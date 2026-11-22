import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Model of the iO-E081 caption area built from the user's photo: every final caption is appended to a
/// transcript with NO separator, "\n" starts a new row (OpenRayneo's navigation frames rely on this; Lab N
/// verifies it), rows wrap at about `rowWidth` characters, and the lens shows only the last `rows` rows.
/// It models the photographed behaviour; it is not proof of how the real lens renders.
enum LensModel {
    static func visibleRows(_ captions: [String], rowWidth: Int = 50, rows: Int = 5) -> [String] {
        let transcript = captions.joined()
        var all: [String] = []
        for paragraph in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let wrapped = CaptionLayout(maxLines: 10_000, charactersPerLine: rowWidth).wrap(String(paragraph))
            all += wrapped.isEmpty ? [""] : wrapped
        }
        return Array(all.suffix(rows))
    }

    static func visibleText(_ captions: [String], rowWidth: Int = 50, rows: Int = 5) -> [String] {
        visibleRows(captions, rowWidth: rowWidth, rows: rows).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

@MainActor @Suite(.serialized) struct LensModelTests {
    /// The model reproduces the photo: earlier calibration patterns still visible, words glued at joins.
    @Test func modelReproducesThePhotographedCalibrationStack() {
        let layout = CaptionLayout(maxLines: 4, charactersPerLine: 26)
        let sent = [CaptionCalibration.replaceFirst, CaptionCalibration.replaceSecond, CaptionCalibration.ruler,
                    CaptionCalibration.numberedLines(layout)]
        let transcript = sent.joined()
        #expect(transcript.contains("appendingREPLACE TEST B")) // the photographed joins
        #expect(transcript.contains("visible0005"))
        #expect(transcript.contains("0080LINE 1"))
        // Rows in the photo hold ~55–60 characters; the tail of 5 rows no longer shows the start of test A.
        let visible = LensModel.visibleRows(sent, rowWidth: 60).joined(separator: " ")
        #expect(!visible.contains("REPLACE TEST A"))
        #expect(visible.contains("LINE 6"))
    }

    @Test func fullFramesShowExactlyOneWindowAtEveryScrollStep() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.frameRows = 5
        presenter.lineScrolling = true
        await presenter.present(Canon.longAnswer)
        let plan = presenter.plan!
        for top in 0..<presenter.pages.count {
            await presenter.showPage(top)
            let expected = plan.lines[top..<min(plan.lines.count, top + 4)].map(\.text)
            #expect(LensModel.visibleText(glasses.shown) == expected, "window \(top)")
        }
    }

    @Test func fullFramesHideTheOldAnswerAndCalibrationLeftovers() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.frameRows = 5
        presenter.lineScrolling = true
        await presenter.present("Old answer about DNS records and TTL values that should vanish completely.")
        await presenter.present("HTTP 401 means the request hasn't been authenticated.")
        let visible = LensModel.visibleText([CaptionCalibration.replaceFirst, CaptionCalibration.ruler] + glasses.shown)
        #expect(visible == presenter.plan!.lines.map(\.text))
        #expect(visible.joined(separator: " ") == "HTTP 401 means the request hasn't been authenticated.")
    }

    @Test func blankRowClearLeavesNothingVisible() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        await presenter.present(Canon.longAnswer)
        await presenter.clearDisplay()
        #expect(LensModel.visibleText(glasses.shown).isEmpty)
    }

    @Test func stableSectionsNeverDuplicateOrGlueWordsOnTheLens() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.appendSafe = true
        await presenter.present(Canon.longAnswer)
        for index in 1..<presenter.pages.count {
            await presenter.showPage(index)
            let visibleWords = Canon.words(LensModel.visibleText(glasses.shown).joined(separator: " "))
            // Whatever is visible is an exact, unduplicated run of the answer's words.
            #expect(Canon.startIndex(of: visibleWords.joined(separator: " "), in: Canon.words(Canon.longAnswer)) != nil
                    || visibleWords.isEmpty, "section \(index)")
        }
    }

    @Test func overlappingFinalWindowsCorruptTheLensUnderTheModel() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: .standard)
        presenter.lineScrolling = true // legacy rolling final windows
        await presenter.present(Canon.longAnswer)
        for index in 1..<5 { await presenter.showPage(index) }
        let visible = LensModel.visibleText(glasses.shown).joined(separator: " ")
        #expect(Canon.startIndex(of: visible, in: Canon.words(Canon.longAnswer)) == nil) // duplicated / glued, as photographed
    }

    @Test func framesStayCorrectWhenCalibratedWidthIsBelowTheRowWidth() {
        // A frame's lines must each fit one lens row; with a calibrated width wider than the row they wrap.
        let plan = ReadingPlan(answer: Canon.longAnswer, layout: CaptionLayout(maxLines: 4, charactersPerLine: 45))
        let frame = GlassesPresenter.blankRows(5) + plan.lines[0..<4].map(\.text).joined(separator: "\n")
        #expect(LensModel.visibleText([frame], rowWidth: 50) == plan.lines[0..<4].map(\.text))
        #expect(LensModel.visibleText([frame], rowWidth: 30).count > 4) // too narrow: rows overflow
    }
}
