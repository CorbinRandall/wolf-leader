import AppKit
import SwiftUI

/// One row of the live install checklist, derived from install.sh's `==> Step` markers.
struct SetupChecklistItem: Identifiable {
    enum Status { case pending, running, done, warning, skipped, failed }

    /// install.sh step title (or the prefix it starts with).
    let id: String
    let label: String
    var state: Status = .pending
    /// First WARN/FAIL text printed inside the step.
    var detail: String?
}

enum SetupChecklist {
    /// Steps install.sh prints, in order, for a mode (it prints every one, with "skip" when off).
    static func planned(mode: String) -> [SetupChecklistItem] {
        var s: [(String, String)] = [("Saving current state", "Save an undo point")]
        if mode == "new" { s.append(("Docker", "Check Docker")) }
        s += [
            ("Git and Python", "Git and Python"),
            ("Git identity", "Set your git name"),
            ("Network shares", "Connect network shares"),
            ("Cursor / Claude Code client", "Install agent skills and rule"),
            ("Obsidian", "Obsidian"),
        ]
        if mode == "new" { s.append(("Wolf Leader hub", "Start the hub in Docker")) }
        s.append(("Hub check", "Check the hub"))
        return s.map { SetupChecklistItem(id: $0.0, label: $0.1) }
    }

    static func build(lines: [String], mode: String, finished: Bool, success: Bool) -> [SetupChecklistItem] {
        var items = planned(mode: mode)
        var current: Int?
        var sawContent = false
        var onlySkip = true
        var warned = false
        var failed = false

        func close(_ i: Int) {
            if failed {
                items[i].state = .failed
            } else if warned {
                items[i].state = .warning
            } else if sawContent && onlySkip {
                items[i].state = .skipped
            } else {
                items[i].state = .done
            }
        }

        for line in lines {
            if line.hasPrefix("==> ") {
                if let c = current { close(c) }
                let title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let idx: Int
                if let found = items.firstIndex(where: { title.hasPrefix($0.id) }) {
                    idx = found
                } else {
                    items.append(SetupChecklistItem(id: title, label: title))
                    idx = items.count - 1
                }
                current = idx
                items[idx].state = .running
                sawContent = false
                onlySkip = true
                warned = false
                failed = false
                continue
            }
            guard let c = current else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            sawContent = true
            if t.hasPrefix("FAIL") {
                failed = true
                items[c].detail = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("WARN") {
                warned = true
                if items[c].detail == nil {
                    items[c].detail = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                }
            }
            if !t.hasPrefix("skip") { onlySkip = false }
        }

        if let c = current, finished {
            if success {
                close(c)
            } else {
                items[c].state = .failed
            }
        }
        return items
    }
}

struct SetupInstallStep: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel
    @ObservedObject var runner: InstallRunner
    @ObservedObject var undoRunner: InstallRunner
    let retry: () -> Void
    let undo: (URL) -> Void
    let openApp: () -> Void

    @State private var showDetails = false

    init(
        model: OnboardingModel, runner: InstallRunner, undoRunner: InstallRunner,
        retry: @escaping () -> Void, undo: @escaping (URL) -> Void, openApp: @escaping () -> Void
    ) {
        self.model = model
        self.runner = runner
        self.undoRunner = undoRunner
        self.retry = retry
        self.undo = undo
        self.openApp = openApp
    }

