import AppKit
import Foundation

/// Every chat on this Mac, and the ones running right now. Chats keep running while you look at
/// other pages, and are kept on disk so they can be picked up after a restart.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var records: [ChatRecord] = []
    private var sessions: [String: ChatSession] = [:]

    static var folder: URL { ConfigStore.supportDir.appendingPathComponent("chats", isDirectory: true) }

    private init() {
        load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ChatStore.shared.stopAll() }
        }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        records = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ChatRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    func chats(projectID: Int) -> [ChatRecord] { records.filter { $0.projectID == projectID } }

    func record(_ id: String) -> ChatRecord? { records.first { $0.id == id } }

    func session(_ id: String) -> ChatSession? {
        if let live = sessions[id] { return live }
        guard let record = record(id) else { return nil }
        let session = ChatSession(record: record, store: self)
        sessions[id] = session
        return session
    }

    func isRunning(_ id: String) -> Bool { sessions[id]?.busy ?? false }

    /// A new chat. In a project, the agent works in the project's copy from the server; without
    /// one, in a scratch folder of its own until it's connected to a project.
    func create(project: ProjectRef?, agent: AgentKind, mode: PermissionMode = .ask) -> ChatRecord {
        let now = Date()
        let id = UUID().uuidString.lowercased()
        let cwd = project.map { ProjectWorkspace.folder(slug: $0.slug).path } ?? ProjectWorkspace.looseFolder(chatID: id).path
        let record = ChatRecord(id: id, projectID: project?.id, projectName: project?.name, projectSlug: project?.slug,
                                agentID: agent.id, title: "New chat", cwd: cwd, mode: mode, agentSessionID: nil,
                                items: [], created: now, updated: now)
        write(record)
        return record
    }

    func write(_ record: ChatRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.insert(record, at: 0) }
        records.sort { $0.updated > $1.updated }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: Self.folder.appendingPathComponent("\(record.id).json"), options: .atomic)
        } catch {
            NSLog("Wolf Leader: couldn't keep chat \(record.id): \(error)")
        }
    }

    /// Removes the chat from this Mac. Its copy on the hub stays in the project's logbook.
    func remove(_ id: String) {
        sessions.removeValue(forKey: id)?.shutdown()
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id).json"))
    }

    func stopAll() {
        for session in sessions.values { session.shutdown() }
    }
}

/// The project a chat belongs to.
struct ProjectRef: Hashable {
    var id: Int
    var name: String
    var slug: String

    init(id: Int, name: String, slug: String?) {
        self.id = id
        self.name = name
        self.slug = slug ?? String(id)
    }

    init(_ project: HubProject) { self.init(id: project.id, name: project.name, slug: project.slug) }
}

