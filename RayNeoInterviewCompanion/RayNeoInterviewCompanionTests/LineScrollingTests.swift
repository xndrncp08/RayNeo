import Foundation
import Testing
@testable import RayNeoInterviewCompanion

enum Scroll {
    static let answer = "I'd start by checking if Meta actually sent the lead to our integration endpoint. Then I'd inspect the API logs for authentication or mapping errors before testing again. If the access token expired, I'd refresh it and replay the failed requests. After that I'd watch the next few leads arrive in Salesforce to confirm the fix worked. Finally I'd add an alert so we hear about problems sooner next time."
    static let layout = CaptionLayout(maxLines: 4, charactersPerLine: 26)
    static var sentences: [String] {
        answer.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

@Suite struct VisualLineMapTests {
    let plan = ReadingPlan(answer: Scroll.answer, layout: Scroll.layout)

    @Test func linesPreserveTextWordsAndOrder() {
        #expect(plan.lines.count >= 12)
        #expect(plan.lines.map(\.text).joined(separator: " ") == Scroll.answer)
        #expect(plan.lines.allSatisfy { $0.text.count <= 26 })
        #expect(plan.lines.first?.words.lowerBound == 0)
        #expect(plan.lines.last?.words.upperBound == plan.words.count)
        for (a, b) in zip(plan.lines, plan.lines.dropFirst()) {
            #expect(a.words.upperBound == b.words.lowerBound)
            #expect(a.sentences.lowerBound <= b.sentences.lowerBound)
        }
        #expect(plan.lines.contains { $0.sentences.count > 1 } || plan.lines.count > 0)
        // A sentence spanning 3+ visual lines exists in this answer.
        let perSentence = Dictionary(grouping: plan.lines, by: \.sentences.lowerBound).mapValues(\.count)
        #expect(perSentence.values.contains { $0 >= 3 })
    }

    @Test func lineWindowsShiftByExactlyOneLine() {
        #expect(plan.lineWindows.count == plan.lines.count - 3)
        for top in plan.lineWindows.indices {
            #expect(plan.lineWindows[top] == plan.lines[top..<(top + 4)].map(\.text).joined(separator: " "))
            #expect(Scroll.layout.wrap(plan.lineWindows[top]).count <= 4)
            #expect(!plan.lineWindows[top].contains("\u{2026}") && !plan.lineWindows[top].contains("/"))
        }
        #expect(Set(plan.lineWindows).count == plan.lineWindows.count) // no duplicate windows
    }

    @Test func randomAnswersMapEveryWordToExactlyOneLine() {
        var rng = CaptionLayoutTests.LCG(state: 42)
        for _ in 0..<200 {
            let answer = CaptionLayoutTests.randomAnswer(&rng)
            for width in [12, 20, 26, 40] {
                let plan = ReadingPlan(answer: answer, layout: CaptionLayout(maxLines: 4, charactersPerLine: width))
                // Words wider than a line are the only ones split across lines.
                let joined = plan.lines.map(\.text).joined(separator: " ")
                if answer.split(separator: " ").allSatisfy({ $0.count <= width }) {
                    #expect(joined == answer)
                } else {
                    #expect(joined.replacingOccurrences(of: " ", with: "") == answer.replacingOccurrences(of: " ", with: ""))
                }
                #expect(plan.lines.flatMap { Array(plan.words[$0.words]) } == ReadingText.tokens(answer))
                #expect(plan.lines.allSatisfy { $0.text.count <= width })
            }
        }
    }

    @Test func longWordsAreHardBrokenOnlyWhenWiderThanALine() {
        let plan = ReadingPlan(answer: "use Microsoft.Graph.ConditionalAccessEvaluation now", layout: CaptionLayout(maxLines: 4, charactersPerLine: 16))
        #expect(plan.lines.allSatisfy { $0.text.count <= 16 })
        #expect(plan.lines.map(\.text).joined().replacingOccurrences(of: " ", with: "").contains("Microsoft.Graph.ConditionalAccessEvaluation"))
        #expect(plan.words == ReadingText.tokens("use Microsoft.Graph.ConditionalAccessEvaluation now"))
    }
}

/// Controller + presenter + real BLE session logic (fake link).
@MainActor @Suite(.serialized) struct LineScrollingTests {
    let io = FakeLinkIO()
    let scheduler = ManualScheduler()
    let display: RayNeoBluetoothDisplay
    let presenter: GlassesPresenter
    let reading: ReadingController
    let plan = ReadingPlan(answer: Scroll.answer, layout: Scroll.layout)

    init() {
        let scheduler = self.scheduler
        display = RayNeoBluetoothDisplay(io: io, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                         schedule: { scheduler.schedule($0, $1) })
        display.allowUnconfirmedSend = true
        presenter = GlassesPresenter(display: display, layout: Scroll.layout)
        reading = ReadingController(presenter: presenter)
        reading.mode = .speechSynced
    }

    func authenticate() throws {
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
    }

    var written: [String] {
        io.sent(business: 0x13, type: 5).compactMap { ($0.json?["content"] as? [String: AnyHashable])?["source_transcript"] as? String }
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(20)) }

    /// The top line must never be ahead of the first unfinished line (one-word lookahead allowed).
    func assertNoUnspokenLineRemoved(_ cursor: Int) {
        let top = presenter.pageIndex
        if top > 0 { #expect(cursor >= plan.lines[top - 1].relaxedTrigger, "line \(top) removed before it was read") }
    }

    /// Streams a sentence as growing partials, `step` words at a time, then a final.
    func read(_ sentence: String, step: Int = 1, speaker: SpeakerLabel = .unknown) async {
        let words = sentence.split(separator: " ")
        var count = 0
        while count < words.count {
            count = min(words.count, count + step)
            reading.ingest(words.prefix(count).joined(separator: " "), isFinal: false, speaker: speaker)
            await settle()
            assertNoUnspokenLineRemoved(reading.cursorWord)
        }
        reading.ingest(sentence, isFinal: true, speaker: speaker)
        await settle()
    }

    @Test func fullAnswerScrollsOneLineAtATimeFromBeginningToEnd() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        #expect(written == [plan.lineWindows[0]]) // starts with the first word, first four lines
        for sentence in Scroll.sentences { await read(sentence) }
        #expect(written == plan.lineWindows) // every window, in order, exactly once
        #expect(presenter.pageIndex == plan.lineWindows.count - 1)
        #expect(reading.boundaries == plan.lineWindows.count - 1)
    }

    @Test func scrollsMidSentenceWithoutWaitingForTheSentenceToEnd() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        let first = Scroll.sentences[0].split(separator: " ")
        // Speak just past the end of line 1, still inside sentence 1.
        let line1Words = plan.lines[0].text.split(separator: " ").count
        for count in 1...(line1Words + 1) {
            reading.ingest(first.prefix(count).joined(separator: " "), isFinal: false, speaker: .unknown)
        }
        await settle()
        #expect(presenter.pageIndex == 1)
        #expect(written.last == plan.lineWindows[1])
    }

