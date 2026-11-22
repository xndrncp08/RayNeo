import Foundation
import Testing
@testable import RayNeoInterviewCompanion

enum Canon {
    static let longAnswer = "I'd check the API logs to see where the request is failing. If Meta sends the lead but Salesforce doesn't receive it, I'd look at authentication first, then the field mappings, and then any rate limits. I don't assume it's the integration until I've confirmed the token is valid in Microsoft Entra ID. Next, I'd replay one failed request with the same payload, so I can watch it go through the REST API end to end. If it's a Node.js worker, I'd also check its logs; for a C# or .NET service I'd look at Application Insights. Once it works, I'd confirm a few new leads arrive in Salesforce and add an alert, so we hear about failures sooner next time."

    /// Display words of the canonical answer (the only source of truth for what may appear).
    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// The window must be an exact, contiguous run of canonical words separated only by whitespace.
    static func startIndex(of window: String, in canonical: [String]) -> Int? {
        let shown = words(window)
        guard !shown.isEmpty, shown.count <= canonical.count else { return nil }
        return (0...(canonical.count - shown.count)).first { Array(canonical[$0..<($0 + shown.count)]) == shown }
    }
}

/// A display whose writes take time, to expose ordering and stale-write problems.
@MainActor final class SlowDisplay: GlassesDisplay {
    let name = "Slow display"
    let isSimulated = true
    private(set) var connectionState: GlassesConnectionState = .ready { didSet { onStateChange?(connectionState) } }
    var onStateChange: ((GlassesConnectionState) -> Void)?
    var isReadyToSend: Bool { connectionState == .ready }
    var sendBlockedReason: String? { isReadyToSend ? nil : connectionState.label }
    var diagnosticSummary: String { "slow" }
    private(set) var log: [String] = []
    func connect() { connectionState = .ready }
    func disconnect() { connectionState = .disconnected }
    func reopenSessionIfClosed() {}
    func restartSession() { log.append("<RESTART>") }
    func show(_ text: String) async throws {
        try await Task.sleep(for: .milliseconds(15))
        log.append(text)
    }
    func clear() async throws {
        try await Task.sleep(for: .milliseconds(15))
        log.append("<CLEAR>")
    }
}

