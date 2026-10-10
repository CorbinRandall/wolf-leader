import AppKit
import SwiftUI

private enum SettingsTab: String, Hashable {
    case general, hub, updates, about
}

struct SettingsView: View {
    @EnvironmentObject private var updates: UpdateChecker
    @State private var tab: SettingsTab = .general

    private var tabs: [WLTab<SettingsTab>] {
        [
            WLTab(id: .general, title: "General", icon: "slider.horizontal.3"),
            WLTab(id: .hub, title: "Hub", icon: "server.rack"),
            WLTab(id: .updates, title: "Updates", icon: "arrow.triangle.2.circlepath", attention: updates.hasUpdate),
            WLTab(id: .about, title: "About", icon: "info.circle"),
        ]
    }

    var body: some View {
        MainPage {
            HStack {
                WLTabBar(tabs: tabs, selection: $tab)
                Spacer(minLength: 0)
            }
            .padding(.bottom, DS.Spacing.xs)
            switch tab {
            case .general:
                SettingsAppearanceGroup()
                SettingsSetupGroup()
            case .hub:
                SettingsHubGroup()
                SettingsOriginalGroup()
            case .updates:
                SettingsUpdatesGroup(runner: updates.runner)
            case .about:
                SettingsAboutGroup()
            }
        }
    }
}

// MARK: - General: appearance

private struct SettingsAppearanceGroup: View {
    @EnvironmentObject private var themes: ThemeStore

    var body: some View {
        WLGroup(title: "Appearance", subtitle: "How Wolf Leader looks on this Mac.", icon: "paintpalette") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(ThemeID.allCases) { theme in
                    ThemeSwatchCard(theme: theme, selected: themes.themeID == theme) {
                        withAnimation(DS.Anim.swap) { themes.themeID = theme }
                    }
                }
            }
        }
    }
}

private struct ThemeSwatchCard: View {
    @Environment(\.palette) private var p
    let theme: ThemeID
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if theme == .system {
                        HStack(spacing: 0) {
                            ThemePreview(palette: ThemeStore.palette(for: .system, systemScheme: .dark))
                            ThemePreview(palette: ThemeStore.palette(for: .system, systemScheme: .light))
                        }
                    } else {
                        ThemePreview(palette: ThemeStore.palette(for: theme, systemScheme: .dark))
                    }
                }
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                        .strokeBorder(p.border.opacity(0.7), lineWidth: 0.6)
                )

                HStack(spacing: 6) {
                    Text(theme.label)
                        .font(DS.Font.bodySmall.weight(.semibold))
                        .foregroundStyle(p.text)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? p.accent : p.textFaint)
                }
                Text(theme.blurb)
                    .font(DS.Font.micro)
                    .foregroundStyle(p.textMuted)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(selected ? p.accent.opacity(0.12) : (hovering ? p.surfaceRaised : p.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(selected ? p.accent.opacity(0.8) : p.border.opacity(0.7), lineWidth: selected ? 1 : 0.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
    }
}

/// Miniature of the main window drawn in a palette's own colors.
private struct ThemePreview: View {
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(palette.accent).frame(height: 8)
                Capsule().fill(palette.textMuted.opacity(0.5)).frame(width: 26, height: 5)
                Capsule().fill(palette.textMuted.opacity(0.5)).frame(width: 20, height: 5)
                Spacer()
            }
            .padding(8)
            .frame(width: 50)
            .frame(maxHeight: .infinity)
            .background(palette.sidebar)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(palette.text.opacity(0.85)).frame(width: 40, height: 6)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.surfaceRaised)
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 4) {
                            Capsule().strokeBorder(palette.accent, lineWidth: 1).frame(width: 20, height: 8)
                            Capsule().fill(palette.accent2).frame(width: 14, height: 8)
                        }
                        .padding(6)
                    }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
        }
    }
}

// MARK: - General: setup

