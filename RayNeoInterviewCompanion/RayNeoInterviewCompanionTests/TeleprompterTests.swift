import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Look-ahead teleprompter and end-of-answer marker. Lens behaviour here is the photographed LensModel
/// (appending transcript, last rows visible) — a simulation, not proof of what the RayNeo iO shows.
@MainActor enum Teleprompter {
    static let check = "\u{2713}"

    static func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

    /// Presenter + reader. `lookahead`: Sentence Frames on a lens verified to replace frames.
    static func make(lookahead: Bool = true, layout: CaptionLayout = .standard, rows: Int = 5,
                     responsiveness: ReadingResponsiveness = .balanced) -> (MockGlassesDisplay, GlassesPresenter, ReadingController) {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: layout)
        presenter.frameRows = rows
        presenter.viewportRows = rows
        presenter.inPlaceReplacementVerified = lookahead
        let reading = ReadingController(presenter: presenter)
        reading.lookaheadWindows = lookahead
        reading.lineScrollingAllowed = lookahead
        reading.responsiveness = responsiveness
        reading.mode = .speechSynced
        return (glasses, presenter, reading)
    }

    /// Speaks `text` word by word as cumulative partials, one utterance per sentence (final at its end).
    /// `paced`: give the writer a moment per word, like a real reader (unpaced = burst, writes coalesce).
    static func speak(_ text: String, into reading: ReadingController, paced: Bool = true, afterWord: (Int) -> Void = { _ in }) async {
        var sentence: [String] = []
        for (index, word) in Canon.words(text).enumerated() {
            sentence.append(word)
            reading.ingest(sentence.joined(separator: " "), isFinal: false, speaker: .unknown)
            afterWord(index + 1)
            if paced { try? await Task.sleep(for: .milliseconds(2)) }
            if ".?!".contains(word.last ?? " ") {
                reading.ingest(sentence.joined(separator: " "), isFinal: true, speaker: .unknown)
                sentence = []
            }
        }
    }

    static func lines(of payload: String) -> [String] { LensModel.visibleText([payload], rowWidth: 60) }
}

@MainActor @Suite(.serialized) struct TeleprompterLayoutTests {
    @Test func shortAnswerIsOneFrameShownImmediatelyWithItsMarker() async {
        let (glasses, presenter, _) = Teleprompter.make()
        await presenter.present("HTTP 401 means the request has not been authenticated.", answerID: 1, endMarker: Teleprompter.check)
        #expect(presenter.pages.count == 1)
        #expect(Teleprompter.lines(of: glasses.shown[0]).joined(separator: " ") == "HTTP 401 means the request has not been authenticated. \(Teleprompter.check)")
        #expect(glasses.shown.count == 1)
    }

    @Test func framesUseFourLinesByDefaultAndFiveOnlyWhenFiveRowsAreCalibrated() {
        let presenter = GlassesPresenter(display: MockGlassesDisplay(), layout: CaptionLayout(maxLines: 5, charactersPerLine: 48))
        presenter.frameRows = 4
        #expect(presenter.windowLines == 4) // 5 lines asked, only 4 rows calibrated
        presenter.frameRows = 5
        #expect(presenter.windowLines == 5)
        #expect(GlassesPresenter(display: MockGlassesDisplay()).windowLines == 4)
    }

    @Test(arguments: [3, 4, 5])
    func everyWindowIsFullAndNoWordIsLost(_ lineCount: Int) async {
        let (glasses, presenter, _) = Teleprompter.make(layout: CaptionLayout(maxLines: lineCount, charactersPerLine: 48), rows: max(5, lineCount))
        await presenter.present(Canon.longAnswer, answerID: 1)
        let plan = presenter.plan!
        #expect(plan.lines.map(\.text).joined(separator: " ") == Canon.longAnswer) // never truncated
        for top in presenter.pages.indices {
            await presenter.showPage(top)
            let shown = Teleprompter.lines(of: glasses.shown.last!)
            #expect(shown.count == lineCount, "window \(top)") // always full, no one-line frames
            #expect(shown.allSatisfy { $0.count <= 48 })
        }
    }

