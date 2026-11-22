import Foundation

/// Link and display-session state. Authentication and display readiness are separate:
/// `.ready` means a display session was ACKNOWLEDGED by the glasses (it never means text is visible).
enum GlassesConnectionState: Equatable, Sendable {
    case disconnected
    case unavailable(String)
    case scanning
    case connecting
    case discovering
    case authenticating
    /// Link authenticated, no display session open.
    case authenticated
    case startingSession
    /// Session start sent, no acknowledgement within the timeout. Sending is blocked unless explicitly allowed.
    case sessionUnconfirmed
    case sessionRejected(String)
    /// The glasses paused the session (e.g. display asleep); it resumes with the same session ID.
    case sessionPaused(String)
    /// Display session confirmed: ready to send.
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .unavailable(let reason): "Unavailable: \(reason)"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .discovering: "Discovering services…"
        case .authenticating: "Authenticating…"
        case .authenticated: "Authenticated (no display session)"
        case .startingSession: "Starting display session…"
        case .sessionUnconfirmed: "Display session UNCONFIRMED (no acknowledgement)"
        case .sessionRejected(let reason): "Display session rejected: \(reason)"
        case .sessionPaused(let reason): "Display session paused by glasses (\(reason))"
        case .ready: "Display session confirmed"
        case .failed(let reason): "Error: \(reason)"
        }
    }

    /// An attempt is running; a new connect request must not interrupt it.
    var isInProgress: Bool {
        switch self {
        case .scanning, .connecting, .discovering, .authenticating, .startingSession: true
        default: false
        }
    }

    /// The link is up and authenticated.
    var isAuthenticatedLink: Bool {
        switch self {
        case .authenticated, .startingSession, .sessionUnconfirmed, .sessionRejected, .sessionPaused, .ready: true
        default: false
        }
    }
}

/// Display protocol abstraction. Real hardware and the simulator implement the same contract.
@MainActor protocol GlassesDisplay: AnyObject {
    var name: String { get }
    var isSimulated: Bool { get }
    var connectionState: GlassesConnectionState { get }
    var onStateChange: ((GlassesConnectionState) -> Void)? { get set }
    /// True only when text may be sent (confirmed session, or an explicitly allowed unconfirmed one).
    var isReadyToSend: Bool { get }
    /// Why text cannot be sent right now (nil when it can).
    var sendBlockedReason: String? { get }
    /// One-line state for diagnostics: no conversation text, no secrets.
    var diagnosticSummary: String { get }
    func connect()
    func disconnect()
    /// Asked when text is waiting but cannot be sent; may reopen a session the device closed.
    func reopenSessionIfClosed()
    /// Replaces the text on the glasses. Success means the write was submitted, not that it is visible.
    func show(_ text: String) async throws
    /// Blanks the caption (app side; the lens result must be confirmed by looking).
    func clear() async throws
    /// Closes the current display session and opens a fresh one (verified close/start messages only).
    func restartSession()
}

enum GlassesError: LocalizedError, Equatable {
    case notReady
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "Glasses are not connected"
        case .writeFailed(let reason): "Glasses write failed: \(reason)"
        }
    }
}

/// In-app simulated glasses. Never presented as proof of real hardware integration.
@MainActor final class MockGlassesDisplay: GlassesDisplay {
    let name = "Simulator"
    let isSimulated = true
    private(set) var connectionState: GlassesConnectionState = .disconnected { didSet { onStateChange?(connectionState) } }
    var onStateChange: ((GlassesConnectionState) -> Void)?
    var isReadyToSend: Bool { connectionState == .ready }
    var sendBlockedReason: String? { isReadyToSend ? nil : connectionState.label }
    var diagnosticSummary: String { "simulator, \(connectionState.label)" }
    private(set) var shown: [String] = []
    var failNextWrite = false

    func connect() { connectionState = .ready }
    func reopenSessionIfClosed() {}
    func disconnect() { connectionState = .disconnected }
    func simulateDrop() { connectionState = .disconnected }

