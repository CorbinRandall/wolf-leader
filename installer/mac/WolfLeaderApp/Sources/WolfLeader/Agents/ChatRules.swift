import AppKit
import Foundation

/// Rules for every chat, with every agent, on every device (kept on the hub):
/// - never ask: every chat runs in Full auto, and anything an agent still asks is approved
/// - the mode new chats start in when "never ask" is off
/// - instructions every agent gets at the start of a chat
/// - which skills from the hub's library every chat starts with
@MainActor
final class ChatRules: ObservableObject {
    static let shared = ChatRules()

    struct Value: Codable, Equatable {
        var never_ask = true
        var default_mode = "auto"
        var rules = ""
        var skills: [String] = []
        var library: [String]? = nil
    }

    @Published private(set) var value: Value
    @Published private(set) var saving = false
    @Published private(set) var problem: String?

    private var hubURL = ""
    private static let cacheKey = "wl.chatRules"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Value.self, from: data) {
            value = cached
        } else {
            value = Value()
        }
    }

    var neverAsk: Bool { value.never_ask }
    var defaultMode: PermissionMode {
        neverAsk ? .auto : (PermissionMode(rawValue: value.default_mode) ?? .ask)
    }
    var library: [String] { value.library ?? value.skills }

    func start(hubURL: String) {
        self.hubURL = hubURL
        Task { await refresh() }
    }

    func refresh() async {
        guard !hubURL.isEmpty else { return }
        do {
            let data = try await HubClient(baseURL: hubURL).data("/api/chat-rules")
            let fresh = try JSONDecoder().decode(Value.self, from: data)
            adopt(fresh)
            problem = nil
        } catch HubClient.HubError.http(404) {
            problem = "This hub can't keep chat rules yet. Update the hub; until then they apply on this Mac only."
        } catch {
            // Offline: keep the last rules this Mac saw.
        }
    }

    func update(_ change: (inout Value) -> Void) {
        var next = value
        change(&next)
        adopt(next)
        Task { await save(next) }
    }

    private func save(_ next: Value) async {
        saving = true
        defer { saving = false }
        do {
            let body: [String: Any] = ["never_ask": next.never_ask, "default_mode": next.default_mode,
                                       "rules": next.rules, "skills": next.skills]
            let data = try await HubClient(baseURL: hubURL).data(
                "/api/chat-rules", method: "PUT", body: try JSONSerialization.data(withJSONObject: body))
            adopt(try JSONDecoder().decode(Value.self, from: data))
            problem = nil
        } catch {
            problem = "Couldn't save the rules to the hub: \(error.localizedDescription)"
        }
    }

    private func adopt(_ next: Value) {
        value = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }

    /// The rules and the chosen skills' instructions, for the start of a chat (any agent).
    func contextBlock(hub: HubClient) async -> String? {
        var sections: [String] = []
        let rules = value.rules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rules.isEmpty {
            sections.append("<user_rules>\nAlways follow these, in every chat:\n\(rules)\n</user_rules>")
        }
        var skills: [String] = []
        var total = 0
        for name in value.skills {
            guard let data = try? await hub.data("/api/skills/\(name)"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? String else { continue }
            let body = String(content.prefix(8000))
            if total + body.count > 24_000 { break }
            total += body.count
            skills.append("<skill name=\"\(name)\">\n\(body)\n</skill>")
        }
        if !skills.isEmpty {
            sections.append("""
            <user_skills>
            The user's own skills. Use each one whenever it applies, as you would a skill you have installed.
            \(skills.joined(separator: "\n\n"))
            </user_skills>
            """)
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
