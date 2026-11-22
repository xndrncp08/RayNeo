import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Model of the firmware behaviour seen in photos from an iO-E081: every final caption is appended to a
/// transcript with no separator. Used to show which strategy stays readable under that behaviour.
enum AppendingFirmware {
    static func render(_ captions: [String]) -> String { captions.joined() }
}

@Suite struct FillerRemovalTests {
    /// The exact real-device answer.
    @Test func salesforceDefinitionLosesTheResearchSentence() {
        let observed = "Salesforce is a cloud-based CRM platform that allows businesses to manage customer relationships, sales, and marketing activities. I would check the Salesforce documentation to confirm the answer."
        let result = AnswerValidator.removeFiller(observed, category: .factual)
        #expect(result?.text == "Salesforce is a cloud-based CRM platform that allows businesses to manage customer relationships, sales, and marketing activities.")
        #expect(result?.removed == 1)
    }

    @Test(arguments: [
        "I would check the documentation to confirm.",
        "I'd probably look it up.",
        "I would research this further.",
        "I would use a calculator to figure that out.",
        "You can check the official docs for more details.",
    ])
    func factualFillerSentencesAreRemoved(_ filler: String) {
        let answer = "A primary key uniquely identifies each row in a table. " + filler
        #expect(AnswerValidator.removeFiller(answer, category: .factual)?.text == "A primary key uniquely identifies each row in a table.")
    }

    @Test func onlyFillerMeansRegenerate() {
        #expect(AnswerValidator.removeFiller("I'd probably look it up. I would check the documentation to confirm.", category: .factual) == nil)
    }

    @Test func troubleshootingStepsStay() {
        let technical = "I'd check the API logs to see where the request fails. Then I'd check the Salesforce documentation for the field mapping limits. Once it's fixed, I'd replay one record to confirm it works."
        #expect(AnswerValidator.removeFiller(technical, category: .technical)?.text == technical)
        let withMeta = technical + " I'd double-check my answer later."
        #expect(AnswerValidator.removeFiller(withMeta, category: .technical)?.text == technical)
    }

    @Test func qualifiersThatMatterAreKept() {
        let answer = "HTTP 401 usually means the request has no valid credentials, although some APIs also use it for expired tokens."
        #expect(AnswerValidator.removeFiller(answer, category: .factual)?.text == answer)
    }
}

@MainActor @Suite struct SalesforceEngineTests {
    @Test func observedAnswerReachesTheGlassesWithoutFillerAndWithoutRegenerating() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: CaptionLayout(maxLines: 20, charactersPerLine: 40))
        let ai = MockAIProvider()
        ai.answer = "Salesforce is a cloud-based CRM platform that allows businesses to manage customer relationships, sales, and marketing activities. I would check the Salesforce documentation to confirm the answer."
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
        await engine.handle(CompletedTurn(text: "What is salesforce?", start: 0, end: 1))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.category == .factual)
        #expect(ai.requests.count == 1)
        #expect(engine.currentAnswer?.text == "Salesforce is a cloud-based CRM platform that allows businesses to manage customer relationships, sales, and marketing activities.")
        #expect(!(glasses.shown.last ?? "").contains("documentation"))
        #expect(ai.requests[0].instructions.contains("one direct, informative sentence"))
    }

    @Test func troubleshootingQuestionsAreNotTreatedAsFactual() {
        #expect(QuestionRouter.route("What would you do if Salesforce stopped receiving leads?").category == .technical)
        #expect(QuestionRouter.route("What is Salesforce?").category == .factual)
    }
}

@MainActor @Suite(.serialized) struct CaptionStrategyTests {
    func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    /// Under appending firmware, overlapping rolling windows duplicate text and glue words ("testthat").
    @Test func overlappingFinalWindowsReproduceThePhotographedCorruption() {
        let answer = "Postgres RLS attaches a policy to a table so that each query only sees rows that the current user or role is allowed to access. You can enable RLS per table and test policies per role."
        let plan = ReadingPlan(answer: answer, layout: CaptionLayout(maxLines: 4, charactersPerLine: 26))
        let rendered = AppendingFirmware.render(plan.lineWindows)
        #expect(plan.lineWindows.count > 1)
        // Overlapping windows re-send words, so an appending transcript shows them more than once…
        #expect(Canon.words(rendered).count > Canon.words(answer).count)
        // …and window ends are glued to the next window's first word (the photographed "testthat" class).
        #expect(rendered.range(of: #"[a-z.][A-Z]|[a-z]{2}that"#, options: .regularExpression) != nil || rendered.contains("testthat"))
    }

