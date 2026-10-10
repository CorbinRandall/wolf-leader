import AppKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    var openSettings: () -> Void
    var openProjects: () -> Void

    private enum LoadState: Equatable {
        case loading, ready, offline(String)
    }

    @State private var state: LoadState = .loading
    @State private var projects: [HubProject] = []
    @State private var chats: [HubChat] = []

    var body: some View {
        MainPage {
            switch state {
            case .loading:
                Tile {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading from your hub…")
                            .font(DS.Font.bodySmall)
                            .foregroundStyle(p.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            case .offline(let why):
                MainNotice(
                    symbol: "wifi.exclamationmark",
                    title: "Can't reach your hub at \(store.config.hubURL)",
                    message: "\(why) · Check Settings."
                ) {
                    Button("Check Settings", action: openSettings)
                        .buttonStyle(OutlineButtonStyle())
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            case .ready:
                stats
                recentChats
            }
            actionTiles
        }
        .task(id: store.config.hubURL) { await load() }
    }

    // MARK: Stats

    private var stats: some View {
        let memories = projects.reduce(0) { $0 + $1.memoryCount }
        let chatTotal = projects.reduce(0) { $0 + $1.chatCount }
        let lastSave = chats.compactMap(\.saved).max()
        return HStack(spacing: DS.Spacing.md) {
            Button(action: openProjects) {
                WLStatTile(title: "Projects", value: "\(projects.count)", icon: "folder")
            }
            .buttonStyle(.plain)
            Button(action: openProjects) {
                WLStatTile(title: "Memories", value: "\(memories)", icon: "brain")
            }
            .buttonStyle(.plain)
            WLStatTile(title: "Chats", value: "\(max(chatTotal, chats.count))", icon: "bubble.left.and.bubble.right")
            WLStatTile(
                title: "Last save",
                value: lastSave.map { Self.timeOnly($0) } ?? "None yet",
                icon: "clock",
                footnote: lastSave.map { Self.dateOnly($0) }
            )
        }
    }

    // MARK: Recent chats

    private var recentChats: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(spacing: 12) {
                    WLIconBadge(systemName: "bubble.left.and.text.bubble.right")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent chats").font(DS.Font.section).foregroundStyle(p.text)
                        Text("The latest sessions your agents saved, across every project.")
                            .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                    }
                    Spacer()
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Refresh")
                    Button("Open hub") { MainLinks.open(store.hub.webURL) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.bottom, 6)

                if chats.isEmpty {
                    Text("No chats saved yet. They show up here once an agent saves a session.")
                        .font(DS.Font.bodySmall)
                        .foregroundStyle(p.textMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(chats) { chat in
                            if chat.id != chats.first?.id { WLDivider() }
                            HomeChatRow(chat: chat) {
                                MainLinks.open(store.hub.webURL(chat: chat.id))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Action tiles

    private var obsidianInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }

    @ViewBuilder
    private var actionTiles: some View {
        if let wiki = store.config.wikiURL {
            HomeActionTile(
                symbol: "book.closed",
                tint: p.accent,
                title: "Open the wiki",
                detail: "Every project's brief, decisions and history as readable pages.",
                buttonTitle: "Open wiki",
                buttonSymbol: "arrow.up.right"
            ) { MainLinks.open(wiki) }
        }
        if let vault = store.config.vaultPath, obsidianInstalled {
            HomeActionTile(
                symbol: "diamond.fill",
                tint: p.warn,
                title: "Open Obsidian",
                detail: "Browse the shared vault with backlinks and graph view.",
                buttonTitle: "Open vault",
                buttonSymbol: "arrow.up.right"
            ) { MainLinks.open(Self.obsidianURL(vault: vault)) }
        }
    }

    static func obsidianURL(vault: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._~"))
        let encoded = vault.addingPercentEncoding(withAllowedCharacters: allowed) ?? vault
        return URL(string: "obsidian://open?path=" + encoded)
    }

    private static func timeOnly(_ d: Date) -> String {
        String(HubDate.format(d).prefix(5))
    }

    private static func dateOnly(_ d: Date) -> String {
        String(HubDate.format(d).dropFirst(6))
    }

    // MARK: Loading

    private func load() async {
        let hub = store.hub
        if case .ready = state {} else { state = .loading }
        do {
            async let ps = hub.projects()
            async let cs = hub.recentChats(limit: 10)
            let (loadedProjects, loadedChats) = try await (ps, cs)
            projects = loadedProjects
            chats = loadedChats
            state = .ready
        } catch {
            state = .offline(error.localizedDescription)
        }
    }
}

/// Wide 96pt tile like MacParakeet's "Enable meeting recording": round tinted icon, bold title
/// with a grey line, outline capsule button on the right.
private struct HomeActionTile: View {
    @Environment(\.palette) private var p
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let buttonTitle: String
    let buttonSymbol: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(Circle().fill(tint.opacity(0.15)))
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.Font.section)
                    .foregroundStyle(p.text)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(p.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: DS.Spacing.md)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: buttonSymbol).font(.system(size: 11, weight: .semibold))
                    Text(buttonTitle)
                }
            }
            .buttonStyle(OutlineButtonStyle(tint: tint))
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

private struct HomeChatRow: View {
    @Environment(\.palette) private var p
    let chat: HubChat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(DS.Font.body)
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Text(chat.projectName ?? "No project yet")
                        .font(DS.Font.caption)
                        .foregroundStyle(p.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(HubDate.format(chat.when))
                    .font(DS.Font.timestamp)
                    .foregroundStyle(p.textMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? p.accent : p.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .fill(hovering ? p.surfaceRaised.opacity(0.6) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
        .help("Open in the hub")
    }
}
