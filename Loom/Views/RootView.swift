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
    @Environment(LoomRouter.self) private var router
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
            .padding(Theme.Space.s20)
        }
        .background(Theme.background)
        .tint(Theme.accent)
        #if os(macOS)
        .overlay(alignment: .topTrailing) {
            UploadsTray { id in
                selectedItem = id
                focusRequest = id
            }
            .padding(.top, 74)
            .padding(.trailing, Theme.Space.s20)
        }
        #endif
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet)
                        .fill(Theme.accentTint)
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    Label("Drop to add to your brain", systemImage: "tray.and.arrow.down")
                        .font(.headline)
                        .foregroundStyle(Theme.label)
                        .padding(.horizontal, Theme.Space.s20).padding(.vertical, Theme.Space.s12)
                        .surfaceTile(Capsule())
                }
                .padding(Theme.Space.s12)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: librarian.lastAddedID) { _, id in
            if let id { focusRequest = id }
        }
        .onChange(of: router.openItem) { _, _ in handleRouter() }
        .onChange(of: router.newNote) { _, _ in handleRouter() }
        .onReceive(NotificationCenter.default.publisher(for: .loomOpenSettings)) { _ in showingSettings = true }
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
            .background(Theme.background)
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
        .onAppear {
            if !llm.hasChosenModel { showingOnboarding = true }
            handleRouter()
        }
        #if os(macOS)
        .onPasteCommand(of: [.url, .plainText, .image, .fileURL]) { _ in
            NotificationCenter.default.post(name: .loomPaste, object: nil)
        }
        #endif
    }

    /// Acts on requests from App Intents (Open Item, New Note).
    private func handleRouter() {
        if let id = router.openItem {
            router.openItem = nil
            selectedItem = id
            focusRequest = id
        }
        if router.newNote {
            router.newNote = false
            // Give the capture button a moment to appear on a cold launch.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                NotificationCenter.default.post(name: .loomNewNote, object: nil)
            }
        }
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
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(spacing: Theme.Space.s8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.labelSecondary)
                    TextField("Search your brain", text: $search)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.label)
                        .focused($searchFocused)
                        .onSubmit { if let first = searchResults.first { open(first) } }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.labelSecondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s12)
                .floatingChrome(Capsule())
                // The soft violet → coral light behind search. A light, not a fill: text never sits on it.
                .background(
                    Theme.glow(radius: 200)
                        .frame(width: 400, height: 400)
                        .allowsHitTesting(false)
                )

                if searchFocused || !search.isEmpty, !searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(searchResults) { item in
                            Button { open(item) } label: {
                                HStack(spacing: Theme.Space.s12) {
                                    Image(systemName: item.kind.symbol).foregroundStyle(Theme.labelSecondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: Theme.Space.s2) {
                                        Text(item.displayTitle).font(.callout.weight(.medium)).foregroundStyle(Theme.label).lineLimit(1)
                                        if !item.preview.isEmpty {
                                            Text(item.preview).font(.caption).foregroundStyle(Theme.labelSecondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, Theme.Space.s6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.hairline))
                    .floatShadow()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: 440)

            Spacer(minLength: 0)

            ChromeGroup {
                HStack(spacing: Theme.Space.s8) {
                    #if os(iOS)
                    // On iPhone and iPad the status is one coloured dot; its panel lists each file's progress.
                    ActivityDot { id in
                        selectedItem = id
                        focusRequest = id
                    }
                    #else
                    ModelStatusChip()
                    #endif
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.label)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .floatingChrome(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
            }
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
        ChromeGroup(spacing: Theme.Space.s16) {
            HStack(alignment: .bottom, spacing: Theme.Space.s12) {
                CaptureButton()
                HStack(spacing: Theme.Space.s8) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accentInk)
                    TextField(llm.isReady ? "Ask your brain anything…" : "Ask your brain (choose a model in Settings)", text: $question)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.label)
                        .onSubmit(ask)
                    Button(action: ask) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, Theme.Space.s16).padding(.vertical, Theme.Space.s12)
                .floatingChrome(Capsule())
                .frame(maxWidth: 560)
                Spacer(minLength: 60) // room for the zoom controls
            }
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
/// Names the active model (Apple Intelligence or a downloaded one) and calmly shows availability states.
struct ModelStatusChip: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            content
        }
        .lineLimit(1)
        .fixedSize()
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.label)
        .padding(.horizontal, Theme.Space.s12)
        .frame(minWidth: 44, minHeight: 44, maxHeight: 44)
        .floatingChrome(Capsule())
        .help(llm.isReady ? (llm.activeModelName ?? "") : AIAvailabilityNotice.message(for: llm))
    }

    @ViewBuilder
    private var content: some View {
        if llm.isReady {
            Circle().fill(Theme.statusReady).frame(width: 8, height: 8)
            if librarian.processingCount > 0 {
                Text("Organizing \(librarian.processingCount)…")
            } else if !isCompact {
                // On a narrow iPhone the dot alone says "ready"; the model name lives in Settings and the tooltip.
                Text(llm.activeModelName ?? "Ready")
            }
        } else {
            switch llm.state {
            case .downloading(let p):
                ProgressView(value: p).frame(width: 50)
                Text("\(Int(p * 100))%").monospacedDigit()
            case .loading:
                ProgressView().controlSize(.small)
                if !isCompact { Text("Loading model…") }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.statusWarning)
                Text("Model error")
            case .notLoaded, .ready:
                appleState
            }
        }
    }

    /// No downloaded model is loaded: say where Apple Intelligence stands, in two or three words.
    @ViewBuilder
    private var appleState: some View {
        switch llm.appleAvailability {
        case .notReady where llm.preferAppleIntelligence:
            ProgressView().controlSize(.small)
            if !isCompact { Text("Getting ready…") }
        case .notEnabled:
            Circle().fill(Theme.labelTertiary).frame(width: 8, height: 8)
            Text(isCompact ? "No model" : "Apple Intelligence off")
        default:
            Circle().fill(Theme.labelTertiary).frame(width: 8, height: 8)
            Text("No model")
        }
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
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusReady)
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
                .foregroundStyle(Theme.label)
                .padding(Theme.Space.s12)

                if !collapsed {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    ForEach(activities.prefix(6)) { activity in
                        Button { onOpen(activity.id) } label: { row(activity) }
                            .buttonStyle(.plain)
                    }
                    if activities.count > 6 {
                        Text("+ \(activities.count - 6) more").font(.caption).foregroundStyle(Theme.labelSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    if librarian.processingCount > working {
                        Text("Updating \(librarian.processingCount - working) older items in the background")
                            .font(.caption).foregroundStyle(Theme.labelSecondary)
                            .padding(.horizontal, 12).padding(.bottom, 10)
                    }
                }
            }
            .frame(width: 310)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.hairline))
            .floatShadow()
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.snappy, value: activities)
        }
    }

    private func row(_ activity: Librarian.Activity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: activity.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.label)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.badge + 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.callout.weight(.medium)).foregroundStyle(Theme.label).lineLimit(1)
                Text(activity.stage.label)
                    .font(.caption)
                    .foregroundStyle(Theme.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch activity.stage {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusReady)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.statusWarning)
            case .waitingForModel: Image(systemName: "pause.circle.fill").foregroundStyle(Theme.labelSecondary)
            default: ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
