import Foundation

/// One editable fact about the user. Only the user (or an import they approved) creates entries;
/// nothing said during a conversation becomes a permanent memory.
nonisolated struct MemoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Education, background, skills, communication style.
        case profile
        /// One project's summary (seeded or imported).
        case project
        /// A section of an imported project document (README, schema, docs…).
        case projectDoc
    }

    var id = UUID()
    var kind: Kind
    var title: String
    /// Project the entry belongs to (projects and their documents).
    var project: String?
    var text: String
    /// Files that support the entry (imported entries only).
    var sources: [String] = []
    var updatedAt = Date()
}

nonisolated struct MemoryDocument: Codable, Equatable, Sendable {
    var entries: [MemoryEntry]
    /// Project name → when its repository was last indexed.
    var lastIndexed: [String: Date] = [:]
    /// Project name → approved spellings / pronunciation variants used to recognise it in speech.
    var aliases: [String: [String]] = MemoryDocument.seedAliases

    static let seedAliases: [String: [String]] = [
        "Diskarte": ["Discarte", "Disk arte"],
        "Resoniq": ["Rezonic", "Resnik", "Resonic", "Resonique"],
        "KindaMoving": ["Kinda Moving", "Kind of Moving"],
        "FJuan": ["F Juan", "Effjuan"],
        "YYC Track": ["Y Y C Track", "YYC Tracker"],
        "BMR Pharmacy Sales Tracker": ["BMR", "BMR Pharmacy", "BMR Sales Tracker"],
    ]

    init(entries: [MemoryEntry], lastIndexed: [String: Date] = [:], aliases: [String: [String]] = MemoryDocument.seedAliases) {
        self.entries = entries
        self.lastIndexed = lastIndexed
        self.aliases = aliases
    }

    /// Memory saved before aliases existed still loads (with the seeded aliases).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([MemoryEntry].self, forKey: .entries)
        lastIndexed = try container.decodeIfPresent([String: Date].self, forKey: .lastIndexed) ?? [:]
        aliases = try container.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? Self.seedAliases
    }
}

/// Persistent profile and project memory, stored locally with complete file protection, with
/// bounded retrieval for prompts (retrieval-augmented, never the whole store).
@MainActor @Observable final class PersonalMemoryStore {
    var document: MemoryDocument { didSet { save() } }
    private let url: URL?

    init(url: URL? = PersonalMemoryStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(MemoryDocument.self, from: data) {
            document = saved
        } else {
            document = MemoryDocument(entries: Self.seed)
        }
    }

