import Foundation
import Security

/// Keychain storage for the user's Gemini API key: never in settings, source, or logs.
enum GeminiKeychain {
    private static let service = "com.derrancap.RayNeoInterviewCompanion.gemini"
    private static let account = "api-key"

    static func save(_ key: String) -> Bool {
        delete()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: Data(key.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult static func delete() -> Bool {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary) == errSecSuccess
    }
}

enum GeminiError: LocalizedError, Equatable {
    case notConsented, missingKey, rateLimited(String), unauthorized(String), badRequest(String)
    case modelUnavailable(String), server(Int, String), offline(String), timedOut, emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConsented: "Gemini is off until you opt in (Settings › AI)."
        case .missingKey: "No Gemini API key saved."
        case .rateLimited(let message): "Gemini free-tier limit reached (429 RESOURCE_EXHAUSTED): \(message)"
        case .unauthorized(let message): "Gemini rejected the API key: \(message)"
        case .badRequest(let message): "Gemini rejected the request: \(message)"
        case .modelUnavailable(let message): "Gemini model unavailable: \(message)"
        case .server(let code, let message): "Gemini server error \(code): \(message)"
        case .offline(let message): "No connection to Gemini: \(message)"
        case .timedOut: "Gemini did not respond in time."
        case .emptyResponse: "Gemini returned no text."
        }
    }

    /// Failures where answering on-device instead is appropriate.
    var allowsFallback: Bool {
        switch self {
        case .badRequest: false
        default: true
        }
    }
}

/// Gemini Developer API (cloud, free tier) via the official REST endpoint
/// `POST /v1beta/models/{model}:streamGenerateContent?alt=sse` with the `x-goog-api-key` header.
/// Sends only: the category instructions, the question, matching knowledge-base notes and (for follow-ups)
/// the previous question and answer. No audio, no transcript history, no portfolio unless enabled.
@MainActor final class GeminiProvider: AIResponseProvider {
    var model = GeminiModel.flashLite.rawValue
    var consented = false
    var keyProvider: () -> String? = { GeminiKeychain.load() }
    var bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
    var session: URLSession = .shared
    var timeout: TimeInterval = 20
    /// Last measured time from request to HTTP response headers (network latency).
    private(set) var lastNetworkSeconds: Double?
    private(set) var lastHTTPStatus: Int?
    /// `finishReason` of the last streamed response (e.g. STOP, MAX_TOKENS, SAFETY).
    private(set) var lastFinishReason: String?

    var name: String { "Gemini \(model) (cloud)" }
    var lastStopReason: String? { lastFinishReason }

    var status: AIStatus {
        guard consented else { return .unavailable("Gemini not enabled (opt in under Settings › AI)") }
        guard keyProvider()?.isEmpty == false else { return .unavailable("no Gemini API key saved") }
        return .ready
    }

