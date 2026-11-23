import Foundation

/// What an interviewer's utterance asks for, independent of punctuation: questions, imperatives ("Design…",
/// "Explain…", "Compare…"), problem scenarios ("Our API is returning 500s") and behavioural prompts all count.
/// Deterministic rules (no model call); confidence is a rule tally, not a probability, and the rules are not
/// perfect: borderline cases still go through the engine's threshold and on-device semantic check.
nonisolated struct InterviewIntent: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case question, explanation, comparison, troubleshooting, systemDesign, coding, architecture, security, behavioural,
             situational, followUp
        /// Not actionable on their own.
        case smallTalk, incomplete, statement

        var actionable: Bool { ![.smallTalk, .incomplete, .statement].contains(self) }
        var label: String {
            switch self {
            case .systemDesign: "system design"
            case .followUp: "follow-up"
            case .smallTalk: "small talk / logistics"
            default: rawValue
            }
        }
    }

    var kind: Kind
    var confidence: Double
    var reason: String
    /// Explicit constraints the interviewer stated ("handle worker crashes", "without losing jobs").
    var requirements: [String] = []
    /// Separate tasks of a multi-part request ("design it", "explain the trade-offs", "describe testing").
    var parts: [String] = []
    /// A scenario was set up but its task has not been stated yet: the endpoint waits a little longer.
    var awaitingTask = false

    var actionable: Bool { kind.actionable }

    // MARK: Classification

    static func classify(_ raw: String, hasContext: Bool = false) -> InterviewIntent {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = Self.sentences(text)
        guard !sentences.isEmpty else { return InterviewIntent(kind: .statement, confidence: 0, reason: "empty") }
        if !text.hasSuffix("?"), TranscriptTurnAssembler.isIncomplete(text) {
            return InterviewIntent(kind: .incomplete, confidence: 0, reason: "ends mid-phrase")
        }
        let perSentence = sentences.map { classifySentence($0, hasContext: hasContext) }
        let requirements = Self.requirements(in: text)
        let parts = Self.parts(in: text)
        let actionable = perSentence.filter(\.actionable)
        guard var best = actionable.max(by: { $0.confidence < $1.confidence }) else {
            if perSentence.contains(where: { $0.kind == .smallTalk }) {
                return InterviewIntent(kind: .smallTalk, confidence: 0, reason: "small talk / logistics only")
            }
            return InterviewIntent(kind: .statement, confidence: 0, reason: "no actionable request")
        }
        // A scenario followed by its task ("…loses internet during an exam. Explain your approach.") is one request.
        let scenario = perSentence.first { $0.kind == .situational || $0.kind == .troubleshooting && $0.awaitingTask }
        let task = actionable.last { !$0.awaitingTask }
        if let scenario, let task, scenario != task {
            let kind = [.explanation, .question, .troubleshooting].contains(task.kind) ? scenario.kind : task.kind
            best = InterviewIntent(kind: kind, confidence: max(0.85, task.confidence), reason: "scenario + task (\(task.reason))")
        } else if let task, best.awaitingTask {
            best = task
        }
        // A design or coding task stated after other sentences still decides the kind.
        if let strongest = actionable.first(where: { [.systemDesign, .coding].contains($0.kind) }), !best.awaitingTask {
            best.kind = strongest.kind
        }
        best.requirements = requirements
        best.parts = parts.count >= 2 ? parts : []
        best.awaitingTask = actionable.allSatisfy(\.awaitingTask)
        if best.parts.count >= 2 {
            best.reason += ", \(best.parts.count) parts"
            best.confidence = max(best.confidence, 0.85) // a multi-part task is unambiguous
        }
        return best
    }

    private static func classifySentence(_ sentence: String, hasContext: Bool) -> InterviewIntent {
        let lower = sentence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let core = stripLeadIns(lower)
        let words = core.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "/") }).map(String.init)
        func intent(_ kind: Kind, _ confidence: Double, _ reason: String, awaiting: Bool = false) -> InterviewIntent {
            InterviewIntent(kind: kind, confidence: confidence, reason: reason, awaitingTask: awaiting)
        }
        // Lead-ins ("Okay, so…") are stripped, so anchored patterns see the request itself.
        func has(_ pattern: String) -> Bool { core.range(of: pattern, options: .regularExpression) != nil }
        guard let first = words.first else { return intent(.statement, 0, "empty") }

        if isSmallTalk(lower, words: words) { return intent(.smallTalk, 0, "small talk / logistics") }
        let politeRequest = has(#"^(i'?d like you to|i want you to|i'?d like to see you|i'?d like to hear|i want to hear|i'?d love to hear)\b"#)
        // The candidate's own voice ("I'd use a queue…") is not a request.
        if !politeRequest, isFirstPerson(core) { return intent(.statement, 0, "first person") }

        let second = words.dropFirst().first ?? ""
        let determiners: Set<String> = ["a", "an", "the", "me", "us", "your", "our", "my", "how", "what", "why", "when", "this", "that",
                                        "these", "those", "it", "some", "one", "two", "three", "each", "every", "its", "their", "any", "all", "out", "up"]
        let unambiguous: Set<String> = ["explain", "describe", "compare", "define", "outline", "summarize", "summarise", "discuss",
                                        "implement", "write", "contrast", "elaborate", "diagnose", "troubleshoot", "investigate", "architect"]
        let ambiguous: Set<String> = ["design", "build", "create", "fix", "debug", "show", "walk", "talk", "take", "go", "tell", "give",
                                      "list", "plan", "sketch", "propose", "suggest", "recommend", "set", "configure", "secure", "restore",
                                      "optimize", "optimise", "refactor", "review", "model", "migrate", "handle", "test", "code", "solve", "find", "make", "reverse", "sort", "remove"]
        let imperative = unambiguous.contains(first) || (ambiguous.contains(first) && (determiners.contains(second) || words.count >= 5 && first != "make"))
        let securityTerms = #"\b(access|mfa|2fa|multi-factor|permission|privilege|account|password|phish|breach|vulnerab|rls|row level security|credential|encrypt|security|secure|sign-in|login|lockout|locked out|compromis|ransomware|token)"#
        let problem = Self.problemPattern
        let scenarioStart = #"^(let'?s say|lets say|say|suppose|imagine|assume|picture this|hypothetically|consider|in a scenario where|you'?re|you are|you'?ve been|you have been|a |an |our |the |one of our|users? |students? |teachers? |customers? |employees? |staff |someone )"#

        // Behavioural prompts first: "Tell me about a time…" is not a request to explain a technology.
        if has(#"\b(tell me about|describe|give me an example of|talk about|share) (a time|an occasion|a situation|a moment|yourself|one of your|your (most|biggest|hardest|favou?rite|proudest|greatest)|a (project|challenge|mistake|failure|conflict) (you|that))"#)
            || has(#"\b(tell me about|walk me through) your (projects?|experience|background|resume|portfolio)\b"#)
            || has(#"^(what'?s|what is|what are) your (greatest|biggest) (strength|weakness)"#)
            || has(#"\bhow do you (handle|deal with|manage|respond to) (conflict|pressure|stress|feedback|criticism|deadlines|disagreement|failure)"#)
            || has(#"^why (do you want|should we hire|are you interested|did you (choose|leave))"#) {
            return intent(.behavioural, 0.85, "behavioural prompt")
        }
        // Follow-ups about the current discussion ("What if the database goes down?").
        if has(#"^(and |but |so |okay,? |ok,? )?(what if|what happens (if|when)|what about|how about|and if|then what|what would happen|how would that|would that|does that|is that still)"#) {
            return intent(hasContext ? .followUp : .question, 0.8, "follow-up phrasing")
        }
        if imperative || has(#"^(can|could|would) you (please )?(design|build|explain|describe|compare|write|implement|walk|show|tell|talk|outline|diagnose|debug|fix|create|help)\b"#)
            || politeRequest || has(#"^(go ahead and|let'?s have you|your task is to|the task is to)\b"#) {
            if has(#"\b(compare|comparing|contrast|difference(s)? between|differ|versus|vs\.?|compared (to|with)|pros and cons)\b"#) {
                return intent(.comparison, 0.85, "comparison request")
            }
            if CodingLanguage.isNewTask(sentence) || has(#"^(write|implement|code|refactor|reverse|sort|remove)\b"#)
                || has(#"^(build|create|make) (a|an|the|me a) (\w+ )?(react |vue |swift |typescript |javascript |python |sql )?(component|function|class|hook|script|query|endpoint|method|program|regex|algorithm|test|module)"#) {
                return intent(.coding, 0.85, "coding task")
            }
            if has(#"^(design|architect|build|sketch|propose|plan)\b"#) || has(#"\b(system design|architecture for|scalab\w+|high availability|distributed)\b"#) {
                return intent(.systemDesign, 0.85, "design task")
            }
            if has(#"^(diagnose|troubleshoot|investigate|debug|fix|solve)\b"#) || has(problem) && has(#"\b(approach|investigate|diagnose|fix|troubleshoot|resolve)\b"#) {
                return intent(.troubleshooting, 0.85, "troubleshooting task")
            }
            if has(#"^(walk|take|talk|go) (me|us) through\b"#), has(#"\b(architecture|schema|database|system|app|application|codebase|design|stack|pipeline|authentication|auth|infrastructure|backend|frontend|data model|how (your|the|it))\b"#) {
                return intent(.architecture, 0.85, "architecture walkthrough")
            }
            if has(securityTerms), has(#"\b(restore|secure|protect|grant|revoke|lock|harden|audit|recover|reset|without (disabling|weakening|turning off|bypassing))\b"#) {
                return intent(.security, 0.85, "security task")
            }
            if has(#"\b(your approach|how you'?d|how you would|what you'?d do|what you would do)\b"#)
                || has(#"\bhow you (prioriti[sz]e|investigate|handle|troubleshoot|diagnose|fix|resolve|respond|communicate|deal with|approach|triage|escalate)\b"#) {
                return intent(.troubleshooting, 0.8, "approach request")
            }
            // "Tell me about…" / "Explain…" alone stays below the confident-handoff level, as before.
            return intent(.explanation, words.count >= 8 ? 0.8 : 0.7, "instruction")
        }
        // Questions: interrogative or polite forms, with or without a question mark.
        let interrogatives: Set<String> = ["what", "how", "why", "when", "where", "which", "who", "what's", "how's", "whats"]
        let auxiliaries: Set<String> = ["can", "could", "would", "will", "do", "does", "did", "is", "are", "should", "have", "has"]
        if interrogatives.contains(first) || (auxiliaries.contains(first) && ["you", "we", "i", "it", "this", "that", "there", "your", "they"].contains(second))
            || sentence.hasSuffix("?") {
            guard words.count >= 3 else { return intent(.statement, 0, "too short") }
            if has(#"\b(difference(s)? between|versus|vs\.?|compared (to|with)|which is better|better than)\b"#) { return intent(.comparison, 0.8, "comparison question") }
            if has(#"\bhow (would|do|did|should) (you|we|i) (design|architect|build|scale)\b"#) { return intent(.systemDesign, 0.8, "design question") }
            if has(#"\bhow (would|do|should) (you|we|i) (debug|troubleshoot|diagnose|investigate|fix|resolve|handle)\b"#) || has(problem) {
                return intent(.troubleshooting, 0.8, "troubleshooting question")
            }
            if has(securityTerms), has(#"\b(restore|secure|protect|grant|revoke|prevent|safely|without weakening|least privilege|recover)\b"#) {
                return intent(.security, 0.8, "security question")
            }
            // Without a question mark a short yes/no form ("Is that common") is weak evidence.
            return intent(.question, sentence.hasSuffix("?") ? 0.75 : words.count >= 5 ? 0.7 : 0.45, "question form")
        }
        // A hypothetical ("Let's say a classroom loses internet…") or a problem stated as fact ("Our Salesforce
        // integration stopped receiving leads.").
        if has(scenarioStart), words.count >= 4 {
            if has(#"^(let'?s say|lets say|say|suppose|imagine|assume|picture this|hypothetically|in a scenario where)\b"#) {
                return intent(.situational, 0.7, "hypothetical scenario (no task stated yet)", awaiting: true)
            }
            if has(problem) { return intent(.troubleshooting, 0.7, "problem scenario (no task stated yet)", awaiting: true) }
        }
        if has(problem), words.count >= 5, !has(#"\b(i|i'd|we'd)\b"#) {
            return intent(.troubleshooting, 0.65, "problem description (no task stated yet)", awaiting: true)
        }
        return intent(.statement, 0, "no request cues")
    }

    /// Something broken or degraded ("stopped receiving leads", "returning 500 errors", "has lost internet").
    static let problemPattern = #"\b((stopped|stops|isn't|is not|aren't|are not|not|no longer|can't|cannot|won't|unable to) (working|receiving|sending|loading|syncing|responding|connecting|getting|showing|saving|log(ging)? in(to)?|sign(ing)? in(to)?|access|reach|connect)|returning (5\d\d|4\d\d|errors?|an error)|(is|are|went|goes|keeps going) down|outages?|crash(es|ed|ing)?|(is|are|got|getting|running) (slow|slower)|timing out|times out|failing|fails|failed|broken|loses|lost|leaking|memory leak|degrad\w*|spik(e|es|ed|ing)|locked out|can't log in|cannot log in|duplicat\w+ (records|emails|charges|rows)|intermittent\w*)\b"#

    static func isProblem(_ text: String) -> Bool { text.lowercased().range(of: problemPattern, options: .regularExpression) != nil }

    // MARK: Small talk

    /// Speech in the candidate's own voice ("I'd use…", "My approach…"); never interviewer context.
    static func isFirstPerson(_ text: String) -> Bool {
        let first = stripLeadIns(text.lowercased()).split(whereSeparator: { !($0.isLetter || $0 == "'") }).first.map(String.init) ?? ""
        return ["i", "i'd", "i'll", "i'm", "i've", "my", "we'd", "we'll", "id"].contains(first)
            && text.lowercased().range(of: #"^(i'?d like you to|i want you to)"#, options: .regularExpression) == nil
    }

    static func isSmallTalk(_ lower: String, words: [String]) -> Bool {
        let text = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let acknowledgements: Set<String> = ["okay", "ok", "alright", "all right", "right", "sure", "yes", "yeah", "yep", "no", "great", "cool",
                                             "perfect", "thanks", "thank you", "got it", "sounds good", "makes sense", "nice", "awesome",
                                             "okay great", "okay thanks", "okay cool", "hmm", "mm", "um", "uh", "uh huh", "mhm", "fine", "good"]
        if acknowledgements.contains(text) { return true }
        let logistics = [
            #"\b(give me|just|wait) (a|one) (second|sec|moment|minute|min)\b"#, #"^(one|just a) (second|sec|moment|minute)\b"#, #"\bhold on\b"#,
            #"^(let me|i'?m (going to|gonna)|i'?ll|i am|i'?m just|we'?ll|we are|we'?re|let'?s) (just )?(quickly )?(open|opening|pull up|pulling up|share|sharing|start|starting|get started|getting started|grab|grabbing|find|load|loading|switch|unmute|mute|turn on|join|joining|set up|setting up|bring up|look at my|check my)\b"#,
            #"^i'?m (just )?(opening|sharing|pulling up|loading|getting|setting up|bringing up|looking for|grabbing)\b"#,
            #"\bcan (you|everyone) (hear|see) (me|my screen|us)\b"#, #"\b(we'?ll|we will|let'?s|we can) (start|begin|get started|kick off)( shortly| soon| now| in a (moment|minute|second))?[.!]?$"#,
            #"\b(share|sharing) my screen\b"#, #"\byou'?re (on )?mute\b"#, #"^(sorry|apologies),? (about that|my (internet|connection|mic))"#,
            #"\bnice to meet you\b"#, #"^(take your time|no rush|whenever you'?re ready|you can (start|begin)( whenever you'?re ready)?|go ahead|keep going|that'?s fine|no problem)[.!]*$"#, #"^(good (morning|afternoon|evening)|hi|hello|hey)\b[^?]{0,30}$"#, #"\bhow are you( doing)?( today)?[?.!]*$"#,
        ]
        return logistics.contains { lower.range(of: $0, options: .regularExpression) != nil } && words.count <= 14
    }

    // MARK: Requirements and parts

    /// Explicit constraints after "must / should / needs to / handle / without / including …", split into items.
    static func requirements(in text: String) -> [String] {
        let lower = text.lowercased()
        let cue = #"\b(must|should|needs? to|has to|have to|handles?|handling|supports?|without|including|while|ensure|make sure|so that|that can|able to|guarantee|deal with|cope with|survive|tolerate|account for)\b"#
        guard let regex = try? NSRegularExpression(pattern: cue) else { return [] }
        var items: [String] = []
        let ns = lower as NSString
        for match in regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let cueWord = ns.substring(with: match.range)
            // The clause after the cue, up to the end of its sentence.
            let rest = ns.substring(from: match.range.location + match.range.length)
            let clause = rest.components(separatedBy: CharacterSet(charactersIn: ".?!;")).first ?? ""
            let pieces = clause.replacingOccurrences(of: #",? and |, or |, "#, with: "|", options: .regularExpression)
                .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            for (index, piece) in pieces.enumerated() {
                // Stop at the next cue: it starts its own requirement.
                let trimmed = piece.components(separatedBy: CharacterSet.whitespaces)
                    .prefix(while: { !["must", "should", "without", "while", "including"].contains($0) }).joined(separator: " ")
                    .replacingOccurrences(of: #"^(be able to|be|also|the|to|any|all)\s+"#, with: "", options: .regularExpression)
                let words = TextSimilarity.contentWords(trimmed)
                guard (1...9).contains(words.count) else { continue }
                let item = index == 0 && cueWord == "without" ? "without " + trimmed : trimmed
                if !items.contains(where: { $0.contains(item) || item.contains($0) }) { items.append(item) }
            }
        }
        return Array(items.prefix(8))
    }

    /// "Design the system, explain the trade-offs, and describe how you'd test it" → three parts.
    static func parts(in text: String) -> [String] {
        let verbs = #"(design|explain|describe|compare|implement|write|build|discuss|outline|walk me through|tell me|show me|list|test|cover|mention|justify|estimate|sketch|identify|propose|define|how you'?d|how you would|what you'?d|why|prioriti[sz]e|investigate|communicate|diagnose|handle|fix|resolve|monitor|prevent|verify|escalate|document|secure|scale|deploy|migrate)"#
        let lower = text.lowercased()
        let pieces = lower.replacingOccurrences(of: #"(,\s*(and\s+)?(then\s+)?|\s+and\s+(then\s+)?|;\s*|\.\s+(then\s+)?(also\s+)?)(?="# + verbs + #"\b)"#,
                                                with: "|", options: .regularExpression)
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!"))) }
        let tasks = pieces.filter { stripLeadIns($0).range(of: "^" + verbs + #"\b"#, options: .regularExpression) != nil && $0.split(separator: " ").count >= 2 }
        return tasks.count >= 2 ? tasks : []
    }

    // MARK: Continuations

    /// A turn that completes the previous request rather than starting a new one: stated constraints
    /// ("The application must handle thousands of submissions…") or, after a scenario, its task
    /// ("Walk me through your approach."). Questions ("What if…?") are follow-ups, never continuations.
    static func isContinuation(_ text: String, of previous: String) -> Bool {
        let before = classify(previous)
        guard before.actionable, !text.trimmingCharacters(in: .whitespaces).hasSuffix("?") else { return false }
        let lower = stripLeadIns(text.lowercased())
        let intent = classify(text)
        if intent.kind == .smallTalk || isFirstPerson(text) { return false }
        if intent.actionable, !intent.awaitingTask {
            return before.awaitingTask && ContextReference.detect(text).refersBack
        }
        let cue = #"^(the|this|that|it|each|every|our|your|users?|students?|staff|customers?|you|we|they|there|also|plus|assume|assuming|keep in mind|make sure|bear in mind|requirements?|constraints?|including|with|without|so that|which|but|and)\b"#
        let constraint = #"\b(must|should|needs? to|has to|have to|will need|can'?t|cannot|may|might|is expected|are expected|handles?|supports?|without|including|there (are|is|will be)|up to|at least|around \d|per (second|minute|day|hour)|within)\b"#
        return lower.range(of: cue, options: .regularExpression) != nil && lower.range(of: constraint, options: .regularExpression) != nil
    }

    // MARK: Prompt guidance

    /// How to structure the answer (internal reasoning order, not headings) and how long it should be.
    func guidance(length: AnswerLength) -> String {
        let structure: String
        switch kind {
        case .troubleshooting:
            structure = "This is a troubleshooting scenario. Work through it as investigate, diagnose, resolve, verify, document: say what you'd check first and why, how you'd narrow down the cause, what you'd change, and how you'd confirm it's fixed. Don't jump to a fix before explaining how you'd find the cause."
        case .systemDesign:
            structure = "This is a system design task. Cover the requirements it states, the main components and how data flows between them, then reliability (failures, retries, duplicates, recovery), security, and the key trade-off. For background or asynchronous work, think about durable job storage, idempotency, retries with exponential backoff and jitter, job leases or visibility timeouts for crashed workers, dead-letter handling, backpressure and monitoring, but only where they serve the stated requirements. Be honest about delivery guarantees: queues give at-least-once processing, and external side effects such as emails can't be guaranteed exactly once, so describe how you'd make duplicates unlikely and harmless."
        case .coding:
            structure = "This is a coding task. Clarify the requirement in a few words, explain the approach, give the implementation the format asks for, then cover edge cases and how you'd validate it."
        case .comparison:
            structure = "This is a comparison. Say what each one is, the differences that matter in practice, the advantages and limits of each, and when you'd choose one over the other. Give both sides real coverage."
        case .security:
            structure = "This is a security scenario. Address the actual task first. Verify identity before changing anything, find the root cause (for example in sign-in and audit logs), fix it for the affected user or resource with least privilege, and never weaken organisation-wide security. If an exception is unavoidable, keep it approved, narrowly scoped and time-limited. Finish with how you'd verify the fix and document it."
        case .architecture:
            structure = "Walk through the architecture: the main parts, how a request or data moves through them, and why it's built that way, including one trade-off or limitation."
        case .behavioural:
            structure = "This is a behavioural question. Use situation, responsibility, action, result naturally, without labelling them. Use only the verified background; if there is none that fits, give an honest, adaptable answer about how you approach this kind of situation instead of inventing a story, employer, incident or achievement."
        case .situational:
            structure = "This is a situational prompt. Say what you'd do first and why, how you'd keep people informed and the situation safe, how you'd resolve it, and how you'd prevent it happening again."
        case .followUp:
            structure = "This is a follow-up. Answer this specific point directly, using the previous discussion as context; don't restate the earlier answer unless a detail is needed."
        case .explanation, .question:
            structure = "Answer the request directly: what it is or how it works, and one practical detail, example or pitfall that shows real understanding."
        case .smallTalk, .incomplete, .statement:
            structure = "Answer the request directly."
        }
        var lines = [structure, "Length: \(sentenceRange(length)) Never drop one of the interviewer's requirements just to stay short."]
        if !requirements.isEmpty {
            lines.append("The interviewer's explicit requirements; your answer must address each one: " + requirements.joined(separator: "; ") + ".")
        }
        if parts.count >= 2 {
            lines.append("This request has \(parts.count) parts; cover each in order: " + parts.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Spoken length by request type and answer mode (guidelines, not quotas).
    func sentenceRange(_ length: AnswerLength) -> String {
        let (short, standard, detailed): (String, String, String) = switch kind {
        case .systemDesign: ("about 4 to 6 sentences.", "about 6 to 10 sentences.", "about 8 to 12 sentences.")
        case .troubleshooting, .security, .situational: ("about 3 to 5 sentences.", "about 5 to 8 sentences.", "about 7 to 10 sentences.")
        case .architecture: ("about 3 to 5 sentences.", "about 5 to 8 sentences.", "about 7 to 10 sentences.")
        case .comparison: ("about 3 to 4 sentences.", "about 4 to 6 sentences.", "about 6 to 8 sentences.")
        case .followUp: ("about 2 to 3 sentences.", "about 2 to 5 sentences.", "about 4 to 6 sentences.")
        case .coding: ("as long as the explanation needs.", "as long as the explanation needs.", "as long as the explanation needs.")
        default: ("about 2 to 3 sentences.", "about 2 to 4 sentences, or more if the topic needs it.", "about 4 to 7 sentences.")
        }
        return switch length {
        case .short: short
        case .standard: standard
        case .detailed: detailed
        }
    }

    /// Output budget large enough for the length above (Gemini counts any thinking tokens against it too).
    func maximumTokens(_ length: AnswerLength) -> Int {
        let base = length.maximumTokens
        return switch kind {
        case .systemDesign: base + 260
        case .troubleshooting, .security, .situational, .architecture: base + 140
        case .comparison: base + 60
        default: base
        }
    }

    // MARK: Completeness

    /// Requirements an answer never mentions (stem or close-synonym match). Deterministic; used for at most
    /// one targeted regeneration, never a second model call by default.
    func missingRequirements(in answer: String) -> [String] {
        let answerStems = Set(TextSimilarity.contentWords(answer).map { Self.stem($0) })
        let lowerAnswer = answer.lowercased()
        return requirements.filter { requirement in
            let generic: Set<String> = ["handle", "handles", "thousands", "lot", "lots", "many", "able", "make", "sure", "work", "time", "without"]
            let stems = TextSimilarity.contentWords(requirement).map { $0.lowercased() }.filter { !generic.contains($0) }.map { Self.stem($0) }
            guard !stems.isEmpty else { return false }
            return !stems.contains { stem in
                answerStems.contains(stem) || (Self.synonyms[stem] ?? []).contains { lowerAnswer.contains($0) }
            }
        }
    }

    static let synonyms: [String: [String]] = [
        "dupli": ["idempot", "dedup", "unique key", "already processed", "once"],
        "outag": ["retry", "retries", "backoff", "unavailab", "down", "circuit breaker"],
        "crash": ["recover", "lease", "visibility timeout", "restart", "heartbeat"],
        "losin": ["durab", "persist", "lost", "lose", "no job is lost", "stored"],
        "lost": ["durab", "persist", "lose", "stored"],
        "submi": ["scale", "volume", "load", "throughput", "concurren", "queue"],
        "secur": ["least privilege", "mfa", "policy", "policies", "secure", "protect"],
        "weake": ["least privilege", "policy", "policies", "secure", "exception"],
        "organ": ["organisation", "organization", "tenant", "everyone", "company-wide", "policy"],
    ]

    static func stem(_ word: String) -> String { String(word.lowercased().prefix(5)) }

    // MARK: Text helpers

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { result.append(sentence) }
        }
        return result.isEmpty && !text.isEmpty ? [text] : result
    }

    static func stripLeadIns(_ lower: String) -> String {
        var core = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let leadIns = ["so", "okay", "ok", "now", "alright", "and", "well", "right", "then", "next", "please", "great", "cool",
                       "all right", "for this one", "next up", "first", "finally", "lastly", "also"]
        var changed = true
        while changed {
            changed = false
            for lead in leadIns where core.hasPrefix(lead + " ") || core.hasPrefix(lead + ", ") || core.hasPrefix(lead + ". ") {
                core = String(core.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: ",. "))
                changed = true
            }
        }
        return core
    }
}
