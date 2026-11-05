import Foundation

/// How Wolf Leader talks to an agent's command-line tool.
/// - claude: Claude Code's stream-json mode, with approvals over stdio.
/// - codex: Codex's app-server (JSON-RPC over stdio).
/// - acp: the Agent Client Protocol, which Gemini, Grok, OpenCode, Kiro and others speak.
enum AgentProtocol: String, Codable, Hashable {
    case claude, codex, acp
}

/// One AI agent Wolf Leader can chat with. The list follows the agents t3code supports.
struct AgentKind: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var company: String
    var binary: String
    var args: [String]
    var proto: AgentProtocol
    /// How to install or sign in, shown when the tool isn't found.
    var installHint: String
    var symbol: String

    static let builtIn: [AgentKind] = [
        AgentKind(id: "claude", name: "Claude", company: "Anthropic", binary: "claude", args: [], proto: .claude,
                  installHint: "Install Claude Code, then run `claude` once to sign in.", symbol: "sparkle"),
        AgentKind(id: "codex", name: "Codex", company: "OpenAI", binary: "codex", args: ["app-server"], proto: .codex,
                  installHint: "Install the Codex CLI, then run `codex login`.", symbol: "chevron.left.forwardslash.chevron.right"),
        AgentKind(id: "gemini", name: "Gemini", company: "Google", binary: "gemini", args: ["--experimental-acp"], proto: .acp,
                  installHint: "Install the Gemini CLI (npm i -g @google/gemini-cli), then run `gemini` once to sign in.", symbol: "diamond"),
        AgentKind(id: "grok", name: "Grok", company: "xAI", binary: "grok", args: ["--permission-mode", "default", "agent", "stdio"], proto: .acp,
                  installHint: "Install the Grok CLI, then sign in.", symbol: "bolt"),
        AgentKind(id: "opencode", name: "OpenCode", company: "SST", binary: "opencode", args: ["acp"], proto: .acp,
                  installHint: "Install OpenCode (brew install sst/tap/opencode), then run `opencode auth login`.", symbol: "terminal"),
        AgentKind(id: "kiro", name: "Kiro", company: "Amazon", binary: "kiro-cli", args: ["acp", "--agent-engine=v3", "--auth-method=cli"], proto: .acp,
                  installHint: "Install the Kiro CLI, then run `kiro-cli login`.", symbol: "cube"),
        AgentKind(id: "fx", name: "Fx", company: "Fx", binary: "fx", args: ["acp"], proto: .acp,
                  installHint: "Install the fx CLI, then sign in.", symbol: "function"),
        AgentKind(id: "copilot", name: "Copilot", company: "GitHub", binary: "copilot", args: ["--acp"], proto: .acp,
                  installHint: "Install the GitHub Copilot CLI (npm i -g @github/copilot), then sign in.", symbol: "airplane"),
    ]
}

/// Finds the agent tools on this Mac. Apps opened from Finder get a bare PATH, so look in the usual places.
enum AgentLocator {
    static var searchDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.cursor/bin", "\(home)/.bun/bin",
                    "\(home)/.opencode/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                    "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        // Node version managers put npm-installed CLIs (gemini, copilot) next to node.
        for manager in ["\(home)/.nvm/versions/node", "\(home)/.local"] {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: manager) {
                dirs += entries.filter { $0.hasPrefix("node-v") || $0.hasPrefix("v") }.sorted().reversed()
                    .map { "\(manager)/\($0)/bin" }
            }
        }
        return dirs
    }

    static var path: String {
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (searchDirs + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    static func find(_ binary: String) -> String? {
        if binary.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }
}
