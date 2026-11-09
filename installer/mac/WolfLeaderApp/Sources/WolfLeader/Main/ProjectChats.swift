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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chats").font(DS.Font.bodySmall.weight(.semibold))
                Text("\(mine.count)").font(DS.Font.caption).foregroundStyle(p.textMuted)
                Spacer()
                Button { nav.newChat(project: ProjectRef(entry.project)) } label: { Label("New chat", systemImage: "plus.bubble") }
                    .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
            }
            if !mine.isEmpty { WLDivider() }
            let shown = showAll ? mine : Array(mine.prefix(3))
            ForEach(shown) { chat in
                if chat.id != shown.first?.id { WLDivider() }
                ChatRow(chat: chat, showProject: false) { nav.open(chat: chat.id, project: entry.id) }
                    .contextMenu { Button("Remove from Chats…", role: .destructive) { removing = chat } }
            }
            if mine.count > 3 {
                Button(showAll ? "Show fewer" : "Show all \(mine.count) chats") { showAll.toggle() }.buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(12)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("Remove “\(removing?.title ?? "")” from Chats?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { chats.remove(removing.id) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It goes away on every device. The copy saved in this project's logbook stays.")
        }
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
                          "\(chat.items.filter { $0.kind == .user }.count) messages",
                          chat.agentDevice.flatMap { $0 == ChatSync.shared.device ? nil : "last on \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(DS.Font.micro).foregroundStyle(p.textMuted)
                }
                Spacer(minLength: 8)
                if chats.isRunning(chat.id) {
                    WLStatusPill(text: "Working", kind: .warn)
                } else if let other = chat.busyElsewhere(than: ChatSync.shared.device) {
                    WLStatusPill(text: "Working on \(other)", kind: .neutral)
                }
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
            WLPageHeader(eyebrow: "Chats", title: "All chats",
                         subtitle: "Every chat with every agent, on every device. Each reply is saved to Wolf Leader as it happens, so you can pick a chat up on another Mac, or with another agent, right where it stopped.") {
                Button { nav.newChat() } label: { Label("New chat", systemImage: "plus.bubble") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            RecentOnThisMacGroup()
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
            OtherToolChatsGroup()
        }
    }
}

