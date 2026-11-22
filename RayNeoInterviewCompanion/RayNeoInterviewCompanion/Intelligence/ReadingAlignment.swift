import Foundation

/// Normalisation and fuzzy word matching shared by the expected answer and the live transcript.
nonisolated enum ReadingText {
    static let contractions: [String: [String]] = [
        "i'd": ["i", "would"], "i'm": ["i", "am"], "i'll": ["i", "will"], "i've": ["i", "have"],
        "it's": ["it", "is"], "that's": ["that", "is"], "there's": ["there", "is"], "what's": ["what", "is"],
        "let's": ["let", "us"], "we're": ["we", "are"], "they're": ["they", "are"], "you're": ["you", "are"],
        "we'd": ["we", "would"], "we'll": ["we", "will"], "we've": ["we", "have"], "they'll": ["they", "will"],
        "don't": ["do", "not"], "doesn't": ["does", "not"], "didn't": ["did", "not"], "can't": ["can", "not"],
        "cannot": ["can", "not"], "won't": ["will", "not"], "isn't": ["is", "not"], "aren't": ["are", "not"],
        "wasn't": ["was", "not"], "wouldn't": ["would", "not"], "couldn't": ["could", "not"],
        "shouldn't": ["should", "not"], "hasn't": ["has", "not"], "haven't": ["have", "not"],
    ]

    /// Function words: they count as weak evidence only, so shared filler never drives the cursor.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "with", "by", "from",
        "is", "are", "was", "were", "be", "been", "am", "it", "its", "this", "that", "these", "those", "i", "you",
        "we", "they", "he", "she", "me", "my", "your", "our", "their", "would", "will", "can", "could", "do",
        "does", "did", "if", "then", "than", "as", "about", "into", "um", "uh", "like", "just", "also", "very",
        "not", "have", "has", "had", "us", "let", "what", "how", "why", "when", "where", "which", "who",
        "first", "next", "there", "here", "up", "out", "all", "any", "some", "should",
    ]

    /// Lower-cased tokens without punctuation, contractions expanded identically on both sides.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .flatMap { raw -> [String] in
                let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                if let expanded = contractions[word] { return expanded }
                let plain = word.replacingOccurrences(of: "'", with: "")
                return plain.isEmpty ? [] : [plain]
            }
    }

    static func isContent(_ word: String) -> Bool { word.count > 1 && !stopwords.contains(word) }

    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// 1 exact, 0.85 same stem, 0.7/0.6 near spelling (recognition errors), 0 otherwise.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if stem(a) == stem(b) { return 0.85 }
        guard min(a.count, b.count) >= 4 else { return 0 }
        switch editDistance(a, b, limit: 2) {
        case 1: return 0.7
        case 2 where max(a.count, b.count) >= 8: return 0.6
        default: return 0
        }
    }

    /// Levenshtein distance, returning limit + 1 as soon as it is exceeded.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMinimum = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}

