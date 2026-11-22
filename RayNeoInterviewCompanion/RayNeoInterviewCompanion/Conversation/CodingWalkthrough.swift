import Foundation

/// One block of a guided coding answer: EXPLAIN → CODE → EXPLAIN → CODE → … → RESULT.
nonisolated struct WalkthroughBlock: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case explanation, code, example, test, result
        var isCode: Bool { self == .code || self == .example || self == .test }
        var label: String {
            switch self {
            case .explanation: "Explain"
            case .code: "Code"
            case .example: "Example"
            case .test: "Test"
            case .result: "Result"
            }
        }
    }

    /// Stable within its walkthrough: "<walkthrough id>-b<index>".
    let id: String
    let index: Int
    let kind: Kind
    /// Spoken sentences (explanation/result) or code with indentation preserved.
    let text: String
    let language: String?
    /// Intermediate code may be a partial stage; the last code block is the complete solution.
    var isComplete = false
}

/// One logical coding answer laid out as an ordered timeline. Generated in a single model request,
/// shared by the iPhone and the glasses so both always show the same block.
nonisolated struct CodingWalkthrough: Equatable, Sendable {
    let id: String
    var language: String
    var taskID: String?
    var answerID: Int
    var blocks: [WalkthroughBlock]
    var edgeCases: [String] = []
    var complexity: String?
    /// Implementation steps when the model listed them separately (older single-CODE format).
    var steps: [String] = []

    var finalCode: String? { blocks.last(where: { $0.kind == .code })?.text }
    /// Explanation and result blocks, in order: the spoken part of the answer.
    var spokenText: String { blocks.filter { !$0.kind.isCode }.map(\.text).joined(separator: " ") }
    var tests: [String] { blocks.filter { $0.kind == .test }.map(\.text) }

    func previous(of block: WalkthroughBlock) -> WalkthroughBlock? { block.index > 0 ? blocks[block.index - 1] : nil }
    func next(of block: WalkthroughBlock) -> WalkthroughBlock? { block.index + 1 < blocks.count ? blocks[block.index + 1] : nil }

    /// "TESTS" and "STEPS" come from the older single-CODE format and are accepted as a repair.
    static let labels = ["EXPLAIN", "CODE", "EXAMPLE", "TESTS", "TEST", "RESULT", "EDGE CASES", "COMPLEXITY", "STEPS"]

    /// What the model is asked to produce (one request for the whole walkthrough).
    static func formatInstruction(language: String) -> String {
        """
        Answer as ONE guided walkthrough. Start every block with its label alone at the start of a line:
        EXPLAIN: one or two short spoken sentences ("First, I'd…").
        CODE: the \(language) code built so far. Each CODE block repeats the previous code and adds the next part, keeping every name it introduced; the last CODE block is the complete working solution.
        Alternate EXPLAIN and CODE (2 or 3 CODE blocks for a small task) and end with RESULT: one sentence on what the code returns.
        Optionally TEST: one to three example calls with their expected results. Then EDGE CASES: one line, and COMPLEXITY: one line when useful.
        Write all code in \(language) only. Never wrap it in another language or call another language's runtime. No Markdown fences, lines under 44 characters. Never claim the code was run or tested.
        """
    }

    /// Parses labelled blocks. Lenient repairs: stray Markdown fences are removed and text before the
    /// first label becomes the first explanation. Returns nil when there is no code at all.
    static func parse(_ raw: String, language: String, answerID: Int = 0, taskID: String? = nil) -> CodingWalkthrough? {
        var items: [(label: String, lines: [String])] = []
        for line in raw.components(separatedBy: .newlines) {
            if let label = labels.first(where: { line.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix($0 + ":") }) {
                let rest = line.trimmingCharacters(in: .whitespaces).dropFirst(label.count + 1)
                items.append((label, rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [String(rest).trimmingCharacters(in: .whitespaces)]))
            } else if items.isEmpty {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { items.append(("EXPLAIN", [line])) }
            } else if !line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                items[items.count - 1].lines.append(line)
            }
        }
        let id = "w\(answerID)"
        var blocks: [WalkthroughBlock] = []
        var edgeCases: [String] = [], complexity: String?, steps: [String] = []
        for item in items {
            switch item.label {
            case "STEPS":
                steps += item.lines.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^(\d{1,2}[.)]|[-*])\s*"#, with: "", options: .regularExpression) }
                    .filter { !$0.isEmpty }
                continue
            case "EDGE CASES":
                edgeCases += item.lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")) }.filter { !$0.isEmpty }
                continue
            case "COMPLEXITY":
                complexity = item.lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                continue
            default: break
            }
            let kind: WalkthroughBlock.Kind = switch item.label {
            case "CODE": .code
            case "EXAMPLE": .example
            case "TEST", "TESTS": .test
            case "RESULT": .result
            default: .explanation
            }
            let text = kind.isCode ? Self.cleanCode(item.lines) : AnswerFormatter.spoken(item.lines.joined(separator: " "))
            guard !text.isEmpty else { continue }
            blocks.append(WalkthroughBlock(id: "\(id)-b\(blocks.count)", index: blocks.count, kind: kind, text: text,
                                           language: kind.isCode ? language : nil))
        }
        guard blocks.contains(where: { $0.kind == .code }) else { return nil }
        if let last = blocks.lastIndex(where: { $0.kind == .code }) { blocks[last].isComplete = true }
        return CodingWalkthrough(id: id, language: language, taskID: taskID, answerID: answerID, blocks: blocks,
                                 edgeCases: edgeCases, complexity: complexity, steps: steps)
    }

    static func cleanCode(_ lines: [String]) -> String {
        let cleaned = lines.map { $0.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        return Array(cleaned.drop(while: \.isEmpty).reversed().drop(while: \.isEmpty).reversed()).joined(separator: "\n")
    }

    /// Problems that make the walkthrough unusable (nil when it is coherent).
    func problem(requiredLanguage: String?) -> String? {
        guard blocks.first?.kind == .explanation else { return "the walkthrough must start with an EXPLAIN block" }
        guard blocks.contains(where: { $0.kind == .explanation && $0.index > 0 }) || blocks.count <= 3 else {
            return "the walkthrough needs explanations between the code blocks"
        }
        let codeBlocks = blocks.filter { $0.kind == .code }
        guard let final = codeBlocks.last?.text else { return "no code was included" }
        if let requiredLanguage, let mismatch = CodeLanguageDetector.mismatch(final, required: requiredLanguage) { return mismatch }
        if !CodeLanguageDetector.balanced(final) { return "the final code block is not a complete solution (unbalanced brackets)" }
        // Every name an earlier stage introduced must survive into the final solution.
        for block in codeBlocks.dropLast() {
            for name in CodeLanguageDetector.declaredNames(block.text) where !final.contains(name) {
                return "an intermediate code block introduces \(name), which the final solution drops"
            }
        }
        return nil
    }
}

