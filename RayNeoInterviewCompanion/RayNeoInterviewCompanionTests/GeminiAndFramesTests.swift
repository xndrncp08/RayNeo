import Foundation
import Synchronization
import Testing
@testable import RayNeoInterviewCompanion

/// Stub transport: no network, no key leaves the test process. Each test owns a `Stub` (its own handler
/// and request record), so suites running in parallel never share mutable state.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String, URLError?)

    final class Stub: @unchecked Sendable {
        let id = UUID().uuidString
        private let lock = NSLock()
        private var storedHandler: Handler = { _ in (500, "", nil) }
        private var storedRequest: URLRequest?
        private var storedBody: Data?
        let session: URLSession

        init() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
            session = URLSession(configuration: configuration)
            StubURLProtocol.registry.withLock { $0[id] = self }
        }

        var handler: Handler {
            get { lock.withLock { storedHandler } }
            set { lock.withLock { storedHandler = newValue } }
        }
        var lastRequest: URLRequest? { lock.withLock { storedRequest } }
        var lastBody: Data? { lock.withLock { storedBody } }
        func record(_ request: URLRequest, _ body: Data?) { lock.withLock { storedRequest = request; storedBody = body } }
    }

    static let registry = Mutex<[String: Stub]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Stub-ID"), let stub = Self.registry.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        }
        stub.record(request, body)
        let (status, text, error) = stub.handler(request)
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func sse(_ chunks: [String]) -> String {
        chunks.map { #"data: {"candidates":[{"content":{"parts":[{"text":"\#($0)"}],"role":"model"}}]}"# + "\n\n" }.joined()
    }
}

