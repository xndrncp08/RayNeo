import Foundation

/// Route → (calculate | clarify | generate → validate → at most one regeneration). Shared by the live
/// conversation engine and the on-device evaluation runner, so both measure the same code.
@MainActor final class AnswerPipeline {
    struct Output: Equatable, Sendable {
        var text: String
        var category: QuestionCategory
        var routeReason: String
        var routeMilliseconds: Double
        var firstTokenSeconds: Double?
        var generationSeconds: Double?
        var validation: String
        var regenerated: Bool
        var usedModel: Bool
        var firstSentenceSeconds: Double? = nil
        var provider: String = ""
        var answerID = 0
        /// "complete" only when the stream ended normally, the text ends a sentence and validation passed.
        var completion = "complete"
        var generationComplete: Bool { completion == "complete" }
        /// Code example for the iPhone and a timed glasses overlay (coding questions that ask for code).
        var snippet: CodeSnippet?
        /// The same answer as an ordered EXPLAIN → CODE → … walkthrough (one model request).
        var walkthrough: CodingWalkthrough?
    }

    var provider: any AIResponseProvider
    var instructions: (QuestionCategory) -> String
    var notes: (String) -> [String]
    var answerLength: AnswerLength
    var hasPortfolio: Bool
    var now: () -> Date = Date.init
    /// Receives streamed partial text and the category (the engine may show a stable first frame early).
    var onPartial: (String, QuestionCategory) -> Void = { _, _ in }
    var log: (String) -> Void = { _ in }
    /// The answer's identity (from `AnswerIdentity`), stamped on the output and on every log line.
    var answerID = 0
    /// Rejects first-person project claims that personal memory does not support (reason, or nil).
    var groundingCheck: (String) -> String? = { _ in nil }
    /// Resolves a follow-up against the active programming task ("show me the code for that").
    var codingResolver: (String) -> ResolvedCodingRequest? = { _ in nil }
    /// Language of the current coding answer (named or inherited), and the walkthrough of the last draft.
    private var language = "JavaScript"
    private var requiredLanguage: String?
    private var lastWalkthrough: CodingWalkthrough?
    /// Coding Skeleton Mode: ask for (or derive) a skeleton block first.
    var codingSkeleton = false
    /// Receives the skeleton of the first draft as soon as its block is complete and validated.
    var onSkeleton: (String) -> Void = { _ in }
    private var skeletonReported = false
    private var firstSentenceAt: Double?

    init(provider: any AIResponseProvider, instructions: @escaping (QuestionCategory) -> String, notes: @escaping (String) -> [String],
         answerLength: AnswerLength, hasPortfolio: Bool, now: @escaping () -> Date = Date.init,
         onPartial: @escaping (String, QuestionCategory) -> Void = { _, _ in }, log: @escaping (String) -> Void = { _ in }) {
        self.provider = provider
        self.instructions = instructions
        self.notes = notes
        self.answerLength = answerLength
        self.hasPortfolio = hasPortfolio
        self.now = now
        self.onPartial = onPartial
        self.log = log
    }

    func answer(_ question: String, previous: (question: String, answer: String)?) async throws -> Output {
        var output = try await produce(question, previous: previous)
        output.answerID = answerID
        if output.usedModel {
            let stop = provider.lastStopReason
            output.completion = !output.validation.hasPrefix("passed") ? "validation \(output.validation)"
                : stop == "MAX_TOKENS" ? "truncated (MAX_TOKENS)"
                : stop.map { $0 != "STOP" } == true ? "stopped (\(stop!))"
                : !AnswerFormatter.endsCleanly(output.text) ? "ends mid-sentence"
                : "complete"
        }
        log(String(format: "Answer #%d: generation finished (%@), validation %@, %.2fs", answerID, output.completion,
                   output.validation, output.generationSeconds ?? 0))
        return output
    }