    func show(_ text: String) async throws {
        guard connectionState == .ready else { throw GlassesError.notReady }
        if failNextWrite { failNextWrite = false; throw GlassesError.writeFailed("simulated failure") }
        shown.append(text)
    }

    private(set) var restarts = 0
    func restartSession() { restarts += 1 }

    private(set) var clears = 0
    func clear() async throws {
        guard connectionState == .ready else { throw GlassesError.notReady }
        clears += 1
    }
}

/// Owns what should be on the glasses: pagination, manual paging and restore after reconnect.
@MainActor @Observable final class GlassesPresenter {
    /// One caption handed to the display. Content-free: safe for ordinary diagnostic exports.
    struct CaptionWrite: Equatable, Sendable {
        var answerID: Int
        var generation: Int
        var kind: String
        var page: Int
        var pageCount: Int
        var words: Range<Int>?
        var lines: ClosedRange<Int>?
        var characters: Int
        var lineBreaks: Int
        var final: Bool
        var result: String
        var latencyMs: Double?

        var summary: String {
            var parts = ["answer #\(answerID)", "gen \(generation)", kind]
            if kind == "window" { parts.append("window \(page + 1)/\(pageCount)") }
            if let words, !words.isEmpty { parts.append("words \(words.lowerBound)–\(words.upperBound - 1)") }
            if let lines { parts.append("lines \(lines.lowerBound)–\(lines.upperBound)") }
            parts += ["\(characters) chars", "\(lineBreaks) line breaks", final ? "final" : "in progress", result]
            if let latencyMs { parts.append(String(format: "%.0f ms after request", latencyMs)) }
            return parts.joined(separator: ", ")
        }
    }

    /// OpenRayneo's verified blank caption: a full-width space.
    nonisolated static let blank = "\u{3000}"

    private(set) var display: any GlassesDisplay
    private(set) var connectionState: GlassesConnectionState
    private(set) var pages: [String] = []
    private(set) var pageIndex = 0
    /// Sections, visual lines and word map of the active answer.
    private(set) var plan: ReadingPlan?
    private(set) var planRevision = 0
    private(set) var lastError: String?
    private(set) var lastSendSeconds: Double?
    private(set) var sendCount = 0
    /// Human-readable delivery state of the current page (written ≠ visible).
    private(set) var deliveryStatus = "Nothing sent yet"
    /// Identity of the active answer and of the desired display state. Every change bumps `generation`;
    /// the writer only ever sends the newest generation, so requests from older answers are dropped.
    private(set) var answerID = 0
    private(set) var generation = 0
    /// The app has cleared the lens (confirmed only by looking at the glasses).
    private(set) var cleared = false
    /// The current plan continues the previous one (a provisional first frame completed).
    private(set) var continuedAnswer = false
    /// A provisional first frame from a still-streaming answer is showing.
    private(set) var provisional = false
    private(set) var lastWrite: CaptionWrite?
    /// Exact text last handed to the display, for the opt-in local debug view only.
    private(set) var outgoingCaption: String?
    /// Line-aware caption layout (calibrated on the device).
    var layout: CaptionLayout
    /// Send OpenRayneo's blank caption before a new answer replaces an older one.
    var clearBetweenAnswers = true
    /// Append-safe delivery: no counter or context, a leading separator space on every segment, and one
    /// character of width reserved for it. Used by the Stable Sections strategy.
    var appendSafe = false
    /// Close and reopen the display session before each new answer.
    var restartSessionPerAnswer = false
    /// Full-frame mode (OpenRayneo technique): rows the lens shows. nil = plain captions.
    var frameRows: Int?
    /// Rows the lens shows, used by blank-row clears.
    var viewportRows = 5
    /// Separator prefixed to each appended stable section.
    var separator = " "
    /// Speech-Synced Reading: pages are one-line-apart windows instead of sections. Switching keeps the
    /// reading position (mapped through word indices) and sends at most one update.
    var lineScrolling = false {
        didSet { if lineScrolling != oldValue { switchPageSource() } }
    }
    /// Lab X verified: a new full-frame caption hides the previous one, so a frame already on the lens may
    /// be replaced in place (look-ahead overlap, adding the end marker to a frame that is already showing).
    var inPlaceReplacementVerified = false
    /// End marker of the active answer (set only for a successfully completed answer); rendered after the
    /// final word of the final window. Never part of the answer text or of speech alignment.
    private(set) var endMarker: String?
    /// The final window was already on the lens before completion and replacement is not verified: the
    /// marker is withheld rather than retransmitting (and possibly duplicating) that window.
    private(set) var markerDeferred = false
    private var markerLoggedFor: Int?
    /// A temporary full frame (a code snippet) shown over the answer through the same single writer.
    private(set) var overlay: (id: Int, text: String, persistent: Bool)?
    enum OverlayEnd: Sendable { case disconnected, replaced }
    /// Called when an overlay ends without its owner asking (disconnect, new answer, clear).
    var onOverlayExpired: (Int, OverlayEnd) -> Void = { _, _ in }
    /// Called with the previous answer ID when a different answer becomes active.
    var onAnswerReplaced: (Int) -> Void = { _ in }
    /// The next window, rendered ahead of time so advancing only hands an existing string to the writer.
    private(set) var prepared: (index: Int, revision: Int, text: String)?
    /// Requests that arrived while a write was in flight (merged into the newest state).
    private(set) var coalescedRequests = 0
    /// Time from a scroll request to its window being handed to the display, in milliseconds.
    private(set) var lastScrollLatencyMs: Double?

