import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

    @State private var projects: [HubProject] = []
    @State private var loadError: String? = nil
    @State private var loading = true
    @State private var query = ""
    @State private var selectedID: Int? = nil

    private var filtered: [HubProject] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.slug ?? "").localizedCaseInsensitiveContains(q)
                || ($0.description ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var selected: HubProject? {
        guard let selectedID else { return nil }
        return projects.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 290)
            Rectangle().fill(p.divider).frame(width: 1)
            Group {
                if let project = selected {
                    ProjectDetailView(project: project)
                        .id(project.id)
                } else {
                    MainPage {
                        MainNotice(
                            symbol: "folder",
                            title: projects.isEmpty ? "No projects to show" : "Pick a project",
                            message: projects.isEmpty
                                ? "Projects appear once an agent saves its first chat."
                                : "Its memories, recent chats and brief show up here."
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(p.background)
        .task(id: store.config.hubURL) { await load() }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            WLPageHeader(title: "Projects", subtitle: "\(projects.count) on your hub") {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Refresh")
            }
            WLSearchField(text: $query, placeholder: "Search projects")

            if loading && projects.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                }
                Spacer()
            } else if let loadError, projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Can't reach your hub at \(store.config.hubURL)")
                        .font(DS.Font.bodySmall.weight(.semibold))
                        .foregroundStyle(p.text)
                    Text(loadError)
                        .font(DS.Font.caption)
                        .foregroundStyle(p.textMuted)
                    Text("Check the hub address in Settings.")
                        .font(DS.Font.caption)
                        .foregroundStyle(p.textMuted)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { project in
                            ProjectRow(project: project, selected: project.id == selectedID) {
                                withAnimation(DS.Anim.select) { selectedID = project.id }
                            }
                        }
                        if filtered.isEmpty {
                            Text(query.isEmpty ? "No projects yet." : "No projects match \u{201C}\(query)\u{201D}.")
                                .font(DS.Font.caption)
                                .foregroundStyle(p.textMuted)
                                .padding(.top, 8)
                        }
                    }
                }
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            projects = try await store.hub.projects()
            loadError = nil
            if selectedID == nil || !projects.contains(where: { $0.id == selectedID }) {
                selectedID = projects.first?.id
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct ProjectRow: View {
    @Environment(\.palette) private var p
    let project: HubProject
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? p.onAccent : p.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(project.memoryCount) memories")
                    if let d = project.updated {
                        Text("·")
                        Text(HubDate.format(d))
                    }
                }
                .font(DS.Font.micro.monospacedDigit())
                .foregroundStyle(selected ? p.onAccent.opacity(0.85) : p.textMuted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .fill(selected ? p.accent : (hovering ? p.surfaceRaised.opacity(0.6) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
    }
}

private struct MemoryGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [HubMemory]
}

private struct ProjectDetailView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    let project: HubProject

    @State private var memories: [HubMemory] = []
    @State private var chats: [HubChat] = []
    @State private var loading = true
    @State private var loadError: String? = nil

    private var groups: [MemoryGroup] {
        var out: [MemoryGroup] = MemoryKind.allCases.compactMap { (kind: MemoryKind) -> MemoryGroup? in
            let items = memories.filter { $0.kind == kind }
            return items.isEmpty ? nil : MemoryGroup(id: kind.rawValue, title: kind.label, symbol: kind.symbol, items: items)
        }
        let other = memories.filter { $0.kind == nil }
        if !other.isEmpty {
            out.append(MemoryGroup(id: "other", title: "Other", symbol: "square.stack", items: other))
        }
        return out
    }

    var body: some View {
        MainPage {
            WLPageHeader(title: project.name, subtitle: subtitle) {
                HStack(spacing: 8) {
                    Button("Open brief") {
                        MainLinks.open(store.hub.briefURL(projectKey: project.key))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        MainLinks.open(store.hub.webURL(project: project.id))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                            Text("Open in hub")
                        }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
            if let description = project.description {
                Text(description)
                    .font(DS.Font.bodySmall)
                    .foregroundStyle(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loading && memories.isEmpty && chats.isEmpty {
                Card {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading memories…").font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                    }
                }
            } else if let loadError {
                MainNotice(symbol: "wifi.exclamationmark", title: "Can't load this project", message: loadError)
            } else {
                memoriesSection
                chatsGroup
            }
        }
        .task(id: project.id) { await load() }
    }

    private var subtitle: String {
        var parts = ["\(project.memoryCount) memories", "\(project.chatCount) chats"]
        if let d = project.updated { parts.append("last activity \(HubDate.format(d))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var memoriesSection: some View {
        if groups.isEmpty {
            MainNotice(symbol: "brain",
                       title: "No memories yet",
                       message: "Decisions, constraints and fixes appear here as agents save them.")
        } else {
            ForEach(groups) { group in
                WLGroup(
                    title: group.title,
                    subtitle: "\(group.items.count) \(group.items.count == 1 ? "memory" : "memories")",
                    icon: group.symbol
                ) {
                    ForEach(group.items) { memory in
                        if memory.id != group.items.first?.id { WLDivider() }
                        Text(memory.content)
                            .font(DS.Font.bodySmall)
                            .foregroundStyle(p.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var chatsGroup: some View {
        WLGroup(title: "Recent chats", subtitle: "Active sessions in this project.", icon: "bubble.left.and.bubble.right") {
            if chats.isEmpty {
                Text("No active chats in this project.")
                    .font(DS.Font.bodySmall)
                    .foregroundStyle(p.textMuted)
            } else {
                ForEach(chats) { chat in
                    if chat.id != chats.first?.id { WLDivider() }
                    Button {
                        MainLinks.open(store.hub.webURL(chat: chat.id))
                    } label: {
                        HStack {
                            Text(chat.title)
                                .font(DS.Font.body)
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            Spacer()
                            Text(HubDate.format(chat.when))
                                .font(DS.Font.timestamp)
                                .foregroundStyle(p.textMuted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(p.textFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in the hub")
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let hub = store.hub
        do {
            async let ms = hub.memories(projectID: project.id)
            async let cs = hub.chats(projectID: project.id, limit: 15)
            let (loadedMemories, loadedChats) = try await (ms, cs)
            memories = loadedMemories
            chats = loadedChats
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
