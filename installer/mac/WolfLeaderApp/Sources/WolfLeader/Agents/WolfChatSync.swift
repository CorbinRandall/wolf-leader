import Foundation

/// Wolf Leader is the layer above the agents. Every chat, whichever agent runs it, starts with
/// what Wolf Leader knows: who you are, the project's purpose and where it was left off, its key
/// memories, and the project's ledger (the recent chats in it, from every agent and device).
/// After every turn the chat is written back to the project, so the next chat (any agent, any
/// device) starts from there.
enum WolfChatSync {
    private static let memoryOrder = ["goal", "constraint", "decision", "active_work", "problem", "caveat", "note"]

    /// Everything an agent should know before the first message of a chat, as one block.
    /// `project` is nil for a chat that isn't in a project yet (it still gets who you are).
    static func context(hub: HubClient, project: ProjectRef?, person: String?, excludingSession: String?) async -> String? {
        let who = person?.trimmingCharacters(in: .whitespaces).isEmpty == false ? person : nil
        async let aboutTask: String? = who == nil ? nil : (try? await hub.profileMarkdown(person: who ?? ""))
        async let briefTask = project != nil ? (try? await hub.brief(projectKey: project!.slug)) : nil
        async let memoriesTask = project != nil ? (try? await hub.memories(projectID: project!.id, limit: 200)) : nil
        async let ledgerTask = project != nil ? ledger(hub: hub, projectID: project!.id, excluding: excludingSession) : nil
        async let sharedTask = try? await hub.sharedContextText(excluding: project?.id)
        let (about, brief, memories, ledger, shared) = await (aboutTask, briefTask, memoriesTask, ledgerTask, sharedTask)

        var sections: [String] = []
        if let about = about?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
            sections.append("<about_you person=\"\(person ?? "")\">\n\(clip(about, 3000))\n</about_you>")
        }
        if let shared = shared?.trimmingCharacters(in: .whitespacesAndNewlines), !shared.isEmpty {
            sections.append("""
            <shared_context>
            Applies to every project: things the user set up once (servers, network, accounts and how to reach them).
            \(clip(shared, 12_000))
            </shared_context>
            """)
        }
        if let project {
            var parts: [String] = []
            if let purpose = brief?.purpose, !purpose.isEmpty { parts.append("Purpose: \(purpose)") }
            if let pickup = brief?.agentPrompt, !pickup.isEmpty { parts.append("Where it was left off:\n\(pickup)") }
            let picked = (memories ?? [])
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { (memoryOrder.firstIndex(of: $0.type) ?? 99) < (memoryOrder.firstIndex(of: $1.type) ?? 99) }
                .prefix(25)
            if !picked.isEmpty {
                parts.append("Key memories:\n" + picked.map { "- \($0.type): \(AgentText.oneLine($0.content, limit: 400))" }.joined(separator: "\n"))
            }
            if let ledger, !ledger.isEmpty {
                parts.append("Project ledger (recent chats in this project, newest first, from every assistant and device):\n" + ledger)
            }
            sections.append("""
            <project name="\(project.name)">
            This chat is part of the Wolf Leader project "\(project.name)". Wolf Leader writes it to the project's ledger after every reply, so the next chat (with any assistant, on any device) picks up from here.
            \(clip(parts.joined(separator: "\n\n"), 12_000))
            </project>
            """)
        }
        guard !sections.isEmpty else { return nil }
        return """
        <wolf_leader_context>
        Wolf Leader is the user's own memory across every AI assistant they use. Use this to pick up where things are; don't recite it back.
        \(sections.joined(separator: "\n\n"))
        </wolf_leader_context>
        """
    }

    /// The project's recent chats, one line each: when, which assistant on which device, and what happened.
    private static func ledger(hub: HubClient, projectID: Int, excluding session: String?) async -> String? {
        guard let data = try? await hub.data("/api/projects/\(projectID)/chats", query: ["limit": "14"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chats = json["active"] as? [[String: Any]] else { return nil }
        let lines: [String] = chats.compactMap { chat in
            if let session, chat["session_id"] as? String == session { return nil }
            let title = (chat["title"] as? String) ?? "Untitled chat"
            let when = HubDate.parse((chat["occurred_at"] as? String) ?? (chat["updated_at"] as? String))
                .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            let content = AgentText.oneLine((chat["content"] as? String) ?? "", limit: 500)
            return "- \(when) · \(title)" + (content.isEmpty ? "" : "\n  \(content)")
        }
        return lines.prefix(10).joined(separator: "\n")
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "\n…" : s }

    /// The conversation so far, for an agent joining it partway: on another device, after a switch
    /// to another agent, or when the earlier agent session is gone. Newest turns are kept first
    /// when it has to be cut; steps the agent took are one line each.
    static func handoff(_ items: [ChatItem], agentName: String, limit: Int = 24_000) -> String? {
        var lines: [String] = []
        var total = 0
        var cut = false
        for item in items.reversed() {
            let line: String
            switch item.kind {
            case .user: line = "User: " + String(item.text.prefix(4000))
            case .agent: line = "Assistant: " + String(item.text.prefix(6000))
            case .tool: line = "(step: \(AgentText.oneLine(item.text, limit: 160))\(item.status == .failed ? ", failed" : ""))"
            default: continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if total + line.count > limit { cut = true; break }
            total += line.count
            lines.append(line)
        }
        guard lines.contains(where: { $0.hasPrefix("User:") }) else { return nil }
        lines.reverse()
        return """
        <wolf_leader_conversation_so_far>
        You (\(agentName)) are picking up a conversation that was already going in Wolf Leader, maybe on another device or with another assistant. Here it is\(cut ? ", newest part" : ""). Carry on from where it left off: don't repeat what was said, and treat the steps as already done.

        \(lines.joined(separator: "\n\n"))
        </wolf_leader_conversation_so_far>
        """
    }

    /// Save (or update) the chat on the hub, filed under its project.
    static func save(_ chat: ChatRecord, hubURL: String) async throws {
        var messages: [[String: String]] = []
        var total = 0
        for item in chat.items.reversed() {
            let entry: [String: String]?
            switch item.kind {
            case .user: entry = ["role": "user", "content": String(item.text.prefix(20_000))]
            case .agent: entry = ["role": "assistant", "content": String(item.text.prefix(20_000))]
            case .tool: entry = ["role": "assistant", "content": "[step] \(item.text)"]
            default: entry = nil
            }
            guard let entry, let content = entry["content"], !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            total += content.count
            if total > 600_000 { break }
            messages.append(entry)
        }
        messages.reverse()
        guard messages.contains(where: { $0["role"] == "user" }) else { return }
        let lastReply = chat.items.last { $0.kind == .agent }?.text ?? ""
        let agentName = chat.agent?.name ?? chat.agentID
        let summary = """
        \(agentName) chat in Wolf Leader\(chat.agentDevice.map { " on \($0)" } ?? "")\(chat.projectName.map { ", project \($0)" } ?? "").
        Asked: \(AgentText.oneLine(chat.items.first { $0.kind == .user }?.text ?? "", limit: 600))
        Latest reply: \(AgentText.oneLine(lastReply, limit: 1500))
        """
        let iso = ISO8601DateFormatter()
        var arguments: [String: Any] = [
            "title": "\(agentName): \(chat.title)",
            "content": summary,
            "session_id": chat.hubSessionID,
            "workspace_path": chat.cwd,
            "messages_json": String(decoding: try JSONSerialization.data(withJSONObject: messages), as: UTF8.self),
            "occurred_at": iso.string(from: chat.created),
        ]
        // With a project the chat is filed (or moved) there; without one the hub keeps it as a loose session.
        if let projectID = chat.projectID { arguments["project_id"] = projectID }
        let reply = try await HubMCP.shared.call(tool: "save_session", arguments: arguments, hubURL: hubURL)
        if reply["ok"] as? Bool == false { throw AgentError.failed(reply["error"] as? String ?? "The hub didn't save the chat.") }
    }
}

/// A small client for the hub's MCP endpoint (the REST port + 1, at /mcp).
actor HubMCP {
    static let shared = HubMCP()
    private var sessionID: String?
    private var sessionHub = ""
    private var nextID = 1

    static func endpoint(_ hubURL: String) -> URL? {
        guard var parts = URLComponents(string: hubURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))) else { return nil }
        parts.port = (parts.port ?? 6971) + 1
        parts.path = "/mcp"
        return parts.url
    }

    func call(tool: String, arguments: [String: Any], hubURL: String) async throws -> [String: Any] {
        do {
            return try await attempt(tool, arguments, hubURL)
        } catch HubMCPError.sessionExpired {
            sessionID = nil
            return try await attempt(tool, arguments, hubURL)
        }
    }

    private enum HubMCPError: Error { case sessionExpired }

    private func attempt(_ tool: String, _ arguments: [String: Any], _ hubURL: String) async throws -> [String: Any] {
        guard let url = Self.endpoint(hubURL) else { throw AgentError.failed("The hub address isn't valid.") }
        if sessionID == nil || sessionHub != hubURL {
            let (_, response) = try await post(url, ["jsonrpc": "2.0", "id": take(), "method": "initialize", "params": [
                "protocolVersion": "2025-03-26", "capabilities": [:],
                "clientInfo": ["name": "wolf-leader-app", "version": "3"],
            ]], session: nil)
            guard let id = response.value(forHTTPHeaderField: "mcp-session-id") else {
                throw AgentError.failed("The hub's MCP server didn't start a session.")
            }
            sessionID = id
            sessionHub = hubURL
            _ = try await post(url, ["jsonrpc": "2.0", "method": "notifications/initialized"], session: id)
        }
        let (data, response) = try await post(url, ["jsonrpc": "2.0", "id": take(), "method": "tools/call",
                                                    "params": ["name": tool, "arguments": arguments]], session: sessionID)
        if [400, 404].contains(response.statusCode) { throw HubMCPError.sessionExpired }
        guard (200..<300).contains(response.statusCode) else { throw AgentError.failed("The hub answered HTTP \(response.statusCode).") }
        // Replies come as server-sent events: take the last `data:` line that holds the result.
        // Lines end in "\r\n", which Swift treats as one character, so split on any newline.
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        let payloads = lines.filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        let bodies = payloads.isEmpty ? [String(decoding: data, as: UTF8.self)] : payloads
        for body in bodies.reversed() {
            guard let message = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { continue }
            if let error = message["error"] as? [String: Any] { throw AgentError.failed(error["message"] as? String ?? "The hub refused the save.") }
            guard let result = message["result"] as? [String: Any] else { continue }
            if let structured = result["structuredContent"] as? [String: Any] { return structured }
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "{}"
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? ["ok": result["isError"] as? Bool != true]
        }
        throw AgentError.failed("The hub's reply couldn't be read.")
    }

    private func take() -> Int { defer { nextID += 1 }; return nextID }

    private func post(_ url: URL, _ body: [String: Any], session: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let session { request.setValue(session, forHTTPHeaderField: "mcp-session-id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.failed("No reply from the hub.") }
        return (data, http)
    }
}