    private func produce(_ question: String, previous: (question: String, answer: String)?) async throws -> Output {
        let routeStart = now()
        var route = QuestionRouter.route(question, hasPreviousAnswer: previous != nil)
        // A follow-up about the active programming task is a coding request, whatever its wording.
        let coding = route.category == .math ? nil : codingResolver(question)
        if let coding {
            route = RoutedQuestion(category: .coding, reason: "coding follow-up: \(coding.kind.label), \(coding.language)")
            log("Answer #\(answerID): contextual coding follow-up resolved (\(coding.kind.rawValue), \(coding.language))")
        } else if previous == nil, Self.isUnanchoredCodeRequest(question) {
            return Output(text: "Sure, which function or task would you like me to write the code for?", category: .ambiguous,
                          routeReason: "code requested for an unknown task", routeMilliseconds: 0, firstTokenSeconds: nil,
                          generationSeconds: nil, validation: "deterministic", regenerated: false, usedModel: false)
        }
        let routeMilliseconds = now().timeIntervalSince(routeStart) * 1000
        log(String(format: "Answer #%d routed as %@ (%@) in %.1f ms", answerID, route.category.rawValue, route.reason, routeMilliseconds))
        if let direct = route.directAnswer {
            return Output(text: direct, category: route.category, routeReason: route.reason, routeMilliseconds: routeMilliseconds,
                          firstTokenSeconds: nil, generationSeconds: nil, validation: "deterministic", regenerated: false, usedModel: false)
        }

        let started = now()
        var firstToken: Double?
        var firstSentence: Double?
        let wantsCode = coding.map(\.kind.wantsCode) ?? (route.category == .coding && CodeSnippet.wanted(for: question))
        // The task's language is kept unless the question names another one; never drift to a wrapper language.
        let requiredLanguage = coding?.language ?? CodingLanguage.named(in: question)
        language = requiredLanguage ?? CodingLanguage.guess(question)
        self.requiredLanguage = requiredLanguage
        let context = coding?.prompt
        // Relevance of a follow-up is judged against the task it continues.
        let subject = coding.map { question + " " + $0.instruction } ?? question
        var (text, snippet) = try await draft(question, category: route.category, previous: previous, correction: nil, wantsCode: wantsCode,
                                              context: context, started: started, firstToken: &firstToken)
        var walkthrough = lastWalkthrough
        text = trimFiller(text, category: route.category) ?? text
        if route.category != .coding { text = NaturalAnswerStyle.polish(text) }
        var verdict = validate(text, snippet: snippet, wantsCode: wantsCode, question: subject, category: route.category)
        var regenerated = false
        if !verdict.passed {
            log("Answer #\(answerID): validation failed (\(verdict.reason)); regenerating once")
            regenerated = true
            var (second, secondSnippet) = try await draft(question, category: route.category, previous: previous, correction: verdict.reason,
                                                          wantsCode: wantsCode, context: context, started: started, firstToken: &firstToken)
            second = trimFiller(second, category: route.category) ?? second
            if route.category != .coding { second = NaturalAnswerStyle.polish(second) }
            let secondVerdict = validate(second, snippet: secondSnippet, wantsCode: wantsCode, question: subject, category: route.category)
            snippet = secondSnippet
            walkthrough = lastWalkthrough
            if secondVerdict.passed {
                text = second
                verdict = secondVerdict
            } else {
                log("Second draft also failed (\(secondVerdict.reason))\(secondVerdict.useFallback ? "; using the honest fallback" : "; keeping it")")
                text = secondVerdict.useFallback ? AnswerValidator.honestFallback : second
                if secondVerdict.useFallback { snippet = nil; walkthrough = nil }
                // A walkthrough that is still incoherent is not shown step by step; the code stays on the iPhone.
                if walkthrough?.problem(requiredLanguage: requiredLanguage) != nil { walkthrough = nil }
                verdict = secondVerdict
            }
        }
        firstSentence = firstSentenceAt
        return Output(text: text, category: route.category, routeReason: route.reason, routeMilliseconds: routeMilliseconds,
                      firstTokenSeconds: firstToken, generationSeconds: now().timeIntervalSince(started),
                      validation: verdict.passed ? "passed" : "failed: \(verdict.reason)", regenerated: regenerated, usedModel: true,
                      firstSentenceSeconds: firstSentence, provider: (provider as? CloudFailoverProvider)?.lastUsed ?? provider.name,
                      snippet: snippet, walkthrough: walkthrough)
    }

    /// The category checks, the requested code being present, and the personal-memory grounding check.
    private func validate(_ text: String, snippet: CodeSnippet?, wantsCode: Bool, question: String,
                          category: QuestionCategory) -> AnswerValidator.Verdict {
        let verdict = AnswerValidator.validate(text, question: question, category: category, hasPortfolio: hasPortfolio)
        guard verdict.passed else { return verdict }
        if wantsCode {
            guard let snippet else { return AnswerValidator.Verdict(passed: false, reason: "did not include the requested code in CODE blocks") }
            if let walkthrough = lastWalkthrough {
                if let problem = walkthrough.problem(requiredLanguage: requiredLanguage) { return AnswerValidator.Verdict(passed: false, reason: problem) }
            } else {
                if let requiredLanguage, let mismatch = CodeLanguageDetector.mismatch(snippet.code, required: requiredLanguage) {
                    return AnswerValidator.Verdict(passed: false, reason: mismatch)
                }
                return AnswerValidator.Verdict(passed: false, reason: "did not use the EXPLAIN / CODE walkthrough blocks")
            }
        }
        if let unsupported = groundingCheck(text) { return AnswerValidator.Verdict(passed: false, reason: unsupported) }
        if category == .technical, let repetition = NaturalAnswerStyle.repetitiveOpening(text) {
            return AnswerValidator.Verdict(passed: false, reason: repetition)
        }
        return verdict
    }

