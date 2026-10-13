import AppKit
import SwiftUI

private enum ProgressTab: String, Hashable {
    case projects, todo, unfiled
}

/// Progress: where every project stands, what to build next, and the sessions that belong nowhere yet.
struct ProgressSectionView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @State private var tab: ProgressTab = .projects
    @State private var response: HubProgressResponse?
    @State private var unfiled: [HubUnfiledSession] = []
    @State private var loading = true
    @State private var error: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var openProject: HubProgressProject?
    @State private var promptFor: HubProgressProject?

    private var tabs: [WLTab<ProgressTab>] {
        [
            WLTab(id: .projects, title: "Projects", icon: "square.grid.2x2"),
            WLTab(id: .todo, title: "To do", icon: "checklist"),
            WLTab(id: .unfiled, title: "Unfiled", icon: "tray", attention: (response?.unfiledSessions ?? 0) > 0),
        ]
    }

    var body: some View {
        MainPage {
            WLPageHeader(eyebrow: "Your work", title: "Your projects, in view.",
                         subtitle: "Where each one stands. What is verified. What to build next.") {
                Button("Refresh") { Task { await load() } }.buttonStyle(OutlineButtonStyle())
            }
            HStack {
                WLTabBar(tabs: tabs, selection: $tab)
                Spacer(minLength: 0)
            }
            if let notice { WLStatusPill(text: notice, kind: .good) }
            if let error { WLStatusPill(text: error, kind: .bad) }
            if loading && response == nil {
                ProgressView("Reading the journal…")
            } else if let response {
                switch tab {
                case .projects: projects(response.projects)
                case .todo: todo(response.projects)
                case .unfiled: unfiledList(response.projects)
                }
            }
            Color.clear.frame(height: 0).task(id: store.config.hubURL) { await load() }
        }
        .sheet(item: $openProject) { project in
            ProjectProgressSheet(project: project, onChange: { await load() }, onPrompt: { promptFor = $0 })
        }
        .sheet(item: $promptFor) { project in
            BuildPromptSheet(project: project, onDone: { await load() })
        }
    }

    // MARK: Projects

    @ViewBuilder
    private func projects(_ all: [HubProgressProject]) -> some View {
        TextField("Find a project", text: $query).mainField().frame(maxWidth: 320)
        let shown = all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        if shown.isEmpty {
            MainNotice(symbol: "square.grid.2x2", title: "No matching projects.", message: "Try another search.")
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(shown) { project in
                ProjectProgressCard(project: project) { openProject = project }
            }
        }
    }

    // MARK: To do

    @ViewBuilder
    private func todo(_ all: [HubProgressProject]) -> some View {
        let open = all.flatMap { project in project.openGoals.map { (project, $0) } }
        if open.isEmpty {
            MainNotice(symbol: "checklist", title: "No goals yet.",
                       message: "Open a project and turn its next step into a goal. Goals start as proposals you can edit.")
        }
        ForEach(["now", "next", "later"], id: \.self) { phase in
            let items = open.filter { $0.1.phase == phase }
            if !items.isEmpty {
                WLGroup(title: phase.capitalized, subtitle: phase == "now" ? "One lane at a time." : nil, icon: "flag") {
                    ForEach(items, id: \.1.id) { project, goal in
                        if goal.id != items.first?.1.id { WLDivider() }
                        Button { openProject = project } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(goal.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text)
                                    if !goal.doneWhen.isEmpty {
                                        Text("Done when: \(goal.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                                    }
                                    Text(project.name).font(DS.Font.micro).foregroundStyle(p.textFaint)
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
    private func unfiledList(_ all: [HubProgressProject]) -> some View {
        if unfiled.isEmpty {
            MainNotice(symbol: "tray", title: "Nothing unfiled.", message: "Every saved session belongs to a project.")
        } else {
            WLGroup(title: "Sessions without a project", subtitle: "Saved, but not part of any project's story yet. File each one where it belongs.", icon: "tray") {
                ForEach(unfiled) { session in
                    if session.id != unfiled.first?.id { WLDivider() }
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
                            ForEach(all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { project in
                                Button(project.name) { file(session, under: project) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func file(_ session: HubUnfiledSession, under project: HubProgressProject) {
        Task {
            do {
                try await store.hub.fileSession(id: session.id, projectID: project.id)
                notice = "Filed under \(project.name)."
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            response = try await store.hub.progress()
            unfiled = (try? await store.hub.unfiledSessions()) ?? []
            if let open = openProject { openProject = response?.projects.first { $0.id == open.id } }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct GoalStatusTag: View {
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
    let project: HubProgressProject
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(project.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(HubDate.format(project.lastSession)).font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    WLEyebrow("Where it stands")
                    Text(project.whereItStands.isEmpty ? "Nothing saved yet." : project.whereItStands)
                        .font(DS.Font.bodySmall).foregroundStyle(p.textMuted).lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
                if let next = project.nextStep {
                    VStack(alignment: .leading, spacing: 3) {
                        WLEyebrow("Next useful step", color: p.accent)
                        Text(next.text).font(DS.Font.bodySmall.weight(.medium)).foregroundStyle(p.text).lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if !next.doneWhen.isEmpty {
                            Text("Done when: \(next.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2)
                        }
                    }
                }
                HStack(spacing: 6) {
                    if project.verifiedCount > 0 { MainTag(text: "\(project.verifiedCount) verified", color: p.good) }
                    if !project.openGoals.isEmpty { MainTag(text: "\(project.openGoals.count) to do", color: p.accent2) }
                    if !project.openProblems.isEmpty { MainTag(text: "\(project.openProblems.count) open problems", color: p.bad) }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(hovering ? p.surfaceRaised : p.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border, lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
    }
}

/// One project: where it stands, its goals, notes that could become goals, and open problems.
private struct ProjectProgressSheet: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let project: HubProgressProject
    let onChange: () async -> Void
    let onPrompt: (HubProgressProject) -> Void
    @State private var title = ""
    @State private var doneWhen = ""
    @State private var phase = "now"
    @State private var error: String?
    @State private var verifying: HubGoal?
    @State private var proof = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    WLEyebrow("Project")
                    Text(project.name).font(DS.Font.page).foregroundStyle(p.text)
                }
                Spacer()
                Button("Prepare build prompt") { dismiss(); onPrompt(project) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(project.openGoals.isEmpty)
                    .help(project.openGoals.isEmpty ? "Add a goal first" : "Make a scoped brief for Codex or Claude")
                Button("Done") { dismiss() }.buttonStyle(OutlineButtonStyle())
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if let error { WLStatusPill(text: error, kind: .bad) }
                    WLGroup(title: "Where it stands", icon: "location") {
                        Text(project.whereItStands.isEmpty ? "Nothing saved yet." : project.whereItStands)
                            .font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled)
                        Text("\(project.sessions) sessions · \(project.memories) memories · last worked on \(HubDate.format(project.lastSession))")
                            .font(DS.Font.micro).foregroundStyle(p.textMuted)
                    }
                    goals
                    if !project.suggestions.isEmpty { suggestions }
                    if !project.openProblems.isEmpty {
                        WLGroup(title: "Still unverified", subtitle: "Open problems from the journal.", icon: "exclamationmark.triangle") {
                            ForEach(project.openProblems) { problem in
                                Text("• \(problem.text)").font(DS.Font.bodySmall).foregroundStyle(p.text)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 640)
        .background(p.background)
        .sheet(item: $verifying) { goal in verifySheet(goal) }
    }

    private var goals: some View {
        WLGroup(title: "Goals", subtitle: "Proposed, then committed, then verified. A goal is verified when you have seen it work.", icon: "flag") {
            if project.goals.isEmpty { Text("No goals yet.").font(DS.Font.bodySmall).foregroundStyle(p.textMuted) }
            ForEach(project.goals) { goal in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.title).font(DS.Font.bodySmall.weight(.semibold))
                        if !goal.doneWhen.isEmpty {
                            Text("Done when: \(goal.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                        }
                        if !goal.proof.isEmpty {
                            Text("Seen: \(goal.proof)").font(DS.Font.micro).foregroundStyle(p.good)
                        }
                    }
                    Spacer()
                    GoalStatusTag(status: goal.status)
                    Menu {
                        ForEach(["now", "next", "later"], id: \.self) { phase in
                            Button("Move to \(phase.capitalized)") { change(goal, ["phase": phase]) }.disabled(goal.phase == phase)
                        }
                        Divider()
                        if goal.status == "proposed" { Button("Commit to it") { change(goal, ["status": "committed"]) } }
                        if goal.status != "verified" { Button("Mark verified…") { proof = ""; verifying = goal } }
                        if goal.status == "verified" { Button("Reopen") { change(goal, ["status": "committed"]) } }
                        Divider()
                        Button("Delete", role: .destructive) { remove(goal) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                WLDivider()
            }
            VStack(alignment: .leading, spacing: 8) {
                WLEyebrow("Add a goal")
                TextField("What should be true?", text: $title).mainField()
                TextField("Done when… (how you will know)", text: $doneWhen).mainField()
                HStack {
                    Picker("", selection: $phase) {
                        Text("Now").tag("now"); Text("Next").tag("next"); Text("Later").tag("later")
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                    Spacer()
                    Button("Add goal") { add(title: title, doneWhen: doneWhen, phase: phase, memoryID: nil) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var suggestions: some View {
        WLGroup(title: "From your notes", subtitle: "Things the journal says are in progress. Make one a goal if it is worth finishing.", icon: "lightbulb") {
            ForEach(project.suggestions) { note in
                HStack(alignment: .top) {
                    Text(note.text).font(DS.Font.bodySmall).foregroundStyle(p.text)
                    Spacer()
                    Button("Make this a goal") { add(title: note.text, doneWhen: "", phase: "now", memoryID: note.id) }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    private func verifySheet(_ goal: HubGoal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WLEyebrow("Mark verified")
            Text(goal.title).font(DS.Font.section)
            if !goal.doneWhen.isEmpty {
                Text("Done when: \(goal.doneWhen)").font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            }
            Text("What did you see that proves it?").font(DS.Font.bodySmall)
            TextField("For example: ran it end to end on 10/14 and the export opened", text: $proof, axis: .vertical)
                .lineLimit(3...5).mainField()
            HStack {
                Spacer()
                Button("Cancel") { verifying = nil }.buttonStyle(OutlineButtonStyle())
                Button("Mark verified") {
                    change(goal, ["status": "verified", "proof": proof]); verifying = nil
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(proof.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 460).background(p.background)
    }

    private func add(title: String, doneWhen: String, phase: String, memoryID: Int?) {
        run { try await store.hub.createGoal(projectID: project.id, title: title, doneWhen: doneWhen, phase: phase, memoryID: memoryID) }
        self.title = ""; self.doneWhen = ""
    }

    private func change(_ goal: HubGoal, _ changes: [String: Any]) {
        run { try await store.hub.updateGoal(id: goal.id, changes) }
    }

    private func remove(_ goal: HubGoal) {
        run { try await store.hub.deleteGoal(id: goal.id) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil; await onChange() } catch { self.error = error.localizedDescription }
        }
    }
}

/// Choose goals, add a note, and get a frozen brief to paste into Codex or Claude.
private struct BuildPromptSheet: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let project: HubProgressProject
    let onDone: () async -> Void
    @State private var chosen: Set<Int> = []
    @State private var note = ""
    @State private var prompt: HubBuildPrompt?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WLEyebrow("Build prompt")
            Text(project.name).font(DS.Font.page).foregroundStyle(p.text)
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
                        ForEach(project.openGoals) { goal in
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
            chosen = Set(project.openGoals.filter { $0.phase == "now" }.map(\.id))
        }
    }

    private func prepare() {
        Task {
            do {
                prompt = try await store.hub.buildPrompt(projectID: project.id, goalIDs: Array(chosen), note: note)
                error = nil
                await onDone()
            } catch { self.error = error.localizedDescription }
        }
    }
}
