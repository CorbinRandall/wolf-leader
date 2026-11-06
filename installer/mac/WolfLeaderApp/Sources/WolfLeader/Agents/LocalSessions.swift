import Foundation

/// Chats your AI tools keep on this Mac (the Claude app's Code sessions, Claude Code, Codex),
/// whether or not they ever reached Wolf Leader. Any of them can be opened in Wolf Leader: it
/// gets saved to the ledger, and the same AI picks the real session back up.
struct LocalSession: Identifiable, Hashable {
    enum Tool: String { case claudeApp, claudeCode, codex }

    var tool: Tool
    /// The tool's own session id (Claude's CLI session, Codex's thread).
    var sessionID: String
    var title: String
    var cwd: String?
    var when: Date
    var transcript: URL

    var id: String { "\(tool.rawValue):\(sessionID)" }
    var toolName: String {
        switch tool {
        case .claudeApp: return "Claude app"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
    /// The Wolf Leader agent that can resume it.
    var agentID: String { tool == .codex ? "codex" : "claude" }
    var folderName: String? { cwd.map { ($0 as NSString).lastPathComponent } }
}

enum LocalSessions {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let injected = ["<environment_context>", "<user_instructions>", "# AGENTS.md", "<system-reminder>",
                                   "<command-", "<local-command", "<recommended_plugins>", "<skills_instructions>",
                                   "<wolf_leader_", "Caveat:", "[Request interrupted"]

    /// Newest first: sessions active in the last `days`, Wolf Leader's own chats left out.
    static func recent(days: Int = 21, limit: Int = 25) -> [LocalSession] {
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        var out = claude(since: since) + codex(since: since)
        out.sort { $0.when > $1.when }
        return Array(out.prefix(limit))
    }

    // MARK: Claude (the Claude app's Code tab and Claude Code share ~/.claude/projects)

    private struct AppMeta { var title: String; var when: Date; var cwd: String?; var archived: Bool }

    /// Titles and times the Claude app keeps for its Code sessions, by CLI session id.
    private static func claudeAppMeta() -> [String: AppMeta] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var out: [String: AppMeta] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = json["cliSessionId"] as? String else { continue }
            let ms = (json["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0
            out[cli] = AppMeta(title: (json["title"] as? String) ?? "Claude app session",
                               when: Date(timeIntervalSince1970: ms / 1000),
                               cwd: json["cwd"] as? String,
                               archived: json["isArchived"] as? Bool ?? false)
        }
        return out
    }

    private static func claude(since: Date) -> [LocalSession] {
        let fm = FileManager.default
        let root = home.appendingPathComponent(".claude/projects")
        let meta = claudeAppMeta()
        var out: [LocalSession] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            // Chats Wolf Leader ran itself are already in Chats.
            if dir.lastPathComponent.contains("WolfLeader") { continue }
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard modified > since else { continue }
                let sid = file.deletingPathExtension().lastPathComponent
                if let app = meta[sid] {
                    if app.archived { continue }
                    out.append(LocalSession(tool: .claudeApp, sessionID: sid, title: app.title, cwd: app.cwd,
                                            when: max(app.when, modified), transcript: file))
                } else {
                    let head = claudeHead(file)
                    guard let said = head.said, !isAutomated(said), !isTemp(head.cwd) else { continue }
                    out.append(LocalSession(tool: .claudeCode, sessionID: sid, title: AgentText.oneLine(said, limit: 80),
                                            cwd: head.cwd, when: modified, transcript: file))
                }
            }
        }
        return out
    }

    /// The first thing the person said and the folder, from the start of a Claude transcript.
    private static func claudeHead(_ file: URL) -> (said: String?, cwd: String?) {
        var said: String?
        var cwd: String?
        for row in rows(file, limit: 300) {
            cwd = cwd ?? row["cwd"] as? String
            if said == nil, row["type"] as? String == "user", row["isMeta"] as? Bool != true,
               let text = userText((row["message"] as? [String: Any])?["content"]) {
                said = text
            }
            if said != nil, cwd != nil { break }
        }
        return (said, cwd)
    }

    // MARK: Codex

