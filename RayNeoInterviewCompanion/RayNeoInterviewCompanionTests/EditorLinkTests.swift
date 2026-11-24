import CryptoKit
import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Values produced by Tools/vscode-code-tutor/protocol.js (and asserted by its Node tests).
enum EditorVectors {
    static let serverPublic = "pOCSkrZRwni5dyxWn1+puxPZBrRqtoyd+dwrRAn4ogk="
    static let clientPublic = "zo060cy2M+x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk="
    static let pairMac = "/7kWSiJlvf874gl0pgCxonECiPTu5zXOovtrWgQOMCo="
    static let pairServerMac = "Ge6qTrQD2GXAFHb1FmhAYZC9zxjBNmP7qd+7BNAKino="
    static let trustKey = "rPgYCKKHoooiJh4D31kqY5EAwbFYaO3IX52knk/QlVI="
    static let resumeMac = "XBpm4KleML9OxbdLsqPyDCnoit+3IXgxAMwzM7FSd3s="
    static let resumeServerMac = "1wWiB8biHiNxUFPE7r5fLzxVIB77pwE4bflIM+8lsCA="
    static let sealedBox = "/NbikK7QKYoRPpWMO4MGDPeWZHDb8dMpPzyAS8lc61mTi59gdPNmXUN7s7vejY2hCSg="
}

/// A test client speaking the editor protocol (as the VS Code extension does).
struct TestEditorClient {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var deviceID = "mac-1"
    var keys: EditorCrypto.SessionKeys?
    var trustKey: Data?
    var expect: String?
    var sent = 0
    var received = 0

    init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }

    mutating func reply(to hello: EditorHandshake, code: String?, trust: Data?) -> EditorHandshake {
        let serverRaw = Data(base64Encoded: hello.serverKey!)!, nonce = Data(base64Encoded: hello.nonce!)!
        let shared = try! privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverRaw))
        let transcript = EditorCrypto.transcript(serverKey: serverRaw, clientKey: privateKey.publicKey.rawRepresentation, nonce: nonce, deviceID: deviceID)
        if let trust {
            keys = EditorCrypto.deriveKeys(shared: shared, nonce: nonce, secret: trust, mode: "session")
            trustKey = trust
        } else {
            let codeHash = Data(SHA256.hash(data: Data(EditorCrypto.normalizeCode(code ?? "").utf8)))
            keys = EditorCrypto.deriveKeys(shared: shared, nonce: nonce, secret: codeHash, mode: "pair")
            trustKey = EditorCrypto.trustKey(shared: shared, nonce: nonce, codeHash: codeHash)
        }
        expect = EditorCrypto.mac(keys!.auth, "server", transcript).base64EncodedString()
        return EditorHandshake(type: trust == nil ? "pair" : "resume", v: 1, clientKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                               deviceID: deviceID, name: "VS Code", mac: EditorCrypto.mac(keys!.auth, "client", transcript).base64EncodedString())
    }

    mutating func seal(_ body: [String: Any], at date: Date) -> Data {
        sent += 1
        var body = body
        body["ts"] = Int(date.timeIntervalSince1970 * 1000)
        let box = try! EditorCrypto.seal(try! JSONSerialization.data(withJSONObject: body), key: keys!.c2s, seq: sent, direction: "c2s")
        return try! JSONEncoder().encode(EditorEnvelope(seq: sent, box: box.base64EncodedString())) + Data([0x0A])
    }

    mutating func open(_ line: Data) -> [String: Any]? {
        guard let envelope = try? JSONDecoder().decode(EditorEnvelope.self, from: line), envelope.seq == received + 1,
              let plain = try? EditorCrypto.open(Data(base64Encoded: envelope.box)!, key: keys!.s2c, seq: envelope.seq, direction: "s2c") else { return nil }
        received = envelope.seq
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }
}