    @Test func lineMapIsContiguousAndRecordsSentencesAndSizes() {
        let plan = ReadingPlan(answer: Canon.longAnswer, layout: .standard)
        var next = 0
        for (index, line) in plan.lines.enumerated() {
            #expect(line.words.lowerBound == next, "line \(index)")
            next = line.words.upperBound
            #expect(line.characters == line.text.count && line.characters <= 48)
            if index > 0 { #expect(line.sentences.lowerBound >= plan.lines[index - 1].sentences.upperBound - 0) }
        }
        #expect(next == plan.words.count)
    }

    @Test func markerSpaceIsReservedSoTheFinalLineNeverOverflows() {
        // One line of exactly 48 characters at width 48: the marker would push it to 50.
        let answer = String(repeating: "abcdefg ", count: 5) + "abcdefg."   // 48 chars
        let layout = CaptionLayout(maxLines: 4, charactersPerLine: 48)
        let plain = ReadingPlan(answer: answer, layout: layout)
        let reserved = ReadingPlan(answer: answer, layout: layout, trailingReserve: 2)
        #expect(plain.lines.last!.characters == 48)
        #expect(reserved.lines.last!.characters + 2 <= 48) // last word moved down, room for " ✓"
        #expect(reserved.words == plain.words)                // same words, same alignment
        #expect(reserved.lines.map(\.text).joined(separator: " ") == answer)
    }

    @Test func finalFrameAtMaximumCapacityStaysWithinRowsWithTheMarker() async {
        for lookahead in [true, false] {
            let (glasses, presenter, _) = Teleprompter.make(lookahead: lookahead)
            await presenter.present(Canon.longAnswer, answerID: 1, endMarker: "[END]")
            await presenter.showPage(presenter.pages.count - 1)
            let shown = Teleprompter.lines(of: glasses.shown.last!)
            #expect(shown.count <= 4)
            #expect(shown.allSatisfy { $0.count <= 48 })
            #expect(shown.last!.hasSuffix(" [END]"))
            #expect(presenter.plan!.words == ReadingPlan(answer: Canon.longAnswer, layout: .standard).words) // never part of speech alignment
        }
    }
}

@MainActor @Suite(.serialized) struct LookAheadScrollingTests {
    @Test func upcomingLinesAppearBeforeTheReaderRunsOutAndSpokenWordsStayVisible() async {
        let (_, presenter, reading) = Teleprompter.make()
        await presenter.present(Canon.longAnswer, answerID: 1)
        let plan = presenter.plan!
        var tops: [Int] = [0]
        await Teleprompter.speak(Canon.longAnswer, into: reading) { _ in
            let top = presenter.pageIndex
            if top != tops.last { tops.append(top) }
            guard let line = reading.readingLine else { return }
            // The line being read is always on screen…
            #expect(line >= top && line <= top + 3, "reading line \(line) outside window \(top)")
            // …and, until the end, at least one further line is visible below it.
            if top < presenter.pages.count - 1 { #expect(top + 3 - line >= 1) }
        }
        #expect(tops == tops.sorted())                  // never backwards
        #expect(tops.count >= 3)                        // jumps, not a slideshow of every line
        #expect(zip(tops, tops.dropFirst()).allSatisfy { $1 - $0 <= 2 }) // balanced: 2 lines ahead, no skipping
        #expect(presenter.pageIndex == presenter.pages.count - 1)
        #expect(reading.readingComplete)
        #expect(plan.lines.count > 4)
    }

    @Test func responsiveMovesEarlierAndConservativeLaterThanBalanced() async {
        func firstJump(_ responsiveness: ReadingResponsiveness) async -> Int? {
            let (_, presenter, reading) = Teleprompter.make(responsiveness: responsiveness)
            await presenter.present(Canon.longAnswer, answerID: 1)
            var at: Int?
            await Teleprompter.speak(Canon.longAnswer, into: reading) { count in if at == nil, presenter.pageIndex > 0 { at = count } }
            return at
        }
        let responsive = await firstJump(.responsive), balanced = await firstJump(.balanced), conservative = await firstJump(.conservative)
        #expect(responsive != nil && balanced != nil && conservative != nil)
        #expect(responsive! < balanced!)
        #expect(balanced! < conservative!)
    }

    @Test func fastReaderJumpsWithoutSkippingTheLineBeingRead() async {
        let (_, presenter, reading) = Teleprompter.make()
        await presenter.present(Canon.longAnswer, answerID: 1)
        let plan = presenter.plan!
        let firstThree = plan.lines[0...2].map(\.text).joined(separator: " ")
        reading.ingest(firstThree, isFinal: false, speaker: .unknown) // three lines in one recognition update
        let line = reading.readingLine!
        #expect(presenter.pageIndex > 0)
        #expect(presenter.pageIndex <= line) // the line being read stays visible
    }

    @Test func pausesRepetitionsRevisionsAndBackgroundSpeechNeverMoveTheWindow() async {
        let (_, presenter, reading) = Teleprompter.make()
        await presenter.present(Canon.longAnswer, answerID: 1)
        let words = Canon.words(Canon.longAnswer)
        reading.ingest(words.prefix(5).joined(separator: " "), isFinal: false, speaker: .unknown)
        let cursor = reading.cursorWord
        for _ in 0..<5 { reading.ingest(words.prefix(5).joined(separator: " "), isFinal: false, speaker: .unknown) } // repetition
        reading.ingest("", isFinal: true, speaker: .unknown)                                                         // pause
        reading.ingest(words.prefix(3).joined(separator: " ") + " tomatoes", isFinal: false, speaker: .unknown)      // revision
        reading.ingest("the weather is lovely today and the parking was easy", isFinal: true, speaker: .unknown)     // background
        #expect(presenter.pageIndex == 0)
        #expect(reading.cursorWord >= cursor) // never backwards
    }

    @Test func rapidUpdatesNeverWriteAnOlderWindowAfterANewerOne() async {
        let (glasses, presenter, reading) = Teleprompter.make()
        await presenter.present(Canon.longAnswer, answerID: 1)
        let index = Dictionary(presenter.pages.indices.map { (presenter.rendered($0), $0) }, uniquingKeysWith: { a, _ in a })
        await Teleprompter.speak(Canon.longAnswer, into: reading, paced: false) // burst: writes coalesce
        await Teleprompter.settle()
        let written = glasses.shown.compactMap { index[$0] }
        #expect(written.count == glasses.shown.count)   // every payload is a canonical window
        #expect(written == written.sorted())            // monotonic
        #expect(Set(written).count == written.count)    // no duplicate payloads
        #expect(written.last == presenter.pages.count - 1)
    }

    @Test func eachVisibleFrameIsExactlyItsWindowUnderTheAppendingLensModel() async {
        let (glasses, presenter, reading) = Teleprompter.make()
        await presenter.present("An older answer about DNS records that must vanish.", answerID: 1)
        await presenter.present(Canon.longAnswer, answerID: 2)
        await Teleprompter.speak(Canon.longAnswer, into: reading)
        await Teleprompter.settle()
        let plan = presenter.plan!
        for count in 2...glasses.shown.count {
            let visible = LensModel.visibleText(Array(glasses.shown.prefix(count)), rowWidth: 60)
            #expect(!visible.joined().contains("DNS"))
            #expect(Canon.startIndex(of: visible.joined(separator: " "), in: Canon.words(Canon.longAnswer)) != nil) // no duplication, no glue
            #expect(visible.count == min(4, plan.lines.count))
        }
    }

    @Test func manualFrameControlsStepOneLookAheadJump() async {
        let (_, presenter, reading) = Teleprompter.make()
        await presenter.present(Canon.longAnswer, answerID: 1)
        reading.nextSection()
        #expect(presenter.pageIndex == 2)
        reading.previousSection()
        #expect(presenter.pageIndex == 0)
        reading.pauseAutoScroll()
        await Teleprompter.speak(Canon.longAnswer, into: reading)
        #expect(presenter.pageIndex == 0)
        reading.resetProgress()
        #expect(presenter.pageIndex == 0 && !reading.readingComplete)
    }

    @Test func withoutVerifiedReplacementFramesNeverOverlap() async {
        let (glasses, presenter, reading) = Teleprompter.make(lookahead: false)
        await presenter.present(Canon.longAnswer, answerID: 1)
        await Teleprompter.speak(Canon.longAnswer, into: reading)
        await Teleprompter.settle()
        let frames = glasses.shown.map { Teleprompter.lines(of: $0).joined(separator: " ") }
        #expect(frames.joined(separator: " ") == Canon.longAnswer) // each word exactly once across frames
        #expect(presenter.pageIndex == presenter.pages.count - 1)
    }

    @Test func nextFrameIsPreparedAheadAndUsedForTheWrite() async {
        let (glasses, presenter, reading) = Teleprompter.make()
        await presenter.present(Canon.longAnswer, answerID: 1)
        reading.ingest("I'd", isFinal: false, speaker: .unknown)
        #expect(presenter.prepared?.index == 2)
        #expect(presenter.prepared?.text == presenter.rendered(2))
        reading.nextSection()
        await Teleprompter.settle()
        #expect(glasses.shown.last == presenter.rendered(2))
    }
}

@MainActor @Suite(.serialized) struct EndMarkerTests {
    func makeEngine(_ ai: MockAIProvider, lookahead: Bool = false, style: EndMarkerStyle = .checkmark)
        -> (MockGlassesDisplay, GlassesPresenter, ReadingController, ConversationEngine) {
        let (glasses, presenter, reading) = Teleprompter.make(lookahead: lookahead)
        var settings = AppSettings()
        settings.semanticClassification = false
        settings.endMarker = style
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        return (glasses, presenter, reading, engine)
    }

