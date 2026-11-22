import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Layout rules on the wrap model. These cannot prove what the lens renders; only calibration can.
@Suite struct CaptionLayoutTests {
    /// Deterministic generator for property tests.
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    static let vocabulary = [
        "I'd", "check", "the", "API", "logs", "first.", "Then", "I'd", "look", "at", "Microsoft", "Entra", "ID",
        "sign-in", "logs,", "MFA,", "SQL", "joins", "REST", "API", "to", "confirm", "it", "works.", "If", "it's",
        "a", "401,", "token", "expired?", "Node.js", "C#", ".NET", "async/await", "Promises", "conditional", "access",
        "policy", "Salesforce", "integration", "replay", "records!", "PostgreSQL", "row-level", "security", "ok",
        "configuration", "troubleshooting", "authentication", "observability", "(maybe)", "—", "3.5", "e.g.",
    ]

    static func randomAnswer(_ rng: inout LCG) -> String {
        (0..<Int.random(in: 1...160, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
    }

    @Test func defaultsLeaveOneLineOfMargin() {
        #expect(CaptionLayout.standard.maxLines == 4)
        #expect(CaptionLayout.standard.charactersPerLine == 48) // photo: rows hold ~55–60 characters
        #expect(!CaptionLayout.standard.contextLine)
        #expect(CaptionLayout.standard.fontSize == 2 && CaptionLayout.standard.finalStatus)
    }

    @Test func greedyWrapAndHardBreakOnlyForOverlongWords() {
        let layout = CaptionLayout(maxLines: 4, charactersPerLine: 10)
        #expect(layout.wrap("aa bb cc dd ee") == ["aa bb cc", "dd ee"])
        #expect(layout.wrap("abcdefghijklmnopqrstuvwxy z") == ["abcdefghij", "klmnopqrst", "uvwxy z"])
        #expect(layout.wrap("one two") == ["one two"])
    }

    /// Property: for random answers and layouts, nothing is dropped, duplicated or reordered, every window
    /// fits, the first window starts with the first word, and word ranges are contiguous.
    @Test(arguments: [(2, 12), (3, 18), (4, 26), (4, 34), (5, 48), (1, 30)])
    func randomAnswersNeverLoseOrOverflow(_ lines: Int, _ width: Int) {
        var rng = LCG(state: UInt64(lines * 1000 + width))
        for trial in 0..<150 {
            let answer = Self.randomAnswer(&rng)
            for context in [false, true] {
                let layout = CaptionLayout(maxLines: lines, charactersPerLine: width, contextLine: context, pageCounter: trial % 2 == 0)
                let plan = ReadingPlan(answer: answer, layout: layout)
                #expect(plan.sections.map(\.text).joined(separator: " ") == answer)
                #expect(plan.words == ReadingText.tokens(answer))
                #expect(plan.windows.allSatisfy { layout.wrap($0).count <= lines }, "overflow \(lines)x\(width): \(answer)")
                #expect(plan.windows.first?.hasPrefix(String(answer.split(separator: " ").first!)) == true)
                #expect(plan.sections.first?.words.lowerBound == 0)
                #expect(plan.sections.last?.words.upperBound == plan.words.count)
                for (a, b) in zip(plan.sections, plan.sections.dropFirst()) { #expect(a.words.upperBound == b.words.lowerBound) }
            }
        }
    }

    @Test func answerLongerThanFiveLinesIsSplitAndStartsAtTheFirstWord() {
        let answer = CaptionCalibration.sampleAnswer
        let plan = ReadingPlan(answer: answer, layout: .standard)
        #expect(CaptionLayout.standard.wrap(answer).count > 5)
        #expect(plan.windows.count > 1)
        #expect(plan.windows[0].hasPrefix("I'd start by checking"))
        #expect(plan.windows.allSatisfy { CaptionLayout.standard.wrap($0).count <= 4 })
    }

    @Test func longSentenceWithoutPunctuationSpansWindows() {
        let sentence = Array(repeating: "check the authentication logs and the integration settings", count: 8).joined(separator: " ")
        let plan = ReadingPlan(answer: sentence, layout: CaptionLayout(maxLines: 4, charactersPerLine: 26))
        #expect(plan.windows.count >= 4)
        #expect(plan.sections.map(\.text).joined(separator: " ") == sentence)
    }

    @Test func prefersSentenceBoundariesOnlyWhenTheFrameStaysFull() {
        // Cut at the sentence end when it keeps at least 60% of the frame…
        let full = ReadingPlan(answer: "I'd check the API logs and the token first. Then I'd verify the scopes and replay a request.",
                               layout: CaptionLayout(maxLines: 3, charactersPerLine: 26))
        #expect(full.sections[0].text == "I'd check the API logs and the token first.")
        // …but never leave a one-line frame when more text fits.
        let sparse = ReadingPlan(answer: "I'd check the logs first. Then I'd verify the token and the scopes before replaying.",
                                 layout: CaptionLayout(maxLines: 2, charactersPerLine: 26))
        #expect(sparse.sections[0].text == "I'd check the logs first. Then I'd verify the token")
    }

    @Test func longSentencesSplitAtClauseBoundaries() {
        let answer = "If the token expired, I'd refresh it in Entra ID, replay the failed requests one by one, and then watch the logs for new authentication errors before closing the ticket."
        let plan = ReadingPlan(answer: answer, layout: CaptionLayout(maxLines: 3, charactersPerLine: 30))
        #expect(plan.sections.count >= 2)
        #expect(plan.sections[0].text.hasSuffix(","))
        #expect(plan.sections.map(\.text).joined(separator: " ") == answer)
    }

    @Test func shortAnswerFitsInOneFrameAndFramesUseThreeToFourLines() {
        #expect(ReadingPlan(answer: "HTTP 401 means the request has not been authenticated.", layout: .standard).sections.count == 1)
        let plan = ReadingPlan(answer: Canon.longAnswer, layout: .standard)
        for section in plan.sections.dropLast() {
            #expect(CaptionLayout.standard.wrap(section.text).count >= 3, "\(section.text)")
        }
    }

    @Test func veryLongTechnicalTermIsSplitOnlyWhenItCannotFit() {
        let term = "Microsoft.Graph.Authentication.ConditionalAccessPolicyEvaluationService.Diagnostics.Verbose.Tracing.Enabled.Flag"
        let layout = CaptionLayout(maxLines: 2, charactersPerLine: 20) // capacity 40 characters
        let plan = ReadingPlan(answer: "I'd enable \(term) then retry", layout: layout)
        let pieces = plan.sections.flatMap { $0.text.split(separator: " ").map(String.init) }
        #expect(pieces.joined().contains(term)) // all characters present, in order
        #expect(plan.words == ReadingText.tokens("I'd enable \(term) then retry")) // counted once for alignment
        #expect(plan.windows.allSatisfy { layout.wrap($0).count <= 2 })
        // A normal long word that fits on a line is never split.
        let normal = ReadingPlan(answer: "troubleshooting authentication", layout: CaptionLayout(maxLines: 2, charactersPerLine: 16))
        #expect(normal.sections.flatMap { $0.text.split(separator: " ") }.map(String.init) == ["troubleshooting", "authentication"])
    }

    @Test func contextLineUsesOneLineAndNeverCostsAWindowItsWords() {
        let layout = CaptionLayout(maxLines: 4, charactersPerLine: 26, contextLine: true, pageCounter: false)
        let plan = ReadingPlan(answer: CaptionCalibration.sampleAnswer, layout: layout)
        #expect(!plan.windows[0].hasPrefix("\u{2026}"))
        for index in 1..<plan.windows.count {
            #expect(plan.windows[index].hasPrefix("\u{2026} "))
            #expect(layout.wrap(plan.windows[index]).count <= 4)
            let previousLast = plan.sections[index - 1].text.split(separator: " ").last!
            #expect(plan.windows[index].contains(previousLast))
            #expect(plan.windows[index].hasSuffix(plan.sections[index].text))
        }
    }

    @Test func pageCounterOnlyWhenItFits() {
        let single = ReadingPlan(answer: "Short answer.", layout: .standard)
        #expect(single.windows == ["Short answer."])
        let tight = CaptionLayout(maxLines: 1, charactersPerLine: 12)
        let plan = ReadingPlan(answer: "aaaaaaaaaaaa bbbbbbbbbbbb", layout: tight)
        #expect(plan.windows == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"]) // no room for " (1/2)"
        let roomy = ReadingPlan(answer: CaptionCalibration.sampleAnswer, layout: .standard)
        #expect(roomy.windows.contains { $0.hasSuffix("/\(roomy.windows.count))") })
    }

    @Test func calibrationPatternsMatchTheConfiguredWidth() {
        let layout = CaptionLayout(maxLines: 4, charactersPerLine: 26)
        let rows = layout.wrap(CaptionCalibration.numberedLines(layout))
        #expect(rows.count == 6)
        #expect(rows.enumerated().allSatisfy { $0.element.hasPrefix("LINE \($0.offset + 1) ") })
        #expect(CaptionCalibration.ruler.hasPrefix("0005 0010 0015"))
    }

    @Test func savedSettingsWithoutLayoutOrWithPartialLayoutDecode() throws {
        let old = #"{"glassesTarget":"rayNeoExperimental","glassesPageCharacters":160}"#
        let settings = try #require(AppSettings.decodeMerged(Data(old.utf8)))
        #expect(settings.captionLayout == .standard)
        #expect(settings.glassesTarget == .rayNeoExperimental)
        let partial = try JSONDecoder().decode(CaptionLayout.self, from: Data(#"{"charactersPerLine":30}"#.utf8))
        #expect(partial.charactersPerLine == 30 && partial.maxLines == 4)
    }
}

/// Speech-synced reading across line-aware window boundaries.
@Suite struct LineAwareReadingTests {
    @Test func readingAcrossMidSentenceBoundariesVisitsEveryWindowInOrder() {
        let answer = "I'd start by checking whether the account is active and whether the user has the right license assigned in the admin center. Then I'd look at the Microsoft Entra ID sign-in logs to see if it's a password issue, an MFA problem, or a conditional access policy blocking them."
        let plan = ReadingPlan(answer: answer, layout: CaptionLayout(maxLines: 3, charactersPerLine: 22))
        #expect(plan.sections.count >= 4)
        var alignment = ReadingAlignment(plan: plan)
        var displayed = 0
        var transitions: [Int] = []
        var time = Date(timeIntervalSince1970: 0)
        for sentence in answer.split(separator: ".").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let words = sentence.split(separator: " ")
            for count in 1...words.count {
                time += 0.3
                _ = alignment.ingest(words.prefix(count).joined(separator: " "), isFinal: false, speaker: .unknown, at: time)
                let target = alignment.suggestedSection(displayed: displayed, utteranceEnded: false)
                if target > displayed {
                    // Never before the visible window's last meaningful word was reached.
                    #expect(alignment.cursor >= plan.sections[displayed].endTrigger)
                    transitions.append(target); displayed = target
                }
            }
            time += 1
            let update = alignment.ingest(sentence, isFinal: true, speaker: .unknown, at: time)
            let target = alignment.suggestedSection(displayed: displayed, utteranceEnded: update.heardBeyondMatch)
            if target > displayed { transitions.append(target); displayed = target }
        }
        #expect(transitions == Array(1..<plan.sections.count))
    }
}

@Suite struct AnswerStyleTests {
    @Test func instructionsCarryTheConversationalPersonaAndPlainTextRules() {
        let text = InterviewPromptBuilder.instructions(length: .standard, portfolio: "")
        for phrase in ["first person", "contractions", "Start directly with the answer", "corporate buzzwords",
                       "what you'd check first", "DJ, the technical interviewer", "3-5 short spoken sentences",
                       "no Markdown", "Microsoft Entra ID", "Do not invent professional experience", "Style example only"] {
            #expect(text.contains(phrase), "missing: \(phrase)")
        }
        #expect(InterviewPromptBuilder.instructions(length: .short, portfolio: "").contains("2-3 short spoken sentences"))
        #expect(InterviewPromptBuilder.instructions(length: .detailed, portfolio: "Built a Next.js app").contains("Built a Next.js app"))
        let prompt = InterviewPromptBuilder.prompt(question: "How do you troubleshoot MFA?", followUpTo: nil, notes: ["MFA: check sign-in logs"])
        #expect(prompt.hasSuffix("Interviewer: How do you troubleshoot MFA?\nYour spoken answer:"))
    }

    @Test func formatterRemovesMarkdownButKeepsTechnicalTerms() {
        let raw = """
        ## Approach
        **First**, I'd check the REST API logs.
        - Then I'd look at Microsoft Entra ID sign-ins for MFA failures.
        2. I'd test the SQL query, the C# service and the Node.js worker on .NET 8.
        * Async/await keeps it readable.
        """
        let cleaned = AnswerFormatter.spoken(raw)
        #expect(cleaned == "Approach First, I'd check the REST API logs. Then I'd look at Microsoft Entra ID sign-ins for MFA failures. I'd test the SQL query, the C# service and the Node.js worker on .NET 8. Async/await keeps it readable.")
        #expect(AnswerFormatter.spoken("I'd check the logs.  Then   retry.") == "I'd check the logs. Then retry.")
    }

    @MainActor @Test func engineDisplaysTheCleanedAnswer() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        let ai = MockAIProvider()
        ai.answer = "**I'd** check the API logs first.\n- Then I'd verify the token."
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        await engine.handle(CompletedTurn(text: "How would you debug a failing API?", start: 0, end: 2))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.text == "I'd check the API logs first. Then I'd verify the token.")
        #expect(glasses.shown == ["I'd check the API logs first. Then I'd verify the token. \u{2713}"])
    }
}
