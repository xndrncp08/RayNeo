# RayPrompt — Handoff

## Implemented

These are complete in code:
- Continuous capture with interruption and route recovery.
- SpeechAnalyzer transcription with an SFSpeech fallback.
- Turn detection.
- Deterministic plus semantic question detection.
- Foundation Models answers: streamed, cancellable, cached, with bounded prompts and three answer lengths.
- The answer-lock state machine: echo filter, wearer-voice heuristic, queueing, conservative auto-advance, manual Lock/Unlock/Next.
- Glasses simulator with paging and restore on reconnect.
- Experimental RayNeo iO BLE adapter.
- Editable knowledge base and verified-only portfolio.
- Consent sheet, settings, diagnostics (latencies, memory, thermal state, filter counters).

## Verified (2026-11-19, on this Mac)

- Simulator Debug build and **unsigned arm64 device Release build**: succeeded, with no Swift warnings.
- `xcodebuild analyze`: no issues.
- **41 automated tests, 7 suites, all passing.** They cover required cases 1–18 with mocks, plus the protocol codec (CRC check value, framing, fragmentation, corrupt CRC, TLV/auth round trip), pitch estimation and speaker separation on synthetic tones.
- The app launched in the iOS 27.2 simulator and the dashboard rendered.

## Not verified

- Anything on a physical iPhone:
  - live microphone and recognition quality;
  - Foundation Models latency;
  - background or locked-screen behaviour;
  - battery use over 60–90 minutes.
- **RayNeo iO display:** never tested. The BLE adapter is a port of macOS-verified logic, not proof of iOS compatibility.
- The speaker heuristic on real voices.

## Blockers and next steps

1. Add your Apple ID team in Xcode and install the app (`INSTALLATION.md`). No signing identity existed on this Mac and no iPhone was connected.
2. Run `HARDWARE_TESTING.md` section A and record the measured latencies.
3. Run section B with the glasses. If BLE display fails, the remaining options are an ExternalAccessory/SPP path, which needs the accessory's MFi protocol (`com.rayneo.venus.pub`) and is unverified for sideloaded apps, or staying with the in-app display.
4. Tune the defaults (thresholds, silence, page size) from real sessions.
5. Optional: add a real speaker-embedding model (for example, a Core ML conversion of a small speaker-verification network) behind `SpeakerActivityService`.

## Update 2026-11-20: RayNeo session correctness and display bring-up

**State:** authentication works on real hardware (user logs). Whether text is visible is **not yet verified**.

**Changes**
- `RayNeoBluetoothDisplay` is now split into session logic and a CoreBluetooth I/O layer (`RayNeoLinkIO` / `CoreBluetoothLinkIO`). Tests drive it through a fake link.
- Explicit states: disconnected, scanning, connecting, discovering, authenticating, authenticated, starting session, session unconfirmed, session rejected, ready (confirmed), error. A timeout is now **UNCONFIRMED**, never Ready.
- Stage timeouts: scan 20 s, connect 15 s, discover 10 s, authenticate 10 s, session acknowledgement 8 s.
- Reconnects are bounded at 5, with 2–30 s backoff. Stale timers are ignored (generation tokens). Connect is idempotent.
- A rejected session keeps the link. A session closed by the glasses is not restarted automatically.
- Starting a new session closes the previous one. Disconnect sends the close frame and waits 0.4 s before cancelling the link.
- Scanning no longer filters on B81D. It matches name, service, or manufacturer prefix `16 57`, as OpenRayneo does.
- New `0x13` caption mode (default) alongside `0x17` prompt mode, and the app-visibility foreground frame after authentication.
- `GlassesPresenter` sends only when `isReadyToSend`, skips identical rewrites, and restores the answer when sending becomes possible again.
- Settings: session type, and an experimental toggle to allow sending on an unconfirmed session (off by default). Saved settings now decode over defaults, so new fields never reset old choices.
- New RayNeo Diagnostics screen: state, device, identifier, services, characteristics, auth, session and acknowledgement, last sent/received/error, reconnects, Connect/Disconnect/Start session, a HELLO test with a visual-confirmation prompt, and Export/Clear.

**Tests:** 65 pass, including 16 new link tests. Builds for a physical iPhone (Debug and Release) succeed.

**Next:** run `HARDWARE_TESTING.md` section B and share the exported diagnostics.

## Update 2026-11-20 (b): caption display verified; AI forwarding

**Verified by the user:** "HELLO FROM IPHONE" appeared on an iO-E081 via the `0x13` caption session (the acknowledgement times out).
**Not yet verified:** AI answers on the glasses, reading-driven paging, and follow-up handling on real hardware (`HARDWARE_TESTING.md` section C).

