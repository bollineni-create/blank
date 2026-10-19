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

    /// Re-reads Apple Intelligence availability. While the model is getting ready, checks again shortly.
    func refreshAppleAvailability() {
        guard !applePaused else { return }
        appleAvailability = AppleModelEngine.availability
        availabilityRecheck?.cancel()
        guard appleAvailability == .notReady else { return }
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
            return try await AppleModelEngine.generate(
                system: system, prompt: prompt, maxTokens: maxTokens, temperature: temperature, onToken: onToken)
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
            return try await AppleModelEngine.organize(prompt, instructions: instructions)
        } catch let error as AppleModelError where error.isRuntimeFailure {
            pauseAppleModel()
            throw error
        }
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
