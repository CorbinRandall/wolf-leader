import SwiftUI

struct AskView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

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
        .onAppear { focused = true }
    }

    /// Hero tile in the shape of MacParakeet's "Transcribe YouTube & more".
    private var hero: some View {
        Tile {
            VStack(spacing: DS.Spacing.md) {
                AskIconCluster()
                Text("Ask your memory")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(p.text)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(p.textMuted)
                        TextField("What did we work on in the billing service around March 3?", text: $query)
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
                            Text("Ask")
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(!canSearch)
                }
                .frame(maxWidth: 520)
                Text("Searches memories, chats, projects and files saved by every agent, on your own hub.")
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
        } else if hits.isEmpty && !searching {
            MainNotice(
                symbol: "questionmark.bubble",
                title: "Nothing found for \u{201C}\(lastQuery)\u{201D}",
                message: "Try fewer or different words."
            )
        } else {
            WLSectionLabel(text: "\(hits.count) result\(hits.count == 1 ? "" : "s") for \u{201C}\(lastQuery)\u{201D}")
                .padding(.top, DS.Spacing.sm)
            LazyVStack(spacing: DS.Spacing.sm + 4) {
                ForEach(hits) { hit in
                    AskResultCard(hit: hit, projectName: projectName(for: hit)) {
                        open(hit)
                    }
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
        let hub = store.hub
        if let chat = hit.linkedChatID {
            MainLinks.open(hub.webURL(chat: chat))
        } else if let project = hit.linkedProjectID {
            MainLinks.open(hub.webURL(project: project))
        } else {
            MainLinks.open(hub.webURL)
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
                let found = try await store.hub.search(q)
                guard !Task.isCancelled else { return }
                hits = found
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
        default: return hit.kind
        }
    }

    private var heading: String {
        switch hit.kind {
        case "memory": return projectName ?? "Memory"
        case "message": return hit.chatTitle ?? hit.title ?? "Chat message"
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