**Changes:**
- Caption compatibility mode (`allowUnconfirmedGlassesSend`): applies to caption sessions only, and re-evaluates sending immediately when toggled.
- The glasses session is reopened once when new text arrives after the glasses closed it. There is no timer-driven restart.
- Reading-driven paging: the next page is shown only after the page's final words were spoken. Uses the existing echo detection.
- Pipeline events (question detected, answer displayed, caption sent / held / failed) are in the shared diagnostic timeline. Speech-bearing pipeline entries are private in the system log.
- `deliveryStatus` is shown on the dashboard and in the diagnostics screen.

**Unchanged:** the BLE handshake, the caption packets, the answer lock, speech recognition and AI generation.

**Tests:** 72 pass, including 7 new pipeline tests. iPhone Debug and Release builds and static analysis are clean.

## Update 2026-11-20 (c): automatic AI answers not reaching the glasses

**Symptom (user):** "HELLO FROM IPHONE" shows on the lens; AI answers show on the iPhone but not on the glasses.

**Code-level divergences found.** The device log has not been seen, so it's not proven which one fired.
1. **Readiness gate.**
   - HELLO uses a per-call override (`sendTestCaption(allowUnconfirmed: true)`).
   - AI answers go through `isReadyToSend`, which needs the separate *Caption compatibility mode* setting. It is off by default, so answers were "held".
   - Now: a dashboard banner explains this and offers an explicit "Enable" button. The held status names the reason.
2. **Protocol defect (fixed).** Every caption `type 3` was treated as "closed". In OpenRayneo, `reason_code` 8/12 means paused and 9/13 means resumed (17 = weak network; only 1–7/10/11/14 close).
   - Effect: a pause dropped our session ID, and the resume was then ignored.
   - The next answer opened a *new* session that the glasses never opened (they refuse a new one while the old is open) and wrote text to it.
   - Now: paused sessions are kept, text is held, and the same session ID is used on resume. Unknown or missing reasons are ignored.

**Diagnostics:** presenter invoked (pages, target, state, session ID, ack, compatibility mode), sending / held (with reason) / sent / failed, BLE write dropped / handed to iOS / queued, answer generated, answer lock activated. Conversation text is reduced to a character count in the exportable timeline.

**Tests:** 78 pass, including 6 new ones (pause/resume regression, non-closing control codes, confirmed resume, held reason, HELLO-vs-answer frame equality, no text in the export).

## Update 2026-11-20 (d): Speech-Synced Reading

**Verified by the user before this change:** AI answers appear automatically on the iO through the caption session.

**Added:** `ReadingPlan`, `ReadingAlignment` (anchored local sequence alignment), `ReadingController`, and the dashboard Reading controls: Manual / Speech-Synced, progress, confidence, decision reason, Pause/Resume Auto-Scroll, Previous/Next Section, Reset. A Settings picker selects the mode; **Manual is the default**. Answers now render as overlapping windows with context. Display writes happen only at section changes.

**Removed:** the earlier completed-turn page advance (`advanceIfRead`, `onWearerReading`, `advancePagesWhileReading`).

**Tests:** 98 pass, including 21 new reading tests on synthetic transcripts. iPhone Debug and Release builds and static analysis are clean.

**Not verified:** real-world alignment accuracy, latency, and behaviour with real SpeechAnalyzer partials. Run `HARDWARE_TESTING.md` section D.

## Update 2026-11-20 (e): line-aware captions, calibration, conversational answers

**Cause of clipped and missing beginnings (from code, lens behaviour unverified):**
- Windows were sized by characters: 160 per window, including up to ~45 characters of previous-section context placed at the top.
- A " (k/N)" counter was appended after sizing.
- Word wrap was never modelled, while the caption config told the glasses 5 lines.
- Typical windows needed 6–7 rendered lines. Losing the *beginning* (not the end) suggests the lens keeps the last lines of over-long captions; calibration pattern 1 verifies this.
- Not the cause: a skipped first window or a bad initial cursor (the presenter starts at window 0, and new answers reset the cursor).

**Changes:**
- New `CaptionLayout`, `CaptionCalibration` and `CaptionCalibrationView`.
- `ReadingPlan` is rewritten around line-aware windows; `GlassesPresenter.paginate` and the character page size are removed.
- Experimental caption `font_size` and `status` options. Defaults are unchanged and verified: font_size 2, final.
- New persona prompt with a style example and plain-text rules. `AnswerFormatter` strips Markdown from answers. Standard length is now 3–5 sentences.

