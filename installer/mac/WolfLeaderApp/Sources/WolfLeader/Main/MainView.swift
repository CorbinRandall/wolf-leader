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
    case newChat, allChats, chat(String), project(Int), projects, library
    case section(MainSection)

    @MainActor init(_ route: Route) {
        switch route.section {
        case .chats:
            // A chat in a project keeps its project lit in the sidebar: that's where you are.
            if let id = route.chatID {
                self = ChatStore.shared.record(id)?.projectID.map { .project($0) } ?? .chat(id)
            } else {
                self = route.chatList ? .allChats : .newChat
            }
        case .projects: self = route.projectID.map { .project($0) } ?? .projects
        case .library, .shares: self = .section(.settings)
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
        case .library: nav.open(libraryTab: nav.route.libraryTab)
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
    @StateObject private var projectsModel = ProjectsModel()
    @ObservedObject private var chats = ChatStore.shared
    @AppStorage("wl.sidebar.showNoProject") private var showNoProject: Bool = true
    @State private var hubOK: Bool? = nil
    @State private var toolbarQuery = ""
    @State private var removingChat: ChatRecord?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SidebarItem?>(
                get: { SidebarItem(nav.route) },
                set: { if let item = $0 { item.open(in: nav) } }
            )) {
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
                Section("Projects") {
                    SidebarProjectFolders(model: projectsModel)
                    Label("All projects", systemImage: "list.bullet").tag(SidebarItem.projects)
                    if showNoProject, chats.records.contains(where: { $0.projectID == nil }) {
                        Label("Loose chats", systemImage: "tray").tag(SidebarItem.allChats)
                    }
                }
                Section {
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
            .contextMenu {
                Button("Sidebar settings") { nav.open(section: .settings) }
            }
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
        .confirmationDialog("Remove \u{201C}\(removingChat?.title ?? "")\u{201D} from Chats?",
                            isPresented: Binding(get: { removingChat != nil }, set: { if !$0 { removingChat = nil } })) {
            Button("Remove", role: .destructive) {
                if let chat = removingChat {
                    if nav.route.chatID == chat.id { nav.newChat() }
                    ChatStore.shared.remove(chat.id)
                }
                removingChat = nil
            }
            Button("Cancel", role: .cancel) { removingChat = nil }
        } message: {
            Text("It goes away on every device. The copy saved in its project's logbook stays.")
        }
        .background {
            Button("") { nav.open(section: .settings) }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
        }
        .environmentObject(nav)
        .environmentObject(search)
        .onAppear { nav.watchSwipes() }
        .environmentObject(updates)
        .task {
            updates.start(store: store)
            SkillSyncer.shared.start(store: store)
        }
        .task(id: store.config.hubURL) {
            await projectsModel.load(store.hub)
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
                ChatHome(model: projectsModel)
            }
        case .projects:
            ProjectsView(openSettings: { nav.open(section: .settings) }, model: projectsModel)
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
