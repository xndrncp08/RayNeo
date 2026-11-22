import Foundation

struct EngineLogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    let message: String
}

struct FilterCounters: Equatable, Sendable {
    var echo = 0, wearer = 0, notQuestion = 0, duplicate = 0, queued = 0, autoAdvanced = 0
}

/// The answer-lock state machine. Hardware-free: AI, glasses and the clock are injected.
/// Core rule: a displayed answer is only replaced by a completed new answer, and while locked
/// only a sufficiently confident interviewer question (or a manual action) may replace it.
@MainActor @Observable final class ConversationEngine {
    private(set) var state: ConversationState = .idle
    private(set) var currentQuestion: InterviewQuestion?
    private(set) var currentAnswer: InterviewAnswer?
    private(set) var pendingQuestion: InterviewQuestion?
    private(set) var streamingText = ""
    private(set) var isLocked = false
    private(set) var log: [EngineLogEntry] = []
    private(set) var counters = FilterCounters()
    private(set) var lastClassificationSeconds: Double?
    private(set) var generationTask: Task<Void, Never>?

    var settings: AppSettings
    var classifier: QuestionDetector
    /// Optional semantic check for borderline turns (Foundation Models in the app).
    var semanticCheck: ((String) async -> Bool?)?
    var instructionsProvider: (QuestionCategory) -> String
    var notesProvider: (String) -> [String] = { _ in [] }
    var hasPortfolio: () -> Bool = { false }
    /// Personal-memory grounding check passed to the pipeline (reason when a claim is unsupported).
    var groundingCheck: (String) -> String? = { _ in nil }
    /// Recent conversation text used to judge whether speech relates to the active discussion.
    var topicText: () -> String = { "" }
    /// Called when an answer becomes the displayed answer (conversation memory, code snippets).
    var onAnswerDisplayed: (InterviewQuestion, InterviewAnswer) -> Void = { _, _ in }
    /// Called when an automatic transition is undone.
    var onAnswerUndone: (InterviewAnswer) -> Void = { _ in }

    // MARK: Automatic question handoff

    /// Explicit handoff state (pure reducer in `HandoffPhase`), recorded for diagnostics and tests.
    private(set) var handoff: HandoffPhase = .listening
    private var generationCount = 0
    /// Evidence for the queued (medium-confidence) question; related turns add to it. No timeout.
    private var pendingEvidence = 0.0
    /// The request an Undo just reversed: it needs fresh evidence before switching again (no oscillation).
    private var suppressedQuestion: String?

    func recordHandoff(_ event: HandoffPhase.Event) {
        let next = handoff.next(event)
        guard next != handoff else { return }
        DiagnosticLog.shared.record(.pipeline, "Handoff: \(handoff.rawValue) → \(next.rawValue)")
        handoff = next
    }

    /// Same subject: shared request words (without "tell me about…") or largely the same wording.
    static func related(_ a: String, _ b: String) -> Bool {
        let first = Set(requestKey(a, context: "").split(separator: " ")), second = Set(requestKey(b, context: "").split(separator: " "))
        let shared = first.intersection(second).count
        return TextSimilarity.jaccard(a, b) >= 0.5 || (!first.isEmpty && Double(shared) / Double(first.union(second).count) >= 0.34)
    }
    /// Resolves follow-ups against the active programming task (passed to the pipeline).
    var codingResolver: (String) -> ResolvedCodingRequest? = { _ in nil }
    /// The active programming task (for classifying coding follow-ups).
    var codingTask: () -> ActiveCodingTask? = { nil }
    /// The active project, so "What about security?" about two projects is not called a duplicate.
    var contextKey: () -> String = { "" }
    /// Turn ID → request key it was handled with, and → the answer generated for it.
    private var handledTurns: [Int: String] = [:]
    private(set) var turnAnswers: [Int: Int] = [:]
    private var generatingTurnID: Int?
    private var currentTurnID: Int?
    private var currentTurnIsRevision = false

    // MARK: Continuous conversation

