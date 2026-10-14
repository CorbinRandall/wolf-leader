import Foundation

// Models and endpoint helpers for the hub REST API (ide_storage/main.py). Every field is optional
// or defaulted and numbers/strings are accepted interchangeably, so a hub that adds, drops or
// retypes a column never breaks the app.

// MARK: - Lenient decoding

struct HubJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s; intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

extension KeyedDecodingContainer where K == HubJSONKey {
    /// First key that holds a string, number or bool, as a non-empty string.
    func str(_ keys: String...) -> String? {
        for k in keys {
            let key = HubJSONKey(k)
            guard contains(key) else { continue }
            if let v = try? decode(String.self, forKey: key) {
                if !v.isEmpty { return v }
                continue
            }
            if let v = try? decode(Int.self, forKey: key) { return String(v) }
            if let v = try? decode(Double.self, forKey: key) { return String(v) }
            if let v = try? decode(Bool.self, forKey: key) { return v ? "true" : "false" }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for k in keys {
            let key = HubJSONKey(k)
            guard contains(key) else { continue }
            if let v = try? decode(Int.self, forKey: key) { return v }
            if let v = try? decode(Double.self, forKey: key), v.isFinite { return Int(v) }
            if let s = try? decode(String.self, forKey: key), let v = Int(s) { return v }
        }
        return nil
    }

    func double(_ keys: String...) -> Double? {
        for k in keys {
            let key = HubJSONKey(k)
            guard contains(key) else { continue }
            if let v = try? decode(Double.self, forKey: key) { return v }
            if let s = try? decode(String.self, forKey: key), let v = Double(s) { return v }
        }
        return nil
    }
}

private struct SkipValue: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Decodes either a bare array or an object wrapping one (`{"projects": [...]}` and friends).
/// Elements that fail to decode are skipped instead of failing the whole list.
struct HubList<T: Decodable>: Decodable {
    var items: [T]

    static var wrapperKeys: [String] {
        ["projects", "chats", "memories", "results", "items", "active", "data", "columns", "skills", "snippets"]
    }

    init(from decoder: Decoder) throws {
        if var arr = try? decoder.unkeyedContainer() {
            items = Self.lossy(&arr)
            return
        }
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        for k in Self.wrapperKeys {
            let key = HubJSONKey(k)
            guard c.contains(key), var arr = try? c.nestedUnkeyedContainer(forKey: key) else { continue }
            items = Self.lossy(&arr)
            return
        }
        items = []
    }

    private static func lossy(_ arr: inout UnkeyedDecodingContainer) -> [T] {
        var out: [T] = []
        while !arr.isAtEnd {
            if let v = try? arr.decode(T.self) {
                out.append(v)
            } else if (try? arr.decode(SkipValue.self)) == nil {
                break
            }
        }
        return out
    }
}

// MARK: - Dates

enum HubDate {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm MM/dd/yyyy"
        return f
    }()

    /// Parses the hub's timestamps: naive UTC ISO (`datetime.utcnow().isoformat()`), with or without
    /// fractional seconds, a `Z`/offset suffix, a space instead of `T`, or a bare date.
    static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let epoch = Double(s), epoch > 100_000_000 {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        if s.count == 10 { s += "T00:00:00" }
        if s.count > 10 {
            let i = s.index(s.startIndex, offsetBy: 10)
            if s[i] == " " { s.replaceSubrange(i...i, with: "T") }
        }
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            s.removeSubrange(dot..<end)
        }
        let timePart = s.count > 19 ? String(s.dropFirst(19)) : ""
        let hasZone = s.hasSuffix("Z") || timePart.contains("+") || timePart.contains("-")
        if !hasZone { s += "Z" }
        return iso.date(from: s)
    }

    static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        return display.string(from: date)
    }

    static func format(_ raw: String?) -> String {
        guard let d = parse(raw) else { return raw ?? "" }
        return display.string(from: d)
    }
}

// MARK: - Models

struct HubProject: Decodable, Identifiable, Hashable {
    var id: Int
    var slug: String?
    var name: String
    var description: String?
    var path: String?
    var status: String
    var chatCount: Int
    var memoryCount: Int
    var snippetCount: Int
    var updatedAt: String?
    var owner: String?
    var ownerSource: String?
    var tags: [String]

    var updated: Date? { HubDate.parse(updatedAt) }
    /// `slug` when the hub has one, else the numeric id (both work for agent-brief).
    var key: String { slug ?? String(id) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id", "project_id") ?? 0
        slug = c.str("slug")
        name = c.str("name", "title", "slug") ?? "Untitled project"
        description = c.str("description")
        path = c.str("path", "compose_path")
        status = c.str("status") ?? "backlog"
        chatCount = c.int("chat_count", "chats") ?? 0
        memoryCount = c.int("memory_count", "memories") ?? 0
        snippetCount = c.int("snippet_count", "snippets") ?? 0
        updatedAt = c.str("updated_at", "last_activity", "created_at")
        owner = c.str("owner")
        ownerSource = c.str("owner_source")
        // Tags arrive as a list or as JSON text.
        if let list = try? c.decode([String].self, forKey: HubJSONKey("tags")) {
            tags = list
        } else if let raw = c.str("tags"), let data = raw.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) {
            tags = list
        } else {
            tags = []
        }
    }

    /// Match the web board's compatibility mapping for statuses created before Kanban existed.
    func kanbanStatus(in columns: [HubKanbanColumn]) -> String {
        if columns.contains(where: { $0.status == status }) { return status }
        if status == "done" || status == "archived" {
            return columns.first(where: { $0.status == "done" })?.status ?? columns.first?.status ?? status
        }
        if status == "backlog" {
            return columns.first(where: { $0.status == "backlog" })?.status ?? columns.first?.status ?? status
        }
        return columns.first(where: { $0.status == "in_progress" })?.status ?? columns.first?.status ?? status
    }
}

