import Foundation

nonisolated struct ImportedProject: Equatable, Sendable {
    var name: String
    var summary: MemoryEntry
    var documents: [MemoryEntry]
    /// Relative paths read; and paths skipped because they may hold secrets.
    var filesRead: [String]
    var filesExcluded: [String]
}

/// Builds a local, structured summary of a user-approved repository folder. Runs entirely on the
/// iPhone: nothing is uploaded. Reads only documentation, manifests, schemas, API definitions, config
/// and test setup — never environment files, keys or credentials — and redacts secret-looking values.
/// Every summarised fact lists the files it came from; nothing is inferred beyond what the files say.
nonisolated enum RepositoryImporter {
    static let maxFiles = 80
    static let maxFileBytes = 200_000
    static let maxDocuments = 40

    enum ImportError: LocalizedError {
        case notAFolder, nothingReadable
        var errorDescription: String? {
            switch self {
            case .notAFolder: "Choose the repository's folder."
            case .nothingReadable: "No README, docs, manifests or schemas were found in that folder."
            }
        }
    }

    static func importRepository(at root: URL, name explicitName: String? = nil) throws -> ImportedProject {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ImportError.notAFolder }
        var files: [(path: String, text: String)] = []
        var excluded: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL, files.count < maxFiles {
            let path = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator?.skipDescendants() }
                continue
            }
            if isSensitive(path) { excluded.append(path); continue }
            guard isRelevant(path), (values?.fileSize ?? 0) <= maxFileBytes,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            files.append((path, redact(text)))
        }
        guard !files.isEmpty else { throw ImportError.nothingReadable }
        return summarize(files: files, folderName: root.lastPathComponent, explicitName: explicitName, excluded: excluded)
    }

    // MARK: Selection and redaction

    static let skippedDirectories: Set<String> = [".git", "node_modules", ".next", "dist", "build", "out", "coverage", ".venv",
                                                  "venv", "__pycache__", ".turbo", ".vercel", "Pods", "DerivedData", ".idea", ".vscode"]

    /// Never read: environment files, keys, certificates, credentials, lockfiles.
    static func isSensitive(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") || name.hasSuffix(".env") { return true }
        let suffixes = [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".crt", ".cer", ".der", ".sqlite", ".db"]
        if suffixes.contains(where: name.hasSuffix) { return true }
        let words = ["secret", "credential", "id_rsa", "id_ed25519", "password", "token", ".npmrc", ".pypirc", "service-account", "serviceaccount"]
        return words.contains { name.contains($0) }
    }

    static func isRelevant(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if name.hasPrefix("readme") || name.hasPrefix("architecture") || name.hasPrefix("testing") || name.hasPrefix("contributing") { return true }
        if ext == "md", lower.hasPrefix("docs/") || lower.contains("/adr/") || lower.contains("decision") { return true }
        let manifests: Set<String> = ["package.json", "requirements.txt", "requirements-dev.txt", "pyproject.toml", "schema.prisma",
                                      "dockerfile", "docker-compose.yml", "docker-compose.yaml", "vercel.json", "render.yaml",
                                      "netlify.toml", "openapi.json", "openapi.yaml", "openapi.yml", "swagger.json", "swagger.yaml"]
        if manifests.contains(name) { return true }
        if name.hasPrefix("jest.config") || name.hasPrefix("vitest.config") || name.hasPrefix("playwright.config") || name == "pytest.ini" { return true }
        if ext == "sql" { return true }
        if lower.hasPrefix(".github/workflows/") { return true }
        // Selected source: API route handlers only.
        if ["ts", "js", "py"].contains(ext), lower.contains("/api/") || lower.contains("routes/") || lower.contains("routers/") { return true }
        return false
    }

    /// Removes values that look like secrets, so they never reach memory, prompts or logs.
    static func redact(_ text: String) -> String {
        let patterns = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            #"AIza[0-9A-Za-z_\-]{30,}"#, #"\bsk-[A-Za-z0-9_\-]{16,}"#, #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, #"\bxox[abpr]-[A-Za-z0-9\-]{10,}"#,
            #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
            #"(?i)\b(postgres(ql)?|mongodb(\+srv)?|mysql|redis)://[^\s'"]+"#,
            #"(?i)\b([A-Z0-9_]*(api[_-]?key|secret|password|passwd|token|private[_-]?key|access[_-]?key)[A-Z0-9_]*)\s*[:=]\s*['"]?[^\s'",]{6,}"#,
        ]
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }

    // MARK: Summary

    /// Dependency → what it tells us. Only listed when the dependency is actually declared.
    static let stackMap: [(key: String, label: String)] = [
        ("next", "Next.js"), ("react", "React"), ("typescript", "TypeScript"), ("@supabase/supabase-js", "Supabase"),
        ("@supabase/ssr", "Supabase"), ("prisma", "Prisma"), ("@prisma/client", "Prisma"), ("express", "Express"),
        ("mongoose", "MongoDB (Mongoose)"), ("mongodb", "MongoDB"), ("pg", "PostgreSQL (pg)"), ("livekit-client", "LiveKit"),
        ("@livekit/components-react", "LiveKit"), ("livekit-server-sdk", "LiveKit"), ("leaflet", "Leaflet maps"),
        ("mapbox-gl", "Mapbox maps"), ("react-leaflet", "Leaflet maps"), ("tailwindcss", "Tailwind CSS"), ("zod", "Zod validation"),
        ("next-auth", "NextAuth"), ("jsonwebtoken", "JWT"), ("bcrypt", "bcrypt"), ("stripe", "Stripe"),
        ("jest", "Jest"), ("vitest", "Vitest"), ("@playwright/test", "Playwright"), ("cypress", "Cypress"),
        ("@testing-library/react", "React Testing Library"), ("fastapi", "FastAPI"), ("flask", "Flask"), ("django", "Django"),
        ("pandas", "pandas"), ("numpy", "NumPy"), ("fitparse", "FIT file parsing (fitparse)"), ("gpxpy", "GPX parsing (gpxpy)"),
        ("librosa", "librosa audio analysis"), ("ffmpeg-python", "FFmpeg (ffmpeg-python)"), ("pydub", "pydub audio"),
        ("pytest", "pytest"), ("sqlalchemy", "SQLAlchemy"), ("psycopg", "PostgreSQL (psycopg)"), ("psycopg2", "PostgreSQL (psycopg2)"),
        ("uvicorn", "Uvicorn"), ("recharts", "Recharts charts"), ("chart.js", "Chart.js charts"), ("socket.io", "Socket.IO"),
    ]

    static func summarize(files: [(path: String, text: String)], folderName: String, explicitName: String?, excluded: [String]) -> ImportedProject {
        var facts: [(label: String, values: [String], sources: Set<String>)] = []
        func add(_ label: String, _ value: String, _ source: String) {
            if let index = facts.firstIndex(where: { $0.label == label }) {
                if !facts[index].values.contains(value) { facts[index].values.append(value) }
                facts[index].sources.insert(source)
            } else {
                facts.append((label, [value], [source]))
            }
        }

        var packageName: String?
        var purpose: String?
        for file in files {
            let name = (file.path as NSString).lastPathComponent.lowercased()
            let lower = file.text.lowercased()
            if name == "package.json", let data = file.text.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if file.path == "package.json" { packageName = json["name"] as? String }
                let deps = ((json["dependencies"] as? [String: Any]) ?? [:]).merging((json["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
                for (key, label) in stackMap where deps[key] != nil { add(label.contains("Jest") || label.contains("Vitest") || label.contains("Playwright") || label.contains("Cypress") || label.contains("Testing Library") ? "Testing" : "Technology stack", label, file.path) }
                if let scripts = json["scripts"] as? [String: Any], scripts["test"] != nil { add("Testing", "npm test script", file.path) }
            }
            if name.hasPrefix("requirements") || name == "pyproject.toml" {
                for (key, label) in stackMap where lower.range(of: #"(^|[\s"'])\#(NSRegularExpression.escapedPattern(for: key))([\s=<>~\[;"']|$)"#, options: .regularExpression) != nil {
                    add(label == "pytest" ? "Testing" : "Technology stack", label, file.path)
                }
                add("Technology stack", "Python", file.path)
            }
            if name == "schema.prisma" {
                for match in matches(#"(?m)^\s*model\s+(\w+)"#, in: file.text) { add("Database tables/models", match, file.path) }
                if let provider = matches(#"provider\s*=\s*"(postgresql|mysql|sqlite|mongodb)""#, in: file.text).first { add("Database", provider, file.path) }
            }
            if file.path.lowercased().hasSuffix(".sql") {
                for match in matches(#"(?i)create\s+table\s+(?:if\s+not\s+exists\s+)?(?:\"?public\"?\.)?\"?(\w+)"#, in: file.text) { add("Database tables/models", match, file.path) }
                if lower.contains("enable row level security") || lower.contains("create policy") { add("Authorization", "PostgreSQL row-level security policies", file.path) }
                if lower.contains("postgis") || lower.contains("geography(") || lower.contains("geometry(") { add("Database", "PostGIS spatial data", file.path) }
            }
            if name.hasPrefix("openapi") || name.hasPrefix("swagger") {
                let paths = matches(#"(?m)^\s{2}(/[\w/{}\-.]*):"#, in: file.text) + matches(#""(/[\w/{}\-.]+)"\s*:\s*\{"#, in: file.text)
                for path in paths.prefix(12) { add("API endpoints", path, file.path) }
            }
            if ["ts", "js", "py"].contains((name as NSString).pathExtension) {
                add("API route files", file.path, file.path)
                for method in matches(#"export\s+(?:async\s+)?function\s+(GET|POST|PUT|PATCH|DELETE)\b"#, in: file.text) { add("API methods", method, file.path) }
                for route in matches(#"@(?:app|router)\.(?:get|post|put|patch|delete)\(\s*["']([^"']+)"#, in: file.text) { add("API endpoints", route, file.path) }
            }
            if name == "vercel.json" { add("Deployment", "Vercel", file.path) }
            if name == "render.yaml" { add("Deployment", "Render", file.path) }
            if name == "netlify.toml" { add("Deployment", "Netlify", file.path) }
            if name == "dockerfile" || name.hasPrefix("docker-compose") { add("Deployment", "Docker", file.path) }
            if file.path.lowercased().hasPrefix(".github/workflows/") { add("Deployment", "GitHub Actions workflow", file.path) }
            if name.hasPrefix("jest.config") { add("Testing", "Jest", file.path) }
            if name.hasPrefix("vitest.config") { add("Testing", "Vitest", file.path) }
            if name.hasPrefix("playwright.config") { add("Testing", "Playwright", file.path) }
            if name == "pytest.ini" { add("Testing", "pytest", file.path) }
            if name.hasPrefix("readme"), file.path.lowercased().hasPrefix("readme") || purpose == nil { purpose = firstParagraph(file.text) }
        }

        let projectName = explicitName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? packageName?.nonEmpty ?? folderName
        var lines: [String] = []
        if let purpose { lines.append("Purpose: \(purpose)") }
        for fact in facts {
            lines.append("\(fact.label): \(fact.values.prefix(14).joined(separator: ", ")) [\(fact.sources.sorted().prefix(4).joined(separator: ", "))]")
        }
        let sources = Set(facts.flatMap(\.sources)).union(files.filter { ($0.path as NSString).lastPathComponent.lowercased().hasPrefix("readme") }.map(\.path))
        let summary = MemoryEntry(kind: .project, title: projectName, project: projectName,
                                  text: lines.joined(separator: "\n"), sources: sources.sorted())

        // Searchable document sections (docs only; code is summarised above, not stored).
        var documents: [MemoryEntry] = []
        for file in files where (file.path as NSString).pathExtension.lowercased() == "md" {
            for section in sections(file.text) where documents.count < maxDocuments {
                documents.append(MemoryEntry(kind: .projectDoc, title: section.title.isEmpty ? file.path : section.title, project: projectName,
                                             text: String(section.body.prefix(600)), sources: [file.path]))
            }
        }
        return ImportedProject(name: projectName, summary: summary, documents: documents, filesRead: files.map(\.path), filesExcluded: excluded)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text).map { String(text[$0]) } : nil
        }
    }

    /// The README's first prose paragraph (no headings, badges, images or HTML).
    static func firstParagraph(_ markdown: String) -> String? {
        for paragraph in markdown.components(separatedBy: "\n\n") {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("!["), !text.hasPrefix("<"), !text.hasPrefix("[!["),
                  !text.hasPrefix("```"), !text.hasPrefix("|") else { continue }
            return String(text.replacingOccurrences(of: "\n", with: " ").prefix(300))
        }
        return nil
    }

    /// Markdown split at headings; empty sections dropped, code fences removed.
    static func sections(_ markdown: String) -> [(title: String, body: String)] {
        var result: [(String, String)] = []
        var title = "", body: [String] = [], inFence = false
        func flush() {
            let text = body.joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if text.count >= 40 { result.append((title, text)) }
            body = []
        }
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if line.hasPrefix("#") {
                flush()
                title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            } else {
                body.append(line)
            }
        }
        flush()
        return result
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
