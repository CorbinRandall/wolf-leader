import AppKit
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case chats, projects, library, ask, shares, settings

    var id: String { rawValue }

    static let primary: [MainSection] = [.chats, .projects, .library, .ask]

    var label: String {
        switch self {
        case .chats: return "Chats"
        case .projects: return "Projects"
        case .library: return "Library"
        case .ask: return "Search"
        case .shares: return "Shares"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .projects: return "folder"
        case .library: return "rectangle.3.group"
        case .ask: return "sparkle.magnifyingglass"
        case .shares: return "externaldrive.connected.to.line.below"
        case .settings: return "gearshape"
        }
    }
}

/// A row in the sidebar.
enum SidebarItem: Hashable {
    case newChat, allChats, chat(String), project(Int), projects, library(String)
    case section(MainSection)

    @MainActor init(_ route: Route) {
        switch route.section {
        case .chats: self = route.chatID.map { .chat($0) } ?? (route.chatList ? .allChats : .newChat)
        case .projects: self = route.projectID.map { .project($0) } ?? .projects
        case .library: self = .library(route.libraryTab)
        default: self = .section(route.section)
        }
    }

    @MainActor func open(in nav: Navigator) {
        switch self {
        case .newChat: nav.newChat()
        case .allChats: nav.openChatList()
        case .chat(let id): nav.open(chat: id)
        case .project(let id): nav.open(project: id)
        case .projects: nav.open(projectsTab: nav.route.projectsTab)
        case .library(let tab): nav.open(libraryTab: tab)
        case .section(let section): nav.open(section: section)
        }
    }
}

