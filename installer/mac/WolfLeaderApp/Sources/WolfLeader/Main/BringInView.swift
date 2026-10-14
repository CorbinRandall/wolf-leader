import AppKit
import SwiftUI

/// Library → Bring in: find past chats in Claude Code, Codex and Cursor on this Mac and add them
/// to projects, plus what those tools have learned about the person.
struct BringInView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

    private struct Group: Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var count: Int
        var new: Int
        var tools: [String]
        var last: String
        var raw: [String: Any]
    }

    private struct Candidate: Identifiable {
        var id: Int
        var text: String
        var kind: String
        var source: String
    }

    @State private var scanning = false
    @State private var groups: [Group] = []
    @State private var choices: [String: String] = [:]      // "p:<id>", "new", "loose", "skip"
    @State private var newNames: [String: String] = [:]
    @State private var candidates: [Candidate] = []
    @State private var picked: Set<Int> = []
    @State private var person = ""
    @State private var owners: [String] = []
    @State private var projects: [HubProject] = []
    @State private var toolCounts: [(String, Int)] = []
    @State private var scanned = false
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var current = ""
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        WLPageHeader(title: "Bring in", subtitle: "Add past chats from Claude Code, Codex and Cursor on this Mac.") {
            Button(scanned ? "Look again" : "Look for history") { Task { await scan() } }
                .buttonStyle(SecondaryButtonStyle()).disabled(scanning || running)
        }
        if let result { WLStatusPill(text: result, kind: .good) }
        if let error { WLStatusPill(text: error, kind: .bad) }
        if scanning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking through your AI tools. This takes about a minute.").font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            }
        } else if running {
            WLGroup(title: "Bringing it in", subtitle: "\(done) of \(total) chats", icon: "tray.and.arrow.down") {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(current).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
            }
        } else if !scanned {
            MainNotice(symbol: "tray.and.arrow.down", title: "Nothing looked at yet",
                       message: "Wolf Leader reads the chats your AI tools keep on this Mac. You choose where each batch goes before anything is added.")
        } else {
            found
        }
        Color.clear.frame(height: 0).task(id: store.config.hubURL) { await loadLists() }
    }

    @ViewBuilder private var found: some View {
        let waiting = groups.filter { $0.new > 0 }
        Text("Found " + toolCounts.map { "\($0.1) new in \(toolName($0.0))" }.joined(separator: ", ") + ".")
            .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
        if waiting.isEmpty {
            MainNotice(symbol: "checkmark.seal", title: "All caught up", message: "Every chat on this Mac is already in Wolf Leader.")
        } else {
            WLGroup(title: "Where each batch goes", subtitle: "Grouped by the folder they happened in. Change any choice.", icon: "folder") {
                ForEach(waiting) { group in
                    if group.key != waiting.first?.key { WLDivider() }
                    row(group)
                }
            }
        }
        if !candidates.isEmpty {
            WLGroup(title: "About you", subtitle: "Notes your tools kept about you. Tick the ones to add to a profile.", icon: "person.text.rectangle") {
                HStack {
                    Text("Add to").font(DS.Font.bodySmall)
                    Picker("", selection: $person) { ForEach(owners, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: 180)
                    Spacer()
                }
                ForEach(candidates) { item in
                    Toggle(isOn: Binding(get: { picked.contains(item.id) },
                                         set: { if $0 { picked.insert(item.id) } else { picked.remove(item.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).font(DS.Font.bodySmall).lineLimit(3)
                            Text("From \(toolName(item.source))").font(DS.Font.micro).foregroundStyle(p.textFaint)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        let count = waiting.filter { (choices[$0.key] ?? "skip") != "skip" }.reduce(0) { $0 + $1.new }
        HStack {
            Spacer()
            Button(count == 1 ? "Bring in 1 chat" : "Bring in \(count) chats") { Task { await importNow() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(count == 0 && picked.isEmpty)
        }
    }

    private func row(_ group: Group) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.label).font(DS.Font.bodySmall.weight(.semibold))
                Text("\(group.new) new · \(group.tools.map(toolName).joined(separator: ", ")) · last \(group.last)")
                    .font(DS.Font.micro).foregroundStyle(p.textMuted)
            }
            Spacer()
            if choices[group.key] == "new" {
                TextField("Project name", text: Binding(get: { newNames[group.key] ?? group.label },
                                                        set: { newNames[group.key] = $0 }))
                    .mainField().frame(width: 180)
            }
            Picker("", selection: Binding(get: { choices[group.key] ?? "skip" }, set: { choices[group.key] = $0 })) {
                Text("New project").tag("new")
                Text("Loose chats").tag("loose")
                Text("Skip").tag("skip")
                Divider()
                ForEach(projects) { Text($0.name).tag("p:\($0.id)") }
            }
            .labelsHidden().frame(width: 200)
        }
    }

    private func toolName(_ tool: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "cursor": "Cursor"][tool] ?? tool.capitalized
    }

    private func loadLists() async {
        async let loadedOwners = store.hub.owners()
        async let loadedProjects = store.hub.projects()
        owners = (try? await loadedOwners) ?? []
        projects = ((try? await loadedProjects) ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if person.isEmpty { person = owners.first ?? "" }
    }

    private func scan() async {
        scanning = true; error = nil; result = nil
        defer { scanning = false }
        do {
            let json = try await ToolBridge.json(["scan"], hubURL: store.config.hubURL)
            toolCounts = ((json["tools"] as? [[String: Any]]) ?? []).compactMap {
                guard let tool = $0["tool"] as? String, let new = $0["new"] as? Int else { return nil }
                return (tool, new)
            }
            groups = ((json["groups"] as? [[String: Any]]) ?? []).map { raw in
                Group(key: raw["key"] as? String ?? UUID().uuidString, label: raw["label"] as? String ?? "Folder",
                      count: raw["count"] as? Int ?? 0, new: raw["new"] as? Int ?? 0,
                      tools: raw["tools"] as? [String] ?? [], last: String((raw["last"] as? String ?? "").prefix(10)), raw: raw)
            }
            choices = [:]; newNames = [:]
            for group in groups {
                let suggestion = group.raw["suggestion"] as? [String: Any] ?? [:]
                switch suggestion["action"] as? String {
                case "existing": choices[group.key] = (suggestion["project_id"] as? Int).map { "p:\($0)" } ?? "loose"
                case "new": choices[group.key] = "new"; newNames[group.key] = suggestion["name"] as? String ?? group.label
                default: choices[group.key] = "loose"
                }
            }
            candidates = ((json["profile"] as? [[String: Any]]) ?? []).enumerated().map { index, item in
                Candidate(id: index, text: item["text"] as? String ?? "", kind: item["kind"] as? String ?? "about",
                          source: item["source"] as? String ?? "import")
            }
            picked = []
            scanned = true
            await loadLists()
        } catch { self.error = error.localizedDescription }
    }

    private func importNow() async {
        var planGroups: [[String: Any]] = []
        for group in groups where group.new > 0 {
            var raw = group.raw
            switch choices[group.key] ?? "skip" {
            case "skip": continue
            case "new": raw["choice"] = ["action": "new", "name": newNames[group.key] ?? group.label]
            case "loose": raw["choice"] = ["action": "loose"]
            case let value where value.hasPrefix("p:"):
                raw["choice"] = ["action": "existing", "project_id": Int(value.dropFirst(2)) ?? 0]
            default: continue
            }
            planGroups.append(raw)
        }
        var plan: [String: Any] = ["groups": planGroups]
        let items = candidates.filter { picked.contains($0.id) }.map { ["text": $0.text, "kind": $0.kind, "source": $0.source] }
        if !items.isEmpty && !person.isEmpty { plan["profile"] = ["person": person, "items": items] }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wolf-import-plan.json")
        do {
            try JSONSerialization.data(withJSONObject: plan).write(to: file)
        } catch { self.error = error.localizedDescription; return }

        running = true; error = nil; result = nil; done = 0; total = 0; current = ""
        var saved = 0, failed = 0, profileAdded = 0
        do {
            _ = try await ToolBridge.stream(["import", file.path], hubURL: store.config.hubURL) { event in
                switch event["event"] as? String {
                case "start": total = event["total"] as? Int ?? 0
                case "project": current = "Made project \(event["name"] as? String ?? "")"
                case "saved", "failed":
                    done = event["done"] as? Int ?? done
                    current = event["title"] as? String ?? ""
                case "finished":
                    saved = event["saved"] as? Int ?? 0
                    failed = event["failed"] as? Int ?? 0
                    profileAdded = event["profile_added"] as? Int ?? 0
                default: break
                }
            }
        } catch { self.error = error.localizedDescription }
        try? FileManager.default.removeItem(at: file)
        running = false
        var parts = ["Brought in \(saved) chat\(saved == 1 ? "" : "s")."]
        if profileAdded > 0 { parts.append("Added \(profileAdded) to \(person)'s profile.") }
        if failed > 0 { parts.append("\(failed) could not be read.") }
        result = parts.joined(separator: " ")
        await scan()
        result = parts.joined(separator: " ")
    }
}

/// Library → My tools: every AI tool on this Mac gets the same profile and skills, so moving from
/// one to another loses nothing. Wolf Leader keeps the history for all of them.
struct MyToolsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

    private struct Tool: Identifiable {
        var id: String
        var name: String
        var installed: Bool
        var connected: Bool
        var skills: Int
        var hasProfile: Bool
    }

    private struct Skill: Identifiable {
        var id: String { name }
        var name: String
        var tools: [String]
    }

    @State private var tools: [Tool] = []
    @State private var skills: [Skill] = []
    @State private var owners: [String] = []
    @State private var person = ""
    @State private var picked: Set<String> = []
    @State private var loading = false
    @State private var sending = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        WLPageHeader(title: "My tools", subtitle: "Give every AI tool on this Mac the same profile and skills.") {
            Button("Check again") { Task { await load() } }.buttonStyle(SecondaryButtonStyle()).disabled(loading)
        }
        if let notice { WLStatusPill(text: notice, kind: .good) }
        if let error { WLStatusPill(text: error, kind: .bad) }
        if loading && tools.isEmpty { ProgressView("Checking your tools…") }
        if !tools.isEmpty {
            WLGroup(title: "On this Mac", subtitle: "Connected tools save their chats to Wolf Leader.", icon: "laptopcomputer") {
                ForEach(tools) { tool in
                    if tool.id != tools.first?.id { WLDivider() }
                    HStack {
                        Text(tool.name).font(DS.Font.bodySmall.weight(.semibold))
                        Spacer()
                        if !tool.installed {
                            MainTag(text: "Not installed")
                        } else {
                            MainTag(text: tool.connected ? "Connected" : "Not connected", color: tool.connected ? p.accent : p.textMuted)
                            MainTag(text: "\(tool.skills) skills")
                            MainTag(text: tool.hasProfile ? "Has your profile" : "No profile yet")
                        }
                    }
                }
                if tools.contains(where: { $0.installed && !$0.connected }) {
                    Text("To connect a tool, use Settings → Update, which sets up every tool it finds.")
                        .font(DS.Font.micro).foregroundStyle(p.textMuted)
                }
            }
            let missing = skills.filter { skill in installed.contains(where: { !skill.tools.contains($0) }) }
            WLGroup(title: "Skills", subtitle: missing.isEmpty ? "Every tool has every skill." : "Tick skills to copy to the tools that lack them.", icon: "shippingbox") {
                ForEach(missing) { skill in
                    Toggle(isOn: Binding(get: { picked.contains(skill.name) },
                                         set: { if $0 { picked.insert(skill.name) } else { picked.remove(skill.name) } })) {
                        HStack {
                            Text(skill.name).font(DS.Font.bodySmall)
                            Spacer()
                            Text("in " + skill.tools.map(toolName).joined(separator: ", "))
                                .font(DS.Font.micro).foregroundStyle(p.textMuted)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if !missing.isEmpty {
                    HStack {
                        Button("Tick all") { picked = Set(missing.map(\.name)) }.buttonStyle(OutlineButtonStyle())
                        Button("Clear") { picked = [] }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            WLGroup(title: "Profile", subtitle: "Each tool reads it at the start of every chat.", icon: "person.text.rectangle") {
                HStack {
                    Text("Whose profile").font(DS.Font.bodySmall)
                    Picker("", selection: $person) {
                        Text("Don't send a profile").tag("")
                        ForEach(owners, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                    Spacer()
                }
                Text("Only a marked part of each tool's notes file is replaced. Anything else you wrote there stays.")
                    .font(DS.Font.micro).foregroundStyle(p.textMuted)
            }
            HStack {
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Send to all my tools") { Task { await send() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sending || (person.isEmpty && picked.isEmpty))
            }
        }
        Color.clear.frame(height: 0).task(id: store.config.hubURL) { await load() }
    }

    private var installed: [String] { tools.filter(\.installed).map(\.id) }

    private func toolName(_ tool: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "cursor": "Cursor"][tool] ?? tool.capitalized
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let json = try await ToolBridge.json(["tools"], hubURL: store.config.hubURL)
            tools = ((json["tools"] as? [[String: Any]]) ?? []).map {
                Tool(id: $0["tool"] as? String ?? "", name: $0["name"] as? String ?? "", installed: $0["installed"] as? Bool ?? false,
                     connected: $0["connected"] as? Bool ?? false, skills: $0["skills"] as? Int ?? 0,
                     hasProfile: $0["has_profile"] as? Bool ?? false)
            }
            skills = ((json["skills"] as? [[String: Any]]) ?? []).map {
                Skill(name: $0["name"] as? String ?? "", tools: $0["tools"] as? [String] ?? [])
            }
            owners = (try? await store.hub.owners()) ?? owners
            if person.isEmpty, let first = owners.first { person = first }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func send() async {
        sending = true; defer { sending = false }
        var args = ["send", "--to", installed.joined(separator: ",")]
        if !person.isEmpty { args += ["--person", person] }
        if !picked.isEmpty { args += ["--skills", picked.sorted().joined(separator: ",")] }
        do {
            let json = try await ToolBridge.json(args, hubURL: store.config.hubURL)
            let copied = ((json["skills"] as? [Any]) ?? []).count
            let profiles = ((json["profile"] as? [Any]) ?? []).count
            var parts: [String] = []
            if profiles > 0 { parts.append("Profile sent to \(profiles) tool\(profiles == 1 ? "" : "s").") }
            if copied > 0 { parts.append("Copied \(copied) skill\(copied == 1 ? "" : "s").") }
            notice = parts.isEmpty ? "Nothing needed sending." : parts.joined(separator: " ")
            picked = []
            error = nil
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

/// One person's profile: what every AI tool should know about them. Edit any line, add new ones.
struct ProfileSheet: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let person: String

    @State private var sections: [HubProfileSection] = []
    @State private var newText = ""
    @State private var newKind = "about"
    @State private var editing: Int?
    @State private var editText = ""
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                WLEyebrow("Profile")
                Text(person).font(DS.Font.page).foregroundStyle(p.text)
                Text("What every AI tool should know about \(person). Bring in adds notes your tools already kept.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notice { WLStatusPill(text: notice, kind: .good) }
                    if let error { WLStatusPill(text: error, kind: .bad) }
                    VStack(alignment: .leading, spacing: 8) {
                        WLEyebrow("Add something about yourself")
                        TextField("For example: I write music, and I'm new to coding", text: $newText, axis: .vertical)
                            .lineLimit(1...4).mainField()
                        HStack {
                            Picker("", selection: $newKind) {
                                ForEach(sections) { Text($0.title).tag($0.kind) }
                            }
                            .labelsHidden().frame(width: 220)
                            Spacer()
                            Button("Add") { add() }.buttonStyle(SecondaryButtonStyle())
                                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            WLEyebrow(section.title)
                            if section.items.isEmpty {
                                Text("Nothing yet.").font(DS.Font.micro).foregroundStyle(p.textFaint)
                            }
                            ForEach(section.items) { item in itemRow(item) }
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Copy for an AI") { copy() }.buttonStyle(OutlineButtonStyle())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 620, height: 700)
        .background(p.background)
        .task { await load() }
    }

    @ViewBuilder private func itemRow(_ item: HubProfileItem) -> some View {
        if editing == item.id {
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $editText, axis: .vertical).lineLimit(1...6).mainField()
                HStack {
                    Picker("", selection: Binding(get: { item.kind }, set: { kind in move(item, to: kind) })) {
                        ForEach(sections) { Text($0.title).tag($0.kind) }
                    }
                    .labelsHidden().frame(width: 220)
                    Spacer()
                    Button("Cancel") { editing = nil }.buttonStyle(OutlineButtonStyle())
                    Button("Save") { save(item) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text(item.text).font(DS.Font.bodySmall).textSelection(.enabled)
                Spacer(minLength: 8)
                if item.source != "manual" { MainTag(text: item.source.capitalized) }
                Button { editText = item.text; editing = item.id } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit")
                Button(role: .destructive) { remove(item) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove")
            }
        }
    }

    private func load() async {
        do { sections = try await store.hub.profile(person: person); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func run(_ done: String?, _ work: @escaping (HubClient) async throws -> Void) {
        Task {
            do { try await work(store.hub); notice = done; error = nil; await load() }
            catch { self.error = "That did not save. \(error.localizedDescription)" }
        }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        newText = ""
        run("Added.") { try await $0.addProfileItem(person: person, text: text, kind: newKind) }
    }

    private func save(_ item: HubProfileItem) {
        let text = editText
        editing = nil
        run(nil) { try await $0.updateProfileItem(id: item.id, text: text) }
    }

    private func move(_ item: HubProfileItem, to kind: String) {
        run(nil) { try await $0.updateProfileItem(id: item.id, kind: kind) }
    }

    private func remove(_ item: HubProfileItem) {
        run("Removed.") { try await $0.deleteProfileItem(id: item.id) }
    }

    private func copy() {
        Task {
            do {
                let text = try await store.hub.profileMarkdown(person: person)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                notice = "Copied. Paste it into any AI chat."
            } catch { self.error = error.localizedDescription }
        }
    }
}
