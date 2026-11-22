import Foundation
import Testing
@testable import RayNeoInterviewCompanion

// MARK: Adaptive auto-advance: explanation evaluator

@Suite struct WalkthroughCompletionEvaluatorTests {
    static let filterBlock = "I'd filter the students by their status and keep only the active ones."
    static let setBlock = "I'd use a Set because it stores unique values. First, I'd create a function that accepts an array."

    func evaluator(_ text: String = filterBlock, _ mode: AdaptiveWalkthroughMode = .balanced) -> WalkthroughCompletionEvaluator {
        WalkthroughCompletionEvaluator(blockID: "w1-b0", text: text, mode: mode)
    }

    func final(_ e: inout WalkthroughCompletionEvaluator, _ text: String) -> WalkthroughCompletionEvaluator.Evaluation {
        e.ingest(text, isFinal: true)
        return e.evaluate(utteranceEnded: true)
    }

    @Test func verbatimAndReadToTheEndAdvance() {
        var e = evaluator()
        #expect(final(&e, Self.filterBlock).advance)
        #expect(evaluator().evaluate(readingComplete: true, utteranceEnded: false).advance)
    }

    @Test func naturalParaphraseAdvances() {
        var e = evaluator()
        let result = final(&e, "So basically I'm going to go through the student list and only keep the ones whose state is active.")
        #expect(result.advance, "\(result)")
        var set = evaluator(Self.setBlock)
        let other = final(&set, "My function takes the list and puts it into a Set, since a Set only holds distinct values.")
        #expect(other.advance, "\(other)")
    }

    @Test func partialOrRevisedExplanationsWait() {
        var e = evaluator()
        #expect(!final(&e, "So I'd filter the").advance)
        var revised = evaluator()
        revised.ingest("I'd filter the students by status", isFinal: false)
        revised.ingest("I'd sort the students", isFinal: false) // the recognizer revised its hypothesis
        let result = final(&revised, "I'd sort the students")
        #expect(!result.advance)
        #expect(result.missing.contains("filter"))
    }

    @Test func pausesAndRepetitionAccumulateAcrossUtterances() {
        var e = evaluator()
        #expect(!final(&e, "First I take the students").advance)                      // a pause mid-explanation
        #expect(final(&e, "and filter them so only active status is kept").advance) // the rest, after the pause
        var repeated = evaluator()
        _ = final(&repeated, "I'd filter the students by their status")
        #expect(final(&repeated, "I'd filter the students by their status and keep the active ones").advance)
    }

    @Test func unrelatedSpeechAndSharedKeywordsNeverAdvance() {
        var unrelated = evaluator()
        let result = final(&unrelated, "The parking downstairs was full again today, we should leave early")
        #expect(!result.advance)
        #expect(result.reason.contains("unrelated"))
        var keywords = evaluator(Self.setBlock)
        #expect(!final(&keywords, "We covered arrays and sets in my statistics class yesterday, it was boring").advance)
    }

    @Test func silenceAloneNeverAdvancesAndMidSentenceWaitsUnlessResponsive() {
        #expect(!evaluator().evaluate(utteranceEnded: true).advance) // nothing heard
        var balanced = evaluator()
        balanced.ingest(Self.filterBlock, isFinal: false)
        #expect(!balanced.evaluate(utteranceEnded: false).advance) // covered, but the sentence has not ended
        var responsive = evaluator(Self.filterBlock, .responsive)
        responsive.ingest(Self.filterBlock, isFinal: false)
        #expect(responsive.evaluate(utteranceEnded: false).advance) // rapid speech: responsive moves mid-sentence
    }

    @Test func modesChangeThresholdsNotDelays() {
        let partial = "I'd filter the students by status"
        var balanced = evaluator(Self.filterBlock, .balanced), conservative = evaluator(Self.filterBlock, .conservative)
        var off = evaluator(Self.filterBlock, .off)
        #expect(final(&balanced, partial).advance)
        #expect(!final(&conservative, partial).advance)
        #expect(!final(&off, Self.filterBlock).advance)
    }
}

