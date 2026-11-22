import Foundation
import Testing
@testable import RayNeoInterviewCompanion

@Suite struct CalculatorTests {
    func answer(_ question: String) -> String? {
        guard case .success(let result)? = Calculator.evaluate(question) else { return nil }
        return result.answer
    }

    /// The exact real-device failure.
    @Test func observedFailureIsAnsweredExactly() {
        #expect(answer("What is 5000×592?") == "5000 times 592 is 2,960,000.")
        #expect(answer("what is 5000 x 592") == "5000 times 592 is 2,960,000.")
        #expect(answer("What's 5,000 * 592?") == "5000 times 592 is 2,960,000.")
    }

    @Test(arguments: [
        ("What's 5000 times 592?", "2,960,000"),
        ("What is 5000 multiplied by 592?", "2,960,000"),
        ("What's 15% of 240?", "15 percent times 240 is 36."),
        ("What is 2 to the power of 8?", "256"),
        ("What's 2^10?", "1,024"),
        ("What is 3 plus 4 times 2?", "is 11."),
        ("What is (3 + 4) × 2?", "is 14."),
        ("What is 7.5 divided by 2.5?", "is 3."),
        ("What's negative 12 plus 30?", "is 18."),
        ("What's -12 + 30?", "is 18."),
        ("What is 1200 multiplied by 1.08?", "is 1,296."),
        ("What's 0.1 plus 0.2?", "is 0.3."),
        ("What is twelve times twelve?", "is 144."),
        ("What is five thousand times five hundred ninety two?", "2,960,000"),
        ("What is 999 squared?", "998,001"),
        ("What is 1 divided by 3?", "about 0.333333"),
        ("What is 10 over 4?", "2.5"),
        ("What is 2 to the power of -2?", "0.25"),
        ("What is the square root of 144?", "12"),
    ])
    func spokenAndTypedArithmetic(_ question: String, _ expected: String) {
        let result = answer(question)
        #expect(result?.contains(expected) == true, "\(question) → \(result ?? "nil")")
    }

    @Test func averages() {
        #expect(answer("What's the average of 12, 18, and 24?") == "The average of 12, 18, and 24 is 18.")
        #expect(answer("mean of 2 3 4 5")?.hasSuffix("is 3.5.") == true)
    }

    @Test func divisionByZeroOverflowAndUnsupportedAreSafe() {
        #expect(Calculator.evaluate("What is 10 divided by 0?") == .failure(.divisionByZero))
        #expect(Calculator.evaluate("What is 10 to the power of 40 times 10 to the power of 40?") == .failure(.overflow))
        if case .failure(.unsupported)? = Calculator.evaluate("What is 2 to the power of 0.5?") {} else { Issue.record("fractional exponent must be refused") }
        if case .failure? = Calculator.evaluate("What is 5 + * 3?") {} else { Issue.record("expected a safe failure") }
        if case .failure? = Calculator.evaluate("What is (5 + 3?") {} else { Issue.record("expected a safe failure") }
    }

    @Test func nonMathQuestionsAreNotCalculations() {
        for question in ["What does HTTP 401 mean?", "How would you troubleshoot a 500 error that times out?",
                         "What port does HTTPS use, 443?", "Tell me about a project you developed.",
                         "What's the difference between OAuth 2 and SAML?", "Explain Microsoft 365 licensing."] {
            #expect(Calculator.evaluate(question) == nil, "\(question)")
        }
    }
}

@Suite struct QuestionRouterTests {
    @Test(arguments: EvaluationItem.all)
    func evaluationSetRoutesAsExpected(_ item: EvaluationItem) {
        #expect(QuestionRouter.route(item.question).category == item.category, "\(item.question)")
    }

    @Test func evaluationSetHasAtLeastFiftyQuestionsAndCorrectMath() {
        #expect(EvaluationItem.all.count >= 50)
        for item in EvaluationItem.all where item.category == .math {
            let answer = QuestionRouter.route(item.question).directAnswer?.lowercased() ?? ""
            #expect(item.expected.contains { answer.contains($0.lowercased()) }, "\(item.question) → \(answer)")
        }
    }

    @Test func followUpsWithContextAreNotAmbiguous() {
        #expect(QuestionRouter.route("Can you explain it?", hasPreviousAnswer: true).category == .technical)
        #expect(QuestionRouter.route("Can you explain it?").category == .ambiguous)
    }
}

@Suite struct AnswerValidatorTests {
    @Test func observedNonAnswerIsRejected() {
        let observed = "I'd probably double-check my math skills. I'd probably use a calculator or a spreadsheet to make sure I'm not making a mistake. If I'm still unsure, I'd probably ask for help or review my notes to make sure I'm not missing anything."
        let verdict = AnswerValidator.validate(observed, question: "What does HTTP 401 mean?", category: .factual, hasPortfolio: false)
        #expect(!verdict.passed)
        #expect(verdict.useFallback)
    }

