import AppKit
import SwiftUI

/// The Chats card on a project page: every chat about this project, with any agent, and a way to
/// start a new one. A chat started here belongs to this project, so it is always filed here.
struct ProjectChatsGroup: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var chats = ChatStore.shared
    let entry: ProjectEntry
    let folders: [HubProjectFolder]
    /// Links a folder to the project on the hub (used when the project has none on this Mac yet).
    let linkFolder: (String) -> Void
    @State private var showAll = false
    @State private var removing: ChatRecord?

    private var mine: [ChatRecord] { chats.chats(projectID: entry.id) }

    var body: some View {
        WLGroup(title: "Chats", subtitle: "Talk to any AI agent about this project. Each chat starts with the project's notes and is saved here.",
                icon: "bubble.left.and.bubble.right") {
            HStack(spacing: 8) {
                NewChatMenu { start($0) }
                if workingFolder == nil {
                    Text("You'll pick the project's folder first.").font(DS.Font.micro).foregroundStyle(p.textFaint)
                } else if let folder = workingFolder {
                    Text("Runs in \(folder)").font(DS.Font.micro.monospaced()).foregroundStyle(p.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                }
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

    /// The first of the project's folders that exists on this Mac.
    private var workingFolder: String? {
        let candidates = folders.filter { $0.kind != "compose" }.map(\.path) + [entry.project.path].compactMap { $0 }
        return candidates.first { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private func start(_ agent: AgentKind) {
        var folder = workingFolder
        if folder == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Use this folder"
            panel.message = "Where does \(entry.name) live on this Mac? It's linked to the project, and agents work there."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            folder = url.path
            linkFolder(url.path)
        }
        guard let folder else { return }
        let chat = chats.create(projectID: entry.id, projectName: entry.name, agent: agent, cwd: folder, mode: .ask)
        nav.open(chat: chat.id, project: entry.id)
    }
}

/// "New chat" with a choice of agent. Agents that aren't installed are listed, greyed out.
struct NewChatMenu: View {
    @Environment(\.palette) private var p
    let start: (AgentKind) -> Void
    @State private var installed: Set<String> = []

    var body: some View {
        Menu {
            Section("Installed") {
                ForEach(AgentKind.builtIn.filter { installed.contains($0.id) }) { agent in
                    Button { start(agent) } label: { Label("\(agent.name) · \(agent.company)", systemImage: agent.symbol) }
                }
            }
            let missing = AgentKind.builtIn.filter { !installed.contains($0.id) }
            if !missing.isEmpty {
                Section("Not installed") {
                    ForEach(missing) { agent in
                        Button { } label: { Label("\(agent.name) · \(agent.company)", systemImage: agent.symbol) }
                            .disabled(true)
                            .help(agent.installHint)
                    }
                }
            }
        } label: {
            Label("New chat", systemImage: "plus.bubble")
        }
        .menuStyle(.button)
        .fixedSize()
        .onAppear { installed = Set(AgentKind.builtIn.filter { AgentLocator.find($0.binary) != nil }.map(\.id)) }
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

    private var groups: [(projectID: Int, name: String, chats: [ChatRecord])] {
        var order: [Int] = []
        var byProject: [Int: [ChatRecord]] = [:]
        for chat in chats.records {
            if byProject[chat.projectID] == nil { order.append(chat.projectID) }
            byProject[chat.projectID, default: []].append(chat)
        }
        return order.map { id in (id, byProject[id]?.first?.projectName ?? "Project", byProject[id] ?? []) }
    }

    var body: some View {
        MainPage {
            WLPageHeader(eyebrow: "Chats", title: "Recent chats",
                         subtitle: "Every chat with every agent, filed under its project. Start a new one from a project's page.")
            if chats.records.isEmpty {
                MainNotice(symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                           message: "Open a project and choose New chat. Claude, Codex and the other agents all work there.") {
                    Button("Open projects") { nav.open(projectsTab: "focus") }.buttonStyle(PrimaryButtonStyle())
                }
            }
            ForEach(groups, id: \.projectID) { group in
                WLGroup(title: group.name) {
                    ForEach(group.chats.prefix(8)) { chat in
                        if chat.id != group.chats.first?.id { WLDivider() }
                        ChatRow(chat: chat) { nav.open(chat: chat.id, project: group.projectID) }
                    }
                    Button("Open project") { nav.open(project: group.projectID) }.buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }
}
