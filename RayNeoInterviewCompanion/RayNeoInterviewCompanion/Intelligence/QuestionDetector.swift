import Foundation

/// Deterministic question / request scoring. The score is a rule tally clamped to 0...1, not a probability.
nonisolated struct QuestionDetector: Sendable {
    var technicalKeywords: [String] = []

    private static let interrogatives: Set<String> = ["what", "how", "why", "when", "where", "which", "who", "whose", "what's", "how's"]
    private static let auxiliaries: Set<String> = ["can", "could", "would", "will", "do", "does", "did", "is", "are", "was", "were", "have", "has", "should", "may", "might"]
    private static let subjects: Set<String> = ["you", "we", "i", "it", "this", "that", "there", "your", "they", "the", "a", "an", "someone", "anyone"]
    private static let requestCues = [
        "tell me", "tell us", "describe", "explain", "walk me through", "walk us through", "talk me through",
        "show me", "show us", "give me", "give us", "talk about", "share", "define", "compare", "outline",
        "take me through", "go through", "elaborate", "summarize", "list",
        // Coding-interview instructions.
        "write a", "write an", "write me", "write the", "write some", "implement", "code up", "create a function", "build a",
    ]
    private static let leadIns = ["so", "okay", "ok", "now", "alright", "and", "well", "right", "then", "next", "please", "can you", "could you", "would you", "i'd like you to", "i want you to"]
    private static let danglingEndings: Set<String> = [
        "and", "or", "but", "the", "a", "an", "of", "to", "with", "between", "for", "about", "like", "so",
        "is", "are", "in", "on", "if", "because", "your", "my", "how", "what", "um", "uh",
    ]
    private static let followUpCues = ["and what about", "what about", "how about", "why is that", "why would", "can you elaborate",
                                       "could you elaborate", "go deeper", "follow up", "what if", "and how", "and why", "then what",
                                       "what happens if", "what happens when", "what would happen", "would your approach", "would that change",
                                       "what happens next", "explain the trade-offs", "how would you prioritize them", "how would you prioritise them"]

    func analyze(_ raw: String, previousQuestion: String? = nil) -> InterviewQuestion {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        func result(_ score: Double, _ reason: String) -> InterviewQuestion {
            InterviewQuestion(text: text, score: min(max(score, 0), 1), isFollowUp: isFollowUp(lower, previous: previousQuestion),
                              reason: reason, detectedAt: Date())
        }
        guard words.count >= 3 else { return result(0, "too short") }
        if let last = words.last, Self.danglingEndings.contains(last), !text.hasSuffix("?") {
            return result(0, "incomplete (ends with '\(last)')")
        }

        // Intent, not punctuation: imperatives and problem scenarios are requests; logistics never are.
        let intent = InterviewIntent.classify(text, hasContext: previousQuestion != nil)
        if intent.kind == .smallTalk { return result(0.1, "small talk / logistics") }

        var score = 0.0
        var reasons: [String] = []
        if text.hasSuffix("?") { score += 0.45; reasons.append("question mark") }

        let core = stripLeadIns(lower)
        let coreWords = core.split(separator: " ").map(String.init)
        if let first = coreWords.first, Self.interrogatives.contains(first) {
            score += 0.45; reasons.append("wh-question")
        } else if let first = words.first, Self.auxiliaries.contains(first), words.count > 1, Self.subjects.contains(words[1]) {
            score += 0.4; reasons.append("yes/no or polite question form")
        }
        if Self.requestCues.contains(where: { core.hasPrefix($0) }) {
            score += 0.55; reasons.append("request phrased as instruction")
        } else if Self.requestCues.contains(where: { lower.contains(" " + $0 + " ") }) {
            score += 0.3; reasons.append("embedded request")
        }
        if words.contains("you") || words.contains("your") { score += 0.05 }
        if technicalKeywords.contains(where: { lower.contains($0) }) { score += 0.1; reasons.append("technical topic") }
        if text.hasSuffix(".") || text.hasSuffix("?") { score += 0.05 }
        if intent.actionable, intent.confidence > score {
            score = intent.confidence
            reasons.append("actionable intent: \(intent.kind.label) (\(intent.reason))")
        }
        return result(score, reasons.isEmpty ? "no question cues" : reasons.joined(separator: ", "))
    }

    private func stripLeadIns(_ lower: String) -> String {
        var core = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        var changed = true
        while changed {
            changed = false
            for lead in Self.leadIns where core.hasPrefix(lead + " ") || core.hasPrefix(lead + ", ") {
                core = String(core.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                changed = true
            }
        }
        return core
    }

    private func isFollowUp(_ lower: String, previous: String?) -> Bool {
        guard previous != nil else { return false }
        return Self.followUpCues.contains(where: { lower.hasPrefix($0) || lower.contains(" " + $0) })
    }
}
