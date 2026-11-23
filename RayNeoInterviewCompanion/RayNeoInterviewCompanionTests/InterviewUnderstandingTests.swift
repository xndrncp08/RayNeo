import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Answers that cover the stated requirements, so validation does not regenerate them.
enum Spoken {
    static let jobs = "I'd store each submission as a durable job in the database in the same transaction as the enrolment, so no job is lost. Workers pull jobs with a lease, so if a worker crashes the lease expires and another worker retries it. Each job carries an idempotency key, so duplicate requests don't send a second email. When the email provider has an outage, retries use exponential backoff with jitter, and jobs that keep failing go to a dead-letter queue. Thousands of submissions are fine because the queue absorbs the load and I can scale workers. Delivery is at-least-once, so the provider's own idempotency matters too."
    static let generic = "I'd look at the logs first, then fix the cause and confirm it worked."
    static let incidents = "I'd handle the exam classroom outage first because it's disrupting an exam right now. Then the Salesforce leads, then the Microsoft 365 sign-in for one person, and I'd keep staff updated throughout."
}

// MARK: Intent detection

@Suite struct InterviewIntentTests {
    let detector = QuestionDetector()

    @Test(arguments: [
        ("How does async/await work?", InterviewIntent.Kind.question),
        ("Explain async/await.", .explanation),
        ("Compare TypeScript and JavaScript.", .comparison),
        ("Design a scalable notification system.", .systemDesign),
        ("Write a function that removes duplicates.", .coding),
        ("Walk me through your authentication architecture.", .architecture),
        ("Our Salesforce integration stopped receiving leads.", .troubleshooting),
        ("Let's say a classroom loses internet during an exam. Explain your approach.", .situational),
        ("Tell me about your most complicated project.", .behavioural),
        ("Describe how you would diagnose a memory leak.", .troubleshooting),
        ("Our API is returning 500 errors. Walk me through your approach.", .troubleshooting),
        ("Restore account access without disabling MFA.", .security),
        ("Build a React component that filters students.", .coding),
        ("Tell me about a time you solved a difficult problem.", .behavioural),
        ("Design a background job processing system for sending enrolment confirmation emails. The application must handle thousands of submissions, temporary email provider outages, duplicate requests, and worker crashes without losing jobs.", .systemDesign),
        ("Okay, so implement a function to remove duplicate records", .coding),
        ("I'd like you to explain how indexing works in PostgreSQL", .explanation),
    ])
    func actionablePromptsAreRecognisedWithoutQuestionMarks(_ text: String, _ kind: InterviewIntent.Kind) {
        let intent = InterviewIntent.classify(text)
        #expect(intent.kind == kind, "\(text): \(intent.kind) (\(intent.reason))")
        #expect(detector.analyze(text).score >= 0.5, "\(text): \(detector.analyze(text).reason)")
    }

    @Test(arguments: ["Okay.", "Give me one second.", "Let me open the project.", "I'm going to share my screen.", "We'll start shortly.",
                      "Okay, I'm just opening the project now.", "Can you hear me okay?", "Sounds good, thanks.",
                      "Design a background job processing system for", "So I'd use a queue for that and then", "Um, yeah."])
    func smallTalkFillerAndIncompleteSpeechAreNotRequests(_ text: String) {
        #expect(detector.analyze(text).score < 0.5, "\(text): \(detector.analyze(text).reason)")
        #expect(!InterviewIntent.classify(text).actionable)
    }

    @Test func requirementsAndPartsAreExtracted() {
        let jobs = InterviewIntent.classify("Design a background job processing system for sending enrolment confirmation emails. The application must handle thousands of submissions, temporary email provider outages, duplicate requests, and worker crashes without losing jobs.")
        let joined = jobs.requirements.joined(separator: " | ")
        for constraint in ["thousands of submissions", "temporary email provider outages", "duplicate requests", "worker crashes", "losing jobs"] {
            #expect(joined.contains(constraint), "\(constraint) missing from \(joined)")
        }
        let multi = InterviewIntent.classify("Design the system, explain the trade-offs, and describe how you'd test it.")
        #expect(multi.parts.count == 3)
        #expect(multi.guidance(length: .standard).contains("3 parts"))
    }

