# RayPrompt — Hardware test checklist

Record the result, iOS version and glasses firmware for each item. "Write succeeded" is **not** the same as "visible on the lens".

## A. iPhone only (simulator glasses)

1. Start a session. The red mic dot appears, Input shows *iPhone Microphone*, and Speech shows *Running · SpeechAnalyzer*.
2. Have someone else ask *"How do you troubleshoot a Microsoft 365 login issue?"*. The transcript appears, the state goes Generating → Answer locked, and the simulated glasses show the answer. Note the **AI first token** and **AI total** values under Diagnostics.
3. Read the answer aloud yourself. Diagnostics should count `echo` up, and the answer must not change.
4. Within 10 s, the other person asks a follow-up. It appears as **Queued question** and the answer is preserved. Tap **Answer it now**.
5. After more than 10 s, the other person asks a new, clearly phrased question. It should auto-advance.
6. Stay silent or make small talk for 2 minutes. No answers should be generated.
7. Connect AirPods or a Bluetooth headset during the session. Input must stay *iPhone Microphone*.
8. Place a phone call into the session, or trigger Siri. The status should go Interrupted, then Listening.
9. Lock the screen for 2 minutes while the other person asks a question, then unlock. Record whether the transcript and answer arrived while locked. This is not verified yet.
10. Run a 60-minute session. Record memory and thermal state every 15 minutes, and note the battery drop.
11. Calibrate your voice in Settings, then repeat step 3 with paraphrasing instead of reading verbatim. Note whether `wearer` increments.

## B. RayNeo iO: "HELLO FROM IPHONE" (no microphone needed)

Leave the glasses bound to the official app (b-d.io reports that binding once is required). Do **not** unbind, reset or flash them.

1. Wear the glasses. The display must be on: a session fails to start while it is off or charging.
2. Force-quit the official RayNeo app so it cannot hold a session.
3. Open the RayNeo diagnostics screen (antenna icon, top left). If needed, tap **Use RayNeo iO**.
   - Session type: **Caption session (0x13)**.
   - Tap **Clear** in Recent events.
4. Tap **Connect**. The state should go: Scanning → Connecting → Discovering → Authenticating → Authenticated → Starting display session. It then ends in one of these:
   - **Display session confirmed** (`RX 0x13 … type 8 {code=1…}`). Tap **Send "HELLO FROM IPHONE"**.
   - **UNCONFIRMED** (no acknowledgement in 8 s). Optionally tap **Send anyway on UNCONFIRMED session (experimental)**.
   - **Rejected (code N)**. Note the code. The link is kept and nothing retries automatically.
5. Look at the glasses and answer **Yes, visible** or **Not visible**. Your answer goes into the log.
6. If it wasn't confirmed or wasn't visible: tap **Disconnect**, switch Session type to **Real-time prompt (0x17)**, tap **Connect** and repeat steps 4–5. Note whether "Conversation ended" appears, and when.
7. Tap **Export diagnostics** and share the text.

Only a "Yes, visible" answer means display works. "Display session confirmed" means the glasses acknowledged the session; it does not prove anything is visible.

## C. Full interview workflow (after B showed text: verified 2026-11-20 on an iO-E081)

**Setup, once:**
- Settings › Glasses: Display = RayNeo iO, Session type = Caption (0x13).
- Turn **on** *Caption compatibility mode* and *Advance pages as I read aloud*.
- Leave *Lock answer after it is displayed* on.
- Force-quit the official RayNeo app and wear the glasses.

1. **Connect:** open RayNeo Diagnostics and tap **Connect**. Wait until the Live Captions intro appears on the glasses. The state reads "UNCONFIRMED" and *Answers forwarded automatically* = **Yes**.
2. **Start:** go back to the dashboard and tap **Start Session**, then confirm consent. The glasses state must not change: starting the microphone does not touch the link.
3. **Interviewer asks:** another person asks clearly, e.g. *"How do you troubleshoot a Microsoft 365 login issue?"*, then stops talking.
   - Expected: the transcript shows the question, the state goes Generating → Answer locked, and within a few seconds the answer replaces the caption text on the glasses.
   - The dashboard's glasses panel shows "Page 1/N written … (unacknowledged session, compatibility mode)".