    /// Explicit phase (pure reducer in `ConversationPhase`), recorded for diagnostics and tests.
    private(set) var phase: ConversationPhase = .idle
    private(set) var lastClassification: SpeechClassification?
    /// A medium-confidence follow-up answered in the background, not shown yet.
    private(set) var preparedAnswer: (question: InterviewQuestion, answer: InterviewAnswer)?
    /// The answer replaced by the latest automatic transition (one-tap undo).
    private(set) var undoAnswer: (question: InterviewQuestion?, answer: InterviewAnswer)?
    private var prepareOnly = false
    private var generationKind: SpeechEventKind = .newQuestion

    func record(_ event: ConversationPhase.Event) {
        let next = phase.next(event)
        guard next != phase else { return }
        DiagnosticLog.shared.record(.pipeline, "Phase: \(phase.rawValue) → \(next.rawValue)")
        phase = next
    }

    var ai: () -> any AIResponseProvider
    private let presenter: GlassesPresenter
    private let now: () -> Date
    private var answerShownAt: Date?
    private var recentQuestions: [(key: String, at: Date, turnID: Int?)] = []
    private var cache: [String: AnswerPipeline.Output] = [:]

    init(settings: AppSettings, ai: @escaping () -> any AIResponseProvider, presenter: GlassesPresenter,
         classifier: QuestionDetector = QuestionDetector(), now: @escaping () -> Date = Date.init,
         instructionsProvider: @escaping (QuestionCategory) -> String = { InterviewPromptBuilder.instructions(for: $0, length: .standard, portfolio: "") }) {
        self.settings = settings
        self.ai = ai
        self.presenter = presenter
        self.classifier = classifier
        self.now = now
        self.instructionsProvider = instructionsProvider
    }

    // MARK: Session

    func start() {
        guard state == .idle else { return }
        state = currentAnswer == nil ? .listening : (isLocked ? .answerLocked : .waitingForNextQuestion)
        record(.start)
        note("Listening")
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
        streamingText = ""
        pendingQuestion = nil
        preparedAnswer = nil
        state = .idle
        record(.stop)
        note("Session stopped")
    }

    // MARK: Turns

    /// Entry point for every completed speech turn. Listening never stops while an answer, a walkthrough
    /// or a generation is active; the handoff state records whether the turn led to a new answer.
    func handle(_ turn: CompletedTurn) async {
        guard state != .idle else { return }
        let generations = generationCount, prepared = preparedAnswer?.answer.answerID
        recordHandoff(.turnDetected)
        await process(turn)
        if generationCount == generations, preparedAnswer?.answer.answerID == prepared {
            recordHandoff(.rejected(hasAnswer: currentAnswer != nil))
        }
    }

