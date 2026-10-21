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
    @State private var showingReels = false
    @State private var showingOnboarding = false
    @State private var confirmingUndo = false
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
        .font(.loomBody)
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
                        .surfaceTile(Theme.pillShape)
                }
                .padding(Theme.Space.s12)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: librarian.lastAddedID) { _, id in
            if let id { focusRequest = id }
        }
        // Something being added is already in the library (a file by name or by contents, or a link): replace
        // it, or skip the new one.
        .alert(librarian.conflict?.title ?? "", isPresented: conflictShown, presenting: librarian.conflict) { conflict in
            let waiting = librarian.conflictsWaiting
            Button("Replace") { librarian.resolveConflict(replace: true) }
            if waiting > 1 {
                Button("Replace All (\(waiting))") { librarian.resolveConflict(replace: true, all: true) }
            }
            Button("Skip", role: .cancel) { librarian.resolveConflict(replace: false) }
            if waiting > 1 {
                Button("Skip All (\(waiting))") { librarian.resolveConflict(replace: false, all: true) }
            }
        } message: { conflict in
            Text(conflict.message)
        }
        .onChange(of: router.openItem) { _, _ in handleRouter() }
        .onChange(of: router.newNote) { _, _ in handleRouter() }
        .onReceive(NotificationCenter.default.publisher(for: .loomOpenSettings)) { _ in showingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .loomOpenReels)) { _ in if hasVideos { showingReels = true } }
        // Edit → Undo Last Add on the Mac: the same dialog as the Undo button in the status panel.
        .onReceive(NotificationCenter.default.publisher(for: .loomUndoLastAdd)) { _ in
            if !librarian.lastBatchFiles.isEmpty { confirmingUndo = true }
        }
        .undoAddDialog(isPresented: $confirmingUndo)
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
        // Reels: your videos, full screen, one at a time, in a random order.
        #if os(iOS)
        .fullScreenCover(isPresented: $showingReels) { reels }
        #else
        .sheet(isPresented: $showingReels) { reels.frame(minWidth: 480, idealWidth: 540, minHeight: 760, idealHeight: 900) }
        #endif
        .onAppear {
            if !UserDefaults.standard.bool(forKey: OnboardingView.seenKey) { showingOnboarding = true }
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

    private var reels: some View {
        ReelsView { id in
            selectedItem = id
            focusRequest = id
        }
    }

    private var hasVideos: Bool {
        items.contains { $0.kind == .video && $0.attachmentName != nil }
    }

    private var panelShown: Binding<Bool> {
        Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })
    }

    /// Shown while there's a question. Only the buttons answer it (Escape presses Skip, the cancel button),
    /// so closing is never mistaken for an answer.
    private var conflictShown: Binding<Bool> {
        Binding(get: { librarian.conflict != nil }, set: { _ in })
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
                    Image(systemName: "magnifyingglass").loomSymbols().foregroundStyle(Theme.labelSecondary)
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
                .floatingChrome(Theme.pillShape)
                // The theme's soft glow behind search, in the languages that have one. A light, not a fill: text never sits on it.
                .background {
                    if Theme.style.centerGlow {
                        Theme.glow(radius: 200)
                            .frame(width: 400, height: 400)
                            .allowsHitTesting(false)
                    }
                }

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
                    // One coloured dot (with the model's name beside it on the Mac). Its panel lists each
                    // file's progress, with cancel, and retry or remove for files that failed.
                    ActivityDot { id in
                        selectedItem = id
                        focusRequest = id
                    }
                    if hasVideos {
                        Button { showingReels = true } label: {
                            Image(systemName: "play.rectangle")
                                .font(.body)
                                .loomSymbols()
                                .foregroundStyle(Theme.label)
                                .frame(width: 44, height: 44)
                                .contentShape(Theme.pillShape)
                                .floatingChrome(Theme.pillShape)
                        }
                        .buttonStyle(.plain)
                        .help("Reels: your videos, one at a time, shuffled")
                    }
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .loomSymbols()
                            .foregroundStyle(Theme.label)
                            .frame(width: 44, height: 44)
                            .contentShape(Theme.pillShape)
                            .floatingChrome(Theme.pillShape)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
            }
        }
        .animation(Theme.motion, value: searchFocused)
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
                    Image(systemName: "sparkles").loomSymbols().foregroundStyle(Theme.accentInk)
                    TextField(llm.isReady ? "Ask your brain anything…" : "Ask your brain (needs Apple Intelligence)", text: $question)
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
                .floatingChrome(Theme.pillShape)
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
                    let failed = activities.filter(\.stage.isFailed).count
                    if working > 0 {
                        ProgressView().controlSize(.small)
                        Text("Adding \(working) \(working == 1 ? "item" : "items")…").font(.subheadline.weight(.semibold))
                    } else if failed > 0 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.statusWarning)
                        Text("\(failed) \(failed == 1 ? "file needs" : "files need") attention").font(.subheadline.weight(.semibold))
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusReady)
                        Text("Uploads").font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    Button { withAnimation(Theme.motion) { collapsed.toggle() } } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    if working == 0 {
                        Button { withAnimation(Theme.motion) { librarian.clearFinishedActivities() } } label: {
                            Image(systemName: "xmark").font(.caption.weight(.bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Theme.label)
                .padding(Theme.Space.s12)

                if !collapsed {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    ForEach(activities.prefix(6)) { activity in row(activity) }
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
            .animation(Theme.motion, value: activities)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen(activity.id) }
            switch activity.stage {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.statusReady)
            case .alreadyAdded: Image(systemName: "doc.on.doc.fill").foregroundStyle(Theme.labelSecondary)
            case .failed:
                Button { withAnimation(Theme.motion) { librarian.retry(activity.id) } } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title3).foregroundStyle(Theme.accentInk)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Try again")
                Button { withAnimation(Theme.motion) { librarian.discard(activity.id) } } label: {
                    Image(systemName: "trash.circle.fill").font(.title3).foregroundStyle(Theme.destructive)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove")
            case .waitingForModel: Image(systemName: "pause.circle.fill").foregroundStyle(Theme.labelSecondary)
            default: ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