**Tests:** 112 pass, including property tests over about 1,800 random layouts (no loss, no reordering, no overflow, starts at the first word), window-boundary reading, prompt and formatter tests. iPhone Debug and Release builds and static analysis are clean.

**Not verified:** actual lens line count and width, top-vs-bottom clipping, whether captions append or replace, experimental font sizes, and the real model's tone.

## Update 2026-11-20 (f): answer engine, Gemma status, line-by-line scrolling

**Arithmetic failure, root cause:**
- There was no routing.
- One system prompt asked for first-person explanations of *approach* ("explaining their approach", "I'd probably", "what you'd check first… how you'd confirm it worked"), with a troubleshooting style example and an interview framing on every input.
- Arithmetic was left to a ~3B on-device model, and there was no answer validation.

**Added:**
- `Calculator`: a Decimal recursive-descent parser handling spoken operators, number words, %, powers, square roots, averages, division by zero and overflow.
- `QuestionRouter`: math / factual / technical / coding / ambiguous.
- Per-category prompts, `AnswerValidator`, and `AnswerPipeline` (one bounded regeneration, then an honest fallback).
- Providers: Auto / Apple / Gemma (unavailable, see `GEMMA.md`) / Off.
- A 52-question on-device evaluation.

**Line scrolling:**
- `ReadingPlan.lines` / `lineWindows` (one global wrap; each line carries its word range and sentence range).
- `ReadingAlignment.suggestedTopLine` with a bounded one-word lookahead and responsiveness tiers.
- Presenter: an ordered, coalescing writer with latency measurement. Speech-Synced uses line windows; Manual keeps sections.

**Tests:** 144 pass. iPhone Debug and Release builds and static analysis are clean. No real-device benchmarks or scrolling feel have been measured.

## Update 2026-11-20 (g): word boundaries, clean layout, single active answer

**Joined words, finding:** no app-side code joins words. Every display join uses " " (or "\n" when opted in), windows are rebuilt from the immutable line map, and the JSON/BLE path doesn't alter strings. Tests verify every transmitted window is an exact run of canonical words.
- OpenRayneo (hardware-verified) says "Final replaces retained text" and clears with a full-width blank in both fields.
- The cause is therefore not established. It is either lens rendering (wrapping or concatenation) or residue on the translation line. Calibration tests 5–8 and the opt-in outgoing-caption view separate app text from lens rendering.

**Fixed structural weaknesses:** `present()` and the reconnect restore used to bypass the writer.

**Now:**
- A single state-based writer: answer ID plus generation, newest-state-only, identical windows skipped, a content-free `CaptionWrite` record per write.
- `clearDisplay()` using OpenRayneo's blank caption, and clear-between-answers (default on).
- No restore after a clear.
- `AnswerFormatter` normalises Unicode whitespace and zero-width characters.
- Optional explicit line breaks.
- Dashboard **Clear Display** and **Next Answer** buttons.

**Tests:** 157 pass. iPhone Debug and Release builds and static analysis are clean.

## Update 2026-11-20 (h): appended captions and factual filler