/// One open chat: its record, the running agent, and what's happening right now.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    enum SaveState: Equatable { case idle, saving, saved(Date), failed(String) }

    @Published private(set) var record: ChatRecord
    @Published private(set) var busy = false
    @Published private(set) var connecting = false
    /// What's happening before the agent starts, e.g. bringing the project in from the server.
    @Published private(set) var preparing: String?
    @Published private(set) var saveState: SaveState = .idle

    nonisolated let id: String
    private weak var store: ChatStore?
    private var driver: AgentDriver?
    private var hubURL = ""
    private var hub: HubClient?

    init(record: ChatRecord, store: ChatStore) {
        self.record = record
        self.id = record.id
        self.store = store
    }

    var pendingApprovals: Bool { record.items.contains { $0.kind == .approval && $0.status == .pending } }

    // MARK: Talking to the agent

    func send(_ text: String, config: ConfigStore) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        hubURL = config.config.hubURL
        let hub = config.hub
        self.hub = hub
        append(ChatItem(id: UUID().uuidString, kind: .user, text: text))
        if record.title == "New chat" { record.title = AgentText.oneLine(text, limit: 60) }
        busy = true
        persist()
        Task {
            do {
                if driver == nil { try await connect() }
                var prompt = text
                if !record.contextSent, let projectID = record.projectID, let name = record.projectName,
                   let context = await WolfChatSync.context(hub: hub, projectID: projectID,
                                                            projectKey: record.projectSlug ?? String(projectID), projectName: name) {
                    prompt = context + "\n\n" + text
                }
                record.contextSent = true
                try await driver?.send(prompt)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func interrupt() { driver?.interrupt() }

    func answer(_ itemID: String, allow: Bool, always: Bool = false) {
        guard let index = record.items.firstIndex(where: { $0.id == itemID }) else { return }
        record.items[index].status = allow ? .allowed : .denied
        driver?.answer(approval: itemID, allow: allow, always: always)
    }

    func setMode(_ mode: PermissionMode) {
        guard mode != record.mode else { return }
        record.mode = mode
        persist()
        // The mode is fixed when an agent starts, so start it again for the next message.
        if !busy { driver?.stop(); driver = nil }
    }

    /// Connect a chat to a project (or move it to another one). The hub refiles it, and the next
    /// message brings in that project's notes.
    func attach(to project: ProjectRef, config: ConfigStore) {
        guard project.id != record.projectID else { return }
        hubURL = config.config.hubURL
        hub = config.hub
        record.projectID = project.id
        record.projectName = project.name
        record.projectSlug = project.slug
        record.contextSent = false
        append(ChatItem(id: UUID().uuidString, kind: .note, text: "Connected to \(project.name). The next message brings in its notes."))
        persist()
        saveToHub()
    }

    func shutdown() {
        driver?.stop()
        driver = nil
        busy = false
    }

    private func connect() async throws {
        guard let agent = record.agent else { throw AgentError.failed("This chat's agent isn't known to this version of Wolf Leader.") }
        guard let executable = AgentLocator.find(agent.binary) else { throw AgentError.notInstalled(agent) }
        if ProjectWorkspace.isWorkspace(record.cwd), let slug = record.projectSlug, let hub {
            preparing = "Bringing \(record.projectName ?? "the project") in from the server…"
            let note = await ProjectWorkspace.prepare(hub: hub, slug: slug, path: record.cwd)
            preparing = nil
            if let note { append(ChatItem(id: UUID().uuidString, kind: .note, text: note)) }
        }
        connecting = true
        defer { connecting = false }
        let driver: AgentDriver
        switch agent.proto {
        case .claude:
            driver = ClaudeDriver(executable: executable, cwd: record.cwd, mode: record.mode, resumeID: record.agentSessionID)
        case .codex:
            driver = CodexDriver(executable: executable, args: agent.args, cwd: record.cwd, mode: record.mode, resumeID: record.agentSessionID)
        case .acp:
            driver = AcpDriver(name: agent.name, executable: executable, args: agent.args, cwd: record.cwd, mode: record.mode,
                               resumeID: record.agentSessionID)
        }
        driver.onEvent = { [weak self] event in self?.apply(event) }
        self.driver = driver
        do {
            try await driver.start()
        } catch {
            driver.stop()
            self.driver = nil
            throw error
        }
    }

    private func fail(_ message: String) {
        append(ChatItem(id: UUID().uuidString, kind: .error, text: message))
        busy = false
        persist()
    }

    // MARK: Applying what the agent reports

    private func apply(_ event: AgentEvent) {
        switch event {
        case .sessionID(let id):
            record.agentSessionID = id
        case .textDelta(let id, let text):
            extend(id, kind: .agent, with: text)
        case .text(let id, let text):
            if let index = index(id, .agent) { record.items[index].text = text } else { append(ChatItem(id: id, kind: .agent, text: text)) }
        case .thinkingDelta(let id, let text):
            extend(id, kind: .thinking, with: text)
        case .toolStarted(let id, let title, let detail):
            if let index = index(id, .tool) {
                record.items[index].text = title
            } else {
                append(ChatItem(id: id, kind: .tool, text: title, detail: detail, status: .running))
            }
        case .toolUpdated(let id, let output, let status):
            guard let index = index(id, .tool) else { return }
            if let output, !output.isEmpty { record.items[index].output = output }
            if let status { record.items[index].status = status }
        case .approval(let id, let title, let detail):
            append(ChatItem(id: id, kind: .approval, text: title, detail: detail, status: .pending))
        case .note(let text):
            append(ChatItem(id: UUID().uuidString, kind: .note, text: text))
        case .turnFinished(let error):
            if let error { append(ChatItem(id: UUID().uuidString, kind: .error, text: error)) }
            finishTurn()
        case .exited(let reason):
            driver = nil
            if let reason { append(ChatItem(id: UUID().uuidString, kind: .error, text: reason)) }
            if busy { finishTurn() }
        }
    }

    private func finishTurn() {
        busy = false
        for index in record.items.indices where record.items[index].status == .running { record.items[index].status = .done }
        for index in record.items.indices where record.items[index].status == .pending { record.items[index].status = .denied }
        persist()
        saveToHub()
        sendFilesToServer()
    }

    /// The agent's changes go back to the project's folder on the server after every reply.
    private func sendFilesToServer() {
        guard ProjectWorkspace.isWorkspace(record.cwd) else { return }
        let path = record.cwd
        let message = "Wolf Leader: \(record.agent?.name ?? "agent") chat, \(record.title)"
        Task {
            if let note = await ProjectWorkspace.sync(path: path, message: message) {
                append(ChatItem(id: UUID().uuidString, kind: .note, text: note))
                persist()
            }
        }
    }

    private func index(_ id: String, _ kind: ChatItem.Kind) -> Int? {
        record.items.lastIndex { $0.id == id && $0.kind == kind }
    }

    private func extend(_ id: String, kind: ChatItem.Kind, with text: String) {
        if let index = index(id, kind) { record.items[index].text += text } else { append(ChatItem(id: id, kind: kind, text: text)) }
    }

    private func append(_ item: ChatItem) {
        record.items.append(item)
    }

    private func persist() {
        record.updated = Date()
        store?.write(record)
    }

    private func saveToHub() {
        let snapshot = record
        let hubURL = hubURL
        saveState = .saving
        Task {
            do {
                try await WolfChatSync.save(snapshot, hubURL: hubURL)
                saveState = .saved(Date())
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }
}
