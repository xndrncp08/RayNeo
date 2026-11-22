import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Model requests that started a generation (validation retries are not separate generations).
@MainActor func generations(_ ai: MockAIProvider) -> Int {
    ai.requests.filter { !$0.instructions.contains("A previous draft was rejected") }.count
}

// MARK: Transcript assembly (Failure B)

@Suite struct TranscriptTurnAssemblerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    func turn(_ output: AssemblerOutput?) -> ConversationTurn? {
        switch output { case .turn(let turn)?: turn; default: nil }
    }

    @Test func partialRevisionsOnlyChangeTheLiveTranscript() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        for (index, text) in ["Can you", "Can you tell", "Can you tell me about", "Can you tell me about your project"].enumerated() {
            assembler.partial(text, at: at(Double(index) * 0.2))
        }
        #expect(assembler.live == "Can you tell me about your project")
        #expect(assembler.turns.isEmpty)
        #expect(assembler.tick(now: at(1.0)) == nil)
        _ = assembler.final("Can you tell me about your project Discarte?", start: 0, end: 2.6, at: at(1.2))
        let emitted = turn(assembler.tick(now: at(2.5)))
        #expect(emitted?.text == "Can you tell me about your project Discarte?")
        #expect(assembler.turns.count == 1)
    }

    @Test func competingHypothesesForTheSameAudioBecomeOneTurn() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("Can you tell me about your project Discarte?", start: 0.0, end: 2.6, at: at(0))
        _ = assembler.final("Can you talk about your project Discarte?", start: 0.1, end: 2.6, at: at(0.3))
        let emitted = turn(assembler.tick(now: at(2)))
        #expect(emitted?.text == "Can you talk about your project Discarte?")
        #expect(emitted?.segmentIDs.count == 1)
        #expect(assembler.revisions == 1)
        #expect(assembler.turns.count == 1)
    }

    @Test func identicalReEmittedFinalIsDropped() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("What is a REST API?", start: 0, end: 1.5, at: at(0))
        _ = assembler.final("What is a REST API?", start: 1.6, end: 1.7, at: at(0.2))
        #expect(turn(assembler.tick(now: at(2)))?.text == "What is a REST API?")
        #expect(assembler.duplicates == 1)
    }

    @Test func adjacentFragmentsOfOneUtteranceAreMerged() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("Can you talk about?", start: 0, end: 1.4, at: at(0))
        #expect(assembler.tick(now: at(1.5)) == nil) // incomplete ending: extra grace, not a question yet
        _ = assembler.final("Discarte.", start: 2.0, end: 2.6, at: at(2.0))
        let emitted = turn(assembler.tick(now: at(3.3)))
        #expect(emitted?.text == "Can you talk about Discarte?")
        #expect(assembler.turns.count == 1)
    }

    @Test func aLateFragmentCompletesTheEmittedTurnAsARevision() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("Can you talk about?", start: 0, end: 1.4, at: at(0))
        let first = turn(assembler.tick(now: at(2.8)))
        #expect(first?.text == "Can you talk about?")
        guard case .revised(let revised)? = assembler.final("Discarte.", start: 3.5, end: 4.0, at: at(4.0)) else {
            Issue.record("expected a revision"); return
        }
        #expect(revised.id == first?.id)
        #expect(revised.text == "Can you talk about Discarte?")
        #expect(revised.revision == 1)
        #expect(assembler.turns.count == 1)
    }

    @Test func anIsolatedNameAfterACompleteQuestionStaysItsOwnShortTurn() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("Can you tell me about your project Diskarte?", start: 0, end: 2.5, at: at(0))
        _ = turn(assembler.tick(now: at(1.3)))
        // Not incomplete, so no merge: the engine later ignores "Diskarte." as too short to be a question.
        #expect(assembler.final("Diskarte.", start: 3.0, end: 3.5, at: at(3.0)) == nil)
        #expect(turn(assembler.tick(now: at(4.5)))?.text == "Diskarte.")
    }

    @Test func repeatedAndSimilarQuestionsStaySeparateTurnsWithStableIDs() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        var ids: [Int] = []
        for (index, text) in ["What is a primary key?", "What is a foreign key?", "What is a foreign key?"].enumerated() {
            let start = Double(index) * 10
            _ = assembler.final(text, start: start, end: start + 1.5, at: at(start))
            if let emitted = turn(assembler.tick(now: at(start + 2))) { ids.append(emitted.id) }
        }
        #expect(ids == [1, 2, 3])
    }

    @Test func recognizerRestartDropsProvisionalTextButKeepsTurns() {
        var assembler = TranscriptTurnAssembler(silence: 1.2)
        _ = assembler.final("What is MFA?", start: 0, end: 1, at: at(0))
        _ = assembler.tick(now: at(2))
        assembler.partial("half a sentence", at: at(3))
        assembler.reset()
        #expect(assembler.live.isEmpty && assembler.pending.isEmpty)
        _ = assembler.final("What is SSO?", start: 5, end: 6, at: at(5))
        #expect(turn(assembler.tick(now: at(7)))?.id == 2)
    }
}

