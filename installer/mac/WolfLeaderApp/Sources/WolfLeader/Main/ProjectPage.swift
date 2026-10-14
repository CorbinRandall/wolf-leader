import AppKit
import SwiftUI

/// Everything about one project, in the app: where it stands, its stage on the board, goals, the
/// journal's memories, the logbook of sessions (readable here), the brief agents get, and where it lives.
struct ProjectPage: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    let entry: ProjectEntry
    @ObservedObject var model: ProjectsModel
    let back: () -> Void
    let prompt: (ProjectEntry) -> Void
    var open: (Int) -> Void = { _ in }

    @State private var related: [HubRelatedProject] = []
    @State private var star: HubNorthStar?
    @State private var howls: [Int: HubHowl] = [:]
    @State private var editingStar = false
    @State private var showStarHistory = false
    @State private var memories: [HubMemory] = []
    @State private var logbook: [HubLogEntry] = []
    @State private var sessions: [HubChat] = []
    @State private var folders: [HubProjectFolder] = []
    @State private var prompts: [HubBuildPrompt] = []
    @State private var brief: HubProjectBrief?
    @State private var loading = true
    @State private var notice: String?
    @State private var reading: HubChat?
    @State private var verifying: HubGoal?
    @State private var proof = ""
    @State private var goalTitle = ""
    @State private var goalDoneWhen = ""
    @State private var goalPhase = "now"
    @State private var goalMilestone = 0
    @State private var milestoneTitle = ""
    @State private var renamingMilestone: HubMilestone?
    @State private var renameText = ""
    @State private var memoryText = ""
    @State private var memoryKind = "note"
    @State private var editing = false
    @State private var showBrief = false
    @State private var showAllSessions = false

    private var progress: HubProgressProject? { entry.progress }

    var body: some View {
        MainPage {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Projects")
                }
                .font(DS.Font.bodySmall.weight(.medium)).foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            header
            if let notice { WLStatusPill(text: notice, kind: .good) }
            if let error = model.error { WLStatusPill(text: error, kind: .bad) }

            northStarCard
            stands
            if !related.isEmpty { connected }
            goals
            if let suggestions = progress?.suggestions, !suggestions.isEmpty { fromNotes(suggestions) }
            if let problems = progress?.openProblems, !problems.isEmpty {
                WLGroup(title: "Still unverified", subtitle: "Open problems from the journal.", icon: "exclamationmark.triangle") {
                    ForEach(problems) { Text("• \($0.text)").font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled) }
                }
            }
            if loading && memories.isEmpty && logbook.isEmpty {
                ProgressView("Loading the rest…")
            }
            logbookGroup
            memoriesGroups
            knowledge
            whereItLives
        }
        .task(id: entry.id) { await load() }
        .sheet(item: $reading) { SessionReader(chatID: $0.id, title: $0.title, when: $0.occurredAt ?? $0.updatedAt) }
        .sheet(item: $verifying) { verifySheet($0) }
        .alert("Rename milestone", isPresented: Binding(get: { renamingMilestone != nil }, set: { if !$0 { renamingMilestone = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let milestone = renamingMilestone { changeMilestone(milestone, ["title": renameText]) }
                renamingMilestone = nil
            }
            Button("Cancel", role: .cancel) { renamingMilestone = nil }
        }
        .sheet(isPresented: $editingStar) {
            NorthStarEditor(current: star?.current?.body ?? "", suggestion: entry.project.description ?? "") { body, why in
                Task {
                    do { try await store.hub.setNorthStar(projectID: entry.id, body: body, why: why); await load(); await model.reload() }
                    catch { model.error = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $editing) {
            ProjectEditor(name: entry.name, description: entry.project.description ?? "") { name, description in
                model.perform("Saved.") { try await $0.updateProject(id: entry.id, name: name, description: description) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    WLEyebrow("Project")
                    Text(entry.name).font(DS.Font.page).foregroundStyle(p.text)
                }
                Spacer(minLength: DS.Spacing.md)
                Button("Prepare build prompt") { prompt(entry) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(entry.openGoals.isEmpty)
                    .help(entry.openGoals.isEmpty ? "Add a goal first" : "Make a scoped brief for Codex or Claude")
                Menu {
                    Button("Copy agent start prompt") { copy(brief?.agentPrompt ?? "", "Start prompt copied.") }
                        .disabled((brief?.agentPrompt ?? "").isEmpty)
                    Button("Copy full brief") { copy(brief?.briefMarkdown ?? "", "Brief copied.") }
                        .disabled((brief?.briefMarkdown ?? "").isEmpty)
                    Button("Refresh brief") { refreshBrief() }
                    Divider()
                    Button("Edit name and description…") { editing = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 8) {
                // The board's column, changeable from here: the same field the board moves.
                Menu {
                    ForEach(model.columns) { column in
                        Button(column.label) { model.move(entry, to: column.status) }
                            .disabled(column.status == model.status(of: entry))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.statusLabel(of: entry))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundStyle(p.accent).background(p.accent.opacity(0.14), in: Capsule())
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Stage on the board")
                OwnerTag(entry: entry, model: model)
                ProjectCounts(entry: entry)
                Text("\(entry.project.chatCount) sessions · \(entry.project.memoryCount) memories · last worked on \(HubDate.format(entry.lastWorked))")
                    .font(DS.Font.micro).foregroundStyle(p.textMuted)
            }
            let purpose = (brief?.purpose).flatMap { $0.isEmpty ? nil : $0 } ?? entry.project.description ?? ""
            if !purpose.isEmpty {
                Text(purpose).font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    // MARK: North Star

    /// Where the project is heading. It sits above everything because the goals serve it, and it
    /// is expected to change as the work teaches you what you actually want.
    private var northStarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(p.accent2)
                WLEyebrow("North Star", color: p.accent2)
                Spacer()
                Button(star?.current == nil ? "Set it" : "Change it") { editingStar = true }.buttonStyle(OutlineButtonStyle())
            }
            if let current = star?.current {
                Text(current.body).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                let history = star?.history.filter { !$0.body.isEmpty } ?? []
                HStack(spacing: 8) {
                    Text("Since \(HubDate.format(current.createdAt))").font(DS.Font.micro).foregroundStyle(p.textMuted)
                    if !history.isEmpty {
                        Button(showStarHistory ? "Hide how it changed" : "Changed \(history.count) time\(history.count == 1 ? "" : "s")") {
                            showStarHistory.toggle()
                        }
                        .buttonStyle(.plain).font(DS.Font.micro.weight(.semibold)).foregroundStyle(p.accent)
                    }
                }
                if let why = current.why, !why.isEmpty, why != "From the journal." {
                    Text("Why it changed: \(why)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                }
                if showStarHistory {
                    ForEach(history) { old in
                        WLDivider()
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(old.body).font(DS.Font.bodySmall).foregroundStyle(p.textMuted).strikethrough(color: p.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Set \(HubDate.format(old.createdAt))").font(DS.Font.micro).foregroundStyle(p.textFaint)
                            }
                            Spacer()
                            Button { removeStarVersion(old) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(p.textFaint).help("Remove from the history")
                        }
                    }
                }
            } else {
                Text("Where is this project heading? One or two sentences. It is fine to be unsure, and normal for it to change.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.accent2.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.accent2.opacity(0.35), lineWidth: 0.8))
    }

    private func removeStarVersion(_ version: HubNorthStarVersion) {
        Task {
            do { try await store.hub.deleteNorthStarVersion(id: version.id); await load() }
            catch { model.error = error.localizedDescription }
        }
    }

    // MARK: Where it stands

    private var stands: some View {
        WLGroup(title: "Where it stands", icon: "location") {
            Text(entry.whereItStands.isEmpty ? "Nothing saved yet." : entry.whereItStands)
                .font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let next = progress?.nextStep {
                VStack(alignment: .leading, spacing: 3) {
                    WLEyebrow("Next useful step", color: p.accent)
                    Text(next.text).font(DS.Font.bodySmall.weight(.medium)).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !next.doneWhen.isEmpty {
                        Text("Done when: \(next.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                    }
                }
            }
        }
    }

    private var connected: some View {
        WLGroup(title: "Connected to", subtitle: "Projects whose journals overlap with this one.", icon: "point.3.connected.trianglepath.dotted") {
            HStack(spacing: 8) {
                ForEach(related.prefix(6)) { other in
                    Button(other.name) { open(other.id) }.buttonStyle(OutlineButtonStyle())
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: The path: milestones, and the goals under each

    private var milestones: [HubMilestone] { progress?.milestones ?? [] }

    private var goals: some View {
        WLGroup(title: "The path", subtitle: "A few milestones between here and the North Star, in order, with the goals under each. Re-order or drop them as the star moves.", icon: "point.topleft.down.to.point.bottomright.curvepath") {
            let all = progress?.goals ?? []
            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                milestoneHeader(milestone, number: index + 1)
                let mine = all.filter { $0.milestoneID == milestone.id }
                if mine.isEmpty {
                    Text("No goals under this yet.").font(DS.Font.micro).foregroundStyle(p.textFaint).padding(.leading, 30)
                }
                ForEach(mine) { goalRow($0).padding(.leading, 30) }
                WLDivider()
            }
            let loose = all.filter { goal in goal.milestoneID == nil || !milestones.contains { $0.id == goal.milestoneID } }
            if !loose.isEmpty {
                if !milestones.isEmpty { WLEyebrow("Not under a milestone") }
                ForEach(loose) { goalRow($0) }
                WLDivider()
            }
            if all.isEmpty && milestones.isEmpty {
                Text("Nothing mapped out yet. Add the big chunks first, then the small steps.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            }
            HStack(spacing: 8) {
                TextField("Add a milestone (a big chunk of the journey)", text: $milestoneTitle).mainField()
                    .onSubmit { addMilestone() }
                Button("Add milestone") { addMilestone() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(milestoneTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            VStack(alignment: .leading, spacing: 8) {
                WLEyebrow("Add a goal")
                TextField("What should be true?", text: $goalTitle).mainField()
                TextField("Done when… (how you will know)", text: $goalDoneWhen).mainField()
                HStack {
                    Picker("", selection: $goalPhase) {
                        Text("Now").tag("now"); Text("Next").tag("next"); Text("Later").tag("later")
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                    if !milestones.isEmpty {
                        Picker("", selection: $goalMilestone) {
                            Text("No milestone").tag(0)
                            ForEach(milestones) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden().frame(maxWidth: 220)
                    }
                    Spacer()
                    Button("Add goal") {
                        let (title, done, phase, milestone) = (goalTitle, goalDoneWhen, goalPhase, goalMilestone)
                        goalTitle = ""; goalDoneWhen = ""
                        model.perform {
                            try await $0.createGoal(projectID: entry.id, title: title, doneWhen: done, phase: phase,
                                                    milestoneID: milestone == 0 ? nil : milestone)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(goalTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func milestoneHeader(_ milestone: HubMilestone, number: Int) -> some View {
        let done = milestone.status == "done"
        return HStack(spacing: 10) {
            Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(done ? p.onAccent : p.text)
                .frame(width: 20, height: 20)
                .background(Circle().fill(done ? p.good : (milestone.status == "in_play" ? p.accent2.opacity(0.35) : p.surfaceRaised)))
            Text(milestone.title).font(DS.Font.body.weight(.semibold)).foregroundStyle(done ? p.textMuted : p.text)
                .strikethrough(done, color: p.textFaint)
            Spacer()
            Menu {
                Button("Not started") { changeMilestone(milestone, ["status": "not_started"]) }.disabled(milestone.status == "not_started")
                Button("In play") { changeMilestone(milestone, ["status": "in_play"]) }.disabled(milestone.status == "in_play")
                Button("Done") { changeMilestone(milestone, ["status": "done"]) }.disabled(done)
            } label: {
                MainTag(text: done ? "Done" : (milestone.status == "in_play" ? "In play" : "Not started"),
                        color: done ? p.good : (milestone.status == "in_play" ? p.accent2 : p.textMuted))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("Move up") { moveMilestone(milestone, by: -1) }.disabled(number == 1)
                Button("Move down") { moveMilestone(milestone, by: 1) }.disabled(number == milestones.count)
                Button("Rename…") { renameText = milestone.title; renamingMilestone = milestone }
                Divider()
                Button("Delete", role: .destructive) { model.perform { try await $0.deleteMilestone(id: milestone.id) } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Deleting a milestone keeps its goals")
        }
    }

    private func goalRow(_ goal: HubGoal) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.title).font(DS.Font.bodySmall.weight(.semibold))
                if !goal.doneWhen.isEmpty {
                    Text("Done when: \(goal.doneWhen)").font(DS.Font.micro).foregroundStyle(p.textMuted)
                }
                if !goal.proof.isEmpty { Text("Seen: \(goal.proof)").font(DS.Font.micro).foregroundStyle(p.good) }
            }
            Spacer()
            MainTag(text: goal.phase.capitalized, color: p.textMuted)
            GoalStatusTag(status: goal.status)
            Menu {
                ForEach(["now", "next", "later"], id: \.self) { phase in
                    Button("Move to \(phase.capitalized)") { change(goal, ["phase": phase]) }.disabled(goal.phase == phase)
                }
                if !milestones.isEmpty {
                    Divider()
                    ForEach(milestones) { milestone in
                        Button("Put under: \(milestone.title)") { change(goal, ["milestone_id": milestone.id]) }
                            .disabled(goal.milestoneID == milestone.id)
                    }
                    Button("Take out of its milestone") { change(goal, ["milestone_id": 0]) }.disabled(goal.milestoneID == nil)
                }
                Divider()
                if goal.status == "proposed" { Button("Commit to it") { change(goal, ["status": "committed"]) } }
                if goal.status != "verified" { Button("Mark verified…") { proof = ""; verifying = goal } }
                if goal.status == "verified" { Button("Reopen") { change(goal, ["status": "committed"]) } }
                Divider()
                Button("Delete", role: .destructive) { model.perform { try await $0.deleteGoal(id: goal.id) } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func addMilestone() {
        let title = milestoneTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        milestoneTitle = ""
        model.perform { try await $0.createMilestone(projectID: entry.id, title: title) }
    }

    private func changeMilestone(_ milestone: HubMilestone, _ changes: [String: Any]) {
        model.perform { try await $0.updateMilestone(id: milestone.id, changes) }
    }

    private func moveMilestone(_ milestone: HubMilestone, by offset: Int) {
        var ids = milestones.map(\.id)
        guard let from = ids.firstIndex(of: milestone.id), ids.indices.contains(from + offset) else { return }
        ids.swapAt(from, from + offset)
        model.perform { try await $0.reorderMilestones(projectID: entry.id, ids: ids) }
    }

    private func fromNotes(_ notes: [HubProgressProject.Note]) -> some View {
        WLGroup(title: "From your notes", subtitle: "Things the journal says are in progress. Make one a goal if it is worth finishing.", icon: "lightbulb") {
            ForEach(notes) { note in
                HStack(alignment: .top) {
                    Text(note.text).font(DS.Font.bodySmall).foregroundStyle(p.text)
                    Spacer()
                    Button("Make this a goal") {
                        model.perform { try await $0.createGoal(projectID: entry.id, title: note.text, doneWhen: "", phase: "now", memoryID: note.id) }
                    }
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
                Button("Mark verified") { change(goal, ["status": "verified", "proof": proof]); verifying = nil }
                    .buttonStyle(PrimaryButtonStyle()).disabled(proof.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 460).background(p.background)
    }

    private func change(_ goal: HubGoal, _ changes: [String: Any]) {
        model.perform { try await $0.updateGoal(id: goal.id, changes) }
    }

    // MARK: Logbook

    private var logbookGroup: some View {
        WLGroup(title: "Logbook", subtitle: "What each session did, newest first. Open one to read it.", icon: "book") {
            if logbook.isEmpty && sessions.isEmpty {
                Text("Nothing saved yet. It fills in after the first /wolfhowl.").font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            }
            let rows = logRows
            ForEach(showAllSessions ? rows : Array(rows.prefix(8)), id: \.chat.id) { row in
                if row.chat.id != rows.first?.chat.id { WLDivider() }
                Button { reading = row.chat } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.chat.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                            if !row.summary.isEmpty {
                                Text(row.summary).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            if let howl = howls[row.chat.id] {
                                Text([howl.deviceName.map { "from \($0)" }, howl.gitCommit.map { "commit \($0.prefix(8))" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(DS.Font.micro.monospaced()).foregroundStyle(p.textFaint)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(HubDate.format(row.chat.when)).font(DS.Font.micro.monospacedDigit()).foregroundStyle(p.textFaint)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.textFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if rows.count > 8 {
                Button(showAllSessions ? "Show fewer" : "Show all \(rows.count) sessions") { showAllSessions.toggle() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    /// Sessions joined with their logbook summary, newest first.
    private var logRows: [(chat: HubChat, summary: String)] {
        let summaries = Dictionary(logbook.map { ($0.chatID, $0.summary) }, uniquingKeysWith: { a, _ in a })
        return sessions
            .sorted { ($0.when ?? .distantPast) > ($1.when ?? .distantPast) }
            .map { (chat: $0, summary: summaries[$0.id] ?? "") }
    }

    // MARK: Memories

    @ViewBuilder
    private var memoriesGroups: some View {
        let groups: [(kind: MemoryKind, items: [HubMemory])] = MemoryKind.allCases.compactMap { kind in
            let items = memories.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
        WLGroup(title: "What the journal knows", subtitle: "\(memories.count) memories, by kind. Add one, or remove what is wrong.", icon: "brain") {
            HStack(alignment: .top, spacing: 8) {
                Picker("", selection: $memoryKind) {
                    ForEach(MemoryKind.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 150)
                TextField("Add a decision, constraint, problem or note", text: $memoryText).mainField()
                Button("Add") {
                    let (text, kind) = (memoryText, memoryKind)
                    memoryText = ""
                    Task {
                        do { try await store.hub.addMemory(projectID: entry.id, type: kind, content: text); await load(); await model.reload() }
                        catch { model.error = error.localizedDescription }
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).disabled(memoryText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        ForEach(groups, id: \.kind) { group in
            MemoryKindGroup(kind: group.kind, items: group.items) { memory in
                Task {
                    do { try await store.hub.deleteMemory(id: memory.id); await load(); await model.reload() }
                    catch { model.error = error.localizedDescription }
                }
            }
        }
    }

    // MARK: Brief and where it lives

    private var knowledge: some View {
        WLGroup(title: "Project brief", subtitle: briefSubtitle, icon: "doc.text") {
            if let text = brief?.briefMarkdown, !text.isEmpty {
                if showBrief {
                    Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button(showBrief ? "Hide brief" : "Show brief") { showBrief.toggle() }.buttonStyle(OutlineButtonStyle())
                    Button("Copy brief") { copy(text, "Brief copied.") }.buttonStyle(OutlineButtonStyle())
                    Button("Refresh brief") { refreshBrief() }.buttonStyle(OutlineButtonStyle())
                }
            } else {
                Text("No brief yet.").font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                Button("Build brief") { refreshBrief() }.buttonStyle(SecondaryButtonStyle())
            }
            if !prompts.isEmpty {
                WLDivider()
                WLEyebrow("Build prompts handed out")
                ForEach(prompts) { saved in
                    HStack {
                        Text(saved.title).font(DS.Font.bodySmall).lineLimit(1)
                        Spacer()
                        Text(HubDate.format(saved.createdAt)).font(DS.Font.micro).foregroundStyle(p.textFaint)
                        Button("Copy") { copy(saved.body, "Build prompt copied.") }.buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
    }

    private var briefSubtitle: String {
        var parts = ["What an agent is given when it picks this project up."]
        if let when = brief?.briefUpdatedAt { parts.append("Updated \(HubDate.format(when)).") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var whereItLives: some View {
        if !folders.isEmpty || entry.project.slug != nil {
            WLGroup(title: "Where it lives", icon: "folder") {
                if !entry.project.tags.isEmpty {
                    HStack(spacing: 6) {
                        Text("Topics").font(DS.Font.micro).foregroundStyle(p.textMuted)
                        ForEach(entry.project.tags, id: \.self) { MainTag(text: $0, color: p.textMuted) }
                    }
                }
                if let slug = entry.project.slug {
                    HStack { Text("Slug").foregroundStyle(p.textMuted); Text(slug).textSelection(.enabled) }.font(DS.Font.micro.monospaced())
                }
                ForEach(folders) { folder in
                    HStack(spacing: 8) {
                        Text(folder.path).font(DS.Font.micro.monospaced()).foregroundStyle(p.text)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        MainTag(text: folder.kind == "compose" ? "Compose stack" : "Folder", color: p.textMuted)
                        if let device = folder.deviceName { Text(device).font(DS.Font.micro).foregroundStyle(p.textFaint) }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func copy(_ value: String, _ message: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        notice = message
    }

    private func refreshBrief() {
        notice = "Rebuilding the brief…"
        Task {
            do { try await store.hub.refreshBrief(projectID: entry.id); await load(); notice = "Brief rebuilt." }
            catch { model.error = error.localizedDescription; notice = nil }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let hub = store.hub
        async let ms = try? hub.memories(projectID: entry.id)
        async let lb = try? hub.logbook(projectID: entry.id)
        async let ss = try? hub.allSessions(projectID: entry.id)
        async let fs = try? hub.folders(projectID: entry.id)
        async let bp = try? hub.buildPrompts(projectID: entry.id)
        async let br = try? hub.brief(projectKey: entry.project.key)
        let (m, l, s, f, b, r) = await (ms, lb, ss, fs, bp, br)
        memories = m ?? memories
        logbook = l ?? logbook
        sessions = s ?? sessions
        folders = f ?? folders
        prompts = b ?? prompts
        brief = r ?? brief
        star = (try? await hub.northStar(projectID: entry.id)) ?? star
        let broadcast = (try? await hub.howls(projectID: entry.id)) ?? []
        howls = Dictionary(broadcast.compactMap { h in h.chatID.map { ($0, h) } }, uniquingKeysWith: { a, _ in a })
        if let slug = entry.project.slug {
            let found = (try? await hub.relatedProjects(slug: slug)) ?? []
            related = found.filter { $0.id != entry.id && model.entry($0.id) != nil }
        }
    }
}

private struct MemoryKindGroup: View {
    @Environment(\.palette) private var p
    let kind: MemoryKind
    let items: [HubMemory]
    let remove: (HubMemory) -> Void
    @State private var expanded = false

    var body: some View {
        WLGroup(title: kind.label, subtitle: "\(items.count) \(items.count == 1 ? "memory" : "memories")", icon: kind.symbol) {
            ForEach(expanded ? items : Array(items.prefix(5))) { memory in
                if memory.id != items.first?.id { WLDivider() }
                HStack(alignment: .top) {
                    Text(memory.content).font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Button { remove(memory) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(p.textFaint).help("Remove this memory")
                }
            }
            if items.count > 5 {
                Button(expanded ? "Show fewer" : "Show all \(items.count)") { expanded.toggle() }.buttonStyle(OutlineButtonStyle())
            }
        }
    }
}

/// Read a saved session without leaving the app.
struct SessionReader: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let chatID: Int
    let title: String
    let when: String?
    @State private var messages: [HubMessage] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    WLEyebrow("Session · \(HubDate.format(when))")
                    Text(title).font(DS.Font.section).foregroundStyle(p.text).lineLimit(2)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if loading { ProgressView("Loading the conversation…") }
                    if let error { WLStatusPill(text: error, kind: .bad) }
                    if !loading && messages.isEmpty && error == nil {
                        Text("This session was saved as a summary only; there is no transcript.")
                            .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                    }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            WLEyebrow(message.role == "user" ? "You" : "Agent", color: message.role == "user" ? p.accent : p.textMuted)
                            Text(message.content).font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(message.role == "user" ? p.surfaceRaised : p.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 680)
        .background(p.background)
        .task {
            do { messages = try await store.hub.messages(chatID: chatID) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct ProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    @State var name: String
    @State var description: String
    let save: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit project").font(DS.Font.section)
            TextField("Name", text: $name).mainField()
            TextField("What is this project?", text: $description, axis: .vertical).lineLimit(3...6).mainField()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button("Save") { save(name.trimmingCharacters(in: .whitespaces), description); dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 480).background(p.background)
    }
}


/// Set or change a project's North Star. Changing it is expected, so the form asks what changed.
private struct NorthStarEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let current: String
    let suggestion: String
    let save: (String, String) -> Void
    @State private var text = ""
    @State private var why = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WLEyebrow("North Star", color: p.accent2)
            Text(current.isEmpty ? "Where is this heading?" : "Where is this heading now?").font(DS.Font.section)
            Text("The end result you are after, in a sentence or two. Not a task list.")
                .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            TextField("For example: an automated pipeline that makes and posts a video every week", text: $text, axis: .vertical)
                .lineLimit(3...6).mainField()
            if current.isEmpty && !suggestion.isEmpty && text.isEmpty {
                Button("Start from the project description") { text = suggestion }.buttonStyle(OutlineButtonStyle())
            }
            if !current.isEmpty {
                Text("What changed your mind? (optional)").font(DS.Font.bodySmall)
                TextField("What you learned that moved it", text: $why, axis: .vertical).lineLimit(2...4).mainField()
            }
            HStack {
                if !current.isEmpty {
                    Button("Clear it") { save("", why); dismiss() }.buttonStyle(OutlineButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button(current.isEmpty ? "Set North Star" : "Change North Star") {
                    save(text.trimmingCharacters(in: .whitespacesAndNewlines), why); dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == current)
            }
        }
        .padding(24).frame(width: 540).background(p.background)
        .onAppear { text = current }
    }
}
