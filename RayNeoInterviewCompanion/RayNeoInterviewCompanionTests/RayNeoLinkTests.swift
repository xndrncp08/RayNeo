import Foundation
import Testing
@testable import RayNeoInterviewCompanion

@MainActor final class FakeLinkIO: RayNeoLinkIO {
    weak var owner: RayNeoBluetoothDisplay?
    private(set) var startCount = 0, cancelCount = 0, readCount = 0, subscribeCount = 0
    private(set) var written = Data()
    func start() { startCount += 1 }
    func cancel() { cancelCount += 1 }
    func readPairInfo() { readCount += 1 }
    func subscribe() { subscribeCount += 1 }
    func write(_ frame: Data) { written.append(frame) }
    var sent: [RayNeoProtocol.Message] { var buffer = written; return RayNeoProtocol.extractFrames(from: &buffer) }
    func sent(business: UInt8, type: UInt64) -> [RayNeoProtocol.Message] { sent.filter { $0.businessID == business && $0.type == type } }
}

@MainActor final class ManualScheduler {
    private(set) var pending: [@MainActor () -> Void] = []
    func schedule(_ seconds: Double, _ work: @escaping @MainActor () -> Void) { pending.append(work) }
    func fireAll() { let work = pending; pending = []; work.forEach { $0() } }
}

/// Hardware-free tests of the RayNeo link/session state machine. They prove protocol handling,
/// not that anything is visible on real glasses.
@MainActor @Suite(.serialized) struct RayNeoLinkTests {
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

    func authenticate() throws {
        display.connect()
        display.ioFound(name: "RayNeo iO-E081", identifier: UUID(), summary: "test")
        display.ioConnected(mtu: 512)
        display.ioDiscovered(services: ["B81D"], characteristics: ["EA8B70D5", "7DB3E235", "EA8B60C5"], complete: true)
        display.ioPairInfo(classic + Data([2]) + bound)
        display.ioNotify(enabled: true, error: nil)
        display.ioReceived(try RayNeoProtocol.pairingFrame(sequence: 0, command: 17, fields: [(16, Data([1]))]))
        let random = Data([9, 8, 7, 6])
        let proof = RayNeoProtocol.authDigest(random: random, deviceID: bound, classicAddress: classic)
        display.ioReceived(try RayNeoProtocol.pairingFrame(sequence: 1, command: 25, fields: [(16, random), (17, proof)]))
    }

    var startedSID: String? {
        let starts = io.sent(business: 0x13, type: 7) + io.sent(business: 0x17, type: 1)
        return starts.last?.json?["sid"] as? String
    }

    func reply(_ business: UInt8, type: UInt64, _ json: [String: Any]) throws {
        display.ioReceived(try RayNeoProtocol.businessFrame(business: business, sequence: 50, type: type, json: json))
    }

    @Test func captionSessionHappyPathSendsHello() async throws {
        try authenticate()
        #expect(display.authenticated)
        #expect(display.connectionState == .startingSession)
        // Foreground visibility (verified OpenRayneo/official frame) precedes the session start.
        let order = io.sent.map { "\($0.businessID)-\($0.payload.first ?? 0)-\($0.type ?? 99)" }
        let visibility = try #require(order.firstIndex(of: "16-31-99"))
        let start = try #require(order.firstIndex { $0.hasPrefix("19-") })
        #expect(visibility < start)
        let sid = try #require(startedSID)
        let config = io.sent(business: 0x13, type: 7).last?.json?["config"] as? [String: AnyHashable]
        #expect(config?["max_lines"] as? Int == 5)

        try reply(0x13, type: 8, ["sid": sid, "code": 1])
        #expect(display.connectionState == .ready)
        #expect(display.sessionAck == .confirmed)

        try await display.sendTestCaption(allowUnconfirmed: false)
        let text = try #require(io.sent(business: 0x13, type: 5).last?.json)
        #expect((text["content"] as? [String: AnyHashable])?["source_transcript"] as? String == "HELLO FROM IPHONE")
        #expect(text["mode"] as? Int == 3)
        #expect(text["status"] as? Int == 1)
        #expect(text["sid"] as? String == sid)
    }