// MARK: Project names (Failure C)

@MainActor @Suite struct ProjectVocabularyTests {
    let normalizer = PersonalMemoryStore(url: nil).vocabulary
    let dictionary: (String) -> Bool = { ["discard", "card", "this", "the", "paper", "pile", "resonate", "disk", "art"].contains($0.lowercased()) }

    func normalized(_ text: String, context: String = "") -> String {
        normalizer.normalize(text, context: context, isDictionaryWord: dictionary).normalized
    }

    @Test func reportedMisrecognitionsMapToTheProject() {
        #expect(normalized("Can you tell me about your project Discarte?") == "Can you tell me about your project Diskarte?")
        #expect(normalized("Can you talk about your project, Rezonic?") == "Can you talk about your project, Resoniq?")
        #expect(normalized("Can you talk about your project, Resnik?") == "Can you talk about your project, Resoniq?")
        #expect(normalized("Tell me about kinda moving.") == "Tell me about KindaMoving.")
    }

    @Test func fuzzyMatchesNeedProjectContext() {
        // No project cue: a close spelling is not enough.
        let unrelated = normalizer.normalize("I like the Resnick paper on parsing.", isDictionaryWord: dictionary)
        #expect(unrelated.replacements.isEmpty)
        // A project keyword ("audio") supplies the context.
        #expect(normalized("How did Rezonic handle audio processing?") == "How did Resoniq handle audio processing?")
        // The project under discussion supplies it too.
        #expect(normalized("And what did Rezonic store?", context: "Resoniq") == "And what did Resoniq store?")
    }

    @Test func ordinaryWordsAreNeverReplaced() {
        #expect(normalized("Put it in the discard pile.") == "Put it in the discard pile.")
        #expect(normalized("Tell me about this card.") == "Tell me about this card.")
        #expect(normalized("Things resonate with users on your app.") == "Things resonate with users on your app.")
    }

    @Test func canonicalNamesAreUnchangedAndOriginalIsKept() {
        let result = normalizer.normalize("Tell me about Resoniq and FJuan.", isDictionaryWord: dictionary)
        #expect(result.normalized == "Tell me about Resoniq and FJuan.")
        #expect(result.replacements.isEmpty)
        let corrected = normalizer.normalize("Can you talk about your project Rezonic?", isDictionaryWord: dictionary)
        #expect(corrected.original == "Can you talk about your project Rezonic?")
        #expect(corrected.replacements.first?.canonical == "Resoniq")
    }

    @Test func switchingProjectsMidConversation() {
        #expect(normalized("Now tell me about Discarte.", context: "FJuan") == "Now tell me about Diskarte.")
    }

    @Test func aliasesAreEditableAndFeedTheRecognizer() {
        let store = PersonalMemoryStore(url: nil)
        store.setAliases(["Rez on it"], for: "Resoniq")
        let vocabulary = store.vocabulary
        #expect(vocabulary.normalize("Tell me about Rez on it.").normalized == "Tell me about Resoniq.")
        #expect(vocabulary.vocabulary.contains("Diskarte") && vocabulary.vocabulary.contains("Rez on it"))
        #expect(!vocabulary.vocabulary.contains("Rezonic")) // removed alias
    }

    @Test func savedMemoryWithoutAliasesStillLoads() throws {
        let old = #"{"entries":[],"lastIndexed":{}}"#
        let document = try JSONDecoder().decode(MemoryDocument.self, from: Data(old.utf8))
        #expect(document.aliases["Resoniq"]?.contains("Rezonic") == true)
    }
}

// MARK: Coding tasks (Failure A)

