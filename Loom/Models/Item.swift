import Foundation
import SwiftData

/// What kind of thing was saved.
enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case note, link, image, pdf, file

    var id: String { rawValue }

    var label: String {
        switch self {
        case .note: "Notes"
        case .link: "Links"
        case .image: "Images"
        case .pdf: "PDFs"
        case .file: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .note: "note.text"
        case .link: "link"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .file: "doc"
        }
    }
}

/// Where the on-device AI is with an item.
enum AIStatus: String, Codable {
    case pending, processing, done, failed, skipped
}

/// One thing in your second brain: a note, a link, an image, a PDF or any file.
@Model
final class Item {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var title: String
    /// What the user typed (the note itself, or their comment on a link/file).
    var body: String
    var urlString: String?
    /// Text pulled out of the content: page text, OCR, PDF text.
    var extractedText: String
    var summary: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var isFavorite: Bool
    /// File name inside the app's attachments folder.
    var attachmentName: String?
    @Attribute(.externalStorage) var thumbnail: Data?
    var aiStatusRaw: String
    /// Packed `[Float]` sentence embedding used for semantic search.
    @Attribute(.externalStorage) var embedding: Data?

    var space: Space?

    init(
        kind: ItemKind,
        title: String = "",
        body: String = "",
        urlString: String? = nil,
        extractedText: String = "",
        attachmentName: String? = nil,
        thumbnail: Data? = nil,
        space: Space? = nil
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.title = title
        self.body = body
        self.urlString = urlString
        self.extractedText = extractedText
        self.summary = ""
        self.tags = []
        self.createdAt = .now
        self.updatedAt = .now
        self.isFavorite = false
        self.attachmentName = attachmentName
        self.thumbnail = thumbnail
        self.aiStatusRaw = AIStatus.pending.rawValue
        self.space = space
    }

    var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    var aiStatus: AIStatus {
        get { AIStatus(rawValue: aiStatusRaw) ?? .pending }
        set { aiStatusRaw = newValue.rawValue }
    }

    var url: URL? { urlString.flatMap(URL.init(string:)) }

    var attachmentURL: URL? { attachmentName.map(AttachmentStore.url(for:)) }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.isEmpty { return String(firstLine.prefix(80)) }
        if let host = url?.host() { return host }
        return "Untitled \(kind.label.dropLast().lowercased())"
    }

    /// Everything we know about the item as plain text, for AI and search.
    var fullText: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if !body.isEmpty { parts.append(body) }
        if let urlString { parts.append(urlString) }
        if !extractedText.isEmpty { parts.append(extractedText) }
        return parts.joined(separator: "\n\n")
    }

    /// Short preview shown on cards.
    var preview: String {
        let source = !summary.isEmpty ? summary : (!body.isEmpty ? body : extractedText)
        return String(source.prefix(240))
    }

    func touch() { updatedAt = .now }
}

/// A user-made collection, like a folder.
@Model
final class Space {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \Item.space) var items: [Item]

    init(name: String, emoji: String = "📁") {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.createdAt = .now
        self.items = []
    }
}

/// A saved "Ask" conversation.
@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation) var messages: [ChatMessage]

    init(title: String = "New chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.messages = []
    }

    var sortedMessages: [ChatMessage] { messages.sorted { $0.createdAt < $1.createdAt } }
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var isUser: Bool
    var text: String
    var createdAt: Date
    /// IDs of the items the answer was based on.
    var sourceIDs: [UUID]
    var conversation: Conversation?

    init(isUser: Bool, text: String, sourceIDs: [UUID] = []) {
        self.id = UUID()
        self.isUser = isUser
        self.text = text
        self.createdAt = .now
        self.sourceIDs = sourceIDs
    }
}
