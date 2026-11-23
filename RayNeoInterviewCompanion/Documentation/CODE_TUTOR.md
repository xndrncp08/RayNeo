# RayPrompt — Code Tutor

Coding answers have three presentations. All of them come from **one** model request per answer.

| Mode | Settings › Conversation › Code on glasses | Lifetime on the glasses |
|---|---|---|
| **Guided walkthrough** (default) | Code Tutor steps | Each block stays until Next, Previous, "next step", the optional timer, or another answer |
| Tutor step pages | Code Tutor steps, for an answer without parsable blocks | Until navigation or another answer |
| **Temporary preview** | 20-second preview | About 20 s per frame (configurable), then back to the answer |

## Guided walkthrough (EXPLAIN → CODE → EXPLAIN → CODE → RESULT)

**Generation**
- The model is asked for labelled blocks: `EXPLAIN:`, `CODE:`, `RESULT:`, and optionally `TEST:`, `EDGE CASES:` and `COMPLEXITY:` (`CodingWalkthrough.formatInstruction`).
- Each `CODE` block repeats the earlier code and adds to it; the last one is the complete solution.
- Blocks are found by these line labels, not Markdown. Stray fences are dropped, and the older single `CODE:` format is repaired into EXPLAIN → CODE → TEST.

**Validation** (before anything reaches the glasses)
- The walkthrough must start with an explanation and contain code.
- The final code must have balanced brackets.
- Every name an intermediate block declares must survive into the final code.
- The code must be in the requested or inherited language: a JavaScript request rejects Python, and rejects runtime wrappers such as `execjs`, `subprocess` or `js2py`.
- A failure triggers one regeneration with the reason. If the answer is still incoherent, it is not shown step by step and gets no end marker; the code stays on the iPhone.

**Identity**
- One answer ID; the walkthrough ID is `w<answerID>`, and block IDs are `w<answerID>-b<index>`.
- The active coding-task ID is attached as well.

**One timeline (`CodeSnippetController`)**
- Steps are explanation blocks plus lens-sized parts of code blocks. A code part has a label row ("CODE 2/3", or "CODE 2/3 · 1/2") only when a row is free.
- The iPhone highlights the block the glasses show, and both move together.

**On the glasses**
- **Explanation blocks** go through the teleprompter (Sentence Frames, reading alignment). When the reading alignment reaches the block's last word, the next code block appears.
- **The end marker** appears only on the final explanation block, never in code.
- **Code blocks** are a persistent full-frame overlay through the single caption writer. Speech never moves them; only Next, Previous, an exact spoken command ("next step", "go back") or the optional timer does.
- **Reconnection:** the current code block is restored. A temporary preview never is.

**Other behaviour**
- Another answer, or a clear, ends the walkthrough.
- **Explain a line:** on the iPhone, tap a line of the final solution. One short model request explains it using the task as context; the walkthrough position does not change.
- **Early first frame:** turned off for coding answers, so partially streamed code never reaches the lens.

## Active coding task (`ActiveCodingTask.swift`)

**Kept**
- The instruction, language, input and output, constraints, your spoken approach (Set, spread…), the code so far, modifications, and turn IDs.

**Follow-ups resolved against it**
- "show me the code for that", "what would that function look like", "make it TypeScript", "what if the array contains objects", "how would you test it", "explain this line".
- The language is inherited unless a new one is named.
- With no task, "show me the code for that" asks one clarifying question.

**Cleared** when a new, non-coding question changes the topic.

## Known limitations

- **Language detection** is heuristic (keywords, annotations, JSX); it rejects clear mismatches but cannot prove correctness.
- **Bracket balancing** ignores strings and comments.
- **Code is never executed**: tests and complexity are the model's claims, labelled "not run".
- **Indentation on the lens** has not been verified on the RayNeo iO.

## Adaptive (hands-free) walkthrough

Settings › Conversation › **Adaptive Walkthrough**, also switchable on the walkthrough card during a session: Off, Conservative, Balanced (default), Responsive.

**Explanation blocks** (`WalkthroughCompletionEvaluator`)
- Each block's key ideas are its stemmed content words; paraphrase groups count as the same idea (unique/distinct/duplicate, filter/keep/select, convert/turn…).
- What you say is scored for:
  - **coverage**: the share of key ideas said;
  - **relevance**: the share of your words that relate to the block, which rejects unrelated talk that shares a keyword;
  - **verbatim alignment**, from the existing reading tracker;
  - **a stable boundary**: the recognizer finalizing your utterance. Silence alone never counts.

| Mode | Coverage | Relevance | Completion | Mid-sentence |
|---|---|---|---|---|
| Conservative | 0.80 | 0.45 | 0.85 | no |
| Balanced | 0.60 | 0.35 | 0.72 | no |
| Responsive | 0.50 | 0.25 | 0.62 | when ≥ 90 % covered |