    private func process(_ turn: CompletedTurn) async {
        let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let started = now()
        currentTurnID = turn.turnID
        currentTurnIsRevision = turn.isRevision
        // One utterance, one generation: a revision only matters when it changes what is being asked.
        if let id = turn.turnID {
            let key = Self.requestKey(text, context: contextKey())
            if turn.isRevision {
                guard handledTurns[id] != key else {
                    counters.duplicate += 1
                    return note("Turn #\(id) revised without changing the request; no new generation")
                }
                note("Turn #\(id) revised: re-evaluating")
                if generatingTurnID == id { generationTask?.cancel() }
                recentQuestions.removeAll { $0.turnID == id }
            }
            handledTurns[id] = key
            if handledTurns.count > 200, let oldest = handledTurns.keys.min() { handledTurns[oldest] = nil }
        }

        var question = classifier.analyze(text, previousQuestion: currentQuestion?.text)
        if settings.continuousConversation { return await handleContinuous(text, question: question, speaker: turn.speaker) }

        // 1. The wearer reading the displayed (or in-progress) answer aloud.
        // The displayed answer, its code (spoken code is never a question) and what is streaming now.
        let reference = [currentAnswer?.text, currentAnswer?.walkthrough?.finalCode ?? currentAnswer?.snippet?.code,
                         streamingText.isEmpty ? nil : streamingText].compactMap { $0 }.joined(separator: " ")
        if !reference.isEmpty {
            let overlap = TextSimilarity.containment(text, in: reference)
            // A clearly question-shaped turn needs much stronger overlap before it is called an echo.
            let threshold = question.score >= settings.autoAdvanceMinScore ? min(settings.echoThreshold + 0.25, 0.95) : settings.echoThreshold
            if overlap >= threshold {
                counters.echo += 1
                return note(String(format: "Ignored (matches displayed answer %.2f)", overlap), quoting: text)
            }
        }

        // 2. Calibrated wearer voice.
        if settings.speakerFilterEnabled, turn.speaker.label == .wearer {
            counters.wearer += 1
            return note("Ignored (wearer voice: \(turn.speaker.reason))", quoting: text)
        }

        guard settings.autoQuestionDetection else { return }

        // 3. Is it a question? Borderline turns may get a semantic check.
        if question.score < settings.questionThreshold, settings.semanticClassification,
           question.score >= settings.questionThreshold - 0.25, let semanticCheck,
           await semanticCheck(text) == true {
            question.score = settings.questionThreshold
            question.reason += ", semantic check: yes"
        }
        lastClassificationSeconds = now().timeIntervalSince(started)
        guard question.score >= settings.questionThreshold else {
            counters.notQuestion += 1
            return note(String(format: "Not a question (%.2f, %@)", question.score, question.reason), quoting: text)
        }

        // 4. Duplicates of something already asked recently.
        if !turn.isRevision, isDuplicate(question.text) {
            counters.duplicate += 1
            return note("Ignored duplicate question", quoting: text)
        }

        // 5. Lock handling. The lock protects against accidental overwrites, not legitimate questions:
        // a confident question replaces the answer automatically (the old one stays visible until the new
        // one's first validated frame); a less certain one is queued and confirmed by later evidence.
        let busy = state == .generating || state == .questionDetected
        if (isLocked && currentAnswer != nil) || busy {
            // A corrected version of the turn already being answered replaces it directly.
            if turn.isRevision, let id = turn.turnID, turnAnswers[id] != nil || generatingTurnID == id {
                return startGeneration(for: question)
            }
            if let pending = pendingQuestion, Self.related(pending.text, question.text) {
                pendingEvidence += question.score
                if pendingEvidence >= 1.2 {
                    counters.autoAdvanced += 1
                    note(String(format: "Handoff accepted: queued question confirmed by a related turn (evidence %.2f)", pendingEvidence))
                    return startGeneration(for: question)
                }
            } else {
                pendingEvidence = question.score
            }
            pendingQuestion = question
            if canAutoAdvance(question, speaker: turn.speaker, replacingVisibleAnswer: !busy) {
                counters.autoAdvanced += 1
                note(String(format: "Handoff accepted: confident question (%.2f, speaker %@)", question.score, turn.speaker.label.rawValue))
                return startGeneration(for: question)
            }
            counters.queued += 1
            return note(String(format: "Handoff deferred: queued (confidence %.2f, speaker %@)", question.score, turn.speaker.label.rawValue), quoting: text)
        }
        startGeneration(for: question)
    }