    func markers(_ payloads: [String], _ marker: String = Teleprompter.check) -> Int {
        payloads.reduce(0) { $0 + $1.components(separatedBy: marker).count - 1 }
    }

    func ask(_ engine: ConversationEngine, _ question: String = "How would you debug a Meta to Salesforce lead integration?") async {
        await engine.handle(CompletedTurn(text: question, start: 0, end: 2))
        await engine.generationTask?.value
    }

    @Test func completedAppleAnswerGetsOneMarkerOnlyAfterItsFinalWord() async {
        let ai = MockAIProvider()
        ai.answer = Canon.longAnswer
        let (glasses, presenter, reading, engine) = makeEngine(ai)
        await ask(engine)
        #expect(engine.currentAnswer?.generationComplete == true)
        #expect(engine.currentAnswer?.text.contains(Teleprompter.check) == false) // never in the answer text
        #expect(markers(glasses.shown) == 0)                                       // not on intermediate frames
        await Teleprompter.speak(Canon.longAnswer, into: reading)
        await Teleprompter.settle()
        #expect(markers(glasses.shown) == 1)
        #expect(Teleprompter.lines(of: glasses.shown.last!).last!.hasSuffix("next time. \(Teleprompter.check)"))
        #expect(reading.readingComplete)
        // Reading complete: further speech changes nothing, nothing is cleared.
        let shown = glasses.shown
        reading.ingest("so that is how I would do it", isFinal: true, speaker: .unknown)
        await Teleprompter.settle()
        #expect(glasses.shown == shown && presenter.pageIndex == presenter.pages.count - 1)
    }

