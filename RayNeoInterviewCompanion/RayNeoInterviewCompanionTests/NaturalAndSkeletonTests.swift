import Foundation
import Testing
@testable import RayNeoInterviewCompanion

// MARK: Natural Answer Mode

@Suite struct NaturalAnswerStyleTests {
    @Test func roboticOpenersAndCorporateWordsAreRemoved() {
        #expect(NaturalAnswerStyle.polish("Great question! Certainly, I'd start with the logs.") == "I'd start with the logs.")
        #expect(NaturalAnswerStyle.polish("That's a really good question. I'd check the token first.") == "I'd check the token first.")
        #expect(NaturalAnswerStyle.polish("Leverage the cache in order to utilize fewer calls.") == "Use the cache to use fewer calls.")
        #expect(NaturalAnswerStyle.polish("I'd check the logs first.") == "I'd check the logs first.") // untouched
    }

    @Test func polishIsPrefixStableSoEarlyFramesMatchTheFinalAnswer() {
        let full = "Great question. I'd leverage the API logs first. Then I'd utilize the sign-in logs to narrow it down."
        let prefix = "Great question. I'd leverage the API logs first."
        #expect(NaturalAnswerStyle.polish(full).hasPrefix(NaturalAnswerStyle.polish(prefix)))
    }

    @Test func repetitiveOpeningsAreDetected() {
        let repetitive = "I'd check the logs. I'd check the token. I'd check the mappings. Then I'd replay a request."
        #expect(NaturalAnswerStyle.repetitiveOpening(repetitive) != nil)
        #expect(NaturalAnswerStyle.repetitiveOpening("I'd check the logs. Then the token. After that, the mappings. Finally I'd replay one.") == nil)
    }

    @Test func instructionsAskForAdaptiveLengthAndDirectFollowUps() {
        let text = InterviewPromptBuilder.instructions(for: .technical, length: .standard, portfolio: "")
        #expect(text.contains("about 3 to 5 sentences for a straightforward question"))
        #expect(text.contains("6 to 9 or more when a complex topic needs it"))
        #expect(text.contains("Prioritise substance over sentence count"))
        #expect(text.contains("answer the latest question directly"))
        #expect(text.contains("never open with \"Great question\""))
        #expect(!text.contains("3-5 short spoken sentences"))
    }

    @MainActor @Test func repetitiveDraftsAreRegeneratedOnce() async throws {
        let ai = MockAIProvider()
        ai.queuedAnswers = ["I'd check the integration logs. I'd check the token. I'd check the field mappings. I'd replay the request."]
        ai.answer = "I'd start with the integration logs. Then the token and the field mappings. After that, I'd replay one failed request."
        let pipeline = AnswerPipeline(provider: ai, instructions: { _ in "Rules." }, notes: { _ in [] }, answerLength: .standard, hasPortfolio: false)
        let output = try await pipeline.answer("How would you debug a failing integration?", previous: nil)
        #expect(ai.requests.count == 2)
        #expect(ai.requests[1].instructions.contains("vary the openings"))
        #expect(output.text == ai.answer)
    }
}

// MARK: Sentence-level streaming

@MainActor @Suite(.serialized) struct SentenceStreamingTests {
    @Test func theFirstValidatedSentenceAppearsEarlyAndTheFrameOnlyGrows() async throws {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses)
        presenter.frameRows = 5
        let reading = ReadingController(presenter: presenter)
        reading.lineScrollingAllowed = false
        reading.mode = .speechSynced
        let ai = MockAIProvider()
        ai.answer = Canon.longAnswer
        ai.perWordDelay = .milliseconds(6)
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        for _ in 0..<300 where glasses.shown.isEmpty { try? await Task.sleep(for: .milliseconds(3)) }
        #expect(engine.state == .generating)
        let first = LensModel.visibleText([glasses.shown[0]], rowWidth: 60).joined(separator: " ")
        #expect(first == "I'd check the API logs to see where the request is failing.") // one complete sentence
        reading.ingest("I'd check the API logs to see", isFinal: false, speaker: .unknown)
        let cursor = reading.cursorWord
        await engine.generationTask?.value
        // Every update kept the words already shown and only appended complete sentences.
        let frames = glasses.shown.map { LensModel.visibleText([$0], rowWidth: 60).joined(separator: " ") }
        for (earlier, later) in zip(frames, frames.dropFirst()) { #expect(later.hasPrefix(earlier), "\(earlier) → \(later)") }
        #expect(frames.last == presenter.plan?.sections.first?.text)
        reading.ingest("I'd check the API logs to see", isFinal: false, speaker: .unknown)
        #expect(reading.cursorWord >= cursor) // reading progress survived the growth
    }
}

// MARK: Coding Skeleton Mode

enum Skeleton {
    static let walkthrough = """
    SKELETON:
    function getActiveStudents(students) {
      // keep the active ones
      return [];
    }
    EXPLAIN: I'd filter the students array and keep each student whose status is active.
    CODE:
    function getActiveStudents(students) {
      return students.filter(student => student.status === "active");
    }
    RESULT: It returns a new array with only the active students.
    """
}

