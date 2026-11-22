import Foundation
import Testing
@testable import RayNeoInterviewCompanion

enum Walk {
    /// The requested example: EXPLAIN → CODE → EXPLAIN → CODE → RESULT.
    static let javascript = """
    EXPLAIN: I'd use a Set because it stores unique values. First, I'd create a function that accepts an array.
    CODE:
    function removeDuplicates(arr) {
      const unique = new Set(arr);
    EXPLAIN: Now I'd use the spread operator to convert that Set back into a regular array.
    CODE:
    function removeDuplicates(arr) {
      const unique = new Set(arr);
      return [...unique];
    }
    RESULT: This returns a new array containing only unique values, in their original order of first appearance.
    TEST: removeDuplicates([1, 1, 2]) // [1, 2]
    EDGE CASES: Objects are compared by reference.
    COMPLEXITY: O(n) time and O(n) space.
    """

    static let typescript = """
    EXPLAIN: I'd filter the students by their status.
    CODE:
    function getActiveStudents(students: Student[]): Student[] {
      return students.filter(student => student.status === "active");
    }
    RESULT: It returns only the active students.
    """

    static let react = """
    EXPLAIN: I'd keep the search text in state and filter while rendering.
    CODE:
    const [query, setQuery] = useState("");
    const visible = students.filter(student =>
      student.name.toLowerCase().includes(query.toLowerCase())
    );
    RESULT: The list updates as the user types.
    """

    static let python = """
    EXPLAIN: I'd convert the list to a dict to keep the first occurrence order.
    CODE:
    def remove_duplicates(items):
        return list(dict.fromkeys(items))
    RESULT: It returns the unique items in order.
    """

    static let sql = """
    EXPLAIN: I'd group the sales by product and add up the quantities.
    CODE:
    SELECT product_id, SUM(quantity) AS total_sold
    FROM sales
    GROUP BY product_id;
    RESULT: Each row is a product with its total sold.
    """

    static let execjs = """
    EXPLAIN: I'd run the JavaScript from Python.
    CODE:
    import execjs
    ctx = execjs.compile("function f(a){return [...new Set(a)]}")
    print(ctx.call("f", [1, 1, 2]))
    RESULT: It prints the unique values.
    """
}

@Suite struct WalkthroughModelTests {
    @Test func interleavedBlocksKeepOrderIdentityAndAFinalCompleteSolution() throws {
        let walkthrough = try #require(CodingWalkthrough.parse(Walk.javascript, language: "JavaScript", answerID: 7, taskID: "task-1"))
        #expect(walkthrough.blocks.map(\.kind) == [.explanation, .code, .explanation, .code, .result, .test])
        #expect(walkthrough.blocks.map(\.id) == ["w7-b0", "w7-b1", "w7-b2", "w7-b3", "w7-b4", "w7-b5"])
        #expect(walkthrough.blocks[1].isComplete == false) // intermediate fragment
        #expect(walkthrough.blocks[3].isComplete)
        #expect(walkthrough.finalCode == "function removeDuplicates(arr) {\n  const unique = new Set(arr);\n  return [...unique];\n}")
        #expect(walkthrough.next(of: walkthrough.blocks[1])?.kind == .explanation)
        #expect(walkthrough.previous(of: walkthrough.blocks[1])?.id == "w7-b0")
        #expect(walkthrough.edgeCases == ["Objects are compared by reference."])
        #expect(walkthrough.complexity == "O(n) time and O(n) space.")
        #expect(walkthrough.spokenText.hasPrefix("I'd use a Set because it stores unique values."))
        #expect(!walkthrough.spokenText.contains("const unique"))
        #expect(walkthrough.problem(requiredLanguage: "JavaScript") == nil)
    }

    @Test(arguments: [(Walk.javascript, "JavaScript"), (Walk.typescript, "TypeScript"), (Walk.react, "React"),
                      (Walk.python, "Python"), (Walk.sql, "SQL")])
    func eachLanguageIsRecognisedAndAccepted(_ raw: String, _ language: String) throws {
        let walkthrough = try #require(CodingWalkthrough.parse(raw, language: language))
        #expect(walkthrough.problem(requiredLanguage: language) == nil, "\(language)")
        // Code lines never lose characters on the lens.
        for block in walkthrough.blocks where block.kind.isCode {
            let rows = CodeSnippet(language: language, code: block.text).lensRows(width: 30)
            #expect(rows.allSatisfy { $0.count <= 30 })
            #expect(rows.map { $0.replacingOccurrences(of: "» ", with: "") }.joined().filter { !$0.isWhitespace } == block.text.filter { !$0.isWhitespace })
        }
    }