    @Test func earlyStreamingFrameNeverCarriesTheMarkerAndIsNotRewritten() async {
        let ai = MockAIProvider()
        ai.answer = Canon.longAnswer
        ai.perWordDelay = .milliseconds(3)
        let (glasses, _, _, engine) = makeEngine(ai, lookahead: true)
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        for _ in 0..<300 where glasses.shown.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(engine.state == .generating)
        #expect(markers(glasses.shown) == 0)
        await engine.generationTask?.value
        #expect(Streaming.settled(glasses.shown).count == 1) // the first window only grew; nothing was rewritten
        #expect(markers(glasses.shown) == 0)
        #expect(engine.currentAnswer?.earlyFrameSeconds != nil)
    }

    @Test func truncatedOrMidSentenceAnswersGetNoMarker() async {
        let ai = MockAIProvider()
        ai.answer = "HTTP 401 means the request has not been authenticated."
        ai.stopReason = "MAX_TOKENS"
        let (glasses, _, _, engine) = makeEngine(ai)
        await ask(engine, "What does HTTP 401 mean?")
        #expect(engine.currentAnswer?.completion == "truncated (MAX_TOKENS)")
        #expect(markers(glasses.shown) == 0)

        let ai2 = MockAIProvider()
        ai2.answer = "HTTP 401 means the request has not been authenticated because the"
        let (glasses2, _, _, engine2) = makeEngine(ai2)
        await ask(engine2, "What does HTTP 401 mean?")
        #expect(engine2.currentAnswer?.completion == "ends mid-sentence")
        #expect(markers(glasses2.shown) == 0)
    }

