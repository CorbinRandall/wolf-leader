import AppKit
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case home, projects, library, ask, wiki, shares, settings

    var id: String { rawValue }

    static let primary: [MainSection] = [.home, .projects, .library, .ask, .wiki]

    var label: String {
        switch self {
        case .home: return "Home"
        case .projects: return "Projects"
        case .library: return "Library"
        case .ask: return "Ask"
        case .wiki: return "Wiki"
        case .shares: return "Shares"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .projects: return "folder"
        case .library: return "rectangle.3.group"
        case .ask: return "sparkle.magnifyingglass"
        case .wiki: return "book.closed"
        case .shares: return "externaldrive.connected.to.line.below"
        case .settings: return "gearshape"
        }
    }
}

/// The app's main window once setup is done: native sidebar (MacParakeet layout) + detail pages.
struct MainView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @StateObject private var updates = UpdateChecker()
    @State private var section: MainSection? = .home
    @State private var hubOK: Bool? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    ForEach(MainSection.primary) { s in
                        Label(s.label, systemImage: s.symbol)
                            .tag(s)
                    }
                }
                Section {
                    Label(MainSection.shares.label, systemImage: MainSection.shares.symbol)
                        .tag(MainSection.shares)
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
                    .tag(MainSection.settings)
                }
            }
            .listStyle(.sidebar)
            .tint(p.accent)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HubStatusCard(hubOK: hubOK, hubURL: store.config.hubURL) {
                    section = .settings
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(p.background)
        }
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
        switch section ?? .home {
        case .home:
            HomeView(openSettings: { section = .settings }, openProjects: { section = .projects }, openWiki: { section = .wiki })
        case .projects:
            ProjectsView()
        case .library:
            LibraryView()
        case .ask:
            AskView()
        case .wiki:
            WikiView()
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
