import Foundation

enum SetupStep: String, Identifiable {
    case welcome, path, server, toggles, askAI, upgrade, passwords, git, review, install

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .path: return "Your setup"
        case .server: return "Set up your server"
        case .toggles: return "What to install"
        case .askAI: return "Ask your AI"
        case .upgrade: return "Upgrade old hub"
        case .passwords: return "Passwords"
        case .git: return "Git name"
        case .review: return "Review"
        case .install: return "Install"
        }
    }
}

struct SetupToggles {
    var client = true
    var shares = true
    var prereqs = true
    var obsidian = true
    var wiki = true
}

/// One `[shareN]` section from the validated answer file.
struct SetupShare: Identifiable, Hashable {
    /// share1 ... share5; install.sh reads passwords by this name.
    let section: String
    let url: String
    /// "NONE" for guest access.
    let user: String
    let askPassword: Bool
    let role: String

    var id: String { section }
    var isGuest: Bool { user == "NONE" }

    /// Same rule as install.sh: drop smb://, any user@, and everything after the first slash.
    var host: String {
        var rest = url
        if rest.lowercased().hasPrefix("smb://") { rest = String(rest.dropFirst(6)) }
        var hostPart = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
        if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
        return hostPart
    }
}

struct IniProblem: Identifiable, Sendable {
    let id = UUID()
    /// Line number in the pasted text, when the validator named one.
    let line: Int?
    let message: String
    /// The offending line as pasted.
    let text: String?
}

enum IniState {
    case empty
    case checking
    case valid
    case invalid([IniProblem])
    case unavailable(String)
}

enum HubCheckState: Equatable {
    case idle, checking, ok, failed(String)
}

struct InstallResult {
    var values: [String: String] = [:]
    var notes: [String] = []

    subscript(key: String) -> String? { values[key] }

    init() {}

    init(file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key == "note" {
                if !value.isEmpty { notes.append(value) }
            } else if values[key] == nil {
                values[key] = value
            }
        }
    }
}

enum InstallOutcome {
    case none
    case success(InstallResult)
    case failure(code: Int32, result: InstallResult)
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: SetupStep = .welcome
    /// Highest step index reached, so the rail can jump back but not ahead.
    @Published private(set) var furthest = 0

    @Published var path: SetupPath? {
        didSet {
            store?.config.setupPath = path
            if path != oldValue { serverCheck = .idle }
        }
    }
    @Published var toggles = SetupToggles()

    @Published var serverURL = "http://wolf.local:6971"
    @Published var serverCheck: HubCheckState = .idle

    @Published var iniText = "" {
        didSet { if iniText != oldValue { scheduleValidation() } }
    }
    @Published private(set) var iniState: IniState = .empty
    @Published private(set) var parsed: [String: String] = [:]
    @Published private(set) var shares: [SetupShare] = []

    /// Typed share passwords, keyed by section (share1...). Only ever kept in memory.
    @Published var passwords: [String: String] = [:]

    @Published var gitName = ""
    @Published var gitEmail = ""

    @Published var outcome: InstallOutcome = .none
    @Published var installError: String?

    private weak var store: ConfigStore?
    private var validateTask: Task<Void, Never>?
    private var workDir: URL?
    private var resultFile: URL?
    private var attached = false

    // MARK: setup

    func attach(_ store: ConfigStore) {
        self.store = store
        guard !attached else { return }
        attached = true
        path = store.config.setupPath
        if !store.config.hubURL.isEmpty { serverURL = store.config.hubURL }
        Task { [weak self] in
            let identity = await Task.detached { SetupSystem.gitIdentity() }.value
            guard let self else { return }
            if self.gitName.isEmpty { self.gitName = identity.name }
            if self.gitEmail.isEmpty { self.gitEmail = identity.email }
        }
    }

    // MARK: steps

    var steps: [SetupStep] {
        var s: [SetupStep] = [.welcome, .path]
        if path == .newOnServer { s.append(.server) }
        s += [.toggles, .askAI]
        if original != nil { s.append(.upgrade) }
        s += [.passwords, .git, .review, .install]
        return s
    }

