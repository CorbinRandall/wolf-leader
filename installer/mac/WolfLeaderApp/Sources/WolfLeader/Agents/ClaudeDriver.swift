import Foundation

/// Claude Code in stream-json mode. One process per chat stays open between turns. Approvals come
/// in as `can_use_tool` control requests, because of `--permission-prompt-tool stdio`.
@MainActor
final class ClaudeDriver: AgentDriver {
    var onEvent: (AgentEvent) -> Void = { _ in }

    private let executable: String
    private let cwd: String
    private let mode: PermissionMode
    private let resumeID: String?
    private var process: JSONLineProcess?
    /// The streamed block being written, keyed by message id and block index.
    private var blocks: [Int: (key: String, kind: String)] = [:]
    private var messageID = ""
    private var streamed: Set<String> = []
    private var approvals: [String: [String: Any]] = [:]
    private var exitReported = false

    init(executable: String, cwd: String, mode: PermissionMode, resumeID: String?) {
        self.executable = executable
        self.cwd = cwd
        self.mode = mode
        self.resumeID = resumeID
    }

    private var permissionMode: String {
        switch mode {
        case .ask: return "default"
        case .edits: return "acceptEdits"
        case .auto: return "bypassPermissions"
        }
    }

    func start() async throws {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", permissionMode]
        if let resumeID { args += ["--resume", resumeID] }
        let process = JSONLineProcess(executable: executable, args: args, cwd: cwd, environment: AgentLocator.environment)
        process.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.handle(message) } }
        process.onExit = { [weak self] code, tail in
            MainActor.assumeIsolated {
                guard let self, !self.exitReported else { return }
                self.exitReported = true
                let why = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                self.onEvent(.exited(code == 0 && why.isEmpty ? nil : (why.isEmpty ? "Claude stopped (exit \(code))." : AgentText.oneLine(why, limit: 400))))
            }
        }
        try process.start()
        self.process = process
        process.send(["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]])
    }

    func send(_ text: String) async throws {
        guard let process, process.isRunning else { throw AgentError.failed("Claude isn't running.") }
        process.send([
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
            "parent_tool_use_id": NSNull(),
            "session_id": "",
        ])
    }

    func interrupt() {
        process?.send(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func answer(approval id: String, allow: Bool, always: Bool) {
        guard let request = approvals.removeValue(forKey: id) else { return }
        var response: [String: Any]
        if allow {
            response = ["behavior": "allow", "updatedInput": request["input"] ?? [:]]
            if always, let suggestions = request["permission_suggestions"] as? [Any] {
                response["updatedPermissions"] = suggestions
            }
        } else {
            response = ["behavior": "deny", "message": "The user said no to this step in Wolf Leader."]
        }
        process?.send(["type": "control_response",
                       "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    func stop() {
        exitReported = true
        process?.terminate()
        process = nil
    }

    // MARK: Reading Claude's output

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "system":
            if message["subtype"] as? String == "init", let id = message["session_id"] as? String { onEvent(.sessionID(id)) }
        case "stream_event":
            handleStream(message["event"] as? [String: Any] ?? [:])
        case "assistant":
            handleAssistant(message["message"] as? [String: Any] ?? [:])
        case "user":
            handleToolResults(message["message"] as? [String: Any] ?? [:])
        case "control_request":
            handleControl(message)
        case "result":
            let failed = message["is_error"] as? Bool ?? false
            let text = message["result"] as? String ?? ""
            onEvent(.turnFinished(error: failed ? (text.isEmpty ? "Claude reported an error." : text) : nil))
        default:
            break
        }
    }

    private func handleStream(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            messageID = (event["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
            blocks = [:]
        case "content_block_start":
            let index = event["index"] as? Int ?? 0
            let kind = (event["content_block"] as? [String: Any])?["type"] as? String ?? ""
            blocks[index] = (key: "\(messageID)-\(index)", kind: kind)
        case "content_block_delta":
            let index = event["index"] as? Int ?? 0
            guard let block = blocks[index], let delta = event["delta"] as? [String: Any] else { return }
            if let text = delta["text"] as? String, delta["type"] as? String == "text_delta" {
                streamed.insert(messageID)
                onEvent(.textDelta(id: block.key, text))
            } else if let thinking = delta["thinking"] as? String {
                onEvent(.thinkingDelta(id: block.key, thinking))
            }
        default:
            break
        }
    }

    private func handleAssistant(_ message: [String: Any]) {
        let id = message["id"] as? String ?? UUID().uuidString
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                // Normally already shown from the stream; this catches text that arrived without it.
                if !streamed.contains(id), let text = block["text"] as? String, !text.isEmpty {
                    onEvent(.text(id: "\(id)-full-\(text.hashValue)", text))
                }
            case "tool_use":
                let toolID = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                onEvent(.toolStarted(id: toolID, title: Self.title(name, input), detail: AgentText.describe(input)))
            default:
                break
            }
        }
    }

    private func handleToolResults(_ message: [String: Any]) {
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String else { continue }
            let failed = block["is_error"] as? Bool ?? false
            onEvent(.toolUpdated(id: toolID, output: AgentText.describe(block["content"]), status: failed ? .failed : .done))
        }
    }

    private func handleControl(_ message: [String: Any]) {
        guard let id = message["request_id"] as? String, let request = message["request"] as? [String: Any] else { return }
        guard request["subtype"] as? String == "can_use_tool" else {
            process?.send(["type": "control_response",
                           "response": ["subtype": "error", "request_id": id, "error": "Not supported in Wolf Leader."]])
            return
        }
        approvals[id] = request
        let name = request["display_name"] as? String ?? request["tool_name"] as? String ?? "a tool"
        let input = request["input"] as? [String: Any] ?? [:]
        onEvent(.approval(id: id, title: Self.title(name, input), detail: AgentText.describe(input)))
    }

    /// "Ran ls", "Edited main.swift": the tool and its main argument in a few words.
    static func title(_ name: String, _ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return "Run `\(AgentText.oneLine(command, limit: 70))`" }
        if let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String {
            let file = (path as NSString).lastPathComponent
            switch name {
            case "Read": return "Read \(file)"
            case "Write": return "Write \(file)"
            case "Edit", "MultiEdit": return "Edit \(file)"
            default: return "\(name) \(file)"
            }
        }
        if let pattern = input["pattern"] as? String { return "\(name) “\(AgentText.oneLine(pattern, limit: 50))”" }
        if let url = input["url"] as? String { return "\(name) \(url)" }
        if let query = input["query"] as? String { return "\(name) “\(AgentText.oneLine(query, limit: 50))”" }
        if let description = input["description"] as? String { return "\(name): \(AgentText.oneLine(description, limit: 60))" }
        return name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ")
    }
}
