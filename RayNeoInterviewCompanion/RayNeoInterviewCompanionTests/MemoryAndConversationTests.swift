import Foundation
import Testing
@testable import RayNeoInterviewCompanion

// MARK: Personal memory

@MainActor @Suite struct PersonalMemoryTests {
    let store = PersonalMemoryStore(url: nil)

    /// Retrieval accuracy over the seeded profile (top-3). Reported in the handoff.
    static let cases: [(question: String, expected: String)] = [
        ("Have you worked with real-time systems?", "Diskarte"),
        ("How have you used Python?", "KindaMoving"),
        ("How have you used Python?", "Resoniq"),
        ("How did you secure your database?", "Resoniq"),
        ("Tell me about KindaMoving.", "KindaMoving"),
        ("How does the kinda moving route planning work?", "KindaMoving"),
        ("What did you build with LiveKit?", "Diskarte"),
        ("Have you worked with audio processing?", "Resoniq"),
        ("Tell me about your Formula 1 dashboard.", "FJuan"),
        ("Have you built anything with interactive maps?", "YYC Track"),
        ("How did you do SQL aggregation for the sales reports?", "BMR Pharmacy Sales Tracker"),
        ("What about the BMR project?", "BMR Pharmacy Sales Tracker"),
        ("Have you used MongoDB?", "YYC Track"),
        ("Have you done background jobs?", "KindaMoving"),
        ("Where did you study?", "Education"),
    ]

    @Test func retrievalFindsTheRightProjectForPersonalQuestions() {
        var hits = 0
        for item in Self.cases {
            let retrieval = store.retrieve(item.question)
            let found = retrieval.entries.contains { ($0.project ?? $0.title) == item.expected }
            if found { hits += 1 } else { Issue.record("\(item.question) → \(retrieval.references), expected \(item.expected)") }
        }
        #expect(hits == Self.cases.count)
    }

    @Test func genericTechnicalQuestionsGetNoForcedProjectExample() {
        #expect(store.retrieve("What is a REST API?").entries.isEmpty)
        #expect(store.retrieve("What does HTTP 401 mean?").entries.isEmpty)
        #expect(store.retrieve("Explain a React useEffect dependency array.").entries.isEmpty)
    }

    @Test func retrievalStaysWithinTheContextBudget() {
        for budget in [150, 300, 900] {
            let retrieval = store.retrieve("Have you used Next.js, Supabase and PostgreSQL in your projects?", budget: budget)
            #expect(retrieval.text.count <= budget)
            #expect(!retrieval.entries.isEmpty)
        }
    }

    @Test func similarProjectsAreDisambiguatedByName() {
        let retrieval = store.retrieve("In Resoniq, how did you use Supabase and Next.js?")
        #expect(retrieval.entries.first?.project == "Resoniq")
    }

    @Test func topicProjectResolvesVagueFollowUps() {
        let retrieval = store.retrieve("What about security?", topicProject: "Diskarte")
        #expect(retrieval.entries.first?.project == "Diskarte")
    }

