import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// The real-device report: a hypothetical production-incident question answered with an invented story about
/// troubleshooting the BMR Pharmacy Sales Tracker. (Reconstructed from the report's description.)
enum Incident {
    static let question = "Imagine users start reporting errors right after a production deployment. How would you investigate the incident across the frontend, the backend, and the PostgreSQL database, and decide whether to roll back?"
    static let bmrAnswer = "When I was troubleshooting my BMR Pharmacy Sales Tracker, I ran into a similar issue where the React frontend kept failing because the Express API returned errors. I'd start by checking the browser console and network tab, then the backend logs and the PostgreSQL slow query log. Once I find the cause, I'd ship a fix."
    static let good = "I'd start with error tracking and the browser network tab to see which frontend requests fail and whether the errors began with the deployment. Then I'd check the backend logs and metrics for the failing endpoints, following one request ID through the API. On the PostgreSQL database I'd look for slow or blocked queries in pg_stat_activity and check whether a migration in the release changed a table or index. If errors jumped right after the deployment and users are affected, I'd roll back first to restore service, unless the release ran a migration that can't be safely reversed, in which case I'd ship a forward fix. Afterwards I'd confirm error rates are back to normal and write up the cause."
    static let bmrAgain = "In my BMR Pharmacy Sales Tracker I had the same thing happen. " + good
}

@Suite struct PersonalContextPolicyTests {
    let projects = PersonalMemoryStore.seed.compactMap(\.project)

    @Test(arguments: [
        (Incident.question, false),
        ("How would you handle errors in your production environment?", false),
        ("Design a scalable notification system.", false),
        ("Explain how PostgreSQL indexes work.", false),
        ("Tell me about your BMR Pharmacy Sales Tracker project.", true),
        ("How did you do SQL aggregation for the sales reports?", true),
        ("How does your experience apply to this role?", true),
        ("Have you worked with PostgreSQL before?", true),
        ("Tell me about a time you debugged a difficult production issue.", true),
    ])
    func personalMemoryOnlyWhenTheQuestionAsksForIt(_ question: String, _ wanted: Bool) {
        let decision = PersonalContextPolicy.decide(question, projects: projects, activeProject: nil)
        #expect(decision.wanted == wanted, "\(question): \(decision.reason)")
    }

    @Test func aFollowUpInsideAProjectDiscussionKeepsIt() {
        #expect(PersonalContextPolicy.decide("What database did it use?", projects: projects, activeProject: "BMR Pharmacy Sales Tracker").wanted)
        #expect(!PersonalContextPolicy.decide(Incident.question, projects: projects, activeProject: "BMR Pharmacy Sales Tracker").wanted)
    }

    @Test func unsolicitedAnecdotesAreFoundAndRemovable() {
        let found = PersonalContextPolicy.anecdotes(in: Incident.bmrAnswer, projects: projects)
        #expect(found.count == 1 && found[0].hasPrefix("When I was troubleshooting my BMR"))
        #expect(PersonalContextPolicy.anecdotes(in: Incident.good, projects: projects).isEmpty)
        #expect(PersonalContextPolicy.anecdotes(in: "I've debugged this kind of outage before in a previous project.", projects: []).count == 1)
        #expect(PersonalContextPolicy.removing(PersonalContextPolicy.anecdotes(in: Incident.bmrAgain, projects: projects), from: Incident.bmrAgain) == Incident.good)
    }

    @Test func theRollbackDecisionIsARequirement() {
        let intent = InterviewIntent.classify(Incident.question)
        #expect(intent.requirements.contains("decide whether to roll back"), "\(intent.requirements)")
        #expect(intent.guidance(length: .standard).contains("state the criteria and the decision explicitly"))
        #expect(intent.missingRequirements(in: Incident.good).isEmpty, "\(intent.missingRequirements(in: Incident.good))")
        #expect(intent.missingRequirements(in: Incident.bmrAnswer).contains("decide whether to roll back"))
    }
}

@MainActor @Suite(.serialized) struct PersonalContextFlowTests {
    let speech = MockSpeech()
    let ai = MockAIProvider()
    let model: AppModel

    init() {
        let speech = self.speech, ai = self.ai
        model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [speech] }, aiFactory: { _ in ai },
                         glassesFactory: { _ in MockGlassesDisplay() }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.settings.semanticClassification = false
        model.settings.minimumLockSeconds = 0
        model.settings.aiModel = .appleOnDevice // personal memory may be used on-device; the policy still decides per question
    }

    func say(_ text: String, at start: Double) async {
        speech.onEvent?(.final(text, start: start, end: start + 4))
        await model.tick(now: Date().addingTimeInterval(10))
        await model.engine.generationTask?.value
    }

    @Test func theIncidentQuestionGetsNoProjectMemoryAndTheBMRStoryIsRejected() async throws {
        #expect(model.memory.projects.contains { $0.project == "BMR Pharmacy Sales Tracker" })
        await model.startSession()
        ai.queuedAnswers = [Incident.bmrAnswer, Incident.good]
        await say(Incident.question, at: 0)
        let first = try #require(ai.requests.first)
        #expect(!first.prompt.contains("BMR") && !first.prompt.contains("Verified background"))
        #expect(!first.instructions.contains("BMR") && !first.instructions.contains("Pharmacy"))
        #expect(first.prompt.contains("decide whether to roll back"))
        let retry = try #require(ai.requests.last)
        #expect(ai.requests.count == 2)
        #expect(retry.instructions.contains("personal project or past experience the question didn't ask about"))
        #expect(model.engine.currentAnswer?.text == Incident.good)
        #expect(model.engine.log.contains { $0.message.contains("personal memory not included (general") })
    }

    @Test func aSecondDraftWithTheAnecdoteHasItRemoved() async {
        await model.startSession()
        ai.queuedAnswers = [Incident.bmrAnswer, Incident.bmrAgain]
        await say(Incident.question, at: 0)
        #expect(model.engine.currentAnswer?.text == Incident.good)
    }

    @Test func projectQuestionsAndTheirFollowUpsStillUseMemory() async throws {
        await model.startSession()
        ai.answer = "BMR Pharmacy Sales Tracker is a React frontend with a Node.js and Express backend on PostgreSQL, built for sales and product reporting."
        await say("Tell me about your BMR Pharmacy Sales Tracker project.", at: 0)
        #expect(ai.requests.last?.prompt.contains("Verified background") == true)
        #expect(ai.requests.last?.prompt.contains("SQL aggregation") == true)
        #expect(model.engine.currentAnswer?.text.contains("BMR") == true) // wanted here: not rejected
        ai.answer = "The reports use SQL aggregation in PostgreSQL, grouped by product and date, and the frontend just renders the results."
        await say("How did the reporting queries work in it?", at: 20)
        #expect(ai.requests.last?.prompt.contains("SQL aggregation") == true)
        ai.queuedAnswers = [Incident.good]
        await say(Incident.question, at: 40)
        #expect(ai.requests.last?.prompt.contains("Verified background") == false)
        #expect(model.engine.currentAnswer?.text == Incident.good)
    }
}
