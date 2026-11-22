import Foundation

enum ReadingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, speechSynced
    var id: String { rawValue }
    var label: String { self == .manual ? "Manual" : "Speech-Synced" }
}

/// Speech-Synced Reading: a moving caption window that scrolls one visual line at a time as the wearer
/// finishes each line. Manual Reading pages by section. Display writes happen only when the window moves,
/// through the presenter's ordered, coalescing writer (verified caption path).
@MainActor @Observable final class ReadingController {
    var mode: ReadingMode = .manual {
        didSet {
            guard mode != oldValue else { return }
            updateScrolling()
            DiagnosticLog.shared.record(.pipeline, "Reading mode: \(mode.label)")
        }
    }
    /// False for the Stable Sections caption strategy: speech-synced reading then advances by section.
    var lineScrollingAllowed = true {
        didSet { if lineScrollingAllowed != oldValue { updateScrolling() } }
    }

    private func updateScrolling() {
        presenter.lineScrolling = mode == .speechSynced && lineScrollingAllowed
    }
    var responsiveness: ReadingResponsiveness = .balanced {
        didSet { alignment?.responsiveness = responsiveness }
    }
    /// Sentence Frames with verified frame replacement: overlapping windows that jump ahead of the reader.
    var lookaheadWindows = false
    /// The reader reached the answer's last meaningful word: auto-scroll stops and the final frame stays
    /// (independent of generation completion; nothing is cleared automatically).
    private(set) var readingComplete = false
    private(set) var autoScrollPaused = false
    private(set) var cursorWord = -1
    private(set) var totalWords = 0
    private(set) var progress = 0.0
    private(set) var confidence = 0.0
    private(set) var lastDecision = "No answer yet"
    private(set) var boundaries = 0

    private let presenter: GlassesPresenter
    private let now: () -> Date
    private var alignment: ReadingAlignment?
    private var alignedRevision = -1
    /// Last window per answer, so Undo of an automatic switch returns to where the reader was.
    private var positions: [Int: Int] = [:]
    private var lastPage = 0
    /// Identity of the answer the alignment belongs to (the presenter's answer ID when it was built).
    private(set) var answerID = 0

    init(presenter: GlassesPresenter, now: @escaping () -> Date = Date.init) {
        self.presenter = presenter
        self.now = now
    }

    /// Top visual line (Speech-Synced) or section (Manual) currently shown.
    var position: Int { presenter.pageIndex }
    var positionCount: Int { presenter.pages.count }

    /// Feed every partial and final transcript update. Ignored in Manual mode.
    func ingest(_ text: String, isFinal: Bool, speaker: SpeakerLabel) {
        guard mode == .speechSynced else { return }
        syncPlan()
        guard var current = alignment else { return }
        let update = current.ingest(text, isFinal: isFinal, speaker: speaker, at: now())
        alignment = current
        publish(current)
        lastDecision = update.reason
        guard !readingComplete else { return }
        if let last = current.plan.lastMeaningfulWord, current.cursor >= last {
            readingComplete = true
            lastDecision = "Reading complete: the final frame stays until you move on"
            DiagnosticLog.shared.record(.pipeline, "Answer #\(answerID): reading completed")
            let final = presenter.pages.count - 1
            if presenter.pageIndex < final, !autoScrollPaused { presenter.scheduleShowPage(final) }
            return
        }
        guard update.accepted || update.heardBeyond > 0 else { return }

        let top = presenter.pageIndex
        let maxTop = max(0, presenter.pages.count - 1)
        var target: Int
        if presenter.lineScrolling, lookaheadWindows {
            // Word-level evidence only: heard-but-unmatched speech never moves the window.
            guard update.accepted, responsiveness != .conservative || update.confidence >= 0.7 else { return }
            target = current.lookaheadTop(current: top, window: presenter.windowLines, maxTop: maxTop,
                                          strongEvidence: update.matched >= 3 && update.confidence >= 0.6)
            if target > top {
                DiagnosticLog.shared.record(.pipeline, "Answer #\(answerID): look-ahead threshold reached (reading line \(readingLine.map { $0 + 1 } ?? 0), \(remainingUnreadLines ?? 0) unread line(s) left) → window top \(target + 1)")
            }
        } else if presenter.lineScrolling {
            target = current.suggestedTopLine(current: top, maxTop: maxTop, heardBeyond: update.heardBeyond, utteranceEnded: isFinal)
            // Several lines at once only on strong evidence; otherwise one line per update.
            let strong = update.accepted && update.matched >= 4 && update.confidence >= 0.7
            if target > top + 1, !strong { target = top + 1 }
        } else {
            // Frames / sections: advance once the frame's last meaningful words were read (partials count).
            target = current.suggestedFrame(displayed: top, heardBeyond: update.heardBeyond, utteranceEnded: isFinal)
        }
        guard target > top else { return }
        guard !autoScrollPaused else {
            lastDecision = "Auto-scroll paused (you have reached line \(target + 1))"
            return
        }
        boundaries += 1
        let unit = presenter.lineScrolling ? "line" : "section"
        lastDecision = "\(unit.capitalized) \(top + 1) finished → \(unit) \(target + 1)"
        DiagnosticLog.shared.record(.pipeline, String(format: "%@ boundary: word %d/%d, %@ %d finished, confidence %.2f → %@ %d/%d; caption update requested",
                                                      unit.capitalized, current.cursor + 1, current.plan.words.count, unit, top + 1,
                                                      update.confidence, unit, target + 1, presenter.pages.count))
        presenter.scheduleShowPage(target)
        lastPage = target
        prepareNext()
    }