    @Test func entriesCanBeUpdatedDeletedPersistedAndExported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersonalMemoryStore(url: url)
        var education = try #require(store.profile.first { $0.title == "Education" })
        education.text = "SAIT Software Development diploma, graduated 2025."
        store.upsert(education)
        store.upsert(MemoryEntry(kind: .profile, title: "Certifications", text: "AWS Cloud Practitioner (studying)."))
        let reloaded = PersonalMemoryStore(url: url)
        #expect(reloaded.profile.contains { $0.text.contains("graduated 2025") })
        #expect(reloaded.profile.contains { $0.title == "Certifications" })
        reloaded.delete(education.id)
        #expect(!reloaded.profile.contains { $0.id == education.id })
        #expect(reloaded.export().contains("Certifications"))
        reloaded.deletePersonalMemory()
        #expect(reloaded.entries.isEmpty)
        reloaded.restoreSeed()
        #expect(reloaded.projects.count == 6)
    }

    @Test func unsupportedPersonalClaimsAreDetected() {
        let entries = store.entries
        #expect(PersonalMemoryStore.unsupportedClaim(in: "In Diskarte I used Redis to cache messages.", entries: entries) != nil)
        #expect(PersonalMemoryStore.unsupportedClaim(in: "I used Kubernetes to deploy KindaMoving.", entries: entries) != nil)
        #expect(PersonalMemoryStore.unsupportedClaim(in: "In Diskarte I used Supabase for realtime messaging and LiveKit for video.", entries: entries) == nil)
        #expect(PersonalMemoryStore.unsupportedClaim(in: "Resoniq uses FFmpeg and Python for audio analysis.", entries: entries) == nil)
        #expect(PersonalMemoryStore.unsupportedClaim(in: "Redis is an in-memory store.", entries: entries) == nil) // no project claim
    }

    @Test func unsupportedClaimTriggersRegeneration() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let ai = MockAIProvider()
        ai.queuedAnswers = ["Yeah, I worked with real-time messaging in Diskarte using Redis pub/sub for read receipts."]
        ai.answer = "Yeah, I worked with real-time messaging in Diskarte using Supabase. I had to handle message delivery, read receipts and reconnect behavior."
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: GlassesPresenter(display: glasses))
        let entries = store.entries
        engine.groundingCheck = { PersonalMemoryStore.unsupportedClaim(in: $0, entries: entries) }
        engine.start()
        await engine.handle(CompletedTurn(text: "Have you worked with real-time systems?", start: 0, end: 2))
        await engine.generationTask?.value
        #expect(ai.requests.count == 2)
        #expect(ai.requests.last?.instructions.lowercased().contains("redis") == true) // the rejection reason is fed back
        #expect(engine.currentAnswer?.text == ai.answer)
        #expect(engine.currentAnswer?.regenerated == true)
    }
}

// MARK: Repository import

@Suite struct RepositoryImporterTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("README.md", """
        # Diskarte

        Diskarte is a communication platform with realtime messaging, read receipts and group conversations.

        ## Setup
        Copy the example and set API_KEY=abcd1234efgh5678 before running the dev server locally with npm run dev.
        """)
        try write("package.json", #"{"name":"diskarte","scripts":{"test":"vitest"},"dependencies":{"next":"15.0.0","react":"19.0.0","@supabase/supabase-js":"2.0.0","livekit-client":"2.0.0"},"devDependencies":{"vitest":"2.0.0","typescript":"5.0.0"}}"#)
        try write("supabase/migrations/001_messages.sql", """
        create table public.messages (id uuid primary key, body text);
        alter table public.messages enable row level security;
        create policy "members read" on public.messages for select using (auth.uid() = sender);
        """)
        try write("src/app/api/messages/route.ts", "export async function GET(request: Request) { return Response.json([]) }")
        try write("docs/architecture.md", "# Architecture\n\nMessages flow through Supabase Realtime channels; LiveKit rooms handle voice and video calls between members.")
        try write("vercel.json", "{}")
        try write(".env.local", "SUPABASE_SERVICE_ROLE_KEY=super-secret-value-123")
        try write("keys/server.pem", "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----")
        try write("node_modules/left-pad/README.md", "# left-pad\n\nThis package must never be indexed because node_modules is skipped.")
        return root
    }

    @Test func importBuildsAGroundedSummaryWithSourcesAndNoSecrets() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try RepositoryImporter.importRepository(at: root)
        let summary = project.summary.text
        #expect(project.name == "diskarte")
        #expect(summary.contains("Purpose: Diskarte is a communication platform"))
        for fact in ["Next.js", "React", "Supabase", "LiveKit", "TypeScript", "Vitest", "messages", "row-level security", "Vercel", "GET"] {
            #expect(summary.contains(fact), "missing \(fact)")
        }
        #expect(summary.contains("supabase/migrations/001_messages.sql")) // claims cite their files
        #expect(project.filesExcluded.contains(".env.local"))
        #expect(project.filesExcluded.contains("keys/server.pem"))
        #expect(!project.filesRead.contains { $0.hasPrefix("node_modules") })
        let everything = summary + project.documents.map(\.text).joined()
        #expect(!everything.contains("super-secret-value-123"))
        #expect(!everything.contains("abcd1234efgh5678"))
        #expect(project.documents.contains { $0.text.contains("LiveKit rooms") })
    }

    @Test func redactionCoversCommonSecretFormats() {
        let text = """
        GEMINI=AIzaSyA1234567890abcdefghijklmnopqrstuv
        token: ghp_abcdefghijklmnopqrstuvwxyz0123456789
        DATABASE_URL=postgresql://user:pass@db.example.com:5432/app
        password = hunter2hunter2
        jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
        """
        let redacted = RepositoryImporter.redact(text)
        for secret in ["AIzaSyA1234", "ghp_abcdef", "user:pass", "hunter2", "eyJhbGci"] { #expect(!redacted.contains(secret), "\(secret)") }
    }

    @MainActor @Test func reimportReplacesAndIndexCanBeDeleted() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalMemoryStore(url: nil)
        let project = try RepositoryImporter.importRepository(at: root, name: "Diskarte")
        store.replaceImport(project)
        store.replaceImport(project)
        #expect(store.entries.filter { $0.kind == .projectDoc && $0.project == "Diskarte" }.count == project.documents.count)
        #expect(store.retrieve("How did Diskarte handle voice and video calls?").entries.contains { $0.kind == .projectDoc })
        store.deleteProjectIndex()
        #expect(!store.entries.contains { $0.kind == .projectDoc })
        #expect(store.projects.contains { $0.project == "Diskarte" && $0.sources.isEmpty }) // your own entry stays
    }
}

