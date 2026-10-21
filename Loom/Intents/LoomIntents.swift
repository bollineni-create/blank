import AppIntents
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Entity

/// A saved item, as Siri, Shortcuts and Spotlight see it: the same title and summary as its card on the map.
struct ItemEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
    static var defaultQuery = ItemQuery()

    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Summary")
    var summary: String

    var kindSymbol: String
    var thumbnail: Data?

    init(item: Item) {
        id = item.id
        kindSymbol = item.kind.symbol
        thumbnail = item.thumbnail
        title = item.displayTitle
        summary = item.summary.isEmpty ? item.preview : item.summary
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: summary.isEmpty ? nil : LocalizedStringResource(stringLiteral: String(summary.prefix(140))),
            image: thumbnail.map { DisplayRepresentation.Image(data: $0) } ?? DisplayRepresentation.Image(systemName: kindSymbol))
    }
}

struct ItemQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ItemEntity] {
        let items = (try? LoomIntentSupport.context.fetch(FetchDescriptor<Item>(predicate: #Predicate { identifiers.contains($0.id) }))) ?? []
        return items.map(ItemEntity.init(item:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [ItemEntity] {
        SearchIndex.rank(LoomIntentSupport.allItems(), query: string, limit: 10).map { ItemEntity(item: $0.item) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ItemEntity] {
        var descriptor = FetchDescriptor<Item>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 10
        return ((try? LoomIntentSupport.context.fetch(descriptor)) ?? []).map(ItemEntity.init(item:))
    }
}

@MainActor
enum LoomIntentSupport {
    static var services: LoomServices {
        LoomServices.shared.start()
        return LoomServices.shared
    }

    static var context: ModelContext { services.container.mainContext }

    static func allItems() -> [Item] {
        (try? context.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
    }

    /// The model, when Apple Intelligence can answer right now.
    static func readyModel() async -> LLMService? {
        let llm = services.llm
        llm.refreshAppleAvailability()
        return llm.isReady ? llm : nil
    }

    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

// MARK: - Save to Loom

struct SaveToLoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Save to Loom"
    static var description = IntentDescription("Saves text, a link or a file to your Loom library. Loom organizes it on this device.")
    static var openAppWhenRun = false

    @Parameter(title: "Text or Link")
    var content: String?

    @Parameter(title: "File")
    var file: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$content) to Loom") { \.$file }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let librarian = LoomIntentSupport.services.librarian
        if let file {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = file.filename.isEmpty ? "Shared file" : file.filename
            let copy = folder.appendingPathComponent(name)
            try file.data.write(to: copy)
            // No window to ask in: a file with a name already in the library is saved as another copy, and one
            // whose contents are already there is let go once that's known.
            librarian.addFile(copy, removeSourceWhenDone: true, onConflict: .keepBoth)
            return .result(dialog: "Saved \(name) to Loom.")
        }
        guard let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw $content.needsValueError("What should Loom save?")
        }
        // A link already saved is kept as it is.
        guard librarian.addPasted(text, onConflict: .keepBoth) else {
            return .result(dialog: "That link is already in Loom.")
        }
        return .result(dialog: "Saved to Loom.")
    }
}

// MARK: - Ask Loom

struct AskLoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Loom"
    static var description = IntentDescription("Answers a question from your saved notes, links and files, on this device.")
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask your brain?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Loom \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw $question.needsValueError("What would you like to ask your brain?") }
        guard let llm = await LoomIntentSupport.readyModel() else {
            let notice = AIAvailabilityNotice.message(for: LoomIntentSupport.services.llm)
            return .result(dialog: IntentDialog(stringLiteral: notice),
                           view: IntentSnippetView(question: q, answer: notice, sources: [], footnote: nil))
        }

        let hits = Array(SearchIndex.rank(LoomIntentSupport.allItems(), query: q, limit: 5).map(\.item))
        let prompt = AskView.buildPrompt(question: q, sources: hits, history: [], perItem: AskView.perItemBudget)
        let answer = try await llm.generate(system: AskView.systemPrompt, prompt: prompt, maxTokens: 400, temperature: 0.4)
        let cited = AskView.renumberCitations(answer, sourceIDs: hits.map(\.id))
        let sources = cited.sourceIDs.compactMap { id in hits.first { $0.id == id } }.prefix(3).map(ItemEntity.init(item:))

        let spoken = Citations.plain(cited.text)
        return .result(
            dialog: IntentDialog(full: LocalizedStringResource(stringLiteral: spoken), supporting: "From your library"),
            view: IntentSnippetView(question: q, answer: cited.text, sources: Array(sources),
                                    footnote: "Answered on this \(LoomIntentSupport.deviceName). Nothing was sent anywhere."))
    }
}

// MARK: - Search Loom

struct SearchLoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Loom"
    static var description = IntentDescription("Finds saved items by meaning, not just exact words.")
    static var openAppWhenRun = false

