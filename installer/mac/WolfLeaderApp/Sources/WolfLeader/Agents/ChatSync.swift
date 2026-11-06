import AppKit
import Foundation

/// Keeps this device's chats and the hub's in step, so a chat started on one Mac opens and
/// continues on any other. Each change goes up a moment after it happens; everything changed
/// elsewhere comes down every 20 seconds and whenever Wolf Leader comes to the front.
/// The newer copy of a chat wins. A chat removed on one device is removed on all of them.
@MainActor
final class ChatSync: ObservableObject {
    static let shared = ChatSync()

    @Published private(set) var lastSynced: Date?
    @Published private(set) var problem: String?
    /// This device's name, as other devices see it ("Running on Corbin's MacBook Pro").
    private(set) var device = Host.current().localizedName ?? "Mac"

    private var hubURL = ""
    private var loop: Task<Void, Never>?
    private var pending: [String: Task<Void, Never>] = [:]
    private var activeObserver: NSObjectProtocol?
    private var pulling = false

    static let interval: Duration = .seconds(20)

    private var hub: HubClient { HubClient(baseURL: hubURL) }
    private var sinceKey: String { "wl.chatSync.since.\(hubURL)" }

    /// Call from the main window. Restarts when the hub address changes.
    func start(hubURL: String, device: String) {
        let changed = hubURL != self.hubURL
        self.hubURL = hubURL
        if !device.isEmpty { self.device = device }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    _ = Task { () async -> Void in await ChatSync.shared.pull() }
                }
            }
        }
        if changed { loop?.cancel(); loop = nil }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pull()
                try? await Task.sleep(for: ChatSync.interval)
            }
        }
    }

    // MARK: Up

    /// Sends this chat to the hub shortly (several quick changes become one upload).
    func schedulePush(_ record: ChatRecord) {
        guard !hubURL.isEmpty else { return }
        pending[record.id]?.cancel()
        pending[record.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.pending[record.id] = nil
            // Send the newest copy this device has, not the one captured when the push was asked for.
            let latest = ChatStore.shared.record(record.id) ?? record
            await self.push(latest)
        }
    }

    private func push(_ record: ChatRecord) async {
        do {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
            var body: [String: Any] = [
                "record": json,
                "updated": Self.iso(record.updated),
                "device": device,
                "title": record.title,
                "agent_id": record.agentID,
            ]
            if let projectID = record.projectID { body["project_id"] = projectID }
            let data = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: try hub.url("/api/app-chats/\(record.id)"), timeoutInterval: 30)
            request.httpMethod = "PUT"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (reply, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 409 {
                // Another device changed this chat after us: take its copy.
                if let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                   let detail = object["detail"] as? [String: Any],
                   let chat = detail["chat"] as? [String: Any],
                   let remote = Self.decode(chat["record"]) {
                    ChatStore.shared.adoptRemote(remote)
                }
            } else if code == 404 {
                problem = "This hub doesn't keep chats for other devices yet. Update the hub to sync chats."
            } else if !(200..<300).contains(code) {
                problem = "Couldn't send a chat to the hub (HTTP \(code))."
            } else {
                problem = nil
            }
        } catch {
            problem = "Couldn't reach the hub to sync chats."
        }
    }

    /// Removes the chat from every device (the copy in the project's logbook stays).
    func pushDelete(_ id: String) {
        guard !hubURL.isEmpty else { return }
        pending[id]?.cancel()
        pending[id] = nil
        let device = device
        Task { _ = try? await hub.data("/api/app-chats/\(id)", query: ["device": device], method: "DELETE") }
    }

    // MARK: Down

    /// Brings in every chat changed on other devices since the last pull.
    func pull() async {
        guard !hubURL.isEmpty, !pulling else { return }
        pulling = true
        defer { pulling = false }
        let since = UserDefaults.standard.string(forKey: sinceKey)
        do {
            var query = ["limit": "2000"]
            if let since { query["since"] = since }
            let data = try await hub.data("/api/app-chats", query: query, timeout: 30)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let now = object["now"] as? String,
                  let chats = object["chats"] as? [[String: Any]] else { return }
            var seen = Set<String>()
            for chat in chats {
                guard let id = chat["id"] as? String else { continue }
                seen.insert(id)
                if chat["deleted"] as? Bool == true {
                    ChatStore.shared.removeLocal(id)
                } else if let remote = Self.decode(chat["record"]) {
                    ChatStore.shared.adoptRemote(remote)
                }
            }
            // First sync with this hub: send up the chats only this device has.
            if since == nil {
                for record in ChatStore.shared.records where !seen.contains(record.id) { schedulePush(record) }
            }
            UserDefaults.standard.set(now, forKey: sinceKey)
            lastSynced = Date()
            if problem?.hasPrefix("Couldn't reach") == true { problem = nil }
        } catch HubClient.HubError.http(404) {
            problem = "This hub doesn't keep chats for other devices yet. Update the hub to sync chats."
        } catch {
            problem = "Couldn't reach the hub to sync chats."
        }
    }

    // MARK: Helpers

    nonisolated static func decode(_ value: Any?) -> ChatRecord? {
        guard let value, !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(ChatRecord.self, from: data)
    }

    nonisolated static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