// MARK: Session conversation memory

@MainActor @Suite struct ConversationMemoryTests {
    @Test func keepsTopicProjectAndABoundedContext() {
        let memory = ConversationMemory()
        let projects = PersonalMemoryStore.seed.compactMap(\.project)
        memory.record(question: "How did you design the database in Diskarte?", answer: "I used Supabase Postgres tables for messages.",
                      category: .technical, kind: .newQuestion, projects: projects)
        #expect(memory.project == "Diskarte")
        memory.record(question: "What about security?", answer: "Row-level security policies.", category: .technical, kind: .followUp, projects: projects)
        #expect(memory.project == "Diskarte") // a follow-up stays on the active project
        for index in 0..<10 {
            memory.record(question: "Question number \(index) about caching?", answer: String(repeating: "word ", count: 80),
                          category: .technical, kind: .newQuestion, projects: projects)
        }
        #expect(memory.exchanges.count == 6)
        #expect(!memory.summary.isEmpty)
        #expect(memory.context(budget: 400).count <= 400)
        #expect(memory.context(budget: 400).contains("Question number 9"))
    }

    @Test func retentionOffKeepsOnlyTheLatestExchangeAndClearWorks() {
        let memory = ConversationMemory()
        memory.retain = false
        memory.record(question: "One?", answer: "A.", category: .factual, kind: .newQuestion, projects: [])
        memory.record(question: "Two?", answer: "B.", category: .factual, kind: .newQuestion, projects: [])
        #expect(memory.exchanges.map(\.question) == ["Two?"])
        #expect(memory.summary.isEmpty)
        memory.clear()
        #expect(memory.exchanges.isEmpty && memory.topic == nil)
    }

