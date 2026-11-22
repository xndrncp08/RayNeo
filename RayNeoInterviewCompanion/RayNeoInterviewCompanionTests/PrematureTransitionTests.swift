import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Explanation → code must wait for the whole explanation (the device bug: code appeared mid-explanation).
@Suite struct StrictExplanationToCodeTests {
    static let block = "I'd filter the students array by each student's status. Then I'd return only the students whose status is active."
    static let first = "I'd filter the students array by each student's status."

    func strict(_ finals: [String], partial: String? = nil, mode: AdaptiveWalkthroughMode = .balanced,
                alignment: Double = 0, readingComplete: Bool = false) -> WalkthroughCompletionEvaluator.Evaluation {
        var e = WalkthroughCompletionEvaluator(blockID: "w1-b0", text: Self.block, mode: mode)
        for text in finals { e.ingest(text, isFinal: true) }
        if let partial { e.ingest(partial, isFinal: false) }
        return e.evaluate(alignmentConfidence: alignment, readingComplete: readingComplete, utteranceEnded: partial == nil, strict: true)
    }

    @Test func theFirstSentenceAloneNeverShowsCode() {
        let result = strict([Self.first])
        #expect(!result.advance)
        #expect(result.reason.contains("sentence 2"))
        #expect(!strict([Self.first, Self.first, Self.first]).advance) // repeating it does not help
    }

    @Test func theWholeExplanationVerbatimOrInOwnWordsShowsCode() {
        #expect(strict([Self.block]).advance)
        #expect(strict([Self.first, "Then I'd return only the students whose status is active."]).advance) // with a long pause between
        #expect(strict(["So I'm going through the student list, checking each status, and returning only the ones that are active."]).advance)
    }

    @Test func partialParaphraseMidPhraseAndRevisionsWait() {
        #expect(!strict(["I'd go through the students and check their status"]).advance)
        #expect(!strict(["I'd filter the students by status and then return the"]).advance)          // ended mid-phrase
        #expect(!strict([], partial: Self.block).advance)                                               // no code mid-utterance
        let revised = strict(["I'd filter the students array by each student's status."], partial: "Then I'd return only the")
        #expect(!revised.advance)
    }

    @Test func readingToTheLastWordNeedsConfidentAlignment() {
        #expect(!strict([], readingComplete: true).advance || false)
        #expect(!strict([Self.first], alignment: 0.3, readingComplete: true).advance)
        #expect(strict([Self.first], alignment: 0.8, readingComplete: true).advance)
    }

    @Test func strictIsStricterThanBlockToBlock() {
        var lenient = WalkthroughCompletionEvaluator(blockID: "w1-b0", text: Self.block, mode: .balanced)
        lenient.ingest(Self.first, isFinal: true)
        // The old rule would have moved on here (most key ideas named); the code rule does not.
        #expect(lenient.evaluate(utteranceEnded: true).coverage >= 0.6)
        #expect(!strict([Self.first]).advance)
    }

    @Test func speechThatStartedBeforeTheBlockIsIgnored() {
        var e = WalkthroughCompletionEvaluator(blockID: "w1-b0", text: Self.block, mode: .balanced)
        e.skipUntilFinal = true
        e.ingest("…and that is why I'd filter the students by status and return the active ones", isFinal: false)
        e.ingest("…and that is why I'd filter the students by status and return the active ones.", isFinal: true)
        #expect(!e.evaluate(utteranceEnded: true, strict: true).advance)
        #expect(e.heardWordCount == 0)
    }
}

@MainActor @Suite(.serialized) struct TransitionCoordinatorTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let controller: CodeSnippetController
    let walkthrough = CodingWalkthrough.parse(Walk.javascript, language: "JavaScript", answerID: 3)!

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

    @Test func readingOnlyTheFirstSentenceKeepsTheExplanation() async {
        await start()
        controller.walkthroughSpeech("I'd use a Set because it stores unique values.", isFinal: true)
        await wait()
        #expect(controller.currentBlock?.index == 0)
        #expect(controller.lastEvaluation?.advance == false)
        controller.walkthroughSpeech("First, I'd create a function that accepts an array.", isFinal: true)
        await wait()
        #expect(controller.currentBlock?.kind == .code)
    }

    @Test func staleCallbacksAreRejected() async {
        await start()
        #expect(!controller.requestTransition(by: 1, source: .timer, expectedStep: 4, reason: "old timer"))
        #expect(!controller.requestTransition(by: 1, source: .semantic, expectedBlockID: "w3-b4", reason: "old evaluation"))
        #expect(controller.stepIndex == 0)
        controller.walkthroughNext()
        await wait()
        #expect(!controller.requestTransition(by: 1, source: .aiCheck, expectedStep: 0, reason: "late AI answer"))
        #expect(controller.stepIndex == 1)
    }

    @Test func aNewQuestionOrAnswerTakesPriority() async {
        await start()
        controller.interrupted = true
        #expect(!controller.requestTransition(by: 1, source: .semantic, expectedStep: 0, reason: "covered"))
        #expect(controller.requestTransition(by: 1, source: .manual, reason: "Next")) // manual control always works
        controller.interrupted = false
        await presenter.present("A different answer.", answerID: 9)
        await wait()
        #expect(controller.walkthrough == nil)
        #expect(!controller.requestTransition(by: 1, source: .semantic, reason: "late"))
        #expect(LensModel.visibleText([glasses.shown.last!], rowWidth: 60).joined(separator: " ") == "A different answer.")
    }

    @Test func codeTimersAreIsolatedFromManualMoves() async {
        controller.walkthroughCodeSeconds = 0.15
        await start()
        controller.walkthroughNext()          // code 1: timer armed for step 1
        await wait()
        controller.walkthroughNext()          // the wearer moved on manually
        controller.walkthroughNext()          // code 2
        await wait(0.12)                       // the step-1 timer fires now and must do nothing
        #expect(controller.stepIndex == 3)
    }
}