4. **Read it aloud:** read the answer from the glasses at normal pace.
   - Expected: no new answer is generated, and Diagnostics › Suppressed › echo increases.
   - With several pages, pause briefly at the end of each page. The next page should appear about 1–2 s after you finish its last words, and never mid-sentence.
   - You can also page manually with the arrows under the glasses preview.
5. **Follow-up:** the interviewer asks *"And what about if MFA is the problem?"* within 10 s of the answer appearing.
   - Expected: it shows as **Queued question** and the current answer stays on the glasses.
   - Tap **Answer it now**, or wait until 10 s have passed and have them ask again. A confident question then replaces the answer automatically.
6. **Stop:** tap **Stop Session**. The microphone turns off and the caption session is closed.
7. Export diagnostics. The `[pipeline]` lines show *Question detected → Answer displayed → Caption sent* with timestamps.

Record for each step: what appeared on the glasses, and the time from the end of the question to the text appearing.

## D. Speech-Synced Reading (teleprompter)

**Prerequisite:** C works (AI answers appear on the lens). Manual Reading stays the default until this passes.

**Setup:**
- Set the dashboard **Reading** section to **Speech-Synced**.
- Calibrate your voice in Settings (optional; it gives stronger evidence).
- Turn on Debug logging so you can watch the decisions.

1. Have the interviewer ask a question whose answer needs 3 or more sections (e.g. *"Walk me through how you'd troubleshoot a failed Salesforce integration."*). Section 1/N appears on the glasses.
2. **Read section 1 naturally.** It must **not** advance while you are mid-section. It should advance within about 1 s of saying its last meaningful words. The new window starts with "…" and the previous line as context.
3. **Stop mid-section for 10 s.** Nothing changes. The progress bar and "Read x/y words" stay put.
4. **Repeat a sentence you already read.** No change, and no backward jump.
5. **Paraphrase a sentence** ("I'd look at…" instead of "I would check…"). It should still follow. If it doesn't, note the "Too little evidence" or "Sparse match" reason.
6. **Interviewer interrupts** while you read ("Sorry, can you speak up?"). The display holds. If it's a question, it is queued per the answer lock.
7. **Unrelated chat** using the same technical words ("the backend team owns the API keys"). No advance.
8. **Pause Auto-Scroll**, read to the end of a section, and confirm it holds. Then **Resume Auto-Scroll**: it catches up with one update.
9. **Previous Section, Next Section, Reset Reading Progress** each move the display once, and reading continues from there.
10. **Turn the glasses off and on mid-answer.** The same section is restored, and reading continues.

Record for each step: whether it advanced, how long after the last word, and any premature or missed advance (export diagnostics; `[pipeline] Reading:` lines show the cursor and confidence for every transition).

## E. Caption calibration (do this before D)

Open RayNeo Diagnostics › **Caption calibration** (or Settings › Glasses), connected in Caption mode with compatibility mode on, and wear the glasses.

1. **Numbered lines:** tap *1 · Numbered lines*. It sends 6 rows padded to your characters-per-line. Record:
   - which LINE numbers are fully visible;
   - whether the **first** or the **last** rows are missing (the last rows kept means the lens shows the end of long captions, which is how answer beginnings were lost);
   - whether any physical row shows two LINE labels (raise characters per line) or a label wraps (lower it).
2. **Width ruler:** tap *2 · Width ruler*. The last number fully shown on the first row is about the characters per line. Set *Characters per line* a little below it.
3. **Replace test:** tap *3 · Replace test*. If "A" is still visible after "B" appears, captions are appending. Turn off *Send captions as final*, repeat, and record whether that fixes it.
4. Set *Lines fully visible* to what you saw and tap **Use N−1 lines… and save**. This keeps one line of margin.
5. **Sample answer:** tap *4 · Sample answer, first window*. It must start with "I'd start by checking" and show completely. Compare it with the simulated layout at the bottom of the screen.
6. Optional: try *Previous-line context: One line* and the experimental *Text density* (applies on the next Connect). Repeat steps 1 and 5 after each change.

Report the numbers from steps 1–4. The defaults (4 × 26) are an estimate until you confirm them.

## F. Answer engine (math, facts, technical, coding)