    /// Continuous conversation: every turn is classified in the context of the active discussion.
    /// High confidence answers (and transitions) automatically; medium prepares the answer but keeps the
    /// current frame; low never touches the display.
    private func handleContinuous(_ text: String, question: InterviewQuestion, speaker: SpeakerEvidence) async {
        // The displayed answer, its code (spoken code is never a question) and what is streaming now.
        let reference = [currentAnswer?.text, currentAnswer?.walkthrough?.finalCode ?? currentAnswer?.snippet?.code,
                         streamingText.isEmpty ? nil : streamingText].compactMap { $0 }.joined(separator: " ")
        let overlap = reference.isEmpty ? 0 : TextSimilarity.containment(text, in: reference)
        let echoThreshold = question.score >= settings.autoAdvanceMinScore ? min(settings.echoThreshold + 0.25, 0.95) : settings.echoThreshold
        let topic = [topicText(), currentQuestion?.text ?? "", currentAnswer?.text ?? ""].joined(separator: " ")
        let speakerLabel = settings.speakerFilterEnabled ? speaker.label : .unknown
        let event = SpeechEventClassifier.classify(text, question: question, echoOverlap: overlap, echoThreshold: echoThreshold,
                                                   speaker: speakerLabel, questionThreshold: settings.questionThreshold, topicText: topic,
                                                   hasActiveAnswer: currentAnswer != nil || state == .generating, codingTask: codingTask())
        lastClassification = event
        note(String(format: "Speech event: %@, %@ confidence %.2f (%@), speaker %@", event.kind.label, event.tier.rawValue,
                    event.confidence, event.reason, speakerLabel.rawValue), quoting: text)
        switch event.kind {
        case .readingAnswer: counters.echo += 1; return
        case .userResponse: counters.wearer += 1; return
        default: break
        }
        guard event.kind.wantsAnswer, event.tier != .low else { counters.notQuestion += 1; return }
        // Later related evidence (the question repeated or rephrased) confirms a prepared answer.
        if let prepared = preparedAnswer, Self.related(prepared.question.text, text) {
            return showPreparedAnswer(reason: "confirmed by a related turn")
        }
        if !currentTurnIsRevision, isDuplicate(text) { counters.duplicate += 1; return note("Ignored duplicate question", quoting: text) }

        var asked = question
        asked.isFollowUp = event.kind.continuesDiscussion && currentAnswer != nil
        asked.score = max(question.score, event.confidence)
        asked.reason = "\(event.kind.label): \(event.reason)"
        record(.question(followUp: asked.isFollowUp))
        let undone = suppressedQuestion.map { Self.related($0, text) } ?? false
        if undone { suppressedQuestion = nil; note("Handoff rejected: this question was just undone; preparing instead") }
        if (event.tier == .high && !undone) || currentAnswer == nil {
            // The newest confident question wins (an older generation is cancelled); with nothing on screen
            // there is no answer to protect, so a medium-confidence question is answered directly too.
            startGeneration(for: asked, kind: event.kind)
        } else if state == .generating {
            pendingQuestion = asked
            counters.queued += 1
            note("Medium-confidence question queued during generation")
        } else {
            note("Medium confidence: preparing the answer; the current frame stays until confirmed")
            startGeneration(for: asked, kind: event.kind, prepareOnly: true)
        }
    }

    /// Shows the prepared (medium-confidence) answer: on tap, when reading completes, or when confirmed.
    func showPreparedAnswer(reason: String) {
        guard let prepared = preparedAnswer else { return }
        preparedAnswer = nil
        note("Showing prepared answer (\(reason))")
        if let currentAnswer { undoAnswer = (currentQuestion, currentAnswer) }
        currentQuestion = prepared.question
        currentAnswer = prepared.answer
        answerShownAt = now()
        record(.transition)
        let answer = prepared.answer
        Task {
            let shown = presentation(of: answer)
            await presenter.present(shown.text, answerID: answer.answerID, endMarker: shown.marker)
            record(.answerShown)
        }
        isLocked = settings.lockAfterDisplay
        if state != .generating { state = isLocked ? .answerLocked : .waitingForNextQuestion }
        onAnswerDisplayed(prepared.question, answer)
    }

    func dismissPrepared() { preparedAnswer = nil }

    /// Reverses the latest automatic transition: the previous answer returns under its own identity.
    func undoTransition() {
        guard let previous = undoAnswer else { return }
        undoAnswer = nil
        generationTask?.cancel()
        suppressedQuestion = currentQuestion?.text
        recordHandoff(.answerShown)
        currentQuestion = previous.question
        currentAnswer = previous.answer
        answerShownAt = now()
        note("Transition undone: answer #\(previous.answer.answerID) restored")
        let answer = previous.answer
        let shown = presentation(of: answer)
        Task { await presenter.present(shown.text, answerID: answer.answerID, endMarker: shown.marker) }
        onAnswerUndone(previous.answer)
    }