    @Parameter(title: "Search for", requestValueDialog: "What are you looking for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Loom for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[ItemEntity]> {
        let results = SearchIndex.rank(LoomIntentSupport.allItems(), query: query, limit: 10).map { ItemEntity(item: $0.item) }
        let dialog: IntentDialog = switch results.count {
        case 0: "Nothing in your brain matches that yet."
        case 1: "Found 1 item."
        default: "Found \(results.count) items."
        }
        return .result(value: results, dialog: dialog)
    }
}

// MARK: - Open Item

struct OpenItemIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Item"
    static var description = IntentDescription("Opens a saved item on your mind map.")

    @Parameter(title: "Item")
    var target: ItemEntity

    init() {}

    init(target: ItemEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LoomIntentSupport.services.router.openItem = target.id
        return .result()
    }
}

// MARK: - New Note

struct NewNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "New Note"
    static var description = IntentDescription("Starts a new note in Loom, or saves the text you give it as a note.")
    static var openAppWhenRun = true

    @Parameter(title: "Note", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = LoomIntentSupport.services
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let note = services.librarian.addNote(text)
            services.router.openItem = note.id
        } else {
            services.router.newNote = true
        }
        return .result()
    }
}

// MARK: - App Shortcuts

struct LoomShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .red }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskLoomIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask \(.applicationName) a question",
            "Ask \(.applicationName) about my stuff",
        ], shortTitle: "Ask Loom", systemImageName: "sparkles")
        AppShortcut(intent: SaveToLoomIntent(), phrases: [
            "Save this to \(.applicationName)",
            "Save to \(.applicationName)",
            "Add this to \(.applicationName)",
        ], shortTitle: "Save to Loom", systemImageName: "tray.and.arrow.down")
        AppShortcut(intent: SearchLoomIntent(), phrases: [
            "Search \(.applicationName)",
            "Find something in \(.applicationName)",
        ], shortTitle: "Search Loom", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenItemIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Show \(\.$target) in \(.applicationName)",
        ], shortTitle: "Open Item", systemImageName: "note.text")
        AppShortcut(intent: NewNoteIntent(), phrases: [
            "New note in \(.applicationName)",
            "Write a note in \(.applicationName)",
        ], shortTitle: "New Note", systemImageName: "square.and.pencil")
    }
}

// MARK: - Snippet

/// The Ask Loom result: a `surface` tile with the speaker line, the answer, up to three sources and one follow-up.
struct IntentSnippetView: View {
    let question: String
    let answer: String
    let sources: [ItemEntity]
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            SpeakerLine(isUser: false)
            Text(Citations.unlinked(answer))
                .font(.body)
                .foregroundStyle(Theme.label)
                .lineSpacing(4)
                .lineLimit(7)
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s6) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.element.id) { i, source in
                        HStack(spacing: Theme.Space.s8) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.accentInk)
                            Image(systemName: source.kindSymbol).font(.caption).foregroundStyle(Theme.labelSecondary)
                            Text(source.title).font(.caption).foregroundStyle(Theme.label).lineLimit(1)
                        }
                    }
                }
            }
            HStack {
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(Theme.labelSecondary)
                }
                Spacer(minLength: Theme.Space.s8)
                if let first = sources.first {
                    Button(intent: OpenItemIntent(target: first)) {
                        Text("Open in Loom").font(.footnote.weight(.semibold))
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .padding(Theme.Space.s16)
        .frame(maxWidth: .infinity, maxHeight: 340, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}