    func prewarm(instructions: String) {} // nothing to warm for a stateless REST call

    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task { @MainActor in
            do {
                var text = ""
                for try await delta in try await self.deltas(for: request) {
                    text += delta
                    continuation.yield(text)
                }
                guard !text.isEmpty else { throw GeminiError.emptyResponse }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func isInterviewQuestion(_ text: String) async -> Bool? { nil } // never sends borderline speech to the cloud

    struct ConnectionReport: Equatable {
        enum Outcome: String {
            case ok = "Connected"
            case invalidKey = "Invalid or restricted API key"
            case unsupportedModel = "Model not found or unsupported"
            case quota = "Free-tier quota exceeded (429)"
            case network = "Network failure"
            case notSetUp = "Not set up"
            case other = "Failed"
        }
        var outcome: Outcome
        var model: String
        var modelCheck = "not checked"
        var httpStatus: Int?
        var firstTokenSeconds: Double?
        var totalSeconds: Double?
        var finishReason: String?
        var response = ""
        var detail = ""

        var summary: String {
            [
                "Result: \(outcome.rawValue)",
                "Model: \(model) — \(modelCheck)",
                "HTTP status: \(httpStatus.map(String.init) ?? "–")",
                "First token: \(firstTokenSeconds.map { String(format: "%.2f s", $0) } ?? "–")",
                "Total: \(totalSeconds.map { String(format: "%.2f s", $0) } ?? "–")",
                "Finish reason: \(finishReason ?? "–")",
                "Response: \(response.isEmpty ? "–" : response)",
            ].joined(separator: "\n") + (detail.isEmpty ? "" : "\nDetail: \(detail)")
        }
    }

    /// User-triggered real request: (1) `models.get` confirms the model exists and lists `generateContent`
    /// (whose streaming form is `streamGenerateContent`); (2) one minimal streamed generation. The key is never shown.
    func testConnection() async -> ConnectionReport {
        var report = ConnectionReport(outcome: .other, model: model)
        guard let key = keyProvider(), !key.isEmpty else {
            report.outcome = .notSetUp
            report.detail = "No API key saved."
            return report
        }
        do {
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model)")!
            let (data, response) = try await session.data(for: makeRequest(url, key: key, method: "GET"))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            report.httpStatus = status
            let body = String(data: data, encoding: .utf8) ?? ""
            guard status == 200 else { throw Self.error(status: status, body: Self.redact(body, key)) }
            let methods = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") || methods.contains("streamGenerateContent") else {
                report.outcome = .unsupportedModel
                report.modelCheck = "exists, but supports only: \(methods.joined(separator: ", "))"
                return report
            }
            report.modelCheck = "exists, supports generateContent"

            let started = Date()
            let wasConsented = consented
            consented = true // the user tapped Test: one explicit request
            defer { consented = wasConsented }
            var text = ""
            for try await delta in try await deltas(for: AnswerRequest(instructions: "Reply with exactly: Connection OK",
                                                                       prompt: "Connection test.", maximumTokens: 64), key: key) {
                if report.firstTokenSeconds == nil { report.firstTokenSeconds = Date().timeIntervalSince(started) }
                text += delta
            }
            report.totalSeconds = Date().timeIntervalSince(started)
            report.httpStatus = lastHTTPStatus
            report.finishReason = lastFinishReason
            report.response = String(text.prefix(200))
            if text.isEmpty {
                report.outcome = .other
                report.detail = lastFinishReason == "MAX_TOKENS"
                    ? "No text before the token limit (the model may have spent it on thinking)."
                    : "The model returned no text."
            } else {
                report.outcome = .ok
            }
        } catch let error as GeminiError {
            report.httpStatus = report.httpStatus == 200 ? lastHTTPStatus : report.httpStatus
            report.outcome = switch error {
            case .unauthorized: .invalidKey
            case .modelUnavailable: .unsupportedModel
            case .rateLimited: .quota
            case .offline, .timedOut: .network
            case .notConsented, .missingKey: .notSetUp
            default: .other
            }
            report.detail = Self.redact(error.localizedDescription, key)
        } catch let error as URLError {
            report.outcome = .network
            report.detail = error.localizedDescription
        } catch {
            report.detail = Self.redact(error.localizedDescription, key)
        }
        return report
    }

    nonisolated static func redact(_ text: String, _ key: String) -> String {
        key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[key]")
    }

    // MARK: Transport

    static func requestBody(_ request: AnswerRequest) throws -> Data {
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": request.instructions]]],
            "contents": [["role": "user", "parts": [["text": request.prompt]]]],
            "generationConfig": ["maxOutputTokens": request.maximumTokens],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The documented streaming route. Kept as one constant so a test can pin it exactly.
    nonisolated static func streamURL(model: String) -> URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
    }

    private func makeRequest(_ url: URL, key: String, method: String) -> URLRequest {
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        // Lets an API key restricted to this iOS bundle (Google Cloud key restrictions) be accepted.
        urlRequest.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        return urlRequest
    }