    /// High confidence, not the wearer's voice, not a just-undone request, and (when replacing an answer that
    /// is on screen) outside the short anti-oscillation cooldown. During a generation the newest question wins.
    private func canAutoAdvance(_ question: InterviewQuestion, speaker: SpeakerEvidence, replacingVisibleAnswer: Bool = true) -> Bool {
        guard settings.autoAdvance, question.score >= settings.autoAdvanceMinScore, speaker.label != .wearer else { return false }
        if let suppressedQuestion, Self.related(suppressedQuestion, question.text) {
            self.suppressedQuestion = nil
            note("Handoff rejected: this question was just undone; waiting for more evidence")
            return false
        }
        guard replacingVisibleAnswer, let shownAt = answerShownAt else { return true }
        return now().timeIntervalSince(shownAt) >= settings.minimumLockSeconds
    }

    /// The same request asked again (or re-recognised with other wording: "tell me about" / "talk about").
    private func isDuplicate(_ text: String) -> Bool {
        let current = now()
        recentQuestions.removeAll { current.timeIntervalSince($0.at) > 180 }
        let key = Self.requestKey(text, context: contextKey())
        let words = Set(key.split(separator: " "))
        return recentQuestions.contains { previous in
            let other = Set(previous.key.split(separator: " "))
            return previous.key == key || (!words.isEmpty && Double(words.intersection(other).count) / Double(words.union(other).count) >= 0.8)
        }
    }

    /// Content words of a request without request verbs, plus the active project.
    static func requestKey(_ text: String, context: String) -> String {
        let words = TextSimilarity.contentWords(text).map { $0.lowercased() }.filter { !SpeechEventClassifier.requestFiller.contains($0) }
        // The active project only disambiguates requests that do not name a subject of their own.
        let tagged = context.isEmpty || words.contains(context.lowercased()) ? [] : ["@" + context.lowercased()]
        return (Array(Set(words)).sorted() + tagged).joined(separator: " ")
    }

    // MARK: Generation

    private func startGeneration(for question: InterviewQuestion, kind: SpeechEventKind? = nil, prepareOnly: Bool = false) {
        generationTask?.cancel()
        generationCount += 1
        pendingEvidence = 0
        recordHandoff(.resolved)
        recordHandoff(.generationStarted)
        self.prepareOnly = prepareOnly
        generationKind = kind ?? (question.isFollowUp ? .followUp : .newQuestion)
        if !prepareOnly { preparedAnswer = nil }
        pendingQuestion = nil
        state = .questionDetected
        recentQuestions.append((Self.requestKey(question.text, context: contextKey()), now(), currentTurnID))
        generatingTurnID = currentTurnID
        if recentQuestions.count > 10 { recentQuestions.removeFirst() }
        let previous = question.isFollowUp ? currentAnswer.map { ($0.question, $0.text) } : nil
        note("Question detected (\(String(format: "%.2f", question.score)), \(question.reason))", quoting: question.text)
        let pendingCurrent = currentQuestion
        if !prepareOnly { currentQuestion = question }
        state = .generating
        record(.generationStarted)
        streamingText = ""
        let answerID = AnswerIdentity.next()
        generatingAnswerID = answerID
        generationTask = Task { [weak self] in
            await self?.generate(question, answerID: answerID, previous: previous, restoreQuestion: pendingCurrent)
        }
    }