    @Test func missingAcknowledgementIsUnconfirmedNotReady() async throws {
        try authenticate()
        scheduler.fireAll() // session acknowledgement timeout
        #expect(display.connectionState == .sessionUnconfirmed)
        #expect(display.sessionAck == .unconfirmed)
        #expect(!display.isReadyToSend)
        await #expect(throws: GlassesError.notReady) { try await display.show("x") }
        #expect(io.sent(business: 0x13, type: 5).isEmpty)

        try await display.sendTestCaption(allowUnconfirmed: true) // explicit experimental override
        #expect(io.sent(business: 0x13, type: 5).count == 1)
        #expect(!display.allowUnconfirmedSend) // override does not persist
    }

    @Test func rejectionKeepsLinkAndDoesNotRetry() throws {
        try authenticate()
        let sid = try #require(startedSID)
        let cancels = io.cancelCount
        try reply(0x13, type: 8, ["sid": sid, "code": 3])
        #expect(display.connectionState == .sessionRejected("code 3"))
        #expect(display.sessionAck == .rejected(3))
        #expect(io.cancelCount == cancels)
        scheduler.fireAll()
        #expect(io.sent(business: 0x13, type: 7).count == 1)
    }

    @Test func staleSessionIDIsIgnored() throws {
        try authenticate()
        try reply(0x13, type: 8, ["sid": "someone-elses-session", "code": 1])
        #expect(display.connectionState == .startingSession)
    }

    @Test func glassesClosingSessionDoesNotAutoRestart() throws {
        try authenticate()
        let sid = try #require(startedSID)
        try reply(0x13, type: 8, ["sid": sid, "code": 1])
        try reply(0x13, type: 3, ["sid": sid, "reason_code": 10])
        #expect(display.connectionState == .authenticated)
        #expect(display.sessionAck == .closedByGlasses("reason_code 10"))
        scheduler.fireAll()
        #expect(io.sent(business: 0x13, type: 7).count == 1)
    }

    @Test func rapidConnectTapsDoNotRestartAttempt() throws {
        display.connect(); display.connect(); display.connect()
        #expect(io.startCount == 1)
        try authenticate() // includes another connect() while in progress
        display.connect()
        #expect(io.startCount == 1)
        #expect(io.cancelCount == 0)
    }

    @Test func duplicateSessionStartIsIgnored() throws {
        try authenticate()
        display.startDisplaySession()
        #expect(io.sent(business: 0x13, type: 7).count == 1)
    }

    @Test func restartingSessionClosesThePreviousOne() throws {
        try authenticate()
        let first = try #require(startedSID)
        try reply(0x13, type: 8, ["sid": first, "code": 1])
        display.startDisplaySession()
        #expect(io.sent(business: 0x13, type: 3).last?.json?["sid"] as? String == first)
        #expect(startedSID != first)
    }

    @Test func reconnectIsBounded() {
        display.connect()
        for _ in 0..<50 where !scheduler.pending.isEmpty { scheduler.fireAll() }
        #expect(io.startCount == 1 + RayNeoBluetoothDisplay.maxReconnectAttempts)
        #expect(scheduler.pending.isEmpty)
        if case .failed = display.connectionState {} else { Issue.record("expected failed, got \(display.connectionState)") }
    }

    @Test func staleTimersAfterDisconnectDoNothing() {
        display.connect()
        display.disconnect()
        scheduler.fireAll()
        #expect(display.connectionState == .disconnected)
        #expect(io.startCount == 1)
    }