struct HubKanbanColumn: Decodable, Identifiable, Hashable {
    var status: String
    var label: String
    var description: String?
    var id: String { status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        status = c.str("status") ?? "backlog"
        label = c.str("label") ?? status.replacingOccurrences(of: "_", with: " ").capitalized
        description = c.str("description")
    }
}

struct HubSkill: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String?
    var fileCount: Int
    var sizeBytes: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.str("id", "name") ?? "skill"
        name = c.str("name", "id") ?? id
        description = c.str("description")
        fileCount = c.int("file_count") ?? 0
        sizeBytes = c.int("size_bytes") ?? 0
    }
}

struct HubSkillsResponse: Decodable {
    var skills: [HubSkill]
    var installPrompt: String
    var publishPrompt: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        skills = (try? c.decode([HubSkill].self, forKey: HubJSONKey("skills"))) ?? []
        installPrompt = c.str("install_prompt") ?? ""
        publishPrompt = c.str("publish_prompt") ?? ""
    }
}

struct HubDuplicateGroup: Decodable, Identifiable {
    var key: String
    var projects: [HubProject]
    var id: String { key }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        key = c.str("key") ?? UUID().uuidString
        projects = (try? c.decode([HubProject].self, forKey: HubJSONKey("projects"))) ?? []
    }
}

struct HubDuplicateResponse: Decodable {
    var groups: [HubDuplicateGroup]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        groups = (try? c.decode([HubDuplicateGroup].self, forKey: HubJSONKey("groups"))) ?? []
    }
}

struct HubSnippet: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String
    var language: String?
    var content: String
    var projectID: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        title = c.str("title") ?? "Untitled snippet"
        language = c.str("language")
        content = c.str("content") ?? ""
        projectID = c.int("project_id")
    }
}

struct HubChat: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String
    var projectID: Int?
    var projectName: String?
    var projectSlug: String?
    var deviceName: String?
    var messageCount: Int?
    var updatedAt: String?
    var occurredAt: String?

    /// When the chat happened (occurred_at), falling back to the last save.
    var when: Date? { HubDate.parse(occurredAt) ?? HubDate.parse(updatedAt) }
    var saved: Date? { HubDate.parse(updatedAt) ?? HubDate.parse(occurredAt) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id", "chat_id") ?? 0
        title = c.str("title") ?? "Untitled chat"
        projectID = c.int("project_id")
        projectName = c.str("project_name", "project")
        projectSlug = c.str("project_slug", "slug")
        deviceName = c.str("device_name")
        messageCount = c.int("message_count")
        updatedAt = c.str("updated_at", "created_at")
        occurredAt = c.str("occurred_at")
    }
}

/// The memory types the hub mines (decision, constraint, ...), in display order.
enum MemoryKind: String, CaseIterable, Identifiable {
    case decision, constraint, problem, active_work, goal, note, caveat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .decision: return "Decisions"
        case .constraint: return "Constraints"
        case .problem: return "Problems"
        case .active_work: return "Active work"
        case .goal: return "Goals"
        case .note: return "Notes"
        case .caveat: return "Caveats"
        }
    }

    var symbol: String {
        switch self {
        case .decision: return "checkmark.seal"
        case .constraint: return "lock"
        case .problem: return "exclamationmark.triangle"
        case .active_work: return "hammer"
        case .goal: return "flag"
        case .note: return "note.text"
        case .caveat: return "info.circle"
        }
    }
}

struct HubMemory: Decodable, Identifiable, Hashable {
    var id: Int
    var type: String
    var content: String
    var projectID: Int?
    var sourceChatID: Int?
    var updatedAt: String?

    var kind: MemoryKind? { MemoryKind(rawValue: type.lowercased()) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        type = c.str("type", "memory_type") ?? "note"
        content = c.str("content", "text") ?? ""
        projectID = c.int("project_id")
        sourceChatID = c.int("source_chat_id")
        updatedAt = c.str("updated_at", "created_at")
    }
}

struct HubSearchHit: Decodable, Identifiable, Hashable {
    /// memory | project | chat | message | howl | catalog | chunk
    var kind: String
    var refID: Int
    var title: String?
    var content: String?
    var projectID: Int?
    var chatID: Int?
    var memoryType: String?
    var slug: String?
    var path: String?
    var chatTitle: String?
    var stamp: String?
    var rank: Double?

    var id: String { "\(kind):\(refID):\(chatID ?? 0)" }
    var date: Date? { HubDate.parse(stamp) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        kind = c.str("kind") ?? "result"
        refID = c.int("id", "ref_id") ?? 0
        title = c.str("title", "chat_title", "name")
        content = c.str("content", "snippet", "embed_text")
        projectID = c.int("project_id")
        chatID = c.int("chat_id")
        memoryType = c.str("memory_type")
        slug = c.str("slug", "project_slug")
        path = c.str("path")
        chatTitle = c.str("chat_title")
        stamp = c.str("updated_at", "created_at", "occurred_at")
        rank = c.double("rrf_score", "rank", "score")
    }

    /// The chat this hit belongs to, if any (chat rows and message rows).
    var linkedChatID: Int? {
        switch kind {
        case "chat": return refID
        case "message": return chatID
        default: return nil
        }
    }

