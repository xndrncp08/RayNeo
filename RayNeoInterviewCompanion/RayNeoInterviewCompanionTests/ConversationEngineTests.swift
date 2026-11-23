import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Simulated conversations against the answer-lock state machine. Hardware-free.
@MainActor @Suite struct ConversationEngineTests {
    let clock = TestClock()
    let ai = MockAIProvider()
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let engine: ConversationEngine

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
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

    // Required cases 1–3: question detected, answer generated, delivered to display.
    @Test func interviewerQuestionIsAnsweredAndDisplayed() async {
        await say("How would you investigate a failed Salesforce integration?")
        #expect(ai.requests.count == 1)
        #expect(engine.currentAnswer?.text == ai.answer)
        #expect(Streaming.settled(glasses.shown) == [ai.answer + " \u{2713}"]) // completed answer: end marker on the final frame
        #expect(glasses.shown.first == "First, I would check the API logs and verify whether the request is reaching the backend.") // sentence-level
        #expect(engine.state == .answerLocked)
        #expect(ai.requests[0].prompt.contains("Salesforce"))
    }

    // Cases 4–5: the wearer reads the answer aloud; nothing new is generated.
    @Test func wearerReadingAnswerDoesNotTriggerGeneration() async {
        await say("How would you investigate a failed integration?")
        clock.advance(30)
        await say("First, I would check the API logs and verify whether the request is reaching the backend.")
        await say("Then I would compare the payload with the expected schema and retry the failed records.")
        #expect(ai.requests.count == 1)
        #expect(Streaming.settled(glasses.shown).count == 1)
        #expect(engine.counters.echo == 2)
        #expect(engine.state == .answerLocked)
    }

    @Test func calibratedWearerVoiceIsIgnored() async {
        await say("What is a REST API?")
        clock.advance(30)
        await say("Why would you choose PostgreSQL over MySQL?", speaker: .wearer)
        #expect(ai.requests.count == 1)
        #expect(engine.counters.wearer == 1)
    }

    // Cases 6–7: inside the short anti-oscillation cooldown a follow-up is queued and the answer is kept.
    @Test func followUpIsQueuedWhileAnswerIsFresh() async {
        ai.answer = "Row Level Security adds a policy to every query, so the performance impact depends on how the policy filters rows."
        await say("Explain how Row Level Security works.")
        clock.advance(1) // inside the 2 s cooldown
        await say("And what about the performance impact?")
        #expect(ai.requests.count == 1)
        #expect(engine.pendingQuestion?.text == "And what about the performance impact?")
        #expect(glasses.shown.count == 1)
        #expect(engine.state == .answerLocked)

        engine.nextQuestion() // manual confirmation
        await engine.generationTask?.value
        #expect(ai.requests.count == 2)
        #expect(ai.requests[1].prompt.contains("Previous question"))
        #expect(engine.pendingQuestion == nil)
    }

    @Test func confidentNewQuestionAutoAdvancesAfterMinimumLockTime() async {
        await say("What is a REST API?")
        clock.advance(15)
        ai.answer = "I would start with students, courses and an enrollment table linking them with foreign keys."
        await say("How would you design a database for tracking student enrollment?")
        #expect(ai.requests.count == 2)
        #expect(engine.counters.autoAdvanced == 1)
        #expect(glasses.shown.filter { $0 != GlassesPresenter.blankRows(5) }.count == 2) // plus blank rows between answers
    }

    @Test func autoAdvanceDisabledRequiresManualAction() async {
        engine.settings.autoAdvance = false
        await say("What is a REST API?")
        clock.advance(60)
        await say("How would you design a database for tracking student enrollment?")
        #expect(ai.requests.count == 1)
        #expect(engine.pendingQuestion != nil)
    }

    // Case 8: duplicate transcript does not cause duplicate generation.
    @Test func duplicateQuestionIsIgnored() async {
        engine.settings.lockAfterDisplay = false
        ai.answer = "Async marks a function that returns a Promise, and await pauses it until that Promise settles."
        await say("What is the difference between async and await?")
        await say("What is the difference between async and await?")
        #expect(ai.requests.count == 1)
        #expect(engine.counters.duplicate == 1)
    }

    // Case 9: silence and filler do not trigger responses.
    @Test func fillerAndSilenceDoNotTrigger() async {
        await say("Um yeah okay")
        await say("   ")
        var detector = TurnDetector(silence: 1)
        #expect(detector.tick(now: clock.now.addingTimeInterval(10)) == nil)
        #expect(ai.requests.isEmpty)
        #expect(engine.state == .listening)
    }