    @Test func promptContextFollowsTheActiveProjectAndRespectsCloudPrivacy() {
        let model = AppModel(defaults: nil, audio: MockAudio(), speechFactory: { [MockSpeech()] }, aiFactory: { _ in MockAIProvider() },
                             glassesFactory: { _ in MockGlassesDisplay() }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        model.conversation.record(question: "Tell me about the Diskarte database.", answer: "Supabase Postgres with realtime channels.",
                                  category: .technical, kind: .newQuestion, projects: model.memory.projects.compactMap(\.project))
        let notes = model.notes(for: "What about security?").joined(separator: "\n")
        #expect(notes.contains("Diskarte"))
        #expect(notes.contains("Conversation so far"))
        model.settings.aiModel = .geminiFlash
        // This interview's context is sent by default (so references can be resolved); personal memory is not.
        #expect(model.notes(for: "What about security?").joined(separator: "\n").contains("Conversation so far"))
        model.settings.geminiIncludeInterviewContext = false
        let cloud = model.notes(for: "What about security?").joined(separator: "\n")
        #expect(!cloud.contains("Diskarte") && !cloud.contains("Conversation so far"))
        #expect(!model.engine.instructionsProvider(.technical).contains("SAIT"))
        model.settings.geminiIncludePortfolio = true
        #expect(model.engine.instructionsProvider(.technical).contains("SAIT"))
    }
}

// MARK: Code snippets

@Suite struct CodeSnippetTests {
    @Test(arguments: [
        ("Write a function that removes duplicates.", "Use a Set.\nCODE:\nconst unique = (items) => [...new Set(items)];", "javascript"),
        ("Show me a TypeScript example.", "Type the result.\nCODE:\nfunction first(items: string[]): string | undefined {\n  return items[0];\n}", "typescript"),
        ("Show me a React example of useState.", "Keep count in state.\nCODE:\nconst [count, setCount] = useState(0);\nreturn <button onClick={() => setCount(count + 1)}>{count}</button>;", "react"),
        ("Write a SQL query to count users per country.", "Group and count.\nCODE:\nSELECT country, COUNT(*)\nFROM users\nGROUP BY country;", "sql"),
        ("Write a Python function to average a list.", "Divide the sum.\n```python\ndef average(values):\n    return sum(values) / len(values)\n```", "python"),
    ])
    func snippetsAreSeparatedFromTheSpokenAnswer(_ question: String, _ raw: String, _ language: String) throws {
        let (spoken, snippet) = CodeSnippet.split(raw, question: question)
        let code = try #require(snippet)
        #expect(code.language == language)
        #expect(!spoken.contains("CODE:") && !spoken.contains("```"))
        #expect(!code.code.contains("```"))
        #expect(CodeSnippet.wanted(for: question))
    }

    @Test func indentationAndEveryCharacterSurviveLensWrapping() {
        let code = "function handler(req, res) {\n    if (!req.user) {\n        return res.status(401).json({ error: 'Unauthorized access to this resource' });\n    }\n}"
        let rows = CodeSnippet(language: "javascript", code: code).lensRows(width: 30)
        #expect(rows.allSatisfy { $0.count <= 30 })
        #expect(rows[1].hasPrefix("  if"))          // 4-space indent compressed to 2
        #expect(rows[2].hasPrefix("    return"))
        let stripped = rows.map { $0.replacingOccurrences(of: "» ", with: "") }.joined().filter { !$0.isWhitespace }
        #expect(stripped == code.filter { !$0.isWhitespace }) // nothing dropped, order kept
    }

    @Test func longSnippetsAreFramedWithIndicatorsAndTruncationIsVisible() {
        let code = (1...30).map { "let value\($0) = \($0);" }.joined(separator: "\n")
        let frames = CodeSnippet(language: "javascript", code: code).lensFrames(width: 48, lines: 4, maxFrames: 4)
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.count <= 4 })
        #expect(frames[0].last == "[code 1/4]")
        #expect(frames[3].last == "[code 4/4 · rest on iPhone]")
        let short = CodeSnippet(language: "sql", code: "SELECT 1;").lensFrames(width: 48, lines: 4)
        #expect(short == [["SELECT 1;"]])
    }
}