1. Ask: **"What is 5000 times 592?"** The glasses must show `5000 times 592 is 2,960,000.` almost instantly. Diagnostics shows `Routed as math`, and no model is used.
2. Also try: "What's 15% of 240?" (36), "What is 2 to the power of 8?" (256), "What's the average of 12, 18, and 24?" (18), "What is 10 divided by 0?" (a safe explanation, not a number).
3. **Factual:** "What does HTTP 401 mean?" should get one direct sentence.
4. **Technical:** "How would you troubleshoot a Microsoft 365 login issue?" should get 3–5 casual first-person steps.
5. **Coding:** "Write a function that removes duplicates from an array." should get a short spoken explanation that doesn't claim the code was tested.
6. **Ambiguous:** "Can you explain it?" (with no earlier answer) should get a clarification request.
7. Settings › AI › **Answer evaluation › Run**: runs 52 questions with the real pipeline on this iPhone. Export the report. It gives accuracy, the rate of non-answers, length, median/p95 latency, cold start and memory.

## G. Line-by-line Speech-Synced scrolling

Prerequisite: calibration (E) is done and Reading mode is **Speech-Synced**, Responsiveness **Balanced**.

1. Ask a technical question. The first 4 lines appear, starting with the first word.
2. Read naturally. As you finish line 1 and start line 2, the window should move up by **one** line. It must not wait for the sentence to end, and must never remove a line before you've said its last meaningful word.
3. Pause mid-line for 10 s: no movement. Repeat a sentence: no movement and no backward jump.
4. Have someone talk over you using the same technical words: no movement.
5. Try Conservative and Responsive and note the difference in how quickly it scrolls.
6. **Back One Line / Forward One Line / Reset to Beginning / Pause / Resume** each produce one update.
7. Turn the glasses off and on mid-answer: the current window is restored.
8. Watch the Reading panel's "Line boundary → write handed to iOS" latency and export diagnostics (`[pipeline] Line boundary…` and `Window … handed to … ms after the request`).

## H. Word spacing, clean layout, and answer replacement

**Setup:** Settings › Caption calibration: turn on **Show exact outgoing caption on the iPhone (debug)**. Leave **Clear the lens between answers** on.

1. **Firmware behaviour first.** Run calibration tests 5–8 and write down the results:
   - **5 · Junction:** do you see "BRAVOCHARLIE", both captions, or only "CHARLIE DELTA"?
   - **6 · Newline:** three rows, or "ROW ONEROW TWO…"? Only if you see three rows, turn on **Explicit line breaks**.
   - **7 · Long then short:** do any LINE rows remain under "SHORT CAPTION"?
   - **8 · Clear:** does the lens go blank?
2. **Word spacing while scrolling:** ask a long technical question with Speech-Synced on, and read it.
   - After every scroll, compare the lens with the iPhone's outgoing-caption view. The iPhone view shows spaces as "·".
   - If the iPhone shows `logs·to` but the lens shows "logsto", the text was sent correctly and the joining happens on the glasses.
   - If the iPhone shows `logsto`, it is an app bug: export diagnostics and report it.
3. Sentences should wrap naturally with nothing cut off or re-punctuated.
4. **Next answer:** after one answer, ask a new question and tap **Next Answer** (or let it auto-advance). The lens should briefly blank, then show only the new answer from its first word.
5. Old questions or answers must never reappear. Tap **Clear Display**: the lens should go blank and stay blank after turning the glasses off and on.
6. Use Forward One Line quickly 5–6 times. The lens should land on the newest window with no fragments mixed in.
7. Turn the glasses off and on mid-answer. Only the active answer's current window should come back.

Export diagnostics. Each `Caption write:` line shows the answer #, generation, word and line ranges, character and line-break counts, final/in-progress, the result, and latency, with no spoken content.

## I. Caption Replacement Lab and Stable sections (do this first)

1. Connect in Caption mode with compatibility mode on, and wear the glasses.
2. Open Settings › Glasses › Caption calibration › **Caption Replacement Lab**. Run cases 1–12 one at a time. After each, pick what you see:
   - Only the last caption
   - Both visible / stacked
   - Words joined together
   - Nothing changed / unclear

   Use cases 2, 4 and 11 (in-progress) and 12 (separator) especially. Every send is logged with its status, session ID, step and interval. Caption text is logged only if you turn on the test-only toggle.
3. Tap **Apply** under Recommendation:
   - If in-progress captions replaced cleanly (cases 2, 4 and 11 = "Only the last caption"), it switches to **Rolling lines, in-progress**.
   - Otherwise it keeps **Stable sections**.