/// The app's main window once setup is done: native sidebar (MacParakeet layout) + detail pages.
struct MainView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @StateObject private var updates = UpdateChecker()
    @StateObject private var nav = Navigator()
    @StateObject private var search = SearchModel()
    @State private var hubOK: Bool? = nil
    @State private var toolbarQuery = ""
    @State private var showAllProjects = false
    @State private var removingChat: ChatRecord?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SidebarItem?>(get: { SidebarItem(nav.route) }, set: { if let item = $0 { item.open(in: nav) } })) {
                Section {
                    HStack(spacing: 8) {
                        WolfMark(size: 18)
                        WLEyebrow("Wolf Leader", color: p.text)
                        if BuildInfo.isDev { MainTag(text: "DEV", color: p.accent2) }
                    }
                    .padding(.vertical, 4)
                    .selectionDisabled()
                }
                // Chat first: a new chat is always one click (or ⌘N) away.
                Section {
                    Label("New chat", systemImage: "square.and.pencil").tag(SidebarItem.newChat)
                    Label(MainSection.ask.label, systemImage: MainSection.ask.symbol).tag(SidebarItem.section(.ask))
                }
                SidebarProjectsSection(showAll: $showAllProjects, removing: $removingChat)
                SidebarChatsSection(removing: $removingChat)
                SidebarLibrarySection()
                Section {
                    Label(MainSection.shares.label, systemImage: MainSection.shares.symbol).tag(SidebarItem.section(.shares))
                    Label {
                        HStack(spacing: 6) {
                            Text(MainSection.settings.label)
                            Spacer(minLength: 0)
                            if updates.needsAttention {
                                Circle()
                                    .fill(p.accent)
                                    .frame(width: 7, height: 7)
                                    .help("Update available")
                            }
                        }
                    } icon: {
                        Image(systemName: MainSection.settings.symbol)
                    }
                    .tag(SidebarItem.section(.settings))
                }
            }
            .listStyle(.sidebar)
            .tint(p.accent)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if updates.appUpdateAvailable || updates.appPhase.active {
                        SidebarUpdateCard()
                    }
                    HubStatusCard(hubOK: hubOK, hubURL: store.config.hubURL) {
                        nav.open(section: .settings)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(p.background)
        }
        // Always in the top-right corner: Return opens the results page with what was typed.
        .searchable(text: $toolbarQuery, placement: .toolbar, prompt: "Search")
        .onSubmit(of: .search) {
            nav.search(toolbarQuery)
            toolbarQuery = ""
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { nav.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .help("New chat (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
                Button { nav.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!nav.canGoBack)
                    .help("Back")
                    .keyboardShortcut("[", modifiers: .command)
                Button { nav.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!nav.canGoForward)
                    .help("Forward")
                    .keyboardShortcut("]", modifiers: .command)
            }
        }
        .confirmationDialog("Remove “\(removingChat?.title ?? "")” from Chats?",
                            isPresented: Binding(get: { removingChat != nil }, set: { if !$0 { removingChat = nil } })) {
            Button("Remove", role: .destructive) {
                if let chat = removingChat {
                    if nav.route.chatID == chat.id { nav.newChat() }
                    ChatStore.shared.remove(chat.id)
                    Drafts.shared.set(chat.id, "")
                }
                removingChat = nil
            }
            Button("Cancel", role: .cancel) { removingChat = nil }
        } message: {
            Text("It goes away on every device. The copy saved in its project's logbook stays.")
        }
        .environmentObject(nav)
        .environmentObject(search)
        .onAppear { nav.watchSwipes() }
        .environmentObject(updates)
        .task {
            updates.start(store: store)
        }
        .task(id: store.config.hubURL) {
            // Chats follow you: every device on this hub sees and continues the same chats.
            ChatSync.shared.start(hubURL: store.config.hubURL, device: store.config.deviceName)
            ChatStore.shared.pruneEmpty()
            ChatRules.shared.start(hubURL: store.config.hubURL)
            await RecentProjects.shared.load(store.hub)
            // Who uses this Mac: guess from its name ("Corbin's Mac Studio") when it's one of the hub's people.
            if store.config.person == nil, let owners = try? await store.hub.owners() {
                let name = store.config.deviceName.lowercased()
                let matches = owners.filter { name.contains($0.lowercased()) }
                if matches.count == 1 { store.config.person = matches[0]; store.save() }
            }
            hubOK = nil
            while !Task.isCancelled {
                hubOK = await store.hub.isHealthy()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch nav.route.section {
        case .chats:
            if let chatID = nav.route.chatID, let session = ChatStore.shared.session(chatID) {
                ChatView(session: session, back: { nav.closeChat() }).id(chatID)
            } else if nav.route.chatList {
                AllChatsView()
            } else {
                ChatHome()
            }
        case .projects:
            ProjectsView(openSettings: { nav.open(section: .settings) })
        case .library:
            LibraryView()
        case .ask:
            AskView()
        case .shares:
            SharesView()
        case .settings:
            SettingsView()
        }
    }
}

/// Which chats the sidebar lists: the ones still in progress. Nobody has to tidy up. A chat
/// stays while it's working, waiting for you, open, has unsent text, or was used in the last
/// day; after a quiet day it leaves the sidebar on its own (it's still in the project and in
/// All chats).
@MainActor
enum SidebarChats {
    static let quietAfter: TimeInterval = 24 * 60 * 60
    static let perProject = 5

    static func needsYou(_ chat: ChatRecord, _ chats: ChatStore) -> Bool {
        chats.isRunning(chat.id) && chat.items.contains { $0.kind == .approval && $0.status == .pending }
    }

    static func inProgress(_ chat: ChatRecord, chats: ChatStore, openID: String?, drafts: Drafts) -> Bool {
        chat.id == openID
            || chats.isRunning(chat.id)
            || chat.busyElsewhere(than: ChatSync.shared.device) != nil
            || drafts.has(chat.id)
            || Date().timeIntervalSince(chat.updated) < quietAfter
    }

    /// In progress, the ones that need you first, then the most recently used.
    static func active(_ records: [ChatRecord], chats: ChatStore, openID: String?, drafts: Drafts) -> [ChatRecord] {
        records.filter { inProgress($0, chats: chats, openID: openID, drafts: drafts) }
            .sorted { a, b in
                let ra = rank(a, chats), rb = rank(b, chats)
                return ra != rb ? ra < rb : a.updated > b.updated
            }
    }

    private static func rank(_ chat: ChatRecord, _ chats: ChatStore) -> Int {
        needsYou(chat, chats) ? 0 : chats.isRunning(chat.id) ? 1 : 2
    }
}

/// Sidebar: projects, most recently used first. A project with chats in progress opens like a
/// folder to show them; click a project to open it, its + starts a chat in it.
private struct SidebarProjectsSection: View {
    @EnvironmentObject private var nav: Navigator
    @Environment(\.palette) private var p
    @ObservedObject private var projects = RecentProjects.shared
    @ObservedObject private var chats = ChatStore.shared
    @ObservedObject private var drafts = Drafts.shared
    @Binding var showAll: Bool
    @Binding var removing: ChatRecord?
    /// Projects whose chat list you folded away.
    @AppStorage("wl.sidebar.folded") private var foldedRaw = ""

    var body: some View {
        let recent = projects.recent(chats: chats.records)
        let active = SidebarChats.active(chats.records.filter { $0.projectID != nil }, chats: chats,
                                         openID: nav.route.chatID, drafts: drafts)
        let byProject = Dictionary(grouping: active, by: { $0.projectID! })
        // Projects with chats in progress are always listed, then the most recent fill up to six.
        let busy = recent.filter { byProject[$0.id] != nil }
        let rest = recent.filter { byProject[$0.id] == nil }
        let limit = showAll ? 25 : 6
        let shown = busy + rest.prefix(max(0, limit - busy.count))
        Section {
            ForEach(shown) { project in
                let list = byProject[project.id] ?? []
                if list.isEmpty {
                    row(project, chats: list)
                } else {
                    DisclosureGroup(isExpanded: expanded(project.id)) {
                        ForEach(list.prefix(SidebarChats.perProject)) { chat in
                            SidebarChatRow(chat: chat, working: chats.isRunning(chat.id),
                                           needsYou: SidebarChats.needsYou(chat, chats),
                                           hasDraft: drafts.has(chat.id), showProject: false)
                                .tag(SidebarItem.chat(chat.id))
                                .contextMenu { SidebarChatMenu(chat: chat, removing: $removing) }
                        }
                        if list.count > SidebarChats.perProject {
                            Button("\(list.count - SidebarChats.perProject) more in \(project.name)…") { nav.open(project: project.id) }
                                .buttonStyle(.plain).font(DS.Font.caption).foregroundStyle(p.textMuted)
                                .selectionDisabled()
                        }
                    } label: {
                        row(project, chats: list)
                    }
                }
            }
            if recent.count > shown.count || showAll {
                Button(showAll ? "Show fewer" : "Show more") { showAll.toggle() }
                    .buttonStyle(.plain).font(DS.Font.caption).foregroundStyle(p.textMuted)
                    .selectionDisabled()
            }
            Label("All projects", systemImage: "square.grid.2x2").tag(SidebarItem.projects)
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                Button { nav.newChat(newProject: true) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("New project: name it, then say what you want")
            }
        }
    }

    private func row(_ project: HubProject, chats list: [ChatRecord]) -> some View {
        SidebarProjectRow(project: project, working: list.contains { chats.isRunning($0.id) },
                          needsYou: list.contains { SidebarChats.needsYou($0, chats) })
            .tag(SidebarItem.project(project.id))
    }

    private var folded: Set<Int> { Set(foldedRaw.split(separator: ",").compactMap { Int($0) }) }

    private func expanded(_ id: Int) -> Binding<Bool> {
        Binding(get: { !folded.contains(id) }, set: { open in
            var set = folded
            if open { set.remove(id) } else { set.insert(id) }
            foldedRaw = set.sorted().map(String.init).joined(separator: ",")
        })
    }
}

private struct SidebarProjectRow: View {
    @EnvironmentObject private var nav: Navigator
    @Environment(\.palette) private var p
    let project: HubProject
    let working: Bool
    var needsYou = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label(project.name, systemImage: "folder").lineLimit(1)
            Spacer(minLength: 0)
            if needsYou {
                Circle().fill(p.accent2).frame(width: 7, height: 7).help("A chat is waiting for your OK")
            } else if working {
                ProgressView().controlSize(.mini)
            }
            if hovering {
                Button { nav.newChat(project: ProjectRef(project)) } label: {
                    Image(systemName: "plus.bubble").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.accent)
                .help("New chat in \(project.name)")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("New chat in \(project.name)") { nav.newChat(project: ProjectRef(project)) }
            Button("Open project") { nav.open(project: project.id) }
        }
    }
}

