import AppKit
import Foundation

/// How to install and sign in to each built-in agent. Commands come from each tool's own docs.
struct AgentRecipe {
    /// A shell command that installs the tool, or nil when there's no one-line installer.
    var install: String?
    /// Arguments that start the tool's sign-in in Terminal ([] = just start it; it asks).
    var signIn: [String]
    /// Where to read more.
    var docs: URL?

    static func of(_ agent: AgentKind) -> AgentRecipe {
        switch agent.id {
        case "claude":
            // The Claude desktop app ships a copy; `claude install` turns it into a normal install.
            let bundled = AgentLocator.claudeFromDesktopApp().map { "\(shellQuote($0)) install" }
            return AgentRecipe(install: bundled ?? "curl -fsSL https://claude.ai/install.sh | bash",
                               signIn: ["auth", "login"],
                               docs: URL(string: "https://docs.claude.com/en/docs/claude-code/setup"))
        case "codex":
            return AgentRecipe(install: "npm install -g @openai/codex", signIn: ["login"],
                               docs: URL(string: "https://github.com/openai/codex"))
        case "gemini":
            return AgentRecipe(install: "npm install -g @google/gemini-cli", signIn: [],
                               docs: URL(string: "https://github.com/google-gemini/gemini-cli"))
        case "grok":
            return AgentRecipe(install: "npm install -g @xai-official/grok", signIn: [],
                               docs: URL(string: "https://x.ai/cli"))
        case "opencode":
            return AgentRecipe(install: "curl -fsSL https://opencode.ai/install | bash", signIn: ["auth", "login"],
                               docs: URL(string: "https://opencode.ai/docs"))
        case "kiro":
            return AgentRecipe(install: "curl -fsSL https://cli.kiro.dev/install | bash", signIn: ["login"],
                               docs: URL(string: "https://kiro.dev/docs/cli/"))
        case "copilot":
            return AgentRecipe(install: "npm install -g @github/copilot", signIn: [],
                               docs: URL(string: "https://docs.github.com/en/copilot/how-tos/copilot-cli/install-copilot-cli"))
        default:
            return AgentRecipe(install: nil, signIn: [], docs: nil)
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Every agent this Mac can chat with: the built-in list plus agents the person added, with where
/// each one's program was found.
final class AgentRegistry: ObservableObject {
    static let shared = AgentRegistry()

    /// Agents added by hand (any ACP tool, or another copy of Claude Code / Codex).
    @Published private(set) var custom: [AgentKind] = []
    /// agent id -> program path, or missing when not found. Refreshed by `refresh()`.
    @Published private(set) var found: [String: String] = [:]
    @Published private(set) var scanning = false

    private static var file: URL { ConfigStore.supportDir.appendingPathComponent("agents.json") }
    private static func overrideKey(_ id: String) -> String { "wl.agentPath.\(id)" }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([AgentKind].self, from: data) {
            custom = saved
        }
        rescanNow()
    }

    var all: [AgentKind] { AgentKind.builtIn + custom }

    func agent(id: String) -> AgentKind? { all.first { $0.id == id } }

    func isCustom(_ agent: AgentKind) -> Bool { custom.contains { $0.id == agent.id } }

    // MARK: Finding programs

    /// The program for this agent: a path the person chose, else the usual places, the login
    /// shell's PATH, and (for Claude) the copy inside the Claude desktop app.
    func program(for agent: AgentKind) -> String? {
        if let chosen = UserDefaults.standard.string(forKey: Self.overrideKey(agent.id)),
           FileManager.default.isExecutableFile(atPath: chosen) {
            return chosen
        }
        if let path = AgentLocator.find(agent.binary) { return path }
        if agent.id == "claude" || agent.binary == "claude" { return AgentLocator.claudeFromDesktopApp() }
        return nil
    }

    func chosenPath(for agent: AgentKind) -> String? {
        UserDefaults.standard.string(forKey: Self.overrideKey(agent.id))
    }

    func choose(path: String?, for agent: AgentKind) {
        if let path { UserDefaults.standard.set(path, forKey: Self.overrideKey(agent.id)) }
        else { UserDefaults.standard.removeObject(forKey: Self.overrideKey(agent.id)) }
        rescanNow()
    }

    /// Quick pass over the known places (no shell). Call `refresh()` for the full search.
    func rescanNow() {
        var map: [String: String] = [:]
        for agent in all { if let p = program(for: agent) { map[agent.id] = p } }
        found = map
    }

    /// Asks the login shell for its PATH once (where npm, bun and installers put tools), then rescans.
    func refresh() async {
        await MainActor.run { scanning = true }
        await AgentLocator.learnShellPath()
        await MainActor.run { rescanNow() }
        await checkSignIns()
        await MainActor.run { scanning = false }
    }

    // MARK: Signed in?

    /// agent id -> signed in (only for tools that can say so without starting a chat).
    @Published private(set) var signedIn: [String: Bool] = [:]

    /// Asks Claude Code (`auth status`) and Codex (`login status`) whether they're signed in.
    func checkSignIns() async {
        var result: [String: Bool] = [:]
        for agent in all {
            guard let program = program(for: agent) else { continue }
            switch agent.proto {
            case .claude:
                let run = await Self.run(program, ["auth", "status"])
                if let data = run.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["loggedIn"] as? Bool {
                    result[agent.id] = ok
                }
            case .codex:
                let run = await Self.run(program, ["login", "status"])
                if !run.isEmpty { result[agent.id] = run.lowercased().contains("logged in") && !run.lowercased().contains("not logged in") }
            case .acp:
                break
            }
        }
        let checked = result
        await MainActor.run { signedIn = checked }
    }

    /// Output of a short command (stdout and stderr), or "" after 8 seconds.
    private static func run(_ program: String, _ args: [String]) async -> String {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: program)
            p.arguments = args
            p.environment = AgentLocator.environment
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return "" }
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); return "" }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
    }

    // MARK: Custom agents

    func add(_ agent: AgentKind) {
        custom.removeAll { $0.id == agent.id }
        custom.append(agent)
        save()
        rescanNow()
    }

    func remove(_ agent: AgentKind) {
        custom.removeAll { $0.id == agent.id }
        UserDefaults.standard.removeObject(forKey: Self.overrideKey(agent.id))
        save()
        rescanNow()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: ConfigStore.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(custom) { try? data.write(to: Self.file, options: .atomic) }
    }

    // MARK: Installing and signing in

    /// Writes the install command to a script for InstallRunner, so its output shows in the app.
    func installScript(for agent: AgentKind) -> URL? {
        guard let command = AgentRecipe.of(agent).install else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wolf-leader-agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("install-\(agent.id).sh")
        let body = """
        #!/bin/bash
        # Installs \(agent.name) for Wolf Leader chats.
        set -o pipefail
        export PATH=\(AgentRecipe.shellQuote(AgentLocator.path))
        echo "$ \(command)"
        \(command)
        """
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Opens Terminal running the agent's sign-in (it needs a browser and a real terminal).
    @discardableResult
    func openSignIn(for agent: AgentKind) -> Bool {
        guard let program = program(for: agent) else { return false }
        let args = AgentRecipe.of(agent).signIn.map(AgentRecipe.shellQuote).joined(separator: " ")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wolf-leader-agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("sign-in-\(agent.id).command")
        let body = """
        #!/bin/zsh
        export PATH=\(AgentRecipe.shellQuote(AgentLocator.path))
        clear
        echo "Signing in to \(agent.name) for Wolf Leader. Follow the steps below."
        echo
        \(AgentRecipe.shellQuote(program)) \(args)
        echo
        echo "Done. You can close this window and go back to Wolf Leader."
        """
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return NSWorkspace.shared.open(script)
    }
}

extension AgentLocator {
    /// Directories the login shell puts on PATH (learned once; GUI apps start with a bare PATH).
    private static let shellPathLock = NSLock()
    nonisolated(unsafe) private static var shellDirs: [String] = []

    static var learnedDirs: [String] {
        shellPathLock.lock(); defer { shellPathLock.unlock() }
        return shellDirs
    }

    /// Runs the person's login shell once to read its PATH. Gives up after 6 seconds.
    static func learnShellPath() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__WL_PATH__"
        let output: String = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return "" }
            let deadline = Date().addingTimeInterval(6)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); return "" }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return }
        let dirs = parts[1].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        shellPathLock.withLock { shellDirs = dirs }
    }

    /// The newest Claude Code that the Claude desktop app keeps for itself.
    static func claudeFromDesktopApp() -> String? {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { VersionOrder.isNewer($0, than: $1) }
        for version in versions {
            let vdir = base.appendingPathComponent(version)
            for build in (try? fm.contentsOfDirectory(atPath: vdir.path)) ?? [] {
                let exe = vdir.appendingPathComponent(build).appendingPathComponent("claude.app/Contents/MacOS/claude").path
                if fm.isExecutableFile(atPath: exe) { return exe }
            }
        }
        return nil
    }
}
