import Foundation
import Speech
import Testing
@testable import RayNeoInterviewCompanion

/// Regression for the device crash `_dispatch_assert_queue_fail` in
/// "closure #1 in closure #1 in static AppModel.requestPermissions()": SFSpeechRecognizer calls its
/// authorization handler on a background queue, and a handler that inherited @MainActor trapped.
@MainActor @Suite(.serialized) struct PermissionCallbackTests {
    @Test func authorizationCompletingOnBackgroundQueueDoesNotTrap() async {
        let status = await AppModel.speechAuthorization { handler in
            DispatchQueue.global(qos: .default).async { handler(.authorized) }
        }
        #expect(status == .authorized)
    }

    @Test func authorizationCompletingOnMainQueueStillWorks() async {
        let status = await AppModel.speechAuthorization { handler in
            DispatchQueue.main.async { handler(.denied) }
        }
        #expect(status == .denied)
    }

    @Test func authorizationCompletingSynchronouslyResumesOnce() async {
        let status = await AppModel.speechAuthorization { handler in handler(.restricted) }
        #expect(status == .restricted)
    }

    /// Real framework path (the exact call that crashed). Runs when the simulator has speech and
    /// microphone pre-granted; otherwise the system prompt would block the test, so it is skipped.
    @Test(.enabled(if: SFSpeechRecognizer.authorizationStatus() == .authorized))
    func realPermissionRequestCompletesWithoutTrapping() async {
        #expect(await AppModel.requestPermissions() == nil)
    }

    @Test func concurrentStartRequestsStartCaptureOnce() async {
        let audio = MockAudio(), speech = MockSpeech(), ai = MockAIProvider(), glasses = MockGlassesDisplay()
        let model = AppModel(defaults: nil, audio: audio, speechFactory: { [speech] }, aiFactory: { _ in ai },
                             glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil),
                             permissions: { try? await Task.sleep(for: .milliseconds(50)); return nil })
        async let first: Void = model.startSession()
        async let second: Void = model.startSession()
        _ = await (first, second)
        #expect(audio.startCount == 1)
        #expect(speech.startCount == 1)
        #expect(model.sessionActive)
    }

    @Test func stopDuringStartupCancelsStart() async {
        let audio = MockAudio(), speech = MockSpeech(), ai = MockAIProvider(), glasses = MockGlassesDisplay()
        let model = AppModel(defaults: nil, audio: audio, speechFactory: { [speech] }, aiFactory: { _ in ai },
                             glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil),
                             permissions: { try? await Task.sleep(for: .milliseconds(100)); return nil })
        let start = Task { await model.startSession() }
        try? await Task.sleep(for: .milliseconds(20))
        await model.stopSession()
        await start.value
        #expect(!model.sessionActive)
        #expect(audio.startCount == 0)
    }
}
