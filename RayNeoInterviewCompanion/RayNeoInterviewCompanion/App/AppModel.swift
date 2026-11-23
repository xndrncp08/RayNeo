import AVFoundation
import Foundation
import Speech
import SwiftUI
import UIKit

struct Diagnostics: Equatable {
    var audioLatencyMs: Double?
    var recognitionLatency: Double?
    var memoryMB: Double = 0
    var thermalState = "nominal"
    var recognitionRestarts = 0
    var sessionStartedAt: Date?
}

/// Coordinator: wires audio → speech → turn detection → engine → glasses, and owns session lifecycle.
@MainActor @Observable final class AppModel {
    var settings: AppSettings { didSet { settingsChanged(from: oldValue) } }
    let engine: ConversationEngine
    let presenter: GlassesPresenter
    let knowledge: KnowledgeBase
    let memory: PersonalMemoryStore
    let conversation = ConversationMemory()
    let snippets: CodeSnippetController
    let reading: ReadingController
    let evaluation = AnswerEvaluationRunner()

    private(set) var sessionActive = false
    private(set) var transcript = TranscriptBuffer()
    private(set) var volatileText = ""
    private(set) var micStatus = "Off"
    private(set) var inputName = "—"
    private(set) var speechStatus = "Not started"
    private(set) var levelDB: Float = -100
    private(set) var diagnostics = Diagnostics()
    private(set) var lastError: String?
    private(set) var calibrating = false
    private(set) var aiProvider: any AIResponseProvider
    var showConsent = false
    /// Speech is ignored (nothing classified, answered or aligned) while muted; the session stays open.
    var muted = false {
        didSet { if muted != oldValue { trace(.session, muted ? "Muted" : "Unmuted") } }
    }
    let editor = EditorBridge()
    private(set) var editorAssistant: EditorAssistant!

    /// Speech for the hands-free walkthrough. While a new question is being answered (or one is waiting to
    /// be confirmed) progression pauses, keeping its position.
    private func feedWalkthrough(_ text: String, isFinal: Bool) {
        // Always tracked: an early skeleton waits for the end of the wearer's sentence.
        snippets.interrupted = engine.state == .generating || engine.state == .questionDetected || engine.preparedAnswer != nil
        snippets.walkthroughSpeech(text, isFinal: isFinal, alignmentProgress: reading.progress, alignmentConfidence: reading.confidence,
                                   readingComplete: reading.readingComplete)
    }

    /// Bounded AI check for a borderline explanation (once per block). On-device always; with Gemini only
    /// when context sharing is on, because it sends what you said.
    func judgeExplanation(expected: String, heard: String) async -> Bool? {
        guard personalContextAllowed, aiProvider.status == .ready else { return nil }
        let request = AnswerRequest(instructions: "Answer only yes or no.",
                                    prompt: "Expected explanation: \(expected.prefix(400))\nWhat the speaker said: \(heard.prefix(500))\nDid the speaker explain the same idea, even in other words?",
                                    maximumTokens: 3)
        var answer = ""
        do { for try await partial in aiProvider.streamAnswer(request) { answer = partial } } catch { return nil }
        let lower = answer.lowercased()
        return lower.hasPrefix("yes") ? true : lower.hasPrefix("no") ? false : nil
    }

    /// One bounded AI request for the editor assistant (explicit help, Explain Selection).
    func askOnce(instructions: String, prompt: String) async -> String? {
        guard aiProvider.status == .ready else { return nil }
        var text = ""
        do { for try await partial in aiProvider.streamAnswer(AnswerRequest(instructions: instructions, prompt: prompt, maximumTokens: 160)) { text = partial } }
        catch { return nil }
        return text.isEmpty ? nil : text
    }

    /// The latest "Explain This Line" result (iPhone only; the walkthrough position is unchanged).
    private(set) var lineExplanation: (line: String, text: String)?

    /// A short explanation of one code line, with the active coding task as context.
    func explainLine(_ line: String) async {
        let language = snippets.walkthrough?.language ?? snippets.snippet?.language ?? "the same language"
        let code = snippets.walkthrough?.finalCode ?? snippets.snippet?.code ?? ""
        let request = AnswerRequest(
            instructions: "Explain one line of \(language) code in one or two short, plain sentences. Explain what the code does; never claim it was run or that you wrote it before.",
            prompt: "Task: \(codingTasks.task?.instruction ?? snippets.snippet?.problem ?? "")\nCode:\n\(code.prefix(800))\nLine: \(line)\nExplanation:",
            maximumTokens: 90)
        lineExplanation = (line, "Explaining…")
        var text = ""
        do {
            for try await partial in aiProvider.streamAnswer(request) { text = partial }
            lineExplanation = (line, AnswerFormatter.spoken(text))
        } catch {
            lineExplanation = (line, error.localizedDescription)
        }
    }

    /// Finalized conversation turns (revisions replace their turn; partial hypotheses never appear here).
    private(set) var finalizedTurns: [FinalizedTurn] = []
    let codingTasks = CodingTaskTracker()
    /// Last memory references used in a prompt (titles only).
    private(set) var lastMemoryReferences: [String] = []

