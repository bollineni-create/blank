import Foundation

/// Keeps copies of imported files in the app's own Application Support folder,
/// so they stay available after the original is moved or deleted.
enum AttachmentStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Copies a file in and returns its stored name.
    static func importFile(at source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let name = "\(UUID().uuidString)-\(source.lastPathComponent)"
        try FileManager.default.copyItem(at: source, to: url(for: name))
        return name
    }

    /// Writes raw data (e.g. a photo) and returns its stored name.
    static func save(_ data: Data, fileExtension: String) throws -> String {
        let name = "\(UUID().uuidString).\(fileExtension)"
        try data.write(to: url(for: name), options: .atomic)
        return name
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(for: name))
    }
}