4. **Stable sections check:** ask "How does Row Level Security work?" and read it.
   - Each segment is a whole sentence or clause with no repeats.
   - Words are correctly spaced at segment joins.
   - The next segment appears only after you finish the current one.
5. **Old answers:** ask a second question. If text from the first answer is still visible, turn on **Fresh caption session for each answer**, try lowering **Caption start wait** (e.g. 3 s), and repeat.
6. **Factual answers:** ask "What is Salesforce?". You should get one definition sentence with no "I would check the documentation…".

## J. Step-by-step Caption Replacement Lab (supersedes I.2)

Open Settings › Glasses › Caption calibration › **Caption Replacement Lab**. For each experiment:
1. Tap **Reset to a clean caption session**. The lens may show the Live Captions intro; that is the clean state.
2. Tap **Send step N**. The iPhone shows the exact text sent (· = space, □ = full-width space, ⏎ = line break). Wait at least 3 s.
3. Pick what you see. The next step unlocks only after you record it.

Run at least **A, B, E, F, N, X**; C, D, E2, G, G2 and S add detail. H is not testable: no caption record ID is documented besides the session ID.

**Which strategy the lab recommends:**
- **B** and **G2** show only the newest caption: **Rolling lines, in-progress**.
- Otherwise, **X** shows only the newest frame each time (needs N = separate rows): **Full-frame scrolling**.
- Otherwise: **Stable sections**.

Then repeat the reading tests (G/H). The calibration patterns (1–8) now also start from a fresh session by default, so earlier patterns can no longer stack on the lens.

## K. Sentence Frames, early first frame, Gemini (2026-11-20)

Prerequisite: Lab X-1/X-2 ("only the newest frame visible"). If X shows older text, use Stable Sections.

1. **Sentence Frames (new default).**
   - Ask a long technical question. The lens should show one 3–4 line frame with no counter, heading or question.
   - Each row ends cleanly. No words are joined, duplicated or clipped, and no older text is visible.
   - A short answer appears whole, at once.
2. **Advancing.** In Speech-Synced mode, read the frame aloud.
   - It should switch to the next frame as you say its last words, without waiting for a pause.
   - Pausing mid-frame must not advance it.
   - Next/Previous Frame buttons step one frame.
3. **Width.** Default rows are 48 characters (photo: ~55–60).
   - If a frame wraps onto a 5th row, lower Characters per line in Calibration.
   - If rows look short, raise it.
4. **Early first frame.** With "Show the first frame while the answer streams" on, ask a technical question.
   - Note whether the first frame appears before the dashboard reaches Answer Locked.
   - When generation finishes, the frame must not flicker or be rewritten.
   - Record "Early first frame shown" and "First complete sentence" from Diagnostics.
5. **Gemini** (only after GEMINI.md setup; tap Test Gemini Connection first):
   - Verify the key. Ask 5 questions and record "Answered by" and "Gemini network latency".
   - Then turn on Airplane mode and ask again. With fallback on, the answer should come from Apple; with fallback off, the previous answer stays and an error is shown.
6. **Benchmark.** Run the 52-question evaluation with Apple, then with Gemini. Export both reports.

## L. Minimal verification pass (do before any further feature work)

Record each result as pass / fail / photo.

1. **Gemini connection:**
   - Settings › Gemini › Test Gemini Connection. Expect "Result: Connected", HTTP 200, the model name with "supports generateContent", a first-token time and the response "Connection OK".
   - Repeat with Airplane mode on (expect "Network failure").
   - If you can, repeat with a deliberately wrong key in a spare slot (expect "Invalid or restricted API key").
2. **Frame payload:**
   - Calibration › Sentence frame preview › Build frames on the sample answer.
   - Each caption shows ≤4 text rows, the longest row is within the limit, and there is no counter.
3. **Lens matches the preview:**
   - Connect the glasses and ask "How would you troubleshoot a Microsoft 365 login issue?".
   - Photograph frame 1, then press Next Frame and photograph each frame.
   - Compare with the preview: same words, no older text, no joined or duplicated words.
4. **Early frame:**
   - Ask a long technical question. Note whether frame 1 appears while the status still says "Thinking…".
   - When the answer completes, frame 1 must not change.
   - Diagnostics: "Answer ID (pipeline · lock · glasses · reading)" shows the same number in the lock, glasses and reading columns; "Early frames replaced by validation" should stay empty.
