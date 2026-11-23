import Foundation

struct KnowledgeTopic: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var keywords: [String]
    var notes: String
}

struct KnowledgeDocument: Codable, Equatable, Sendable {
    var topics: [KnowledgeTopic]
    /// User-entered, verified facts only. Empty by default: the app never invents experience.
    var portfolio: String
}

/// Local, editable knowledge base stored in Application Support with complete file protection.
@MainActor @Observable final class KnowledgeBase {
    var document: KnowledgeDocument { didSet { save() } }
    private let url: URL?

    init(url: URL? = KnowledgeBase.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(KnowledgeDocument.self, from: data) {
            document = saved
        } else {
            document = KnowledgeDocument(topics: Self.defaultTopics, portfolio: "")
        }
    }

    static var defaultURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("knowledge-base.json")
    }

    var keywords: [String] { document.topics.flatMap(\.keywords) }

    /// Top matching topic notes for a question, bounded for the model's context window.
    func notes(for question: String, limit: Int = 2, maximumCharacters: Int = 600) -> [String] {
        let lower = question.lowercased()
        return document.topics
            .map { topic in (topic, topic.keywords.filter { lower.contains($0) }.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { "\($0.0.title): \(String($0.0.notes.prefix(maximumCharacters)))" }
    }

    func resetToDefaults() { document.topics = Self.defaultTopics }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    nonisolated static let defaultTopics: [KnowledgeTopic] = [
        .init(title: "JavaScript", keywords: ["javascript", "closure", "event loop", "hoisting"], notes: "Single-threaded with an event loop; closures capture lexical scope; prefer const/let; strict equality ===."),
        .init(title: "TypeScript", keywords: ["typescript", "type safety", "interface", "generic"], notes: "Static types over JavaScript; interfaces/types, generics, union types, strict mode catches null errors at compile time."),
        .init(title: "React", keywords: ["react", "hook", "useeffect", "usestate", "component", "virtual dom"], notes: "Components and props; state via hooks; useEffect for side effects with dependency arrays; keys for lists; lift state or use context."),
        .init(title: "Next.js", keywords: ["next.js", "nextjs", "server component", "ssr", "app router"], notes: "React framework: file-based routing, server components, SSR/SSG/ISR, API routes/route handlers, middleware."),
        .init(title: "REST APIs", keywords: ["rest", "api", "endpoint", "http method"], notes: "Resources and HTTP verbs (GET/POST/PUT/PATCH/DELETE), statelessness, idempotency, versioning, pagination, consistent error bodies."),
        .init(title: "HTTP status codes", keywords: ["status code", "404", "500", "401", "403", "429"], notes: "2xx success, 3xx redirect, 4xx client error (400 bad request, 401 unauthenticated, 403 forbidden, 404 not found, 429 rate limited), 5xx server error (500, 502 bad gateway, 503 unavailable, 504 timeout)."),
        .init(title: "Error handling", keywords: ["error handling", "exception", "try catch", "retry"], notes: "Validate inputs, catch at boundaries, log with context and correlation IDs, return clear errors, retry transient failures with backoff, never swallow errors."),
        .init(title: "Promises and async/await", keywords: ["promise", "async", "await"], notes: "A Promise represents a future value; async functions return promises; await pauses until settled; use try/catch; Promise.all for parallel work."),
        .init(title: "PostgreSQL", keywords: ["postgres", "postgresql", "index", "query plan", "explain"], notes: "Relational database: transactions/ACID, indexes (B-tree), EXPLAIN ANALYZE for slow queries, constraints, JSONB, roles and privileges."),
        .init(title: "SQL joins", keywords: ["join", "inner join", "left join"], notes: "INNER returns matching rows; LEFT keeps all left rows; RIGHT/FULL OUTER; join on keys; watch for duplicate rows from one-to-many joins."),
        .init(title: "Normalization", keywords: ["normalization", "normal form", "denormal"], notes: "1NF atomic values, 2NF no partial dependency, 3NF no transitive dependency; reduces redundancy; denormalize deliberately for read performance."),
        .init(title: "Authentication vs authorization", keywords: ["authentication", "authorization", "oauth", "jwt", "sso", "mfa"], notes: "Authentication proves identity (passwords, MFA, SSO/OAuth/OIDC); authorization decides access (roles, permissions, least privilege)."),
        .init(title: "Row Level Security", keywords: ["row level security", "rls", "policy", "policies"], notes: "Postgres RLS attaches policies to a table so each query only sees rows the current user/role is allowed; enable per table; test policies per role."),
        .init(title: "Microsoft 365", keywords: ["microsoft 365", "office 365", "m365", "outlook", "exchange", "sharepoint", "onedrive"], notes: "Check service health in the admin center, license assignment, user sign-in logs, mailbox/permissions, conditional access, clear cached credentials."),
        .init(title: "Microsoft Entra ID", keywords: ["entra", "azure ad", "active directory", "conditional access"], notes: "Cloud identity: users/groups, SSO, MFA, conditional access, sign-in logs show failure reason codes; password reset and account lockout checks."),
        .init(title: "Microsoft Teams", keywords: ["teams"], notes: "Check service health, license, network/firewall, client cache, policies (meeting/messaging), audio/video device settings."),
        .init(title: "Salesforce CRM", keywords: ["salesforce", "crm"], notes: "Objects, fields, profiles/permission sets; integrations via REST/Bulk API and connected apps; check API limits, integration user permissions, debug logs."),
        .init(title: "Learning Management Systems", keywords: ["lms", "moodle", "canvas", "learning management"], notes: "Moodle/Canvas courses, enrolments, gradebook; integrations via LTI and SIS sync; check enrolment sync logs, roles, and LTI keys."),
        .init(title: "Integration failures", keywords: ["integration", "third-party", "webhook", "sync fail"], notes: "Reproduce, check logs on both sides, verify credentials/tokens, API limits, payload/schema changes, network; fix, replay failed records, monitor."),
        .init(title: "Logging and monitoring", keywords: ["logging", "monitoring", "alert", "observability", "metrics"], notes: "Structured logs with levels and correlation IDs, centralised logging, metrics and dashboards, alerts on error rates/latency, uptime checks."),
        .init(title: "Security", keywords: ["security", "phishing", "vulnerability", "patch", "encryption"], notes: "Least privilege, MFA, patching, encryption in transit/at rest, backups, phishing awareness, input validation, secrets management."),
        .init(title: "Network troubleshooting", keywords: ["network", "internet", "dns", "dhcp", "wifi", "ping", "traceroute"], notes: "Work up the layers: physical link, IP/DHCP, gateway ping, DNS (nslookup), traceroute, firewall/proxy; check scope (one user vs everyone)."),
        .init(title: "Git", keywords: ["git", "branch", "merge", "rebase", "pull request"], notes: "Branches, commits, pull requests and reviews, merge vs rebase, resolving conflicts, never force-push shared branches."),
        .init(title: "CI/CD", keywords: ["ci/cd", "pipeline", "continuous integration", "deployment", "github actions"], notes: "Automated build and tests on every push, gated deploys, environment configs/secrets, rollbacks, staged releases."),
        .init(title: "System administration", keywords: ["server", "backup", "windows server", "linux", "patching", "group policy"], notes: "Patching cycles, backups and restore tests, user provisioning, group policy, monitoring disk/CPU, documentation and change control."),
        .init(title: "Technical support", keywords: ["support ticket", "help desk", "user issue", "troubleshoot"], notes: "Gather details and reproduce, check scope and recent changes, fix or escalate, communicate clearly, document in the ticket, confirm with the user."),
    ]
}

/// Builds the bounded prompt sent to the model.
enum InterviewPromptBuilder {
    /// Rules every answer follows, whatever the question type.
    static let shared = """
    You help a junior IT & Systems Developer during interview practice or explicitly authorized AI-assisted interviews.
    Answer the question that was asked. Never describe how you would look something up, double-check it, or ask someone: give the answer.
    Plain text only: no Markdown, headings, bullet points, numbered lists, or code blocks. Keep technical terms such as REST API, SQL, MFA, and Microsoft Entra ID exactly as written.
    Do not invent professional experience or claim to have used technologies the user has not actually worked with.
    Writing, showing, explaining or testing code on request is never a claim about past work: always give the requested code or explanation directly ("Here's how I'd write it…"), and never refuse because the user has not written it before. Only claims such as "I built this in Diskarte" need verified background.
    If you are genuinely unsure of a fact, say so in a few words instead of guessing.
    """

    /// The conversational interview voice: technical and troubleshooting questions only.
    static let persona = """
    Generate answers in first person, as though the developer is naturally explaining their approach to the interviewer.
    Sound conversational, clear, and technically capable. Use contractions like "I'd" and "I've" where natural, and vary how sentences start; don't keep repeating "I'd probably".
    Prefer concrete technical steps and examples over abstract explanations.
    Explain technical reasoning in plain English while retaining important terminology.
    Start directly with the answer rather than introducing the topic: never open with "Great question", "Certainly", "Absolutely", or by restating the question.
    Explain your reasoning as you go (why you'd check or choose something), like a developer thinking out loud with a colleague.
    Use plain words instead of corporate ones (say "use", not "leverage" or "utilize"; avoid "robust", "seamless", "synergy", "cutting-edge"), and avoid unnecessary filler, generic motivational statements, and overly formal language.
    Don't repeat a point you already made, and don't start several sentences the same way.
    When verified background includes a project that genuinely fits the question, mention one concrete detail from it naturally; never force a project into an unrelated answer.
    For a follow-up, answer the latest question directly and build on what was already said instead of repeating it.
    When describing troubleshooting, explain what you'd check first, how you'd narrow down the problem, what you'd fix, and how you'd confirm it worked.
    Use a calm, approachable tone suitable for speaking directly to DJ, the technical interviewer.
    """

    /// One before/after pair showing the register, not content to reuse.
    static let styleExample = """
    Style example only. Too formal: "In order to effectively diagnose the aforementioned authentication failure, I would initiate a comprehensive investigation of the identity management infrastructure." Better: "I'd start by checking whether the account is active and whether the user has the right license. Then I'd look at the Entra sign-in logs to see if it's a password issue, an MFA problem, or a conditional access policy blocking them."
    """

    static func instructions(for category: QuestionCategory = .technical, length: AnswerLength, portfolio: String) -> String {
        let trimmedPortfolio = String(portfolio.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
        let experience = trimmedPortfolio.isEmpty
            ? "The developer has not provided any verified experience. For questions about their own past projects or history, give a short, honest way to approach the answer and do not invent details. This never applies to requests to write, show, explain or test code: answer those directly."
            : "Verified background (the ONLY experience you may mention):\n\(trimmedPortfolio)"
        let style: String
        switch category {
        case .factual:
            style = """
            This is a direct factual question. Answer with one direct, informative sentence that states the fact or definition plainly, without first person. Only add a second sentence if it carries essential information. Never add sentences about checking documentation, researching, confirming or verifying the answer.
            """
        case .coding:
            style = """
            This is a programming question. Explain the solution directly in 2 to 4 short spoken sentences ("Here's how I'd write it…"): the approach, the key language feature or API, and the complexity or a pitfall. Prefer correct, simple, readable code. If no code section is requested, mention an essential fragment inline briefly, for example [...new Set(items)]. Never claim the code was run, compiled, or tested.
            """
        case .technical, .math, .ambiguous:
            style = """
            \(persona)
            Answer in complete, natural spoken sentences that are easy to say aloud: \(length.sentences). Prioritise substance over sentence count.
            \(styleExample)
            """
        }
        return [shared, style, experience].joined(separator: "\n")
    }

    static func prompt(question: String, followUpTo previous: (question: String, answer: String)?, notes: [String]) -> String {
        var parts: [String] = []
        if !notes.isEmpty { parts.append("Reference notes:\n" + notes.joined(separator: "\n")) }
        if let previous {
            parts.append("Previous question: \(previous.question.prefix(300))\nPrevious answer: \(previous.answer.prefix(600))")
            parts.append("This is a follow-up: answer only the new point, in the same context, without repeating the previous answer.")
        }
        parts.append("Interviewer: \(question.prefix(600))\nYour spoken answer:")
        return parts.joined(separator: "\n\n")
    }
}

/// Makes model output safe to show on the glasses and to say aloud: removes Markdown structure only,
/// never words, and keeps technical tokens like "C#", "Node.js" and ".NET" intact.
/// Deterministic clean-up of generated speech: robotic openers and corporate wording. Prefix-stable (it only
/// changes the opening and individual words), so an early frame and the final answer always agree.
nonisolated enum NaturalAnswerStyle {
    static let openers = [
        #"^(?:that'?s|that is|what) an? (?:really |very )?(?:great|good|excellent|interesting) question[.!,]?\s*"#,
        #"^(?:great|good|excellent) question[.!,]?\s*"#,
        #"^(?:certainly|absolutely|of course|sure thing|definitely)[.!,]\s*"#,
        #"^as an? (?:ai|language model|developer|candidate|interviewee)\b[^,.]*,\s*"#,
        #"^(?:so,? )?(?:to answer your question|in answer to your question)[,:]?\s*"#,
    ]
    static let plainWords: [(String, String)] = [
        ("utilization", "use"), ("utilizing", "using"), ("utilized", "used"), ("utilizes", "uses"), ("utilize", "use"),
        ("leveraging", "using"), ("leveraged", "used"), ("leverages", "uses"), ("leverage", "use"), ("in order to", "to"),
    ]

    static func polish(_ text: String) -> String {
        var result = text
        var changed = true
        while changed { // "Great question! Certainly, …"
            changed = false
            for pattern in openers {
                if let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]), range.lowerBound == result.startIndex {
                    result.removeSubrange(range)
                    changed = true
                }
            }
        }
        if let first = result.first, first.isLowercase, result != text { result = first.uppercased() + result.dropFirst() }
        for (word, plain) in plainWords {
            let capitalized = word.prefix(1).uppercased() + word.dropFirst()
            result = result.replacingOccurrences(of: "\\b\(capitalized)\\b", with: plain.prefix(1).uppercased() + plain.dropFirst(),
                                                 options: .regularExpression)
            result = result.replacingOccurrences(of: "\\b\(word)\\b", with: plain, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// Three or more sentences that open with the same two words ("I'd check… I'd check… I'd check…").
    static func repetitiveOpening(_ text: String) -> String? {
        var openings: [String: Int] = [:]
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            count += 1
            let words = sentence.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).prefix(2).joined(separator: " ")
            if !words.isEmpty { openings[words, default: 0] += 1 }
        }
        guard count >= 4, let repeated = openings.first(where: { $0.value >= 3 }) else { return nil }
        return "opens \(repeated.value) sentences with \"\(repeated.key)\"; vary the openings"
    }
}

nonisolated enum AnswerFormatter {
    /// The answer ends with a finished sentence (not cut off mid-sentence by a token limit).
    static func endsCleanly(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"[.!?;]["'\u{201D}\u{2019})\]]*$"#, options: .regularExpression) != nil
    }

    /// The prefix of streamed text that ends with a completed sentence (".", "?" or "!" followed by
    /// whitespace), so an unfinished sentence or a decimal like "3.5" is never cut. "" if none yet.
    static func completeSentences(_ text: String) -> String {
        guard let range = text.range(of: #"[.!?]["')\]]?\s(?!.*[.!?]["')\]]?\s)"#, options: [.regularExpression]) else { return "" }
        return String(text[..<range.lowerBound]) + String(text[range].dropLast())
    }

    static func spoken(_ raw: String) -> String {
        // Unicode spaces become plain spaces; invisible zero-width characters are dropped so they can
        // never make two words look like one on the lens.
        var unified = ""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x2060, 0xFEFF: continue
            case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000, 0x0009: unified.unicodeScalars.append(" ")
            default: unified.unicodeScalars.append(scalar)
            }
        }
        let lines = unified.components(separatedBy: .newlines).map { line -> String in
            var text = line.trimmingCharacters(in: .whitespaces)
            // Headings and list markers at the start of a line.
            while text.hasPrefix("#") { text.removeFirst() }
            for marker in ["- ", "* ", "\u{2022} ", "+ "] where text.hasPrefix(marker) { text.removeFirst(marker.count) }
            if let range = text.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) { text.removeSubrange(range) }
            return text.trimmingCharacters(in: .whitespaces)
        }
        var text = lines.filter { !$0.isEmpty }.joined(separator: " ")
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