    @Test func languageDriftAndRuntimeWrappersAreRejected() throws {
        let wrapped = try #require(CodingWalkthrough.parse(Walk.execjs, language: "JavaScript"))
        #expect(wrapped.problem(requiredLanguage: "JavaScript")?.contains("another language's runtime") == true)
        let python = try #require(CodingWalkthrough.parse(Walk.python, language: "JavaScript"))
        #expect(python.problem(requiredLanguage: "JavaScript")?.contains("Python") == true)
        let plainJS = try #require(CodingWalkthrough.parse(Walk.javascript, language: "TypeScript"))
        #expect(plainJS.problem(requiredLanguage: "TypeScript") != nil)
        #expect(CodeLanguageDetector.detect("return { status: Active, name: user.name };") != "TypeScript") // a plain object literal is not a type
    }

    @Test func incoherentOrIncompleteCodeIsRejected() throws {
        let dropped = """
        EXPLAIN: First I'd keep a set of seen values.
        CODE:
        function removeDuplicates(arr) {
          const seen = new Set();
        EXPLAIN: Then return the unique values.
        CODE:
        function removeDuplicates(arr) {
          return [...new Set(arr)];
        }
        RESULT: Done.
        """
        #expect(try #require(CodingWalkthrough.parse(dropped, language: "JavaScript")).problem(requiredLanguage: "JavaScript")?.contains("seen") == true)
        let unbalanced = "EXPLAIN: Here it is.\nCODE:\nfunction f(arr) {\n  return [...new Set(arr)];\nRESULT: Done."
        #expect(try #require(CodingWalkthrough.parse(unbalanced, language: "JavaScript")).problem(requiredLanguage: "JavaScript")?.contains("complete") == true)
    }

    @Test func malformedOutputIsRepairedOrRefused() throws {
        #expect(CodingWalkthrough.parse("I'd use a Set and spread it back into an array.", language: "JavaScript") == nil)
        // Older single-CODE format with fences: repaired into EXPLAIN → CODE → TEST.
        let old = "Use a Set.\nCODE:\n```js\nconst unique = (items) => [...new Set(items)];\n```\nSTEPS:\n1. Make a Set\nTESTS:\n- unique([1, 1]) is [1]"
        let repaired = try #require(CodingWalkthrough.parse(old, language: "JavaScript"))
        #expect(repaired.blocks.map(\.kind) == [.explanation, .code, .test])
        #expect(repaired.finalCode == "const unique = (items) => [...new Set(items)];")
        #expect(repaired.steps == ["Make a Set"])
    }

    @Test func spokenNavigationNeedsAnExactShortCommand() {
        #expect(WalkthroughCommand.parse("Next step.") == .next)
        #expect(WalkthroughCommand.parse("go back") == .previous)
        #expect(WalkthroughCommand.parse("The next step is to spread it into an array") == nil)
        #expect(WalkthroughCommand.parse("What comes next?") == nil)
    }
}

@MainActor @Suite(.serialized) struct WalkthroughPipelineTests {
    func pipeline(_ ai: MockAIProvider, resolver: @escaping (String) -> ResolvedCodingRequest? = { _ in nil }) -> AnswerPipeline {
        let pipeline = AnswerPipeline(provider: ai, instructions: { _ in "Rules." }, notes: { _ in [] }, answerLength: .standard, hasPortfolio: false)
        pipeline.codingResolver = resolver
        pipeline.answerID = 9
        return pipeline
    }

    @Test func oneRequestProducesTheWholeValidatedWalkthrough() async throws {
        let ai = MockAIProvider()
        ai.answer = Walk.javascript
        let output = try await pipeline(ai).answer("Write a JavaScript function that removes duplicate values from an array.", previous: nil)
        #expect(ai.requests.count == 1) // never one request per block
        #expect(ai.requests[0].instructions.contains("Write all code in JavaScript only"))
        let walkthrough = try #require(output.walkthrough)
        #expect(walkthrough.answerID == 9)
        #expect(output.text == walkthrough.spokenText)
        #expect(output.snippet?.code == walkthrough.finalCode)
        #expect(output.validation == "passed")
        #expect(output.generationComplete)
    }

    @Test func wrongLanguageIsRegeneratedOnceThenDropped() async throws {
        let ai = MockAIProvider()
        ai.queuedAnswers = [Walk.execjs]
        ai.answer = Walk.javascript
        let fixed = try await pipeline(ai).answer("Write a JavaScript function that removes duplicate values from an array.", previous: nil)
        #expect(ai.requests.count == 2)
        #expect(ai.requests[1].instructions.contains("another language's runtime"))
        #expect(fixed.walkthrough != nil && fixed.regenerated)

        let stubborn = MockAIProvider()
        stubborn.answer = Walk.python
        let output = try await pipeline(stubborn).answer("Write a JavaScript function that removes duplicate values from an array.", previous: nil)
        #expect(output.walkthrough == nil) // never shown step by step
        #expect(!output.generationComplete) // and no end marker
    }

