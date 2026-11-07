import SwiftUI

/// One thing the sidebar can show. Each can be moved and hidden.
enum SidebarBlock: String, CaseIterable, Identifiable, Hashable {
    case newChat, search, allProjects, projects, allChats, library, shares, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newChat: return "New chat"
        case .search: return "Search"
        case .allProjects: return "All projects"
        case .projects: return "Projects"
        case .allChats: return "All chats"
        case .library: return "Library"
        case .shares: return "Shares"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .newChat: return "square.and.pencil"
        case .search: return MainSection.ask.symbol
        case .allProjects: return "square.grid.2x2"
        case .projects: return "folder"
        case .allChats: return "list.bullet"
        case .library: return MainSection.library.symbol
        case .shares: return MainSection.shares.symbol
        case .settings: return MainSection.settings.symbol
        }
    }

    /// What it is, for the Settings list.
    var detail: String {
        switch self {
        case .projects: return "Your project folders, with chats in progress inside"
        case .library: return "Skills, People, Bring in and the rest"
        case .allChats: return "Every chat in one list"
        default: return ""
        }
    }

    /// Shown as its own block in the sidebar rather than a single row.
    var isGroup: Bool { self == .projects || self == .library }
}

/// One view inside Library.
struct LibraryEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String

    static let all: [LibraryEntry] = [
        .init(id: "skills", title: "Skills", symbol: "shippingbox"),
        .init(id: "people", title: "People", symbol: "person.2"),
        .init(id: "bringin", title: "Bring in", symbol: "tray.and.arrow.down"),
        .init(id: "tools", title: "AI tools", symbol: "person.2.wave.2"),
        .init(id: "repos", title: "Backups", symbol: "externaldrive.badge.checkmark"),
        .init(id: "cleanup", title: "Cleanup", symbol: "arrow.triangle.merge"),
        .init(id: "snippets", title: "Snippets", symbol: "chevron.left.forwardslash.chevron.right"),
    ]

    var hideKey: String { "library.\(id)" }
}

/// The order of the sidebar and what's hidden in it. Saved on this Mac.
@MainActor
final class SidebarLayout: ObservableObject {
    static let shared = SidebarLayout()

    static let defaultOrder: [SidebarBlock] = [.newChat, .search, .allProjects, .projects, .allChats, .library, .shares, .settings]
    static let defaultHidden: Set<String> = [SidebarBlock.allChats.rawValue]

    private static let orderKey = "wl.sidebar.order"
    private static let hiddenKey = "wl.sidebar.hidden"

    @Published private(set) var order: [SidebarBlock]
    @Published private(set) var hidden: Set<String>

    private init() {
        let defaults = UserDefaults.standard
        var saved = (defaults.string(forKey: Self.orderKey) ?? "").split(separator: ",").compactMap { SidebarBlock(rawValue: String($0)) }
        // Anything added in a newer version goes where it sits by default.
        for (index, block) in Self.defaultOrder.enumerated() where !saved.contains(block) {
            saved.insert(block, at: min(index, saved.count))
        }
        order = saved
        if let raw = defaults.string(forKey: Self.hiddenKey) {
            hidden = Set(raw.split(separator: ",").map(String.init))
        } else {
            hidden = Self.defaultHidden
        }
    }

    var visible: [SidebarBlock] { order.filter { !isHidden($0) } }
    var hiddenCount: Int { hidden.count }

    /// Runs of plain rows share one sidebar section; Projects and Library get their own.
    var groups: [[SidebarBlock]] {
        var result: [[SidebarBlock]] = []
        for block in visible {
            if block.isGroup || result.last?.first?.isGroup ?? true {
                result.append([block])
            } else {
                result[result.count - 1].append(block)
            }
        }
        return result
    }

    func isHidden(_ block: SidebarBlock) -> Bool { hidden.contains(block.rawValue) }
    func isHidden(_ entry: LibraryEntry) -> Bool { hidden.contains(entry.hideKey) }

    func setHidden(_ block: SidebarBlock, _ hide: Bool) { setHidden(key: block.rawValue, hide) }
    func setHidden(_ entry: LibraryEntry, _ hide: Bool) { setHidden(key: entry.hideKey, hide) }

    private func setHidden(key: String, _ hide: Bool) {
        if hide { hidden.insert(key) } else { hidden.remove(key) }
        save()
    }

    func showEverything() {
        hidden = []
        save()
    }

    func reset() {
        order = Self.defaultOrder
        hidden = Self.defaultHidden
        save()
    }

