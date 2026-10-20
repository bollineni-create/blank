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
    /// Items the model went quiet on once; they were put back in line, and a second time is marked failed.
    private var stalledOnce: Set<UUID> = []
    /// Files whose copy failed before they joined the library: how to try again, and how to let go.
    private struct FailedAdd {
        let again: () -> Void
        let cleanUp: () -> Void
    }
    private var failedAdds: [UUID: FailedAdd] = [:]
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

        /// Done: the tray entry fades out on its own. Failed ones stay until they're retried or removed.
        var isTerminal: Bool { self == .done }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
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
        for activity in activities where activity.stage.isFailed { failedAdds.removeValue(forKey: activity.id)?.cleanUp() }
        activities.removeAll { $0.stage.isFinished }
    }

    /// Tries a failed entry again: a file that couldn't be copied is copied again; one the AI couldn't
    /// organize, or a video with nothing to hear, goes back through the AI.
    func retry(_ id: UUID) {
        activities.removeAll { $0.id == id }
        if let failed = failedAdds.removeValue(forKey: id) {
            failed.again()
        } else if let item = fetchItem(id) {
            reorganize(item)
        }
    }

    /// Removes a failed entry, and the item with it if it made it into the library.
    func discard(_ id: UUID) {
        activities.removeAll { $0.id == id }
        failedAdds.removeValue(forKey: id)?.cleanUp()
        if let item = fetchItem(id) { delete(item) }
    }

    // MARK: Cleaning up

    /// A file that's broken: it never made it into the library whole, what's in the library has no file behind
    /// it, or it hangs off nothing on the map.
    struct BrokenFile: Identifiable, Equatable {
        enum Reason {
            /// Its copy failed, so it's still in the status list and never joined the library.
            case copyFailed
            /// It's in the library, but its file is neither on this device nor in iCloud.
            case fileMissing
            /// It's in the library with no tags and no space, so it floats loose on the map, connected to
            /// nothing: a video saved as a picture by mistake, a photo with no words in it, anything the AI
            /// found nothing in.
            case loose
        }
        let id: UUID
        let reason: Reason
        /// What kind of item it is, when it's in the library.
        var kind: ItemKind?
        /// Its name, for the dialog that asks before removing.
        var title = ""
    }

    /// Adds cut off longer ago than this aren't still arriving from another device; they're stuck.
    private static let addGracePeriod: TimeInterval = 60 * 60

    /// Every broken file: status-list entries whose copy failed, items whose file is missing from this device
    /// and from iCloud, and items that hang off nothing on the map (no tags, no space). Nothing still being
    /// added, waiting for the AI or being organized counts, and with `syncing` on, neither does an item another
    /// device started adding within the last hour (its file arrives when that device finishes).
    func brokenFiles(syncing: Bool) -> [BrokenFile] {
        var broken: [BrokenFile] = []
        for activity in activities where activity.stage.isFailed && failedAdds[activity.id] != nil {
            broken.append(BrokenFile(id: activity.id, reason: .copyFailed, title: activity.title))
        }
        let recent = Date.now.addingTimeInterval(-Self.addGracePeriod)
        func inProgress(_ item: Item) -> Bool {
            addTasks[item.id] != nil || organizing?.id == item.id
        }
        func stillArriving(_ item: Item) -> Bool {
            (item.aiStatus == .importing || item.aiStatus == .processing) && item.createdAt > recent
        }

        // An item with a copy for iCloud can't be missing its file: the file is written from that copy on first use.
        let note = ItemKind.note.rawValue
        let link = ItemKind.link.rawValue
        let candidates = (try? context?.fetch(FetchDescriptor<Item>(
            predicate: #Predicate { $0.attachmentData == nil && $0.kindRaw != note && $0.kindRaw != link }))) ?? []
        for item in candidates {
            if let name = item.attachmentName, AttachmentStore.hasFile(named: name) { continue }
            if inProgress(item) || (syncing && stillArriving(item)) { continue }
            broken.append(BrokenFile(id: item.id, reason: .fileMissing, kind: item.kind, title: item.displayTitle))
        }

        // Loose on the map: nothing connects it to anything, and the AI is done with it.
        let found = Set(broken.map(\.id))
        let items = (try? context?.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        for item in items where !found.contains(item.id) {
            guard item.tags.isEmpty, item.space == nil else { continue }
            // Still on its way through: it may yet get tags.
            if inProgress(item) || item.aiStatus == .importing || item.aiStatus == .processing || item.aiStatus == .pending { continue }
            broken.append(BrokenFile(id: item.id, reason: .loose, kind: item.kind, title: item.displayTitle))
        }
        return broken
    }

    /// Removes broken files in one go: what Remove does for each, without going row by row.
    func cleanUp(_ files: [BrokenFile]) {
        for file in files { discard(file.id) }
    }

    private func fetchItem(_ id: UUID) -> Item? {
        try? context?.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
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

    /// What to do when a file being added has the same name as one already in the library.
    enum ConflictPolicy {
        /// Ask, through `conflict`: replace the copy that's there, or skip this file.
        case ask
        case replace
        /// Add it as another copy, without asking (Shortcuts and Siri have no window to ask in).
        case keepBoth
    }

    /// Adds any file. The tray shows it right away; it joins the library as soon as its copy is whole, and
    /// reading it (text, OCR, transcription) happens a few files at a time in the background.
    /// Pass `removeSourceWhenDone` for temporary copies (drops, Photos) so they're cleaned up after.
    /// A file with the same name as one already in the library is handled per `onConflict`.
    func addFile(_ url: URL, space: Space? = nil, removeSourceWhenDone: Bool = false, onConflict: ConflictPolicy = .ask) {
        let fileName = url.lastPathComponent
        let matches = onConflict == .keepBoth ? [] : existingCopies(named: fileName)
        guard !matches.isEmpty, onConflict == .ask else {
            startFile(url, space: space, removeSourceWhenDone: removeSourceWhenDone, replacing: matches)
            return
        }
        ask(Conflict(fileName: fileName, matches: matches) { [weak self] replace in
            guard let self else { return }
            if replace {
                startFile(url, space: space, removeSourceWhenDone: removeSourceWhenDone, replacing: matches)
            } else if removeSourceWhenDone {
                AttachmentStore.removeTemporary(url)
            }
        })
    }

    /// Adds a file, taking the place of `replacing` (copies of it already in the library) once its copy is whole.
    /// The new item keeps the old one's space, tags and favorite, so a replaced file stays where it was.
    private func startFile(_ url: URL, space: Space?, removeSourceWhenDone: Bool, replacing: [ExistingCopy]) {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: ItemKind = type.conforms(to: .pdf) ? .pdf
            : type.conforms(to: .image) ? .image
            : type.conforms(to: .movie) ? .video
            : .file
        let title = url.deletingPathExtension().lastPathComponent
        let item = Item(kind: kind, title: kind == .image ? "" : title, space: space)
        if let old = replacing.compactMap({ fetchItem($0.id) }).first {
            if space == nil { item.space = old.space }
            item.tags = old.tags
            item.isFavorite = old.isFavorite
        }
        importAttachment(into: item, named: url.lastPathComponent, removeSource: removeSourceWhenDone ? url : nil,
                         replacing: replacing.map(\.id)) {
            try AttachmentStore.importFile(at: url)
        }
    }

    /// Copies a file into the library, then adds the item and reads it. The item is only saved once its file
    /// is whole, so quitting mid-copy leaves nothing behind; quitting mid-read is picked up at the next launch.
    /// Items in `replacing` are removed at that same moment, so a copy that fails leaves them as they were.
    private func importAttachment(into item: Item, named displayName: String, removeSource: URL? = nil,
                                  replacing: [UUID] = [], copy: @escaping @Sendable () throws -> String) {
        item.aiStatus = .importing
        let symbol = item.kind.symbol
        setStage(id: item.id, title: displayName, symbol: symbol, .copying)
        addTasks[item.id] = Task {
            await Self.copies.acquire()
            let name = await Task.detached(priority: .userInitiated) { try? copy() }.value
            Self.copies.release()
            if cancelledIDs.contains(item.id) {
                // Cancelled before it joined the library: nothing to keep.
                AttachmentStore.delete(name)
                if let removeSource { AttachmentStore.removeTemporary(removeSource) }
                cancelledIDs.remove(item.id)
                addTasks[item.id] = nil
                return
            }
            guard let name else {
                // The source stays where it is so Retry can copy it again; Remove lets it go.
                addTasks[item.id] = nil
                failedAdds[item.id] = FailedAdd(
                    again: { [weak self] in
                        self?.importAttachment(into: item, named: displayName, removeSource: removeSource,
                                               replacing: replacing, copy: copy)
                    },
                    cleanUp: { if let removeSource { AttachmentStore.removeTemporary(removeSource) } })
                setStage(id: item.id, title: displayName, symbol: symbol, .failed("Couldn't copy \(displayName)"))
                return
            }
            if let removeSource { AttachmentStore.removeTemporary(removeSource) }
            for id in replacing { removeReplaced(id) }
            item.attachmentName = name
            insert(item)
            await readAttachment(item)
            if discardIfCancelled(item) { return }
            await finishAdding(item)
        }
    }

    // MARK: Files already in the library

    /// A copy of a file that's already in the library, or still in the tray after a failed copy.
    struct ExistingCopy {
        let id: UUID
        /// Didn't finish adding: its copy failed, it was cut off, the AI failed on it, or its file is missing.
        let isBroken: Bool
        /// Being copied in or read right now.
        let isInProgress: Bool
    }

    /// Every copy of a file with this name: items whose file came in under it, and tray entries whose copy
    /// of it failed. Names are compared the way Finder does, ignoring case.
    func existingCopies(named fileName: String) -> [ExistingCopy] {
        var copies: [ExistingCopy] = []
        let items = (try? context?.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.attachmentName != nil }))) ?? []
        for item in items {
            guard let stored = item.attachmentName, let original = AttachmentStore.originalName(of: stored),
                  original.caseInsensitiveCompare(fileName) == .orderedSame else { continue }
            let failedInTray = activities.contains { $0.id == item.id && $0.stage.isFailed }
            let missing = !AttachmentStore.hasFile(named: stored) && item.attachmentData == nil
            let inProgress = addTasks[item.id] != nil && !failedInTray
            let cutOff = (item.aiStatus == .importing || item.aiStatus == .processing) && !inProgress
            copies.append(ExistingCopy(id: item.id,
                                       isBroken: failedInTray || missing || cutOff || item.aiStatus == .failed,
                                       isInProgress: inProgress))
        }
        for activity in activities where activity.stage.isFailed && failedAdds[activity.id] != nil
            && activity.title.caseInsensitiveCompare(fileName) == .orderedSame {
            copies.append(ExistingCopy(id: activity.id, isBroken: true, isInProgress: false))
        }
        return copies
    }

    /// Takes a copy out of the library (and the tray) because a new copy of the same file has come in.
    private func removeReplaced(_ id: UUID) {
        activities.removeAll { $0.id == id }
        failedAdds.removeValue(forKey: id)?.cleanUp()
        if let task = addTasks[id] {
            // Still being added: its task removes the half-added item at its next step.
            cancelledIDs.insert(id)
            task.cancel()
            return
        }
        guard let item = fetchItem(id) else { return }
        if let organizing, organizing.id == id {
            // Let the AI step finish (it still writes to the item), then let the item go.
            let task = organizing.task
            task.cancel()
            Task {
                await task.value
                if let item = fetchItem(id) { delete(item) }
            }
            return
        }
        delete(item)
    }

    /// A question for the user: a file being added has the same name as one already in the library.
    struct Conflict: Identifiable {
        let id = UUID()
        let fileName: String
        let matches: [ExistingCopy]
        /// Called once with the answer: replace what's there (true) or skip this file (false).
        let proceed: (Bool) -> Void

        var isBroken: Bool { matches.contains(where: \.isBroken) }

        var title: String {
            if isBroken { return "“\(fileName)” didn't finish adding" }
            if matches.contains(where: \.isInProgress) { return "“\(fileName)” is being added" }
            return "“\(fileName)” is already in your library"
        }

        var message: String {
            let copies = matches.count == 1 ? "the copy" : "the \(matches.count) copies"
            if isBroken {
                let what = matches.count == 1 ? "The copy" : "A copy"
                return "\(what) in your library is incomplete. Replace \(copies) with the file you're adding, or skip this file and keep what's there."
            }
            return "Replace \(copies) in your library with the file you're adding (its space, tags and favorite are kept), or skip this file."
        }
    }

    /// The question being asked right now; the main page shows it. Others wait their turn.
    private(set) var conflict: Conflict?
    private var conflictQueue: [Conflict] = []
    /// How many files are waiting on an answer, counting the one being asked about.
    var conflictsWaiting: Int { conflictQueue.count + (conflict == nil ? 0 : 1) }

    private func ask(_ question: Conflict) {
        if conflict == nil { conflict = question } else { conflictQueue.append(question) }
    }

    /// Answers the current question. With `all`, every file still waiting gets the same answer.
    func resolveConflict(replace: Bool, all: Bool = false) {
        guard let current = conflict else { return }
        conflict = nil
        current.proceed(replace)
        if all {
            let rest = conflictQueue
            conflictQueue.removeAll()
            for question in rest { question.proceed(replace) }
            return
        }
        guard !conflictQueue.isEmpty else { return }
        // Let the alert close before the next one opens, or it stays shut.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if conflict == nil, !conflictQueue.isEmpty { conflict = conflictQueue.removeFirst() }
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
        stalledOnce.remove(item.id)
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
        guard autoOrganize, llm.isReady, let context else { return }
        guard !queueRunning else {
            // Already working through the queue; it picks up anything new on its next pass. Keep the count
            // honest meanwhile, so the tray says what's ahead of a newly queued item.
            refreshProcessingCount()
            return
        }
        queueRunning = true
        Task {
            defer {
                queueRunning = false
                organizing = nil
                processingCount = 0
                if !llm.isReady {
                    // The model went away mid-queue. Say so, instead of leaving items at "Queued for summary…"
                    // with nothing working on them; `modelBecameReady` queues them again.
                    for i in activities.indices where activities[i].stage == .queued { activities[i].stage = .waitingForModel }
                }
                backfillAttachmentsForSync()
            }
            while llm.isReady {
                let pending = AIStatus.pending.rawValue
                var descriptor = FetchDescriptor<Item>(
                    predicate: #Predicate { $0.aiStatusRaw == pending },
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
                descriptor.fetchLimit = 1
                guard let item = try? context.fetch(descriptor).first else { break }
                // Claimed before the work starts, so the count below doesn't see it as still waiting.
                item.aiStatus = .processing
                let work = Task { await organize(item) }
                organizing = (item.id, work)
                refreshProcessingCount()
                await work.value
                organizing = nil
            }
        }
    }

    /// How many items the AI still has to do: the one it's on, plus everything waiting.
    private func refreshProcessingCount() {
        let pending = AIStatus.pending.rawValue
        let waiting = (try? context?.fetchCount(FetchDescriptor<Item>(predicate: #Predicate { $0.aiStatusRaw == pending }))) ?? 0
        processingCount = waiting + (organizing == nil ? 0 : 1)
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
            let (fields, read) = try await organizedFields(for: text, kind: item.kind, existingTags: existing)
            let parsed = Organized(title: fields.title, summary: fields.summary, takeaways: fields.takeaways,
                                   tags: Self.relevantTags(fields.tags, existing: existing, content: read))
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
            stalledOnce.remove(item.id)
            setStage(item, .done, create: false)
        } catch where Task.isCancelled || error is CancellationError {
            // Cancelled from the activity list: keep what the item had and don't summarize it.
            item.aiStatus = .skipped
            activities.removeAll { $0.id == item.id }
        } catch let error as AppleModelError where error.isRuntimeFailure && !llm.isReady {
            // The model stopped responding: wait for it instead of failing the item.
            item.aiStatus = .pending
            setStage(item, .waitingForModel, create: false)
        } catch let error as AppleModelError where error.isTimeout {
            // The model went quiet on this item, and is paused for a minute (see LLMService). The first time, the
            // item goes back in line for when the model returns, so one hiccup doesn't leave a row of items to
            // retry by hand; if it hangs on the same item again, that one is marked failed and Retry runs it.
            if stalledOnce.insert(item.id).inserted {
                item.aiStatus = .pending
                setStage(item, .waitingForModel, create: false)
            } else {
                stalledOnce.remove(item.id)
                item.aiStatus = .failed
                setStage(item, .failed("Apple Intelligence didn't answer in time; try again"), create: false)
            }
        } catch {
            item.aiStatus = .failed
            setStage(item, .failed("Couldn't summarize; try Regenerate"), create: false)
        }
        try? context?.save()
    }

    /// Roughly how much text we feed the model per item.
    private var llmInputBudget: Int { llm.inputBudgetCharacters }

    /// Asks the model for an item's fields, and returns them with the text it actually read. The character
    /// budget is a guess at the model's small context window: code, scanned text and other scripts take more
    /// tokens per character, and a prompt the model turns away for its length is halved and sent again (twice)
    /// instead of failing the item.
    private func organizedFields(for text: String, kind: ItemKind, existingTags: String) async throws
        -> (fields: OrganizedFields, read: String) {
        var text = text
        var shrinks = 0
        while true {
            do {
                let fields = try await llm.organizeWithAppleModel(
                    Self.applePrompt(kind: kind, text: text, existingTags: existingTags),
                    instructions: "You are a precise librarian for a private personal knowledge library.")
                return (fields, text)
            } catch let error as AppleModelError where error.isTooLong && shrinks < 2 {
                shrinks += 1
                text = String(text.prefix(text.count / 2))
            }
        }
    }

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