/// An answer split into caption windows that each fit the lens, with an exact map from every window to the
/// global alignment-word indices it contains. Every word of the answer appears, in order, in exactly one
/// window core; optional context and the page counter are display-only extras.
nonisolated struct ReadingPlan: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        /// The window's own words (no context, no counter).
        let text: String
        /// Global indices into `words`.
        let words: Range<Int>
        /// Index of the section's last meaningful word: reaching it advances the display.
        let endTrigger: Int
        /// Second-to-last meaningful word: accepted only at the end of an utterance with more speech heard,
        /// so one misrecognised final word cannot strand the reader.
        let relaxedTrigger: Int
    }

    /// One rendered line of the whole answer, wrapped once at the calibrated width and never re-wrapped.
    struct VisualLine: Equatable, Sendable {
        let text: String
        /// Global indices into `words` (may be empty for punctuation-only lines).
        let words: Range<Int>
        /// Last meaningful word: once spoken, the line may scroll away.
        let endTrigger: Int
        /// Second-to-last meaningful word: the one-word lookahead used when recognition lags.
        let relaxedTrigger: Int
        /// Sentences (0-based, in answer order) this line belongs to.
        let sentences: ClosedRange<Int>
        var characters: Int { text.count }
    }

    let answer: String
    let layout: CaptionLayout
    let words: [String]
    let sections: [Section]
    /// Exactly what is sent to the glasses for each section (Manual Reading).
    let windows: [String]
    /// The answer as consecutive visual lines (Speech-Synced Reading).
    let lines: [VisualLine]
    /// Window starting at each top line: `layout.lines` consecutive lines, no counter, no context.
    let lineWindows: [String]

    /// `trailingReserve`: characters kept free after the last word (for a rendered end marker), so the
    /// marker never forces an extra row. Only the last line / last section is affected.
    init(answer: String, layout: CaptionLayout, trailingReserve: Int = 0) {
        self.answer = answer
        self.layout = layout
        // Display words; a word that cannot fit in a whole window is split (the only time words are split).
        let capacity = layout.width * layout.lines
        var pieces: [(text: String, tokens: [String])] = []
        var pieceSentence: [Int] = []
        var sentence = 0
        for word in answer.split(whereSeparator: \.isWhitespace).map(String.init) {
            let tokens = ReadingText.tokens(word)
            if word.count <= capacity {
                pieces.append((word, tokens)); pieceSentence.append(sentence)
            } else {
                var rest = Substring(word), first = true
                while !rest.isEmpty {
                    pieces.append((String(rest.prefix(capacity)), first ? tokens : [])); pieceSentence.append(sentence)
                    rest = rest.dropFirst(capacity); first = false
                }
            }
            if Self.endsSentence(word) { sentence += 1 }
        }

        var words: [String] = []
        var cores: [[String]] = []
        var contexts: [String?] = []
        var sections: [Section] = []
        var start = 0
        while start < pieces.count {
            var context = layout.contextLine && !cores.isEmpty ? Self.contextTail(cores[cores.count - 1], width: layout.width - 2) : nil
            var end = Self.fill(pieces.map(\.text), from: start, prefix: context.map { ["\u{2026}"] + $0 } ?? [], layout: layout, reserve: trailingReserve)
            if end == start, context != nil { // context must never cost the window its first word
                context = nil
                end = Self.fill(pieces.map(\.text), from: start, prefix: [], layout: layout, reserve: trailingReserve)
            }
            end = max(end, start + 1)
            // Prefer a sentence end that keeps the frame at least 60% full, otherwise a clause boundary
            // (",", ";", ":", "—") that keeps it at least 60% full; never overflow to keep a sentence together.
            if end < pieces.count {
                let span = end - start
                if let boundary = (start..<(end - 1)).last(where: { Self.endsSentence(pieces[$0].text) }),
                   Double(boundary + 1 - start) >= Double(span) * 0.6 {
                    end = boundary + 1
                } else if let boundary = (start..<(end - 1)).last(where: { Self.endsClause(pieces[$0].text) || pieces[$0 + 1].text == "\u{2014}" }),
                          Double(boundary + 1 - start) >= Double(span) * 0.6 {
                    end = boundary + 1
                }
            }
            let slice = pieces[start..<end]
            let tokens = slice.flatMap(\.tokens)
            let range = words.count..<(words.count + tokens.count)
            words += tokens
            let meaningful = range.filter { ReadingText.isContent(words[$0]) }
            let trigger = meaningful.last ?? (range.isEmpty ? range.lowerBound - 1 : range.upperBound - 1)
            sections.append(Section(text: slice.map(\.text).joined(separator: " "), words: range, endTrigger: trigger,
                                    relaxedTrigger: meaningful.count >= 2 ? meaningful[meaningful.count - 2] : trigger))
            cores.append(slice.map(\.text))
            contexts.append(context.map { ["\u{2026}"] + $0 }?.joined(separator: " "))
            start = end
        }

        self.words = words
        self.sections = sections
        let total = sections.count
        windows = sections.indices.map { index in
            let base = [contexts[index], sections[index].text].compactMap { $0 }.joined(separator: " ")
            guard layout.pageCounter, total > 1 else { return base }
            let counted = base + " (\(index + 1)/\(total))"
            return layout.wrap(counted).count <= layout.lines ? counted : base
        }

        // Visual lines over the same pieces and the same global word indices.
        var lines: [VisualLine] = []
        var current: [(text: String, tokens: [String], sentence: Int)] = []
        var tokenIndex = 0
        func flush() {
            guard !current.isEmpty else { return }
            let count = current.reduce(0) { $0 + $1.tokens.count }
            let range = tokenIndex..<(tokenIndex + count)
            tokenIndex += count
            let meaningful = range.filter { ReadingText.isContent(words[$0]) }
            let end = meaningful.last ?? range.upperBound - 1
            lines.append(VisualLine(text: current.map(\.text).joined(separator: " "), words: range, endTrigger: end,
                                    relaxedTrigger: meaningful.count >= 2 ? meaningful[meaningful.count - 2] : end,
                                    sentences: current.first!.sentence...current.last!.sentence))
            current = []
        }
        for (index, piece) in pieces.enumerated() {
            var chunks: [String] = []
            var rest = Substring(piece.text)
            while rest.count > layout.width { chunks.append(String(rest.prefix(layout.width))); rest = rest.dropFirst(layout.width) }
            if !rest.isEmpty || chunks.isEmpty { chunks.append(String(rest)) }
            for (chunkIndex, chunk) in chunks.enumerated() {
                let length = current.reduce(0) { $0 + $1.text.count + 1 } - 1
                let isLast = index == pieces.count - 1 && chunkIndex == chunks.count - 1
                if !current.isEmpty, length + 1 + chunk.count + (isLast ? trailingReserve : 0) > layout.width { flush() }
                current.append((chunk, chunkIndex == 0 ? piece.tokens : [], pieceSentence[index]))
                if chunks.count > 1, chunkIndex < chunks.count - 1 { flush() }
            }
        }
        flush()
        self.lines = lines
        let span = layout.lines
        lineWindows = lines.isEmpty ? [] : (0...max(0, lines.count - span)).map { top in
            lines[top..<min(lines.count, top + span)].map(\.text).joined(separator: layout.explicitLineBreaks ? "\n" : " ")
        }
    }

    /// The answer's last meaningful word: reaching it means reading is complete.
    var lastMeaningfulWord: Int? { lines.last?.endTrigger ?? sections.last?.endTrigger }

    func line(containing word: Int) -> Int? {
        lines.firstIndex { $0.words.contains(word) }
    }

    func section(containing word: Int) -> Int? {
        sections.firstIndex { $0.words.contains(word) }
    }

    /// Largest end index such that prefix + pieces[start..<end] wraps within the line limit.
    private static func fill(_ pieces: [String], from start: Int, prefix: [String], layout: CaptionLayout, reserve: Int = 0) -> Int {
        var end = start
        // The final piece must also leave room for the reserved marker (as a placeholder word).
        func marker(_ end: Int) -> [String] { end == pieces.count - 1 && reserve > 1 ? [String(repeating: "x", count: reserve - 1)] : [] }
        while end < pieces.count, layout.fits(prefix + Array(pieces[start...end]) + marker(end)) { end += 1 }
        return end
    }

    private static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:".contains(last) || word.hasSuffix("\u{2014}")
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')\u{201D}\u{2019}")).last else { return false }
        return ".?!".contains(last)
    }

    /// The previous window's last words that fit on one line (after the "…" marker).
    static func contextTail(_ words: [String], width: Int) -> [String]? {
        var tail: [String] = []
        for word in words.reversed() {
            let length = tail.reduce(0) { $0 + $1.count + 1 } + word.count
            if length > width - 1 { break }
            tail.insert(word, at: 0)
        }
        return tail.isEmpty ? nil : tail
    }
}

