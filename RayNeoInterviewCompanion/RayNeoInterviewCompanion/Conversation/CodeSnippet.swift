import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A short code example that accompanies a spoken coding answer. The iPhone shows it complete; the
/// glasses show it as compact plain-text frames (no Markdown, no syntax highlighting).
nonisolated struct CodeSnippet: Codable, Equatable, Sendable {
    var language: String
    var code: String
    /// Code Tutor material (all optional; parsed from the model's STEPS / EDGE CASES / COMPLEXITY / TESTS).
    var problem = ""
    var steps: [String] = []
    var edgeCases: [String] = []
    var complexity: String?
    var tests: [String] = []

    static let marker = "CODE:"
    static let sections = ["STEPS", "EDGE CASES", "COMPLEXITY", "TESTS"]

    /// What the model is asked to produce for a code answer (parsed by `split`).
    static let formatInstruction = """
    After the spoken explanation, write each of these on its own line, in this order: \(marker) then the complete working code     (at most 14 lines, each under 44 characters, no Markdown fences); STEPS: then 2 to 4 numbered implementation steps of one short     line each; EDGE CASES: then 1 to 3 short lines; COMPLEXITY: one line when useful; TESTS: 1 to 3 example calls with their     expected results. Never claim the code was run or tested.
    """

    /// Questions that benefit from seeing code (not every coding question does).
    static func wanted(for question: String) -> Bool {
        let lower = question.lowercased()
        return ["write a", "write the", "write me", "show me", "example", "snippet", "code for", "query to", "query that",
                "implement", "how would you write", "can you show", "what would the code", "sample code", "code that"].contains { lower.contains($0) }
    }

    /// Splits raw model output into the spoken part and an optional snippet: the text after a line
    /// "CODE:", or the first fenced block. The spoken part never contains code.
    static func split(_ raw: String, question: String = "") -> (spoken: String, snippet: CodeSnippet?) {
        var spoken = raw
        var code: String?
        var language = ""
        if let range = raw.range(of: #"(?m)^\s*CODE:\s*"#, options: .regularExpression) {
            spoken = String(raw[..<range.lowerBound])
            code = String(raw[range.upperBound...])
        } else if let range = raw.range(of: #"```[\w+#-]*[ \t]*\n[\s\S]*?(```|$)"#, options: .regularExpression) {
            spoken = String(raw[..<range.lowerBound]) + " " + String(raw[range.upperBound...])
            code = String(raw[range])
        }
        guard var body = code else { return (raw, nil) }
        // Tutor sections follow the code; anything else after it is ignored for the code.
        var sectionText = ""
        if let header = body.range(of: #"(?m)^\s*(STEPS|EDGE CASES|COMPLEXITY|TESTS)\s*:"#, options: .regularExpression) {
            sectionText = String(body[header.lowerBound...])
            body = String(body[..<header.lowerBound])
        }
        // Strip fences (and a language tag) that may surround the code.
        if let fence = body.range(of: #"^\s*```([\w+#-]*)[ \t]*\n?"#, options: .regularExpression) {
            language = body[fence].trimmingCharacters(in: CharacterSet(charactersIn: "` \n\t"))
            body.removeSubrange(fence)
        }
        body = body.replacingOccurrences(of: #"\n?```\s*$"#, with: "", options: .regularExpression)
        let lines = body.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        let trimmed = Array(lines.drop(while: { $0.isEmpty }).reversed().drop(while: { $0.isEmpty }).reversed())
        guard !trimmed.isEmpty else { return (spoken, nil) }
        let text = trimmed.joined(separator: "\n")
        var snippet = CodeSnippet(language: language.isEmpty ? guessLanguage(text, question: question) : language, code: text)
        snippet.problem = question
        let parsed = parseSections(sectionText)
        snippet.steps = parsed["STEPS"] ?? []
        snippet.edgeCases = parsed["EDGE CASES"] ?? []
        snippet.complexity = parsed["COMPLEXITY"]?.joined(separator: " ")
        snippet.tests = parsed["TESTS"] ?? []
        return (spoken, snippet)
    }

    /// "STEPS:\n1. Make a Set\n2. Spread it" → ["STEPS": ["Make a Set", "Spread it"]].
    static func parseSections(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = sections.first(where: { trimmed.uppercased().hasPrefix($0 + ":") }) {
                current = header
                let rest = trimmed.dropFirst(header.count + 1).trimmingCharacters(in: .whitespaces)
                result[header, default: []] += rest.isEmpty ? [] : [cleanItem(rest)]
            } else if let current, !trimmed.isEmpty {
                result[current, default: []].append(cleanItem(trimmed))
            }
        }
        return result
    }

    private static func cleanItem(_ line: String) -> String {
        line.replacingOccurrences(of: #"^(\d{1,2}[.)]|[-*\x{2022}])\s*"#, with: "", options: .regularExpression)
    }

    /// Code Tutor pages for the lens: a "n/N step" row (truncated to one row) above the code excerpt that
    /// goes with it. Short code is repeated on every step page; long code is spread across pages.
    func tutorPages(width: Int, lines: Int) -> [[String]] {
        let rows = lensRows(width: width)
        let room = max(1, lines - 1)
        let chunks = stride(from: 0, to: max(1, rows.count), by: room).map { Array(rows[$0..<min(rows.count, $0 + room)]) }
        let count = max(steps.count, chunks.count)
        return (0..<count).map { index in
            let step = index < steps.count ? steps[index] : "code"
            var label = "\(index + 1)/\(count) \(step)"
            if label.count > width { label = String(label.prefix(width - 1)) + "\u{2026}" }
            return [label] + chunks[min(index, chunks.count - 1)]
        }
    }

    static func guessLanguage(_ code: String, question: String) -> String {
        let lower = (question + " " + code).lowercased()
        if lower.range(of: #"\b(select|insert into|create table|group by)\b"#, options: .regularExpression) != nil { return "sql" }
        if lower.contains("def ") || lower.contains("python") { return "python" }
        if lower.contains("usestate") || lower.contains("useeffect") || lower.contains("react") || code.contains("</") { return "react" }
        if lower.contains("typescript") || code.range(of: #":\s*(string|number|boolean)\b|interface\s"#, options: .regularExpression) != nil { return "typescript" }
        return "javascript"
    }

    /// Rows for the lens: indentation compressed to 2 spaces per level, lines longer than `width`
    /// broken at a space or punctuation when possible (otherwise hard-broken) with a "» " continuation.
    /// No character of the code is dropped.
    func lensRows(width: Int) -> [String] {
        CodePaginator.rows(code, width: width).map(\.text)
    }


    /// Frames of at most `lines` rows. Multi-frame snippets reserve one row per frame for a
    /// "code 1/3" indicator; beyond `maxFrames` the last frame says the rest is on the iPhone.
    func lensFrames(width: Int, lines: Int, maxFrames: Int = 4) -> [[String]] {
        let rows = lensRows(width: width)
        guard rows.count > lines else { return [rows] }
        let perFrame = max(1, lines - 1)
        var chunks = stride(from: 0, to: rows.count, by: perFrame).map { Array(rows[$0..<min(rows.count, $0 + perFrame)]) }
        let truncated = chunks.count > maxFrames
        if truncated { chunks = Array(chunks.prefix(maxFrames)) }
        return chunks.enumerated().map { index, chunk in
            let last = index == chunks.count - 1
            return chunk + ["[code \(index + 1)/\(chunks.count)\(truncated && last ? " · rest on iPhone" : "")]"]
        }
    }

    private static func indentUnit(_ code: String) -> Int {
        let indents = code.components(separatedBy: "\n").map { $0.prefix(while: { $0 == " " }).count }.filter { $0 > 0 }
        return indents.min() ?? 0
    }
}

/// Shows a code answer on the glasses in one of two modes:
/// - Preview: each frame for a limited time (default 20 s), then back to the answer.
/// - Code Tutor: one implementation step per page (step row + code excerpt), kept until the user moves
///   to another step, exits, or another answer takes over — no timer.
/// Every run has its own ID and answer ID: a timer can only end its own snippet; a new answer, a clear or
/// a disconnect ends it, and an ended snippet is never restored on reconnection. Preview time starts when
/// a frame is handed to Bluetooth; actual visibility is approximate (the lens does not acknowledge display).
@MainActor @Observable final class CodeSnippetController {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case tutor, preview
        var id: String { rawValue }
        var label: String { self == .tutor ? "Code Tutor steps (stay until you move on)" : "20-second preview" }
    }

    private(set) var snippet: CodeSnippet?
    private(set) var answerID: Int?
    private(set) var snippetID = 0
    private(set) var mode = Mode.preview
    private(set) var frames: [[String]] = []
    private(set) var frameIndex = 0
    private(set) var remaining: Double = 0
    private(set) var status = "No code snippet"
    private(set) var tutorActive = false
    var duration: Double = 20
    var tick: Double = 0.25
    var onShown: () -> Void = {}
    var onEnded: () -> Void = {}

    private let presenter: GlassesPresenter
    private var task: Task<Void, Never>?

    init(presenter: GlassesPresenter) {
        self.presenter = presenter
        presenter.onOverlayExpired = { [weak self] id, end in self?.overlayEnded(id, end) }
        presenter.onAnswerReplaced = { [weak self] previous in
            // Another answer took the teleprompter while an explanation block was showing.
            guard let self, self.walkthrough != nil, previous == (self.answerID ?? self.walkthrough?.answerID) else { return }
            self.endWalkthrough(status: "Walkthrough paused (another answer replaced it; Undo restores it)")
        }
    }

    var isActive: Bool { task != nil || tutorActive || walkthrough != nil }

    private func overlayEnded(_ id: Int, _ end: GlassesPresenter.OverlayEnd) {
        if walkthrough != nil, id == snippetID {
            // Our own explanation block replacing the previous code block is part of the walkthrough.
            guard !presentingExplanation else { return }
            return endWalkthrough(status: "Walkthrough closed (another answer replaced it)")
        }
        expired(id, reason: end == .disconnected ? "glasses disconnected" : "replaced by a new answer or cleared")
    }

    // MARK: Guided walkthrough — one ordered timeline shared by the iPhone and the glasses

    /// One position in the timeline: an explanation block, or one lens-sized part of a code block.
    struct WalkthroughStep: Equatable, Sendable {
        var block: Int
        var part: Int
        var parts: Int
        var rows: [String]
    }

    private(set) var walkthrough: CodingWalkthrough?
    private(set) var walkthroughSteps: [WalkthroughStep] = []
    private(set) var stepIndex = 0
    private(set) var walkthroughPaused = false
    /// Seconds before a code step advances by itself (0 = only Next / "next step").
    var walkthroughCodeSeconds: Double = 0
    private var walkthroughMarker: String?
    private var presentingExplanation = false
    private var stepTimer: Task<Void, Never>?

    // Adaptive auto-advance
    var adaptiveMode = AdaptiveWalkthroughMode.balanced
    /// Calibrated code layout (separate from the explanation layout).
    var codeLayout = CodeDisplayLayout()
    /// Bounded AI check for borderline explanations (at most once per block; nil = not available).
    var semanticJudge: ((_ expected: String, _ heard: String) async -> Bool?)?
    /// A new question is being answered: progression waits (the position is kept).
    var interrupted = false
    /// The current code step's expected structures, for a paired editor.
    var onCodeStep: (_ blockID: String, _ language: String, _ structures: [String]) -> Void = { _, _, _ in }
    private(set) var lastEvaluation: WalkthroughCompletionEvaluator.Evaluation?
    private(set) var editorStatus: String?
    private var evaluator: WalkthroughCompletionEvaluator?
    private var heardText = ""
    private var judgeAsked = false
    private var nextPrepared = false
    private var expectedStructures = 0
    private var evidenceAt: Date?
    /// Walkthroughs replaced by other answers, per answer ID (last few), so Undo restores the right one
    /// at the block where it was — even after the replacement itself was suspended by the Undo.
    struct Suspended: Equatable { var walkthrough: CodingWalkthrough; var snippet: CodeSnippet?; var marker: String?; var step: Int }
    private(set) var suspended: [Int: Suspended] = [:]

    private func suspend(_ walkthrough: CodingWalkthrough, answerID: Int) {
        suspended[answerID] = Suspended(walkthrough: walkthrough, snippet: snippet, marker: walkthroughMarker, step: stepIndex)
        while suspended.count > 4, let oldest = suspended.keys.min() { suspended[oldest] = nil }
    }

    var currentBlock: WalkthroughBlock? {
        guard let walkthrough, walkthroughSteps.indices.contains(stepIndex) else { return nil }
        return walkthrough.blocks[walkthroughSteps[stepIndex].block]
    }
    var atLastStep: Bool { stepIndex >= walkthroughSteps.count - 1 }

    /// Starts the walkthrough of an answer whose first explanation the engine has already presented.
    func startWalkthrough(_ walkthrough: CodingWalkthrough, snippet: CodeSnippet?, answerID: Int, endMarker: String?, display: Bool = true) {
        if self.walkthrough?.id == walkthrough.id, self.answerID == answerID {
            return DiagnosticLog.shared.record(.pipeline, "Duplicate walkthrough activation suppressed (answer #\(answerID))")
        }
        cancel(reason: nil)
        snippetID += 1
        let id = snippetID
        self.walkthrough = walkthrough
        self.snippet = snippet
        self.answerID = answerID
        mode = .tutor
        walkthroughMarker = endMarker
        walkthroughPaused = false
        let layout = effectiveCodeLayout
        walkthroughSteps = Self.steps(for: walkthrough, layout: layout)
        stepIndex = 0
        transitionToken += 1
        let token = transitionToken
        DiagnosticLog.shared.record(.pipeline, "Code Tutor walkthrough #\(id) activated (answer #\(answerID)): \(walkthrough.blocks.count) blocks, \(walkthroughSteps.count) steps; code layout \(layout.rows)x\(layout.charactersPerRow)\(codeLayout.verified ? " (verified)" : " (not yet verified on the glasses)")")
        onShown()
        pendingEarlySkeleton = nil
        if display { Task { await showStep(id, token: token) } }
    }

    /// Code layout used on the lens: the calibrated code layout, never taller than the caption rows.
    var effectiveCodeLayout: CodeDisplayLayout {
        var layout = codeLayout
        let lensRows = presenter.frameRows ?? presenter.viewportRows
        if layout.rows > lensRows {
            DiagnosticLog.shared.record(.pipeline, "Code layout overflow: \(layout.rows) rows > \(lensRows) lens rows; using \(lensRows)")
            layout.rows = lensRows
        }
        return layout
    }

    /// Lens steps: one per explanation; a code block becomes one or more pages from the code paginator
    /// (code layout, not the sentence wrapper). Deterministic for a given layout.
    static func steps(for walkthrough: CodingWalkthrough, layout: CodeDisplayLayout) -> [WalkthroughStep] {
        var steps: [WalkthroughStep] = []
        for block in walkthrough.blocks {
            guard block.kind.isCode else { steps.append(WalkthroughStep(block: block.index, part: 0, parts: 1, rows: [])); continue }
            let (pages, report) = CodePaginator.paginate(block.text, layout: layout)
            DiagnosticLog.shared.record(.pipeline, "Code pagination \(block.id): \(report.summary) at \(layout.rows)x\(layout.charactersPerRow)")
            for page in pages { steps.append(WalkthroughStep(block: block.index, part: page.part, parts: page.parts, rows: page.rows)) }
        }
        return steps
    }

    static func steps(for walkthrough: CodingWalkthrough, width: Int, lines: Int) -> [WalkthroughStep] {
        steps(for: walkthrough, layout: CodeDisplayLayout(rows: lines, charactersPerRow: width))
    }

    // MARK: Transition coordinator: the only way the walkthrough position changes

    enum TransitionSource: String, Sendable {
        case manual, command, reading, semantic, aiCheck, timer, editor, restart
        var automatic: Bool { [.reading, .semantic, .aiCheck, .timer, .editor].contains(self) }
    }
    /// Bumped by every authorized transition (and by start/end); async work from an older token is void.
    private(set) var transitionToken = 0

    /// Authorizes and performs one move. Automatic sources must still see the step and block they evaluated,
    /// the walkthrough's answer on the teleprompter, and no pause or new question taking priority.
    @discardableResult
    func requestTransition(by delta: Int, source: TransitionSource, expectedStep: Int? = nil, expectedBlockID: String? = nil,
                           reason: String) -> Bool {
        guard let walkthrough else { return false }
        var rejection: String?
        if let expectedStep, expectedStep != stepIndex { rejection = "the walkthrough already moved" }
        else if let expectedBlockID, expectedBlockID != currentBlock?.id { rejection = "the block changed" }
        else if !walkthroughSteps.indices.contains(stepIndex + delta) { rejection = "no step there" }
        else if source.automatic, walkthroughPaused { rejection = "paused" }
        else if source.automatic, interrupted { rejection = "a new question is being answered" }
        else if source.automatic, presenter.answerID != (answerID ?? walkthrough.answerID) { rejection = "another answer is active" }
        if let rejection {
            DiagnosticLog.shared.record(.pipeline, "Walkthrough transition rejected (\(source.rawValue)): \(rejection)")
            return false
        }
        if !source.automatic, adaptiveMode != .off, source != .restart { DiagnosticLog.shared.record(.pipeline, "Walkthrough manual override (\(source.rawValue))") }
        if source.automatic { evidenceAt = Date() }
        stepIndex += delta
        transitionToken += 1
        let id = snippetID, token = transitionToken
        DiagnosticLog.shared.record(.pipeline, "Walkthrough transition authorized (\(source.rawValue)): \(reason) -> step \(stepIndex + 1)/\(walkthroughSteps.count)")
        Task { await showStep(id, token: token) }
        return true
    }

    func walkthroughNext(reason: String = "Next", source: TransitionSource = .manual) {
        requestTransition(by: 1, source: source, reason: reason)
    }
    func walkthroughPrevious(reason: String = "Previous", source: TransitionSource = .manual) {
        requestTransition(by: -1, source: source, reason: reason)
    }

    /// Shows the current step again (after a temporary editor caption covered it).
    func redisplayCurrentStep() {
        guard walkthrough != nil else { return }
        transitionToken += 1
        let id = snippetID, token = transitionToken
        Task { await showStep(id, token: token) }
    }

    func restartWalkthrough() {
        guard walkthrough != nil, stepIndex > 0 else { return }
        requestTransition(by: -stepIndex, source: .restart, reason: "Restart")
    }

    /// The utterance in progress (partials seen, final not yet): it may belong to the previous block.
    private var utteranceInProgress = false

    // MARK: Coding Skeleton Mode: early skeleton

    /// A validated skeleton of a still-streaming answer, on the glasses (overlay id = -answerID).
    private(set) var earlySkeleton: (answerID: Int, rows: [String])?
    /// Waiting for the wearer to finish their sentence: a skeleton never interrupts a spoken explanation.
    private(set) var pendingEarlySkeleton: (answerID: Int, rows: [String])?

    func showEarlySkeleton(_ code: String, answerID: Int) {
        guard let rows = CodePaginator.paginate(code, layout: effectiveCodeLayout).pages.first?.rows, !rows.isEmpty else { return }
        if utteranceInProgress {
            pendingEarlySkeleton = (answerID, rows)
            return DiagnosticLog.shared.record(.pipeline, "Skeleton for answer #\(answerID) ready; waiting for the end of your sentence")
        }
        displayEarlySkeleton(answerID: answerID, rows: rows)
    }

    private func displayEarlySkeleton(answerID: Int, rows: [String]) {
        pendingEarlySkeleton = nil
        earlySkeleton = (answerID, rows)
        DiagnosticLog.shared.record(.pipeline, "Skeleton for answer #\(answerID) shown while the walkthrough is generated")
        Task { _ = await presenter.showOverlay(rows, id: -answerID, persistent: true) }
    }

    /// The answer behind an early skeleton failed or was cancelled: the skeleton leaves the glasses.
    func withdrawEarlySkeleton(answerID: Int) {
        if pendingEarlySkeleton?.answerID == answerID { pendingEarlySkeleton = nil }
        guard earlySkeleton?.answerID == answerID else { return }
        earlySkeleton = nil
        DiagnosticLog.shared.record(.pipeline, "Early skeleton for answer #\(answerID) withdrawn")
        Task { await presenter.endOverlay(id: -answerID) }
    }

    /// Presents a skeleton-first walkthrough: the skeleton and the answer in one write (no flash of text).
    func presentWalkthrough(_ walkthrough: CodingWalkthrough, snippet: CodeSnippet?, answerID: Int, endMarker: String?) async {
        startWalkthrough(walkthrough, snippet: snippet, answerID: answerID, endMarker: endMarker, display: false)
        await showStep(snippetID, token: transitionToken)
    }

    /// Speech while an explanation block is shown (partials and finals). Advances only on enough evidence
    /// that the block was explained — verbatim or in the wearer's own words — never on silence alone.
    func walkthroughSpeech(_ text: String, isFinal: Bool, alignmentProgress: Double = 0, alignmentConfidence: Double = 0,
                           readingComplete: Bool = false) {
        utteranceInProgress = !isFinal && !text.isEmpty
        if !utteranceInProgress, let pending = pendingEarlySkeleton { displayEarlySkeleton(answerID: pending.answerID, rows: pending.rows) }
        guard let walkthrough, var current = evaluator, let block = currentBlock, !block.kind.isCode, !atLastStep else { return }
        guard !walkthroughPaused, !interrupted, adaptiveMode != .off else { return }
        current.mode = adaptiveMode
        current.ingest(text, isFinal: isFinal)
        evaluator = current
        heardText = isFinal ? heardText + " " + text : heardText
        // Explanation -> code is strict: code must never cover text the wearer is still reading.
        let strict = walkthroughSteps.indices.contains(stepIndex + 1) && walkthrough.blocks[walkthroughSteps[stepIndex + 1].block].kind.isCode
        let evaluation = current.evaluate(alignmentProgress: alignmentProgress, alignmentConfidence: alignmentConfidence,
                                          readingComplete: readingComplete, utteranceEnded: isFinal, strict: strict)
        lastEvaluation = evaluation
        if evaluation.advance { return advanceAutomatically(evaluation, from: block, source: readingComplete ? .reading : .semantic) }
        if !nextPrepared, evaluation.coverage >= 0.5 {
            nextPrepared = true // steps are rendered when the walkthrough starts; this marks the anticipation point
            DiagnosticLog.shared.record(.pipeline, "Walkthrough \(block.id): next block ready (coverage \(Int(evaluation.coverage * 100))%)")
        }
        guard isFinal else { return }
        DiagnosticLog.shared.record(.pipeline, String(format: "Walkthrough %@: premature transition rejected (%@; coverage %.2f, relevance %.2f, alignment %.2f, completion %.2f)",
                                                      block.id, evaluation.reason, evaluation.coverage, evaluation.relevance, evaluation.alignment, evaluation.completion))
        if evaluation.borderline, !judgeAsked, let judge = semanticJudge {
            judgeAsked = true
            let index = stepIndex, heard = heardText
            Task {
                guard await judge(block.text, heard) == true else { return }
                var judged = evaluation
                judged.reason = "AI check: the explanation was covered"
                advanceAutomatically(judged, from: block, source: .aiCheck, step: index)
            }
        }
    }

    /// A paired editor's report for the shown code step. Text presence is evidence, not proof: the error
    /// count (when reported) must be zero, and nothing advances without a report for this exact block.
    func editorProgress(_ progress: EditorProgress) {
        guard walkthrough != nil, let block = currentBlock, block.kind.isCode, progress.blockID == block.id else { return }
        let verdict = CodeStructures.complete(expected: expectedStructures, present: progress.present, errors: progress.errors, mode: adaptiveMode)
        editorStatus = verdict.reason
        DiagnosticLog.shared.record(.pipeline, "Walkthrough \(block.id): \(verdict.reason)")
        guard verdict.done, !atLastStep else { return }
        requestTransition(by: 1, source: .editor, expectedStep: stepIndex, expectedBlockID: block.id, reason: verdict.reason)
    }

    private func advanceAutomatically(_ evaluation: WalkthroughCompletionEvaluator.Evaluation, from block: WalkthroughBlock,
                                      source: TransitionSource, step: Int? = nil) {
        DiagnosticLog.shared.record(.pipeline, String(format: "Walkthrough %@: automatic transition attempted (%@; coverage %.2f, alignment %.2f, completion %.2f)",
                                                      block.id, evaluation.reason, evaluation.coverage, evaluation.alignment, evaluation.completion))
        requestTransition(by: 1, source: source, expectedStep: step ?? stepIndex, expectedBlockID: block.id, reason: evaluation.reason)
    }

    /// Restores a walkthrough that another answer replaced (Undo), at the block where it was.
    @discardableResult
    func resumeSuspended(answerID: Int) -> Bool {
        guard let saved = suspended[answerID] else { return false }
        suspended[answerID] = nil
        startWalkthrough(saved.walkthrough, snippet: saved.snippet, answerID: answerID, endMarker: saved.marker)
        stepIndex = min(saved.step, max(0, walkthroughSteps.count - 1))
        transitionToken += 1 // the start's own step-0 display is now void
        let id = snippetID, token = transitionToken
        DiagnosticLog.shared.record(.pipeline, "Walkthrough restored at step \(stepIndex + 1) (undo)")
        Task { await showStep(id, token: token) }
        return true
    }

    func pauseWalkthrough() {
        walkthroughPaused = true
        stepTimer?.cancel()
        status = "Walkthrough paused (Next and Previous still work)"
    }

    func resumeWalkthrough() {
        walkthroughPaused = false
        scheduleStepTimer(snippetID)
        status = "Walkthrough resumed"
    }

    private func showStep(_ id: Int, token: Int) async {
        guard id == snippetID, token == transitionToken, let walkthrough, walkthroughSteps.indices.contains(stepIndex) else { return }
        stepTimer?.cancel()
        let index = stepIndex
        let step = walkthroughSteps[index]
        let block = walkthrough.blocks[step.block]
        if block.kind.isCode {
            evaluator = nil
            if step.part == 0 {
                let structures = CodeStructures.expected(from: block.text)
                expectedStructures = structures.count
                editorStatus = nil
                onCodeStep(block.id, block.language ?? walkthrough.language, structures)
            }
            let target = answerID ?? walkthrough.answerID
            let submitted: Bool
            if presenter.answerID != target, let explanation = walkthrough.blocks.first(where: { $0.kind == .explanation }) {
                // The walkthrough's answer is not on the teleprompter yet (skeleton first): one atomic write.
                presentingExplanation = true
                await presenter.present(explanation.text, answerID: target, overlay: (id, step.rows))
                presentingExplanation = false
                submitted = presenter.lastWrite?.answerID == target && presenter.lastWrite?.result.hasPrefix("handed") == true
            } else {
                submitted = await presenter.showOverlay(step.rows, id: id, persistent: true)
            }
            earlySkeleton = nil
            logEvidenceLatency(submitted)
            DiagnosticLog.shared.record(.pipeline, "Code frame \(block.id) part \(step.part + 1)/\(step.parts): \(step.rows.count) rows "
                                        + (submitted ? "submitted to Bluetooth (visibility not confirmed by the glasses)" : "held: glasses not ready"))
            guard id == snippetID, token == transitionToken, stepIndex == index else { return }
            status = "Block \(step.block + 1)/\(walkthrough.blocks.count) · \(block.kind.label)\(step.parts > 1 ? " part \(step.part + 1)/\(step.parts)" : "")"
                + (submitted ? " on glasses" : " (glasses not ready; shown when they return)")
            if submitted { scheduleStepTimer(id) }
        } else {
            // Another answer took over the teleprompter: the walkthrough is over.
            guard presenter.answerID == (answerID ?? walkthrough.answerID) else { return endWalkthrough(status: "Walkthrough closed (another answer replaced it)") }
            var fresh = WalkthroughCompletionEvaluator(blockID: block.id, text: block.text, mode: adaptiveMode)
            // An utterance that started before this block appeared belongs to what was read before.
            fresh.skipUntilFinal = utteranceInProgress
            evaluator = fresh
            heardText = ""; judgeAsked = false; nextPrepared = false
            presentingExplanation = true
            let last = step.block == walkthrough.blocks.count - 1
            await presenter.present(block.text, answerID: answerID ?? walkthrough.answerID, endMarker: last ? walkthroughMarker : nil)
            presentingExplanation = false
            logEvidenceLatency(presenter.lastWrite?.result.hasPrefix("handed") == true)
            guard id == snippetID, token == transitionToken, stepIndex == index else { return }
            status = "Block \(step.block + 1)/\(walkthrough.blocks.count) · \(block.kind.label) on glasses (read it aloud to continue)"
        }
    }

    /// Time from completion evidence to the next block's caption being handed to Bluetooth.
    private func logEvidenceLatency(_ submitted: Bool) {
        guard let evidenceAt else { return }
        self.evidenceAt = nil
        DiagnosticLog.shared.record(.pipeline, String(format: "Walkthrough: completion evidence → caption %@ in %.0f ms",
                                                      submitted ? "submitted" : "held (glasses not ready)", Date().timeIntervalSince(evidenceAt) * 1000))
    }

    private func scheduleStepTimer(_ id: Int) {
        guard walkthroughCodeSeconds > 0, !walkthroughPaused, currentBlock?.kind.isCode == true, !atLastStep else { return }
        let index = stepIndex, seconds = walkthroughCodeSeconds
        stepTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, id == self.snippetID else { return }
            self.requestTransition(by: 1, source: .timer, expectedStep: index, reason: "code timer (\(Int(seconds)) s)")
        }
    }

    private func endWalkthrough(status: String) {
        guard let walkthrough else { return }
        transitionToken += 1
        if let answerID { suspend(walkthrough, answerID: answerID) }
        evaluator = nil
        stepTimer?.cancel()
        self.walkthrough = nil
        walkthroughSteps = []
        stepIndex = 0
        self.status = status
        onEnded()
    }

    func show(_ snippet: CodeSnippet, answerID: Int, mode: Mode = .preview) {
        if isActive, self.answerID == answerID, self.snippet == snippet, self.mode == mode {
            return DiagnosticLog.shared.record(.pipeline, "Duplicate code activation suppressed (answer #\(answerID))")
        }
        cancel(reason: nil)
        snippetID += 1
        let id = snippetID
        self.snippet = snippet
        self.answerID = answerID
        self.mode = mode
        let width = presenter.effectiveLayout.width, lines = presenter.windowLines
        frames = mode == .tutor ? snippet.tutorPages(width: width, lines: lines) : snippet.lensFrames(width: width, lines: lines)
        frameIndex = 0
        if mode == .tutor {
            tutorActive = true
            DiagnosticLog.shared.record(.pipeline, "Code Tutor activated #\(id) (answer #\(answerID)): \(frames.count) step page(s)")
            Task { await showTutorPage(id) }
        } else {
            DiagnosticLog.shared.record(.pipeline, "Code snippet #\(id) (answer #\(answerID)): \(frames.count) frame(s), \(Int(duration)) s each")
            task = Task { [weak self] in await self?.run(id) }
        }
    }

    func nextStep() { moveStep(by: 1) }
    func previousStep() { moveStep(by: -1) }

    private func moveStep(by delta: Int) {
        guard tutorActive, frames.indices.contains(frameIndex + delta) else { return }
        frameIndex += delta
        let id = snippetID
        Task { await showTutorPage(id) }
    }

    private func showTutorPage(_ id: Int) async {
        guard id == snippetID, tutorActive, frames.indices.contains(frameIndex) else { return }
        let submitted = await presenter.showOverlay(frames[frameIndex], id: id)
        guard id == snippetID, tutorActive else { return }
        guard submitted else { return expired(id, reason: "not sent: glasses not ready") }
        if frameIndex == 0 { onShown() }
        status = "Code Tutor step \(frameIndex + 1)/\(frames.count) on glasses"
        DiagnosticLog.shared.record(.pipeline, "Code Tutor #\(id) step \(frameIndex + 1)/\(frames.count) handed to Bluetooth")
    }

    /// Ends the snippet or tutor now (new answer, user action) and returns the lens to the answer.
    func cancel(reason: String? = "dismissed") {
        guard isActive else { return }
        task?.cancel()
        task = nil
        tutorActive = false
        stepTimer?.cancel()
        if let walkthrough, let answerID { suspend(walkthrough, answerID: answerID) }
        walkthrough = nil
        walkthroughSteps = []
        evaluator = nil
        remaining = 0
        if let reason { status = "Code hidden (\(reason))" }
        let id = snippetID
        Task { await presenter.endOverlay(id: id) }
        onEnded()
    }

    private func run(_ id: Int) async {
        for index in frames.indices {
            guard id == snippetID, !Task.isCancelled else { return }
            frameIndex = index
            let submitted = await presenter.showOverlay(frames[index], id: id)
            guard id == snippetID, !Task.isCancelled else { return }
            guard submitted else { return expired(id, reason: "not sent: glasses not ready") }
            if index == 0 { onShown() }
            DiagnosticLog.shared.record(.pipeline, "Code snippet #\(id) frame \(index + 1)/\(frames.count) handed to Bluetooth; \(Int(duration)) s window started")
            remaining = duration
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(min(tick, remaining)))
                guard id == snippetID, !Task.isCancelled else { return }
                remaining = max(0, remaining - tick)
                status = "Code \(index + 1)/\(frames.count) on glasses · \(Int(remaining.rounded(.up))) s left"
            }
        }
        guard id == snippetID else { return }
        DiagnosticLog.shared.record(.pipeline, "Code snippet #\(id) expired; returning to the answer")
        await presenter.endOverlay(id: id)
        finish(id, status: "Code shown for \(Int(duration)) s per frame; back to the answer")
    }

    private func expired(_ id: Int, reason: String) {
        guard id == snippetID, isActive else { return }
        DiagnosticLog.shared.record(.pipeline, "Code #\(id) ended: \(reason)")
        task?.cancel()
        Task { await presenter.endOverlay(id: id) }
        finish(id, status: mode == .tutor ? "Code Tutor closed (\(reason))" : "Code expired (\(reason))")
    }

    private func finish(_ id: Int, status: String) {
        guard id == snippetID else { return }
        task = nil
        tutorActive = false
        remaining = 0
        self.status = status
        onEnded()
    }

    func copyToPasteboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = snippet?.code
        #endif
    }
}