    private let audio: any AudioCapturing
    private let speechFactory: @MainActor () -> [any SpeechRecognizing]
    private let glassesFactory: @MainActor (GlassesTarget) -> any GlassesDisplay
    private let permissions: @MainActor () async -> String?
    private let defaults: UserDefaults?
    private let speaker = SpeakerActivityService()
    private var speech: (any SpeechRecognizing)?
    private var assembler: TranscriptTurnAssembler
    /// Assembler output waiting for the next tick (revisions arrive with final results).
    private var assembled: [AssemblerOutput] = []
    private var tickTask: Task<Void, Never>?
    private var lastFrameTime = -1.0
    private var consecutiveSpeechFailures = 0
    private var starting = false
    private var startCancelled = false
    private static let settingsKey = "appSettings.v1"

    init(defaults: UserDefaults? = .standard,
         audio: any AudioCapturing = AudioCaptureService(),
         speechFactory: @escaping @MainActor () -> [any SpeechRecognizing] = { [AnalyzerSpeechRecognizer(), LegacySpeechRecognizer()] },
         aiFactory: @escaping @MainActor (AIModelChoice) -> any AIResponseProvider = AppModel.makeAI,
         glassesFactory: @escaping @MainActor (GlassesTarget) -> any GlassesDisplay = AppModel.makeGlasses,
         knowledge: KnowledgeBase = KnowledgeBase(),
         memory: PersonalMemoryStore? = nil,
         permissions: @escaping @MainActor () async -> String? = AppModel.requestPermissions) {
        let savedData = defaults?.data(forKey: Self.settingsKey)
        var settings = savedData.flatMap(AppSettings.decodeMerged) ?? AppSettings()
        if let savedData { Self.migrate(&settings, from: savedData) }
        self.settings = settings
        self.defaults = defaults
        self.audio = audio
        self.speechFactory = speechFactory
        self.glassesFactory = glassesFactory
        // Without persistent defaults (tests) the memory is in-memory only.
        self.memory = memory ?? PersonalMemoryStore(url: defaults == nil ? nil : PersonalMemoryStore.defaultURL)
        self.permissions = permissions
        self.knowledge = knowledge
        self.aiProvider = aiFactory(settings.aiModel)
        self.assembler = TranscriptTurnAssembler(silence: settings.endOfTurnSilence)
        let presenter = GlassesPresenter(display: glassesFactory(settings.glassesTarget), layout: settings.captionLayout)
        self.presenter = presenter
        self.snippets = CodeSnippetController(presenter: presenter)
        snippets.duration = settings.codeSnippetSeconds
        snippets.walkthroughCodeSeconds = settings.walkthroughCodeSeconds
        snippets.adaptiveMode = settings.adaptiveWalkthrough
        snippets.codeLayout = settings.codeLayout
        conversation.retain = settings.conversationRetention
        presenter.clearBetweenAnswers = settings.clearBetweenAnswers
        presenter.appendSafe = settings.captionStrategy.appendSafe
        presenter.restartSessionPerAnswer = settings.restartCaptionSessionPerAnswer
        presenter.frameRows = settings.captionStrategy.usesFrames ? settings.viewportRows : nil
        presenter.viewportRows = settings.viewportRows
        presenter.separator = settings.segmentSeparator.text
        self.reading = ReadingController(presenter: presenter)
        presenter.inPlaceReplacementVerified = settings.inPlaceReplacement
        reading.lookaheadWindows = settings.lookaheadWindows
        reading.lineScrollingAllowed = settings.captionStrategy.allowsLineScrolling || settings.lookaheadWindows
        reading.mode = settings.readingMode
        reading.responsiveness = settings.readingResponsiveness
        self.aiFactory = aiFactory
        self.engine = ConversationEngine(settings: settings, ai: { DisabledAIProvider() }, presenter: presenter,
                                         classifier: QuestionDetector(technicalKeywords: knowledge.keywords))
        engine.ai = { [unowned self] in self.aiProvider }
        engine.instructionsProvider = { [unowned self] category in
            // The portfolio and profile are private: only sent to the cloud if the user explicitly allows it.
            guard self.personalContextAllowed else {
                return InterviewPromptBuilder.instructions(for: category, length: self.settings.answerLength, portfolio: "")
            }
            let profile = self.settings.personalMemoryEnabled ? self.memory.profileSummary() : ""
            let background = [profile, self.knowledge.document.portfolio].filter { !$0.isEmpty }.joined(separator: "\n")
            return InterviewPromptBuilder.instructions(for: category, length: self.settings.answerLength, portfolio: background)
        }
        engine.hasPortfolio = { [unowned self] in
            !self.knowledge.document.portfolio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        engine.notesProvider = { [unowned self] question in self.notes(for: question) }
        engine.groundingCheck = { [unowned self] answer in
            self.settings.personalMemoryEnabled ? PersonalMemoryStore.unsupportedClaim(in: answer, entries: self.memory.entries) : nil
        }
        engine.topicText = { [unowned self] in self.conversation.context(budget: 600) }
        engine.onAnswerDisplayed = { [unowned self] question, answer in
            self.conversation.record(question: question.text, answer: answer.text, category: answer.category, kind: answer.kind,
                                     projects: self.memory.projects.compactMap(\.project))
            if answer.category == .ambiguous { self.conversation.noteUnresolved(question.text) }
            if answer.category == .coding {
                self.codingTasks.record(code: answer.snippet?.code, request: question.text, turnID: nil)
                if answer.snippet != nil { DiagnosticLog.shared.record(.pipeline, "Code generated for answer #\(answer.answerID)") }
            }
            if self.settings.codeDisplay == .tutor, let walkthrough = answer.walkthrough {
                self.snippets.startWalkthrough(walkthrough, snippet: answer.snippet, answerID: answer.answerID,
                                               endMarker: self.engine.endMarker(for: answer))
            } else if let snippet = answer.snippet {
                self.snippets.show(snippet, answerID: answer.answerID, mode: self.settings.codeDisplay)
            } else if self.snippets.isActive, self.snippets.answerID != answer.answerID {
                self.snippets.cancel(reason: "new answer")
            }
        }
        engine.onAnswerUndone = { [unowned self] answer in
            self.conversation.removeLast()
            DiagnosticLog.shared.record(.pipeline, "Undo performed: answer #\(answer.answerID) restored")
            // Back to the Code Tutor block, or the reading position, the reader had reached.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                if !self.snippets.resumeSuspended(answerID: answer.answerID) { self.reading.restorePosition(for: answer.answerID) }
            }
        }
        snippets.onCodeStep = { [unowned self] blockID, language, structures in
            self.editor.expect(blockID: blockID, language: language, structures: structures)
        }
        engine.onInterviewerTurn = { [unowned self] text, turnID in
            guard let turnID else { return }
            let decision = self.conversation.recordInterviewer(text, turnID: turnID)
            let context = self.conversation.interview
            DiagnosticLog.shared.record(.pipeline, "Interview context: \(decision) · \(context.statements.count) statement(s), \(context.incidents.count) incident(s), \(context.constraints.count) constraint(s)")
        }
        editorAssistant = EditorAssistant(presenter: presenter, snippets: snippets)
        editorAssistant.isSpeaking = { [unowned self] in !self.volatileText.isEmpty }
        editorAssistant.codeLayout = { [unowned self] in self.snippets.effectiveCodeLayout }
        editorAssistant.askAI = { [unowned self] instructions, prompt in await self.askOnce(instructions: instructions, prompt: prompt) }
        editor.onEvent = { [unowned self] event in self.editorAssistant.handle(event) }
        if settings.editorLinkEnabled { editor.setEnabled(true) }
        snippets.semanticJudge = { [unowned self] expected, heard in await self.judgeExplanation(expected: expected, heard: heard) }
        engine.onEarlySkeleton = { [unowned self] answerID, code in self.snippets.showEarlySkeleton(code, answerID: answerID) }
        engine.onEarlyContentWithdrawn = { [unowned self] answerID in self.snippets.withdrawEarlySkeleton(answerID: answerID) }
        engine.presentWalkthrough = { [unowned self] answer in
            guard let walkthrough = answer.walkthrough else { return false }
            await self.snippets.presentWalkthrough(walkthrough, snippet: answer.snippet, answerID: answer.answerID,
                                                   endMarker: self.engine.endMarker(for: answer))
            return true
        }
        engine.codingResolver = { [unowned self] in self.codingTasks.resolve($0) }
        engine.codingTask = { [unowned self] in self.codingTasks.task }
        engine.contextKey = { [unowned self] in self.conversation.project ?? "" }
        snippets.onShown = { [unowned self] in self.engine.record(.codeShown) }
        snippets.onEnded = { [unowned self] in self.engine.record(.codeEnded) }
        engine.semanticCheck = { [unowned self] in await self.aiProvider.isInterviewQuestion($0) }
        audio.onEvent = { [weak self] in self?.handleAudio($0) }
        inputName = audio.inputName
        applyGlassesSettings()
        applyAISettings()
    }