    private func generate(_ question: InterviewQuestion, answerID: Int, previous: (String, String)?, restoreQuestion: InterviewQuestion?) async {
        defer { if generatingAnswerID == answerID { generatingAnswerID = nil } }
        let started = now()
        generationStarted = started
        earlyFrameSeconds = nil
        firstFrameSubmitted = nil
        let key = TextSimilarity.normalized(question.text) + "|" + settings.answerLength.rawValue
        do {
            let output: AnswerPipeline.Output
            var fromCache = false
            if settings.cacheAnswers, let cached = cache[key] {
                output = cached
                fromCache = true
            } else {
                earlyFrameShown = false
                earlyFrameTask = nil
                let pipeline = AnswerPipeline(
                    provider: ai(), instructions: instructionsProvider, notes: notesProvider, answerLength: settings.answerLength,
                    hasPortfolio: hasPortfolio(), now: now,
                    onPartial: { [weak self] partial, category in
                        self?.streamingText = partial
                        self?.considerEarlyFrame(partial, category: category, answerID: answerID)
                    }, log: { [weak self] in self?.note($0) })
                pipeline.answerID = answerID
                pipeline.groundingCheck = groundingCheck
                pipeline.codingResolver = codingResolver
                output = try await pipeline.answer(question.text, previous: previous.map { (question: $0.0, answer: $0.1) })
                try Task.checkCancellation()
            }
            guard !output.text.isEmpty else { throw AIError.emptyAnswer }
            // Only validated model answers are cached; clarifications, math and fallbacks are cheap or must not stick.
            if settings.cacheAnswers, !fromCache, output.validation == "passed" {
                if cache.count > 200 { cache.removeAll() }
                cache[key] = output
            }
            // A cached output keeps its text but belongs to this new answer.
            var answer = InterviewAnswer(answerID: answerID, question: question.text, text: output.text, fromCache: fromCache,
                                         firstTokenSeconds: output.firstTokenSeconds, totalSeconds: now().timeIntervalSince(started),
                                         createdAt: now(), category: output.category, routeMilliseconds: output.routeMilliseconds,
                                         validation: output.validation, regenerated: output.regenerated)
            answer.firstSentenceSeconds = output.firstSentenceSeconds
            answer.snippet = output.snippet
            answer.walkthrough = output.walkthrough
            answer.walkthrough?.taskID = codingTask()?.id
            answer.kind = generationKind
            if prepareOnly {
                preparedAnswer = (question, answer)
                streamingText = ""
                state = currentAnswer == nil ? .listening : (isLocked ? .answerLocked : .waitingForNextQuestion)
                return note("Answer #\(answerID) prepared (medium confidence); tap Show or keep reading")
            }
            let replacing = currentAnswer != nil
            // Every automatic replacement can be undone (classic and continuous conversation).
            if let currentAnswer { undoAnswer = (restoreQuestion, currentAnswer) }
            answer.generationComplete = output.generationComplete
            answer.completion = output.completion
            answer.provider = output.provider
            answer.earlyFrameSeconds = earlyFrameSeconds
            note(String(format: "Answer generated: %d chars, %@, in %.2fs (validation %@)", output.text.count, output.category.rawValue,
                        answer.totalSeconds, output.validation))
            state = .displayingAnswer
            currentAnswer = answer
            streamingText = ""
            answerShownAt = now()
            await earlyFrameTask?.value
            if earlyFrameShown, !output.text.hasPrefix(earlyFrameText) {
                earlyFrameReplacements += 1
                note("Answer #\(answerID): final answer differs from the early frame (validation regenerated it); frame replaced")
            }
            if replacing { record(.transition) }
            recordHandoff(.replacementReady)
            if replacing { recordHandoff(.switched) }
            if let turnID = generatingTurnID { turnAnswers[turnID] = answerID }
            let shown = presentation(of: answer)
            await presenter.present(shown.text, answerID: answerID, continuingProvisional: earlyFrameShown && shown.text == output.text,
                                    endMarker: shown.marker)
            record(.answerShown)
            onAnswerDisplayed(question, answer)
            if firstFrameSubmitted == nil, presenter.lastWrite?.answerID == answerID, presenter.lastWrite?.result.hasPrefix("handed") == true {
                firstFrameSubmitted = now().timeIntervalSince(started)
            }
            currentAnswer?.frameSubmittedSeconds = firstFrameSubmitted
            if let seconds = firstFrameSubmitted { note(String(format: "Answer #%d: first frame submitted to Bluetooth after %.2fs (not proof of visibility)", answerID, seconds)) }
            recordHandoff(.answerShown)
            if replacing { note(String(format: "Handoff complete: old answer deactivated; question → replacement frame %.2fs", firstFrameSubmitted ?? 0)) }
            guard !Task.isCancelled, state == .displayingAnswer else { return }
            isLocked = settings.lockAfterDisplay
            state = isLocked ? .answerLocked : .waitingForNextQuestion
            if isLocked { note("Answer lock activated") }
            note(String(format: "Answer displayed in %.2fs", answer.totalSeconds))
        } catch is CancellationError {
            record(.cancelled)
            recordHandoff(.cancelled(hasAnswer: currentAnswer != nil))
            await restoreAfterEarlyFrame()
            settleAfterInterruptedGeneration(restoreQuestion)
            note("Generation cancelled")
        } catch {
            guard !Task.isCancelled else { return settleAfterInterruptedGeneration(restoreQuestion) }
            streamingText = ""
            await restoreAfterEarlyFrame()
            record(.failed)
            state = .error(error.localizedDescription)
            note("Generation failed: \(error.localizedDescription)")
            // Errors are not terminal: keep listening and keep any previously displayed answer.
            try? await Task.sleep(for: .seconds(2))
            if case .error = state { state = currentAnswer == nil ? .listening : (isLocked ? .answerLocked : .waitingForNextQuestion) }
        }
    }