    /// The project this hit belongs to, if any.
    var linkedProjectID: Int? {
        kind == "project" ? refID : projectID
    }
}

// MARK: - Endpoints

extension HubClient {
    private var root: String { baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    /// Hub web UI.
    var webURL: URL? { URL(string: root + "/") }
    func webURL(chat id: Int) -> URL? { URL(string: root + "/?chat=\(id)") }
    func webURL(project id: Int) -> URL? { URL(string: root + "/?project=\(id)") }
    func briefURL(projectKey: String) -> URL? {
        let key = projectKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectKey
        return URL(string: root + "/api/projects/\(key)/agent-brief")
    }

    /// GET /api/projects (newest activity first).
    func projects(limit: Int = 500) async throws -> [HubProject] {
        try await get("/api/projects", query: ["limit": String(limit)], as: HubList<HubProject>.self).items
    }

    /// GET /api/chats (active chats across all projects, newest save first).
    func recentChats(limit: Int = 10) async throws -> [HubChat] {
        try await get("/api/chats", query: ["limit": String(limit)], as: HubList<HubChat>.self).items
    }

    /// GET /api/projects/{id}/chats → `active`.
    func chats(projectID: Int, limit: Int = 20) async throws -> [HubChat] {
        try await get("/api/projects/\(projectID)/chats", query: ["limit": String(limit)],
                      as: HubList<HubChat>.self).items
    }

    /// GET /api/memories?project_id= (active memories, newest first).
    func memories(projectID: Int, limit: Int = 500) async throws -> [HubMemory] {
        try await get("/api/memories", query: ["project_id": String(projectID), "limit": String(limit)],
                      as: HubList<HubMemory>.self).items
    }

    /// GET /api/search?q= (hybrid keyword + vector search).
    func search(_ q: String, limit: Int = 40) async throws -> [HubSearchHit] {
        try await get("/api/search", query: ["q": q, "limit": String(limit)], as: HubList<HubSearchHit>.self).items
    }

    func kanbanColumns() async throws -> [HubKanbanColumn] {
        try await get("/api/kanban/columns", as: HubList<HubKanbanColumn>.self).items
    }

    func createKanbanColumn(label: String, description: String) async throws -> [HubKanbanColumn] {
        let body = try JSONSerialization.data(withJSONObject: ["label": label, "description": description])
        let response = try await data("/api/kanban/columns", method: "POST", body: body)
        return try JSONDecoder().decode(HubList<HubKanbanColumn>.self, from: response).items
    }

    func updateKanbanColumn(status: String, label: String, description: String) async throws -> [HubKanbanColumn] {
        let body = try JSONSerialization.data(withJSONObject: ["label": label, "description": description])
        let response = try await data("/api/kanban/columns/\(status)", method: "PUT", body: body)
        return try JSONDecoder().decode(HubList<HubKanbanColumn>.self, from: response).items
    }

    func reorderKanbanColumns(_ statuses: [String]) async throws -> [HubKanbanColumn] {
        let body = try JSONSerialization.data(withJSONObject: ["statuses": statuses])
        let response = try await data("/api/kanban/columns-order", method: "PUT", body: body)
        return try JSONDecoder().decode(HubList<HubKanbanColumn>.self, from: response).items
    }

    func deleteKanbanColumn(status: String, moveTo: String) async throws -> [HubKanbanColumn] {
        let response = try await data("/api/kanban/columns/\(status)", query: ["move_to": moveTo], method: "DELETE")
        return try JSONDecoder().decode(HubList<HubKanbanColumn>.self, from: response).items
    }

    func updateProjectStatus(id: Int, status: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["status": status])
        _ = try await data("/api/projects/\(id)", method: "PUT", body: body)
    }

    func skills() async throws -> HubSkillsResponse {
        try await get("/api/skills", as: HubSkillsResponse.self)
    }

    /// Take a skill out of the master set. The hub keeps the files in its trash.
    func deleteSkill(id: String) async throws {
        _ = try await data("/api/skills/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id), method: "DELETE")
    }

    /// Add a skill from a ZIP. The hub names it from SKILL.md, its folder, or the file name.
    func addSkill(archive: Data, filename: String, overwrite: Bool) async throws -> String {
        try await postSkill(["archive_base64": archive.base64EncodedString(), "filename": filename, "overwrite": overwrite])
    }

    /// Add a skill from loose files: a folder's contents, or a single SKILL.md.
    func addSkill(files: [(path: String, data: Data)], filename: String?, overwrite: Bool) async throws -> String {
        var payload: [String: Any] = [
            "files": files.map { ["path": $0.path, "content_base64": $0.data.base64EncodedString()] },
            "overwrite": overwrite,
        ]
        if let filename { payload["filename"] = filename }
        return try await postSkill(payload)
    }

    private func postSkill(_ payload: [String: Any]) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let reply = try await data("/api/skills/import", method: "POST", body: body, timeout: 60)
        let skill = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["skill"] as? [String: Any]
        return (skill?["name"] as? String) ?? "skill"
    }

    func duplicateGroups() async throws -> [HubDuplicateGroup] {
        try await get("/api/projects/duplicates", as: HubDuplicateResponse.self).groups
    }