- Reading a block verbatim to its last word always completes it.
- A borderline final utterance gets at most **one** yes/no AI check per block. It runs on-device always; with Gemini only when context sharing is on.

**Code blocks**
- Speech, pauses and silence never move a code block. The microphone cannot tell whether you typed anything.
- They move on Next, "next step", the optional timer, or a paired editor (below).

**Editor companion** (optional: `Tools/vscode-code-tutor`, Settings › Pair a code editor)
- Pairing is an HMAC challenge, so the 6-digit code never travels. Local Wi-Fi only, one editor at a time, and the listener runs only while pairing is on.
- The iPhone sends the step's expected lines (generated code). The editor returns only the file name, a true/false per line, and its error count — never your source.
- A code step completes only when every line is present and errors = 0. Conservative also requires that an error check was reported.
- Messages are not encrypted.

**Interruptions**
- Progression pauses while a new question is being answered or a prepared answer is waiting.
- A replaced walkthrough is kept per answer; Undo restores it at the block where it was.

**Diagnostics**
- Block ID, coverage, relevance, completion, and the reason for waiting or advancing.
- "Next block ready", manual overrides, editor verdicts, and the time from completion evidence to caption submission.

## Explanation → code: strict transitions (2026-11-20, device fix)

**Causes of code appearing mid-explanation**
1. Coverage was measured over the whole block. The first sentence usually names most of the key ideas, and the recognizer finalizing that sentence counted as end-of-explanation evidence.
2. The utterance already in progress when a block appeared (still reading the previous one) was counted for the new block.
3. Speech, the AI check, timers, the editor and manual controls each moved the walkthrough independently.

**Now**
- Every move goes through `CodeSnippetController.requestTransition`, the transition coordinator. It checks:
  - **Step and block:** the expected step and block still match.
  - **Answer:** the walkthrough's answer is still on the teleprompter.
  - **Priority:** for automatic sources, no pause and no newer question.

  It logs the source and reason. A token voids every display or callback started before the latest transition.
- **Explanation → code** (`evaluate(strict: true)`) requires either:
  - verbatim reading to the last word with alignment confidence ≥ 0.6; or
  - a final, not-mid-phrase utterance in which **every sentence** is covered (≥ 50 %, the last ≥ 60 %), overall coverage ≥ the mode's strict level (Balanced 0.85, Conservative 0.95, Responsive 0.75), and at least half the block's words' worth of speech.
- An utterance that began before the block appeared is ignored.
- Never: partial coverage, punctuation or silence alone.

## Code layout and pagination

- `CodeDisplayLayout` is separate from the explanation layout: code rows (default 5, never more than the calibrated lens rows), characters per row (default 48), indentation per level (default 2).
- **Settings › Caption Calibration › Code Display Calibration** sends six patterns: row ruler, width ruler with code symbols, indentation ladder, long-line wrapping, frame replacement, sample page. "Verified on my RayNeo" saves the layout.
- **No new protocol fields:** font size is not changed (only caption font_size 2 has been seen working).
- `CodePaginator`:
  - **Breaks:** at spaces, after `, ; ( [ {` or before a method-chain `.`, never inside string literals. A row is cut inside a token only when no boundary exists (counted as a hard break).
  - **Characters:** every character is kept in order; blank lines are dropped on the lens only.
  - **Pages:** wrapped rows of a line stay on one page.
  - **Labels:** a single-page block has no label; a multi-page block shows "(k/N)" on its last row (or on a row of its own if that row is full).
- The iPhone always shows the full code.

## Coding Skeleton Mode (default on)

- Coding walkthroughs open with a `SKELETON` block: a concise, syntactically correct outline of the final solution.
  - **Validation:** balanced brackets, the requested language, ≤ 10 lines, and only names the final code keeps.
  - **Fallback:** if the model omits it, the skeleton is derived from the final code (signature, a body comment, closing line). SQL gets none.
- **Early display:** when its block is complete while streaming, the skeleton appears on the glasses before the rest of the answer. It waits while you are mid-sentence, and is withdrawn if the answer fails or is cancelled.
- **Atomic adoption:** the final walkthrough adopts it in one write (skeleton + answer), with no second write and no flash of text.
- **Lifetime:** like any code step, it stays until Next, "next step", an editor report or an optional timer. Speech and silence never remove it.

## Editor link (see Tools/vscode-code-tutor/README.md)

- **Progress:** code steps advance on a *stable* editor report (no edits for 1.5 s) with every expected line present, the expected names present as symbols, and no errors.
- **Priority:** explicit help > a confident new question > the walkthrough > editor progress > low-priority diagnostics.
  - Errors appear briefly on the glasses only on code steps, and never while you are speaking.
  - Warnings stay on the iPhone. Repeated captions are coalesced.