@MainActor @Suite struct CodingTaskTests {
    static let instruction = "Write a JavaScript function that removes duplicate values from an array."
    static let approach = "So I'd solve that using a Set to filter out duplicates, since a Set only stores unique values. I'd write a function that takes the array, passes it into a new Set constructor, and spreads it back into an array."
    static let followUp = "Can you show me the code for that, please?"
    static let refusal = "I haven't written that specific piece of code in my past work, so I don't have an example ready to show you right now. If you'd like, I can talk through the logic I'd use to build it from scratch using standard patterns."
    static let good = "Here's how I'd write it: the array goes into a new Set, which keeps only unique values, and spreading it gives an array back.\nCODE:\nfunction removeDuplicates(arr) {\n  return [...new Set(arr)];\n}\nSTEPS:\n1. Create a Set from the array\n2. Spread the Set into a new array\nEDGE CASES:\n- Objects are compared by reference\nCOMPLEXITY: O(n) time and space\nTESTS:\n- removeDuplicates([1, 1, 2]) returns [1, 2]"

    @Test func theTaskTheApproachAndTheFollowUpAreResolvedTogether() throws {
        let tracker = CodingTaskTracker()
        #expect(tracker.observe(Self.instruction, turnID: 1, startsNewTopic: true) != nil)
        #expect(tracker.task?.language == "JavaScript")
        tracker.observe(Self.approach, turnID: 2, startsNewTopic: false)
        #expect(tracker.task?.dataStructures.contains("set") == true)
        let resolved = try #require(tracker.resolve(Self.followUp))
        #expect(resolved.kind == .implement)
        #expect(resolved.language == "JavaScript")
        #expect(resolved.prompt.contains("removes duplicate values from an array"))
        #expect(resolved.prompt.contains("spreads it back"))
        #expect(resolved.prompt.contains("never a claim about past work"))
    }

    @Test(arguments: [
        ("Can you do that in TypeScript?", CodingFollowUp.modify, "TypeScript"),
        ("What if the array contains objects?", .modify, "JavaScript"),
        ("How would you test it?", .test, "JavaScript"),
        ("Can you explain this line?", .explain, "JavaScript"),
        ("Can you make it asynchronous?", .modify, "JavaScript"),
        ("What would that function look like?", .implement, "JavaScript"),
        ("Can you implement it?", .implement, "JavaScript"),
    ])
    func codingFollowUpsResolveAgainstTheTask(_ text: String, _ kind: CodingFollowUp, _ language: String) throws {
        let tracker = CodingTaskTracker()
        tracker.observe(Self.instruction, turnID: 1, startsNewTopic: true)
        let resolved = try #require(tracker.resolve(text))
        #expect(resolved.kind == kind)
        #expect(resolved.language == language)
    }

    @Test func theTaskIsClearedOnARealTopicChangeAndANewTaskReplacesIt() {
        let tracker = CodingTaskTracker()
        tracker.observe(Self.instruction, turnID: 1, startsNewTopic: true)
        tracker.observe("Now tell me about Diskarte.", turnID: 2, startsNewTopic: true)
        #expect(tracker.task == nil)
        tracker.observe("Write a SQL query that sums quantity sold per product.", turnID: 3, startsNewTopic: true)
        #expect(tracker.task?.language == "SQL")
        #expect(tracker.resolve("Can you show me the code for that?") != nil)
    }

    @Test func pastWorkRefusalsAreRejectedButHypotheticalCodeAndExplanationsPass() {
        let question = Self.instruction
        #expect(!AnswerValidator.validate(Self.refusal, question: question, category: .coding, hasPortfolio: false).passed)
        #expect(AnswerValidator.validate("Here's how I'd implement it: pass the array into a new Set and spread it back into an array.",
                                         question: question, category: .coding, hasPortfolio: false).passed)
        #expect(AnswerValidator.validate("A Set stores unique values, so spreading it into an array removes duplicate values.",
                                         question: question, category: .coding, hasPortfolio: false).passed)
        // Real experience claims still need evidence.
        #expect(!AnswerValidator.validate("I implemented this exact function in my previous job.", question: question,
                                          category: .coding, hasPortfolio: false).passed)
        #expect(PersonalMemoryStore.unsupportedClaim(in: "In Diskarte, I implemented this exact solution.", entries: PersonalMemoryStore.seed) != nil)
    }

    @Test func showMeTheCodeWithoutATaskAsksOneClarification() async throws {
        let ai = MockAIProvider()
        let pipeline = AnswerPipeline(provider: ai, instructions: { _ in "" }, notes: { _ in [] }, answerLength: .standard, hasPortfolio: false)
        let output = try await pipeline.answer("Can you show me the code for that?", previous: nil)
        #expect(output.category == .ambiguous)
        #expect(output.text.contains("which function"))
        #expect(ai.requests.isEmpty)
    }
}

