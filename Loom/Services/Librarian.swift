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
        Task {
            item.extractedText = await ContentExtractor.recognizeText(in: data)
            item.aiStatus = .pending
            finishAdding(item)
        }
    }

    func addFile(_ url: URL, space: Space? = nil) {
        guard let name = try? AttachmentStore.importFile(at: url) else { return }
        let stored = AttachmentStore.url(for: name)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: ItemKind = type.conforms(to: .pdf) ? .pdf
            : type.conforms(to: .image) ? .image
            : type.conforms(to: .movie) ? .video
            : .file
        let title = url.deletingPathExtension().lastPathComponent
        let thumb: Data? = kind == .pdf ? ContentExtractor.pdfThumbnail(stored)
            : (kind == .image ? (try? Data(contentsOf: stored)).flatMap { ContentExtractor.thumbnail(from: $0) } : nil)
        let item = Item(kind: kind, title: kind == .image ? "" : title, attachmentName: name, thumbnail: thumb, space: space)
        item.aiStatus = .processing
        insert(item, organize: false)
        Task {
            if kind == .video {
                let info = await ContentExtractor.videoInfo(stored)
                item.thumbnail = info.thumbnail
                let length = ContentExtractor.formatDuration(info.duration)
                item.extractedText = "Video \(title)" + (length.isEmpty ? "" : ", \(length) long")
            } else {
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

    // MARK: AI queue

    private func insert(_ item: Item, organize: Bool = true) {
        context?.insert(item)
        try? context?.save()
        if organize { finishAdding(item) }
    }

    private func finishAdding(_ item: Item) {
        item.embedding = SearchIndex.pack(SearchIndex.embed(item.fullText))
        if !autoOrganize { item.aiStatus = .skipped }
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

    private struct Organized: Decodable {
        var title: String?
        var summary: String?
        var tags: [String]?
    }

    private func organize(_ item: Item) async {
        item.aiStatus = .processing
        let text = String(item.fullText.prefix(llmInputBudget))
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 3 else {
            item.aiStatus = .skipped
            return
        }
        let existing = topTags(limit: 30).joined(separator: ", ")
        let prompt = """
        Organize this saved \(item.kind.rawValue) for a personal knowledge library.

        CONTENT:
        \"\"\"
        \(text)
        \"\"\"

        Respond with only a JSON object, no other text:
        {"title": "short descriptive title, at most 8 words", "summary": "1-3 sentence summary of what this is and why it matters", "tags": ["2 to 5 short lowercase topic tags"]}
        \(existing.isEmpty ? "" : "Prefer reusing these existing tags when they fit: \(existing)")
        """
        do {
            let reply = try await llm.generate(
                system: "You are a precise librarian. You only ever reply with valid JSON.",
                prompt: prompt, maxTokens: 300, temperature: 0.2)
            guard let parsed = Self.parseJSON(reply) else {
                item.aiStatus = .failed
                try? context?.save()
                return
            }
            // Keep titles the user (or the web page) gave, except bare hostnames and empty ones.
            if let title = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
               item.title.isEmpty || item.title == item.url?.host() {
                item.title = title
            }
            if let summary = parsed.summary { item.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let tags = parsed.tags {
                let cleaned = tags.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines)) }
                    .filter { !$0.isEmpty && $0.count < 30 }
                item.tags = Array(NSOrderedSet(array: item.tags + cleaned)).compactMap { $0 as? String }.prefix(8).map { $0 }
            }
            item.embedding = SearchIndex.pack(SearchIndex.embed(item.fullText + "\n" + item.summary + "\n" + item.tags.joined(separator: " ")))
            item.aiStatus = .done
        } catch {
            item.aiStatus = .failed
        }
        try? context?.save()
    }

    /// Roughly how much text we feed the model per item; smaller on iPhone.
    private var llmInputBudget: Int {
        #if os(macOS)
        6000
        #else
        3000
        #endif
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
