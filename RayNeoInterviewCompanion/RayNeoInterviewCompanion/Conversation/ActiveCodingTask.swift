import Foundation

/// The programming task under discussion, kept across turns until the conversation clearly moves on.
nonisolated struct ActiveCodingTask: Equatable, Sendable {
    var id = "task-" + UUID().uuidString.prefix(8)
    var instruction: String
    var language: String
    var functionality: String
    var expectedInput: String?
    var expectedOutput: String?
    var constraints: [String] = []
    /// What the candidate said about their approach (bounded), and the techniques it named.
    var userApproach: String?
    var dataStructures: [String] = []
    var previousCode: String?
    var tutorStep = 0
    var modifications: [String] = []
    var turnIDs: [Int] = []
    var updatedAt = Date()

    /// Compact prompt context for a follow-up about this task.
    func promptBlock(request: String, kind: CodingFollowUp, language requested: String) -> String {
        var lines = ["Active programming task: \"\(instruction.prefix(300))\"", "Language: \(requested)"]
        if let expectedInput { lines.append("Input: \(expectedInput)") }
        if let expectedOutput { lines.append("Output: \(expectedOutput)") }
        if !constraints.isEmpty { lines.append("Constraints: \(constraints.joined(separator: "; "))") }
        if !dataStructures.isEmpty || userApproach != nil {
            lines.append("The candidate's own approach: \(dataStructures.joined(separator: ", "))\(userApproach.map { " — \"\($0.prefix(240))\"" } ?? "")")
        }
        if !modifications.isEmpty { lines.append("Changes already discussed: \(modifications.suffix(3).joined(separator: "; "))") }
        if let previousCode { lines.append("Code so far:\n\(previousCode.prefix(700))") }
        lines.append("Requested now (\(kind.label)): \"\(request.prefix(200))\"")
        lines.append("This continues the same task. Keep the language unless a new one was requested, follow the candidate's approach when it is correct, and give the code or explanation directly. It is a hypothetical implementation, never a claim about past work.")
        return lines.joined(separator: "\n")
    }
}

nonisolated enum CodingFollowUp: String, Sendable {
    case implement, modify, explain, test
    var label: String {
        switch self {
        case .implement: "show the implementation"
        case .modify: "modify the implementation"
        case .explain: "explain the code"
        case .test: "show how to test it"
        }
    }
    var wantsCode: Bool { self != .explain }
}

nonisolated struct ResolvedCodingRequest: Equatable, Sendable {
    var kind: CodingFollowUp
    var language: String
    var prompt: String
    /// The task's original instruction (relevance is judged against it, not the bare "show me that").
    var instruction: String
}

/// Language, request and follow-up rules for programming conversations (deterministic, testable).
nonisolated enum CodingLanguage {
    /// Languages a speaker can name explicitly (TypeScript before JavaScript).
    static let explicit: [(name: String, cues: [String])] = [
        ("TypeScript", ["typescript"]), ("JavaScript", ["javascript", " js "]), ("Python", ["python"]), ("SQL", [" sql"]),
        ("React", ["react"]), ("Swift", ["swift"]), ("Java", [" java "]), ("C#", ["c#", "c sharp"]), ("Go", ["golang"]),
    ]
    /// Hints when no language is named.
    static let hints: [(name: String, cues: [String])] = [
        ("React", ["usestate", "useeffect", "component", "jsx", "hook"]), ("SQL", ["query", "select ", "table", "group by"]),
        ("Python", ["django", "fastapi", "pandas"]), ("JavaScript", ["node", "express", "array", "promise"]),
    ]

    /// The language a text names explicitly (nil if none).
    static func named(in text: String) -> String? {
        let lower = " " + text.lowercased() + " "
        return explicit.first { $0.cues.contains(where: { lower.contains($0) }) }?.name
    }

    /// Best guess for a new task: the named language, else the technology it mentions, else JavaScript.
    static func guess(_ text: String) -> String {
        if let named = named(in: text) { return named }
        let lower = " " + text.lowercased() + " "
        return hints.first { $0.cues.contains(where: { lower.contains($0) }) }?.name ?? "JavaScript"
    }

    static let requestVerbs = ["write", "implement", "create", "build", "code", "debug", "fix", "refactor", "design"]
    static let programmingNouns = ["function", "method", "class", "component", "endpoint", "query", "script", "api", "algorithm",
                                   "array", "string", "hook", "test", "loop", "regex", "program", "module", "route", "schema"]

    /// "Write a JavaScript function that…", "Implement an endpoint…", "Create a component…", "Debug this code…".
    static func isNewTask(_ text: String) -> Bool {
        let lower = text.lowercased()
        let stripped = lower.replacingOccurrences(of: #"^(so|okay|ok|now|alright|and|can you|could you|would you|please|i'd like you to|i want you to)[ ,]+"#,
                                                  with: "", options: .regularExpression)
        let imperative = requestVerbs.contains { stripped.hasPrefix($0 + " ") }
        let noun = programmingNouns.contains { lower.contains($0) }
        return imperative && noun && !refersBack(lower)
    }

    static func refersBack(_ lower: String) -> Bool {
        let words = Set(lower.split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init))
        return !words.isDisjoint(with: ["that", "it", "this", "those", "same"]) && !lower.contains("that takes") && !lower.contains("that returns")
            && !lower.contains("function that") && !lower.contains("query that") && !lower.contains("component that")
    }

    /// The kind of follow-up a turn asks for about an active task (nil when it is not one).
    static func followUp(_ text: String, task: ActiveCodingTask) -> CodingFollowUp? {
        let lower = " " + text.lowercased() + " "
        if isNewTask(text) { return nil }
        let refers = refersBack(lower)
        let test = [" test it", " test that", " test this", "how would you test", "unit test", "tests for", "write tests", "how do you test"]
        let explain = ["explain this line", "explain that line", "explain the line", "what does this line", "what does that line",
                       "explain the code", "walk me through the code", "how does that code", "why does that", "explain how that works", "explain that code"]
        let modify = ["contains objects", "array of objects", "objects instead", "asynchronous", " async", "make it ", "instead of",
                      "without using", "in place", "recursive", "optimiz", "faster", "what if the", "handle ", "case-insensitive", "sorted"]
        let implement = ["show me the code", "the code for", "show the code", "show me how", "write that", "write it", "implement it",
                         "implement that", "code that", "code it", "look like", "how would you code", "what would that function",
                         "what would the code", "can you write", "show me an example", "an example", "the implementation", "see the code",
                         "show me", "type that out", "write the code", "write out"]
        if test.contains(where: { lower.contains($0) }) { return .test }
        if explain.contains(where: { lower.contains($0) }) { return .explain }
        if let language = named(in: text), language != task.language { return .modify }
        if modify.contains(where: { lower.contains($0) }), refers || lower.contains(" array") || lower.contains(" the function") { return .modify }
        if implement.contains(where: { lower.contains($0) }) { return .implement }
        return nil
    }

    static let techniques = ["set", "spread operator", "spread", "map", "filter", "reduce", "sort", "hash map", "hashmap", "object",
                             "dictionary", "two pointers", "recursion", "loop", "for loop", "includes", "indexof", "binary search",
                             "group by", "join", "index", "promise", "async/await", "try/catch", "useState", "useEffect", "regex"]

    /// The candidate describing their own approach ("So I'd solve that using a Set…").
    static func isApproach(_ text: String) -> Bool {
        let lower = text.lowercased()
        let firstPerson = ["i'd", "i would", "i'll", "i will", "i'm going to", "my approach", "i think i'd", "we could", "i'd probably", "i'd use", "so i'd"]
        return firstPerson.contains { lower.hasPrefix($0) || lower.contains(" " + $0 + " ") || lower.hasPrefix("so " + $0) }
    }
}