/// The physical Failure A scenario, end to end through speech events, assembly, classification,
/// the active task, generation, validation and the Code Tutor on the glasses.
@MainActor @Suite(.serialized) struct CodingConversationTests {
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

    /// One utterance at `start` seconds on the capture timeline, then enough silence to end the turn.
    func say(_ text: String, at start: Double, seconds: Double = 3) async {
        speech.onEvent?(.final(text, start: start, end: start + seconds))
        await model.tick(now: Date().addingTimeInterval(10))
        await model.engine.generationTask?.value
    }

    @Test(arguments: [false, true])
    func showMeTheCodeProducesTheFunctionAndTheCodeTutor(_ continuous: Bool) async throws {
        model.settings.continuousConversation = continuous
        await model.startSession()
        ai.queuedAnswers = ["I'd put the array into a Set, since a Set only keeps unique values, then spread it back into an array.\nCODE:\nfunction removeDuplicates(arr) {\n  return [...new Set(arr)];\n}"]
        await say(CodingTaskTests.instruction, at: 0)
        #expect(model.codingTasks.task?.language == "JavaScript")
        let requestsAfterQuestion = ai.requests.count

        await say(CodingTaskTests.approach, at: 10, seconds: 9)
        #expect(ai.requests.count == requestsAfterQuestion) // the candidate's explanation is not a question
        #expect(model.codingTasks.task?.dataStructures.contains("set") == true)

        ai.queuedAnswers = [CodingTaskTests.refusal, CodingTaskTests.good]
        await say(CodingTaskTests.followUp, at: 30)
        let request = try #require(ai.requests.last)
        #expect(request.prompt.contains("Active programming task"))
        #expect(request.prompt.contains("removes duplicate values"))
        #expect(request.instructions.contains("CODE:"))
        #expect(!request.instructions.contains("For questions about their own past projects or history, give") || request.instructions.contains("never applies to requests to write"))
        let answer = try #require(model.engine.currentAnswer)
        #expect(answer.category == .coding)
        #expect(!answer.text.contains("haven't written")) // the refusal was rejected and regenerated
        #expect(answer.snippet?.code == "function removeDuplicates(arr) {\n  return [...new Set(arr)];\n}")
        #expect(answer.snippet?.steps.count == 2)
        // Code Tutor (guided walkthrough): the explanation first, then the code on Next.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.snippets.walkthrough?.answerID == answer.answerID)
        #expect(LensModel.visibleText([glasses.shown.last!], rowWidth: 60).joined(separator: " ").hasPrefix("Here's how I'd write it"))
        model.snippets.walkthroughNext()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(glasses.shown.last?.contains("return [...new Set(arr)];") == true)
    }

    @Test func aFragmentedQuestionProducesOneGenerationAboutTheRightProject() async {
        model.settings.continuousConversation = true
        await model.startSession()
        let start = Date().timeIntervalSince1970
        speech.onEvent?(.partial("Can you talk"))
        speech.onEvent?(.final("Can you talk about?", start: start, end: start + 1.4))
        speech.onEvent?(.final("Rezonic.", start: start + 2, end: start + 2.5))
        await model.tick(now: Date().addingTimeInterval(5))
        await model.engine.generationTask?.value
        #expect(model.finalizedTurns.count == 1)
        #expect(model.finalizedTurns.first?.normalized == "Can you talk about Resoniq?")
        #expect(generations(ai) == 1)
        #expect(ai.requests.first?.prompt.contains("Resoniq") == true)
        // The same request again with other words (a re-recognition) does not ask the model twice.
        speech.onEvent?(.final("Can you tell me about your project Resoniq?", start: start + 8, end: start + 10))
        await model.tick(now: Date().addingTimeInterval(20))
        await model.engine.generationTask?.value
        #expect(generations(ai) == 1)
    }
}

// MARK: Engine turn mapping

@MainActor @Suite(.serialized) struct TurnGenerationMappingTests {
    let glasses = MockGlassesDisplay()
    let ai = MockAIProvider()
    let engine: ConversationEngine