@Suite struct CaptionTextIntegrityTests {
    @Test func everyLineWindowIsAnExactRunOfCanonicalWords() {
        let canonical = Canon.words(Canon.longAnswer)
        for width in [18, 22, 26, 32, 40] {
            let plan = ReadingPlan(answer: Canon.longAnswer, layout: CaptionLayout(maxLines: 4, charactersPerLine: width))
            for window in plan.lineWindows + plan.windows.map({ $0.replacingOccurrences(of: #" \(\d+/\d+\)$"#, with: "", options: .regularExpression) }) {
                #expect(Canon.startIndex(of: window, in: canonical) != nil, "width \(width): \(window)")
                #expect(!window.contains("logsto") && !window.contains("  "))
            }
        }
    }

    @Test func wordsAtLineBoundariesKeepTheirSeparator() {
        // Force "logs" to end a visual line and "to" to start the next.
        let answer = "I'd check the API logs to see where the request is failing."
        let plan = ReadingPlan(answer: answer, layout: CaptionLayout(maxLines: 4, charactersPerLine: 22))
        #expect(plan.lines.map(\.text) == ["I'd check the API logs", "to see where the", "request is failing."])
        #expect(plan.lineWindows == [answer])
        let explicit = ReadingPlan(answer: answer, layout: CaptionLayout(maxLines: 4, charactersPerLine: 22, explicitLineBreaks: true))
        #expect(explicit.lineWindows == ["I'd check the API logs\nto see where the\nrequest is failing."])
    }

    @Test func formatterNormalisesUnicodeWhitespaceOnceAndKeepsTerms() {
        let raw = "I'd\u{00A0}check the API\u{200B} logs\tto see\r\nwhere it's failing.\u{2028}Use C#, .NET, Node.js and the REST\u{3000}API — don't guess. Café 数据 ✅"
        let cleaned = AnswerFormatter.spoken(raw)
        #expect(cleaned == "I'd check the API logs to see where it's failing. Use C#, .NET, Node.js and the REST API — don't guess. Café 数据 ✅")
        #expect(AnswerFormatter.spoken(cleaned) == cleaned) // idempotent
        let plan = ReadingPlan(answer: cleaned, layout: .standard)
        #expect(plan.lines.map(\.text).joined(separator: " ") == cleaned)
        #expect(plan.words == ReadingText.tokens(cleaned))
    }

    @Test func punctuationStaysAttachedAcrossLineBoundaries() {
        let plan = ReadingPlan(answer: Canon.longAnswer, layout: CaptionLayout(maxLines: 4, charactersPerLine: 24))
        for line in plan.lines {
            #expect(!line.text.hasPrefix(",") && !line.text.hasPrefix(".") && !line.text.hasPrefix(";"))
            #expect(line.text == line.text.trimmingCharacters(in: .whitespaces))
        }
    }
}

@MainActor @Suite(.serialized) struct CaptionLifecycleTests {
    func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

    @Test func twentyLineAnswerScrollsWithEveryWindowCanonical() async throws {
        let io = FakeLinkIO(), scheduler = ManualScheduler()
        let display = RayNeoBluetoothDisplay(io: io, defaults: UserDefaults(suiteName: UUID().uuidString)!, schedule: { scheduler.schedule($0, $1) })
        display.allowUnconfirmedSend = true
        let presenter = GlassesPresenter(display: display, layout: CaptionLayout(maxLines: 4, charactersPerLine: 26))
        let reading = ReadingController(presenter: presenter)
        reading.mode = .speechSynced
        let classic = Data([1, 2, 3, 4, 5, 6]), bound = Data([7, 7, 7, 7, 7, 7])
        display.connect()
        display.ioFound(name: "RayNeo iO-E081", identifier: UUID(), summary: "test")
        display.ioConnected(mtu: 512)
        display.ioDiscovered(services: ["B81D"], characteristics: ["EA8B70D5", "7DB3E235", "EA8B60C5"], complete: true)
        display.ioPairInfo(classic + Data([2]) + bound)
        display.ioNotify(enabled: true, error: nil)
        display.ioReceived(try RayNeoProtocol.pairingFrame(sequence: 0, command: 17, fields: [(16, Data([1]))]))
        let random = Data([1, 1, 1, 1])
        display.ioReceived(try RayNeoProtocol.pairingFrame(sequence: 1, command: 25, fields: [
            (16, random), (17, RayNeoProtocol.authDigest(random: random, deviceID: bound, classicAddress: classic))]))
        scheduler.fireAll()

        let answer = AnswerFormatter.spoken(Canon.longAnswer)
        await presenter.present(answer)
        let plan = try #require(presenter.plan)
        #expect(plan.lines.count >= 20)
        for sentence in answer.split(separator: ".").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let words = sentence.split(separator: " ")
            for count in 1...words.count {
                reading.ingest(words.prefix(count).joined(separator: " "), isFinal: false, speaker: .unknown)
                try? await Task.sleep(for: .milliseconds(5))
            }
            reading.ingest(sentence, isFinal: true, speaker: .unknown)
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(30))

        let written = io.sent(business: 0x13, type: 5).compactMap { ($0.json?["content"] as? [String: AnyHashable])?["source_transcript"] as? String }
        let canonical = Canon.words(answer)
        #expect(written == plan.lineWindows) // every window, in order, once, from the first word to the last
        var previousStart = -1
        for window in written {
            let start = try #require(Canon.startIndex(of: window, in: canonical), "not canonical: \(window)")
            #expect(start > previousStart) // only moves forward
            previousStart = start
            #expect(!window.contains("logsto"))
        }
        #expect(Canon.words(written.last ?? "").last == canonical.last)
    }

    @Test func newAnswerNeverMixesWithTheOldOneEvenWithDelayedWrites() async throws {
        let slow = SlowDisplay()
        let presenter = GlassesPresenter(display: slow, layout: .standard)
        presenter.lineScrolling = true
        await presenter.present(Canon.longAnswer)
        presenter.scheduleShowPage(1)
        presenter.scheduleShowPage(2)
        presenter.scheduleShowPage(3) // still queued when the new answer arrives
        let next = "HTTP 401 means the request hasn't been authenticated yet."
        await presenter.present(next)
        await settle()
        let lastClear = try #require(slow.log.lastIndex(of: GlassesPresenter.blankRows(5))) // blank rows before the new answer
        #expect(Array(slow.log[(lastClear + 1)...]) == [next]) // nothing from the old answer after the new one starts
        #expect(slow.log.filter { $0 != GlassesPresenter.blankRows(5) }.allSatisfy { Canon.startIndex(of: $0, in: Canon.words(Canon.longAnswer)) != nil || $0 == next })
    }

    @Test func rapidScrollsWriteOnlyTheNewestWindowInOrder() async {
        let slow = SlowDisplay()
        let presenter = GlassesPresenter(display: slow, layout: .standard)
        presenter.lineScrolling = true
        await presenter.present(Canon.longAnswer)
        for index in 1...6 { presenter.scheduleShowPage(index) }
        await settle()
        let pages = presenter.pages
        let tops = slow.log.compactMap { pages.firstIndex(of: $0) }
        #expect(tops == tops.sorted())
        #expect(tops.last == 6)
        #expect(Set(tops).count == tops.count) // no window written twice
        #expect(presenter.coalescedRequests >= 4)
    }

    @Test func clearDisplayIsFinalAndReconnectDoesNotRestoreIt() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        await presenter.present("Short answer.")
        await presenter.clearDisplay()
        #expect(glasses.shown == ["Short answer.", GlassesPresenter.blankRows(5)]) // blank rows push the answer out of view
        #expect(presenter.cleared)
        glasses.simulateDrop()
        glasses.connect()
        await settle()
        #expect(glasses.shown == ["Short answer.", GlassesPresenter.blankRows(5)]) // not restored after a clear
        await presenter.present("Next answer.")
        #expect(glasses.shown == ["Short answer.", GlassesPresenter.blankRows(5), "Next answer."]) // already blank: no second clear
    }

