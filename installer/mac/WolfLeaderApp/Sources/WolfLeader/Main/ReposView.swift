import AppKit
import SwiftUI

/// Library → Repos: which projects are under version control, which still need a repo, folders that
/// several projects share, the notes vaults, and the last off-site copy.
struct ReposLibraryView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @State private var response: HubReposResponse?
    @State private var loading = true
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        WLPageHeader(title: "Repos", subtitle: "Where each project's files are versioned, and what is not protected yet.") {
            Button("Refresh") { Task { await load() } }.buttonStyle(OutlineButtonStyle())
        }
        if let notice { WLStatusPill(text: notice, kind: .good) }
        if loading && response == nil {
            ProgressView("Checking repos…")
        } else if let error, response == nil {
            MainNotice(symbol: "arrow.triangle.branch", title: "Repos unavailable", message: error)
        } else if let response {
            if let error { WLStatusPill(text: error, kind: .bad) }
            summary(response)
            needsRepo(response.projects.filter { $0.state == "needs_repo" })
            sharedFolders(response.sharedFolders)
            versioned(response.projects.filter { $0.state == "versioned" })
            notes(response)
            offsite(response)
        }
        Color.clear.frame(height: 0).task(id: store.config.hubURL) { await load() }
    }

    // MARK: Sections

    private func summary(_ r: HubReposResponse) -> some View {
        let count = { (state: String) in r.projects.filter { $0.state == state }.count }
        return HStack(spacing: 8) {
            WLStatusPill(text: "\(count("versioned")) versioned", kind: .good)
            WLStatusPill(text: "\(count("needs_repo")) need a repo", kind: count("needs_repo") > 0 ? .warn : .neutral)
            WLStatusPill(text: "\(r.sharedFolders.count) shared folders", kind: r.sharedFolders.isEmpty ? .neutral : .warn)
            WLStatusPill(text: "\(count("knowledge_only")) notes only", kind: .neutral)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func needsRepo(_ items: [HubRepoProject]) -> some View {
        if !items.isEmpty {
            WLGroup(title: "Needs a repo", subtitle: "These projects have files but no version history. Copy a prompt and give it to an agent on the machine that holds the folder.", icon: "exclamationmark.triangle") {
                ForEach(items) { item in
                    if item.id != items.first?.id { WLDivider() }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(DS.Font.bodySmall.weight(.semibold))
                            Text(item.why ?? "No git repo").font(DS.Font.micro).foregroundStyle(p.textMuted)
                            if let folder = item.folder {
                                Text(folder).font(DS.Font.micro.monospaced()).foregroundStyle(p.textMuted)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Button("Copy setup prompt") { copy(item.setupPrompt ?? "", "Setup prompt for \(item.name) copied.") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sharedFolders(_ folders: [HubSharedFolder]) -> some View {
        if !folders.isEmpty {
            WLGroup(title: "Shared folders", subtitle: "Several projects use these folders, so a save from one cannot pick a project and has to ask. Unlink the projects that do not live there.", icon: "folder.badge.questionmark") {
                ForEach(folders) { folder in
                    if folder.id != folders.first?.id { WLDivider() }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(folder.path).font(DS.Font.bodySmall.weight(.semibold).monospaced())
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        ForEach(folder.projects) { project in
                            HStack {
                                Text(project.name).font(DS.Font.bodySmall)
                                Spacer()
                                Button("Unlink") { unlink(project, from: folder) }
                                    .buttonStyle(OutlineButtonStyle()).disabled(busy)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func versioned(_ items: [HubRepoProject]) -> some View {
        WLGroup(title: "Versioned projects", subtitle: "\(items.count) with a git repo, as of each project's last save.", icon: "arrow.triangle.branch") {
            if items.isEmpty { Text("No project has a repo yet.").foregroundStyle(p.textMuted) }
            ForEach(items) { item in
                if item.id != items.first?.id { WLDivider() }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(DS.Font.bodySmall.weight(.semibold))
                        Text(commitLine(item)).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2)
                        if let remote = item.remote {
                            Text(remote).font(DS.Font.micro.monospaced()).foregroundStyle(p.textMuted)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    if let dirty = item.dirtyFiles, dirty > 0 {
                        WLStatusPill(text: "\(dirty) uncommitted", kind: .warn)
                    } else if item.dirtyFiles != nil {
                        WLStatusPill(text: "Clean", kind: .good)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notes(_ r: HubReposResponse) -> some View {
        let schedule = r.notesScheduleMinutes > 0
            ? "The hub commits changed notes every \(Int(r.notesScheduleMinutes)) minutes."
            : "Scheduled commits are turned off on this hub."
        WLGroup(title: "Notes", subtitle: schedule, icon: "note.text") {
            if r.notes.isEmpty { Text("No notes vault is under git on this hub.").foregroundStyle(p.textMuted) }
            ForEach(r.notes) { repo in
                if repo.id != r.notes.first?.id { WLDivider() }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.owner).font(DS.Font.bodySmall.weight(.semibold))
                        Text(repo.lastCommitAt.map { "Last commit \(HubDate.format($0))" } ?? "No commits yet")
                            .font(DS.Font.micro).foregroundStyle(p.textMuted)
                    }
                    Spacer()
                    WLStatusPill(text: repo.uncommitted > 0 ? "\(repo.uncommitted) uncommitted" : "Up to date",
                                 kind: repo.uncommitted > 0 ? .warn : .good)
                }
            }
            if r.notes.contains(where: { $0.uncommitted > 0 }) {
                Button("Commit notes now") { commitNotes() }.buttonStyle(SecondaryButtonStyle()).disabled(busy)
            }
        }
    }

    @ViewBuilder
    private func offsite(_ r: HubReposResponse) -> some View {
        WLGroup(title: "Off-site copy", subtitle: "A second machine pulls every repo and the newest database backup once a day.", icon: "externaldrive.badge.icloud") {
            if let copy = r.offsite?.lastGood {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last copy \(HubDate.format(copy.createdAt))").font(DS.Font.bodySmall.weight(.semibold))
                        Text("\(copy.repos) repos\(copy.dumpName.map { " and \($0)" } ?? "") on \(copy.deviceName ?? "another machine")")
                            .font(DS.Font.micro).foregroundStyle(p.textMuted)
                        if let destination = copy.destination {
                            Text(destination).font(DS.Font.micro.monospaced()).foregroundStyle(p.textMuted).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    WLStatusPill(text: r.offsite?.stale == true ? "Over 2 days old" : "Current",
                                 kind: r.offsite?.stale == true ? .warn : .good)
                }
                if r.offsite?.lastFailed == true, let detail = r.offsite?.latest?.detail {
                    WLStatusPill(text: "Latest run failed: \(detail)", kind: .bad)
                }
            } else {
                Text("No off-site copy has been made. Everything lives on the hub server only.")
                    .font(DS.Font.bodySmall).foregroundStyle(p.text)
            }
            if !r.offsiteInstall.isEmpty {
                Text("To set one up, run this on the machine that should hold the copy. It needs SSH access to the hub server.")
                    .font(DS.Font.micro).foregroundStyle(p.textMuted)
                Button("Copy install command") { copy(r.offsiteInstall, "Install command copied.") }
                    .buttonStyle(r.offsite?.lastGood == nil ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(OutlineButtonStyle()))
            }
        }
    }

    // MARK: Actions

    private func commitLine(_ item: HubRepoProject) -> String {
        var parts: [String] = []
        if let sha = item.lastCommit { parts.append(String(sha.prefix(8))) }
        if let branch = item.branch { parts.append(branch) }
        if let subject = item.lastSubject { parts.append(subject) }
        if let device = item.deviceName { parts.append("from \(device)") }
        let when = HubDate.format(item.howledAt ?? item.lastCommitAt)
        if !when.isEmpty { parts.append(when) }
        return parts.isEmpty ? "No commit recorded yet" : parts.joined(separator: " · ")
    }

    private func copy(_ value: String, _ message: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        notice = message
    }

    private func unlink(_ project: HubSharedFolder.Member, from folder: HubSharedFolder) {
        let alert = NSAlert()
        alert.messageText = "Unlink \(project.name) from this folder?"
        alert.informativeText = "\(folder.path)\n\nThe project and everything saved in it stay. Saves from this folder will no longer be offered \(project.name)."
        alert.addButton(withTitle: "Unlink")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("Unlinked \(project.name).") { try await store.hub.unlinkFolder(projectID: project.id, path: folder.path) }
    }

    private func commitNotes() {
        run("Notes committed.") { try await store.hub.commitNotes() }
    }

    private func run(_ done: String, _ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await work()
                notice = done
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { response = try await store.hub.repos(); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// Lets one call site choose between two button styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
