import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Answer forwarding over the caption transport in compatibility mode (unacknowledged sessions).
/// Hardware-free: proves what is written to the link, not what is visible.
@MainActor @Suite(.serialized) struct RayNeoPipelineTests {
    let io = FakeLinkIO()
    let scheduler = ManualScheduler()
    let display: RayNeoBluetoothDisplay
    let classic = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
    let bound = Data([0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6])

    init() {
        let scheduler = self.scheduler
        display = RayNeoBluetoothDisplay(io: io, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                         schedule: { scheduler.schedule($0, $1) })
    }

    /// Mirrors the real iO-E081: authentication succeeds, the caption start is never acknowledged.
    func authenticateUnacknowledged() throws {
        display.connect()
        display.ioFound(name: "RayNeo iO-E081", identifier: UUID(), summary: "test")
        display.ioConnected(mtu: 512)
        display.ioDiscovered(services: ["B81D"], characteristics: ["EA8B70D5", "7DB3E235", "EA8B60C5"], complete: true)
        display.ioPairInfo(classic + Data([2]) + bound)
        display.ioNotify(enabled: true, error: nil)
        display.ioReceived(try RayNeoProtocol.pairingFrame(sequence: 0, command: 17, fields: [(16, Data([1]))]))
        let random = Data([9, 8, 7, 6])
        display.ioReceived(try RayNeoProtocol.pairingFrame(sequence: 1, command: 25, fields: [
            (16, random), (17, RayNeoProtocol.authDigest(random: random, deviceID: bound, classicAddress: classic))]))
        scheduler.fireAll() // acknowledgement timeout
    }

    var captionTexts: [String] {
        io.sent(business: 0x13, type: 5).compactMap { ($0.json?["content"] as? [String: AnyHashable])?["source_transcript"] as? String }
    }

    func makeEngine(_ presenter: GlassesPresenter, _ ai: MockAIProvider) -> ConversationEngine {
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        return engine
    }

    @Test func compatibilityModeForwardsAnswersAutomatically() async throws {
        display.allowUnconfirmedSend = true
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        let ai = MockAIProvider()
        let engine = makeEngine(presenter, ai)
        try authenticateUnacknowledged()
        #expect(display.connectionState == .sessionUnconfirmed)
        #expect(display.isReadyToSend)

        await engine.handle(CompletedTurn(text: "How would you investigate a failed integration?", start: 0, end: 2))
        await engine.generationTask?.value
        #expect(captionTexts == [ai.answer + " \u{2713}"])
        #expect(presenter.deliveryStatus.contains("compatibility mode"))
        #expect(engine.state == .answerLocked)
    }

    @Test func withoutCompatibilityModeAnswerIsHeldThenSentWhenEnabled() async throws {
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        try authenticateUnacknowledged()
        await presenter.present("Held answer.")
        #expect(captionTexts.isEmpty)
        #expect(presenter.deliveryStatus.contains("held"))

        display.allowUnconfirmedSend = true // same state, but now sendable: the held page is restored
        try await Task.sleep(for: .milliseconds(50))
        #expect(captionTexts == ["Held answer."])
    }

    @Test func compatibilityModeNeverAppliesToPromptSessions() throws {
        display.sessionMode = .prompt
        display.allowUnconfirmedSend = true
        try authenticateUnacknowledged()
        #expect(display.connectionState == .sessionUnconfirmed)
        #expect(!display.isReadyToSend)
    }

