import AppKit
import SwiftUI

/// The projects the sidebar and the new-chat page offer: open ones, the ones you chatted in most
/// recently first. One shared list, so a project made on the new-chat page shows up everywhere.
@MainActor
final class RecentProjects: ObservableObject {
    static let shared = RecentProjects()

    @Published private(set) var all: [HubProject] = []
    private var hub: HubClient?

    func load(_ hub: HubClient) async {
        self.hub = hub
        if let projects = try? await hub.projects() { all = projects }
    }

    func reload() async { if let hub { await load(hub) } }

    func project(_ id: Int) -> HubProject? { all.first { $0.id == id } }

    /// Open projects, most recently used first (a chat in it counts as use).
    func recent(chats: [ChatRecord]) -> [HubProject] {
        var lastChat: [Int: Date] = [:]
        for chat in chats {
            guard let id = chat.projectID else { continue }
            lastChat[id] = max(lastChat[id] ?? .distantPast, chat.updated)
        }
        func used(_ p: HubProject) -> Date { max(lastChat[p.id] ?? .distantPast, p.updated ?? .distantPast) }
        return all.filter { !["done", "archived"].contains($0.status) }.sorted { used($0) > used($1) }
    }

    /// Make a project from just a name. Returns it with its real slug, so its chat gets its folder.
    func create(name: String, owner: String?, hub: HubClient) async throws -> ProjectRef {
        let id = try await hub.startProject(name: name, description: "", northStar: "", owner: owner ?? "",
                                            status: "in_progress", milestones: [], folder: "", tags: [])
        self.hub = hub
        await reload()
        if let made = project(id) { return ProjectRef(made) }
        return ProjectRef(id: id, name: name, slug: nil)
    }
}

