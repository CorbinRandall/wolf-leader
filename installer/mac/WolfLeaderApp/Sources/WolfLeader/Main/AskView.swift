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
    @State private var kindFilter: HitGroup? = nil
    @State private var projectFilter: Int? = nil
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
        } else if hits.isEmpty && !searching && (answer?.summary.isEmpty ?? true) {
            MainNotice(
                symbol: "questionmark.bubble",
                title: "Nothing found for \u{201C}\(lastQuery)\u{201D}",
                message: "Try fewer or different words."
            )
        } else {
            if let answer, !answer.summary.isEmpty { answerBlock(answer) }
            if !hits.isEmpty {
            WLSectionLabel(text: (answer?.summary.isEmpty ?? true)
                           ? "\(hits.count) result\(hits.count == 1 ? "" : "s") for \u{201C}\(lastQuery)\u{201D}"
                           : "Also found by search")
                .padding(.top, DS.Spacing.sm)
            resultFilters
            LazyVStack(spacing: DS.Spacing.sm + 4) {
                ForEach(filteredHits) { hit in
                    AskResultCard(hit: hit, projectName: projectName(for: hit)) {
                        open(hit)
                    }
                }
            }
            }
        }
    }

    private var filteredHits: [HubSearchHit] {
        hits.filter { hit in
            (kindFilter == nil || HitGroup(hit) == kindFilter)
                && (projectFilter == nil || hit.linkedProjectID == projectFilter)
        }
    }

    /// Narrow the results after they come back: by kind, and by the projects that appear in them.
    @ViewBuilder
    private var resultFilters: some View {
        let groups = HitGroup.allCases.filter { g in hits.contains { HitGroup($0) == g } }
        let projectIDs = Array(Set(hits.compactMap(\.linkedProjectID))).sorted {
            (projectNames[$0] ?? "") < (projectNames[$1] ?? "")
        }
        HStack(spacing: 6) {
            FilterChip(label: "All", count: hits.count, on: kindFilter == nil) { kindFilter = nil }
            ForEach(groups, id: \.self) { g in
                FilterChip(label: g.label, count: hits.filter { HitGroup($0) == g }.count, on: kindFilter == g) {
                    kindFilter = kindFilter == g ? nil : g
                }
            }
            Spacer(minLength: 0)
            if projectIDs.count > 1 {
                Menu {
                    Button("All projects") { projectFilter = nil }
                    Divider()
                    ForEach(projectIDs, id: \.self) { id in
                        Button(projectNames[id] ?? "Project \(id)") { projectFilter = id }
                    }
                } label: {
                    Text(projectFilter.flatMap { projectNames[$0] } ?? "All projects")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var placeholder: String {
        let name = projectNames.values.sorted().first { $0.count > 3 } ?? "my project"
        return "What did I learn for \(name) three days ago?"
    }

    /// The direct answer: what the hub understood, then the matching entries in full.
    @ViewBuilder
    private func answerBlock(_ answer: HubAnswer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let project = answer.understoodProject { MainTag(text: project) }
                if let when = answer.understoodWhen { MainTag(text: when, color: p.accent2) }
                if let about = answer.understoodAbout { MainTag(text: about, color: p.textMuted) }
                Spacer(minLength: 0)
            }
            Text(answer.summary).font(DS.Font.body.weight(.semibold)).foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DS.Spacing.sm)
        ForEach(answer.sections) { section in
            WLGroup(title: section.title, subtitle: "\(section.items.count)", icon: MemoryKind(rawValue: section.kind)?.symbol ?? "square.stack") {
                ForEach(section.items) { item in
                    if item.id != section.items.first?.id { WLDivider() }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Text([item.project, HubDate.format(item.when)].compactMap { $0 }.joined(separator: " · "))
                                .font(DS.Font.micro).foregroundStyle(p.textFaint)
                            if let chat = item.chatID {
                                Button("Read the session") { reading = ReadingSession(id: chat, title: item.project ?? "Session", when: item.when) }
                                    .buttonStyle(.plain).font(DS.Font.micro.weight(.semibold)).foregroundStyle(p.accent)
                            }
                            if let project = item.projectID {
                                Button("Open project") { nav.open(project: project) }
                                    .buttonStyle(.plain).font(DS.Font.micro.weight(.semibold)).foregroundStyle(p.accent)
                            }
                        }
                    }
                }
            }
        }
        if !answer.sessions.isEmpty {
            WLGroup(title: "Sessions", subtitle: "What was worked on then. Click one to read it.", icon: "book") {
                ForEach(answer.sessions) { session in
                    if session.id != answer.sessions.first?.id { WLDivider() }
                    Button { reading = ReadingSession(id: session.chatID, title: session.title, when: session.when) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if !session.summary.isEmpty {
                                Text(session.summary).font(DS.Font.micro).foregroundStyle(p.textMuted)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            Text([session.project, HubDate.format(session.when)].compactMap { $0 }.joined(separator: " · "))
                                .font(DS.Font.micro).foregroundStyle(p.textFaint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
        kindFilter = nil
        projectFilter = nil
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

private struct AskResultCard: View {
    @Environment(\.palette) private var p
    let hit: HubSearchHit
    let projectName: String?
    let action: () -> Void
    @State private var hovering = false

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
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 280 ? String(flat.prefix(280)) + "…" : flat
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    MainTag(text: kindLabel)
                    Text(heading)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = hit.date {
                        Text(HubDate.format(date))
                            .font(DS.Font.timestamp)
                            .foregroundStyle(p.textMuted)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hovering ? p.accent : p.textFaint)
                }
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(DS.Font.bodySmall)
                        .foregroundStyle(p.text.opacity(0.85))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let decision = hit.decisions.first {
                    Label("Decided: \(decision.text)", systemImage: "checkmark.seal")
                        .font(DS.Font.micro)
                        .foregroundStyle(p.text.opacity(0.85))
                        .lineLimit(2)
                }
                if let around = hit.context.first {
                    Text("\(around.role ?? "") \u{00B7} \(around.text)")
                        .font(DS.Font.micro)
                        .foregroundStyle(p.textMuted)
                        .lineLimit(2)
                }
                if hit.source == "fuzzy" {
                    Text("Close spelling match").font(DS.Font.micro).foregroundStyle(p.textFaint)
                }
                if let name = projectName, hit.kind != "memory", hit.kind != "project" {
                    Label(name, systemImage: "folder")
                        .font(DS.Font.micro)
                        .foregroundStyle(p.textMuted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? p.surfaceRaised : p.surface,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(p.border.opacity(0.7), lineWidth: 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
        .help("Open in the hub")
    }
}


/// A saved session picked to be read in the app.
struct ReadingSession: Identifiable, Hashable {
    let id: Int
    let title: String
    let when: String?
}

/// The kinds a result can be narrowed to.
enum HitGroup: CaseIterable, Hashable {
    case memories, conversations, projects, other

    init(_ hit: HubSearchHit) {
        switch hit.kind {
        case "memory": self = .memories
        case "chat", "message", "convo", "howl": self = .conversations
        case "project": self = .projects
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .memories: return "Memories"
        case .conversations: return "Conversations"
        case .projects: return "Projects"
        case .other: return "Files"
        }
    }
}

private struct FilterChip: View {
    @Environment(\.palette) private var p
    let label: String
    let count: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(label) \(count)")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(on ? p.background : p.text)
                .background(on ? p.accent : p.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(p.border.opacity(on ? 0 : 0.7), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}