/// The newest chats in the Claude app, Claude Code and Codex on this Mac, saved to Wolf Leader or
/// not. Open one and it's in Wolf Leader (and its ledger) from then on.
private struct RecentOnThisMacGroup: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var agents = AgentRegistry.shared
    @ObservedObject private var chats = ChatStore.shared
    @State private var sessions: [LocalSession] = []
    @State private var known: Set<String> = []
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sessions.isEmpty {
                WLGroup(title: "Recent on this Mac",
                        subtitle: "Your latest chats in the Claude app, Claude Code and Codex, saved to Wolf Leader or not. Open one to keep going here; it's saved to Wolf Leader as soon as you do.",
                        icon: "clock.arrow.circlepath") {
                    let shown = showAll ? sessions : Array(sessions.prefix(6))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { WLDivider() }
                        row(session)
                    }
                    if sessions.count > 6 {
                        Button(showAll ? "Show fewer" : "Show all \(sessions.count)") { showAll.toggle() }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
    }

    private func row(_ session: LocalSession) -> some View {
        let opened = chats.openedLocal(session)
        let saved = opened != nil || known.contains(session.sessionID)
        let ready = agents.all.filter { agents.found[$0.id] != nil }
        let own = ready.first { $0.id == session.agentID }
        return HStack(spacing: 10) {
            Image(systemName: session.tool == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accent)
                .frame(width: 26, height: 26)
                .background(p.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                Text([session.toolName, session.folderName, HubDate.format(session.when)].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.Font.micro).foregroundStyle(p.textMuted)
            }
            Spacer(minLength: 8)
            if !saved { WLStatusPill(text: "Not in Wolf Leader", kind: .warn) }
            if let opened {
                Button("Open") { nav.open(chat: opened.id, project: opened.projectID) }.buttonStyle(OutlineButtonStyle())
            } else if let own {
                Button("Open here") { open(session, with: own) }.buttonStyle(PrimaryButtonStyle())
                    .help("Opens it in Wolf Leader and saves it. \(own.name) picks the session back up where it stopped.")
            }
            Menu {
                Section("Continue with") {
                    ForEach(ready) { agent in
                        Button { open(session, with: agent) } label: { Label("\(agent.name) · \(agent.company)", systemImage: agent.symbol) }
                    }
                }
                if ready.isEmpty { Button("Set up an AI…") { nav.open(libraryTab: "tools") } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func open(_ session: LocalSession, with agent: AgentKind) {
        let chat = ChatStore.shared.openLocal(session, with: agent, hubURL: store.config.hubURL)
        nav.open(chat: chat.id, project: chat.projectID)
    }

    private func load() async {
        let found = await Task.detached { LocalSessions.recent() }.value
        sessions = found
        guard !found.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["ids": found.map(\.sessionID)]),
              let data = try? await store.hub.data("/api/sessions/known", method: "POST", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        known = Set((json["known"] as? [String]) ?? [])
    }
}

/// Chats saved from AI tools outside Wolf Leader (Claude Code in a terminal, Codex, Cursor). Any of
/// them can be carried on here, with any agent, without losing what was said.
private struct OtherToolChatsGroup: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var agents = AgentRegistry.shared
    @State private var saved: [[String: Any]] = []
    @State private var working: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !saved.isEmpty {
                WLGroup(title: "From your other AI tools",
                        subtitle: "Chats saved from Claude Code, Codex, Cursor and others. Continue any of them here, with any agent.",
                        icon: "tray.and.arrow.down") {
                    ForEach(Array(saved.prefix(12).enumerated()), id: \.offset) { index, chat in
                        if index > 0 { WLDivider() }
                        row(chat)
                    }
                    if let error { Text(error).font(DS.Font.caption).foregroundStyle(p.bad) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: store.config.hubURL) { await load() }
    }

    private func row(_ chat: [String: Any]) -> some View {
        let id = chat["id"] as? Int ?? 0
        let ready = agents.all.filter { agents.found[$0.id] != nil }
        let meta = [chat["project_name"] as? String,
                    (chat["device_name"] as? String).flatMap { $0 == "unraid-server" ? nil : "on \($0)" },
                    (chat["message_count"] as? Int).map { "\($0) messages" },
                    HubDate.parse((chat["occurred_at"] as? String) ?? (chat["updated_at"] as? String)).map { HubDate.format($0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return WLRow(title: AgentText.oneLine(chat["title"] as? String ?? "Untitled chat", limit: 80), detail: meta) {
            if working == id {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    ForEach(ready) { agent in
                        Button { Task { await continueChat(id, with: agent) } } label: {
                            Label("\(agent.name) · \(agent.company)", systemImage: agent.symbol)
                        }
                    }
                    if ready.isEmpty { Button("Set up agents…") { nav.open(libraryTab: "tools") } }
                } label: {
                    Text("Continue with…")
                }
                .menuStyle(.button).fixedSize()
                .disabled(working != nil)
            }
        }
    }

    private func load() async {
        guard let data = try? await store.hub.data("/api/chats", query: ["limit": "40"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chats = json["chats"] as? [[String: Any]] else { return }
        saved = chats.filter {
            !(($0["session_id"] as? String) ?? "").hasPrefix("wolf-chat-") && (($0["message_count"] as? Int) ?? 0) > 0
        }
    }

    private func continueChat(_ id: Int, with agent: AgentKind) async {
        working = id
        error = nil
        defer { working = nil }
        do {
            let record = try await ChatStore.shared.continueHubChat(id: id, with: agent, hub: store.hub)
            nav.open(chat: record.id, project: record.projectID)
        } catch {
            self.error = "Couldn't bring that chat in: \(error.localizedDescription)"
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