@Suite struct SkeletonModelTests {
    @Test func aSkeletonOpensTheTimelineAndIsValidated() throws {
        let walkthrough = try #require(CodingWalkthrough.parse(Skeleton.walkthrough, language: "JavaScript", answerID: 2))
        #expect(walkthrough.blocks.map(\.kind) == [.skeleton, .explanation, .code, .result])
        #expect(walkthrough.problem(requiredLanguage: "JavaScript") == nil)
        #expect(!walkthrough.spokenText.contains("return []"))
        #expect(walkthrough.finalCode?.contains("filter") == true) // the skeleton is never the final code
    }

    @Test func badSkeletonsAreRejected() throws {
        let renamed = Skeleton.walkthrough.replacingOccurrences(of: "function getActiveStudents(students) {\n  // keep", with: "function activeOnly(students) {\n  // keep")
        #expect(try #require(CodingWalkthrough.parse(renamed, language: "JavaScript")).problem(requiredLanguage: "JavaScript")?.contains("activeOnly") == true)
        let unbalanced = Skeleton.walkthrough.replacingOccurrences(of: "  return [];\n}", with: "  return [];")
        #expect(try #require(CodingWalkthrough.parse(unbalanced, language: "JavaScript")).problem(requiredLanguage: "JavaScript")?.contains("skeleton") == true)
        let python = Skeleton.walkthrough.replacingOccurrences(of: "function getActiveStudents(students) {\n  // keep the active ones\n  return [];\n}",
                                                                with: "def get_active_students(students):\n    pass")
        #expect(try #require(CodingWalkthrough.parse(python, language: "JavaScript")).problem(requiredLanguage: "JavaScript") != nil)
    }

    @Test func aMissingSkeletonIsDerivedFromTheFinalCode() throws {
        let plain = try #require(CodingWalkthrough.parse(Walk.javascript, language: "JavaScript", answerID: 4)).withSkeleton()
        #expect(plain.blocks.first?.kind == .skeleton)
        #expect(plain.blocks.first?.text == "function removeDuplicates(arr) {\n  // implementation below\n}")
        #expect(plain.blocks.map(\.id) == plain.blocks.indices.map { "w4-b\($0)" })
        #expect(plain.problem(requiredLanguage: "JavaScript") == nil)
        #expect(CodingWalkthrough.deriveSkeleton("def f(items):\n    seen = set()\n    return seen", language: "Python") == "def f(items):\n    ...  # implementation below")
        #expect(CodingWalkthrough.deriveSkeleton("SELECT a\nFROM b\nGROUP BY a;", language: "SQL") == nil)
    }

    @Test func aStreamingSkeletonIsOnlyTakenOnceItsBlockIsComplete() {
        #expect(CodingWalkthrough.completedSkeleton(in: "SKELETON:\nfunction f(a) {\n  // body") == nil)
        #expect(CodingWalkthrough.completedSkeleton(in: "SKELETON:\nfunction f(a) {\n  // body\n}\nEXPLAIN: First") == "function f(a) {\n  // body\n}")
    }
}

@MainActor @Suite(.serialized) struct SkeletonDisplayTests {
    let speech = MockSpeech()
    let ai = MockAIProvider()
    let glasses = MockGlassesDisplay()
    let model: AppModel

    init() {
        let speech = self.speech, ai = self.ai, glasses = self.glasses
        model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [speech] }, aiFactory: { _ in ai },
                         glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.settings.semanticClassification = false
    }

    func ask(_ text: String, at start: Double) async {
        speech.onEvent?(.final(text, start: start, end: start + 2))
        await model.tick(now: Date().addingTimeInterval(10))
    }

    @Test func theSkeletonAppearsWhileGeneratingAndTheWalkthroughAdoptsIt() async throws {
        await model.startSession()
        ai.answer = Skeleton.walkthrough
        ai.perWordDelay = .milliseconds(8)
        await ask("Write a JavaScript function that filters active students.", at: 0)
        for _ in 0..<300 where !(glasses.shown.last?.contains("// keep the active ones") ?? false) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.engine.state == .generating)            // shown before the answer finished
        #expect(glasses.shown.last?.contains("// keep the active ones") == true)
        await model.engine.generationTask?.value
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.snippets.currentBlock?.kind == .skeleton)
        let skeletonWrites = glasses.shown.filter { $0.contains("// keep the active ones") }
        #expect(skeletonWrites.count == 1)                     // adopted without a second write
        // It stays: speech and time never remove it.
        speech.onEvent?(.final("I'm going to filter the students and keep the active ones.", start: 20, end: 23))
        await model.tick(now: Date().addingTimeInterval(20))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.snippets.currentBlock?.kind == .skeleton)
        model.snippets.walkthroughNext()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(LensModel.visibleText([glasses.shown.last!], rowWidth: 60).joined(separator: " ").hasPrefix("I'd filter the students"))
    }

    @Test func theSkeletonWaitsForTheEndOfYourSentenceAndLeavesIfTheAnswerIsCancelled() async throws {
        await model.startSession()
        ai.answer = "I'd check the API logs first, then the integration user's token and the field mappings."
        await ask("How would you troubleshoot a Salesforce integration?", at: 0)
        await model.engine.generationTask?.value
        speech.onEvent?(.partial("I'd check the API logs first")) // the wearer is reading the answer aloud
        model.snippets.showEarlySkeleton("function f(a) {\n  // body\n}", answerID: 999)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(glasses.shown.last?.contains("// body") == false)
        #expect(model.snippets.pendingEarlySkeleton != nil)
        speech.onEvent?(.final("I'd check the API logs first", start: 5, end: 7))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(glasses.shown.last?.contains("// body") == true)
        model.snippets.withdrawEarlySkeleton(answerID: 999)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(glasses.shown.last?.contains("// body") == false)
        #expect(LensModel.visibleText([glasses.shown.last!], rowWidth: 60).joined(separator: " ").hasPrefix("I'd check the API logs first"))
    }
}