    private static func codex(since: Date) -> [LocalSession] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        if let text = try? String(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = row["id"] as? String else { continue }
                names[id] = row["thread_name"] as? String
            }
        }
        var newest: [String: LocalSession] = [:]
        for root in [".codex/sessions", ".codex/archived_sessions"] {
            let walker = fm.enumerator(at: home.appendingPathComponent(root), includingPropertiesForKeys: [.contentModificationDateKey])
            while let file = walker?.nextObject() as? URL {
                guard file.lastPathComponent.hasPrefix("rollout-"), file.pathExtension == "jsonl" else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard modified > since,
                      let range = file.lastPathComponent.range(of: #"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}"#, options: .regularExpression)
                else { continue }
                let sid = String(file.lastPathComponent[range])
                var cwd: String?
                var said: String?
                for row in rows(file, limit: 200) {
                    let payload = row["payload"] as? [String: Any] ?? [:]
                    cwd = cwd ?? payload["cwd"] as? String
                    if said == nil, payload["type"] as? String == "message", payload["role"] as? String == "user" {
                        said = codexText(payload["content"])
                    }
                    if said != nil, cwd != nil { break }
                }
                // Wolf Leader's own Codex chats, and apps running Codex behind the scenes.
                if let cwd, cwd.contains("/WolfLeader") || cwd.contains("/Library/Application Support/") || isTemp(cwd) { continue }
                guard let said, !isAutomated(said) else { continue }
                let title = names[sid].flatMap { $0.isEmpty ? nil : $0 } ?? AgentText.oneLine(said, limit: 80)
                let session = LocalSession(tool: .codex, sessionID: sid, title: title, cwd: cwd, when: modified, transcript: file)
                if let have = newest[sid], have.when >= modified { continue }
                newest[sid] = session
            }
        }
        return Array(newest.values)
    }

    // MARK: Turning a transcript into chat lines

    static func items(for session: LocalSession, limit: Int = 160) -> [ChatItem] {
        var items: [ChatItem] = []
        func add(_ kind: ChatItem.Kind, _ text: String, at: Date?) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if kind == .agent, let last = items.last, last.kind == .agent {
                items[items.count - 1].text += "\n\n" + text
                return
            }
            items.append(ChatItem(id: UUID().uuidString, kind: kind, text: text, status: kind == .tool ? .done : nil, at: at ?? Date()))
        }
        for row in rows(session.transcript, limit: 20_000) {
            let at = HubDate.parse(row["timestamp"] as? String)
            if session.tool == .codex {
                let payload = row["payload"] as? [String: Any] ?? [:]
                switch payload["type"] as? String {
                case "message":
                    let text = codexText(payload["content"]) ?? ""
                    if payload["role"] as? String == "user" { add(.user, text, at: at) }
                    else if payload["role"] as? String == "assistant" { add(.agent, text, at: at) }
                case "function_call", "custom_tool_call":
                    add(.tool, "\(payload["name"] as? String ?? "step") \(AgentText.oneLine(payload["arguments"] as? String ?? payload["input"] as? String ?? "", limit: 140))", at: at)
                default: break
                }
            } else {
                let message = row["message"] as? [String: Any] ?? [:]
                switch row["type"] as? String {
                case "user":
                    if row["isMeta"] as? Bool == true { continue }
                    if let text = userText(message["content"]) { add(.user, text, at: at) }
                case "assistant":
                    for block in (message["content"] as? [[String: Any]]) ?? [] {
                        switch block["type"] as? String {
                        case "text": add(.agent, block["text"] as? String ?? "", at: at)
                        case "tool_use":
                            add(.tool, "\(block["name"] as? String ?? "step") \(AgentText.oneLine(AgentText.describe(block["input"]), limit: 140))", at: at)
                        default: break
                        }
                    }
                default: break
                }
            }
        }
        return Array(items.suffix(limit))
    }

    // MARK: Helpers

    private static func rows(_ file: URL, limit: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        // Big transcripts: the head is enough for titles; whole files for opening one.
        let data = (limit < 1000 ? (try? handle.read(upToCount: 2_000_000)) : (try? handle.readToEnd())) ?? Data()
        var out: [[String: Any]] = []
        for line in data.split(separator: 0x0A) {
            if out.count >= limit { break }
            if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { out.append(row) }
        }
        return out
    }

    /// What the person typed (Claude transcripts): plain text, not tool results or injected blocks.
    private static func userText(_ content: Any?) -> String? {
        var text: String?
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] {
            let parts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !injected.contains(where: { t.hasPrefix($0) }) else { return nil }
        return t
    }

    private static func codexText(_ content: Any?) -> String? {
        let parts = ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
        guard let t = Optional(parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)), !t.isEmpty,
              !injected.contains(where: { t.hasPrefix($0) }) else { return nil }
        return t
    }

    /// Throwaway runs (scripts, tests) happen in temp folders; they're not anyone's chat.
    static func isTemp(_ cwd: String?) -> Bool {
        guard let cwd else { return false }
        return ["/tmp", "/private/tmp", "/var/folders/", "/private/var/folders/"].contains { cwd == $0 || cwd.hasPrefix($0 + (($0.hasSuffix("/")) ? "" : "/")) }
    }

    private static func isAutomated(_ said: String) -> Bool {
        said.range(of: #"^you are an? (helpful )?(assistant|transcription|text|formatting|writing)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}
