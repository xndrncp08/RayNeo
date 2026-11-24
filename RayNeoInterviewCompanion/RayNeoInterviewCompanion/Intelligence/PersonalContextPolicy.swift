import Foundation

/// When personal memory (projects, profile, portfolio) belongs in an answer. Technical overlap alone is never
/// enough: "investigate an incident across the frontend, backend and PostgreSQL" shares every technology with a
/// project, but it asks how to investigate, not about that project.
nonisolated enum PersonalContextPolicy {
    struct Decision: Equatable, Sendable {
        var wanted: Bool
        var reason: String
    }

    /// Wording that asks about the developer's own work. (" in your " alone is too broad: "in your production
    /// environment" is hypothetical.)
    static let cues = PersonalMemoryStore.personalCues.filter { $0 != " in your " } + [
        " in your project", " in your experience", " in your previous", " in your last", " in your past", " in your work",
        " in your own", " your projects", " your portfolio", " your resume", " you've built", " you have built",
        " you've worked", " you have worked", " worked on ", " how does that apply", " how would your experience",
        " apply to your", " relate to your", " any experience", " tell me about yourself", " your role ", " your past ",
        " previous project", " past project", " a project where", " give me an example from",
    ]

    static func decide(_ question: String, projects: [String], activeProject: String?) -> Decision {
        let query = " " + PersonalMemoryStore.normalize(question) + " "
        if let named = projects.first(where: { PersonalMemoryStore.mentions(query, project: $0) }) {
            return Decision(wanted: true, reason: "names \(named)")
        }
        if let cue = cues.first(where: { query.contains($0) }) {
            return Decision(wanted: true, reason: "asks about your own experience (\"\(cue.trimmingCharacters(in: .whitespaces))\")")
        }
        let intent = InterviewIntent.classify(question, hasContext: activeProject != nil)
        if intent.kind == .behavioural { return Decision(wanted: true, reason: "behavioural question") }
        // "What database did that use?" right after a project answer stays on that project.
        let short = query.split(separator: " ").count <= 10
        let pronoun = query.range(of: #" (it|its|that|this|they|them|there) "#, options: .regularExpression) != nil
        if let activeProject, intent.kind == .followUp || ContextReference.detect(question).refersBack || short && pronoun {
            return Decision(wanted: true, reason: "follow-up about \(activeProject)")
        }
        return Decision(wanted: false, reason: "general \(intent.kind.label) question")
    }

    /// First-person past-experience claims and project references ("When I was troubleshooting my BMR Pharmacy
    /// Sales Tracker…"): never wanted in an answer to a general or hypothetical question.
    static let pastExperience = [
        #"\bin my (own |personal |previous |last |recent |side |school |capstone |past )?(project|projects|app|application|tracker|system|work|internship|job|role|experience|portfolio|codebase)\b"#,
        #"\bwhen i (was |were )?(work(ed|ing)|built|build(ing)?|debugg(ed|ing)|troubleshot|troubleshooting|ran into|had|deployed|developed|fixing|fixed)\b"#,
        #"\bi('ve| have) (dealt|debugged|troubleshot|handled|seen|run into|built|worked|faced|encountered|fixed|had to)\b"#,
        #"\bi (once|previously|recently|actually) (\w+ )?(debugged|troubleshot|fixed|built|handled|ran into|faced|encountered|worked|had|saw|used|deployed)\b"#,
        #"\bmy [a-z0-9 ]{0,40}(tracker|project|app|application|dashboard|platform) (had|ran|used|uses|has|was)\b"#,
        #"\bthat'?s (exactly )?what i did\b"#, #"\bfor example,? (in|on|with) my\b"#, #"\bi remember (when|a time)\b"#,
        #"\bfrom my (own )?experience\b"#, #"\bin a (previous|past|recent) project\b"#,
    ]

    static func anecdotes(in answer: String, projects: [String]) -> [String] {
        var sentences: [String] = []
        answer.enumerateSubstrings(in: answer.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences.filter { sentence in
            let normalized = " " + PersonalMemoryStore.normalize(sentence) + " "
            return projects.contains { PersonalMemoryStore.mentions(normalized, project: $0) }
                || pastExperience.contains { sentence.lowercased().range(of: $0, options: .regularExpression) != nil }
        }
    }

    /// The answer without those sentences (unchanged when nothing would remain).
    static func removing(_ anecdotes: [String], from answer: String) -> String {
        var result = answer
        for sentence in anecdotes { result = result.replacingOccurrences(of: sentence, with: "") }
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? answer : result
    }
}
