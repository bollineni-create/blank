import Foundation
import LlamaKit

/// A model you can download and run on the device (GGUF format, run by llama.cpp).
struct LocalModel: Identifiable, Hashable {
    let name: String
    /// Hugging Face repo and file, e.g. `unsloth/Qwen3-1.7B-GGUF` + `Qwen3-1.7B-Q4_K_M.gguf`.
    let repo: String
    let file: String
    let sizeGB: Double
    let note: String

    var id: String { file }
    var downloadURL: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")! }
    var isQwen3: Bool { file.hasPrefix("Qwen3") }

    static let catalog: [LocalModel] = [
        .init(name: "Qwen3 0.6B", repo: "unsloth/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf", sizeGB: 0.64,
              note: "Tiny and fast. Works on any recent iPhone; basic quality."),
        .init(name: "Gemma 3 1B", repo: "unsloth/gemma-3-1b-it-GGUF", file: "gemma-3-1b-it-Q4_K_M.gguf", sizeGB: 0.81,
              note: "Small and quick, good for tagging and summaries."),
        .init(name: "Llama 3.2 1B", repo: "bartowski/Llama-3.2-1B-Instruct-GGUF", file: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", sizeGB: 0.81,
              note: "Small and quick general model."),
        .init(name: "Qwen3 1.7B", repo: "unsloth/Qwen3-1.7B-GGUF", file: "Qwen3-1.7B-Q4_K_M.gguf", sizeGB: 1.1,
              note: "Recommended for iPhone. Best balance of speed and quality."),
        .init(name: "Llama 3.2 3B", repo: "bartowski/Llama-3.2-3B-Instruct-GGUF", file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", sizeGB: 2.0,
              note: "Better answers. iPhone 15 Pro or newer, or any Apple silicon Mac."),
        .init(name: "Qwen3 4B", repo: "unsloth/Qwen3-4B-GGUF", file: "Qwen3-4B-Q4_K_M.gguf", sizeGB: 2.5,
              note: "Recommended for Mac. Strong reasoning over your notes."),
        .init(name: "Qwen3 8B", repo: "unsloth/Qwen3-8B-GGUF", file: "Qwen3-8B-Q4_K_M.gguf", sizeGB: 5.0,
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

/// Downloads, loads and runs the on-device language model.
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

    private var engine: LlamaEngine?
    private var loadTask: Task<Void, Never>?

    private static let selectedKey = "selectedModelID"

    /// Where downloaded models live. Application Support (not Caches) so iOS doesn't purge them.
    static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    static func configureEnvironment() {
        _ = modelsDirectory
    }

    /// Context window: how much text the model can look at once.
    private var contextLength: Int {
        #if os(macOS)
        8192
        #else
        4096
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

    private func fileURL(_ model: LocalModel) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.file)
    }

    func isDownloaded(_ model: LocalModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(model).path)
    }

    func diskUsage(_ model: LocalModel) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: fileURL(model).path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    func delete(_ model: LocalModel) {
        if loadedModel == model || selectedModel == model {
            loadTask?.cancel()
            engine = nil
            loadedModel = nil
            state = .notLoaded
        }
        try? FileManager.default.removeItem(at: fileURL(model))
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
        engine = nil
        loadedModel = nil
        let destination = fileURL(model)
        let contextLength = contextLength

        loadTask = Task {
            do {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    state = .downloading(0)
                    try await FileDownloader.download(model.downloadURL, to: destination) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, case .downloading = self.state else { return }
                            self.state = .downloading(fraction)
                        }
                    }
                }
                try Task.checkCancellation()
                state = .loading
                let engine = try await Task.detached(priority: .userInitiated) {
                    try LlamaEngine(path: destination.path, contextLength: contextLength)
                }.value
                try Task.checkCancellation()
                self.engine = engine
                self.loadedModel = model
                self.state = .ready
            } catch is CancellationError {
                // A newer load replaced this one.
            } catch let error as URLError where error.code == .cancelled {
                // Download cancelled.
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
        guard let engine, let model = loadedModel else { throw LLMError.notReady }
        isGenerating = true
        defer { isGenerating = false }

        // Qwen3 "thinking" adds latency we don't want here; this is its built-in off switch.
        let userText = model.isQwen3 ? prompt + " /no_think" : prompt
        let messages = [ChatTurn(role: "system", content: system), ChatTurn(role: "user", content: userText)]

        var raw = ""
        for try await piece in engine.stream(messages, maxTokens: maxTokens, temperature: temperature) {
            try Task.checkCancellation()
            raw += piece
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
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notReady: "No AI model is loaded. Download one in Settings → AI Model."
        case .badResponse(let code): "The model download failed (HTTP \(code)). Check your connection and try again."
        }
    }
}

/// Downloads a large file with progress, moving it into place only when complete.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func download(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let downloader = FileDownloader(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = LLMError.badResponse(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