/// Lightweight, deterministic checks on generated code (no execution).
nonisolated enum CodeLanguageDetector {
    /// The language the code is written in, when it is clear.
    static func detect(_ code: String) -> String? {
        let lower = code.lowercased()
        if code.range(of: #"(?im)^\s*(select|insert into|update|delete from|create table|with)\b"#, options: .regularExpression) != nil { return "SQL" }
        if code.range(of: #"(?m)^\s*(def |import \w+$|from \w+ import|print\()"#, options: .regularExpression) != nil
            || lower.contains("execjs") || code.range(of: #"(?m)^\s*(if|for|while|def|elif|else)\b[^{\n]*:\s*$"#, options: .regularExpression) != nil {
            return "Python"
        }
        let jsx = code.range(of: #"<[A-Za-z][\w.]*[\s>/]"#, options: .regularExpression) != nil && code.contains("</") || code.contains("/>")
        let hooks = code.range(of: #"\buse[A-Z]\w*\("#, options: .regularExpression) != nil
        // Primitive annotations, typed arrays/generics, return types, interfaces and type aliases ("{ status: Active }" is plain JS).
        let types = code.range(of: #"\w\??:\s*(string|number|boolean|any|unknown|void|never)\b|\w\??:\s*[A-Z]\w*(\[\]|<[^>]+>)|\)\s*:\s*[A-Za-z]\w*(\[\]|<[^>]+>)?\s*(\{|=>)|\binterface\s+\w+|\btype\s+\w+\s*="#,
                               options: .regularExpression) != nil
        if jsx || hooks { return types ? "React (TSX)" : "React" }
        if types { return "TypeScript" }
        if code.range(of: #"\b(function|const|let|var)\b|=>"#, options: .regularExpression) != nil { return "JavaScript" }
        return nil
    }

    /// Why the code does not match the requested language (nil when it does or cannot be told).
    static func mismatch(_ code: String, required: String) -> String? {
        let lower = code.lowercased()
        if ["execjs", "subprocess", "node -e", "pyexecjs", "js2py"].contains(where: { lower.contains($0) }), required != "Python" || lower.contains("execjs") {
            return "the code wraps another language's runtime instead of writing \(required)"
        }
        guard let detected = detect(code) else { return nil }
        let accepted: Set<String> = switch required {
        case "JavaScript": ["JavaScript", "React"]
        case "TypeScript": ["TypeScript", "React (TSX)"]
        case "React": ["React", "React (TSX)", "JavaScript", "TypeScript"]
        case "Python": ["Python"]
        case "SQL": ["SQL"]
        default: [detected]
        }
        return accepted.contains(detected) ? nil : "the code is \(detected), but \(required) was requested"
    }

    /// Brackets, braces and parentheses close (strings and comments are not parsed: a deliberate approximation).
    static func balanced(_ code: String) -> Bool {
        var stack: [Character] = []
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        for character in code {
            if "([{".contains(character) { stack.append(character) }
            else if let open = pairs[character] { guard stack.popLast() == open else { return false } }
        }
        return stack.isEmpty
    }

    static func declaredNames(_ code: String) -> [String] {
        RepositoryImporter.matches(#"\b(?:function|const|let|var|def|class|interface|type)\s+([A-Za-z_]\w*)"#, in: code)
    }
}

/// Spoken navigation for a walkthrough. Only a short, exact command counts, never ordinary speech.
nonisolated enum WalkthroughCommand: Equatable, Sendable {
    case next, previous

    static func parse(_ text: String) -> WalkthroughCommand? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
        if ["next", "next step", "next block", "continue", "go on", "next one", "show the next step"].contains(words) { return .next }
        if ["previous", "previous step", "go back", "back", "previous block", "last step"].contains(words) { return .previous }
        return nil
    }
}
