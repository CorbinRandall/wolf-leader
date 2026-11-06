import AppKit
import SwiftUI

/// One chat with one agent, inside a project. Replies stream in; steps the agent takes show as
/// short rows you can open; anything that needs your OK waits for you here.
struct ChatView: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var nav: Navigator
    @Environment(\.palette) private var p
    @ObservedObject var session: ChatSession
    @ObservedObject private var rules = ChatRules.shared
    let back: () -> Void
    @State private var draft = ""
    @State private var choosingProject = false
    @State private var snippets: [HubSnippet] = []
    @FocusState private var composing: Bool

    private var record: ChatRecord { session.record }
    private var agent: AgentKind? { record.agent }
    private var installed: Bool { agent.map { AgentRegistry.shared.program(for: $0) != nil } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(p.border).frame(height: 1)
            transcript
            if let other = busyElsewhere { elsewhereBar(other) }
            if !installed, let agent, !record.items.isEmpty, !session.busy { missingAgentBar(agent) }
            if needsSignIn, let agent { signInBar(agent) }
            composer
        }
        .background(p.background)
        .onAppear { composing = true }
        .sheet(isPresented: $choosingProject) {
            ProjectPickerSheet(current: record.projectID) { session.attach(to: $0, config: store) }
                .environment(\.palette, p)
                .environmentObject(store)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(record.projectName ?? "Chats")
                }
                .font(DS.Font.bodySmall.weight(.medium)).foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(record.title).font(DS.Font.section).foregroundStyle(p.text).lineLimit(1)
                if let agent { MainTag(text: "\(agent.name) · \(agent.company)") }
                Spacer(minLength: 8)
                continueWithMenu
                Button {
                    choosingProject = true
                } label: {
                    Label(record.projectName.map { "In \($0)" } ?? "Add to a project…",
                          systemImage: record.projectID == nil ? "folder.badge.plus" : "folder")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(record.projectID == nil ? "Connect this chat to a project. Wolf Leader files it there." : "Move this chat to another project")
                saveBadge
                Menu {
                    if rules.neverAsk {
                        Text("Never ask is on for every chat: agents act without asking.")
                        Button("Change in Settings > Rules…") { nav.open(settingsTab: "rules") }
                    } else {
                        ForEach(PermissionMode.allCases) { mode in
                            Button { session.setMode(mode) } label: {
                                if mode == record.mode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                            }
                            .help(mode.help)
                        }
                        Divider()
                        Button("Rules for every chat…") { nav.open(settingsTab: "rules") }
                    }
                } label: {
                    Label(rules.neverAsk ? "Never asks" : record.mode.label,
                          systemImage: rules.neverAsk || record.mode == .auto ? "bolt.fill" : "hand.raised")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(rules.neverAsk ? "Every chat runs without asking (Settings > Rules)." : record.mode.help)
            }
            Text(folderLine).font(DS.Font.micro).foregroundStyle(p.textFaint).lineLimit(1).truncationMode(.middle)
                .help(record.cwd)
        }
        .padding(.horizontal, DS.Spacing.lg).padding(.vertical, 14)
    }

    private var folderLine: String {
        if ProjectWorkspace.isWorkspace(record.cwd) { return "Works in \(record.projectName ?? "the project")'s folder on the server" }
        if record.cwd.hasPrefix(ProjectWorkspace.looseRoot.path) { return "Works in a scratch folder until it's added to a project" }
        return "Works in \(record.cwd)"
    }

    @ViewBuilder
    private var saveBadge: some View {
        switch session.saveState {
        case .idle: EmptyView()
        case .saving: WLStatusPill(text: "Saving to Wolf Leader…", kind: .neutral)
        case .saved(let when): WLStatusPill(text: "Saved \(when.formatted(date: .omitted, time: .shortened))", kind: .good)
        case .failed(let why): WLStatusPill(text: "Not saved", kind: .bad).help(why)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if record.items.isEmpty { emptyState }
                    ForEach(record.items) { item in
                        ChatItemView(item: item, session: session).id(item.id)
                    }
                    if session.busy && !session.pendingApprovals {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(session.preparing ?? (session.connecting ? "Starting \(agent?.name ?? "the agent")…" : "Working…"))
                                .font(DS.Font.caption).foregroundStyle(p.textMuted)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, DS.Spacing.lg).padding(.vertical, DS.Spacing.md)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: record.items.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") } }
            .onChange(of: record.items.last?.text.count ?? 0) { _, _ in proxy.scrollTo("bottom") }
            .onAppear { proxy.scrollTo("bottom") }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: agent?.symbol ?? "bubble.left").font(.system(size: 24, weight: .semibold)).foregroundStyle(p.accent)
            Text(record.projectName.map { "Ask \(agent?.name ?? "the agent") anything about \($0)." } ?? "Ask \(agent?.name ?? "the agent") anything.")
                .font(DS.Font.section).foregroundStyle(p.text)
            Text(record.projectID == nil
                 ? "This chat is saved to Wolf Leader after every reply. Add it to a project any time, and Wolf Leader files it there."
                 : "It starts with this project's notes, works in the project's folder on the server, and is saved back to the project after every reply.")
                .font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
            if !installed, let agent {
                WLStatusPill(text: "\(agent.name) isn't set up on this Mac yet", kind: .warn)
                Button("Set up \(agent.name)…") { nav.open(libraryTab: "tools") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.vertical, DS.Spacing.lg)
    }

    // MARK: Other devices and agents

    /// The device this chat is working on right now, when it isn't this one.
    private var busyElsewhere: String? {
        session.busy ? nil : record.busyElsewhere(than: ChatSync.shared.device)
    }

    private func elsewhereBar(_ device: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Working on \(device) right now. Its replies show up here as they're saved; you can send when it's done.")
                .font(DS.Font.caption).foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.lg).padding(.vertical, 10)
        .background(p.accent.opacity(0.08))
    }

    /// The chat came from another device whose agent this Mac doesn't have: carry on with one it does.
    private func missingAgentBar(_ agent: AgentKind) -> some View {
        let ready = AgentRegistry.shared.all.filter { AgentRegistry.shared.found[$0.id] != nil }
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.swap").foregroundStyle(p.accent)
            Text("\(agent.name) isn't set up on this Mac. Carry on with:")
                .font(DS.Font.caption).foregroundStyle(p.text)
            ForEach(ready.prefix(4)) { other in
                Button(other.name) { session.switchAgent(to: other) }.buttonStyle(OutlineButtonStyle())
            }
            Button("Set up \(agent.name)…") { nav.open(libraryTab: "tools") }.buttonStyle(SecondaryButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.lg).padding(.vertical, 10)
        .background(p.accent.opacity(0.06))
    }

    /// Keep this chat, carry on with a different agent.
    private var continueWithMenu: some View {
        let others = AgentRegistry.shared.all.filter { $0.id != record.agentID && AgentRegistry.shared.found[$0.id] != nil }
        return Menu {
            if others.isEmpty {
                Button("Set up more agents…") { nav.open(libraryTab: "tools") }
            } else {
                Section("Continue this chat with") {
                    ForEach(others) { other in
                        Button { session.switchAgent(to: other) } label: { Label("\(other.name) · \(other.company)", systemImage: other.symbol) }
                    }
                }
            }
        } label: {
            Label("Continue with…", systemImage: "arrow.triangle.swap").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(session.busy || busyElsewhere != nil)
        .help("Hand this chat to another agent. It gets the conversation so far and carries on.")
    }

    // MARK: Sign-in

    /// The agent's last error says it isn't signed in (e.g. Claude Code's "Not logged in · Please run /login").
    private var needsSignIn: Bool {
        guard !session.busy, let last = record.items.last, last.kind == .error else { return false }
        let text = last.text.lowercased()
        return ["not logged in", "please run /login", "log in", "login required", "not authenticated",
                "unauthenticated", "sign in", "authentication required", "auth login"].contains { text.contains($0) }
    }

    private func signInBar(_ agent: AgentKind) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key").foregroundStyle(p.warn)
            Text("\(agent.name) needs you to sign in once on this Mac. It opens in Terminal; come back here when it says you're in.")
                .font(DS.Font.caption).foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Sign in to \(agent.name)") { AgentRegistry.shared.openSignIn(for: agent) }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, DS.Spacing.lg).padding(.vertical, 10)
        .background(p.warn.opacity(0.08))
    }

    // MARK: Composer

    /// Saved snippets (Library > Snippets), this project's first, dropped into the message.
    private var snippetMenu: some View {
        let mine = snippets.filter { $0.projectID != nil && $0.projectID == record.projectID }
        let others = snippets.filter { !($0.projectID != nil && $0.projectID == record.projectID) }
        return Menu {
            if snippets.isEmpty {
                Text("No snippets yet")
                Button("Add snippets in Library…") { nav.open(libraryTab: "snippets") }
            }
            if !mine.isEmpty {
                Section(record.projectName ?? "This project") {
                    ForEach(mine) { s in Button(s.title) { insert(s.content) } }
                }
            }
            if !others.isEmpty {
                Section("Snippets") {
                    ForEach(others.prefix(30)) { s in Button(s.title) { insert(s.content) } }
                }
            }
        } label: {
            Image(systemName: "text.insert")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Insert a saved snippet")
        .disabled(session.busy || busyElsewhere != nil)
        .task(id: store.config.hubURL) { snippets = (try? await store.hub.snippets()) ?? [] }
    }

    private func insert(_ text: String) {
        draft = draft.isEmpty ? text : draft + (draft.hasSuffix("\n") ? "" : "\n") + text
        composing = true
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            snippetMenu
            TextField("Message \(agent?.name ?? "the agent")…", text: $draft, axis: .vertical)
                .lineLimit(1...10)
                .focused($composing)
                .mainField()
                .onSubmit(send)
                .disabled(session.busy || busyElsewhere != nil)
            if session.busy {
                Button { session.interrupt() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send", action: send)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, DS.Spacing.lg).padding(.vertical, 12)
        .frame(maxWidth: 860 + DS.Spacing.lg * 2)
        .frame(maxWidth: .infinity)
        .background(p.background)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.busy else { return }
        draft = ""
        session.send(text, config: store)
        composing = true
    }
}

/// One line of the chat.
private struct ChatItemView: View {
    @Environment(\.palette) private var p
    let item: ChatItem
    @ObservedObject var session: ChatSession
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                MarkdownText(text: item.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(p.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .agent:
            MarkdownText(text: item.text).frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            DisclosureGroup(isExpanded: $open) {
                Text(item.text).font(DS.Font.caption).foregroundStyle(p.textMuted).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Thinking").font(DS.Font.caption.italic()).foregroundStyle(p.textFaint)
            }
        case .tool:
            tool
        case .approval:
            approval
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.bad)
                Text(item.text).font(DS.Font.bodySmall).foregroundStyle(p.text).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bad.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .note:
            Text(item.text).font(DS.Font.caption).foregroundStyle(p.textMuted).textSelection(.enabled)
        }
    }

    private var tool: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(item.text).font(DS.Font.caption.monospaced()).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if !item.detail.isEmpty || !item.output.isEmpty {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(p.textFaint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach([item.detail, item.output].filter { !$0.isEmpty }, id: \.self) { block in
                    ScrollView {
                        Text(block).font(DS.Font.micro.monospaced()).foregroundStyle(p.textMuted).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(8)
                    .background(p.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .running: ProgressView().controlSize(.mini).frame(width: 14)
        case .failed, .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(p.bad).font(.system(size: 12))
        default: Image(systemName: "checkmark.circle.fill").foregroundStyle(p.good).font(.system(size: 12))
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(p.accent2)
                Text("Wants to: \(item.text)").font(DS.Font.bodySmall.weight(.semibold)).foregroundStyle(p.text)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(DS.Font.micro.monospaced()).foregroundStyle(p.textMuted).lineLimit(12).textSelection(.enabled)
            }
            switch item.status {
            case .pending:
                HStack(spacing: 8) {
                    Button("Allow") { session.answer(item.id, allow: true) }.buttonStyle(PrimaryButtonStyle())
                    Button("Always allow") { session.answer(item.id, allow: true, always: true) }.buttonStyle(OutlineButtonStyle())
                    Button("Don't allow") { session.answer(item.id, allow: false) }.buttonStyle(OutlineButtonStyle())
                }
            case .allowed:
                Text("Allowed").font(DS.Font.micro).foregroundStyle(p.good)
            default:
                Text("Not allowed").font(DS.Font.micro).foregroundStyle(p.textFaint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.accent2.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.accent2.opacity(0.4), lineWidth: 1))
    }
}

/// Markdown with code blocks set apart. Inline styles (bold, `code`, links) come from AttributedString.
struct MarkdownText: View {
    @Environment(\.palette) private var p
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    ScrollView(.horizontal) {
                        Text(segment.text).font(DS.Font.caption.monospaced()).foregroundStyle(p.text).textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text(Self.attributed(segment.text)).font(DS.Font.body).foregroundStyle(p.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func segments(_ text: String) -> [(text: String, code: Bool)] {
        let parts = text.components(separatedBy: "```")
        return parts.enumerated().compactMap { index, part in
            let code = index % 2 == 1
            var body = part
            if code, let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
            body = body.trimmingCharacters(in: code ? .newlines : .whitespacesAndNewlines)
            return body.isEmpty ? nil : (body, code)
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
