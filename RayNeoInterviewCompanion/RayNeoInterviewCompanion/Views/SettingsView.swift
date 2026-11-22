import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("About RayPrompt") {
                    Text("A hands-free AI assistant and adaptive teleprompter for smart glasses.")
                    Text("For conversations, coding, presentations, and hands-free guidance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Speech") {
                    Picker("Language", selection: $model.settings.localeIdentifier) {
                        ForEach(["en-US", "en-GB", "en-AU", "en-CA", "en-IN"], id: \.self) { Text($0) }
                    }
                    Picker("Microphone", selection: $model.settings.preferredInputUID) {
                        Text("iPhone microphone (default)").tag(String?.none)
                        ForEach(model.availableInputs) { Text($0.name).tag(Optional($0.id)) }
                    }
                    slider("End-of-turn silence", value: $model.settings.endOfTurnSilence, range: 0.6...3, format: "%.1f s")
                }
                Section {
                    Toggle("Automatic question detection", isOn: $model.settings.autoQuestionDetection)
                    slider("Question threshold (lower = more sensitive)", value: $model.settings.questionThreshold, range: 0.3...0.9, format: "%.2f")
                    Toggle("On-device semantic check for borderline phrases", isOn: $model.settings.semanticClassification)
                } header: { Text("Question detection") }
                Section {
                    Toggle("Lock answer after it is displayed", isOn: $model.settings.lockAfterDisplay)
                    Toggle("Auto-advance on a confident new question", isOn: $model.settings.autoAdvance)
                    slider("Auto-advance minimum score", value: $model.settings.autoAdvanceMinScore, range: 0.6...1, format: "%.2f")
                    slider("Minimum time an answer stays", value: $model.settings.minimumLockSeconds, range: 0...60, format: "%.0f s")
                    slider("Ignore speech matching the answer at", value: $model.settings.echoThreshold, range: 0.3...0.9, format: "%.2f")
                } header: { Text("Answer lock") } footer: {
                    Text("While locked, new questions are queued. They replace the answer only when auto-advance conditions are met or you tap Next Question.")
                }
                Section {
                    Toggle("Filter calibrated wearer voice", isOn: $model.settings.speakerFilterEnabled)
                    slider("Wearer pitch tolerance", value: $model.settings.wearerPitchTolerance, range: 1...6, format: "%.1f semitones")
                    if let profile = model.settings.wearerProfile {
                        LabeledContent("Calibrated", value: String(format: "%.0f Hz, %.0f dB", profile.medianPitchHz, profile.medianLevelDB))
                        Button("Remove calibration", role: .destructive) { model.settings.wearerProfile = nil }
                    }
                    Button(model.calibrating ? "Recording… keep talking" : "Calibrate my voice (6 s)") {
                        Task { await model.calibrateWearer() }
                    }.disabled(model.calibrating)
                } header: { Text("Speaker filtering") } footer: {
                    Text("Read any paragraph aloud at your normal speaking volume. This is a pitch/level heuristic, not voice identification; it cannot perfectly separate speakers.")
                }
                Section("AI") {
                    Picker("Model", selection: $model.settings.aiModel) {
                        ForEach(AIModelChoice.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Active", value: model.aiProvider.name)
                    LabeledContent("Status", value: model.aiProvider.status.label)
                    if model.settings.aiModel == .gemmaOnDevice || model.settings.aiModel == .auto {
                        Text("Gemma: \(GemmaProvider.blocker). Math answers never use a model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink("Answer evaluation (\(EvaluationItem.all.count) questions)") { AnswerEvaluationView(model: model) }
                    Toggle("Show the first frame while the answer streams", isOn: $model.settings.earlyFirstFrame)
                    Picker("End-of-Answer Indicator", selection: $model.settings.endMarker) {
                        ForEach(EndMarkerStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Answer length", selection: $model.settings.answerLength) {
                        Text("Short (2–3 sentences)").tag(AnswerLength.short)
                        Text("Standard (3–5)").tag(AnswerLength.standard)
                        Text("Detailed (6–8)").tag(AnswerLength.detailed)
                    }
                    Toggle("Cache answers locally", isOn: $model.settings.cacheAnswers)
                    NavigationLink("Knowledge base & portfolio") { KnowledgeEditorView(model: model) }
                    NavigationLink("Personal AI Memory") { PersonalMemoryView(model: model) }
                }
                Section {
                    Toggle("Continuous conversation (follow-ups)", isOn: $model.settings.continuousConversation)
                    Picker("Code on glasses", selection: $model.settings.codeDisplay) {
                        ForEach(CodeSnippetController.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper("Preview: \(Int(model.settings.codeSnippetSeconds)) s per frame", value: $model.settings.codeSnippetSeconds, in: 5...60, step: 5)
                    Picker("Adaptive Walkthrough", selection: $model.settings.adaptiveWalkthrough) {
                        ForEach(AdaptiveWalkthroughMode.allCases) { Text($0.label).tag($0) }
                    }
                    EditorPairingRow(editor: model.editor)
                    Stepper(model.settings.walkthroughCodeSeconds == 0 ? "Walkthrough code: advance on Next only"
                            : "Walkthrough code: auto-advance after \(Int(model.settings.walkthroughCodeSeconds)) s",
                            value: $model.settings.walkthroughCodeSeconds, in: 0...60, step: 5)
                    Toggle("Transcript debugging (raw vs normalised text)", isOn: $model.settings.transcriptDebug)
                } header: { Text("Conversation") } footer: {
                    Text("Continuous conversation classifies every turn (follow-up, clarification, correction, your own reading…). Confident follow-ups replace the answer automatically (with one-tap undo); less certain ones are prepared and shown when you finish reading or tap Show. A single microphone cannot reliably tell who is speaking, so uncertain speech never replaces an answer.")
                }
                GeminiSettingsSection(model: model)
                Section {
                    Picker("Display", selection: $model.settings.glassesTarget) {
                        ForEach(GlassesTarget.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Display style", selection: $model.settings.captionStrategy) {
                        ForEach(CaptionStrategy.selectable) { Text($0.label).tag($0) }
                    }
                    Picker("Session type", selection: $model.settings.glassesSessionMode) {
                        ForEach(DisplaySessionMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Caption compatibility mode (send without acknowledgement)", isOn: $model.settings.allowUnconfirmedGlassesSend)
                    Picker("Reading mode", selection: $model.settings.readingMode) {
                        ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
                    }
                    NavigationLink("Caption calibration (\(model.settings.captionLayout.lines) lines × \(model.settings.captionLayout.width) chars)") {
                        CaptionCalibrationView(model: model)
                    }
                    NavigationLink("RayNeo diagnostics") { RayNeoDiagnosticsView(model: model) }
                } header: { Text("Glasses") } footer: {
                    Text("Caption compatibility mode lets answers be sent when the glasses open the caption page but never acknowledge it, which is the behaviour seen on a RayNeo iO-E081 that displayed the text. Caption sessions only. Close the official RayNeo app while using this.")
                }
                Section {
                    Toggle("Debug logging (on-screen only)", isOn: $model.settings.debugLogging)
                    Button("Clear transcript", role: .destructive) { model.clearTranscript() }
                    Button("Clear cached answers", role: .destructive) { model.engine.clearCache() }
                } header: { Text("Privacy & debugging") } footer: {
                    Text("Audio is never stored. Session transcripts stay in memory. Text goes to your glasses over Bluetooth. If you enable Gemini, questions and selected context go to Google. Optional editor pairing shares generated code and progress over local Wi-Fi.")
                }
            }
            .navigationTitle("RayPrompt Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: format, value.wrappedValue))
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}

struct KnowledgeEditorView: View {
    let model: AppModel

    var body: some View {
        @Bindable var knowledge = model.knowledge
        Form {
            Section {
                TextEditor(text: $knowledge.document.portfolio).frame(minHeight: 140)
            } header: { Text("Portfolio (verified facts only)") } footer: {
                Text("Projects, roles, tools you actually used. The AI may only mention experience written here.")
            }
            Section("Topics") {
                ForEach($knowledge.document.topics) { $topic in
                    NavigationLink(topic.title) {
                        Form {
                            TextField("Title", text: $topic.title)
                            TextField("Keywords (comma separated)", text: Binding(
                                get: { topic.keywords.joined(separator: ", ") },
                                set: { topic.keywords = $0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                            TextEditor(text: $topic.notes).frame(minHeight: 200)
                        }
                        .navigationTitle(topic.title)
                        .onDisappear { model.refreshKeywords() }
                    }
                }
                .onDelete { knowledge.document.topics.remove(atOffsets: $0) }
                Button("Add topic") { knowledge.document.topics.append(KnowledgeTopic(title: "New topic", keywords: [], notes: "")) }
                Button("Restore default topics") { knowledge.resetToDefaults(); model.refreshKeywords() }
            }
        }
        .navigationTitle("Knowledge base")
    }
}

/// Gemini Flash (cloud): explicit opt-in, privacy and billing disclosure, Keychain key, model, verification.
struct GeminiSettingsSection: View {
    @Bindable var model: AppModel
    @State private var keyInput = ""
    @State private var keySaved = GeminiKeychain.load()?.isEmpty == false
    @State private var verifyResult: String?

    var body: some View {
        Section {
            Toggle("Allow Gemini (sends questions to Google)", isOn: $model.settings.geminiConsent)
            if model.settings.geminiConsent {
                SecureField(keySaved ? "API key saved (enter to replace)" : "Gemini API key", text: $keyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("Save key") {
                        keySaved = GeminiKeychain.save(keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyInput = ""
                    }.disabled(keyInput.isEmpty)
                    Spacer()
                    Button("Remove key", role: .destructive) { GeminiKeychain.delete(); keySaved = false }.disabled(!keySaved)
                }
                .buttonStyle(.borderless)
                Picker("Model (free tier)", selection: $model.settings.geminiModel) {
                    ForEach(GeminiModel.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("If Gemini fails, answer on-device (Apple)", isOn: $model.settings.geminiFallbackToApple)
                Toggle("Share memory & conversation context with Gemini", isOn: $model.settings.geminiIncludePortfolio)
                Button("Test Gemini Connection") {
                    Task {
                        verifyResult = "Testing \(model.settings.geminiModel)…"
                        let provider = GeminiProvider()
                        provider.model = model.settings.geminiModel
                        let report = await provider.testConnection()
                        verifyResult = report.summary
                        // Status and timings only; the key and the response text stay out of the log.
                        DiagnosticLog.shared.record(.pipeline, "Gemini connection test: \(report.outcome.rawValue), model \(report.model), HTTP \(report.httpStatus.map(String.init) ?? "–"), first token \(report.firstTokenSeconds.map { String(format: "%.2fs", $0) } ?? "–")")
                    }
                }.disabled(!keySaved)
                if let verifyResult { Text(verifyResult).font(.caption.monospaced()).textSelection(.enabled) }
                Text("Select “Gemini Flash (cloud)” as the AI model above to use it.").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Gemini Flash (cloud, optional)") } footer: {
            Text("""
            Gemini runs on Google's servers, not on this iPhone. When selected, each question, the answer instructions, matching knowledge-base notes and (for follow-ups) the previous question and answer are sent to Google. No audio is ever sent. Your profile, project memory, portfolio and recent conversation are sent only if you turn on context sharing, and then only the few relevant entries per question. On Google's free tier, submitted content may be used to improve Google's products. Use a key from a Google AI Studio project WITHOUT billing so usage can never be charged, and restrict the key to this iOS bundle ID. Free-tier limits return “429 RESOURCE_EXHAUSTED”; the app then answers on-device if fallback is on.
            """)
        }
    }
}

/// Optional pairing with the VS Code companion (Tools/vscode-code-tutor) for code-step progress.
struct EditorPairingRow: View {
    let editor: EditorBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Pair a code editor", isOn: Binding(get: { editor.listening }, set: { $0 ? editor.start() : editor.stop() }))
            if editor.listening {
                Text("Code \(editor.pairingCode) · connect to \(EditorBridge.wifiAddress() ?? "this iPhone's Wi-Fi address"):\(editor.port.map(String.init) ?? "…")")
                    .font(.caption.monospaced())
                Text(editor.status).font(.caption2).foregroundStyle(.secondary)
                Text("Same Wi-Fi only. The editor sends file names, which expected lines are present and its error count — never your source.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