    @Test func stableSectionsStayReadableUnderAppendingFirmware() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: CaptionLayout(maxLines: 4, charactersPerLine: 26))
        presenter.appendSafe = true
        let answer = Canon.longAnswer
        await presenter.present(answer)
        for index in 1..<presenter.pages.count { await presenter.showPage(index) }
        // Appended without any separator by the firmware, the transcript still reads exactly as the answer.
        let rendered = AppendingFirmware.render(glasses.shown)
        #expect(rendered.trimmingCharacters(in: .whitespaces) == answer)
        #expect(glasses.shown.allSatisfy { $0.hasPrefix(" ") && !$0.contains("/") && !$0.contains("\u{2026}") }) // separator, no counter, no context
        // Non-overlapping: every word is transmitted exactly once.
        #expect(Canon.words(glasses.shown.joined(separator: " ")) == Canon.words(answer))
        // Each segment still fits the line budget including its separator.
        #expect(glasses.shown.allSatisfy { CaptionLayout(maxLines: 4, charactersPerLine: 26).wrap($0).count <= 4 })
    }

    @Test func stableSectionsAdvanceOnlyAfterTheSectionIsRead() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.appendSafe = true
        let reading = ReadingController(presenter: presenter)
        reading.lineScrollingAllowed = false
        reading.mode = .speechSynced
        #expect(!presenter.lineScrolling)
        await presenter.present(Canon.longAnswer)
        let plan = presenter.plan!
        let firstSection = plan.sections[0].text.split(separator: " ")
        for count in 1...(firstSection.count / 2) {
            reading.ingest(firstSection.prefix(count).joined(separator: " "), isFinal: false, speaker: .unknown)
        }
        await settle()
        #expect(presenter.pageIndex == 0) // never mid-section
        reading.ingest(firstSection.joined(separator: " "), isFinal: true, speaker: .unknown)
        await settle()
        #expect(presenter.pageIndex == 1)
        #expect(glasses.shown.count == 2)
    }

    @Test func inProgressStrategySendsStatusZeroLineWindows() async throws {
        let io = FakeLinkIO(), scheduler = ManualScheduler()
        let display = RayNeoBluetoothDisplay(io: io, defaults: UserDefaults(suiteName: UUID().uuidString)!, schedule: { scheduler.schedule($0, $1) })
        display.allowUnconfirmedSend = true
        display.captionFinalStatus = CaptionStrategy.rollingInProgress.finalStatus
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
        let presenter = GlassesPresenter(display: display, layout: .standard)
        presenter.lineScrolling = true
        await presenter.present(Canon.longAnswer)
        await presenter.showPage(1)
        let frames = io.sent(business: 0x13, type: 5)
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { ($0.json?["status"] as? Int) == 0 })
        #expect(presenter.lastWrite?.final == false)

        // Replacement Lab sends use the explicit status regardless of strategy, on the same session.
        let sid = try display.sendLabCaption("ALPHA ONE TWO", final: true, logText: false)
        let lab = io.sent(business: 0x13, type: 5).last?.json
        #expect((lab?["status"] as? Int) == 1)
        #expect((lab?["sid"] as? String)?.hasPrefix(sid) == true)
    }

    @Test func freshSessionPerAnswerRestartsAndNeverWritesTheOldAnswerAfterwards() async {
        let slow = SlowDisplay()
        let presenter = GlassesPresenter(display: slow, layout: .standard)
        presenter.restartSessionPerAnswer = true
        await presenter.present("Old answer about DNS records.")
        await presenter.present("New answer about Microsoft Entra ID.")
        await settle()
        let restart = slow.log.firstIndex(of: "<RESTART>")
        #expect(restart != nil)
        #expect(Array(slow.log[(restart! + 1)...]) == ["New answer about Microsoft Entra ID."])
        #expect(!slow.log.contains("<CLEAR>")) // a fresh session needs no blank
    }

    @Test func labExperimentsCoverTheRequestedCases() {
        let byID = Dictionary(uniqueKeysWithValues: LabExperiment.all.map { ($0.id, $0) })
        func statuses(_ id: String) -> [Bool] { byID[id]!.steps.compactMap { if case .caption(_, let final) = $0 { final } else { nil } } }
        #expect(statuses("A") == [true, true])
        #expect(statuses("B") == [false, false])
        #expect(statuses("C") == [true, false])
        #expect(statuses("D") == [false, true])
        #expect(byID["E"]!.steps.contains(.blankRows(final: true)))
        #expect(byID["E2"]!.steps.contains(.openRayneoBlank))
        #expect(byID["F"]!.steps.contains(.restartSession))
        #expect(byID["G"]!.steps.count == 3 && byID["G2"]!.steps.count == 3)
        #expect(byID["N"]!.steps.contains { if case .caption(let text, _) = $0 { text.contains("\n") } else { false } })
        #expect(byID["X"]!.steps.allSatisfy { if case .frame = $0 { true } else { false } })
        #expect(CaptionLabView.visible("a b\u{3000}c\nd") == "a·b□c⏎\nd")
    }

    @Test func strategySettingsDriveThePipeline() {
        #expect(!CaptionStrategy.stableSections.allowsLineScrolling && CaptionStrategy.stableSections.appendSafe)
        #expect(CaptionStrategy.rollingInProgress.allowsLineScrolling && !CaptionStrategy.rollingInProgress.finalStatus)
        #expect(AppSettings().captionStrategy == .sentenceFrames)
        #expect(AppSettings.decodeMerged(Data(#"{"glassesTarget":"rayNeoExperimental"}"#.utf8))?.captionStrategy == .sentenceFrames)
    }
}
