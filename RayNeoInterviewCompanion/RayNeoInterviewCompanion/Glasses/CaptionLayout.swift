import Foundation

/// Conservative model of the RayNeo caption area: a fixed number of rendered lines of roughly
/// `charactersPerLine` characters, filled by greedy word wrapping. The real firmware wraps with its own
/// (unknown) font metrics, so the defaults leave a line of margin and are calibrated on the device.
nonisolated struct CaptionLayout: Codable, Equatable, Sendable {
    /// Lines the app may fill. The lens shows about five; four leaves a safety line.
    var maxLines = 4
    /// The iO-E081 photo shows rows of ~55–60 characters at font_size 2; 48 leaves a margin.
    var charactersPerLine = 48
    /// Show the last few words of the previous window as a "… context" first line.
    var contextLine = false
    /// Append " (k/N)" only when it still fits within `maxLines`.
    var pageCounter = true
    /// Caption config `font_size` (OpenRayneo default 2 is the device-verified value; others are experimental).
    var fontSize = 2
    /// Caption text `status`: 1 = final (device-verified), 0 = in progress (experimental).
    var finalStatus = true
    /// Join visual lines with "\n" instead of spaces. Only safe once the newline test showed the lens keeps
    /// separate rows: if the firmware dropped newlines, the words either side would touch.
    var explicitLineBreaks = false

    static let standard = CaptionLayout()

    init(maxLines: Int = 4, charactersPerLine: Int = 48, contextLine: Bool = false, pageCounter: Bool = true,
         fontSize: Int = 2, finalStatus: Bool = true, explicitLineBreaks: Bool = false) {
        self.maxLines = maxLines
        self.charactersPerLine = charactersPerLine
        self.contextLine = contextLine
        self.pageCounter = pageCounter
        self.fontSize = fontSize
        self.finalStatus = finalStatus
        self.explicitLineBreaks = explicitLineBreaks
    }

    /// Tolerant decoding: fields added later never reset a saved calibration.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptionLayout()
        maxLines = try container.decodeIfPresent(Int.self, forKey: .maxLines) ?? defaults.maxLines
        charactersPerLine = try container.decodeIfPresent(Int.self, forKey: .charactersPerLine) ?? defaults.charactersPerLine
        contextLine = try container.decodeIfPresent(Bool.self, forKey: .contextLine) ?? defaults.contextLine
        pageCounter = try container.decodeIfPresent(Bool.self, forKey: .pageCounter) ?? defaults.pageCounter
        fontSize = try container.decodeIfPresent(Int.self, forKey: .fontSize) ?? defaults.fontSize
        finalStatus = try container.decodeIfPresent(Bool.self, forKey: .finalStatus) ?? defaults.finalStatus
        explicitLineBreaks = try container.decodeIfPresent(Bool.self, forKey: .explicitLineBreaks) ?? defaults.explicitLineBreaks
    }

    var width: Int { max(charactersPerLine, 8) }
    var lines: Int { max(maxLines, 1) }

    /// Greedy word wrap. A word wider than a line is hard-broken: the only case where a word is split.
    func wrap(_ words: [String]) -> [String] {
        var result: [String] = []
        var line = ""
        for word in words {
            var rest = word
            while rest.count > width {
                if !line.isEmpty { result.append(line); line = "" }
                result.append(String(rest.prefix(width)))
                rest = String(rest.dropFirst(width))
            }
            guard !rest.isEmpty else { continue }
            if line.isEmpty { line = rest }
            else if line.count + 1 + rest.count <= width { line += " " + rest }
            else { result.append(line); line = rest }
        }
        if !line.isEmpty { result.append(line) }
        return result
    }

    func wrap(_ text: String) -> [String] { wrap(text.split(whereSeparator: \.isWhitespace).map(String.init)) }

    func fits(_ words: [String]) -> Bool { wrap(words).count <= lines }
}

/// Calibration captions, sent through the same verified 0x13 caption path as answers.
nonisolated enum CaptionCalibration {
    /// Six numbered rows, each padded to exactly `charactersPerLine` so a matching wrap puts one per row.
    /// Which numbers are fully visible shows both the visible line count and whether the lens keeps the
    /// first or the last lines of an over-long caption.
    static func numberedLines(_ layout: CaptionLayout, count: Int = 6) -> String {
        (1...count).map { index in
            var row = layout.width >= 16 ? "LINE \(index) — VISIBLE" : "L\(index)"
            while row.count + 2 <= layout.width { row += " \u{00B7}" }
            return row
        }.joined(separator: " ")
    }

    /// "0005 0010 0015 …": each number is the column of the space after it, so the last number fully
    /// shown on the first row ≈ characters per line.
    static let ruler = stride(from: 5, through: 80, by: 5).map { String(format: "%04d", $0) }.joined(separator: " ")

    static let replaceFirst = "REPLACE TEST A — if you can still see this after B appears, captions are appending"
    static let replaceSecond = "REPLACE TEST B — only this line should be visible"
    /// Junction: if the lens shows "BRAVOCHARLIE", consecutive captions are concatenated without a space.
    static let junctionFirst = "ALPHA BRAVO"
    static let junctionSecond = "CHARLIE DELTA"
    /// Newline: three separate rows means "\n" is respected; "ROW ONEROW TWO" means it is dropped.
    static let newlines = "ROW ONE\nROW TWO\nROW THREE"
    static let shortCaption = "SHORT CAPTION"

    static let endMarkerTest = "End marker test. Check mark: \u{2713} ASCII: [END]"
    static let sampleAnswer = "I'd start by checking whether the account is active and whether the user has the right license. Then I'd look at the Microsoft Entra ID sign-in logs to see if it's a password issue, an MFA problem, or a conditional access policy blocking them. Once I've fixed it, I'd have them sign in again to confirm."
}
