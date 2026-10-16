import SwiftUI

struct AskView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var nav: Navigator
    @Environment(\.palette) private var p

    @State private var answer: HubAnswer?
    @State private var reading: ReadingSession?
    @State private var query = ""
    @State private var lastQuery = ""
    @State private var hits: [HubSearchHit] = []
    @State private var searching = false
    @State private var error: String? = nil
    @State private var projectNames: [Int: String] = [:]
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var focused: Bool

    private var canSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        MainPage {
            hero
            results
        }
        .task(id: store.config.hubURL) { await loadProjectNames() }
        .sheet(item: $reading) { SessionReader(chatID: $0.id, title: $0.title, when: $0.when) }
        .onAppear {
            focused = true
            takePendingSearch()
        }
        .onChange(of: nav.pendingSearch) { takePendingSearch() }
    }

    /// A search typed in the toolbar lands here and runs straight away.
    private func takePendingSearch() {
        guard let q = nav.pendingSearch else { return }
        nav.pendingSearch = nil
        query = q
        runSearch()
    }

    /// Hero tile in the shape of MacParakeet's "Transcribe YouTube & more".
    private var hero: some View {
        Tile {
            VStack(spacing: DS.Spacing.md) {
                AskIconCluster()
                Text("Search")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(p.text)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(p.textMuted)
                        TextField(placeholder, text: $query)
                            .textFieldStyle(.plain)
                            .font(DS.Font.bodySmall)
                            .foregroundStyle(p.text)
                            .focused($focused)
                            .onSubmit(runSearch)
                        if searching {
                            ProgressView().controlSize(.small)
                        } else if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(p.textFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                            .strokeBorder(focused ? p.accent.opacity(0.6) : p.border.opacity(0.7), lineWidth: focused ? 1 : 0.6)
                    )
                    Button(action: runSearch) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                            Text("Search")
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(!canSearch)
                }
                .frame(maxWidth: 520)
                Text("Search every memory, session and message. Or ask, like \u{201C}what did I save for Wolf Leader three months ago?\u{201D} Answers are quoted from your records, not written by an AI.")
                    .font(DS.Font.caption)
                    .foregroundStyle(p.textFaint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.md)
        }
    }

    @ViewBuilder
    private var results: some View {
        if let error {
            MainNotice(
                symbol: "wifi.exclamationmark",
                title: "Can't reach your hub at \(store.config.hubURL)",
                message: "\(error) · Check Settings."
            )
        } else if lastQuery.isEmpty {
            EmptyView()
        } else if hits.isEmpty && !searching && (answer?.sections.isEmpty ?? true) && (answer?.sessions.isEmpty ?? true) {
            MainNotice(
                symbol: "questionmark.bubble",
                title: "Nothing found for \u{201C}\(lastQuery)\u{201D}",
                message: "Try fewer or different words."
            )
        } else {
            if let answer, !answer.summary.isEmpty {
                Text(answer.summary).font(DS.Font.body.weight(.semibold)).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Spacing.sm)
            }
            topics
                .id(lastQuery) // a new search starts every topic collapsed again
        }
    }

    /// One card per topic with only the top few rows, so you pick where to dig in.
    private var topics: some View {
        VStack(spacing: DS.Spacing.sm + 4) {
            if !projectRows.isEmpty {
                TopicGroup(title: "Projects", icon: "folder", items: projectRows) { row in
                    ProjectHitRowView(row: row) { nav.open(project: row.id) }
                }
            }
            ForEach(answer?.sections ?? []) { section in
                TopicGroup(title: section.title, icon: MemoryKind(rawValue: section.kind)?.symbol ?? "square.stack",
                           items: section.items) { item in
                    AnswerItemRow(item: item,
                                  read: item.chatID.map { chat in { reading = ReadingSession(id: chat, title: item.project ?? "Session", when: item.when) } },
                                  openProject: item.projectID.map { id in { nav.open(project: id) } })
                }
            }
            if let sessions = answer?.sessions, !sessions.isEmpty {
                TopicGroup(title: "Sessions", icon: "book", items: sessions) { session in
                    SessionRow(session: session) {
                        reading = ReadingSession(id: session.chatID, title: session.title, when: session.when)
                    }
                }
            }
            ForEach(hitTopics, id: \.title) { topic in
                TopicGroup(title: topic.title, icon: topic.icon, items: topic.hits) { hit in
                    HitRow(hit: hit, projectName: projectName(for: hit)) { open(hit) }
                }
            }
        }
    }

    /// The project the question named comes first, then projects that matched by name,
    /// then projects mentioned most often in the other results.
    private var projectRows: [ProjectHitRow] {
        var order: [Int] = []
        if let id = answer?.understoodProjectID { order.append(id) }
        for hit in hits where hit.kind == "project" && !order.contains(hit.refID) { order.append(hit.refID) }
        var mentions: [Int: Int] = [:]
        for hit in hits { if let id = hit.linkedProjectID { mentions[id, default: 0] += 1 } }
        order += mentions.keys.filter { !order.contains($0) }.sorted { (mentions[$0] ?? 0) > (mentions[$1] ?? 0) }
        return order.map { ProjectHitRow(id: $0, name: projectNames[$0] ?? "Project \($0)", mentions: mentions[$0] ?? 0) }
    }

    private struct HitTopic {
        let title: String
        let icon: String
        let hits: [HubSearchHit]
    }

    private var hitTopics: [HitTopic] {
        // Memories already shown in an answer section are not repeated.
        let answered = Set((answer?.sections ?? []).flatMap { $0.items.map(\.memoryID) })
        func pick(_ kinds: Set<String>) -> [HubSearchHit] { hits.filter { kinds.contains($0.kind) } }
        return [
            HitTopic(title: "Conversations", icon: "bubble.left.and.bubble.right", hits: pick(["message", "convo", "chat", "howl"])),
            HitTopic(title: "Memories", icon: "square.stack", hits: pick(["memory"]).filter { !answered.contains($0.refID) }),
            HitTopic(title: "Files", icon: "doc.text", hits: pick(["catalog", "chunk"])),
        ].filter { !$0.hits.isEmpty }
    }

    private var placeholder: String {
        let name = projectNames.values.sorted().first { $0.count > 3 } ?? "my project"
        return "What did I learn for \(name) three days ago?"
    }

    private func projectName(for hit: HubSearchHit) -> String? {
        if let id = hit.linkedProjectID, let name = projectNames[id] { return name }
        if hit.kind == "project" { return hit.title }
        return hit.slug
    }

    private func open(_ hit: HubSearchHit) {
        // Everything opens here in the app: a session in the reader, anything else on its project's page.
        if let chat = hit.linkedChatID {
            reading = ReadingSession(id: chat, title: hit.chatTitle ?? hit.title ?? "Session", when: hit.stamp)
        } else if let project = hit.linkedProjectID {
            nav.open(project: project)
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            searching = true
            defer { searching = false }
            do {
                let found = try await store.hub.ask(q)
                guard !Task.isCancelled else { return }
                answer = found
                hits = found.results
                lastQuery = q
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                lastQuery = q
            }
        }
    }

    private func loadProjectNames() async {
        guard let projects = try? await store.hub.projects() else { return }
        var names: [Int: String] = [:]
        for project in projects { names[project.id] = project.name }
        projectNames = names
    }
}

