import Foundation

/// Session-scoped conversation memory: recent exchanges, a rolling summary of older ones, the current
/// topic and project, and unresolved questions. In memory only (never written to disk); cleared with
/// the session or on request. With retention off only the latest exchange is kept (for follow-ups).
@MainActor @Observable final class ConversationMemory {
    struct Exchange: Identifiable, Equatable, Sendable {
        let id = UUID()
        var question: String
        var answer: String
        var category: QuestionCategory
        var kind: SpeechEventKind
        var project: String?
        var at: Date
    }

    var retain = true { didSet { if !retain { trim(keep: 1) } } }
    var maxExchanges = 6
    private(set) var exchanges: [Exchange] = []
    /// One line per exchange that left the recent window (oldest first, bounded).
    private(set) var summary: [String] = []
    private(set) var topic: String?
    private(set) var project: String?
    private(set) var unresolved: [String] = []
    /// The interviewer's own statements in the current topic (scenarios, incidents, constraints).
    private(set) var interview = InterviewContext()

    @discardableResult
    func recordInterviewer(_ text: String, turnID: Int, at now: Date = Date()) -> InterviewContext.Decision {
        interview.record(text, turnID: turnID, at: now)
    }

    func record(question: String, answer: String, category: QuestionCategory, kind: SpeechEventKind, projects: [String]) {
        let mentioned = projects.first { PersonalMemoryStore.mentions(PersonalMemoryStore.normalize(question + " " + answer), project: $0) }
        // A follow-up stays on the active project unless it names another one.
        if let mentioned { project = mentioned } else if kind == .newQuestion { project = nil }
        let terms = TextSimilarity.contentWords(question).prefix(4).joined(separator: " ")
        topic = project.map { terms.isEmpty ? $0 : "\($0) · \(terms)" } ?? (terms.isEmpty ? topic : terms)
        unresolved.removeAll { TextSimilarity.jaccard($0, question) >= 0.6 }
        // A revised request (the same turn with its constraints added) replaces the answer to its shorter version.
        if let last = exchanges.last, TranscriptTurnAssembler.contains(question, last.question) { exchanges.removeLast() }
        exchanges.append(Exchange(question: question, answer: answer, category: category, kind: kind, project: project, at: Date()))
        trim(keep: retain ? maxExchanges : 1)
    }

    /// Drops the latest exchange (an automatic transition the user undid).
    func removeLast() { if !exchanges.isEmpty { exchanges.removeLast() } }

    func noteUnresolved(_ question: String) {
        guard retain, !unresolved.contains(question) else { return }
        unresolved.append(question)
        if unresolved.count > 5 { unresolved.removeFirst() }
    }

    func clear() {
        exchanges = []; summary = []; topic = nil; project = nil; unresolved = []; interview.clear()
    }

    /// Prompt context within `budget` characters: the rolling summary, then the latest exchanges
    /// (newest kept when the budget is tight).
    /// `since`: only exchanges from the current topic (older ones are stale context for an unrelated question).
    /// `request`: the request being answered; an exchange for a shorter version of it (before its constraints
    /// were added) is superseded, not context.
    /// `statements`: interviewer statements already sent as scenario context; their text is not repeated.
    func context(budget: Int = 900, since: Date? = nil, request: String? = nil, statements: [String] = []) -> String {
        let known = Set(statements.map(TextSimilarity.normalized))
        let exchanges = (since.map { start in self.exchanges.filter { $0.at >= start } } ?? self.exchanges)
            .filter { exchange in request.map { !TranscriptTurnAssembler.contains($0, exchange.question) } ?? true }
        guard !exchanges.isEmpty || !summary.isEmpty else { return "" }
        var recent: [String] = []
        var used = 0
        let answerRoom = min(320, max(60, budget / 3))
        // Exchanges about another project are not context for this one.
        let relevant = exchanges.suffix(3).filter { project == nil || $0.project == nil || $0.project == project }
        for exchange in relevant.reversed() {
            let line = known.contains(TextSimilarity.normalized(exchange.question))
                ? "Your answer to the interviewer's statement above: \(exchange.answer.prefix(answerRoom))"
                : "Q: \(exchange.question.prefix(160))\nA: \(exchange.answer.prefix(answerRoom))"
            // The newest exchange is always included (truncated by the final prefix if needed).
            guard recent.isEmpty || used + line.count <= budget - 80 else { break }
            recent.insert(line, at: 0)
            used += line.count + 1
        }
        var parts: [String] = []
        let earlier = summary.suffix(6).joined(separator: "; ")
        if !earlier.isEmpty, used + earlier.count + 20 <= budget { parts.append("Earlier topics: \(earlier)") }
        if let topic { parts.append("Current topic: \(topic)") }
        parts += recent
        return String(parts.joined(separator: "\n").prefix(budget))
    }

    private func trim(keep: Int) {
        while exchanges.count > keep {
            let old = exchanges.removeFirst()
            if retain { summary.append(String((old.project.map { "\($0): " } ?? "") + old.question.prefix(80))) }
        }
        if summary.count > 12 { summary.removeFirst(summary.count - 12) }
        if !retain { summary = []; unresolved = [] }
    }
}
