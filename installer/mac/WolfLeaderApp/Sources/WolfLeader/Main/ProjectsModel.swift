import SwiftUI

/// One project as every Projects view sees it: the hub's record plus its progress.
struct ProjectEntry: Identifiable, Hashable {
    var project: HubProject
    var progress: HubProgressProject?

    var id: Int { project.id }
    var name: String { project.name }
    var openGoals: [HubGoal] { progress?.openGoals ?? [] }
    var verifiedCount: Int { progress?.verifiedCount ?? 0 }
    var openProblems: Int { progress?.openProblems.count ?? 0 }
    var whereItStands: String { progress?.whereItStands ?? project.description ?? "" }
    var lastWorked: String? { progress?.lastSession ?? project.updatedAt }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let haystack = [project.name, project.slug, project.description, project.owner, progress?.whereItStands,
                        progress?.nextStep?.text] + (progress?.goals.map { Optional($0.title) } ?? [])
        return haystack.compactMap { $0?.lowercased() }.contains { $0.contains(q) }
    }
}

/// The single source for the Projects section. List, Board, Progress and a project's own page all
/// read and change this, so a move on the board or a new goal shows up everywhere at once.
@MainActor
final class ProjectsModel: ObservableObject {
    @Published var entries: [ProjectEntry] = []
    @Published var columns: [HubKanbanColumn] = []
    @Published var unfiled: [HubUnfiledSession] = []
    @Published var owners: [String] = []
    @Published var loading = true
    @Published var error: String?
    @Published var notice: String?

    private var hub: HubClient?
    private var triedAutoFiling = false

    func load(_ hub: HubClient) async {
        self.hub = hub
        loading = true
        defer { loading = false }
        do {
            async let projects = hub.projects()
            async let columns = hub.kanbanColumns()
            let (loadedProjects, loadedColumns) = try await (projects, columns)
            // Progress and unfiled sessions are newer hub features; an older hub still gets list and board.
            let progress = (try? await hub.progress())?.projects ?? []
            let byID = Dictionary(progress.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.columns = loadedColumns
            entries = loadedProjects.map { ProjectEntry(project: $0, progress: byID[$0.id]) }
            unfiled = (try? await hub.unfiledSessions()) ?? []
            owners = (try? await hub.owners()) ?? owners
            // Let the hub file what clearly belongs somewhere, once per launch, so nobody sorts by hand.
            if !unfiled.isEmpty && !triedAutoFiling {
                triedAutoFiling = true
                if let filed = try? await hub.autoFileSessions(), filed > 0 {
                    notice = "Filed \(filed) loose session\(filed == 1 ? "" : "s") into the project \(filed == 1 ? "it belongs" : "they belong") to."
                    unfiled = (try? await hub.unfiledSessions()) ?? []
                }
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func reload() async {
        if let hub { await load(hub) }
    }

    func entry(_ id: Int) -> ProjectEntry? { entries.first { $0.id == id } }

    func status(of entry: ProjectEntry) -> String { entry.project.kanbanStatus(in: columns) }

    func statusLabel(of entry: ProjectEntry) -> String {
        let status = status(of: entry)
        return columns.first { $0.status == status }?.label ?? status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Run a change against the hub, then refresh so every view agrees.
    func perform(_ done: String? = nil, _ work: @escaping (HubClient) async throws -> Void) {
        guard let hub else { return }
        Task {
            do {
                try await work(hub)
                error = nil
                if let done { notice = done }
                await load(hub)
            } catch { self.error = error.localizedDescription }
        }
    }

    func setOwner(_ entry: ProjectEntry, _ owner: String) {
        perform { try await $0.setOwner(projectID: entry.id, owner: owner) }
    }

    /// What deserves attention now: a goal marked "now", or an in-progress project touched recently.
    func isNow(_ entry: ProjectEntry) -> Bool {
        if entry.openGoals.contains(where: { $0.phase == "now" }) { return true }
        guard status(of: entry) == "in_progress", let last = HubDate.parse(entry.lastWorked) else { return false }
        return last > Date().addingTimeInterval(-14 * 86_400)
    }

    /// Lined up but not being worked: later goals, or in progress but gone quiet.
    func isNext(_ entry: ProjectEntry) -> Bool {
        guard !isNow(entry), status(of: entry) != "done" else { return false }
        return !entry.openGoals.isEmpty || status(of: entry) == "in_progress"
    }

    func move(_ entry: ProjectEntry, to status: String) {
        perform { try await $0.updateProjectStatus(id: entry.id, status: status) }
    }
}
