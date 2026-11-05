import Foundation

/// The Wolf Leader side of every chat: the project's brief goes into the first message, and the
/// whole chat is saved to the hub, under its project, after every turn.
enum WolfChatSync {
    private static let memoryOrder = ["goal", "constraint", "decision", "active_work", "problem", "caveat", "note"]

    /// The project's purpose, where it was left off, and its key memories, as one block for the agent.
    static func context(hub: HubClient, projectID: Int, projectKey: String, projectName: String) async -> String? {
        async let briefTask = try? hub.brief(projectKey: projectKey)
        async let memoriesTask = try? hub.memories(projectID: projectID, limit: 200)
        let (brief, memories) = await (briefTask, memoriesTask)
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
        guard !parts.isEmpty else { return nil }
        var text = parts.joined(separator: "\n\n")
        if text.count > 8000 { text = String(text.prefix(8000)) + "\n…" }
        return """
        <wolf_leader_context project="\(projectName)">
        This chat is part of the Wolf Leader project "\(projectName)". Wolf Leader saves it to the project automatically.
        \(text)
        </wolf_leader_context>
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
        \(agentName) chat in Wolf Leader\(chat.projectName.map { ", project \($0)" } ?? "").
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
