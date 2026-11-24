import Foundation

/// What the finalized question obliges the answer to do: its main task, the explicit requirements and parts
/// (from `InterviewIntent`), and whether personal memory may appear. Built once per answer, rendered into the
/// prompt, and checked before an answer is displayed. Checks are deterministic: a requirement counts only where
/// a clause of the answer actually says something about it, not where a keyword merely appears in a list.
/// Heuristic, not semantic understanding: it catches omissions and off-task answers, not wrong reasoning.
nonisolated struct AnswerContract: Equatable, Sendable {
    var intent: InterviewIntent
    /// "secure a next.js application", "investigate the incident" (nil when no clear task could be found).
    var task: String?
    var personalAllowed: Bool
    var projects: [String]

    init(question: String, intent: InterviewIntent, personalAllowed: Bool = true, projects: [String] = []) {
        self.intent = intent
        self.task = Self.mainTask(of: question)
        self.personalAllowed = personalAllowed
        self.projects = projects
    }

    /// One line for the prompt, so the model answers the actual task first.
    var promptLine: String? {
        task.map { "Main task: \($0). Answer it directly before anything else." }
    }

    /// Everything the answer fails to do; empty when the contract is met.
    func violations(in answer: String) -> [String] {
        var problems = intent.missingRequirements(in: answer)
        let coverage = Coverage(answer)
        if let task, !coverage.addresses(task) { problems.append("the main task (\(task)) is not addressed") }
        if intent.parts.count >= 2 {
            for part in intent.parts where !coverage.addresses(Self.strippedRequest(part)) { problems.append("the part \"\(part)\"") }
        }
        if !personalAllowed, let anecdote = PersonalContextPolicy.anecdotes(in: answer, projects: projects).first {
            problems.append("a personal project or past experience the question didn't ask about (\"\(anecdote.prefix(60))\")")
        }
        return problems
    }

    /// Text that may be shown while the answer is still streaming: never an unsolicited personal anecdote.
    func allowsEarlyText(_ text: String) -> Bool {
        personalAllowed || PersonalContextPolicy.anecdotes(in: text, projects: projects).isEmpty
    }

    // MARK: Task extraction

    /// The request's verb phrase without its framing: "How would you investigate the incident across…" →
    /// "investigate the incident"; "Explain how you'd secure a Next.js app using…" → "secure a next.js app".
    static func mainTask(of question: String) -> String? {
        let sentences = InterviewIntent.sentences(question)
        // A scenario or statement with no request yet ("The college has three incidents.") has no task to enforce.
        guard let request = sentences.first(where: { InterviewIntent.classify($0).actionable && !InterviewIntent.classify($0).awaitingTask }) else { return nil }
        let task = strippedRequest(request)
        let words = task.split(separator: " ")
        guard (2...12).contains(words.count) else { return words.count > 12 ? words.prefix(8).joined(separator: " ") : nil }
        return task
    }

    static func strippedRequest(_ text: String) -> String {
        var core = InterviewIntent.stripLeadIns(text.lowercased())
        let framing = [
            #"^(can|could|would) you (please )?"#, #"^(i'?d like you to|i want you to|go ahead and|let'?s have you) "#,
            #"^(explain|describe|tell me|walk me through|talk me through|take me through|show me|outline|discuss)( to me)?( how| why| what)?( you'?d| you would| you| to| we'?d| we would| i'?d| i would)? "#,
            #"^how (would|do|should|did|can|could) (you|we|i) "#, #"^what (would|do|should) (you|we) do to "#,
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in framing {
                if let range = core.range(of: pattern, options: .regularExpression) { core.removeSubrange(range); changed = true }
            }
        }
        if let cut = core.range(of: #"(,|;|\?|\.(\s|$)| especially | particularly | using | across | when | while | without | so that | and (then )?(how|what|why) | for (students|users|each) )"#,
                                options: .regularExpression) {
            core = String(core[..<cut.lowerBound])
        }
        return core.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    // MARK: Coverage

    /// Clauses of an answer that say something (four words or more), with their word stems.
    struct Coverage {
        let clauses: [String]
        let stems: [Set<String>]

        init(_ answer: String) {
            clauses = answer.lowercased().components(separatedBy: CharacterSet(charactersIn: ".;!?,:"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.split(separator: " ").count >= 4 }
            stems = clauses.map { Set(TextSimilarity.contentWords($0).map { InterviewIntent.stem($0) }) }
        }

        func says(_ stem: String, or phrases: [String] = []) -> Bool {
            clauses.indices.contains { stems[$0].contains(stem) || phrases.contains(where: clauses[$0].contains) }
        }

        /// A task or part is addressed when its action is carried out (the verb or what doing it involves) or
        /// what it acts on is discussed.
        func addresses(_ request: String) -> Bool {
            let words = TextSimilarity.contentWords(request).map { $0.lowercased() }
            guard let first = words.first else { return true }
            let action = AnswerContract.actions[InterviewIntent.stem(first)]
            let generic: Set<String> = ["work", "use", "make", "thing", "way", "them", "these", "those", "handle", "deal", "approach", "explain"]
            let objects = (action == nil ? words : Array(words.dropFirst())).filter { !generic.contains($0) }.map { InterviewIntent.stem($0) }
            if objects.isEmpty && action == nil { return true }
            if let action, says(InterviewIntent.stem(first), or: action) { return true }
            return objects.contains { says($0, or: InterviewIntent.synonyms[$0] ?? []) }
        }
    }

    /// Request verbs and what doing them looks like in a spoken answer.
    static let actions: [String: [String]] = [
        "inves": ["check", "look at", "logs", "trace", "reproduce", "narrow", "find the cause", "root cause"],
        "debug": ["check", "logs", "reproduce", "breakpoint", "trace", "narrow"],
        "troub": ["check", "logs", "reproduce", "narrow", "isolate"],
        "diagn": ["check", "logs", "metrics", "cause", "narrow"],
        "prior": ["first", "before", "most urgent", "urgent", "critical", "impact", "next", "then"],
        "commu": ["update", "inform", "tell", "let them know", "notify", "message", "keep", "explain to"],
        "secur": ["auth", "polic", "permission", "access", "encrypt", "least privilege", "role"],
        "desig": ["component", "service", "queue", "database", "store", "flow", "api"],
        "build": ["component", "function", "service", "api", "store"],
        "imple": ["function", "code", "loop", "return", "use"],
        "write": ["function", "code", "return", "query", "select"],
        "test": ["test", "verify", "confirm", "assert", "check that"],
        "fix": ["change", "update", "patch", "roll back", "revert", "deploy", "fix"],
        "resol": ["fix", "change", "restore", "roll back", "revert"],
        "resto": ["restore", "unlock", "reset", "grant", "re-enable", "access"],
        "compa": ["whereas", "while", "better", "instead", "unlike", "both", "difference"],
        "scale": ["scale", "replica", "shard", "cache", "load", "horizontal"],
        "monit": ["metric", "alert", "dashboard", "log", "monitor"],
        "migra": ["migrat", "move", "copy", "cut over", "backfill"],
        "decid": ["decide", "if ", "unless", "criteria", "would roll", "would revert"],
        "optim": ["index", "cache", "faster", "reduce", "profile"],
        "preve": ["prevent", "avoid", "guard", "validate", "alert"],
        "handl": ["retry", "catch", "fallback", "handle"],
    ]
}
