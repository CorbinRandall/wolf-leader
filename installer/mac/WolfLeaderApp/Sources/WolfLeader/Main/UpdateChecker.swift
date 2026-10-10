import AppKit
import Combine
import Foundation

/// owner/repo parsed from https://github.com/owner/repo(.git), git@github.com:owner/repo(.git)
/// or ssh://git@github.com/owner/repo.
struct GitHubRepo: Equatable {
    let owner: String
    let name: String

    var web: URL? { URL(string: "https://github.com/\(owner)/\(name)") }

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        guard !s.isEmpty else { return nil }

        let path: String
        if s.hasPrefix("git@") {
            guard let colon = s.firstIndex(of: ":") else { return nil }
            path = String(s[s.index(after: colon)...])
        } else {
            let withScheme = s.contains("://") ? s : "https://" + s
            guard let url = URL(string: withScheme), url.host != nil else { return nil }
            path = url.path
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = parts[0]
        name = parts[1]
    }
}

enum UpdateError: LocalizedError {
    case notConfigured, badURL, http(Int), rateLimited, badResponse, step(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No GitHub repository is set for update checks."
        case .badURL: return "The repository address isn't a GitHub URL."
        case .http(let code): return "GitHub answered with HTTP \(code)."
        case .rateLimited: return "GitHub's hourly limit for update checks was reached. Try again later."
        case .badResponse: return "GitHub sent something unexpected."
        case .step(let why): return why
        }
    }
}

