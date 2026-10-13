import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryTab: String, Hashable {
    case skills, people, repos, cleanup, snippets
}

/// Client-first management tools. The hub keeps a compact fallback UI; day-to-day organization
/// lives here in the native app.
struct LibraryView: View {
    @State private var tab: LibraryTab = .skills

    private var tabs: [WLTab<LibraryTab>] {
        [
            WLTab(id: .skills, title: "Skills", icon: "shippingbox"),
            WLTab(id: .people, title: "People", icon: "person.2"),
            WLTab(id: .repos, title: "Backups", icon: "externaldrive.badge.checkmark"),
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
            case .skills: SkillsLibraryView()
            case .people: PeopleLibraryView()
            case .repos: ReposLibraryView()
            case .cleanup: DuplicateCleanupView()
            case .snippets: SnippetsLibraryView()
            }
        }
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


/// Library → People: who projects can belong to. Add, rename or remove an owner.
private struct PeopleLibraryView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @State private var owners: [String] = []
    @State private var counts: [String: Int] = [:]
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var removing: String?
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        WLPageHeader(title: "People", subtitle: "Who a project can belong to. Change a project's owner from its tag in Projects.")
        if let notice { WLStatusPill(text: notice, kind: .good) }
        if let error { WLStatusPill(text: error, kind: .bad) }
        WLGroup(title: "Owners", subtitle: "\(counts[""] ?? 0) project\((counts[""] ?? 0) == 1 ? " has" : "s have") no owner.", icon: "person.2") {
            if owners.isEmpty { Text("No owners yet.").font(DS.Font.bodySmall).foregroundStyle(p.textMuted) }
            ForEach(owners, id: \.self) { name in
                if name != owners.first { WLDivider() }
                HStack {
                    if renaming == name {
                        TextField("Name", text: $renameText).mainField().frame(maxWidth: 240)
                            .onSubmit { rename(name) }
                        Button("Save") { rename(name) }.buttonStyle(SecondaryButtonStyle())
                            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { renaming = nil }.buttonStyle(OutlineButtonStyle())
                    } else {
                        Text(name).font(DS.Font.bodySmall.weight(.semibold))
                        Text("\(counts[name] ?? 0) project\((counts[name] ?? 0) == 1 ? "" : "s")").font(DS.Font.micro).foregroundStyle(p.textMuted)
                    }
                    Spacer()
                    if renaming != name {
                        Button("Rename") { renameText = name; renaming = name }.buttonStyle(OutlineButtonStyle())
                        Button("Remove") { removing = name }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            WLDivider()
            HStack {
                TextField("Add a person", text: $newName).mainField().frame(maxWidth: 240).onSubmit { add() }
                Button("Add") { add() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
        }
        Color.clear.frame(height: 0).task(id: store.config.hubURL) { await load() }
            .confirmationDialog(
                "Remove \(removing ?? "")?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                presenting: removing
            ) { name in
                ForEach(owners.filter { $0 != name }, id: \.self) { other in
                    Button("Remove and give their projects to \(other)") { remove(name, moveTo: other) }
                }
                Button("Remove and leave their projects with no owner", role: .destructive) { remove(name, moveTo: nil) }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { name in
                Text("\(counts[name] ?? 0) project\((counts[name] ?? 0) == 1 ? "" : "s") belong to \(name). The projects themselves are kept.")
            }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        run("Added \(name).") { try await $0.addOwner(name) }
    }

    private func rename(_ old: String) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        run("Renamed \(old) to \(name).") { try await $0.renameOwner(old, to: name) }
    }

    private func remove(_ name: String, moveTo: String?) {
        removing = nil
        run("Removed \(name).") { try await $0.removeOwner(name, moveTo: moveTo) }
    }

    private func run(_ done: String, _ work: @escaping (HubClient) async throws -> Void) {
        Task {
            do { try await work(store.hub); notice = done; error = nil; await load() }
            catch { self.error = "That did not work. The name may already be taken."; notice = nil }
        }
    }

    private func load() async {
        do {
            let summary = try await store.hub.ownerSummary()
            owners = summary.owners
            counts = summary.counts
        } catch { self.error = error.localizedDescription }
    }
}
