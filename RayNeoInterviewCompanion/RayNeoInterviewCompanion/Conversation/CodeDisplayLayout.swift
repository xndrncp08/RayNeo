import Foundation

/// How code is laid out on the lens — separate from the explanation (sentence) layout. Saved after the
/// wearer confirms it on the RayNeo with the Code Display Calibration patterns; nothing here assumes the
/// lens shows more than the calibrated rows.
nonisolated struct CodeDisplayLayout: Codable, Equatable, Sendable {
    /// Rows of code per frame (never more than the lens rows calibrated for captions).
    var rows = 5
    /// Characters that fit on one lens row in code (monospace-ish symbols included).
    var charactersPerRow = 48
    /// Spaces per indentation level on the lens (the source keeps its own).
    var indentSpaces = 2
    /// The wearer confirmed this layout with the calibration patterns on the glasses.
    var verified = false
    var verifiedAt: Date?

    init(rows: Int = 5, charactersPerRow: Int = 48, indentSpaces: Int = 2) {
        self.rows = rows
        self.charactersPerRow = charactersPerRow
        self.indentSpaces = indentSpaces
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 5
        charactersPerRow = try container.decodeIfPresent(Int.self, forKey: .charactersPerRow) ?? 48
        indentSpaces = try container.decodeIfPresent(Int.self, forKey: .indentSpaces) ?? 2
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        verifiedAt = try container.decodeIfPresent(Date.self, forKey: .verifiedAt)
    }
}

/// Code-specific wrapping and pagination (never the sentence wrapper). Every character of the code
/// survives in order; only indentation is compressed and blank lines are dropped on the lens.
nonisolated enum CodePaginator {
    struct Row: Equatable, Sendable {
        var text: String
        /// Index of the source line this row belongs to (wrapped rows share it).
        var line: Int
        var continuation: Bool
        /// The row had to be cut inside a token or string (no safe boundary within the width).
        var hardBreak: Bool
    }

    struct Page: Equatable, Sendable {
        var rows: [String]
        var part: Int
        var parts: Int
    }

    struct Report: Equatable, Sendable {
        var sourceLines: Int
        var rows: Int
        var pages: Int
        var hardBreaks: Int
        var summary: String { "\(sourceLines) lines → \(rows) rows → \(pages) page(s), \(hardBreaks) hard break(s)" }
    }

    static let continuationMark = "» "

    /// Lens rows: indentation re-expressed as `indentSpaces` per level; a line longer than `width` breaks
    /// at the last safe boundary outside string literals (a space, or after , ; ( [ { or before a . of a
    /// method chain), and only as a last resort inside a token. Continuations start with "» ".
    static func rows(_ code: String, width: Int, indentSpaces: Int = 2) -> [Row] {
        let lines = code.components(separatedBy: "\n")
        let unit = lines.map { $0.prefix(while: { $0 == " " }).count }.filter { $0 > 0 }.min() ?? 0
        var result: [Row] = []
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let leading = line.prefix(while: { $0 == " " }).count
            let level = unit == 0 ? 0 : leading / unit
            let indent = String(repeating: " ", count: min(width / 3, level * indentSpaces))
            var rest = Array(line.dropFirst(leading))
            var first = true
            while !rest.isEmpty {
                let prefix = first ? indent : indent + continuationMark
                let room = max(8, width - prefix.count)
                var cut = rest.count
                var hard = false
                if rest.count > room {
                    if let safe = safeBreak(rest, limit: room) { cut = safe } else { cut = room; hard = true }
                }
                let piece = String(rest[..<cut])
                result.append(Row(text: prefix + piece.trimmingCharacters(in: .init(charactersIn: " ")), line: index,
                                  continuation: !first, hardBreak: hard))
                rest = Array(rest[cut...].drop(while: { $0 == " " }))
                first = false
            }
        }
        return result
    }

    /// The last boundary ≤ limit outside a string literal, keeping at least a third of the row.
    static func safeBreak(_ characters: [Character], limit: Int) -> Int? {
        var quote: Character?
        var escaped = false
        var best: Int?
        for (index, character) in characters.enumerated() {
            if index >= limit { break }
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
                continue
            }
            if "\"'`".contains(character) { quote = character; continue }
            if character == " " { best = index + 1 }
            else if ",;([{".contains(character) { best = index + 1 }
            else if character == ".", index > 0, characters[index - 1] != ".", index + 1 < characters.count, characters[index + 1].isLetter { best = index }
        }
        guard let best, best >= limit / 3 else { return nil }
        return best
    }

    /// Pages of at most `layout.rows` rows. Wrapped rows of one source line stay on the same page unless the
    /// line alone is taller than a page. A multi-page block gets a compact "(k/N)" on its last row when it
    /// fits, otherwise on a row of its own; a single-page block gets no label at all.
    static func paginate(_ code: String, layout: CodeDisplayLayout) -> (pages: [Page], report: Report) {
        let width = layout.charactersPerRow
        let all = rows(code, width: width, indentSpaces: layout.indentSpaces)
        let capacity = max(1, layout.rows)
        func split(_ capacity: Int) -> [[String]] {
            var pages: [[String]] = [], current: [String] = []
            var index = 0
            while index < all.count {
                let line = all[index].line
                let group = all[index...].prefix { $0.line == line }.map(\.text)
                if !current.isEmpty, current.count + group.count > capacity { pages.append(current); current = [] }
                for row in group {
                    if current.count == capacity { pages.append(current); current = [] }
                    current.append(row)
                }
                index += group.count
            }
            if !current.isEmpty || pages.isEmpty { pages.append(current) }
            return pages
        }
        var chunks = split(capacity)
        if chunks.count > 1 {
            // Labels must not overflow: re-split with one row free when a label cannot share a row.
            let labelled = chunks.enumerated().allSatisfy { (index, rows) in
                rows.count < capacity || (rows.last?.count ?? 0) + label(index, chunks.count).count + 1 <= width
            }
            if !labelled { chunks = split(max(1, capacity - 1)) }
        }
        let pages = chunks.enumerated().map { index, rows -> Page in
            guard chunks.count > 1 else { return Page(rows: rows, part: 0, parts: 1) }
            var rows = rows
            let tag = label(index, chunks.count)
            if let last = rows.last, last.count + tag.count + 1 <= width { rows[rows.count - 1] = last + " " + tag } else { rows.append(tag) }
            return Page(rows: rows, part: index, parts: chunks.count)
        }
        let report = Report(sourceLines: code.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count,
                            rows: all.count, pages: pages.count, hardBreaks: all.filter(\.hardBreak).count)
        return (pages, report)
    }

    static func label(_ index: Int, _ count: Int) -> String { "(\(index + 1)/\(count))" }
}
