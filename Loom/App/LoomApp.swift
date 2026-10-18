import SwiftUI
import SwiftData

@main
struct LoomApp: App {
    @State private var llm: LLMService
    @State private var librarian: Librarian
    let container: ModelContainer

    init() {
        LLMService.configureEnvironment()
        let llm = LLMService()
        _llm = State(initialValue: llm)
        _librarian = State(initialValue: Librarian(llm: llm))
        do {
            container = try ModelContainer(for: Item.self, Space.self, Conversation.self, ChatMessage.self)
        } catch {
            fatalError("Could not open the library database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(llm)
                .environment(librarian)
                .onAppear(perform: start)
                .onChange(of: llm.state) { _, state in
                    if state == .ready { librarian.runQueue() }
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Note") { NotificationCenter.default.post(name: .loomNewNote, object: nil) }
                    .keyboardShortcut("n")
                Button("Save Link…") { NotificationCenter.default.post(name: .loomNewLink, object: nil) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(llm)
                .environment(librarian)
                .modelContainer(container)
                .frame(width: 560, height: 620)
        }
        #endif
    }

    private func start() {
        guard librarian.context == nil else { return }
        let context = container.mainContext
        librarian.context = context
        // Anything interrupted mid-processing last time goes back in the queue.
        let processing = AIStatus.processing.rawValue
        if let stuck = try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.aiStatusRaw == processing })) {
            for item in stuck { item.aiStatus = .pending }
            try? context.save()
        }
        llm.loadSelectedIfDownloaded()
    }
}

extension Notification.Name {
    static let loomNewNote = Notification.Name("loomNewNote")
    static let loomNewLink = Notification.Name("loomNewLink")
    static let loomPaste = Notification.Name("loomPaste")
}
