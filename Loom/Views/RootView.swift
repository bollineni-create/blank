import SwiftUI
import SwiftData

/// What the sidebar is showing.
enum SidebarSelection: Hashable {
    case map
    case all
    case favorites
    case kind(ItemKind)
    case space(UUID)
    case tag(String)
    case ask
    case settings
}

struct RootView: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian
    @Query(sort: \Space.createdAt) private var spaces: [Space]
    @Query private var items: [Item]

    @State private var selection: SidebarSelection? = .map
    @State private var showingOnboarding = false
    @State private var newSpaceName = ""
    @State private var showingNewSpace = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Mind Map", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarSelection.map)
                    Label("Everything", systemImage: "square.grid.2x2").tag(SidebarSelection.all)
                    Label("Ask", systemImage: "sparkles").tag(SidebarSelection.ask)
                    Label("Favorites", systemImage: "star").tag(SidebarSelection.favorites)
                }
                Section("Types") {
                    ForEach(ItemKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(SidebarSelection.kind(kind))
                    }
                }
                Section {
                    ForEach(spaces) { space in
                        Label { Text(space.name) } icon: { Text(space.emoji) }
                            .tag(SidebarSelection.space(space.id))
                            .contextMenu {
                                Button("Delete Space", role: .destructive) { librarian.context?.delete(space) }
                            }
                    }
                    Button { showingNewSpace = true } label: { Label("New Space", systemImage: "plus") }
                        .buttonStyle(.borderless)
                } header: { Text("Spaces") }
                if !topTags.isEmpty {
                    Section("Tags") {
                        ForEach(topTags, id: \.self) { tag in
                            Label(tag, systemImage: "number").tag(SidebarSelection.tag(tag))
                        }
                    }
                }
                #if os(iOS)
                Section {
                    Label("Settings", systemImage: "gearshape").tag(SidebarSelection.settings)
                }
                #endif
            }
            .navigationTitle("Loom")
            .safeAreaInset(edge: .bottom) { ModelStatusBar().padding(8) }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            #endif
        } detail: {
            NavigationStack {
                switch selection ?? .map {
                case .map:
                    MindMapView()
                case .ask:
                    AskView()
                case .settings:
                    SettingsView()
                default:
                    LibraryView(filter: selection ?? .all)
                }
            }
        }
        .alert("New Space", isPresented: $showingNewSpace) {
            TextField("Name", text: $newSpaceName)
            Button("Create") {
                let name = newSpaceName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { librarian.context?.insert(Space(name: name)) }
                newSpaceName = ""
            }
            Button("Cancel", role: .cancel) { newSpaceName = "" }
        }
        .sheet(isPresented: $showingOnboarding) { OnboardingView() }
        .onAppear { if !llm.hasChosenModel { showingOnboarding = true } }
    }

    private var topTags: [String] {
        var counts: [String: Int] = [:]
        for item in items { for tag in item.tags { counts[tag, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(15).map(\.key)
    }
}

/// Small footer showing what the on-device AI is doing.
struct ModelStatusBar: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian

    var body: some View {
        HStack(spacing: 8) {
            switch llm.state {
            case .ready:
                Image(systemName: "cpu").foregroundStyle(.green)
                Text(librarian.processingCount > 0 ? "Organizing \(librarian.processingCount)…" : (llm.loadedModel?.name ?? "Ready"))
            case .downloading(let p):
                ProgressView(value: p).frame(width: 60)
                Text("Downloading \(Int(p * 100))%")
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading model…")
            case .notLoaded:
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text("No model loaded")
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Model failed to load")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
