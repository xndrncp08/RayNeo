import Foundation

/// What "these incidents", "the second one", "it" or "explain the trade-offs" point back to.
nonisolated struct ContextReference: Equatable, Sendable {
    /// Explicit reference phrases found in the request ("these incidents", "them", "the second one").
    var phrases: [String] = []
    /// 1-based ordinal ("the second one" → 2), when one is used.
    var ordinal: Int?
    /// A request with no subject of its own ("Explain the trade-offs.", "Can you elaborate?").
    var implicit = false
    /// The reference is plural ("these", "them", "each of them").
    var plural = false

    var refersBack: Bool { !phrases.isEmpty || ordinal != nil || implicit }

    static func detect(_ text: String) -> ContextReference {
        let lower = " " + text.lowercased() + " "
        var reference = ContextReference()
        let explicit = [
            #"\b(these|those) (\w+ ){0,2}?(incidents?|issues?|problems?|systems?|tickets?|requests?|tasks?|scenarios?|things|ones|cases?|services?|users?|steps?|options?|approaches?|outages?|failures?|errors?|components?|requirements?|constraints?|tools?|technologies|projects?)\b"#,
            #"\b(this|that) (situation|scenario|problem|issue|incident|case|approach|system|design|one|outage|failure|error|setup|architecture|requirement|ticket)\b"#,
            #"\bthe (first|second|third|fourth|fifth|last|other|previous|earlier|same|original) (one|incident|issue|problem|system|option|approach|case|step|scenario|ticket|request|outage)\b"#,
            #"\b(what|everything|things) (we|you|i) (just )?(discussed|talked about|mentioned|said|described|covered)\b"#,
            #"\b(as|like) (i|we|you) (just )?(said|mentioned|described)\b"#,
            #"\b(each|all|both|either) of (them|those|these)\b"#, #"\b(them|they)\b"#, #"\b(these|those)\b"#,
            #"\b(handle|fix|solve|approach|prioriti[sz]e|investigate|debug|test|scale|secure) (it|that|this|them)\b"#,
            #"\bwhat if (it|that|this|they)\b"#, #"\b(would|does|will) (that|your approach|it) change\b"#,
        ]
        for pattern in explicit {
            guard let range = lower.range(of: pattern, options: .regularExpression) else { continue }
            let phrase = String(lower[range])
            if !reference.phrases.contains(where: { $0.contains(phrase) || phrase.contains($0) }) { reference.phrases.append(phrase) }
        }
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5]
        if let match = lower.range(of: #"\b(the )?(first|second|third|fourth|fifth) (one|incident|issue|problem|system|option|approach|case|scenario|ticket|request|outage)\b"#, options: .regularExpression) {
            let word = lower[match].split(separator: " ").first { ordinals[String($0)] != nil }.map(String.init)
            reference.ordinal = word.flatMap { ordinals[$0] }
        }
        reference.plural = lower.range(of: #"\b(these|those|them|they|each of|all of|both)\b"#, options: .regularExpression) != nil
        // No subject of its own: what remains after request wording and generic interview words is tiny.
        let generic: Set<String> = ["trade-off", "tradeoff", "trade", "off", "offs", "tradeoffs", "elaborate", "detail", "happen", "next", "change", "approach",
                                    "differently", "instead", "scale", "fail", "work", "mean", "example", "more", "further", "again",
                                    "go", "on", "continue", "else", "step", "pros", "cons", "risk", "downside", "alternative", "prioritize",
                                    "prioritise", "priority", "order", "first", "handle", "deal", "why", "improve", "better", "test", "through"]
        let subject = TextSimilarity.contentWords(text).filter { !SpeechEventClassifier.requestFiller.contains($0) && !generic.contains($0) }
        reference.implicit = subject.isEmpty && TextSimilarity.contentWords(text).count <= 6
        return reference
    }
}