/// Incremental word-level alignment of live speech against the expected answer.
///
/// Each transcript update is aligned with a bounded local sequence alignment (Smith-Waterman style)
/// between the newest heard words and the next `lookAhead` expected words after a monotonic cursor.
/// The cursor moves only on ordered, multi-word, mostly-content evidence near the current position,
/// so silence, filler, re-reading, or unrelated talk that shares vocabulary cannot move it.
nonisolated struct ReadingAlignment: Sendable {
    struct Update: Equatable, Sendable {
        var accepted: Bool
        var cursor: Int
        var confidence: Double
        var reason: String
        /// Words were heard after the last matched word (used for the relaxed end-of-section rule).
        var heardBeyondMatch: Bool
        /// How many heard words follow the last matched word in the current utterance.
        var heardBeyond: Int = 0
        /// New words confirmed by this update.
        var matched: Int = 0
    }

    struct Path: Equatable, Sendable {
        var score = 0.0
        /// Matches on already-confirmed anchor words (context only, never counted as progress).
        var anchorMatched = 0
        /// New evidence: matches beyond the cursor.
        var matched = 0, matchedContent = 0, matchedWeight = 0.0, expectedSpanWeight = 0.0
        var firstNewExpected = -1, lastExpected = 0, firstHeard = 0, lastHeard = 0
    }

    let plan: ReadingPlan
    private(set) var cursor = -1
    private(set) var confidence = 0.0
    private(set) var lastReason = "Waiting for speech"
    private var lastAccepted: Date?
    /// Tokens of the current (possibly still revising) utterance, and how many of them were already aligned.
    private var utterance: [String] = []
    private var consumed = 0

    var lookAhead = 30
    var maxSkip = 10
    var responsiveness: ReadingResponsiveness = .balanced
    var heardWindow = 24
    var continuationWindow: TimeInterval = 20

    init(plan: ReadingPlan) { self.plan = plan }

    var progress: Double { plan.words.isEmpty ? 0 : Double(cursor + 1) / Double(plan.words.count) }

    mutating func ingest(_ text: String, isFinal: Bool, speaker: SpeakerLabel, at now: Date) -> Update {
        let tokens = ReadingText.tokens(text)
        var acceptedMatches = 0
        // A revised partial only re-opens words that actually changed: aligned words are never counted twice.
        let unchanged = zip(utterance, tokens).prefix { $0 == $1 }.count
        consumed = min(consumed, unchanged)
        utterance = tokens
        defer { if isFinal { utterance = []; consumed = 0 } }

        func result(_ accepted: Bool, _ reason: String) -> Update {
            lastReason = reason
            return Update(accepted: accepted, cursor: cursor, confidence: confidence, reason: reason,
                          // Only words after a match made in THIS utterance count as "beyond the match".
                          heardBeyondMatch: consumed > 0 && tokens.count > consumed,
                          heardBeyond: consumed > 0 ? tokens.count - consumed : 0,
                          matched: accepted ? acceptedMatches : 0)
        }
        guard cursor + 1 < plan.words.count else { return result(false, "End of answer reached") }
        guard tokens.count > consumed else { return result(false, "No new words") }

        // Continuity: the last confirmed words (and the heard words that matched them) are included as an
        // anchor, so "...reaching the | backend" can confirm a single new word. Never for a likely interviewer.
        let recent = lastAccepted.map { now.timeIntervalSince($0) <= continuationWindow } ?? false
        let canAnchor = cursor >= 0 && recent && speaker != .interviewer
        let anchor = canAnchor ? min(3, cursor + 1) : 0
        let heardStart = max(consumed > 0 ? consumed - anchor : 0, tokens.count - heardWindow, 0)
        let heard = Array(tokens[heardStart...])
        let windowStart = cursor + 1 - anchor
        let expected = Array(plan.words[windowStart..<min(plan.words.count, cursor + 1 + lookAhead)])

        let (nearest, anyMatch) = Self.align(heard: heard, expected: expected, anchor: anchor, maxSkip: maxSkip)
        guard let path = nearest else {
            return result(false, anyMatch ? "Nearest match is more than \(maxSkip) words ahead; holding" : "No ordered match with the upcoming text")
        }
        let skipped = path.firstNewExpected - anchor
        let connected = path.anchorMatched > 0 && skipped <= 2
        let continuation = canAnchor && skipped <= 2
        // Uncertain speakers need more evidence; a likely interviewer needs much more.
        var need: (words: Int, content: Int) = connected ? (1, 1) : continuation ? (2, 1)
            : speaker == .interviewer ? (6, 4) : speaker == .wearer ? (3, 2) : (4, 3)
        switch responsiveness {
        case .conservative: need = (need.words + 1, need.content + (connected ? 0 : 1))
        case .balanced: break
        case .responsive where !connected && !continuation && speaker != .interviewer:
            need = (max(3, need.words - 1), max(2, need.content - 1))
        case .responsive: break
        }
        let coverage = path.expectedSpanWeight > 0 ? path.matchedWeight / path.expectedSpanWeight : 0
        let density = Double(path.matched + path.anchorMatched) / Double(path.lastHeard - path.firstHeard + 1)

        if path.matched < need.words || path.matchedContent < need.content {
            return result(false, "Too little evidence: \(path.matched) words / \(path.matchedContent) meaningful (need \(need.words)/\(need.content))")
        }
        if coverage < 0.45 { return result(false, String(format: "Sparse match against the answer (%.2f)", coverage)) }
        if density < 0.4 { return result(false, String(format: "Sparse match in speech (%.2f)", density)) }

        cursor = windowStart + path.lastExpected
        consumed = heardStart + path.lastHeard + 1
        acceptedMatches = path.matched
        confidence = min(1, 0.5 * min(1, coverage) + 0.5 * min(1, density))
        lastAccepted = now
        return result(true, "Matched \(path.matched) new words (\(path.matchedContent) meaningful)\(connected ? ", continuing" : "")")
    }

    /// The window the display should show, never behind `displayed`. Advances past a section only when the
    /// cursor reached its last meaningful word, or its second-to-last at the end of an utterance.
    func suggestedSection(displayed: Int, utteranceEnded: Bool) -> Int {
        var section = displayed
        while section < plan.sections.count - 1 {
            let current = plan.sections[section]
            let trigger = utteranceEnded ? current.relaxedTrigger : current.endTrigger
            guard cursor >= trigger else { break }
            section += 1
        }
        return section
    }

    /// First visual line not yet finished, never behind `current` and never past `maxTop`.
    /// A line is finished when its last meaningful word is confirmed, or its second-to-last when the
    /// recogniser has already heard more words after the match (one-word lookahead, by responsiveness).
    /// The lookahead only covers a short unconfirmed tail (a misrecognised last word or two): at least as
    /// many words must have been heard after the match, in the same utterance, as remain in the line.
    func suggestedTopLine(current: Int, maxTop: Int, heardBeyond: Int, utteranceEnded: Bool) -> Int {
        var top = current
        while top < maxTop, plan.lines.indices.contains(top) {
            let line = plan.lines[top]
            if cursor >= line.endTrigger { top += 1; continue }
            let remaining = line.words.upperBound - 1 - cursor
            let lookahead = cursor >= line.relaxedTrigger && heardBeyond >= remaining && remaining >= 1 && {
                switch responsiveness {
                case .conservative: return utteranceEnded && remaining <= 2
                case .balanced: return remaining <= 2 && (utteranceEnded || heardBeyond >= 2)
                case .responsive: return remaining <= 3
                }
            }()
            guard lookahead else { break }
            top += 1
        }
        return top
    }

    /// Lines of look-ahead kept below the line being read before the window jumps.
    var lookaheadLines: Int { responsiveness == .conservative ? 1 : 2 }

    /// Look-ahead teleprompter (overlapping windows; only with verified frame replacement). The window keeps
    /// the line being read plus `lookaheadLines` unread lines below it; once fewer remain it jumps so the
    /// line being read becomes the top line — the words being spoken stay visible. Moves only forward and
    /// never past the last full window. Responsive treats the last two words of a line as the next line
    /// for *when* to move, never for *where*.
    func lookaheadTop(current top: Int, window: Int, maxTop: Int, strongEvidence: Bool) -> Int {
        guard cursor >= 0, !plan.lines.isEmpty, let reading = plan.line(containing: min(cursor + 1, plan.words.count - 1)) else { return top }
        var effective = reading
        if responsiveness == .responsive, plan.lines[reading].words.upperBound - 1 - cursor <= 2 { effective += 1 }
        let unreadBelow = top + window - 1 - effective
        let target = min(reading, maxTop)
        guard unreadBelow < lookaheadLines, target > top else { return top }
        // Reading text that was never on screen needs strong evidence (a fast reader, not a misalignment).
        if reading > top + window - 1, !strongEvidence { return min(top + window - lookaheadLines, maxTop) }
        return target
    }

    /// Sentence Frames: the next frame once the current frame's last meaningful word was read, or — like the
    /// line lookahead — its second-to-last when at least the remaining words were already heard (partials
    /// count; silence alone never advances). Moves one frame at a time.
    func suggestedFrame(displayed: Int, heardBeyond: Int, utteranceEnded: Bool) -> Int {
        guard plan.sections.indices.contains(displayed), displayed < plan.sections.count - 1 else { return displayed }
        let frame = plan.sections[displayed]
        if cursor >= frame.endTrigger { return displayed + 1 }
        let remaining = frame.words.upperBound - 1 - cursor
        let lookahead = cursor >= frame.relaxedTrigger && remaining >= 1 && heardBeyond >= remaining && {
            switch responsiveness {
            case .conservative: return utteranceEnded && remaining <= 2
            case .balanced: return remaining <= 2 && (utteranceEnded || heardBeyond >= 2)
            case .responsive: return remaining <= 3
            }
        }()
        return lookahead ? displayed + 1 : displayed
    }

    /// Keeps progress when the same answer grows (a provisional first frame replaced by the full answer).
    mutating func continueFrom(_ previous: ReadingAlignment) {
        guard previous.plan.words.count <= plan.words.count,
              Array(plan.words.prefix(previous.plan.words.count)) == previous.plan.words else { return }
        cursor = previous.cursor
        confidence = previous.confidence
        lastAccepted = previous.lastAccepted
        lastReason = "Continued: answer completed while reading"
    }

    /// Manual line navigation: the reader starts the given visual line from its beginning.
    mutating func moveCursor(toStartOfLine line: Int) {
        guard plan.lines.indices.contains(line) else { return }
        cursor = plan.lines[line].words.lowerBound - 1
        utterance = []; consumed = 0; lastAccepted = nil
        lastReason = "Moved to line \(line + 1)"
    }

    /// Manual navigation: the reader starts the given section from its beginning.
    mutating func moveCursor(toStartOf section: Int) {
        guard plan.sections.indices.contains(section) else { return }
        cursor = plan.sections[section].words.lowerBound - 1
        utterance = []; consumed = 0; lastAccepted = nil
        lastReason = "Moved to section \(section + 1)"
    }

    mutating func reset() { moveCursor(toStartOf: 0); confidence = 0; lastReason = "Reset" }

    /// Local alignment of heard words against expected words, whose first `anchor` entries are already
    /// confirmed. Returns the best path with new evidence starting within `maxSkip` words of the cursor
    /// (closest preferred, which disambiguates repeated phrases), and whether any new match existed at all.
    static func align(heard: [String], expected: [String], anchor: Int, maxSkip: Int) -> (Path?, Bool) {
        guard !heard.isEmpty, expected.count > anchor else { return (nil, false) }
        let rows = heard.count + 1, columns = expected.count + 1
        var grid = Array(repeating: Array(repeating: Path(), count: columns), count: rows)
        var best: Path?
        var bestValue = -Double.infinity
        var anyMatch = false
        for i in 1..<rows {
            for j in 1..<columns {
                let word = expected[j - 1]
                let isNew = j - 1 >= anchor
                let weight = ReadingText.isContent(word) ? 1.0 : 0.3
                let similarity = ReadingText.similarity(heard[i - 1], word)
                var cell = Path()
                let diagonal = grid[i - 1][j - 1]
                if similarity > 0 {
                    var next = diagonal.score > 0 ? diagonal : Path(firstHeard: i - 1)
                    next.score += 2 * weight * similarity
                    if isNew {
                        next.matched += 1
                        next.matchedContent += weight == 1 ? 1 : 0
                        next.matchedWeight += weight * similarity
                        if next.firstNewExpected < 0 { next.firstNewExpected = j - 1 }
                    } else {
                        next.anchorMatched += 1
                    }
                    next.lastExpected = j - 1
                    next.lastHeard = i - 1
                    cell = next
                } else if diagonal.score > 0.6 {
                    cell = diagonal
                    cell.score -= 0.6
                }
                var skipHeard = grid[i - 1][j]
                skipHeard.score -= 0.4
                if skipHeard.score > cell.score { cell = skipHeard }
                var skipExpected = grid[i][j - 1]
                skipExpected.score -= weight == 1 ? 0.5 : 0.2
                if skipExpected.score > cell.score { cell = skipExpected }
                if cell.score <= 0 { cell = Path() }
                grid[i][j] = cell
                guard cell.matched > 0 else { continue }
                anyMatch = true
                let skipped = cell.firstNewExpected - anchor
                guard skipped <= maxSkip else { continue }
                let value = cell.score - 0.06 * Double(skipped)
                if value > bestValue { bestValue = value; best = cell }
            }
        }
        // Coverage is measured over the new region only: firstNewExpected...lastExpected.
        if var path = best {
            path.expectedSpanWeight = expected[path.firstNewExpected...path.lastExpected]
                .reduce(0) { $0 + (ReadingText.isContent($1) ? 1.0 : 0.3) }
            best = path
        }
        return (best, anyMatch)
    }
}

enum ReadingResponsiveness: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative, balanced, responsive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .conservative: "Conservative (advance later)"
        case .balanced: "Balanced (2 lines ahead)"
        case .responsive: "Responsive (advance earlier)"
        }
    }
}