    init() {
        glasses.connect()
        var settings = AppSettings()
        settings.semanticClassification = false
        settings.lockAfterDisplay = false
        let ai = self.ai
        engine = ConversationEngine(settings: settings, ai: { ai }, presenter: GlassesPresenter(display: glasses))
        engine.start()
    }

    func handle(_ text: String, id: Int, revision: Bool = false) async {
        await engine.handle(CompletedTurn(text: text, start: 0, end: 1, turnID: id, isRevision: revision))
        await engine.generationTask?.value
    }

    @Test func rewordedReRecognitionDoesNotRegenerate() async {
        await handle("Can you tell me about your project Diskarte?", id: 1)
        await handle("Can you talk about your project Diskarte?", id: 2)
        #expect(generations(ai) == 1)
    }

    @Test func aRevisionOnlyRegeneratesWhenTheRequestChanged() async {
        await handle("What is a primary key?", id: 1)
        await handle("What is a primary key?", id: 1, revision: true)
        #expect(generations(ai) == 1)
        await handle("What is a foreign key?", id: 1, revision: true)
        #expect(generations(ai) == 2)
        #expect(engine.turnAnswers[1] == engine.currentAnswer?.answerID)
    }

    @Test func similarButDistinctQuestionsAreBothAnswered() async {
        await handle("What is a primary key?", id: 1)
        await handle("What is a foreign key?", id: 2)
        #expect(generations(ai) == 2)
    }

    @Test func aRevisionCancelsTheStaleGenerationForThatTurn() async {
        ai.perWordDelay = .milliseconds(10)
        ai.queuedAnswers = ["A primary key uniquely identifies each row in a table and can never be null.",
                            "A foreign key references the primary key of another table to link related rows."]
        await engine.handle(CompletedTurn(text: "What is a primary key?", start: 0, end: 1, turnID: 1))
        try? await Task.sleep(for: .milliseconds(30))
        await handle("What is a foreign key?", id: 1, revision: true)
        #expect(engine.currentAnswer?.text.hasPrefix("A foreign key") == true)
        #expect(!glasses.shown.contains { $0.contains("uniquely identifies") })
    }
}

// MARK: Context and topic changes

@MainActor @Suite(.serialized) struct TopicChangeTests {
    @Test func projectTopicChangesAndProjectFollowUps() async {
        let ai = MockAIProvider()
        let glasses = MockGlassesDisplay()
        let model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [MockSpeech()] }, aiFactory: { _ in ai },
                             glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.settings.semanticClassification = false
        model.settings.continuousConversation = true
        await model.startSession()
        func ask(_ text: String, _ answer: String, id: Int) async {
            ai.queuedAnswers = [answer]
            await model.engine.handle(CompletedTurn(text: text, start: 0, end: 1, turnID: id))
            await model.engine.generationTask?.value
        }
        await ask("Tell me about your FJuan project.", "FJuan is my Formula 1 analytics dashboard using OpenF1 telemetry and driver comparisons.", id: 1)
        #expect(model.conversation.project == "FJuan")
        await ask("Now tell me about Diskarte.", "Diskarte is a Next.js communication platform with Supabase auth and realtime messaging.", id: 2)
        #expect(model.engine.currentAnswer?.kind == .newQuestion)
        #expect(model.conversation.project == "Diskarte")
        #expect(ai.requests.last?.prompt.contains("Diskarte: Next.js communication platform") == true)
        await ask("What about security?", "In Diskarte I relied on Supabase authentication with access controls for each conversation.", id: 3)
        let prompt = ai.requests.last?.prompt ?? ""
        #expect(prompt.contains("Diskarte: Next.js communication platform"))
        #expect(!prompt.contains("FJuan: Formula 1"))
        #expect(model.conversation.project == "Diskarte")
    }
}

// MARK: Structured code and the Code Tutor display

@MainActor @Suite struct StructuredCodeTests {
    @Test func structuredSectionsAreParsedAndNeverReachTheCode() throws {
        let (spoken, snippet) = CodeSnippet.split(CodingTaskTests.good, question: CodingTaskTests.instruction)
        let code = try #require(snippet)
        #expect(spoken.hasPrefix("Here's how I'd write it"))
        #expect(code.code == "function removeDuplicates(arr) {\n  return [...new Set(arr)];\n}")
        #expect(code.steps == ["Create a Set from the array", "Spread the Set into a new array"])
        #expect(code.edgeCases == ["Objects are compared by reference"])
        #expect(code.complexity == "O(n) time and space")
        #expect(code.tests == ["removeDuplicates([1, 1, 2]) returns [1, 2]"])
        #expect(code.problem == CodingTaskTests.instruction)
    }