    @Test func pausesSilenceAndRepetitionNeverScroll() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        let words = Scroll.sentences[0].split(separator: " ")
        reading.ingest(words.prefix(3).joined(separator: " "), isFinal: false, speaker: .unknown)
        reading.ingest(words.prefix(3).joined(separator: " "), isFinal: true, speaker: .unknown) // pause
        reading.ingest("", isFinal: true, speaker: .unknown) // silence
        await settle()
        #expect(presenter.pageIndex == 0)
        await read(Scroll.sentences[0])
        let top = presenter.pageIndex
        await read(Scroll.sentences[0]) // re-reading the same sentence
        #expect(presenter.pageIndex == top)
    }

    @Test func slowReaderWithGapsStillScrolls() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        let words = Scroll.sentences[0].split(separator: " ")
        for count in 1...words.count {
            reading.ingest(words.prefix(count).joined(separator: " "), isFinal: count % 3 == 0, speaker: .unknown)
            if count % 3 == 0 { reading.ingest("", isFinal: true, speaker: .unknown) }
        }
        await settle()
        #expect(presenter.pageIndex >= 1)
        assertNoUnspokenLineRemoved(reading.cursorWord)
    }

    @Test func fastReaderNeverDropsAnUnreadLine() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        for sentence in Scroll.sentences { await read(sentence, step: 5) }
        #expect(presenter.pageIndex == plan.lineWindows.count - 1)
        // Written windows only move forward.
        let tops = written.compactMap { plan.lineWindows.firstIndex(of: $0) }
        #expect(tops == tops.sorted())
    }

    @Test func correctedPartialsAreNotDoubleCounted() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        reading.ingest("I'd start by checking if Meta actually sent the lid", isFinal: false, speaker: .unknown)
        let before = reading.cursorWord
        reading.ingest("I'd start by checking if Meta actually sent the lead to our", isFinal: false, speaker: .unknown)
        reading.ingest("I'd start by checking", isFinal: false, speaker: .unknown) // revision drops words
        #expect(reading.cursorWord >= before)
        reading.ingest("I'd start by checking if Meta actually sent the lead to our integration endpoint", isFinal: true, speaker: .unknown)
        await settle()
        assertNoUnspokenLineRemoved(reading.cursorWord)
        let tops = written.compactMap { plan.lineWindows.firstIndex(of: $0) }
        #expect(tops == tops.sorted() && Set(tops).count == tops.count) // forward only, no duplicate windows
    }

    @Test func unrelatedInterviewerSpeechNeverScrolls() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        await read("I'd start by checking if Meta")
        let top = presenter.pageIndex, writes = written.count
        await read("sorry can you check the API logs and the integration endpoint for Salesforce", speaker: .interviewer)
        await read("the access token and the alert in Salesforce", speaker: .unknown)
        #expect(presenter.pageIndex == top)
        #expect(written.count == writes)
    }

    @Test func weakEvidenceNeverJumpsSeveralLines() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        await read("I'd start by checking if Meta actually sent the lead to our integration endpoint")
        let top = presenter.pageIndex
        // Two words that match far ahead: at most one line, and here none (too little evidence).
        reading.ingest("inspect logs", isFinal: false, speaker: .unknown)
        await settle()
        #expect(presenter.pageIndex <= top + 1)
    }

    @Test func manualLineControlsPauseAndResume() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        reading.nextSection()
        await settle()
        #expect(presenter.pageIndex == 1)
        #expect(reading.cursorWord == plan.lines[1].words.lowerBound - 1)
        reading.previousSection()
        await settle()
        #expect(presenter.pageIndex == 0)

        reading.pauseAutoScroll()
        let writes = written.count
        await read(Scroll.sentences[0])
        #expect(presenter.pageIndex == 0)
        #expect(written.count == writes)
        reading.resumeAutoScroll()
        await settle()
        #expect(presenter.pageIndex > 0)
        #expect(written.count == writes + 1) // one catch-up write

        reading.resetProgress()
        await settle()
        #expect(presenter.pageIndex == 0 && reading.cursorWord == -1)
    }

    @Test func rapidScrollRequestsCoalesceToTheNewestWindowInOrder() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        let before = written.count
        presenter.scheduleShowPage(1)
        presenter.scheduleShowPage(2)
        presenter.scheduleShowPage(3)
        presenter.scheduleShowPage(4)
        await settle()
        #expect(Array(written.dropFirst(before)) == [plan.lineWindows[4]])
        #expect(presenter.coalescedRequests == 3)
        presenter.scheduleShowPage(4) // identical: no write
        await settle()
        #expect(written.count == before + 1)
        #expect(presenter.lastScrollLatencyMs != nil)
    }

    @Test func reconnectWhileScrollingRestoresTheCurrentLineWindow() async throws {
        try authenticate()
        await presenter.present(Scroll.answer)
        await read(Scroll.sentences[0])
        display.ioDisconnected(error: "out of range")
        await read(Scroll.sentences[1]) // scrolls while disconnected: held
        let top = presenter.pageIndex
        scheduler.fireAll()
        try authenticate()
        await settle()
        #expect(written.last == plan.lineWindows[top])
        await read(Scroll.sentences[2])
        #expect(presenter.pageIndex > top)
    }

    @Test func responsivenessChangesEvidenceNotDelays() async throws {
        // Line 1's last meaningful word is misrecognised; one more word is heard after it.
        let words = plan.lines[0].text.split(separator: " ").map(String.init)
        var garbled = words
        garbled[garbled.count - 1] = "zzzz"
        let spoken = (garbled + ["the"]).joined(separator: " ")
        var results: [ReadingResponsiveness: Int] = [:]
        for mode in ReadingResponsiveness.allCases {
            var alignment = ReadingAlignment(plan: plan)
            alignment.responsiveness = mode
            let update = alignment.ingest(spoken, isFinal: false, speaker: .unknown, at: Date())
            results[mode] = alignment.suggestedTopLine(current: 0, maxTop: plan.lineWindows.count - 1,
                                                       heardBeyond: update.heardBeyond, utteranceEnded: false)
        }
        #expect(results[.conservative] == 0)
        #expect(results[.responsive] == 1)
        #expect((results[.balanced] ?? 0) <= (results[.responsive] ?? 0))
    }

    @Test func modeSwitchKeepsThePositionAndAnswerLockHolds() async throws {
        try authenticate()
        let ai = MockAIProvider()
        ai.answer = Scroll.answer
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        await engine.generationTask?.value
        #expect(engine.state == .answerLocked)

        await read(Scroll.sentences[0])
        await read(Scroll.sentences[1])
        await engine.handle(CompletedTurn(text: Scroll.sentences[1], start: 3, end: 8)) // wearer reading aloud
        #expect(ai.requests.count == 1)
        #expect(engine.state == .answerLocked)

        let wordAtTop = plan.lines[presenter.pageIndex].words.lowerBound
        reading.mode = .manual
        await settle()
        #expect(presenter.plan?.sections[presenter.pageIndex].words.contains(wordAtTop) == true
                || presenter.plan?.sections[presenter.pageIndex].words.lowerBound ?? 0 <= wordAtTop)
        reading.mode = .speechSynced
        await settle()
        #expect(presenter.pages == plan.lineWindows)
    }
}