@Suite struct EditorCryptoVectorTests {
    @Test func swiftAndNodeDeriveTheSameKeysProofsAndBoxes() throws {
        let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let client = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        #expect(server.publicKey.rawRepresentation.base64EncodedString() == EditorVectors.serverPublic)
        #expect(client.publicKey.rawRepresentation.base64EncodedString() == EditorVectors.clientPublic)
        var session = EditorServerSession(privateKey: server, nonce: Data(repeating: 3, count: 16), pairingCode: "ABCDE-FGH23")
        var editor = TestEditorClient(privateKey: client)
        editor.deviceID = "test-device"
        let pair = editor.reply(to: session.hello, code: "abcde-fgh23", trust: nil)
        #expect(pair.mac == EditorVectors.pairMac)
        let (reply, outcome) = session.handshake(pair, trusted: [], now: Date())
        #expect(reply.mac == EditorVectors.pairServerMac)
        guard case .paired(let trusted) = outcome else { Issue.record("not paired"); return }
        #expect(trusted.key.base64EncodedString() == EditorVectors.trustKey)

        var resumeSession = EditorServerSession(privateKey: server, nonce: Data(repeating: 3, count: 16), pairingCode: nil)
        let resume = editor.reply(to: resumeSession.hello, code: nil, trust: trusted.key)
        #expect(resume.mac == EditorVectors.resumeMac)
        let (resumed, _) = resumeSession.handshake(resume, trusted: [trusted], now: Date())
        #expect(resumed.mac == EditorVectors.resumeServerMac)
        // Open the box Node sealed ({"type":"ping","ts":1700000000000}).
        let event = try resumeSession.open(EditorEnvelope(seq: 1, box: EditorVectors.sealedBox), now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(event.type == "ping")
    }

    @Test func pairingCodesAreLongAndNormalised() {
        let code = EditorCrypto.newPairingCode()
        #expect(code.count == 11 && code.contains("-"))
        #expect(EditorCrypto.normalizeCode("abcde-fgh23") == "ABCDEFGH23")
    }
}

@MainActor @Suite(.serialized) struct EditorBridgeTests {
    let store = MemoryTrustStore()
    let bridge: EditorBridge
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        bridge = EditorBridge(trust: store)
        let clock = self.clock
        bridge.now = { clock }
    }

    final class Wire {
        var lines: [Data] = []
        var closed = false
        func handshake() -> EditorHandshake? { lines.last.flatMap { try? JSONDecoder().decode(EditorHandshake.self, from: $0) } }
    }

    func connect(_ wire: Wire) -> Int {
        bridge.accept(transmit: { data in wire.lines.append(data.dropLast()) }, close: { wire.closed = true })
    }

    func pair(_ client: inout TestEditorClient, wire: Wire) -> Int {
        let code = bridge.startPairing()
        let token = connect(wire)
        let reply = client.reply(to: wire.handshake()!, code: code, trust: nil)
        bridge.receive(try! JSONEncoder().encode(reply) + Data([0x0A]), token: token)
        return token
    }

    @Test func initialPairingThenAutomaticReconnectionWithoutACode() {
        var client = TestEditorClient()
        let wire = Wire()
        _ = pair(&client, wire: wire)
        let paired = try? JSONDecoder().decode(EditorHandshake.self, from: wire.lines[1])
        #expect(paired?.type == "paired" && paired?.mac == client.expect) // the iPhone proved the code too
        #expect(bridge.connected && store.all().count == 1)
        #expect(bridge.pairing == nil) // single use
        bridge.disconnect()

        // Reconnection: no pairing window, no code — the trust key authenticates a fresh session.
        var again = TestEditorClient()
        again.deviceID = client.deviceID
        let wire2 = Wire()
        let token = connect(wire2)
        #expect(wire2.handshake()?.mode == "resume")
        let resume = again.reply(to: wire2.handshake()!, code: nil, trust: client.trustKey)
        bridge.receive(try! JSONEncoder().encode(resume) + Data([0x0A]), token: token)
        #expect(bridge.connected)
        #expect(bridge.metrics.resumes == 1 && bridge.metrics.pairings == 1)
    }

    @Test func wrongCodeIsRejectedAndTheCodeIsBurned() {
        _ = bridge.startPairing()
        var client = TestEditorClient()
        let wire = Wire()
        let token = connect(wire)
        bridge.receive(try! JSONEncoder().encode(client.reply(to: wire.handshake()!, code: "AAAAA-AAAAA", trust: nil)) + Data([0x0A]), token: token)
        #expect(!bridge.connected && wire.closed)
        #expect(bridge.pairing == nil)            // one attempt per code: no online guessing
        #expect(bridge.metrics.authFailures == 1)
        #expect(store.all().isEmpty)
    }

