import Foundation
import Testing
@testable import RayNeoInterviewCompanion

@MainActor @Suite(.serialized) struct GeminiConnectionTests {
    let stub = StubURLProtocol.Stub()
    func provider() -> GeminiProvider {
        let gemini = GeminiProvider()
        gemini.keyProvider = { "test-key-123" }
        gemini.session = stub.session
        gemini.model = "gemini-3.5-flash-lite"
        return gemini // not consented: the test button is the explicit user action
    }

    static let modelOK = #"{"name":"models/gemini-3.5-flash-lite","supportedGenerationMethods":["generateContent","countTokens"]}"#
    static let streamOK = #"data: {"candidates":[{"content":{"parts":[{"text":"Connection OK"}]},"finishReason":"STOP"}]}"# + "\n\n"

    func route(get: (Int, String, URLError?), post: (Int, String, URLError?)) {
        stub.handler = { request in request.httpMethod == "GET" ? get : post }
    }

    @Test func streamingRouteIsExactlyTheDocumentedOne() {
        #expect(GeminiProvider.streamURL(model: "gemini-3.5-flash-lite").absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:streamGenerateContent?alt=sse")
    }

    @Test func successfulTestReportsStatusModelLatencyAndResponseButNeverTheKey() async {
        route(get: (200, Self.modelOK, nil), post: (200, Self.streamOK, nil))
        let report = await provider().testConnection()
        #expect(report.outcome == .ok)
        #expect(report.httpStatus == 200)
        #expect(report.modelCheck == "exists, supports generateContent")
        #expect(report.firstTokenSeconds != nil)
        #expect(report.response == "Connection OK")
        #expect(report.finishReason == "STOP")
        #expect(!report.summary.contains("test-key-123"))
        #expect(stub.lastRequest?.url?.absoluteString.contains("test-key") == false)
    }