    @Test func completenessCheckFindsOmittedRequirementsWithoutAnotherModelCall() {
        let jobs = InterviewIntent.classify("Design a job system. It must handle duplicate requests and worker crashes without losing jobs.")
        #expect(jobs.missingRequirements(in: Spoken.jobs).isEmpty)
        let missing = jobs.missingRequirements(in: "I'd use a queue and retry failed jobs with backoff.")
        #expect(missing.contains { $0.contains("duplicate") })
        #expect(missing.contains { $0.contains("crash") })
    }

    @Test func guidanceAdaptsToTheRequestTypeAndLength() {
        let design = InterviewIntent.classify("Design a scalable notification system.")
        #expect(design.guidance(length: .standard).contains("at-least-once"))
        #expect(design.maximumTokens(.standard) > AnswerLength.standard.maximumTokens)
        let security = InterviewIntent.classify("How would you restore access safely without weakening security for the entire organization?")
        #expect(security.kind == .security)
        let guidance = security.guidance(length: .short)
        #expect(guidance.contains("Verify identity") && guidance.contains("least privilege") && guidance.contains("organisation-wide"))
        let comparison = InterviewIntent.classify("Compare REST APIs and GraphQL.")
        #expect(comparison.guidance(length: .standard).contains("both sides"))
        let behavioural = InterviewIntent.classify("Tell me about your most complicated project.")
        #expect(behavioural.guidance(length: .standard).contains("instead of inventing"))
    }

    @Test func continuationsCompleteThePreviousRequestButQuestionsDoNot() {
        let design = "Design a background job processing system for sending enrolment confirmation emails."
        #expect(InterviewIntent.isContinuation("The application must handle thousands of submissions and worker crashes without losing jobs.", of: design))
        #expect(InterviewIntent.isContinuation("Walk me through your approach.", of: "Our Salesforce integration stopped receiving leads."))
        #expect(!InterviewIntent.isContinuation("What happens if the worker crashes?", of: design))
        #expect(!InterviewIntent.isContinuation("Compare REST and GraphQL.", of: design))
        #expect(!InterviewIntent.isContinuation("I'd use a durable queue for that.", of: design))
        #expect(!InterviewIntent.isContinuation("The worker should be fine.", of: "Okay."))
    }
}

// MARK: Transcript assembly

