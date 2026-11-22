import Foundation
import Testing
@testable import RayNeoInterviewCompanion

/// Synthetic transcript sequences against the speech-synced reading alignment.
/// These prove the algorithm's behaviour on the inputs below, not real-world accuracy.
@Suite struct ReadingAlignmentTests {
    static let answer = "First, I would check the API logs and verify whether the request is reaching the backend. Then I'd compare the payload with the expected schema and look for recent changes. If the token expired, I would refresh the credentials and replay the failed records. Finally, I would monitor the integration to confirm it stays healthy."
    let plan = ReadingPlan(answer: answer, layout: CaptionLayout(maxLines: 4, charactersPerLine: 30))
    let s1 = "First, I would check the API logs and verify whether the request is reaching the backend."

    final class Clock { var now = Date(timeIntervalSince1970: 0) }

    /// Streams `text` as growing partial results (one word at a time), optionally finishing with a final.
    @discardableResult
    func read(_ alignment: inout ReadingAlignment, _ text: String, speaker: SpeakerLabel = .unknown, final: Bool = true,
              clock: Clock = Clock(), onPartial: ((ReadingAlignment) -> Void)? = nil) -> ReadingAlignment.Update? {
        let words = text.split(separator: " ")
        var last: ReadingAlignment.Update?
        for count in 1...words.count {
            clock.now += 0.3
            last = alignment.ingest(words.prefix(count).joined(separator: " "), isFinal: false, speaker: speaker, at: clock.now)
            onPartial?(alignment)
        }
        if final {
            clock.now += 0.8
            last = alignment.ingest(text, isFinal: true, speaker: speaker, at: clock.now)
        }
        return last
    }

    func index(of word: String, in section: Int = 0) -> Int {
        plan.sections[section].words.first { plan.words[$0] == word }!
    }

    func sectionAfter(_ alignment: ReadingAlignment, _ update: ReadingAlignment.Update?, final: Bool) -> Int {
        alignment.suggestedSection(displayed: 0, utteranceEnded: final && (update?.heardBeyondMatch ?? false))
    }

    @Test func planHasOneSentencePerWindowAtThisWidth() {
        #expect(plan.sections.count == 4) // the scenarios below assume this layout
        #expect(plan.sections[0].text == s1)
        #expect(plan.windows.allSatisfy { plan.layout.wrap($0).count <= 4 })
        #expect(plan.words.contains("would") && !plan.words.contains("i'd")) // contractions expanded
    }

    @Test func verbatimReadingAdvancesOnlyAtTheSectionEnd() {
        var alignment = ReadingAlignment(plan: plan)
        var premature = false
        read(&alignment, "First I would check the API logs and verify whether the request is", final: false) {
            if $0.suggestedSection(displayed: 0, utteranceEnded: false) > 0 { premature = true }
        }
        #expect(!premature)
        // Trailing function words ("is") never move the cursor on their own: it rests on "request".
        #expect(alignment.cursor == index(of: "request"))
        let update = read(&alignment, "First I would check the API logs and verify whether the request is reaching the backend")
        #expect(alignment.cursor == index(of: "backend"))
        #expect(sectionAfter(alignment, update, final: true) == 1)
    }

    @Test func pausesNeverAdvanceAndCursorIsMonotonic() {
        var alignment = ReadingAlignment(plan: plan)
        let clock = Clock()
        var update = read(&alignment, "First I would check the API logs", clock: clock)
        #expect(alignment.cursor == index(of: "logs"))
        #expect(sectionAfter(alignment, update, final: true) == 0)
        clock.now += 6 // long pause, then silence-only final
        _ = alignment.ingest("", isFinal: true, speaker: .unknown, at: clock.now)
        #expect(alignment.suggestedSection(displayed: 0, utteranceEnded: true) == 0)
        update = read(&alignment, "and verify whether the request is reaching the backend", clock: clock)
        #expect(alignment.cursor == index(of: "backend"))
        #expect(sectionAfter(alignment, update, final: true) == 1)
    }

    @Test func repeatedAndStutteredWords() {
        var alignment = ReadingAlignment(plan: plan)
        read(&alignment, "First I I would check check the API logs and and verify whether the the request is reaching the backend")
        #expect(alignment.cursor == index(of: "backend"))
    }

    @Test func paraphrasedSentence() {
        var alignment = ReadingAlignment(plan: plan)
        let update = read(&alignment, "so first I'd look at the API logs and check whether requests are reaching the backend")
        #expect(alignment.cursor == index(of: "backend"))
        #expect(sectionAfter(alignment, update, final: true) == 1)
    }

    @Test func skippedWords() {
        var alignment = ReadingAlignment(plan: plan)
        read(&alignment, "First check the API logs verify the request is reaching the backend")
        #expect(alignment.cursor == index(of: "backend"))
    }

    @Test func partiallyRecognizedSpeechUsesTheRelaxedEndRule() {
        var alignment = ReadingAlignment(plan: plan)
        let update = read(&alignment, "First I would check the A P I locks and verify whether the request is reaching the back end")
        #expect(alignment.cursor == index(of: "reaching")) // "backend" was misrecognised
        #expect(alignment.suggestedSection(displayed: 0, utteranceEnded: false) == 0)
        #expect(sectionAfter(alignment, update, final: true) == 1) // final words heard after the last match
    }