/// Runs a command off the main thread and returns its exit code and combined output.
enum MainProcess {
    static func run(_ executable: String, _ args: [String], stdinNull: Bool = true) async -> (code: Int32, output: String) {
        let result = await Task.detached { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            if stdinNull { process.standardInput = FileHandle.nullDevice }
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        return (code: result.0, output: result.1)
    }
}

/// Checks GitHub for commits newer than this build, and refreshes the Cursor / Claude Code skills
/// and rule from the latest branch by running its installer/mac/install.sh --mode update.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Commit: Identifiable, Hashable {
        let sha: String
        let title: String
        let author: String
        let date: Date?
        var id: String { sha }
        var shortSHA: String { String(sha.prefix(7)) }
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Int)
        /// The build has no commit recorded (or GitHub doesn't know it): only the branch head is shown.
        case branchHead
        case notConfigured
        case failed(String)
    }

    static let interval: TimeInterval = 6 * 60 * 60

    @Published private(set) var status: Status = .idle
    @Published private(set) var commits: [Commit] = []
    @Published private(set) var lastChecked: Date? = nil
    /// Downloading and unpacking before the installer starts.
    @Published private(set) var preparing = false
    @Published private(set) var updateNote: String? = nil
    @Published private(set) var updateSucceeded: Bool? = nil
    /// Branch names on GitHub for the branch picker (always includes the current branch).
    @Published private(set) var branches: [String] = []

    let runner = InstallRunner()

    private weak var store: ConfigStore?
    private var loop: Task<Void, Never>?
    private var exitWatch: AnyCancellable?
    private var runnerWatch: AnyCancellable?
    private var awaitingInstall = false
    private var pending: (work: URL, result: URL, backup: URL, head: String?)?

    var hasUpdate: Bool {
        if case .available(let n) = status { return n > 0 }
        return false
    }

    var repo: GitHubRepo? {
        let configured = store?.config.repoURL ?? ""
        return GitHubRepo(configured.isEmpty ? BuildInfo.repoURL : configured)
    }

    var branch: String {
        let b = (store?.config.branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? BuildInfo.branch : b
    }

    var releasesURL: URL? { repo?.web?.appendingPathComponent("releases") }

    var busy: Bool { preparing || runner.running }

    /// Call once from the main window; checks now and every 6 hours.
    func start(store: ConfigStore) {
        self.store = store
        if exitWatch == nil {
            exitWatch = runner.$exitCode.sink { [weak self] code in
                guard let code, let self else { return }
                Task { @MainActor in self.installFinished(code) }
            }
            runnerWatch = runner.objectWillChange.sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.objectWillChange.send() }
            }
        }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(UpdateChecker.interval))
                if self == nil { return }
            }
        }
    }

    // MARK: Checking

    func check() async {
        guard let repo else {
            status = .notConfigured
            commits = []
            return
        }
        if status == .checking { return }
        status = .checking
        let branch = self.branch
        let api = "https://api.github.com/repos/\(repo.owner)/\(repo.name)"
        do {
            // Last commit this Mac updated to, else the commit the app was built from.
            if let sha = Self.baseline(repo: repo, branch: branch) ?? BuildInfo.gitSHA {
                do {
                    let json = try await Self.fetchJSON("\(api)/compare/\(sha)...\(Self.pathEscape(branch))")
                    guard let dict = json as? [String: Any] else { throw UpdateError.badResponse }
                    let ahead = (dict["ahead_by"] as? Int) ?? 0
                    let list = (dict["commits"] as? [[String: Any]]) ?? []
                    commits = ahead > 0 ? Array(list.compactMap { Self.commit(from: $0) }.reversed()) : []
                    status = ahead > 0 ? .available(ahead) : .upToDate
                } catch UpdateError.http(404) {
                    try await loadBranchHead(api: api, branch: branch)
                }
            } else {
                // No git info in this build (zip or Xcode): start counting from today's head.
                try await loadBranchHead(api: api, branch: branch)
                if let head = commits.first?.sha { Self.setBaseline(head, repo: repo, branch: branch) }
                commits = []
                status = .upToDate
            }
            lastChecked = Date()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: Branch picker

    func loadBranches() async {
        guard let repo else { branches = []; return }
        let api = "https://api.github.com/repos/\(repo.owner)/\(repo.name)"
        var names: [String] = []
        if let list = try? await Self.fetchJSON("\(api)/branches?per_page=100") as? [[String: Any]] {
            names = list.compactMap { $0["name"] as? String }
        }
        if !names.contains(branch) { names.insert(branch, at: 0) }
        branches = names.sorted { a, b in
            if a == "main" { return true }
            if b == "main" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    func setBranch(_ name: String) {
        guard let store, name != branch else { return }
        store.config.branch = name
        store.save()
        commits = []
        status = .idle
        Task { await check() }
    }

    nonisolated private static func baselineKey(repo: GitHubRepo, branch: String) -> String {
        "wl.updateBaseline.\(repo.owner)/\(repo.name)@\(branch)"
    }

    nonisolated private static func baseline(repo: GitHubRepo, branch: String) -> String? {
        UserDefaults.standard.string(forKey: baselineKey(repo: repo, branch: branch))
    }

    nonisolated private static func setBaseline(_ sha: String, repo: GitHubRepo, branch: String) {
        UserDefaults.standard.set(sha, forKey: baselineKey(repo: repo, branch: branch))
    }

    private static func headSHA(api: String, branch: String) async throws -> String? {
        let enc = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? branch
        let json = try await fetchJSON("\(api)/commits?sha=\(enc)&per_page=1")
        return (json as? [[String: Any]])?.first?["sha"] as? String
    }

    private func loadBranchHead(api: String, branch: String) async throws {
        let enc = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? branch
        let json = try await Self.fetchJSON("\(api)/commits?sha=\(enc)&per_page=1")
        guard let list = json as? [[String: Any]] else { throw UpdateError.badResponse }
        commits = list.compactMap { Self.commit(from: $0) }
        status = .branchHead
    }

    private static func fetchJSON(_ address: String) async throws -> Any {
        guard let url = URL(string: address) else { throw UpdateError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WolfLeader-mac/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.rateLimited }
            throw UpdateError.http(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    nonisolated private static func commit(from d: [String: Any]) -> Commit? {
        guard let sha = d["sha"] as? String else { return nil }
        let info = d["commit"] as? [String: Any]
        let message = (info?["message"] as? String) ?? ""
        let title = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let author = info?["author"] as? [String: Any]
        let login = (d["author"] as? [String: Any])?["login"] as? String
        let name = (author?["name"] as? String) ?? login ?? "unknown"
        let date = HubDate.parse(author?["date"] as? String)
        return Commit(sha: sha, title: title, author: name, date: date)
    }

    // MARK: Update skills & rule

    func updateSkills() async {
        guard let store else { return }
        guard let repo else {
            updateNote = UpdateError.notConfigured.localizedDescription
            updateSucceeded = false
            return
        }
        guard !busy else { return }
        preparing = true
        updateSucceeded = nil
        updateNote = "Downloading the latest files from GitHub…"
        defer { preparing = false }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("wolf-leader-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let head = try? await Self.headSHA(api: "https://api.github.com/repos/\(repo.owner)/\(repo.name)", branch: branch)
            guard let zipURL = URL(string: "https://codeload.github.com/\(repo.owner)/\(repo.name)/zip/refs/heads/\(Self.pathEscape(branch))") else {
                throw UpdateError.badURL
            }
            let (downloaded, resp) = try await URLSession.shared.download(from: zipURL)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.http(http.statusCode)
            }
            let zip = work.appendingPathComponent("source.zip")
            try fm.moveItem(at: downloaded, to: zip)

            updateNote = "Unpacking…"
            let src = work.appendingPathComponent("src", isDirectory: true)
            let unzip = await MainProcess.run("/usr/bin/ditto", ["-x", "-k", zip.path, src.path])
            guard unzip.code == 0 else {
                throw UpdateError.step("Couldn't unpack the download. \(unzip.output)")
            }
            guard let root = Self.findCheckout(in: src) else {
                throw UpdateError.step("The download doesn't contain installer/mac/install.sh.")
            }
            let script = root.appendingPathComponent("installer/mac/install.sh")
            for name in ["install.sh", "ini.sh"] {
                try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: root.appendingPathComponent("installer/mac/\(name)").path)
            }

            let ini = work.appendingPathComponent("wolf-leader-setup.ini")
            try Self.answerFile(for: store.config).write(to: ini, atomically: true, encoding: .utf8)
            let result = work.appendingPathComponent("result.txt")
            let backup = Self.newBackupDir()

            var args = ["--mode", "update", "--toggles", "client", "--ini", ini.path,
                        "--result", result.path, "--backup-dir", backup.path]
            let git = Self.gitIdentity()
            if !git.name.isEmpty, !git.email.isEmpty {
                args += ["--git-name", git.name, "--git-email", git.email]
            }

            pending = (work: work, result: result, backup: backup, head: head)
            awaitingInstall = true
            updateNote = "Installing the new skills and rule…"
            runner.run(script: script, args: args, env: [:])
        } catch {
            try? fm.removeItem(at: work)
            updateNote = error.localizedDescription
            updateSucceeded = false
        }
    }

    private func installFinished(_ code: Int32) {
        guard awaitingInstall, let job = pending else { return }
        awaitingInstall = false
        pending = nil

        let fields = Self.readResult(job.result)
        let backupPath = fields["backup_dir"] ?? job.backup.path
        if let store, FileManager.default.fileExists(atPath: backupPath + "/restore.sh") {
            store.config.lastBackupPath = backupPath
            store.save()
        }
        if code == 0 && fields["status"] != "fail" {
            updateSucceeded = true
            if let head = job.head, let repo {
                Self.setBaseline(head, repo: repo, branch: branch)
                commits = []
                status = .upToDate
            }
            let warnings = Int(fields["warnings"] ?? "0") ?? 0
            updateNote = "Skills and rule are up to date. Restart Cursor and Claude Code to load them."
                + (warnings > 0 ? " Finished with \(warnings) warning\(warnings == 1 ? "" : "s"); see the log." : "")
        } else {
            updateSucceeded = false
            updateNote = "The update stopped" + (fields["reason"].map { ": \($0)" } ?? ".") + " See the log below."
        }
        try? FileManager.default.removeItem(at: job.work)
    }

    // MARK: Helpers

    nonisolated private static func findCheckout(in dir: URL) -> URL? {
        let fm = FileManager.default
        let marker = "installer/mac/install.sh"
        if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) { return dir }
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return children.first { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    nonisolated private static func newBackupDir() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let base = ConfigStore.supportDir.appendingPathComponent("backup-\(f.string(from: Date()))", isDirectory: true)
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: base.path + "-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// `key=value` lines written by install.sh --result (first value wins).
    nonisolated private static func readResult(_ file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            if out[key] == nil { out[key] = String(line[line.index(after: eq)...]) }
        }
        return out
    }

    /// git user.name / user.email from ~/.gitconfig (read directly so a Mac without Command Line
    /// Tools never gets Apple's "install developer tools" prompt).
    nonisolated static func gitIdentity() -> (name: String, email: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var name = ""
        var email = ""
        for file in [home.appendingPathComponent(".gitconfig"), home.appendingPathComponent(".config/git/config")] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var section = ""
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
                    continue
                }
                guard section == "user", let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                if key == "name", name.isEmpty { name = value }
                if key == "email", email.isEmpty { email = value }
            }
        }
        return (name, email)
    }

    /// Minimal valid wolf-leader-setup.ini (installer/CONFIG.md) for a client-only update.
    static func answerFile(for config: WolfConfig) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        func exists(_ paths: String...) -> String {
            paths.contains { fm.fileExists(atPath: $0) } ? "yes" : "no"
        }
        let obsidian = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
            || fm.fileExists(atPath: "/Applications/Obsidian.app")

        var lines = [
            "[wolf]",
            "format=1",
            "os=mac",
            "hub_url=\(iniValue(config.hubURL))",
            "mcp_url=\(iniValue(config.mcpURL))",
            "timezone=\(TimeZone.current.identifier)",
            "device_name=\(deviceLabel(config.deviceName))",
            "",
            "[detected]",
            "git=\(exists("/Library/Developer/CommandLineTools/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git", "/Applications/Xcode.app"))",
            "python=\(exists("/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Frameworks/Python.framework", "/Library/Developer/CommandLineTools/usr/bin/python3"))",
            "python_version=NONE",
            "docker=\(exists("/Applications/Docker.app"))",
            "obsidian=\(obsidian ? "yes" : "no")",
            "cursor=\(exists("/Applications/Cursor.app", home + "/Applications/Cursor.app", home + "/.cursor"))",
            "claude_code=\(exists(home + "/.claude"))",
            "wolf_client=\(exists(home + "/.cursor/rules/wolf-leader-hub.mdc", home + "/.cursor/skills/save"))",
            "",
            "[backup]",
            "done=no",
            "path=NONE",
            "files=0",
        ]
        lines.append("")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func iniValue(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    /// device_name must be 1-32 letters, digits or hyphens.
    nonisolated static func deviceLabel(_ raw: String) -> String {
        var out = ""
        var lastHyphen = false
        for ch in raw.unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch)
                lastHyphen = false
            } else if !lastHyphen, !out.isEmpty {
                out.append("-")
                lastHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 32 { out = String(out.prefix(32)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "Mac" : out
    }
}