5. **Gemini answer:** select Gemini Flash and ask 3 questions. Record "Answered by", "AI first token" and "Gemini network latency".

## M. Look-ahead teleprompter and end-of-answer marker

1. **Glyph:** Calibration › pattern 9. If ✓ shows as a box, "?" or nothing, set Settings › End-of-Answer Indicator to ASCII [END].
2. **Lab X:**
   - If X-1 and X-2 showed only the newest frame, Apply the recommendation; this turns on "Lens shows only the newest frame".
   - Otherwise leave it off: frames stay non-overlapping.
3. **Short answer:** ask "What does HTTP 401 mean?". The whole answer should appear in one frame, ending with the marker.
4. **Long answer** (Speech-Synced, Look-Ahead Balanced): ask a long technical question, then read aloud at normal pace.
   - The first frame shows 4 full lines.
   - As you start the 3rd visible line, the window should jump: your current line moves to the top and 3 new lines appear below.
   - Expect no pause before upcoming text appears, and no repeated, joined or missing words. Photograph two transitions.
5. **Compare settings:** try Responsive and Conservative.
   - Responsive should move slightly earlier; Conservative only on the last line.
   - Background talk or pausing must not move the window.
6. **Marker placement:**
   - The marker appears only on the final frame, after the last word, and only once.
   - It never appears during "Thinking…" or on the early frame.
   - When you finish reading, the final frame stays and the dashboard says "reading complete".
7. **Timings:** record Diagnostics › "First frame submitted to Bluetooth" and "Reading boundary → caption handed to Bluetooth".

## N. Personal memory, code snippets, continuous conversation

