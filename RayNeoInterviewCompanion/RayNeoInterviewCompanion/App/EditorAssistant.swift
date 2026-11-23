import Foundation

/// Plain-language explanations for common editor diagnostics (TypeScript/JavaScript, Python, SQL).
/// Deterministic; an AI explanation is used only when the wearer explicitly asks and no rule matches.
nonisolated enum DiagnosticExplainer {
    struct Explanation: Equatable, Sendable {
        /// Compact text for the glasses.
        var short: String
        /// Whether a rule recognised the diagnostic.
        var matched: Bool
    }

    static func explain(_ diagnostic: EditorEvent.Diagnostic) -> Explanation {
        let message = diagnostic.message
        func quoted(_ index: Int) -> String? {
            let parts = message.components(separatedBy: CharacterSet(charactersIn: "'\"`"))
            return parts.count > index * 2 + 1 ? parts[index * 2 + 1] : nil
        }
        let lower = message.lowercased()
        let rules: [(Bool, () -> String)] = [
            (lower.hasPrefix("cannot find name") || lower.contains("is not defined") || lower.contains("nameerror"),
             { "Check whether \(quoted(0) ?? "that name") is defined in the current scope or passed in as a function parameter." }),
            (lower.contains("does not exist on type"),
             { "\(quoted(1) ?? "That type") has no \(quoted(0) ?? "such property"): check the spelling, or the type you expect here." }),
            (lower.contains("is not assignable to"),
             { "A \(quoted(0) ?? "value") is used where \(quoted(1) ?? "another type") is expected: convert it or fix the type." }),
            (lower.contains("is possibly 'undefined'") || lower.contains("is possibly 'null'") || lower.contains("possibly undefined"),
             { "This value may be undefined here: check it first or use optional chaining (?.)." }),
            (lower.contains("is not a function"),
             { "\(quoted(0) ?? "It") is called like a function but holds something else at that point." }),
            (lower.contains("expected") && (lower.contains("';'") || lower.contains("','") || lower.contains("')'") || lower.contains("'}'")),
             { "A bracket or punctuation mark is missing near this line: check the closing \(quoted(0) ?? "symbol")." }),
            (lower.contains("unterminated string"), { "A string is not closed: add the missing quote." }),
            (lower.contains("unexpected token") || lower.contains("declaration or statement expected") || lower.contains("invalid syntax"),
             { "The syntax breaks near this line: look for an extra or missing bracket, comma or keyword." }),
            (lower.contains("indent"), { "This line's indentation does not match its block." }),
            (lower.contains("syntax error at or near"),
             { "The SQL is invalid near \(quoted(0) ?? "that word"): check the keyword order or a missing comma." }),
            (lower.contains("is declared but its value is never read") || lower.contains("unused"),
             { "\(quoted(0) ?? "Something") is declared but never used: remove it or use it." }),
        ]
        if let rule = rules.first(where: { $0.0 }) { return Explanation(short: rule.1(), matched: true) }
        return Explanation(short: "Line \(diagnostic.line.map(String.init) ?? "?"): \(String(message.prefix(80)))", matched: false)
    }
}

/// Everything the editor reports, and what of it reaches the glasses. Display priority:
/// 1. explicitly requested help (and Explain Selection), 2. a confident new question (the engine's handoff),
/// 3. the active walkthrough, 4. editor progress (advances the walkthrough), 5. low-priority diagnostics.
/// Background editor events never replace a spoken explanation: while the wearer speaks they wait, warnings
/// never reach the glasses, and repeated events are coalesced.
@MainActor @Observable final class EditorAssistant {
    struct State: Equatable, Sendable {
        var file: String?
        var language: String?
        var line: Int?
        var column: Int?
        var symbol: String?
        var selectionLines: Int?
        var errors = 0
        var warnings = 0
    }

    private(set) var state = State()
    private(set) var diagnostics: [EditorEvent.Diagnostic] = []
    /// The current explicit help or selection explanation (iPhone detail; compact version on the glasses).
    private(set) var help: (title: String, detail: String)?
    private(set) var taskStatus: String?
    private(set) var autoProgress = true
    private(set) var lastEventToCaptionMs: Double?

