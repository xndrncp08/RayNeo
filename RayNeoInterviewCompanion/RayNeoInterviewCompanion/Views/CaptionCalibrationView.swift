import SwiftUI

/// Calibrates the line-aware caption layout against what the lens actually shows.
/// Settings are saved immediately (AppSettings) and used by Manual and Speech-Synced reading.
struct CaptionCalibrationView: View {
    @Bindable var model: AppModel
    @State private var result: String?
    @State private var visibleLines = 4
    @State private var freshSessionPerPattern = true

    private var layout: CaptionLayout { model.settings.captionLayout }

    var body: some View {
        Form {
            Section {
                Stepper("Maximum lines: \(layout.maxLines)", value: $model.settings.captionLayout.maxLines, in: 1...7)
                Stepper("Characters per line: \(layout.charactersPerLine)", value: $model.settings.captionLayout.charactersPerLine, in: 10...60)
                Picker("Previous-line context", selection: $model.settings.captionLayout.contextLine) {
                    Text("Off").tag(false)
                    Text("One line").tag(true)
                }
                Toggle("Page counter (only when it fits)", isOn: $model.settings.captionLayout.pageCounter)
            } header: { Text("Caption window") } footer: {
                Text("Default: 4 lines × 26 characters, which leaves one of the lens's ~5 lines as margin. The window size is lines × characters per line, laid out with word wrapping. Changes apply to the next answer.")
            }

            Section {
                Picker("Text density (font_size)", selection: $model.settings.captionLayout.fontSize) {
                    Text("1 · smaller (experimental)").tag(1)
                    Text("2 · default (verified)").tag(2)
                    Text("3 · larger (experimental)").tag(3)
                }
                Picker("Display style", selection: $model.settings.captionStrategy) {
                    ForEach(CaptionStrategy.selectable) { Text($0.label).tag($0) }
                }
                Toggle("Fresh caption session for each answer", isOn: $model.settings.restartCaptionSessionPerAnswer)
                Stepper("Caption start wait: \(model.settings.captionStartWait, format: .number.precision(.fractionLength(1))) s",
                        value: $model.settings.captionStartWait, in: 1...8, step: 0.5)
                NavigationLink("Caption Replacement Lab (step by step)") { CaptionLabView(model: model) }
                NavigationLink("Sentence frame preview (exact payloads)") { FramePreviewView(model: model) }
                NavigationLink("Code Display Calibration") { CodeDisplayCalibrationView(model: model) }
                Toggle("Lens shows only the newest frame (Lab X verified)", isOn: $model.settings.framesReplaceVerified)
                Text("Turn on only after Lab X-1 and X-2 showed nothing but the newest frame. It enables look-ahead windows (upcoming lines before you finish) and adding the end marker to a frame already showing.")
                    .font(.caption2).foregroundStyle(.secondary)
                Stepper("Lens rows visible: \(model.settings.viewportRows)", value: $model.settings.viewportRows, in: 3...8)
                Picker("Section separator", selection: $model.settings.segmentSeparator) {
                    ForEach(SegmentSeparator.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Explicit line breaks (only if test 6 showed separate rows)", isOn: $model.settings.captionLayout.explicitLineBreaks)
                Toggle("Clear the lens between answers", isOn: $model.settings.clearBetweenAnswers)
                Toggle("Show exact outgoing caption on the iPhone (debug)", isOn: $model.settings.showOutgoingCaption)
            } header: { Text("Caption session (experimental options)") } footer: {
                Text("Text density takes effect on the next Connect. Only font_size 2 and final captions have been seen working on the glasses; other values are untested. If the replace test shows captions appending, try turning “final” off.")
            }

            Section {
                Toggle("Start each pattern from a fresh caption session", isOn: $freshSessionPerPattern)
                Button("1 · Numbered lines (6 rows)") { send(CaptionCalibration.numberedLines(layout)) }
                Button("2 · Width ruler") { send(CaptionCalibration.ruler) }
                Button("3 · Replace test (A, then B after 2 s)") { replaceTest() }
                Button("4 · Sample answer, first window") { send(ReadingPlan(answer: CaptionCalibration.sampleAnswer, layout: layout).windows.first ?? "") }
                Button("5 · Junction test (ALPHA BRAVO, then CHARLIE DELTA)") { sequence([CaptionCalibration.junctionFirst, CaptionCalibration.junctionSecond]) }
                Button("6 · Newline test (three rows)") { send(CaptionCalibration.newlines) }
                Button("7 · Long then short (6 rows, then SHORT CAPTION)") { sequence([CaptionCalibration.numberedLines(layout), CaptionCalibration.shortCaption]) }
                Button("8 · Clear test (blank caption)") { Task { result = await model.clearTestCaption() } }
                Button("9 · End marker glyph test (✓ and [END])") { send(CaptionCalibration.endMarkerTest) }
                if let result { Text(result).font(.callout) }
            } header: { Text("Send test patterns to the glasses") } footer: {
                Text("""
                1: note which LINE numbers are fully visible, and whether the first or the last rows are missing. Each row is padded to your characters-per-line, so if one physical row shows two LINE labels, raise characters per line; if a label wraps, lower it.
                2: the last number fully shown on the first row is roughly the characters per line.
                3: if A is still visible after B appears, captions are appending instead of replacing.
                5: "BRAVOCHARLIE" or both captions visible means consecutive captions are joined; "CHARLIE DELTA" alone means clean replacement.
                6: three separate rows means line breaks are respected; "ROW ONEROW TWO" means they are dropped (keep Explicit line breaks off).
                7: if any LINE rows remain after SHORT CAPTION appears, shorter captions do not fully replace longer ones.
                9: if the check mark shows as a box, "?" or nothing, set End-of-Answer Indicator to ASCII [END].
                8: the lens should go blank (OpenRayneo's clear). Record what you see.
                """)
            }

            Section {
                Stepper("Lines fully visible: \(visibleLines)", value: $visibleLines, in: 1...7)
                Button("Use \(max(1, visibleLines - 1)) lines (one line of margin) and save") {
                    model.settings.captionLayout.maxLines = max(1, visibleLines - 1)
                    model.recordCalibration("\(visibleLines) lines fully visible on the lens")
                    result = "Saved: \(model.settings.captionLayout.maxLines) lines × \(model.settings.captionLayout.charactersPerLine) characters."
                }
                Button("Save current settings as calibrated") {
                    model.recordCalibration("settings confirmed on the lens")
                    result = "Saved."
                }
                Button("Restore defaults", role: .destructive) { model.settings.captionLayout = .standard }
            } header: { Text("Record what you saw") }

            Section {
                ForEach(Array(ReadingPlan(answer: CaptionCalibration.sampleAnswer, layout: layout).windows.enumerated()), id: \.offset) { index, window in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Window \(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        Text(layout.wrap(window).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black, in: .rect(cornerRadius: 6))
                    }
                }
            } header: { Text("Simulated layout of a sample answer") } footer: {
                Text("A simulation of the wrapping rules, not a picture of the lens. Only the glasses can confirm what is actually visible.")
            }
        }
        .navigationTitle("Caption Calibration")
        .onAppear { visibleLines = layout.maxLines + 1 }
    }

    /// Earlier patterns stack on the lens's caption transcript, so each one starts from a fresh session.
    private func send(_ text: String) {
        Task {
            if freshSessionPerPattern { result = await model.labResetSession() }
            result = await model.sendTestCaption(text, allowUnconfirmed: true)
        }
    }

    private func sequence(_ texts: [String]) {
        Task {
            if freshSessionPerPattern { result = await model.labResetSession() }
            for (index, text) in texts.enumerated() {
                if index > 0 { try? await Task.sleep(for: .seconds(2)) }
                result = await model.sendTestCaption(text, allowUnconfirmed: true)
            }
        }
    }

    private func replaceTest() {
        Task {
            if freshSessionPerPattern { result = await model.labResetSession() }
            result = await model.sendTestCaption(CaptionCalibration.replaceFirst, allowUnconfirmed: true)
            try? await Task.sleep(for: .seconds(2))
            result = await model.sendTestCaption(CaptionCalibration.replaceSecond, allowUnconfirmed: true)
        }
    }
}

/// Shows, before anything is sent, the exact caption strings the current settings produce for an answer:
/// one entry per frame, with spaces (·), blank padding rows (□) and row breaks (⏎) made visible.
struct FramePreviewView: View {
    let model: AppModel
    @State private var text = ""
    @State private var payloads: [String] = []

    var body: some View {
        let layout = model.settings.captionLayout
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 110).font(.callout)
                Button("Build frames") { Task { payloads = await model.presenter.previewPayloads(text, endMarker: model.settings.endMarker.text) } }
            } header: { Text("Answer text") } footer: {
                Text("\(model.settings.captionStrategy.label) · \(layout.maxLines) lines × \(layout.charactersPerLine) chars · \(model.settings.viewportRows) lens rows. Nothing is sent to the glasses.")
            }
            ForEach(Array(payloads.enumerated()), id: \.offset) { index, payload in
                let rows = payload.components(separatedBy: "\n")
                let textRows = rows.filter { !$0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\u{3000}"))).isEmpty }
                let longest = textRows.map { $0.trimmingCharacters(in: .whitespaces).count }.max() ?? 0
                Section("Caption \(index + 1) of \(payloads.count)") {
                    Text(CaptionLabView.visible(payload)).font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("Text rows", value: "\(textRows.count) (max \(layout.maxLines))")
                    LabeledContent("Longest row", value: "\(longest) chars (limit \(layout.charactersPerLine))")
                    LabeledContent("Payload", value: "\(payload.utf8.count) bytes")
                }
            }
        }
        .navigationTitle("Frame Preview")
        .onAppear { if text.isEmpty { text = model.engine.currentAnswer?.text ?? CaptionCalibration.sampleAnswer } }
    }
}

