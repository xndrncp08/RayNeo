import AVFoundation
import Foundation
@testable import RayNeoInterviewCompanion

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
}

@MainActor final class MockAIProvider: AIResponseProvider {
    var status: AIStatus = .ready
    var answer = "First, I would check the API logs and verify whether the request is reaching the backend. Then I would compare the payload with the expected schema and retry the failed records."
    var perWordDelay: Duration = .zero
    var failure: Error?
    var semanticAnswer: Bool?
    /// Simulated provider stop reason (e.g. "MAX_TOKENS"); nil like Apple's provider.
    var stopReason: String?
    var lastStopReason: String? { stopReason }
    /// Answers used one per request before falling back to `answer` (regeneration tests).
    var queuedAnswers: [String] = []
    private(set) var requests: [AnswerRequest] = []

    func prewarm(instructions: String) {}

    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let text = queuedAnswers.isEmpty ? answer : queuedAnswers.removeFirst()
        // Keep empty pieces so runs of spaces (code indentation) survive streaming.
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let delay = perWordDelay, failure = failure
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure { continuation.finish(throwing: failure); return }
                var text = ""
                var first = true
                for word in words {
                    if delay != .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    text += first ? word : " " + word
                    first = false
                    continuation.yield(text)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func isInterviewQuestion(_ text: String) async -> Bool? { semanticAnswer }
}

@MainActor final class MockAudio: AudioCapturing {
    private(set) var isRunning = false
    var inputName = "iPhone Microphone"
    var onEvent: ((AudioEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?

    func availableInputs() -> [AudioInputOption] { [AudioInputOption(id: "builtin", name: "iPhone Microphone")] }

    func start(format: AVAudioFormat, preferredInputUID: String?, handler: @escaping AudioBufferHandler) throws {
        if let startError { throw startError }
        startCount += 1
        isRunning = true
    }

    func stop() { stopCount += 1; isRunning = false }
}

@MainActor final class MockSpeech: SpeechRecognizing {
    let engineName = "Mock recognizer"
    var prepareError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var onEvent: (@MainActor (SpeechEvent) -> Void)?

    func prepare(locale: Locale) async throws -> AVAudioFormat {
        if let prepareError { throw prepareError }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    func start(onEvent: @escaping @MainActor (SpeechEvent) -> Void) throws {
        startCount += 1
        self.onEvent = onEvent
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition) {}

    func stop() async { stopCount += 1 }
}

struct TestError: LocalizedError { var errorDescription: String? { "test failure" } }

/// Sentence-level streaming shows the first sentence first and then the completed frame. These helpers
/// collapse that growth: a caption whose visible words are a prefix of the next one's was superseded.
enum Streaming {
    static func visible(_ caption: String) -> String {
        LensModel.visibleText([caption], rowWidth: 400).joined(separator: " ")
    }

    /// The captions that were not later grown by appending (one per frame actually shown).
    static func settled(_ captions: [String]) -> [String] {
        captions.enumerated().filter { index, caption in
            index == captions.count - 1 || !(visible(captions[index + 1]).hasPrefix(visible(caption)) && visible(captions[index + 1]) != visible(caption))
        }.map(\.element)
    }
}
