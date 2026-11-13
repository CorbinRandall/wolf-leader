import Foundation

/// A model an agent can run, and the effort levels it takes.
struct ModelOption: Identifiable, Hashable {
    var id: String
    var name: String
    var efforts: [String]
}

/// Which models and effort levels each agent offers. Claude's are fixed aliases (always the latest
/// of each); Codex's come from `codex app-server` (`model/list`), since they depend on the account.
/// nil model or effort = leave the agent's own default alone.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let claudeModels: [ModelOption] = [
        ModelOption(id: "fable", name: "Fable", efforts: claudeEfforts),
        ModelOption(id: "opus", name: "Opus", efforts: claudeEfforts),
        ModelOption(id: "sonnet", name: "Sonnet", efforts: claudeEfforts),
        ModelOption(id: "haiku", name: "Haiku", efforts: claudeEfforts),
    ]
    static let codexEfforts = ["low", "medium", "high", "xhigh", "max"]

    @Published private(set) var codexModels: [ModelOption] = []
    private var loadingCodex = false

    /// Whether this agent's model and effort can be picked here.
    static func supports(_ agent: AgentKind?) -> Bool {
        guard let agent else { return false }
        return agent.proto == .claude || agent.proto == .codex
    }

    func models(for agent: AgentKind?) -> [ModelOption] {
        switch agent?.proto {
        case .claude: return Self.claudeModels
        case .codex:
            loadCodexIfNeeded()
            return codexModels
        default: return []
        }
    }

    /// Effort levels for a model (or the agent's usual ones when the model is the default).
    func efforts(for agent: AgentKind?, model: String?) -> [String] {
        if let model, let match = models(for: agent).first(where: { $0.id == model }), !match.efforts.isEmpty {
            return match.efforts
        }
        switch agent?.proto {
        case .claude: return Self.claudeEfforts
        case .codex: return Self.codexEfforts
        default: return []
        }
    }

    func modelName(_ id: String?, agent: AgentKind?) -> String {
        guard let id else { return "Default" }
        return models(for: agent).first { $0.id == id }?.name ?? id
    }

    static func effortName(_ effort: String?) -> String {
        switch effort {
        case nil: return "Default"
        case "xhigh": return "Extra high"
        case let e?: return e.prefix(1).uppercased() + e.dropFirst()
        }
    }

    /// Short label for a button: "Opus · High", "Default".
    func label(agent: AgentKind?, model: String?, effort: String?) -> String {
        switch (model, effort) {
        case (nil, nil): return "Default model"
        case (let m?, nil): return modelName(m, agent: agent)
        case (nil, let e?): return "Effort: \(Self.effortName(e))"
        case (let m?, let e?): return "\(modelName(m, agent: agent)) · \(Self.effortName(e))"
        }
    }

    /// Asks Codex once which models this account offers.
    func loadCodexIfNeeded() {
        guard codexModels.isEmpty, !loadingCodex,
              let codex = AgentRegistry.shared.all.first(where: { $0.proto == .codex }),
              let executable = AgentRegistry.shared.program(for: codex) else { return }
        loadingCodex = true
        Task {
            defer { loadingCodex = false }
            let process = JSONLineProcess(executable: executable, args: ["app-server"], cwd: NSTemporaryDirectory(),
                                          environment: AgentLocator.environment)
            let peer = JSONRPCPeer(process: process, tagged: false)
            defer { process.terminate() }
            do {
                try process.start()
                // Don't wait forever on a Codex that never answers; stopping it fails the requests.
                Task { try? await Task.sleep(for: .seconds(20)); process.terminate() }
                _ = try await peer.request("initialize", ["clientInfo": ["name": "wolf-leader", "title": "Wolf Leader", "version": "3"]])
                peer.notify("initialized")
                let listed = try await peer.request("model/list", [:])
                let rows = (listed["data"] as? [[String: Any]]) ?? (listed["models"] as? [[String: Any]]) ?? []
                codexModels = rows.compactMap { row in
                    guard row["hidden"] as? Bool != true,
                          let id = (row["id"] as? String) ?? (row["model"] as? String) else { return nil }
                    let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                        .compactMap { $0["reasoningEffort"] as? String }
                    return ModelOption(id: id, name: row["displayName"] as? String ?? id, efforts: efforts)
                }
            } catch {
                NSLog("Wolf Leader: couldn't list Codex models: \(error)")
            }
        }
    }
}