    @Test func sessionClosedByGlassesIsReopenedOnlyForNewText() async throws {
        display.allowUnconfirmedSend = true
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        try authenticateUnacknowledged()
        let sid = try #require(io.sent(business: 0x13, type: 7).last?.json?["sid"] as? String)
        display.ioReceived(try RayNeoProtocol.businessFrame(business: 0x13, sequence: 9, type: 3, json: ["sid": sid, "reason_code": 10]))
        #expect(display.connectionState == .authenticated)
        scheduler.fireAll()
        #expect(io.sent(business: 0x13, type: 7).count == 1) // no restart by itself

        await presenter.present("New answer.")
        #expect(io.sent(business: 0x13, type: 7).count == 2) // reopened once for the new text
        await presenter.present("New answer.") // still starting: no duplicate start
        #expect(io.sent(business: 0x13, type: 7).count == 2)
        scheduler.fireAll() // no acknowledgement → unconfirmed → compatibility mode restores the page
        try await Task.sleep(for: .milliseconds(50))
        #expect(captionTexts == ["New answer."])
    }

    @Test func pipelineEventsAreInTheDiagnosticTimeline() async throws {
        DiagnosticLog.shared.clear()
        display.allowUnconfirmedSend = true
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        let engine = makeEngine(presenter, MockAIProvider())
        try authenticateUnacknowledged()
        await engine.handle(CompletedTurn(text: "What is a REST API?", start: 0, end: 2))
        await engine.generationTask?.value
        let pipeline = DiagnosticLog.shared.entries.filter { $0.category == .pipeline }.map(\.message)
        #expect(pipeline.contains { $0.hasPrefix("Question detected") })
        let id = try #require(engine.currentAnswer?.answerID)
        #expect(pipeline.contains { $0.hasPrefix("Caption write: answer #\(id), gen 1, window, window 1/1") })
        #expect(pipeline.contains { $0.hasPrefix("Answer displayed") })
    }

