import Foundation

/// Codex through `codex app-server`: JSON-RPC over stdio, one thread per chat.
@MainActor
final class CodexDriver: AgentDriver {
    var onEvent: (AgentEvent) -> Void = { _ in }

    private let executable: String
    private let args: [String]
    private let cwd: String
    private let mode: PermissionMode
    private var threadID: String?
    private var turnID: String?
    private var peer: JSONRPCPeer?
    private var approvals: [String: Any] = [:]
    private var exitReported = false

    init(executable: String, args: [String], cwd: String, mode: PermissionMode, resumeID: String?, toolsURL: String? = nil) {
        self.executable = executable
        // Config overrides go before the subcommand (`codex -c … app-server`).
        self.args = (toolsURL.map { WolfTools.codexArgs(url: $0) } ?? []) + args
        self.cwd = cwd
        self.mode = mode
        self.threadID = resumeID
    }

    private var approvalPolicy: String {
        switch mode {
        case .ask: return "untrusted"
        case .edits: return "on-request"
        case .auto: return "never"
        }
    }

    private var sandbox: String { mode == .auto ? "danger-full-access" : "workspace-write" }

    func start() async throws {
        let process = JSONLineProcess(executable: executable, args: args, cwd: cwd, environment: AgentLocator.environment)
        let peer = JSONRPCPeer(process: process, tagged: false)
        peer.onNotification = { [weak self] method, params in self?.handle(method, params) }
        peer.onRequest = { [weak self] id, method, params in self?.handleRequest(id, method, params) }
        peer.onExit = { [weak self] reason in
            guard let self, !self.exitReported else { return }
            self.exitReported = true
            self.onEvent(.exited(reason))
        }
        self.peer = peer
        try process.start()
        _ = try await peer.request("initialize", ["clientInfo": ["name": "wolf-leader", "title": "Wolf Leader", "version": "3"]])
        peer.notify("initialized")
        var settings: [String: Any] = ["cwd": cwd, "approvalPolicy": approvalPolicy, "sandbox": sandbox]
        if let model = await usableModel(peer) { settings["model"] = model }
        if let threadID {
            do {
                _ = try await peer.request("thread/resume", settings.merging(["threadId": threadID]) { a, _ in a })
                return
            } catch {
                onEvent(.note("Couldn't pick the old Codex thread back up, so this continues in a new one."))
            }
        }
        let result = try await peer.request("thread/start", settings)
        if let id = (result["thread"] as? [String: Any])?["id"] as? String {
            threadID = id
            onEvent(.sessionID(id))
        }
    }

    /// The model to ask for, when the one in ~/.codex/config.toml isn't offered to this account
    /// (an old setting would otherwise fail every turn). nil = leave Codex's choice alone.
    private func usableModel(_ peer: JSONRPCPeer) async -> String? {
        guard let configured = Self.configuredModel(),
              let listed = try? await peer.request("model/list", [:]) else { return nil }
        let rows = (listed["data"] as? [[String: Any]]) ?? (listed["models"] as? [[String: Any]]) ?? []
        let ids = rows.compactMap { ($0["id"] as? String) ?? ($0["model"] as? String) }
        guard !ids.isEmpty, !ids.contains(configured) else { return nil }
        let fallback = rows.first { $0["isDefault"] as? Bool == true }.flatMap { ($0["id"] as? String) ?? ($0["model"] as? String) } ?? ids[0]
        onEvent(.note("Codex is set to \(configured), which your account doesn't offer, so this chat uses \(fallback)."))
        return fallback
    }

    /// The top-level `model = "…"` in ~/.codex/config.toml (before any [section]).
    nonisolated static func configuredModel() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard line.hasPrefix("model"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    func send(_ text: String, images: [ChatImage]) async throws {
        guard let peer, let threadID else { throw AgentError.failed("Codex isn't running.") }
        let result = try await peer.request("turn/start", [
            "threadId": threadID,
            "input": [["type": "text", "text": text]] + images.map { ["type": "image", "url": "data:image/png;base64," + $0.data.base64EncodedString()] },
        ])
        turnID = (result["turn"] as? [String: Any])?["id"] as? String
    }

    func interrupt() {
        guard let peer, let threadID, let turnID else { return }
        Task { _ = try? await peer.request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) }
    }

    func answer(approval id: String, allow: Bool, always: Bool) {
        guard let requestID = approvals.removeValue(forKey: id) else { return }
        peer?.respond(requestID, result: ["decision": allow ? (always ? "acceptForSession" : "accept") : "decline"])
    }