    /// "Show me the code for that" with nothing to refer to: ask instead of inventing a task.
    static func isUnanchoredCodeRequest(_ question: String) -> Bool {
        let lower = " " + question.lowercased() + " "
        let cues = ["show me the code", "the code for that", "write that", "implement that", "implement it", "code that", "see the code"]
        return cues.contains { lower.contains($0) } && !CodingLanguage.isNewTask(question)
    }

    /// Strips filler sentences; a draft that is only filler becomes empty so validation regenerates it.
    private func trimFiller(_ text: String, category: QuestionCategory) -> String? {
        guard let result = AnswerValidator.removeFiller(text, category: category) else {
            log("Draft was only filler")
            return ""
        }
        if result.removed > 0 { log("Removed \(result.removed) filler sentence(s) from a \(category.rawValue) answer") }
        return result.text
    }

    private func draft(_ question: String, category: QuestionCategory, previous: (question: String, answer: String)?,
                       correction: String?, wantsCode: Bool, context: String? = nil, started: Date,
                       firstToken: inout Double?) async throws -> (String, CodeSnippet?) {
        if case .unavailable(let reason) = provider.status { throw AIError.unavailable(reason) }
        var instructionText = instructions(category)
        if let correction {
            instructionText += "\nA previous draft was rejected because it \(correction). Answer the question itself, directly."
        }
        if wantsCode { instructionText += "\n" + CodingWalkthrough.formatInstruction(language: language, skeleton: codingSkeleton) }
        let maximumTokens = switch category {
        case .factual: 110
        case .coding: wantsCode ? 520 : 220
        default: answerLength.maximumTokens
        }
        let request = AnswerRequest(instructions: instructionText,
                                    prompt: InterviewPromptBuilder.prompt(question: question, followUpTo: previous,
                                                                          notes: (context.map { [$0] } ?? []) + notes(question)),
                                    maximumTokens: maximumTokens)
        var text = ""
        log("Answer #\(answerID): provider \(provider.name)\(correction == nil ? "" : " (regeneration)")")
        for try await partial in provider.streamAnswer(request) {
            try Task.checkCancellation()
            if firstToken == nil {
                firstToken = now().timeIntervalSince(started)
                log(String(format: "Answer #%d: first token after %.2fs", answerID, firstToken ?? 0))
            }
            text = partial
            // Code never reaches the spoken text, the early frame or the teleprompter.
            let formatted = wantsCode
                ? AnswerFormatter.spoken(CodingWalkthrough.parse(partial, language: language)?.spokenText
                    ?? partial.components(separatedBy: "CODE:").first?.replacingOccurrences(of: #"\b(EXPLAIN|RESULT):\s*"#, with: "", options: .regularExpression) ?? "")
                : AnswerFormatter.spoken(CodeSnippet.split(partial).spoken)
            if firstSentenceAt == nil, !AnswerFormatter.completeSentences(formatted + " ").isEmpty {
                firstSentenceAt = now().timeIntervalSince(started)
                log(String(format: "Answer #%d: first complete sentence after %.2fs", answerID, firstSentenceAt ?? 0))
            }
            onPartial(formatted, category)
            // Coding Skeleton Mode: the skeleton can be shown before the rest of the walkthrough arrives.
            if wantsCode, codingSkeleton, correction == nil, !skeletonReported, let skeleton = CodingWalkthrough.completedSkeleton(in: partial),
               CodeLanguageDetector.balanced(skeleton), requiredLanguage.flatMap({ CodeLanguageDetector.mismatch(skeleton, required: $0) }) == nil {
                skeletonReported = true
                onSkeleton(skeleton)
            }
        }
        try Task.checkCancellation()
        lastWalkthrough = nil
        if wantsCode, var walkthrough = CodingWalkthrough.parse(text, language: language, answerID: answerID) {
            if codingSkeleton { walkthrough = walkthrough.withSkeleton() }
            lastWalkthrough = walkthrough
            var snippet = CodeSnippet(language: language.lowercased(), code: walkthrough.finalCode ?? "")
            snippet.problem = question
            snippet.steps = walkthrough.steps.isEmpty ? walkthrough.blocks.filter { $0.kind == .explanation }.map(\.text) : walkthrough.steps
            snippet.edgeCases = walkthrough.edgeCases
            snippet.complexity = walkthrough.complexity
            snippet.tests = walkthrough.tests
            return (walkthrough.spokenText, snippet)
        }
        let parts = CodeSnippet.split(text, question: question)
        return (AnswerFormatter.spoken(parts.spoken), parts.snippet)
    }
}
