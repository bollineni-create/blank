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
    }

    struct Activity: Identifiable, Equatable {
        let id: UUID
        var title: String
        var symbol: String
        var stage: Stage
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
        Task {
            do {
                let content = try await ContentExtractor.fetchLink(url)
                if !content.title.isEmpty { item.title = content.title }
                item.extractedText = [content.description, content.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if let imageURL = content.imageURL { item.thumbnail = await ContentExtractor.fetchImageData(imageURL) }
            } catch {
                // Offline or blocked: keep the link; it can be re-fetched later.
            }
            item.aiStatus = .pending
            finishAdding(item)
        }
        return item
    }

    func addImage(_ data: Data, fileExtension: String = "jpg", space: Space? = nil) {
        guard let name = try? AttachmentStore.save(data, fileExtension: fileExtension) else { return }
        let item = Item(kind: .image, attachmentName: name, thumbnail: ContentExtractor.thumbnail(from: data), space: space)
        item.aiStatus = .processing
        insert(item, organize: false)
        setStage(item, .reading("Reading text in the image…"))
        Task {
            item.extractedText = await ContentExtractor.recognizeText(in: data)
            item.aiStatus = .pending
            finishAdding(item)
        }
    }

    /// Adds any file. It appears right away; copying and reading happen in the background.
    /// Pass `removeSourceWhenDone` for temporary copies (drops, Photos) so they're cleaned up after.
    func addFile(_ url: URL, space: Space? = nil, removeSourceWhenDone: Bool = false) {
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

        Task {
            let name = await Task.detached(priority: .userInitiated) { try? AttachmentStore.importFile(at: url) }.value
            if removeSourceWhenDone { try? FileManager.default.removeItem(at: url) }
            guard let name else {
                item.aiStatus = .failed
                setStage(item, .failed("Couldn't copy \(url.lastPathComponent)"))
                try? context?.save()
                return
            }
            item.attachmentName = name
            let stored = AttachmentStore.url(for: name)
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
                let info = await ContentExtractor.videoInfo(stored)
                item.thumbnail = info.thumbnail
                let length = ContentExtractor.formatDuration(info.duration)
                let transcript = await ContentExtractor.transcribe(stored)
                item.extractedText = "Video \(title)" + (length.isEmpty ? "" : ", \(length) long")
                    + (transcript.isEmpty ? "" : "\n\nTranscript:\n" + transcript)
            default:
                setStage(item, .reading("Reading the file…"))
                item.extractedText = await ContentExtractor.text(fromFile: stored)
            }
            item.aiStatus = .pending
            finishAdding(item)
        }
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

    /// Queues items organized by an older prompt so they get takeaways too.
    func upgradeOldSummaries() {
        let done = AIStatus.done.rawValue
        let current = Self.aiVersion
        let old = (try? context?.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.aiStatusRaw == done && $0.aiVersion < current }))) ?? []
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
                await organize(item)
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
        \(existing.isEmpty ? "" : "Prefer reusing these existing tags when they fit: \(existing)")
        """
        do {
            let parsed: Organized
            if llm.usesAppleModel {
                // Guided generation fills fixed fields, so there's no JSON to parse.
                let fields = try await llm.organizeWithAppleModel(
                    Self.applePrompt(kind: item.kind, text: text, existingTags: existing),
                    instructions: "You are a precise librarian for a private personal knowledge library.")
                parsed = Organized(title: fields.title, summary: fields.summary, takeaways: fields.takeaways, tags: fields.tags)
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
        \(existingTags.isEmpty ? "" : "Prefer reusing these existing tags when they fit: \(existingTags)")

        CONTENT:
        \(text)
        """
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