    private let aiFactory: @MainActor (AIModelChoice) -> any AIResponseProvider
    private var lastLabStep: Date?

    /// Settings saved before version 2 keep explicit choices, but untouched old defaults move to the new
    /// ones: Stable Sections → Sentence Frames, 4 × 26 characters → 4 × 48.
    nonisolated static func migrate(_ settings: inout AppSettings, from data: Data) {
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let version = raw["settingsVersion"] as? Int ?? 1
        if version < 2 {
            if settings.captionStrategy == .stableSections { settings.captionStrategy = .sentenceFrames }
            var oldDefault = CaptionLayout()
            oldDefault.charactersPerLine = 26
            if settings.captionLayout == oldDefault { settings.captionLayout.charactersPerLine = 48 }
        }
        // v3: the 10 s answer lock became a 2 s anti-oscillation cooldown (automatic question handoff).
        if version < 3, settings.minimumLockSeconds == 10 { settings.minimumLockSeconds = 2 }
        settings.settingsVersion = 3
    }


    static func makeAI(_ choice: AIModelChoice) -> any AIResponseProvider {
        switch choice {
        case .appleOnDevice: FoundationModelsProvider()
        case .geminiFlash: CloudFailoverProvider(gemini: GeminiProvider(), fallback: FoundationModelsProvider())
        case .auto: FallbackAIProvider(preferred: GemmaProvider(), fallback: FoundationModelsProvider(), explicitChoice: false)
        case .gemmaOnDevice: FallbackAIProvider(preferred: GemmaProvider(), fallback: FoundationModelsProvider(), explicitChoice: true)
        case .disabled: DisabledAIProvider()
        }
    }

    static func makeGlasses(_ target: GlassesTarget) -> any GlassesDisplay {
        target == .simulator ? MockGlassesDisplay() : RayNeoBluetoothDisplay()
    }

    var availableInputs: [AudioInputOption] { audio.availableInputs() }

    // MARK: Session lifecycle

    /// Shows the consent reminder; the session starts only after the user confirms.
    func requestStart() { showConsent = true }