/// Calibrates the code frames on the RayNeo (rows, characters per row, indentation). Each pattern is sent
/// as one full frame from a fresh caption session; only what the wearer confirms on the lens is saved as
/// verified. Font size is not changed here (only caption font_size 2 has been seen working).
struct CodeDisplayCalibrationView: View {
    @Bindable var model: AppModel
    @State private var result: String?

    var body: some View {
        let layout = model.settings.codeLayout
        Form {
            Section {
                Stepper("Code rows: \(layout.rows)", value: $model.settings.codeLayout.rows, in: 1...8)
                Stepper("Characters per row: \(layout.charactersPerRow)", value: $model.settings.codeLayout.charactersPerRow, in: 20...80, step: 2)
                Stepper("Indent per level: \(layout.indentSpaces)", value: $model.settings.codeLayout.indentSpaces, in: 1...4)
                if layout.rows > model.settings.viewportRows {
                    Text("More rows than the \(model.settings.viewportRows) lens rows calibrated for captions: code uses \(model.settings.viewportRows) until Lens rows visible is raised (only if the lens really shows them).")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Verified on my RayNeo", isOn: Binding(get: { layout.verified }, set: { verified in
                    model.settings.codeLayout.verified = verified
                    model.settings.codeLayout.verifiedAt = verified ? Date() : nil
                }))
                if let date = layout.verifiedAt { Text("Verified \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            } header: { Text("Code layout") } footer: {
                Text("Explanations keep their own layout (Caption Calibration). Changing these values un-verifies nothing automatically: re-run the patterns after any change.")
            }
            Section {
                Button("1 · Row ruler (\(layout.rows + 1) numbered code rows)") { send(rowRuler(layout.rows + 1)) }
                Button("2 · Width ruler with code symbols") { send(widthRuler(layout.charactersPerRow + 6)) }
                Button("3 · Indentation ladder") { send(["function outer() {", "  if (ready) {", "    for (const item of items) {", "      log(item);", "    }", "  }", "}"]) }
                Button("4 · Long line wrapping") { sendCode(#"const message = `User ${user.name} has ${items.length} items, total: ${formatCurrency(total, "CAD")}`;"#) }
                Button("5 · Replacement (frame A, then frame B)") { replacement() }
                Button("6 · Sample code page") { sendCode("function getActiveStudents(students) {\n  return students.filter(student => {\n    return student.status === \"active\";\n  });\n}") }
                if let result { Text(result).font(.callout) }
            } header: { Text("Test on the glasses") } footer: {
                Text("""
                1: note the highest row number fully visible; set Code rows to it (never more than you saw).
                2: the last complete group shows the safe characters per row; set it a little lower.
                3: check the steps are visibly indented; if spaces collapse, keep Indent per level at 2 anyway (the iPhone shows real indentation).
                4: the line must wrap at a comma or space with "» " and no character missing or joined.
                5: when B appears, nothing of A may remain.
                6: the page should look like code: one statement per row, quotes and brackets intact.
                """)
            }
        }
        .navigationTitle("Code Display Calibration")
    }

    private func rowRuler(_ count: Int) -> [String] {
        (1...max(1, count)).map { "\($0)| const row\($0) = items[\($0)];" }
    }

    private func widthRuler(_ length: Int) -> [String] {
        let digits = (1...length).map { $0 % 10 == 0 ? Character(String(($0 / 10) % 10)) : "." }
        let symbols = Array(String(repeating: "{}()[];=>\"'", count: length / 11 + 1).prefix(length))
        return [String(digits), String(symbols)]
    }

    private func sendCode(_ code: String) {
        let pages = CodePaginator.paginate(code, layout: model.settings.codeLayout).pages
        send(pages.first?.rows ?? [])
    }

    private func send(_ rows: [String]) {
        let text = GlassesPresenter.frame(rows, padding: max(1, model.settings.viewportRows - rows.count))
        Task {
            _ = await model.labResetSession()
            result = await model.sendTestCaption(text, allowUnconfirmed: true)
        }
    }

    private func replacement() {
        Task {
            _ = await model.labResetSession()
            result = await model.sendTestCaption(GlassesPresenter.frame(["FRAME A — if any of this stays,", "frames do not replace."], padding: 3), allowUnconfirmed: true)
            try? await Task.sleep(for: .seconds(2))
            result = await model.sendTestCaption(GlassesPresenter.frame(["FRAME B only."], padding: 4), allowUnconfirmed: true)
        }
    }
}
