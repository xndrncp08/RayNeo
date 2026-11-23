import Foundation

enum QuestionCategory: String, Codable, CaseIterable, Sendable {
    case math, factual, technical, coding, ambiguous
}

struct RoutedQuestion: Equatable, Sendable {
    var category: QuestionCategory
    /// Complete answer when no model is needed (math, clarification).
    var directAnswer: String?
    var reason: String
}

/// Deterministic routing before any model call. Math never reaches an LLM.
nonisolated enum QuestionRouter {
    private static let codingCues = ["write a function", "write code", "write a query", "implement", "code snippet", "snippet",
                                     "show me the code", "the code for", "code for that", "see the code", "write that out",
                                     "find the bug", "fix this", "this function", "refactor", "algorithm", "regex",
                                     "regular expression", "time complexity", "big o", "syntax", "in javascript", "in typescript",
                                     "in python", "in swift", "in sql", "write a sql query", "query to", "remove duplicates", "reverse a", "dependency array",
                                     "useeffect", "usestate", "usememo", "usecallback", "=>", "()", "console.log"]
    private static let technicalCues = ["how would you", "how do you", "how did you", "walk me through", "describe", "tell me about",
                                        "troubleshoot", "debug", "investigate", "what would you do", "how would i", "approach",
                                        "difference between", "explain how", "explain why", "handle", "design", "set up", "secure",
                                        "why would", "when would you", "what steps"]
    private static let factualStarts = ["what is", "what's", "what are", "what does", "what do", "define", "what port",
                                        "what status", "which", "who", "when was", "is it true", "meaning of", "what's the purpose",
                                        "what is the purpose"]
    /// Words that carry no subject on their own.
    private static let vague: Set<String> = ["explain", "work", "works", "mean", "means", "thing", "stuff", "something", "about",
                                             "again", "more", "detail", "elaborate", "please", "sorry", "repeat", "say", "go", "on"]

    static func route(_ question: String, hasPreviousAnswer: Bool = false) -> RoutedQuestion {
        let lower = " " + question.lowercased() + " "
        if let calculation = Calculator.evaluate(question) {
            switch calculation {
            case .success(let result): return RoutedQuestion(category: .math, directAnswer: result.answer, reason: "deterministic calculation")
            case .failure(let failure): return RoutedQuestion(category: .math, directAnswer: Calculator.explanation(failure), reason: "calculation could not be completed safely")
            }
        }
        let subject = TextSimilarity.contentWords(question).filter { !vague.contains($0) }
        if subject.isEmpty, !hasPreviousAnswer {
            return RoutedQuestion(category: .ambiguous,
                                  directAnswer: "I'm not sure what that's referring to. Could you give me a bit more detail on which part you mean?",
                                  reason: "no subject to answer about")
        }
        // "Write a JavaScript function…" breaks the literal "write a function" cue: programming instructions count too.
        if codingCues.contains(where: { lower.contains($0) }) || CodingLanguage.isNewTask(question)
            || question.range(of: #"\buse[A-Z]\w+|\w+\([^)]*\)"#, options: .regularExpression) != nil {
            return RoutedQuestion(category: .coding, reason: "coding cue")
        }
        if technicalCues.contains(where: { lower.contains($0) }) {
            return RoutedQuestion(category: .technical, reason: "interview/troubleshooting cue")
        }
        if factualStarts.contains(where: { lower.hasPrefix(" " + $0 + " ") }) {
            return RoutedQuestion(category: .factual, reason: "direct factual question")
        }
        return RoutedQuestion(category: .technical, reason: "default")
    }
}

