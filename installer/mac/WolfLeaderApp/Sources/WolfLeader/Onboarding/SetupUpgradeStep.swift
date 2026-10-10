import SwiftUI

/// Shown when the AI's `[original]` section reports an original (SQLite) Wolf Leader hub.
/// Runs scripts/wolf-og-migrate.sh here or on the hub computer over SSH; Next skips it.
struct SetupUpgradeStep: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel
    @ObservedObject var runner: InstallRunner
    let start: () -> Void

    init(model: OnboardingModel, runner: InstallRunner, start: @escaping () -> Void) {
        self.model = model
        self.runner = runner
        self.start = start
    }

    private var hub: OriginalHub? { model.original }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupHeader(
                title: "Upgrade your original Wolf Leader",
                subtitle: "Your AI found the original, older Wolf Leader hub at \(model.value("wolf", "hub_url")). This version needs that hub upgraded first."
            )

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    bullet("Your projects, chats and memories are copied into the new hub.")
                    bullet("The original folder isn't changed. Its container is stopped and kept as wolf-leader-og.")
                    bullet("You can go back any time: Settings, Hub, Downgrade.")
                    if let hub, hub.canRun {
                        SetupSummaryRow(label: "Runs on", value: hub.runsWhere)
                        SetupSummaryRow(label: "Original folder", value: hub.folder)
                    }
                }
            }

            if let hub, hub.canRun {
                runControls
            } else {
                SetupNotice(kind: .warn, text: "Your AI couldn't log in to the hub computer with an SSH key, so run this on that computer, then click Next:")
                SetupCommandRow(command: OriginalHub.manualCommand(
                    repoURL: store.config.repoURL, branch: store.config.branch, action: "upgrade"))
            }

            if model.upgradeSucceeded != true {
                Text("Not now? Click Next to skip. This Mac still connects, but the new skills need the upgraded hub to work fully.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var runControls: some View {
        if OriginalHub.script == nil {
            SetupNotice(kind: .bad, text: "This copy of Wolf Leader is missing scripts/wolf-og-migrate.sh. Rebuild it with installer/mac/build-app.sh.")
        } else {
            HStack(spacing: 12) {
                Button(model.upgradeSucceeded == false ? "Try again" : "Upgrade now", action: start)
                    .buttonStyle(PrimaryButtonStyle(warm: true))
                    .disabled(runner.running || model.upgradeSucceeded == true)
                    .opacity(runner.running || model.upgradeSucceeded == true ? 0.5 : 1)
                if runner.running {
                    ProgressView().controlSize(.small)
                    Text(currentStep)
                        .font(.system(size: 13))
                        .foregroundStyle(p.textMuted)
                        .lineLimit(1)
                }
            }
            switch model.upgradeSucceeded {
            case .some(true):
                SetupNotice(kind: .good, text: "Upgraded. Your hub keeps the same address, so setup continues as normal. Click Next.")
            case .some(false):
                SetupNotice(kind: .bad, text: "The upgrade stopped (code \(runner.exitCode ?? -1)). The lines below say why. The original hub is untouched unless it says otherwise.")
            case .none:
                EmptyView()
            }
            if !runner.lines.isEmpty {
                log
            }
        }
    }

    private var currentStep: String {
        let marker = runner.lines.last { $0.hasPrefix("==> ") }
        return marker.map { String($0.dropFirst(4)) } ?? "Starting…"
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "•").foregroundStyle(p.textMuted)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(runner.lines.enumerated()), id: \.offset) { i, line in
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
            .frame(height: 200)
            .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.border))
            .onChange(of: runner.lines.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}
