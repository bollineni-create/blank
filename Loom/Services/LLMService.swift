import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// A model you can download and run on the device.
struct LocalModel: Identifiable, Hashable {
    let configuration: ModelConfiguration
    let name: String
    let sizeGB: Double
    let note: String

    var id: String { configuration.name }

    static func == (a: LocalModel, b: LocalModel) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Repo folder name the Hugging Face cache uses, e.g. `models--mlx-community--Qwen3-1.7B-4bit`.
    var cacheFolderName: String { "models--" + id.replacingOccurrences(of: "/", with: "--") }

    static let catalog: [LocalModel] = [
        .init(configuration: LLMRegistry.qwen3_0_6b_4bit, name: "Qwen3 0.6B", sizeGB: 0.35,
              note: "Tiny and fast. Works on any recent iPhone; basic quality."),
        .init(configuration: LLMRegistry.gemma3_1B_qat_4bit, name: "Gemma 3 1B", sizeGB: 0.75,
              note: "Small and quick, good for tagging and summaries."),
        .init(configuration: LLMRegistry.llama3_2_1B_4bit, name: "Llama 3.2 1B", sizeGB: 0.7,
              note: "Small and quick general model."),
        .init(configuration: LLMRegistry.qwen3_1_7b_4bit, name: "Qwen3 1.7B", sizeGB: 1.0,
              note: "Recommended for iPhone. Best balance of speed and quality."),
        .init(configuration: LLMRegistry.llama3_2_3B_4bit, name: "Llama 3.2 3B", sizeGB: 1.8,
              note: "Better answers. iPhone 15 Pro or newer, or any Apple silicon Mac."),
        .init(configuration: LLMRegistry.qwen3_4b_4bit, name: "Qwen3 4B", sizeGB: 2.3,
              note: "Recommended for Mac. Strong reasoning over your notes."),
        .init(configuration: LLMRegistry.qwen3_8b_4bit, name: "Qwen3 8B", sizeGB: 4.6,
              note: "Mac only (16 GB RAM or more). Highest quality here."),
    ]

    static var recommended: LocalModel {
        #if os(macOS)
        catalog.first { $0.name == "Qwen3 4B" }!
        #else
        catalog.first { $0.name == "Qwen3 1.7B" }!
        #endif
    }
}

/// Downloads, loads and runs the on-device language model (Apple MLX).
@MainActor
@Observable
final class LLMService {
    enum State: Equatable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .notLoaded
    private(set) var loadedModel: LocalModel?
    private(set) var isGenerating = false

    private var container: ModelContainer?
    private var loadTask: Task<Void, Never>?

    private static let selectedKey = "selectedModelID"

    /// Where downloaded weights live. Application Support (not Caches) so iOS doesn't purge them.
    static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Models/hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    /// Must run before any Hugging Face client is created.
    static func configureEnvironment() {
        setenv("HF_HUB_CACHE", modelsDirectory.path, 1)
        #if os(iOS)
        // Keep MLX's buffer cache small so the app stays under iOS memory limits.
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        #endif
    }

    var selectedModel: LocalModel {
        get {
            let id = UserDefaults.standard.string(forKey: Self.selectedKey)
            return LocalModel.catalog.first { $0.id == id } ?? LocalModel.recommended
        }
        set { UserDefaults.standard.set(newValue.id, forKey: Self.selectedKey) }
    }

    var isReady: Bool { state == .ready }

    var hasChosenModel: Bool { UserDefaults.standard.string(forKey: Self.selectedKey) != nil }

    func isDownloaded(_ model: LocalModel) -> Bool {
        let dir = Self.modelsDirectory.appendingPathComponent(model.cacheFolderName)
        return FileManager.default.fileExists(atPath: dir.path)
    }

    func diskUsage(_ model: LocalModel) -> Int64 {
        let dir = Self.modelsDirectory.appendingPathComponent(model.cacheFolderName)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    func delete(_ model: LocalModel) {
        if loadedModel == model {
            container = nil
            loadedModel = nil
            state = .notLoaded
        }
        try? FileManager.default.removeItem(at: Self.modelsDirectory.appendingPathComponent(model.cacheFolderName))
    }

    /// Loads the selected model if it is already on disk (never starts a download by itself).
    func loadSelectedIfDownloaded() {
        if isDownloaded(selectedModel) { load(selectedModel) }
    }

    /// Downloads (if needed) and loads a model. Switching models unloads the previous one.
    func load(_ model: LocalModel) {
        if loadedModel == model, state == .ready { return }
        selectedModel = model
        loadTask?.cancel()
        container = nil
        loadedModel = nil
        state = isDownloaded(model) ? .loading : .downloading(0)

        loadTask = Task {
            do {
                let container = try await #huggingFaceLoadModelContainer(
                    configuration: model.configuration
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        let fraction = progress.fractionCompleted
                        self.state = fraction >= 1 ? .loading : .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                self.container = container
                self.loadedModel = model
                self.state = .ready
            } catch is CancellationError {
                // A newer load replaced this one.
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs one prompt and streams the answer. Calls are queued so only one runs at a time.
    @discardableResult
    func generate(
        system: String,
        prompt: String,
        maxTokens: Int = 600,
        temperature: Float = 0.4,
        onToken: ((String) -> Void)? = nil
    ) async throws -> String {
        while isGenerating { try await Task.sleep(for: .milliseconds(150)) }
        guard let container else { throw LLMError.notReady }
        isGenerating = true
        defer { isGenerating = false }

        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature),
            // Qwen3 "thinking" adds latency and noise we don't want here; other models ignore this.
            additionalContext: ["enable_thinking": false]
        )
        var raw = ""
        for try await chunk in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            raw += chunk
            onToken?(Self.visibleText(raw))
        }
        return Self.visibleText(raw)
    }

    /// Hides any `<think>…</think>` reasoning a model emits.
    static func visibleText(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        if let open = s.range(of: "<think>") { s = String(s[..<open.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LLMError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: "No AI model is loaded. Download one in Settings → AI Model."
        }
    }
}