@MainActor @Suite(.serialized) struct CodeSnippetTimerTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let controller: CodeSnippetController
    let snippet = CodeSnippet(language: "sql", code: "SELECT country, COUNT(*)\nFROM users\nGROUP BY country;")

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses)
        presenter.frameRows = 5
        controller = CodeSnippetController(presenter: presenter)
        controller.duration = 0.2
        controller.tick = 0.02
    }

    func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    var showingCode: Bool { glasses.shown.last?.contains("GROUP BY") == true }

    @Test func snippetIsShownThenExpiresBackToTheAnswer() async {
        await presenter.present("Group the users by country and count them.", answerID: 1)
        let answerFrame = glasses.shown.last
        controller.show(snippet, answerID: 1)
        await wait(0.08)
        #expect(showingCode)
        #expect(controller.remaining > 0 && controller.remaining <= 0.2)
        await wait(0.35)
        #expect(!showingCode)
        #expect(glasses.shown.last == answerFrame)
        #expect(!controller.isActive)
    }

    @Test func cancelEndsTheSnippetAndItsTimerCannotActLater() async {
        await presenter.present("Answer one.", answerID: 1)
        controller.show(snippet, answerID: 1)
        await wait(0.06)
        controller.cancel()
        await wait(0.05)
        #expect(!showingCode)
        let count = glasses.shown.count
        await wait(0.3)
        #expect(glasses.shown.count == count) // the cancelled timer wrote nothing
    }

    @Test func aNewAnswerReplacesTheSnippetAndTheOldTimerNeverClearsIt() async {
        await presenter.present("Answer one.", answerID: 1)
        controller.show(snippet, answerID: 1)
        await wait(0.06)
        await presenter.present("A completely new answer about DNS caching.", answerID: 2)
        #expect(!showingCode)
        #expect(!controller.isActive)
        let shown = glasses.shown
        await wait(0.3)
        #expect(glasses.shown == shown)
        #expect(presenter.answerID == 2)
    }

    @Test func aNewerSnippetIsNotEndedByTheOlderTimer() async {
        await presenter.present("Answer one.", answerID: 1)
        controller.show(snippet, answerID: 1)
        await wait(0.12)
        let second = CodeSnippet(language: "python", code: "def average(values):\n    return sum(values) / len(values)")
        controller.show(second, answerID: 1)
        await wait(0.12) // the first snippet's window would have ended here
        #expect(glasses.shown.last?.contains("def average") == true)
        await wait(0.25)
        #expect(glasses.shown.last?.contains("def average") == false)
    }

    @Test func disconnectExpiresTheSnippetAndReconnectRestoresTheAnswerNotTheCode() async {
        await presenter.present("Answer one.", answerID: 1)
        controller.show(snippet, answerID: 1)
        await wait(0.06)
        glasses.simulateDrop()
        #expect(!controller.isActive)
        #expect(controller.status.contains("disconnected"))
        glasses.connect()
        await wait(0.05)
        #expect(!showingCode)
        #expect(LensModel.visibleText([glasses.shown.last!]).joined(separator: " ") == "Answer one.")
    }

    @Test func multiFrameSnippetsGetAWindowPerFrame() async {
        await presenter.present("Answer one.", answerID: 1)
        let long = CodeSnippet(language: "javascript", code: (1...6).map { "const v\($0) = \($0);" }.joined(separator: "\n"))
        controller.show(long, answerID: 1)
        await wait(0.08)
        #expect(glasses.shown.last?.contains("[code 1/2]") == true)
        await wait(0.22)
        #expect(glasses.shown.last?.contains("[code 2/2]") == true)
        await wait(0.25)
        #expect(glasses.shown.last?.contains("code") == false)
    }

    @Test func codeOnlyReachesTheIPhoneAndOverlayNeverTheTeleprompter() async {
        let ai = MockAIProvider()
        ai.answer = "I'd use a Set because it drops duplicates in one pass.\nCODE:\nconst unique = (items) => [...new Set(items)];"
        var settings = AppSettings()
        settings.semanticClassification = false
        let engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        var shown: InterviewAnswer?
        engine.onAnswerDisplayed = { _, answer in shown = answer }
        engine.start()
        await engine.handle(CompletedTurn(text: "Write a function that removes duplicates from an array.", start: 0, end: 2))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.text == "I'd use a Set because it drops duplicates in one pass.")
        #expect(shown?.snippet?.code == "const unique = (items) => [...new Set(items)];")
        #expect(presenter.plan?.answer.contains("new Set") == false)
        #expect(ai.requests.last?.instructions.contains("CODE:") == true)
    }
}

// MARK: Continuous conversation

@Suite struct SpeechEventClassifierTests {
    let detector = QuestionDetector()
    let topic = "How would you debug a Salesforce integration? I'd check the Salesforce API logs, the authentication token and the field mappings."

    func classify(_ text: String, active: Bool = true, speaker: SpeakerLabel = .unknown, echo: Double = 0) -> SpeechClassification {
        SpeechEventClassifier.classify(text, question: detector.analyze(text, previousQuestion: active ? "How would you debug a Salesforce integration?" : nil),
                                       echoOverlap: echo, echoThreshold: 0.5, speaker: speaker, questionThreshold: 0.5,
                                       topicText: active ? topic : "", hasActiveAnswer: active)
    }