@MainActor @Suite(.serialized) struct GeminiProviderTests {
    let stub = StubURLProtocol.Stub()
    func provider() -> GeminiProvider {
        let gemini = GeminiProvider()
        gemini.consented = true
        gemini.keyProvider = { "test-key" }
        gemini.session = stub.session
        gemini.model = GeminiModel.flashLite.rawValue
        return gemini
    }

    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await item in stream { out.append(item) }
        return out
    }

    let request = AnswerRequest(instructions: "Be brief.", prompt: "Interviewer: What is MFA?\nYour spoken answer:", maximumTokens: 110)

    @Test func streamsCumulativeTextFromTheDocumentedEndpoint() async throws {
        stub.handler = { _ in (200, StubURLProtocol.sse(["MFA means ", "multi-factor authentication."]), nil) }
        let parts = try await collect(provider().streamAnswer(request))
        #expect(parts == ["MFA means ", "MFA means multi-factor authentication."])
        let sent = try #require(stub.lastRequest)
        #expect(sent.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:streamGenerateContent?alt=sse")
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(sent.url?.query?.contains("key=") == false) // the key never appears in the URL
        let body = try #require(stub.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 110)
        #expect((body["generationConfig"] as? [String: Any])?["temperature"] == nil) // ignored by 3.6+ models
        #expect(body["systemInstruction"] != nil && body["contents"] != nil)
    }

    @Test func thoughtPartsAndKeepAlivesAreIgnored() throws {
        #expect(try GeminiProvider.parseEvent(": keep-alive") == nil)
        #expect(try GeminiProvider.parseEvent(#"data: {"candidates":[{"content":{"parts":[{"text":"plan","thought":true},{"text":"Answer."}]}}]}"#) == "Answer.")
    }

    @Test(arguments: [
        (429, #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded"}}"#, "rateLimited"),
        (403, #"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"API key not valid"}}"#, "unauthorized"),
        (404, #"{"error":{"code":404,"status":"NOT_FOUND","message":"model not found"}}"#, "modelUnavailable"),
        (400, #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"bad field"}}"#, "badRequest"),
        (503, #"{"error":{"code":503,"status":"UNAVAILABLE","message":"overloaded"}}"#, "server"),
    ])
    func httpErrorsAreMappedExplicitly(_ status: Int, _ body: String, _ kind: String) async {
        stub.handler = { _ in (status, body, nil) }
        do {
            _ = try await collect(provider().streamAnswer(request))
            Issue.record("expected an error")
        } catch let error as GeminiError {
            #expect(String(describing: error).hasPrefix(kind), "\(error)")
            if status == 429 { #expect(error.localizedDescription.contains("RESOURCE_EXHAUSTED")) }
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func timeoutsAndOfflineAreReported() async {
        stub.handler = { _ in (0, "", URLError(.timedOut)) }
        await #expect(throws: GeminiError.timedOut) { _ = try await collect(provider().streamAnswer(request)) }
        stub.handler = { _ in (0, "", URLError(.notConnectedToInternet)) }
        do { _ = try await collect(provider().streamAnswer(request)); Issue.record("expected offline") }
        catch let error as GeminiError { if case .offline = error {} else { Issue.record("\(error)") } }
        catch { Issue.record("\(error)") }
    }

    @Test func nothingIsSentWithoutConsentOrKey() async {
        let gemini = provider()
        gemini.consented = false
        #expect(gemini.status != .ready)
        await #expect(throws: GeminiError.notConsented) { _ = try await collect(gemini.streamAnswer(request)) }
        gemini.consented = true
        gemini.keyProvider = { nil }
        await #expect(throws: GeminiError.missingKey) { _ = try await collect(gemini.streamAnswer(request)) }
        #expect(stub.lastRequest == nil)
    }

    @Test func rateLimitFallsBackToAppleBeforeAnyText() async throws {
        stub.handler = { _ in (429, #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"quota"}}"#, nil) }
        let apple = MockAIProvider()
        apple.answer = "Local answer."
        let cloud = CloudFailoverProvider(gemini: provider(), fallback: apple)
        let parts = try await collect(cloud.streamAnswer(request))
        #expect(parts.last == "Local answer.")
        #expect(cloud.lastUsed == "AI")
        cloud.fallbackEnabled = false
        await #expect(throws: (any Error).self) { _ = try await collect(cloud.streamAnswer(request)) }
    }

    @Test func badRequestsAreNotHiddenByFallback() async {
        stub.handler = { _ in (400, #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"bad"}}"#, nil) }
        let cloud = CloudFailoverProvider(gemini: provider(), fallback: MockAIProvider())
        await #expect(throws: (any Error).self) { _ = try await collect(cloud.streamAnswer(request)) }
    }

    @Test func portfolioStaysOnDeviceUnlessAllowed() {
        let knowledge = KnowledgeBase(url: nil)
        knowledge.document.portfolio = "Built a private CRM for Acme Corp."
        let model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [MockSpeech()] }, aiFactory: { _ in MockAIProvider() },
                             glassesFactory: { _ in MockGlassesDisplay() }, knowledge: knowledge, permissions: { nil })
        let personal = "Tell me about your experience with CRMs."
        model.settings.aiModel = .geminiFlash
        #expect(!model.notes(for: personal).joined().contains("Acme"))
        model.settings.geminiIncludePortfolio = true
        #expect(model.notes(for: personal).joined().contains("Acme"))
        model.settings.aiModel = .appleOnDevice
        model.settings.geminiIncludePortfolio = false
        #expect(model.notes(for: personal).joined().contains("Acme"))
        // Never in the system instructions, and never for a question that doesn't ask about your own work.
        #expect(!model.engine.instructionsProvider(.technical).contains("Acme"))
        #expect(!model.notes(for: "How would you investigate a slow CRM integration?").joined().contains("Acme"))
    }
}

@Suite struct StreamingTextTests {
    @Test func completeSentencesNeverIncludeUnfinishedText() {
        #expect(AnswerFormatter.completeSentences("I'd check the logs. Then I'd ver") == "I'd check the logs.")
        #expect(AnswerFormatter.completeSentences("Version 3.5 is") == "")
        #expect(AnswerFormatter.completeSentences("Done.") == "")
        #expect(AnswerFormatter.completeSentences("One. Two? Three! Fo") == "One. Two? Three!")
    }

    @Test func settingsMigrationMovesOnlyUntouchedOldDefaults() throws {
        let old = #"{"captionStrategy":"stableSections","captionLayout":{"maxLines":4,"charactersPerLine":26}}"#
        var settings = try #require(AppSettings.decodeMerged(Data(old.utf8)))
        AppModel.migrate(&settings, from: Data(old.utf8))
        #expect(settings.captionStrategy == .sentenceFrames && settings.captionLayout.charactersPerLine == 48)

        let calibrated = #"{"captionStrategy":"fullFrames","captionLayout":{"maxLines":3,"charactersPerLine":30}}"#
        var kept = try #require(AppSettings.decodeMerged(Data(calibrated.utf8)))
        AppModel.migrate(&kept, from: Data(calibrated.utf8))
        #expect(kept.captionStrategy == .fullFrames && kept.captionLayout.charactersPerLine == 30)

        let current = #"{"settingsVersion":2,"captionStrategy":"stableSections"}"#
        var untouched = try #require(AppSettings.decodeMerged(Data(current.utf8)))
        AppModel.migrate(&untouched, from: Data(current.utf8))
        #expect(untouched.captionStrategy == .stableSections)
    }
}

@MainActor @Suite(.serialized) struct SentenceFrameTests {
    func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    func framePresenter(_ glasses: MockGlassesDisplay) -> GlassesPresenter {
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.frameRows = 5
        return presenter
    }

    @Test func everyFrameIsOneCaptionShowingThreeToFourLinesAndNothingElse() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = framePresenter(glasses)
        await presenter.present("Old answer about DNS records that must not remain visible on the lens.")
        await presenter.present(Canon.longAnswer)
        let plan = presenter.plan!
        for index in plan.sections.indices {
            await presenter.showPage(index)
            let visible = LensModel.visibleText(glasses.shown, rowWidth: 58)
            #expect(visible == CaptionLayout.standard.wrap(plan.sections[index].text), "frame \(index)")
            if index < plan.sections.count - 1 { #expect(visible.count >= 3) }
        }
        // All frames together reproduce the answer exactly, in order, once.
        #expect(plan.sections.map(\.text).joined(separator: " ") == Canon.longAnswer)
    }

    @Test func rowBreaksAreSpaceProtectedEvenIfTheLensDroppedThem() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = framePresenter(glasses)
        await presenter.present(Canon.longAnswer)
        let frame = glasses.shown.last!
        #expect(!frame.contains(where: { $0 == "\n" }) || frame.components(separatedBy: "\n").dropLast().allSatisfy { $0.hasSuffix(" ") })
        let flattened = frame.replacingOccurrences(of: "\n", with: "") // worst case: the lens ignores line breaks
        let words = Canon.words(flattened).filter { $0 != GlassesPresenter.blank }
        #expect(Canon.startIndex(of: words.joined(separator: " "), in: Canon.words(Canon.longAnswer)) == 0)
    }

    @Test func framesAdvanceOnReadingProgressWithoutWaitingForSilence() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = framePresenter(glasses)
        let reading = ReadingController(presenter: presenter)
        reading.lineScrollingAllowed = false
        reading.mode = .speechSynced
        await presenter.present(Canon.longAnswer)
        let plan = presenter.plan!
        // Partial results only (no final): the frame advances as soon as its last meaningful word is read.
        let words = plan.sections[0].text.split(separator: " ")
        for count in 1...words.count { reading.ingest(words.prefix(count).joined(separator: " "), isFinal: false, speaker: .unknown) }
        await settle()
        #expect(presenter.pageIndex == 1)
        #expect(glasses.shown.count == 2)
        // A pause (silence-only final) never advances.
        reading.ingest("", isFinal: true, speaker: .unknown)
        await settle()
        #expect(presenter.pageIndex == 1)
        // Manual Next / Previous frame still work.
        reading.nextSection(); await settle()
        #expect(presenter.pageIndex == 2)
        reading.previousSection(); await settle()
        #expect(presenter.pageIndex == 1)
    }

    @Test func streamingAnswerShowsAStableFirstFrameEarlyAndNeverRewritesIt() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = framePresenter(glasses)
        let reading = ReadingController(presenter: presenter)
        reading.lineScrollingAllowed = false
        reading.mode = .speechSynced
        let ai = MockAIProvider()
        ai.answer = Canon.longAnswer
        ai.perWordDelay = .milliseconds(4)
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()

        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        // Wait until the early frame is out while generation is still running.
        for _ in 0..<200 where glasses.shown.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!glasses.shown.isEmpty)
        #expect(engine.state == .generating) // still streaming
        let early = glasses.shown.first!

        // The wearer starts reading the early frame before the answer completes.
        let firstWords = presenter.plan!.sections[0].text.split(separator: " ").prefix(6).joined(separator: " ")
        reading.ingest(firstWords, isFinal: false, speaker: .unknown)
        let cursor = reading.cursorWord

        await engine.generationTask?.value
        #expect(engine.state == .answerLocked)
        #expect(glasses.shown.first == early)                 // the early frame came first…
        #expect(Streaming.settled(glasses.shown).count == 1)  // …and only grew by appending (never rewritten)
        #expect(presenter.plan?.answer == engine.currentAnswer?.text) // the full (post-processed) answer
        #expect(presenter.pages.count > 1)
        reading.ingest(firstWords, isFinal: false, speaker: .unknown)
        #expect(reading.cursorWord >= cursor) // reading progress survived the completion
        #expect(engine.currentAnswer?.earlyFrameSeconds != nil)
    }

    @Test func noEarlyFrameForFactualAnswersOrWhenDisabled() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = framePresenter(glasses)
        let ai = MockAIProvider()
        ai.answer = "Multi-factor authentication requires two or more proofs of identity. It blocks most password attacks. It is standard in Microsoft Entra ID."
        ai.perWordDelay = .milliseconds(2)
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        await engine.handle(CompletedTurn(text: "What is MFA?", start: 0, end: 1))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.earlyFrameSeconds == nil)
        #expect(glasses.shown.count == 1)
    }

    @Test func cancelledStreamWithdrawsItsEarlyFrameAndRestoresThePreviousAnswer() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = framePresenter(glasses)
        let ai = MockAIProvider()
        var settings = AppSettings()
        settings.semanticClassification = false
        settings.lockAfterDisplay = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        ai.answer = "A short previous answer about DNS caching."
        await engine.handle(CompletedTurn(text: "How would you fix DNS caching problems?", start: 0, end: 1))
        await engine.generationTask?.value
        let previous = presenter.plan?.answer

        ai.answer = Canon.longAnswer
        ai.perWordDelay = .milliseconds(8)
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 2, end: 3))
        for _ in 0..<300 where !presenter.provisional { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(presenter.provisional)
        engine.cancelGeneration()
        await engine.generationTask?.value
        #expect(presenter.plan?.answer == previous) // the old answer is back, no half-generated text left
        #expect(engine.currentAnswer?.text == previous)
    }
}
