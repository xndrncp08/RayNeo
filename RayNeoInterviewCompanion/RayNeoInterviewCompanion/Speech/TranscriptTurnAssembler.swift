import Foundation

/// One finalized recognizer result. SpeechAnalyzer exposes no result IDs, so the local ID is derived
/// from the result's audio range on the capture timeline (the stable boundary the API does expose).
nonisolated struct RecognizedSegment: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var id: String { String(format: "seg-%.2f-%.2f", start, end) }

    /// Fraction of the shorter segment's audio covered by the other one.
    func overlap(with other: RecognizedSegment) -> Double {
        let shared = min(end, other.end) - max(start, other.start)
        let shorter = max(0.05, min(end - start, other.end - other.start))
        return max(0, shared) / shorter
    }
}

/// A stable conversation turn assembled from one or more segments.
nonisolated struct ConversationTurn: Identifiable, Equatable, Sendable {
    let id: Int
    var text: String
    var start: Double
    var end: Double
    var segmentIDs: [String]
    /// Bumped when a late segment revises or completes the turn after it was emitted.
    var revision = 0
}

nonisolated enum AssemblerOutput: Equatable, Sendable {
    /// A new turn, ready for classification.
    case turn(ConversationTurn)
    /// An already-emitted turn whose text changed (late correction, or a fragment that completes it).
    case revised(ConversationTurn)
}