    @Test func classifiesTheConversationKinds() {
        #expect(classify("How would you debug a Salesforce integration?", active: false).kind == .newQuestion)
        #expect(classify("How would you debug a Salesforce integration?", active: false).tier == .high)
        for followUp in ["What if the API key expired?", "Why did you choose Supabase?", "What about authentication?",
                         "What if Salesforce is down?", "Okay, but how would you actually implement that?"] {
            let event = classify(followUp)
            #expect(event.kind == .followUp, "\(followUp): \(event)")
            #expect(event.tier == .high, "\(followUp): \(event)")
        }
        #expect(classify("Can you explain that further?").kind == .clarification)
        #expect(classify("Why?").kind == .clarification)
        #expect(classify("No, I meant the authentication part.").kind == .correction)
        #expect(classify("Take your time.").kind == .instruction)
        #expect(classify("I'd check the Salesforce API logs", echo: 0.9).kind == .readingAnswer)
        #expect(classify("What if the token expired?", speaker: .wearer).kind == .userResponse)
        #expect(classify("The parking downstairs was full again today").kind == .general)
    }

    @Test func ambiguousSpeakerAndWeakEvidenceNeverReachHighConfidence() {
        let event = classify("Is that common")
        #expect(event.kind == .followUp)
        #expect(event.tier == .medium)
        #expect(classify("Maybe the logs", active: true).tier == .low)
    }

    @Test func phaseReducerIsDeterministic() {
        var phase = ConversationPhase.idle
        let script: [(ConversationPhase.Event, ConversationPhase)] = [
            (.start, .listening), (.question(followUp: false), .questionDetected), (.generationStarted, .generating),
            (.answerShown, .answerReady), (.readingStarted, .reading), (.question(followUp: true), .followUpDetected),
            (.generationStarted, .followUpGenerating), (.transition, .transitioning), (.answerShown, .answerReady),
            (.codeShown, .codeDisplay), (.codeEnded, .answerReady), (.readingCompleted, .completed),
            (.question(followUp: false), .questionDetected), (.generationStarted, .generating), (.cancelled, .listening),
            (.failed, .error), (.question(followUp: false), .questionDetected), (.stop, .idle), (.answerShown, .idle),
        ]
        for (event, expected) in script {
            phase = phase.next(event)
            #expect(phase == expected, "\(event)")
        }
    }
}

@MainActor @Suite(.serialized) struct ContinuousConversationTests {
    let glasses = MockGlassesDisplay()
    let presenter: GlassesPresenter
    let ai = MockAIProvider()
    let engine: ConversationEngine
    static let first = "I'd check the Salesforce API logs first, then the authentication token and the field mappings."
    static let expired = "If the API key expired, I'd rotate it in Salesforce, update the stored secret and replay the failed requests."

    init() {
        glasses.connect()
        presenter = GlassesPresenter(display: glasses)
        var settings = AppSettings()
        settings.semanticClassification = false
        settings.continuousConversation = true
        let ai = self.ai
        engine = ConversationEngine(settings: settings, ai: { ai }, presenter: presenter)
        engine.start()
    }

    func turn(_ text: String, speaker: SpeakerLabel = .unknown) async {
        var evidence = SpeakerEvidence.unknown
        evidence.label = speaker
        await engine.handle(CompletedTurn(text: text, start: 0, end: 1, speaker: evidence))
        await engine.generationTask?.value
    }

    func ask() async {
        ai.queuedAnswers = [Self.first]
        await turn("How would you debug a Salesforce integration?")
        #expect(engine.currentAnswer?.text == Self.first)
    }

    @Test func confidentFollowUpTransitionsAutomaticallyWithContext() async {
        await ask()
        let firstID = engine.currentAnswer?.answerID
        ai.queuedAnswers = [Self.expired]
        await turn("What if the API key expired?")
        #expect(engine.currentAnswer?.text == Self.expired) // no Continue tap
        #expect(engine.currentAnswer?.kind == .followUp)
        #expect(engine.currentAnswer?.answerID != firstID)
        #expect(presenter.plan?.answer == Self.expired)
        let prompt = ai.requests.last?.prompt ?? ""
        #expect(prompt.contains("Previous question: How would you debug a Salesforce integration?"))
        #expect(prompt.contains("without repeating the previous answer"))
        #expect(engine.phase == .answerReady)
        // No caption mixes the two answers.
        #expect(!glasses.shown.contains { $0.contains("field mappings") && $0.contains("rotate") })
    }