    // MARK: Early first frame

    /// Times a shown early frame had to be replaced because the validated answer differs (regeneration).
    private(set) var earlyFrameReplacements = 0
    /// Identity of the answer being generated (nil when idle); the locked answer's is `currentAnswer?.answerID`.
    private(set) var generatingAnswerID: Int?
    private var earlyFrameText = ""
    private var firstFrameSubmitted: Double?

    /// What the teleprompter shows first: a guided walkthrough starts with its first explanation block
    /// (the Code Tutor then moves through the rest); any other answer is shown whole.
    func presentation(of answer: InterviewAnswer) -> (text: String, marker: String?) {
        if settings.codeDisplay == .tutor, let walkthrough = answer.walkthrough, let first = walkthrough.blocks.first, first.kind == .explanation {
            return (first.text, walkthrough.blocks.count == 1 ? endMarker(for: answer) : nil)
        }
        return (answer.text, endMarker(for: answer))
    }

    /// The marker is only for an answer that finished normally and passed validation.
    func endMarker(for answer: InterviewAnswer) -> String? {
        answer.generationComplete ? settings.endMarker.text : nil
    }
    private var earlyFrameShown = false
    private var earlyFrameTask: Task<Void, Never>?
    private var earlyFrameSeconds: Double?
    private var generationStarted: Date?

    /// Shows the first frame of a streaming technical/coding answer once it is final: only complete
    /// sentences, no filler, and more text already beyond the frame. Never a partial word.
    private func considerEarlyFrame(_ partial: String, category: QuestionCategory, answerID: Int) {
        // Partials of a superseded generation never reach the lens.
        // Coding answers are validated as a whole first: partially streamed code never reaches the glasses.
        guard settings.earlyFirstFrame, !prepareOnly, !earlyFrameShown, answerID == generatingAnswerID,
              category == .technical else { return }
        let complete = AnswerFormatter.completeSentences(partial)
        // The early text must already pass the same validation as a final answer (no fake experience, on topic).
        guard !complete.isEmpty, AnswerValidator.removeFiller(complete, category: category)?.removed == 0,
              let question = currentQuestion?.text,
              AnswerValidator.validate(complete, question: question, category: category, hasPortfolio: hasPortfolio()).passed,
              let frame = presenter.stableFirstFrame(of: complete) else { return }
        earlyFrameShown = true
        earlyFrameText = frame
        earlyFrameSeconds = generationStarted.map { now().timeIntervalSince($0) }
        note(String(format: "Answer #%d: first frame validated after %.2fs (early, while streaming)", answerID, earlyFrameSeconds ?? 0))
        let started = generationStarted
        earlyFrameTask = Task {
            await presenter.presentProvisional(frame, answerID: answerID)
            if presenter.lastWrite?.answerID == answerID, presenter.lastWrite?.result.hasPrefix("handed") == true, let started {
                firstFrameSubmitted = now().timeIntervalSince(started)
            }
        }
    }