    @Test func disconnectDeliversCloseBeforeCancellingLink() throws {
        try authenticate()
        let sid = try #require(startedSID)
        try reply(0x13, type: 8, ["sid": sid, "code": 1])
        let cancels = io.cancelCount
        display.disconnect()
        let close = try #require(io.sent(business: 0x13, type: 3).last?.json)
        #expect(close["sid"] as? String == sid)
        #expect(close["reason_code"] as? Int == 10)
        #expect(io.cancelCount == cancels) // cancel is delayed so the close frame can leave
        scheduler.fireAll()
        #expect(io.cancelCount == cancels + 1)
        #expect(display.connectionState == .disconnected)
    }

    @Test func promptModeUsesItsOwnMessages() throws {
        display.sessionMode = .prompt
        try authenticate()
        let sid = try #require(startedSID)
        #expect(io.sent(business: 0x17, type: 1).count == 1)
        try reply(0x13, type: 8, ["sid": sid, "code": 1]) // caption ack must not confirm a prompt session
        #expect(display.connectionState == .startingSession)
        try reply(0x17, type: 2, ["sid": sid, "code": 1])
        #expect(display.connectionState == .ready)
    }

    @Test func transportDropReconnectsAndPresenterRestoresAnswer() async throws {
        let presenter = GlassesPresenter(display: display)
        try authenticate()
        try reply(0x13, type: 8, ["sid": try #require(startedSID), "code": 1])
        await presenter.present("Check the logs first. Then verify the token.")
        #expect(io.sent(business: 0x13, type: 5).count == 1)

        display.ioDisconnected(error: "out of range")
        #expect(display.connectionState == .disconnected)
        #expect(presenter.currentPage != nil)
        scheduler.fireAll() // reconnect
        #expect(io.startCount == 2)
        try authenticate()
        try reply(0x13, type: 8, ["sid": try #require(startedSID), "code": 1])
        try await Task.sleep(for: .milliseconds(50))
        let texts = io.sent(business: 0x13, type: 5).compactMap { ($0.json?["content"] as? [String: AnyHashable])?["source_transcript"] as? String }
        #expect(texts == ["Check the logs first. Then verify the token.", "Check the logs first. Then verify the token."])
    }

    @Test func presenterDoesNotSendOnUnconfirmedSession() async throws {
        let presenter = GlassesPresenter(display: display)
        try authenticate()
        scheduler.fireAll()
        await presenter.present("Answer")
        #expect(io.sent(business: 0x13, type: 5).isEmpty)
        #expect(presenter.lastError?.contains("UNCONFIRMED") == true)
    }

    // AI answer forwarding + answer lock, end to end through the real BLE session logic.
    @Test func aiAnswersReachTheLinkAndWearerSpeechDoesNotRewrite() async throws {
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        let ai = MockAIProvider()
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        try authenticate()
        try reply(0x13, type: 8, ["sid": try #require(startedSID), "code": 1])
        engine.start()

        await engine.handle(CompletedTurn(text: "How would you investigate a failed integration?", start: 0, end: 2))
        await engine.generationTask?.value
        let captions = io.sent(business: 0x13, type: 5).count
        #expect(captions >= 1 && captions <= 2) // first sentence, then the completed frame

        await engine.handle(CompletedTurn(text: "First, I would check the API logs and verify whether the request is reaching the backend.", start: 3, end: 6))
        await engine.generationTask?.value
        await presenter.present(ai.answer) // identical re-present must not cause another write
        #expect(io.sent(business: 0x13, type: 5).count == captions)
        #expect(engine.state == .answerLocked)
    }

    @Test func savedSettingsWithoutNewFieldsKeepUserChoices() throws {
        let old = #"{"glassesTarget":"rayNeoExperimental","answerLength":"short"}"#
        let settings = try #require(AppSettings.decodeMerged(Data(old.utf8)))
        #expect(settings.glassesTarget == .rayNeoExperimental)
        #expect(settings.answerLength == .short)
        #expect(settings.glassesSessionMode == .caption)
    }
}
