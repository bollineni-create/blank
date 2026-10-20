import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The floating "+" on the main page: notes, links, photos & videos, files and paste.
struct CaptureButton: View {
    @Environment(Librarian.self) private var librarian

    @State private var showingNote = false
    @State private var showingLink = false
    @State private var showingFiles = false
    @State private var showingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button { showingNote = true } label: { Label("New Note", systemImage: "square.and.pencil") }
            Button { showingLink = true } label: { Label("Save Link", systemImage: "link") }
            Button { showingPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
            Button { showingFiles = true } label: { Label("Import Files", systemImage: "folder") }
            Button { pasteFromClipboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            CaptureGlyph()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add to your brain")
        .sheet(isPresented: $showingNote) { NoteEditorSheet() }
        .sheet(isPresented: $showingLink) { AddLinkSheet() }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            // One pick is one batch, so Undo takes the whole pick out again.
            guard case .success(let urls) = result else { return }
            librarian.beginAddBatch()
            urls.forEach { librarian.addFile($0) }
            librarian.endAddBatch()
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoSelection, maxSelectionCount: 20,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoSelection) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                // Held open while the videos export one by one, so they stay one batch for Undo.
                librarian.beginAddBatch()
                for p in picked { await add(p) }
                librarian.endAddBatch()
                photoSelection = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loomNewNote)) { _ in showingNote = true }
        .onReceive(NotificationCenter.default.publisher(for: .loomNewLink)) { _ in showingLink = true }
        .onReceive(NotificationCenter.default.publisher(for: .loomPaste)) { _ in pasteFromClipboard() }
    }

    /// Adds a photo or video from the picker. The picker doesn't always say which it is (on the Mac,
    /// `supportedContentTypes` can come back empty), and a video loaded as plain data used to be saved as a
    /// picture: an image file nothing could open, with nothing in it to read. So anything that isn't clearly a
    /// photo is tried as a video first, and plain data is checked for a movie container before it's kept as one.
    private func add(_ p: PhotosPickerItem) async {
        let types = p.supportedContentTypes
        let saysMovie = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        let saysImage = types.contains { $0.conforms(to: .image) }
        if saysMovie || !saysImage {
            // Videos come in as a temporary file; the library keeps its own copy.
            let placeholder = librarian.startPlaceholder("Video from Photos", symbol: "video")
            let movie = try? await p.loadTransferable(type: PickedMovie.self)
            librarian.endPlaceholder(placeholder)
            if let movie {
                librarian.addFile(movie.url, removeSourceWhenDone: true)
                return
            }
        }
        guard let data = try? await p.loadTransferable(type: Data.self) else { return }
        if let ext = Self.movieExtension(of: data) {
            // A video the picker wouldn't hand over as a file: write it out as one, so it's read and played as a video.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let url = folder.appendingPathComponent("Video from Photos.\(ext)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url)
                librarian.addFile(url, removeSourceWhenDone: true)
            } catch {
                // Nothing to add.
            }
        } else if PlatformImage(data: data) != nil {
            librarian.addImage(data)
        }
    }

    /// "mov" or "mp4" when the bytes are a QuickTime or MPEG-4 file (both open with an `ftyp` box), else nil.
    private static func movieExtension(of data: Data) -> String? {
        let head = Array(data.prefix(12))
        guard head.count == 12, head[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        return head[8..<12].elementsEqual("qt  ".utf8) ? "mov" : "mp4"
    }

    private func pasteFromClipboard() {
        #if os(iOS)
        let board = UIPasteboard.general
        if let url = board.url { librarian.addLink(url) }
        else if let image = board.image, let data = image.jpegData(compressionQuality: 0.9) { librarian.addImage(data) }
        else if let text = board.string { librarian.addPasted(text) }
        #else
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first {
            if url.isFileURL { librarian.addFile(url) } else { librarian.addLink(url) }
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff),
                  let jpeg = ContentExtractor.thumbnail(from: data, maxPixel: 4000) {
            librarian.addImage(jpeg)
        } else if let text = board.string(forType: .string) {
            librarian.addPasted(text)
        }
        #endif
    }
}

/// The "+" itself: Loom's one primary action. Accent-tinted Liquid Glass in the glass languages where available,
/// otherwise the signature gradient with its accent glow; the print and clay languages press a flat accent
/// disc with their own outline and depth.
private struct CaptureGlyph: View {
    var body: some View {
        let style = Theme.style
        let plus = Image(systemName: "plus")
            .font(.title2)
            .fontWeight(style.symbolWeight == .light ? .regular : .semibold)
            .foregroundStyle(Theme.onAccent)
            .frame(width: 56, height: 56)
        if style.glass {
            glass(plus)
        } else {
            plus
                .background(Theme.signature, in: Circle())
                .overlay {
                    if style.inkOutline { Circle().strokeBorder(Theme.label, lineWidth: style.outline) }
                }
                .tileShadow()
        }
    }

    @ViewBuilder
    private func glass(_ plus: some View) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            plus
                .background(Theme.signature.opacity(0.55), in: Circle())
                .glassEffect(.regular.tint(Theme.accent).interactive(), in: Circle())
        } else {
            plus
                .background(Theme.signature, in: Circle())
                .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 8)
        }
    }
}

/// A video picked from the photo library, copied out of the picker's temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // Unique folder, original file name, so the saved item keeps a readable title.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

// MARK: Cross-platform image helpers

#if os(macOS)
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif

/// Handles anything dropped on the main page: Finder files, web links, and photos,
/// videos or text dragged out of other apps.
enum DropImporter {
    /// One drop is one batch for Undo: the files come in one callback at a time, so the batch is held open
    /// for each provider until its callback has added (or given up on) what it carried.
    @MainActor
    static func importProviders(_ providers: [NSItemProvider], into librarian: Librarian) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                librarian.beginAddBatch()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    // Copy dropped files right away: the system may revoke access after this callback.
                    let local = url.flatMap { $0.isFileURL ? copyToTemporary($0) : nil }
                    Task { @MainActor in
                        defer { librarian.endAddBatch() }
                        if let local {
                            librarian.addFile(local, removeSourceWhenDone: true)
                        } else if let url, !url.isFileURL {
                            librarian.addLink(url)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                librarian.beginAddBatch()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    let local = url.flatMap(copyToTemporary)
                    Task { @MainActor in
                        defer { librarian.endAddBatch() }
                        if let local { librarian.addFile(local, removeSourceWhenDone: true) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                librarian.beginAddBatch()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    let jpeg = data.flatMap { ContentExtractor.thumbnail(from: $0, maxPixel: 4000) }
                    Task { @MainActor in
                        defer { librarian.endAddBatch() }
                        if let jpeg { librarian.addImage(jpeg) }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                librarian.beginAddBatch()
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    Task { @MainActor in
                        defer { librarian.endAddBatch() }
                        if let text { librarian.addPasted(text) }
                    }
                }
            }
        }
    }

    private static func copyToTemporary(_ url: URL) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }
}