    @Test func missingCodeIsRegenerated() async throws {
        let ai = MockAIProvider()
        ai.queuedAnswers = ["I'd put the array into a Set and spread it back into an array to remove duplicate values."]
        ai.answer = Walk.javascript
        let output = try await pipeline(ai).answer("Write a JavaScript function that removes duplicate values from an array.", previous: nil)
        #expect(ai.requests.count == 2)
        #expect(output.walkthrough != nil)
    }

    @Test func followUpsInheritTheTaskLanguage() async throws {
        let tracker = CodingTaskTracker()
        tracker.observe("Write a JavaScript function that removes duplicate values from an array.", turnID: 1, startsNewTopic: true)
        let ai = MockAIProvider()
        ai.answer = Walk.javascript
        _ = try await pipeline(ai, resolver: { tracker.resolve($0) }).answer("Can you show me the code for that?", previous: nil)
        #expect(ai.requests[0].instructions.contains("Write all code in JavaScript only"))
        ai.answer = Walk.typescript
        _ = try await pipeline(ai, resolver: { tracker.resolve($0) }).answer("Can you make it TypeScript?", previous: nil)
        #expect(ai.requests[1].instructions.contains("Write all code in TypeScript only"))
    }

    @Test func truncatedWalkthroughsGetNoMarker() async throws {
        let ai = MockAIProvider()
        ai.answer = Walk.javascript
        ai.stopReason = "MAX_TOKENS"
        let output = try await pipeline(ai).answer("Write a JavaScript function that removes duplicate values from an array.", previous: nil)
        #expect(output.completion == "truncated (MAX_TOKENS)")
    }
}

@MainActor @Suite(.serialized) struct WalkthroughDisplayTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let controller: CodeSnippetController
    let walkthrough = CodingWalkthrough.parse(Walk.javascript, language: "JavaScript", answerID: 3)!

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses)
        presenter.frameRows = 5
        controller = CodeSnippetController(presenter: presenter)
        controller.duration = 0.1
    }

    func wait(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }
    var lens: String { LensModel.visibleText([glasses.shown.last ?? ""], rowWidth: 60).joined(separator: " ") }

    func start() async {
        await presenter.present(walkthrough.blocks[0].text, answerID: 3) // the engine shows the first explanation
        controller.startWalkthrough(walkthrough, snippet: nil, answerID: 3, endMarker: "\u{2713}")
        await wait()
    }

    @Test func nextAndPreviousWalkTheOneTimelineInOrder() async {
        await start()
        #expect(glasses.shown.count == 1) // starting did not rewrite the first explanation
        var seen: [String] = [lens]
        while !controller.atLastStep {
            controller.walkthroughNext()
            await wait()
            seen.append(lens)
        }
        #expect(seen.count == controller.walkthroughSteps.count)
        #expect(seen[0].hasPrefix("I'd use a Set"))
        #expect(seen[1].hasPrefix("function removeDuplicates(arr) {") && seen[1].contains("const unique = new Set(arr);")) // one page: no label
        #expect(seen[2].hasPrefix("Now I'd use the spread operator"))
        #expect(seen[3].hasPrefix("function removeDuplicates") && seen[3].contains("return [...unique];")) // 4 rows fill the lens: no label
        #expect(seen[4].hasPrefix("This returns a new array"))
        #expect(seen[5].contains("removeDuplicates([1, 1, 2])"))
        #expect(Set(seen).count == seen.count) // no block skipped or duplicated
        // The marker belongs to the final explanation, never to code.
        #expect(seen.filter { $0.contains("\u{2713}") }.isEmpty || seen[4].hasSuffix("\u{2713}"))
        #expect(!seen[1].contains("\u{2713}") && !seen[3].contains("\u{2713}") && !seen[5].contains("\u{2713}"))
        controller.walkthroughPrevious()
        await wait()
        #expect(lens.hasPrefix("This returns a new array"))
        #expect(controller.currentBlock?.kind == .result)
    }

    @Test func guidedCodeStaysUntilNavigationButCanBeTimed() async {
        await start()
        controller.walkthroughNext()
        await wait(0.3) // longer than the preview window
        #expect(lens.hasPrefix("function removeDuplicates(arr) {")) // the code block stays
        controller.walkthroughCodeSeconds = 0.1
        controller.walkthroughNext() // explanation
        controller.walkthroughNext() // code 2
        await wait(0.3)
        #expect(lens.hasPrefix("This returns a new array")) // advanced by the optional timer
        controller.pauseWalkthrough()
        controller.walkthroughNext() // manual navigation still works while paused
        await wait()
        #expect(lens.contains("removeDuplicates([1, 1, 2])"))
    }

    @Test func longCodeBlocksSplitIntoPartsOfTheSameBlock() {
        let long = (1...9).map { "  const v\($0) = items[\($0)];" }.joined(separator: "\n")
        let raw = "EXPLAIN: Declare the values.\nCODE:\nfunction f(items) {\n\(long)\n}\nRESULT: Done."
        let parsed = CodingWalkthrough.parse(raw, language: "JavaScript")!
        let steps = CodeSnippetController.steps(for: parsed, width: 48, lines: 4)
        let code = steps.filter { !$0.rows.isEmpty }
        #expect(code.count == 3)                       // 11 lines on 4-row pages
        #expect(Set(code.map(\.block)) == [1])          // parts of the same parent block, in order
        #expect(code.map(\.part) == [0, 1, 2])
        #expect(code.first?.rows.first == "function f(items) {")
        #expect(code.first?.rows.last?.hasSuffix("(1/3)") == true) // compact part marker on the last row
        #expect(code.allSatisfy { $0.rows.count <= 4 })
    }

    @Test func reconnectionRestoresTheCurrentCodeBlock() async {
        await start()
        controller.walkthroughNext()
        await wait()
        let codeFrame = glasses.shown.last
        glasses.simulateDrop()
        glasses.connect()
        await wait()
        #expect(glasses.shown.last == codeFrame)
        #expect(controller.walkthrough != nil)
        #expect(controller.currentBlock?.kind == .code)
    }

    @Test func aNewAnswerEndsTheWalkthroughAndItNeverReturns() async {
        await start()
        controller.walkthroughNext()
        await wait()
        await presenter.present("A different answer about DNS caching.", answerID: 4)
        await wait()
        #expect(controller.walkthrough == nil)
        controller.walkthroughNext()
        await wait()
        #expect(lens == "A different answer about DNS caching.")
    }

    @Test func duplicateActivationIsSuppressed() async {
        await start()
        let count = glasses.shown.count
        controller.startWalkthrough(walkthrough, snippet: nil, answerID: 3, endMarker: nil)
        await wait()
        #expect(glasses.shown.count == count)
    }
}

