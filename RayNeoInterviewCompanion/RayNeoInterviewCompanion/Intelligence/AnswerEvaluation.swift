import Foundation
import Observation

/// Offline evaluation questions. Math expectations are exact; others list terms a relevant answer must use.
nonisolated struct EvaluationItem: Sendable, Identifiable {
    let id: Int
    let question: String
    let category: QuestionCategory
    let expected: [String]

    static let all: [EvaluationItem] = {
        let raw: [(String, QuestionCategory, [String])] = [
            ("What is 5000×592?", .math, ["2,960,000"]),
            ("What's 5000 times 592?", .math, ["2,960,000"]),
            ("What's 15% of 240?", .math, ["36"]),
            ("What is 2 to the power of 8?", .math, ["256"]),
            ("What's the average of 12, 18, and 24?", .math, ["18"]),
            ("What is 3 plus 4 times 2?", .math, ["11"]),
            ("What is (3 + 4) × 2?", .math, ["14"]),
            ("What is 7.5 divided by 2.5?", .math, ["3"]),
            ("What's negative 12 plus 30?", .math, ["18"]),
            ("What is 1200 multiplied by 1.08?", .math, ["1,296"]),
            ("What is 10 divided by 0?", .math, ["divides by zero"]),
            ("What is twelve times twelve?", .math, ["144"]),
            ("What's 0.1 plus 0.2?", .math, ["0.3"]),
            ("What is 999 squared?", .math, ["998,001"]),
            ("What does HTTP 401 mean?", .factual, ["authenticat"]),
            ("What does HTTP 403 mean?", .factual, ["forbidden", "permission", "access"]),
            ("What is a REST API?", .factual, ["http", "resource"]),
            ("What is the purpose of a database index?", .factual, ["quer", "faster", "lookup"]),
            ("What is a foreign key?", .factual, ["table", "reference"]),
            ("What does DNS do?", .factual, ["domain", "ip", "name"]),
            ("What is MFA?", .factual, ["factor"]),
            ("What is Microsoft Entra ID?", .factual, ["identity", "azure", "sign"]),
            ("What is a primary key?", .factual, ["unique", "row", "identif"]),
            ("What is CI/CD?", .factual, ["integration", "deploy"]),
            ("What port does HTTPS use?", .factual, ["443"]),
            ("What is a 500 error?", .factual, ["server"]),
            ("How would you troubleshoot a Microsoft 365 login issue?", .technical, ["sign-in", "license", "mfa", "password", "account"]),
            ("How would you debug a Salesforce integration that stopped syncing?", .technical, ["log", "api", "auth", "mapping"]),
            ("What's the difference between authentication and authorization?", .technical, ["identity", "permission", "access", "who"]),
            ("Explain async/await.", .technical, ["promise", "asynchronous"]),
            ("How would you investigate a slow SQL query?", .technical, ["index", "explain", "plan"]),
            ("Walk me through how you'd handle a failed deployment.", .technical, ["rollback", "log", "roll back"]),
            ("How would you secure a REST API?", .technical, ["auth", "token", "https"]),
            ("How do you troubleshoot a user who can't connect to Wi-Fi?", .technical, ["network", "dns", "ip", "router", "adapter"]),
            ("How would you set up Row Level Security in Postgres?", .technical, ["policy", "policies", "enable"]),
            ("How would you handle a Moodle enrolment sync failure?", .technical, ["log", "sync", "enrol"]),
            ("Tell me about how you'd monitor an integration.", .technical, ["log", "alert", "monitor"]),
            ("How would you respond if Teams calls keep dropping?", .technical, ["network", "bandwidth", "client", "update"]),
            ("Describe how you'd normalize a database.", .technical, ["normal form", "redundan", "table"]),
            ("How would you handle API rate limits?", .technical, ["retry", "backoff", "limit"]),
            ("Write a function that removes duplicates from an array.", .coding, ["set"]),
            ("Explain a React useEffect dependency array.", .coding, ["render", "run", "dependenc"]),
            ("How would you implement API error handling in TypeScript?", .coding, ["try", "catch", "error"]),
            ("What's the time complexity of looking up a key in a hash map?", .coding, ["o(1)", "constant"]),
            ("Find the bug: const total = items.map(i => i.price).reduce((a, b) => a + b)", .coding, ["initial", "empty", "0"]),
            ("Write a SQL query to count users per country.", .coding, ["group by", "count"]),
            ("How would you debounce a search input in JavaScript?", .coding, ["timeout", "settimeout", "debounce"]),
            ("Explain useState in React.", .coding, ["state", "render"]),
            ("What about that?", .ambiguous, ["detail"]),
            ("Can you explain it?", .ambiguous, ["detail"]),
            ("How does it work?", .ambiguous, ["detail"]),
            ("Why?", .ambiguous, ["detail"]),
        ]
        return raw.enumerated().map { EvaluationItem(id: $0.offset, question: $0.element.0, category: $0.element.1, expected: $0.element.2) }
    }()
}

