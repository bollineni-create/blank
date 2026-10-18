import Foundation
#if !targetEnvironment(simulator)
import llama
#endif

public struct ChatTurn: Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LlamaError: LocalizedError {
    case loadFailed(String)
    case contextFailed
    case templateFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let path): "Couldn't load the model file at \(path). Try deleting and downloading it again."
        case .contextFailed: "Couldn't start the model. The device may be low on memory; try a smaller model."
        case .templateFailed: "Couldn't format the prompt for this model."
        case .tokenizeFailed: "Couldn't read the prompt."
        case .decodeFailed(let code): "The model stopped unexpectedly (code \(code))."
        case .unavailable: "Downloaded models don't run in the iOS Simulator. Use Apple Intelligence, or run Loom on a device."
        }
    }
}

#if targetEnvironment(simulator)

/// llama.cpp has no iOS Simulator build, so on the simulator loading a model always fails
/// and Loom relies on Apple's Foundation Models.
public actor LlamaEngine {
    public init(path: String, contextLength: Int, useGPU: Bool = true) throws {
        throw LlamaError.unavailable
    }

    public nonisolated func stream(
        _ messages: [ChatTurn],
        maxTokens: Int,
        temperature: Float
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LlamaError.unavailable) }
    }
}

#else

/// A loaded GGUF model running on the GPU through llama.cpp.
/// All work happens on this actor, one generation at a time.
public actor LlamaEngine {
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let context: OpaquePointer
    private let batchSize = 512

    private static let backend: Void = { llama_backend_init() }()

    public init(path: String, contextLength: Int, useGPU: Bool = true) throws {
        _ = Self.backend

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = useGPU ? 999 : 0
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LlamaError.loadFailed(path)
        }

        var contextParams = llama_context_default_params()
        let trained = Int(llama_model_n_ctx_train(model))
        contextParams.n_ctx = UInt32(trained > 0 ? min(contextLength, trained) : contextLength)
        contextParams.n_batch = UInt32(batchSize)
        contextParams.n_ubatch = UInt32(batchSize)
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Streams the reply to a chat as text pieces.
    public nonisolated func stream(
        _ messages: [ChatTurn],
        maxTokens: Int,
        temperature: Float
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages, maxTokens: maxTokens, temperature: temperature) { piece in
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ messages: [ChatTurn],
        maxTokens: Int,
        temperature: Float,
        emit: @Sendable (String) -> Void
    ) throws {
        let prompt = try applyTemplate(messages)
        var tokens = try tokenize(prompt)

        llama_memory_clear(llama_get_memory(context), true)

        // Leave room for the answer; if the prompt is too long keep its end (the question).
        let contextSize = Int(llama_n_ctx(context))
        let room = max(64, contextSize - maxTokens - 8)
        if tokens.count > room { tokens = Array(tokens.suffix(room)) }

        // Read the prompt in chunks.
        var start = 0
        while start < tokens.count {
            try Task.checkCancellation()
            let count = min(batchSize, tokens.count - start)
            let rc = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + start, Int32(count)))
            }
            guard rc == 0 else { throw LlamaError.decodeFailed(rc) }
            start += count
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        // A token can end in the middle of a multi-byte character; hold bytes until they decode.
        var pending: [UInt8] = []
        let limit = min(maxTokens, contextSize - tokens.count - 1)
        for _ in 0..<max(0, limit) {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            pending += piece(for: token)
            if let text = String(bytes: pending, encoding: .utf8) {
                emit(text)
                pending.removeAll()
            } else if pending.count > 8 {
                emit(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }

            let rc = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            guard rc == 0 else { throw LlamaError.decodeFailed(rc) }
        }
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
    }

    private func applyTemplate(_ messages: [ChatTurn]) throws -> String {
        let template = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        var chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }

        var capacity = Int32(messages.reduce(0) { $0 + $1.content.utf8.count + $1.role.utf8.count } * 2 + 1024)
        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            let written = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, capacity)
            guard written >= 0 else { throw LlamaError.templateFailed }
            if written <= capacity {
                return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity = written + 1
        }
        throw LlamaError.templateFailed
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        }
        guard count > 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }
}

#endif
