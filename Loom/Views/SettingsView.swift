import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian
    @Environment(SyncMonitor.self) private var sync
    @Query private var items: [Item]
    private let themes = ThemeStore.shared

    var body: some View {
        @Bindable var bindableLibrarian = librarian
        Form {
            Section {
                ForEach(LoomTheme.all) { option in
                    Button { themes.theme = option } label: { ThemeRow(theme: option, selected: option.id == themes.theme.id) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Each theme is a whole design language: its colours, type, corners, depth, icons and motion, and how the map draws topics, links and the canvas, in light and dark mode.")
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: Theme.Space.s6) {
                        if llm.isReady {
                            Circle().fill(Theme.statusReady).frame(width: 8, height: 8)
                            Text("Active")
                        } else {
                            Text(appleStatus)
                        }
                    }
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("Apple's on-device model answers your questions and organizes what you save. Nothing is sent anywhere.")
            }

            Section("Organizing") {
                Toggle("Auto-organize new items", isOn: $bindableLibrarian.autoOrganize)
                Button("Organize all unprocessed items") { librarian.organizeAllUnprocessed() }
                    .disabled(!llm.isReady)
                Button("Redo summaries & takeaways for everything") { librarian.reorganizeAll() }
                    .disabled(!llm.isReady)
                LabeledContent("Items", value: "\(items.count)")
                LabeledContent("Organized", value: "\(items.filter { $0.aiStatus == .done }.count)")
            }

            Section {
                let broken = librarian.brokenFiles(syncing: sync.hasCloudKit == true)
                let lastAdded = librarian.lastBatchFiles
                LabeledContent("Broken files", value: "\(broken.count)")
                CleanUpButton(files: broken, label: "Clean up broken files…")
                LabeledContent("Last added", value: lastAdded.isEmpty ? "Nothing to undo" : "\(lastAdded.count) \(lastAdded.count == 1 ? "file" : "files")")
                UndoAddButton(files: lastAdded, label: "Undo last add…")
                EraseLibraryButton(itemCount: items.count)
            } header: {
                Text("Library")
            } footer: {
                Text("A broken file is one whose copy into the library never finished, one that's in the library with no file behind it on this device or in iCloud, or one that hangs off nothing on the map: no tags and no space, like a video saved as a picture by mistake or a photo with no words in it. Clean up removes them all at once and names them first. Items being added or organized right now, or added in the last hour and still waiting for Apple Intelligence, are left alone. With auto-organize off, or while Apple Intelligence isn't available, nothing would tag an item, so untagged items aren't counted.\n\nUndo last add takes out the files that were added together most recently (one drop, one pick, one paste), even if they're still being copied in or read. It names them first, and works once per batch, until the app is quit.\n\nErase library removes everything: every item, space and Ask conversation, and the files behind them on this device. It asks first. With iCloud sync on, your other devices empty too. Your theme and other settings are kept.")
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: Theme.Space.s6) {
                        Circle().fill(syncColor).frame(width: 8, height: 8)
                        Text(sync.headline)
                    }
                }
                if let detail = sync.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                if let date = sync.lastImport {
                    LabeledContent("Last received", value: date.formatted(.relative(presentation: .named)))
                }
                if let date = sync.lastExport {
                    LabeledContent("Last sent", value: date.formatted(.relative(presentation: .named)))
                }
                Button("Send everything on this device to iCloud") { librarian.resendLibraryToICloud() }
                    .disabled(sync.hasCloudKit != true)
            } header: {
                Text("iCloud sync")
            } footer: {
                Text("Your Mac and iPhone share one library when both are signed in to the same Apple Account and both copies of Loom are signed with the same team and run from Xcode, so they use the same iCloud environment. If items you saved before sync was on are missing from your other devices, tap Send everything on the device that has them.")
            }

            Section("Search") {
                Text("Semantic search uses Apple's built-in on-device sentence embeddings, so it works even with no model loaded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .tint(Theme.accent)
        .font(.loomBody)
        .navigationTitle("Settings")
        .onAppear { llm.refreshAppleAvailability() }
    }

    private var syncColor: Color {
        switch sync.tone {
        case .ok: Theme.statusReady
        case .busy: Theme.statusBusy
        case .problem: Theme.statusUploading
        }
    }

    private var appleStatus: String {
        switch llm.appleAvailability {
        case .available: "Active"
        case .notEnabled: "Turned off in Settings"
        case .deviceNotEligible: "Not available on this device"
        case .notReady: "Getting ready…"
        case .unsupportedOS: "Needs iOS 26 or macOS 26"
        case .unavailable: "Unavailable"
        }
    }
}

/// Empties the whole library after a dialog says what that means. Needs a second confirmation, since there's
/// no undo and iCloud carries the deletion to every device.
private struct EraseLibraryButton: View {
    @Environment(Librarian.self) private var librarian
    @Environment(SyncMonitor.self) private var sync
    @Query private var spaces: [Space]
    @Query private var conversations: [Conversation]
    var itemCount: Int
    @State private var confirming = false
    @State private var confirmingAgain = false

    var body: some View {
        Button("Erase library…", role: .destructive) { confirming = true }
            .disabled(itemCount == 0 && spaces.isEmpty && conversations.isEmpty)
            .help("Remove everything from the library")
            .confirmationDialog("Erase the whole library?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Continue…", role: .destructive) {
                    // Let the dialog close before the alert opens, or it stays shut.
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        confirmingAgain = true
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(message)
            }
            .alert("Erase \(Self.count(itemCount, "item")), \(Self.count(spaces.count, "space")) and \(Self.count(conversations.count, "conversation"))?",
                   isPresented: $confirmingAgain) {
                Button("Erase Everything", role: .destructive) {
                    withAnimation(Theme.motion) { librarian.eraseLibrary() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This can't be undone.")
            }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private var message: String {
        var text = "Every item, space and Ask conversation is removed, along with the files behind them on this device. "
        text += "Anything still being added is stopped. There's no undo."
        if sync.hasCloudKit == true {
            text += " iCloud sync is on, so the library on your other devices is emptied too."
        }
        text += " Your theme and other settings stay as they are."
        return text
    }
}

/// A theme in the picker: a swatch of its canvas, accent and second hue, its name in its own display face.
private struct ThemeRow: View {
    let theme: LoomTheme
    let selected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            RoundedRectangle(cornerRadius: min(theme.corner ?? 8, 8))
                .fill(theme.ground.color)
                .overlay(RoundedRectangle(cornerRadius: min(theme.corner ?? 8, 8)).strokeBorder(theme.line.color, lineWidth: 1))
                .overlay {
                    HStack(spacing: -4) {
                        Circle().fill(theme.accent.color)
                        Circle().fill(theme.signal.color)
                    }
                    .frame(height: 14)
                }
                .frame(width: 44, height: 30)
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                Text(theme.style.displayCaps ? theme.name.uppercased() : theme.name)
                    .font(theme.display.font(size: 17, relativeTo: .body))
                    .tracking(theme.display.tracking)
                    .foregroundStyle(Theme.label)
                Text(theme.mood).font(.caption).foregroundStyle(Theme.labelSecondary)
            }
            Spacer(minLength: Theme.Space.s8)
            if selected {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accentInk)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// First-run sheet: explains the app.
struct OnboardingView: View {
    @Environment(LLMService.self) private var llm
    @Environment(\.dismiss) private var dismiss

    static let seenKey = "hasSeenOnboarding"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "brain.head.profile").font(.system(size: 48)).foregroundStyle(Theme.labelSecondary)
                    Text("Your private second brain").font(.loomDisplay).serifTracking().foregroundStyle(Theme.label)
                    feature("tray.and.arrow.down", "Save anything", "Notes, links, photos, screenshots, PDFs and files in one place.")
                    feature("sparkles", "Organized for you", "Apple Intelligence, running on this device, titles, summarizes and tags everything.")
                    feature("magnifyingglass", "Search by meaning", "Find things by what they're about, not just the exact words.")
                    feature("bubble.left.and.text.bubble.right", "Ask your library", "Chat with your saved stuff and get answers with sources.")
                    feature("lock.shield", "Fully on-device", "No data ever leaves your device.")
                    if llm.appleAvailability != .available {
                        AIAvailabilityNotice(showsAction: false)
                    }
                }
                .padding(Theme.Space.s24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    UserDefaults.standard.set(true, forKey: Self.seenKey)
                    dismiss()
                } label: {
                    Text("Get started").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
            .background(Theme.background)
            .tint(Theme.accent)
        }
        #if os(macOS)
        .frame(width: 520, height: 680)
        #endif
        .interactiveDismissDisabled()
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2)
                .foregroundStyle(symbol == "sparkles" ? Theme.accentInk : Theme.label).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Theme.label)
                Text(detail).foregroundStyle(Theme.labelSecondary)
            }
        }
    }
}
