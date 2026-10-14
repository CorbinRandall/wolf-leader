import AppKit
import SwiftUI

enum ProjectsTab: String, Hashable {
    case focus, board, all
}

/// Projects answers three questions, in this order: what am I working on, what is next, and where
/// is everything else. Focus shows only the few projects in play with their next step; Board is the
/// same projects by stage; All is every project, searchable. Every view opens the same project page.
struct ProjectsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    var openSettings: () -> Void = {}
    @StateObject private var model = ProjectsModel()
    @EnvironmentObject private var nav: Navigator
    @State private var query = ""
    @State private var promptFor: ProjectEntry?
    @State private var columnEditor: ColumnEditorContext?
    @State private var showLoose = false
    @State private var starting = false
    @State private var stageFilter = "open"
    @State private var topic = ""

    // Which view and which project are part of the window's history, so back and forward work here.
    private var tab: Binding<ProjectsTab> {
        Binding(get: { ProjectsTab(rawValue: nav.route.projectsTab) ?? .focus }, set: { nav.open(projectsTab: $0.rawValue) })
    }

    private var openID: Int? {
        get { nav.route.projectID }
        nonmutating set { nav.open(project: newValue) }
    }

    private var tabs: [WLTab<ProjectsTab>] {
        [
            WLTab(id: .focus, title: "Focus", icon: "scope"),
            WLTab(id: .board, title: "Board", icon: "rectangle.3.group"),
            WLTab(id: .all, title: "All projects", icon: "list.bullet"),
        ]
    }

    private var shown: [ProjectEntry] { model.entries.filter { $0.matches(query) } }

    var body: some View {
        Group {
            if let openID, let entry = model.entry(openID) {
                ProjectPage(entry: entry, model: model, back: { nav.closeProject() }, prompt: { promptFor = $0 },
                            open: { self.openID = $0 })
                    .id(openID)
            } else {
                overview
            }
        }
        .background(p.background)
        .task(id: store.config.hubURL) { await model.load(store.hub) }
        .sheet(item: $promptFor) { entry in
            BuildPromptSheet(entry: entry, onDone: { await model.reload() })
        }
        .sheet(isPresented: $showLoose) { LooseSessionsSheet(model: model) }
        .sheet(isPresented: $starting) {
            NewProjectSheet(model: model) { id in
                Task { await model.reload(); nav.open(project: id) }
            }
        }
        .sheet(item: $columnEditor) { editor in
            KanbanColumnEditor(context: editor) { label, description in
                model.perform { hub in
                    if let status = editor.status {
                        _ = try await hub.updateKanbanColumn(status: status, label: label, description: description)
                    } else {
                        _ = try await hub.createKanbanColumn(label: label, description: description)
                    }
                }
            }
            .environment(\.palette, p)
        }
    }

    private var overview: some View {
        MainPage {
            WLPageHeader(title: "Projects", subtitle: "What you are working on, what is next, and where everything else is.") {
                HStack(spacing: 8) {
                    WLSearchField(text: $query, placeholder: "Search projects and goals").frame(width: 260)
                    Button { starting = true } label: { Label("New project", systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut("n", modifiers: .command)
                    if tab.wrappedValue == .board {
                        Button("Add column") { columnEditor = ColumnEditorContext() }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(OutlineButtonStyle()).help("Refresh")
                }
            }
            HStack {
                WLTabBar(tabs: tabs, selection: tab)
                Spacer(minLength: 0)
            }
            if let notice = model.notice { WLStatusPill(text: notice, kind: .good) }
            if let error = model.error { WLStatusPill(text: error, kind: .bad) }
            if model.loading && model.entries.isEmpty {
                ProgressView("Reading the journal…")
            } else if model.entries.isEmpty, model.error != nil {
                MainNotice(symbol: "wifi.exclamationmark", title: "Can't reach your hub at \(store.config.hubURL)",
                           message: "Check the hub address in Settings.") {
                    Button("Check Settings", action: openSettings).buttonStyle(OutlineButtonStyle())
                    Button("Try again") { Task { await model.reload() } }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                switch tab.wrappedValue {
                case .focus: focus
                case .board:
                    ProjectBoard(model: model, entries: shown, open: { openID = $0.id }, editColumn: { columnEditor = ColumnEditorContext(column: $0) })
                case .all: list
                }
            }
        }
    }

    // MARK: Focus

    @ViewBuilder
    private var focus: some View {
        let now = shown.filter { model.isNow($0) }
        let next = shown.filter { model.isNext($0) }
        let parked = shown.count - now.count - next.count

        WLEyebrow("Now · \(now.count)", color: p.accent)
        if now.isEmpty {
            MainNotice(symbol: "scope", title: "Nothing in focus.",
                       message: "Open a project and add a goal for now, or move a project to In progress on the board.")
        }
        if now.count > 5 {
            WLStatusPill(text: "\(now.count) projects in play at once. Fewer is easier: park some on the board, or move goals to Next.", kind: .warn)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(now) { entry in
                FocusCard(entry: entry, model: model) { openID = entry.id }
            }
        }

        if !next.isEmpty {
            WLEyebrow("Next · \(next.count)").padding(.top, 6)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(next) { entry in
                        if entry.id != next.first?.id { WLDivider() }
                        Button { openID = entry.id } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text)
                                    Text(entry.progress?.nextStep.map { "Next: \($0.text)" } ?? entry.whereItStands)
                                        .font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                ProjectCounts(entry: entry)
                                Text(HubDate.format(entry.lastWorked)).font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        HStack(spacing: 10) {
            if parked > 0 {
                Button("\(parked) other project\(parked == 1 ? "" : "s") parked or done") { stageFilter = "all"; tab.wrappedValue = .all }
                    .buttonStyle(OutlineButtonStyle())
            }
            if !model.unfiled.isEmpty {
                Button("\(model.unfiled.count) loose session\(model.unfiled.count == 1 ? "" : "s")") { showLoose = true }
                    .buttonStyle(OutlineButtonStyle())
                    .help("One-off chats that belong to no project. Nothing you have to do.")
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    // MARK: List

    private var listed: [ProjectEntry] {
        let inTopic = topic.isEmpty ? shown : shown.filter { $0.project.tags.contains(topic) }
        switch stageFilter {
        case "open": return inTopic.filter { model.status(of: $0) != "done" }
        case "all": return inTopic
        default: return inTopic.filter { model.status(of: $0) == stageFilter }
        }
    }

    private var topics: [String] {
        Array(Set(model.entries.flatMap(\.project.tags))).sorted()
    }

    private var stats: some View {
        let memories = model.entries.reduce(0) { $0 + $1.project.memoryCount }
        let sessions = model.entries.reduce(0) { $0 + $1.project.chatCount } + model.unfiled.count
        let last = model.entries.compactMap { HubDate.parse($0.lastWorked) }.max()
        return HStack(spacing: DS.Spacing.md) {
            WLStatTile(title: "Projects", value: "\(model.entries.count)", icon: "folder")
            WLStatTile(title: "Memories", value: "\(memories)", icon: "brain")
            WLStatTile(title: "Chats", value: "\(sessions)", icon: "bubble.left.and.bubble.right")
            WLStatTile(title: "Last save", value: last.map { String(HubDate.format($0).prefix(5)) } ?? "None yet",
                       icon: "clock", footnote: last.map { String(HubDate.format($0).dropFirst(6)) })
        }
    }

    @ViewBuilder
    private var list: some View {
        stats
        HStack(spacing: 8) {
            Picker("", selection: $stageFilter) {
                Text("Open").tag("open")
                ForEach(model.columns) { Text($0.label).tag($0.status) }
                Text("Everything").tag("all")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if !topics.isEmpty {
                Picker("", selection: $topic) {
                    Text("Any topic").tag("")
                    ForEach(topics, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            Text("\(listed.count) of \(model.entries.count)").font(DS.Font.micro).foregroundStyle(p.textMuted)
            Spacer()
            if !model.unfiled.isEmpty {
                Button("\(model.unfiled.count) loose sessions") { showLoose = true }.buttonStyle(OutlineButtonStyle())
            }
        }
        let shown = listed
        if shown.isEmpty { MainNotice(symbol: "list.bullet", title: "No matching projects.", message: "Try another search or stage.") }
        Card(padding: 6) {
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    if entry.id != shown.first?.id { WLDivider() }
                    Button { openID = entry.id } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(entry.name).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text)
                                    MainTag(text: model.statusLabel(of: entry), color: p.textMuted)
                                    OwnerTag(entry: entry, model: model)
                                }
                                if let next = entry.progress?.nextStep {
                                    Text("Next: \(next.text)").font(DS.Font.micro).foregroundStyle(p.text).lineLimit(1)
                                } else if !entry.whereItStands.isEmpty {
                                    Text(entry.whereItStands).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            ProjectCounts(entry: entry)
                            Text(HubDate.format(entry.lastWorked)).font(DS.Font.micro.monospacedDigit())
                                .foregroundStyle(p.textFaint).frame(width: 118, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.textFaint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// The same three numbers on every view of a project: goals done, goals open, open problems.
struct ProjectCounts: View {
    @Environment(\.palette) private var p
    let entry: ProjectEntry

    var body: some View {
        HStack(spacing: 6) {
            if entry.verifiedCount > 0 { MainTag(text: "\(entry.verifiedCount) verified", color: p.good) }
            if !entry.openGoals.isEmpty { MainTag(text: "\(entry.openGoals.count) to do", color: p.accent2) }
            if entry.openProblems > 0 { MainTag(text: "\(entry.openProblems) problems", color: p.bad) }
        }
    }
}

struct GoalStatusTag: View {
    @Environment(\.palette) private var p
    let status: String
    var body: some View {
        switch status {
        case "verified": MainTag(text: "Verified", color: p.good)
        case "committed": MainTag(text: "Committed", color: p.accent2)
        default: MainTag(text: "Proposed", color: p.textMuted)
        }
    }
}

/// The owner, as a menu: click it to hand the project to someone else.
struct OwnerTag: View {
    @Environment(\.palette) private var p
    let entry: ProjectEntry
    @ObservedObject var model: ProjectsModel

    var body: some View {
        let owner = entry.project.owner ?? ""
        if model.owners.isEmpty {
            if !owner.isEmpty { MainTag(text: owner) }
        } else {
            Menu {
                ForEach(model.owners, id: \.self) { name in
                    Button(name) { model.setOwner(entry, name) }.disabled(name == owner)
                }
                if !owner.isEmpty {
                    Divider()
                    Button("No owner") { model.setOwner(entry, "") }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(owner.isEmpty ? "No owner" : owner)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(p.accent).background(p.accent.opacity(0.14), in: Capsule())
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Change who owns this project")
        }
    }
}

/// A project in play: the one next step, the goals for now, and nothing else.
private struct FocusCard: View {
    @Environment(\.palette) private var p
    let entry: ProjectEntry
    @ObservedObject var model: ProjectsModel
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(HubDate.format(entry.lastWorked)).font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                }
                if let star = entry.progress?.northStar, !star.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(p.accent2).padding(.top, 2)
                        Text(star).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                if let progress = entry.progress, let milestone = progress.currentMilestone,
                   let index = progress.milestones.firstIndex(of: milestone) {
                    Text("Milestone \(index + 1) of \(progress.milestones.count): \(milestone.title)")
                        .font(DS.Font.micro.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                }
                if let next = entry.progress?.nextStep {
                    VStack(alignment: .leading, spacing: 3) {
                        WLEyebrow("Next step", color: p.accent)
                        Text(next.text).font(DS.Font.bodySmall.weight(.medium)).foregroundStyle(p.text).lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if !next.doneWhen.isEmpty {
                            Text("Done when: \(next.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2)
                        }
                    }
                } else {
                    Text(entry.whereItStands.isEmpty ? "No next step yet. Open it and add a goal." : entry.whereItStands)
                        .font(DS.Font.bodySmall).foregroundStyle(p.textMuted).lineLimit(3).multilineTextAlignment(.leading)
                }
                let goals = entry.openGoals.filter { $0.phase == "now" }.prefix(3)
                if goals.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(goals.dropFirst())) { goal in
                            HStack(spacing: 6) {
                                Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(p.textFaint)
                                Text(goal.title).font(DS.Font.micro).foregroundStyle(p.text).lineLimit(1)
                            }
                        }
                    }
                }
                HStack { ProjectCounts(entry: entry); Spacer(minLength: 0) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(hovering ? p.surfaceRaised : p.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
    }
}

/// One-off chats that belong to no project. Read one, file it, or delete it. None of it is required.
private struct LooseSessionsSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ProjectsModel
    @State private var reading: HubUnfiledSession?
    @State private var confirmAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    WLEyebrow("Loose sessions")
                    Text("Chats that belong to no project").font(DS.Font.section).foregroundStyle(p.text)
                    Text("Chats that match a project are filed by themselves. Move the rest to One-offs to keep things tidy.")
                        .font(DS.Font.micro).foregroundStyle(p.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !model.unfiled.isEmpty {
                    Button("Move all to One-offs") {
                        model.perform("Moved to One-offs.") { try await $0.fileLooseInOneOffs() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if model.unfiled.count > 1 {
                    Button("Delete all") { confirmAll = true }.buttonStyle(OutlineButtonStyle())
                }
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.unfiled.isEmpty {
                        Text("Nothing loose.").font(DS.Font.bodySmall).foregroundStyle(p.textMuted).padding(20)
                    }
                    ForEach(model.unfiled) { session in
                        HStack(alignment: .top, spacing: 10) {
                            Button { reading = session } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if !session.summary.isEmpty {
                                        Text(session.summary).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Text("\(HubDate.format(session.happenedAt)) · \(session.messages) messages · click to read")
                                        .font(DS.Font.micro).foregroundStyle(p.textFaint)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu("File under…") {
                                ForEach(model.entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { entry in
                                    Button(entry.name) {
                                        model.perform("Filed under \(entry.name).") { try await $0.fileSession(id: session.id, projectID: entry.id) }
                                    }
                                }
                            }
                            .fixedSize()
                            Button { model.perform { try await $0.deleteSession(id: session.id) } } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }
                            .buttonStyle(.plain).foregroundStyle(p.textMuted).help("Delete this session")
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 720, height: 560)
        .background(p.background)
        .sheet(item: $reading) { SessionReader(chatID: $0.id, title: $0.title, when: $0.happenedAt) }
        .confirmationDialog("Delete all \(model.unfiled.count) loose sessions?", isPresented: $confirmAll) {
            Button("Delete all", role: .destructive) {
                let ids = model.unfiled.map(\.id)
                model.perform("Deleted \(ids.count) loose sessions.") { hub in
                    for id in ids { try await hub.deleteSession(id: id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Their transcripts are removed from the hub. Projects are not touched.") }
    }
}

// MARK: - Board

/// The board: columns are the project's stage. Cards carry the same next step and counts as the
/// other views; dragging a card (or its Move menu) changes the stage everywhere.
struct ProjectBoard: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: ProjectsModel
    let entries: [ProjectEntry]
    let open: (ProjectEntry) -> Void
    let editColumn: (HubKanbanColumn) -> Void
    @State private var deleting: HubKanbanColumn?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.columns) { column in
                    let cards = entries.filter { model.status(of: $0) == column.status }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(column.label).font(DS.Font.body.weight(.semibold))
                            Spacer()
                            MainTag(text: String(cards.count))
                            Menu {
                                Button("Rename") { editColumn(column) }
                                let index = model.columns.firstIndex(of: column) ?? 0
                                Button("Move left") { moveColumn(column, by: -1) }.disabled(index == 0)
                                Button("Move right") { moveColumn(column, by: 1) }.disabled(index >= model.columns.count - 1)
                                Divider()
                                Button("Delete", role: .destructive) { deleting = column }.disabled(model.columns.count <= 1)
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        if let description = column.description, !description.isEmpty {
                            Text(description).font(DS.Font.micro).foregroundStyle(p.textMuted)
                        }
                        ForEach(cards) { card($0) }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(width: 280, alignment: .top)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    .dropDestination(for: String.self) { ids, _ in
                        guard let raw = ids.first, let id = Int(raw), let entry = model.entry(id) else { return false }
                        model.move(entry, to: column.status)
                        return true
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \(deleting?.label ?? "column")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { column in
            ForEach(model.columns.filter { $0.status != column.status }) { destination in
                Button("Delete and move projects to \(destination.label)", role: .destructive) {
                    model.perform { _ = try await $0.deleteKanbanColumn(status: column.status, moveTo: destination.status) }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Projects are kept. Choose the column that should receive them.")
        }
    }

    private func card(_ entry: ProjectEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name).font(DS.Font.bodySmall.weight(.semibold)).lineLimit(2)
                Spacer()
                OwnerTag(entry: entry, model: model)
            }
            if let next = entry.progress?.nextStep {
                Text("Next: \(next.text)").font(DS.Font.micro).foregroundStyle(p.text).lineLimit(3)
            } else if let description = entry.project.description {
                Text(description).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(3)
            }
            ProjectCounts(entry: entry)
            HStack {
                Text(HubDate.format(entry.lastWorked)).font(DS.Font.micro).foregroundStyle(p.textFaint)
                Spacer()
                Menu("Move") {
                    ForEach(model.columns.filter { $0.status != model.status(of: entry) }) { destination in
                        Button(destination.label) { model.move(entry, to: destination.status) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.row))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row))
        .onTapGesture { open(entry) }
        .draggable(String(entry.id))
        .help("Open \(entry.name)")
    }

    private func moveColumn(_ column: HubKanbanColumn, by offset: Int) {
        guard let source = model.columns.firstIndex(of: column) else { return }
        let target = source + offset
        guard model.columns.indices.contains(target) else { return }
        var statuses = model.columns.map(\.status)
        statuses.swapAt(source, target)
        model.perform { _ = try await $0.reorderKanbanColumns(statuses) }
    }
}

struct ColumnEditorContext: Identifiable {
    let id = UUID()
    var status: String?
    var label = ""
    var description = ""

    init(column: HubKanbanColumn? = nil) {
        status = column?.status
        label = column?.label ?? ""
        description = column?.description ?? ""
    }
}

struct KanbanColumnEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var description: String
    let context: ColumnEditorContext
    let save: (String, String) -> Void

    init(context: ColumnEditorContext, save: @escaping (String, String) -> Void) {
        self.context = context
        self.save = save
        _label = State(initialValue: context.label)
        _description = State(initialValue: context.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(context.status == nil ? "Add column" : "Edit column").font(DS.Font.section)
            TextField("Column name", text: $label).mainField()
            TextField("Description", text: $description).mainField()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save") { save(label.trimmingCharacters(in: .whitespacesAndNewlines), description); dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

// MARK: - Build prompt

/// Choose goals, add a note, and get a frozen brief to paste into Codex or Claude.
struct BuildPromptSheet: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let entry: ProjectEntry
    let onDone: () async -> Void
    @State private var chosen: Set<Int> = []
    @State private var note = ""
    @State private var prompt: HubBuildPrompt?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WLEyebrow("Build prompt")
            Text(entry.name).font(DS.Font.page).foregroundStyle(p.text)
            if let prompt {
                Text("Saved as written. Paste it into Codex or Claude in the project's folder.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                ScrollView {
                    Text(prompt.body).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(p.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.border, lineWidth: 0.8))
                HStack {
                    if copied { WLStatusPill(text: "Copied", kind: .good) }
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(OutlineButtonStyle())
                    Button("Copy prompt") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt.body, forType: .string)
                        copied = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                Text("Choose what to build. The prompt includes only these goals, plus the constraints and decisions that bear on them.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                if let error { WLStatusPill(text: error, kind: .bad) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entry.openGoals) { goal in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(goal.id) },
                                set: { on in if on { chosen.insert(goal.id) } else { chosen.remove(goal.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(goal.title).font(DS.Font.bodySmall.weight(.semibold))
                                    if !goal.doneWhen.isEmpty {
                                        Text("Done when: \(goal.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                WLEyebrow("Anything to preserve or avoid?")
                TextField("Optional", text: $note, axis: .vertical).lineLimit(2...4).mainField()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle())
                    Button("Prepare prompt") { prepare() }.buttonStyle(PrimaryButtonStyle()).disabled(chosen.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 600)
        .background(p.background)
        .onAppear {
            // Start with what is up now, so the default prompt is narrow.
            chosen = Set(entry.openGoals.filter { $0.phase == "now" }.map(\.id))
        }
    }

    private func prepare() {
        Task {
            do {
                prompt = try await store.hub.buildPrompt(projectID: entry.id, goalIDs: Array(chosen), note: note)
                error = nil
                await onDone()
            } catch { self.error = error.localizedDescription }
        }
    }
}


/// Start a project by hand: what it is, where it is heading, and a few first steps. No agent needed.
struct NewProjectSheet: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ProjectsModel
    let created: (Int) -> Void

    @State private var name = ""
    @State private var about = ""
    @State private var northStar = ""
    @State private var owner = ""
    @State private var stage = "in_progress"
    @State private var milestones = ""
    @State private var folder = ""
    @State private var topics = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                WLEyebrow("New project")
                Text("Start something").font(DS.Font.page).foregroundStyle(p.text)
                Text("Only the name is needed. Everything else can be filled in or changed later.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Name") { TextField("For example: First album", text: $name).mainField() }
                    field("What is it?") {
                        TextField("A sentence or two, for you and for any AI tool you point at it", text: $about, axis: .vertical)
                            .lineLimit(2...4).mainField()
                    }
                    field("North Star", note: "Where it is heading. It is fine to be unsure; you will change it as you go.") {
                        TextField("For example: ten songs I would play for friends, released by spring", text: $northStar, axis: .vertical)
                            .lineLimit(2...4).mainField()
                    }
                    HStack(alignment: .top, spacing: 16) {
                        field("Owner") {
                            Picker("", selection: $owner) {
                                Text("No owner").tag("")
                                ForEach(model.owners, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                        field("Stage") {
                            Picker("", selection: $stage) {
                                ForEach(model.columns) { Text($0.label).tag($0.status) }
                            }
                            .labelsHidden()
                        }
                    }
                    field("First milestones", note: "Optional. One per line, in order: the big chunks between now and the North Star.") {
                        TextEditor(text: $milestones)
                            .font(DS.Font.bodySmall).frame(height: 84).scrollContentBackground(.hidden)
                            .padding(6).background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
                    }
                    field("Folder", note: "Optional. Where the work lives, so saves from there land here.") {
                        HStack {
                            TextField("/path/to/the/project", text: $folder).mainField()
                            Button("Choose…") { chooseFolder() }.buttonStyle(OutlineButtonStyle())
                        }
                    }
                    field("Topics", note: "Optional, comma separated.") {
                        TextField("music, ai", text: $topics).mainField()
                    }
                    if let error { WLStatusPill(text: error, kind: .bad) }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(saving ? "Creating…" : "Create project") { create() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            .padding(16)
        }
        .frame(width: 600, height: 720)
        .background(p.background)
        .onAppear {
            if model.columns.contains(where: { $0.status == "in_progress" }) == false { stage = model.columns.first?.status ?? "active" }
        }
    }

    private func field<Content: View>(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WLEyebrow(title)
            content()
            if let note { Text(note).font(DS.Font.micro).foregroundStyle(p.textFaint) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func create() {
        saving = true
        let lines = milestones.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tags = topics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            defer { saving = false }
            do {
                let id = try await store.hub.startProject(
                    name: name.trimmingCharacters(in: .whitespaces), description: about, northStar: northStar,
                    owner: owner, status: stage, milestones: lines, folder: folder, tags: tags)
                dismiss()
                created(id)
            } catch { self.error = "Could not create it. \(error.localizedDescription)" }
        }
    }
}