    func mergeProjects(targetID: Int, sourceIDs: [Int]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["target_id": targetID, "source_ids": sourceIDs])
        _ = try await data("/api/projects/merge", method: "POST", body: body, timeout: 30)
    }

    func snippets(projectID: Int? = nil) async throws -> [HubSnippet] {
        var query: [String: String] = ["limit": "500"]
        if let projectID { query["project_id"] = String(projectID) }
        return try await get("/api/snippets", query: query, as: HubList<HubSnippet>.self).items
    }

    func createSnippet(title: String, language: String, content: String, projectID: Int?) async throws {
        var payload: [String: Any] = ["title": title, "language": language, "content": content]
        if let projectID { payload["project_id"] = projectID }
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await data("/api/snippets", method: "POST", body: body)
    }

    func deleteSnippet(id: Int) async throws {
        _ = try await data("/api/snippets/\(id)", method: "DELETE")
    }
}

// MARK: - Repo health (GET /api/repos)

struct HubRepoProject: Decodable, Identifiable, Hashable {
    var id: Int
    var slug: String
    var name: String
    var state: String
    var why: String?
    var folder: String?
    var folders: [String]
    var sharedFolders: [String]
    var remote: String?
    var branch: String?
    var lastCommit: String?
    var lastCommitAt: String?
    var lastSubject: String?
    var dirtyFiles: Int?
    var deviceName: String?
    var howledAt: String?
    var setupPrompt: String?
    var remoteIsPublicHost: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("project_id", "id") ?? 0
        slug = c.str("slug") ?? ""
        name = c.str("name") ?? slug
        state = c.str("state") ?? "knowledge_only"
        why = c.str("why")
        folder = c.str("folder")
        folders = (try? c.decode([String].self, forKey: HubJSONKey("folders"))) ?? []
        sharedFolders = (try? c.decode([String].self, forKey: HubJSONKey("shared_folders"))) ?? []
        remote = c.str("remote")
        branch = c.str("branch")
        lastCommit = c.str("last_commit")
        lastCommitAt = c.str("last_commit_at")
        lastSubject = c.str("last_subject")
        dirtyFiles = c.int("dirty_files")
        deviceName = c.str("device_name")
        howledAt = c.str("howled_at")
        setupPrompt = c.str("setup_prompt")
        remoteIsPublicHost = c.str("remote_is_public_host") == "true"
    }
}

struct HubSharedFolder: Decodable, Identifiable, Hashable {
    struct Member: Decodable, Identifiable, Hashable {
        var id: Int
        var slug: String
        var name: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: HubJSONKey.self)
            id = c.int("id") ?? 0
            slug = c.str("slug") ?? ""
            name = c.str("name") ?? slug
        }
    }

    var path: String
    var projects: [Member]
    var id: String { path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        path = c.str("path") ?? ""
        projects = (try? c.decode([Member].self, forKey: HubJSONKey("projects"))) ?? []
    }
}

struct HubNotesRepo: Decodable, Identifiable, Hashable {
    var owner: String
    var path: String
    var uncommitted: Int
    var lastCommitAt: String?
    var lastSubject: String?
    var id: String { path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        owner = c.str("owner") ?? "Notes"
        path = c.str("path") ?? ""
        uncommitted = c.int("uncommitted") ?? 0
        lastCommitAt = c.str("last_commit_at")
        lastSubject = c.str("last_subject")
    }
}

struct HubOffsiteStatus: Decodable, Hashable {
    struct Copy: Decodable, Hashable {
        var deviceName: String?
        var destination: String?
        var repos: Int
        var dumpName: String?
        var detail: String?
        var createdAt: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: HubJSONKey.self)
            deviceName = c.str("device_name")
            destination = c.str("destination")
            repos = c.int("repos") ?? 0
            dumpName = c.str("dump_name")
            detail = c.str("detail")
            createdAt = c.str("created_at")
        }
    }

    var lastGood: Copy?
    var latest: Copy?
    var stale: Bool
    var lastFailed: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        lastGood = try? c.decode(Copy.self, forKey: HubJSONKey("last_good"))
        latest = try? c.decode(Copy.self, forKey: HubJSONKey("latest"))
        stale = c.str("stale") != "false"
        lastFailed = c.str("last_failed") == "true"
    }
}

struct HubReposResponse: Decodable {
    var projects: [HubRepoProject]
    var sharedFolders: [HubSharedFolder]
    var notes: [HubNotesRepo]
    var notesScheduleMinutes: Double
    var offsite: HubOffsiteStatus?
    var offsiteInstall: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        projects = (try? c.decode([HubRepoProject].self, forKey: HubJSONKey("projects"))) ?? []
        sharedFolders = (try? c.decode([HubSharedFolder].self, forKey: HubJSONKey("shared_folders"))) ?? []
        notes = (try? c.decode([HubNotesRepo].self, forKey: HubJSONKey("notes"))) ?? []
        notesScheduleMinutes = c.double("notes_schedule_minutes") ?? 0
        offsite = try? c.decode(HubOffsiteStatus.self, forKey: HubJSONKey("offsite"))
        offsiteInstall = c.str("offsite_install") ?? ""
    }
}

extension HubClient {
    func repos() async throws -> HubReposResponse {
        try JSONDecoder().decode(HubReposResponse.self, from: try await data("/api/repos", timeout: 30))
    }

    func unlinkFolder(projectID: Int, path: String) async throws {
        _ = try await data("/api/projects/\(projectID)/paths", query: ["path": path], method: "DELETE")
    }

    func commitNotes() async throws {
        _ = try await data("/api/notes/commit", method: "POST", body: Data("{}".utf8), timeout: 120)
    }
}

// MARK: - Progress, goals, build prompts (GET /api/progress)

