import SwiftUI
import SwiftData

/// What the side panel is showing.
enum Panel: Equatable {
    case item(UUID)
    case ask
}

/// The single main page: the mind map fills the window and everything else floats on top of it.
struct RootView: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]

    @State private var panel: Panel?
    @State private var selectedItem: UUID?
    @State private var focusRequest: UUID?
    @State private var search = ""
    @State private var question = ""
    @State private var pendingQuestion: String?
    @State private var showingSettings = false
    @State private var showingOnboarding = false
    @State private var isDropTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            KnowledgeWebView(selection: $selectedItem, highlight: search, focusRequest: $focusRequest)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            UploadsTray { id in
                selectedItem = id
                focusRequest = id
            }
            .padding(.top, 70)
            .padding(.trailing, 16)
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    Label("Drop to add to your brain", systemImage: "tray.and.arrow.down.fill")
                        .font(.title3.bold())
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(10)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: librarian.lastAddedID) { _, id in
            if let id { focusRequest = id }
        }
        .onDrop(of: [.fileURL, .url, .movie, .image, .plainText], isTargeted: $isDropTargeted) { providers in
            DropImporter.importProviders(providers, into: librarian)
            return !providers.isEmpty
        }
        .inspector(isPresented: panelShown) {
            NavigationStack {
                panelContent
                    .navigationDestination(for: UUID.self) { id in
                        if let item = items.first(where: { $0.id == id }) { ItemDetailView(item: item) }
                    }
            }
            .inspectorColumnWidth(min: 340, ideal: 420, max: 600)
        }
        .onChange(of: selectedItem) { _, id in
            if let id { panel = .item(id) }
        }
        .onChange(of: panel) { _, newPanel in
            if case .item = newPanel {} else { selectedItem = nil }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 620)
            #endif
        }
        .sheet(isPresented: $showingOnboarding) { OnboardingView() }
        .onAppear { if !llm.hasChosenModel { showingOnboarding = true } }
        #if os(macOS)
        .onPasteCommand(of: [.url, .plainText, .image, .fileURL]) { _ in
            NotificationCenter.default.post(name: .loomPaste, object: nil)
        }
        #endif
    }

    private var panelShown: Binding<Bool> {
        Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .item(let id):
            if let item = items.first(where: { $0.id == id }) {
                ItemDetailView(item: item, onDelete: { panel = nil })
                    .id(id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { panel = nil } label: { Image(systemName: "xmark") }
                        }
                    }
            } else {
                ContentUnavailableView("Item not found", systemImage: "questionmark")
            }
        case .ask:
            AskView(pendingQuestion: $pendingQuestion)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { panel = nil } label: { Image(systemName: "xmark") }
                    }
                }
        case nil:
            EmptyView()
        }
    }

    // MARK: Top: search, model status, settings

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search your brain", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = searchResults.first { open(first) } }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)

                if searchFocused || !search.isEmpty, !searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(searchResults) { item in
                            Button { open(item) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.kind.symbol).foregroundStyle(Color.accentColor).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                                        if !item.preview.isEmpty {
                                            Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: 440)

            Spacer(minLength: 0)

            ModelStatusChip()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private var searchResults: [Item] {
        guard search.trimmingCharacters(in: .whitespaces).count > 1 else { return [] }
        return Array(SearchIndex.rank(items, query: search, limit: 6).map(\.item))
    }

    private func open(_ item: Item) {
        searchFocused = false
        selectedItem = item.id
        focusRequest = item.id
    }

    // MARK: Bottom: add + ask

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            CaptureButton()
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                TextField(llm.isReady ? "Ask your brain anything…" : "Ask your brain (load a model in Settings)", text: $question)
                    .textFieldStyle(.plain)
                    .onSubmit(ask)
                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            .frame(maxWidth: 560)
            Spacer(minLength: 60) // room for the zoom controls
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { panel = .ask; return }
        question = ""
        pendingQuestion = q
        panel = .ask
    }
}

/// Compact status of the on-device model, shown at the top right.
struct ModelStatusChip: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian

    var body: some View {
        HStack(spacing: 7) {
            switch llm.state {
            case .ready:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(librarian.processingCount > 0 ? "Organizing \(librarian.processingCount)…" : (llm.loadedModel?.name ?? "Ready"))
            case .downloading(let p):
                ProgressView(value: p).frame(width: 50)
                Text("\(Int(p * 100))%").monospacedDigit()
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading model…")
            case .notLoaded:
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text("No model")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Model error")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Live list of what's being added: copying, reading, transcribing, summarizing.
struct UploadsTray: View {
    @Environment(Librarian.self) private var librarian
    @Environment(LLMService.self) private var llm
    var onOpen: (UUID) -> Void
    @State private var collapsed = false

    var body: some View {
        let activities = librarian.activities
        let working = activities.filter { !$0.stage.isFinished }.count
        if !activities.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if working > 0 {
                        ProgressView().controlSize(.small)
                        Text("Adding \(working) \(working == 1 ? "item" : "items")…").font(.subheadline.weight(.semibold))
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Uploads").font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    if working == 0 {
                        Button { withAnimation { librarian.clearFinishedActivities() } } label: {
                            Image(systemName: "xmark").font(.caption.weight(.bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)

                if !collapsed {
                    Divider()
                    ForEach(activities.prefix(6)) { activity in
                        Button { onOpen(activity.id) } label: { row(activity) }
                            .buttonStyle(.plain)
                    }
                    if activities.count > 6 {
                        Text("+ \(activities.count - 6) more").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    if librarian.processingCount > working {
                        Text("Updating \(librarian.processingCount - working) older items in the background")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.bottom, 10)
                    }
                }
            }
            .frame(width: 310)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.snappy, value: activities)
        }
    }

    private func row(_ activity: Librarian.Activity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: activity.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(activity.stage.label)
                    .font(.caption)
                    .foregroundStyle(stageColor(activity.stage))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch activity.stage {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .waitingForModel: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            default: ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func stageColor(_ stage: Librarian.Stage) -> Color {
        switch stage {
        case .failed: .orange
        case .done: .green
        default: .secondary
        }
    }
}