    func startSession() async {
        // Re-entrancy guard: start suspends at several awaits, so a second tap must not start twice.
        guard !sessionActive, !starting else { return trace(.session, "Start Session ignored (already active or starting)") }
        trace(.session, "Start Session: glasses target = \(presenter.display.name)")
        starting = true
        startCancelled = false
        defer { starting = false }
        showConsent = false
        lastError = nil
        if let denied = await permissions() { lastError = denied; micStatus = "Permission denied"; return trace(.session, "Permissions denied") }
        guard !startCancelled else { return }
        trace(.session, "Permissions granted")

        var prepared: (any SpeechRecognizing, AVAudioFormat)?
        var reasons: [String] = []
        for candidate in speechFactory() {
            do { prepared = (candidate, try await candidate.prepare(locale: Locale(identifier: settings.localeIdentifier))); break }
            catch { reasons.append("\(candidate.engineName): \(error.localizedDescription)") }
        }
        guard !startCancelled else { return }
        guard let (recognizer, format) = prepared else {
            lastError = reasons.joined(separator: "\n")
            speechStatus = "Unavailable"
            return
        }
        trace(.session, "Speech recognizer prepared: \(recognizer.engineName)")
        speech = recognizer
        speaker.reset()
        lastFrameTime = -1
        assembler = TranscriptTurnAssembler(silence: settings.endOfTurnSilence)
        speech?.setVocabulary(memory.vocabulary.vocabulary)
        trace(.audio, "Before activation: \(Self.audioRouteSummary())")
        do {
            try startRecognizer()
            try audio.start(format: format, preferredInputUID: settings.preferredInputUID,
                            handler: Self.bufferHandler(speech: recognizer, speaker: speaker))
        } catch {
            await recognizer.stop()
            speech = nil
            audio.stop()
            lastError = error.localizedDescription
            micStatus = "Failed"
            return trace(.audio, "Audio start failed: \(error.localizedDescription)")
        }
        trace(.audio, "Audio session active (.record, not mixable) and engine running. After: \(Self.audioRouteSummary())")
        sessionActive = true
        micStatus = "Listening"
        inputName = audio.inputName
        diagnostics.sessionStartedAt = Date()
        diagnostics.audioLatencyMs = (AVAudioSession.sharedInstance().inputLatency + AVAudioSession.sharedInstance().ioBufferDuration) * 1000
        conversation.clear() // conversation memory is session-scoped
        engine.start()
        trace(.session, "Requesting glasses connect() on \(presenter.display.name)")
        presenter.display.connect()
        aiProvider.prewarm(instructions: engine.instructionsProvider(.technical))
        startTicking()
    }

    func stopSession() async {
        if starting { startCancelled = true }
        guard sessionActive else { return }
        trace(.session, "Stop Session: mic off, then glasses disconnect()")
        // Microphone off first, immediately.
        audio.stop()
        micStatus = "Off"
        sessionActive = false
        tickTask?.cancel()
        tickTask = nil
        await speech?.stop()
        speech = nil
        speechStatus = "Stopped"
        volatileText = ""
        assembler.reset()
        engine.stop()
        presenter.display.disconnect()
    }

    func clearTranscript() {
        transcript.removeAll()
        finalizedTurns.removeAll()
        volatileText = ""
    }

    /// Idempotent: never tears down an attempt in progress or an authenticated link.
    func connectGlasses() {
        trace(.session, "Connect tapped on \(presenter.display.name) (state: \(presenter.connectionState.label))")
        presenter.display.connect()
    }

    func disconnectGlasses() {
        trace(.session, "Disconnect tapped on \(presenter.display.name)")
        presenter.display.disconnect()
    }

    var rayNeo: RayNeoBluetoothDisplay? { presenter.display as? RayNeoBluetoothDisplay }

    /// Sends "HELLO FROM IPHONE". Independent of the microphone and AI pipeline.
    func sendTestCaption(_ text: String = "HELLO FROM IPHONE", allowUnconfirmed: Bool) async -> String {
        guard let rayNeo else { return "Select RayNeo iO as the glasses display first." }
        do {
            try await rayNeo.sendTestCaption(text, allowUnconfirmed: allowUnconfirmed)
            presenter.invalidateSentPage() // the test text replaced whatever answer page was showing
            trace(.session, "Test caption written to BLE (\(text.count) chars, \(rayNeo.connectionState.label)); awaiting visual confirmation")
            return "Written to Bluetooth. This does not prove it is visible — check the glasses and record what you see."
        } catch {
            trace(.session, "Test caption not sent: \(error.localizedDescription) (\(rayNeo.connectionState.label))")
            return "Not sent: \(error.localizedDescription) (\(rayNeo.connectionState.label))"
        }
    }