    private var wasReadyToSend = false
    private var sending = false
    private var requestedAt: Date?
    private var writtenGeneration: Int?
    private var lastWrittenText: String?
    private var needsBlank = false

    init(display: any GlassesDisplay, layout: CaptionLayout = .standard) {
        self.display = display
        self.connectionState = display.connectionState
        self.layout = layout
        attach()
    }

    var currentPage: String? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    func replaceDisplay(_ newDisplay: any GlassesDisplay) {
        display.onStateChange = nil
        display.disconnect()
        display = newDisplay
        connectionState = newDisplay.connectionState
        wasReadyToSend = newDisplay.isReadyToSend
        writtenGeneration = nil
        lastWrittenText = nil
        attach()
    }

    /// Activates a new answer: the only answer on the lens from now on. Reading restarts at word and line 0.
    /// The layout actually used to build windows (append-safe mode reserves room for the separator).
    var effectiveLayout: CaptionLayout {
        guard appendSafe || frameRows != nil else { return layout }
        var adjusted = layout
        adjusted.pageCounter = false
        adjusted.contextLine = false
        if appendSafe { adjusted.charactersPerLine = max(8, layout.charactersPerLine - separator.count) }
        // A frame never has more text rows than the lens shows (5 lines only if 5 rows were calibrated).
        if let frameRows { adjusted.maxLines = min(layout.maxLines, frameRows) }
        return adjusted
    }

    /// Text lines of one window (look-ahead line windows, or a frame/section wrapped at the effective width).
    var windowLines: Int { effectiveLayout.lines }

    /// The first frame of a streaming answer, when it can no longer change as more text arrives:
    /// the complete sentences so far already fill more than one frame. nil if it is not stable yet.
    func stableFirstFrame(of completeSentences: String) -> String? {
        let plan = ReadingPlan(answer: completeSentences, layout: effectiveLayout)
        if lineScrolling {
            // Look-ahead windows: the first full window, once a further line exists (so its last line is closed).
            guard plan.lines.count > windowLines else { return nil }
            return plan.lines.prefix(windowLines).map(\.text).joined(separator: " ")
        }
        guard plan.sections.count >= 2 else { return nil }
        return plan.sections[0].text
    }

    /// Shows a stable first frame of a still-streaming answer. The final answer then continues it via
    /// `present(_:continuingProvisional:)` without rewriting the frame if it is unchanged.
    func presentProvisional(_ firstFrame: String, answerID id: Int) async {
        DiagnosticLog.shared.record(.pipeline, "Answer #\(id): provisional first frame (\(firstFrame.count) chars) from a streaming answer")
        await present(firstFrame, answerID: id)
        provisional = true
    }