    @Test func goodAnswersPass() {
        #expect(AnswerValidator.validate("HTTP 401 means the request hasn't been authenticated. Usually I'd check the credentials or token first.",
                                         question: "What does HTTP 401 mean?", category: .factual, hasPortfolio: false).passed)
        #expect(AnswerValidator.validate("I'd use a Set because it drops duplicate values, then spread it back into an array.",
                                         question: "Write a function that removes duplicates from an array.", category: .coding, hasPortfolio: false).passed)
    }

    @Test func fabricatedExperienceAndFakeTestingAreRejected() {
        #expect(!AnswerValidator.validate("In my last role at a bank I fixed Entra sign-in issues daily.",
                                          question: "How would you fix Entra sign-in issues?", category: .technical, hasPortfolio: false).passed)
        #expect(AnswerValidator.validate("In my last role at a bank I fixed Entra sign-in issues daily.",
                                         question: "How would you fix Entra sign-in issues?", category: .technical, hasPortfolio: true).passed)
        #expect(!AnswerValidator.validate("I tested this and the Set approach removes duplicates.",
                                          question: "Remove duplicates from an array", category: .coding, hasPortfolio: false).passed)
    }

    @Test func offTopicAnswerIsRejected() {
        let verdict = AnswerValidator.validate("I'd make sure the team communicates well and stays positive.",
                                               question: "How would you debug a Salesforce integration?", category: .technical, hasPortfolio: false)
        #expect(!verdict.passed && !verdict.useFallback)
    }
}

@Suite struct CategoryPromptTests {
    @Test func eachCategoryHasItsOwnStyle() {
        let technical = InterviewPromptBuilder.instructions(for: .technical, length: .standard, portfolio: "")
        let factual = InterviewPromptBuilder.instructions(for: .factual, length: .standard, portfolio: "")
        let coding = InterviewPromptBuilder.instructions(for: .coding, length: .standard, portfolio: "")
        for text in [technical, factual, coding] {
            #expect(text.contains("Never describe how you would look something up"))
            #expect(text.contains("Microsoft Entra ID"))
            #expect(text.contains("Do not invent professional experience"))
        }
        #expect(technical.contains("DJ, the technical interviewer") && technical.contains("3-5 short spoken sentences"))
        #expect(!technical.contains("\"I'd probably\" where natural"))
        #expect(factual.contains("one direct, informative sentence") && factual.contains("Never add sentences about checking documentation") && !factual.contains("DJ"))
        #expect(coding.contains("Never claim the code was run") && !coding.contains("Style example"))
    }
}

/// Engine-level behaviour with a mock model.
@MainActor @Suite struct AnswerRoutingEngineTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let ai = MockAIProvider()
    let engine: ConversationEngine

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        var settings = AppSettings()
        settings.semanticClassification = false
        let ai = self.ai
        engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
    }

    func ask(_ text: String) async {
        await engine.handle(CompletedTurn(text: text, start: 0, end: 2))
        await engine.generationTask?.value
    }

    @Test func mathBypassesTheModelAndReachesTheGlasses() async {
        await ask("What is 5000×592?")
        #expect(ai.requests.isEmpty)
        #expect(engine.currentAnswer?.text == "5000 times 592 is 2,960,000.")
        #expect(engine.currentAnswer?.category == .math)
        #expect(glasses.shown == ["5000 times 592 is 2,960,000. \u{2713}"]) // end marker rendered, not in the text
        #expect(engine.state == .answerLocked)
    }

    @Test func mathWorksEvenWhenTheModelIsUnavailable() async {
        ai.status = .unavailable("Apple Intelligence is off")
        await ask("What's 15% of 240?")
        #expect(engine.currentAnswer?.text == "15 percent times 240 is 36.")
    }

    @Test func nonAnswerTriggersOneRegenerationThenHonestFallback() async {
        ai.answer = "I'd probably double-check that. I'd probably look it up or ask a colleague."
        await ask("What does HTTP 401 mean?")
        #expect(ai.requests.count == 2) // one bounded regeneration, no loop
        #expect(ai.requests[1].instructions.contains("previous draft was rejected"))
        #expect(engine.currentAnswer?.text == AnswerValidator.honestFallback)
    }

    @Test func factualQuestionsUseTheFactualStyle() async {
        ai.answer = "HTTP 401 means the request hasn't been authenticated."
        await ask("What does HTTP 401 mean?")
        #expect(ai.requests.count == 1)
        #expect(ai.requests[0].instructions.contains("direct factual question"))
        #expect(engine.currentAnswer?.category == .factual)
    }

    @Test func ambiguousQuestionGetsAClarificationWithoutAModel() async {
        await ask("Can you explain that thing again?")
        #expect(ai.requests.isEmpty)
        #expect(engine.currentAnswer?.category == .ambiguous)
        #expect(engine.currentAnswer?.text.contains("more detail") == true)
    }

    @Test func cancellingAModelAnswerStillWorks() async {
        ai.perWordDelay = .milliseconds(50)
        await engine.handle(CompletedTurn(text: "How would you secure a REST API?", start: 0, end: 2))
        engine.cancelGeneration()
        await engine.generationTask?.value
        #expect(engine.currentAnswer == nil)
        #expect(glasses.shown.isEmpty)
    }

    @Test func localInferenceFailureKeepsListening() async {
        ai.failure = TestError()
        await ask("How would you secure a REST API?")
        #expect(engine.currentAnswer == nil)
        #expect(engine.state == .listening)
    }

    @Test func gemmaSelectionFallsBackToAppleWithAVisibleReason() {
        let apple = MockAIProvider()
        let provider = FallbackAIProvider(preferred: GemmaProvider(), fallback: apple, explicitChoice: true)
        #expect(provider.status == .ready)
        #expect(provider.name.contains("fallback: Gemma On-Device not included in this build"))
        let auto = FallbackAIProvider(preferred: GemmaProvider(), fallback: apple, explicitChoice: false)
        #expect(auto.name == "Auto → AI")
    }
}
