import Foundation

/// The explicit conversation state machine required by the spec (see ARCHITECTURE.md).
enum ConversationState: Equatable, Sendable {
    case idle
    case listening
    case questionDetected
    case generating
    case displayingAnswer
    case answerLocked
    case waitingForNextQuestion
    case error(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listening"
        case .questionDetected: "Question detected"
        case .generating: "Thinking…"
        case .displayingAnswer: "Displaying answer"
        case .answerLocked: "Answer locked"
        case .waitingForNextQuestion: "Waiting for next question"
        case .error(let message): "Error: \(message)"
        }
    }
}

struct TranscriptSegment: Identifiable, Equatable, Sendable {
    let id = UUID()
    var text: String
    /// Seconds on the capture timeline (frames / sample rate since the session started).
    var start: Double
    var end: Double
    var speaker: SpeakerLabel = .unknown
}

struct InterviewQuestion: Equatable, Sendable {
    var text: String
    /// Deterministic score in 0...1 from `QuestionDetector`; not a probability.
    var score: Double
    var isFollowUp: Bool
    var reason: String
    var detectedAt: Date
}

/// One immutable identity per answer, issued when its question is accepted and carried unchanged by the
/// pipeline output, the answer lock, every caption write of the presenter and the reading alignment.
@MainActor enum AnswerIdentity {
    private static var last = 0
    static func next() -> Int {
        last += 1
        return last
    }
}

struct InterviewAnswer: Equatable, Sendable {
    var answerID = 0
    var question: String
    var text: String
    var fromCache: Bool
    var firstTokenSeconds: Double?
    var totalSeconds: Double
    var createdAt: Date
    var category: QuestionCategory = .technical
    var routeMilliseconds: Double = 0
    var validation = "n/a"
    var regenerated = false
    var firstSentenceSeconds: Double?
    var earlyFrameSeconds: Double?
    var provider = ""
    /// The provider finished normally and the final answer passed validation (end marker eligible).
    var generationComplete = false
    /// "complete", "truncated (MAX_TOKENS)", "ends mid-sentence", "validation failed", …
    var completion = ""
    /// Seconds from question to the first caption of this answer handed to Bluetooth (not proof of visibility).
    var frameSubmittedSeconds: Double?
    var snippet: CodeSnippet?
    /// Guided EXPLAIN → CODE → … walkthrough for a coding answer (same answer ID).
    var walkthrough: CodingWalkthrough?
    /// What kind of speech produced the question (new question, follow-up, clarification…).
    var kind: SpeechEventKind = .newQuestion
}

enum SessionPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case practice, live
    var id: String { rawValue }
    var label: String { self == .practice ? "Practice (simulation)" : "Live (everyone has consented)" }
}

enum EndMarkerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case checkmark, ascii, off
    var id: String { rawValue }
    var text: String? {
        switch self {
        case .checkmark: "\u{2713}"
        case .ascii: "[END]"
        case .off: nil
        }
    }
    var label: String {
        switch self {
        case .checkmark: "Checkmark ✓ (default)"
        case .ascii: "ASCII [END] (if ✓ does not render)"
        case .off: "Off"
        }
    }
}

enum SpeakerLabel: String, Codable, Sendable {
    case wearer, interviewer, unknown
}

/// Measured features plus the rule that produced the label. No synthetic probabilities.
struct SpeakerEvidence: Equatable, Sendable {
    var label: SpeakerLabel
    var medianPitchHz: Double?
    var medianLevelDB: Double?
    var voicedSeconds: Double
    var reason: String

    static let unknown = SpeakerEvidence(label: .unknown, medianPitchHz: nil, medianLevelDB: nil, voicedSeconds: 0, reason: "No speaker evidence")
}

/// A completed interviewer/wearer speech turn, produced by `TurnDetector`.
/// A finalized utterance as shown in the app (original recognition and the normalised interpretation).
struct FinalizedTurn: Identifiable, Equatable, Sendable {
    let id: Int
    var original: String
    var normalized: String
    var revision: Int
}

struct CompletedTurn: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var speaker: SpeakerEvidence = .unknown
    /// Stable ID from the transcript assembler (nil for turns from tests or tools).
    var turnID: Int?
    /// A later version of an already-handled turn (late correction or completed fragment).
    var isRevision = false
}

enum AnswerLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case short, standard, detailed
    var id: String { rawValue }
    /// Guidance, not a quota: substance decides, and complex topics may use the longer range.
    var sentences: String {
        switch self {
        case .short: "about 2 to 3 sentences for a straightforward question and up to 5 when the topic needs it"
        case .standard: "about 3 to 5 sentences for a straightforward question, and 6 to 9 or more when a complex topic needs it to be explained properly"
        case .detailed: "6 to 9 sentences, or more when the topic needs it"
        }
    }
    var maximumTokens: Int {
        switch self {
        case .short: 200
        case .standard: 380
        case .detailed: 560
        }
    }
}

