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
            if case .success(let urls) = result { urls.forEach { librarian.addFile($0) } }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoSelection, maxSelectionCount: 20,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoSelection) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for p in picked {
                    if p.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        // Videos come in as a temporary file; the library keeps its own copy.
                        let placeholder = librarian.startPlaceholder("Video from Photos", symbol: "video")
                        let movie = try? await p.loadTransferable(type: PickedMovie.self)
                        librarian.endPlaceholder(placeholder)
                        if let movie { librarian.addFile(movie.url, removeSourceWhenDone: true) }
                    } else if let data = try? await p.loadTransferable(type: Data.self) {
                        librarian.addImage(data)
                    }
                }
                photoSelection = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loomNewNote)) { _ in showingNote = true }
        .onReceive(NotificationCenter.default.publisher(for: .loomNewLink)) { _ in showingLink = true }
        .onReceive(NotificationCenter.default.publisher(for: .loomPaste)) { _ in pasteFromClipboard() }
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
    @MainActor
    static func importProviders(_ providers: [NSItemProvider], into librarian: Librarian) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // Copy dropped files right away: the system may revoke access after this callback.
                    let local = url.isFileURL ? copyToTemporary(url) : nil
                    Task { @MainActor in
                        if let local {
                            librarian.addFile(local, removeSourceWhenDone: true)
                        } else if !url.isFileURL {
                            librarian.addLink(url)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url, let local = copyToTemporary(url) else { return }
                    Task { @MainActor in librarian.addFile(local, removeSourceWhenDone: true) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let jpeg = ContentExtractor.thumbnail(from: data, maxPixel: 4000) else { return }
                    Task { @MainActor in librarian.addImage(jpeg) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in librarian.addPasted(text) }
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