    var isSpeaking: () -> Bool = { false }
    /// One bounded AI request (instructions, prompt) → text; nil when unavailable.
    var askAI: (String, String) async -> String? = { _, _ in nil }
    var codeLayout: () -> CodeDisplayLayout = { CodeDisplayLayout() }

    static let helpOverlay = -2_000_001
    static let statusOverlay = -2_000_002
    private let presenter: GlassesPresenter
    private let snippets: CodeSnippetController
    private var pendingGlasses: (rows: [String], persistent: Bool, key: String)?
    private var recent: [String: Date] = [:]
    private var statusTask: Task<Void, Never>?

    init(presenter: GlassesPresenter, snippets: CodeSnippetController) {
        self.presenter = presenter
        self.snippets = snippets
    }

    func handle(_ event: EditorEvent, receivedAt: Date = Date()) {
        switch event.type {
        case "state":
            if let file = event.file { state.file = file }
            if let language = event.language { state.language = language }
            if let line = event.line { state.line = line }
            if let column = event.column { state.column = column }
            if event.symbol != nil { state.symbol = event.symbol }
            if let selection = event.selectionLines { state.selectionLines = selection }
        case "diagnostics":
            diagnostics = Array((event.diagnostics ?? []).prefix(20))
            state.errors = event.errors ?? diagnostics.filter { $0.severity == "error" }.count
            state.warnings = event.warnings ?? diagnostics.filter { $0.severity == "warning" }.count
            // Priority 5: only a stable error, only while the wearer is working on code, never while speaking.
            guard event.stable == true, let error = diagnostics.first(where: { $0.severity == "error" }) else { return }
            let codeStep = snippets.walkthrough == nil || snippets.currentBlock?.kind.isCode == true
            guard codeStep else { return }
            let explanation = DiagnosticExplainer.explain(error)
            show(rows(explanation.short, prefix: error.line.map { "Line \($0):" }), persistent: false, key: "diag:\(error.message)", receivedAt: receivedAt)
        case "progress":
            guard autoProgress else { return DiagnosticLog.shared.record(.pipeline, "Editor progress ignored: automatic progression is off") }
            guard event.stable == true else { return } // wait for the editor state to settle
            guard let blockID = event.blockID, let present = event.present else { return }
            snippets.editorProgress(EditorProgress(blockID: blockID, file: event.file ?? "", language: event.language, present: present, errors: event.errors))
        case "help":
            let diagnostic = event.diagnostics?.first ?? diagnostics.first(where: { $0.severity == "error" })
            Task { await explainDiagnostic(diagnostic, excerpt: event.code, receivedAt: receivedAt) }
        case "explain":
            guard let code = event.code, !code.isEmpty else { return }
            Task { await explainSelection(code, language: event.language ?? state.language ?? "", receivedAt: receivedAt) }
        case "task":
            guard let task = event.task else { return }
            let kind = task.kind == "test" ? "Tests" : "Build"
            // Passed only when the runner actually reported success (exit code 0).
            let summary = switch task.exitCode {
            case 0?: "\(kind) passed (\(task.name))"
            case let code?: "\(kind) failed (\(task.name), exit \(code))"
            case nil: "\(kind) task ended without a result (\(task.name))"
            }
            taskStatus = summary
            DiagnosticLog.shared.record(.pipeline, "Editor \(kind.lowercased()) result: \(task.exitCode.map { "exit \($0)" } ?? "no result")")
            show(rows(summary), persistent: false, key: "task:\(summary):\(event.ts ?? 0)", receivedAt: receivedAt)
        case "auto":
            autoProgress = event.enabled ?? true
            DiagnosticLog.shared.record(.pipeline, "Editor automatic progression \(autoProgress ? "on" : "off")")
        case "dismiss":
            dismissHelp()
        default:
            break
        }
    }

