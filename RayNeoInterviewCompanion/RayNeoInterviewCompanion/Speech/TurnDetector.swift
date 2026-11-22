import Foundation

/// Bounded rolling transcript. Old segments drop off so long sessions do not grow memory.
struct TranscriptBuffer: Sendable {
    private(set) var segments: [TranscriptSegment] = []
    let maximumSegments: Int
    let maximumCharacters: Int

    init(maximumSegments: Int = 200, maximumCharacters: Int = 20_000) {
        self.maximumSegments = maximumSegments
        self.maximumCharacters = maximumCharacters
    }

    var characterCount: Int { segments.reduce(0) { $0 + $1.text.count } }

    mutating func append(_ segment: TranscriptSegment) {
        // Recognizers occasionally re-emit an identical final for the same audio; drop it.
        if let last = segments.last, last.text == segment.text, abs(last.end - segment.end) < 0.5 { return }
        segments.append(segment)
        var characters = characterCount
        while segments.count > maximumSegments || characters > maximumCharacters {
            characters -= segments.removeFirst().text.count
        }
    }

    mutating func removeAll() { segments.removeAll() }

    /// Most recent text, bounded, for prompt context.
    func recentText(maximumCharacters: Int) -> String {
        var result: [String] = []
        var total = 0
        for segment in segments.reversed() {
            total += segment.text.count + 1
            if total > maximumCharacters { break }
            result.insert(segment.text, at: 0)
        }
        return result.joined(separator: " ")
    }
}

/// Groups recognizer output into speech turns. A turn ends after `silence` seconds with
/// no new transcript text and no voice activity. Times are injected so it is fully testable.
struct TurnDetector: Sendable {
    var silence: Double
    private var finalizedText: [String] = []
    private var volatileText = ""
    private var turnStart: Double?
    private var turnEnd: Double = 0
    private var lastActivity: Date?

    init(silence: Double) { self.silence = silence }

    var pendingText: String { (finalizedText + (volatileText.isEmpty ? [] : [volatileText])).joined(separator: " ") }
    var hasPendingSpeech: Bool { !pendingText.trimmingCharacters(in: .whitespaces).isEmpty }

    mutating func partial(_ text: String, at now: Date) {
        if text != volatileText { lastActivity = now }
        volatileText = text
    }

    mutating func final(_ text: String, start: Double, end: Double, at now: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileText = ""
        lastActivity = now
        guard !trimmed.isEmpty else { return }
        // Deduplicate a fragment re-emitted as final.
        if finalizedText.last == trimmed { return }
        finalizedText.append(trimmed)
        if turnStart == nil { turnStart = start }
        turnEnd = max(turnEnd, end)
    }

    /// Voice activity keeps a turn open even while the recognizer has not produced new text yet.
    mutating func voiceActivity(at now: Date) {
        if hasPendingSpeech { lastActivity = now }
    }

    /// Returns a completed turn once the configured silence has elapsed.
    mutating func tick(now: Date) -> CompletedTurn? {
        guard hasPendingSpeech, let lastActivity, now.timeIntervalSince(lastActivity) >= silence else { return nil }
        let turn = CompletedTurn(text: pendingText, start: turnStart ?? turnEnd, end: turnEnd)
        reset()
        return turn
    }

    mutating func reset() {
        finalizedText = []; volatileText = ""; turnStart = nil; turnEnd = 0; lastActivity = nil
    }
}