    @Test func expiredCodesRevokedAndExpiredTrustAreRejected() {
        var client = TestEditorClient()
        _ = pair(&client, wire: Wire())
        bridge.forget(client.deviceID)
        #expect(!bridge.connected)
        var again = TestEditorClient()
        again.deviceID = client.deviceID
        let wire = Wire()
        let token = connect(wire)
        bridge.receive(try! JSONEncoder().encode(again.reply(to: wire.handshake()!, code: nil, trust: client.trustKey)) + Data([0x0A]), token: token)
        #expect(!bridge.connected)
        #expect(wire.handshake()?.reason?.contains("not paired") == true)

        store.save(TrustedEditor(deviceID: "old", name: "Old", key: Data(repeating: 9, count: 32), pairedAt: clock.addingTimeInterval(-40 * 86_400),
                                 expiresAt: clock.addingTimeInterval(-86_400)))
        var old = TestEditorClient()
        old.deviceID = "old"
        let wire2 = Wire()
        let token2 = connect(wire2)
        bridge.receive(try! JSONEncoder().encode(old.reply(to: wire2.handshake()!, code: nil, trust: Data(repeating: 9, count: 32))) + Data([0x0A]), token: token2)
        #expect(wire2.handshake()?.reason?.contains("expired") == true)

        let code = bridge.startPairing()
        let later = clock.addingTimeInterval(EditorCrypto.codeLifetime + 1)
        bridge.now = { later }
        var late = TestEditorClient()
        let wire3 = Wire()
        let token3 = connect(wire3)
        #expect(wire3.handshake()?.mode == "resume") // the window closed
        bridge.receive(try! JSONEncoder().encode(late.reply(to: wire3.handshake()!, code: code, trust: nil)) + Data([0x0A]), token: token3)
        #expect(!bridge.connected)
    }

    @Test func replayStaleTamperedAndOversizedMessagesCloseTheSession() {
        var events: [EditorEvent] = []
        bridge.onEvent = { events.append($0) }
        var client = TestEditorClient()
        let wire = Wire()
        let token = pair(&client, wire: wire)
        let first = client.seal(["type": "state", "file": "a.js"], at: clock)
        bridge.receive(first, token: token)
        #expect(events.map(\.file) == ["a.js"])
        bridge.receive(first, token: token)       // replay
        #expect(!bridge.connected)
        #expect(bridge.metrics.rejectedMessages == 1)
        #expect(events.count == 1)

        var second = TestEditorClient()
        let wire2 = Wire()
        let token2 = pair(&second, wire: wire2)
        bridge.receive(second.seal(["type": "ping"], at: clock.addingTimeInterval(-600)), token: token2) // stale timestamp
        #expect(!bridge.connected)

        var third = TestEditorClient()
        let wire3 = Wire()
        let token3 = pair(&third, wire: wire3)
        // Flip one ciphertext byte (not a JSON character or base64 padding bit, which may not change the box).
        let sealed = third.seal(["type": "state", "file": "b.js"], at: clock)
        var envelope = try! JSONDecoder().decode(EditorEnvelope.self, from: sealed.dropLast())
        var box = Data(base64Encoded: envelope.box)!
        box[box.count / 2] ^= 0x01
        envelope.box = box.base64EncodedString()
        let tampered = try! JSONEncoder().encode(envelope) + Data([0x0A])
        bridge.receive(tampered, token: token3)
        #expect(!bridge.connected)
        var fourth = TestEditorClient()
        let wire4 = Wire()
        let token4 = pair(&fourth, wire: wire4)
        bridge.receive(Data(repeating: 0x41, count: EditorCrypto.maxLine + 10), token: token4)
        #expect(!bridge.connected)
    }

    @Test func pingsGetPongsAndExpectationsAreResentAfterReconnection() {
        bridge.expect(blockID: "w1-b1", language: "JavaScript", structures: ["function f() {"])
        var client = TestEditorClient()
        let wire = Wire()
        let token = pair(&client, wire: wire)
        let decoded = wire.lines.dropFirst(2).compactMap { client.open($0) }
        #expect(decoded.contains { $0["type"] as? String == "expect" && $0["blockID"] as? String == "w1-b1" })
        bridge.receive(client.seal(["type": "ping", "id": 7], at: clock), token: token)
        #expect(wire.lines.compactMap { client.open($0) }.contains { $0["type"] as? String == "pong" && $0["id"] as? Int == 7 })
    }

    @Test func heartbeatLossRateLimitsAndSuspension() {
        var client = TestEditorClient()
        let token = pair(&client, wire: Wire())
        let later = clock.addingTimeInterval(31)
        bridge.now = { later }
        #expect(!bridge.checkHeartbeat())
        #expect(!bridge.connected && bridge.metrics.heartbeatTimeouts == 1)

        bridge.now = { later }
        var flood = TestEditorClient()
        let floodToken = pair(&flood, wire: Wire())
        for _ in 0..<60 where bridge.connected { bridge.receive(flood.seal(["type": "state"], at: later), token: floodToken) }
        #expect(!bridge.connected && bridge.metrics.rateLimited == 1)
        _ = token

        bridge.setSuspended(true)
        #expect(!bridge.shouldListen)
        bridge.setSuspended(false)
        #expect(bridge.shouldListen == bridge.enabled)
    }