struct HubGoal: Decodable, Identifiable, Hashable {
    var id: Int
    var projectID: Int
    var title: String
    var doneWhen: String
    var phase: String
    var status: String
    var proof: String
    var milestoneID: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        projectID = c.int("project_id") ?? 0
        milestoneID = c.int("milestone_id")
        title = c.str("title") ?? "Untitled goal"
        doneWhen = c.str("done_when") ?? ""
        phase = c.str("phase") ?? "now"
        status = c.str("status") ?? "proposed"
        proof = c.str("proof") ?? ""
    }
}

struct HubProgressProject: Decodable, Identifiable, Hashable {
    struct NextStep: Decodable, Hashable {
        var text: String
        var doneWhen: String
        var from: String
        var memoryID: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: HubJSONKey.self)
            text = c.str("text") ?? ""
            doneWhen = c.str("done_when") ?? ""
            from = c.str("from") ?? "notes"
            memoryID = c.int("memory_id")
        }
    }

    struct Note: Decodable, Identifiable, Hashable {
        var id: Int
        var text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: HubJSONKey.self)
            id = c.int("memory_id", "id") ?? 0
            text = c.str("text") ?? ""
        }
    }

    var id: Int
    var slug: String
    var name: String
    var status: String
    var northStar: String
    var whereItStands: String
    var lastSession: String?
    var sessions: Int
    var memories: Int
    var nextStep: NextStep?
    var openProblems: [Note]
    var suggestions: [Note]
    var goals: [HubGoal]
    var milestones: [HubMilestone]

    var openGoals: [HubGoal] { goals.filter { $0.status != "verified" } }
    /// The milestone being worked: the one marked in play, else the first that is not done.
    var currentMilestone: HubMilestone? {
        milestones.first { $0.status == "in_play" } ?? milestones.first { $0.status != "done" }
    }
    var verifiedCount: Int { goals.count - openGoals.count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("project_id", "id") ?? 0
        slug = c.str("slug") ?? ""
        name = c.str("name") ?? slug
        status = c.str("status") ?? "active"
        northStar = c.str("north_star") ?? ""
        whereItStands = c.str("where_it_stands") ?? ""
        lastSession = c.str("last_session")
        sessions = c.int("sessions") ?? 0
        memories = c.int("memories") ?? 0
        nextStep = try? c.decode(NextStep.self, forKey: HubJSONKey("next_step"))
        openProblems = (try? c.decode([Note].self, forKey: HubJSONKey("open_problems"))) ?? []
        suggestions = (try? c.decode([Note].self, forKey: HubJSONKey("suggestions"))) ?? []
        goals = (try? c.decode([HubGoal].self, forKey: HubJSONKey("goals"))) ?? []
        milestones = (try? c.decode([HubMilestone].self, forKey: HubJSONKey("milestones"))) ?? []
    }
}

/// One of the few big chunks between where a project is and its North Star.
struct HubMilestone: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String
    var status: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        title = c.str("title") ?? "Milestone"
        status = c.str("status") ?? "not_started"
    }
}

struct HubProgressResponse: Decodable {
    var projects: [HubProgressProject]
    var unfiledSessions: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        projects = (try? c.decode([HubProgressProject].self, forKey: HubJSONKey("projects"))) ?? []
        unfiledSessions = c.int("unfiled_sessions") ?? 0
    }
}

struct HubUnfiledSession: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String
    var summary: String
    var happenedAt: String?
    var workspacePath: String?
    var messages: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        title = c.str("title") ?? "Untitled session"
        summary = c.str("summary") ?? ""
        happenedAt = c.str("happened_at")
        workspacePath = c.str("workspace_path")
        messages = c.int("messages") ?? 0
    }
}

struct HubBuildPrompt: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String
    var body: String
    var createdAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        title = c.str("title") ?? "Build brief"
        body = c.str("body") ?? ""
        createdAt = c.str("created_at")
    }
}

extension HubClient {
    func progress() async throws -> HubProgressResponse {
        try JSONDecoder().decode(HubProgressResponse.self, from: try await data("/api/progress", timeout: 30))
    }

    private func send(_ path: String, method: String, _ payload: [String: Any]) async throws -> Data {
        try await data(path, method: method, body: try JSONSerialization.data(withJSONObject: payload), timeout: 30)
    }

    func createGoal(projectID: Int, title: String, doneWhen: String, phase: String, memoryID: Int? = nil,
                    milestoneID: Int? = nil) async throws {
        var payload: [String: Any] = ["title": title, "done_when": doneWhen, "phase": phase]
        if let memoryID { payload["source_memory_id"] = memoryID }
        if let milestoneID { payload["milestone_id"] = milestoneID }
        _ = try await send("/api/projects/\(projectID)/goals", method: "POST", payload)
    }

    func updateGoal(id: Int, _ changes: [String: Any]) async throws {
        _ = try await send("/api/goals/\(id)", method: "PUT", changes)
    }

    func deleteGoal(id: Int) async throws {
        _ = try await data("/api/goals/\(id)", method: "DELETE")
    }

    func buildPrompt(projectID: Int, goalIDs: [Int], note: String) async throws -> HubBuildPrompt {
        let reply = try await send("/api/projects/\(projectID)/build-prompts", method: "POST", ["goal_ids": goalIDs, "note": note])
        return try JSONDecoder().decode(HubBuildPrompt.self, from: reply)
    }

    func unfiledSessions() async throws -> [HubUnfiledSession] {
        struct Wrapper: Decodable { var sessions: [HubUnfiledSession] }
        return try JSONDecoder().decode(Wrapper.self, from: try await data("/api/sessions/unfiled", timeout: 30)).sessions
    }

