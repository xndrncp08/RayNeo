import Foundation
import FoundationModels

enum AIStatus: Equatable, Sendable {
    case ready
    case unavailable(String)
    case disabled

    var label: String {
        switch self {
        case .ready: "Ready (on-device)"
        case .unavailable(let reason): "Unavailable: \(reason)"
        case .disabled: "Disabled"
        }
    }
}

struct AnswerRequest: Sendable {
    var instructions: String
    var prompt: String
    var maximumTokens: Int
}

/// Provider boundary so an optional online provider can be added later without touching the engine.
@MainActor protocol AIResponseProvider: AnyObject {
    var name: String { get }
    var status: AIStatus { get }
    func prewarm(instructions: String)
    /// Streams the cumulative answer text. Cancelling the consuming task cancels generation.
    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error>
    /// Semantic yes/no question check for borderline turns. nil = could not classify.
    func isInterviewQuestion(_ text: String) async -> Bool?
    /// Why the last stream ended, when the provider reports it (Gemini `finishReason`, e.g. STOP or MAX_TOKENS).
    var lastStopReason: String? { get }
}

extension AIResponseProvider {
    var name: String { "AI" }
    var lastStopReason: String? { nil }
}

/// Apple Foundation Models (on-device, free, no API key).
@MainActor final class FoundationModelsProvider: AIResponseProvider {
    let name = "Apple On-Device"
    private var warmSession: LanguageModelSession?
    private var warmInstructions = ""

    var status: AIStatus {
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.deviceNotEligible): return .unavailable("this device does not support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("turn on Apple Intelligence in Settings")
        case .unavailable(.modelNotReady): return .unavailable("model is still downloading")
        case .unavailable(let other): return .unavailable(String(describing: other))
        }
    }

    func prewarm(instructions: String) {
        guard status == .ready else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        warmSession = session
        warmInstructions = instructions
    }

    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        // Each question gets a fresh session: bounded context, no transcript growth across the interview.
        let session = (warmInstructions == request.instructions ? warmSession : nil) ?? LanguageModelSession(instructions: request.instructions)
        warmSession = nil
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: request.maximumTokens)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task { @MainActor [weak self] in
            do {
                for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
                    continuation.yield(snapshot.content)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            self?.prewarm(instructions: request.instructions)
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func isInterviewQuestion(_ text: String) async -> Bool? {
        guard status == .ready else { return nil }
        let session = LanguageModelSession(instructions: "You classify single utterances from a job interview. Reply with exactly one word: yes or no.")
        let prompt = "Is the following utterance a question or request that the interviewer expects the candidate to answer?\nUtterance: \"\(text.prefix(400))\""
        guard let reply = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: 3)) else { return nil }
        let answer = reply.content.lowercased()
        if answer.contains("yes") { return true }
        if answer.contains("no") { return false }
        return nil
    }
}

/// Explicit unavailable state: never silently substitutes a cloud provider.
@MainActor final class DisabledAIProvider: AIResponseProvider {
    let name = "Off"
    var status: AIStatus { .disabled }
    func prewarm(instructions: String) {}
    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIError.unavailable("AI generation is disabled in Settings")) }
    }
    func isInterviewQuestion(_ text: String) async -> Bool? { nil }
}

enum AIError: LocalizedError, Equatable {
    case unavailable(String)
    case emptyAnswer
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "AI unavailable: \(reason)"
        case .emptyAnswer: "The model returned an empty answer"
        }
    }
}

/// Local Gemma through Google's LiteRT-LM Swift runtime. NOT included in this build: the official SwiftPM
/// package (github.com/google-ai-edge/LiteRT-LM, product "LiteRTLM") ships its runtime through Git LFS,
/// which is not installed on the build Mac, and a `.litertlm` model must be supplied separately.
/// See Documentation/GEMMA.md. This provider only reports that state; it never generates text.
@MainActor final class GemmaProvider: AIResponseProvider {
    let name = "Gemma On-Device"
    static let blocker = "not included in this build (LiteRT-LM needs git-lfs to build; see GEMMA.md)"
    var status: AIStatus { .unavailable(Self.blocker) }
    func prewarm(instructions: String) {}
    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIError.unavailable(Self.blocker)) }
    }
    func isInterviewQuestion(_ text: String) async -> Bool? { nil }
}

/// Documented selection policy, never a cloud substitute:
/// - Auto: Gemma if it is ready, otherwise Apple On-Device.
/// - Gemma selected but unavailable: Apple On-Device, with the reason shown.
@MainActor final class FallbackAIProvider: AIResponseProvider {
    let preferred: any AIResponseProvider
    let fallback: any AIResponseProvider
    let explicitChoice: Bool

    init(preferred: any AIResponseProvider, fallback: any AIResponseProvider, explicitChoice: Bool) {
        self.preferred = preferred
        self.fallback = fallback
        self.explicitChoice = explicitChoice
    }

    private var active: any AIResponseProvider { preferred.status == .ready ? preferred : fallback }

    var name: String {
        if preferred.status == .ready { return preferred.name }
        if case .unavailable(let reason) = preferred.status, explicitChoice {
            return "\(fallback.name) (fallback: \(preferred.name) \(reason))"
        }
        return explicitChoice ? fallback.name : "Auto → \(fallback.name)"
    }

    var status: AIStatus { active.status }
    func prewarm(instructions: String) { active.prewarm(instructions: instructions) }
    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> { active.streamAnswer(request) }
    func isInterviewQuestion(_ text: String) async -> Bool? { await active.isInterviewQuestion(text) }
}