    /// With `continuingProvisional`, a final answer that starts with the provisional frame keeps its identity,
    /// position and reading progress, so nothing already shown is rewritten.
    /// `answerID` is the identity issued by the engine; callers without one (tests, tools) get a fresh one.
    /// `endMarker`: only for a successfully completed answer; rendered after its final word.
    func present(_ text: String, answerID id: Int? = nil, continuingProvisional: Bool = false, endMarker marker: String? = nil) async {
        let reserve = marker.map { $0.count + 1 } ?? 0
        if continuingProvisional, provisional, id == answerID, let current = plan, !cleared,
           text.hasPrefix(current.answer), pageIndex == 0 {
            // The window already on the lens must come out identical; the marker's reserved space may not
            // reflow it, so fall back to no reserve (and a deferred marker) if it would.
            for tryReserve in Set([reserve, 0]).sorted(by: >) {
                let fullPlan = ReadingPlan(answer: text, layout: effectiveLayout, trailingReserve: tryReserve)
                let fullPages = lineScrolling ? fullPlan.lineWindows : fullPlan.windows
                guard fullPages.first == pages.first else { continue }
                provisional = false
                continuedAnswer = true
                plan = fullPlan
                pages = fullPages
                // The window already showing is the final one: adding the marker means retransmitting it.
                let finalAlreadyShown = fullPages.count == 1 && lastWrittenText != nil
                markerDeferred = marker != nil && (tryReserve == 0 || (finalAlreadyShown && !inPlaceReplacementVerified))
                endMarker = markerDeferred ? nil : marker
                if markerDeferred { DiagnosticLog.shared.record(.pipeline, "Answer #\(answerID): end marker deferred (final frame already on the lens; in-place replacement not verified)") }
                planRevision += 1
                prepared = nil
                DiagnosticLog.shared.record(.pipeline, "Answer #\(answerID) completed: \(pages.count) frame(s); first frame already showing")
                generation += 1
                await write() // identical first frame: skipped by the writer
                return
            }
        }
        let droppedOverlay = dropOverlay(reason: "new answer", end: .replaced)
        provisional = false
        continuedAnswer = false
        endMarker = marker
        markerDeferred = false
        prepared = nil
        let newPlan = ReadingPlan(answer: text, layout: effectiveLayout, trailingReserve: reserve)
        let newPages = lineScrolling ? newPlan.lineWindows : newPlan.windows
        DiagnosticLog.shared.record(.pipeline, "Presenter invoked: answer \(newPlan.words.count) words → \(newPages.count) window(s) of ≤\(layout.lines) lines × \(layout.width) chars; target \(display.name); \(display.diagnosticSummary)")
        // The identical answer presented again while it is showing: nothing to write.
        if !cleared, !droppedOverlay, newPlan.answer == plan?.answer, newPages == pages, pageIndex == 0, writtenGeneration == generation {
            if let id { answerID = id }
            return
        }
        let previouslyWritten = lastWrittenText != nil && lastWrittenText != viewportClearText
        let previousAnswer = answerID
        answerID = id ?? AnswerIdentity.next()
        if answerID != previousAnswer { onAnswerReplaced(previousAnswer) }
        generation += 1
        cleared = false
        if restartSessionPerAnswer, previouslyWritten {
            // A fresh session starts with an empty transcript; the writer holds until it is usable again.
            needsBlank = false
            writtenGeneration = nil
            lastWrittenText = nil
            DiagnosticLog.shared.record(.pipeline, "New answer #\(answerID): restarting the caption session so no earlier text remains")
            display.restartSession()
        } else {
            // Frames already push everything else out of view.
            needsBlank = clearBetweenAnswers && previouslyWritten && frameRows == nil
        }
        pages = newPages
        plan = newPlan
        planRevision += 1
        pageIndex = 0
        requestedAt = Date()
        await write()
    }