    /// A failed or cancelled generation must not leave its provisional frame on the lens.
    private func restoreAfterEarlyFrame() async {
        guard earlyFrameShown else { return }
        earlyFrameShown = false
        await earlyFrameTask?.value
        // The previous answer returns under its own identity.
        if let previous = currentAnswer {
            let shown = presentation(of: previous)
            await presenter.present(shown.text, answerID: previous.answerID, endMarker: shown.marker)
        } else {
            await presenter.clearDisplay()
        }
        note("Provisional frame withdrawn")
    }

    private func settleAfterInterruptedGeneration(_ restoreQuestion: InterviewQuestion?) {
        streamingText = ""
        guard state != .idle else { return }
        if currentAnswer?.question != currentQuestion?.text { currentQuestion = restoreQuestion }
        state = currentAnswer == nil ? .listening : (isLocked ? .answerLocked : .waitingForNextQuestion)
    }

    // MARK: Manual controls

    func lock() {
        isLocked = true
        if currentAnswer != nil, state != .idle, state != .generating { state = .answerLocked }
        note("Answer locked")
    }

    func unlock() {
        isLocked = false
        if state == .answerLocked { state = .waitingForNextQuestion }
        note("Answer unlocked")
    }

    /// Answers the queued question now, or unlocks so the next question is answered.
    func nextQuestion() {
        guard state != .idle else { return }
        if let pending = pendingQuestion, state != .generating {
            note("Manual advance to queued question")
            startGeneration(for: pending)
        } else {
            unlock()
        }
    }

    func cancelGeneration() {
        guard generationTask != nil else { return }
        generationTask?.cancel()
    }

    func dismissPending() { pendingQuestion = nil }

    func clearCache() { cache.removeAll() }

    /// Quoted speech goes only to the on-screen engine log; the exportable timeline gets its length.
    private func note(_ message: String, quoting text: String? = nil) {
        DiagnosticLog.shared.record(.pipeline, text.map { "\(message) [\($0.count) chars]" } ?? message)
        let message = text.map { "\(message): \($0.prefix(60))" } ?? message
        log.append(EngineLogEntry(date: now(), message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// Automatic question handoff: listening → answer active → new turn → resolved → generating the
/// replacement (old answer still visible) → replacement ready → switching → answer active. Pure reducer.
nonisolated enum HandoffPhase: String, Sendable {
    case listening, answerActive, newTurnDetected, followUpResolved, generatingReplacement, replacementReady, switching

    enum Event: Equatable, Sendable {
        case turnDetected, resolved, generationStarted, replacementReady, switched, answerShown, reset
        case rejected(hasAnswer: Bool), cancelled(hasAnswer: Bool)
    }

    func next(_ event: Event) -> HandoffPhase {
        switch (self, event) {
        case (_, .reset): .listening
        case (_, .answerShown): .answerActive
        case (.generatingReplacement, .turnDetected): .generatingReplacement // listening continues; the turn decides later
        case (_, .turnDetected): .newTurnDetected
        case (.newTurnDetected, .resolved): .followUpResolved
        case (_, .generationStarted): .generatingReplacement
        case (.generatingReplacement, .replacementReady): .replacementReady
        case (.replacementReady, .switched): .switching
        case (.newTurnDetected, .rejected(let hasAnswer)), (.followUpResolved, .rejected(let hasAnswer)):
            hasAnswer ? .answerActive : .listening
        case (.generatingReplacement, .cancelled(let hasAnswer)), (.replacementReady, .cancelled(let hasAnswer)):
            hasAnswer ? .answerActive : .listening
        default: self
        }
    }
}