**Root cause (from the user's photos, inferred):** the iO-E081 treats each FINAL 0x13 caption as a transcript entry, appended without a separator.
- Overlapping rolling windows therefore showed duplicated sentences.
- Window ends were glued to the next window's first word: "test"+"that" = the last word of window k plus the first word of window k+1.

Outgoing strings were already proven correct by tests, and BLE writes are serialised. No documented caption-record ID exists besides `sid`.

**Changes:**
- `CaptionStrategy`:
  - Stable sections (default: non-overlapping, leading separator space, no counter or context, section advance on confirmed reading);
  - Rolling in-progress (status 0, needs Lab confirmation);
  - Rolling final (legacy).
- Optional fresh session per answer, and a configurable caption start wait.
- `sendLabCaption` and the 12-case Caption Replacement Lab, with a recommendation.

**Filler:**
- `AnswerValidator.removeFiller` (category-aware; troubleshooting steps kept).
- The pipeline trims filler before validation.
- The factual prompt now asks for one direct sentence with no research or verification statements.

**Tests:** 171 pass. iPhone Debug and Release builds and static analysis are clean.

## Update 2026-11-20 (i): appending caption transcript confirmed by photo

**Photo evidence:**
- REPLACE TEST A and B, the width ruler and LINE 1–6 are all visible at once, glued at the joins ("appendingREPLACE", "visible0005", "0080LINE 1").
- The first row starts mid-sentence.
- Conclusion: FINAL 0x13 captions are appended to a transcript with no separator, and the lens shows the last ~5 rows. Rows hold about 55–60 Latin characters at font_size 2.

**OpenRayneo comparison:**
- Our packet is identical to OpenRayneo's caption text packet.
- No record ID or replacement field is documented besides `sid`.
- OpenRayneo's multi-frame features (navigation, character video) send FINAL full-screen frames (rows joined with "\n", "　" padding), which is consistent with an appending transcript whose visible tail is the newest frame.
- OpenRayneo never relies on in-progress captions to replace text.

**Changes:**
- `CaptionStrategy.fullFrames`: row break, 5 blank rows, then the window lines joined with "\n".
- All clears now use blank rows (`GlassesPresenter.blankRows`), which push old text out of view; the OpenRayneo single blank only appends one cell.
- The step-by-step lab A–X starts from a fresh session, shows the exact text, and records an observation per step.
- Calibration patterns now reset the session first.
- `LensModel` tests reproduce the photo and check each strategy.

**Verified on hardware:** final captions append (photo).

**Not verified:**
- in-progress replacement (B, G2);
- whether "\n" starts a row (N);
- whether full frames are clean (X);
- whether blank rows or a session restart clear the lens (E, F).

## Update 2026-11-20 (j): Sentence Frames, early first frame, Gemini Flash

**Sentence Frames (new default display style)**
- Non-overlapping 3–4 line frames, each sent as one full-frame caption: blank padding rows, then the frame's rows.
- Every row break is `" \n"`, so words cannot touch even if the lens ignored line breaks.
- Frames end at a sentence boundary that keeps them at least 60% full, otherwise at a clause boundary (",;:—").
- Advance on reading progress: the frame's last meaningful word, or the second-to-last when the remaining words were already heard. Partial results count; silence never advances.
- Migration (settings v2): only untouched old defaults move (Stable Sections → Sentence Frames; 4×26 → 4×48).
- Styles offered: Sentence Frames / Stable Sections / Full-Frame Scrolling / Experimental In-Progress Rolling.

**Early first frame (technical/coding answers only)**
- Once the streamed complete sentences already fill more than one frame, frame 1 is final and is shown.
- The completed answer continues it without a rewrite and keeps reading progress.
- On failure or cancel, the previous answer is restored.
- No partial words or fake text. The state label shows "Thinking…".

**Gemini Flash**
- Opt-in cloud provider (`GeminiProvider.swift`, see GEMINI.md): Keychain key, free-tier model picker, Apple fallback before the first text, portfolio withheld by default.
- The evaluation compares providers.

**Tests:** 196 in 31 suites pass. Debug/Release device builds and static analysis are clean.

**Not verified:**
- Sentence Frames on the lens: depends on Lab X/N.
- Early-frame timing on the device.
- Any real Gemini call or latency (only stubbed transport was tested).
- Free-tier RPM/RPD values.

## Update 2026-11-20 (k): verification pass

**Endpoint:** the code always used `/v1beta/models/{model}:streamGenerateContent?alt=sse`. The `moeContent` in the earlier report was display truncation. The route is now one constant (`GeminiProvider.streamURL`), pinned by a test.

**Test Gemini Connection** (`GeminiProvider.testConnection`):
- Runs `models.get`, which must list `generateContent`, then one minimal streamed request.
- Reports outcome, HTTP status, model check, first token, total time, finish reason and response. The key is redacted.

**Error mapping fixes:**
- 400 with `API_KEY_INVALID` is now an invalid key; before, it was reported as a bad request and skipped the Apple fallback.
- 400 "is not supported for" is now an unsupported model.
- `MAX_TOKENS` with no text is explained.

**Frame preview:** Calibration › Sentence frame preview runs the real presenter and writer against a mock display. It shows the exact payloads; a test proves they are byte-identical to what is sent.

**Answer identity:**
- `AnswerIdentity.next()` issues one ID per accepted question. The same ID is carried by the pipeline output, the lock (`InterviewAnswer.answerID`), the presenter (every caption write) and `ReadingController.answerID`.
- Continuing an early frame now requires the same ID.
- Partials from a superseded generation can't trigger an early frame.

**Early frame:** the early text must now pass the same validation as a final answer. If regeneration still produces a different answer, the frame is replaced and counted under "Early frames replaced by validation".

**Tests:** 209 in 33 suites pass (two runs). Debug/Release builds and static analysis are clean.

## Update 2026-11-20 (l): look-ahead teleprompter, end-of-answer marker

**Look-ahead windows** (`ReadingAlignment.lookaheadTop`)
- Overlapping 3–5 line windows. When fewer than *N* unread lines remain below the line being read, the window jumps so that line becomes the top line:
  - Conservative: N = 1.
  - Balanced (default): N = 2.
  - Responsive: N = 2, also counting the last two words of a line.
- Words being spoken never leave the screen; the window never moves backwards and never moves on unmatched speech.
- Enabled only for Sentence Frames with `framesReplaceVerified`, which Lab X sets. Otherwise frames stay non-overlapping (the readable fallback).
- Frames are clamped to the calibrated lens rows. The next window is rendered ahead (`GlassesPresenter.prepare`).
- Manual Next/Previous move one jump.

**End-of-answer marker** (✓ / [END] / Off)
- Rendered after the final word of the final window only. It is never in the answer text or the alignment; space is reserved via `ReadingPlan(trailingReserve:)`.
- Shown only when generation is "complete": normal stop, not MAX_TOKENS, text ends a sentence, and validation passed.
- If the final window was already on the lens before completion and replacement is not verified, the marker is deferred and shown on the iPhone instead.
- **Reading complete** is tracked separately: auto-scroll stops and the final frame stays.

**Test infrastructure:** `StubURLProtocol` used one shared static handler, which raced across parallel suites and crashed the test runner. Each test now owns a stub.

**Tests:** 235 in 36 suites pass (two runs). Debug/Release builds and static analysis are clean.

## Update 2026-11-20 (m): personal memory, code snippets, continuous conversation

**Personal memory** (`Intelligence/PersonalMemory.swift`)
- Profile, project and project-document entries, seeded only from the user's own description. Stored as JSON in Application Support with complete file protection. Editable, exportable and deletable in Settings › Personal AI Memory.
- Retrieval scores project names (tolerant: "kinda moving", "BMR"), concepts and exact words, keeps the top 3 within a 900-character budget, and requires a strong match for non-personal questions, so no project example is forced into an answer.
- Retrieval accuracy on the 15-case personal-question set: **15/15 top-3** (after fixes; it was 13/15 before adding the education concept and weighting exact words).
- Grounding: a first-person sentence that names a project plus a technology missing from that project's memory fails validation and the answer is regenerated.

**Repository import** (`RepositoryImporter.swift`)
- Reads only docs, manifests, schemas, SQL, OpenAPI, API routes, deploy and test config.
- Never reads `.env*`, keys, certificates or credential-named files; skips `node_modules`, `.git` and build folders.
- Redacts API keys, tokens, JWTs, connection strings and password/secret assignments.
- Each fact cites its files; markdown sections become searchable `projectDoc` entries. Fully local.

**Conversation memory** (`ConversationMemory.swift`)
- Session-scoped and in memory only: last 6 exchanges, a rolling summary of older ones, topic, active project and unresolved questions, with a budgeted prompt context.
- With retention off, only the latest exchange is kept. Cleared at session start.

**Prompts**
- Notes = knowledge-base topics + retrieved memory + conversation context.
- With Gemini, memory and conversation context are sent only when "Share memory & conversation context" is on (default off).
- Follow-ups are told not to repeat the previous answer.

**Code snippets** (`CodeSnippet.swift`)
- Coding questions that ask for code get a "CODE:" section, parsed out of the spoken answer (also fenced blocks). The iPhone shows it whole, with Copy Code; code is never run.
- Lens rows: indentation compressed to 2 spaces per level; long lines broken with "» " and no characters lost. Multi-frame snippets get a "[code n/N]" row; past 4 frames, "rest on iPhone".
- `CodeSnippetController`: 20 s (configurable) per frame, starting when the frame is handed to Bluetooth. Timers are guarded by snippet ID. A new answer, a clear or a disconnect ends the snippet; a disconnect expires it, so reconnect restores the answer, never the code.
- The presenter has a single-writer overlay; for plain captions it blanks before the answer returns.

**Continuous conversation** (opt-in; `SpeechEventClassifier.swift`)
- Each turn is classified: new question, follow-up, clarification, correction, instruction, reading the answer, your own response, general, or uncertain.
- Tiers:
  - High (≥ 0.8): generate and transition automatically.
  - Medium (≥ 0.55): prepare without displaying; shown on tap, when reading completes, or when the question is repeated.
  - Low: ignored.
- Unknown-speaker turns without strong question form are capped below high.
- One-tap undo restores the previous answer under its own ID. The newest confident question cancels older generations.
- `ConversationPhase` is a pure reducer (idle → … → completed / codeDisplay / error), recorded in diagnostics.
- With the setting off, the classic answer lock behaves exactly as before.

**Also**
- QuestionDetector now treats coding instructions ("write a…", "implement…") as requests.
- The consent sheet has Practice/Live; Live requires the consent toggle; cloud text is accurate for Gemini.
- Mute control; microphone and "Sending to Google" indicators.

**Tests:** 269 in 43 suites pass (three runs). Debug/Release builds and static analysis are clean.

**Not verified on hardware:**
- Follow-up detection with real voices.
- Speaker attribution.
- Code readability on the lens and indentation rendering.
- Actual snippet visibility time.
- The repository picker with a real repo.

## Update 2026-11-20 (n): transcript assembly, project names, coding context

**Root causes of the device failures**
- **(A) Coding refusal:** "show me the code for that" was routed as a generic technical question whose prompt warns about inventing experience. No coding-task context existed, and the validator neither caught refusals nor required code.
- **(B) Fragmented questions:** turns were cut on 1.2 s of silence alone, so "Can you talk about?" became its own question. Duplicates were compared on raw words.
- **(C) Project names:** nothing mapped misrecognised names to project names.

**Fixes**
- `TranscriptTurnAssembler`:
  - Turns keep audio-range segment IDs; a correction of the same audio replaces its segment.
  - Unfinished endings wait an extra grace, and a fragment just after an unfinished turn becomes a revision of it.
  - Turn IDs are stable.
- **Engine:** each turn ID maps to one generation. A revision that leaves the request unchanged is ignored; one that changes it cancels and regenerates. Duplicates are compared on request keys (content words minus request verbs, plus the active project).
- `ProjectVocabularyNormalizer`:
  - Exact names and editable aliases always match. Phonetic and edit-distance matches need project context; dictionary words are guarded.
  - The original text is kept.
  - The vocabulary goes to the SpeechAnalyzer `AnalysisContext.contextualStrings` and the SFSpeechRecognizer `contextualStrings`.
- `ActiveCodingTask` and `CodingTaskTracker` carry the task across turns. Prompts state that writing code is never a past-work claim; refusals and missing code are rejected.

## Update 2026-11-20 (o): interleaved Explanation → Code walkthroughs

**Root cause found during this work:** "Write a JavaScript function…" was not routed as coding: the literal cue "write a function" is broken by the word "JavaScript". The router now also accepts `CodingLanguage.isNewTask`. This was the initial question of device scenario A.

**Walkthrough** (see CODE_TUTOR.md)
- `CodingWalkthrough` holds one ordered timeline of `WalkthroughBlock`s with stable IDs, produced by **one** model request.
- The language is pinned to the requested or inherited language. Validation covers language, wrapper runtimes, a complete final solution, and coherent intermediate stages; one regeneration is allowed.
- The engine presents only the first explanation, and `CodeSnippetController` drives the shared timeline:
  - Explanations go through the teleprompter and reading alignment.
  - Code goes through a persistent overlay, restored on reconnect.
  - Navigation: Next/Previous, an exact spoken command, or an optional timer.
- The 20-second preview keeps its own lifecycle, and is never restored after a disconnect.
- The end marker is shown only on the final explanation. Early frames are off for coding answers.
- iPhone: walkthrough blocks with the active one highlighted, the final solution, Explain a line, tests, edge cases and complexity.

**Tests:** 320 in 55 suites; three consecutive full runs passed. Debug/Release clean builds have no warnings; static analysis is clean.

**This folder is not a git repository**, so there is no VCS status to review.

**Not verified on hardware:**
- The walkthrough on the lens: code readability and indentation.
- Reading-driven block advance with real speech.
- Contextual strings improving recognition of project names.
- Follow-up and speaker handling with real voices.

## Update 2026-11-20 (p): hands-free Code Tutor and automatic question handoff

**Adaptive walkthrough**
- `WalkthroughCompletionEvaluator` scores concept coverage with paraphrase groups, relevance, verbatim alignment and the utterance boundary, with per-mode thresholds (see CODE_TUTOR.md).
- At most one bounded AI check per block. Code blocks never advance on speech or silence.
- `EditorBridge` / `EditorSession` and `Tools/vscode-code-tutor` provide the optional paired editor (HMAC pairing; booleans, error count and file name only).
- Info.plist gained `NSLocalNetworkUsageDescription` and `NSBonjourServices`, used only when pairing is on.

**Automatic question handoff** (`HandoffPhase` reducer in ConversationEngine)
- Phases: listening → answerActive → newTurnDetected → followUpResolved → generatingReplacement (the old answer stays visible) → replacementReady → switching → answerActive.
- **Classic mode no longer needs Continue:**
  - A confident (≥ 0.8), non-wearer question replaces the answer automatically.
  - The old 10 s lock became a 2 s anti-oscillation cooldown (settings v3 migrates the untouched value).
  - During generation the newest confident question wins.
- **Medium confidence:** queued and confirmed by related evidence (accumulated ≥ 1.2), never by a timeout.
- **Undo:** works for every automatic switch. It restores the answer, its reading position (`ReadingController.restorePosition`) or its walkthrough block (per-answer suspension). An undone question needs fresh evidence to switch again, which prevents oscillation.
- **Echo protection** now includes the visible code, so speaking code aloud is never a question.

**Tests:** 343 in 61 suites; three consecutive runs passed. Clean Debug/Release builds have no warnings; static analysis is clean.

**Changed behaviour** (two older tests were updated to the new contract):
- A confident question during generation replaces the stale generation.
- Follow-ups inside the 2 s cooldown are still queued.

**Not verified on hardware:**
- Paraphrase detection with real speech.
- False-advance and false-switch rates in noise.
- The editor companion on a real network.
- Handoff timing on Gemini.

## Update 2026-11-20 (q): premature code transitions, code density

**Root cause:** whole-block coverage plus the recognizer's end-of-sentence final, after only the first sentence; utterances carried over from before the block; and several uncoordinated transition sources.

**Fix:**
- Transition coordinator (`requestTransition`, with a token).
- Strict explanation → code evaluation: per-sentence coverage, verbatim reading needs confidence, never mid-utterance or mid-phrase; carried-over speech skipped.
- `CodeDisplayLayout` + `CodePaginator`: string-safe breaks, line groups kept together, compact part labels.
- Code Display Calibration screen, saved in `settings.codeLayout`.

**Changed expectations:**
- Single-page code blocks no longer carry a "CODE n/N" row.
- A speech test that covered only one of two sentences no longer advances, as intended.

**Tests:** 359 in 65 suites; three consecutive runs passed. Clean Debug/Release builds have no warnings; static analysis is clean.

**Hardware:** nothing in this update has been verified on the RayNeo. That includes extra code rows and width, and whether the lens preserves leading spaces.

## Update 2026-11-22 (r): natural answers, sentence streaming, Coding Skeleton Mode

**Natural answers**
- Adaptive length: about 3–5 sentences, 6–9+ for complex topics.
- `NaturalAnswerStyle.polish`: openers and corporate words. It is prefix-stable, so early frames match the final answer.
- Answers that repeat the same opening three times are regenerated once.
- The prompt asks follow-ups to answer the latest question directly.

**Sentence streaming**
- The first complete sentence is shown as soon as it passes validation (relevance is judged on the final answer only).
- The first frame then grows by complete sentences only: at most one more write before completion, never changing shown words.

**Skeleton:** `SKELETON` block, validated and derived when missing, shown early (deferred while speaking), adopted atomically.

**Speed**

| Change | Effect |
|---|---|
| Endpoint for complete questions | 0.6 s (was 1.2 s) |
| Prompt budgets | Trimmed |
| Measured, simulated stream | First frame 0.098 s vs ≈ 0.26 s; endpoint 0.6 s vs 1.2 s; context 1056 vs 1106 chars |

Real Gemini/RayNeo timings need the device.

## Update 2026-11-22 (s): VS Code ↔ iPhone ↔ RayNeo editor link

**Security** (`App/EditorSecurity.swift` ⇄ `Tools/vscode-code-tutor/protocol.js`; shared vectors)
- X25519 + HKDF-SHA256 with a single-use, 2-minute pairing code of about 50 bits.
- A 30-day trust key in the Keychain / SecretStorage; ephemeral keys for every session.
- ChaCha20-Poly1305 with strict sequence numbers and timestamps.
- Rate limit, size limit, heartbeat watchdog. Each connection has its own buffer, so a stranger cannot disturb the connected editor.
- Forget / revocation.

**Bridge** (`EditorBridge`)
- Fixed port 48654 (any port as fallback) plus the Bonjour name `RayPrompt-<tag>`.
- Listening stops while the app is in the background.
- Metrics.

**Assistant** (`EditorAssistant`)
- Display priority; `DiagnosticExplainer` rules plus an AI fallback on explicit help.
- Explain Selection; test/build results.
- Progress needs stable, present, error-free steps.

**Extension:** reconnects with backoff and Bonjour rediscovery; sends metadata by default; excerpts only after confirmation, redacted, never from sensitive files.

**Tests:** 390 in 74 suites (three runs) and 6 Node tests pass. Clean builds; analysis clean.

**Not verified on hardware or a real network:** pairing, reconnection, Bonjour, latency, and the extension in a real VS Code.

## Update 2026-11-22 (t): interview intent, long prompts, context awareness

**Root causes found**
1. **Imperatives never triggered an answer.** "Design a background job…" scored 0.05, below the 0.5 threshold and even below the 0.25 band where the on-device semantic check runs.
2. **Duplicated or lost transcript text.** A restarted recognizer repeats the previous result's tail ("…submissions, tem" + "The application must handle thousands of submissions, temporary…"), and the segments were joined verbatim. An overlapping correction replaced a longer pending segment wholesale.
3. **Incomplete answers.** The prompt carried no per-request structure and no list of the interviewer's constraints.
4. **Context missing from Gemini requests:**
   - Interviewer statements that weren't questions were dropped.
   - With Gemini, conversation history was gated together with personal memory under one toggle (off by default).
   - Knowledge-base keywords matched as substrings: "explain" in the PostgreSQL topic (`EXPLAIN ANALYZE`) attached PostgreSQL notes to every "Explain…" request. This is the reported "these incidents" → PostgreSQL answer.
   - "What happens if…" wasn't a follow-up cue.
   - The answer cache ignored follow-up context.

**What changed**

| Area | Change |
|---|---|
| Intent (`Intelligence/InterviewIntent.swift`) | `InterviewIntent`: kinds, requirements, parts, prompt guidance, length and token budget per kind, a deterministic completeness check (at most one targeted regeneration), continuations. `QuestionDetector` takes the intent's confidence and caps small talk at 0.1. |
| Assembler (`TranscriptTurnAssembler`) | `stitch` / `revise` / `overlapLength` / `contains`; scenario endpoint `scenarioSilence` (2.4 s); `absorb` folds a continuation turn into the previous one, in `AppModel.process`, gated by `settings.continuationGap` (3 s). `TranscriptBuffer` merges progressive finals. |
| Context (`Conversation/InterviewContext.swift`) | `InterviewContext`: statements in the current topic, incidents, constraints, topic expiry (explicit cue, unrelated request, 10 min). `ContextReference` resolves these / those / the second one / implicit references. Recorded through `engine.onInterviewerTurn` after echo and wearer filtering. |
| Engine | Answers read aloud are stripped sentence by sentence, so an interviewer interruption inside one turn survives. Each turn gets a transcript role label. Contextual requests skip the cache. |
| Prompt | Notes now carry the scenario note, Q&A from the current topic only (superseded and duplicate entries removed), and the previous exchange sent once. Request guidance sits in the prompt; the system instructions stay stable. |
| Settings | `geminiIncludeInterviewContext` (default on). `geminiIncludePortfolio` now covers personal memory only. |

**Measured (simulator, deterministic mock provider)**
- Actionable prompts dispatched: 8/11 before, 11/11 after.
- False positives: "Give me a second." was answered before, none after.
- Classification cost: 26 µs → 191 µs per utterance.
- Incident request prompt: 295 characters (PostgreSQL notes, no incidents) → 1,963 characters (the scenario, three numbered incidents, reference resolution, troubleshooting structure, three parts).

No live Gemini or device measurements yet.

## Update 2026-11-22 (u): finalized question revisions and answer relevance

**Root cause.** The device report reproduces deterministically. SpeechAnalyzer finalizes "…using Supabase Authentication and PostgreSQL RLS" and "especially when students, instructors, and administrators have different access permissions." as two segments.
- After the 1.2 s endpoint, the first half was a complete turn: a trailing comma didn't count as unfinished. It was answered and the answer locked.
- The second half became its own turn, classified as "Not a question" (classic mode) or "General conversation" (continuous mode). It never reached the answer.
- No requirement was extracted from "especially when…", so validation had nothing to check.

**Fixes**
- *Unfinished clauses:* `isIncomplete` counts a trailing comma, colon, semicolon or dash; qualifier endings ("especially", "such"…); and open endings ("that", "when"…) without terminal punctuation. These turns wait silence + grace.
- *Continuations:* `InterviewIntent.isQualifierClause` lets "especially / including / where / when…" clauses continue the previous request. They're joined as a clause ("…RLS, especially when…").
- *Engine revisions:* a revision of a turn whose answer is active or generating is regenerated as the same request, with the kind and context of its first version.
  - It is never a follow-up to its own partial answer.
  - It is never undone back to that partial answer.
  - A non-material revision updates the active question's wording.
- *Display hold:* while the interviewer is still speaking within `continuationGap` of the turn, no early frame is shown, and a finished answer waits up to 3 s. A revision cancels it during the wait; if nobody keeps speaking, there is no delay.
- *Follow-ups:* a self-contained request (five or more subject words, no back-reference) is a new question even when it shares the topic's words. Detector follow-up cues inside long questions are ignored.
- *Validation:* requirements now come from qualifier clauses too. Enumerated items ("students, instructors, and administrators") must each be explained in a clause of their own; a list mention doesn't count. Role-based security questions get per-role guidance (ownership, assignments, admin rights, RLS enforcement, server-held keys) and must say how authorization is tested.
