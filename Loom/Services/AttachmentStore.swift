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

    /// Files land here while they copy in and move into place once whole, so a copy cut short by quitting
    /// the app never passes for a finished attachment. Emptied at launch.
    static let stagingDirectory: URL = {
        let dir = directory.appendingPathComponent("Importing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// The name a file had before it was copied in, from its stored name (`UUID-name`).
    /// Nil for raw saves (a pasted photo), which never had one.
    static func originalName(of stored: String) -> String? {
        guard let dash = stored.index(stored.startIndex, offsetBy: 36, limitedBy: stored.endIndex),
              dash < stored.endIndex, stored[dash] == "-",
              UUID(uuidString: String(stored[..<dash])) != nil else { return nil }
        let name = String(stored[stored.index(after: dash)...])
        return name.isEmpty ? nil : name
    }

    /// Whether a stored file is on disk and has something in it.
    static func hasFile(named name: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url(for: name).path))?[.size] as? Int
        return (size ?? 0) > 0
    }

    /// Copies a file in and returns its stored name. The copy is staged first, then moved into place in one step.
    static func importFile(at source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let name = "\(UUID().uuidString)-\(source.lastPathComponent)"
        let staged = stagingDirectory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.moveItem(at: staged, to: url(for: name))
        return name
    }

    /// Throws away copies that never finished (the app quit mid-copy). Call once at launch.
    static func clearStaging() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: stagingDirectory.path)) ?? [] {
            try? fm.removeItem(at: stagingDirectory.appendingPathComponent(name))
        }
    }

    /// Removes a temporary source (a drop, a Photos export, a Shortcuts file) and the folder made just for it.
    static func removeTemporary(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        let temp = fm.temporaryDirectory.resolvingSymlinksInPath().path
        guard folder.resolvingSymlinksInPath().path.hasPrefix(temp + "/"),
              (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true else { return }
        try? fm.removeItem(at: folder)
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

    /// Removes every stored file but the ones named in `keep` (files still being added, which their own add
    /// takes care of). The staging folder is left alone: copies in progress land there.
    static func deleteAll(except keep: Set<String>) {
        let fm = FileManager.default
        let staging = stagingDirectory.lastPathComponent
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name != staging && !keep.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
