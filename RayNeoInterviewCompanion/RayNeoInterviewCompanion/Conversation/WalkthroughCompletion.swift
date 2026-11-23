import Foundation

/// How readily a guided walkthrough moves on by itself. Changes evidence thresholds, never adds delays.
nonisolated enum AdaptiveWalkthroughMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, conservative, balanced, responsive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off (Next / \"next step\" only)"
        case .conservative: "Conservative"
        case .balanced: "Balanced (default)"
        case .responsive: "Responsive"
        }
    }

    /// Share of the block's key concepts that must have been said.
    var coverage: Double { switch self { case .off: 2; case .conservative: 0.8; case .balanced: 0.6; case .responsive: 0.5 } }
    /// Share of what was said that must relate to the block (rejects unrelated talk with shared keywords).
    var relevance: Double { switch self { case .off: 2; case .conservative: 0.45; case .balanced: 0.35; case .responsive: 0.25 } }
    /// Combined completion confidence needed.
    var completion: Double { switch self { case .off: 2; case .conservative: 0.85; case .balanced: 0.72; case .responsive: 0.62 } }
    /// Responsive may advance inside an utterance once nearly everything was said; others wait for its end.
    var midUtterance: Bool { self == .responsive }
    /// Explanation → code is stricter: showing code early hides the text the wearer is still reading.
    var strictCoverage: Double { min(0.95, coverage + 0.25) }
}

