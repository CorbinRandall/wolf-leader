import AppKit
import SwiftUI

/// First-launch setup: one window, a step rail on the left, Back/Next at the bottom, no pop-ups.
struct OnboardingView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @StateObject private var model = OnboardingModel()
    @StateObject private var runner = InstallRunner()
    @StateObject private var undoRunner = InstallRunner()
    @StateObject private var upgradeRunner = InstallRunner()

    var body: some View {
        HStack(spacing: 0) {
            SetupStepRail(model: model, locked: runner.running || undoRunner.running || upgradeRunner.running)
                .frame(width: 236)
                .background(p.sidebar)
            Rectangle().fill(p.border).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    stepContent
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 44)
                        .padding(.top, 32)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity)
                }
                if showsBottomBar {
                    Rectangle().fill(p.border).frame(height: 1)
                    bottomBar
                }
            }
            .background(p.background)
        }
        .foregroundStyle(p.text)
        .onAppear { model.attach(store) }
        .onChange(of: runner.exitCode) { _, code in
            guard let code else { return }
            model.finishInstall(code: code, store: store)
        }
        .onChange(of: upgradeRunner.exitCode) { _, code in
            guard let code else { return }
            model.finishUpgrade(code: code)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: SetupWelcomeStep()
        case .path: SetupPathStep(model: model)
        case .server: SetupServerStep(model: model)
        case .toggles: SetupTogglesStep(model: model)
        case .askAI: SetupAskAIStep(model: model)
        case .upgrade: SetupUpgradeStep(model: model, runner: upgradeRunner, start: startUpgrade)
        case .passwords: SetupPasswordsStep(model: model)
        case .git: SetupGitStep(model: model)
        case .review: SetupReviewStep(model: model)
        case .install:
            SetupInstallStep(
                model: model, runner: runner, undoRunner: undoRunner,
                retry: startInstall,
                undo: startUndo,
                openApp: openMainWindow
            )
        }
    }

    private var showsBottomBar: Bool {
        if model.step != .install { return true }
        return model.isFailure && !undoRunner.running
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if store.config.setupComplete && model.step != .install {
                Button("Close setup") { store.showOnboarding = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(p.textMuted)
            }
            Spacer()
            if model.canGoBack && !upgradeRunner.running {
                Button("Back") { model.back() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            if model.step != .install {
                Button(model.step == .review ? "Install" : "Next") { advance() }
                    .buttonStyle(PrimaryButtonStyle(warm: model.step == .review))
                    .disabled(!nextEnabled)
                    .opacity(nextEnabled ? 1 : 0.45)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(p.background)
    }

    private var nextEnabled: Bool {
        if upgradeRunner.running { return false }
        if model.step == .review { return model.installScript != nil && model.canAdvance }
        return model.canAdvance
    }

    private func advance() {
        guard model.step == .review else {
            model.next()
            return
        }
        guard !runner.running, let job = model.prepareInstall() else { return }
        model.next()
        runner.run(script: job.script, args: job.args, env: job.env)
    }

    private func startInstall() {
        guard !runner.running, !undoRunner.running else { return }
        guard let job = model.prepareInstall() else { return }
        runner.run(script: job.script, args: job.args, env: job.env)
    }

    private func startUpgrade() {
        guard !upgradeRunner.running, !runner.running, let job = model.upgradeJob() else { return }
        upgradeRunner.run(script: job.script, args: job.args, env: [:])
    }

    private func startUndo(_ script: URL) {
        guard !undoRunner.running, !runner.running else { return }
        undoRunner.run(script: script, args: ["-y"], env: [:])
    }

    private func openMainWindow() {
        store.config.setupComplete = true
        store.showOnboarding = false
        store.save()
    }
}

// MARK: - step rail

struct SetupStepRail: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel
    var locked: Bool

    var body: some View {
        let steps = model.steps
        let current = model.index(of: model.step)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Wolf Leader")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(p.text)
                    Text("Setup")
                        .font(.system(size: 12))
                        .foregroundStyle(p.textMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                    railRow(step: s, number: i + 1, index: i, current: current)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
            Text("Version \(BuildInfo.version)")
                .font(.system(size: 11))
                .foregroundStyle(p.textMuted)
                .padding(20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func railRow(step s: SetupStep, number: Int, index i: Int, current: Int) -> some View {
        let skipped = model.isSkipped(s)
        let isCurrent = i == current
        let done = i < current && !skipped
        let reachable = !locked && i <= model.furthest && !skipped && s != .install && !isCurrent
        return Button {
            if reachable { model.jump(to: s) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? p.accent : (done ? p.accent.opacity(0.18) : p.surfaceRaised))
                        .frame(width: 22, height: 22)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(p.accent)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isCurrent ? p.onAccent : p.textMuted)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent || done ? p.text : p.textMuted)
                    if skipped {
                        Text("Not needed")
                            .font(.system(size: 11))
                            .foregroundStyle(p.textMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? p.surfaceRaised : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(skipped ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .help(reachable ? "Go back to \(s.title)" : "")
    }
}