@Suite struct LongPromptAssemblyTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func emitted(_ assembler: inout TranscriptTurnAssembler, at seconds: Double) -> [ConversationTurn] {
        guard case .turn(let turn)? = assembler.tick(now: t0.addingTimeInterval(seconds)) else { return [] }
        return [turn]
    }

    @Test func aRestartedRecognizerRepeatingTheTailIsStitchedNotDuplicated() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        assembler.partial("Des", at: t0)
        assembler.partial("Design a background job processing system for sending enrolment confirmation emails", at: t0.addingTimeInterval(3))
        _ = assembler.final("Design a background job processing system for sending enrolment confirmation emails. The application must handle thousands of submissions, tem",
                            start: 0, end: 8, at: t0.addingTimeInterval(8))
        _ = assembler.final("The application must handle thousands of submissions, temporary email provider outages, duplicate requests, and worker crashes without losing jobs.",
                            start: 8, end: 14, at: t0.addingTimeInterval(14))
        let turns = emitted(&assembler, at: 16)
        #expect(turns.count == 1)
        let text = turns.first?.text ?? ""
        #expect(text.components(separatedBy: "The application must handle").count == 2) // exactly once
        #expect(!text.contains(" tem "))
        for constraint in ["thousands of submissions", "temporary email provider outages", "duplicate requests", "worker crashes without losing jobs"] {
            #expect(text.contains(constraint))
        }
    }

    @Test func revisionsKeepTheLongerReadingAndRepeatedFinalsAreDropped() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        let full = "Design a background job processing system that handles worker crashes and duplicate requests."
        _ = assembler.final(full, start: 0, end: 5, at: t0)
        _ = assembler.final("Design a background job processing system", start: 0, end: 3, at: t0.addingTimeInterval(0.2))
        _ = assembler.final(full, start: 0, end: 5, at: t0.addingTimeInterval(0.3))
        let turns = emitted(&assembler, at: 2)
        #expect(turns.map(\.text) == [full])
        #expect(assembler.duplicates == 2)
    }

    @Test func aBriefPauseDoesNotTruncateAndAScenarioWaitsForItsTask() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("Design a background job processing system.", start: 0, end: 3, at: t0)
        #expect(emitted(&assembler, at: 0.9).isEmpty)
        _ = assembler.final("It must survive worker crashes.", start: 3.9, end: 6, at: t0.addingTimeInterval(1.0))
        #expect(emitted(&assembler, at: 2.3).first?.text == "Design a background job processing system. It must survive worker crashes.")

        var scenario = TranscriptTurnAssembler(silence: 1.2)
        _ = scenario.final("Our Salesforce integration suddenly stopped receiving leads.", start: 0, end: 3, at: t0)
        #expect(emitted(&scenario, at: 1.6).isEmpty) // a scenario without its task waits longer
        _ = scenario.final("Walk me through your approach.", start: 4.7, end: 6, at: t0.addingTimeInterval(1.8))
        #expect(emitted(&scenario, at: 3.1).first?.text == "Our Salesforce integration suddenly stopped receiving leads. Walk me through your approach.")

        var alone = TranscriptTurnAssembler(silence: 1.2)
        _ = alone.final("Our Salesforce integration suddenly stopped receiving leads.", start: 0, end: 3, at: t0)
        #expect(emitted(&alone, at: 2.5).count == 1) // …but never indefinitely
    }

    @Test func aContinuationIsAbsorbedIntoThePreviousTurn() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("Design a background job processing system.", start: 0, end: 3, at: t0)
        let first = emitted(&assembler, at: 2)
        _ = assembler.final("The application must handle duplicate requests.", start: 4, end: 7, at: t0.addingTimeInterval(7))
        let second = emitted(&assembler, at: 9)
        let merged = assembler.absorb(second[0])
        #expect(merged?.id == first[0].id && merged?.revision == 1)
        #expect(merged?.text == "Design a background job processing system. The application must handle duplicate requests.")
        #expect(assembler.turns.count == 1)
    }

    @Test func theReadableTranscriptKeepsOneEntryPerRevisedSegment() {
        var buffer = TranscriptBuffer()
        buffer.append(TranscriptSegment(text: "And after I push a fix, I monitor", start: 0, end: 3))
        buffer.append(TranscriptSegment(text: "And after I push a fix, I monitor the database performance metrics.", start: 0, end: 5))
        buffer.append(TranscriptSegment(text: "the database performance metrics. Then I check the logs.", start: 5, end: 8))
        #expect(buffer.segments.map(\.text) == ["And after I push a fix, I monitor the database performance metrics. Then I check the logs."])
        buffer.append(TranscriptSegment(text: "A different question now.", start: 9, end: 10))
        #expect(buffer.segments.count == 2)
    }
}

// MARK: Context tracking

@Suite struct InterviewContextTests {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    static let incidents = "The college has three incidents. The examination classroom has lost internet, one staff member cannot sign into Microsoft 365, and the Salesforce integration has stopped receiving enrolment leads."