    /// Priority 1: the wearer asked. Rule-based when possible; AI only for unknown diagnostics.
    func explainDiagnostic(_ diagnostic: EditorEvent.Diagnostic?, excerpt: String?, receivedAt: Date = Date()) async {
        guard let diagnostic else {
            help = ("No error at the cursor", "VS Code reports no error here.")
            return
        }
        var short = DiagnosticExplainer.explain(diagnostic)
        if !short.matched, let text = await askAI(
            "Explain this compiler or linter message in one short, plain sentence and suggest one concrete debugging step. Never claim you ran the code.",
            "Language: \(state.language ?? "")\nMessage: \(diagnostic.message.prefix(300))\(excerpt.map { "\nCode near it:\n\($0.prefix(800))" } ?? "")") {
            short = DiagnosticExplainer.Explanation(short: AnswerFormatter.spoken(text), matched: true)
        }
        help = ("Line \(diagnostic.line.map(String.init) ?? "?"): \(diagnostic.message)", short.short)
        show(rows(short.short, prefix: diagnostic.line.map { "Line \($0):" }), persistent: true, key: "help:\(diagnostic.message)",
             receivedAt: receivedAt, explicit: true)
    }

    /// Priority 1: Explain Selection. The walkthrough position is unchanged.
    func explainSelection(_ code: String, language: String, receivedAt: Date = Date()) async {
        let task = snippets.walkthrough.map { "Current coding task language: \($0.language)." } ?? ""
        let text = await askAI(
            "Explain the selected \(language) code naturally and professionally in 2 to 4 spoken sentences: its purpose, the language features it relies on, and one edge case. \(task) Never claim it was run or tested.",
            "Selected code:\n\(code.prefix(4096))") ?? "No explanation available right now."
        let spoken = AnswerFormatter.spoken(text)
        help = ("Selected code", spoken)
        let compact = spoken.components(separatedBy: ". ").prefix(2).joined(separator: ". ")
        show(rows(compact), persistent: true, key: "explain:\(code.hashValue)", receivedAt: receivedAt, explicit: true)
    }

    func dismissHelp() {
        help = nil
        Task {
            await presenter.endOverlay(id: Self.helpOverlay)
            snippets.redisplayCurrentStep()
        }
    }

    /// The wearer finished a sentence: a deferred editor caption may now appear.
    func speechEnded() {
        guard let pending = pendingGlasses else { return }
        pendingGlasses = nil
        display(pending.rows, persistent: pending.persistent, receivedAt: Date())
    }

    // MARK: Glasses

    private func rows(_ text: String, prefix: String? = nil) -> [String] {
        let layout = codeLayout()
        let lines = CaptionLayout(maxLines: 20, charactersPerLine: layout.charactersPerRow).wrap(text)
        return Array(((prefix.map { [$0] } ?? []) + lines).prefix(max(1, layout.rows)))
    }

    private func show(_ rows: [String], persistent: Bool, key: String, receivedAt: Date, explicit: Bool = false) {
        // Coalesce: the same caption within 30 s is not sent again.
        if let last = recent[key], Date().timeIntervalSince(last) < 30 { return }
        recent[key] = Date()
        if recent.count > 50 { recent = recent.filter { Date().timeIntervalSince($0.value) < 30 } }
        guard explicit || !isSpeaking() else {
            pendingGlasses = (rows, persistent, key)
            return DiagnosticLog.shared.record(.pipeline, "Editor caption deferred until you finish speaking")
        }
        display(rows, persistent: persistent, receivedAt: receivedAt)
    }

    private func display(_ rows: [String], persistent: Bool, receivedAt: Date) {
        let id = persistent ? Self.helpOverlay : Self.statusOverlay
        statusTask?.cancel()
        Task {
            let submitted = await presenter.showOverlay(rows, id: id, persistent: persistent)
            if submitted {
                lastEventToCaptionMs = Date().timeIntervalSince(receivedAt) * 1000
                DiagnosticLog.shared.record(.pipeline, String(format: "Editor event → caption submitted in %.0f ms (visibility not confirmed)", lastEventToCaptionMs ?? 0))
            }
            guard !persistent else { return }
            // Status captions are brief; then the lens returns to the answer or the walkthrough step.
            statusTask = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await presenter.endOverlay(id: Self.statusOverlay)
                snippets.redisplayCurrentStep()
            }
        }
    }
}