// MARK: Editor pairing protocol

@Suite struct EditorSessionTests {
    @Test func pairingNeedsTheHMACAndProgressNeedsPairing() throws {
        var session = EditorSession(code: "123456", nonce: "n1")
        _ = session.expect(blockID: "w1-b1", language: "JavaScript", structures: ["function f(arr) {", "return [...new Set(arr)];"])
        let early = session.receive(Data(#"{"type":"progress","blockID":"w1-b1","present":[true,true]}"#.utf8))
        #expect(early.close && early.progress == nil)

        var wrong = EditorSession(code: "123456", nonce: "n1")
        #expect(wrong.receive(try JSONEncoder().encode(EditorMessage(type: "hello", mac: EditorMessage.mac(code: "000000", nonce: "n1")))).close)

        let hello = session.receive(try JSONEncoder().encode(EditorMessage(type: "hello", mac: EditorMessage.mac(code: "123456", nonce: "n1"))))
        #expect(session.paired && !hello.close)
        #expect(hello.replies.map(\.type) == ["paired", "expect"]) // the pending step is sent on pairing
        let report = session.receive(Data(#"{"type":"progress","blockID":"w1-b1","file":"/Users/me/secret/project/dedupe.js","present":[true,false],"errors":0}"#.utf8))
        #expect(report.progress?.file == "dedupe.js") // only the file name is kept
        #expect(report.progress?.present == [true, false])
        #expect(session.receive(Data("not json".utf8)).close)
    }

    @Test func structuresPresentAreEvidenceNotProof() {
        #expect(CodeStructures.expected(from: "function f(arr) {\n  return [...new Set(arr)];\n}") == ["function f(arr) {", "return [...new Set(arr)];"])
        #expect(CodeStructures.complete(expected: 2, present: [true, true], errors: 0, mode: .balanced).done)
        #expect(!CodeStructures.complete(expected: 2, present: [true, false], errors: 0, mode: .balanced).done)
        #expect(!CodeStructures.complete(expected: 2, present: [true, true], errors: 1, mode: .balanced).done)
        #expect(!CodeStructures.complete(expected: 2, present: [true, true], errors: nil, mode: .conservative).done)
        #expect(!CodeStructures.complete(expected: 2, present: [true, true], errors: 0, mode: .off).done)
    }
}

// MARK: Adaptive walkthrough controller

@MainActor @Suite(.serialized) struct AdaptiveWalkthroughControllerTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let controller: CodeSnippetController
    let walkthrough = CodingWalkthrough.parse(Walk.javascript, language: "JavaScript", answerID: 3)!
    var expected: [(String, [String])] = []

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses)
        presenter.frameRows = 5
        controller = CodeSnippetController(presenter: presenter)
    }

    func wait(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }

    func start() async {
        await presenter.present(walkthrough.blocks[0].text, answerID: 3)
        controller.startWalkthrough(walkthrough, snippet: nil, answerID: 3, endMarker: nil)
        await wait()
    }

    @Test func ownWordsAdvanceFromExplanationToCode() async {
        await start()
        controller.walkthroughSpeech("I'm going to take the array and put it in a Set because a Set only stores distinct values", isFinal: true)
        await wait()
        #expect(controller.currentBlock?.kind == .code)
        #expect(controller.lastEvaluation?.advance == true)
    }

    @Test func codeNeverDisappearsOnSpeechOrSilence() async {
        await start()
        controller.walkthroughNext()
        await wait()
        for text in ["const unique equals new Set of arr", "okay", "now I'm typing it out", "Next step is to spread it"] {
            controller.walkthroughSpeech(text, isFinal: true)
        }
        await wait(0.3)
        #expect(controller.currentBlock?.kind == .code)
    }

    @Test func pairedEditorAdvancesACodeBlockOnlyOnACompleteErrorFreeReport() async {
        var sent: [(String, [String])] = []
        controller.onCodeStep = { blockID, _, structures in sent.append((blockID, structures)) }
        await start()
        controller.walkthroughNext()
        await wait()
        let (blockID, structures) = try! #require(sent.last)
        #expect(blockID == "w3-b1")
        controller.editorProgress(EditorProgress(blockID: blockID, file: "a.js", present: structures.map { _ in false }, errors: 0))
        controller.editorProgress(EditorProgress(blockID: blockID, file: "a.js", present: structures.map { _ in true }, errors: 2))
        controller.editorProgress(EditorProgress(blockID: "w9-b1", file: "a.js", present: structures.map { _ in true }, errors: 0)) // stale
        await wait()
        #expect(controller.currentBlock?.id == "w3-b1")
        #expect(controller.editorStatus?.contains("error") == true)
        controller.editorProgress(EditorProgress(blockID: blockID, file: "a.js", present: structures.map { _ in true }, errors: 0))
        await wait()
        #expect(controller.currentBlock?.kind == .explanation)
        #expect(controller.currentBlock?.index == 2)
    }

    @Test func interruptionPausesProgressionAndKeepsThePosition() async {
        await start()
        controller.interrupted = true
        controller.walkthroughSpeech("I'd put the array in a Set because a Set only stores unique values", isFinal: true)
        await wait()
        #expect(controller.currentBlock?.index == 0)
        controller.interrupted = false
        controller.walkthroughSpeech("I'd write a function that takes the array and puts it in a Set, because a Set only stores unique values", isFinal: true)
        await wait()
        #expect(controller.currentBlock?.index == 1)
    }

    @Test func aReplacedWalkthroughCanBeRestoredAtItsBlock() async {
        await start()
        controller.walkthroughNext(); controller.walkthroughNext()
        await wait()
        await presenter.present("A different answer about objects.", answerID: 4)
        await wait()
        #expect(controller.walkthrough == nil)
        #expect(controller.suspended[3]?.step == 2)
        await presenter.present(walkthrough.blocks[0].text, answerID: 3) // Undo restores the answer…
        #expect(controller.resumeSuspended(answerID: 3))               // …and the walkthrough at its block
        await wait()
        #expect(controller.currentBlock?.index == 2)
        #expect(LensModel.visibleText([glasses.shown.last!], rowWidth: 60).joined(separator: " ").hasPrefix("Now I'd use the spread operator"))
    }

    @Test func borderlineExplanationsGetOneBoundedAICheck() async {
        var calls = 0
        controller.semanticJudge = { _, _ in calls += 1; return true }
        await start()
        // Two of the key ideas in other words: borderline for Balanced.
        controller.walkthroughSpeech("Basically the Set only keeps unique stuff and that's the trick here honestly", isFinal: true)
        await wait()
        controller.walkthroughSpeech("Basically the Set only keeps unique stuff and that's the trick here honestly", isFinal: true)
        await wait()
        #expect(calls <= 1)
        #expect(controller.currentBlock?.kind == .code || calls == 0)
    }
}

// MARK: Automatic question handoff

@Suite struct HandoffPhaseTests {
    @Test func reducerFollowsTheHandoffLifecycle() {
        var phase = HandoffPhase.listening
        let script: [(HandoffPhase.Event, HandoffPhase)] = [
            (.turnDetected, .newTurnDetected), (.resolved, .followUpResolved), (.generationStarted, .generatingReplacement),
            (.replacementReady, .replacementReady), (.answerShown, .answerActive), (.turnDetected, .newTurnDetected),
            (.rejected(hasAnswer: true), .answerActive), (.turnDetected, .newTurnDetected), (.resolved, .followUpResolved),
            (.generationStarted, .generatingReplacement), (.turnDetected, .generatingReplacement), (.replacementReady, .replacementReady),
            (.switched, .switching), (.answerShown, .answerActive), (.turnDetected, .newTurnDetected), (.resolved, .followUpResolved),
            (.generationStarted, .generatingReplacement), (.cancelled(hasAnswer: true), .answerActive), (.reset, .listening),
        ]
        for (event, expected) in script {
            phase = phase.next(event)
            #expect(phase == expected, "\(event)")
        }
    }
}

@MainActor @Suite(.serialized) struct AutomaticHandoffTests {
    let clock = TestClock()
    let ai = MockAIProvider()
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let engine: ConversationEngine
    static let salesforce = "I'd check the Salesforce API logs first, then the integration user's token and the field mappings."
    static let expired = "If the API key expired, I'd rotate it in Salesforce, update the stored secret and replay the failed calls."

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses)
        let ai = self.ai, clock = self.clock
        var settings = AppSettings()
        settings.semanticClassification = false
        engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter, now: { clock.now })
        engine.start()
    }

    func say(_ text: String, speaker: SpeakerLabel = .unknown) async {
        var evidence = SpeakerEvidence.unknown
        evidence.label = speaker
        await engine.handle(CompletedTurn(text: text, start: 0, end: 1, speaker: evidence))
        await engine.generationTask?.value
    }

    @Test func confidentFollowUpReplacesTheAnswerWithoutContinue() async {
        ai.queuedAnswers = [Self.salesforce, Self.expired]
        await say("How would you troubleshoot a Salesforce integration?")
        clock.advance(4) // the wearer is reading
        await say("What if the API key expired?")
        #expect(engine.currentAnswer?.text == Self.expired) // no nextQuestion() call
        #expect(presenter.plan?.answer == Self.expired)
        #expect(ai.requests.last?.prompt.contains("Previous question: How would you troubleshoot a Salesforce integration?") == true)
        #expect(engine.handoff == .answerActive)
        #expect(!glasses.shown.contains { $0.contains("field mappings") && $0.contains("rotate") })
    }

    @Test func unrelatedNewQuestionReplacesWithoutOldContext() async {
        ai.queuedAnswers = [Self.salesforce, "HTTP 401 means the request was not authenticated."]
        await say("How would you troubleshoot a Salesforce integration?")
        clock.advance(4)
        await say("What does HTTP 401 mean?")
        #expect(engine.currentAnswer?.question == "What does HTTP 401 mean?")
        #expect(ai.requests.last?.prompt.contains("Previous question") == false)
    }

    @Test func readingAloudAcknowledgmentsAndSilenceNeverSwitch() async {
        ai.queuedAnswers = [Self.salesforce]
        await say("How would you troubleshoot a Salesforce integration?")
        clock.advance(4)
        await say("I'd check the Salesforce API logs first, then the integration user's token")
        await say("Okay.")
        await say("Right.")
        clock.advance(60) // silence
        #expect(ai.requests.count == 1)
        #expect(engine.currentAnswer?.text == Self.salesforce)
        #expect(engine.handoff == .answerActive)
    }

    @Test func mediumConfidenceIsConfirmedByEvidenceNotATimeout() async {
        ai.queuedAnswers = [Self.salesforce, "For caching I'd keep the access token until it expires and refresh it on a 401."]
        await say("How would you troubleshoot a Salesforce integration?")
        clock.advance(4)
        await say("Tell me about token caching.")              // a request, but not confident enough alone
        #expect(engine.currentAnswer?.text == Self.salesforce)
        clock.advance(120)                                      // no timeout ever switches it
        #expect(engine.currentAnswer?.text == Self.salesforce)
        await say("Tell me more about caching the token.")     // related evidence
        #expect(engine.currentAnswer?.text.hasPrefix("For caching") == true)
    }

    @Test func undoRestoresAndTheSameQuestionDoesNotOscillate() async {
        ai.queuedAnswers = [Self.salesforce, Self.expired]
        await say("How would you troubleshoot a Salesforce integration?")
        clock.advance(4)
        await say("What if the API key expired?")
        engine.undoTransition()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(engine.currentAnswer?.text == Self.salesforce)
        clock.advance(4)
        ai.queuedAnswers = [Self.expired]
        await engine.handle(CompletedTurn(text: "What if the API key has expired?", start: 0, end: 1))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.text == Self.salesforce) // needs fresh evidence, no flip-flop
        await say("What if the API key expired, how would you fix it?")
        #expect(engine.currentAnswer?.text == Self.expired)    // the evidence arrived
    }

    @Test func reconnectDuringHandoffShowsOnlyTheNewAnswer() async {
        ai.queuedAnswers = [Self.salesforce, Self.expired]
        ai.perWordDelay = .milliseconds(5)
        await say("How would you troubleshoot a Salesforce integration?")
        clock.advance(4)
        await engine.handle(CompletedTurn(text: "What if the API key expired?", start: 0, end: 1))
        glasses.simulateDrop()
        try? await Task.sleep(for: .milliseconds(40))
        glasses.connect()
        await engine.generationTask?.value
        try? await Task.sleep(for: .milliseconds(40))
        let lens = LensModel.visibleText([glasses.shown.last!], rowWidth: 60).joined(separator: " ")
        #expect(lens.hasPrefix(Self.expired)) // the new answer (with its end marker), never the old one
        #expect(!lens.contains("field mappings"))
    }
}