/// Decides when the wearer has finished explaining one walkthrough block, in their own words or verbatim.
/// Local and deterministic: key concepts (stemmed content words with synonym groups) are matched against
/// what was heard; verbatim reading alignment counts as well. Silence alone never completes a block —
/// the recognizer's end of utterance only counts together with enough coverage.
nonisolated struct WalkthroughCompletionEvaluator: Sendable {
    struct Concept: Equatable, Sendable {
        let key: String
        let forms: [String]
    }

    struct Evaluation: Equatable, Sendable {
        var blockID: String
        var coverage: Double
        var covered: [String]
        var missing: [String]
        var relevance: Double
        var alignment: Double
        var completion: Double
        var advance: Bool
        /// Close enough that an optional AI check may decide.
        var borderline: Bool
        var reason: String
    }

    let blockID: String
    let concepts: [Concept]
    /// Concept keys of each sentence of the block, in order.
    let sentenceConcepts: [[String]]
    /// Meaningful words in the block (a paraphrase of the whole block is roughly this long).
    let blockWords: Int
    var mode: AdaptiveWalkthroughMode
    /// Ignore the utterance that was already in progress when the block appeared (it belongs to what
    /// the wearer was reading before), up to and including its final result.
    var skipUntilFinal = false
    private var finalized: [String] = []
    private var live: [String] = []
    private var lastFinal = ""

    init(blockID: String, text: String, mode: AdaptiveWalkthroughMode) {
        self.blockID = blockID
        self.mode = mode
        concepts = Self.concepts(of: text)
        blockWords = Self.meaningful(text).count
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence, !Self.meaningful(sentence).isEmpty { sentences.append(sentence) }
        }
        let keys = Set(concepts.map(\.key))
        sentenceConcepts = sentences.map { Self.concepts(of: $0).map(\.key).filter { keys.contains($0) } }.filter { !$0.isEmpty }
    }

    /// Partial results replace the live hypothesis (recognizer revisions); finals are kept.
    mutating func ingest(_ text: String, isFinal: Bool) {
        if skipUntilFinal {
            if isFinal { skipUntilFinal = false }
            return
        }
        let words = Self.meaningful(text)
        if isFinal { finalized += words; live = []; lastFinal = text } else { live = words }
    }

    var heardWordCount: Int { finalized.count + live.count }

    /// `strict` (explanation → code): the whole explanation must have been delivered — read verbatim to
    /// its last word with confidence, or every sentence (the last included) covered in a finished utterance.
    func evaluate(alignmentProgress: Double = 0, alignmentConfidence: Double = 0, readingComplete: Bool = false,
                  utteranceEnded: Bool, strict: Bool = false) -> Evaluation {
        if strict { return evaluateStrict(alignmentProgress: alignmentProgress, alignmentConfidence: alignmentConfidence,
                                          readingComplete: readingComplete, utteranceEnded: utteranceEnded) }
        let heard = finalized + live
        let covered = concepts.filter { concept in heard.contains { word in concept.forms.contains { Self.match(word, $0) } } }
        let coverage = concepts.isEmpty ? (heard.isEmpty ? 0 : 1) : Double(covered.count) / Double(concepts.count)
        let related = heard.filter { word in concepts.contains { $0.forms.contains { Self.match(word, $0) } } }.count
        let relevance = heard.isEmpty ? 0 : Double(related) / Double(heard.count)
        let alignment = alignmentProgress * alignmentConfidence
        var evaluation = Evaluation(blockID: blockID, coverage: coverage, covered: covered.map(\.key),
                                    missing: concepts.filter { !covered.contains($0) }.map(\.key), relevance: relevance,
                                    alignment: alignment, completion: 0, advance: false, borderline: false, reason: "")
        guard mode != .off else { evaluation.reason = "adaptive walkthrough is off"; return evaluation }
        if readingComplete {
            evaluation.completion = 1
            evaluation.advance = true
            evaluation.reason = "explanation read to its last word"
            return evaluation
        }
        let boundary = utteranceEnded ? 1.0 : (mode.midUtterance && coverage >= 0.9 ? 0.6 : 0)
        let semantic = 0.55 * coverage + 0.25 * min(1, relevance / 0.6) + 0.2 * boundary
        evaluation.completion = max(semantic, alignment >= 0.9 ? alignment : 0)
        let enough = covered.count >= min(2, concepts.count)
        if heard.isEmpty {
            evaluation.reason = "nothing heard yet"
        } else if relevance < mode.relevance {
            evaluation.reason = String(format: "speech is mostly unrelated (relevance %.2f)", relevance)
        } else if coverage < mode.coverage || !enough {
            evaluation.reason = "covered \(covered.count)/\(concepts.count) key ideas; waiting"
            evaluation.borderline = utteranceEnded && coverage >= mode.coverage - 0.2 && heard.count >= 6
        } else if boundary == 0 {
            evaluation.reason = "ideas covered; waiting for the end of the sentence"
        } else if evaluation.completion < mode.completion {
            evaluation.reason = String(format: "completion %.2f below %.2f", evaluation.completion, mode.completion)
        } else {
            evaluation.advance = true
            evaluation.reason = "covered \(covered.count)/\(concepts.count) key ideas in your own words"
        }
        return evaluation
    }

    private func evaluateStrict(alignmentProgress: Double, alignmentConfidence: Double, readingComplete: Bool,
                                utteranceEnded: Bool) -> Evaluation {
        var evaluation = evaluate(alignmentProgress: alignmentProgress, alignmentConfidence: alignmentConfidence,
                                  readingComplete: false, utteranceEnded: utteranceEnded)
        evaluation.advance = false
        evaluation.borderline = false
        guard mode != .off else { return evaluation }
        if readingComplete {
            guard alignmentConfidence >= 0.6 else {
                evaluation.reason = String(format: "reached the last word but alignment confidence is %.2f", alignmentConfidence)
                return evaluation
            }
            evaluation.completion = 1
            evaluation.advance = true
            evaluation.reason = "explanation read to its last word"
            return evaluation
        }
        let heard = finalized + live
        let perSentence = sentenceConcepts.map { keys in
            Double(keys.filter { evaluation.covered.contains($0) }.count) / Double(max(1, keys.count))
        }
        let sentencesCovered = perSentence.allSatisfy { $0 >= 0.5 } && (perSentence.last ?? 1) >= 0.6
        let enoughSpeech = Double(heard.count) >= 0.5 * Double(blockWords)
        if heard.isEmpty {
            evaluation.reason = "nothing heard yet"
        } else if !utteranceEnded || !live.isEmpty {
            evaluation.reason = "waiting for the end of the utterance (no code mid-sentence)"
        } else if TranscriptTurnAssembler.isIncomplete(lastFinal) {
            evaluation.reason = "the utterance ended mid-phrase"
        } else if evaluation.relevance < mode.relevance {
            evaluation.reason = String(format: "speech is mostly unrelated (relevance %.2f)", evaluation.relevance)
        } else if !sentencesCovered {
            let missing = perSentence.firstIndex { $0 < 0.5 } ?? perSentence.count - 1
            evaluation.reason = "sentence \(missing + 1) of \(perSentence.count) not explained yet"
        } else if !enoughSpeech {
            evaluation.reason = "too little said for the whole explanation"
        } else if evaluation.coverage < mode.strictCoverage {
            evaluation.reason = String(format: "covered %d/%d key ideas (code needs %.0f%%)", evaluation.covered.count, concepts.count,
                                       mode.strictCoverage * 100)
            evaluation.borderline = evaluation.coverage >= mode.strictCoverage - 0.2 && heard.count >= 6
        } else {
            evaluation.completion = max(evaluation.completion, 0.9)
            evaluation.advance = true
            evaluation.reason = "whole explanation covered (\(evaluation.covered.count)/\(concepts.count) key ideas, every sentence)"
        }
        return evaluation
    }

    // MARK: Concepts

    static let generic: Set<String> = ["use", "make", "really", "go", "going", "want", "need", "now", "here", "basically", "thing",
                                       "way", "just", "get", "okay", "ok", "so", "well", "actually", "probably", "let", "let's",
                                       "start", "write", "code", "create", "do", "done", "one", "ones", "some", "all", "only",
                                       "new", "because", "since", "whose", "which", "back", "right", "yeah", "regular"]

    /// Paraphrase groups: any member covers the concept.
    static let synonyms: [[String]] = [
        ["unique", "distinct", "duplicate", "dedupe", "dedup", "repeat"], ["array", "list"], ["spread", "unpack", "expand"],
        ["convert", "turn", "transform", "change"], ["return", "give", "output", "produce", "result"], ["filter", "keep", "select", "pick"],
        ["store", "hold", "contain", "save"], ["function", "method", "helper"], ["accept", "take", "receive", "pass", "input", "parameter", "argument"],
        ["active", "enabled"], ["status", "state"], ["student", "learner", "pupil"], ["loop", "iterate", "each"],
        ["check", "compare", "match", "equal"], ["object", "record", "item", "element", "value", "entry"], ["order", "sequence"],
        ["sum", "add", "total"], ["count", "number"], ["string", "text"], ["length", "size"], ["group", "bucket"],
    ]

    static func meaningful(_ text: String) -> [String] {
        TextSimilarity.contentWords(text).filter { !generic.contains($0) }
    }

    static func concepts(of text: String) -> [Concept] {
        var result: [Concept] = []
        for word in meaningful(text) {
            let group = synonyms.first { $0.contains { match(word, $0) } }
            let key = group?.first ?? word
            guard !result.contains(where: { $0.key == key }) else { continue }
            result.append(Concept(key: key, forms: group ?? [word]))
        }
        return Array(result.prefix(8))
    }

    /// Same word up to inflection ("store"/"storing", "array"/"arrays"); short words must match exactly.
    static func match(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        guard shorter >= 4 else { return a + "s" == b || b + "s" == a }
        let common = zip(a, b).prefix { $0 == $1 }.count
        return common >= max(4, shorter - 1)
    }
}