    /// The original (SQLite) hub the AI reported in `[original]`, if any.
    var original: OriginalHub? {
        guard value("original", "found") == "yes" else { return nil }
        func v(_ k: String) -> String {
            let s = value("original", k)
            return s == "NONE" ? "" : s
        }
        return OriginalHub(location: v("where"), folder: v("folder"), sshTarget: v("ssh_target"),
                           sshPort: v("ssh_port"), sshKey: v("ssh_key"))
    }

    @Published private(set) var upgradeSucceeded: Bool?

    /// Script and arguments for the Upgrade step, or nil when it can't run from this Mac.
    func upgradeJob() -> (script: URL, args: [String])? {
        guard let hub = original, hub.canRun, let script = OriginalHub.script else { return nil }
        return (script, hub.args("upgrade", hubURL: value("wolf", "hub_url")))
    }

    func finishUpgrade(code: Int32) {
        upgradeSucceeded = code == 0
        guard code == 0, let store, var hub = original else { return }
        hub.upgraded = true
        store.config.original = hub
        store.save()
    }

    var askShares: [SetupShare] { shares.filter { $0.askPassword && !$0.isGuest } }

    func isSkipped(_ s: SetupStep) -> Bool {
        s == .passwords && isIniValid && askShares.isEmpty
    }

    var isIniValid: Bool {
        if case .valid = iniState { return true }
        return false
    }

    var gitValid: Bool {
        let email = gitEmail.trimmingCharacters(in: .whitespaces)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return !gitName.trimmingCharacters(in: .whitespaces).isEmpty
            && parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !email.contains(" ")
    }

    var canAdvance: Bool {
        switch step {
        case .welcome, .server, .toggles, .upgrade, .passwords, .review: return true
        case .path: return path != nil
        case .askAI: return isIniValid
        case .git: return gitValid
        case .install: return false
        }
    }

    var canGoBack: Bool {
        guard step != .welcome else { return false }
        return step != .install || isFailure
    }

    var isFailure: Bool {
        if case .failure = outcome { return true }
        return false
    }

    func index(of s: SetupStep) -> Int { steps.firstIndex(of: s) ?? 0 }

    func next() {
        let list = steps
        guard canAdvance, var i = list.firstIndex(of: step) else { return }
        if step == .askAI { applyAnswersToConfig() }
        repeat { i += 1 } while i < list.count && isSkipped(list[i])
        guard i < list.count else { return }
        step = list[i]
        furthest = max(furthest, i)
    }

    func back() {
        let list = steps
        guard var i = list.firstIndex(of: step) else { step = .welcome; return }
        repeat { i -= 1 } while i > 0 && isSkipped(list[i])
        step = list[max(i, 0)]
        if step == .review { outcome = .none }
    }

    func jump(to s: SetupStep) {
        guard step != .install || isFailure else { return }
        let i = index(of: s)
        guard i <= furthest, s != .install, !isSkipped(s) else { return }
        step = s
        outcome = .none
    }

    // MARK: toggles

    var togglesCSV: String {
        var t: [String] = []
        if toggles.client { t.append("client") }
        if toggles.shares { t.append("shares") }
        if toggles.prereqs { t.append("prereqs") }
        if toggles.obsidian { t.append("obsidian") }
        if toggles.wiki && path == .newOnThisMac { t.append("wiki") }
        return t.joined(separator: ",")
    }

    // MARK: server check

    func checkServer() {
        let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        serverCheck = .checking
        Task { [weak self] in
            let state: HubCheckState
            do {
                _ = try await HubClient(baseURL: url).data("/health", timeout: 5)
                state = .ok
            } catch {
                state = .failed(error.localizedDescription)
            }
            guard let self, self.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == url else { return }
            self.serverCheck = state
        }
    }

    // MARK: prompt