    private func deltas(for request: AnswerRequest, key explicitKey: String? = nil) async throws -> AsyncThrowingStream<String, Error> {
        guard consented else { throw GeminiError.notConsented }
        guard let key = explicitKey ?? keyProvider(), !key.isEmpty else { throw GeminiError.missingKey }
        var urlRequest = makeRequest(Self.streamURL(model: model), key: key, method: "POST")
        urlRequest.httpBody = try Self.requestBody(request)
        lastHTTPStatus = nil
        lastFinishReason = nil

        let started = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError {
            throw error.code == .timedOut ? GeminiError.timedOut : GeminiError.offline(error.localizedDescription)
        }
        lastNetworkSeconds = Date().timeIntervalSince(started)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        lastHTTPStatus = statusCode
        guard statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 2_000 { break } }
            throw Self.error(status: statusCode, body: Self.redact(body, key))
        }
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let reader = Task { @MainActor in
            do {
                for try await line in bytes.lines {
                    if let reason = Self.finishReason(line) { self.lastFinishReason = reason }
                    if let delta = try Self.parseEvent(line) { continuation.yield(delta) }
                }
                continuation.finish()
            } catch let error as URLError {
                continuation.finish(throwing: error.code == .timedOut ? GeminiError.timedOut : GeminiError.offline(error.localizedDescription))
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reader.cancel() }
        return stream
    }

    /// One SSE line → the text delta it carries (nil for keep-alives, empty or non-text events).
    nonisolated static func parseEvent(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] {
            throw Self.error(status: error["code"] as? Int ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // Skip "thought" parts; only answer text is used.
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    nonisolated static func finishReason(_ line: String) -> String? {
        guard line.hasPrefix("data:"), let data = line.dropFirst(5).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ((json["candidates"] as? [[String: Any]])?.first)?["finishReason"] as? String
    }

    nonisolated static func error(status: Int, body: String) -> GeminiError {
        let message: String = {
            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = json["error"] as? [String: Any] else { return String(body.prefix(200)) }
            return [error["status"] as? String, error["message"] as? String].compactMap { $0 }.joined(separator: ": ")
        }()
        // An invalid key is reported as 400 INVALID_ARGUMENT with reason API_KEY_INVALID, not 401/403.
        if body.contains("API_KEY_INVALID") || body.localizedCaseInsensitiveContains("API key not valid") { return .unauthorized(message) }
        if status == 400, body.localizedCaseInsensitiveContains("is not supported for") { return .modelUnavailable(message) }
        switch status {
        case 429: return .rateLimited(message)
        case 401, 403: return .unauthorized(message)
        case 404: return .modelUnavailable(message)
        case 400: return .badRequest(message)
        default: return .server(status, message)
        }
    }
}

/// Cloud provider with an explicit, opt-in on-device fallback. Falls back only if the cloud fails BEFORE
/// producing any text, so an answer is never a splice of two models. Never substitutes another cloud.
@MainActor final class CloudFailoverProvider: AIResponseProvider {
    let gemini: GeminiProvider
    let fallback: any AIResponseProvider
    var fallbackEnabled = true
    /// Which provider produced the most recent answer (shown in the UI).
    private(set) var lastUsed: String = ""
    private var lastUsedProvider: (any AIResponseProvider)?
    var lastStopReason: String? { lastUsedProvider?.lastStopReason }

    init(gemini: GeminiProvider, fallback: any AIResponseProvider) {
        self.gemini = gemini
        self.fallback = fallback
    }

    var name: String {
        if gemini.status == .ready { return gemini.name }
        return fallbackEnabled ? "\(fallback.name) (Gemini unavailable)" : gemini.name
    }

    var status: AIStatus {
        if gemini.status == .ready { return .ready }
        return fallbackEnabled ? fallback.status : gemini.status
    }

    func prewarm(instructions: String) { fallback.prewarm(instructions: instructions) }
    func isInterviewQuestion(_ text: String) async -> Bool? { await fallback.isInterviewQuestion(text) }

    func streamAnswer(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task { @MainActor in
            var produced = false
            do {
                if self.gemini.status == .ready {
                    for try await text in self.gemini.streamAnswer(request) { produced = true; continuation.yield(text) }
                    self.lastUsed = self.gemini.name
                    self.lastUsedProvider = self.gemini
                    return continuation.finish()
                }
                guard self.fallbackEnabled else { throw GeminiError.notConsented }
            } catch {
                let canFallBack = !produced && self.fallbackEnabled && ((error as? GeminiError)?.allowsFallback ?? true) && !(error is CancellationError)
                guard canFallBack else { return continuation.finish(throwing: error) }
                DiagnosticLog.shared.record(.pipeline, "Gemini failed before any text (\(error.localizedDescription)); answering on-device")
            }
            do {
                for try await text in self.fallback.streamAnswer(request) { continuation.yield(text) }
                self.lastUsed = self.fallback.name
                self.lastUsedProvider = self.fallback
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
