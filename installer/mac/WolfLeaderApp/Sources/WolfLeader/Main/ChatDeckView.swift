import AppKit
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
                        ForEach(nav.draftColumns, id: \.self) { id in
                            draftColumn(id, height: columnHeight).id(id)
                        }
                        addButton(height: columnHeight).id("add")
                    }
                    .frame(height: columnHeight)
                    .padding(.horizontal, 10).padding(.vertical, 10)
                    // Exactly the window's height, so the deck only ever scrolls sideways.
                    .frame(height: geo.size.height)
                    .background(HorizontalOnlyScroll().frame(width: 0, height: 0))
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .onChange(of: nav.openChatIDs) { old, new in
                    cachedGroups = buildGroups()
                    guard let last = new.last, !old.contains(last) else { return }
                    // Auto-expand the group if the new chat lands in a collapsed one.
                    if let pid = chats.record(last)?.projectID {
                        withAnimation(.easeOut(duration: 0.2)) { collapsedGroups.subtract(["proj-\(pid)"]) }
                    }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .leading) }
                }
                .onChange(of: nav.draftColumns) { old, new in
                    guard new.count > old.count else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("add", anchor: .trailing) }
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

    // MARK: Draft columns and "+"

    /// An empty composer column. Sending turns it into a real chat in the same spot.
    private func draftColumn(_ id: UUID, height: CGFloat) -> some View {
        let closable = nav.draftColumns.count > 1 || !nav.openChatIDs.isEmpty
        return ZStack(alignment: .topTrailing) {
            ChatHome(projectsModel: projectsModel,
                     draftKey: Navigator.draftKey(id),
                     takesPending: id == nav.draftColumns.last,
                     onStarted: { nav.closeDraftColumn(id) })
                .frame(width: colWidth, height: height)
            if closable {
                Button { nav.closeDraftColumn(id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(p.textMuted)
                        .padding(14)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }

    /// A thin line with a "+" that adds another empty column.
    private func addButton(height: CGFloat) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(p.border).frame(width: 1, height: height)
            Button { nav.addDraftColumn() } label: {
                ZStack {
                    Circle().strokeBorder(p.border, lineWidth: 1.5).frame(width: 32, height: 32)
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(p.textMuted)
                }
                .frame(width: 40, height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a column")
        }
    }
}

/// Pins the deck's scroll area so it only ever moves sideways. Placed inside the deck's content,
/// it finds the scroll view around it, turns off up/down scrolling and the toolbar inset, and
/// snaps it back to the top if anything (a text box keeping its cursor in view, a "scroll to
/// latest") tries to move it vertically.
struct HorizontalOnlyScroll: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?
        private weak var pinned: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        private func pin() {
            guard let scroll = enclosingScrollView, scroll !== pinned else { return }
            pinned = scroll
            scroll.hasVerticalScroller = false
            scroll.verticalScrollElasticity = .none
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets()
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak clip, weak scroll] _ in
                guard let clip, let scroll else { return }
                let top: CGFloat = (scroll.documentView?.isFlipped ?? true)
                    ? 0 : max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                if abs(clip.bounds.origin.y - top) > 0.5 {
                    clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: top))
                    scroll.reflectScrolledClipView(clip)
                }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}
