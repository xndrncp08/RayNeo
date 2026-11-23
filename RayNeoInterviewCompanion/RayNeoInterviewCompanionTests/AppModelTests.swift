import Foundation
import SwiftUI
import Testing
@testable import RayNeoInterviewCompanion

/// End-to-end pipeline with mocked hardware: speech events → turn detection → engine → glasses.
@MainActor @Suite struct AppModelTests {
    let audio = MockAudio()
    let speech = MockSpeech()
    let ai = MockAIProvider()
    let glasses = MockGlassesDisplay()
    let model: AppModel

    init() {
        let speech = self.speech, ai = self.ai, glasses = self.glasses
        model = AppModel(defaults: nil, audio: audio, speechFactory: { [speech] }, aiFactory: { _ in ai },
                         glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.settings.semanticClassification = false
    }

    @Test func fullPipelineAnswersSpokenQuestion() async {
        await model.startSession()
        #expect(model.sessionActive)
        #expect(audio.isRunning)
        #expect(model.engine.state == .listening)
        #expect(glasses.connectionState == .ready)

        speech.onEvent?(.partial("How do you troubleshoot"))
        speech.onEvent?(.final("How do you troubleshoot a Microsoft 365 login issue?", start: 0, end: 3))
        await model.tick(now: Date().addingTimeInterval(5))
        await model.engine.generationTask?.value
        #expect(model.transcript.segments.count == 1)
        #expect(Streaming.settled(glasses.shown).count == 1) // first sentence, then the completed frame
        // Default Sentence Frames: the frame's rows show the answer from its first word.
        #expect(LensModel.visibleText(glasses.shown).first?.hasPrefix("First, I would check the API logs") == true)
        #expect(model.presenter.plan?.sections.map(\.text).joined(separator: " ") == ai.answer)
        #expect(model.engine.state == .answerLocked)
    }

    // Case 12: recognition fails temporarily and is restarted without stopping the microphone.
    @Test func recognitionFailureRestartsRecognizer() async throws {
        await model.startSession()
        speech.onEvent?(.failed("transient"))
        try await Task.sleep(for: .milliseconds(1500))
        #expect(speech.startCount == 2)
        #expect(audio.isRunning)
        #expect(model.diagnostics.recognitionRestarts == 1)
    }

    // Cases 15–16: stopping turns the microphone off immediately and tears everything down.
    @Test func stopSessionStopsCapture() async {
        await model.startSession()
        await model.stopSession()
        #expect(!audio.isRunning)
        #expect(audio.stopCount == 1)
        #expect(speech.stopCount == 1)
        #expect(model.engine.state == .idle)
        #expect(glasses.connectionState == .disconnected)
        speech.onEvent?(.final("What is a REST API?", start: 0, end: 1))
        #expect(model.transcript.segments.isEmpty)
    }

    // Case 18: background/foreground transitions keep the session running.
    @Test func backgroundTransitionKeepsSession() async {
        await model.startSession()
        model.handleScenePhase(.background)
        #expect(model.sessionActive)
        #expect(audio.isRunning)
        model.handleScenePhase(.active)
        #expect(!model.speechStatus.contains("background"))
    }

    @Test func permissionDeniedDoesNotStartMicrophone() async {
        let denied = AppModel(defaults: nil, audio: audio, speechFactory: { [speech] }, aiFactory: { _ in ai },
                              glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { "Microphone access is off." })
        await denied.startSession()
        #expect(!denied.sessionActive)
        #expect(audio.startCount == 0)
        #expect(denied.lastError == "Microphone access is off.")
    }

    @Test func recognizerUnavailableFallsBackToNextEngine() async {
        let broken = MockSpeech()
        broken.prepareError = TestError()
        let working = speech
        let fallback = AppModel(defaults: nil, audio: audio, speechFactory: { [broken, working] }, aiFactory: { _ in ai },
                                glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        await fallback.startSession()
        #expect(fallback.sessionActive)
        #expect(working.startCount == 1)
        #expect(broken.startCount == 0)
    }

    @Test func audioInterruptionIsReported() async {
        await model.startSession()
        audio.onEvent?(.interrupted)
        #expect(model.micStatus.contains("Interrupted"))
        audio.onEvent?(.resumed)
        #expect(model.micStatus == "Listening")
    }
}