    @Test func incidentsAndReferencesResolveAgainstTheScenario() throws {
        var context = InterviewContext()
        _ = context.record(Self.incidents, turnID: 1, at: t0)
        #expect(context.incidents.count == 3)
        #expect(context.incidents[1].contains("Microsoft 365"))
        let request = "Explain how you prioritize these incidents, investigate them, and communicate with affected staff."
        _ = context.record(request, turnID: 2, at: t0.addingTimeInterval(20))
        let note = try #require(context.promptNote(for: request))
        #expect(note.contains("1) The examination classroom has lost internet"))
        #expect(note.contains("2) one staff member cannot sign into Microsoft 365"))
        #expect(note.contains("3) the Salesforce integration has stopped receiving enrolment leads"))
        #expect(note.contains("refers to the 3 incidents above"))
        #expect(!note.contains(request)) // the request itself is sent once, as the interviewer's question

        let second = try #require(context.promptNote(for: "What about the second one?"))
        #expect(second.contains("most likely means incident 2: one staff member cannot sign into Microsoft 365"))
        #expect(try #require(context.promptNote(for: "How would you prioritize these?")).contains("3 incidents"))
        #expect(try #require(context.promptNote(for: "Explain the trade-offs.")).contains("refers to the scenario above"))
    }

    @Test func severalStatementsBuildOneScenarioAndAClearTopicChangeExpiresIt() {
        var context = InterviewContext()
        #expect(context.record("Our college runs Moodle for coursework.", turnID: 1, at: t0) == .added)
        #expect(context.record("Students upload assignments every Friday afternoon.", turnID: 2, at: t0.addingTimeInterval(5)) == .added)
        #expect(context.record("Last week uploads started failing for large files.", turnID: 3, at: t0.addingTimeInterval(9)) == .added)
        #expect(context.record("How would you investigate it?", turnID: 4, at: t0.addingTimeInterval(12)) == .added)
        #expect(context.statements.count == 4)
        #expect(context.record("Compare REST APIs and GraphQL.", turnID: 5, at: t0.addingTimeInterval(200)) == .newTopic("unrelated request"))
        #expect(context.statements.map(\.turnID) == [5])
        #expect(context.record("Let's move on. Explain how PostgreSQL indexes work.", turnID: 6, at: t0.addingTimeInterval(260)) == .newTopic("explicit topic change"))
        #expect(context.record("And what about composite ones?", turnID: 7, at: t0.addingTimeInterval(1_000)) == .newTopic("previous context is stale"))
    }

    @Test func candidateSpeechSmallTalkAndRevisionsAreHandled() {
        var context = InterviewContext()
        #expect(context.record("Okay, give me one second.", turnID: 1, at: t0) == .ignored("small talk or incomplete"))
        #expect(context.record("I'd check the switch first and then the access point.", turnID: 2, at: t0) == .ignored("candidate's voice"))
        _ = context.record("Our API is returning 500 errors", turnID: 3, at: t0)
        #expect(context.record("Our API is returning 500 errors since this morning's deploy.", turnID: 3, at: t0.addingTimeInterval(1)) == .revised)
        #expect(context.statements.map(\.text) == ["Our API is returning 500 errors since this morning's deploy."])
    }

    @Test func anUnresolvableReferenceAsksForAStatedAssumptionNotInventedDetail() throws {
        let note = try #require(InterviewContext().promptNote(for: "How would you prioritize them?"))
        #expect(note.contains("was not captured") && note.contains("assumption"))
        #expect(InterviewContext().promptNote(for: "Compare REST APIs and GraphQL.") == nil)
    }

    @Test func referenceDetection() {
        #expect(ContextReference.detect("Explain how you prioritize these incidents").plural)
        #expect(ContextReference.detect("What about the second one?").ordinal == 2)
        #expect(ContextReference.detect("Can you elaborate?").implicit)
        #expect(ContextReference.detect("What happens next?").implicit)
        #expect(ContextReference.detect("What if it fails?").refersBack)
        #expect(ContextReference.detect("Would your approach change?").refersBack)
        #expect(!ContextReference.detect("Compare REST APIs and GraphQL.").refersBack)
        #expect(!ContextReference.detect("Design a scalable notification system.").refersBack)
    }
}

// MARK: End to end (speech events → assembly → intent → context → Gemini request → teleprompter)

@MainActor @Suite(.serialized) struct InterviewUnderstandingFlowTests {
    let speech = MockSpeech()
    let ai = MockAIProvider()
    let glasses = MockGlassesDisplay()
    let model: AppModel
    var clock = 0.0