private struct SettingsSetupGroup: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

    @State private var confirmUndo = false
    @State private var undoing = false
    @State private var undoOutput: String? = nil
    @State private var undoOK: Bool? = nil

    private var restoreScript: String? {
        guard let dir = store.config.lastBackupPath, !dir.isEmpty else { return nil }
        let path = (dir as NSString).appendingPathComponent("restore.sh")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    var body: some View {
        WLGroup(title: "Setup", subtitle: "Change how this Mac connects, or put back what the last install changed.", icon: "wand.and.stars") {
            WLRow(title: "Run setup again", detail: "Walk through the setup steps. Your current settings stay until you finish.") {
                Button("Run setup") { store.showOnboarding = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            WLDivider()
            WLRow(
                title: "Undo last install",
                detail: restoreScript == nil
                    ? "No undo point found yet. Each install saves one."
                    : "Undo point: \(store.config.lastBackupPath ?? "")"
            ) {
                Button {
                    confirmUndo = true
                } label: {
                    HStack(spacing: 6) {
                        if undoing { ProgressView().controlSize(.small) }
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                        Text("Undo")
                    }
                }
                .buttonStyle(OutlineButtonStyle(tint: p.warn))
                .disabled(restoreScript == nil || undoing)
            }
            if let undoOutput {
                if let undoOK {
                    WLStatusPill(text: undoOK ? "Files put back. Restart Cursor and Claude Code." : "The undo script reported a problem.",
                                 kind: undoOK ? .good : .bad)
                }
                SettingsLogBox(lines: undoOutput.components(separatedBy: .newlines))
            }
        }
        .confirmationDialog("Undo the last install?", isPresented: $confirmUndo) {
            Button("Undo install", role: .destructive) { Task { await undo() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This puts back the Cursor and Claude Code files from before the last install and removes the ones it created. Keychain passwords, mounted shares and installed apps stay as they are.")
        }
    }

    private func undo() async {
        guard let script = restoreScript else { return }
        undoing = true
        defer { undoing = false }
        let result = await MainProcess.run("/bin/bash", [script, "-y"])
        undoOK = result.code == 0
        undoOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Hub

private struct SettingsHubGroup: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

    @State private var hubDraft = ""
    @State private var mcpDraft = ""
    @State private var testing = false
    @State private var hubResult: (ok: Bool, text: String)? = nil
    @State private var mcpResult: (ok: Bool, text: String)? = nil

    private var changed: Bool {
        hubDraft.trimmingCharacters(in: .whitespacesAndNewlines) != store.config.hubURL
            || mcpDraft.trimmingCharacters(in: .whitespacesAndNewlines) != store.config.mcpURL
    }

    var body: some View {
        WLGroup(title: "Hub", subtitle: "Where this Mac saves and reads memories.", icon: "server.rack") {
            addressRow("Hub address", detail: hubResult?.text ?? "REST API, for example http://wolf.local:6971",
                       example: "http://wolf.local:6971", text: $hubDraft, result: hubResult)
            WLDivider()
            addressRow("MCP address", detail: mcpResult?.text ?? "What Cursor and Claude Code connect to.",
                       example: "http://wolf.local:6972/mcp", text: $mcpDraft, result: mcpResult)
            WLDivider()
            WLRow(title: "Connection", detail: "Checks both addresses from this Mac.") {
                HStack(spacing: 8) {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack(spacing: 6) {
                            if testing { ProgressView().controlSize(.small) }
                            Text("Test connection")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(testing)
                    Button("Save") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!changed)
                        .opacity(changed ? 1 : 0.5)
                }
            }
        }
        .onAppear {
            hubDraft = store.config.hubURL
            mcpDraft = store.config.mcpURL
        }
    }

    private func addressRow(_ title: String, detail: String, example: String, text: Binding<String>,
                            result: (ok: Bool, text: String)?) -> some View {
        WLRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                if let result {
                    WLStatusPill(text: result.ok ? "Reachable" : "No answer", kind: result.ok ? .good : .bad)
                }
                TextField(example, text: text)
                    .mainField()
                    .frame(width: 260)
                    .onSubmit { save() }
            }
        }
    }

    private func save() {
        let hub = hubDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mcp = mcpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hub.isEmpty else { return }
        store.config.hubURL = hub
        if !mcp.isEmpty { store.config.mcpURL = mcp }
        store.save()
        hubDraft = store.config.hubURL
        mcpDraft = store.config.mcpURL
    }

    private func test() async {
        testing = true
        defer { testing = false }
        hubResult = nil
        mcpResult = nil
        let hub = hubDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mcp = mcpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        async let hubOK = HubClient(baseURL: hub).isHealthy(timeout: 6)
        async let mcpOK = Self.reachable(mcp)
        let (h, m) = await (hubOK, mcpOK)
        hubResult = h
            ? (ok: true, text: "The hub answered.")
            : (ok: false, text: "No answer from \(hub)/health.")
        mcpResult = m
            ? (ok: true, text: "The MCP server answered.")
            : (ok: false, text: "No answer from \(mcp).")
    }

    /// Any HTTP response counts: the MCP endpoint rejects plain GETs but still answers.
    static func reachable(_ address: String) async -> Bool {
        guard let url = URL(string: address), url.host != nil else { return false }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        // bytes(for:) returns once headers arrive, so an open event stream can't stall the check.
        guard let answer = try? await URLSession.shared.bytes(for: req) else { return false }
        answer.0.task.cancel()
        return answer.1 is HTTPURLResponse
    }
}

// MARK: - Hub: downgrade to the original Wolf Leader

private struct SettingsOriginalGroup: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @StateObject private var runner = InstallRunner()
    @State private var confirm = false

    var body: some View {
        if let hub = store.config.original, hub.upgraded || runner.exitCode != nil {
            WLGroup(title: "Original Wolf Leader", subtitle: "This hub was upgraded from the original Wolf Leader. You can go back to it.", icon: "clock.arrow.circlepath") {
                WLRow(
                    title: "Downgrade",
                    detail: hub.canRun
                        ? "Stops the new hub on \(hub.runsWhere), copies everything saved since the upgrade back into the original (its old file is backed up first) and starts the original again."
                        : "Run this on the hub computer:"
                ) {
                    if hub.canRun {
                        Button {
                            confirm = true
                        } label: {
                            HStack(spacing: 6) {
                                if runner.running { ProgressView().controlSize(.small) }
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                                Text("Downgrade")
                            }
                        }
                        .buttonStyle(OutlineButtonStyle(tint: p.warn))
                        .disabled(runner.running || !hub.upgraded || OriginalHub.script == nil)
                    }
                }
                if !hub.canRun {
                    SetupCommandRow(command: OriginalHub.manualCommand(
                        repoURL: store.config.repoURL, branch: store.config.branch, action: "revert"))
                }
                if let code = runner.exitCode {
                    WLStatusPill(text: code == 0 ? "Back on the original Wolf Leader." : "The downgrade stopped (code \(code)); see below.",
                                 kind: code == 0 ? .good : .bad)
                }
                if !runner.lines.isEmpty {
                    SettingsLogBox(lines: runner.lines)
                }
            }
            .confirmationDialog("Go back to the original Wolf Leader?", isPresented: $confirm) {
                Button("Downgrade", role: .destructive) { start(hub) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The new hub's database is kept, so you can upgrade again later. Features the original lacks, like /wolfhowl and /wolfeat, stop working.")
            }
            .onChange(of: runner.exitCode) { _, code in
                guard code == 0 else { return }
                store.config.original?.upgraded = false
                store.save()
            }
        }
    }

    private func start(_ hub: OriginalHub) {
        guard let script = OriginalHub.script else { return }
        runner.run(script: script, args: hub.args("revert", hubURL: store.config.hubURL), env: [:])
    }
}

// MARK: - Updates

private struct SettingsUpdatesGroup: View {
    @EnvironmentObject private var updates: UpdateChecker
    @Environment(\.palette) private var p
    @ObservedObject var runner: InstallRunner

    private var working: Bool { updates.preparing || runner.running }

    private var statusTitle: String {
        switch updates.status {
        case .idle, .checking: return "Checking for updates…"
        case .upToDate: return "Up to date"
        case .available(let n): return "Update available · \(n) new commit\(n == 1 ? "" : "s")"
        case .branchHead: return "Latest on \(updates.branch)"
        case .notConfigured: return "Update checks are off"
        case .failed: return "Couldn't check for updates"
        }
    }

    private var statusDetail: String {
        var parts: [String] = []
        switch updates.status {
        case .branchHead: parts.append("This build doesn't record its commit.")
        case .notConfigured: parts.append("This build has no GitHub repository set.")
        case .failed(let why): parts.append(why)
        default: break
        }
        if let checked = updates.lastChecked { parts.append("Last checked \(HubDate.format(checked))") }
        return parts.isEmpty ? "Checks GitHub on launch and every 6 hours." : parts.joined(separator: " ")
    }

    private var statusPill: (String, WLStatusKind)? {
        switch updates.status {
        case .upToDate: return ("Current", .good)
        case .available: return ("New", .warn)
        case .failed: return ("Offline", .bad)
        default: return nil
        }
    }

    var body: some View {
        WLGroup(title: "Updates", subtitle: "Keep the skills, rule and this app current.", icon: "arrow.triangle.2.circlepath") {
            WLRow(title: statusTitle, detail: statusDetail) {
                HStack(spacing: 8) {
                    if let pill = statusPill { WLStatusPill(text: pill.0, kind: pill.1) }
                    Button {
                        Task { await updates.check() }
                    } label: {
                        HStack(spacing: 6) {
                            if updates.status == .checking { ProgressView().controlSize(.small) }
                            Text("Check now")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(updates.status == .checking)
                }
            }
            WLDivider()
            WLRow(title: "Branch", detail: "Which GitHub branch to follow. Pushes to it show up here as updates.") {
                Picker("Branch", selection: Binding(
                    get: { updates.branch },
                    set: { updates.setBranch($0) }
                )) {
                    ForEach(updates.branches.isEmpty ? [updates.branch] : updates.branches, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(working)
                .task { await updates.loadBranches() }
            }
            WLDivider()
            WLRow(title: "Skills & rule", detail: "Downloads the latest Cursor and Claude Code files from GitHub and installs them. Makes an undo point first.") {
                Button {
                    Task { await updates.updateSkills() }
                } label: {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.small) }
                        Text("Update skills & rule")
                    }
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(working || updates.repo == nil)
            }
            WLDivider()
            WLRow(title: "App", detail: "New versions of this app are published on GitHub.") {
                Button("Get the new app") { MainLinks.open(updates.releasesURL) }
                    .buttonStyle(updates.hasUpdate ? OutlineButtonStyle(tint: p.warn) : OutlineButtonStyle(tint: p.textMuted))
                    .disabled(updates.releasesURL == nil)
            }
            if let note = updates.updateNote {
                Text(note)
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundStyle(noteColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !runner.lines.isEmpty {
                SettingsLogBox(lines: runner.lines)
            }
        }

        if !updates.commits.isEmpty {
            WLGroup(title: updates.hasUpdate ? "What's new" : "Latest commit", icon: "list.bullet.rectangle") {
                ForEach(updates.commits.prefix(25)) { commit in
                    if commit.id != updates.commits.first?.id { WLDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(commit.shortSHA)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(p.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.title.isEmpty ? "(no message)" : commit.title)
                                .font(DS.Font.bodySmall)
                                .foregroundStyle(p.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text([commit.author, HubDate.format(commit.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(DS.Font.timestamp)
                                .foregroundStyle(p.textMuted)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if updates.commits.count > 25 {
                    Text("and \(updates.commits.count - 25) more")
                        .font(DS.Font.micro)
                        .foregroundStyle(p.textMuted)
                }
            }
        }
    }

    private var noteColor: Color {
        switch updates.updateSucceeded {
        case .some(true): return p.good
        case .some(false): return p.bad
        case .none: return p.textMuted
        }
    }
}

/// Scrolling monospaced output that follows the newest line.
private struct SettingsLogBox: View {
    @Environment(\.palette) private var p
    let lines: [String]

    var body: some View {
        let shown = Array(lines.suffix(500))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { item in
                        Text(item.element.isEmpty ? " " : item.element)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(p.text.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(item.offset)
                    }
                }
                .padding(10)
            }
            .frame(height: 180)
            .background(p.background, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .strokeBorder(p.border.opacity(0.7), lineWidth: 0.6)
            )
            .onAppear { proxy.scrollTo(shown.count - 1, anchor: .bottom) }
            .onChange(of: lines.count) {
                proxy.scrollTo(min(lines.count, 500) - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: - About

private struct SettingsAboutGroup: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

    var body: some View {
        WLGroup(title: "Wolf Leader", subtitle: "Memory for your AI coding agents, on your own hub.", icon: "info.circle") {
            row("Version", BuildInfo.version)
            WLDivider()
            row("Commit", BuildInfo.gitSHA.map { String($0.prefix(10)) } ?? "Not recorded in this build")
            WLDivider()
            row("Branch", store.config.branch.isEmpty ? BuildInfo.branch : store.config.branch)
            WLDivider()
            row("Repository", store.config.repoURL.isEmpty ? "Not set" : store.config.repoURL)
            WLDivider()
            row("This Mac", store.config.deviceName)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        WLRow(title: title) {
            Text(value)
                .font(DS.Font.bodySmall.weight(.medium))
                .foregroundStyle(p.textMuted)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
