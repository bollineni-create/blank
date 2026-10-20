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

    /// How long one call may take. Apple's model answers in seconds, so a call that runs this long has hung.
    /// Without a limit, one hung call held the organizing queue forever: everything behind it sat at
    /// "Queued for summary…" with nothing to show why, and Ask waited on the same stuck call.
    static let organizeTimeout: Duration = .seconds(120)
    static let answerTimeout: Duration = .seconds(240)
    /// Hung calls back to back: the model itself is stuck, so pause it instead of timing out item after item.
    private var timeoutsInARow = 0

    /// Re-reads Apple Intelligence availability. While the model is getting ready (or away for a reason the
    /// system doesn't name), checks again shortly, so queued work carries on once it's back.
    func refreshAppleAvailability() {
        guard !applePaused else { return }
        appleAvailability = AppleModelEngine.availability
        availabilityRecheck?.cancel()
        guard appleAvailability == .notReady || appleAvailability == .unavailable else { return }
        scheduleAvailabilityRecheck(after: 20)
    }

    /// Set after Apple's model fails at runtime even though the system reported it available.
    private var applePaused = false

    /// Treats Apple's model as "getting ready" for a minute, so work waits instead of failing over and over.
    private func pauseAppleModel() {
        applePaused = true
        appleAvailability = .notReady
        scheduleAvailabilityRecheck(after: 60)
    }

    private func scheduleAvailabilityRecheck(after seconds: Int) {
        availabilityRecheck?.cancel()
        availabilityRecheck = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.applePaused = false
            self.refreshAppleAvailability()
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
        guard isReady else { throw LLMError.notReady }
        isGenerating = true
        defer { isGenerating = false }
        do {
            let answer = try await withDeadline(Self.answerTimeout) {
                try await AppleModelEngine.generate(
                    system: system, prompt: prompt, maxTokens: maxTokens, temperature: temperature, onToken: onToken)
            }
            timeoutsInARow = 0
            return answer
        } catch is ModelTimeout {
            throw timedOut()
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
            let fields = try await withDeadline(Self.organizeTimeout) {
                try await AppleModelEngine.organize(prompt, instructions: instructions)
            }
            timeoutsInARow = 0
            return fields
        } catch is ModelTimeout {
            throw timedOut()
        } catch let error as AppleModelError where error.isRuntimeFailure {
            pauseAppleModel()
            throw error
        }
    }

    /// A call ran past its deadline. The second in a row pauses the model for a minute, so the rest of the
    /// queue waits for it instead of each item spending the full deadline to fail.
    private func timedOut() -> AppleModelError {
        timeoutsInARow += 1
        if timeoutsInARow >= 2 {
            timeoutsInARow = 0
            pauseAppleModel()
        }
        return .timedOut
    }
}

/// Thrown by `withDeadline` when the work doesn't finish in time.
struct ModelTimeout: Error {}

/// Runs `work`, giving up after `limit`. On timeout the work is cancelled and left behind: a system call that
/// ignores cancellation finishes (or stays hung) on its own, without holding the caller. Structured task groups
/// can't do this, because they wait for every child to end before returning.
func withDeadline<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
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

    func start(_ continuation: CheckedContinuation<T, Error>, limit: Duration, work: @escaping @Sendable () async throws -> T) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        let job = Task {
            let result: Result<T, Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            self.finish(result)
        }
        let clock = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self.finish(.failure(ModelTimeout()))
        }
        lock.lock()
        self.work = job
        self.timer = clock
        lock.unlock()
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