    func fileSession(id: Int, projectID: Int) async throws {
        _ = try await send("/api/sessions/\(id)/file", method: "POST", ["project_id": projectID])
    }
}

// MARK: - Everything about one project (the app's project page)

struct HubLogEntry: Decodable, Identifiable, Hashable {
    var chatID: Int
    var title: String
    var summary: String
    var occurredAt: String?
    var id: Int { chatID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        chatID = c.int("chat_id", "id") ?? 0
        title = c.str("title") ?? "Session"
        summary = c.str("summary", "agent_summary") ?? ""
        occurredAt = c.str("occurred_at", "updated_at", "saved_at")
    }
}

struct HubProjectBrief: Decodable {
    var purpose: String
    var briefMarkdown: String
    var agentPrompt: String
    var briefUpdatedAt: String?
    var continueMode: String?
    var deployState: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        purpose = c.str("purpose_summary", "description") ?? ""
        briefMarkdown = c.str("brief_md") ?? ""
        agentPrompt = c.str("agent_prompt", "pickup_prompt") ?? ""
        briefUpdatedAt = c.str("brief_updated_at")
        continueMode = c.str("continue_mode")
        deployState = c.str("deploy_state")
    }
}

struct HubProjectFolder: Decodable, Identifiable, Hashable {
    var id: Int
    var path: String
    var kind: String
    var deviceName: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        path = c.str("path") ?? ""
        kind = c.str("kind") ?? "workspace"
        deviceName = c.str("device_name")
    }
}

struct HubMessage: Decodable, Identifiable, Hashable {
    var id: Int
    var role: String
    var content: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        role = c.str("role") ?? "assistant"
        content = c.str("content") ?? ""
    }
}

extension HubClient {
    /// Session summaries for one project, newest first.
    func logbook(projectID: Int) async throws -> [HubLogEntry] {
        struct Wrapper: Decodable { var entries: [HubLogEntry]? }
        let raw = try await data("/api/projects/\(projectID)/where-left-off", timeout: 30)
        return (try JSONDecoder().decode(Wrapper.self, from: raw)).entries ?? []
    }

    func brief(projectKey: String) async throws -> HubProjectBrief {
        try JSONDecoder().decode(HubProjectBrief.self, from: try await data("/api/projects/\(projectKey)/agent-brief", timeout: 30))
    }

    func folders(projectID: Int) async throws -> [HubProjectFolder] {
        try await get("/api/projects/\(projectID)/paths", as: HubList<HubProjectFolder>.self).items
    }

    /// Every saved session of a project: active ones, then archived.
    func allSessions(projectID: Int) async throws -> [HubChat] {
        struct Wrapper: Decodable { var archived: [HubChat]?; var chats: [HubChat]? }
        let raw = try await data("/api/projects/\(projectID)/chats", query: ["archived": "true", "limit": "200"], timeout: 30)
        let active = (try? await chats(projectID: projectID, limit: 50)) ?? []
        let archived = (try? JSONDecoder().decode(Wrapper.self, from: raw))?.archived ?? []
        var seen = Set<Int>()
        return (active + archived).filter { seen.insert($0.id).inserted }
    }

    func messages(chatID: Int) async throws -> [HubMessage] {
        struct Wrapper: Decodable { var messages: [HubMessage] }
        return try JSONDecoder().decode(Wrapper.self, from: try await data("/api/chats/\(chatID)/messages", timeout: 60)).messages
    }

    func buildPrompts(projectID: Int) async throws -> [HubBuildPrompt] {
        struct Wrapper: Decodable { var prompts: [HubBuildPrompt] }
        return try JSONDecoder().decode(Wrapper.self, from: try await data("/api/projects/\(projectID)/build-prompts")).prompts
    }

    func addMemory(projectID: Int, type: String, content: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["project_id": projectID, "type": type, "content": content])
        _ = try await data("/api/memories", method: "POST", body: body, timeout: 60)
    }

    func deleteMemory(id: Int) async throws {
        _ = try await data("/api/memories/\(id)", method: "DELETE", timeout: 60)
    }

    func updateProject(id: Int, name: String, description: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "description": description])
        _ = try await data("/api/projects/\(id)", method: "PUT", body: body, timeout: 60)
    }

    /// Regenerate the project's brief from its memories and sessions.
    func refreshBrief(projectID: Int) async throws {
        _ = try await data("/api/projects/\(projectID)/distill", method: "POST", body: Data("{}".utf8), timeout: 180)
    }
}

// MARK: - Owners, loose sessions, related projects

struct HubRelatedProject: Identifiable, Hashable {
    var id: Int
    var name: String
}

