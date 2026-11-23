import Foundation

nonisolated enum SpeechEventKind: String, Codable, CaseIterable, Sendable {
    case newQuestion, followUp, clarification, correction, instruction, readingAnswer, userResponse, general, uncertain
    /// A new programming instruction ("Write a function…", "Implement an endpoint…").
    case codingRequest
    /// Implementation, modification, explanation or test of the active programming task.
    case codingFollowUp

    var label: String {
        switch self {
        case .newQuestion: "New question"
        case .followUp: "Follow-up"
        case .clarification: "Clarification"
        case .correction: "Correction"
        case .instruction: "Interviewer instruction"
        case .readingAnswer: "Reading the answer"
        case .userResponse: "Your own explanation"
        case .codingRequest: "Coding request"
        case .codingFollowUp: "Coding follow-up"
        case .general: "General conversation"
        case .uncertain: "Uncertain"
        }
    }

    /// Kinds that ask for an answer.
    var wantsAnswer: Bool { [.newQuestion, .followUp, .clarification, .correction, .codingRequest, .codingFollowUp].contains(self) }
    /// Continues the active discussion (answered with the previous exchange as context).
    var continuesDiscussion: Bool { [.followUp, .clarification, .correction, .codingFollowUp].contains(self) }
}

nonisolated struct SpeechClassification: Equatable, Sendable {
    enum Tier: String, Sendable { case high, medium, low }
    var kind: SpeechEventKind
    /// Rule tally in 0...1 (not a probability).
    var confidence: Double
    /// Content-word overlap with the active discussion (0...1).
    var relatedness: Double
    var reason: String

    var tier: Tier { confidence >= 0.8 ? .high : confidence >= 0.55 ? .medium : .low }
}

/// Classifies one completed speech turn in the context of the active discussion. Deterministic rules
/// over the existing signals: echo of the displayed answer, speaker estimate, question score,
/// follow-up / clarification / correction phrasing and relatedness to the current topic. A single
/// iPhone microphone cannot reliably tell speakers apart, so an unknown speaker never raises confidence.
nonisolated enum SpeechEventClassifier {
    static let followUpStarts = ["what about", "how about", "what if", "why did you", "why would you", "why not", "okay but", "ok but",
                                 "okay, but", "ok, but", "but how", "but what", "but why", "and how", "and what", "and why", "so how",
                                 "so what", "then what", "how would you actually", "how would you scale", "can you show", "show me an example",
                                 "could you show", "what happens if", "what happens when", "would that", "does that", "is that", "and if"]
    static let clarificationCues = ["explain that further", "explain that", "explain it", "what do you mean", "elaborate", "say more",
                                    "go deeper", "can you clarify", "more detail", "unpack that", "expand on", "say that again",
                                    "walk me through that", "tell me more"]
    static let shortFollowUps: Set<String> = ["why", "why?", "how so", "how so?", "why's that", "like what", "such as", "for example",
                                              "how come", "meaning", "and then", "really", "in what way"]
    static let correctionStarts = ["no,", "no i meant", "no, i meant", "actually,", "actually i meant", "sorry, i meant", "i meant",
                                   "not that", "i said", "that's not what i asked", "that's not what i meant", "let me rephrase", "i was asking"]
    static let instructionCues = ["take your time", "go ahead", "let's move on", "moving on", "next question", "let me ask you",
                                  "let's switch", "let's talk about", "keep going", "you can start", "whenever you're ready"]
    static let anaphora: Set<String> = ["that", "it", "this", "those", "these", "there", "they", "them"]
    /// Request wording that says nothing about the subject ("tell me about…", "can you talk about…").
    static let requestFiller: Set<String> = ["tell", "talk", "describe", "explain", "walk", "show", "give", "share", "please", "about",
                                             "little", "bit", "more", "can", "could", "would", "you", "me", "us", "your", "the", "a", "an", "now", "project", "projects"]

    static func classify(_ text: String, question: InterviewQuestion, echoOverlap: Double, echoThreshold: Double,
                         speaker: SpeakerLabel, questionThreshold: Double, topicText: String, hasActiveAnswer: Bool,
                         codingTask: ActiveCodingTask? = nil) -> SpeechClassification {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        // Relatedness of the subject only: "Now tell me about Diskarte" shares "tell" with any earlier request.
        let subject = TextSimilarity.contentWords(text).filter { !requestFiller.contains($0.lowercased()) }.joined(separator: " ")
        let related = topicText.isEmpty || subject.isEmpty ? 0 : TextSimilarity.containment(subject, in: topicText)
        func result(_ kind: SpeechEventKind, _ confidence: Double, _ reason: String) -> SpeechClassification {
            // Unknown speaker: never more than medium on its own; the interviewer label adds a little.
            var value = confidence + (speaker == .interviewer ? 0.05 : 0)
            if speaker == .unknown, kind.wantsAnswer, question.score < questionThreshold { value = min(value, 0.79) }
            return SpeechClassification(kind: kind, confidence: min(1, max(0, value)), relatedness: related, reason: reason)
        }

        // 1. The wearer reading the displayed answer aloud is never a question.
        if echoOverlap >= echoThreshold { return result(.readingAnswer, echoOverlap, String(format: "matches displayed answer %.2f", echoOverlap)) }
        // 2. The calibrated wearer voice is the user's own response.
        if speaker == .wearer { return result(.userResponse, 0.7, "wearer voice") }
        if words.isEmpty { return result(.general, 0, "empty") }

        let starts = { (cues: [String]) in cues.contains { lower.hasPrefix($0) } }
        let contains = { (cues: [String]) in cues.contains { lower.contains($0) } }

        // Programming instructions are often imperatives without a question mark.
        if CodingLanguage.isNewTask(text) {
            return result(.codingRequest, max(0.85, question.score), "programming instruction")
        }
        // The candidate talking through their own approach is not a question.
        if hasActiveAnswer || codingTask != nil, CodingLanguage.isApproach(text), question.score < questionThreshold {
            return result(.userResponse, 0.65, "your own explanation")
        }
        if let codingTask, let kind = CodingLanguage.followUp(text, task: codingTask) {
            return result(.codingFollowUp, 0.8 + 0.1 * question.score, "\(kind.label) of the active coding task")
        }
        if hasActiveAnswer, starts(correctionStarts) {
            return result(.correction, 0.8 + 0.2 * question.score, "correction phrasing")
        }
        if contains(instructionCues), question.score < questionThreshold {
            return result(.instruction, 0.6, "interviewer instruction")
        }
        if hasActiveAnswer {
            if shortFollowUps.contains(lower.trimmingCharacters(in: .punctuationCharacters)) {
                return result(.clarification, 0.7, "short follow-up")
            }
            if contains(clarificationCues) {
                return result(.clarification, 0.65 + 0.25 * min(1, question.score + related), "clarification phrasing")
            }
            let cue = starts(followUpStarts) || question.isFollowUp
            // A fully specified request ("Explain how you'd secure a Next.js app with Supabase Auth and RLS…") is a
            // new question even when it shares the topic's words; only short or referring requests continue it.
            let ownSubject = TextSimilarity.contentWords(text).filter { !requestFiller.contains($0.lowercased()) }.count
            let selfContained = ownSubject >= 5 && !ContextReference.detect(text).refersBack
            let refers = !selfContained && words.contains { anaphora.contains($0) } && question.score >= 0.4
            if cue || refers || (!selfContained && related >= 0.25 && question.score >= questionThreshold) {
                let confidence = 0.45 + (cue ? 0.25 : 0) + (refers ? 0.1 : 0) + 0.2 * related + 0.2 * question.score
                return result(.followUp, confidence, [cue ? "follow-up phrasing" : nil, refers ? "refers back" : nil,
                                                      related >= 0.25 ? String(format: "related %.2f", related) : nil].compactMap { $0 }.joined(separator: ", "))
            }
        }
        if question.score >= questionThreshold {
            // A request phrased as an instruction from its first word ("Tell me about…") is unambiguous.
            let instruction = question.reason.contains("request phrased as instruction") || question.reason.contains("actionable intent")
            return result(.newQuestion, instruction ? max(question.score, 0.8) : question.score, question.reason)
        }
        if question.score >= questionThreshold - 0.2 { return result(.uncertain, question.score, "borderline question (\(question.reason))") }
        return result(.general, 0.2, "no question cues")
    }
}

