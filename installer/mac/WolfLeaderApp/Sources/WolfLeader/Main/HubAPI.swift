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