    @Test func validationFailureGetsNoMarkerAndRegenerationStartsCompletionAfresh() async {
        let fake = "In my last role at Contoso I fixed this every week. I would check the logs."
        let ai = MockAIProvider()
        ai.queuedAnswers = [fake, fake]
        let (glasses, _, _, engine) = makeEngine(ai)
        await ask(engine)
        #expect(engine.currentAnswer?.generationComplete == false)
        #expect(markers(glasses.shown) == 0)

        let ai2 = MockAIProvider()
        ai2.queuedAnswers = [fake]
        ai2.answer = "I'd check the API logs to see where the lead request fails, then verify the Salesforce token and field mappings."
        let (glasses2, _, _, engine2) = makeEngine(ai2)
        await ask(engine2)
        #expect(engine2.currentAnswer?.regenerated == true)
        #expect(engine2.currentAnswer?.generationComplete == true)
        #expect(markers(glasses2.shown) == 1)
        #expect(!glasses2.shown.joined().contains("Contoso"))
    }

    @Test func asciiFallbackAndOff() async {
        let ai = MockAIProvider()
        ai.answer = "HTTP 401 means the request has not been authenticated."
        let (glasses, _, _, engine) = makeEngine(ai, style: .ascii)
        await ask(engine, "What does HTTP 401 mean?")
        #expect(markers(glasses.shown, "[END]") == 1)
        let (glassesOff, _, _, engineOff) = makeEngine(MockAIProvider(), style: .off)
        await ask(engineOff, "What does HTTP 401 mean?")
        #expect(markers(glassesOff.shown) == 0 && markers(glassesOff.shown, "[END]") == 0)
    }

    @Test func cancelledGenerationGetsNoMarker() async {
        let ai = MockAIProvider()
        ai.answer = Canon.longAnswer
        ai.perWordDelay = .milliseconds(5)
        let (glasses, _, _, engine) = makeEngine(ai)
        await engine.handle(CompletedTurn(text: "How would you debug a Meta to Salesforce lead integration?", start: 0, end: 2))
        try? await Task.sleep(for: .milliseconds(40))
        engine.cancelGeneration()
        await engine.generationTask?.value
        #expect(markers(glasses.shown) == 0)
        #expect(engine.currentAnswer == nil)
    }

    @Test func reconnectingOnTheFinalFrameRestoresItWithOneMarker() async {
        let ai = MockAIProvider()
        ai.answer = "HTTP 401 means the request has not been authenticated."
        let (glasses, presenter, _, engine) = makeEngine(ai)
        await ask(engine, "What does HTTP 401 mean?")
        let final = glasses.shown.last!
        glasses.simulateDrop()
        glasses.connect()
        await Teleprompter.settle()
        #expect(glasses.shown.last == final)
        #expect(markers([glasses.shown.last!]) == 1)
        #expect(presenter.endMarker == Teleprompter.check)
    }