/// Runs the evaluation set through the real answer pipeline with the selected provider, on the device.
@MainActor @Observable final class AnswerEvaluationRunner {
    struct Row: Identifiable {
        let id: Int
        let question: String
        let expectedCategory: QuestionCategory
        let category: QuestionCategory
        let passed: Bool
        let nonAnswer: Bool
        let seconds: Double
        let firstToken: Double?
        let words: Int
        let answer: String
        let firstSentence: Double?
        let failed: Bool
        let quota: Bool
    }

    private(set) var rows: [Row] = []
    private(set) var running = false
    private(set) var providerName = ""
    private(set) var memoryMB = 0.0
    /// Summaries of completed runs by provider, for comparing Apple and Gemini on this device.
    private(set) var history: [String: String] = [:]
    private var task: Task<Void, Never>?

    var summary: String {
        guard !rows.isEmpty else { return "Not run yet" }
        func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "–" : "\(part * 100 / whole)%" }
        let math = rows.filter { $0.expectedCategory == .math }
        let model = rows.filter { $0.expectedCategory != .math && $0.expectedCategory != .ambiguous }
        let latencies = rows.map(\.seconds).sorted()
        let modelLatencies = model.map(\.seconds).sorted()
        func quantile(_ values: [Double], _ q: Double) -> String {
            values.isEmpty ? "–" : String(format: "%.2fs", values[min(values.count - 1, Int(Double(values.count - 1) * q))])
        }
        return """
        Provider: \(providerName)
        Questions: \(rows.count); routing matched expectation: \(percent(rows.filter { $0.category == $0.expectedCategory }.count, rows.count))
        Numerical accuracy: \(percent(math.filter(\.passed).count, math.count))
        Model answers mentioning expected terms: \(percent(model.filter(\.passed).count, model.count))
        Non-answer rate: \(percent(rows.filter(\.nonAnswer).count, rows.count))
        Average length: \(rows.isEmpty ? 0 : rows.map(\.words).reduce(0, +) / rows.count) words
        Latency all: median \(quantile(latencies, 0.5)), p95 \(quantile(latencies, 0.95))
        Latency model answers: median \(quantile(modelLatencies, 0.5)), p95 \(quantile(modelLatencies, 0.95))
        First complete sentence (model): median \(quantile(model.compactMap(\.firstSentence).sorted(), 0.5))
        First model answer (cold start): \(model.first.map { String(format: "%.2fs", $0.seconds) } ?? "–")
        Failures: \(percent(model.filter(\.failed).count, model.count)) · quota (429): \(percent(model.filter(\.quota).count, model.count))
        Memory footprint after run: \(String(format: "%.0f MB", memoryMB))
        """
    }

    var report: String {
        summary + "\n\n" + rows.map { row in
            "[\(row.passed ? "PASS" : "FAIL")] \(row.expectedCategory.rawValue)→\(row.category.rawValue) \(String(format: "%.2fs", row.seconds)) | \(row.question) | \(row.answer)"
        }.joined(separator: "\n")
    }

    func run(provider: any AIResponseProvider, instructions: @escaping (QuestionCategory) -> String,
             notes: @escaping (String) -> [String], length: AnswerLength) {
        guard !running else { return }
        running = true
        rows = []
        providerName = provider.name
        task = Task { [weak self] in
            for item in EvaluationItem.all {
                guard let self, !Task.isCancelled else { break }
                let pipeline = AnswerPipeline(provider: provider, instructions: instructions, notes: notes,
                                              answerLength: length, hasPortfolio: false)
                let started = Date()
                var text = "", category = item.category, firstToken: Double?, firstSentence: Double?
                var failed = false, quota = false
                do {
                    let output = try await pipeline.answer(item.question, previous: nil)
                    text = output.text; category = output.category; firstToken = output.firstTokenSeconds
                    firstSentence = output.firstSentenceSeconds
                } catch {
                    text = "ERROR: \(error.localizedDescription)"
                    failed = true
                    if case .rateLimited? = error as? GeminiError { quota = true }
                }
                let lower = text.lowercased()
                let nonAnswer = text == AnswerValidator.honestFallback || text.hasPrefix("ERROR")
                    || (item.category != .ambiguous && !AnswerValidator.validate(text, question: item.question, category: category, hasPortfolio: false).passed)
                let passed = item.expected.contains { lower.contains($0.lowercased()) }
                self.rows.append(Row(id: item.id, question: item.question, expectedCategory: item.category, category: category,
                                     passed: passed, nonAnswer: nonAnswer, seconds: Date().timeIntervalSince(started),
                                     firstToken: firstToken, words: text.split(separator: " ").count, answer: text,
                                     firstSentence: firstSentence, failed: failed, quota: quota))
            }
            self?.memoryMB = AppModel.memoryFootprintMB()
            self?.running = false
            if let self { self.history[self.providerName] = self.summary }
            if let self { DiagnosticLog.shared.record(.pipeline, "Evaluation finished: \(self.summary.replacingOccurrences(of: "\n", with: " · "))") }
        }
    }

    func cancel() { task?.cancel(); running = false }
}