    func stop() {
        exitReported = true
        peer?.process.terminate()
        peer = nil
    }

    // MARK: Reading Codex's output

    private func handle(_ method: String, _ params: [String: Any]) {
        let itemID = params["itemId"] as? String ?? ""
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String { onEvent(.textDelta(id: itemID, delta)) }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params["delta"] as? String { onEvent(.thinkingDelta(id: itemID, delta)) }
        case "item/started":
            if let item = params["item"] as? [String: Any] { started(item) }
        case "item/completed":
            if let item = params["item"] as? [String: Any] { completed(item) }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            turnID = nil
            onEvent(.turnFinished(error: turn["status"] as? String == "failed" ? (error ?? "Codex couldn't finish.") : error))
        case "error":
            if let message = (params["error"] as? [String: Any])?["message"] as? String, params["willRetry"] as? Bool != true {
                onEvent(.note(message))
            }
        default:
            break
        }
    }

    private func started(_ item: [String: Any]) {
        let id = item["id"] as? String ?? UUID().uuidString
        switch item["type"] as? String {
        case "commandExecution":
            onEvent(.toolStarted(id: id, title: "Run `\(AgentText.oneLine(Self.command(item), limit: 70))`", detail: ""))
        case "fileChange":
            onEvent(.toolStarted(id: id, title: Self.fileTitle(item), detail: ""))
        case "mcpToolCall":
            let server = item["server"] as? String ?? "tool"
            let tool = item["tool"] as? String ?? ""
            onEvent(.toolStarted(id: id, title: "\(server) · \(tool)", detail: AgentText.describe(item["arguments"])))
        case "webSearch":
            onEvent(.toolStarted(id: id, title: "Search the web “\(item["query"] as? String ?? "")”", detail: ""))
        default:
            break
        }
    }

    private func completed(_ item: [String: Any]) {
        let id = item["id"] as? String ?? ""
        let failed = ["failed", "declined"].contains(item["status"] as? String ?? "")
        switch item["type"] as? String {
        case "agentMessage":
            if let text = item["text"] as? String, !text.isEmpty { onEvent(.text(id: id, text)) }
        case "commandExecution":
            onEvent(.toolUpdated(id: id, output: item["aggregatedOutput"] as? String, status: failed ? .failed : .done))
        case "fileChange":
            let diff = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["diff"] as? String }.joined(separator: "\n")
            onEvent(.toolUpdated(id: id, output: diff, status: failed ? .failed : .done))
        case "mcpToolCall":
            onEvent(.toolUpdated(id: id, output: AgentText.describe(item["result"] ?? item["error"]), status: failed ? .failed : .done))
        case "webSearch":
            onEvent(.toolUpdated(id: id, output: nil, status: .done))
        default:
            break
        }
    }

    private func handleRequest(_ id: Any, _ method: String, _ params: [String: Any]) {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "execCommandApproval", "applyPatchApproval":
            let key = UUID().uuidString
            approvals[key] = id
            let command = Self.command(params)
            let title = command.isEmpty ? "Change files" : "Run `\(AgentText.oneLine(command, limit: 70))`"
            var detail = params["reason"] as? String ?? ""
            if let cwd = params["cwd"] as? String { detail += (detail.isEmpty ? "" : "\n") + "In \(cwd)" }
            onEvent(.approval(id: key, title: title, detail: detail))
        default:
            peer?.respondError(id, message: "Wolf Leader doesn't handle \(method) yet.")
        }
    }

    /// The command without the `/bin/zsh -lc '…'` wrapper Codex adds.
    static func command(_ item: [String: Any]) -> String {
        var command = (item["command"] as? String) ?? ((item["command"] as? [String])?.joined(separator: " ") ?? "")
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            command = String(command.dropFirst(prefix.count))
            if let first = command.first, (first == "'" || first == "\""), command.last == first, command.count >= 2 {
                command = String(command.dropFirst().dropLast())
            }
        }
        return command
    }

    static func fileTitle(_ item: [String: Any]) -> String {
        let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            .map { ($0 as NSString).lastPathComponent }
        if paths.isEmpty { return "Edit files" }
        return "Edit " + (paths.count > 3 ? paths.prefix(3).joined(separator: ", ") + " and \(paths.count - 3) more" : paths.joined(separator: ", "))
    }
}