    /// Dragged onto another item: it takes that item's place.
    func move(_ block: SidebarBlock, onto target: SidebarBlock) {
        guard block != target, let from = order.firstIndex(of: block), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(block, at: to)
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    enum Step { case top, up, down, bottom }

    func move(_ block: SidebarBlock, _ step: Step) {
        // Up and down step over hidden items, so each press visibly moves it.
        let shown = visible
        guard let at = shown.firstIndex(of: block) else { return }
        let target: SidebarBlock?
        switch step {
        case .top: target = shown.first
        case .bottom: target = shown.last
        case .up: target = at > 0 ? shown[at - 1] : nil
        case .down: target = at < shown.count - 1 ? shown[at + 1] : nil
        }
        if let target { move(block, onto: target) }
    }

    func canMove(_ block: SidebarBlock, _ step: Step) -> Bool {
        let shown = visible
        guard let at = shown.firstIndex(of: block) else { return false }
        switch step {
        case .top, .up: return at > 0
        case .down, .bottom: return at < shown.count - 1
        }
    }

    private func save() {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: Self.orderKey)
        UserDefaults.standard.set(hidden.sorted().joined(separator: ","), forKey: Self.hiddenKey)
    }
}

// MARK: - Sidebar pieces

/// Right-click menu for a sidebar item: move it, hide it, or customize the whole sidebar.
struct SidebarBlockMenu: View {
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var layout = SidebarLayout.shared
    let block: SidebarBlock

    var body: some View {
        Button("Move to Top") { layout.move(block, .top) }.disabled(!layout.canMove(block, .top))
        Button("Move Up") { layout.move(block, .up) }.disabled(!layout.canMove(block, .up))
        Button("Move Down") { layout.move(block, .down) }.disabled(!layout.canMove(block, .down))
        Button("Move to Bottom") { layout.move(block, .bottom) }.disabled(!layout.canMove(block, .bottom))
        Divider()
        Button("Hide \(block.title)") { layout.setHidden(block, true) }
        Divider()
        Button("Customize Sidebar…") { nav.open(settingsTab: "sidebar") }
    }
}

extension View {
    /// Drag this item onto another to swap places; right-click to move or hide it.
    func sidebarBlock(_ block: SidebarBlock) -> some View {
        self
            .draggable(SidebarDrag(block: block.rawValue))
            .dropDestination(for: SidebarDrag.self) { items, _ in
                guard let raw = items.first?.block, let moved = SidebarBlock(rawValue: raw) else { return false }
                withAnimation { SidebarLayout.shared.move(moved, onto: block) }
                return true
            }
            .contextMenu { SidebarBlockMenu(block: block) }
    }
}

/// What's carried while dragging a sidebar item (its own type, so dropped text is ignored).
struct SidebarDrag: Codable, Transferable {
    let block: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// MARK: - Settings > Sidebar

/// Everything the sidebar can show: drag to reorder, switch off to hide, and bring back anything hidden.
struct SidebarSettingsGroup: View {
    @Environment(\.palette) private var p
    @ObservedObject private var layout = SidebarLayout.shared

    var body: some View {
        WLGroup(title: "Sidebar", subtitle: "Drag to reorder. Switch something off to hide it. You can also drag and right-click items in the sidebar itself.",
                icon: "sidebar.left") {
            List {
                ForEach(layout.order) { block in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(p.textFaint)
                        Label(block.title, systemImage: block.symbol)
                            .foregroundStyle(layout.isHidden(block) ? p.textFaint : p.text)
                        if !block.detail.isEmpty {
                            Text(block.detail).font(DS.Font.caption).foregroundStyle(p.textFaint).lineLimit(1)
                        }
                        Spacer()
                        Toggle("Show", isOn: Binding(get: { !layout.isHidden(block) }, set: { layout.setHidden(block, !$0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
                .onMove { layout.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .frame(height: CGFloat(layout.order.count) * 34 + 8)
        }

        WLGroup(title: "Inside Library", subtitle: "Which views show under Library in the sidebar. All of them stay in Library's own tabs.",
                icon: MainSection.library.symbol) {
            ForEach(LibraryEntry.all) { entry in
                WLRow(title: entry.title, detail: "") {
                    Toggle("Show", isOn: Binding(get: { !layout.isHidden(entry) }, set: { layout.setHidden(entry, !$0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }

        HStack {
            Button("Show everything") { layout.showEverything() }
                .disabled(layout.hiddenCount == 0)
            Button("Reset to default") { layout.reset() }
            Spacer()
        }
    }
}
