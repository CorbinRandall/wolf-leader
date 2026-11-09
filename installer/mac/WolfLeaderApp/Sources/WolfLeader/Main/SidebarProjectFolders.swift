import SwiftUI

struct SidebarProjectFolders: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: ProjectsModel
    @EnvironmentObject var nav: Navigator
    @ObservedObject private var chats = ChatStore.shared
    @ObservedObject private var drafts = Drafts.shared
    @AppStorage("wl.sidebar.projectOrder") private var savedOrder: String = ""

    private var activeEntries: [ProjectEntry] {
        model.entries.filter { model.status(of: $0) != "done" }
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

    var body: some View {
        ForEach(orderedEntries) { entry in
            row(for: entry)
        }
        .onMove(perform: move)
    }

    @ViewBuilder
    private func row(for entry: ProjectEntry) -> some View {
        let active = activeChats(for: entry)
        if active.isEmpty {
            Label { Text(entry.name) } icon: { Image(systemName: "folder").foregroundStyle(p.accent) }
                .tag(SidebarItem.project(entry.id))
                .onTapGesture { nav.open(project: entry.id) }
                .contextMenu { menu(for: entry) }
        } else {
            DisclosureGroup {
                ForEach(active) { chat in
                    Label(chat.title, systemImage: chat.agent?.symbol ?? "bubble.left")
                        .onTapGesture { nav.open(chat: chat.id, project: entry.id) }
                }
            } label: {
                Label { Text(entry.name) } icon: { Image(systemName: "folder").foregroundStyle(p.accent) }
                    .onTapGesture { nav.open(project: entry.id) }
            }
            .contextMenu { menu(for: entry) }
        }
    }

    @ViewBuilder
    private func menu(for entry: ProjectEntry) -> some View {
        let entries = orderedEntries
        let index = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
        Button("Move to top") { reorder(entry.id, to: 0) }.disabled(index == 0)
        Button("Move up") { reorder(entry.id, to: index - 1) }.disabled(index == 0)
        Button("Move down") { reorder(entry.id, to: index + 1) }.disabled(index == entries.count - 1)
        Button("Move to bottom") { reorder(entry.id, to: entries.count - 1) }.disabled(index == entries.count - 1)
        Divider()
        Button("Sort by recent use") { savedOrder = "" }
    }

    private func activeChats(for entry: ProjectEntry) -> [ChatRecord] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return chats.chats(projectID: entry.id).filter {
            $0.updated > cutoff || nav.route.chatID == $0.id || !drafts[$0.id].isEmpty
        }
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
