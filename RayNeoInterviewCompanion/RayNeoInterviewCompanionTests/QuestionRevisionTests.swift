import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// The real-device report: SpeechAnalyzer finalizes the question in two parts and the answer was generated (and
/// locked) from the first. Exact wording from the screenshot.
enum Screenshot {
    static let first = "Explain how you'd secure a Next.js application using Supabase Authentication and PostgreSQL RLS"
    static let second = "especially when students, instructors, and administrators have different access permissions."
    static let full = first + ", " + second
    static let partialAnswer = "I'd use Supabase Auth for sign-in in the Next.js app and turn on PostgreSQL RLS so every query is checked against the signed-in user."
    /// Mentions every keyword but treats the roles as one group: the failure the report describes.
    static let keywordsOnly = "I'd secure the Next.js application with Supabase Authentication and PostgreSQL RLS policies for students, instructors, and administrators. That way permissions are handled in the database for all of them."
    static let good = "I'd use Supabase Authentication for sign-in and store each user's role, student, instructor or administrator, in a profiles table the client can't edit. Students can only read and update rows they own, because the RLS policy compares the row's owner to auth.uid(). Instructors can see submissions only for courses they're assigned to, through a policy that joins the course assignments table. Administrators get full management rights through a role check in the policy, and the service role key stays on the server, never in the Next.js client. RLS is enabled on every table, so the database enforces this even if a UI check is skipped. To test authorization, I'd sign in as each role and confirm a student can't read another student's rows and an instructor can't see an unassigned course."
}

@Suite struct UnfinishedClauseTests {
    let t0 = Date(timeIntervalSince1970: 4_000_000)

    @Test func clausesCutAtACommaOrQualifierAreUnfinished() {
        #expect(TranscriptTurnAssembler.isIncomplete(Screenshot.first + ","))
        #expect(TranscriptTurnAssembler.isIncomplete("Explain how RLS works, especially"))
        #expect(TranscriptTurnAssembler.isIncomplete("Design the schema so that"))
        #expect(!TranscriptTurnAssembler.isIncomplete("Can you explain that?"))
        #expect(!TranscriptTurnAssembler.isIncomplete(Screenshot.first + "."))
        #expect(InterviewIntent.classify(Screenshot.first + ",").kind == .incomplete)
    }

    @Test func theCommaVariantWaitsAndBecomesOneTurn() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final(Screenshot.first + ",", start: 0, end: 5, at: t0)
        #expect(assembler.tick(now: t0.addingTimeInterval(2.0)) == nil) // unfinished: no answer yet
        _ = assembler.final(Screenshot.second, start: 7, end: 11, at: t0.addingTimeInterval(2.2))
        guard case .turn(let turn)? = assembler.tick(now: t0.addingTimeInterval(3.5)) else { Issue.record("no turn"); return }
        #expect(turn.text == Screenshot.full)
    }

    @Test func qualifierClausesContinueTheRequestButNewQuestionsDoNot() {
        #expect(InterviewIntent.isContinuation(Screenshot.second, of: Screenshot.first + "."))
        #expect(InterviewIntent.isContinuation(Screenshot.second, of: Screenshot.first + ","))
        #expect(InterviewIntent.isContinuation("Particularly for the admin dashboard.", of: Screenshot.first + "."))
        #expect(!InterviewIntent.isContinuation("When would you use Redis instead", of: Screenshot.first + "."))
        #expect(!InterviewIntent.isContinuation("What about rate limiting?", of: Screenshot.first + "."))
    }

    @Test func rolesMustBeExplainedIndividuallyNotJustNamed() {
        let intent = InterviewIntent.classify(Screenshot.full)
        #expect(intent.kind == .security)
        #expect(intent.items == ["students", "instructors", "administrators"])
        let guidance = intent.guidance(length: .standard)
        #expect(guidance.contains("For each role") && guidance.contains("row level security") && guidance.contains("test authorization for each role"))
        #expect(guidance.contains("students; instructors; administrators"))
        let missing = intent.missingRequirements(in: Screenshot.keywordsOnly)
        #expect(missing.contains("students (named but not explained individually)"))
        #expect(missing.contains("instructors (named but not explained individually)"))
        #expect(missing.contains("administrators (named but not explained individually)"))
        #expect(missing.contains("how you'd test authorization for each role"))
        #expect(intent.missingRequirements(in: Screenshot.good).isEmpty, "\(intent.missingRequirements(in: Screenshot.good))")
    }
}