/// Handoff while a Code Tutor walkthrough is active, end to end through AppModel.
@MainActor @Suite(.serialized) struct HandoffDuringWalkthroughTests {
    let speech = MockSpeech()
    let ai = MockAIProvider()
    let glasses = MockGlassesDisplay()
    let model: AppModel

    init() {
        let speech = self.speech, ai = self.ai, glasses = self.glasses
        model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [speech] }, aiFactory: { _ in ai },
                         glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.settings.semanticClassification = false
        model.settings.minimumLockSeconds = 0
    }

    static let objects = """
    EXPLAIN: For objects I'd compare a key, because a Set compares objects by reference.
    CODE:
    function removeDuplicates(arr, key) {
      const seen = new Set();
      return arr.filter(item => {
        if (seen.has(item[key])) return false;
        seen.add(item[key]);
        return true;
      });
    }
    RESULT: It keeps the first object for each key value.
    """

    func ask(_ text: String, at start: Double) async {
        speech.onEvent?(.final(text, start: start, end: start + 2))
        await model.tick(now: Date().addingTimeInterval(10))
        await model.engine.generationTask?.value
        try? await Task.sleep(for: .milliseconds(80))
    }

    @Test(arguments: [false, true])
    func followUpDuringTheWalkthroughRevisesItAndUndoRestoresIt(_ onCodeBlock: Bool) async throws {
        await model.startSession()
        ai.queuedAnswers = [Walk.javascript]
        await ask("Write a JavaScript function that removes duplicate values from an array.", at: 0)
        let first = try #require(model.snippets.walkthrough)
        if onCodeBlock { model.snippets.walkthroughNext(); try? await Task.sleep(for: .milliseconds(60)) }
        let position = model.snippets.stepIndex

        ai.queuedAnswers = [Self.objects]
        await ask("What if the array contains objects?", at: 10)
        let request = try #require(ai.requests.last)
        #expect(request.prompt.contains("Active programming task"))      // same task, revised
        #expect(request.instructions.contains("Write all code in JavaScript only"))
        let revised = try #require(model.snippets.walkthrough)
        #expect(revised.id != first.id)
        #expect(model.snippets.stepIndex == 0)                           // the new walkthrough starts at its beginning
        #expect(!glasses.shown.last!.contains("[...unique]"))            // old blocks do not come back

        model.engine.undoTransition()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(model.snippets.walkthrough?.id == first.id)
        #expect(model.snippets.stepIndex == position)
    }
}
