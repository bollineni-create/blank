import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let filter: SidebarSelection

    @Environment(Librarian.self) private var librarian
    @Query(sort: \Item.createdAt, order: .reverse) private var allItems: [Item]
    @Query private var spaces: [Space]

    @State private var searchText = ""
    @State private var searchResults: [Item]?
    @State private var showingNote = false
    @State private var showingLink = false
    @State private var showingFileImporter = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var isDropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 14)]

    var body: some View {
        ScrollView {
            if visibleItems.isEmpty {
                emptyState.padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(visibleItems) { item in
                        NavigationLink(value: item.id) {
                            ItemCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .navigationDestination(for: UUID.self) { id in
            if let item = allItems.first(where: { $0.id == id }) { ItemDetailView(item: item) }
        }
        .searchable(text: $searchText, prompt: "Search by meaning or keyword")
        .task(id: searchText) {
            // Small debounce so we don't re-rank on every keystroke.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searchResults = searchText.isEmpty ? nil : SearchIndex.rank(filteredItems, query: searchText).map(\.item)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { addMenu }
        }
        .sheet(isPresented: $showingNote) { NoteEditorSheet(space: currentSpace) }
        .sheet(isPresented: $showingLink) { AddLinkSheet(space: currentSpace) }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach { librarian.addFile($0, space: currentSpace) } }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoSelection, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
        .onChange(of: photoSelection) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                for p in picked {
                    if p.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        // Videos come in as a temporary file; the library keeps its own copy.
                        if let movie = try? await p.loadTransferable(type: PickedMovie.self) {
                            librarian.addFile(movie.url, space: currentSpace)
                            try? FileManager.default.removeItem(at: movie.url)
                        }
                    } else if let data = try? await p.loadTransferable(type: Data.self) {
                        librarian.addImage(data, space: currentSpace)
                    }
                }
                photoSelection = []
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                if url.isFileURL { librarian.addFile(url, space: currentSpace) } else { librarian.addLink(url, space: currentSpace) }
            }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loomNewNote)) { _ in showingNote = true }
        .onReceive(NotificationCenter.default.publisher(for: .loomNewLink)) { _ in showingLink = true }
        #if os(macOS)
        .onPasteCommand(of: [.url, .plainText, .image, .fileURL]) { providers in handlePaste(providers) }
        #endif
    }

    private var addMenu: some View {
        Menu {
            Button { showingNote = true } label: { Label("New Note", systemImage: "square.and.pencil") }
            Button { showingLink = true } label: { Label("Save Link", systemImage: "link") }
            Button { showingPhotos = true } label: { Label("Add Photos & Videos", systemImage: "photo.on.rectangle") }
            Button { showingFileImporter = true } label: { Label("Import Files", systemImage: "folder") }
            Button { pasteFromClipboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    @ViewBuilder
    private func contextMenu(for item: Item) -> some View {
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites") { item.isFavorite.toggle() }
        Menu("Move to Space") {
            Button("None") { item.space = nil }
            ForEach(spaces) { space in Button("\(space.emoji) \(space.name)") { item.space = space } }
        }
        Button("Organize with AI") { librarian.reorganize(item) }
        Divider()
        Button("Delete", role: .destructive) { librarian.delete(item) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "Nothing here yet" : "No matches").font(.title3.bold())
            Text(searchText.isEmpty
                 ? "Save notes, links, photos and files. Your on-device AI will title, summarize and tag them."
                 : "Try different words — search understands meaning, not just exact text.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
            if searchText.isEmpty { addMenu.menuStyle(.borderlessButton).fixedSize().padding(.top, 4) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Filtering

    private var currentSpace: Space? {
        if case .space(let id) = filter { return spaces.first { $0.id == id } }
        return nil
    }

    private var filteredItems: [Item] {
        switch filter {
        case .favorites: allItems.filter(\.isFavorite)
        case .kind(let kind): allItems.filter { $0.kind == kind }
        case .space(let id): allItems.filter { $0.space?.id == id }
        case .tag(let tag): allItems.filter { $0.tags.contains(tag) }
        default: allItems
        }
    }

    private var visibleItems: [Item] { searchResults ?? filteredItems }

    private var title: String {
        switch filter {
        case .favorites: "Favorites"
        case .kind(let kind): kind.label
        case .space: currentSpace.map { "\($0.emoji) \($0.name)" } ?? "Space"
        case .tag(let tag): "#\(tag)"
        default: "Everything"
        }
    }

    // MARK: Paste

    private func pasteFromClipboard() {
        #if os(iOS)
        let board = UIPasteboard.general
        if let url = board.url { librarian.addLink(url, space: currentSpace) }
        else if let image = board.image, let data = image.jpegData(compressionQuality: 0.9) { librarian.addImage(data, space: currentSpace) }
        else if let text = board.string { librarian.addPasted(text, space: currentSpace) }
        #else
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first {
            if url.isFileURL { librarian.addFile(url, space: currentSpace) } else { librarian.addLink(url, space: currentSpace) }
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff),
                  let jpeg = ContentExtractor.thumbnail(from: data, maxPixel: 4000) {
            librarian.addImage(jpeg, space: currentSpace)
        } else if let text = board.string(forType: .string) {
            librarian.addPasted(text, space: currentSpace)
        }
        #endif
    }

    #if os(macOS)
    private func handlePaste(_ providers: [NSItemProvider]) {
        pasteFromClipboard()
    }
    #endif
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

/// A card in the library grid.
struct ItemCard: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = item.thumbnail, let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if item.kind == .video {
                            Image(systemName: "play.circle.fill").font(.system(size: 40))
                                .foregroundStyle(.white).shadow(radius: 4)
                        }
                    }
            }
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbol).foregroundStyle(Color.accentColor)
                Text(item.url?.host() ?? item.kind.label.dropLast().description)
                    .lineLimit(1)
                Spacer()
                if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                if item.aiStatus == .processing { ProgressView().controlSize(.mini) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2)
            if !item.preview.isEmpty {
                Text(item.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(item.thumbnail == nil ? 5 : 2)
            }
            if !item.tags.isEmpty {
                Text(item.tags.prefix(4).map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            Text(item.createdAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
