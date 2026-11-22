import SwiftUI

/// One step of a Replacement Lab experiment. Only documented messages: caption text (status 0/1),
/// OpenRayneo's blank caption, and the verified session close/start.
enum LabStep: Equatable, Sendable {
    case caption(String, final: Bool)
    case blankRows(final: Bool)
    case openRayneoBlank
    case restartSession
    case frame([String])

    var title: String {
        switch self {
        case .caption(let text, let final): "\(final ? "Final" : "In-progress") caption: \(text.replacingOccurrences(of: "\n", with: " ⏎ "))"
        case .blankRows(let final): "\(final ? "Final" : "In-progress") blank rows (push old text out of view)"
        case .openRayneoBlank: "OpenRayneo blank caption (full-width blank in both fields)"
        case .restartSession: "Close and restart the caption session"
        case .frame(let lines): "Full frame: \(lines.first ?? "")…"
        }
    }
}

struct LabExperiment: Identifiable, Sendable {
    let id: String
    let title: String
    let question: String
    let steps: [LabStep]

    static let all: [LabExperiment] = {
        let long = (1...6).map { "LINE \($0) VISIBLE" }.joined(separator: " ")
        return [
            .init(id: "A", title: "Final → Final", question: "Does the second caption replace the first?",
                  steps: [.caption("ALPHA ONE TWO", final: true), .caption("BRAVO THREE FOUR", final: true)]),
            .init(id: "B", title: "In-progress → In-progress", question: "Does the second replace the first?",
                  steps: [.caption("CHARLIE FIVE SIX", final: false), .caption("DELTA SEVEN EIGHT", final: false)]),
            .init(id: "C", title: "Final → In-progress", question: "What happens to the final caption?",
                  steps: [.caption("ECHO NINE TEN", final: true), .caption("FOXTROT ELEVEN TWELVE", final: false)]),
            .init(id: "D", title: "In-progress → Final", question: "Does the final replace the in-progress text?",
                  steps: [.caption("GOLF ONE TWO", final: false), .caption("HOTEL THREE FOUR", final: true)]),
            .init(id: "E", title: "Blank rows → New caption", question: "Do blank rows clear everything earlier?",
                  steps: [.caption("OLD TEXT SHOULD DISAPPEAR", final: true), .blankRows(final: true), .caption("NEW CAPTION AFTER BLANK ROWS", final: true)]),
            .init(id: "E2", title: "OpenRayneo blank → New caption", question: "Does the documented blank clear the lens?",
                  steps: [.caption("OLD TEXT SHOULD DISAPPEAR", final: true), .openRayneoBlank, .caption("NEW CAPTION AFTER BLANK", final: true)]),
            .init(id: "F", title: "New session → New caption", question: "Does a session restart give a clean lens, and does the link stay up?",
                  steps: [.caption("BEFORE RESTART", final: true), .restartSession, .caption("AFTER RESTART", final: true)]),
            .init(id: "G", title: "Short → Long → Short (final)", question: "Are earlier lines retained?",
                  steps: [.caption("SHORT ONE", final: true), .caption(long, final: true), .caption("SHORT TWO", final: true)]),
            .init(id: "G2", title: "Short → Long → Short (in-progress)", question: "Are earlier lines retained?",
                  steps: [.caption("SHORT ONE", final: false), .caption(long, final: false), .caption("SHORT TWO", final: false)]),
            .init(id: "N", title: "Explicit newlines", question: "Are ROW ONE, TWO, THREE on separate rows?",
                  steps: [.caption("ROW ONE\nROW TWO\nROW THREE", final: true)]),
            .init(id: "S", title: "Separators between appended captions", question: "Which joins keep a visible gap?",
                  steps: [.caption("SEGMENT ONE ends", final: true), .caption(" SEGMENT TWO normal space", final: true), .caption("\u{3000}SEGMENT THREE full-width space", final: true)]),
            .init(id: "X", title: "Full frames (OpenRayneo technique)", question: "Is ONLY the newest frame visible after each step?",
                  steps: [.frame(["FRAME ONE row 1", "FRAME ONE row 2", "FRAME ONE row 3", "FRAME ONE row 4"]),
                          .frame(["FRAME TWO row 1", "FRAME TWO row 2", "FRAME TWO row 3", "FRAME TWO row 4"]),
                          .frame(["FRAME THREE row 1", "FRAME THREE row 2"])]),
        ]
    }()
}

enum LabObservation: String, CaseIterable, Identifiable, Sendable {
    case onlyThis = "Only this step's text"
    case stacked = "This plus earlier text"
    case joined = "Words joined together"
    case blank = "Lens is blank"
    case noChange = "No change"
    case other = "Something else / unclear"
    var id: String { rawValue }
}