    /// Returns to the window the reader had reached in `answerID` (after an Undo restored that answer).
    @discardableResult
    func restorePosition(for answerID: Int) -> Bool {
        syncPlan()
        guard presenter.answerID == answerID, let page = positions[answerID], page > 0 else { return false }
        move(to: page, reason: "Reading position restored (undo)")
        return true
    }

    /// Renders the window the next advance will show, ahead of time.
    private func prepareNext() {
        let top = presenter.pageIndex, last = presenter.pages.count - 1
        guard top < last else { return }
        presenter.prepare(min(last, top + frameStep))
    }

    /// Visual line holding the next word to read.
    var readingLine: Int? {
        guard let alignment, !alignment.plan.words.isEmpty else { return nil }
        return alignment.plan.line(containing: min(max(alignment.cursor + 1, 0), alignment.plan.words.count - 1))
    }

    /// Unread lines on screen below the line being read.
    var remainingUnreadLines: Int? {
        guard let plan = presenter.plan, let line = readingLine else { return nil }
        let last = presenter.pageLines(presenter.pageIndex)?.upperBound
            ?? (plan.sections.indices.contains(presenter.pageIndex) ? plan.line(containing: plan.sections[presenter.pageIndex].words.upperBound - 1) : nil)
        return last.map { max(0, $0 - line) }
    }

    func pauseAutoScroll() {
        autoScrollPaused = true
        lastDecision = "Auto-scroll paused"
    }

    /// Resumes and catches up with one update if reading already moved past the visible top line.
    func resumeAutoScroll() {
        autoScrollPaused = false
        lastDecision = "Auto-scroll resumed"
        guard mode == .speechSynced, let alignment else { return }
        let target = presenter.lineScrolling
            ? alignment.suggestedTopLine(current: presenter.pageIndex, maxTop: max(0, presenter.pages.count - 1), heardBeyond: 0, utteranceEnded: false)
            : alignment.suggestedFrame(displayed: presenter.pageIndex, heardBeyond: 0, utteranceEnded: false)
        if target > presenter.pageIndex { presenter.scheduleShowPage(target) }
    }

    /// One line back (Speech-Synced) or one section back (Manual).
    func previousSection() { move(to: max(0, presenter.pageIndex - frameStep)) }
    /// One line forward (Speech-Synced) or one section forward (Manual).
    func nextSection() { move(to: min(presenter.pages.count - 1, presenter.pageIndex + frameStep)) }

    /// One "frame" of manual movement: a look-ahead jump in look-ahead mode, otherwise one window.
    private var frameStep: Int {
        presenter.lineScrolling && lookaheadWindows ? max(1, presenter.windowLines - (alignment?.lookaheadLines ?? 2)) : 1
    }
    func resetProgress() { move(to: 0, reason: "Reset to the beginning") }

    private func move(to index: Int, reason: String? = nil) {
        guard presenter.pages.indices.contains(index) else { return }
        syncPlan()
        if presenter.lineScrolling { alignment?.moveCursor(toStartOfLine: index) } else { alignment?.moveCursor(toStartOf: index) }
        if let alignment { publish(alignment) }
        readingComplete = false // a manual move resumes reading from that position
        lastDecision = reason ?? "Moved to \(presenter.lineScrolling ? "line" : "section") \(index + 1) manually"
        presenter.scheduleShowPage(index)
        lastPage = index
        prepareNext()
    }

    /// A new answer replaces the alignment and starts at its first line.
    private func syncPlan() {
        guard presenter.planRevision != alignedRevision else { return }
        alignedRevision = presenter.planRevision
        let previous = alignment
        let sameAnswer = presenter.continuedAnswer && presenter.answerID == answerID
        if presenter.answerID != answerID { positions[answerID] = lastPage; lastPage = 0 }
        answerID = presenter.answerID
        alignment = presenter.plan.map { plan in
            var alignment = ReadingAlignment(plan: plan)
            alignment.responsiveness = responsiveness
            // Same answer grown from a provisional first frame: keep the reader's progress.
            if sameAnswer, let previous { alignment.continueFrom(previous) }
            return alignment
        }
        if let alignment { publish(alignment) }
        prepareNext()
        guard !sameAnswer else { return }
        readingComplete = false
        boundaries = 0
        lastDecision = "New answer: waiting for you to start reading"
    }

    private func publish(_ alignment: ReadingAlignment) {
        cursorWord = alignment.cursor
        totalWords = alignment.plan.words.count
        progress = alignment.progress
        confidence = alignment.confidence
    }
}
