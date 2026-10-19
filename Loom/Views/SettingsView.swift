import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian
    @Environment(SyncMonitor.self) private var sync
    @Query private var items: [Item]

    var body: some View {
        @Bindable var bindableLibrarian = librarian
        @Bindable var bindableLLM = llm
        Form {
            Section {
                Toggle("Use Apple Intelligence when available", isOn: $bindableLLM.preferAppleIntelligence)
                    .disabled(llm.appleAvailability == .unsupportedOS || llm.appleAvailability == .deviceNotEligible)
                LabeledContent("Status") {
                    HStack(spacing: Theme.Space.s6) {
                        if llm.usesAppleModel {
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
                Text("Apple's on-device model answers and organizes when it's available. Nothing is sent anywhere. Otherwise Loom uses a model you download below.")
            }

            Section {
                ModelPicker()
            } header: {
                Text("Downloaded models")
            } footer: {
                Text("Models are downloaded once from Hugging Face and then run entirely on this device with llama.cpp. Your library never leaves the device.")
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
            } header: {
                Text("iCloud sync")
            } footer: {
                Text("Your Mac and iPhone share one library when both are signed in to the same Apple Account and both copies of Loom are signed with the same team and run from Xcode, so they use the same iCloud environment.")
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
        case .available: "Off for Loom"
        case .notEnabled: "Turned off in Settings"
        case .deviceNotEligible: "Not available on this device"
        case .notReady: "Getting ready…"
        case .unsupportedOS: "Needs iOS 26 or macOS 26"
        case .unavailable: "Unavailable"
        }
    }
}

/// Lists downloadable models with download / load / delete controls.
struct ModelPicker: View {
    @Environment(LLMService.self) private var llm
    @State private var confirmDelete: LocalModel?

    var body: some View {
        if case .failed(let message) = llm.state {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.label).font(.callout)
                .symbolRenderingMode(.multicolor)
        }
        ForEach(LocalModel.catalog) { model in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(model.name).font(.headline).foregroundStyle(Theme.label)
                        if model == LocalModel.recommended {
                            Text("Recommended").font(.caption2.bold()).foregroundStyle(Theme.label)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accentTint, in: Capsule())
                        }
                    }
                    Text(model.note).font(.caption).foregroundStyle(Theme.labelSecondary)
                    Text(sizeLabel(model)).font(.caption2).foregroundStyle(Theme.labelTertiary)
                }
                Spacer()
                control(for: model)
            }
            .padding(.vertical, 4)
            .contextMenu {
                if llm.isDownloaded(model) {
                    Button("Delete Download", role: .destructive) { confirmDelete = model }
                }
            }
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "model")?", isPresented: .init(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let m = confirmDelete { llm.delete(m) } }
        }
    }

    @ViewBuilder
    private func control(for model: LocalModel) -> some View {
        let isSelected = llm.selectedModel == model
        if isSelected, case .downloading(let p) = llm.state {
            VStack(alignment: .trailing) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.caption2).monospacedDigit()
            }
        } else if isSelected, llm.state == .loading {
            ProgressView().controlSize(.small)
        } else if llm.loadedModel == model, llm.isReady {
            Label(llm.usesAppleModel ? "Ready" : "Active", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                .foregroundStyle(Theme.statusReady).font(.callout)
        } else if llm.isDownloaded(model) {
            HStack {
                Button("Use") { llm.load(model) }.buttonStyle(.bordered)
                Button(role: .destructive) { confirmDelete = model } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        } else {
            Button("Download") { llm.load(model) }.buttonStyle(.borderedProminent)
        }
    }

    private func sizeLabel(_ model: LocalModel) -> String {
        if llm.isDownloaded(model) {
            let bytes = llm.diskUsage(model)
            return "Downloaded · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return String(format: "≈ %.1f GB download", model.sizeGB)
    }
}

/// First-run sheet: explains the app and starts the model download.
struct OnboardingView: View {
    @Environment(LLMService.self) private var llm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "brain.head.profile").font(.system(size: 48)).foregroundStyle(Theme.labelSecondary)
                    Text("Your private second brain").font(.loomDisplay).serifTracking().foregroundStyle(Theme.label)
                    feature("tray.and.arrow.down", "Save anything", "Notes, links, photos, screenshots, PDFs and files in one place.")
                    feature("sparkles", "Organized for you", "An AI model running on this device titles, summarizes and tags everything.")
                    feature("magnifyingglass", "Search by meaning", "Find things by what they're about, not just the exact words.")
                    feature("bubble.left.and.text.bubble.right", "Ask your library", "Chat with your saved stuff and get answers with sources.")
                    feature("lock.shield", "Fully on-device", "After the one-time model download, no data ever leaves your device.")
                    if llm.appleAvailability != .unsupportedOS && llm.appleAvailability != .available {
                        AIAvailabilityNotice(showsAction: false)
                    }
                    Text("Pick a model to download").font(.loomTitle3).serifTracking().foregroundStyle(Theme.label)
                        .padding(.top, Theme.Space.s16)
                    Text("\(LocalModel.recommended.name) (≈ \(String(format: "%.1f", LocalModel.recommended.sizeGB)) GB) is a good fit for this device. Use Wi-Fi. You can switch any time in Settings.")
                        .foregroundStyle(Theme.labelSecondary)
                }
                .padding(Theme.Space.s24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        llm.load(LocalModel.recommended)
                        dismiss()
                    } label: {
                        Text("Download \(LocalModel.recommended.name)").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Choose later") {
                        UserDefaults.standard.set(LocalModel.recommended.id, forKey: "selectedModelID")
                        dismiss()
                    }
                }
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
