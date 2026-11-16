import SwiftUI

/// The deck: open chats as fixed-width columns, grouped by project (Chrome-style tab groups).
/// Each project gets a colored header bar spanning its columns. Groups collapse to a narrow
/// column showing the project name. The add slot lives at the right edge.
struct ChatDeckView: View {
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @ObservedObject private var chats = ChatStore.shared
    var projectsModel: ProjectsModel

    private let colWidth: CGFloat = 480
    private let collapsedWidth: CGFloat = 68
    private let groupHeaderHeight: CGFloat = 26

    @State private var collapsedGroups: Set<String> = []

    private static let groupPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .cyan, .indigo]

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 0) {
                        let gs = chatGroups
                        ForEach(gs) { group in
                            groupColumns(group, isFirstGroup: group.id == gs.first?.id)
                        }
                        addSlot.id("add")
                    }
                    .frame(minHeight: geo.size.height)
                }
                .onChange(of: nav.openChatIDs) { old, new in
                    guard let last = new.last, !old.contains(last) else { return }
                    // Auto-expand the group if the new chat lands in a collapsed one.
                    if let pid = chats.record(last)?.projectID {
                        withAnimation(.easeOut(duration: 0.2)) { collapsedGroups.subtract(["proj-\(pid)"]) }
                    }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .leading) }
                }
                .onChange(of: nav.showingNewChatPanel) { _, showing in
                    if showing {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("add", anchor: .trailing) }
                    }
                }
            }
        }
    }

    // MARK: Groups

    struct ChatGroup: Identifiable {
        let id: String
        let projectID: Int?
        let projectName: String?
        var chatIDs: [String]
        let colorIndex: Int
    }

    private var chatGroups: [ChatGroup] {
        var result: [ChatGroup] = []
        var colorCounter = 0
        for id in nav.openChatIDs {
            let record = chats.record(id)
            let pid = record?.projectID
            let gid = pid.map { "proj-\($0)" } ?? "none"
            if let idx = result.firstIndex(where: { $0.id == gid }) {
                result[idx].chatIDs.append(id)
            } else {
                let ci = pid != nil ? colorCounter : -1
                if pid != nil { colorCounter += 1 }
                result.append(ChatGroup(id: gid, projectID: pid,
                                        projectName: record?.projectName,
                                        chatIDs: [id], colorIndex: ci))
            }
        }
        return result
    }

    private func color(for group: ChatGroup) -> Color {
        guard group.colorIndex >= 0 else { return p.accent }
        return Self.groupPalette[group.colorIndex % Self.groupPalette.count]
    }

    // MARK: Group rendering

    @ViewBuilder
    private func groupColumns(_ group: ChatGroup, isFirstGroup: Bool) -> some View {
        if group.projectID == nil {
            // No-project chats: flat columns, no group chrome.
            ForEach(Array(group.chatIDs.enumerated()), id: \.element) { index, id in
                chatColumn(id: id, leftBorder: !(isFirstGroup && index == 0)).id(id)
            }
        } else if collapsedGroups.contains(group.id) {
            collapsedGroupColumn(group, leftBorder: !isFirstGroup)
        } else {
            ForEach(Array(group.chatIDs.enumerated()), id: \.element) { index, id in
                let isFirstInGroup = index == 0
                groupedChatColumn(id: id, group: group,
                                   isFirstInGroup: isFirstInGroup,
                                   leftBorder: !(isFirstGroup && isFirstInGroup))
                    .id(id)
            }
        }
    }

    // A chat column inside a project group — has a colored header strip on top.
    @ViewBuilder
    private func groupedChatColumn(id: String, group: ChatGroup, isFirstInGroup: Bool, leftBorder: Bool) -> some View {
        if let session = chats.session(id) {
            let c = color(for: group)
            VStack(spacing: 0) {
                // Header: label + collapse button on first column; plain color bar on rest.
                if isFirstInGroup {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { collapsedGroups.formUnion([group.id]) }
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(c).frame(width: 7, height: 7)
                            Text(group.projectName ?? "Project")
                                .font(DS.Font.micro.weight(.semibold))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            if group.chatIDs.count > 1 {
                                Text("\(group.chatIDs.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(c)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(c.opacity(0.15)))
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.textMuted)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: groupHeaderHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(c.opacity(0.1))
                        .overlay(Rectangle().fill(c).frame(height: 2), alignment: .top)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse \(group.projectName ?? "group")")
                } else {
                    // Continuation bar: same height, same tint, no label.
                    c.opacity(0.07)
                        .frame(height: groupHeaderHeight)
                        .overlay(Rectangle().fill(c).frame(height: 2), alignment: .top)
                }
                // The chat itself.
                HStack(spacing: 0) {
                    if leftBorder { Rectangle().fill(p.border).frame(width: 1) }
                    ChatView(session: session, back: { nav.close(chatID: id) })
                        .frame(width: colWidth)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // A collapsed group: one narrow column, project name rotated vertically.
    private func collapsedGroupColumn(_ group: ChatGroup, leftBorder: Bool) -> some View {
        let c = color(for: group)
        return HStack(spacing: 0) {
            if leftBorder { Rectangle().fill(p.border).frame(width: 1) }
            VStack(spacing: 0) {
                // Header strip with expand chevron.
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { collapsedGroups.subtract([group.id]) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(c).frame(width: 7, height: 7)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(p.textMuted)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: groupHeaderHeight)
                    .frame(maxWidth: .infinity)
                    .background(c.opacity(0.1))
                    .overlay(Rectangle().fill(c).frame(height: 2), alignment: .top)
                }
                .buttonStyle(.plain)
                // Body: rotated project name + chat count.
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { collapsedGroups.subtract([group.id]) }
                } label: {
                    VStack(spacing: 12) {
                        Text(group.projectName ?? "Project")
                            .font(DS.Font.bodySmall.weight(.medium))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                            .rotationEffect(.degrees(-90))
                            .fixedSize()
                        Text("\(group.chatIDs.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(c)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(c.opacity(0.15)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Expand \(group.projectName ?? "group")")
            }
            .frame(width: collapsedWidth - (leftBorder ? 1 : 0))
        }
    }

    // A plain column (no-project chat, or first column of first group before any project chrome).
    @ViewBuilder
    private func chatColumn(id: String, leftBorder: Bool) -> some View {
        if let session = chats.session(id) {
            HStack(spacing: 0) {
                if leftBorder { Rectangle().fill(p.border).frame(width: 1) }
                ChatView(session: session, back: { nav.close(chatID: id) })
                    .frame(width: colWidth)
            }
        }
    }

    // MARK: Add slot

    @ViewBuilder
    private var addSlot: some View {
        let hasChats = !nav.openChatIDs.isEmpty
        let expanded = !hasChats || nav.showingNewChatPanel
        HStack(spacing: 0) {
            if hasChats { Rectangle().fill(p.border).frame(width: 1) }
            if expanded {
                ZStack(alignment: .topTrailing) {
                    ChatHome(projectsModel: projectsModel)
                        .frame(width: colWidth)
                    if hasChats {
                        Button { nav.showingNewChatPanel = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(p.textMuted)
                                .padding(14)
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                    }
                }
            } else {
                addButton
            }
        }
    }

    private var addButton: some View {
        Button { nav.showingNewChatPanel = true } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(p.border, lineWidth: 1.5).frame(width: 40, height: 40)
                    Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(p.textMuted)
                }
                Text("New chat").font(DS.Font.caption).foregroundStyle(p.textMuted)
            }
            .frame(width: 100)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New chat (⌘N)")
    }
}
