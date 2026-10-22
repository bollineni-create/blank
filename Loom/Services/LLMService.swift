import Foundation

/// Runs the on-device language model: Apple's Foundation Model (Apple Intelligence).
@MainActor
@Observable
final class LLMService {
    private(set) var isGenerating = false

    /// Whether Apple's on-device model can run right now (refreshed on launch and when the app comes back).
    private(set) var appleAvailability: AppleModelAvailability = AppleModelEngine.availability
    private var availabilityRecheck: Task<Void, Never>?

    var isReady: Bool { appleAvailability.isAvailable }

    /// The name shown in Settings and the status chip.
    var activeModelName: String? { isReady ? "Apple Intelligence" : nil }

    /// How much item text to put in one prompt; Apple's model has a small context window.
    var inputBudgetCharacters: Int { AppleModelEngine.inputBudgetCharacters }

    /// How long the model may go quiet before a call is given up on. Answers stream in as the model writes
    /// them, so a slow answer keeps showing signs of life and is left to finish; one silent this long has hung.
    /// The limit used to be on the whole call. On a busy Mac (files being read, transcribed and embedded at the
    /// same time) Apple's model slows down a lot, and healthy calls were cut off at the limit and marked failed,
    /// while the cut-off call kept the model busy behind the next one. Each batch got through fewer items
    /// than the last, and the queue stalled on and off.
    static let stallTimeout: Duration = .seconds(120)

    /// Called when the model becomes usable again after being unavailable or paused, so the organizing queue
    /// picks up where it stopped. Set by `LoomServices`; it doesn't depend on a window being open.
    var becameReady: (@MainActor () -> Void)?

    /// Re-reads Apple Intelligence availability. While the model is getting ready (or away for a reason the
    /// system doesn't name), checks again shortly, so queued work carries on once it's back.
    func refreshAppleAvailability() {
        guard !isPaused else { return }
        let wasReady = isReady
        appleAvailability = AppleModelEngine.availability
        availabilityRecheck?.cancel()
        if isReady {
            if !wasReady { becameReady?() }
            return
        }
        guard appleAvailability == .notReady || appleAvailability == .unavailable else { return }
        scheduleAvailabilityRecheck(after: 20)
    }

    /// Set after Apple's model fails at runtime even though the system reported it available. The system
    /// still says "available" then, so this is what tells "Loom is giving it a minute" apart from the model
    /// downloading.
    private(set) var isPaused = false

    /// Ends a pause early, from the "Try now" buttons: checks the model again and, if it's there, the queue
    /// carries on.
    func retryNow() {
        guard isPaused else { return }
        availabilityRecheck?.cancel()
        isPaused = false
        refreshAppleAvailability()
    }

    /// Treats Apple's model as "getting ready" for a minute, so work waits instead of failing over and over.
    /// After a hung call this also gives the system time to let that call go before the next one starts.
    private func pauseAppleModel() {
        isPaused = true
        appleAvailability = .notReady
        scheduleAvailabilityRecheck(after: 60)
    }

    private func scheduleAvailabilityRecheck(after seconds: Int) {
        availabilityRecheck?.cancel()
        availabilityRecheck = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.isPaused = false
            self.refreshAppleAvailability()
        }
    }

    /// Runs one prompt and streams the answer. Calls are queued so only one runs at a time. `onToken` gets the
    /// whole answer so far, on the main actor, so views can show it as it arrives.
    @discardableResult
    func generate(
        system: String,
        prompt: String,
        maxTokens: Int = 600,
        temperature: Float = 0.4,
        onToken: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        while isGenerating { try await Task.sleep(for: .milliseconds(150)) }
        guard isReady else { throw LLMError.notReady }
        isGenerating = true
        defer { isGenerating = false }
        do {
            return try await withDeadline(Self.stallTimeout) { stillWorking in
                try await AppleModelEngine.generate(
                    system: system, prompt: prompt, maxTokens: maxTokens, temperature: temperature,
                    onToken: { text in
                        stillWorking()
                        onToken?(text)
                    })
            }
        } catch is ModelTimeout {
            pauseAppleModel()
            throw AppleModelError.timedOut
        } catch let error as AppleModelError where error.isRuntimeFailure {
            pauseAppleModel()
            throw error
        }
    }

    /// Guided generation of an item's title, summary, takeaways and tags.
    func organizeWithAppleModel(_ prompt: String, instructions: String) async throws -> OrganizedFields {
        while isGenerating { try await Task.sleep(for: .milliseconds(150)) }
        guard isReady else { throw LLMError.notReady }
        isGenerating = true
        defer { isGenerating = false }
        do {
            return try await withDeadline(Self.stallTimeout) { stillWorking in
                try await AppleModelEngine.organize(prompt, instructions: instructions, onProgress: stillWorking)
            }
        } catch is ModelTimeout {
            // The model went silent: it's stuck, not slow. Pause it so the queue waits instead of hanging the
            // same way on the next item (the librarian puts the item back in line once).
            pauseAppleModel()
            throw AppleModelError.timedOut
        } catch let error as AppleModelError where error.isRuntimeFailure {
            pauseAppleModel()
            throw error
        }
    }
}

/// Thrown by `withDeadline` when the work goes quiet for too long.
struct ModelTimeout: Error {}

/// Runs `work`, giving up once `limit` passes with no sign of progress. `work` is handed a closure to call each
/// time something arrives (a token, a partial result); every call starts the clock again, so slow work that is
/// still moving is left to finish and only silence counts as a hang. On timeout the work is cancelled and left
/// behind: a system call that ignores cancellation finishes (or stays hung) on its own, without holding the
/// caller. Structured task groups can't do this, because they wait for every child to end before returning.
func withDeadline<T: Sendable>(
    _ limit: Duration,
    _ work: @escaping @Sendable (_ stillWorking: @escaping @Sendable () -> Void) async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, limit: limit, work: work)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// First to finish wins: the work's answer, the deadline, or cancellation from outside. Later finishers are ignored.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    /// When the work last reported progress; the deadline is measured from here.
    private var lastProgress = ContinuousClock.now

    func start(
        _ continuation: CheckedContinuation<T, Error>, limit: Duration,
        work: @escaping @Sendable (_ stillWorking: @escaping @Sendable () -> Void) async throws -> T
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        lock.lock()
        self.continuation = continuation
        self.lastProgress = .now
        lock.unlock()
        let job = Task {
            let result: Result<T, Error>
            do { result = .success(try await work { self.progressed() }) } catch { result = .failure(error) }
            self.finish(result)
        }
        let clock = Task {
            // Sleep until the deadline as it stood; if progress moved it meanwhile, sleep again until the new one.
            while !Task.isCancelled {
                let deadline = self.deadline(limit)
                if deadline <= .now {
                    self.finish(.failure(ModelTimeout()))
                    return
                }
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        }
        lock.lock()
        self.work = job
        self.timer = clock
        lock.unlock()
    }

    private func progressed() {
        lock.lock()
        lastProgress = .now
        lock.unlock()
    }

    private func deadline(_ limit: Duration) -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return lastProgress + limit
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let work = self.work
        let timer = self.timer
        lock.unlock()
        guard let continuation else { return }
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}

enum LLMError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: "Apple Intelligence isn't available. Turn it on in Settings to use Loom's AI features."
        }
    }
}
