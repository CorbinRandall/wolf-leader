import SwiftUI

/// The sidebar's project list: open projects only, the ones you used last on top, each with one
/// line saying where it is. Chats aren't listed here; a project's page is where you carry on.
struct SidebarProjectFolders: View {
    @ObservedObject var model: ProjectsModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.palette) private var p
    @ObservedObject private var chats = ChatStore.shared
    @AppStorage("wl.sidebar.projectOrder") private var savedOrder: String = ""
    @AppStorage("wl.sidebar.showAllProjects") private var showAll = false

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
        var result = ids.compactMap { byID[$0] }
        let placed = Set(ids)
        result += activeEntries.filter { !placed.contains($0.id) }
        return result
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
            row(for: entry)
        }
        .onMove(perform: showAll ? move : nil)
        let hidden = orderedEntries.count - shown.count
        if hidden > 0 || (showAll && orderedEntries.count > Self.short) {
            Button(showAll ? "Show fewer" : "\(hidden) more") { showAll.toggle() }
                .buttonStyle(.plain).font(DS.Font.caption).foregroundStyle(p.textMuted)
                .selectionDisabled()
        }
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
        .tag(SidebarItem.project(entry.id))
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

    private func move(from source: IndexSet, to destination: Int) {
        var entries = orderedEntries
        entries.move(fromOffsets: source, toOffset: destination)
        savedOrder = entries.map { String($0.id) }.joined(separator: ",")
    }

    private func reorder(_ id: Int, to target: Int) {
        var entries = orderedEntries
        guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
        let item = entries.remove(at: from)
        entries.insert(item, at: max(0, min(target, entries.count)))
        savedOrder = entries.map { String($0.id) }.joined(separator: ",")
    }
}
