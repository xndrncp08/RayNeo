# RayPrompt — Architecture

```
AudioCaptureService ──(converted buffers, audio thread)──┬─> SpeechRecognizing (Analyzer | Legacy)
                                                         └─> SpeakerActivityService (level/pitch ring)
SpeechRecognizing ──SpeechEvent──> AppModel ──> TurnDetector ──CompletedTurn + SpeakerEvidence──> ConversationEngine
ConversationEngine ──> AIResponseProvider (FoundationModels | Disabled)
ConversationEngine ──> GlassesPresenter ──> GlassesDisplay (MockGlassesDisplay | RayNeoBluetoothDisplay)
```

| File | Responsibility |
| --- | --- |
| `App/AppModel.swift` | Coordinator. Owns the session lifecycle, permissions, the 200 ms turn tick, recognizer recovery, diagnostics, calibration and settings persistence. All hardware is injected. |
| `Audio/AudioCaptureService.swift` | AVAudioEngine tap, conversion to the recognizer format, built-in mic preference, interruption, route and media-reset recovery. |
| `Speech/SpeechRecognitionService.swift` | SpeechAnalyzer path, plus an SFSpeechRecognizer fallback that restarts on each final result and every 55 s. |
| `Speech/TurnDetector.swift` | End-of-turn detection: silence after the last transcript change and the last voice activity. Also holds the bounded `TranscriptBuffer`. |
| `Speaker/SpeakerActivity.swift` | Per-buffer RMS and autocorrelation pitch. Wearer calibration profile. Heuristic labels (wearer / interviewer / unknown) that report the measured features, never a probability. |
| `Intelligence/QuestionDetector.swift` | Deterministic question and request scoring, incomplete-utterance rejection, follow-up cues. |
| `Intelligence/TextSimilarity.swift` | Word and bigram containment used for echo suppression and duplicate detection. |
| `Intelligence/AIResponseService.swift` | Provider protocol, Foundation Models implementation (fresh bounded session per question, prewarmed), explicit disabled state. |
| `Intelligence/KnowledgeBase.swift` | Editable topics and verified portfolio (file-protected JSON), plus the prompt builder. |
| `Conversation/ConversationEngine.swift` | Answer-lock state machine. |
| `Glasses/*` | Display protocol, simulator, presenter (pagination, restore after reconnect), RayNeo codec and experimental BLE adapter. |

## State machine

`IDLE → LISTENING → QUESTION_DETECTED → GENERATING → DISPLAYING_ANSWER → ANSWER_LOCKED ⇄ WAITING_FOR_NEXT_QUESTION`, with `ERROR` as a transient state that returns to the previous resting state after 2 s.

Every completed turn passes through these filters, in order:
1. **Echo:** if the turn's overlap with the displayed (or still-streaming) answer reaches `echoThreshold`, it is ignored. A strongly question-shaped turn needs `echoThreshold + 0.25`.
2. **Wearer voice:** ignored if the calibrated speaker heuristic labels the turn as the wearer.
3. **Question score:** below the threshold, the turn is ignored. A turn within 0.25 below the threshold gets an on-device yes/no semantic check.
4. **Duplicate:** ignored if it repeats a question asked in the last 180 s (Jaccard ≥ 0.8).
5. **Lock:** if an answer is locked, or a generation is in flight, the question is **queued** in `pendingQuestion`. It replaces the answer automatically only when all of these hold:
   - auto-advance is on;
   - the score is ≥ `autoAdvanceMinScore` (0.8);
   - the speaker is not the wearer;
   - the answer has been shown for ≥ `minimumLockSeconds` (10 s).

   Otherwise the user taps **Next** or **Answer it now**.

Invariants:
- The glasses only change when a **complete** new answer exists. Nothing is ever cleared on a timer.
- A cancelled or failed generation leaves the previous answer displayed.
- A Bluetooth drop never clears the answer. The presenter re-sends the current page when the connection returns.

## Concurrency

- UI-facing services are `@MainActor`.
- The audio tap runs in a `nonisolated` `AudioTapProcessor`. Its block is created in a nonisolated static function, so it carries no main-actor isolation check.
- The tap hands buffers to the recognizer through a `Mutex`-guarded continuation (or an `NSLock` for the legacy request) and to the speaker store through a `Mutex`.
- The main actor reads features at 5 Hz. Nothing blocks the audio thread.

## Bounds

| Data | Limit |
| --- | --- |
| Transcript | 200 segments / 20 000 characters |
| Engine log | 200 entries |
| Voice features | 120 s |
| Answer cache | 200 entries |
| Prompt notes | 2 × 600 characters |
| Portfolio | 1 500 characters |
| Model context | One fresh session per question |

## Speech-Synced Reading

`ReadingPlan` (`Intelligence/ReadingAlignment.swift`) splits an answer into sections of about 70% of the page size. Each displayed window is `… <tail of previous section> <section>`. `ReadingAlignment` keeps a monotonic word cursor. `ReadingController` (`Conversation/ReadingController.swift`) receives every SpeechAnalyzer partial and final result from `AppModel.handleSpeech` and calls `GlassesPresenter.showPage` only at section transitions.

**Alignment (per transcript update):**
1. Normalise the words: lowercase, no punctuation, contractions expanded the same way on both sides. Word similarity: exact 1, same stem 0.85, near spelling (edit distance 1–2) 0.6–0.7.
2. Re-align only words that are new or changed since the last accepted alignment. Revised partials re-open only the changed suffix.
3. Run a bounded **local sequence alignment** (Smith-Waterman: match = 2·weight·similarity, mismatch −0.6, skipped heard −0.4, skipped expected −0.5 or −0.2). It compares at most 24 heard words against the next 30 expected words. Up to 3 already-confirmed words act as an *anchor*, used only when the speaker is not a likely interviewer and the last progress was within 20 s. Meaningful words weigh 1, function words 0.3. Closer starts are preferred (−0.06 per skipped word); new evidence must start within 10 words of the cursor.
4. Acceptance is tiered by context:

   | Situation | Required matches |
   |---|---|
   | Connected to the anchor | ≥1 new meaningful word |
   | Continuation within 2 words of the cursor | ≥2 words, 1 meaningful |
   | Fresh start, calibrated wearer | 3 words / 2 meaningful |
   | Fresh start, unknown speaker | 4 / 3 |
   | Fresh start, likely interviewer | 6 / 4 |

   In every case, coverage of the matched answer span must be ≥0.45 and density in the heard span ≥0.4.
5. The cursor only moves forward. A section advances when the cursor reaches its last meaningful word. At the end of an utterance it also advances at the second-to-last meaningful word, if more speech was heard after it. Silence alone never advances.

## Line-aware caption windows (replaces character pages)

`CaptionLayout` (`Glasses/CaptionLayout.swift`) models the caption area as `maxLines` lines (default 4) of `charactersPerLine` (default 26), filled by greedy word wrapping. Words are hard-broken only if a single word is wider than a line. `ReadingPlan(answer:layout:)` builds the windows:
1. Split the answer on whitespace into display words. A word larger than a whole window is split into window-sized pieces, and its alignment tokens are counted once.
2. Fill each window with as many words as fit when wrapped, including the "… context" first line if enabled. Context is dropped for a window rather than ever costing it its first word.
3. If the window ends mid-sentence and an earlier sentence end lies in its second half, cut there.
4. Map each window to its exact range of global alignment words. Ranges are contiguous and complete.
5. Append " (k/N)" only if the window still wraps within `maxLines`.

The presenter sends `plan.windows` unchanged, so no suffix is added after layout. Speech-synced reading uses the same plan, so section triggers are the last meaningful words of each visible window.
