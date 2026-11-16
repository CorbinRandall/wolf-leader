import SwiftUI

/// The sidebar's project list: open projects only, the ones you used last on top, each with one
/// line saying where it is. Each project can be expanded to show its recent chats.
struct SidebarProjectFolders: View {
    @ObservedObject var model: ProjectsModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var p
    @ObservedObject private var chats = ChatStore.shared
    @AppStorage("wl.sidebar.projectOrder") private var savedOrder: String = ""
    @AppStorage("wl.sidebar.projectOrderSavedAt") private var savedOrderAt: Double = 0
    @AppStorage("wl.sidebar.showAllProjects") private var showAll = false
    /// Projects start open; this holds the ones you closed.
    @State private var collapsed: Set<Int> = []

    /// How many projects show before "more".
    private static let short = 7

    private var activeEntries: [ProjectEntry] {
        model.entries
            .filter { model.status(of: $0) != "done" }
            .sorted { ProjectPulse.lastUsed($0, chats: chats) > ProjectPulse.lastUsed($1, chats: chats) }
    }

    private var orderedEntries: [ProjectEntry] {
        let ids = savedOrder.split(separator: ",").compactMap { Int($0) }
        guard !ids.isEmpty else { return activeEntries }
        var byID: [Int: ProjectEntry] = [:]
        for entry in activeEntries { byID[entry.id] = entry }
        // Anything new, or used since the list was last arranged by hand, goes on top (newest
        // first). The hand-arranged order holds for everything else.
        let savedAt = Date(timeIntervalSince1970: savedOrderAt)
        let placed = Set(ids)
        let fresh = activeEntries.filter {
            !placed.contains($0.id) || ProjectPulse.lastUsed($0, chats: chats) > savedAt
        }
        let freshIDs = Set(fresh.map(\.id))
        return fresh + ids.compactMap { byID[$0] }.filter { !freshIDs.contains($0.id) }
    }

    /// The short list, plus anything further down that is busy or open right now.
    private var shownEntries: [ProjectEntry] {
        let all = orderedEntries
        guard !showAll, all.count > Self.short else { return all }
        return all.enumerated().filter { index, entry in
            index < Self.short || nav.route.projectID == entry.id
                || ProjectPulse.state(projectID: entry.id, chats: chats) != .idle
        }.map(\.element)
    }

    var body: some View {
        let shown = shownEntries
        ForEach(shown) { entry in
            projectGroup(for: entry)
        }
        .onMove(perform: showAll ? move : nil)
        .onAppear { autoExpand() }
        .onChange(of: nav.openChatIDs) { _, _ in autoExpand() }
        let hidden = orderedEntries.count - shown.count
        if hidden > 0 || (showAll && orderedEntries.count > Self.short) {
            Button(showAll ? "Show fewer" : "\(hidden) more") { showAll.toggle() }
                .buttonStyle(.plain).font(DS.Font.caption).foregroundStyle(p.textMuted)
                .selectionDisabled()
        }
    }

    private func projectGroup(for entry: ProjectEntry) -> some View {
        let projectChats = chats.chats(projectID: entry.id)
        if projectChats.isEmpty {
            return AnyView(row(for: entry).tag(SidebarItem.project(entry.id)))
        }
        let isExpanded = Binding<Bool>(
            get: { !collapsed.contains(entry.id) },
            set: { v in if v { collapsed.remove(entry.id) } else { collapsed.insert(entry.id) } }
        )
        return AnyView(
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(projectChats.prefix(4)) { chat in
                    Label(chat.title, systemImage: chat.agent?.symbol ?? "bubble.left")
                        .font(DS.Font.micro)
                        .lineLimit(1)
                        .tag(SidebarItem.chat(chat.id))
                }
            } label: {
                row(for: entry)
            }
            .tag(SidebarItem.project(entry.id))
        )
    }

    private func row(for entry: ProjectEntry) -> some View {
        let state = ProjectPulse.state(projectID: entry.id, chats: chats)
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(ProjectPulse.line(for: entry, chats: chats))
                    .font(DS.Font.micro)
                    .foregroundStyle(state == .idle ? p.textFaint : p.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch state {
            case .needsYou: Circle().fill(p.accent2).frame(width: 7, height: 7).help("Waiting for your OK")
            case .working: ProgressView().controlSize(.mini).help("Working")
            case .idle: EmptyView()
            }
        }
        .padding(.vertical, 1)
        .help(entry.name)
        .contextMenu { menu(for: entry) }
    }

    @ViewBuilder
    private func menu(for entry: ProjectEntry) -> some View {
        let entries = orderedEntries
        let index = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
        Button("Continue") { ProjectPulse.resume(entry, nav: nav, chats: chats) }
        Button("Fresh chat") { nav.newChat(project: ProjectRef(entry.project)) }
        Divider()
        Button("Move to top") { reorder(entry.id, to: 0) }.disabled(index == 0)
        Button("Move up") { reorder(entry.id, to: index - 1) }.disabled(index == 0)
        Button("Move down") { reorder(entry.id, to: index + 1) }.disabled(index == entries.count - 1)
        Button("Move to bottom") { reorder(entry.id, to: entries.count - 1) }.disabled(index == entries.count - 1)
        Divider()
        Button("Sort by recent use") { savedOrder = "" }
    }

    private func autoExpand() {
        for entry in orderedEntries {
            let projectChats = chats.chats(projectID: entry.id)
            if projectChats.contains(where: { nav.openChatIDs.contains($0.id) }) {
                collapsed.remove(entry.id)
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var entries = orderedEntries
        entries.move(fromOffsets: source, toOffset: destination)
        saveOrder(entries)
    }

    private func saveOrder(_ entries: [ProjectEntry]) {
        savedOrder = entries.map { String($0.id) }.joined(separator: ",")
        savedOrderAt = Date().timeIntervalSince1970
    }

    private func reorder(_ id: Int, to target: Int) {
        var entries = orderedEntries
        guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
        let item = entries.remove(at: from)
        entries.insert(item, at: max(0, min(target, entries.count)))
        saveOrder(entries)
    }
}