    static var defaultURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("personal-memory.json")
    }

    var entries: [MemoryEntry] { document.entries }
    var profile: [MemoryEntry] { entries.filter { $0.kind == .profile } }
    var projects: [MemoryEntry] { entries.filter { $0.kind == .project } }

    func upsert(_ entry: MemoryEntry) {
        var entry = entry
        entry.updatedAt = Date()
        if let index = document.entries.firstIndex(where: { $0.id == entry.id }) { document.entries[index] = entry } else { document.entries.append(entry) }
    }

    func delete(_ id: UUID) { document.entries.removeAll { $0.id == id } }

    /// Deletes the profile and every project (personal memory). The project index is separate.
    func deletePersonalMemory() { document.entries.removeAll { $0.kind != .projectDoc } }

    /// Deletes imported documents and imported project summaries; seeded summaries the user kept stay.
    func deleteProjectIndex() {
        document.entries.removeAll { $0.kind == .projectDoc || ($0.kind == .project && !$0.sources.isEmpty) }
        document.lastIndexed = [:]
    }

    func restoreSeed() {
        document = MemoryDocument(entries: Self.seed + entries.filter { $0.kind == .projectDoc }, lastIndexed: document.lastIndexed,
                                  aliases: MemoryDocument.seedAliases.merging(document.aliases) { seeded, kept in Array(Set(seeded + kept)).sorted() })
    }

    // MARK: Project names in speech

    func setAliases(_ aliases: [String], for project: String) {
        document.aliases[project] = aliases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Canonical names from your projects, their approved aliases and their technology / domain words.
    var vocabulary: ProjectVocabularyNormalizer {
        ProjectVocabularyNormalizer(entries: projects.compactMap { project in
            guard let name = project.project, !name.isEmpty else { return nil }
            let text = " " + Self.normalize(project.text) + " "
            let keywords = (Self.technologies + Self.domainWords).filter { text.contains(" " + $0) }
            return ProjectVocabularyEntry(canonical: name, aliases: document.aliases[name] ?? [], keywords: keywords)
        })
    }

    nonisolated static let domainWords = ["guitar", "tone", "audio", "running", "gpx", "coros", "formula", "telemetry", "driver",
                                          "transit", "station", "pharmacy", "messaging", "read receipts", "livekit", "openf1", "jolpica"]

    /// Replaces everything previously imported for this project with a fresh import.
    func replaceImport(_ imported: ImportedProject) {
        document.entries.removeAll { $0.project == imported.name && ($0.kind == .projectDoc || !$0.sources.isEmpty) }
        document.entries.append(imported.summary)
        document.entries.append(contentsOf: imported.documents)
        document.lastIndexed[imported.name] = Date()
    }

    func export() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(document)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Retrieval

    struct Retrieval: Equatable, Sendable {
        var entries: [MemoryEntry]
        /// Prompt text, bounded by the character budget.
        var text: String
        var references: [String] {
            entries.map { entry in entry.project.map { entry.kind == .projectDoc ? "\($0) › \(entry.title)" : $0 } ?? entry.title }
        }
    }

    /// The few entries relevant to `question`, within `budget` characters. A project or personal cue
    /// lowers the bar; a generic technical question only gets memory when it clearly matches, so a
    /// project example is never forced into every answer.
    func retrieve(_ question: String, topicProject: String? = nil, limit: Int = 3, budget: Int = 900) -> Retrieval {
        Self.retrieve(question, from: entries, topicProject: topicProject, limit: limit, budget: budget)
    }

    nonisolated static func retrieve(_ question: String, from entries: [MemoryEntry], topicProject: String? = nil,
                                     limit: Int = 3, budget: Int = 900) -> Retrieval {
        let query = " " + normalize(question) + " "
        let personal = personalCues.contains { query.contains($0) }
        let queryConcepts = concepts(in: query)
        let queryWords = Set(TextSimilarity.contentWords(question))
        let named = Set(entries.compactMap(\.project).filter { mentions(query, project: $0) })
        func score(_ entry: MemoryEntry) -> Int {
            let text = " " + normalize(entry.title + " " + entry.text) + " "
            var score = 0
            if let project = entry.project, named.contains(project) { score += 6 }
            if let project = entry.project, project == topicProject, named.isEmpty { score += 3 }
            score += 2 * queryConcepts.intersection(concepts(in: text)).count
            // An exact word (often a technology like "MongoDB") counts as much as a concept.
            score += 2 * min(3, queryWords.filter { text.contains(" " + $0 + " ") }.count)
            if entry.kind == .profile, personal { score += 1 }
            return score
        }
        let threshold = personal || !named.isEmpty ? 2 : 5
        let scored: [(entry: MemoryEntry, score: Int)] = entries.map { (entry: $0, score: score($0)) }
        // Highest score first; on a tie a project summary before documents and profile lines.
        let ranked = scored.filter { $0.score >= threshold }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.kind == .project && b.entry.kind != .project
        }
        var chosen: [MemoryEntry] = []
        var text = ""
        for (entry, _) in ranked where chosen.count < limit {
            let label = entry.project ?? entry.title
            let line = "\(label): \(entry.text)"
            let remaining = budget - text.count
            guard remaining > 60 else { break }
            text += (text.isEmpty ? "" : "\n") + String(line.prefix(remaining - 1))
            chosen.append(entry)
        }
        return Retrieval(entries: chosen, text: text)
    }

    /// The profile in a few lines, for the answer-style instructions.
    func profileSummary(budget: Int = 700) -> String {
        String(profile.map { "\($0.title): \($0.text)" }.joined(separator: "\n").prefix(budget))
    }

    /// A first-person sentence that names a project and a technology the project's memory does not mention.
    /// Returns the reason, or nil when every such claim is supported.
    nonisolated static func unsupportedClaim(in answer: String, entries: [MemoryEntry]) -> String? {
        let projects = Set(entries.compactMap(\.project))
        let sentences = answer.split(whereSeparator: { ".!?".contains($0) }).map { " " + normalize(String($0)) + " " }
        for sentence in sentences {
            for project in projects where mentions(sentence, project: project) {
                // "In Diskarte I implemented this exact solution": the generated code was never part of a project.
                if sentence.range(of: #"\b(this|that) (exact|same)\b|\bthe same (function|solution|code|approach)\b|\bthis exact\b"#, options: .regularExpression) != nil,
                   sentence.range(of: #"\bi (implemented|built|wrote|used|did)\b"#, options: .regularExpression) != nil {
                    return "claims the generated code was used in \(project); that is not in your memory"
                }
                let known = " " + normalize(entries.filter { $0.project == project }.map { $0.title + " " + $0.text }.joined(separator: " ")) + " "
                for tech in technologies where sentence.contains(" " + tech + " ") && !known.contains(" " + tech) {
                    return "claims \(tech) in \(project) without support in your memory"
                }
            }
        }
        return nil
    }

    // MARK: Vocabulary

    /// Matches "KindaMoving" / "kinda moving", and a multi-word name's leading acronym ("BMR", "YYC").
    nonisolated static func mentions(_ normalizedText: String, project: String) -> Bool {
        let name = normalize(project)
        if normalizedText.replacingOccurrences(of: " ", with: "").contains(name.replacingOccurrences(of: " ", with: "")) { return true }
        let words = name.split(separator: " ")
        return words.count > 1 && words[0].count >= 3 && (" " + normalizedText + " ").contains(" \(words[0]) ")
    }

    nonisolated static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.+#/ -]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\w)[.,](?=\s|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Concept → phrases that signal it (in questions and in memory text alike).
    nonisolated static let conceptMap: [String: [String]] = [
        "realtime": ["real-time", "realtime", "real time", "live ", "websocket", "messaging", "telemetry", "read receipts"],
        "python": ["python", "fastapi"],
        "security": ["secur", "row-level", "row level", " rls", "access control", "authoriz", "permission", "polic"],
        "database": ["database", " db ", "postgres", "sql", "supabase", "prisma", "postgis", "schema", "table"],
        "auth": ["authentic", " auth", "login", "sign-in", "sign in"],
        "testing": ["test"],
        "deployment": ["deploy", "vercel", "render", "hosting", "ci/cd"],
        "api": [" api", "rest", "endpoint", "integration"],
        "audio": ["audio", "ffmpeg", "sound", "guitar", "tone"],
        "maps": [" map", "route", "gps", "gpx", "postgis", "station"],
        "jobs": ["background", " job", "queue", "durable", "worker"],
        "analytics": ["analytic", "dashboard", "report", "metric", "aggregation", "performance analysis"],
        "video": ["video", "voice", "livekit", "call"],
        "frontend": ["react", "next.js", "nextjs", "frontend", "front end", " ui"],
        "javascript": ["javascript", "typescript", "node.js", "node "],
        "prediction": ["predict", "model", "forecast"],
        "education": ["study", "studied", "school", "college", "education", "diploma", "degree", "graduat", "sait"],
    ]

    nonisolated static func concepts(in text: String) -> Set<String> {
        Set(conceptMap.filter { $0.value.contains { text.contains($0) } }.map(\.key))
    }

    nonisolated static let personalCues = [" have you ", " did you ", " you built ", " you used ", " you've ", " your project",
                                           " your experience", " experience with ", " have you used ", " how have you ", " you worked ",
                                           " tell me about a project", " tell me about your", " you implement", " your app", " you chose ",
                                           " why did you ", " in your ", " your background", " you studied", " your education"]

    /// Technologies that may only be claimed for a project when its memory mentions them.
    nonisolated static let technologies = [
        "kubernetes", "docker", "redis", "graphql", "mongodb", "mysql", "aws", "azure", "firebase", "django", "flask",
        "angular", "vue", "svelte", "kafka", "rabbitmq", "websocket", "websockets", "stripe", "terraform", "jest", "vitest",
        "playwright", "cypress", "pytest", "prisma", "supabase", "postgis", "fastapi", "ffmpeg", "livekit", "mongoose",
        "tailwind", "vercel", "celery", "sqlite", "dynamodb", "openai", "tensorflow", "pytorch", "pandas", "numpy", "express",
    ]

    // MARK: Seed (the user's own description; nothing invented)

    nonisolated static let seed: [MemoryEntry] = [
        .init(kind: .profile, title: "Education", text: "SAIT Software Development diploma graduate."),
        .init(kind: .profile, title: "Technical background", text: "Primary development experience: JavaScript, TypeScript, React, Next.js, Node.js, Python, PostgreSQL, Supabase, REST APIs, authentication, testing, and application deployment."),
        .init(kind: .profile, title: "Communication style", text: "Casual but professional, technically accurate, natural to speak aloud, direct and practical, usually 3–5 sentences. Not jargon-heavy, not overly formal, no corporate buzzwords. Explains technical decisions naturally without exaggerating experience."),
        .init(kind: .project, title: "Diskarte", project: "Diskarte", text: "Next.js communication platform. Supabase authentication and database. Realtime messaging. LiveKit voice and video. Read receipts. Group conversations. Notifications. Access controls and security. Testing and deployment."),
        .init(kind: .project, title: "KindaMoving", project: "KindaMoving", text: "Running analytics platform. Next.js and TypeScript. Supabase and PostgreSQL/PostGIS. Python FastAPI computation services. GPX/FIT activity processing. Route planning. Running performance analysis. COROS integration. Durable background jobs."),
        .init(kind: .project, title: "Resoniq", project: "Resoniq", text: "Guitar-tone sharing platform. Next.js, TypeScript and Supabase. PostgreSQL and Prisma. Audio analysis and background processing. Python and FFmpeg. Authentication and row-level security."),
        .init(kind: .project, title: "FJuan", project: "FJuan", text: "Formula 1 analytics dashboard. Next.js and TypeScript. OpenF1 and Jolpica APIs. Live telemetry. Historical race data. Driver comparisons. Prediction modeling."),
        .init(kind: .project, title: "YYC Track", project: "YYC Track", text: "Public transit feedback and analytics. MERN architecture (MongoDB, Express, React, Node.js). Interactive maps. Station ratings. User feedback. Administrative analytics."),
        .init(kind: .project, title: "BMR Pharmacy Sales Tracker", project: "BMR Pharmacy Sales Tracker", text: "React frontend. Node.js and Express backend. PostgreSQL database. Sales and product reporting. SQL aggregation. Vercel and Render deployment."),
    ]

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