    /// The exact caption payloads this configuration would send for `text`, frame by frame, produced by the
    /// real presenter and writer against a mock display. Nothing is transmitted and no answer ID is issued.
    func previewPayloads(_ text: String, endMarker marker: String? = nil) async -> [String] {
        let mock = MockGlassesDisplay()
        mock.connect()
        let copy = GlassesPresenter(display: mock, layout: layout)
        copy.appendSafe = appendSafe
        copy.frameRows = frameRows
        copy.viewportRows = viewportRows
        copy.separator = separator
        copy.lineScrolling = lineScrolling
        copy.clearBetweenAnswers = clearBetweenAnswers
        copy.inPlaceReplacementVerified = inPlaceReplacementVerified
        await copy.present(text, answerID: 0, endMarker: marker)
        for index in copy.pages.indices.dropFirst() { await copy.showPage(index) }
        return mock.shown
    }

    /// Shows one window of the active answer and waits for the writer (or hands it to the running writer).
    func showPage(_ index: Int) async {
        guard request(index) else { return }
        await write()
    }

    /// Moves to a window immediately (position updates synchronously) and writes it in the background.
    func scheduleShowPage(_ index: Int) {
        guard request(index) else { return }
        Task { await write() }
    }

    /// Removes the active answer from the lens (app side). Reconnects will not bring it back.
    func clearDisplay() async {
        dropOverlay(reason: "display cleared", end: .replaced)
        guard !cleared else { return }
        cleared = true
        generation += 1
        requestedAt = Date()
        DiagnosticLog.shared.record(.pipeline, "Clear display requested (answer #\(answerID))")
        await write()
    }

    private func request(_ index: Int) -> Bool {
        guard pages.indices.contains(index), index != pageIndex || cleared else { return false }
        if writtenGeneration != generation { coalescedRequests += 1 } // the previous request is superseded unwritten
        pageIndex = index
        cleared = false
        generation += 1
        requestedAt = Date()
        return true
    }

