import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryTab: String, Hashable {
    case board, skills, cleanup, snippets
}

/// Client-first management tools. The hub keeps a compact fallback UI; day-to-day organization
/// lives here in the native app.
struct LibraryView: View {
    @State private var tab: LibraryTab = .board

    private var tabs: [WLTab<LibraryTab>] {
        [
            WLTab(id: .board, title: "Board", icon: "rectangle.3.group"),
            WLTab(id: .skills, title: "Skills", icon: "shippingbox"),
            WLTab(id: .cleanup, title: "Cleanup", icon: "arrow.triangle.merge"),
            WLTab(id: .snippets, title: "Snippets", icon: "chevron.left.forwardslash.chevron.right"),
        ]
    }

    var body: some View {
        MainPage {
            HStack {
                WLTabBar(tabs: tabs, selection: $tab)
                Spacer(minLength: 0)
            }
            switch tab {
            case .board: ProjectBoardView()
            case .skills: SkillsLibraryView()
            case .cleanup: DuplicateCleanupView()
            case .snippets: SnippetsLibraryView()
            }
        }
    }
}

private struct ProjectBoardView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @State private var columns: [HubKanbanColumn] = []
    @State private var projects: [HubProject] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var columnEditor: ColumnEditorContext?
    @State private var deletingColumn: HubKanbanColumn?

    private var visibleProjects: [HubProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return projects }
        return projects.filter { project in
            [project.name, project.description, project.slug, project.owner]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    var body: some View {
        WLPageHeader(title: "Project board", subtitle: "Move work through the stages defined on your hub.") {
            HStack(spacing: 8) {
                TextField("Search projects", text: $search).mainField().frame(width: 220)
                Button("Add column") { columnEditor = ColumnEditorContext() }.buttonStyle(PrimaryButtonStyle())
                Button("Refresh") { Task { await load() } }.buttonStyle(SecondaryButtonStyle())
            }
        }
        if loading && columns.isEmpty {
            ProgressView("Loading board…")
        } else if let error {
            MainNotice(symbol: "exclamationmark.triangle", title: "Board unavailable", message: error)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { column in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(column.label).font(DS.Font.body.weight(.semibold))
                                Spacer()
                                MainTag(text: String(visibleProjects.filter { $0.kanbanStatus(in: columns) == column.status }.count))
                                Menu {
                                    Button("Rename") { columnEditor = ColumnEditorContext(column: column) }
                                    let index = columns.firstIndex(of: column) ?? 0
                                    Button("Move left") { Task { await moveColumn(column, offset: -1) } }
                                        .disabled(index == 0)
                                    Button("Move right") { Task { await moveColumn(column, offset: 1) } }
                                        .disabled(index >= columns.count - 1)
                                    Divider()
                                    Button("Delete", role: .destructive) { deletingColumn = column }
                                        .disabled(columns.count <= 1)
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton)
                            }
                            if let description = column.description, !description.isEmpty {
                                Text(description).font(DS.Font.micro).foregroundStyle(p.textMuted)
                            }
                            ForEach(visibleProjects.filter { $0.kanbanStatus(in: columns) == column.status }) { project in
                                projectCard(project)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(width: 270, alignment: .top)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        .dropDestination(for: String.self) { projectIDs, _ in
                            dropProjects(projectIDs, on: column.status)
                        }
                    }
                }
            }
        }
        Color.clear.frame(height: 0)
            .task(id: store.config.hubURL) { await load() }
            .sheet(item: $columnEditor) { editor in
                KanbanColumnEditor(context: editor) { label, description in
                    await saveColumn(editor, label: label, description: description)
                }
                .environment(\.palette, p)
            }
            .confirmationDialog(
                "Delete \(deletingColumn?.label ?? "column")?",
                isPresented: Binding(get: { deletingColumn != nil }, set: { if !$0 { deletingColumn = nil } }),
                presenting: deletingColumn
            ) { column in
                ForEach(columns.filter { $0.status != column.status }) { destination in
                    Button("Delete and move projects to \(destination.label)", role: .destructive) {
                        Task { await deleteColumn(column, moveTo: destination.status) }
                    }
                }
                Button("Cancel", role: .cancel) { deletingColumn = nil }
            } message: { _ in
                Text("Projects are kept. Choose the column that should receive them.")
            }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let loadedColumns = store.hub.kanbanColumns()
            async let loadedProjects = store.hub.projects()
            (columns, projects) = try await (loadedColumns, loadedProjects)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func move(_ project: HubProject, to status: String) async {
        do {
            try await store.hub.updateProjectStatus(id: project.id, status: status)
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func projectCard(_ project: HubProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name).font(DS.Font.bodySmall.weight(.semibold))
                Spacer()
                if let owner = project.owner, !owner.isEmpty {
                    MainTag(text: owner)
                        .help(project.ownerSource == "folder" ? "Assigned from the \(owner) folder" : "Project owner")
                }
            }
            if let description = project.description {
                Text(description)
                    .font(DS.Font.micro)
                    .foregroundStyle(p.textMuted)
                    .lineLimit(3)
            }
            HStack {
                Text("\(project.memoryCount) memories").font(DS.Font.micro)
                Spacer()
                Menu("Move") { moveDestinations(for: project) }
                    .menuStyle(.borderlessButton)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.row))
        .draggable(String(project.id))
    }

    @ViewBuilder
    private func moveDestinations(for project: HubProject) -> some View {
        let currentStatus = project.kanbanStatus(in: columns)
        ForEach(columns.filter { $0.status != currentStatus }) { destination in
            Button(destination.label) { moveRequested(project, to: destination.status) }
        }
    }

    private func moveRequested(_ project: HubProject, to status: String) {
        Task { await move(project, to: status) }
    }

    private func dropProjects(_ projectIDs: [String], on status: String) -> Bool {
        guard let rawProjectID = projectIDs.first, let projectID = Int(rawProjectID),
              let project = projects.first(where: { $0.id == projectID }) else { return false }
        moveRequested(project, to: status)
        return true
    }

    private func saveColumn(_ editor: ColumnEditorContext, label: String, description: String) async {
        do {
            if let status = editor.status {
                columns = try await store.hub.updateKanbanColumn(status: status, label: label, description: description)
            } else {
                columns = try await store.hub.createKanbanColumn(label: label, description: description)
            }
            columnEditor = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func moveColumn(_ column: HubKanbanColumn, offset: Int) async {
        guard let source = columns.firstIndex(of: column) else { return }
        let target = source + offset
        guard columns.indices.contains(target) else { return }
        var statuses = columns.map(\.status)
        statuses.swapAt(source, target)
        do { columns = try await store.hub.reorderKanbanColumns(statuses); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func deleteColumn(_ column: HubKanbanColumn, moveTo: String) async {
        do {
            columns = try await store.hub.deleteKanbanColumn(status: column.status, moveTo: moveTo)
            deletingColumn = nil
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ColumnEditorContext: Identifiable {
    let id = UUID()
    var status: String?
    var label = ""
    var description = ""

    init(column: HubKanbanColumn? = nil) {
        status = column?.status
        label = column?.label ?? ""
        description = column?.description ?? ""
    }
}

private struct KanbanColumnEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var description: String
    let context: ColumnEditorContext
    let save: (String, String) async -> Void

    init(context: ColumnEditorContext, save: @escaping (String, String) async -> Void) {
        self.context = context
        self.save = save
        _label = State(initialValue: context.label)
        _description = State(initialValue: context.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(context.status == nil ? "Add column" : "Edit column").font(DS.Font.section)
            TextField("Column name", text: $label).mainField()
            TextField("Description", text: $description).mainField()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save") { Task { await save(label.trimmingCharacters(in: .whitespacesAndNewlines), description); dismiss() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct SkillsLibraryView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @State private var response: HubSkillsResponse?
    @State private var loading = true
    @State private var error: String?
    @State private var notice: String?
    @State private var addError: String?
    @State private var dropTargeted = false
    @State private var adding = false

    var body: some View {
        WLPageHeader(title: "Skills library", subtitle: "Portable skills shared by every connected client.") {
            HStack(spacing: 8) {
                Button("Add skill") { chooseSkills() }.buttonStyle(SecondaryButtonStyle())
                Button("Export all") { MainLinks.open(exportURL) }.buttonStyle(OutlineButtonStyle())
            }
        }
        if let notice { WLStatusPill(text: notice, kind: .good) }
        if let addError { WLStatusPill(text: addError, kind: .bad) }
        dropZone
        if loading && response == nil {
            ProgressView("Loading skills…")
        } else if let error {
            MainNotice(symbol: "shippingbox", title: "Skills unavailable", message: error)
        } else if let response {
            WLGroup(title: "Available skills", subtitle: "\(response.skills.count) stored on the hub", icon: "shippingbox") {
                if response.skills.isEmpty {
                    Text("No shared skills yet.").foregroundStyle(p.textMuted)
                }
                ForEach(response.skills) { skill in
                    if skill.id != response.skills.first?.id { WLDivider() }
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(skill.name).font(DS.Font.bodySmall.weight(.semibold))
                            Text(skill.description ?? "\(skill.fileCount) files")
                                .font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2)
                        }
                        Spacer()
                        Button("Download") { MainLinks.open(downloadURL(skill.id)) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            WLGroup(title: "Connect another client", subtitle: "Copy the current hub-specific install prompt.", icon: "laptopcomputer") {
                Text(response.installPrompt).font(DS.Font.micro).foregroundStyle(p.textMuted).textSelection(.enabled)
                Button("Copy install prompt") { copy(response.installPrompt) }.buttonStyle(SecondaryButtonStyle())
            }
        }
        Color.clear.frame(height: 0).task(id: store.config.hubURL) { await load() }
    }

    private var root: String { store.config.hubURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
    private var exportURL: URL? { URL(string: root + "/api/skills/export.zip") }
    private func downloadURL(_ id: String) -> URL? {
        URL(string: root + "/api/skills/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/download")
    }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        notice = "Copied to the clipboard."
    }
    private var dropZone: some View {
        VStack(spacing: 4) {
            if adding {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "square.and.arrow.down").font(.system(size: 18)).foregroundStyle(dropTargeted ? p.accent : p.textMuted)
            }
            Text("Drop a skill here").font(DS.Font.bodySmall.weight(.semibold))
            Text("A skill folder, a ZIP, or a single SKILL.md. Or click to choose.")
                .font(DS.Font.micro).foregroundStyle(p.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(dropTargeted ? p.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTargeted ? p.accent : p.border, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
        )
        .contentShape(Rectangle())
        .onTapGesture { chooseSkills() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { Task { await add(urls) } }
            return true
        }
        .accessibilityLabel("Add a skill")
    }

    private func chooseSkills() {
        let panel = NSOpenPanel()
        panel.message = "Choose a skill folder, a ZIP, or a SKILL.md file."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await add(urls) }
    }

    /// Each dropped or chosen item is one skill.
    private func add(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        adding = true; addError = nil; notice = nil
        defer { adding = false }
        var added: [String] = []
        for url in urls {
            do {
                if let name = try await addOne(url, overwrite: false) { added.append(name) }
            } catch HubClient.HubError.http(409) {
                guard confirmReplace(url.lastPathComponent) else { continue }
                do {
                    if let name = try await addOne(url, overwrite: true) { added.append(name) }
                } catch { addError = describe(error, url) }
            } catch { addError = describe(error, url) }
        }
        if !added.isEmpty {
            notice = added.count == 1 ? "Added \(added[0])." : "Added \(added.count) skills."
            await load()
        }
    }

    private func addOne(_ url: URL, overwrite: Bool) async throws -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let files = try Self.files(in: url)
            guard files.contains(where: { $0.path.hasSuffix("SKILL.md") }) else { throw SkillAddError.noManifest }
            return try await store.hub.addSkill(files: files, filename: nil, overwrite: overwrite)
        }
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "zip":
            return try await store.hub.addSkill(archive: data, filename: url.lastPathComponent, overwrite: overwrite)
        case "md":
            // A lone markdown file is the skill's SKILL.md. Its own name wins; the file name is the fallback.
            let isManifest = url.deletingPathExtension().lastPathComponent.lowercased() == "skill"
            return try await store.hub.addSkill(
                files: [(path: "SKILL.md", data: data)], filename: isManifest ? nil : url.lastPathComponent, overwrite: overwrite)
        default:
            throw SkillAddError.unsupported
        }
    }

    private enum SkillAddError: Error { case noManifest, unsupported }

    private static let skipped: Set<String> = [".DS_Store", ".git", "__pycache__"]

    /// Every file under a skill folder, with paths relative to the folder's parent.
    private static func files(in folder: URL) throws -> [(path: String, data: Data)] {
        let base = folder.standardizedFileURL.path
        var found: [(path: String, data: Data)] = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = walker?.nextObject() as? URL {
            if skipped.contains(item.lastPathComponent) { walker?.skipDescendants(); continue }
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(item.standardizedFileURL.path.dropFirst(base.count + 1))
            found.append((path: folder.lastPathComponent + "/" + relative, data: try Data(contentsOf: item)))
        }
        return found
    }

    private func confirmReplace(_ label: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace the existing skill?"
        alert.informativeText = "A skill from “\(label)” is already in the library."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func describe(_ error: Error, _ url: URL) -> String {
        let label = url.lastPathComponent
        switch error {
        case SkillAddError.noManifest, HubClient.HubError.http(400):
            return "“\(label)” is not a skill yet: it needs a SKILL.md file at its top level."
        case SkillAddError.unsupported:
            return "“\(label)” can't be added. Use a skill folder, a ZIP, or a SKILL.md file."
        default:
            return "Couldn't add “\(label)”: \(error.localizedDescription)"
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { response = try await store.hub.skills(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct DuplicateCleanupView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @State private var groups: [HubDuplicateGroup] = []
    @State private var selections: [String: Int] = [:]
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        WLPageHeader(title: "Duplicate cleanup", subtitle: "Review exact name or slug matches before combining anything.") {
            Button("Scan again") { Task { await load() } }.buttonStyle(SecondaryButtonStyle())
        }
        if loading && groups.isEmpty {
            ProgressView("Scanning…")
        } else if let error {
            MainNotice(symbol: "exclamationmark.triangle", title: "Cleanup unavailable", message: error)
        } else if groups.isEmpty {
            MainNotice(symbol: "checkmark.seal", title: "No duplicates found", message: "Project names and slugs are clean.")
        } else {
            ForEach(groups) { group in
                WLGroup(title: "Possible duplicate", subtitle: "Choose the project record to keep.", icon: "arrow.triangle.merge") {
                    Picker("Keep", selection: selection(group)) {
                        ForEach(group.projects) { project in
                            Text("\(project.name) · \(project.chatCount) chats · \(project.memoryCount) memories").tag(project.id)
                        }
                    }
                    ForEach(group.projects) { project in
                        Text(project.path ?? project.slug ?? String(project.id)).font(DS.Font.micro).foregroundStyle(p.textMuted)
                    }
                    Button("Merge selected duplicates") { Task { await merge(group) } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        Color.clear.frame(height: 0).task(id: store.config.hubURL) { await load() }
    }

    private func selection(_ group: HubDuplicateGroup) -> Binding<Int> {
        Binding(get: { selections[group.key] ?? group.projects.first?.id ?? 0 },
                set: { selections[group.key] = $0 })
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            groups = try await store.hub.duplicateGroups()
            for group in groups where selections[group.key] == nil { selections[group.key] = group.projects.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func merge(_ group: HubDuplicateGroup) async {
        guard let target = selections[group.key] ?? group.projects.first?.id else { return }
        do {
            try await store.hub.mergeProjects(targetID: target, sourceIDs: group.projects.map(\.id).filter { $0 != target })
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

private struct SnippetsLibraryView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @State private var snippets: [HubSnippet] = []
    @State private var projects: [HubProject] = []
    @State private var title = ""
    @State private var language = ""
    @State private var content = ""
    @State private var projectID = 0
    @State private var error: String?

    var body: some View {
        WLPageHeader(title: "Snippets", subtitle: "Small reusable pieces of code stored with project context.")
        WLGroup(title: "New snippet", subtitle: "Save a reusable command, query, or code fragment.", icon: "plus.square") {
            HStack {
                TextField("Title", text: $title).mainField()
                TextField("Language", text: $language).mainField().frame(width: 150)
                Picker("Project", selection: $projectID) {
                    Text("No project").tag(0)
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }.frame(width: 220)
            }
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced)).frame(minHeight: 100)
                .padding(8).background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            Button("Save snippet") { Task { await create() } }
                .buttonStyle(PrimaryButtonStyle()).disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let error { WLStatusPill(text: error, kind: .bad) }
        WLGroup(title: "Saved snippets", subtitle: "\(snippets.count) on this hub", icon: "chevron.left.forwardslash.chevron.right") {
            if snippets.isEmpty { Text("No snippets yet.").foregroundStyle(p.textMuted) }
            ForEach(snippets) { snippet in
                if snippet.id != snippets.first?.id { WLDivider() }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(snippet.title).font(DS.Font.bodySmall.weight(.semibold))
                        if let language = snippet.language { MainTag(text: language) }
                        Spacer()
                        Button(role: .destructive) { Task { await remove(snippet) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    Text(snippet.content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(8)
                }
            }
        }
        Color.clear.frame(height: 0).task(id: store.config.hubURL) { await load() }
    }

    private func load() async {
        do {
            async let loadedSnippets = store.hub.snippets()
            async let loadedProjects = store.hub.projects()
            (snippets, projects) = try await (loadedSnippets, loadedProjects)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func create() async {
        do {
            try await store.hub.createSnippet(title: title, language: language, content: content, projectID: projectID == 0 ? nil : projectID)
            title = ""; language = ""; content = ""
            await load()
        } catch { self.error = error.localizedDescription }
    }
    private func remove(_ snippet: HubSnippet) async {
        do { try await store.hub.deleteSnippet(id: snippet.id); await load() }
        catch { self.error = error.localizedDescription }
    }
}
