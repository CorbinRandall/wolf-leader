import Foundation

/// How much an agent may do without asking.
enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    case ask, edits, auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Ask first"
        case .edits: return "Auto-edit"
        case .auto: return "Full auto"
        }
    }

    var help: String {
        switch self {
        case .ask: return "The agent asks before it changes files or runs commands."
        case .edits: return "The agent edits files in the project folder on its own, and asks before anything else."
        case .auto: return "The agent does everything without asking. Use only in folders you trust."
        }
    }
}

/// One line in a chat: what you said, what the agent said, or a step it took.
struct ChatItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case user, agent, thinking, tool, approval, error, note }
    enum Status: String, Codable { case running, done, failed, pending, allowed, denied }

    var id: String
    var kind: Kind
    var text: String
    /// A tool's input, or the reason an approval is asked.
    var detail: String = ""
    /// A tool's result.
    var output: String = ""
    var status: Status?
    var at = Date()
}

/// A chat with one agent, in a project or not yet in one. Stored on this Mac so it can be picked
/// up again, and saved to the hub after every turn.
struct ChatRecord: Identifiable, Codable, Hashable {
    var id: String
    /// nil until the chat is connected to a project; until then the hub keeps it as a loose session.
    var projectID: Int?
    var projectName: String?
    var projectSlug: String?
    var agentID: String
    var title: String
    var cwd: String
    var mode: PermissionMode
    /// The model and effort level to run, as the agent names them. nil = the agent's own default.
    var model: String?
    var effort: String?
    /// The agent's own session or thread id, so a chat can be resumed after the app restarts.
    var agentSessionID: String?
    var items: [ChatItem]
    var created: Date
    var updated: Date
    var contextSent = false
    /// The device whose agent session `agentSessionID` is; that session only exists there.
    var agentDevice: String?
    /// While an agent is working on this chat: which device, and until when (renewed as it works).
    /// Other devices wait instead of starting a second agent on the same chat.
    var activeDevice: String?
    var activeUntil: Date?
    /// The next message hands the agent the conversation so far (another device or another agent).
    var needsHandoff: Bool?

    var agent: AgentKind? { AgentRegistry.shared.agent(id: agentID) }

    /// Running on another device right now.
    func busyElsewhere(than device: String) -> String? {
        guard let other = activeDevice, other != device, let until = activeUntil, until > Date() else { return nil }
        return other
    }

    /// The id the hub files this chat under; saving again updates it instead of adding a copy.
    var hubSessionID: String { "wolf-chat-\(id)" }
}

/// What an agent driver reports back while it works.
enum AgentEvent {
    case sessionID(String)
    case textDelta(id: String, String)
    case text(id: String, String)
    case thinkingDelta(id: String, String)
    case toolStarted(id: String, title: String, detail: String)
    case toolUpdated(id: String, output: String?, status: ChatItem.Status?)
    case approval(id: String, title: String, detail: String)
    case note(String)
    case turnFinished(error: String?)
    case exited(String?)
}

/// The common shape of every agent connection (Claude, Codex, ACP).
@MainActor
protocol AgentDriver: AnyObject {
    var onEvent: (AgentEvent) -> Void { get set }
    func start() async throws
    /// Sends a message. Attached images go as images where the agent supports that; other files as paths.
    func send(_ text: String, attachments: [URL]) async throws
    func interrupt()
    func answer(approval id: String, allow: Bool, always: Bool)
    func stop()
}

enum AgentError: LocalizedError {
    case notInstalled(AgentKind)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let agent): return "\(agent.name) isn't set up on this Mac yet. Open Settings > Agents to install it or point Wolf Leader at it."
        case .failed(let why): return why
        }
    }
}

/// Short, readable text for any JSON value an agent sends (tool inputs and outputs).
enum AgentText {
    static func describe(_ value: Any?, limit: Int = 4000) -> String {
        guard let value, !(value is NSNull) else { return "" }
        let text: String
        if let s = value as? String {
            text = s
        } else if let list = value as? [Any] {
            text = list.map { item -> String in
                if let dict = item as? [String: Any] {
                    if let t = dict["text"] as? String { return t }
                    if let inner = dict["content"] { return describe(inner, limit: limit) }
                }
                return describe(item, limit: limit)
            }.joined(separator: "\n")
        } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = "\(value)"
        }
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    static func oneLine(_ text: String, limit: Int = 90) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