/// Owns the active programming task for the session.
@MainActor @Observable final class CodingTaskTracker {
    private(set) var task: ActiveCodingTask?

    /// Every finalized turn. Returns a short decision for diagnostics (nil = no change).
    @discardableResult
    func observe(_ text: String, turnID: Int, startsNewTopic: Bool) -> String? {
        if CodingLanguage.isNewTask(text) {
            task = Self.makeTask(text, turnID: turnID)
            return "Active coding task selected (\(task!.language))"
        }
        guard var current = task else { return nil }
        if CodingLanguage.isApproach(text) {
            let lower = " " + text.lowercased() + " "
            current.userApproach = String(text.prefix(400))
            current.dataStructures = Array(Set(current.dataStructures + CodingLanguage.techniques.filter { lower.contains(" " + $0.lowercased()) })).sorted()
            current.turnIDs.append(turnID)
            current.updatedAt = Date()
            task = current
            return "Coding task: candidate's approach recorded (\(current.dataStructures.joined(separator: ", ")))"
        }
        if CodingLanguage.followUp(text, task: current) != nil {
            current.turnIDs.append(turnID)
            task = current
            return nil
        }
        if startsNewTopic {
            task = nil
            return "Coding task cleared (topic changed)"
        }
        return nil
    }

    /// Resolves a follow-up ("show me the code for that") against the active task.
    func resolve(_ text: String) -> ResolvedCodingRequest? {
        guard let task, let kind = CodingLanguage.followUp(text, task: task) else { return nil }
        let language = CodingLanguage.named(in: text) ?? task.language
        return ResolvedCodingRequest(kind: kind, language: language, prompt: task.promptBlock(request: text, kind: kind, language: language),
                                     instruction: task.instruction)
    }

    /// After an answer about the task: keep its code (and any language change) for the next follow-up.
    func record(code: String?, request: String, turnID: Int?) {
        guard var current = task else { return }
        if let code { current.previousCode = code }
        if let language = CodingLanguage.named(in: request), language != current.language {
            current.modifications.append("now in \(language)")
            current.language = language
        } else if CodingLanguage.followUp(request, task: current) == .modify {
            current.modifications.append(String(request.prefix(120)))
        }
        if let turnID { current.turnIDs.append(turnID) }
        current.updatedAt = Date()
        task = current
    }

    func clear() { task = nil }

    static func makeTask(_ text: String, turnID: Int) -> ActiveCodingTask {
        let lower = text.lowercased()
        let functionality = text.range(of: #"(?i)\b(that|to|which)\s+(.+?)[.?!]*$"#, options: .regularExpression)
            .map { String(text[$0]).replacingOccurrences(of: #"(?i)^(that|to|which)\s+"#, with: "", options: .regularExpression) } ?? text
        let input = lower.range(of: #"(from|takes|given|accepts) (an? |the )?[a-z ]{2,30}?(array|list|string|object|number|table|input)s?"#, options: .regularExpression).map { String(lower[$0]) }
        let output = lower.range(of: #"returns? (an? |the )?[a-z ]{2,40}"#, options: .regularExpression).map { String(lower[$0]) }
        let constraints = ["without using", "in place", "o(n)", "o(1)", "constant space", "no libraries", "recursively", "case-insensitive"]
            .filter { lower.contains($0) }
        return ActiveCodingTask(instruction: text, language: CodingLanguage.guess(text), functionality: functionality,
                                expectedInput: input, expectedOutput: output, constraints: constraints, turnIDs: [turnID])
    }
}
