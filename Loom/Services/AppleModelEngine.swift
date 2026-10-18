import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device Foundation Model can be used right now.
enum AppleModelAvailability: Equatable {
    case available
    /// Apple Intelligence is turned off in Settings.
    case notEnabled
    /// This device can't run Apple Intelligence.
    case deviceNotEligible
    /// The model is still downloading or preparing.
    case notReady
    /// Older OS without the FoundationModels framework.
    case unsupportedOS
    case unavailable

    var isAvailable: Bool { self == .available }
}

/// What the organizer asks the model for. Guided generation fills these fixed fields,
/// so titles, summaries and tags always fit their slots.
struct OrganizedFields {
    var title: String
    var summary: String
    var takeaways: [String]
    var tags: [String]
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "What is worth remembering from one saved item in a personal library")
struct GeneratedOrganization {
    @Guide(description: "A short descriptive title on one line, at most 8 words")
    var title: String

    @Guide(description: "Up to three sentences stating the main finding, argument or lesson, not a description of the document")
    var summary: String

    @Guide(description: "Short, specific lessons, facts, numbers or action items, one sentence each", .maximumCount(5))
    var takeaways: [String]

    @Guide(description: "Short lowercase topic tags", .maximumCount(5))
    var tags: [String]
}
#endif

/// Runs prompts on Apple's on-device Foundation Model (Apple Intelligence).
/// Every call checks availability first, so callers can fall back to a downloaded llama.cpp model.
enum AppleModelEngine {
    static var availability: AppleModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.appleIntelligenceNotEnabled):
                return .notEnabled
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.modelNotReady):
                return .notReady
            case .unavailable:
                return .unavailable
            }
        }
        #endif
        return .unsupportedOS
    }

    /// The Apple model's context window is small (about 4,096 tokens), so prompts are trimmed harder.
    static let inputBudgetCharacters = 6000

    /// Streams a plain-text answer. `onToken` receives the whole answer so far.
    static func generate(
        system: String,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        onToken: ((String) -> Void)?
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            let options = GenerationOptions(temperature: Double(temperature), maximumResponseTokens: maxTokens)
            var text = ""
            do {
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    try Task.checkCancellation()
                    text = snapshot.content
                    onToken?(text)
                }
            } catch let error as LanguageModelSession.GenerationError {
                throw AppleModelError(error)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw LLMError.notReady
    }

    /// Guided generation: the model fills a title, summary, takeaways and tags directly.
    static func organize(_ prompt: String, instructions: String) async throws -> OrganizedFields {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: prompt, generating: GeneratedOrganization.self,
                    options: GenerationOptions(temperature: 0.2))
                let g = response.content
                return OrganizedFields(title: g.title, summary: g.summary, takeaways: g.takeaways, tags: g.tags)
            } catch let error as LanguageModelSession.GenerationError {
                throw AppleModelError(error)
            }
        }
        #endif
        throw LLMError.notReady
    }
}

/// Calm, one-line versions of the Foundation Models errors.
struct AppleModelError: LocalizedError {
    let message: String

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    init(_ error: LanguageModelSession.GenerationError) {
        switch error {
        case .exceededContextWindowSize:
            message = "That was too much text for Apple Intelligence at once. Try a shorter question."
        case .guardrailViolation:
            message = "Apple Intelligence couldn't answer that one."
        case .unsupportedLanguageOrLocale:
            message = "Apple Intelligence doesn't support this language yet."
        case .assetsUnavailable:
            message = "The model is getting ready…"
        default:
            message = error.localizedDescription
        }
    }
    #endif

    var errorDescription: String? { message }
}