@MainActor @Suite(.serialized) struct QuestionRevisionFlowTests {
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
        model.settings.aiModel = .geminiFlash
    }

    var lens: [String] { glasses.shown.map { LensModel.visibleText([$0], rowWidth: 60).joined(separator: " ") } }

    /// The two finals with a pause long enough to end the first turn (the device behaviour).
    func speakInTwoParts(firstEnd: String) async {
        speech.onEvent?(.final(Screenshot.first + firstEnd, start: 0, end: 5))
        await model.tick(now: Date().addingTimeInterval(firstEnd == "," ? 3 : 1.5))
        await model.engine.generationTask?.value
        speech.onEvent?(.final(Screenshot.second, start: 6.5, end: 11))
        await model.tick(now: Date().addingTimeInterval(3))
        await model.engine.generationTask?.value
    }

    @Test(arguments: [(false, "."), (false, ","), (true, "."), (true, ",")])
    func theFinalizedQuestionReplacesTheAnswerToItsFirstHalf(_ continuous: Bool, _ firstEnd: String) async throws {
        model.settings.continuousConversation = continuous
        await model.startSession()
        ai.queuedAnswers = [Screenshot.partialAnswer, Screenshot.keywordsOnly, Screenshot.good]
        await speakInTwoParts(firstEnd: firstEnd)
        let answer = try #require(model.engine.currentAnswer)
        // The active question is the finalized one, answered as a new question (not a follow-up to itself).
        #expect(answer.question == Screenshot.full)
        #expect(model.engine.currentQuestion?.text == Screenshot.full)
        #expect(answer.kind == .newQuestion)
        #expect(model.finalizedTurns.map(\.normalized) == [Screenshot.full])
        let request = try #require(ai.requests.first { $0.prompt.contains("Interviewer: " + Screenshot.full) })
        #expect(!request.prompt.contains("This is a follow-up") && !request.prompt.contains("Previous question"))
        #expect(!request.prompt.contains(Screenshot.partialAnswer)) // the superseded answer is not context
        #expect(request.prompt.contains("For each role") && request.prompt.contains("students; instructors; administrators"))
        // The keyword-only draft was rejected for the roles and testing; the displayed answer covers each point.
        let retry = try #require(ai.requests.last)
        #expect(retry.instructions.contains("administrators (named but not explained individually)"))
        #expect(retry.instructions.contains("test authorization"))
        #expect(answer.text == Screenshot.good)
        for point in ["Students can only read and update rows they own", "courses they're assigned to", "Administrators get full management rights",
                      "RLS is enabled on every table", "To test authorization"] {
            #expect(answer.text.contains(point))
        }
        #expect(model.engine.undoAnswer == nil) // undo never brings back the answer to the half question
        try? await Task.sleep(for: .milliseconds(60))
        #expect(lens.last?.hasPrefix("I'd use Supabase Authentication for sign-in and store") == true)
    }

    @Test func nothingFromTheHalfQuestionReachesTheGlassesWhileTheInterviewerIsStillSpeaking() async throws {
        await model.startSession()
        ai.perWordDelay = .milliseconds(2)
        ai.queuedAnswers = [Screenshot.partialAnswer, Screenshot.good]
        speech.onEvent?(.final(Screenshot.first + ".", start: 0, end: 5))
        await model.tick(now: Date().addingTimeInterval(1.5))           // the first half is endpointed and generation starts…
        speech.onEvent?(.partial("especially when students, instructors"))  // …but the interviewer keeps talking
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!lens.contains { $0.contains("every query is checked") })   // no early frame, no final frame
        #expect(model.engine.currentAnswer == nil)
        speech.onEvent?(.final(Screenshot.second, start: 6.5, end: 11))
        await model.tick(now: Date().addingTimeInterval(3))
        await model.engine.generationTask?.value
        #expect(model.engine.currentAnswer?.question == Screenshot.full)
        #expect(model.engine.currentAnswer?.text == Screenshot.good)
        #expect(!lens.contains { $0.contains("every query is checked") })
        #expect(model.engine.log.contains { $0.message.contains("Generation cancelled") || $0.message.contains("regenerating the answer for the finalized question") })
    }

    @Test func aHoldNeverBlocksAnAnswerWhenNobodyContinues() async {
        await model.startSession()
        ai.answer = Screenshot.good
        speech.onEvent?(.final(Screenshot.full, start: 0, end: 9))
        let started = Date()
        await model.tick(now: Date().addingTimeInterval(1.5))
        await model.engine.generationTask?.value
        #expect(Date().timeIntervalSince(started) < 1) // no artificial delay
        #expect(model.engine.currentAnswer?.text == Screenshot.good)
    }

    @Test func anIndependentQuestionOnTheSameTopicIsNotAFollowUpButAReferringOneIs() async throws {
        model.settings.continuousConversation = true
        await model.startSession()
        ai.answer = "Row level security attaches policies to a table so each query only returns the rows the current user may see."
        speech.onEvent?(.final("How does PostgreSQL row level security work in Supabase?", start: 0, end: 4))
        await model.tick(now: Date().addingTimeInterval(10)); await model.engine.generationTask?.value
        ai.answer = Screenshot.good
        speech.onEvent?(.final(Screenshot.full, start: 20, end: 29))
        await model.tick(now: Date().addingTimeInterval(20)); await model.engine.generationTask?.value
        #expect(model.engine.currentAnswer?.kind == .newQuestion)
        #expect(ai.requests.last?.prompt.contains("This is a follow-up") == false)
        ai.answer = "For the admin dashboard I'd check the administrator role in the policy and on the server before any query runs."
        speech.onEvent?(.final("What about the admin dashboard?", start: 50, end: 52))
        await model.tick(now: Date().addingTimeInterval(30)); await model.engine.generationTask?.value
        #expect(model.engine.currentAnswer?.kind == .followUp)
        #expect(ai.requests.last?.prompt.contains("This is a follow-up") == true)
    }
}