enum AIModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, appleOnDevice, geminiFlash, gemmaOnDevice, disabled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto (on-device)"
        case .appleOnDevice: "Apple On-Device"
        case .geminiFlash: "Gemini Flash (cloud)"
        case .gemmaOnDevice: "Gemma On-Device"
        case .disabled: "Off (math and clarifications only)"
        }
    }
}

enum GlassesTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case simulator, rayNeoExperimental
    var id: String { rawValue }
    var label: String { self == .simulator ? "In-app simulator" : "RayNeo iO (experimental BLE)" }
}

/// How answer text is delivered to the 0x13 caption session.
/// Photos from an iO-E081 show that consecutive FINAL captions stack like transcript entries and are
/// joined without a separator, so overlapping rolling windows duplicate text and glue words together.
enum CaptionStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Default. Non-overlapping, sentence-aware frames of 3–4 lines, each sent as ONE caption laid out as a
    /// full frame (blank padding row(s), then the frame's lines). Every row break is preceded by a space, so
    /// even if the lens ignored line breaks no two words could touch. Advances on reading progress.
    case sentenceFrames
    /// Non-overlapping, sentence-aware segments with a leading separator space: readable whether the
    /// firmware replaces or appends. Advances only on confirmed reading (or manually).
    case stableSections
    /// One-line rolling windows sent as IN-PROGRESS captions (status 0), which caption UIs typically update
    /// in place. Use only after the Replacement Lab shows in-progress captions replace cleanly.
    case rollingInProgress
    /// One-line rolling windows sent as final captions. Stacks on iO-E081; kept for comparison only.
    case rollingFinal
    /// OpenRayneo's full-frame technique for an appending caption transcript: every update is a row break,
    /// blank rows, then the window's lines joined by "\n", so the lens's visible tail is exactly the current
    /// window. Needs the Lab to confirm that "\n" starts a new row.
    case fullFrames

    var id: String { rawValue }
    var label: String {
        switch self {
        case .sentenceFrames: "Sentence Frames (default)"
        case .stableSections: "Stable Sections"
        case .rollingInProgress: "Experimental In-Progress Rolling"
        case .rollingFinal: "Rolling lines, final (stacks on iO-E081)"
        case .fullFrames: "Full-Frame Scrolling (one line at a time)"
        }
    }
    var allowsLineScrolling: Bool { self == .rollingInProgress || self == .rollingFinal || self == .fullFrames }
    var usesFrames: Bool { self == .fullFrames || self == .sentenceFrames }
    /// Styles offered in the UI (rolling-final stays decodable but is not offered).
    static var selectable: [CaptionStrategy] { [.sentenceFrames, .stableSections, .fullFrames, .rollingInProgress] }
    var finalStatus: Bool { self != .rollingInProgress }
    var appendSafe: Bool { self == .stableSections }
}

enum SegmentSeparator: String, Codable, CaseIterable, Identifiable, Sendable {
    case space, fullWidthSpace
    var id: String { rawValue }
    var text: String { self == .space ? " " : "\u{3000}" }
    var label: String { self == .space ? "Normal space" : "Full-width space (OpenRayneo padding)" }
}

/// RayNeo display session type. Separate implementations; caption is the default because it is the
/// session type reported working from an iPhone over CoreBluetooth (b-d.io) and is fully specified in OpenRayneo.
enum DisplaySessionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case caption, prompt
    var id: String { rawValue }
    var label: String { self == .caption ? "Caption session (0x13)" : "Real-time prompt (0x17, \"conversation\")" }
}

struct WearerProfile: Codable, Equatable, Sendable {
    var medianPitchHz: Double
    var medianLevelDB: Double
    var voicedSeconds: Double
    var createdAt: Date
}

enum GeminiModel: String, CaseIterable, Identifiable, Sendable {
    case flashLite = "gemini-3.5-flash-lite"
    case flash36 = "gemini-3.6-flash"
    case flash38 = "gemini-3.8-flash"
    var id: String { rawValue }
}