    private static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/WolfLeader/install.log")

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.outcome {
            case .none:
                runningView
            case .success(let result):
                successView(result)
            case .failure(let code, let result):
                failureView(code: code, result: result)
            }
        }
    }

    private var mode: String { model.path?.installMode ?? "connect" }

    private var items: [SetupChecklistItem] {
        let finished = runner.exitCode != nil && !runner.running
        return SetupChecklist.build(lines: runner.lines, mode: mode, finished: finished, success: runner.exitCode == 0)
    }

    // MARK: running

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupHeader(
                title: "Installing…",
                subtitle: mode == "new"
                    ? "Building the hub can take 10–15 minutes the first time. Keep this window open."
                    : "This usually takes a minute or two. Keep this window open."
            )
            if let error = model.installError {
                SetupNotice(kind: .bad, text: error)
            }
            checklist
            detailsLog
        }
    }

    private var checklist: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        stateIcon(item.state)
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.system(size: 13, weight: item.state == .running ? .semibold : .regular))
                                .foregroundStyle(item.state == .pending || item.state == .skipped ? p.textMuted : p.text)
                            if item.state == .skipped {
                                Text("Skipped")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.textMuted)
                            } else if let detail = item.detail {
                                Text(detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(item.state == .failed ? p.bad : p.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: SetupChecklistItem.Status) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(p.textMuted.opacity(0.6))
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(p.good)
        case .warning:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(p.warn)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(p.textMuted)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(p.bad)
        }
    }

    private var detailsLog: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            logBox(runner.lines, height: 240, follow: true)
                .padding(.top, 8)
        } label: {
            Text(showDetails ? "Hide details" : "Show details")
                .font(.system(size: 13))
                .foregroundStyle(p.textMuted)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showDetails.toggle() } }
        }
    }

    private func logBox(_ lines: [String], height: CGFloat, follow: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(verbatim: line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(p.text.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
            }
            .frame(height: height)
            .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.border))
            .onAppear {
                if follow, !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
            .onChange(of: lines.count) { _, n in
                if follow, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }

    // MARK: success

    private func successView(_ result: InstallResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(p.good)
                VStack(alignment: .leading, spacing: 4) {
                    Text("All set")
                        .font(.system(size: 30, weight: .bold))
                    Text(model.toggles.client
                         ? "Restart Cursor so it picks up the new skills."
                         : "Wolf Leader is ready on this Mac.")
                        .font(.system(size: 15))
                        .foregroundStyle(p.textMuted)
                }
            }

            switch result["health"] ?? "" {
            case "ok":
                SetupNotice(kind: .good, text: "Your hub answered at \(result["health_url"] ?? model.value("wolf", "hub_url")).")
            case "fail":
                SetupNotice(kind: .warn, text: "The hub didn't answer at \(result["health_url"] ?? "its address") yet. Is it running, and is this Mac on the same network? Wolf Leader will keep trying.")
            default:
                EmptyView()
            }

            if !result.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Good to know")
                        .font(.system(size: 14, weight: .bold))
                    ForEach(Array(result.notes.prefix(8).enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "•").foregroundStyle(p.textMuted)
                            Text(verbatim: note)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let backup = result["backup_dir"], !backup.isEmpty {
                HStack(spacing: 10) {
                    Text(verbatim: "Undo point: \(backup)")
                        .font(.system(size: 12))
                        .foregroundStyle(p.textMuted)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup)])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(p.accent)
                }
            }

            Button("Open Wolf Leader", action: openApp)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)

            detailsLog
        }
    }

    // MARK: failure

    private func failureView(code: Int32, result: InstallResult) -> some View {
        let restore = model.restoreScript(for: result)
        return VStack(alignment: .leading, spacing: 16) {
            SetupHeader(title: "Setup stopped before finishing", subtitle: failureMessage(code: code, result: result))
            if let error = model.installError {
                SetupNotice(kind: .bad, text: error)
            }
            checklist
            Text("Last lines from the installer")
                .font(.system(size: 13, weight: .semibold))
            logBox(Array(runner.lines.suffix(14)), height: 170, follow: true)

            HStack(spacing: 10) {
                Button("Try again", action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(runner.running || undoRunner.running)
                if let restore {
                    Button("Undo changes") { undo(restore) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(runner.running || undoRunner.running)
                }
                Button("Open full log") { NSWorkspace.shared.open(Self.logURL) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(p.accent)
            }

            undoStatus
            detailsLog
        }
    }

    @ViewBuilder
    private var undoStatus: some View {
        if undoRunner.running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Putting your files back…")
                    .font(.system(size: 13))
                    .foregroundStyle(p.textMuted)
            }
        } else if let code = undoRunner.exitCode {
            if code == 0 {
                SetupNotice(kind: .good, text: "Undone. The files Setup changed are back the way they were. Restart Cursor if it's open.")
            } else {
                SetupNotice(kind: .bad, text: "Undo didn't finish (code \(code)). The lines below say what it tried.")
            }
            if !undoRunner.lines.isEmpty {
                logBox(undoRunner.lines, height: 120, follow: true)
            }
        }
    }

    private func failureMessage(code: Int32, result: InstallResult) -> String {
        if let reason = result["reason"], !reason.isEmpty {
            if reason == "answer file is not valid" {
                return "The installer didn't accept your AI's reply. Go back to Ask your AI and paste it again."
            }
            return reason
        }
        switch code {
        case 2:
            return "The installer didn't accept the answers or options it was given."
        case 15, 143, -1:
            return "The installer was stopped before it finished."
        default:
            return "Something went wrong. The lines below show the last thing it tried. Nothing was lost: Setup made an undo point first."
        }
    }
}