/// Sits between the recognizer and everything that classifies speech or asks for answers.
///
/// - Live transcript: the volatile hypothesis, replaced on every partial (never a turn by itself).
/// - Finalized turns: stable utterances with IDs and the segments they came from.
/// - Revisions: a final whose audio overlaps an earlier segment replaces it (no new turn); an identical
///   re-emitted final is dropped.
/// - Incomplete endings ("…talk about?") wait a short extra grace for the rest, and a short fragment that
///   arrives just after an incomplete turn was emitted completes that turn (a revision), never a new turn.
/// Times are injected, so behaviour is deterministic in tests.
nonisolated struct TranscriptTurnAssembler: Sendable {
    var silence: Double
    /// Extra wait when the pending text ends mid-phrase.
    var incompleteGrace = 1.5
    /// How long after an incomplete turn a short fragment may still complete it.
    var mergeWindow = 4.0
    /// Faster endpoint for a finalized, clearly complete question (ends with "?", not mid-phrase).
    var questionSilence = 0.6
    /// Longer endpoint after a scenario whose task has not been stated yet ("Our API is returning 500s."),
    /// so "Walk me through your approach." after a short pause belongs to the same request.
    var scenarioSilence = 2.4

    private(set) var live = ""
    private(set) var pending: [RecognizedSegment] = []
    private(set) var turns: [ConversationTurn] = []
    private(set) var revisions = 0
    private(set) var merges = 0
    private(set) var duplicates = 0
    private var lastActivity: Date?
    private var lastEmittedAt: Date?
    private var nextID = 1

    init(silence: Double) { self.silence = silence }

    var pendingText: String {
        let finals = pending.map(\.text).reduce("") { text, next in
            text.isEmpty ? next : (Self.isIncomplete(text) && Self.isFragment(next) ? Self.merge(text, next) : Self.stitch(text, next))
        }
        return Self.stitch(finals, live)
    }
    var hasPendingSpeech: Bool { !pendingText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Volatile hypothesis: replaces the previous one (a revision of the live transcript only).
    mutating func partial(_ text: String, at now: Date) {
        if text != live { lastActivity = now }
        live = text
    }

    /// A finalized result. Returns a revised turn when it belongs to one already emitted.
    mutating func final(_ text: String, start: Double, end: Double, at now: Date) -> AssemblerOutput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        live = ""
        lastActivity = now
        guard !trimmed.isEmpty else { return nil }
        let segment = RecognizedSegment(text: trimmed, start: start, end: max(start, end))

        // A correction of audio already in the pending turn replaces that segment.
        if let index = pending.firstIndex(where: { $0.overlap(with: segment) >= 0.5 }) {
            let revised = Self.revise(pending[index].text, with: trimmed)
            if revised != pending[index].text {
                revisions += 1
                pending[index] = RecognizedSegment(text: revised, start: min(pending[index].start, segment.start), end: max(pending[index].end, segment.end))
            } else { duplicates += 1 }
            return nil
        }
        if let last = pending.last, Self.contains(last.text, trimmed) { duplicates += 1; return nil }

        // Late segment for the last emitted turn: a correction of its audio, or the rest of an incomplete turn.
        if pending.isEmpty, var last = turns.last, let emitted = lastEmittedAt {
            let lastAudio = RecognizedSegment(text: last.text, start: last.start, end: last.end)
            // Re-recognised audio, or a restarted recognizer repeating the turn's last words in a new segment.
            let repeatsTail = now.timeIntervalSince(emitted) <= mergeWindow && Self.overlapLength(last.text, trimmed) >= 3
            // A lone word already in the turn ("Diskarte.") may be said again on purpose; only longer repeats are duplicates.
            let repeated = trimmed.split(separator: " ").count >= 3 && Self.contains(last.text, trimmed)
            if segment.overlap(with: lastAudio) >= 0.5 || repeatsTail || now.timeIntervalSince(emitted) <= mergeWindow && repeated {
                let revised = Self.revise(last.text, with: trimmed)
                if revised == last.text { duplicates += 1; return nil }
                revisions += 1
                last.text = revised
                last.end = max(last.end, segment.end)
                last.segmentIDs.append(segment.id)
                last.revision += 1
                turns[turns.count - 1] = last
                return .revised(last)
            }
            if now.timeIntervalSince(emitted) <= mergeWindow, Self.isIncomplete(last.text), Self.isFragment(trimmed) {
                merges += 1
                last.text = Self.merge(last.text, trimmed)
                last.end = max(last.end, segment.end)
                last.segmentIDs.append(segment.id)
                last.revision += 1
                turns[turns.count - 1] = last
                return .revised(last)
            }
        }
        pending.append(segment)
        return nil
    }

    /// Voice activity keeps a turn open while the recognizer has not produced text yet.
    mutating func voiceActivity(at now: Date) {
        if hasPendingSpeech { lastActivity = now }
    }

    /// Emits the turn once silence (plus grace for an unfinished phrase) has elapsed.
    mutating func tick(now: Date) -> AssemblerOutput? {
        guard hasPendingSpeech, let lastActivity else { return nil }
        let text = pendingText
        let completeQuestion = live.isEmpty && text.hasSuffix("?") && !Self.isIncomplete(text)
        let wait = Self.isIncomplete(text) ? silence + incompleteGrace
            : completeQuestion ? min(silence, questionSilence)
            : InterviewIntent.classify(text).awaitingTask ? max(silence, scenarioSilence) : silence
        guard now.timeIntervalSince(lastActivity) >= wait else { return nil }
        let start = pending.first?.start ?? pending.last?.end ?? 0
        let end = pending.map(\.end).max() ?? start
        let turn = ConversationTurn(id: nextID, text: pendingText, start: start, end: end, segmentIDs: pending.map(\.id))
        nextID += 1
        turns.append(turn)
        if turns.count > 50 { turns.removeFirst(turns.count - 50) }
        pending = []
        live = ""
        self.lastActivity = nil
        lastEmittedAt = now
        return .turn(turn)
    }

    /// Folds a later turn (a continuation such as "The application must handle…") into the turn before it,
    /// which is re-emitted as a revision with the same ID. Returns nil when there is no earlier turn.
    mutating func absorb(_ turn: ConversationTurn) -> ConversationTurn? {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }), index > 0 else { return nil }
        var previous = turns[index - 1]
        previous.text = Self.stitch(previous.text, turn.text)
        previous.end = max(previous.end, turn.end)
        previous.segmentIDs += turn.segmentIDs
        previous.revision += 1
        merges += 1
        turns[index - 1] = previous
        turns.remove(at: index)
        return previous
    }

    /// Recognizer restart: provisional text is discarded; emitted turns and IDs are kept.
    mutating func reset() {
        pending = []; live = ""; lastActivity = nil
    }

    // MARK: Text rules

    static let danglingEndings: Set<String> = ["and", "or", "but", "the", "a", "an", "of", "to", "with", "between", "for", "about",
                                               "like", "so", "is", "are", "in", "on", "if", "because", "your", "my", "how", "what",
                                               "um", "uh", "called", "named", "regarding", "using", "into", "from"]

    /// Ends mid-phrase ("Can you talk about?", "Tell me about your"), whatever the punctuation.
    static func isIncomplete(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        guard let last = words.last else { return false }
        return danglingEndings.contains(String(last))
    }

    /// A short continuation (a name or phrase), not a question of its own.
    static func isFragment(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        let lower = text.lowercased()
        let questionStart = ["what", "how", "why", "can", "could", "would", "do", "does", "is", "are", "tell", "write"].contains { lower.hasPrefix($0 + " ") }
        return words.count <= 4 && !questionStart
    }

    /// "Can you talk about?" + "Discarte." → "Can you talk about Discarte?"
    static func merge(_ first: String, _ fragment: String) -> String {
        let wasQuestion = first.hasSuffix("?")
        let head = first.trimmingCharacters(in: CharacterSet(charactersIn: "?.!, "))
        var tail = fragment.trimmingCharacters(in: .whitespaces)
        if wasQuestion { tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: ".!")) + (tail.hasSuffix("?") ? "" : "?") }
        if wasQuestion, tail.hasSuffix("??") { tail.removeLast() }
        return head + " " + tail
    }

    /// Joins two consecutive recognition results without repeating words: a restarted recognizer often repeats
    /// the tail of the previous result ("…thousands of submissions, tem" + "The application must handle thousands
    /// of submissions, temporary…"). The longest overlap (at least two words, or one cut-off word) is merged once.
    static func stitch(_ first: String, _ second: String) -> String {
        let a = first.trimmingCharacters(in: .whitespaces), b = second.trimmingCharacters(in: .whitespaces)
        if a.isEmpty || b.isEmpty { return join([a, b]) }
        if contains(b, a) { return b }
        if contains(a, b) { return a }
        let aWords = a.split(separator: " ").map(String.init), bWords = b.split(separator: " ").map(String.init)
        let k = overlapLength(a, b)
        guard k > 0 else { return join([a, b]) }
        // The cut-off last word of `first` ("tem") is replaced by its complete form in `second`.
        return join([aWords.dropLast(k).joined(separator: " "), bWords.joined(separator: " ")])
    }

    /// A corrected result for the same audio: the longer reading wins when one contains the other, overlapping
    /// readings are stitched, and a genuinely different reading replaces the old one.
    static func revise(_ old: String, with new: String) -> String {
        if contains(old, new) { return old }
        if contains(new, old) { return new }
        return overlapLength(old, new) >= 2 ? stitch(old, new) : new
    }

    /// Words `second` repeats from the end of `first` (the last word of `first` may be cut off).
    static func overlapLength(_ first: String, _ second: String) -> Int {
        let a = first.split(separator: " ").map(key), b = second.split(separator: " ").map(key)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        for k in stride(from: min(a.count, b.count, 40), through: 1, by: -1) {
            let tail = Array(a.suffix(k)), head = Array(b.prefix(k))
            let exact = tail == head
            let cutOff = tail.dropLast() == head.dropLast() && tail.last.map { last in head.last.map { $0.hasPrefix(last) && last.count >= 2 } ?? false } == true
            // One shared word is too weak ("…the database." + "Database indexes…" are both real speech).
            if (exact || cutOff) && k >= 2 { return k }
        }
        return 0
    }

    /// `text` already includes every word of `part`, in order and contiguously (case and punctuation ignored).
    static func contains(_ text: String, _ part: String) -> Bool {
        let t = text.split(separator: " ").map(key), p = part.split(separator: " ").map(key)
        guard !p.isEmpty, p.count <= t.count else { return false }
        return (0...(t.count - p.count)).contains { Array(t[$0..<($0 + p.count)]) == p }
    }

    private static func key(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