@Suite struct CodePaginatorTests {
    @Test func longLinesKeepEveryCharacterAndBreakOutsideStrings() {
        let line = #"const message = "Hello, world; (a) [b] {c}" + user.name + ", welcome back to the dashboard";"#
        let rows = CodePaginator.rows(line, width: 30)
        #expect(rows.allSatisfy { $0.text.count <= 30 })
        let rejoined = rows.map { $0.text.replacingOccurrences(of: CodePaginator.continuationMark, with: "") }.joined()
        #expect(rejoined.filter { !$0.isWhitespace } == line.filter { !$0.isWhitespace })
        // No row ends inside the first string literal (it has commas and semicolons inside it).
        #expect(!rows.contains { $0.text.hasSuffix("Hello,") || $0.text.hasSuffix("world;") })
        // Only the second literal is longer than a row, so at most one cut inside it is unavoidable.
        #expect(rows.filter(\.hardBreak).count <= 1)
    }

    @Test func identifiersAndOperatorsAreNotSplitWhenABoundaryExists() {
        let rows = CodePaginator.rows("const activeStudents = students.filter(student => student.isActive && student.enrolled);", width: 34)
        for row in rows {
            let text = row.text.replacingOccurrences(of: CodePaginator.continuationMark, with: "")
            #expect(!text.hasSuffix("activeStu") && !text.hasSuffix("&") && !text.hasPrefix("&&s"))
        }
        #expect(rows.filter(\.hardBreak).isEmpty)
    }

    @Test func nestedFunctionsKeepRelativeIndentation() {
        let code = "function outer(list) {\n    function inner(item) {\n        return item * 2;\n    }\n    return list.map(inner);\n}"
        let rows = CodePaginator.rows(code, width: 48, indentSpaces: 2).map(\.text)
        #expect(rows == ["function outer(list) {", "  function inner(item) {", "    return item * 2;", "  }", "  return list.map(inner);", "}"])
    }

    @Test func pagesKeepOrderKeepWrappedLinesTogetherAndDropBlankLines() {
        let code = (1...7).map { "let value\($0) = compute(\($0), options);" }.joined(separator: "\n\n")
        let (pages, report) = CodePaginator.paginate(code, layout: CodeDisplayLayout(rows: 3, charactersPerRow: 40))
        #expect(report.sourceLines == 7)
        #expect(pages.map(\.part) == Array(0..<pages.count))
        #expect(pages.allSatisfy { $0.rows.count <= 3 && $0.rows.allSatisfy { $0.count <= 40 } })
        #expect(!pages.flatMap(\.rows).contains(""))
        let joined = pages.flatMap(\.rows).joined(separator: " ")
        for index in 1...7 { #expect(joined.contains("value\(index)")) }
        // A single page gets no label at all.
        #expect(CodePaginator.paginate("return 1;", layout: CodeDisplayLayout()).pages.first?.rows == ["return 1;"])
    }

    @Test func codeLayoutPersistsAndOldSettingsDecode() throws {
        var settings = AppSettings()
        settings.codeLayout = CodeDisplayLayout(rows: 5, charactersPerRow: 56, indentSpaces: 1)
        settings.codeLayout.verified = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try #require(AppSettings.decodeMerged(data))
        #expect(decoded.codeLayout.charactersPerRow == 56 && decoded.codeLayout.verified)
        let old = try #require(AppSettings.decodeMerged(Data(#"{"captionStrategy":"sentenceFrames"}"#.utf8)))
        #expect(old.codeLayout == CodeDisplayLayout())
    }
}

/// The walkthrough uses the code layout, not the explanation layout.
@MainActor @Suite(.serialized) struct CodeLayoutIntegrationTests {
    @Test func codeFramesUseTheCalibratedCodeLayoutAndNeverExceedTheLens() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: CaptionLayout(maxLines: 3, charactersPerLine: 30))
        presenter.frameRows = 5
        let controller = CodeSnippetController(presenter: presenter)
        controller.codeLayout = CodeDisplayLayout(rows: 7, charactersPerRow: 56) // more rows than the lens: clamped to 5
        let walkthrough = CodingWalkthrough.parse(Walk.javascript, language: "JavaScript", answerID: 5)!
        await presenter.present(walkthrough.blocks[0].text, answerID: 5)
        controller.startWalkthrough(walkthrough, snippet: nil, answerID: 5, endMarker: nil)
        controller.walkthroughNext(); controller.walkthroughNext(); controller.walkthroughNext()
        try? await Task.sleep(for: .milliseconds(80))
        // The exact payload: one row per code line, indentation kept (the lens model's word wrapper would strip it).
        #expect(glasses.shown.last!.hasSuffix(" \nfunction removeDuplicates(arr) { \n  const unique = new Set(arr); \n  return [...unique]; \n}"))
        #expect(controller.walkthroughSteps.allSatisfy { $0.rows.count <= 5 })
    }
}
