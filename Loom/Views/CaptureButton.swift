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
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle().fill(LinearGradient(colors: [Color.accentColor, Color(red: 0.55, green: 0.38, blue: 0.95)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .shadow(color: Color.accentColor.opacity(0.45), radius: 12, y: 5)
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
                        if let movie = try? await p.loadTransferable(type: PickedMovie.self) {
                            librarian.addFile(movie.url)
                            try? FileManager.default.removeItem(at: movie.url)
                        }
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

/// A video picked from the photo library, copied out of the picker's temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(received.file.lastPathComponent)")
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
