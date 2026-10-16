import AppKit
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case projects, library, ask, shares, settings

    var id: String { rawValue }

    static let primary: [MainSection] = [.projects, .library, .ask]

    var label: String {
        switch self {
        case .projects: return "Projects"
        case .library: return "Library"
        case .ask: return "Search"
        case .shares: return "Shares"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .projects: return "folder"
        case .library: return "rectangle.3.group"
        case .ask: return "sparkle.magnifyingglass"
        case .shares: return "externaldrive.connected.to.line.below"
        case .settings: return "gearshape"
        }
    }
}

/// A row in the sidebar: a whole section, or one view inside Projects or Library.
enum SidebarItem: Hashable {
    case projects(String)
    case library(String)
    case section(MainSection)

    @MainActor init(_ route: Route) {
        switch route.section {
        case .projects: self = .projects(route.projectsTab)
        case .library: self = .library(route.libraryTab)
        default: self = .section(route.section)
        }
    }

    @MainActor func open(in nav: Navigator) {
        switch self {
        case .projects(let tab): nav.open(projectsTab: tab)
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
    @State private var hubOK: Bool? = nil
    @State private var toolbarQuery = ""

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
                // Every view inside a section is one click away, no menu diving.
                Section("Projects") {
                    Label("Focus", systemImage: "scope").tag(SidebarItem.projects("focus"))
                    Label("Board", systemImage: "rectangle.3.group").tag(SidebarItem.projects("board"))
                    Label("All projects", systemImage: "list.bullet").tag(SidebarItem.projects("all"))
                }
                Section("Library") {
                    Label("Skills", systemImage: "shippingbox").tag(SidebarItem.library("skills"))
                    Label("People", systemImage: "person.2").tag(SidebarItem.library("people"))
                    Label("Bring in", systemImage: "tray.and.arrow.down").tag(SidebarItem.library("bringin"))
                    Label("My tools", systemImage: "laptopcomputer").tag(SidebarItem.library("tools"))
                    Label("Backups", systemImage: "externaldrive.badge.checkmark").tag(SidebarItem.library("repos"))
                    Label("Cleanup", systemImage: "arrow.triangle.merge").tag(SidebarItem.library("cleanup"))
                    Label("Snippets", systemImage: "chevron.left.forwardslash.chevron.right").tag(SidebarItem.library("snippets"))
                }
                Section {
                    Label(MainSection.shares.label, systemImage: MainSection.shares.symbol).tag(SidebarItem.section(.shares))
                    Label {
                        HStack(spacing: 6) {
                            Text(MainSection.settings.label)
                            Spacer(minLength: 0)
                            if updates.hasUpdate {
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
                HubStatusCard(hubOK: hubOK, hubURL: store.config.hubURL) {
                    nav.open(section: .settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
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
        .environmentObject(nav)
        .onAppear { nav.watchSwipes() }
        .environmentObject(updates)
        .task {
            updates.start(store: store)
        }
        .task(id: store.config.hubURL) {
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
