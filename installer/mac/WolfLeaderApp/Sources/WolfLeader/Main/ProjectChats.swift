import AppKit
import SwiftUI

/// The Chats card on a project page: every chat about this project, with any agent, and a way to
/// start a new one. A chat started here belongs to this project, so it is always filed here.
struct ProjectChatsGroup: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var chats = ChatStore.shared
    let entry: ProjectEntry
    @State private var showAll = false
    @State private var removing: ChatRecord?

    private var mine: [ChatRecord] { chats.chats(projectID: entry.id) }

    var body: some View {
        WLGroup(title: "Chats", subtitle: "Talk to any AI agent about this project. Each chat starts with the project's notes, works in the project's folder on the server, and is saved here.",
                icon: "bubble.left.and.bubble.right") {
            NewChatMenu { agent in
                let chat = chats.create(project: ProjectRef(entry.project), agent: agent)
                nav.open(chat: chat.id, project: entry.id)
            }
            if !mine.isEmpty { WLDivider() }
            let shown = showAll ? mine : Array(mine.prefix(6))
            ForEach(shown) { chat in
                if chat.id != shown.first?.id { WLDivider() }
                ChatRow(chat: chat, showProject: false) { nav.open(chat: chat.id, project: entry.id) }
                    .contextMenu { Button("Remove from this Mac…", role: .destructive) { removing = chat } }
            }
            if mine.count > 6 {
                Button(showAll ? "Show fewer" : "Show all \(mine.count) chats") { showAll.toggle() }.buttonStyle(OutlineButtonStyle())
            }
        }
        .confirmationDialog("Remove “\(removing?.title ?? "")” from this Mac?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { chats.remove(removing.id) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The copy saved in Wolf Leader stays in this project's logbook.")
        }
    }
}

/// "New chat" with a choice of agent. Agents that aren't set up yet lead to Settings > Agents,
/// where they can be installed, signed in to, or pointed at by hand.
struct NewChatMenu: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var agents = AgentRegistry.shared
    let start: (AgentKind) -> Void

    var body: some View {
        let ready = agents.all.filter { agents.found[$0.id] != nil }
        let missing = agents.all.filter { agents.found[$0.id] == nil }
        Menu {
            if !ready.isEmpty {
                Section("Ready") {
                    ForEach(ready) { agent in
                        Button { start(agent) } label: { Label("\(agent.name) · \(agent.company)", systemImage: agent.symbol) }
                    }
                }
            }
            if !missing.isEmpty {
                Section("Set up first") {
                    ForEach(missing) { agent in
                        Button { nav.open(settingsTab: "agents") } label: {
                            Label("Set up \(agent.name)…", systemImage: agent.symbol)
                        }
                    }
                }
            }
            Divider()
            Button { nav.open(settingsTab: "agents") } label: { Label("Manage agents…", systemImage: "gearshape") }
        } label: {
            Label("New chat", systemImage: "plus.bubble")
        }
        .menuStyle(.button)
        .fixedSize()
        .onAppear { agents.rescanNow() }
        .task { await agents.refresh() }
    }
}

/// One chat in a list: agent, title, when, and whether it's working right now.
struct ChatRow: View {
    @Environment(\.palette) private var p
    @ObservedObject private var chats = ChatStore.shared
    let chat: ChatRecord
    var showProject = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: chat.agent?.symbol ?? "bubble.left")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accent)
                    .frame(width: 26, height: 26)
                    .background(p.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text([chat.agent?.name ?? chat.agentID, showProject ? chat.projectName : nil,
                          "\(chat.items.filter { $0.kind == .user }.count) messages"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(DS.Font.micro).foregroundStyle(p.textMuted)
                }
                Spacer(minLength: 8)
                if chats.isRunning(chat.id) { WLStatusPill(text: "Working", kind: .warn) }
                Text(HubDate.format(chat.updated)).font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The sidebar's Chats page: recent chats from every project, grouped by project.
struct AllChatsView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var chats = ChatStore.shared

    /// Chats not in a project come first, then each project's, most recent first.
    private var groups: [(projectID: Int?, name: String, chats: [ChatRecord])] {
        var order: [Int?] = []
        var byProject: [Int?: [ChatRecord]] = [:]
        for chat in chats.records {
            if byProject[chat.projectID] == nil { order.append(chat.projectID) }
            byProject[chat.projectID, default: []].append(chat)
        }
        order.sort { a, _ in a == nil }
        return order.map { id in (id, id == nil ? "Not in a project yet" : byProject[id]?.first?.projectName ?? "Project", byProject[id] ?? []) }
    }

    var body: some View {
        MainPage {
            WLPageHeader(eyebrow: "Chats", title: "Recent chats",
                         subtitle: "Every chat with every agent. Start one here and add it to a project any time, or start it from a project's page.") {
                NewChatMenu { agent in
                    let chat = chats.create(project: nil, agent: agent)
                    nav.open(chat: chat.id, project: nil)
                }
            }
            if chats.records.isEmpty {
                MainNotice(symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                           message: "Choose New chat to talk to Claude, Codex or another agent. Add the chat to a project whenever you like.")
            }
            ForEach(groups, id: \.projectID) { group in
                WLGroup(title: group.name) {
                    ForEach(group.chats.prefix(8)) { chat in
                        if chat.id != group.chats.first?.id { WLDivider() }
                        ChatRow(chat: chat) { nav.open(chat: chat.id, project: group.projectID) }
                    }
                    if let id = group.projectID {
                        Button("Open project") { nav.open(project: id) }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
    }
}

/// Pick the project a chat belongs to.
struct ProjectPickerSheet: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let current: Int?
    let choose: (ProjectRef) -> Void
    @State private var projects: [HubProject] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    private var shown: [HubProject] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let open = projects.filter { !["done", "archived"].contains($0.status) }
        guard !q.isEmpty else { return open }
        return projects.filter { ($0.name + " " + ($0.slug ?? "") + " " + ($0.description ?? "")).lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(current == nil ? "Add this chat to a project" : "Move this chat to another project")
                    .font(DS.Font.section).foregroundStyle(p.text)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Text("Wolf Leader files the chat there, and the next message brings in that project's notes.")
                .font(DS.Font.caption).foregroundStyle(p.textMuted)
            TextField("Search projects", text: $query).mainField()
            if loading { ProgressView() }
            if let error { WLStatusPill(text: error, kind: .bad) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { project in
                        Button {
                            choose(ProjectRef(project))
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text)
                                    if let description = project.description, !description.isEmpty {
                                        Text(description).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if project.id == current { Image(systemName: "checkmark").foregroundStyle(p.accent) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(project.id == current)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .background(p.background)
        .task {
            do { projects = try await store.hub.projects() } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