/// Center symbol with memory-type icons around it (MacParakeet's source-logo cluster).
private struct AskIconCluster: View {
    @Environment(\.palette) private var p

    var body: some View {
        let items: [(String, Color)] = [
            ("checkmark.seal", p.accent),
            ("folder", p.warn),
            ("bubble.left.and.bubble.right", p.good),
            ("doc.text", p.textMuted),
            ("exclamationmark.triangle", p.bad),
            ("flag", p.accent2),
        ]
        ZStack {
            Circle()
                .fill(p.surface)
                .frame(width: 48, height: 48)
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(p.textMuted)
            ForEach(0..<items.count, id: \.self) { i in
                let angle = Double(i) / Double(items.count) * 2 * Double.pi - Double.pi / 2
                Image(systemName: items[i].0)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(items[i].1)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(items[i].1.opacity(0.16)))
                    .offset(x: CGFloat(cos(angle) * 54), y: CGFloat(sin(angle) * 54))
            }
        }
        .frame(width: 140, height: 140)
    }
}

/// A saved session picked to be read in the app.
struct ReadingSession: Identifiable, Hashable {
    let id: Int
    let title: String
    let when: String?
}


// MARK: - Topic cards

private let topicPreview = 3

/// A titled card that shows the first few rows and grows on request.
private struct TopicGroup<Item: Identifiable, Row: View>: View {
    @Environment(\.palette) private var p
    let title: String
    let icon: String
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row
    @State private var shown = topicPreview

