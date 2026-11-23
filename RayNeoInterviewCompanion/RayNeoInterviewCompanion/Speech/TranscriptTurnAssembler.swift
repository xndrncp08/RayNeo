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
            text.isEmpty ? next : (Self.isIncomplete(text) && Self.isFragment(next) ? Self.merge(text, next) : Self.join([text, next]))
        }
        return Self.join([finals, live])
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
            if pending[index].text != trimmed { revisions += 1; pending[index] = segment } else { duplicates += 1 }
            return nil
        }
        if pending.last?.text == trimmed { duplicates += 1; return nil }

        // Late segment for the last emitted turn: a correction of its audio, or the rest of an incomplete turn.
        if pending.isEmpty, var last = turns.last, let emitted = lastEmittedAt {
            let lastAudio = RecognizedSegment(text: last.text, start: last.start, end: last.end)
            if segment.overlap(with: lastAudio) >= 0.5 {
                if last.text == trimmed || last.text.hasSuffix(trimmed) { duplicates += 1; return nil }
                revisions += 1
                last.text = trimmed
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
        let wait = Self.isIncomplete(text) ? silence + incompleteGrace : (completeQuestion ? min(silence, questionSilence) : silence)
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

    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
