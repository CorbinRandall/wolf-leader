import AppKit
import Foundation

/// Every chat on this Mac, and the ones running right now. Chats keep running while you look at
/// other pages, and are kept on disk so they can be picked up after a restart.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var records: [ChatRecord] = []
    private var sessions: [String: ChatSession] = [:]

    static var folder: URL { ConfigStore.sessionDir.appendingPathComponent("chats", isDirectory: true) }

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
    func create(project: ProjectRef?, agent: AgentKind, mode: PermissionMode? = nil) -> ChatRecord {
        // New chats start the way the rules for every chat say (Full auto unless changed).
        let mode = mode ?? ChatRules.shared.defaultMode
        let now = Date()
        let id = UUID().uuidString.lowercased()
        let cwd = project.map { ProjectWorkspace.folder(slug: $0.slug).path } ?? ProjectWorkspace.looseFolder(chatID: id).path
        let record = ChatRecord(id: id, projectID: project?.id, projectName: project?.name, projectSlug: project?.slug,
                                agentID: agent.id, title: "New chat", cwd: cwd, mode: mode, agentSessionID: nil,
                                items: [], created: now, updated: now)
        write(record)
        return record
    }

    /// Keeps the chat on this Mac and (unless it just came from the hub) sends it to the hub.
    func write(_ record: ChatRecord, sync: Bool = true) {
        if sync { ChatSync.shared.schedulePush(record) }
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

    /// Removes the chat from Wolf Leader's chat list on every device. The copy saved in the
    /// project's logbook stays.
    func remove(_ id: String) {
        removeLocal(id, force: true)
        ChatSync.shared.pushDelete(id)
    }

    /// Another device removed this chat. A chat that's working here right now is left alone.
    func removeLocal(_ id: String, force: Bool = false) {
        if !force, sessions[id]?.busy == true { return }
        sessions.removeValue(forKey: id)?.shutdown()
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id).json"))
    }

    /// A chat that was opened but never used: nothing sent, never named, and not just opened
    /// (an older app on another device may still be waiting for its first message).
    static func isEmpty(_ record: ChatRecord) -> Bool {
        record.title == "New chat" && !record.items.contains { $0.kind == .user }
            && Date().timeIntervalSince(record.updated) > 10 * 60
    }

    /// Drops chats that were opened but never used, here and on every device. Chats are only made
    /// when the first message is sent now; this clears ones left by older versions and other devices.
    func pruneEmpty() {
        for record in records where Self.isEmpty(record) && sessions[record.id]?.busy != true {
            remove(record.id)
        }
    }

    /// A newer copy of a chat from another device. Its folder is this device's own copy of the
    /// project (or its scratch folder), and an open chat shows the new turns right away.
    func adoptRemote(_ incoming: ChatRecord) {
        if Self.isEmpty(incoming) {
            // Never used on the device that made it: don't list it, and clear it from the hub.
            if record(incoming.id) != nil { removeLocal(incoming.id) }
            ChatSync.shared.pushDelete(incoming.id)
            return
        }
        var remote = incoming
        remote.cwd = remote.projectSlug.map { ProjectWorkspace.folder(slug: $0).path }
            ?? ProjectWorkspace.looseFolder(chatID: remote.id).path
        if let local = record(remote.id) {
            guard remote.updated > local.updated else { return }
            if sessions[remote.id]?.busy == true { return }
        }
        write(remote, sync: false)
        sessions[remote.id]?.adopt(remote)
    }

    /// A chat saved from another tool (Claude Code in a terminal, Codex, Cursor) becomes a Wolf
    /// Leader chat: same project, the conversation so far, and whichever agent you pick carries on.
    func continueHubChat(id hubChatID: Int, with agent: AgentKind, hub: HubClient) async throws -> ChatRecord {
        let data = try await hub.data("/api/chats/\(hubChatID)", query: ["include_messages": "true"], timeout: 30)
        guard let chat = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.failed("The hub sent something unexpected.")
        }
        let project: ProjectRef? = (chat["project_id"] as? Int).map {
            ProjectRef(id: $0, name: chat["project_name"] as? String ?? "Project", slug: chat["project_slug"] as? String)
        }
        var record = create(project: project, agent: agent)
        let messages = (chat["messages"] as? [[String: Any]]) ?? []
        var items: [ChatItem] = messages.suffix(80).compactMap { message in
            let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let kind: ChatItem.Kind = (message["role"] as? String) == "user" ? .user : .agent
            return ChatItem(id: UUID().uuidString, kind: kind, text: text,
                            at: HubDate.parse(message["created_at"] as? String) ?? Date())
        }
        let from = [chat["device_name"] as? String].compactMap { $0 }.filter { $0 != "unraid-server" }.first
        items.append(ChatItem(id: UUID().uuidString, kind: .note,
                              text: "Brought in from \(from.map { "a chat on \($0)" } ?? "a saved chat"). \(agent.name) gets this conversation with your next message."))
        record.items = items
        record.title = AgentText.oneLine(chat["title"] as? String ?? "Continued chat", limit: 60)
        if project == nil, let projectName = chat["project_name"] as? String { record.projectName = projectName }
        record.needsHandoff = items.contains { $0.kind == .user } ? true : nil
        record.updated = Date()
        write(record)
        return record
    }

    /// A chat from the Claude app, Claude Code or Codex on this Mac becomes a Wolf Leader chat,
    /// saved to the ledger right away (so nothing is lost even if it was never saved before).
    /// With the same AI it resumes that very session, in its own folder; with another AI the
    /// conversation is handed over. Opening it again reopens the same chat.
    func openLocal(_ local: LocalSession, with agent: AgentKind, hubURL: String) -> ChatRecord {
        let key = "wl.localSession.\(local.id)"
        if let existing = UserDefaults.standard.string(forKey: key), let chat = record(existing) {
            if chat.agentID != agent.id { session(chat.id)?.switchAgent(to: agent) }
            return record(existing) ?? chat
        }
        var chat = create(project: nil, agent: agent)
        let items = LocalSessions.items(for: local)
        let sameAI = agent.id == local.agentID
        chat.title = AgentText.oneLine(local.title, limit: 60)
        chat.items = items + [ChatItem(id: UUID().uuidString, kind: .note, text: sameAI
            ? "Brought in from the \(local.toolName)\(local.folderName.map { " (\($0))" } ?? ""). \(agent.name) picks this session back up where it stopped, with Wolf Leader's context."
            : "Brought in from the \(local.toolName). \(agent.name) gets this conversation with your next message.")]
        if sameAI, let cwd = local.cwd, FileManager.default.fileExists(atPath: cwd) {
            // The real session lives with its folder: resume it there.
            chat.cwd = cwd
            chat.agentSessionID = local.sessionID
            chat.agentDevice = ChatSync.shared.device
        } else if items.contains(where: { $0.kind == .user }) {
            chat.needsHandoff = true
        }
        chat.contextSent = false
        chat.updated = Date()
        write(chat)
        UserDefaults.standard.set(chat.id, forKey: key)
        let snapshot = chat
        Task { try? await WolfChatSync.save(snapshot, hubURL: hubURL) }
        return chat
    }

    /// Local sessions already opened here, by LocalSession.id.
    func openedLocal(_ local: LocalSession) -> ChatRecord? {
        UserDefaults.standard.string(forKey: "wl.localSession.\(local.id)").flatMap { record($0) }
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
    private var skillsFingerprint = ""

    init(record: ChatRecord, store: ChatStore) {
        self.record = record
        self.id = record.id
        self.store = store
    }

    var pendingApprovals: Bool { record.items.contains { $0.kind == .approval && $0.status == .pending } }

    // MARK: Talking to the agent

    /// This device, as the other devices see it.
    private var thisDevice: String { ChatSync.shared.device }

    func send(_ text: String, images: [ChatImage] = [], config: ConfigStore) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !images.isEmpty), !busy else { return }
        if let other = record.busyElsewhere(than: thisDevice) {
            append(ChatItem(id: UUID().uuidString, kind: .note,
                            text: "This chat is working on \(other) right now. Send again when it's done there."))
            return
        }
        hubURL = config.config.hubURL
        let hub = config.hub
        self.hub = hub
        let person = config.config.person
        // "Never ask" applies to every chat, old ones too.
        if ChatRules.shared.neverAsk, record.mode != .auto {
            record.mode = .auto
            driver?.stop()
            driver = nil
        }
        // If skills changed on disk since this process started, reconnect so the agent sees them.
        let currentFingerprint = SkillSyncer.fingerprint()
        if !skillsFingerprint.isEmpty, skillsFingerprint != currentFingerprint, driver != nil {
            driver?.stop(); driver = nil
            append(ChatItem(id: UUID().uuidString, kind: .note, text: "Skills updated — reconnecting to pick them up."))
        }
        let earlier = record.items
        append(ChatItem(id: UUID().uuidString, kind: .user, text: text, images: images.isEmpty ? nil : images))
        if record.title == "New chat" { record.title = text.isEmpty ? "Image chat" : AgentText.oneLine(text, limit: 60) }
        busy = true
        claim()
        persist()
        Task {
            do {
                if driver == nil { try await connect() }
                var parts: [String] = []
                // Wolf Leader's context goes first: who you are, and for a project chat its
                // brief, memories and ledger (what every assistant has done in it so far).
                if !record.contextSent || record.needsHandoff == true {
                    let project = record.projectID.map { ProjectRef(id: $0, name: record.projectName ?? "Project", slug: record.projectSlug) }
                    if let context = await WolfChatSync.context(hub: hub, project: project, person: person,
                                                                excludingSession: record.hubSessionID) {
                        parts.append(context)
                    }
                    // Your rules and skills for every chat, whichever agent runs it.
                    if let rules = await ChatRules.shared.contextBlock(hub: hub) { parts.append(rules) }
                    if ChatRules.shared.hubTools { parts.append(WolfTools.instructions(projectSlug: record.projectSlug)) }
                }
                if record.needsHandoff == true, let handoff = WolfChatSync.handoff(earlier, agentName: record.agent?.name ?? "the agent") {
                    parts.append(handoff)
                }
                parts.append(text)
                record.contextSent = true
                record.needsHandoff = nil
                try await driver?.send(parts.joined(separator: "\n\n"), images: images)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Marks the chat as working on this device, so other devices wait. Renewed while it works.
    private func claim() {
        record.activeDevice = thisDevice
        record.activeUntil = Date().addingTimeInterval(15 * 60)
    }

    private func release() {
        record.activeDevice = nil
        record.activeUntil = nil
    }

    /// A newer copy of this chat arrived from another device.
    func adopt(_ remote: ChatRecord) {
        guard !busy else { return }
        // If another device ran the agent since, this device's agent session is out of date.
        if remote.agentDevice != thisDevice, remote.agentSessionID != record.agentSessionID {
            driver?.stop()
            driver = nil
        }
        record = remote
    }

    /// Carry on this chat with another agent. It gets the conversation so far with the next message.
    func switchAgent(to agent: AgentKind) {
        guard !busy, agent.id != record.agentID else { return }
        driver?.stop()
        driver = nil
        let from = record.agent?.name ?? record.agentID
        record.agentID = agent.id
        record.agentSessionID = nil
        record.agentDevice = nil
        if record.items.contains(where: { $0.kind == .user }) { record.needsHandoff = true }
        append(ChatItem(id: UUID().uuidString, kind: .note,
                        text: "Switched from \(from) to \(agent.name). \(agent.name) gets the conversation so far with your next message."))
        persist()
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
        guard let executable = AgentRegistry.shared.program(for: agent) else { throw AgentError.notInstalled(agent) }
        if ProjectWorkspace.isWorkspace(record.cwd), let slug = record.projectSlug, let hub {
            preparing = "Bringing \(record.projectName ?? "the project") in from the server…"
            let note = await ProjectWorkspace.prepare(hub: hub, slug: slug, path: record.cwd)
            preparing = nil
            if let note { append(ChatItem(id: UUID().uuidString, kind: .note, text: note)) }
        }
        skillsFingerprint = SkillSyncer.fingerprint()
        connecting = true
        defer { connecting = false }
        // An agent session only exists on the device that ran it. Anywhere else (or with no
        // session to resume) the agent starts fresh and is handed the conversation so far.
        let resumable = record.agentDevice == nil || record.agentDevice == thisDevice
        let resumeID = resumable ? record.agentSessionID : nil
        if resumeID == nil, record.items.filter({ $0.kind == .user }).count > 1 { record.needsHandoff = true }
        // Wolf Leader's tools (search, recall, remember…) in the chat, unless the rules turn them off.
        let tools = WolfTools.url(hubURL: hubURL)
        let driver: AgentDriver
        switch agent.proto {
        case .claude:
            driver = ClaudeDriver(executable: executable, cwd: record.cwd, mode: record.mode, resumeID: resumeID, toolsURL: tools)
        case .codex:
            driver = CodexDriver(executable: executable, args: agent.args, cwd: record.cwd, mode: record.mode, resumeID: resumeID,
                                 toolsURL: tools)
        case .acp:
            driver = AcpDriver(name: agent.name, executable: executable, args: agent.args, cwd: record.cwd, mode: record.mode,
                               resumeID: resumeID, toolsURL: tools)
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
        release()
        persist()
    }

    // MARK: Applying what the agent reports

    private func apply(_ event: AgentEvent) {
        // A long turn keeps its claim on the chat so other devices keep waiting.
        if busy, let until = record.activeUntil, until.timeIntervalSinceNow < 5 * 60 {
            claim()
            persist()
        }
        switch event {
        case .sessionID(let id):
            record.agentSessionID = id
            record.agentDevice = thisDevice
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
            if ChatRules.shared.neverAsk || record.mode == .auto {
                // "Never ask": approve it for good, so the agent doesn't ask about this again.
                append(ChatItem(id: id, kind: .approval, text: title, detail: detail, status: .allowed))
                DispatchQueue.main.async { [weak self] in self?.driver?.answer(approval: id, allow: true, always: true) }
            } else {
                append(ChatItem(id: id, kind: .approval, text: title, detail: detail, status: .pending))
            }
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
        release()
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
