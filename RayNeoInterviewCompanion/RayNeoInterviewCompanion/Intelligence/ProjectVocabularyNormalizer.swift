import Foundation

nonisolated struct ProjectVocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String { canonical }
    var canonical: String
    /// User-approved spellings and pronunciation variants ("Rezonic", "Resnik").
    var aliases: [String]
    /// Words that make this project the likely subject (from its memory).
    var keywords: [String] = []
}

nonisolated struct NormalizedTranscript: Equatable, Sendable {
    struct Replacement: Equatable, Sendable {
        var original: String
        var canonical: String
        var confidence: Double
        var method: String
    }
    var original: String
    var normalized: String
    var replacements: [Replacement]
}

/// Recognises the user's project names in recognised speech. Only replaces when the evidence is strong:
/// an exact name or approved alias, or a close phonetic / spelling match *with* project context (a cue
/// such as "project", "app", "called" nearby, the project already being discussed, or one of its keywords).
/// Ordinary dictionary words are never fuzzily replaced without an explicit cue. The original text is kept.
nonisolated struct ProjectVocabularyNormalizer: Sendable {
    var entries: [ProjectVocabularyEntry]
    var threshold = 0.82

    static let cues: Set<String> = ["project", "projects", "app", "application", "called", "named", "your", "about", "built", "build",
                                    "on", "in", "my", "with", "platform", "dashboard", "site", "tracker"]
    static let strongCues: Set<String> = ["project", "app", "called", "named"]

    /// The contextual strings to give the recognizer (canonical names and aliases).
    var vocabulary: [String] { Array(Set(entries.flatMap { [$0.canonical] + $0.aliases })).sorted() }

    func normalize(_ text: String, context: String = "", isDictionaryWord: (String) -> Bool = { _ in false }) -> NormalizedTranscript {
        let tokens = Self.tokens(in: text)
        let lowerText = text.lowercased(), lowerContext = context.lowercased()
        var candidates: [(range: Range<Int>, entry: ProjectVocabularyEntry, confidence: Double, method: String)] = []
        for start in tokens.indices {
            for length in 1...3 where start + length <= tokens.count {
                let span = tokens[start..<(start + length)]
                let compact = Self.compact(span.map(\.text).joined())
                guard compact.count >= 3 else { continue }
                let before = tokens[max(0, start - 3)..<start].map { $0.text.lowercased() }
                let cue = before.contains { Self.cues.contains($0) }
                let strongCue = before.last.map { Self.strongCues.contains($0) } ?? false
                for entry in entries {
                    let names = [entry.canonical] + entry.aliases
                    let mentioned = names.contains { lowerContext.contains($0.lowercased()) }
                        || entry.keywords.contains { lowerText.contains($0.lowercased()) }
                    if names.contains(where: { Self.compact($0) == compact }) {
                        // An approved alias that is also a dictionary word ("discard") still needs context.
                        let ordinary = length == 1 && compact != Self.compact(entry.canonical) && isDictionaryWord(span.first!.text)
                        if !ordinary || strongCue || mentioned {
                            candidates.append((start..<(start + length), entry, 1.0, "alias"))
                        }
                        continue
                    }
                    guard compact.count >= 4, cue || mentioned else { continue }
                    if length == 1, isDictionaryWord(span.first!.text), !strongCue { continue }
                    let target = Self.compact(entry.canonical)
                    let edit = Self.similarity(compact, target)
                    // "this card" sounds like "Diskarte": ordinary words only merge into a name when spelled closely.
                    if length > 1, span.allSatisfy({ isDictionaryWord($0.text) }), edit < 0.8 { continue }
                    var score = edit
                    if edit >= 0.5, Self.phoneticKey(compact) == Self.phoneticKey(target) { score = max(score, 0.86) }
                    score += (strongCue ? 0.06 : 0) + (mentioned ? 0.06 : 0)
                    if score >= threshold { candidates.append((start..<(start + length), entry, min(0.99, score), "phonetic/edit")) }
                }
            }
        }
        // Best non-overlapping spans: highest confidence, then longest.
        var chosen: [(range: Range<Int>, entry: ProjectVocabularyEntry, confidence: Double, method: String)] = []
        for candidate in candidates.sorted(by: { ($0.confidence, $0.range.count) > ($1.confidence, $1.range.count) })
        where !chosen.contains(where: { $0.range.overlaps(candidate.range) }) {
            chosen.append(candidate)
        }
        var result = text
        var replacements: [NormalizedTranscript.Replacement] = []
        for candidate in chosen.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let first = tokens[candidate.range.lowerBound].range, last = tokens[candidate.range.upperBound - 1].range
            let original = String(text[first.lowerBound..<last.upperBound])
            guard original != candidate.entry.canonical else { continue }
            result.replaceSubrange(first.lowerBound..<last.upperBound, with: candidate.entry.canonical)
            replacements.insert(.init(original: original, canonical: candidate.entry.canonical, confidence: candidate.confidence,
                                      method: candidate.method), at: 0)
        }
        return NormalizedTranscript(original: text, normalized: result, replacements: replacements)
    }

    // MARK: Matching

    struct Token { var text: String; var range: Range<String.Index> }

    static func tokens(in text: String) -> [Token] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9']*"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { Token(text: String(text[$0]), range: $0) }
        }
    }

    static func compact(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// 1 − normalised Levenshtein distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// A consonant skeleton that treats c/k/q, s/z/x, f/v/ph, d/t, b/p and m/n alike and drops vowels
    /// after the first letter: "Rezonic", "Resnik" and "Resoniq" all become "rsnk".
    static func phoneticKey(_ word: String) -> String {
        let chars = Array(word.lowercased().filter(\.isLetter))
        var mapped: [Character] = []
        var index = 0
        while index < chars.count {
            let c = chars[index], next = index + 1 < chars.count ? chars[index + 1] : nil
            if c == "p", next == "h" { mapped.append("f"); index += 2; continue }
            if c == "c", next == "k" { mapped.append("k"); index += 2; continue }
            switch c {
            case "c", "k", "q": mapped.append("k")
            case "s", "z", "x": mapped.append("s")
            case "f", "v": mapped.append("f")
            case "d", "t": mapped.append("t")
            case "b", "p": mapped.append("p")
            case "m", "n": mapped.append("n")
            default: mapped.append(c)
            }
            index += 1
        }
        var key = ""
        var previous: Character?
        for (position, c) in mapped.enumerated() {
            if position > 0, "aeiouhwy".contains(c) { continue }
            if c == previous { continue }
            key.append(c)
            previous = c
        }
        return key
    }
}