private struct SidebarChatMenu: View {
    @EnvironmentObject private var nav: Navigator
    let chat: ChatRecord
    @Binding var removing: ChatRecord?

    var body: some View {
        if let id = chat.projectID { Button("Open \(chat.projectName ?? "project")") { nav.open(project: id) } }
        Button("Remove from Chats…", role: .destructive) { removing = chat }
    }
}

/// Sidebar: chats in progress that aren't in a project yet (the rest sit under their project),
/// and the way to every chat.
private struct SidebarChatsSection: View {
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var chats = ChatStore.shared
    @ObservedObject private var drafts = Drafts.shared
    @Binding var removing: ChatRecord?

    var body: some View {
        let loose = SidebarChats.active(chats.records.filter { $0.projectID == nil }, chats: chats,
                                        openID: nav.route.chatID, drafts: drafts)
        Section("Chats") {
            ForEach(loose.prefix(8)) { chat in
                SidebarChatRow(chat: chat, working: chats.isRunning(chat.id),
                               needsYou: SidebarChats.needsYou(chat, chats), hasDraft: drafts.has(chat.id))
                    .tag(SidebarItem.chat(chat.id))
                    .contextMenu { SidebarChatMenu(chat: chat, removing: $removing) }
            }
            Label("All chats", systemImage: "list.bullet").tag(SidebarItem.allChats)
        }
    }
}

