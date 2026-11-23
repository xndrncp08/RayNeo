import SwiftUI

struct DashboardView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    private var engine: ConversationEngine { model.engine }
    private var presenter: GlassesPresenter { model.presenter }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.lastError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if let ble = model.rayNeo, ble.connectionState == .sessionUnconfirmed, ble.activeSessionMode == .caption,
                   !model.settings.allowUnconfirmedGlassesSend {
                    Section {
                        Label("AI answers are held: the caption session was never acknowledged and Caption compatibility mode is off.", systemImage: "eyeglasses")
                            .foregroundStyle(.orange)
                        Button("Enable Caption compatibility mode") { model.settings.allowUnconfirmedGlassesSend = true }
                    }
                }
                if model.sessionActive || model.snippets.snippet != nil { ConversationPanel(model: model) }
                if model.editor.connected || model.editorAssistant.help != nil { EditorPanel(model: model) }
                Section("Glasses") {
                    GlassesPreviewView(presenter: presenter, reading: model.reading)
                    HStack {
                        Button("Clear Display", systemImage: "xmark.rectangle") { Task { await presenter.clearDisplay() } }
                            .disabled(presenter.pages.isEmpty || presenter.cleared)
                        Spacer()
                        Button("Next Answer", systemImage: "forward.fill") { engine.nextQuestion() }
                            .disabled(!model.sessionActive || engine.pendingQuestion == nil)
                    }
                    .buttonStyle(.bordered)
                    .font(.callout)
                    if model.settings.showOutgoingCaption { OutgoingCaptionView(presenter: presenter) }
                }
                if !presenter.pages.isEmpty { Section("Reading") { ReadingControlsView(model: model) } }
                Section("Answer") { answerSection }
                Section("Live transcript") { TranscriptView(model: model) }
                Section("Status") { statusRows }
                Section("Diagnostics") { DiagnosticsView(model: model) }
            }
            .navigationTitle("RayPrompt")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { RayNeoDiagnosticsView(model: model) } label: { Label("RayNeo diagnostics", systemImage: "antenna.radiowaves.left.and.right") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(isPresented: $model.showConsent) { ConsentView(model: model) }
        }
    }

    @ViewBuilder private var answerSection: some View {
        LabeledContent("State", value: engine.state.label)
        if let question = engine.currentQuestion {
            VStack(alignment: .leading, spacing: 4) {
                Text("Question").font(.caption).foregroundStyle(.secondary)
                Text(question.text).font(.callout)
                if question.isFollowUp { Text("Follow-up").font(.caption2).foregroundStyle(.blue) }
            }
        }
        if !engine.streamingText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Generating…").font(.caption).foregroundStyle(.secondary)
                Text(engine.streamingText).font(.callout).foregroundStyle(.secondary)
            }
        }
        if let answer = engine.currentAnswer {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Displayed answer · \(answer.category.rawValue)").font(.caption).foregroundStyle(.secondary)
                    if engine.isLocked { Label("Locked", systemImage: "lock.fill").font(.caption).foregroundStyle(.green) }
                }
                Text(answer.text).font(.body).textSelection(.enabled)
            }
        }
        if let pending = engine.pendingQuestion {
            VStack(alignment: .leading, spacing: 6) {
                Text("Queued question (answer preserved)").font(.caption).foregroundStyle(.orange)
                Text(pending.text).font(.callout)
                HStack {
                    Button("Answer it now") { engine.nextQuestion() }.buttonStyle(.borderedProminent)
                    Button("Dismiss") { engine.dismissPending() }.buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var statusRows: some View {
        LabeledContent("Glasses", value: "\(presenter.display.name): \(presenter.connectionState.label)")
        LabeledContent("Microphone") {
            HStack(spacing: 6) {
                if model.sessionActive {
                    Circle().fill(.red).frame(width: 8, height: 8).accessibilityLabel("Microphone active")
                }
                Text(model.micStatus)
            }
        }
        LabeledContent("Input", value: model.inputName)
        LabeledContent("Speech", value: model.speechStatus)
        LabeledContent("AI model", value: model.aiProvider.status.label)
        if model.sessionActive {
            ProgressView(value: Double(max(0, min(1, (model.levelDB + 70) / 60))))
                .accessibilityLabel("Input level")
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                if model.sessionActive {
                    Button(role: .destructive) { Task { await model.stopSession() } } label: {
                        Label("Stop Session", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { model.requestStart() } label: {
                        Label("Start Session", systemImage: "mic.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
            }
            HStack {
                if engine.isLocked {
                    Button("Unlock", systemImage: "lock.open") { engine.unlock() }
                } else {
                    Button("Lock", systemImage: "lock") { engine.lock() }.disabled(engine.currentAnswer == nil)
                }
                Spacer()
                Button("Next", systemImage: "forward.fill") { engine.nextQuestion() }.disabled(!model.sessionActive).accessibilityLabel("Next question")
                Spacer()
                Button("Connect", systemImage: "eyeglasses") { model.connectGlasses() }
            }
            .buttonStyle(.bordered)
            .font(.callout)
        }
        .padding()
        .background(.bar)
    }
}

struct GlassesPreviewView: View {
    let presenter: GlassesPresenter
    let reading: ReadingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presenter.currentPage ?? "—")
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                .padding(12)
                .background(.black, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Glasses display: \(presenter.currentPage ?? "empty")")
            HStack {
                Text(presenter.display.isSimulated ? "Simulated display" : "Mirror of text sent to RayNeo iO (delivery ≠ visible)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if presenter.pages.count > 1 {
                    Button("Previous section", systemImage: "chevron.left") { reading.previousSection() }
                        .labelStyle(.iconOnly).disabled(presenter.pageIndex == 0)
                    Text("\(presenter.pageIndex + 1)/\(presenter.pages.count)").font(.caption).monospacedDigit()
                    Button("Next section", systemImage: "chevron.right") { reading.nextSection() }
                        .labelStyle(.iconOnly).disabled(presenter.pageIndex + 1 >= presenter.pages.count)
                }
            }
            .buttonStyle(.borderless)
            if !presenter.display.isSimulated {
                Text(presenter.deliveryStatus).font(.caption2).foregroundStyle(.secondary)
            }
            if let error = presenter.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}

/// Opt-in local debug view: the exact text last handed to the glasses, with spaces shown as "·" and
/// line breaks as "⏎", so source-text problems can be told apart from lens rendering.
struct OutgoingCaptionView: View {
    let presenter: GlassesPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Exact outgoing caption (debug)").font(.caption2).foregroundStyle(.secondary)
            if let text = presenter.outgoingCaption {
                Text(CaptionLabView.visible(text))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let write = presenter.lastWrite { Text(write.summary).font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text("Nothing sent yet").font(.caption)
            }
        }
    }
}

/// Reading mode, progress and auto-scroll controls. Usable while a session is running.
struct ReadingControlsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let reading = model.reading
        let synced = reading.mode == .speechSynced
        Picker("Reading mode", selection: $model.settings.readingMode) {
            ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        if synced {
            Picker("Teleprompter Look-Ahead", selection: $model.settings.readingResponsiveness) {
                ForEach(ReadingResponsiveness.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.settings.lookaheadWindows
                 ? "Look-ahead windows: the next lines appear before you finish (frame replacement verified)."
                 : "Non-overlapping frames: look-ahead windows need Lab X verification (Calibration).")
                .font(.caption2).foregroundStyle(.secondary)
            ProgressView(value: reading.progress) {
                Text("Word \(max(0, reading.cursorWord + 1))/\(reading.totalWords) · top line \(reading.position + 1)/\(reading.positionCount) · confidence \(reading.confidence, format: .number.precision(.fractionLength(2)))")
                    .font(.caption)
            }
            Text(reading.lastDecision).font(.caption2).foregroundStyle(.secondary)
            Text("Reading line \(reading.readingLine.map { "\($0 + 1)" } ?? "–") · unread lines on screen \(reading.remainingUnreadLines.map(String.init) ?? "–") · next frame prepared \(model.presenter.prepared.map { "\($0.index + 1)" } ?? "–")\(reading.readingComplete ? " · reading complete" : "")")
                .font(.caption2).foregroundStyle(.secondary)
            if let latency = model.presenter.lastScrollLatencyMs {
                Text("Reading boundary → caption handed to Bluetooth: \(Int(latency)) ms · coalesced \(model.presenter.coalescedRequests)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(reading.autoScrollPaused ? "Resume Auto-Scroll" : "Pause Auto-Scroll",
                   systemImage: reading.autoScrollPaused ? "play.fill" : "pause.fill") {
                reading.autoScrollPaused ? reading.resumeAutoScroll() : reading.pauseAutoScroll()
            }
        }
        HStack {
            Button(synced ? "Back One Line" : "Previous Section", systemImage: synced ? "chevron.up" : "backward.end") { reading.previousSection() }
            Spacer()
            Button(synced ? "Forward One Line" : "Next Section", systemImage: synced ? "chevron.down" : "forward.end") { reading.nextSection() }
        }
        .buttonStyle(.bordered)
        Button("Reset to Beginning", systemImage: "arrow.counterclockwise") { reading.resetProgress() }
            .font(.callout)
    }
}

struct TranscriptView: View {
    let model: AppModel

    var body: some View {
        // Finalized turns only (revisions replace their turn); the live hypothesis is shown separately.
        let turns = model.finalizedTurns.suffix(8)
        if turns.isEmpty && model.volatileText.isEmpty {
            Text(model.sessionActive ? "Listening…" : "Start a session to transcribe.").foregroundStyle(.secondary)
        }
        ForEach(turns) { turn in
            VStack(alignment: .leading, spacing: 2) {
                if let role = turn.role, role != "Interviewer" {
                    Text(role).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(turn.normalized).font(.callout).foregroundStyle(turn.role == nil || turn.role == "Interviewer" ? .primary : .secondary)
                if model.settings.transcriptDebug {
                    Text("#\(turn.id) rev \(turn.revision) · raw: \(turn.original)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        if !model.volatileText.isEmpty { Text(model.volatileText).font(.callout).foregroundStyle(.secondary).italic() }
        if !model.finalizedTurns.isEmpty {
            Button("Clear transcript", role: .destructive) { model.clearTranscript() }.font(.caption)
        }
    }
}

struct DiagnosticsView: View {
    let model: AppModel
    private let log = DiagnosticLog.shared

    var body: some View {
        let engine = model.engine
        let d = model.diagnostics
        DisclosureGroup("Latency, memory, filtering") {
            row("Audio input latency", d.audioLatencyMs.map { String(format: "%.0f ms", $0) })
            row("Recognition lag (end of speech → final)", d.recognitionLatency.map { String(format: "%.2f s", $0) })
            row("Question classification", engine.lastClassificationSeconds.map { String(format: "%.0f ms", $0 * 1000) })
            row("Answer ID (pipeline · lock · glasses · reading)",
                "\(engine.generatingAnswerID.map { "#\($0)" } ?? "–") · \(engine.currentAnswer.map { "#\($0.answerID)" } ?? "–") · #\(model.presenter.answerID) · #\(model.reading.answerID)")
            row("Early frames replaced by validation", engine.earlyFrameReplacements == 0 ? nil : "\(engine.earlyFrameReplacements)")
            row("Answered by", engine.currentAnswer.map { $0.provider.isEmpty ? $0.category.rawValue : "\($0.provider) · \($0.category.rawValue)" })
            row("Generation", engine.currentAnswer.map { $0.generationComplete ? "complete ✓" : $0.completion })
            row("End marker", model.presenter.markerDeferred ? "deferred (final frame was already on the lens)" : model.presenter.endMarker.map { "on final frame: \($0)" })
            row("AI first token", engine.currentAnswer?.firstTokenSeconds.map { String(format: "%.2f s", $0) })
            row("First frame submitted to Bluetooth", engine.currentAnswer?.frameSubmittedSeconds.map { String(format: "%.2f s (not proof of visibility)", $0) })
            row("First complete sentence", engine.currentAnswer?.firstSentenceSeconds.map { String(format: "%.2f s", $0) })
            row("Early first frame shown", engine.currentAnswer?.earlyFrameSeconds.map { String(format: "%.2f s", $0) })
            row("Gemini network latency", model.gemini?.lastNetworkSeconds.map { String(format: "%.2f s", $0) })
            row("AI total", engine.currentAnswer.map { String(format: "%.2f s%@", $0.totalSeconds, $0.fromCache ? " (cache)" : "") })
            row("Glasses write", model.presenter.lastSendSeconds.map { String(format: "%.0f ms", $0 * 1000) })
            row("Memory footprint", String(format: "%.0f MB", d.memoryMB))
            row("Thermal state", d.thermalState)
            row("Recognizer restarts", "\(d.recognitionRestarts)")
            let c = engine.counters
            row("Suppressed", "echo \(c.echo) · wearer \(c.wearer) · non-question \(c.notQuestion) · duplicate \(c.duplicate)")
            row("Queued / auto-advanced", "\(c.queued) / \(c.autoAdvanced)")
            if model.settings.debugLogging {
                ForEach(engine.log.suffix(30).reversed()) { entry in
                    Text("\(entry.date.formatted(date: .omitted, time: .standard)) \(entry.message)").font(.caption2.monospaced())
                }
            }
        }
        DisclosureGroup("Session / audio / Bluetooth timeline (\(log.entries.count))") {
            HStack {
                ShareLink("Export log", item: log.text)
                Spacer()
                Button("Clear", role: .destructive) { log.clear() }
            }
            .buttonStyle(.borderless)
            ForEach(log.entries.suffix(80).reversed()) { entry in
                Text(entry.line).font(.caption2.monospaced()).textSelection(.enabled)
            }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: value ?? "—").font(.caption)
    }
}

struct ConsentView: View {
    let model: AppModel
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Session", selection: Bindable(model).settings.sessionPurpose) {
                        ForEach(SessionPurpose.allCases) { Text($0.label).tag($0) }
                    }
                    Text("This session continuously listens with the iPhone microphone and transcribes speech on this device.\(model.settings.continuousConversation ? " Continuous conversation is on: every turn is classified and follow-up answers can replace the current one automatically." : "")")
                    Text(model.settings.aiModel == .geminiFlash
                         ? "Answers come from Gemini: each question\(model.settings.geminiIncludePortfolio ? ", your relevant memory and recent conversation" : "") is sent to Google's servers. Audio is never sent or saved."
                         : "Answers are generated on this iPhone. Audio is never saved and nothing is uploaded.")
                    Text("Transcripts and conversation memory stay in memory on this iPhone and are discarded when the session ends.")
                    Text("Use live assistance only where everyone present has agreed to transcription and AI assistance. Stop the session immediately if anyone objects.")
                }
                if model.settings.sessionPurpose == .live {
                    Section { Toggle("Everyone present knows and agrees", isOn: $confirmed) }
                }
            }
            .navigationTitle("Before you start")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.showConsent = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await model.startSession() } }.disabled(model.settings.sessionPurpose == .live && !confirmed)
                }
            }
        }
    }
}

/// Live conversation status: indicators, mute, classification, pending follow-up, undo and code snippet.
struct ConversationPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let engine = model.engine
        Section("Conversation") {
            HStack {
                Label(model.muted ? "Muted" : "Listening", systemImage: model.muted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(model.muted ? .orange : .red)
                if model.settings.aiModel == .geminiFlash {
                    Label("Sending to Google", systemImage: "cloud.fill").foregroundStyle(.blue)
                }
                Spacer()
                Text(model.settings.sessionPurpose == .practice ? "Practice" : "Live").font(.caption.bold())
            }
            .font(.caption)
            Button(model.muted ? "Unmute" : "Mute", systemImage: model.muted ? "mic.fill" : "mic.slash") { model.muted.toggle() }
            LabeledContent("Phase", value: engine.phase.rawValue)
            if let event = engine.lastClassification {
                LabeledContent("Last speech", value: "\(event.kind.label) · \(event.tier.rawValue) \(String(format: "%.2f", event.confidence))")
            }
            if let topic = model.conversation.topic { LabeledContent("Topic", value: topic) }
            if !model.lastMemoryReferences.isEmpty {
                LabeledContent("Memory used", value: model.lastMemoryReferences.joined(separator: ", "))
            }
            if let prepared = engine.preparedAnswer {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Follow-up answer ready (not shown yet)", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                    Text(prepared.question.text).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Show now") { engine.showPreparedAnswer(reason: "tapped") }.buttonStyle(.borderedProminent)
                        Button("Dismiss") { engine.dismissPrepared() }.buttonStyle(.bordered)
                    }
                }
            }
            if engine.undoAnswer != nil {
                Button("Undo last automatic transition", systemImage: "arrow.uturn.backward") { engine.undoTransition() }
            }
        }
        if let snippet = model.snippets.snippet {
            Section("Code Tutor · \(snippet.language)") {
                if !snippet.problem.isEmpty { Text(snippet.problem).font(.callout.weight(.semibold)) }
                if let walkthrough = model.snippets.walkthrough { WalkthroughView(model: model, walkthrough: walkthrough) }
                Text(model.snippets.walkthrough == nil ? "Code" : "Final solution").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    Text(CodeHighlighter.highlight(snippet.code, language: snippet.language)).font(.caption.monospaced())
                        .textSelection(.enabled).padding(.vertical, 4)
                }
                ExplainLineView(model: model, code: snippet.code)
                if !snippet.steps.isEmpty {
                    ForEach(Array(snippet.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)").font(.caption)
                            .fontWeight(model.snippets.tutorActive && model.snippets.frameIndex == index ? .bold : .regular)
                    }
                }
                if !snippet.edgeCases.isEmpty { LabeledContent("Edge cases", value: snippet.edgeCases.joined(separator: "; ")).font(.caption) }
                if let complexity = snippet.complexity { LabeledContent("Complexity", value: complexity).font(.caption) }
                if !snippet.tests.isEmpty { LabeledContent("Tests (not run)", value: snippet.tests.joined(separator: "; ")).font(.caption) }
                Text(model.snippets.status).font(.caption).foregroundStyle(.secondary)
                if model.snippets.tutorActive {
                    HStack {
                        Button("Previous step", systemImage: "chevron.left") { model.snippets.previousStep() }
                        Spacer()
                        Text("\(model.snippets.frameIndex + 1)/\(model.snippets.frames.count)").font(.caption.monospacedDigit())
                        Spacer()
                        Button("Next step", systemImage: "chevron.right") { model.snippets.nextStep() }
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("Copy Code", systemImage: "doc.on.doc") { model.snippets.copyToPasteboard() }
                    Spacer()
                    if model.snippets.isActive {
                        Button("Hide from glasses") { model.snippets.cancel() }
                    } else if let id = engine.currentAnswer?.answerID {
                        Menu("Show on glasses") {
                            Button("Code Tutor steps") { model.snippets.show(snippet, answerID: id, mode: .tutor) }
                            Button("20-second preview") { model.snippets.show(snippet, answerID: id, mode: .preview) }
                        }
                    }
                }
                .buttonStyle(.borderless)
                Text("Code is never run. Glasses visibility time is approximate: the lens does not confirm what it shows.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Minimal keyword highlighting for the iPhone code view (the glasses get plain text).
enum CodeHighlighter {
    static let keywords: Set<String> = ["function", "return", "const", "let", "var", "if", "else", "for", "while", "new", "class",
                                        "import", "export", "async", "await", "def", "in", "of", "from", "interface", "type",
                                        "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "JOIN", "AS", "SUM", "COUNT", "AND", "OR"]

    static func highlight(_ code: String, language: String) -> AttributedString {
        var result = AttributedString(code)
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z_]+|"[^"\n]*"|'[^'\n]*'|//[^\n]*|#[^\n]*|--[^\n]*"#) else { return result }
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range, in: code), let attributed = Range(range, in: result) else { continue }
            let token = String(code[range])
            if token.hasPrefix("//") || (token.hasPrefix("#") && language == "python") || token.hasPrefix("--") {
                result[attributed].foregroundColor = .secondary
            } else if token.hasPrefix("\"") || token.hasPrefix("'") {
                result[attributed].foregroundColor = .orange
            } else if keywords.contains(token) {
                result[attributed].foregroundColor = .purple
            }
        }
        return result
    }
}

/// The walkthrough timeline on the iPhone: every block, the active one highlighted, synced with the glasses.
struct WalkthroughView: View {
    let model: AppModel
    let walkthrough: CodingWalkthrough

    var body: some View {
        let snippets = model.snippets
        let active = snippets.currentBlock?.index
        VStack(alignment: .leading, spacing: 8) {
            ForEach(walkthrough.blocks) { block in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(block.index + 1). \(block.kind.label)\(block.kind == .code && !block.isComplete ? " (partial)" : "")")
                        .font(.caption2.weight(.semibold)).foregroundStyle(block.index == active ? Color.accentColor : .secondary)
                    if block.kind.isCode {
                        ScrollView(.horizontal) {
                            Text(CodeHighlighter.highlight(block.text, language: walkthrough.language)).font(.caption2.monospaced())
                        }
                    } else {
                        Text(block.text).font(.caption)
                    }
                }
                .padding(6)
                .background(block.index == active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Previous", systemImage: "chevron.left") { snippets.walkthroughPrevious() }.disabled(snippets.stepIndex == 0)
                Spacer()
                Text("Step \(snippets.stepIndex + 1)/\(snippets.walkthroughSteps.count)").font(.caption.monospacedDigit())
                Spacer()
                Button("Next", systemImage: "chevron.right") { snippets.walkthroughNext() }.disabled(snippets.atLastStep)
            }
            .buttonStyle(.borderless)
            HStack {
                Button(snippets.walkthroughPaused ? "Resume" : "Pause") {
                    snippets.walkthroughPaused ? snippets.resumeWalkthrough() : snippets.pauseWalkthrough()
                }
                Spacer()
                Button("Restart") { snippets.restartWalkthrough() }
            }
            .buttonStyle(.borderless).font(.caption)
            Picker("Adaptive", selection: Bindable(model).settings.adaptiveWalkthrough) {
                ForEach(AdaptiveWalkthroughMode.allCases) { Text($0 == .balanced ? "Balanced" : $0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            if let evaluation = snippets.lastEvaluation, snippets.currentBlock?.kind.isCode == false {
                Text("Explained \(evaluation.covered.count)/\(evaluation.covered.count + evaluation.missing.count) key ideas · \(evaluation.reason)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if snippets.currentBlock?.kind.isCode == true {
                Text(snippets.editorStatus.map { "Editor: \($0)" }
                     ?? "Code stays until you say \"next step\", tap Next, or a paired editor reports the step done. Silence never removes it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Tap a line of the final code for a short explanation (does not move the walkthrough).
struct ExplainLineView: View {
    let model: AppModel
    let code: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Explain a line", isExpanded: $expanded) {
            ForEach(Array(code.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { Task { await model.explainLine(line.trimmingCharacters(in: .whitespaces)) } } label: {
                        Text(line).font(.caption2.monospaced()).lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let explanation = model.lineExplanation, code.contains(explanation.line) {
                Text(explanation.text).font(.caption)
            }
        }
        .font(.caption)
    }
}

/// What the paired editor reports: file and function, diagnostics, help, test/build results.
struct EditorPanel: View {
    let model: AppModel

    var body: some View {
        let assistant = model.editorAssistant!
        Section("VS Code") {
            LabeledContent("Status", value: model.editor.status)
            if let file = assistant.state.file {
                LabeledContent("File", value: "\(file)\(assistant.state.line.map { " · line \($0)" } ?? "")\(assistant.state.symbol.map { " · \($0)" } ?? "")")
            }
            LabeledContent("Diagnostics", value: "\(assistant.state.errors) error(s), \(assistant.state.warnings) warning(s)")
            ForEach(Array(assistant.diagnostics.prefix(3).enumerated()), id: \.offset) { _, diagnostic in
                Text("\(diagnostic.severity) · line \(diagnostic.line.map(String.init) ?? "?"): \(diagnostic.message)").font(.caption2)
            }
            if let help = assistant.help {
                VStack(alignment: .leading, spacing: 4) {
                    Text(help.title).font(.caption.weight(.semibold))
                    Text(help.detail).font(.caption)
                    Button("Dismiss from glasses") { assistant.dismissHelp() }.font(.caption)
                }
            }
            if let status = assistant.taskStatus { LabeledContent("Last test/build", value: status) }
            if let latency = assistant.lastEventToCaptionMs {
                LabeledContent("Editor event → caption", value: "\(Int(latency)) ms (submitted, not confirmed visible)")
            }
            Toggle("Automatic step progression from the editor", isOn: Binding(get: { assistant.autoProgress }, set: { on in
                assistant.handle(EditorEvent(type: "auto", enabled: on))
            }))
        }
    }
}