/// The new-chat page: one big box. Pick a project (or make one), type, press Return.
/// The chat starts right away and keeps running while you go elsewhere.
struct ChatHome: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var nav: Navigator
    @Environment(\.palette) private var p
    @ObservedObject private var agents = AgentRegistry.shared
    @ObservedObject private var projects = RecentProjects.shared
    @ObservedObject private var chats = ChatStore.shared
    @AppStorage("wl.chat.agent") private var agentID = "claude"
    @ObservedObject var projectsModel: ProjectsModel

    @State private var draft = ""
    @State private var files: [URL] = []
    /// The model and effort for the next chat; remembered per agent.
    @State private var model: String?
    @State private var effort: String?
    @State private var project: ProjectRef?
    @State private var naming = false
    @State private var newName = ""
    @State private var picking = false
    @State private var starting = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case message, projectName }

    private var ready: [AgentKind] { agents.all.filter { agents.found[$0.id] != nil } }
    private var agent: AgentKind? { ready.first { $0.id == agentID } ?? ready.first }
    /// The chips: recent projects, plus the picked one if it came from "More…".
    private var chips: [ProjectRef] {
        var list = projects.recent(chats: chats.records).prefix(6).map(ProjectRef.init)
        if let project, !list.contains(where: { $0.id == project.id }) { list.insert(project, at: 0) }
        return list
    }
    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty) && agent != nil && !starting
            && (!naming || !newName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.lg) {
                Spacer(minLength: 60)
                VStack(spacing: 6) {
                    WolfMark(size: 34)
                    Text(greeting).font(DS.Font.hero).foregroundStyle(p.text)
                }
                projectChips
                composer
                if let error { WLStatusPill(text: error, kind: .bad) }
                if ready.isEmpty && !agents.scanning { noAgents }
                if project == nil && !naming && draft.isEmpty { PickUpStrip(model: projectsModel).padding(.top, DS.Spacing.sm) }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(p.background)
        .onAppear {
            takePending()
            focus = .message
            agents.rescanNow()
        }
        .onChange(of: nav.pendingNewChat) { _, _ in takePending() }
        .task { await agents.refresh() }
        .task(id: store.config.hubURL) { await projects.load(store.hub) }
        .sheet(isPresented: $picking) {
            ProjectPickerSheet(current: project?.id) { choose($0) }
                .environment(\.palette, p)
                .environmentObject(store)
        }
    }

    private var greeting: String {
        if let project { return "What's next for \(project.name)?" }
        if naming { return "Start something new" }
        return "What do you want to work on?"
    }

    // MARK: Project chips

    private var projectChips: some View {
        VStack(spacing: 8) {
            FlowLayout(spacing: 8) {
                chip("No project", symbol: "bubble.left", selected: project == nil && !naming) {
                    naming = false; project = nil; focus = .message
                }
                ForEach(chips, id: \.id) { ref in
                    chip(ref.name, symbol: "folder", selected: project?.id == ref.id && !naming) { choose(ref) }
                }
                chip("More…", symbol: "ellipsis", selected: false) { picking = true }
                chip("New project", symbol: "plus", selected: naming, accent: true) {
                    naming = true; project = nil; focus = .projectName
                }
            }
            if naming {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").foregroundStyle(p.accent)
                    TextField("Name the new project", text: $newName)
                        .textFieldStyle(.plain)
                        .font(DS.Font.body)
                        .focused($focus, equals: .projectName)
                        .onSubmit { focus = .message }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(p.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(p.accent.opacity(0.5), lineWidth: 1))
                .frame(maxWidth: 360)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DS.Anim.swap, value: naming)
    }

    private func chip(_ title: String, symbol: String, selected: Bool, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(DS.Font.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? p.onAccent : (accent ? p.accent : p.text))
                .background(selected ? p.accent : p.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : (accent ? p.accent.opacity(0.5) : p.border.opacity(0.7)), lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ ref: ProjectRef) {
        naming = false
        project = ref
        focus = .message
    }

    /// A project's + button (sidebar or project page) asked for a chat in that project.
    private func takePending() {
        guard let request = nav.pendingNewChat else { return }
        nav.pendingNewChat = nil
        naming = request.newProject
        project = request.project
        error = nil
        focus = naming ? .projectName : .message
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(agent.map { "Message \($0.name)…" } ?? "Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Font.bodyLarge)
                .lineLimit(3...14)
                .focused($focus, equals: .message)
                .shiftReturnNewline()
                .onSubmit(start)
                .disabled(starting)
            AttachmentTray(files: $files)
            HStack(spacing: 10) {
                agentMenu
                AttachButton(files: $files)
                MicButton(id: "new-chat", draft: $draft)
                ModelMenu(agent: agent, model: model, effort: effort) { m, e in
                    model = m
                    effort = e
                    if let agent { ModelDefaults.set(agent.id, model: m, effort: e) }
                }
                .task(id: agent?.id) {
                    model = agent.flatMap { ModelDefaults.model($0.id) }
                    effort = agent.flatMap { ModelDefaults.effort($0.id) }
                }
                if let project {
                    Label(project.name, systemImage: "folder").font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
                } else if naming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("New: \(newName)", systemImage: "folder.badge.plus").font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if starting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: start) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(p.onAccent)
                            .frame(width: 30, height: 30)
                            .background(canSend ? p.accent : p.textFaint.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help("Start the chat (Return; Shift-Return for a new line)")
                }
            }
        }
        .padding(16)
        .acceptsAttachments($files)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.border.opacity(0.8), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var agentMenu: some View {
        Menu {
            ForEach(ready) { a in
                Button { agentID = a.id } label: {
                    if a.id == agent?.id { Label("\(a.name) · \(a.company)", systemImage: "checkmark") } else { Text("\(a.name) · \(a.company)") }
                }
            }
            Divider()
            Button("Set up more AIs…") { nav.open(libraryTab: "tools") }
        } label: {
            Label(agent?.name ?? "Choose an AI", systemImage: agent?.symbol ?? "sparkle")
                .font(DS.Font.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Which AI runs this chat. You can hand the chat to another one later.")
    }

    private var noAgents: some View {
        MainNotice(symbol: "person.2.wave.2", title: "Set up an AI to chat with",
                   message: "Wolf Leader runs Claude Code, Codex, Gemini and others on this Mac.") {
            Button("Set up an AI…") { nav.open(libraryTab: "tools") }.buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Start

    private func start() {
        guard canSend, let agent else { return }
        Dictation.shared.stop()
        let text = draft
        let attached = files
        let name = newName.trimmingCharacters(in: .whitespaces)
        let makeProject = naming
        starting = true
        error = nil
        Task {
            defer { starting = false }
            var ref = project
            if makeProject {
                do {
                    ref = try await projects.create(name: name, owner: store.config.person, hub: store.hub)
                } catch {
                    self.error = "Couldn't make the project: \(error.localizedDescription)"
                    return
                }
            }
            let chat = chats.create(project: ref, agent: agent, model: model, effort: effort)
            chats.session(chat.id)?.send(text, attachments: attached, config: store)
            draft = ""
            files = []
            newName = ""
            naming = false
            project = nil
            nav.open(chat: chat.id)
        }
    }
}

/// Lays chips out in rows, wrapping and centring each row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.items + [index], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