    var body: some View {
        WLGroup(title: title, subtitle: "\(items.count)", icon: icon) {
            ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { index, item in
                if index > 0 { WLDivider() }
                row(item)
            }
            if items.count > topicPreview {
                HStack(spacing: 14) {
                    if items.count > shown {
                        Button("Show \(min(10, items.count - shown)) more") { withAnimation(DS.Anim.hover) { shown += 10 } }
                    }
                    if shown > topicPreview {
                        Button("Show less") { withAnimation(DS.Anim.hover) { shown = topicPreview } }
                    }
                }
                .buttonStyle(.plain)
                .font(DS.Font.micro.weight(.semibold))
                .foregroundStyle(p.accent)
            }
        }
    }
}

struct ProjectHitRow: Identifiable, Hashable {
    let id: Int
    let name: String
    let mentions: Int
}

private struct ProjectHitRowView: View {
    @Environment(\.palette) private var p
    let row: ProjectHitRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(row.name).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text)
                Spacer(minLength: 8)
                if row.mentions > 0 {
                    Text("\(row.mentions) result\(row.mentions == 1 ? "" : "s")").font(DS.Font.micro).foregroundStyle(p.textMuted)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AnswerItemRow: View {
    @Environment(\.palette) private var p
    let item: HubAnswerItem
    let read: (() -> Void)?
    let openProject: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text).font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text([item.project, HubDate.format(item.when)].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.Font.micro).foregroundStyle(p.textFaint)
                if let read {
                    Button("Read the session", action: read)
                        .buttonStyle(.plain).font(DS.Font.micro.weight(.semibold)).foregroundStyle(p.accent)
                }
                if let openProject {
                    Button("Open project", action: openProject)
                        .buttonStyle(.plain).font(DS.Font.micro.weight(.semibold)).foregroundStyle(p.accent)
                }
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(\.palette) private var p
    let session: HubAnswerSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !session.summary.isEmpty {
                    Text(session.summary).font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text([session.project, HubDate.format(session.when)].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.Font.micro).foregroundStyle(p.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One search result inside a topic card: kind, where it came from, when, and a short excerpt.
private struct HitRow: View {
    @Environment(\.palette) private var p
    let hit: HubSearchHit
    let projectName: String?
    let action: () -> Void

    private var kindLabel: String {
        switch hit.kind {
        case "memory": return (hit.memoryType ?? "memory").replacingOccurrences(of: "_", with: " ")
        case "catalog": return "file"
        case "chunk": return "file excerpt"
        case "convo": return "conversation"
        default: return hit.kind
        }
    }

    private var heading: String {
        switch hit.kind {
        case "memory": return projectName ?? "Memory"
        case "message", "convo": return hit.chatTitle ?? hit.title ?? "Conversation"
        default: return hit.title ?? projectName ?? "Result"
        }
    }

    private var snippet: String {
        var text = hit.content ?? ""
        if hit.kind == "memory", text.isEmpty, let title = hit.title { text = title }
        return text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    MainTag(text: kindLabel)
                    Text(heading).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = hit.date {
                        Text(HubDate.format(date)).font(DS.Font.timestamp).foregroundStyle(p.textMuted)
                    }
                }
                if !snippet.isEmpty {
                    Text(snippet).font(DS.Font.micro).foregroundStyle(p.text.opacity(0.85)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let decision = hit.decisions.first {
                    Label("Decided: \(decision.text)", systemImage: "checkmark.seal")
                        .font(DS.Font.micro).foregroundStyle(p.textMuted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