/// Guided, step-by-step physical test. Each experiment starts from a fresh caption session (clean state),
/// steps are sent only when you tap, and the next step unlocks after you record what is visible.
struct CaptionLabView: View {
    @Bindable var model: AppModel
    @State private var selected = LabExperiment.all[0].id
    @State private var nextStep = 0
    @State private var busy = false
    @State private var sentText: String?
    @State private var status = ""
    @State private var awaitingObservation = false
    @State private var observations: [String: LabObservation] = [:]

    private var experiment: LabExperiment { LabExperiment.all.first { $0.id == selected }! }

    var body: some View {
        Form {
            Section {
                Text("Connect in Caption mode and wear the glasses. Wait at least 3 seconds between steps. Record what is physically visible after every step: a successful send does not mean it displayed correctly.")
                    .font(.callout)
                Toggle("Log caption text for these tests (test-only)", isOn: $model.settings.logLabCaptionText)
            }
            Section("Experiment") {
                Picker("Experiment", selection: $selected) {
                    ForEach(LabExperiment.all) { Text("\($0.id) · \($0.title)").tag($0.id) }
                }
                .onChange(of: selected) { reset() }
                Text(experiment.question).font(.callout.weight(.semibold))
                Button(busy ? "Working…" : "1 · Reset to a clean caption session") { startClean() }
                    .disabled(busy)
                ForEach(Array(experiment.steps.enumerated()), id: \.offset) { index, step in
                    HStack {
                        Text("\(index + 2) · \(step.title)").font(.caption)
                        Spacer()
                        if let observation = observations["\(experiment.id)-\(index)"] {
                            Text(observation.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(nextStep < experiment.steps.count ? "Send step \(nextStep + 2)" : "Experiment complete") { send() }
                    .disabled(busy || awaitingObservation || nextStep >= experiment.steps.count)
            }
            if let sentText {
                Section("Exact text just sent") {
                    Text(Self.visible(sentText)).font(.caption.monospaced()).textSelection(.enabled)
                    Text("· = space, □ = full-width space, ⏎ = line break").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if awaitingObservation {
                Section("What do you see on the lens now?") {
                    ForEach(LabObservation.allCases) { option in
                        Button(option.rawValue) { record(option) }
                    }
                }
            }
            if !status.isEmpty { Section { Text(status).font(.caption) } }
            Section("Recommendation") {
                Text(recommendation.reason).font(.callout)
                Button("Apply: \(recommendation.strategy.label)") {
                    model.settings.captionStrategy = recommendation.strategy
                    if observations["X-1"] == .onlyThis, observations["X-2"] == .onlyThis { model.settings.framesReplaceVerified = true }
                    model.recordCalibration("Lab recommendation applied: \(recommendation.strategy.rawValue)")
                }
            }
            Section("H · Caption record identifiers") {
                Text("Not testable: the only identifier the documented 0x13 caption messages carry is the session ID (sid), which every step here reuses. No record ID or replacement field is documented, so none is sent.")
                    .font(.caption)
            }
        }
        .navigationTitle("Caption Replacement Lab")
    }

    static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "·")
            .replacingOccurrences(of: "\u{3000}", with: "□")
            .replacingOccurrences(of: "\n", with: "⏎\n")
    }

    private var recommendation: (strategy: CaptionStrategy, reason: String) {
        if observations["X-1"] == .onlyThis, observations["X-2"] == .onlyThis {
            return (.sentenceFrames, "Only the newest frame was visible (X): Sentence Frames show one complete 3–4 line frame at a time (Full-Frame Scrolling is the line-by-line variant).")
        }
        if observations["B-1"] == .onlyThis, observations["G2-2"] == .onlyThis {
            return (.rollingInProgress, "In-progress captions replaced cleanly (B, G2): one-line rolling with in-progress updates.")
        }
        return (.stableSections, "Full frames (X) are not confirmed yet: Stable Sections stay readable on an appending transcript even if line breaks are ignored.")
    }

    private func reset() {
        nextStep = 0
        sentText = nil
        awaitingObservation = false
        status = ""
    }

    private func startClean() {
        busy = true
        reset()
        Task {
            status = await model.labResetSession()
            busy = false
        }
    }

    private func send() {
        let step = experiment.steps[nextStep]
        busy = true
        Task {
            let outcome = await model.runLabStep(step, experiment: experiment.id, index: nextStep)
            sentText = outcome.text
            status = outcome.status
            awaitingObservation = outcome.sent
            busy = false
        }
    }

    private func record(_ observation: LabObservation) {
        observations["\(experiment.id)-\(nextStep)"] = observation
        model.recordCalibration("Lab \(experiment.id) step \(nextStep + 2) (\(experiment.steps[nextStep].title)): \(observation.rawValue)")
        awaitingObservation = false
        nextStep += 1
    }
}
