import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Saves things into the library and lets the on-device AI organize them:
/// extracts text, builds the search embedding, and writes a title, summary and tags.
@MainActor
@Observable
final class Librarian {
    let llm: LLMService
    var context: ModelContext?

    /// Turn off to keep items exactly as saved (no AI titles, summaries or tags).
    var autoOrganize: Bool = UserDefaults.standard.object(forKey: "autoOrganize") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoOrganize, forKey: "autoOrganize")
            if autoOrganize { runQueue() }
        }
    }

    private(set) var processingCount = 0
    private var queueRunning = false
    /// Background work adding each item (copying, fetching, reading), so it can be cancelled.
    private var addTasks: [UUID: Task<Void, Never>] = [:]
    /// The item the AI is organizing right now.
    private var organizing: (id: UUID, task: Task<Void, Never>)?
    /// Cancelled items, so late stage updates don't bring them back into the list.
    private var cancelledIDs: Set<UUID> = []

    // MARK: Upload activity (what the uploads tray shows)

    enum Stage: Equatable {
        case copying
        case reading(String)
        case waitingForModel
        case queued
        case summarizing
        case done
        case failed(String)

        var label: String {
            switch self {
            case .copying: "Copying into your library…"
            case .reading(let what): what
            case .waitingForModel: "Waiting for an AI model (Settings)"
            case .queued: "Queued for summary…"
            case .summarizing: "Summarizing lessons…"
            case .done: "Added"
            case .failed(let why): why
            }
        }

        /// Done or failed: the tray entry fades out on its own.
        var isTerminal: Bool {
            if case .failed = self { return true }
            return self == .done
        }

        var isFinished: Bool {
            switch self {
            case .done, .failed, .waitingForModel: true
            default: false
            }
        }

        /// Copying a file in or reading text out of it.
        var isAdding: Bool {
            switch self {
            case .copying, .reading: true
            default: false
            }
        }

        /// Rough share of the work done, for the mini progress bars.
        var progress: Double {
            switch self {
            case .copying: 0.1
            case .reading: 0.35
            case .waitingForModel: 0.5
            case .queued: 0.55
            case .summarizing: 0.8
            case .done, .failed: 1
            }
        }
    }

    struct Activity: Identifiable, Equatable {
        let id: UUID
        var title: String
        var symbol: String
        var stage: Stage
        /// Placeholders stand for work that has no item yet (e.g. pulling a video out of Photos) and can't be cancelled.
        var isPlaceholder = false
    }

    /// Newest first. Finished entries fade out after a few seconds.
    private(set) var activities: [Activity] = []
    /// The most recently added item, so the main page can fly to it.
    private(set) var lastAddedID: UUID?

    /// IDs of items still being copied, read or summarized.
    var busyItemIDs: Set<UUID> {
        Set(activities.filter { !$0.stage.isFinished }.map(\.id))
    }

    private func setStage(_ item: Item, _ stage: Stage, create: Bool = true) {
        setStage(id: item.id, title: item.displayTitle, symbol: item.kind.symbol, stage, create: create)
    }

    private func setStage(id: UUID, title: String, symbol: String, _ stage: Stage, create: Bool = true) {
        guard !cancelledIDs.contains(id) else { return }
        if let i = activities.firstIndex(where: { $0.id == id }) {
            activities[i].stage = stage
            activities[i].title = title
        } else if create {
            activities.insert(Activity(id: id, title: title, symbol: symbol, stage: stage), at: 0)
        } else {
            return
        }
        if stage.isTerminal {
            Task {
                try? await Task.sleep(for: .seconds(6))
                activities.removeAll { $0.id == id && $0.stage == stage }
            }
        }
    }

    /// For slow work that happens before an item exists (e.g. pulling a video out of Photos).
    func startPlaceholder(_ title: String, symbol: String) -> UUID {
        let id = UUID()
        setStage(id: id, title: title, symbol: symbol, .copying)
        if let i = activities.firstIndex(where: { $0.id == id }) { activities[i].isPlaceholder = true }
        return id
    }

    func endPlaceholder(_ id: UUID) {
        activities.removeAll { $0.id == id }
    }

    func clearFinishedActivities() {
        activities.removeAll { $0.stage.isFinished }
    }

    /// When a model finishes loading, items that were waiting move on.
    func modelBecameReady() {
        for i in activities.indices where activities[i].stage == .waitingForModel { activities[i].stage = .queued }
        runQueue()
    }

    init(llm: LLMService) {
        self.llm = llm
    }

    // MARK: Adding

    @discardableResult
    func addNote(_ text: String, title: String = "", space: Space? = nil) -> Item {
        let item = Item(kind: .note, title: title, body: text, space: space)
        insert(item)
        return item
    }

    /// Accepts pasted text: a URL becomes a link, anything else a note.
    func addPasted(_ text: String, space: Space? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") {
            addLink(url, space: space)
        } else if !trimmed.isEmpty {
            addNote(trimmed, space: space)
        }
    }

    @discardableResult
    func addLink(_ url: URL, comment: String = "", space: Space? = nil) -> Item {
        let item = Item(kind: .link, title: url.host() ?? url.absoluteString, body: comment, urlString: url.absoluteString, space: space)
        item.aiStatus = .processing
        insert(item, organize: false)
        setStage(item, .reading("Fetching the page…"))
        addTasks[item.id] = Task {
            do {
                let content = try await ContentExtractor.fetchLink(url)
                if !content.title.isEmpty { item.title = content.title }
                item.extractedText = [content.description, content.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if let imageURL = content.imageURL { item.thumbnail = await ContentExtractor.fetchImageData(imageURL) }
            } catch {
                // Offline or blocked: keep the link; it can be re-fetched later.
            }
            if discardIfCancelled(item) { return }
            item.aiStatus = .pending
            finishAdding(item)
        }
        return item
    }

    func addImage(_ data: Data, fileExtension: String = "jpg", space: Space? = nil) {
        guard let name = try? AttachmentStore.save(data, fileExtension: fileExtension) else { return }
        let item = Item(kind: .image, attachmentName: name, thumbnail: ContentExtractor.thumbnail(from: data), space: space)
        item.attachmentData = data
        item.aiStatus = .processing
        insert(item, organize: false)
        setStage(item, .reading("Reading text in the image…"))
        addTasks[item.id] = Task {
            item.extractedText = await ContentExtractor.recognizeText(in: data)
            if discardIfCancelled(item) { return }
            item.aiStatus = .pending
            finishAdding(item)
        }
        return item
    }

    /// Imports what was saved from the Share menu while Loom was closed or in the background.
    func importShareInbox() {
        guard context != nil else { return }
        for (entry, note) in ShareInbox.pending() {
            switch entry.kind {
            case .link:
                if let string = entry.url, let url = URL(string: string) { addLink(url, comment: entry.comment) }
            case .text:
                if let text = entry.text {
                    if entry.comment.isEmpty { addPasted(text) } else { addNote(text + "\n\n" + entry.comment) }
                }
            case .file:
                if let name = entry.fileName, let url = ShareInbox.fileURL(name),
                   FileManager.default.fileExists(atPath: url.path) {
                    let item = addFile(url, removeSourceWhenDone: true)
                    if !entry.comment.isEmpty { item.body = entry.comment }
                }
            }
            ShareInbox.finish(note)
        }
    }

    /// Adds any file. It appears right away; copying and reading happen in the background.
    /// Pass `removeSourceWhenDone` for temporary copies (drops, Photos) so they're cleaned up after.
    @discardableResult
    func addFile(_ url: URL, space: Space? = nil, removeSourceWhenDone: Bool = false) -> Item {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: ItemKind = type.conforms(to: .pdf) ? .pdf
            : type.conforms(to: .image) ? .image
            : type.conforms(to: .movie) ? .video
            : .file
        let title = url.deletingPathExtension().lastPathComponent
        let item = Item(kind: kind, title: kind == .image ? "" : title, space: space)
        item.aiStatus = .processing
        insert(item, organize: false)
        setStage(id: item.id, title: url.lastPathComponent, symbol: kind.symbol, .copying)

        addTasks[item.id] = Task {
            let name = await Task.detached(priority: .userInitiated) { try? AttachmentStore.importFile(at: url) }.value
            if removeSourceWhenDone { try? FileManager.default.removeItem(at: url) }
            if let name, Task.isCancelled { item.attachmentName = name }
            if discardIfCancelled(item) { return }
            guard let name else {
                addTasks[item.id] = nil
                item.aiStatus = .failed
                setStage(item, .failed("Couldn't copy \(url.lastPathComponent)"))
                try? context?.save()
                return
            }
            item.attachmentName = name
            let stored = AttachmentStore.url(for: name)
            item.attachmentData = try? Data(contentsOf: stored, options: .mappedIfSafe)
            switch kind {
            case .pdf:
                item.thumbnail = ContentExtractor.pdfThumbnail(stored)
                setStage(item, .reading("Reading the PDF…"))
                item.extractedText = await ContentExtractor.text(fromFile: stored)
            case .image:
                item.thumbnail = (try? Data(contentsOf: stored)).flatMap { ContentExtractor.thumbnail(from: $0) }
                setStage(item, .reading("Reading text in the image…"))
                item.extractedText = await ContentExtractor.text(fromFile: stored)
            case .video:
                setStage(item, .reading("Transcribing the video…"))
                await readVideo(item, from: stored)
            default:
                setStage(item, .reading("Reading the file…"))
                item.extractedText = await ContentExtractor.text(fromFile: stored)
            }
            if discardIfCancelled(item) { return }
            item.aiStatus = .pending
            finishAdding(item)
        }
    }

    /// Transcribes a video and reads text off its frames. Returns why there's no transcript, if there isn't one.
    @discardableResult
    private func readVideo(_ item: Item, from url: URL) async -> String? {
        let info = await ContentExtractor.videoInfo(url)
        if item.thumbnail == nil { item.thumbnail = info.thumbnail }
        let length = ContentExtractor.formatDuration(info.duration)
        let read = await ContentExtractor.videoText(url)
        var text = "Video" + (length.isEmpty ? "" : ", \(length) long")
        if !read.transcript.isEmpty { text += "\n\n\(Item.transcriptHeading)\n" + read.transcript }
        if !read.screenText.isEmpty { text += "\n\n\(Item.screenTextHeading)\n" + read.screenText }
        item.extractedText = text
        return read.speechProblem
    }

    // MARK: Cancelling

    /// Stops work on an item. One still being added is removed from the library;
    /// one waiting for or in the AI keeps what it has and isn't summarized.
    func cancel(_ id: UUID) {
        guard activities.first(where: { $0.id == id })?.isPlaceholder != true else { return }
        cancelledIDs.insert(id)
        activities.removeAll { $0.id == id }
        if let task = addTasks[id] {
            task.cancel()  // The add task removes the item at its next step.
            return
        }
        if let organizing, organizing.id == id {
            organizing.task.cancel()
        } else if let item = try? context?.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first,
                  item.aiStatus == .pending {
            item.aiStatus = .skipped
            try? context?.save()
        }
        cancelledIDs.remove(id)
    }

    /// Cancels everything in the list and every item still waiting for the AI.
    func cancelAll() {
        for activity in activities where !activity.stage.isFinished { cancel(activity.id) }
        let pending = AIStatus.pending.rawValue
        for item in (try? context?.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.aiStatusRaw == pending }))) ?? [] {
            item.aiStatus = .skipped
        }
        organizing?.task.cancel()
        try? context?.save()
    }

    /// Ends an add that was cancelled: the half-added item and its file are removed.
    private func discardIfCancelled(_ item: Item) -> Bool {
        addTasks[item.id] = nil
        guard cancelledIDs.contains(item.id) else { return false }
        cancelledIDs.remove(item.id)
        delete(item)
        return true
    }

    func delete(_ item: Item) {
        AttachmentStore.delete(item.attachmentName)
        context?.delete(item)
        try? context?.save()
    }

    /// Call after the user edits an item so search stays accurate.
    func itemEdited(_ item: Item) {
        item.touch()
        item.embedding = SearchIndex.pack(SearchIndex.embed(item.fullText + "\n" + item.summary))
        try? context?.save()
    }

    func reorganize(_ item: Item) {
        item.aiStatus = .pending
        setStage(item, llm.isReady ? .queued : .waitingForModel)
        try? context?.save()
        runQueue()
    }

    /// Queues every item the AI skipped or failed on.
    func organizeAllUnprocessed() {
        guard let items = try? context?.fetch(FetchDescriptor<Item>()) else { return }
        for item in items where item.aiStatus == .skipped || item.aiStatus == .failed { item.aiStatus = .pending }
        try? context?.save()
        runQueue()
    }

    /// Redoes the summary and takeaways for every item.
    func reorganizeAll() {
        guard let items = try? context?.fetch(FetchDescriptor<Item>()) else { return }
        for item in items where item.aiStatus != .processing { item.aiStatus = .pending }
        try? context?.save()
        runQueue()
    }

    /// Items saved before iCloud sync kept their files only on this device. Copies each file into
    /// the library, one at a time, so iCloud can carry it to your other devices.
    func backfillAttachmentsForSync() {
        guard let context else { return }
        let ids = ((try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.attachmentName != nil && $0.attachmentData == nil }))) ?? [])
            .map(\.persistentModelID)
        guard !ids.isEmpty else { return }
        Task {
            for id in ids {
                guard let item = context.model(for: id) as? Item, let name = item.attachmentName,
                      item.attachmentData == nil else { continue }
                let url = AttachmentStore.url(for: name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                item.attachmentData = try? Data(contentsOf: url, options: .mappedIfSafe)
                try? context.save()
                await Task.yield()
            }
        }
    }

    /// Queues items organized by an older prompt so they get takeaways too.
    func upgradeOldSummaries() {
        let done = AIStatus.done.rawValue
        let current = Self.aiVersion
        let outdated = (try? context?.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.aiStatusRaw == done && $0.aiVersion < current }))) ?? []
        // Videos summarized with no transcript got made-up takeaways; read them again.
        let video = ItemKind.video.rawValue
        let unreadVideos = ((try? context?.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.aiStatusRaw == done && $0.kindRaw == video }))) ?? [])
            .filter { !$0.videoHasContent }
        let old = outdated + unreadVideos
        guard !old.isEmpty else { return }
        for item in old { item.aiStatus = .pending }
        try? context?.save()
    }

    // MARK: AI queue

    private func insert(_ item: Item, organize: Bool = true) {
        context?.insert(item)
        try? context?.save()
        lastAddedID = item.id
        if organize { finishAdding(item) }
    }

    private func finishAdding(_ item: Item) {
        item.embedding = SearchIndex.pack(SearchIndex.embed(item.fullText))
        if !autoOrganize {
            item.aiStatus = .skipped
            setStage(item, .done)
        } else {
            setStage(item, llm.isReady ? .queued : .waitingForModel)
        }
        try? context?.save()
        runQueue()
    }

    /// Organizes every item still waiting for the AI. Safe to call often.
    func runQueue() {
        guard !queueRunning, autoOrganize, llm.isReady, let context else { return }
        queueRunning = true
        Task {
            defer { queueRunning = false; processingCount = 0 }
            while llm.isReady {
                let pending = AIStatus.pending.rawValue
                var descriptor = FetchDescriptor<Item>(
                    predicate: #Predicate { $0.aiStatusRaw == pending },
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
                descriptor.fetchLimit = 1
                let count = (try? context.fetchCount(FetchDescriptor<Item>(predicate: #Predicate { $0.aiStatusRaw == pending }))) ?? 0
                processingCount = count
                guard let item = try? context.fetch(descriptor).first else { break }
                let work = Task { await organize(item) }
                organizing = (item.id, work)
                await work.value
                organizing = nil
            }
        }
    }

    /// Bump when the organizing prompt changes; items made with older versions are redone.
    static let aiVersion = 2

    private struct Organized: Decodable {
        var title: String?
        var summary: String?
        var takeaways: [String]?
        var tags: [String]?
    }

    private func organize(_ item: Item) async {
        item.aiStatus = .processing
        if item.kind == .video, !item.videoHasContent, let url = item.attachmentURL {
            // Read it again: Speech Recognition may have been allowed since, or this predates on-screen text.
            setStage(item, .reading("Transcribing the video…"), create: false)
            let problem = await readVideo(item, from: url)
            guard item.videoHasContent else {
                // A filename and a running time are nothing to learn from; the model would only make takeaways up.
                item.summary = ""
                item.takeaways = []
                item.aiStatus = .skipped
                setStage(item, .failed(problem ?? "No speech or on-screen text found in this video."), create: false)
                try? context?.save()
                return
            }
        }
        setStage(item, .summarizing, create: false)
        let text = String(item.fullText.prefix(llmInputBudget))
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 3 else {
            item.aiStatus = .skipped
            setStage(item, .done, create: false)
            return
        }
        let existing = topTags(limit: 30).joined(separator: ", ")
        let prompt = """
        Read this saved \(item.kind.rawValue) from a personal knowledge library and capture what is worth remembering from it.

        CONTENT:
        \"\"\"
        \(text)
        \"\"\"

        Respond with only a JSON object, no other text:
        {"title": "short descriptive title, at most 8 words", "summary": "2-3 sentences stating the main finding, argument or lesson: what the reader should learn or remember, not a description of the document", "takeaways": ["3 to 5 short, specific lessons, facts, numbers or action items from the content, each one sentence"], "tags": ["2 to 5 short lowercase topic tags"]}
        If the content is too thin to learn from, keep takeaways to what it actually says.
        Use only facts from the content. Never write about Loom, this library or tags.
        \(existing.isEmpty ? "" : "Prefer reusing these existing tags when they fit: \(existing)")
        """
        do {
            let parsed: Organized
            if llm.usesAppleModel {
                // Guided generation fills fixed fields, so there's no JSON to parse.
                let fields = try await llm.organizeWithAppleModel(
                    Self.applePrompt(kind: item.kind, text: text, existingTags: existing),
                    instructions: "You are a precise librarian for a private personal knowledge library.")
                parsed = Organized(title: fields.title, summary: fields.summary, takeaways: fields.takeaways,
                                   tags: Self.relevantTags(fields.tags, existing: existing, content: text))
            } else {
                let reply = try await llm.generate(
                    system: "You are a precise librarian. You only ever reply with valid JSON.",
                    prompt: prompt, maxTokens: 550, temperature: 0.2)
                guard let json = Self.parseJSON(reply) else {
                    item.aiStatus = .failed
                    setStage(item, .failed("Couldn't summarize; try Regenerate"), create: false)
                    try? context?.save()
                    return
                }
                parsed = json
            }
            // Keep titles the user (or the web page) gave, except bare hostnames and empty ones.
            if let title = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
               item.title.isEmpty || item.title == item.url?.host() {
                item.title = title
            }
            if let summary = parsed.summary { item.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let takeaways = parsed.takeaways {
                item.takeaways = takeaways
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespacesAndNewlines)) }
                    .filter { !$0.isEmpty }
                    .prefix(6).map { $0 }
            }
            if let tags = parsed.tags {
                let cleaned = tags.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines)) }
                    .filter { !$0.isEmpty && $0.count < 30 }
                item.tags = Array(NSOrderedSet(array: item.tags + cleaned)).compactMap { $0 as? String }.prefix(8).map { $0 }
            }
            item.embedding = SearchIndex.pack(SearchIndex.embed(
                item.fullText + "\n" + item.summary + "\n" + item.takeaways.joined(separator: "\n") + "\n" + item.tags.joined(separator: " ")))
            item.aiVersion = Self.aiVersion
            item.aiStatus = .done
            setStage(item, .done, create: false)
        } catch where Task.isCancelled || error is CancellationError {
            // Cancelled from the activity list: keep what the item had and don't summarize it.
            item.aiStatus = .skipped
            activities.removeAll { $0.id == item.id }
        } catch let error as AppleModelError where error.isRuntimeFailure && !llm.isReady {
            // The model stopped responding: wait for it (or a downloaded model) instead of failing the item.
            item.aiStatus = .pending
            setStage(item, .waitingForModel, create: false)
        } catch {
            item.aiStatus = .failed
            setStage(item, .failed("Couldn't summarize; try Regenerate"), create: false)
        }
        try? context?.save()
    }

    /// Roughly how much text we feed the model per item; smaller on iPhone and for Apple's model.
    private var llmInputBudget: Int { llm.inputBudgetCharacters }

    private static func applePrompt(kind: ItemKind, text: String, existingTags: String) -> String {
        """
        Read this saved \(kind.rawValue) and capture what is worth remembering from it.
        If the content is too thin to learn from, keep takeaways to what it actually says.
        Use only facts from the content. Never write about Loom, this library or tags.
        Tags must name topics this content is actually about.

        CONTENT:
        \(text)
        \(existingTags.isEmpty ? "" : "\nThe library already uses these tags. Reuse one only if the content above is clearly about it: \(existingTags)")
        """
    }

    /// Small models sometimes copy the whole list of existing tags. Keep a reused tag only if the content mentions it.
    private static func relevantTags(_ tags: [String], existing: String, content: String) -> [String] {
        let known = Set(existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let haystack = content.lowercased()
        return tags.filter { tag in
            let t = tag.lowercased().trimmingCharacters(in: .whitespaces)
            guard known.contains(t) else { return true }
            return t.split(separator: " ").contains { haystack.contains(String($0.prefix(5))) }
        }
    }

    private static func parseJSON(_ reply: String) -> Organized? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        let json = String(reply[start...end])
        return try? JSONDecoder().decode(Organized.self, from: Data(json.utf8))
    }

    func topTags(limit: Int) -> [String] {
        guard let items = try? context?.fetch(FetchDescriptor<Item>()) else { return [] }
        var counts: [String: Int] = [:]
        for item in items { for tag in item.tags { counts[tag, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }
}