/// The interview's ongoing scenario: what the interviewer has said since the current topic began, including
/// statements that never needed an answer themselves ("The college has three incidents…"). Deterministic and
/// bounded; no model call. Statements in the candidate's voice, answer echoes and small talk never enter it.
nonisolated struct InterviewContext: Equatable, Sendable {
    struct Statement: Equatable, Sendable {
        var turnID: Int
        var text: String
        var at: Date
        /// Scenario description rather than a request ("Our integration stopped receiving leads.").
        var setup: Bool
    }

    enum Decision: Equatable, Sendable {
        case added, revised, newTopic(String), ignored(String)
    }

    private(set) var statements: [Statement] = []
    private(set) var topicStartedAt: Date?
    private(set) var topicChanges = 0
    var maxStatements = 10
    var maxCharacters = 1400
    /// Context older than this is stale even without an explicit topic change.
    var staleAfter: TimeInterval = 600

    static let topicChangeCues = #"\b(let'?s move on|moving on|next question|(a |on to a )?(different|new|another) (topic|question|area|subject)|switching gears|change (of )?(topic|gears)|something (else|different) now|let'?s talk about something else|unrelated (question|topic)|forget (that|about that)|on a different note)\b"#

    var text: String { statements.map(\.text).joined(separator: " ") }

    /// Records one interviewer turn (a revision replaces its earlier text) and decides whether it continues the
    /// current scenario or starts a new topic.
    mutating func record(_ raw: String, turnID: Int, at now: Date) -> Decision {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = InterviewIntent.classify(text)
        guard !text.isEmpty, intent.kind != .smallTalk, intent.kind != .incomplete || text.split(separator: " ").count >= 6 else {
            return .ignored("small talk or incomplete")
        }
        guard !InterviewIntent.isFirstPerson(text) else { return .ignored("candidate's voice") }
        let setup = intent.awaitingTask || intent.kind == .statement
        if let index = statements.firstIndex(where: { $0.turnID == turnID }) {
            statements[index].text = text
            statements[index].setup = setup
            return .revised
        }
        var decision = Decision.added
        if let last = statements.last {
            let lower = text.lowercased()
            let reference = ContextReference.detect(text)
            let related = TextSimilarity.containment(subject(text), in: self.text)
            if now.timeIntervalSince(last.at) > staleAfter {
                decision = .newTopic("previous context is stale")
            } else if lower.range(of: Self.topicChangeCues, options: .regularExpression) != nil {
                decision = .newTopic("explicit topic change")
            } else if reference.refersBack || intent.kind == .followUp {
                decision = .added
            } else if setup {
                // A scenario being described sentence by sentence keeps growing; a new problem after a
                // request was answered starts a new topic unless it is clearly about the same thing.
                decision = last.setup || related >= 0.2 ? .added : .newTopic("new scenario")
            } else {
                decision = related >= 0.25 || last.setup && now.timeIntervalSince(last.at) < 90 ? .added : .newTopic("unrelated request")
            }
        }
        if case .newTopic = decision {
            statements = []
            topicChanges += 1
        }
        if statements.isEmpty { topicStartedAt = now }
        statements.append(Statement(turnID: turnID, text: text, at: now, setup: setup))
        if statements.count > maxStatements { statements.removeFirst(statements.count - maxStatements) }
        while self.text.count > maxCharacters, statements.count > 1 { statements.removeFirst() }
        return decision
    }

    mutating func clear() {
        statements = []
        topicStartedAt = nil
    }

    // MARK: Scenario details

    /// Separate problems the interviewer described ("the exam classroom has lost internet", "one staff member
    /// cannot sign into Microsoft 365", …), in the order they were mentioned.
    var incidents: [String] {
        var result: [String] = []
        for statement in statements where statement.setup || InterviewIntent.isProblem(statement.text) {
            for sentence in InterviewIntent.sentences(statement.text) {
                let clauses = sentence.replacingOccurrences(of: #",\s*(and\s+|while\s+|plus\s+)?(?=(the|a|an|one|our|another|also|some|two|three|several|users?|staff|students?)\b)|;\s*|\s+and\s+(?=(the|a|an|one|our|another|also)\b)"#,
                                                            with: "|", options: [.regularExpression, .caseInsensitive])
                    .split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;"))) }
                for clause in clauses where InterviewIntent.isProblem(clause) && clause.split(separator: " ").count >= 3 {
                    let cleaned = clause.replacingOccurrences(of: #"^(and|also|plus|then|meanwhile|at the same time)\s+"#, with: "",
                                                              options: [.regularExpression, .caseInsensitive])
                    if !result.contains(where: { TextSimilarity.jaccard($0, cleaned) >= 0.7 }) { result.append(cleaned) }
                }
            }
        }
        return Array(result.prefix(6))
    }

    /// Constraints stated for the scenario ("limited IT staff", "without losing jobs", "minimise disruption").
    var constraints: [String] {
        var result = InterviewIntent.requirements(in: text)
        for sentence in InterviewIntent.sentences(text)
        where sentence.range(of: #"\b(limited|only (one|two|a few)|minimi[sz]e|can'?t afford|budget|deadline|no downtime|by (tomorrow|today|the end of)|at the same time|simultaneously|you'?re the only|alone)\b"#,
                             options: [.regularExpression, .caseInsensitive]) != nil {
            let trimmed = sentence.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if !result.contains(where: { trimmed.lowercased().contains($0) }) { result.append(trimmed) }
        }
        return Array(result.prefix(6))
    }

    // MARK: Prompt

    /// The context block for a request: what the interviewer said earlier in this topic, the incidents and
    /// constraints in it, and what the request's references point to. Nil when there is nothing to add.
    func promptNote(for request: String) -> String? {
        let reference = ContextReference.detect(request)
        let normalizedRequest = TextSimilarity.normalized(request)
        let earlier = statements.filter { TextSimilarity.normalized($0.text) != normalizedRequest
            && TextSimilarity.containment($0.text, in: request) < 0.9 }
        guard !earlier.isEmpty || reference.refersBack else { return nil }
        var lines: [String] = []
        if !earlier.isEmpty {
            var budget = maxCharacters
            var kept: [String] = []
            for statement in earlier.reversed() {
                let line = "- " + statement.text.prefix(400)
                guard kept.isEmpty || budget - line.count >= 0 else { break }
                kept.insert(line, at: 0)
                budget -= line.count
            }
            lines.append("What the interviewer said earlier in this part of the interview (oldest first):\n" + kept.joined(separator: "\n"))
        }
        let incidents = self.incidents
        if incidents.count >= 2 {
            lines.append("Separate incidents or problems described: " + incidents.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "; ") + ".")
        }
        let constraints = self.constraints
        if !constraints.isEmpty { lines.append("Stated constraints: " + constraints.joined(separator: "; ") + ".") }

        if reference.refersBack {
            let said = reference.phrases.first.map { "\"\($0.trimmingCharacters(in: .whitespaces))\"" } ?? "The request"
            if earlier.isEmpty {
                lines.append("\(said) refers to something said earlier that was not captured. Don't invent specifics: give a useful answer that holds in the likely cases and state your assumption in a few words.")
            } else if let ordinal = reference.ordinal, ordinal <= incidents.count {
                lines.append("\(said) most likely means incident \(ordinal): \(incidents[ordinal - 1]). Answer about that one.")
            } else if reference.plural, incidents.count >= 2 {
                lines.append("\(said) refers to the \(incidents.count) incidents above. Address each of them specifically, and compare them where the request asks (for example priority by impact, urgency, security risk and number of people affected).")
            } else {
                lines.append("\(said) refers to the scenario above. Answer about that scenario specifically; if it is still ambiguous, state your assumption in a few words.")
            }
        }
        if !earlier.isEmpty {
            lines.append("Answer in terms of this scenario (its systems, constraints and people), not a generic version of the topic. Mention a detail only if it is relevant to the request.")
        }
        return lines.joined(separator: "\n")
    }

    private func subject(_ text: String) -> String {
        TextSimilarity.contentWords(text).filter { !SpeechEventClassifier.requestFiller.contains($0) }.joined(separator: " ")
    }
}
