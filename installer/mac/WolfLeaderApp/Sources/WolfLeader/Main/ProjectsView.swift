import AppKit
import SwiftUI

enum ProjectsTab: String, Hashable {
    case progress, board, list, todo, unfiled
}

/// Projects: one set of projects, seen three ways (progress cards, the board, a plain list), plus
/// the goals across all of them and the sessions that belong to none. Every view opens the same
/// project page, and a change made in one shows up in the others.
struct ProjectsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @StateObject private var model = ProjectsModel()
    @AppStorage("wl.projects.tab") private var tabRaw = ProjectsTab.progress.rawValue
    @State private var query = ""
    @State private var openID: Int?
    @State private var promptFor: ProjectEntry?
    @State private var columnEditor: ColumnEditorContext?

    private var tab: Binding<ProjectsTab> {
        Binding(get: { ProjectsTab(rawValue: tabRaw) ?? .progress }, set: { tabRaw = $0.rawValue })
    }

    private var tabs: [WLTab<ProjectsTab>] {
        [
            WLTab(id: .progress, title: "Progress", icon: "square.grid.2x2"),
            WLTab(id: .board, title: "Board", icon: "rectangle.3.group"),
            WLTab(id: .list, title: "List", icon: "list.bullet"),
            WLTab(id: .todo, title: "To do", icon: "checklist"),
            WLTab(id: .unfiled, title: "Unfiled", icon: "tray", attention: !model.unfiled.isEmpty),
        ]
    }

    private var shown: [ProjectEntry] { model.entries.filter { $0.matches(query) } }

    var body: some View {
        Group {
            if let openID, let entry = model.entry(openID) {
                ProjectPage(entry: entry, model: model, back: { self.openID = nil }, prompt: { promptFor = $0 })
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
            WLPageHeader(title: "Projects", subtitle: "\(model.entries.count) projects. The same work, seen as progress, a board, or a list.") {
                HStack(spacing: 8) {
                    WLSearchField(text: $query, placeholder: "Search projects and goals").frame(width: 260)
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
            } else {
                switch tab.wrappedValue {
                case .progress: progress
                case .board:
                    ProjectBoard(model: model, entries: shown, open: { openID = $0.id }, editColumn: { columnEditor = ColumnEditorContext(column: $0) })
                case .list: list
                case .todo: todo
                case .unfiled: unfiledList
                }
            }
        }
    }

    // MARK: Progress

    @ViewBuilder
    private var progress: some View {
        if shown.isEmpty { MainNotice(symbol: "square.grid.2x2", title: "No matching projects.", message: "Try another search.") }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(shown) { entry in
                ProjectProgressCard(entry: entry, status: model.statusLabel(of: entry)) { openID = entry.id }
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if shown.isEmpty { MainNotice(symbol: "list.bullet", title: "No matching projects.", message: "Try another search.") }
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
                                    if let owner = entry.project.owner, !owner.isEmpty { MainTag(text: owner) }
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

    // MARK: To do

    @ViewBuilder
    private var todo: some View {
        let open = shown.flatMap { entry in entry.openGoals.map { (entry, $0) } }
        if open.isEmpty {
            MainNotice(symbol: "checklist", title: "No goals yet.",
                       message: "Open a project and turn its next step into a goal. Goals start as proposals you can edit.")
        }
        ForEach(["now", "next", "later"], id: \.self) { phase in
            let items = open.filter { $0.1.phase == phase }
            if !items.isEmpty {
                WLGroup(title: phase.capitalized, subtitle: phase == "now" ? "One lane at a time." : nil, icon: "flag") {
                    ForEach(items, id: \.1.id) { entry, goal in
                        if goal.id != items.first?.1.id { WLDivider() }
                        Button { openID = entry.id } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(goal.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text)
                                    if !goal.doneWhen.isEmpty {
                                        Text("Done when: \(goal.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                                    }
                                    Text("\(entry.name) · \(model.statusLabel(of: entry))").font(DS.Font.micro).foregroundStyle(p.textFaint)
                                }
                                Spacer()
                                GoalStatusTag(status: goal.status)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Unfiled

    @ViewBuilder
    private var unfiledList: some View {
        if model.unfiled.isEmpty {
            MainNotice(symbol: "tray", title: "Nothing unfiled.", message: "Every saved session belongs to a project.")
        } else {
            WLGroup(title: "Sessions without a project", subtitle: "Saved, but not part of any project's story yet. File each one where it belongs.", icon: "tray") {
                ForEach(model.unfiled) { session in
                    if session.id != model.unfiled.first?.id { WLDivider() }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(DS.Font.bodySmall.weight(.semibold)).lineLimit(2)
                            if !session.summary.isEmpty {
                                Text(session.summary).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(3)
                            }
                            Text("\(HubDate.format(session.happenedAt)) · \(session.messages) messages")
                                .font(DS.Font.micro).foregroundStyle(p.textFaint)
                        }
                        Spacer()
                        Menu("File under…") {
                            ForEach(model.entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { entry in
                                Button(entry.name) {
                                    model.perform("Filed under \(entry.name).") { try await $0.fileSession(id: session.id, projectID: entry.id) }
                                }
                            }
                        }
                        .fixedSize()
                    }
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

private struct ProjectProgressCard: View {
    @Environment(\.palette) private var p
    let entry: ProjectEntry
    let status: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    MainTag(text: status, color: p.textMuted)
                    Spacer(minLength: 6)
                    Text(HubDate.format(entry.lastWorked)).font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    WLEyebrow("Where it stands")
                    Text(entry.whereItStands.isEmpty ? "Nothing saved yet." : entry.whereItStands)
                        .font(DS.Font.bodySmall).foregroundStyle(p.textMuted).lineLimit(4).multilineTextAlignment(.leading)
                }
                if let next = entry.progress?.nextStep {
                    VStack(alignment: .leading, spacing: 3) {
                        WLEyebrow("Next useful step", color: p.accent)
                        Text(next.text).font(DS.Font.bodySmall.weight(.medium)).foregroundStyle(p.text).lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if !next.doneWhen.isEmpty {
                            Text("Done when: \(next.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2)
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
                if let owner = entry.project.owner, !owner.isEmpty { MainTag(text: owner) }
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