extension HubClient {
    func owners() async throws -> [String] {
        let raw = try await data("/api/owners")
        return ((try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["owners"] as? [String]) ?? []
    }

    /// "" clears a hand-set owner.
    func setOwner(projectID: Int, owner: String) async throws {
        _ = try await data("/api/projects/\(projectID)", method: "PUT",
                           body: try JSONSerialization.data(withJSONObject: ["owner": owner]), timeout: 60)
    }

    /// Ask the hub to file loose sessions that clearly belong to a project. Returns how many it filed.
    func autoFileSessions() async throws -> Int {
        let raw = try await data("/api/sessions/auto-file", method: "POST", body: Data("{}".utf8), timeout: 120)
        return (((try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["filed"] as? [Any]) ?? []).count
    }

    /// File loose chats that clearly match a project; everything else goes to One-offs.
    func fileLooseInOneOffs() async throws {
        _ = try await data("/api/sessions/one-offs", method: "POST", body: Data("{}".utf8), timeout: 180)
    }

    func deleteSession(id: Int) async throws {
        _ = try await data("/api/chats/\(id)", method: "DELETE", timeout: 60)
    }

    /// Projects the hub considers closest to this one (by what their journals say).
    func relatedProjects(slug: String) async throws -> [HubRelatedProject] {
        let raw = try await data("/api/eat", query: ["slug": slug], timeout: 60)
        let brief = (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["brief"] as? [String: Any]
        let related = (brief?["related"] as? [[String: Any]]) ?? []
        var seen = Set<Int>()
        return related.compactMap { item in
            guard item["kind"] as? String == "project", let id = item["id"] as? Int, seen.insert(id).inserted,
                  (item["similarity"] as? Double ?? 0) >= 0.6 else { return nil }
            return HubRelatedProject(id: id, name: (item["title"] as? String) ?? "Project")
        }
    }
}

extension HubClient {
    func ownerSummary() async throws -> (owners: [String], counts: [String: Int]) {
        let json = (try JSONSerialization.jsonObject(with: try await data("/api/owners")) as? [String: Any]) ?? [:]
        return ((json["owners"] as? [String]) ?? [], (json["counts"] as? [String: Int]) ?? [:])
    }

    private func ownerPath(_ name: String) -> String {
        "/api/owners/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
    }

    func addOwner(_ name: String) async throws {
        _ = try await data("/api/owners", method: "POST", body: try JSONSerialization.data(withJSONObject: ["name": name]))
    }

    func renameOwner(_ old: String, to new: String) async throws {
        _ = try await data(ownerPath(old), method: "PUT", body: try JSONSerialization.data(withJSONObject: ["name": new]), timeout: 60)
    }

    func removeOwner(_ name: String, moveTo: String?) async throws {
        _ = try await data(ownerPath(name), query: moveTo.map { ["move_to": $0] } ?? [:], method: "DELETE", timeout: 60)
    }
}

// MARK: - North Star and broadcasts

struct HubNorthStarVersion: Decodable, Identifiable, Hashable {
    var id: Int
    var body: String
    var why: String?
    var createdAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        id = c.int("id") ?? 0
        body = c.str("body") ?? ""
        why = c.str("why")
        createdAt = c.str("created_at")
    }
}

struct HubNorthStar: Decodable {
    var current: HubNorthStarVersion?
    var history: [HubNorthStarVersion]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        current = try? c.decode(HubNorthStarVersion.self, forKey: HubJSONKey("current"))
        history = (try? c.decode([HubNorthStarVersion].self, forKey: HubJSONKey("history"))) ?? []
    }
}

/// One save that was broadcast: which machine it came from and the commit it pointed at.
struct HubHowl: Decodable, Hashable {
    var chatID: Int?
    var deviceName: String?
    var gitCommit: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        chatID = c.int("chat_id")
        deviceName = c.str("device_name")
        gitCommit = c.str("git_commit")
    }
}

extension HubClient {
    func northStar(projectID: Int) async throws -> HubNorthStar {
        try JSONDecoder().decode(HubNorthStar.self, from: try await data("/api/projects/\(projectID)/north-star"))
    }

    func setNorthStar(projectID: Int, body: String, why: String) async throws {
        _ = try await data("/api/projects/\(projectID)/north-star", method: "PUT",
                           body: try JSONSerialization.data(withJSONObject: ["body": body, "why": why]), timeout: 60)
    }

    func deleteNorthStarVersion(id: Int) async throws {
        _ = try await data("/api/north-star-versions/\(id)", method: "DELETE")
    }

    func howls(projectID: Int) async throws -> [HubHowl] {
        try await get("/api/howls", query: ["project_id": String(projectID), "limit": "100"], as: HubList<HubHowl>.self).items
    }
}

extension HubClient {
    func createMilestone(projectID: Int, title: String) async throws {
        _ = try await data("/api/projects/\(projectID)/milestones", method: "POST",
                           body: try JSONSerialization.data(withJSONObject: ["title": title]))
    }

    func updateMilestone(id: Int, _ changes: [String: Any]) async throws {
        _ = try await data("/api/milestones/\(id)", method: "PUT", body: try JSONSerialization.data(withJSONObject: changes))
    }

    func reorderMilestones(projectID: Int, ids: [Int]) async throws {
        _ = try await data("/api/projects/\(projectID)/milestones/order", method: "PUT",
                           body: try JSONSerialization.data(withJSONObject: ["ids": ids]))
    }

    func deleteMilestone(id: Int) async throws {
        _ = try await data("/api/milestones/\(id)", method: "DELETE")
    }
}

// MARK: - Ask (GET /api/ask): answers quoted from the journal

struct HubAnswerItem: Decodable, Identifiable, Hashable {
    var memoryID: Int
    var text: String
    var when: String?
    var projectID: Int?
    var project: String?
    var chatID: Int?
    var id: Int { memoryID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        memoryID = c.int("memory_id") ?? 0
        text = c.str("text") ?? ""
        when = c.str("when")
        projectID = c.int("project_id")
        project = c.str("project")
        chatID = c.int("chat_id")
    }
}

struct HubAnswerSection: Decodable, Identifiable, Hashable {
    var kind: String
    var title: String
    var items: [HubAnswerItem]
    var id: String { kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        kind = c.str("kind") ?? "note"
        title = c.str("title") ?? kind.capitalized
        items = (try? c.decode([HubAnswerItem].self, forKey: HubJSONKey("items"))) ?? []
    }
}