    @Test(arguments: [
        "function removeDuplicates(arr) {\n  return [...new Set(arr)];\n}",
        "function getActiveStudents(students: Student[]): Student[] {\n  return students.filter(student => student.status === \"active\");\n}",
        "const [query, setQuery] = useState(\"\");\n\nconst visible = students.filter(student =>\n  student.name.toLowerCase().includes(query.toLowerCase())\n);",
        "SELECT product_id, SUM(quantity) AS total_sold\nFROM sales\nGROUP BY product_id;",
    ])
    func regressionExamplesKeepEveryTokenOnTheLens(_ code: String) {
        let snippet = CodeSnippet(language: "", code: code, steps: ["Step one", "Step two"])
        for width in [26, 34, 48] {
            let rows = snippet.lensRows(width: width)
            #expect(rows.allSatisfy { $0.count <= width })
            let rejoined = rows.map { $0.replacingOccurrences(of: "» ", with: "") }.joined().filter { !$0.isWhitespace }
            #expect(rejoined == code.filter { !$0.isWhitespace })
        }
        let pages = snippet.tutorPages(width: 48, lines: 4)
        #expect(pages.allSatisfy { $0.count <= 4 && $0.allSatisfy { $0.count <= 48 } })
        #expect(pages.first?.first?.hasPrefix("1/") == true)
    }
}

@MainActor @Suite(.serialized) struct CodeTutorDisplayTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let controller: CodeSnippetController
    let snippet = CodeSnippet(language: "javascript", code: "function removeDuplicates(arr) {\n  return [...new Set(arr)];\n}",
                              steps: ["Create a Set from the array", "Spread the Set into a new array"])

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses)
        presenter.frameRows = 5
        controller = CodeSnippetController(presenter: presenter)
        controller.duration = 0.1
        controller.tick = 0.02
    }

    func wait(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }

    @Test func tutorStepsStayUntilNavigationAndNeverAccumulate() async {
        await presenter.present("Use a Set to remove duplicates.", answerID: 1)
        controller.show(snippet, answerID: 1, mode: .tutor)
        await wait()
        #expect(glasses.shown.last?.contains("1/2 Create a Set") == true)
        await wait(0.3) // longer than the preview duration: tutor pages do not expire
        #expect(glasses.shown.last?.contains("1/2 Create a Set") == true)
        controller.nextStep()
        await wait()
        #expect(glasses.shown.last?.contains("2/2 Spread the Set") == true)
        #expect(LensModel.visibleText([glasses.shown.last!], rowWidth: 60).count <= 4) // one page visible, nothing stacked
        controller.previousStep()
        await wait()
        #expect(glasses.shown.last?.contains("1/2") == true)
    }

    @Test func duplicateActivationIsSuppressed() async {
        await presenter.present("Use a Set.", answerID: 1)
        controller.show(snippet, answerID: 1, mode: .tutor)
        await wait()
        let count = glasses.shown.count
        controller.show(snippet, answerID: 1, mode: .tutor)
        await wait()
        #expect(glasses.shown.count == count)
    }

    @Test func newAnswerAndReconnectionNeverRestoreOldCode() async {
        await presenter.present("Use a Set.", answerID: 1)
        controller.show(snippet, answerID: 1, mode: .tutor)
        await wait()
        glasses.simulateDrop()
        #expect(!controller.tutorActive)
        glasses.connect()
        await wait()
        #expect(glasses.shown.last?.contains("removeDuplicates") == false)
        controller.show(snippet, answerID: 1, mode: .tutor)
        await wait()
        await presenter.present("A different answer about DNS.", answerID: 2)
        await wait()
        #expect(!controller.tutorActive)
        #expect(glasses.shown.last?.contains("removeDuplicates") == false)
    }

    @Test func previewModeStillExpires() async {
        await presenter.present("Use a Set.", answerID: 1)
        controller.show(snippet, answerID: 1, mode: .preview)
        await wait()
        #expect(glasses.shown.last?.contains("removeDuplicates") == true)
        await wait(0.25)
        #expect(glasses.shown.last?.contains("removeDuplicates") == false)
    }
}