    @Test func anUnauthenticatedStrangerCannotDisturbTheConnectedEditor() {
        var events: [EditorEvent] = []
        bridge.onEvent = { events.append($0) }
        var client = TestEditorClient()
        let token = pair(&client, wire: Wire())
        let stranger = Wire()
        let strangerToken = connect(stranger)
        bridge.receive(Data("{\"type\":\"resume\",\"v\":1}\n".utf8), token: strangerToken) // malformed, unauthenticated
        #expect(stranger.closed)
        #expect(bridge.connected)
        bridge.receive(client.seal(["type": "state", "file": "still.js"], at: clock), token: token)
        #expect(events.last?.file == "still.js")
    }
}

// MARK: Editor assistant

@Suite struct DiagnosticExplainerTests {
    @Test(arguments: [
        ("Cannot find name 'students'.", "Check whether students is defined in the current scope or passed in as a function parameter."),
        ("Property 'statuss' does not exist on type 'Student'.", "Student has no statuss: check the spelling, or the type you expect here."),
        ("Object is possibly 'undefined'.", "This value may be undefined here: check it first or use optional chaining (?.)."),
        ("';' expected.", "A bracket or punctuation mark is missing near this line: check the closing ;."),
        ("\"roster\" is not defined", "Check whether roster is defined in the current scope or passed in as a function parameter."),
        ("syntax error at or near \"FORM\"", "The SQL is invalid near FORM: check the keyword order or a missing comma."),
    ])
    func commonDiagnosticsGetPlainExplanations(_ message: String, _ expected: String) {
        #expect(DiagnosticExplainer.explain(.init(message: message, severity: "error", line: 4)).short == expected)
    }

    @Test func unknownDiagnosticsFallBackToTheMessage() {
        let result = DiagnosticExplainer.explain(.init(message: "Some rare linker complaint", severity: "error", line: 9))
        #expect(!result.matched && result.short.hasPrefix("Line 9:"))
    }
}