struct AppSettings: Codable, Equatable, Sendable {
    /// Bumped when defaults change in a way that should migrate untouched old defaults.
    var settingsVersion = 3
    /// Decodes saved settings over the defaults, so fields added in later versions never reset the rest.
    static func decodeMerged(_ data: Data) -> AppSettings? {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new }) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: merged)
    }

    var localeIdentifier = "en-US"
    var preferredInputUID: String?
    /// Minimum `QuestionDetector` score that counts as a question. Lower = more sensitive.
    var questionThreshold = 0.5
    var endOfTurnSilence = 1.2
    var autoQuestionDetection = true
    var semanticClassification = true
    var speakerFilterEnabled = true
    /// Pitch distance (semitones) within which a turn is attributed to the calibrated wearer.
    var wearerPitchTolerance = 2.5
    /// Transcript-vs-displayed-answer overlap at or above which a turn is treated as the wearer reading.
    var echoThreshold = 0.5
    var answerLength: AnswerLength = .standard
    var aiModel: AIModelChoice = .auto
    var lockAfterDisplay = true
    var autoAdvance = true
    var autoAdvanceMinScore = 0.8
    /// Anti-oscillation cooldown: a confident question never replaces an answer shown less than this ago.
    var minimumLockSeconds = 2.0
    var glassesTarget: GlassesTarget = .simulator
    /// Line-aware caption layout, calibrated on the device (Settings › Caption calibration).
    var captionLayout = CaptionLayout.standard
    var glassesSessionMode: DisplaySessionMode = .caption
    /// Experimental: allow text writes when the glasses never acknowledged the display session.
    var allowUnconfirmedGlassesSend = false
    /// Manual is the safe default until speech-synced reading is verified on hardware.
    var readingMode: ReadingMode = .manual
    /// How much speech evidence Speech-Synced Reading needs before scrolling a line.
    var readingResponsiveness: ReadingResponsiveness = .balanced
    var captionStrategy: CaptionStrategy = .sentenceFrames
    /// Close and reopen the caption session for every new answer, so no earlier transcript can remain.
    var restartCaptionSessionPerAnswer = false
    /// Seconds to wait for a caption-start acknowledgement before treating the session as unconfirmed.
    var captionStartWait = 8.0
    /// Test-only: write the Replacement Lab's caption text into the diagnostic log.
    var logLabCaptionText = false
    /// Rows the lens shows at once (photo of an iO-E081: about 5). Used for frames and blank-row clears.
    var viewportRows = 5
    /// Separator before each appended stable section.
    var segmentSeparator: SegmentSeparator = .space
    /// Gemini (cloud) — off until the user opts in. The API key lives in the Keychain, never in settings.
    var geminiConsent = false
    /// Verified free-tier model identifiers (AI Studio pricing page, November 2026).
    var geminiModel = GeminiModel.flashLite.rawValue
    var geminiFallbackToApple = true
    /// The portfolio stays on the device unless this is turned on.
    var geminiIncludePortfolio = false
    /// Show the first complete frame of a streamed answer before generation finishes.
    var earlyFirstFrame = true
    /// Subtle marker after the final sentence of a successfully completed answer (rendered, never in the text).
    var endMarker = EndMarkerStyle.checkmark
    /// Lab X confirmed that a new full-frame caption hides the previous one on this lens. Only then may
    /// Sentence Frames use overlapping look-ahead windows; otherwise frames never overlap.
    var framesReplaceVerified = false
    /// Continuous conversation: classify every turn (follow-ups, clarifications, corrections…) and move to
    /// follow-up answers automatically. Opt-in.
    var continuousConversation = false
    /// Personal memory (profile and projects) is used in prompts.
    var personalMemoryEnabled = true
    /// Keep the session's earlier exchanges (otherwise only the latest, for follow-ups).
    var conversationRetention = true
    /// Show a code snippet on the glasses, per frame, for this many seconds.
    var codeSnippetSeconds = 20.0
    var sessionPurpose = SessionPurpose.practice
    /// How code answers appear on the glasses.
    var codeDisplay = CodeSnippetController.Mode.tutor
    /// Guided walkthrough: seconds before a code block advances by itself (0 = only on Next / "next step").
    var walkthroughCodeSeconds = 0.0
    /// Hands-free walkthrough: how much evidence moves to the next block (Off = manual only).
    var adaptiveWalkthrough = AdaptiveWalkthroughMode.balanced
    /// Code frames' own layout, confirmed with Settings › Code Display Calibration.
    var codeLayout = CodeDisplayLayout()
    /// Coding Skeleton Mode: a validated code outline before the walkthrough.
    var codingSkeleton = true
    /// Allow the paired VS Code companion to connect (encrypted; trusted editors only).
    var editorLinkEnabled = false
    /// Show raw vs normalised transcript text in the app and diagnostics (private; off by default).
    var transcriptDebug = false
    /// Look-ahead (overlapping) windows: Sentence Frames on a lens verified to replace full frames.
    var lookaheadWindows: Bool { captionStrategy == .sentenceFrames && framesReplaceVerified }
    /// A frame already on the lens may be replaced in place (full frames + Lab X verified).
    var inPlaceReplacement: Bool { captionStrategy.usesFrames && framesReplaceVerified }
    /// Blank the lens (OpenRayneo's verified blank caption) before a new answer replaces an older one.
    var clearBetweenAnswers = true
    /// Opt-in: show the exact outgoing caption text on the iPhone (local only, never exported).
    var showOutgoingCaption = false
    var cacheAnswers = true
    var debugLogging = false
    var wearerProfile: WearerProfile?
}
