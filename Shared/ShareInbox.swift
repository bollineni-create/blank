import Foundation

/// A drop box shared by Loom and its Share extension (through an App Group).
///
/// The extension never opens the library database: it copies what you shared into this
/// folder and writes a small JSON note per item. Loom imports the folder when it opens,
/// when it comes to the front, and right away when the extension pings it.
enum ShareInbox {
    static let appGroup = "group.com.personal.loom"
    static let darwinNotification = "com.personal.loom.share-inbox" as CFString

    struct Entry: Codable, Identifiable {
        enum Kind: String, Codable { case link, text, file }

        var id = UUID()
        var kind: Kind
        var url: String?
        var text: String?
        /// File name inside `filesFolder` (for `.file`).
        var fileName: String?
        /// What the user typed in the share sheet.
        var comment: String = ""
        var created = Date()
    }

    static var folder: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Files", isDirectory: true),
                                                 withIntermediateDirectories: true)
        return dir
    }

    static var filesFolder: URL? { folder?.appendingPathComponent("Files", isDirectory: true) }

    static func fileURL(_ name: String) -> URL? { filesFolder?.appendingPathComponent(name) }

    /// Copies a shared file into the inbox. Returns its stored name.
    static func stageFile(at source: URL) throws -> String {
        guard let files = filesFolder else { throw CocoaError(.fileNoSuchFile) }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        // A unique subfolder keeps the original file name, which becomes the item's title.
        let id = UUID().uuidString
        let dir = files.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(source.lastPathComponent))
        return "\(id)/\(source.lastPathComponent)"
    }

    static func discardStagedFile(_ name: String) {
        guard let url = fileURL(name) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func add(_ entry: Entry) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(entry)
        try data.write(to: folder.appendingPathComponent("\(entry.id.uuidString).json"), options: .atomic)
    }

    /// Everything waiting to be imported, oldest first, with the note file to delete afterwards.
    static func pending() -> [(entry: Entry, note: URL)] {
        guard let folder,
              let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return names.filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }.map { ($0, url) }
            }
            .sorted { $0.entry.created < $1.entry.created }
    }

    static func finish(_ note: URL) {
        try? FileManager.default.removeItem(at: note)
    }

    /// Tells a running Loom that new things arrived.
    static func notifyApp() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(darwinNotification), nil, nil, true)
    }

    private static var onChange: (@MainActor () -> Void)?

    /// Calls `handler` whenever the Share extension saves something (while Loom is running).
    static func observe(_ handler: @escaping @MainActor () -> Void) {
        onChange = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in ShareInbox.onChange?() }
        }, darwinNotification, nil, .deliverImmediately)
    }
}