    @Test func reconnectRestoresOnlyTheActiveAnswersCurrentWindow() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.lineScrolling = true
        await presenter.present("Old answer about DNS.")
        await presenter.present(Canon.longAnswer)
        await presenter.showPage(3)
        let current = presenter.currentPage
        glasses.simulateDrop()
        glasses.connect()
        await settle()
        #expect(glasses.shown.last == current)
        #expect(!glasses.shown.suffix(2).contains("Old answer about DNS."))
    }

    @Test func clearBetweenAnswersCanBeTurnedOff() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.clearBetweenAnswers = false
        await presenter.present("First.")
        await presenter.present("Second.")
        #expect(glasses.shown == ["First.", "Second."])
    }

    @Test func shorterCaptionIsSentWholeNotAsADiff() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.clearBetweenAnswers = false
        await presenter.present(Canon.longAnswer)
        await presenter.present("OK.")
        #expect(glasses.shown.last == "OK.")
    }

    @Test func identicalWindowsAreNotResentOnModeRoundTrip() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        await presenter.present("Short answer that fits.")
        presenter.lineScrolling = true
        await settle()
        presenter.lineScrolling = false
        await settle()
        #expect(glasses.shown == ["Short answer that fits."])
    }

    @Test func writeRecordsCarryRangesButNoContent() async {
        DiagnosticLog.shared.clear()
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.lineScrolling = true
        await presenter.present(Canon.longAnswer)
        await presenter.showPage(2)
        let write = presenter.lastWrite
        #expect(write?.kind == "window" && write?.page == 2)
        #expect(write?.lines == 2...5)
        #expect(write?.words?.lowerBound == presenter.plan?.lines[2].words.lowerBound)
        #expect(write?.characters == presenter.currentPage?.count)
        #expect(write?.lineBreaks == 0)
        #expect(presenter.outgoingCaption == presenter.currentPage)
        let exported = DiagnosticLog.shared.text
        #expect(exported.contains("Caption write: answer #\(presenter.answerID)"))
        #expect(!exported.contains("Salesforce") && !exported.contains("Meta"))
    }
}