// MARK: Measured latency (simulated providers; real Gemini/RayNeo timings need the device)

@MainActor @Suite(.serialized) struct LatencyMeasurementTests {
    @Test func completeQuestionsEndpointFaster() {
        let t0 = Date(timeIntervalSince1970: 0)
        var question = TranscriptTurnAssembler(silence: 1.2)
        _ = question.final("How would you secure a REST API?", start: 0, end: 2, at: t0)
        #expect(question.tick(now: t0.addingTimeInterval(0.59)) == nil)
        #expect(question.tick(now: t0.addingTimeInterval(0.6)) != nil)
        var statement = TranscriptTurnAssembler(silence: 1.2)
        _ = statement.final("Tell me about your testing approach.", start: 0, end: 2, at: t0)
        #expect(statement.tick(now: t0.addingTimeInterval(1.19)) == nil) // statements keep the full silence
        #expect(statement.tick(now: t0.addingTimeInterval(1.2)) != nil)
        print("LATENCY endpointing: complete question 0.60 s (was 1.20 s); statements unchanged 1.20 s")
    }

    @Test func firstFrameArrivesAtTheFirstSentenceInsteadOfTheFirstFullFrame() async {
        let delay = 0.006
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses)
        presenter.frameRows = 5
        let ai = MockAIProvider()
        ai.answer = Canon.longAnswer
        ai.perWordDelay = .milliseconds(6)
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        await engine.generationTask?.value
        let measured = engine.currentAnswer?.earlyFrameSeconds ?? .infinity
        let words = Canon.longAnswer.split(separator: " ")
        // Real per-word time of this simulated stream (scheduling overhead included).
        let perWord = (engine.currentAnswer?.firstTokenSeconds).map { _ in (engine.currentAnswer?.totalSeconds ?? 0) / Double(words.count) } ?? delay
        // The previous policy waited until the complete sentences filled more than one frame.
        let previousWords = (1...words.count).first { count in
            presenter.stableFirstFrame(of: AnswerFormatter.completeSentences(words.prefix(count).joined(separator: " ") + " ")) != nil
        } ?? words.count
        let firstSentenceWords = "I'd check the API logs to see where the request is failing.".split(separator: " ").count
        print(String(format: "LATENCY first frame: measured %.3f s (first sentence, %d words); previous policy needed %d words ≈ %.3f s at the measured %.1f ms/word",
                     measured, firstSentenceWords, previousWords, Double(previousWords) * perWord, perWord * 1000))
        #expect(previousWords > firstSentenceWords * 2)
        #expect(measured < Double(previousWords) * perWord)
    }

    @Test func promptContextIsSmaller() {
        let model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [MockSpeech()] }, aiFactory: { _ in MockAIProvider() },
                             glassesFactory: { _ in MockGlassesDisplay() }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.conversation.record(question: "Tell me about the Diskarte database.", answer: String(repeating: "Supabase Postgres with realtime channels. ", count: 12),
                                  category: .technical, kind: .newQuestion, projects: model.memory.projects.compactMap(\.project))
        let question = "How did you secure the realtime messaging and the database in Diskarte?"
        let now = model.notes(for: question).joined(separator: "\n").count
        // The previous budgets, with the same section labels: 2 × 600-char topic notes, 900 memory, 700 conversation.
        let previous = (model.knowledge.notes(for: question)
                        + ["Verified background (mention a project only if it directly answers the question; never add details beyond this):\n"
                           + model.memory.retrieve(question, topicProject: model.conversation.project, budget: 900).text,
                           "Conversation so far (resolve \"that\", \"it\" and follow-ups against this):\n" + model.conversation.context(budget: 700)])
            .joined(separator: "\n").count
        print("LATENCY prompt context: \(now) chars now vs \(previous) chars with the previous budgets")
        #expect(now < previous)
        #expect(model.notes(for: question).joined().contains("Diskarte"))
    }
}
