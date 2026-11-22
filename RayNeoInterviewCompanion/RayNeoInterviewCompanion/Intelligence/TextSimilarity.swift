import Foundation

/// Cheap lexical similarity used for echo suppression and duplicate detection.
nonisolated enum TextSimilarity {
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "with", "by", "from",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those", "i", "you",
        "we", "they", "he", "she", "me", "my", "your", "our", "their", "would", "will", "can", "could", "do",
        "does", "did", "if", "then", "than", "as", "about", "into", "um", "uh", "like", "just", "also", "very",
        "what", "how", "why", "when", "where", "which", "who", "first", "next", "i'd", "i'm", "i'll", "there",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { stem(String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'"))) }
            .filter { !$0.isEmpty }
    }

    static func contentWords(_ text: String) -> [String] {
        words(text).filter { !stopwords.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    /// How much of `fragment` appears inside `reference` (0...1), weighting shared word pairs.
    /// Fragments with fewer than 3 content words return 0: too short to judge.
    static func containment(_ fragment: String, in reference: String) -> Double {
        let content = contentWords(fragment)
        guard content.count >= 3 else { return 0 }
        let referenceWords = Set(contentWords(reference))
        let unigram = Double(content.filter(referenceWords.contains).count) / Double(content.count)
        let fragmentPairs = bigrams(words(fragment))
        let referencePairs = Set(bigrams(words(reference)))
        let bigram = fragmentPairs.isEmpty ? 0 : Double(fragmentPairs.filter(referencePairs.contains).count) / Double(fragmentPairs.count)
        return max(unigram * 0.6 + bigram * 0.4, bigram)
    }

    static func jaccard(_ a: String, _ b: String) -> Double {
        let left = Set(contentWords(a)), right = Set(contentWords(b))
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private static func bigrams(_ words: [String]) -> [String] {
        guard words.count >= 2 else { return [] }
        return (0..<(words.count - 1)).map { words[$0] + " " + words[$0 + 1] }
    }

    // shortcut: suffix stripping, not a real stemmer; good enough for "requests/reaching/checked".
    private static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }
}