    /// The single writer. It always sends the LATEST desired state (answer, window, or clear); anything
    /// requested meanwhile is coalesced, so an older window can never be written after a newer one and
    /// nothing from a previous answer is sent once a new answer is active. Identical text is not re-sent.
    private func write() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        while writtenGeneration != generation {
            let target = generation
            guard display.isReadyToSend else { recordHeld(); return }
            if cleared {
                guard await send(viewportClearText, kind: "clear", target: target) else { return }
            } else if let overlay {
                if overlay.text != lastWrittenText {
                    guard await send(overlay.text, kind: "code", target: target) else { return }
                }
            } else {
                if needsBlank {
                    needsBlank = false
                    guard await send(viewportClearText, kind: "clear before new answer", target: target) else { return }
                    if generation != target { continue }
                }
                guard currentPage != nil else { writtenGeneration = target; break }
                let page = prepared.flatMap { $0.index == pageIndex && $0.revision == planRevision ? $0.text : nil } ?? rendered(pageIndex)
                if page == lastWrittenText, lastWrite?.answerID == answerID {
                    writtenGeneration = target // identical window already on the lens
                    continue
                }
                guard await send(page, kind: "window", target: target) else { return }
            }
            writtenGeneration = target
        }
    }

    private func send(_ text: String, kind: String, target: Int) async -> Bool {
        let started = Date()
        var record = CaptionWrite(answerID: answerID, generation: target, kind: kind, page: pageIndex, pageCount: pages.count,
                                  words: kind == "window" ? pageWords(pageIndex) : nil,
                                  lines: kind == "window" ? pageLines(pageIndex) : nil,
                                  characters: text.count, lineBreaks: text.filter(\.isNewline).count,
                                  final: (display as? RayNeoBluetoothDisplay)?.captionFinalStatus ?? true, result: "", latencyMs: nil)
        do {
            try await display.show(text)
            outgoingCaption = text
            lastWrittenText = text
            lastSendSeconds = Date().timeIntervalSince(started)
            sendCount += 1
            lastError = nil
            if let requestedAt { lastScrollLatencyMs = Date().timeIntervalSince(requestedAt) * 1000 }
            record.result = "handed to \(display.name)"
            record.latencyMs = lastScrollLatencyMs
            let session = display.connectionState == .ready ? "confirmed session" : "unacknowledged session, compatibility mode"
            deliveryStatus = kind == "window"
                ? "Page \(pageIndex + 1)/\(pages.count) written to \(display.name) at \(Date().formatted(date: .omitted, time: .standard)) (\(session)); the glasses do not report visibility"
                : "Lens cleared by the app at \(Date().formatted(date: .omitted, time: .standard)) (\(session)); confirm on the glasses"
            lastWrite = record
            DiagnosticLog.shared.record(.pipeline, "Caption write: \(record.summary)")
            if kind == "window", endMarker != nil, pageIndex == pages.count - 1, markerLoggedFor != answerID {
                markerLoggedFor = answerID
                DiagnosticLog.shared.record(.pipeline, "Answer #\(answerID): end marker attached to the final frame")
            }
            return true
        } catch {
            lastError = error.localizedDescription
            record.result = "failed: \(error.localizedDescription)"
            lastWrite = record
            deliveryStatus = "\(kind) write failed: \(error.localizedDescription)"
            DiagnosticLog.shared.record(.pipeline, "Caption write: \(record.summary)")
            return false
        }
    }

    private func recordHeld() {
        let what = cleared ? "Clear" : "Page \(pageIndex + 1)/\(pages.count)"
        lastError = "Not sent: \(display.connectionState.label)"
        deliveryStatus = "\(what) held, not sent: \(display.sendBlockedReason ?? display.connectionState.label). It is sent automatically when sending becomes possible"
        DiagnosticLog.shared.record(.pipeline, deliveryStatus)
        display.reopenSessionIfClosed()
    }

    /// Rows of blanks that push any earlier caption out of the lens's visible tail (appending transcript).
    /// Every line break is preceded by a space, so if the lens ignored line breaks no words could touch.
    nonisolated static func blankRows(_ rows: Int) -> String {
        frame([], padding: rows)
    }

    /// One caption laid out as a frame: a row break, `padding` blank rows, then one row per line.
    nonisolated static func frame(_ lines: [String], padding: Int) -> String {
        let rows = Array(repeating: blank, count: max(1, padding)) + lines
        return " \n" + rows.joined(separator: " \n")
    }

    var viewportClearText: String { Self.blankRows(frameRows ?? viewportRows) }

    /// Exactly what is sent for a window: plain, separator-prefixed (stable sections), or a full frame.
    /// The end marker goes only after the final word of the final window.
    func rendered(_ index: Int) -> String {
        guard pages.indices.contains(index) else { return "" }
        let marker = index == pages.count - 1 ? endMarker : nil
        if let rows = frameRows {
            var lines: [String]
            if lineScrolling, let plan, plan.lines.indices.contains(index) {
                lines = plan.lines[index..<min(plan.lines.count, index + effectiveLayout.lines)].map(\.text)
                if let marker, !lines.isEmpty { lines[lines.count - 1] += " " + marker } // room reserved in the line map
            } else {
                lines = effectiveLayout.wrap(marker.map { pages[index] + " " + $0 } ?? pages[index]) // reserved in the section fill
            }
            // Pad only as far as needed so the visible tail holds exactly this frame (at least one blank row).
            return Self.frame(lines, padding: max(1, rows - lines.count))
        }
        let text = appendSafe ? separator + pages[index] : pages[index]
        return marker.map { text + " " + $0 } ?? text
    }

    /// Shows `rows` as one full frame over the answer. Returns true once it was handed to the transport.
    func showOverlay(_ rows: [String], id: Int, persistent: Bool = false) async -> Bool {
        guard display.isReadyToSend else { return false }
        let text = Self.frame(rows, padding: max(1, (frameRows ?? viewportRows) - rows.count))
        overlay = (id, text, persistent)
        generation += 1
        requestedAt = Date()
        await write()
        // Another write may have been in flight: wait (bounded) for the writer to reach this frame.
        for _ in 0..<100 where overlay?.id == id && lastWrittenText != text && display.isReadyToSend {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return overlay?.id == id && lastWrittenText == text
    }

    /// Ends overlay `id` (a stale timer cannot end a newer one) and restores the answer's current window.
    func endOverlay(id: Int) async {
        guard overlay?.id == id else { return }
        overlay = nil
        // Plain captions append on this lens: push the code out of view before the answer returns.
        if frameRows == nil { needsBlank = true }
        generation += 1
        requestedAt = Date()
        await write()
    }

    @discardableResult private func dropOverlay(reason: String, end: OverlayEnd) -> Bool {
        guard let overlay else { return false }
        self.overlay = nil
        DiagnosticLog.shared.record(.pipeline, "Code overlay #\(overlay.id) ended: \(reason)")
        onOverlayExpired(overlay.id, end)
        return true
    }

    /// Renders a window ahead of time (content-free log). Advancing then only hands it to the writer.
    func prepare(_ index: Int) {
        guard pages.indices.contains(index), prepared?.index != index || prepared?.revision != planRevision else { return }
        let started = Date()
        prepared = (index, planRevision, rendered(index))
        DiagnosticLog.shared.record(.pipeline, String(format: "Answer #%d: next frame %d/%d prepared in %.1f ms", answerID, index + 1, pages.count,
                                                      Date().timeIntervalSince(started) * 1000))
    }

    func pageWords(_ index: Int) -> Range<Int>? {
        guard let plan else { return nil }
        if lineScrolling {
            guard plan.lines.indices.contains(index) else { return nil }
            let last = min(plan.lines.count, index + plan.layout.lines) - 1
            return plan.lines[index].words.lowerBound..<plan.lines[last].words.upperBound
        }
        return plan.sections.indices.contains(index) ? plan.sections[index].words : nil
    }

    func pageLines(_ index: Int) -> ClosedRange<Int>? {
        guard let plan, lineScrolling, plan.lines.indices.contains(index) else { return nil }
        return index...(min(plan.lines.count, index + plan.layout.lines) - 1)
    }

    /// Rebuilds pages for the current mode, keeping the reader's position via word indices.
    private func switchPageSource() {
        guard let plan else { return }
        let firstWord = lineScrolling
            ? plan.sections.indices.contains(pageIndex) ? plan.sections[pageIndex].words.lowerBound : 0
            : plan.lines.indices.contains(pageIndex) ? plan.lines[pageIndex].words.lowerBound : 0
        pages = lineScrolling ? plan.lineWindows : plan.windows
        let mapped = lineScrolling
            ? min(plan.line(containing: firstWord) ?? 0, max(0, pages.count - 1))
            : plan.section(containing: firstWord) ?? 0
        pageIndex = max(0, mapped)
        guard !cleared else { return }
        generation += 1
        requestedAt = Date()
        Task { await write() }
    }

    /// Something else (a calibration pattern) replaced the caption: the next write must not be skipped.
    func invalidateSentPage() {
        writtenGeneration = nil
        lastWrittenText = nil
    }

    func nextPage() async { await showPage(pageIndex + 1) }
    func previousPage() async { await showPage(pageIndex - 1) }

    private func attach() {
        display.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connectionState = state
            let ready = self.display.isReadyToSend
            defer { self.wasReadyToSend = ready }
            // A new display session starts empty: everything must be written again.
            if !ready { self.writtenGeneration = nil; self.lastWrittenText = nil }
            // A temporary overlay expires logically on disconnect and is never restored on reconnection;
            // a persistent one (the current walkthrough code block) is rewritten when the glasses return.
            if !ready, self.overlay?.persistent != true { self.dropOverlay(reason: "glasses disconnected", end: .disconnected) }
            // Restore only the active answer's current window, never a cleared or older one.
            if ready, !self.wasReadyToSend, !self.cleared, self.currentPage != nil {
                Task { await self.write() }
            }
        }
    }
}
