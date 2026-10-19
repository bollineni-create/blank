import SwiftUI
import SwiftData

/// The library, the model and the librarian, shared by the app's windows and its App Intents
/// (Siri and Shortcuts can run before any window exists).
@MainActor
final class LoomServices {
    static let shared = LoomServices()

    let container: ModelContainer
    let llm: LLMService
    let librarian: Librarian
    /// Whether iCloud is actually syncing the library, and why not.
    let sync: SyncMonitor
    /// Requests from App Intents that the main page acts on.
    let router = LoomRouter()

    private init() {
        Theme.registerFonts()
        llm = LLMService()
        librarian = Librarian(llm: llm)
        // Listens before the library opens, so it hears iCloud's first setup report.
        sync = SyncMonitor()
        do {
            // Syncs through the private iCloud database named in the entitlements, so the Mac and
            // iPhone share one library. Without iCloud (signed out, unsigned build) it stays on this device.
            let configuration = ModelConfiguration(cloudKitDatabase: .automatic)
            container = try ModelContainer(for: Item.self, Space.self, Conversation.self, ChatMessage.self,
                                           configurations: configuration)
        } catch {
            fatalError("Could not open the library database: \(error)")
        }
    }

    /// Connects the librarian to the database and checks the model. Safe to call more than once.
    func start() {
        guard librarian.context == nil else { return }
        librarian.context = container.mainContext
        // Copies the last run never finished are dropped; adds it never finished are picked up where they stopped.
        AttachmentStore.clearStaging()
        librarian.resumeInterruptedAdds()
        librarian.upgradeOldSummaries()
        librarian.backfillAttachmentsForSync()
        llm.refreshAppleAvailability()
        librarian.runQueue()
    }
}

/// What App Intents ask the main page to show.
@MainActor
@Observable
final class LoomRouter {
    var openItem: UUID?
    var newNote = false
}

@main
struct LoomApp: App {
    @State private var llm: LLMService
    @State private var librarian: Librarian
    @State private var router: LoomRouter
    @State private var sync: SyncMonitor
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer

    init() {
        let services = LoomServices.shared
        _llm = State(initialValue: services.llm)
        _librarian = State(initialValue: services.librarian)
        _router = State(initialValue: services.router)
        _sync = State(initialValue: services.sync)
        container = services.container
        LoomShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(llm)
                .environment(librarian)
                .environment(router)
                .environment(sync)
                .onAppear { LoomServices.shared.start() }
                .onChange(of: llm.isReady) { _, ready in
                    if ready { librarian.modelBecameReady() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { llm.refreshAppleAvailability() }
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
                .environment(sync)
                .modelContainer(container)
                .frame(width: 560, height: 620)
        }
        #endif
    }
}

extension Notification.Name {
    static let loomNewNote = Notification.Name("loomNewNote")
    static let loomNewLink = Notification.Name("loomNewLink")
    static let loomPaste = Notification.Name("loomPaste")
    static let loomOpenSettings = Notification.Name("loomOpenSettings")
}