    init() {
        let speech = self.speech, ai = self.ai, glasses = self.glasses
        model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [speech] }, aiFactory: { _ in ai },
                         glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.settings.semanticClassification = false
        model.settings.minimumLockSeconds = 0
        model.settings.aiModel = .geminiFlash // the interview context is sent by default; personal memory is not
    }

    /// One finalized utterance at `start` seconds on the capture timeline, then enough silence to end the turn.
    func say(_ text: String, at start: Double, seconds: Double = 3) async {
        speech.onEvent?(.final(text, start: start, end: start + seconds))
        await model.tick(now: Date().addingTimeInterval(10))
        await model.engine.generationTask?.value
    }

    var lastPrompt: String { ai.requests.last?.prompt ?? "" }

    @Test(arguments: [false, true])
    func testA_anInstructionWithoutAQuestionMarkProducesOneCompleteRequest(_ continuous: Bool) async throws {
        model.settings.continuousConversation = continuous
        await model.startSession()
        ai.queuedAnswers = [Spoken.jobs]
        let start = 100.0
        speech.onEvent?(.partial("Design a back"))
        speech.onEvent?(.partial("Design a background job processing system"))
        speech.onEvent?(.final("Design a background job processing system for sending enrolment confirmation emails. The application must handle thousands of submissions, tem", start: start, end: start + 8))
        speech.onEvent?(.final("The application must handle thousands of submissions, temporary email provider outages, duplicate requests, and worker crashes without losing jobs.", start: start + 8, end: start + 14))
        speech.onEvent?(.final("The application must handle thousands of submissions, temporary email provider outages, duplicate requests, and worker crashes without losing jobs.", start: start + 8, end: start + 14))
        await model.tick(now: Date().addingTimeInterval(10))
        await model.engine.generationTask?.value
        #expect(generations(ai) == 1)
        #expect(ai.requests.count == 1) // the answer covered every requirement: no regeneration
        let prompt = lastPrompt
        #expect(prompt.contains("system design task"))
        for constraint in ["thousands of submissions", "temporary email provider outages", "duplicate requests", "worker crashes", "losing jobs"] {
            #expect(prompt.contains("requirements; your answer must address each one") && prompt.contains(constraint))
        }
        #expect(prompt.components(separatedBy: "The application must handle").count == 2)
        #expect((ai.requests.last?.maximumTokens ?? 0) > AnswerLength.standard.maximumTokens)
        #expect(model.engine.currentAnswer?.text == Spoken.jobs)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(glasses.shown.last.map { LensModel.visibleText([$0], rowWidth: 60).joined(separator: " ").hasPrefix("I'd store each submission") } == true)
        #expect(model.finalizedTurns.count == 1)
    }

    @Test func aConstraintSpokenAfterAPauseRevisesTheSameRequest() async {
        await model.startSession()
        ai.queuedAnswers = ["I'd put each email job on a background queue and have workers send the confirmation emails.", Spoken.jobs]
        await say("Design a background job processing system for enrolment confirmation emails.", at: 0, seconds: 4)
        #expect(generations(ai) == 1)
        await say("The application must handle duplicate requests and worker crashes without losing jobs.", at: 5.5, seconds: 5)
        #expect(generations(ai) == 2)
        #expect(lastPrompt.contains("Design a background job processing system") && lastPrompt.contains("worker crashes"))
        #expect(model.finalizedTurns.count == 1)
        #expect(model.engine.currentAnswer?.text == Spoken.jobs)
        #expect(!lastPrompt.contains("put each email job on a background queue")) // the superseded answer is not context
    }

    @Test func aMissingRequirementTriggersOneTargetedRegeneration() async {
        await model.startSession()
        ai.queuedAnswers = ["I'd use a queue and retry failed jobs with backoff, and monitor it.", Spoken.jobs]
        await say("Design a job system. It must handle duplicate requests and worker crashes without losing jobs.", at: 0)
        #expect(ai.requests.count == 2)
        #expect(ai.requests.last?.instructions.contains("did not address the interviewer's requirement") == true)
        #expect(model.engine.currentAnswer?.text == Spoken.jobs)
    }

    @Test func testB_secureAccessRestorationGetsTheSecurityStructure() async {
        await model.startSession()
        ai.answer = "First, I'd verify the user's identity and check the Entra ID sign-in logs to see whether it's a lockout, an MFA issue or a permission problem. Then I'd restore only the access that user needs without changing organisation-wide security policies, and confirm they can sign in."
        await say("How would you restore access safely without weakening security for the entire organization?", at: 0)
        #expect(generations(ai) == 1)
        #expect(lastPrompt.contains("security scenario") && lastPrompt.contains("Verify identity") && lastPrompt.contains("least privilege"))
        #expect(model.engine.currentAnswer != nil)
    }

    @Test func testC_aFollowUpKeepsTheDesignAsContextAndIsNeverServedFromCache() async {
        await model.startSession()
        ai.queuedAnswers = [Spoken.jobs]
        await say("Design a background job processing system for enrolment emails that survives worker crashes and duplicate requests without losing jobs.", at: 0)
        let first = model.engine.currentAnswer?.answerID
        ai.answer = "The worker would retry the job after its lease expires, so the email could be sent twice; an idempotency key per enrolment and a sent marker make that unlikely, but email can't be guaranteed exactly once."
        await say("What happens if the worker crashes after sending an email but before acknowledging the job?", at: 20)
        #expect(generations(ai) == 2)
        #expect(lastPrompt.contains("This is a follow-up"))
        #expect(lastPrompt.contains("Design a background job processing system")) // the earlier request is context
        #expect(model.engine.currentAnswer?.answerID != first)
        // The same follow-up again in an unrelated topic is generated afresh, not taken from the cache.
        await say("Let's move on. Design a video transcoding pipeline that handles worker crashes.", at: 60)
        await say("What happens if the worker crashes after sending an email but before acknowledging the job?", at: 90)
        #expect(model.engine.currentAnswer?.fromCache == false)
    }

    @Test func testD_logisticsNeitherCallGeminiNorInterruptTheAnswer() async {
        await model.startSession()
        await say("Explain how database indexes speed up queries.", at: 0)
        let requests = ai.requests.count, answer = model.engine.currentAnswer?.answerID
        await say("Okay, I'm just opening the project now.", at: 10)
        await say("Give me one second.", at: 15)
        #expect(ai.requests.count == requests)
        #expect(model.engine.currentAnswer?.answerID == answer)
        #expect(model.finalizedTurns.count == 3) // still transcribed
    }

    @Test(arguments: [false, true])
    func requiredExample_theRequestCarriesTheThreeIncidents(_ continuous: Bool) async throws {
        model.settings.continuousConversation = continuous
        await model.startSession()
        ai.answer = Spoken.incidents
        await say(InterviewContextTests.incidents, at: 0, seconds: 9)
        await say("Explain how you prioritize these incidents, investigate them, and communicate with affected staff.", at: 30)
        let prompt = lastPrompt
        #expect(prompt.contains("Interviewer: Explain how you prioritize these incidents"))
        #expect(prompt.contains("The examination classroom has lost internet"))
        #expect(prompt.contains("cannot sign into Microsoft 365"))
        #expect(prompt.contains("stopped receiving enrolment leads"))
        #expect(prompt.contains("refers to the 3 incidents above"))
        #expect(!prompt.contains("PostgreSQL")) // "Explain" no longer selects the PostgreSQL EXPLAIN notes
        #expect(prompt.contains("troubleshooting scenario") && prompt.contains("This request has 3 parts"))
        #expect(prompt.components(separatedBy: "The college has three incidents").count == 2) // the scenario is sent once

        await say("What about the second one?", at: 50)
        #expect(lastPrompt.contains("most likely means incident 2: one staff member cannot sign into Microsoft 365"))
        await say("Would your approach change if the outage also hit the staff room?", at: 70)
        #expect(lastPrompt.contains("The examination classroom has lost internet")) // several follow-ups, one scenario
    }

    @Test func anUnrelatedNewQuestionGetsNoStaleScenario() async {
        await model.startSession()
        ai.answer = Spoken.incidents
        await say(InterviewContextTests.incidents, at: 0, seconds: 9)
        await say("How would you prioritize these?", at: 20)
        #expect(lastPrompt.contains("Microsoft 365"))
        ai.answer = "REST exposes resources over fixed endpoints, while GraphQL lets the client ask for exactly the fields it needs through one endpoint."
        await say("Compare REST APIs and GraphQL.", at: 40)
        #expect(!lastPrompt.contains("Microsoft 365"))
        #expect(!lastPrompt.contains("Conversation so far"))
    }

    @Test func contextGivenBeforeTheQuestionInSeparateStatementsReachesTheRequest() async {
        await model.startSession()
        await say("Our college runs Moodle for coursework.", at: 0)
        await say("Students upload assignments every Friday afternoon.", at: 5)
        #expect(ai.requests.isEmpty) // statements are context, not questions
        await say("Last week uploads started failing for large files.", at: 10)
        await say("How would you investigate it?", at: 25)
        #expect(lastPrompt.contains("Moodle") && lastPrompt.contains("Friday") && lastPrompt.contains("failing for large files"))
    }

    @Test func theInterviewContextRespectsTheGeminiPrivacySetting() async {
        model.settings.geminiIncludeInterviewContext = false
        await model.startSession()
        await say("Our college runs Moodle for coursework.", at: 0)
        await say("How would you investigate slow uploads there?", at: 10)
        #expect(!lastPrompt.contains("Moodle for coursework"))
    }

    @Test(arguments: [false, true])
    func answerEchoIsIgnoredButAnInterruptionInsideItIsAnswered(_ continuous: Bool) async throws {
        model.settings.continuousConversation = continuous
        await model.startSession()
        ai.queuedAnswers = [Spoken.jobs]
        await say("Design a background job system that handles duplicate requests and worker crashes without losing jobs.", at: 0)
        let requests = ai.requests.count
        // The wearer reads the answer aloud while the microphone stays on.
        await say("Workers pull jobs with a lease, so if a worker crashes the lease expires and another worker retries it.", at: 20, seconds: 6)
        #expect(ai.requests.count == requests)
        #expect(model.finalizedTurns.last?.role == "Reading the answer")
        #expect(model.conversation.interview.statements.count == 1) // the echo is not interviewer context
        // Reading continues, then the interviewer interrupts in the same turn.
        ai.answer = "If the queue itself goes down, producers keep jobs in the database outbox and publish them once it recovers."
        await say("Each job carries an idempotency key, so duplicate requests don't send a second email. Sorry, what happens if the queue itself goes down?", at: 40, seconds: 8)
        #expect(ai.requests.count == requests + 1)
        let prompt = try #require(ai.requests.last?.prompt)
        #expect(prompt.contains("Interviewer: Sorry, what happens if the queue itself goes down?"))
        // A genuine question that shares words with the answer is not discarded.
        await say("Why would you put jobs that keep failing into a dead-letter queue instead of retrying forever?", at: 70)
        #expect(ai.requests.count == requests + 2)
    }

    @Test func emptyAndFailedGenerationsAreNotShownAsCompleteAnswers() async {
        await model.startSession()
        ai.answer = ""
        await say("Explain how database indexes speed up queries.", at: 0)
        #expect(model.engine.currentAnswer?.generationComplete != true)
        ai.answer = Spoken.generic
        ai.failure = TestError()
        await say("Explain how load balancers work.", at: 10)
        try? await Task.sleep(for: .seconds(2.2))
        #expect(model.engine.state != .generating)
        ai.failure = nil
        ai.answer = "A load balancer spreads requests across several servers and stops sending traffic to ones that fail health checks."
        await say("Explain how load balancers distribute traffic.", at: 20)
        #expect(model.engine.currentAnswer?.text.hasPrefix("A load balancer") == true) // recoverable
    }
}
