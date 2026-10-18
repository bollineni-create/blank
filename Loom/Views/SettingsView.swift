import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(LLMService.self) private var llm
    @Environment(Librarian.self) private var librarian
    @Query private var items: [Item]

    var body: some View {
        @Bindable var bindableLibrarian = librarian
        Form {
            Section {
                ModelPicker()
            } header: {
                Text("AI Model")
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

            Section("Search") {
                Text("Semantic search uses Apple's built-in on-device sentence embeddings, so it works even with no model loaded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

/// Lists downloadable models with download / load / delete controls.
struct ModelPicker: View {
    @Environment(LLMService.self) private var llm
    @State private var confirmDelete: LocalModel?

    var body: some View {
        if case .failed(let message) = llm.state {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
        ForEach(LocalModel.catalog) { model in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(model.name).font(.headline)
                        if model == LocalModel.recommended {
                            Text("Recommended").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(model.note).font(.caption).foregroundStyle(.secondary)
                    Text(sizeLabel(model)).font(.caption2).foregroundStyle(.tertiary)
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
            Label("Active", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green).font(.callout)
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
                    Image(systemName: "brain.head.profile").font(.system(size: 56)).foregroundStyle(Color.accentColor)
                    Text("Your private second brain").font(.largeTitle.bold())
                    feature("tray.and.arrow.down", "Save anything", "Notes, links, photos, screenshots, PDFs and files in one place.")
                    feature("sparkles", "Organized for you", "An AI model running on this device titles, summarizes and tags everything.")
                    feature("magnifyingglass", "Search by meaning", "Find things by what they're about, not just the exact words.")
                    feature("bubble.left.and.text.bubble.right", "Ask your library", "Chat with your saved stuff and get answers with sources.")
                    feature("lock.shield", "Fully on-device", "After the one-time model download, no data ever leaves your device.")
                    Divider()
                    Text("Pick a model to download").font(.headline)
                    Text("\(LocalModel.recommended.name) (≈ \(String(format: "%.1f", LocalModel.recommended.sizeGB)) GB) is a good fit for this device. Use Wi-Fi. You can switch any time in Settings.")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
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
        }
        #if os(macOS)
        .frame(width: 520, height: 680)
        #endif
        .interactiveDismissDisabled()
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
