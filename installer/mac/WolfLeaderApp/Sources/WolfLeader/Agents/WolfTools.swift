import Foundation

/// Wolf Leader's own tools inside every chat: the hub's MCP server, so whichever AI is running
/// can look things up mid-conversation (search, a project's brief and memories, an earlier chat,
/// your profile) and add to the ledger (a decision, constraint or problem; something lasting
/// about you). Saving the chat and choosing its project stay with Wolf Leader, so those tools are
/// left out: an AI calling them would file a second copy of the chat.
enum WolfTools {
    /// Same name as the server older client installs added to Claude Code / Codex, so ours
    /// replaces theirs for chats here instead of running next to it.
    static let server = "wolf-leader"

    static let blocked = ["save_session", "save_current_session", "wolfhowl", "wolfeat",
                          "create_project", "set_project", "resolve_project"]

    /// The hub's MCP address for this chat, or nil when the rules turn the tools off.
    @MainActor
    static func url(hubURL: String) -> String? {
        guard ChatRules.shared.hubTools else { return nil }
        return HubMCP.endpoint(hubURL)?.absoluteString
    }

    // MARK: Per agent

    /// Claude Code: an --mcp-config file, with the save/project tools turned off.
    static func claudeArgs(url: String) -> [String] {
        let dir = ConfigStore.supportDir.appendingPathComponent("agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("wolf-leader-mcp.json")
        let config: [String: Any] = ["mcpServers": [server: ["type": "http", "url": url]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]),
              (try? data.write(to: file, options: .atomic)) != nil else { return [] }
        // Wolf Leader's own tools never need asking about; the save/project ones are off.
        return ["--mcp-config", file.path,
                "--allowedTools", "mcp__\(server)",
                "--disallowedTools", blocked.map { "mcp__\(server)__\($0)" }.joined(separator: ",")]
    }

    /// Codex: config overrides before the subcommand. `ide-storage` is the same hub under an
    /// older name; it's switched off here so its save tools don't come along.
    static func codexArgs(url: String) -> [String] {
        let list = blocked.map { "\"\($0)\"" }.joined(separator: ",")
        // Codex holds MCP calls for approval on its own (even with approvals off) unless the server
        // says otherwise; Wolf Leader's tools are always fine to use.
        // A disabled entry still needs a valid transport when no legacy server is configured.
        return ["-c", "mcp_servers.\(server).url=\"\(url)\"",
                "-c", "mcp_servers.\(server).disabled_tools=[\(list)]",
                "-c", "mcp_servers.\(server).default_tools_approval_mode=\"approve\"",
                "-c", "mcp_servers.ide-storage={command=\"/usr/bin/false\",enabled=false}"]
    }

    /// Agent Client Protocol: an HTTP server in session/new, for agents that take one.
    static func acpServers(url: String?, capabilities: [String: Any]?) -> [[String: Any]] {
        guard let url,
              let mcp = capabilities?["mcpCapabilities"] as? [String: Any],
              mcp["http"] as? Bool == true else { return [] }
        return [["type": "http", "name": server, "url": url, "headers": [] as [Any]]]
    }

    // MARK: What the AI is told

    /// One short block so the AI knows the tools are there and what not to do with them.
    static func instructions(projectSlug: String?) -> String {
        """
        <wolf_leader_tools>
        You have the wolf-leader tools: Wolf Leader is the user's memory across every AI they use. Use them when the conversation needs something you weren't given above:
        - search: find anything in their projects, memories and past chats (any assistant, any device)
        - recall / get_brief / get_memories\(projectSlug.map { " (this project: \($0))" } ?? ""): a project's full context
        - get_session: read an earlier chat in full; get_profile: who the user is
        - remember: record a decision, constraint, problem or open work worth keeping for the next chat
        - add_to_profile: something lasting the user said about themselves
        Wolf Leader saves this chat and files it in its project on its own: never save the chat, howl, or create or switch projects.
        </wolf_leader_tools>
        """
    }
}
