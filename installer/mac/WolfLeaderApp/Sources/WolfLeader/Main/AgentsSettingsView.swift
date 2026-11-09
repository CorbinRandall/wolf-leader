import AppKit
import SwiftUI

/// Settings > Agents: every AI agent Wolf Leader can chat with, whether it's ready on this Mac,
/// and one click to install it, sign in, or point Wolf Leader at it. Custom ACP agents go here too.
struct AgentsSettingsGroup: View {
    @Environment(\.palette) private var p
    @ObservedObject private var agents = AgentRegistry.shared
    @StateObject private var runner = InstallRunner()
    @State private var installing: AgentKind?
    @State private var note: (text: String, ok: Bool)?
    @State private var adding = false
    @AppStorage("wl.claudeModel") private var claudeModel = ""

    var body: some View {
        WLGroup(title: "Agents", subtitle: "The AI agents you can start a chat with. Each runs on this Mac with your own account.",
                icon: "person.2.wave.2") {
            ForEach(agents.all) { agent in
                if agent.id != agents.all.first?.id { WLDivider() }
                AgentRow(agent: agent, busy: runner.running, install: { install(agent) })
            }
            WLDivider()
            VStack(alignment: .leading, spacing: 6) {
                Picker("Claude model", selection: $claudeModel) {
                    Text("Claude Code default").tag("")
                    Text("Fable 5.2").tag("claude-fable-5-2")
                    Text("Latest Fable").tag("fable")
                    Text("Latest Opus").tag("opus")
                    Text("Latest Sonnet").tag("sonnet")
                }
                Text("Applies when Claude connects to a chat. Fable 5.2 requires Claude Code 2.1.290 or newer and account access.")
                    .font(DS.Font.caption).foregroundStyle(p.textMuted)
            }
            WLDivider()
            HStack(spacing: 8) {
                Button { adding = true } label: { Label("Add another agent…", systemImage: "plus") }
                    .buttonStyle(OutlineButtonStyle())
                Button {
                    Task { await agents.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if agents.scanning { ProgressView().controlSize(.small) }
                        Text("Look again")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(agents.scanning)
                Spacer(minLength: 0)
            }
            if let note {
                Text(note.text)
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundStyle(note.ok ? p.good : p.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !runner.lines.isEmpty { SettingsLogBox(lines: runner.lines) }
        }
        .task { await agents.refresh() }
        // Back from the Terminal sign-in: show the new state without a click.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await agents.refresh() }
        }
        .onChange(of: runner.exitCode) { _, code in
            guard let code, let agent = installing else { return }
            installing = nil
            Task {
                await agents.refresh()
                if code == 0, agents.found[agent.id] != nil {
                    note = ("\(agent.name) is installed. Finish signing in in the Terminal window that just opened, then start a chat.", true)
                    agents.openSignIn(for: agent)
                } else if code == 0 {
                    note = ("The installer finished, but Wolf Leader can't find \(agent.name) yet. Click Look again, or Choose… to point at it.", false)
                } else {
                    note = ("Installing \(agent.name) stopped. See the log below.", false)
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddAgentSheet { agents.add($0) }
                .environment(\.palette, p)
        }
    }

    private func install(_ agent: AgentKind) {
        guard let script = agents.installScript(for: agent) else { return }
        note = nil
        installing = agent
        runner.run(script: script, args: [], env: [:])
    }
}

/// One agent: where it is (or isn't), and what you can do about it.
private struct AgentRow: View {
    @Environment(\.palette) private var p
    @ObservedObject private var agents = AgentRegistry.shared
    let agent: AgentKind
    let busy: Bool
    let install: () -> Void

    private var path: String? { agents.found[agent.id] }
    private var fromClaudeApp: Bool { path?.contains("/Application Support/Claude/claude-code/") == true }
    private var recipe: AgentRecipe { AgentRecipe.of(agent) }

    private var detail: String {
        guard let path else {
            return recipe.install == nil
                ? "Not found on this Mac. \(agent.installHint) Then click Look again, or Choose… to point at it."
                : "Not installed. Install sets it up, then you sign in once."
        }
        if fromClaudeApp { return "Using the copy inside the Claude app. Sign in once to chat with it." }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path) + (agents.chosenPath(for: agent) != nil ? " (chosen by you)" : "")
    }

    var body: some View {
        WLRow(title: "\(agent.name) · \(agent.company)", detail: detail) {
            HStack(spacing: 8) {
                if path != nil {
                    switch agents.signedIn[agent.id] {
                    case .some(true):
                        WLStatusPill(text: "Signed in", kind: .good)
                    case .some(false):
                        WLStatusPill(text: "Sign in needed", kind: .warn)
                    case .none:
                        WLStatusPill(text: "Found", kind: .good)
                    }
                    Button("Sign in…") { agents.openSignIn(for: agent) }
                        .buttonStyle(agents.signedIn[agent.id] == false ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(OutlineButtonStyle()))
                        .help("Opens Terminal running \(agent.name)'s sign-in. Click Look again when you're done.")
                }
                if recipe.install != nil, path == nil || fromClaudeApp {
                    Button(path == nil ? "Install" : "Install for Terminal too", action: install)
                        .buttonStyle(path == nil ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(OutlineButtonStyle()))
                        .disabled(busy)
                        .help(recipe.install ?? "")
                }
                Menu {
                    Button("Choose the program…") { choose() }
                    if agents.chosenPath(for: agent) != nil {
                        Button("Find it automatically again") { agents.choose(path: nil, for: agent) }
                    }
                    if let docs = recipe.docs {
                        Button("Install instructions") { NSWorkspace.shared.open(docs) }
                    }
                    if let path {
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                    }
                    if agents.isCustom(agent) {
                        Divider()
                        Button("Remove \(agent.name)", role: .destructive) { agents.remove(agent) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(agent.name) program"
        panel.message = "Pick the \(agent.binary) command-line program (not an app)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        agents.choose(path: url.path, for: agent)
    }
}

/// Add any agent by its command: most speak the Agent Client Protocol (ACP).
private struct AddAgentSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let add: (AgentKind) -> Void

    @State private var name = ""
    @State private var program = ""
    @State private var arguments = ""
    @State private var proto: AgentProtocol = .acp

    private var trimmedProgram: String { program.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !trimmedProgram.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an agent").font(DS.Font.section).foregroundStyle(p.text)
            Text("Any command-line agent that speaks the Agent Client Protocol works, plus other copies of Claude Code or Codex.")
                .font(DS.Font.caption).foregroundStyle(p.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            field("Name") { TextField("e.g. Qwen Code", text: $name).mainField() }
            field("Program") {
                HStack {
                    TextField("command name or full path, e.g. qwen", text: $program).mainField()
                    Button("Choose…") { choose() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            field("Arguments") { TextField("what starts it in ACP mode, e.g. --acp", text: $arguments).mainField() }
            field("Speaks") {
                Picker("Speaks", selection: $proto) {
                    Text("Agent Client Protocol (ACP)").tag(AgentProtocol.acp)
                    Text("Claude Code stream").tag(AgentProtocol.claude)
                    Text("Codex app-server").tag(AgentProtocol.codex)
                }
                .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Add") {
                    let program = trimmedProgram
                    let binary = program.hasPrefix("/") ? program : (program.split(separator: " ").first.map(String.init) ?? program)
                    add(AgentKind(id: "custom-" + UUID().uuidString.prefix(8).lowercased(),
                                  name: name.trimmingCharacters(in: .whitespaces),
                                  company: "Added by you",
                                  binary: binary,
                                  args: Self.split(arguments),
                                  proto: proto,
                                  installHint: "Install it, then sign in the way its docs describe.",
                                  symbol: "person.crop.circle.badge.plus"))
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 480)
        .background(p.background)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DS.Font.caption.weight(.semibold)).foregroundStyle(p.textMuted)
            content()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { program = url.path }
    }

    /// Splits arguments on spaces, keeping "quoted parts" together.
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