    @Test func readingAloudOwnSpeechAndUnrelatedTalkNeverReplaceTheAnswer() async {
        await ask()
        let shown = glasses.shown
        await turn("I'd check the Salesforce API logs first, then the authentication token")      // reading
        await turn("What if the token expired?", speaker: .wearer)                                  // own voice
        await turn("The parking downstairs was full again today")                                  // unrelated
        await turn("Take your time.")                                                               // instruction
        #expect(engine.currentAnswer?.text == Self.first)
        #expect(glasses.shown == shown)
        #expect(ai.requests.count == 1)
    }

    @Test func mediumConfidenceIsPreparedButNotShownUntilConfirmed() async {
        await ask()
        ai.queuedAnswers = ["It's common when tokens are rotated without updating the integration user."]
        await turn("Is that common")
        #expect(engine.preparedAnswer != nil)
        #expect(engine.currentAnswer?.text == Self.first)  // current frame kept
        #expect(presenter.plan?.answer == Self.first)
        engine.showPreparedAnswer(reason: "tapped")
        await Task.yield(); try? await Task.sleep(for: .milliseconds(30))
        #expect(presenter.plan?.answer.hasPrefix("It's common") == true)
        #expect(engine.preparedAnswer == nil)
    }

    @Test func mistakenTransitionCanBeUndoneInOneTap() async {
        await ask()
        let firstID = engine.currentAnswer?.answerID
        ai.queuedAnswers = [Self.expired]
        await turn("What if the API key expired?")
        engine.undoTransition()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(engine.currentAnswer?.text == Self.first)
        #expect(presenter.plan?.answer == Self.first)
        #expect(presenter.answerID == firstID) // restored under its own identity
        #expect(engine.undoAnswer == nil)
    }

    @Test func rapidFollowUpsKeepOnlyTheNewestAnswer() async {
        await ask()
        ai.perWordDelay = .milliseconds(15)
        ai.queuedAnswers = ["If the API key expired I'd rotate it and replay the failed calls carefully one by one.",
                            "If Salesforce is down I'd queue the leads and retry with backoff once it recovers."]
        await engine.handle(CompletedTurn(text: "What if the API key expired?", start: 0, end: 1))
        try? await Task.sleep(for: .milliseconds(40))
        await engine.handle(CompletedTurn(text: "What if Salesforce is down?", start: 1, end: 2))
        await engine.generationTask?.value
        #expect(engine.currentAnswer?.text.hasPrefix("If Salesforce is down") == true)
        #expect(!glasses.shown.contains { $0.contains("rotate it and replay") })
        #expect(presenter.plan?.answer.hasPrefix("If Salesforce is down") == true)
    }

    @Test func clarificationsAndCorrectionsAreAnsweredInContext() async {
        await ask()
        ai.queuedAnswers = ["Sure, the token is what Salesforce uses to trust the integration user."]
        await turn("Can you explain that further?")
        #expect(engine.currentAnswer?.kind == .clarification)
        #expect(ai.requests.last?.prompt.contains("Previous answer") == true)
        // A correction from an unattributed voice is prepared; from the interviewer it is applied.
        ai.queuedAnswers = ["For authentication specifically, I'd confirm the connected app and the OAuth scopes."]
        await turn("No, I meant the authentication part.")
        #expect(engine.preparedAnswer?.answer.kind == .correction)
        engine.dismissPrepared()
        ai.queuedAnswers = ["For authentication specifically, I'd confirm the connected app and the OAuth scopes."]
        await turn("No, I meant the login part.", speaker: .interviewer)
        #expect(engine.currentAnswer?.kind == .correction)
    }

    @Test func offByDefaultKeepsTheClassicLock() async {
        var settings = AppSettings()
        settings.semanticClassification = false
        #expect(settings.continuousConversation == false)
        let engine = ConversationEngine(settings: settings, ai: { self.ai }, presenter: presenter)
        engine.start()
        ai.queuedAnswers = [Self.first]
        await engine.handle(CompletedTurn(text: "How would you debug a Salesforce integration?", start: 0, end: 1))
        await engine.generationTask?.value
        await engine.handle(CompletedTurn(text: "What if the API key expired?", start: 2, end: 3))
        #expect(engine.currentAnswer?.text == Self.first) // locked: queued, not replaced
        #expect(engine.pendingQuestion != nil)
    }
}