    // Case 13: cancellation leaves the previous display untouched.
    @Test func cancelledGenerationKeepsPreviousState() async {
        ai.perWordDelay = .milliseconds(50)
        await engine.handle(CompletedTurn(text: "What is a REST API?", start: 0, end: 1))
        #expect(engine.state == .generating)
        engine.cancelGeneration()
        await engine.generationTask?.value
        #expect(engine.currentAnswer == nil)
        #expect(glasses.shown.isEmpty)
        #expect(engine.state == .listening)
    }

    // Case 14: model unavailable → explicit error, no fabricated answer, keeps listening.
    @Test func unavailableModelReportsErrorAndRecovers() async {
        ai.status = .unavailable("Apple Intelligence is off")
        await say("What is a REST API?")
        #expect(engine.currentAnswer == nil)
        #expect(glasses.shown.isEmpty)
        #expect(engine.log.contains { $0.message.contains("Apple Intelligence is off") })
        #expect(engine.state == .listening)
    }

    @Test func generationFailurePreservesExistingAnswer() async {
        await say("What is a REST API?")
        ai.failure = TestError()
        engine.unlock()
        await say("How would you design a database for tracking student enrollment?")
        #expect(engine.currentAnswer?.question == "What is a REST API?")
        #expect(glasses.shown.count == 1)
        #expect(engine.state == .waitingForNextQuestion)
    }

    /// Automatic question handoff: a confident new question during generation replaces the stale one.
    @Test func confidentQuestionDuringGenerationReplacesItAutomatically() async {
        ai.perWordDelay = .milliseconds(10)
        await engine.handle(CompletedTurn(text: "What is a REST API?", start: 0, end: 1))
        await engine.handle(CompletedTurn(text: "How do you troubleshoot a Microsoft 365 login issue?", start: 1, end: 2))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.question == "How do you troubleshoot a Microsoft 365 login issue?")
        #expect(glasses.shown.count == 1) // the cancelled REST answer never reached the lens
    }

    // Case 15: stopping clears transient state and ignores later speech.
    @Test func stoppedEngineIgnoresSpeech() async {
        engine.stop()
        await say("What is a REST API?")
        #expect(engine.state == .idle)
        #expect(ai.requests.isEmpty)
    }

    @Test func manualLockUnlock() async {
        engine.settings.lockAfterDisplay = false
        await say("What is a REST API?")
        #expect(engine.state == .waitingForNextQuestion)
        engine.lock()
        #expect(engine.state == .answerLocked)
        engine.unlock()
        #expect(engine.state == .waitingForNextQuestion)
    }

    @Test func cachedAnswerSkipsModel() async {
        engine.settings.lockAfterDisplay = false
        await say("What is a REST API?")
        clock.advance(400) // past the duplicate window
        await say("What is a REST API?")
        #expect(ai.requests.count == 1)
        #expect(engine.currentAnswer?.fromCache == true)
    }

    // Case 17: long sessions stay bounded.
    @Test func longSessionsStayBounded() async {
        for index in 0..<600 { await say("This is statement number \(index) about the weather.") }
        #expect(engine.log.count <= 200)
        var buffer = TranscriptBuffer()
        for index in 0..<10_000 { buffer.append(TranscriptSegment(text: "Segment \(index) with some words in it", start: Double(index), end: Double(index) + 1)) }
        #expect(buffer.segments.count <= 200)
        #expect(buffer.characterCount <= 20_000)
    }
}

@Suite struct TurnDetectorTests {
    @Test func turnEndsOnlyAfterSilence() {
        let start = Date(timeIntervalSince1970: 0)
        var detector = TurnDetector(silence: 1.2)
        detector.partial("What is", at: start)
        #expect(detector.tick(now: start.addingTimeInterval(0.5)) == nil)
        detector.final("What is a closure?", start: 0, end: 1.4, at: start.addingTimeInterval(1))
        #expect(detector.tick(now: start.addingTimeInterval(1.5)) == nil)
        detector.voiceActivity(at: start.addingTimeInterval(1.8))
        #expect(detector.tick(now: start.addingTimeInterval(2.5)) == nil)
        let turn = detector.tick(now: start.addingTimeInterval(3.1))
        #expect(turn?.text == "What is a closure?")
        #expect(detector.tick(now: start.addingTimeInterval(10)) == nil)
    }

    @Test func multiSegmentTurnIsJoinedAndDeduplicated() {
        let start = Date(timeIntervalSince1970: 0)
        var detector = TurnDetector(silence: 1)
        detector.final("Tell me about a project", start: 0, end: 2, at: start)
        detector.final("Tell me about a project", start: 0, end: 2, at: start)
        detector.final("you developed recently.", start: 2, end: 3, at: start.addingTimeInterval(0.5))
        #expect(detector.tick(now: start.addingTimeInterval(2))?.text == "Tell me about a project you developed recently.")
    }
}