/// Speech-driven navigation through AppModel: explanations advance when read, code only on a command.
@MainActor @Suite(.serialized) struct WalkthroughSpeechTests {
    let speech = MockSpeech()
    let ai = MockAIProvider()
    let glasses = MockGlassesDisplay()
    let model: AppModel

    init() {
        let speech = self.speech, ai = self.ai, glasses = self.glasses
        model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [speech] }, aiFactory: { _ in ai },
                         glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.settings.semanticClassification = false
        model.settings.readingMode = .speechSynced
    }

    func wait(_ seconds: Double = 0.08) async { try? await Task.sleep(for: .seconds(seconds)) }

    @Test func readingTheExplanationShowsTheCodeAndOnlyACommandMovesOn() async throws {
        await model.startSession()
        ai.answer = Walk.javascript
        speech.onEvent?(.final("Write a JavaScript function that removes duplicate values from an array.", start: 0, end: 3))
        await model.tick(now: Date().addingTimeInterval(10))
        await model.engine.generationTask?.value
        await wait()
        let walkthrough = try #require(model.snippets.walkthrough)
        #expect(model.engine.currentAnswer?.walkthrough?.taskID == model.codingTasks.task?.id)
        #expect(model.snippets.currentBlock?.kind == .explanation)

        // Reading the first explanation aloud (partials) advances to its code.
        let words = walkthrough.blocks[0].text.split(separator: " ")
        for count in 1...words.count { speech.onEvent?(.partial(words.prefix(count).joined(separator: " "))) }
        await wait()
        #expect(model.snippets.currentBlock?.kind == .code)

        // Unrelated speech and a sentence containing "next" do not move a code block.
        speech.onEvent?(.final("The next part is honestly the easy bit", start: 20, end: 22))
        await model.tick(now: Date().addingTimeInterval(20))
        await wait()
        #expect(model.snippets.currentBlock?.kind == .code)
        let requests = ai.requests.count

        // An exact command does, and is never sent to the model.
        speech.onEvent?(.final("Next step.", start: 30, end: 31))
        await model.tick(now: Date().addingTimeInterval(30))
        await wait()
        #expect(model.snippets.currentBlock?.index == 2)
        #expect(ai.requests.count == requests)
    }
}
