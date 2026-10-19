import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Lets only a few pieces of work run at once. Reading twenty files together (OCR, PDF text, transcription)
/// filled memory and starved the main thread, which is what froze the app when a big batch was dropped in.
final class WorkLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    /// Waits for a free slot. Pair every call with `release()`.
    func acquire() async {
        lock.lock()
        if running < limit {
            running += 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            lock.unlock()
        }
    }

    /// Hands the slot to the next in line, or frees it.
    func release() {
        lock.lock()
        guard !waiting.isEmpty else {
            running -= 1
            lock.unlock()
            return
        }
        let next = waiting.removeFirst()
        lock.unlock()
        next.resume()
    }
}

/// Saves things into the library and lets the on-device AI organize them:
/// extracts text, builds the search embedding, and writes a title, summary and tags.
@MainActor
@Observable
final class Librarian {
    let llm: LLMService
    var context: ModelContext?

    /// Files copy in one at a time (the disk is quickest that way, and each shows up as soon as its copy is
    /// whole), a couple are read at once, and a few web pages fetch at once.
    private static let copies = WorkLimiter(limit: 1)
    private static let readers = WorkLimiter(limit: 2)
    private static let fetches = WorkLimiter(limit: 4)

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
    private var backfillRunning = false
    /// Asked to copy files again while a copy was running.
    private var backfillAgain = false

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
            case .waitingForModel: "Waiting for Apple Intelligence"
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
        item.aiStatus = .importing
        insert(item)
        addTasks[item.id] = Task {
            if discardIfCancelled(item) { return }
            await finishAdding(item)
        }
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
        item.aiStatus = .importing
        insert(item)
        addTasks[item.id] = Task {
            await fetchPage(for: item)
            if discardIfCancelled(item) { return }
            await finishAdding(item)
        }
        return item
    }

    /// Fetches a link's page text and preview image. Offline or blocked, the link is kept as it is.
    private func fetchPage(for item: Item) async {
        guard let url = item.url else { return }
        setStage(item, .reading("Fetching the page…"))
        await Self.fetches.acquire()
        defer { Self.fetches.release() }
        guard !Task.isCancelled else { return }
        do {
            let content = try await ContentExtractor.fetchLink(url)
            if !content.title.isEmpty { item.title = content.title }
            item.extractedText = [content.description, content.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if let imageURL = content.imageURL { item.thumbnail = await ContentExtractor.fetchImageData(imageURL) }
        } catch {
            // Offline or blocked: keep the link; it can be re-fetched later.
        }
    }

    func addImage(_ data: Data, fileExtension: String = "jpg", space: Space? = nil) {
        let item = Item(kind: .image, space: space)
        importAttachment(into: item, named: "Image") { try AttachmentStore.save(data, fileExtension: fileExtension) }
    }

    /// Adds any file. The tray shows it right away; it joins the library as soon as its copy is whole, and
    /// reading it (text, OCR, transcription) happens a few files at a time in the background.
    /// Pass `removeSourceWhenDone` for temporary copies (drops, Photos) so they're cleaned up after.
    func addFile(_ url: URL, space: Space? = nil, removeSourceWhenDone: Bool = false) {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: ItemKind = type.conforms(to: .pdf) ? .pdf
            : type.conforms(to: .image) ? .image
            : type.conforms(to: .movie) ? .video
            : .file
        let title = url.deletingPathExtension().lastPathComponent
        let item = Item(kind: kind, title: kind == .image ? "" : title, space: space)
        importAttachment(into: item, named: url.lastPathComponent, removeSource: removeSourceWhenDone ? url : nil) {
            try AttachmentStore.importFile(at: url)
        }
    }

    /// Copies a file into the library, then adds the item and reads it. The item is only saved once its file
    /// is whole, so quitting mid-copy leaves nothing behind; quitting mid-read is picked up at the next launch.
    private func importAttachment(into item: Item, named displayName: String, removeSource: URL? = nil,
                                  copy: @escaping @Sendable () throws -> String) {
        item.aiStatus = .importing
        let symbol = item.kind.symbol
        setStage(id: item.id, title: displayName, symbol: symbol, .copying)
        addTasks[item.id] = Task {
            await Self.copies.acquire()
            let name = await Task.detached(priority: .userInitiated) { try? copy() }.value
            Self.copies.release()
            if let removeSource { AttachmentStore.removeTemporary(removeSource) }
            if cancelledIDs.contains(item.id) {
                // Cancelled before it joined the library: nothing to keep.
                AttachmentStore.delete(name)
                cancelledIDs.remove(item.id)
                addTasks[item.id] = nil
                return
            }
            guard let name else {
                addTasks[item.id] = nil
                setStage(id: item.id, title: displayName, symbol: symbol, .failed("Couldn't copy \(displayName)"))
                return
            }
            item.attachmentName = name
            insert(item)
            await readAttachment(item)
            if discardIfCancelled(item) { return }
            await finishAdding(item)
        }
    }

    /// Reads an item's file: a thumbnail and its text, OCR or transcript. A couple run at once.
    private func readAttachment(_ item: Item) async {
        guard let name = item.attachmentName else { return }
        let stored = AttachmentStore.url(for: name)
        await Self.readers.acquire()
        defer { Self.readers.release() }
        guard !Task.isCancelled else { return }
        // The copy for iCloud is made off the main thread once the AI is done (see backfillAttachmentsForSync).
        switch item.kind {
        case .pdf:
            setStage(item, .reading("Reading the PDF…"))
            if item.thumbnail == nil { item.thumbnail = await ContentExtractor.fileThumbnail(stored, kind: .pdf) }
            item.extractedText = await ContentExtractor.text(fromFile: stored)
        case .image:
            setStage(item, .reading("Reading text in the image…"))
            if item.thumbnail == nil { item.thumbnail = await ContentExtractor.fileThumbnail(stored, kind: .image) }
            item.extractedText = await ContentExtractor.text(fromFile: stored)
        case .video:
            setStage(item, .reading("Transcribing the video…"))
            await readVideo(item, from: stored)
        default:
            setStage(item, .reading("Reading the file…"))
            item.extractedText = await ContentExtractor.text(fromFile: stored)
        }
    }

    /// Finishes adds the last run left behind. An item is `importing` from the moment it's saved until it has
    /// been read, so anything still in that state (or stuck in `processing` from an older build) was cut off
    /// by quitting: it's read again and queued. A file whose copy never finished has nothing in it to keep.
    func resumeInterruptedAdds() {
        guard let context else { return }
        let importing = AIStatus.importing.rawValue
        let processing = AIStatus.processing.rawValue
        let stuck = (try? context.fetch(FetchDescriptor<Item>(
            predicate: #Predicate { $0.aiStatusRaw == importing || $0.aiStatusRaw == processing }))) ?? []
        for item in stuck {
            let wasImporting = item.aiStatus == .importing
            switch item.kind {
            case .note:
                if wasImporting { resume(item) { } } else { item.aiStatus = .pending }
            case .link:
                if wasImporting || item.extractedText.isEmpty {
                    resume(item) { await self.fetchPage(for: item) }
                } else {
                    item.aiStatus = .pending
                }
            case .image, .video, .pdf, .file:
                if item.attachmentName == nil, item.attachmentData == nil {
                    // Never finished copying in, before copies were staged: an empty shell with no file.
                    context.delete(item)
                } else if item.attachmentURL.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                    // Another device is still adding it; its result arrives through iCloud.
                    continue
                } else if wasImporting || item.extractedText.isEmpty {
                    resume(item) { await self.readAttachment(item) }
                } else {
                    item.aiStatus = .pending
                }
            }
        }
        try? context.save()
    }

    private func resume(_ item: Item, _ read: @escaping () async -> Void) {
        item.aiStatus = .importing
        addTasks[item.id] = Task {
            await read()
            if discardIfCancelled(item) { return }
            await finishAdding(item)
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
        guard cancelledIDs.contains(item.id) else { return false }
        addTasks[item.id] = nil
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
        for item in items where item.aiStatus != .processing && item.aiStatus != .importing { item.aiStatus = .pending }
        try? context?.save()
        runQueue()
    }

    /// Marks every item and space as changed so iCloud uploads them again. Items saved while sync was off
    /// or failing (no iCloud, or a container iCloud refused) were never sent, and iCloud only sends changes.
    func resendLibraryToICloud() {
        guard let context else { return }
        for item in (try? context.fetch(FetchDescriptor<Item>())) ?? [] { item.touch() }
        // Spaces have no edit date, so nudge the creation date by a millisecond; nothing shows that precision.
        for space in (try? context.fetch(FetchDescriptor<Space>())) ?? [] { space.createdAt += 0.001 }
        try? context.save()
        backfillAttachmentsForSync()
    }

    /// Items saved before iCloud sync kept their files only on this device. Copies each file into
    /// the library, one at a time, so iCloud can carry it to your other devices.
    func backfillAttachmentsForSync() {
        guard let container = context?.container else { return }
        guard !backfillRunning else { backfillAgain = true; return }
        backfillRunning = true
        Task {
            await Task.detached(priority: .utility) { Self.copyAttachmentsIntoLibrary(container) }.value
            backfillRunning = false
            if backfillAgain {
                backfillAgain = false
                backfillAttachmentsForSync()
            }
        }
    }

    /// Runs off the main thread with its own context: reading and saving a large video on the main
    /// thread froze the screen. Skips items the AI may still be changing; they're picked up once it's done.
    nonisolated private static func copyAttachmentsIntoLibrary(_ container: ModelContainer) {
        let processing = AIStatus.processing.rawValue
        let pending = AIStatus.pending.rawValue
        let importing = AIStatus.importing.rawValue
        let ids = ((try? ModelContext(container).fetch(FetchDescriptor<Item>(predicate: #Predicate {
            $0.attachmentName != nil && $0.attachmentData == nil
                && $0.aiStatusRaw != processing && $0.aiStatusRaw != pending && $0.aiStatusRaw != importing
        }))) ?? []).map(\.id)
        for id in ids {
            autoreleasepool {
                // A fresh context per file, so each copy is let go once it's saved. Fetched by ID, not
                // looked up, so an item deleted meanwhile is simply skipped.
                let context = ModelContext(container)
                guard let item = try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first,
                      let name = item.attachmentName,
                      item.attachmentData == nil,
                      let data = try? Data(contentsOf: AttachmentStore.url(for: name), options: .mappedIfSafe) else { return }
                item.attachmentData = data
                try? context.save()
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

    private func insert(_ item: Item) {
        context?.insert(item)
        try? context?.save()
        lastAddedID = item.id
    }

    /// The last step of adding: the search embedding, then the AI queue (or done, with auto-organize off).
    private func finishAdding(_ item: Item) async {
        item.embedding = await SearchIndex.embedInBackground(item.fullText)
        if discardIfCancelled(item) { return }
        if !autoOrganize {
            item.aiStatus = .skipped
            setStage(item, .done)
        } else {
            item.aiStatus = .pending
            setStage(item, llm.isReady ? .queued : .waitingForModel)
        }
        addTasks[item.id] = nil
        try? context?.save()
        runQueue()
        // With the AI off, nothing else will make the copy for iCloud.
        if !autoOrganize { backfillAttachmentsForSync() }
    }

    /// Organizes every item still waiting for the AI. Safe to call often.
    func runQueue() {
        guard !queueRunning, autoOrganize, llm.isReady, let context else { return }
        queueRunning = true
        Task {
            defer {
                queueRunning = false
                processingCount = 0
                backfillAttachmentsForSync()
            }
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

    private struct Organized {
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
        do {
            // Guided generation fills fixed fields, so there's no JSON to parse.
            let fields = try await llm.organizeWithAppleModel(
                Self.applePrompt(kind: item.kind, text: text, existingTags: existing),
                instructions: "You are a precise librarian for a private personal knowledge library.")
            let parsed = Organized(title: fields.title, summary: fields.summary, takeaways: fields.takeaways,
                                   tags: Self.relevantTags(fields.tags, existing: existing, content: text))
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
            item.embedding = await SearchIndex.embedInBackground(
                item.fullText + "\n" + item.summary + "\n" + item.takeaways.joined(separator: "\n") + "\n" + item.tags.joined(separator: " "))
            item.aiVersion = Self.aiVersion
            item.aiStatus = .done
            setStage(item, .done, create: false)
        } catch where Task.isCancelled || error is CancellationError {
            // Cancelled from the activity list: keep what the item had and don't summarize it.
            item.aiStatus = .skipped
            activities.removeAll { $0.id == item.id }
        } catch let error as AppleModelError where error.isRuntimeFailure && !llm.isReady {
            // The model stopped responding: wait for it instead of failing the item.
            item.aiStatus = .pending
            setStage(item, .waitingForModel, create: false)
        } catch {
            item.aiStatus = .failed
            setStage(item, .failed("Couldn't summarize; try Regenerate"), create: false)
        }
        try? context?.save()
    }

    /// Roughly how much text we feed the model per item.
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

    func topTags(limit: Int) -> [String] {
        guard let items = try? context?.fetch(FetchDescriptor<Item>()) else { return [] }
        var counts: [String: Int] = [:]
        for item in items { for tag in item.tags { counts[tag, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }
}