private struct SidebarChatRow: View {
    @Environment(\.palette) private var p
    let chat: ChatRecord
    let working: Bool
    let needsYou: Bool
    var hasDraft = false
    var showProject = true

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title).lineLimit(1)
                if showProject, let project = chat.projectName {
                    Text(project).font(DS.Font.micro).foregroundStyle(p.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if needsYou {
                Circle().fill(p.accent2).frame(width: 7, height: 7).help("Waiting for your OK")
            } else if working {
                ProgressView().controlSize(.mini).help("Working")
            } else if chat.busyElsewhere(than: ChatSync.shared.device) != nil {
                Image(systemName: "desktopcomputer").font(.system(size: 10)).foregroundStyle(p.textFaint)
                    .help("Working on another device")
            } else if hasDraft {
                Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(p.textFaint)
                    .help("Unsent message")
            }
        }
        .help([chat.title, chat.projectName, chat.agent?.name].compactMap { $0 }.joined(separator: " · "))
    }
}

/// Sidebar: Library folds open to every view inside it (Skills, People, ...).
private struct SidebarLibrarySection: View {
    @AppStorage("wl.sidebar.libraryOpen") private var open = true

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $open) {
                Label("Skills", systemImage: "shippingbox").tag(SidebarItem.library("skills"))
                Label("People", systemImage: "person.2").tag(SidebarItem.library("people"))
                Label("Bring in", systemImage: "tray.and.arrow.down").tag(SidebarItem.library("bringin"))
                Label("AI tools", systemImage: "person.2.wave.2").tag(SidebarItem.library("tools"))
                Label("Backups", systemImage: "externaldrive.badge.checkmark").tag(SidebarItem.library("repos"))
                Label("Cleanup", systemImage: "arrow.triangle.merge").tag(SidebarItem.library("cleanup"))
                Label("Snippets", systemImage: "chevron.left.forwardslash.chevron.right").tag(SidebarItem.library("snippets"))
            } label: {
                Label(MainSection.library.label, systemImage: MainSection.library.symbol)
                    .contentShape(Rectangle())
                    .onTapGesture { open.toggle() }
                    .selectionDisabled()
            }
        }
    }
}