struct HubAnswerSession: Decodable, Identifiable, Hashable {
    var chatID: Int
    var title: String
    var summary: String
    var when: String?
    var project: String?
    var id: Int { chatID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        chatID = c.int("chat_id") ?? 0
        title = c.str("title") ?? "Session"
        summary = c.str("summary") ?? ""
        when = c.str("when")
        project = c.str("project")
    }
}

struct HubAnswer: Decodable {
    var summary: String
    var understoodProject: String?
    var understoodWhen: String?
    var understoodAbout: String?
    var sections: [HubAnswerSection]
    var sessions: [HubAnswerSession]
    var results: [HubSearchHit]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: HubJSONKey.self)
        summary = c.str("summary") ?? ""
        sections = (try? c.decode([HubAnswerSection].self, forKey: HubJSONKey("sections"))) ?? []
        sessions = (try? c.decode([HubAnswerSession].self, forKey: HubJSONKey("sessions"))) ?? []
        results = (try? c.decode(HubList<HubSearchHit>.self, forKey: HubJSONKey("results")))?.items ?? []
        if let u = try? c.nestedContainer(keyedBy: HubJSONKey.self, forKey: HubJSONKey("understood")) {
            understoodWhen = u.str("when")
            understoodAbout = u.str("about")
            if let project = try? u.nestedContainer(keyedBy: HubJSONKey.self, forKey: HubJSONKey("project")) {
                understoodProject = project.str("name")
            }
        }
    }
}

extension HubClient {
    func ask(_ question: String) async throws -> HubAnswer {
        try JSONDecoder().decode(HubAnswer.self, from: try await data("/api/ask", query: ["q": question], timeout: 60))
    }
}

// MARK: - Making and keeping projects by hand

extension HubClient {
    private func json(_ path: String, _ method: String, _ payload: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let raw = try await data(path, method: method, body: try JSONSerialization.data(withJSONObject: payload), timeout: timeout)
        return (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
    }

    /// Returns the new project's id.
    func startProject(name: String, description: String, northStar: String, owner: String, status: String,
                      milestones: [String], folder: String, tags: [String]) async throws -> Int {
        let reply = try await json("/api/projects/start", "POST", [
            "name": name, "description": description, "north_star": northStar, "owner": owner, "status": status,
            "milestones": milestones, "folder": folder, "tags": tags,
        ], timeout: 120)
        return (reply["id"] as? Int) ?? 0
    }

    func writeJournal(projectID: Int, text: String) async throws {
        _ = try await json("/api/projects/\(projectID)/journal", "POST", ["text": text], timeout: 180)
    }

    /// Link a folder. Returns the projects that already use it, if any (then it is not linked).
    func addFolder(projectID: Int, path: String) async throws -> [String] {
        let reply = try await json("/api/projects/\(projectID)/paths", "POST", ["path": path])
        return (reply["shared_with"] as? [String]) ?? []
    }

    func removeFolder(projectID: Int, path: String) async throws {
        _ = try await data("/api/projects/\(projectID)/paths", query: ["path": path], method: "DELETE")
    }

    func setTags(projectID: Int, tags: [String]) async throws {
        _ = try await json("/api/projects/\(projectID)", "PUT", ["tags": tags])
    }

    func deleteProject(id: Int) async throws {
        _ = try await data("/api/projects/\(id)", method: "DELETE", timeout: 120)
    }
}

// MARK: - Profiles

struct HubProfileItem: Identifiable, Hashable {
    var id: Int
    var kind: String
    var text: String
    var source: String
}

struct HubProfileSection: Identifiable, Hashable {
    var id: String { kind }
    var kind: String
    var title: String
    var items: [HubProfileItem]
}

extension HubClient {
    private func personPath(_ name: String) -> String {
        "/api/people/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
    }

    func profile(person: String) async throws -> [HubProfileSection] {
        let json = (try JSONSerialization.jsonObject(with: try await data(personPath(person) + "/profile")) as? [String: Any]) ?? [:]
        return ((json["sections"] as? [[String: Any]]) ?? []).map { section in
            HubProfileSection(
                kind: section["kind"] as? String ?? "about",
                title: section["title"] as? String ?? "",
                items: ((section["items"] as? [[String: Any]]) ?? []).compactMap { item in
                    guard let id = item["id"] as? Int else { return nil }
                    return HubProfileItem(id: id, kind: item["kind"] as? String ?? "about",
                                          text: item["text"] as? String ?? "", source: item["source"] as? String ?? "manual")
                })
        }
    }

    func profileMarkdown(person: String) async throws -> String {
        String(decoding: try await data(personPath(person) + "/profile.md"), as: UTF8.self)
    }

    func addProfileItem(person: String, text: String, kind: String) async throws {
        _ = try await data(personPath(person) + "/profile", method: "POST",
                           body: try JSONSerialization.data(withJSONObject: ["text": text, "kind": kind, "source": "manual"]))
    }

    func updateProfileItem(id: Int, text: String? = nil, kind: String? = nil) async throws {
        var body: [String: String] = [:]
        if let text { body["text"] = text }
        if let kind { body["kind"] = kind }
        _ = try await data("/api/profile-items/\(id)", method: "PUT", body: try JSONSerialization.data(withJSONObject: body))
    }

    func deleteProfileItem(id: Int) async throws {
        _ = try await data("/api/profile-items/\(id)", method: "DELETE")
    }
}