Setup:
- Settings › Conversation › Continuous conversation **on**.
- Start the session as **Practice** (a friend plays the interviewer; Live requires everyone's consent).
- Speech-Synced reading on. Record each step as pass / fail / photo.

1. **Import a repository:**
   - Copy one real repo folder (e.g. Diskarte) to Files / iCloud Drive.
   - Settings › Personal AI Memory › Import a repository folder.
   - Check the summary's facts and the file references under My Projects. Confirm the import message lists skipped sensitive files and that no secret values appear (Export memory).
2. **Grounded answer:** ask "How did you handle real-time messaging in Diskarte?".
   - Dashboard › Conversation › "Memory used" names Diskarte.
   - The answer mentions only facts in your memory. If it names a technology you did not use, note it: the grounding check should have rejected it.
3. **Code snippet:**
   - Ask "Write a SQL query to count users per country."
   - The spoken explanation is on the teleprompter; the code card appears on the iPhone with Copy Code.
   - The glasses show the code frame with no Markdown and no joined tokens. Check whether indentation survives.
4. **20-second window:** time from the code appearing to the answer returning, using a stopwatch. Expect about 20 s per frame (approximate).
5. **Expired snippet:** show a snippet, turn the glasses off (or walk out of range) and back on. The answer must return, never the code.
6. **Technical question:** ask "How would you debug a Salesforce integration?", then start reading the answer aloud.
7. **Follow-up:** while you read, the other person asks "What if the API key expired?".
   - Expect it recognised as Follow-up, high, and the new answer to replace the old **without tapping anything**.
   - Note the time to the first new frame.
8. **Undo:** if a transition was wrong, tap Undo last automatic transition; the previous answer must return.
9. **Medium confidence:** the other person says "Is that common" (no question mark tone). Expect "Follow-up answer ready (not shown yet)". It appears when you finish reading or tap Show now.
10. **Speech that must not replace the answer:**
    - Read your answer aloud; say "the parking was full today"; have the interviewer say "Take your time".
    - The answer must not change.
11. **No old text:** check the lens after each transition: no old captions, no mixed answers.
12. **Speaker attribution:** repeat 7–10 in a quiet room and with background noise (TV or café audio). Note misclassifications from Diagnostics › Last speech.
13. **Clearing data:** Clear Session Memory, Delete project index, Delete personal memory, Export. Confirm each is reflected immediately.

## O. Conversation intelligence and guided coding walkthroughs (2026-11-20)

Setup:
- Continuous conversation on; Code on glasses = Code Tutor steps; Speech-Synced reading.
- Optional: Settings › Conversation › Transcript debugging on, to see raw vs normalised turns.

A. **Guided JavaScript coding**
- Ask "Write a JavaScript function that removes duplicate values from an array."
- Expect, on the glasses and the iPhone together:
  1. Explanation (Set).
  2. First code fragment.
  3. Explanation (spread operator).
  4. Complete function.
  5. Result, with ✓.
- Read each explanation aloud: its code should appear when you finish. Say "next step" to leave a code block.
- Check that no Python/`execjs` appears, no old block stays visible, and the iPhone highlights the same block as the lens.

B. **Contextual follow-up**
- Explain the Set approach aloud, then have someone ask "Can you show me the code for that?".
- Expect JavaScript code for the same task: no refusal, no unrelated solution, no language change.

C. **Project names**
- Ask "Can you tell me about your project Diskarte?" and "Can you talk about your project Resoniq?". Also try pronunciations that may come out as "Rezonic" or "Resnik".
- Expect one turn per utterance (Live transcript), the canonical name, one model request each (Diagnostics), and an answer about the right project.

D. **Follow-up modification**
- Ask "What if the array contains objects?" and then "Can you make it TypeScript?".
- Expect updated walkthroughs for the same task; only the second one is in TypeScript.

E. **Temporary preview**
- Switch Code on glasses to 20-second preview and ask a coding question.
- The code should leave the lens after about 20 s per frame.
- Turn the glasses off and on during a preview: it must not come back.
- Repeat during a guided walkthrough code block: that block *should* come back.

F. **False triggers**
- Read an answer aloud, pause, repeat a sentence, make small talk, and say a sentence containing "next".
- Expect no new model request and no block change.

## P. Hands-free walkthrough and automatic question handoff

Practice Mode with a consenting partner; Adaptive Walkthrough = Balanced.

1. **Paraphrase:** ask "Write a JavaScript function that filters active students".
   - Explain the first block in your own words. The code should appear when you finish the sentence, without "next step".
   - Note the coverage line on the walkthrough card.
2. **Code stays:** start typing; keep talking, pause, stay silent for 30 s. The code must stay visible.
3. **Editor (optional):** pair VS Code (Tools/vscode-code-tutor) and type the code.
   - The step should advance only once every line is present and VS Code shows no errors.
   - Unplug Wi-Fi: the code must stay.
4. **Further blocks:** continue explaining; check each automatic transition and that no block is skipped.
5. **Handoff during a walkthrough:** your partner asks "What if the array contains objects?" during an explanation, then again during a code block.
   - Expect a revised JavaScript walkthrough without any tap, and the old blocks never coming back.
   - Tap Undo: the previous walkthrough returns at the same block.
6. **Handoff during reading:** ask "How would you troubleshoot a Salesforce integration?" and read the answer aloud. Your partner interrupts with "What if the API key expired?", then "How would you prevent that?".
   - Expect two automatic switches with focused answers. Record "First frame submitted to Bluetooth" for each.
7. **No false switches:** read the answer aloud; say "okay" and "right"; make small talk; stay silent. Expect no switch and no new model request (Diagnostics).
8. **Noise:** repeat 1, 5 and 7 with background noise. Record false advances and false switches. Speaker attribution is not reliable with one microphone.
9. **Manual controls:** Previous, Next, Pause, Resume, Restart, Adaptive Off. All should work at any time.

## Q. No premature code; code density

1. **Calibrate code first:** Settings › Caption Calibration › Code Display Calibration.
   - Run patterns 1–6 and set rows and characters to what you actually saw, never more. Turn on "Verified on my RayNeo".
   - Photograph patterns 1, 2 and 5.
2. **First sentence only:** ask "Write a JavaScript function that filters active students".
   - Read ONLY the first sentence of the first explanation, then pause for 10 s. The explanation must stay.
3. **Finish naturally:** finish the explanation (verbatim, or in your own words covering each sentence). The code should appear without a command.
4. **Density:** check that the code fills the calibrated rows.
   - Longer code shows "(1/2)" on its last row and continues on Next, with no missing or joined characters, quotes or brackets.
   - Indentation is visible, or note that the lens collapses spaces.
5. **Code stays:** type the code while talking or silent. The code stays.
6. **Handoff:** your partner asks a new question. Expect an automatic switch, and no stale code afterwards.
7. **Repeat:** steps 2–6 with paraphrasing, long pauses, and background noise. Record any premature or missed transitions.
   - Diagnostics shows "premature transition rejected (…)" and "transition authorized (…)" with reasons.