/// Bottom of the sidebar when a new app is out: one click updates and reopens.
private struct SidebarUpdateCard: View {
    @EnvironmentObject private var updates: UpdateChecker
    @Environment(\.palette) private var p
    @State private var hovering = false

    private var caption: String {
        switch updates.appPhase {
        case .downloading(let f): return f.map { "Downloading update… \(Int($0 * 100))%" } ?? "Downloading update…"
        case .building: return "Building update…"
        case .installing: return "Installing update…"
        case .relaunching: return "Reopening…"
        case .idle, .failed: break
        }
        if case .failed = updates.appPhase { return "Update didn't finish · see Settings > Updates" }
        if let v = updates.latestRelease?.version, updates.channel == .release { return "Update to \(v)" }
        return "Update available · click to install"
    }

    var body: some View {
        Button {
            Task { await updates.updateApp() }
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Group {
                    if updates.appPhase.active {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(p.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(p.accent.opacity(0.12)))
                Text(caption)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row)
                    .fill(hovering ? p.surfaceRaised : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        }
        .buttonStyle(.plain)
        .disabled(updates.busy)
        .help("Downloads the new version, swaps it in and reopens Wolf Leader. Settings, chats and projects stay.")
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
    }
}

/// Pinned card under the sidebar list (MacParakeet's "1,117 electric cars, crushed" card).
private struct HubStatusCard: View {
    @Environment(\.palette) private var p
    let hubOK: Bool?
    let hubURL: String
    let action: () -> Void
    @State private var hovering = false

    init(hubOK: Bool?, hubURL: String, action: @escaping () -> Void) {
        self.hubOK = hubOK
        self.hubURL = hubURL
        self.action = action
    }

    var body: some View {
        let host = URL(string: hubURL)?.host ?? hubURL
        let (symbol, tint, caption): (String, Color, String) = {
            switch hubOK {
            case .some(true): return ("server.rack", p.good, "Hub online · \(host)")
            case .some(false): return ("wifi.exclamationmark", p.bad, "Can't reach hub at \(host)")
            case .none: return ("hourglass", p.textMuted, "Checking hub · \(host)")
            }
        }()
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.12)))
                Text(caption)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row)
                    .fill(hovering ? p.surfaceRaised : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        }
        .buttonStyle(.plain)
        .help("Hub at \(hubURL)")
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.sm)
    }
}

// MARK: - Shared pieces for the detail pages

/// Scrolling detail page: `p.background`, 24pt padding, stacked tiles and cards.
struct MainPage<Content: View>: View {
    @Environment(\.palette) private var p
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                content()
            }
            .padding(DS.Spacing.lg)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(p.background)
    }
}

/// Friendly message for empty lists and offline states: round tinted icon, title, grey line, buttons.
struct MainNotice<Actions: View>: View {
    @Environment(\.palette) private var p
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        Tile {
            VStack(spacing: DS.Spacing.sm + 4) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(p.textMuted)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(p.surface))
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(p.text)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(DS.Font.caption)
                        .foregroundStyle(p.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) { actions() }
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

extension MainNotice where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = { EmptyView() }
    }
}

/// Rounded inset field (MacParakeet's "Paste any video link" box).
struct MainFieldChrome: ViewModifier {
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(DS.Font.bodySmall)
            .foregroundStyle(p.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
    }
}

extension View {
    func mainField() -> some View { modifier(MainFieldChrome()) }
}

/// Small pill label (memory type, result kind, share role).
struct MainTag: View {
    @Environment(\.palette) private var p
    let text: String
    var color: Color?

    var body: some View {
        let c = color ?? p.accent
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(c)
            .background(c.opacity(0.14), in: Capsule())
    }
}

enum MainLinks {
    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