    @Test func revisedPartialsAreNotDoubleCounted() {
        var alignment = ReadingAlignment(plan: plan)
        let start = Date(timeIntervalSince1970: 0)
        _ = alignment.ingest("First I would check the API locks", isFinal: false, speaker: .unknown, at: start)
        let afterWrong = alignment.cursor
        _ = alignment.ingest("First I would check the API logs and verify", isFinal: false, speaker: .unknown, at: start + 1)
        #expect(alignment.cursor == index(of: "verify"))
        #expect(alignment.cursor >= afterWrong)
        // A revision that drops already-aligned words never moves the cursor backward.
        _ = alignment.ingest("First I would check", isFinal: false, speaker: .unknown, at: start + 2)
        #expect(alignment.cursor == index(of: "verify"))
        // Re-reading words before the cursor does not re-advance it.
        _ = alignment.ingest("First I would check the API logs", isFinal: true, speaker: .unknown, at: start + 3)
        #expect(alignment.cursor == index(of: "verify"))
    }

    @Test func unrelatedBackgroundConversationFreezesProgress() {
        var alignment = ReadingAlignment(plan: plan)
        let clock = Clock()
        read(&alignment, "First I would check the API logs", clock: clock)
        let cursor = alignment.cursor
        for chatter in ["yeah the weather has been really nice this week",
                        "the backend team handles API keys and logs",
                        "did you see the request from the payload team"] {
            clock.now += 3
            read(&alignment, chatter, clock: clock)
            #expect(alignment.cursor == cursor, "moved on: \(chatter)")
        }
        #expect(alignment.suggestedSection(displayed: 0, utteranceEnded: true) == 0)
    }

    @Test func sharedVocabularyFromAnotherSpeakerCannotStartTracking() {
        var alignment = ReadingAlignment(plan: plan)
        read(&alignment, "the backend team handles API keys and logs", speaker: .unknown)
        #expect(alignment.cursor == -1)
        read(&alignment, "can you check the API logs for the backend", speaker: .interviewer)
        #expect(alignment.cursor == -1)
    }

    @Test func interviewerInterruptionDoesNotMoveTheCursor() {
        var alignment = ReadingAlignment(plan: plan)
        let clock = Clock()
        read(&alignment, "First I would check the API logs", clock: clock)
        let cursor = alignment.cursor
        clock.now += 1
        read(&alignment, "Sorry can you also explain how you would verify the request", speaker: .interviewer, clock: clock)
        #expect(alignment.cursor == cursor)
        clock.now += 1
        read(&alignment, "and verify whether the request is reaching the backend", clock: clock)
        #expect(alignment.cursor == index(of: "backend"))
    }

    @Test func repeatedPhraseInAnswerPrefersTheNearestOccurrence() {
        let plan = ReadingPlan(answer: "Check the logs first. Then restart the service cleanly. Check the logs again to confirm.", layout: CaptionLayout(maxLines: 8, charactersPerLine: 30))
        var alignment = ReadingAlignment(plan: plan)
        read(&alignment, "check the logs first", speaker: .wearer)
        #expect(alignment.cursor == 2) // first occurrence: check(0) the(1) logs(2); "first" is a function word
        read(&alignment, "then restart the service cleanly", speaker: .wearer)
        read(&alignment, "check the logs again", speaker: .wearer)
        #expect(plan.words[alignment.cursor] == "again")
    }

    @Test func lowConfidenceMatchesAreRejected() {
        var alignment = ReadingAlignment(plan: plan)
        for noise in ["the and is the of", "logs", "request backend", "whatever check it"] {
            let update = read(&alignment, noise)
            #expect(update?.accepted == false, "accepted: \(noise)")
        }
        #expect(alignment.cursor == -1)
    }

    @Test func longAnswerAdvancesSectionBySection() {
        var alignment = ReadingAlignment(plan: plan)
        let clock = Clock()
        var displayed = 0
        var transitions: [Int] = []
        let sentences = [
            "First I would check the API logs and verify whether the request is reaching the backend",
            "Then I would compare the payload with the expected schema and look for recent changes",
            "If the token expired I would refresh the credentials and replay the failed records",
            "Finally I would monitor the integration to confirm it stays healthy",
        ]
        for sentence in sentences {
            let update = read(&alignment, sentence, clock: clock) { partial in
                let target = partial.suggestedSection(displayed: displayed, utteranceEnded: false)
                if target > displayed { transitions.append(target); displayed = target }
            }
            let target = alignment.suggestedSection(displayed: displayed, utteranceEnded: update?.heardBeyondMatch ?? false)
            if target > displayed { transitions.append(target); displayed = target }
            clock.now += 1.5
        }
        #expect(transitions == [1, 2, 3])
        #expect(alignment.progress == 1)
    }

    @Test func manualNavigationRepositionsTheCursor() {
        var alignment = ReadingAlignment(plan: plan)
        alignment.moveCursor(toStartOf: 2)
        #expect(alignment.cursor == plan.sections[2].words.lowerBound - 1)
        read(&alignment, "If the token expired I would refresh the credentials and replay the failed records")
        #expect(alignment.suggestedSection(displayed: 2, utteranceEnded: true) == 3)
        alignment.reset()
        #expect(alignment.cursor == -1)
    }
}