    /// Full app path: mic start never disturbs an established glasses link, and a spoken question
    /// ends up as caption text without any manual send.
    @Test func appSessionForwardsSpokenQuestionOverExistingLink() async throws {
        let audio = MockAudio(), speech = MockSpeech(), ai = MockAIProvider()
        let display = self.display
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var settings = AppSettings()
        settings.glassesTarget = .rayNeoExperimental
        settings.allowUnconfirmedGlassesSend = true
        settings.semanticClassification = false
        settings.captionLayout = CaptionLayout(maxLines: 20, charactersPerLine: 40)
        defaults.set(try JSONEncoder().encode(settings), forKey: "appSettings.v1")
        let model = AppModel(defaults: defaults, audio: audio, speechFactory: { [speech] }, aiFactory: { _ in ai },
                             glassesFactory: { _ in display }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        #expect(display.allowUnconfirmedSend)

        try authenticateUnacknowledged()
        let starts = io.startCount, cancels = io.cancelCount
        await model.startSession()
        #expect(audio.isRunning)
        #expect(io.startCount == starts && io.cancelCount == cancels) // link untouched by mic start
        #expect(display.connectionState == .sessionUnconfirmed)

        speech.onEvent?(.final("How do you troubleshoot a Microsoft 365 login issue?", start: 0, end: 3))
        await model.tick(now: Date().addingTimeInterval(5))
        await model.engine.generationTask?.value
        #expect(LensModel.visibleText(captionTexts).joined(separator: " ") == ai.answer) // Sentence Frames default
    }

    func control(_ reason: Int?, sid: String) throws {
        var json: [String: Any] = ["sid": sid, "text": ""]
        if let reason { json["reason_code"] = reason }
        display.ioReceived(try RayNeoProtocol.businessFrame(business: 0x13, sequence: 77, type: 3, json: json))
    }

    /// Regression for the real-device failure: HELLO works right after connecting, but later AI answers
    /// never appear. A type-3 PAUSE (reason 8/12) used to be treated as a close: the session ID was dropped,
    /// the later RESUME was ignored as "another session", and the answer went to a newly started session
    /// the glasses never opened.
    @Test func pausedThenResumedSessionDeliversHeldAnswerOnTheOriginalSession() async throws {
        display.allowUnconfirmedSend = true
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        try authenticateUnacknowledged()
        let sid = try #require(io.sent(business: 0x13, type: 7).last?.json?["sid"] as? String)
        try await display.sendTestCaption(allowUnconfirmed: false) // compatibility mode on: no override needed
        #expect(captionTexts == ["HELLO FROM IPHONE"])

        try control(12, sid: sid) // glasses pause (e.g. display asleep)
        #expect(display.connectionState == .sessionPaused("reason_code 12"))
        #expect(display.sessionID == sid)

        await presenter.present("AI answer.")
        #expect(captionTexts == ["HELLO FROM IPHONE"]) // held while paused
        #expect(io.sent(business: 0x13, type: 7).count == 1) // no competing new session

        try control(13, sid: sid) // glasses resume
        #expect(display.connectionState == .sessionUnconfirmed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(captionTexts == ["HELLO FROM IPHONE", "AI answer."])
        #expect(io.sent(business: 0x13, type: 5).allSatisfy { $0.json?["sid"] as? String == sid })
    }

    @Test func nonClosingControlMessagesKeepTheSession() throws {
        display.allowUnconfirmedSend = true
        try authenticateUnacknowledged()
        let sid = try #require(io.sent(business: 0x13, type: 7).last?.json?["sid"] as? String)
        try control(nil, sid: sid)
        try control(17, sid: sid)  // weak network
        try control(99, sid: sid)  // unknown
        try control(9, sid: sid)   // resume while not paused
        #expect(display.connectionState == .sessionUnconfirmed)
        #expect(display.sessionID == sid)
        try control(10, sid: sid)  // a real close
        #expect(display.connectionState == .authenticated)
        #expect(display.sessionID == nil)
    }

    @Test func confirmedSessionResumesToReady() throws {
        try authenticateUnacknowledged()
        let sid = try #require(io.sent(business: 0x13, type: 7).last?.json?["sid"] as? String)
        display.ioReceived(try RayNeoProtocol.businessFrame(business: 0x13, sequence: 60, type: 8, json: ["sid": sid, "code": 1]))
        try control(8, sid: sid)
        #expect(!display.isReadyToSend)
        try control(9, sid: sid)
        #expect(display.connectionState == .ready)
    }

    @Test func compatibilityOffExplainsWhyAnswerIsHeld() async throws {
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        try authenticateUnacknowledged()
        await presenter.present("Held.")
        #expect(presenter.deliveryStatus.contains("Caption compatibility mode is OFF"))
        #expect(captionTexts.isEmpty)
    }

    @Test func aiAnswerUsesTheSameFrameShapeAsTheVerifiedTestCaption() async throws {
        display.allowUnconfirmedSend = true
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        try authenticateUnacknowledged()
        try await display.sendTestCaption(allowUnconfirmed: false)
        await presenter.present("AI answer.")
        let frames = io.sent(business: 0x13, type: 5)
        #expect(frames.count == 2)
        let hello = try #require(frames.first?.json), answer = try #require(frames.last?.json)
        #expect(Set(hello.keys) == Set(answer.keys))
        #expect(hello["sid"] == answer["sid"])
        #expect(hello["mode"] == answer["mode"] && hello["status"] == answer["status"])
    }

    @Test func exportableTimelineContainsNoConversationText() async throws {
        DiagnosticLog.shared.clear()
        display.allowUnconfirmedSend = true
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        let ai = MockAIProvider()
        let engine = makeEngine(presenter, ai)
        try authenticateUnacknowledged()
        await engine.handle(CompletedTurn(text: "How would you investigate a failed Salesforce integration?", start: 0, end: 2))
        await engine.generationTask?.value
        let text = DiagnosticLog.shared.text
        #expect(!text.contains("Salesforce"))
        #expect(!text.contains("API logs"))
        for event in ["Question detected", "Answer generated", "Presenter invoked", "Caption write: answer #", "handed to", "Answer lock activated"] {
            #expect(text.contains(event), "missing \(event)")
        }
    }
}