/// Category-specific checks on model output. Math is never validated against a model: the calculator is authoritative.
nonisolated enum AnswerValidator {
    struct Verdict: Equatable, Sendable {
        var passed: Bool
        var reason: String
        /// Fall back to the honest "not sure" answer instead of showing the draft.
        var useFallback = false
    }

    private static let nonAnswer = [
        #"\bdouble[- ]?check\b"#, #"\blook (it|this|that) up\b"#, #"\bgoogle\b"#, #"\bsearch (online|for it|the web)\b"#,
        #"\buse a calculator\b"#, #"\bspreadsheet\b"#, #"\bask (for help|someone|a colleague|my team)\b"#, #"\breview my notes\b"#,
        #"\bmy math skills\b"#, #"\bas an ai\b"#, #"\bi (don't|do not) know\b"#, #"\bi would need more information\b"#,
    ]
    private static let fakeExperience = [
        #"\bin my (last|previous|current|old) (role|job|position|company)\b"#, #"\bat my (last|previous|current) (job|company|role)\b"#,
        #"\bwhen i worked (at|for)\b"#, #"\bi'?ve worked (at|for)\b"#, #"\byears of experience\b"#, #"\bat my company\b"#,
    ]
    /// A coding request answered as if it were about past work ("I haven't written that…").
    private static let codeRefusal = [
        #"\bi (haven't|have not|never) (written|implemented|built|coded|done|worked on) (that|this|it)\b"#,
        #"\b(don't|do not) have (an?|any) (code )?example\b"#, #"\bin my (past|previous) work\b"#,
        #"\bi can (talk|walk) (you )?through the logic\b"#, #"\binstead of (writing|showing) (the )?code\b"#,
    ]
    private static let fakeTesting = [#"\bi (tested|ran|executed) (it|this|the code|that)\b"#, #"\b(has|have) been tested\b"#,
                                      #"\bverified that it works\b"#, #"\bi('ve| have) tested\b"#]

    /// `requireRelevance: false` is used for the first sentences of a streaming answer only: an opening sentence
    /// often does not repeat the question's nouns; the final answer is always checked with relevance.
    static func validate(_ answer: String, question: String, category: QuestionCategory, hasPortfolio: Bool,
                         requireRelevance: Bool = true) -> Verdict {
        let lower = answer.lowercased()
        func hits(_ patterns: [String]) -> Int { patterns.filter { lower.range(of: $0, options: .regularExpression) != nil }.count }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Verdict(passed: false, reason: "empty answer", useFallback: true) }
        let keyTerms = Set(TextSimilarity.contentWords(question))
        let relevant = !requireRelevance || keyTerms.isEmpty || !keyTerms.isDisjoint(with: Set(TextSimilarity.contentWords(answer)))
        let hedges = hits(nonAnswer)
        if hedges >= 2 || (hedges >= 1 && !relevant) {
            return Verdict(passed: false, reason: "describes how to find an answer instead of answering", useFallback: true)
        }
        if !hasPortfolio, hits(fakeExperience) > 0 {
            return Verdict(passed: false, reason: "claims professional experience that was not provided", useFallback: true)
        }
        if category == .coding, hits(codeRefusal) > 0 {
            return Verdict(passed: false, reason: "refused to write the requested code as if it were a question about past work; write the code", useFallback: false)
        }
        if category == .coding, hits(fakeTesting) > 0 {
            return Verdict(passed: false, reason: "claims the code was run or tested", useFallback: false)
        }
        if !relevant { return Verdict(passed: false, reason: "does not mention the question's subject", useFallback: false) }
        return Verdict(passed: true, reason: "ok")
    }

    /// Sentences that only talk about researching, double-checking or confirming the answer itself.
    /// They add no information to a factual answer. Troubleshooting steps ("check the API logs") do not match.
    private static let metaFiller = [
        #"\b(check|consult|refer to|look at|read|review|search|google)\b[^.]{0,40}\b(documentation|docs|official (site|website|docs)|website|sources?|online|internet)\b[^.]{0,40}\b(to )?(confirm|verify|make sure|double[- ]?check|learn more|be sure|for (more )?details)"#,
        #"\b(to|and) (confirm|verify|double[- ]?check) (the|my|this|that) answer\b"#,
        #"\blook (it|this|that) up\b"#, #"\bresearch (this|it|that)( (topic|further|more))?\b"#, #"\bresearch further\b"#,
        #"\buse a calculator\b"#, #"\bdouble[- ]?check (my|the) (math|answer|work)\b"#,
        #"\bask (someone|a colleague|for help|an expert)\b"#, #"\bi('m| am) not (completely |entirely )?sure,? but\b"#,
    ]

    /// Removes trailing or standalone filler sentences. Factual/coding answers lose any matching sentence;
    /// technical answers only lose sentences about confirming the answer itself, never real steps.
    /// Returns nil when nothing informative would be left (the caller then regenerates).
    static func removeFiller(_ answer: String, category: QuestionCategory) -> (text: String, removed: Int)? {
        var sentences: [String] = []
        answer.enumerateSubstrings(in: answer.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { sentences.append(sentence) }
        }
        let patterns = category == .technical ? Array(metaFiller.dropFirst()) : metaFiller
        let kept = sentences.filter { sentence in
            let lower = sentence.lowercased()
            let isFiller = patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
            // In technical answers a sentence that also names a concrete thing to check stays.
            return !isFiller || (category == .technical && lower.range(of: #"\b(logs?|settings?|configuration|policy|token|endpoint|server)\b"#, options: .regularExpression) != nil)
        }
        guard !kept.isEmpty else { return nil }
        return (kept.joined(separator: " "), sentences.count - kept.count)
    }

    static let honestFallback = "I'm not certain about that one, so I'd rather not guess. Could you rephrase it or give me a bit more context?"
}