// MARK: Editor progress (optional, explicitly paired)

/// Code structures a step expects, compared whitespace-insensitively by the editor companion. Presence is
/// evidence, not proof of a correct implementation; the editor's error count is reported alongside.
nonisolated enum CodeStructures {
    static func expected(from code: String) -> [String] {
        code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .filter { line in line.contains { $0.isLetter || $0.isNumber } }
    }

    /// The step is complete when every structure is present and (when the editor reports it) nothing fails
    /// its syntax/type check. Conservative also requires that the editor reported a check result.
    static func complete(expected: Int, present: [Bool], errors: Int?, mode: AdaptiveWalkthroughMode) -> (done: Bool, reason: String) {
        guard mode != .off else { return (false, "adaptive walkthrough is off") }
        guard expected > 0, present.count == expected else { return (false, "editor report does not match this step") }
        let found = present.filter { $0 }.count
        guard found == expected else { return (false, "editor: \(found)/\(expected) expected structures present") }
        if let errors, errors > 0 { return (false, "editor: structures present but \(errors) error(s) reported") }
        if errors == nil, mode == .conservative { return (false, "editor: structures present; waiting for a syntax/type check") }
        return (true, errors == 0 ? "editor: all structures present, no errors" : "editor: all structures present")
    }
}

/// One progress report for the active code step.
nonisolated struct EditorProgress: Equatable, Sendable {
    var blockID: String
    var file: String
    var language: String?
    var present: [Bool]
    var errors: Int?
}
