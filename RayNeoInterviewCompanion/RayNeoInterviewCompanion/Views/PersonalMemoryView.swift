import SwiftUI
import UniformTypeIdentifiers

/// Everything the assistant knows about the user, all visible and editable. Nothing said in a
/// conversation becomes a permanent memory; entries change only here or through an approved import.
struct PersonalMemoryView: View {
    @Bindable var model: AppModel
    @State private var editing: MemoryEntry?
    @State private var importing = false
    @State private var importResult: String?
    @State private var confirmDeleteMemory = false
    @State private var confirmDeleteIndex = false

    var body: some View {
        let memory = model.memory
        List {
            Section {
                ForEach(memory.profile) { entry in row(entry) }
                Button("Add profile entry", systemImage: "plus") { editing = MemoryEntry(kind: .profile, title: "", text: "") }
            } header: { Text("About Me") } footer: {
                Text("Education, background, skills and how you like to explain things. Answers may only claim what is written here or in your projects.")
            }

            Section {
                ForEach(memory.projects) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        row(entry)
                        let documents = memory.entries.filter { $0.kind == .projectDoc && $0.project == entry.project }.count
                        let indexed = entry.project.flatMap { memory.document.lastIndexed[$0] }
                        Text([entry.sources.isEmpty ? "Entered by you" : "Imported from \(entry.sources.count) file(s)",
                              documents > 0 ? "\(documents) indexed section(s)" : nil,
                              indexed.map { "indexed \($0.formatted(date: .abbreviated, time: .shortened))" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("Add project", systemImage: "plus") { editing = MemoryEntry(kind: .project, title: "", project: "", text: "") }
                Button("Import a repository folder…", systemImage: "folder.badge.plus") { importing = true }
                if let importResult { Text(importResult).font(.caption) }
            } header: { Text("My Projects") } footer: {
                Text("Import reads a repository folder on this iPhone (Files / iCloud Drive): README, docs, manifests, schemas, API routes, deployment and test config. It never reads .env files, keys or credentials, redacts secret-looking values, and uploads nothing. Each summarised fact lists the files it came from.")
            }

            Section {
                ForEach(memory.projects.compactMap(\.project), id: \.self) { project in
                    AliasRow(project: project, aliases: memory.document.aliases[project] ?? []) { memory.setAliases($0, for: project) }
                }
            } header: { Text("Project Names & Pronunciations") } footer: {
                Text("Spellings the recogniser produces for your projects (comma-separated). They are also given to the speech recogniser as vocabulary. Close variants are only corrected when you are clearly talking about a project.")
            }

            Section {
                LabeledContent("Current topic", value: model.conversation.topic ?? "–")
                if let task = model.codingTasks.task {
                    LabeledContent("Coding task", value: "\(task.language): \(task.functionality.prefix(60))")
                }
                ForEach(model.conversation.exchanges.reversed()) { exchange in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exchange.question).font(.caption.weight(.semibold))
                        Text(exchange.answer).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if !model.conversation.unresolved.isEmpty {
                    LabeledContent("Unresolved", value: "\(model.conversation.unresolved.count)")
                }
                Button("Clear Session Memory", role: .destructive) { model.conversation.clear() }
            } header: { Text("Conversation Memory") } footer: {
                Text("Kept in memory for this session only; never saved to disk.")
            }

            Section {
                Toggle("Use personal memory in answers", isOn: $model.settings.personalMemoryEnabled)
                Toggle("Keep earlier exchanges this session", isOn: $model.settings.conversationRetention)
                Toggle("Share memory & conversation context with Gemini", isOn: $model.settings.geminiIncludePortfolio)
                ShareLink("Export memory (JSON)", item: memory.export())
                Button("Restore initial profile and projects") { memory.restoreSeed() }
                Button("Delete personal memory", role: .destructive) { confirmDeleteMemory = true }
                Button("Delete project index", role: .destructive) { confirmDeleteIndex = true }
            } header: { Text("Privacy and Controls") } footer: {
                Text("Memory is stored on this iPhone with file protection (encrypted while the device is locked). Only the few entries relevant to a question are put in a prompt, and they go to Google only when context sharing is on and Gemini is selected.")
            }
        }
        .navigationTitle("Personal AI Memory")
        .sheet(item: $editing) { entry in MemoryEditor(entry: entry) { model.memory.upsert($0) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in importRepository(result) }
        .confirmationDialog("Delete your profile and projects?", isPresented: $confirmDeleteMemory, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.memory.deletePersonalMemory() }
        }
        .confirmationDialog("Delete all imported repository data?", isPresented: $confirmDeleteIndex, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.memory.deleteProjectIndex() }
        }
    }

    private func row(_ entry: MemoryEntry) -> some View {
        Button { editing = entry } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title).font(.callout.weight(.semibold))
                Text(entry.text).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
        .buttonStyle(.plain)
        .swipeActions { Button("Delete", role: .destructive) { model.memory.delete(entry.id) } }
    }

    private func importRepository(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): importResult = error.localizedDescription
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let project = try RepositoryImporter.importRepository(at: url)
                model.memory.replaceImport(project)
                importResult = "Imported \(project.name): \(project.filesRead.count) file(s) read, \(project.documents.count) section(s) indexed, \(project.filesExcluded.count) sensitive file(s) skipped."
                DiagnosticLog.shared.record(.session, "Repository imported: \(project.filesRead.count) files, \(project.filesExcluded.count) excluded")
            } catch {
                importResult = error.localizedDescription
            }
        }
    }
}

private struct MemoryEditor: View {
    @State var entry: MemoryEntry
    let save: (MemoryEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $entry.title)
                if entry.kind != .profile {
                    TextField("Project", text: Binding(get: { entry.project ?? "" }, set: { entry.project = $0 }))
                }
                TextEditor(text: $entry.text).frame(minHeight: 200)
                if !entry.sources.isEmpty {
                    Section("Sources") { ForEach(entry.sources, id: \.self) { Text($0).font(.caption.monospaced()) } }
                }
            }
            .navigationTitle(entry.kind == .profile ? "Profile entry" : "Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if entry.kind == .project, (entry.project ?? "").isEmpty { entry.project = entry.title }
                        save(entry)
                        dismiss()
                    }.disabled(entry.title.isEmpty || entry.text.isEmpty)
                }
            }
        }
    }
}

private struct AliasRow: View {
    let project: String
    let aliases: [String]
    let save: ([String]) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project).font(.callout.weight(.semibold))
            TextField("Aliases, comma-separated", text: $text)
                .font(.caption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { save(text.split(separator: ",").map(String.init)) }
        }
        .onAppear { text = aliases.joined(separator: ", ") }
        .swipeActions { Button("Clear", role: .destructive) { text = ""; save([]) } }
    }
}
