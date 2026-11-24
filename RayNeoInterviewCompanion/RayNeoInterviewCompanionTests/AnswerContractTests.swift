import Foundation
import Testing
@testable import RayNeoInterviewCompanion

@Suite struct AnswerContractTests {
    let projects = PersonalMemoryStore.seed.compactMap(\.project)

    func contract(_ question: String, personal: Bool = true) -> AnswerContract {
        AnswerContract(question: question, intent: InterviewIntent.classify(question), personalAllowed: personal, projects: projects)
    }

    @Test func theMainTaskIsTheRequestWithoutItsFraming() {
        #expect(contract(Screenshot.full).task == "secure a next.js application")
        #expect(contract(Incident.question).task == "investigate the incident")
        #expect(contract("Design a background job processing system for enrolment emails.").task == "design a background job processing system for enrolment emails")
        #expect(contract("Okay, can you walk me through how you'd debug a slow API?").task == "debug a slow api")
        #expect(contract(InterviewContextTests.incidents).task == nil) // a scenario statement sets no task
    }

    @Test func theRLSQuestionRequiresEachRoleRLSAndAuthorizationTesting() {
        let rls = contract(Screenshot.full)
        let violations = rls.violations(in: Screenshot.keywordsOnly)
        #expect(violations.contains("students (named but not explained individually)"))
        #expect(violations.contains("instructors (named but not explained individually)"))
        #expect(violations.contains("administrators (named but not explained individually)"))
        #expect(violations.contains("how you'd test authorization for each role"))
        #expect(rls.violations(in: Screenshot.good).isEmpty, "\(rls.violations(in: Screenshot.good))")
        #expect(rls.promptLine == "Main task: secure a next.js application. Answer it directly before anything else.")
    }

    @Test func theIncidentQuestionRejectsTheBMRStoryAndAMissingRollbackDecision() {
        let incident = contract(Incident.question, personal: false)
        let violations = incident.violations(in: Incident.bmrAnswer)
        #expect(violations.contains { $0.hasPrefix("a personal project or past experience") && $0.contains("BMR") })
        #expect(violations.contains("decide whether to roll back"))
        #expect(incident.violations(in: Incident.good).isEmpty, "\(incident.violations(in: Incident.good))")
        #expect(!incident.allowsEarlyText("When I was troubleshooting my BMR Pharmacy Sales Tracker, I ran into this."))
        #expect(incident.allowsEarlyText("I'd start with error tracking and the browser network tab."))
    }

    @Test func everyPartOfAMultiPartRequestMustBeCovered() {
        let request = "Explain how you prioritize these incidents, investigate them, and communicate with affected staff."
        let parts = contract(request)
        #expect(parts.intent.parts.count == 3)
        let noCommunication = "I'd handle the exam outage first because it's disrupting an exam right now, then the Salesforce leads. I'd check the switch and access point logs, and then the webhook delivery logs."
        #expect(parts.violations(in: noCommunication) == ["the part \"communicate with affected staff\""])
        #expect(parts.violations(in: noCommunication + " I'd keep affected staff updated on the workaround and the next update time.").isEmpty)
    }

    @Test func anOffTaskAnswerFailsEvenWhenItIsFluent() {
        let indexes = contract("Explain how PostgreSQL indexes work.")
        #expect(indexes.violations(in: "React re-renders a component when its state or props change, so memoising expensive children helps.") == ["the main task (postgresql indexes work) is not addressed"])
        #expect(indexes.violations(in: "A PostgreSQL index is a separate B-tree structure that lets the planner find matching rows without scanning the whole table.").isEmpty)
    }

    @Test func projectAnswersMayUseMemoryWhenTheQuestionAsksForIt() {
        let project = contract("Tell me about your BMR Pharmacy Sales Tracker project.", personal: true)
        #expect(project.violations(in: "BMR Pharmacy Sales Tracker is a React frontend with a Node.js and Express backend on PostgreSQL for sales reporting.").isEmpty)
    }
}

@MainActor @Suite(.serialized) struct AnswerContractFlowTests {
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
        model.settings.aiModel = .appleOnDevice
    }

    var lens: [String] { glasses.shown.map { LensModel.visibleText([$0], rowWidth: 60).joined(separator: " ") } }

    func ask(_ question: String) async {
        speech.onEvent?(.final(question, start: 0, end: 9))
        await model.tick(now: Date().addingTimeInterval(10))
        await model.engine.generationTask?.value
    }

    @Test func theBMRStoryNeverReachesTheGlassesEvenWhileStreaming() async {
        await model.startSession()
        ai.perWordDelay = .milliseconds(1)
        ai.queuedAnswers = [Incident.bmrAnswer, Incident.good]
        await ask(Incident.question)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!lens.contains { $0.contains("BMR") || $0.contains("troubleshooting my") })
        #expect(model.engine.currentAnswer?.text == Incident.good)
        #expect(ai.requests.first?.prompt.contains("Main task: investigate the incident") == true)
    }

    @Test func theRLSQuestionIsShownOnlyOnceEveryRoleIsCovered() async {
        await model.startSession()
        ai.queuedAnswers = [Screenshot.keywordsOnly, Screenshot.good]
        await ask(Screenshot.full)
        #expect(ai.requests.count == 2)
        #expect(ai.requests.last?.instructions.contains("did not address the interviewer's requirement(s)") == true)
        #expect(model.engine.currentAnswer?.text == Screenshot.good)
        #expect(model.engine.currentAnswer?.validation == "passed")
    }
}