    var hubHint: String {
        if path == .newOnThisMac { return "http://localhost:6971" }
        if path == .newOnServer, serverCheck == .ok {
            return serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        }
        return "http://wolf.local:6971"
    }

    /// PROMPT.md body (between the two `---` lines) with the placeholders filled in.
    var promptText: String? {
        guard let root = Payload.root,
              let md = try? String(contentsOf: root.appendingPathComponent("installer/PROMPT.md"), encoding: .utf8)
        else { return nil }
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let rules = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }
        guard rules.count >= 2 else { return nil }
        let body = lines[(rules[0] + 1)..<rules[1]].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body
            .replacingOccurrences(of: "{{OS}}", with: "mac")
            .replacingOccurrences(of: "{{MODE}}", with: (path ?? .connectExisting).installMode)
            .replacingOccurrences(of: "{{HUB_HINT}}", with: hubHint)
    }

    // MARK: answer file

    func value(_ section: String, _ key: String) -> String { parsed["\(section).\(key)"] ?? "" }

    private func scheduleValidation() {
        validateTask?.cancel()
        let text = iniText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            iniState = .empty
            parsed = [:]
            shares = []
            return
        }
        iniState = .checking
        validateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let result = await Task.detached { IniValidator.validate(text) }.value
            guard let self, !Task.isCancelled, self.iniText == text else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: IniValidator.Result) {
        switch result {
        case .valid(let values):
            parsed = values
            let names = (values["meta.shares"] ?? "").split(separator: " ").map(String.init)
            shares = names.map { s in
                SetupShare(
                    section: s,
                    url: values["\(s).smb_url"] ?? "",
                    user: values["\(s).user"] ?? "NONE",
                    askPassword: values["\(s).password"] == "ASK",
                    role: values["\(s).role"] ?? "extra"
                )
            }
            let keep = Set(shares.map(\.section))
            passwords = passwords.filter { keep.contains($0.key) }
            iniState = .valid
        case .invalid(let problems):
            parsed = [:]
            shares = []
            iniState = .invalid(problems)
        case .unavailable(let why):
            parsed = [:]
            shares = []
            iniState = .unavailable(why)
        }
    }

    func applyAnswersToConfig() {
        guard let store, isIniValid else { return }
        store.config.setupPath = path
        let hub = value("wolf", "hub_url")
        let mcp = value("wolf", "mcp_url")
        let device = value("wolf", "device_name")
        if !hub.isEmpty { store.config.hubURL = hub }
        if !mcp.isEmpty { store.config.mcpURL = mcp }
        if !device.isEmpty { store.config.deviceName = device }
        store.config.shares = shares.map {
            ShareConfig(url: $0.url, user: $0.isGuest ? "" : $0.user, role: $0.role)
        }
    }

    /// The agent's own backup folder, if it reported one and it exists here.
    var agentBackup: (path: String, files: String)? {
        guard value("backup", "done") == "yes" else { return nil }
        var p = value("backup", "path")
        if p.hasPrefix("~/") { p = NSHomeDirectory() + String(p.dropFirst(1)) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
        return (p, value("backup", "files"))
    }

    var agentBackupReported: String? {
        value("backup", "done") == "yes" ? value("backup", "path") : nil
    }

    // MARK: install

    var installScript: URL? {
        guard let root = Payload.root else { return nil }
        let url = root.appendingPathComponent("installer/mac/install.sh")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Writes the answer file (and a mode-600 secrets file when passwords were typed) to a private
    /// temp folder and returns what to hand to InstallRunner.
    func prepareInstall() -> (script: URL, args: [String], env: [String: String])? {
        installError = nil
        guard let script = installScript else {
            installError = "This copy of Wolf Leader is missing its setup files. Rebuild it with installer/mac/build-app.sh."
            return nil
        }
        guard let mode = path?.installMode else {
            installError = "Pick your setup first."
            return nil
        }
        cleanupWorkDir()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wolf-leader-setup-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            installError = "Couldn't create a temporary folder: \(error.localizedDescription)"
            return nil
        }
        workDir = dir
        let ini = dir.appendingPathComponent("wolf-leader-setup.ini")
        let result = dir.appendingPathComponent("result.txt")
        resultFile = result
        let normalized = iniText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard fm.createFile(atPath: ini.path, contents: Data(normalized.utf8), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: result.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else {
            installError = "Couldn't write the answer file to a temporary folder."
            return nil
        }

        var env: [String: String] = [:]
        let secretLines = askShares.compactMap { share -> String? in
            let pw = (passwords[share.section] ?? "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            return pw.isEmpty ? nil : "\(share.section)=\(pw)"
        }
        if !secretLines.isEmpty {
            let secrets = dir.appendingPathComponent("secrets")
            let body = secretLines.joined(separator: "\n") + "\n"
            guard fm.createFile(atPath: secrets.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600]) else {
                installError = "Couldn't hand the share passwords to the installer."
                return nil
            }
            env["WL_SECRETS_FILE"] = secrets.path
        }

        let args = [
            "--ini", ini.path,
            "--mode", mode,
            "--toggles", togglesCSV,
            "--git-name", gitName.trimmingCharacters(in: .whitespaces),
            "--git-email", gitEmail.trimmingCharacters(in: .whitespaces),
            "--result", result.path,
        ]
        outcome = .none
        return (script, args, env)
    }

    /// Call when InstallRunner reports an exit code.
    func finishInstall(code: Int32, store: ConfigStore) {
        let result = resultFile.map { InstallResult(file: $0) } ?? InstallResult()
        if let dir = workDir {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("secrets"))
        }
        if code == 0 {
            for share in askShares {
                let pw = passwords[share.section] ?? ""
                guard !pw.isEmpty, !share.host.isEmpty else { continue }
                _ = SMBKeychain.save(host: share.host, user: share.user, password: pw)
            }
            passwords = [:]
            applyAnswersToConfig()
            if let backup = result["backup_dir"], !backup.isEmpty { store.config.lastBackupPath = backup }
            store.config.setupPath = path
            store.config.setupComplete = true
            // Keep the done screen up; "Open Wolf Leader" clears this.
            store.showOnboarding = true
            store.save()
            outcome = .success(result)
        } else {
            if let backup = result["backup_dir"], !backup.isEmpty {
                store.config.lastBackupPath = backup
                store.save()
            }
            outcome = .failure(code: code, result: result)
        }
        cleanupWorkDir()
    }

    /// restore.sh of the backup this run made, if it was written.
    func restoreScript(for result: InstallResult) -> URL? {
        guard let dir = result["backup_dir"], !dir.isEmpty else { return nil }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("restore.sh")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func cleanupWorkDir() {
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
    }
}

// MARK: - answer-file validation (runs installer/mac/ini.sh)

enum IniValidator {
    enum Result: Sendable {
        case valid([String: String])
        case invalid([IniProblem])
        case unavailable(String)
    }

    /// Blocking: call off the main actor.
    static func validate(_ text: String) -> Result {
        guard let root = Payload.root else {
            return .unavailable("This copy of Wolf Leader is missing its setup files, so the reply can't be checked.")
        }
        let iniSh = root.appendingPathComponent("installer/mac/ini.sh")
        let fm = FileManager.default
        guard fm.fileExists(atPath: iniSh.path) else {
            return .unavailable("ini.sh is missing from the app's setup files.")
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("wolf-leader-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .unavailable("Couldn't create a temporary folder to check the reply.")
        }
        defer { try? fm.removeItem(at: dir) }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paste = dir.appendingPathComponent("paste.txt")
        let extracted = dir.appendingPathComponent("answers.ini")
        guard fm.createFile(atPath: paste.path, contents: Data(normalized.utf8), attributes: [.posixPermissions: 0o600]) else {
            return .unavailable("Couldn't write the reply to a temporary file.")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [
            "-c", ". \"$1\" && wl_ini_extract \"$2\" >\"$3\" && wl_ini_parse \"$3\" mac",
            "wl-ini-check", iniSh.path, paste.path, extracted.path,
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return .unavailable("Couldn't run the checker: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        if proc.terminationStatus == 0 {
            var values: [String: String] = [:]
            for line in output.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                values[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            return .valid(values)
        }
        return .invalid(problems(from: output, offset: fenceLine(in: normalized)))
    }

    /// 1-based line of the fence ini.sh starts reading after (0 when there is none), mirroring
    /// wl_ini_extract, so error line numbers point at the pasted text.
    static func fenceLine(in text: String) -> Int {
        let lines = text.components(separatedBy: "\n")
        func isFence(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        if let i = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("```") && t.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "ini"
        }) {
            return i + 1
        }
        if let i = lines.firstIndex(where: isFence) { return i + 1 }
        return 0
    }

    static func problems(from output: String, offset: Int) -> [IniProblem] {
        var items: [(line: Int?, message: String, text: String?)] = []
        for raw in output.components(separatedBy: "\n") {
            if raw.hasPrefix("      > ") {
                if !items.isEmpty { items[items.count - 1].text = String(raw.dropFirst(8)) }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("Line "), let colon = line.firstIndex(of: ":"),
               let n = Int(line[line.index(line.startIndex, offsetBy: 5)..<colon]) {
                let msg = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                items.append((line: n + offset, message: msg, text: nil))
            } else {
                items.append((line: nil, message: line, text: nil))
            }
        }
        if items.isEmpty {
            return [IniProblem(line: nil, message: "The reply couldn't be read. Paste your AI's whole answer, including the ```ini block.", text: nil)]
        }
        let missingAll = items.allSatisfy { $0.line == nil && $0.message.hasPrefix("Missing section") }
        if missingAll {
            return [IniProblem(line: nil, message: "This doesn't look like your AI's answer yet. Paste its whole reply, including the ```ini block.", text: nil)]
        }
        return items.map { IniProblem(line: $0.line, message: friendly($0.message), text: $0.text) }
    }

    private static func friendly(_ message: String) -> String {
        if message.hasPrefix("Missing "), message.contains("= in [") {
            // "Missing timezone= in [wolf]"
            let key = message.dropFirst(8).prefix { $0 != "=" }
            let section = message.split(separator: "[").last.map { $0.dropLast() } ?? ""
            return "The [\(section)] section has no \(key) line."
        }
        if message.hasPrefix("Missing section ") {
            return "The \(message.dropFirst(16)) section is missing."
        }
        guard let first = message.first else { return message }
        return first.uppercased() + message.dropFirst()
    }
}

// MARK: - small system checks

struct GitIdentity: Sendable {
    var name = ""
    var email = ""
}

enum SetupSystem {
    static var dockerFound: Bool {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        return [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker",
            "/Applications/Docker.app", home + "/Applications/Docker.app",
        ].contains { fm.fileExists(atPath: $0) }
    }

    /// `git config --global user.name/email`. /usr/bin/git without Command Line Tools pops Apple's
    /// install dialog, so it is only run when real; otherwise ~/.gitconfig is read directly.
    static func gitIdentity() -> GitIdentity {
        if let git = usableGit() {
            let name = run(git, ["config", "--global", "user.name"]) ?? ""
            let email = run(git, ["config", "--global", "user.email"]) ?? ""
            if !name.isEmpty || !email.isEmpty { return GitIdentity(name: name, email: email) }
        }
        return gitconfigFile()
    }

    private static func usableGit() -> String? {
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        if run("/usr/bin/xcode-select", ["-p"]) != nil, fm.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }
        return nil
    }

    /// Trimmed stdout, or nil when the command fails.
    private static func run(_ exe: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gitconfigFile() -> GitIdentity {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gitconfig")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return GitIdentity() }
        var section = ""
        var name = ""
        var email = ""
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
            if key == "name" { name = value } else if key == "email" { email = value }
        }
        return GitIdentity(name: name, email: email)
    }
}
