import Foundation

/// Deterministic arithmetic for spoken or typed questions. Never evaluates strings as code: a tiny
/// tokenizer and recursive-descent parser over `Decimal` (exact for typical interview arithmetic).
nonisolated enum Calculator {
    enum Failure: Error, Equatable, Sendable {
        case divisionByZero, overflow, unsupported(String)
    }

    struct Result: Equatable, Sendable {
        /// e.g. "5000 times 592"
        let spokenExpression: String
        let value: Decimal
        /// e.g. "5000 times 592 is 2,960,000."
        let answer: String
    }

    /// nil = not a calculation. `.failure` = clearly a calculation, but it cannot be computed safely.
    static func evaluate(_ question: String) -> Swift.Result<Result, Failure>? {
        let text = normalize(question)
        if let average = averageForm(text) { return average }
        let tokens: [Token]
        do { tokens = try tokenize(text) } catch { return looksMathematical(text) ? .failure(.unsupported(text)) : nil }
        let numbers = tokens.filter { if case .number = $0 { return true }; return false }.count
        let operators = tokens.filter {
            switch $0 { case .op, .percent, .sqrt: true; default: false }
        }.count
        guard numbers >= 1, operators >= 1 else { return nil }
        var parser = Parser(tokens: tokens)
        do {
            let value = try parser.parseExpression()
            guard parser.isAtEnd else { return .failure(.unsupported(text)) }
            let spoken = tokens.map(\.spoken).joined(separator: " ").replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " )", with: ")")
            return .success(Result(spokenExpression: spoken, value: value, answer: "\(spoken) is \(format(value))."))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.unsupported(text))
        }
    }

    /// Spoken answer for a failure (never a guessed number).
    static func explanation(_ failure: Failure) -> String {
        switch failure {
        case .divisionByZero: "That divides by zero, so it doesn't have a defined answer."
        case .overflow: "That number is too large for me to calculate exactly."
        case .unsupported: "I couldn't follow that calculation exactly. Could you say it again more slowly?"
        }
    }

    // MARK: Normalisation

    static func normalize(_ question: String) -> String {
        var text = " " + question.lowercased()
            .replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
            + " "
        // Thousands separators inside numbers ("5,000"), but not list commas ("12, 18").
        text = text.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        for lead in ["what is", "what's", "whats", "how much is", "calculate", "compute", "can you calculate", "could you calculate",
                     "tell me", "what do you get for", "what does", "solve", "work out", "quickly", "so", "okay", "ok", "um", "uh"] {
            text = text.replacingOccurrences(of: " \(lead) ", with: " ")
        }
        text = text.replacingOccurrences(of: #"[?!]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\.\s*$"#, with: " ", options: .regularExpression)
        let phrases: [(String, String)] = [
            ("multiplied by", " * "), ("times", " * "), ("divided by", " / "), ("over", " / "), ("plus", " + "),
            ("minus", " - "), ("negative", " - "), ("to the power of", " ^ "), ("raised to the power of", " ^ "), ("raised to", " ^ "),
            ("to the", " ^ "), ("squared", " ^ 2 "), ("cubed", " ^ 3 "), ("percent", " % "), ("per cent", " % "),
            ("square root of", " sqrt "), ("open parenthesis", " ( "), ("close parenthesis", " ) "),
            ("equals", " "), ("equal", " "), ("is", " "), ("the", " "), ("and", " "),
        ]
        text = NumberWords.replace(in: text)
        for (phrase, symbol) in phrases {
            text = text.replacingOccurrences(of: "\\b\(phrase)\\b", with: symbol, options: .regularExpression)
        }
        // Multiplication signs; the letter "x" only between operands. "of" multiplies after a percentage.
        for sign in ["×", "✕", "·", "∙"] { text = text.replacingOccurrences(of: sign, with: " * ") }
        text = text.replacingOccurrences(of: #"([\d)])\s*x\s*(?=[\d(-])"#, with: "$1 * ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"%\s*of\b"#, with: "% *", options: .regularExpression)
        text = text.replacingOccurrences(of: "÷", with: " / ").replacingOccurrences(of: "**", with: " ^ ")
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func looksMathematical(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber).count
        let symbols = text.filter { "+-*/^%".contains($0) }.count
        let words = text.split(separator: " ").filter { $0.contains(where: \.isLetter) }.count
        return digits >= 2 && symbols >= 1 && words <= 2
    }

    /// "average of 12, 18, and 24" / "mean of 3 4 5"
    private static func averageForm(_ text: String) -> Swift.Result<Result, Failure>? {
        guard let range = text.range(of: #"^(?:an? )?(?:average|mean) of "#, options: .regularExpression) else { return nil }
        let numbers = text[range.upperBound...].split(whereSeparator: { $0 == "," || $0 == " " }).filter { !$0.isEmpty }
        let values = numbers.compactMap { Decimal(string: String($0), locale: Locale(identifier: "en_US_POSIX")) }
        guard values.count == numbers.count, values.count >= 2 else { return .failure(.unsupported(text)) }
        let mean = values.reduce(0, +) / Decimal(values.count)
        let list = numbers.dropLast().joined(separator: ", ") + ", and " + numbers.last!
        return .success(Result(spokenExpression: "the average of \(list)", value: mean, answer: "The average of \(list) is \(format(mean))."))
    }

    static func format(_ value: Decimal) -> String {
        var rounded = Decimal(), copy = value
        NSDecimalRound(&rounded, &copy, 6, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        let text = formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
        return rounded == value ? text : "about \(text)"
    }

    // MARK: Tokens and parser

    enum Token: Equatable {
        case number(Decimal, String), op(Character), percent, open, close, sqrt
        var spoken: String {
            switch self {
            case .number(_, let raw): raw
            case .op(let op): ["+": "plus", "-": "minus", "*": "times", "/": "divided by", "^": "to the power of"][op] ?? String(op)
            case .percent: "percent"
            case .open: "("
            case .close: ")"
            case .sqrt: "the square root of"
            }
        }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == " " { index = text.index(after: index); continue }
            if character.isNumber || (character == "." && text.index(after: index) < text.endIndex && text[text.index(after: index)].isNumber) {
                var end = index
                while end < text.endIndex, text[end].isNumber || text[end] == "." { end = text.index(after: end) }
                let raw = String(text[index..<end])
                guard raw.filter({ $0 == "." }).count <= 1, let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw Failure.unsupported(raw)
                }
                tokens.append(.number(value, raw))
                index = end
                continue
            }
            if text[index...].hasPrefix("sqrt") { tokens.append(.sqrt); index = text.index(index, offsetBy: 4); continue }
            switch character {
            case "+", "-", "*", "/", "^": tokens.append(.op(character))
            case "%": tokens.append(.percent)
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: throw Failure.unsupported(String(character))
            }
            index = text.index(after: index)
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var position = 0
        var isAtEnd: Bool { position >= tokens.count }
        static let limit = Decimal(string: "1e30")!

        mutating func parseExpression() throws -> Decimal {
            var value = try parseTerm()
            while case .op(let op)? = peek(), op == "+" || op == "-" {
                position += 1
                let rhs = try parseTerm()
                value = try checked(op == "+" ? value + rhs : value - rhs)
            }
            return value
        }

        mutating func parseTerm() throws -> Decimal {
            var value = try parseUnary()
            while case .op(let op)? = peek(), op == "*" || op == "/" {
                position += 1
                let rhs = try parseUnary()
                if op == "/" {
                    guard rhs != 0 else { throw Failure.divisionByZero }
                    value = try checked(value / rhs)
                } else {
                    value = try checked(value * rhs)
                }
            }
            return value
        }

        mutating func parseUnary() throws -> Decimal {
            if case .op("-")? = peek() { position += 1; return try checked(-(try parseUnary())) }
            if case .op("+")? = peek() { position += 1; return try parseUnary() }
            return try parsePower()
        }

        /// Right-associative; exponent must be a whole number between -64 and 64.
        mutating func parsePower() throws -> Decimal {
            let base = try parsePostfix()
            guard case .op("^")? = peek() else { return base }
            position += 1
            let exponent = try parseUnary()
            guard exponent == exponent.rounded(), abs(exponent) <= 64 else { throw Failure.unsupported("exponent") }
            let count = NSDecimalNumber(decimal: abs(exponent)).intValue
            var result: Decimal = 1
            for _ in 0..<count { result = try checked(result * base) }
            if exponent < 0 {
                guard result != 0 else { throw Failure.divisionByZero }
                result = try checked(1 / result)
            }
            return result
        }

        mutating func parsePostfix() throws -> Decimal {
            var value = try parsePrimary()
            while case .percent? = peek() { position += 1; value /= 100 }
            return value
        }

        mutating func parsePrimary() throws -> Decimal {
            guard let token = next() else { throw Failure.unsupported("end") }
            switch token {
            case .number(let value, _): return value
            case .open:
                let value = try parseExpression()
                guard case .close? = next() else { throw Failure.unsupported("parenthesis") }
                return value
            case .sqrt:
                let value = try parsePrimary()
                guard value >= 0 else { throw Failure.unsupported("square root of a negative number") }
                let root = Decimal(sqrt(NSDecimalNumber(decimal: value).doubleValue))
                let whole = root.rounded()
                return whole * whole == value ? whole : root
            default: throw Failure.unsupported("operator")
            }
        }

        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }
        private mutating func next() -> Token? { defer { position += 1 }; return peek() }
        private func checked(_ value: Decimal) throws -> Decimal {
            guard !value.isNaN, abs(value) < Self.limit else { throw Failure.overflow }
            return value
        }
    }
}

nonisolated extension Decimal {
    func rounded() -> Decimal {
        var result = Decimal(), copy = self
        NSDecimalRound(&result, &copy, 0, .plain)
        return result
    }
}

/// "five thousand two hundred and six" → "5206". Recognisers usually emit digits; this covers the rest.
nonisolated enum NumberWords {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    static func replace(in text: String) -> String {
        var output: [String] = []
        var total = 0, current = 0, inNumber = false
        func flush() { if inNumber { output.append(String(total + current)); total = 0; current = 0; inNumber = false } }
        let words = text.split(separator: " ").map(String.init)
        for (index, raw) in words.enumerated() {
            let word = raw.replacingOccurrences(of: "-", with: " ")
            let parts = word.split(separator: " ").map(String.init)
            if parts.allSatisfy({ units[$0] != nil }) && !parts.isEmpty {
                current += parts.compactMap { units[$0] }.reduce(0, +); inNumber = true
            } else if raw == "a", index + 1 < words.count, scales[words[index + 1]] != nil {
                current += 1; inNumber = true
            } else if let scale = scales[raw], inNumber || Int(output.last ?? "") != nil {
                if !inNumber, let previous = Int(output.removeLast()) { current = previous; inNumber = true }
                if scale == 100 { current *= 100 } else { total += current * scale; current = 0 }
            } else if raw == "and", inNumber, index + 1 < words.count, units[words[index + 1]] != nil {
                continue
            } else {
                flush(); output.append(raw)
            }
        }
        flush()
        return " " + output.joined(separator: " ") + " "
    }
}