@MainActor @Suite(.serialized) struct EditorAssistantTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let snippets: CodeSnippetController
    let assistant: EditorAssistant
    var speaking = false

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses)
        presenter.frameRows = 5
        snippets = CodeSnippetController(presenter: presenter)
        assistant = EditorAssistant(presenter: presenter, snippets: snippets)
    }

    func wait(_ seconds: Double = 0.06) async { try? await Task.sleep(for: .seconds(seconds)) }
    var lens: String { LensModel.visibleText([glasses.shown.last ?? ""], rowWidth: 60).joined(separator: " ") }
    func error(_ message: String, line: Int = 3) -> EditorEvent {
        EditorEvent(type: "diagnostics", errors: 1, warnings: 0, stable: true, diagnostics: [.init(message: message, severity: "error", line: line)])
    }

    func startWalkthrough() async -> CodingWalkthrough {
        let walkthrough = CodingWalkthrough.parse(Walk.javascript, language: "JavaScript", answerID: 3)!
        await presenter.present(walkthrough.blocks[0].text, answerID: 3)
        snippets.startWalkthrough(walkthrough, snippet: nil, answerID: 3, endMarker: nil)
        await wait()
        return walkthrough
    }

    @Test func automaticProgressionNeedsAStableCompleteErrorFreeStep() async {
        _ = await startWalkthrough()
        snippets.walkthroughNext()
        await wait()
        let block = snippets.currentBlock!.id
        assistant.handle(EditorEvent(type: "progress", blockID: block, present: [true, true], errors: 0, stable: false)) // still typing
        assistant.handle(EditorEvent(type: "progress", blockID: block, present: [true, false], errors: 0, stable: true)) // incorrect / incomplete
        assistant.handle(EditorEvent(type: "progress", blockID: block, present: [true, true], errors: 1, stable: true))  // compiler error
        await wait()
        #expect(snippets.currentBlock?.id == block)
        assistant.handle(EditorEvent(type: "auto", enabled: false))
        assistant.handle(EditorEvent(type: "progress", blockID: block, present: [true, true], errors: 0, stable: true))
        await wait()
        #expect(snippets.currentBlock?.id == block) // progression disabled
        assistant.handle(EditorEvent(type: "auto", enabled: true))
        assistant.handle(EditorEvent(type: "progress", blockID: "w9-b1", present: [true, true], errors: 0, stable: true)) // stale block
        await wait()
        #expect(snippets.currentBlock?.id == block)
        assistant.handle(EditorEvent(type: "progress", blockID: block, present: [true, true], errors: 0, stable: true))
        await wait()
        #expect(snippets.currentBlock?.kind == .explanation)
    }

    @Test func errorsAppearOnCodeStepsOnlyWarningsNeverAndDuplicatesAreSuppressed() async {
        _ = await startWalkthrough() // on an explanation step
        assistant.handle(error("Cannot find name 'arr'."))
        await wait()
        #expect(!lens.contains("arr is defined")) // never over an explanation
        snippets.walkthroughNext()
        await wait()
        assistant.handle(EditorEvent(type: "diagnostics", errors: 0, warnings: 1, stable: true, diagnostics: [.init(message: "'x' is declared but its value is never read.", severity: "warning", line: 2)]))
        await wait()
        #expect(lens.contains("const unique")) // warnings stay on the iPhone
        assistant.handle(error("Cannot find name 'arr'."))
        await wait()
        #expect(lens.contains("arr is defined"))
        let count = glasses.shown.count
        assistant.handle(error("Cannot find name 'arr'."))
        await wait()
        #expect(glasses.shown.count == count) // coalesced
    }

    @Test func lowPriorityCaptionsWaitWhileYouSpeakButExplicitHelpDoesNot() async {
        assistant.isSpeaking = { true }
        await presenter.present("Reading this answer aloud.", answerID: 1)
        assistant.handle(EditorEvent(type: "task", task: .init(name: "npm test", kind: "test", exitCode: 0)))
        await wait()
        #expect(lens == "Reading this answer aloud.")
        #expect(assistant.taskStatus == "Tests passed (npm test)")
        assistant.speechEnded()
        await wait()
        #expect(lens.contains("Tests passed"))
        await assistant.explainDiagnostic(.init(message: "Cannot find name 'students'.", severity: "error", line: 12), excerpt: nil)
        await wait()
        #expect(lens.contains("students is defined")) // explicit request: shown even while speaking
        #expect(assistant.help?.title.contains("Line 12") == true)
    }

    @Test func testAndBuildResultsAreReportedOnlyAsTheRunnerSaid() {
        assistant.handle(EditorEvent(type: "task", task: .init(name: "npm test", kind: "test", exitCode: 1)))
        #expect(assistant.taskStatus == "Tests failed (npm test, exit 1)")
        assistant.handle(EditorEvent(type: "task", task: .init(name: "tsc", kind: "build", exitCode: 0)))
        #expect(assistant.taskStatus == "Build passed (tsc)")
        assistant.handle(EditorEvent(type: "task", task: .init(name: "jest", kind: "test", exitCode: nil)))
        #expect(assistant.taskStatus == "Tests task ended without a result (jest)")
    }

    @Test func explainSelectionKeepsTheWalkthroughPosition() async {
        var prompts: [String] = []
        assistant.askAI = { _, prompt in prompts.append(prompt); return "This filters the students array to the active ones. It relies on Array.prototype.filter. Watch out for missing status fields." }
        _ = await startWalkthrough()
        snippets.walkthroughNext()
        await wait()
        let position = snippets.stepIndex
        assistant.handle(EditorEvent(type: "explain", language: "javascript", code: "students.filter(s => s.status === 'active')"))
        await wait(0.12)
        #expect(prompts.first?.contains("students.filter") == true)
        #expect(lens.contains("filters the students array"))
        #expect(snippets.stepIndex == position)
        assistant.dismissHelp()
        await wait(0.12)
        #expect(lens.contains("const unique")) // back to the same code step
    }

    @Test func helpSurvivesAGlassesReconnectionAndANewAnswerEndsIt() async {
        await presenter.present("An answer.", answerID: 1)
        await assistant.explainDiagnostic(.init(message: "Cannot find name 'students'.", severity: "error", line: 2), excerpt: nil)
        await wait()
        glasses.simulateDrop()
        glasses.connect()
        await wait()
        #expect(lens.contains("students is defined")) // explicit help is persistent
        await presenter.present("A new answer after a new question.", answerID: 2)
        await wait()
        #expect(lens == "A new answer after a new question.") // a confident new question outranks editor help
    }
}
