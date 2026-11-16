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
    @State private var cachedGroups: [ChatGroup] = []

    private static let groupPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .cyan, .indigo]

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                let columnHeight = max(0, geo.size.height - 20)
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(cachedGroups) { group in
                            groupColumns(group, isFirstGroup: group.id == cachedGroups.first?.id, height: columnHeight)
                        }
                        if nav.openChatIDs.isEmpty && !nav.showingNewChatPanel {
                            emptyDeck(height: columnHeight).id("empty-deck")
                        } else {
                            addSlot(height: columnHeight).id("add")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 10)
                    .frame(height: columnHeight)
                }
                .onChange(of: nav.openChatIDs) { old, new in
                    cachedGroups = buildGroups()
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
                .onAppear { cachedGroups = buildGroups() }
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

    private func buildGroups() -> [ChatGroup] {
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
    private func groupColumns(_ group: ChatGroup, isFirstGroup: Bool, height: CGFloat) -> some View {
        if group.projectID == nil {
            ForEach(group.chatIDs, id: \.self) { id in
                chatColumn(id: id, height: height).id(id)
            }
        } else if collapsedGroups.contains(group.id) {
            collapsedGroupColumn(group, height: height)
        } else {
            ForEach(Array(group.chatIDs.enumerated()), id: \.element) { index, id in
                groupedChatColumn(id: id, group: group, isFirstInGroup: index == 0, height: height).id(id)
            }
        }
    }

    // A chat column inside a project group — has a colored header strip on top and a rounded colored outline.
    @ViewBuilder
    private func groupedChatColumn(id: String, group: ChatGroup, isFirstInGroup: Bool, height: CGFloat) -> some View {
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
                        .background(c.opacity(0.12))
                    }
                    .buttonStyle(.plain)
                    .help("Collapse \(group.projectName ?? "group")")
                } else {
                    c.opacity(0.07).frame(height: groupHeaderHeight)
                }
                ChatView(session: session, back: { nav.close(chatID: id) })
                    .frame(width: colWidth, height: height - groupHeaderHeight)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.opacity(0.45), lineWidth: 1.5))
        }
    }

    // A collapsed group: one narrow column, project name rotated vertically.
    private func collapsedGroupColumn(_ group: ChatGroup, height: CGFloat) -> some View {
        let c = color(for: group)
        return VStack(spacing: 0) {
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
                .background(c.opacity(0.12))
            }
            .buttonStyle(.plain)
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
        .frame(width: collapsedWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.opacity(0.45), lineWidth: 1.5))
    }

    // A plain (no-project) column — subtle neutral outline.
    @ViewBuilder
    private func chatColumn(id: String, height: CGFloat) -> some View {
        if let session = chats.session(id) {
            ChatView(session: session, back: { nav.close(chatID: id) })
                .frame(width: colWidth, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        }
    }

    // MARK: Add slot

    @ViewBuilder
    private func addSlot(height: CGFloat) -> some View {
        let hasChats = !nav.openChatIDs.isEmpty
        let expanded = nav.showingNewChatPanel
        HStack(spacing: 0) {
            if hasChats { Rectangle().fill(p.border).frame(width: 1) }
            if expanded {
                ZStack(alignment: .topTrailing) {
                    ChatHome(projectsModel: projectsModel)
                        .frame(width: colWidth, height: height)
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
                addButton(height: height)
            }
        }
    }

    private func addButton(height: CGFloat) -> some View {
        let firstColumn = nav.openChatIDs.count == 1
        return Button { nav.newChat() } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(p.border, lineWidth: 1.5).frame(width: 40, height: 40)
                    Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(p.textMuted)
                }
                Text(firstColumn ? "Add column" : "New chat")
                    .font(DS.Font.caption.weight(firstColumn ? .semibold : .regular))
                    .foregroundStyle(firstColumn ? p.accent : p.textMuted)
                if firstColumn {
                    Text("beside this chat")
                        .font(DS.Font.micro).foregroundStyle(p.textFaint)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 100)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(firstColumn ? "Add another chat beside this column" : "New chat (⌘N)")
    }

    private func emptyDeck(height: CGFloat) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 7) {
                Text("Your chats, side by side")
                    .font(DS.Font.page).foregroundStyle(p.text)
                Text("Each chat gets its own column. Start one now, then open more beside it.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            HStack(alignment: .top, spacing: 10) {
                previewColumn(title: "Chat 1", symbol: "bubble.left", active: true)
                previewColumn(title: "Chat 2", symbol: "plus", active: false)
                previewColumn(title: "Chat 3", symbol: "plus", active: false)
            }
            Button { nav.newChat() } label: {
                Label("New chat", systemImage: "plus.bubble")
                    .font(DS.Font.bodySmall.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .foregroundStyle(p.onAccent)
                    .background(p.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(width: colWidth, height: height)
        .background(p.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private func previewColumn(title: String, symbol: String, active: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(DS.Font.micro.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? p.accent : p.textFaint)
            .padding(.horizontal, 9).frame(height: 28)
            Rectangle().fill(p.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(active ? p.accent.opacity(0.22) : p.border.opacity(0.7)).frame(width: 68, height: 6)
                RoundedRectangle(cornerRadius: 4).fill(p.border.opacity(0.55)).frame(height: 5)
                RoundedRectangle(cornerRadius: 4).fill(p.border.opacity(0.55)).frame(width: 58, height: 5)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 7).fill(p.surface).frame(height: 32)
            }
            .padding(9)
        }
        .frame(width: 112, height: 132)
        .background(p.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(active ? p.accent.opacity(0.55) : p.border, lineWidth: active ? 1.5 : 1))
    }
}