/// The conversation's explicit phases. Pure reducer: deterministic and testable; the engine records
/// every transition (diagnostics) while its proven answer-lock logic keeps deciding what is shown.
nonisolated enum ConversationPhase: String, CaseIterable, Sendable {
    case idle, listening, questionDetected, generating, answerReady, reading, followUpDetected, followUpGenerating,
         transitioning, codeDisplay, completed, error

    enum Event: Equatable, Sendable {
        case start, stop, question(followUp: Bool), generationStarted, answerShown, readingStarted, readingCompleted,
             transition, codeShown, codeEnded, failed, cancelled
    }

    func next(_ event: Event) -> ConversationPhase {
        switch (self, event) {
        case (_, .stop): .idle
        case (.idle, .start): .listening
        case (.idle, _): .idle
        case (_, .start): self
        case (_, .failed): .error
        case (_, .question(let followUp)): followUp && [.answerReady, .reading, .completed, .codeDisplay, .followUpGenerating, .generating].contains(self) ? .followUpDetected : .questionDetected
        case (.followUpDetected, .generationStarted), (.followUpGenerating, .generationStarted): .followUpGenerating
        case (_, .generationStarted): .generating
        case (.followUpGenerating, .answerShown), (.transitioning, .answerShown): .answerReady
        case (_, .transition): .transitioning
        case (_, .answerShown): .answerReady
        case (.answerReady, .readingStarted): .reading
        case (.reading, .readingCompleted), (.answerReady, .readingCompleted): .completed
        case (_, .codeShown): .codeDisplay
        case (.codeDisplay, .codeEnded): .answerReady
        case (.generating, .cancelled), (.followUpGenerating, .cancelled), (.questionDetected, .cancelled), (.followUpDetected, .cancelled): .listening
        case (.error, _): .error
        default: self
        }
    }
}