    @Test func markerIsNotAddedByRetransmittingAFinalFrameAlreadyOnAnAppendingLens() async {
        for verified in [false, true] {
            let (glasses, presenter, _) = Teleprompter.make(lookahead: false)
            presenter.inPlaceReplacementVerified = verified
            let text = "I'd check the API logs first. Then I'd verify the token and the scopes."
            await presenter.presentProvisional(text, answerID: 7)
            await presenter.present(text, answerID: 7, continuingProvisional: true, endMarker: Teleprompter.check)
            await Teleprompter.settle()
            if verified {
                #expect(glasses.shown.count == 2 && markers(glasses.shown) == 1) // replaced in place
            } else {
                #expect(glasses.shown.count == 1 && markers(glasses.shown) == 0) // deferred: shown on the iPhone
                #expect(presenter.markerDeferred)
            }
        }
    }

    @Test func stableSectionsOnAnAppendingLensShowTheMarkerOnceAtTheEnd() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.appendSafe = true
        await presenter.present(Canon.longAnswer, answerID: 1, endMarker: Teleprompter.check)
        for index in presenter.pages.indices.dropFirst() { await presenter.showPage(index) }
        let transcript = glasses.shown.joined()
        #expect(markers(glasses.shown) == 1)
        #expect(Canon.words(transcript) == Canon.words(Canon.longAnswer) + [Teleprompter.check])
    }

    @Test func geminiStreamingCompletionAndMaxTokens() async {
        func run(_ finish: String) async -> (MockGlassesDisplay, ConversationEngine) {
            let gemini = GeminiProvider()
            gemini.consented = true
            gemini.keyProvider = { "k" }
            let stub = StubURLProtocol.Stub()
            gemini.session = stub.session
            let chunks = ["HTTP 401 means the request ", "has not been authenticated."]
            stub.handler = { _ in
                (200, chunks.enumerated().map { index, text in
                    #"data: {"candidates":[{"content":{"parts":[{"text":"\#(text)"}]}\#(index == chunks.count - 1 ? #","finishReason":"\#(finish)""# : "")}]}"# + "\n\n"
                }.joined(), nil)
            }
            let cloud = CloudFailoverProvider(gemini: gemini, fallback: MockAIProvider())
            let (glasses, presenter, _) = Teleprompter.make(lookahead: false)
            var settings = AppSettings()
            settings.semanticClassification = false
            let engine = ConversationEngine(settings: settings, ai: { cloud }, presenter: presenter)
            engine.start()
            await engine.handle(CompletedTurn(text: "What does HTTP 401 mean?", start: 0, end: 1))
            await engine.generationTask?.value
            return (glasses, engine)
        }
        let (ok, okEngine) = await run("STOP")
        #expect(okEngine.currentAnswer?.generationComplete == true)
        #expect(okEngine.currentAnswer?.provider.contains("Gemini") == true)
        #expect(markers(ok.shown) == 1)
        let (cut, cutEngine) = await run("MAX_TOKENS")
        #expect(cutEngine.currentAnswer?.completion == "truncated (MAX_TOKENS)")
        #expect(markers(cut.shown) == 0)
    }

    @Test func networkFailureFallsBackToAppleAndThatAnswerCompletes() async {
        let gemini = GeminiProvider()
        gemini.consented = true
        gemini.keyProvider = { "k" }
        let stub = StubURLProtocol.Stub()
        gemini.session = stub.session
        stub.handler = { _ in (0, "", URLError(.notConnectedToInternet)) }
        let apple = MockAIProvider()
        apple.answer = "HTTP 401 means the request has not been authenticated."
        let cloud = CloudFailoverProvider(gemini: gemini, fallback: apple)
        let (glasses, presenter, _) = Teleprompter.make(lookahead: false)
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { cloud }, presenter: presenter)
        engine.start()
        await engine.handle(CompletedTurn(text: "What does HTTP 401 mean?", start: 0, end: 1))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.text == apple.answer)
        #expect(engine.currentAnswer?.generationComplete == true)
        #expect(markers(glasses.shown) == 1)
    }
}