    @Test func modelThatDoesNotGenerateContentIsUnsupported() async {
        route(get: (200, #"{"name":"models/x","supportedGenerationMethods":["embedContent"]}"#, nil), post: (200, Self.streamOK, nil))
        let report = await provider().testConnection()
        #expect(report.outcome == .unsupportedModel)
        #expect(report.modelCheck.contains("embedContent"))
    }

    @Test func unknownModelIsUnsupported() async {
        route(get: (404, #"{"error":{"code":404,"status":"NOT_FOUND","message":"models/x is not found"}}"#, nil), post: (200, "", nil))
        #expect(await provider().testConnection().outcome == .unsupportedModel)
    }

    @Test func invalidKeyReportedAs400IsAKeyFailureAndIsRedacted() async {
        let body = #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"API key not valid: test-key-123","details":[{"reason":"API_KEY_INVALID"}]}}"#
        route(get: (400, body, nil), post: (200, "", nil))
        let report = await provider().testConnection()
        #expect(report.outcome == .invalidKey)
        #expect(report.httpStatus == 400)
        #expect(!report.summary.contains("test-key-123"))
        #expect(GeminiProvider.error(status: 400, body: body).allowsFallback) // a bad key still falls back to Apple
    }

    @Test func quotaAndNetworkFailuresAreDistinguished() async {
        route(get: (200, Self.modelOK, nil), post: (429, #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"quota"}}"#, nil))
        let quota = await provider().testConnection()
        #expect(quota.outcome == .quota)
        #expect(quota.httpStatus == 429)
        route(get: (0, "", URLError(.notConnectedToInternet)), post: (0, "", nil))
        #expect(await provider().testConnection().outcome == .network)
        route(get: (200, Self.modelOK, nil), post: (0, "", URLError(.timedOut)))
        #expect(await provider().testConnection().outcome == .network)
    }

    @Test func emptyResponseAtTheTokenLimitIsExplained() async {
        route(get: (200, Self.modelOK, nil), post: (200, #"data: {"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}]}"# + "\n\n", nil))
        let report = await provider().testConnection()
        #expect(report.outcome == .other)
        #expect(report.finishReason == "MAX_TOKENS")
        #expect(report.detail.contains("token limit"))
    }

    @Test func connectionTestDoesNotLeaveConsentOn() async {
        route(get: (200, Self.modelOK, nil), post: (200, Self.streamOK, nil))
        let gemini = provider()
        _ = await gemini.testConnection()
        #expect(!gemini.consented)
    }
}

@MainActor @Suite(.serialized) struct AnswerIdentityAndPreviewTests {
    func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    func setUp(answer: String, delay: Duration = .milliseconds(4)) -> (MockGlassesDisplay, GlassesPresenter, ReadingController, ConversationEngine, MockAIProvider) {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.frameRows = 5
        let reading = ReadingController(presenter: presenter)
        reading.lineScrollingAllowed = false
        reading.mode = .speechSynced
        let ai = MockAIProvider()
        ai.answer = answer
        ai.perWordDelay = delay
        var settings = AppSettings()
        settings.semanticClassification = false
        settings.lockAfterDisplay = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        return (glasses, presenter, reading, engine, ai)
    }

    @Test func pipelineLockPresenterAndReadingShareOneImmutableAnswerID() async {
        let (glasses, presenter, reading, engine, ai) = setUp(answer: Canon.longAnswer)
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        for _ in 0..<300 where !presenter.provisional { try? await Task.sleep(for: .milliseconds(5)) }
        let id = engine.generatingAnswerID
        #expect(id != nil)
        #expect(presenter.answerID == id) // early frame written under the generating answer's ID
        reading.ingest("I", isFinal: false, speaker: .unknown)
        #expect(reading.answerID == id)
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.answerID == id) // the lock holds the same ID
        #expect(presenter.answerID == id)            // completing did not issue a new one
        #expect(presenter.lastWrite?.answerID == id)
        reading.ingest("I", isFinal: false, speaker: .unknown)
        #expect(reading.answerID == id)
        #expect(Streaming.settled(glasses.shown).count == 1)

        // The next answer gets a new ID everywhere.
        ai.answer = "Multi-factor authentication requires two or more proofs of identity."
        await engine.handle(CompletedTurn(text: "What is MFA?", start: 3, end: 4))
        await engine.generationTask?.value
        let next = engine.currentAnswer?.answerID
        #expect(next != id && next != nil)
        #expect(presenter.answerID == next && presenter.lastWrite?.answerID == next)
        await settle()
        reading.ingest("Multi", isFinal: false, speaker: .unknown)
        #expect(reading.answerID == next)
    }

    @Test func earlyFrameIsNeverDuplicatedOrRewrittenAsTheAnswerContinues() async {
        let (glasses, presenter, reading, engine, _) = setUp(answer: Canon.longAnswer)
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.earlyFrameSeconds != nil)
        let plan = presenter.plan!
        for index in plan.sections.indices.dropFirst() { reading.nextSection(); await settle(); #expect(presenter.pageIndex == index) }
        // One caption per frame, frame 1 written once; reading every frame gives the answer exactly once.
        let settled = Streaming.settled(glasses.shown)
        #expect(settled.count == plan.sections.count)
        let visibleFrames = settled.map { LensModel.visibleText([$0], rowWidth: 58).joined(separator: " ") }
        #expect(visibleFrames.joined(separator: " ") == (engine.currentAnswer?.text ?? "") + " \u{2713}")
    }

    @Test func earlyFrameIsWithheldWhenItsTextWouldFailValidation() async {
        let fake = "In my last role at Contoso I debugged exactly this kind of integration every single week for the sales team. " + Canon.longAnswer
        let (_, _, _, engine, _) = setUp(answer: fake)
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.earlyFrameSeconds == nil)
    }

    @Test func previewMatchesTheCaptionsActuallySentAndFramesAreClean() async {
        let (glasses, presenter, _, _, _) = setUp(answer: "")
        await presenter.present("An older answer about DNS records that must never show up again.")
        let preview = await presenter.previewPayloads(Canon.longAnswer)
        let before = glasses.shown.count
        await presenter.present(Canon.longAnswer)
        for index in presenter.pages.indices.dropFirst() { await presenter.showPage(index) }
        #expect(Array(glasses.shown.dropFirst(before)) == preview) // byte-for-byte what is transmitted
        #expect(glasses.shown.count - before == preview.count)
        for payload in preview {
            let rows = LensModel.visibleText([payload], rowWidth: 58)
            #expect(rows.count <= 4)
            #expect(payload.range(of: #"\b\d+\s*/\s*\d+\b"#, options: .regularExpression) == nil) // no page counter
            #expect(!payload.contains("DNS")) // no old-answer text
        }
        // Frames do not overlap: their words concatenate to the answer exactly once.
        #expect(preview.map { LensModel.visibleText([$0], rowWidth: 58).joined(separator: " ") }.joined(separator: " ") == Canon.longAnswer)
    }

    @Test func previewDoesNotTouchTheLiveDisplayOrIssueAnID() async {
        let (glasses, presenter, _, _, _) = setUp(answer: "")
        await presenter.present("Live answer.")
        let id = presenter.answerID
        let shown = glasses.shown
        _ = await presenter.previewPayloads(Canon.longAnswer)
        #expect(glasses.shown == shown)
        #expect(presenter.answerID == id)
        #expect(AppSettings().captionStrategy == .sentenceFrames)
    }
}
