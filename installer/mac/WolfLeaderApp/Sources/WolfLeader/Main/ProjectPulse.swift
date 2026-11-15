import SwiftUI

/// A project at a glance: is an agent working in it, does it need you, or where did it stop.
/// The sidebar, the home page and a project's own page all read this, so they always agree.
@MainActor
enum ProjectPulse {
    enum State: Equatable {
        case needsYou, working, idle
    }

    static func state(projectID: Int, chats: ChatStore) -> State {
        let mine = chats.chats(projectID: projectID).filter { chats.isRunning($0.id) }
        if mine.contains(where: { chat in chat.items.contains { $0.kind == .approval && $0.status == .pending } }) {
            return .needsYou
        }
        return mine.isEmpty ? .idle : .working
    }

    /// One short line under a project's name.
    static func line(for entry: ProjectEntry, chats: ChatStore) -> String {
        switch state(projectID: entry.id, chats: chats) {
        case .needsYou: return "Needs your OK"
        case .working: return "Working…"
        case .idle:
            if let next = entry.progress?.nextStep?.text, !next.isEmpty { return "Next: " + AgentText.oneLine(next, limit: 80) }
            let stands = AgentText.oneLine(entry.whereItStands, limit: 80)
            if !stands.isEmpty { return stands }
            if let last = HubDate.parse(entry.lastWorked) { return "Last worked " + HubDate.format(last) }
            return "Not started"
        }
    }

    /// The chat "Continue" opens: the one most recently used in this project, if there is one.
    static func latestChat(projectID: Int, chats: ChatStore) -> ChatRecord? {
        chats.chats(projectID: projectID).max { $0.updated < $1.updated }
    }

    /// When the project was last used: its newest chat here, or the hub's last session.
    static func lastUsed(_ entry: ProjectEntry, chats: ChatStore) -> Date {
        let chat = latestChat(projectID: entry.id, chats: chats)?.updated ?? .distantPast
        return max(chat, HubDate.parse(entry.lastWorked) ?? .distantPast)
    }

    /// Pick the project back up: its latest conversation, or a new one when it has none.
    static func resume(_ entry: ProjectEntry, nav: Navigator, chats: ChatStore) {
        if let chat = latestChat(projectID: entry.id, chats: chats) {
            nav.open(chat: chat.id, project: entry.id)
        } else {
            nav.newChat(project: ProjectRef(entry.project))
        }
    }
}

/// Top of a project's page: where it stands, what's next, and one button to carry on.
struct ContinueCard: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var chats = ChatStore.shared
    let entry: ProjectEntry
    /// The newest saved session, when the page has loaded it.
    var lastSession: HubLogEntry?

    private var latest: ChatRecord? { ProjectPulse.latestChat(projectID: entry.id, chats: chats) }

    var body: some View {
        let state = ProjectPulse.state(projectID: entry.id, chats: chats)
        Tile {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack(spacing: 8) {
                    WLEyebrow("Where you left off", color: p.accent)
                    if state == .needsYou { WLStatusPill(text: "Needs your OK", kind: .warn) }
                    if state == .working { WLStatusPill(text: "Working", kind: .warn) }
                    Spacer(minLength: 0)
                    if let last = HubDate.parse(entry.lastWorked) {
                        Text(HubDate.format(last)).font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                    }
                }
                Text(entry.whereItStands.isEmpty ? "Nothing saved yet. Start a chat and Wolf Leader keeps track from here."
                     : entry.whereItStands.replacingOccurrences(of: "**", with: ""))
                    .font(DS.Font.body).foregroundStyle(p.text).textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastSession, !lastSession.summary.isEmpty, lastSession.summary != entry.whereItStands {
                    VStack(alignment: .leading, spacing: 3) {
                        WLEyebrow("Last session", color: p.textMuted)
                        Text(lastSession.summary).font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                            .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let next = entry.progress?.nextStep {
                    VStack(alignment: .leading, spacing: 3) {
                        WLEyebrow("Next step", color: p.accent)
                        Text(next.text).font(DS.Font.bodySmall.weight(.medium)).foregroundStyle(p.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if !next.doneWhen.isEmpty {
                            Text("Done when: \(next.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button { ProjectPulse.resume(entry, nav: nav, chats: chats) } label: {
                        Label(latest == nil ? "Start" : "Continue", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help(latest.map { "Opens \u{201C}\($0.title)\u{201D}" } ?? "Starts this project's first chat")
                    if latest != nil {
                        Button { nav.newChat(project: ProjectRef(entry.project)) } label: {
                            Label("Fresh chat", systemImage: "plus.bubble")
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .help("Starts a new chat with this project's notes")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Home page: the projects you used most recently, each one click from carrying on.
struct PickUpStrip: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigator
    @ObservedObject var model: ProjectsModel
    @ObservedObject private var chats = ChatStore.shared

    private var recent: [ProjectEntry] {
        model.entries
            .filter { model.status(of: $0) != "done" && ProjectPulse.lastUsed($0, chats: chats) > .distantPast }
            .sorted { ProjectPulse.lastUsed($0, chats: chats) > ProjectPulse.lastUsed($1, chats: chats) }
            .prefix(3).map { $0 }
    }

    var body: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WLEyebrow("Pick up where you left off", color: p.textMuted)
                ForEach(recent) { entry in
                    HStack(spacing: 10) {
                        Button { nav.open(project: entry.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                                Text(ProjectPulse.line(for: entry, chats: chats))
                                    .font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(entry.name)")
                        Text(HubDate.format(ProjectPulse.lastUsed(entry, chats: chats)))
                            .font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                        Button("Continue") { ProjectPulse.resume(entry, nav: nav, chats: chats) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