    /// The user's observation is the only evidence that text was actually visible.
    /// Replacement Lab: start from a clean state by restarting the caption session (verified close/start),
    /// then wait until captions can be sent again.
    func labResetSession() async -> String {
        guard let rayNeo, rayNeo.connectionState.isAuthenticatedLink else { return "Connect to the glasses first (RayNeo diagnostics › Connect)." }
        rayNeo.restartSession()
        let deadline = Date().addingTimeInterval(settings.captionStartWait + 4)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if rayNeo.connectionState == .ready || rayNeo.connectionState == .sessionUnconfirmed { break }
        }
        presenter.invalidateSentPage()
        trace(.session, "LAB reset: caption session restarted (\(rayNeo.connectionState.label))")
        return "Clean session: \(rayNeo.connectionState.label). The lens may show the Live Captions intro; that is the clean state."
    }

    /// Replacement Lab: sends one step. Logs packet kind, status, session, step and interval; text only when
    /// test logging is on. Returns the exact transmitted text for the iPhone to show.
    func runLabStep(_ step: LabStep, experiment: String, index: Int) async -> (text: String, status: String, sent: Bool) {
        guard let rayNeo else { return ("", "Select RayNeo iO as the glasses display first.", false) }
        let interval = lastLabStep.map { String(format: "%.1f s after the previous step", Date().timeIntervalSince($0)) } ?? "first step"
        lastLabStep = Date()
        defer { presenter.invalidateSentPage() }
        do {
            switch step {
            case .caption(let text, let final):
                let sid = try rayNeo.sendLabCaption(text, final: final, logText: settings.logLabCaptionText)
                trace(.session, "LAB \(experiment) step \(index + 2): 0x13 type 5 \(final ? "final" : "in progress"), sid \(sid), \(text.count) chars, \(interval)")
                return (text, "Sent (\(final ? "final" : "in progress")). Record what you see.", true)
            case .blankRows(let final):
                let text = GlassesPresenter.blankRows(settings.viewportRows)
                let sid = try rayNeo.sendLabCaption(text, final: final, logText: false)
                trace(.session, "LAB \(experiment) step \(index + 2): blank rows (\(settings.viewportRows)), \(final ? "final" : "in progress"), sid \(sid), \(interval)")
                return (text, "Blank rows sent. Record what you see.", true)
            case .openRayneoBlank:
                let previous = rayNeo.allowUnconfirmedSend
                rayNeo.allowUnconfirmedSend = true
                defer { rayNeo.allowUnconfirmedSend = previous }
                try await rayNeo.clear()
                trace(.session, "LAB \(experiment) step \(index + 2): OpenRayneo blank (source+translation full-width blank, final), \(interval)")
                return (GlassesPresenter.blank, "OpenRayneo blank sent. Record what you see.", true)
            case .restartSession:
                let status = await labResetSession()
                return ("[session restart]", status, true)
            case .frame(let lines):
                let text = GlassesPresenter.blankRows(settings.viewportRows) + lines.joined(separator: "\n")
                let sid = try rayNeo.sendLabCaption(text, final: true, logText: settings.logLabCaptionText)
                trace(.session, "LAB \(experiment) step \(index + 2): full frame (\(lines.count) rows after \(settings.viewportRows) blank rows), final, sid \(sid), \(interval)")
                return (text, "Frame sent. Record what you see.", true)
            }
        } catch {
            return ("", "Not sent: \(error.localizedDescription) (\(rayNeo.connectionState.label)). Reset the session and try again.", false)
        }
    }

    /// Calibration: OpenRayneo's blank caption through the same path as Clear Display.
    func clearTestCaption() async -> String {
        guard let rayNeo else { return "Select RayNeo iO as the glasses display first." }
        let previous = rayNeo.allowUnconfirmedSend
        rayNeo.allowUnconfirmedSend = true
        defer { rayNeo.allowUnconfirmedSend = previous }
        do {
            try await rayNeo.clear()
            presenter.invalidateSentPage()
            trace(.session, "Clear test written to BLE; awaiting visual confirmation")
            return "Blank caption written. Check whether the lens is empty."
        } catch {
            return "Not sent: \(error.localizedDescription)"
        }
    }

    func recordCalibration(_ note: String) {
        let layout = settings.captionLayout
        trace(.session, "USER CALIBRATION: \(note) — saved \(layout.lines) lines × \(layout.width) chars, context \(layout.contextLine ? "on" : "off"), counter \(layout.pageCounter ? "on" : "off"), font_size \(layout.fontSize), status \(layout.finalStatus ? "final" : "in progress")")
    }

    func recordVisualConfirmation(visible: Bool) {
        trace(.session, "USER OBSERVATION: test caption \(visible ? "VISIBLE" : "NOT visible") on glasses (mode \(settings.glassesSessionMode.rawValue), state \(presenter.connectionState.label))")
    }

    func handleScenePhase(_ phase: ScenePhase) {
        trace(.session, "Scene phase: \(phase)")
        switch phase {
        case .background:
            // Capture continues under the audio background mode; the editor link stops listening (iOS may
            // suspend the app; VS Code reconnects with backoff when it is active again).
            if sessionActive { speechStatus += " (background)" }
            editor.setSuspended(true)
        case .active:
            speechStatus = speechStatus.replacingOccurrences(of: " (background)", with: "")
            refreshDiagnostics()
            editor.setSuspended(false)
        default: break
        }
    }

    // MARK: Wearer calibration

    /// Records ~6 s of the wearer speaking to build a pitch/level profile.
    func calibrateWearer(seconds: Double = 6) async {
        guard !calibrating else { return }
        calibrating = true
        defer { calibrating = false }
        let ownsAudio = !sessionActive
        if ownsAudio {
            if let denied = await permissions() { lastError = denied; return }
            speaker.reset()
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            do { try audio.start(format: format, preferredInputUID: settings.preferredInputUID, handler: Self.bufferHandler(speech: nil, speaker: speaker)) }
            catch { lastError = error.localizedDescription; return }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let start = speaker.latest?.time ?? 0
        try? await Task.sleep(for: .seconds(seconds))
        let end = speaker.latest?.time ?? start
        if ownsAudio { audio.stop() }
        if let profile = speaker.makeProfile(from: start, to: end) {
            settings.wearerProfile = profile
            lastError = nil
        } else {
            lastError = "Calibration needs at least 2 seconds of clear speech. Try again in a quieter spot."
        }
    }

    // MARK: Pipeline

    nonisolated static func bufferHandler(speech: (any SpeechRecognizing)?, speaker: SpeakerActivityService) -> AudioBufferHandler {
        { buffer, frame in
            speech?.append(buffer, at: frame)
            if let voice = SpeakerActivityService.analyze(buffer, time: Double(frame) / buffer.format.sampleRate) {
                speaker.append(voice)
            }
        }
    }

    private func startRecognizer() throws {
        speechStatus = "Starting (\(speech?.engineName ?? "-"))"
        try speech?.start { [weak self] event in self?.handleSpeech(event) }
        speechStatus = "Running · \(speech?.engineName ?? "-")"
    }

    /// Reading feeds the phase machine; finishing the answer shows a prepared follow-up answer.
    private func readingProgressed() {
        if reading.cursorWord >= 0 { engine.record(.readingStarted) }
        guard reading.readingComplete else { return }
        // Mid-walkthrough the walkthrough evaluator decides (see feedWalkthrough); this is not the answer's end.
        if snippets.walkthrough != nil, !snippets.atLastStep { return }
        engine.record(.readingCompleted)
        if engine.preparedAnswer != nil { engine.showPreparedAnswer(reason: "you finished reading") }
    }

    func handleSpeech(_ event: SpeechEvent) {
        guard sessionActive else { return }
        switch event {
        case .partial(let text):
            guard !muted else { return }
            if !assembler.hasPendingSpeech { DiagnosticLog.shared.record(.pipeline, "Speech started (partial transcript)") }
            volatileText = text
            assembler.partial(text, at: Date())
            reading.ingest(text, isFinal: false, speaker: liveSpeakerLabel())
            readingProgressed()
            feedWalkthrough(text, isFinal: false)
        case .final(let text, let start, let end):
            consecutiveSpeechFailures = 0
            guard !muted else { return }
            volatileText = ""
            transcript.append(TranscriptSegment(text: text, start: start, end: end))
            let before = (assembler.revisions, assembler.merges, assembler.duplicates)
            if let output = assembler.final(text, start: start, end: end, at: Date()) { assembled.append(output) }
            if assembler.revisions > before.0 { DiagnosticLog.shared.record(.pipeline, "Transcript revision detected (segment replaced, no new turn)") }
            if assembler.merges > before.1 { DiagnosticLog.shared.record(.pipeline, "Utterance merged: a fragment completed the previous turn") }
            if assembler.duplicates > before.2 { DiagnosticLog.shared.record(.pipeline, "Duplicate recognition result suppressed") }
            reading.ingest(text, isFinal: true, speaker: liveSpeakerLabel())
            readingProgressed()
            feedWalkthrough(text, isFinal: true)
            editorAssistant.speechEnded()
            if let started = diagnostics.sessionStartedAt {
                diagnostics.recognitionLatency = max(0, Date().timeIntervalSince(started) - end)
            }
        case .failed(let message):
            recoverRecognition(after: message)
        }
    }

    private func recoverRecognition(after message: String) {
        consecutiveSpeechFailures += 1
        diagnostics.recognitionRestarts += 1
        speechStatus = "Recovering: \(message)"
        guard consecutiveSpeechFailures <= 5 else {
            speechStatus = "Failed: \(message)"
            lastError = "Speech recognition keeps failing. Stop and restart the session."
            return
        }
        Task { [weak self] in
            guard let self, let speech = self.speech else { return }
            await speech.stop()
            try? await Task.sleep(for: .seconds(Double(self.consecutiveSpeechFailures)))
            guard self.sessionActive else { return }
            do {
                _ = try await speech.prepare(locale: Locale(identifier: self.settings.localeIdentifier))
                try self.startRecognizer()
            } catch {
                self.handleSpeech(.failed(error.localizedDescription))
            }
        }
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            var counter = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                await self.tick()
                counter += 1
                if counter % 25 == 0 { self.refreshDiagnostics() }
            }
        }
    }

    /// One pass of turn detection. Public for tests.
    func tick(now: Date = Date()) async {
        if let frame = speaker.latest, frame.time > lastFrameTime {
            lastFrameTime = frame.time
            levelDB = frame.levelDB
            if frame.voiced { assembler.voiceActivity(at: now) }
        }
        let ready = assembled + (assembler.tick(now: now).map { [$0] } ?? [])
        assembled = []
        for output in ready { await process(output) }
    }

    /// A finalized (or revised) utterance: normalise project names, update the coding task, then classify.
    private func process(_ output: AssemblerOutput) async {
        var (turn, isRevision): (ConversationTurn, Bool) = switch output {
        case .turn(let turn): (turn, false)
        case .revised(let turn): (turn, true)
        }
        // "Design a job system…" [pause] "The application must handle worker crashes…" is one request: the
        // continuation is folded into the previous turn, which is re-evaluated with every constraint.
        if !isRevision, assembler.turns.count >= 2, let previous = assembler.turns.dropLast().last,
           turn.start - previous.end <= settings.continuationGap, engine.echoOverlap(turn.text) < settings.echoThreshold,
           InterviewIntent.isContinuation(turn.text, of: previous.text), let merged = assembler.absorb(turn) {
            DiagnosticLog.shared.record(.pipeline, "Turn #\(turn.id) continues turn #\(merged.id): merged into one request (revision \(merged.revision))")
            turn = merged
            isRevision = true
        }
        let normalized = normalize(turn.text)
        // "Next step" / "go back" during a walkthrough navigate; they are never questions.
        if snippets.walkthrough != nil, !isRevision, let command = WalkthroughCommand.parse(normalized.normalized) {
            DiagnosticLog.shared.record(.pipeline, "Walkthrough command recognised (turn #\(turn.id))")
            return command == .next ? snippets.walkthroughNext(reason: "spoken command", source: .command)
                : snippets.walkthroughPrevious(reason: "spoken command", source: .command)
        }
        DiagnosticLog.shared.record(.pipeline, String(format: "Utterance %@: turn #%d, %d segment(s), %.1fs%@", isRevision ? "revised" : "finalized",
                                                      turn.id, turn.segmentIDs.count, turn.end - turn.start,
                                                      settings.transcriptDebug ? " · raw \"\(turn.text)\" → \"\(normalized.normalized)\"" : ""))
        let display = FinalizedTurn(id: turn.id, original: turn.text, normalized: normalized.normalized, revision: turn.revision)
        if let index = finalizedTurns.firstIndex(where: { $0.id == turn.id }) { finalizedTurns[index] = display } else { finalizedTurns.append(display) }
        if finalizedTurns.count > 30 { finalizedTurns.removeFirst(finalizedTurns.count - 30) }

        let lower = normalized.normalized.lowercased()
        let newTopic = engine.classifier.analyze(normalized.normalized).score >= settings.questionThreshold
            && !CodingLanguage.refersBack(lower) && QuestionRouter.route(normalized.normalized).category != .coding
        if let decision = codingTasks.observe(normalized.normalized, turnID: turn.id, startsNewTopic: newTopic) {
            DiagnosticLog.shared.record(.pipeline, "\(decision) (turn #\(turn.id))")
        }
        var completed = CompletedTurn(text: normalized.normalized, start: turn.start, end: turn.end, turnID: turn.id, isRevision: isRevision)
        completed.speaker = speaker.evidence(start: turn.start, end: turn.end, profile: settings.wearerProfile,
                                            pitchTolerance: settings.wearerPitchTolerance)
        await engine.handle(completed)
        if let index = finalizedTurns.firstIndex(where: { $0.id == turn.id }) { finalizedTurns[index].role = engine.lastTurnRole }
    }

    /// Project names from personal memory, recognised in speech (original text is kept for debugging).
    func normalize(_ text: String) -> NormalizedTranscript {
        let result = memory.vocabulary.normalize(text, context: [conversation.project ?? "", conversation.context(budget: 300)].joined(separator: " "),
                                                 isDictionaryWord: Self.isDictionaryWord)
        for replacement in result.replacements {
            DiagnosticLog.shared.record(.pipeline, String(format: "Project name normalized to %@ (%@, confidence %.2f)%@", replacement.canonical,
                                                          replacement.method, replacement.confidence,
                                                          settings.transcriptDebug ? " from \"\(replacement.original)\"" : ""))
        }
        return result
    }

    static func isDictionaryWord(_ word: String) -> Bool {
        let checker = UITextChecker()
        let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: word.utf16.count),
                                                  startingAt: 0, wrap: false, language: "en_US")
        return range.location == NSNotFound
    }

    /// Speaker heuristic over the last 2.5 s of audio, for live reading alignment.
    private func liveSpeakerLabel() -> SpeakerLabel {
        guard let latest = speaker.latest?.time else { return .unknown }
        return speaker.evidence(start: latest - 2.5, end: latest, profile: settings.wearerProfile,
                                pitchTolerance: settings.wearerPitchTolerance).label
    }

    private func handleAudio(_ event: AudioEvent) {
        trace(.audio, "Audio event: \(event); route: \(Self.audioRouteSummary())")
        switch event {
        case .interrupted: micStatus = "Interrupted (another app or a call)"
        case .resumed: micStatus = sessionActive ? "Listening" : micStatus
        case .routeChanged(let name): inputName = name
        case .failed(let message): micStatus = "Failed"; lastError = message
        }
        inputName = audio.inputName
    }

    private func refreshDiagnostics() {
        diagnostics.memoryMB = Self.memoryFootprintMB()
        diagnostics.thermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious – consider Short answers"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: Settings

    private func settingsChanged(from old: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults?.set(data, forKey: Self.settingsKey) }
        engine.settings = settings
        assembler.silence = settings.endOfTurnSilence
        presenter.layout = settings.captionLayout
        presenter.clearBetweenAnswers = settings.clearBetweenAnswers
        presenter.appendSafe = settings.captionStrategy.appendSafe
        presenter.restartSessionPerAnswer = settings.restartCaptionSessionPerAnswer
        presenter.frameRows = settings.captionStrategy.usesFrames ? settings.viewportRows : nil
        presenter.viewportRows = settings.viewportRows
        presenter.separator = settings.segmentSeparator.text
        presenter.inPlaceReplacementVerified = settings.inPlaceReplacement
        snippets.duration = settings.codeSnippetSeconds
        snippets.walkthroughCodeSeconds = settings.walkthroughCodeSeconds
        snippets.adaptiveMode = settings.adaptiveWalkthrough
        snippets.codeLayout = settings.codeLayout
        conversation.retain = settings.conversationRetention
        reading.lookaheadWindows = settings.lookaheadWindows
        reading.lineScrollingAllowed = settings.captionStrategy.allowsLineScrolling || settings.lookaheadWindows
        reading.mode = settings.readingMode
        reading.responsiveness = settings.readingResponsiveness
        if old.aiModel != settings.aiModel { aiProvider = aiFactory(settings.aiModel) }
        applyAISettings()
        if old.glassesTarget != settings.glassesTarget {
            trace(.session, "Glasses target changed: \(old.glassesTarget.label) → \(settings.glassesTarget.label) (old display disconnect())")
            presenter.replaceDisplay(glassesFactory(settings.glassesTarget))
            if sessionActive { presenter.display.connect() }
        }
        applyGlassesSettings()
    }

    /// Personal memory and conversation context may go into prompts: always on-device; to Gemini only
    /// when the user turned on cloud context sharing.
    var personalContextAllowed: Bool { settings.aiModel != .geminiFlash || settings.geminiIncludePortfolio }

    /// Prompt notes: knowledge-base topics, then (when allowed) retrieved personal memory and the
    /// conversation so far, each within a fixed budget.
    var interviewContextAllowed: Bool { settings.aiModel != .geminiFlash || settings.geminiIncludeInterviewContext }

    func notes(for question: String) -> [String] {
        // Bounded prompt: smaller budgets keep the first token fast; only what is relevant is included.
        var notes = knowledge.notes(for: question, limit: 2, maximumCharacters: 400)
        lastMemoryReferences = []
        if personalContextAllowed, settings.personalMemoryEnabled {
            let retrieval = memory.retrieve(question, topicProject: conversation.project, budget: 700)
            if !retrieval.entries.isEmpty { notes = Array(notes.prefix(1)) } // your memory beats generic topic notes
            lastMemoryReferences = retrieval.references
            if !retrieval.text.isEmpty {
                notes.append("Verified background (mention a project only if it directly answers the question; never add details beyond this):\n\(retrieval.text)")
                DiagnosticLog.shared.record(.pipeline, "Memory retrieved: \(retrieval.references.count) reference(s): \(retrieval.references.joined(separator: ", "))")
            }
        }
        guard interviewContextAllowed else { return notes }
        // The scenario the interviewer described (even statements that were not questions), then the Q&A of
        // the current topic only: an unrelated new question gets no stale context.
        if let scenario = conversation.interview.promptNote(for: question) { notes.append(scenario) }
        let context = conversation.context(budget: 550, since: conversation.interview.topicStartedAt, request: question,
                                           statements: conversation.interview.statements.map(\.text))
        if !context.isEmpty { notes.append("Conversation so far (resolve \"that\", \"it\" and follow-ups against this):\n\(context)") }
        return notes
    }

    /// Gemini configuration comes from settings; the key comes from the Keychain.
    private func applyAISettings() {
        guard let cloud = aiProvider as? CloudFailoverProvider else { return }
        cloud.gemini.model = settings.geminiModel
        cloud.gemini.consented = settings.geminiConsent
        cloud.fallbackEnabled = settings.geminiFallbackToApple
    }

    var gemini: GeminiProvider? { (aiProvider as? CloudFailoverProvider)?.gemini }

    private func applyGlassesSettings() {
        guard let rayNeo else { return }
        rayNeo.language = settings.localeIdentifier
        rayNeo.sessionMode = settings.glassesSessionMode
        rayNeo.allowUnconfirmedSend = settings.allowUnconfirmedGlassesSend
        rayNeo.captionFontSize = settings.captionLayout.fontSize
        rayNeo.captionFinalStatus = settings.captionStrategy.finalStatus
        rayNeo.sessionAckWait = settings.captionStartWait
    }

    func runEvaluation() {
        evaluation.run(provider: aiProvider, instructions: engine.instructionsProvider, notes: engine.notesProvider,
                       length: settings.answerLength)
    }

    func refreshKeywords() { engine.classifier.technicalKeywords = knowledge.keywords }

    // MARK: Platform helpers

    private func trace(_ category: DiagnosticLog.Category, _ message: String) {
        DiagnosticLog.shared.record(category, message)
    }

    /// Port types only (no device names beyond the system port name).
    static func audioRouteSummary() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let available = (session.availableInputs ?? []).map(\.portType.rawValue).joined(separator: ",")
        return "category \(session.category.rawValue), in [\(inputs)], out [\(outputs)], available in [\(available)], otherAudioPlaying \(session.isOtherAudioPlaying)"
    }

    static func requestPermissions() async -> String? {
        guard await AVAudioApplication.requestRecordPermission() else {
            return "Microphone access is off. Enable it in Settings › Privacy › Microphone."
        }
        guard await speechAuthorization() == .authorized else {
            return "Speech recognition access is off. Enable it in Settings › Privacy › Speech Recognition."
        }
        return nil
    }

    /// SFSpeechRecognizer invokes this handler on an arbitrary background queue, so it must not
    /// inherit AppModel's @MainActor isolation (that inserted a main-queue assertion and trapped).
    /// The framework calls the handler exactly once, so the continuation is resumed exactly once.
    nonisolated static func speechAuthorization(
        request: @Sendable (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = SFSpeechRecognizer.requestAuthorization
    ) async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            request { @Sendable status in continuation.resume(returning: status) }
        }
    }

    nonisolated static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
