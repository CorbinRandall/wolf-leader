import Foundation

/// Any agent that speaks the Agent Client Protocol (Gemini, Grok, OpenCode, Kiro, Copilot, Fx).
@MainActor
final class AcpDriver: AgentDriver {
    var onEvent: (AgentEvent) -> Void = { _ in }

    private let name: String
    private let executable: String
    private let args: [String]
    private let cwd: String
    private let mode: PermissionMode
    private var sessionID: String?
    private var peer: JSONRPCPeer?
    private var approvals: [String: (requestID: Any, allow: String?, always: String?, reject: String?)] = [:]
    /// Text arrives in chunks; a tool call in between starts a new message.
    private var textID = UUID().uuidString
    private var thoughtID = UUID().uuidString
    /// While an old session is loading, the agent replays it; that history is already on screen.
    private var replaying = false
    private var exitReported = false

    init(name: String, executable: String, args: [String], cwd: String, mode: PermissionMode, resumeID: String?) {
        self.name = name
        self.executable = executable
        self.args = args
        self.cwd = cwd
        self.mode = mode
        self.sessionID = resumeID
    }

    func start() async throws {
        let process = JSONLineProcess(executable: executable, args: args, cwd: cwd, environment: AgentLocator.environment)
        let peer = JSONRPCPeer(process: process, tagged: true)
        peer.onNotification = { [weak self] method, params in self?.handle(method, params) }
        peer.onRequest = { [weak self] id, method, params in self?.handleRequest(id, method, params) }
        peer.onExit = { [weak self] reason in
            guard let self, !self.exitReported else { return }
            self.exitReported = true
            self.onEvent(.exited(reason))
        }
        self.peer = peer
        try process.start()
        let hello = try await peer.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "wolf-leader", "title": "Wolf Leader", "version": "3"],
        ])
        let canLoad = (hello["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool ?? false
        if let sessionID, canLoad {
            replaying = true
            defer { replaying = false }
            if (try? await peer.request("session/load", ["sessionId": sessionID, "cwd": cwd, "mcpServers": []])) != nil { return }
        }
        if sessionID != nil { onEvent(.note("\(name) can't reopen the old session, so this continues in a new one.")) }
        let result = try await peer.request("session/new", ["cwd": cwd, "mcpServers": []])
        guard let id = result["sessionId"] as? String else { throw AgentError.failed("\(name) didn't start a session.") }
        sessionID = id
        onEvent(.sessionID(id))
    }

    func send(_ text: String) async throws {
        guard let peer, let sessionID else { throw AgentError.failed("\(name) isn't running.") }
        textID = UUID().uuidString
        let result = try await peer.request("session/prompt", ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]])
        let reason = result["stopReason"] as? String ?? "end_turn"
        onEvent(.turnFinished(error: reason == "refusal" ? "\(name) refused to continue." : nil))
    }

    func interrupt() {
        guard let sessionID else { return }
        peer?.notify("session/cancel", ["sessionId": sessionID])
    }

    func answer(approval id: String, allow: Bool, always: Bool) {
        guard let pending = approvals.removeValue(forKey: id) else { return }
        let option = allow ? (always ? (pending.always ?? pending.allow) : pending.allow) : pending.reject
        if let option {
            peer?.respond(pending.requestID, result: ["outcome": ["outcome": "selected", "optionId": option]])
        } else {
            peer?.respond(pending.requestID, result: ["outcome": ["outcome": "cancelled"]])
        }
    }

    func stop() {
        exitReported = true
        peer?.process.terminate()
        peer = nil
    }

    // MARK: Reading the agent's output

    private func handle(_ method: String, _ params: [String: Any]) {
        guard method == "session/update", !replaying, let update = params["update"] as? [String: Any] else { return }
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if let text = Self.text(update["content"]) { onEvent(.textDelta(id: textID, text)) }
        case "agent_thought_chunk":
            if let text = Self.text(update["content"]) { onEvent(.thinkingDelta(id: thoughtID, text)) }
        case "tool_call":
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            textID = UUID().uuidString
            thoughtID = UUID().uuidString
            onEvent(.toolStarted(id: id, title: update["title"] as? String ?? "Tool", detail: AgentText.describe(update["rawInput"])))
            if let status = Self.status(update["status"]), status != .running { onEvent(.toolUpdated(id: id, output: nil, status: status)) }
        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            let output = (update["content"] as? [[String: Any]])?.compactMap { Self.text($0["content"]) ?? ($0["newText"] as? String) }
                .joined(separator: "\n")
            onEvent(.toolUpdated(id: id, output: output?.isEmpty == false ? output : AgentText.describe(update["rawOutput"]),
                                 status: Self.status(update["status"])))
        case "plan":
            let steps = (update["entries"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                guard let content = entry["content"] as? String else { return nil }
                return (entry["status"] as? String == "completed" ? "✓ " : "• ") + content
            }
            if !steps.isEmpty { onEvent(.note("Plan:\n" + steps.joined(separator: "\n"))) }
        default:
            break
        }
    }

    private func handleRequest(_ id: Any, _ method: String, _ params: [String: Any]) {
        guard method == "session/request_permission" else {
            peer?.respondError(id, message: "Wolf Leader doesn't handle \(method) yet.")
            return
        }
        let options = params["options"] as? [[String: Any]] ?? []
        func option(_ kind: String) -> String? { options.first { $0["kind"] as? String == kind }?["optionId"] as? String }
        let allow = option("allow_once") ?? option("allow_always")
        let pending = (requestID: id, allow: allow, always: option("allow_always"), reject: option("reject_once") ?? option("reject_always"))
        let call = params["toolCall"] as? [String: Any] ?? [:]
        let kind = call["kind"] as? String ?? ""
        // Auto-edit lets file edits and reads through; Full auto lets everything through.
        if mode == .auto || (mode == .edits && ["edit", "read", "search", "think", "fetch"].contains(kind)), let allow {
            peer?.respond(id, result: ["outcome": ["outcome": "selected", "optionId": allow]])
            return
        }
        let key = UUID().uuidString
        approvals[key] = pending
        onEvent(.approval(id: key, title: call["title"] as? String ?? "Allow this step?", detail: AgentText.describe(call["rawInput"])))
    }

    private static func text(_ content: Any?) -> String? {
        guard let content = content as? [String: Any], content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    private static func status(_ raw: Any?) -> ChatItem.Status? {
        switch raw as? String {
        case "completed": return .done
        case "failed": return .failed
        case "pending", "in_progress": return .running
        default: return nil
        }
    }
}
