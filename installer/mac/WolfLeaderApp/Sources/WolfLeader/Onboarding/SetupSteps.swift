import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Welcome

struct SetupWelcomeStep: View {
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 10) {
                Text("Wolf Leader, now on autopilot")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(p.text)
                Text("v1 gave every agent you use one shared memory. This update makes the remembering happen on its own.")
                    .font(.system(size: 15))
                    .foregroundStyle(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("magnifyingglass", "Find any old chat", "Ask what you worked on, in any project, on any day.")
                feature("sparkles", "Remembers while you work", "Decisions and fixes save themselves. No commands to type.")
                feature("laptopcomputer", "Pick up on any machine", "Same project and context on every computer you use.")
            }
            Text("Setup takes a few minutes and backs up everything it changes first.")
                .font(.system(size: 12))
                .foregroundStyle(p.textMuted)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ line: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(p.accent)
                .frame(width: 30, height: 30)
                .background(p.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.text)
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(p.textMuted)
            }
        }
    }
}

// MARK: - Your setup

struct SetupPathStep: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel
    @State private var dockerFound = SetupSystem.dockerFound

    init(model: OnboardingModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupHeader(title: "Your setup", subtitle: "Where does your Wolf Leader memory live?")
            SetupChoiceCard(
                title: SetupPath.connectExisting.setupTitle,
                detail: "Connect this Mac to it. Most people pick this.",
                example: "Your NAS or home server at http://wolf.local:6971",
                selected: model.path == .connectExisting
            ) { model.path = .connectExisting }
            SetupChoiceCard(
                title: SetupPath.updateThisMac.setupTitle,
                detail: "Refresh the skills, rule and settings to the latest version.",
                example: "You set this Mac up before and want the new version",
                selected: model.path == .updateThisMac
            ) { model.path = .updateThisMac }
            SetupChoiceCard(
                title: SetupPath.newOnServer.setupTitle,
                detail: "Your memory lives on a computer that's always on, so every machine can reach it.",
                example: "A NAS, Proxmox container or Linux box",
                selected: model.path == .newOnServer
            ) { model.path = .newOnServer }
            SetupChoiceCard(
                title: SetupPath.newOnThisMac.setupTitle,
                detail: "Runs in Docker and only works while this Mac is on.",
                example: "Good for trying it out",
                selected: model.path == .newOnThisMac
            ) {
                model.path = .newOnThisMac
                dockerFound = SetupSystem.dockerFound
            }
            if model.path == .newOnThisMac && !dockerFound {
                VStack(alignment: .leading, spacing: 8) {
                    SetupNotice(
                        kind: .warn,
                        text: "Docker isn't installed on this Mac. Install Docker Desktop and open it once before you press Install, or pick another option."
                    )
                    HStack(spacing: 14) {
                        if let url = URL(string: "https://www.docker.com/products/docker-desktop/") {
                            Link("Get Docker Desktop", destination: url)
                                .font(.system(size: 13))
                        }
                        Button("Check again") { dockerFound = SetupSystem.dockerFound }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(p.accent)
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }
}

// MARK: - Set up your server (path c)

struct SetupServerStep: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel

    private var repo: String {
        let r = BuildInfo.repoURL
        return r.isEmpty ? "https://github.com/CorbinRandall/wolf-leader" : r
    }

    private var commands: [String] {
        [
            "git clone --branch \(BuildInfo.branch) \(repo) wolf-leader",
            "cd wolf-leader",
            "cp .env.example .env",
            "docker compose -f docker-compose.postgres.yml up -d --build",
        ]
    }

    private var guideURL: URL? {
        URL(string: "\(repo)/blob/\(BuildInfo.branch)/docs/lxc-hub.md")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupHeader(
                title: "Set up your server",
                subtitle: "Run these on the always-on computer, in a terminal or over SSH. It needs git and Docker."
            )
            VStack(alignment: .leading, spacing: 8) {
                ForEach(commands, id: \.self) { SetupCommandRow(command: $0) }
            }
            Text(verbatim: "Before the last command you can open .env and change POSTGRES_PASSWORD from change-me, and set IDE_STORAGE_PUBLIC_URL to this server's address. The first build takes about 10 minutes.")
                .font(.system(size: 12))
                .foregroundStyle(p.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                SetupCopyButton(text: commands.joined(separator: "\n"), label: "Copy all")
                if let guideURL {
                    Link("Full guide: docs/lxc-hub.md", destination: guideURL)
                        .font(.system(size: 13))
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check my hub")
                        .font(.system(size: 14, weight: .bold))
                    Text("Type the server's address once it's running. You can also skip this and check later.")
                        .font(.system(size: 13))
                        .foregroundStyle(p.textMuted)
                    HStack(spacing: 10) {
                        TextField("http://wolf.local:6971", text: $model.serverURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .onSubmit { model.checkServer() }
                            .onChange(of: model.serverURL) { _, _ in
                                if model.serverCheck != .checking { model.serverCheck = .idle }
                            }
                        Button("Check") { model.checkServer() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.serverCheck == .checking)
                    }
                    switch model.serverCheck {
                    case .idle:
                        EmptyView()
                    case .checking:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking \(model.serverURL)/health …")
                                .font(.system(size: 12))
                                .foregroundStyle(p.textMuted)
                        }
                    case .ok:
                        SetupNotice(kind: .good, text: "Your hub answered. This Mac will connect to it.")
                    case .failed(let why):
                        SetupNotice(kind: .bad, text: "No answer yet. Is the container running, and is this Mac on the same network? (\(why))")
                    }
                }
            }
        }
    }
}

// MARK: - What to install

struct SetupTogglesStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupHeader(title: "What to install", subtitle: "Everything is on by default. Turn off anything you don't want.")
            SetupToggleCard(
                title: "Agent skills and rule",
                detail: "Teaches your AI tools to use Wolf Leader without being asked.",
                example: "Cursor and Claude Code start saving memories on their own",
                isOn: $model.toggles.client
            )
            SetupToggleCard(
                title: "Network shares",
                detail: "Connects the shared drives your AI lists, and reconnects them when you log in.",
                example: "Connect W: style drives like smb://wolf.local/wolf at login",
                isOn: $model.toggles.shares
            )
            SetupToggleCard(
                title: "Git and Python",
                detail: "Installs the tools the skills use, if this Mac doesn't have them.",
                example: "Only if missing",
                isOn: $model.toggles.prereqs
            )
            SetupToggleCard(
                title: "Obsidian — recommended",
                detail: "A free notes app that opens your Wolf Leader vault.",
                example: "Browse your project notes like a wiki",
                isOn: $model.toggles.obsidian
            )
            if model.path == .newOnThisMac {
                SetupToggleCard(
                    title: "Wiki — highly recommended",
                    detail: "Builds a website from your projects inside the hub.",
                    example: "A searchable site of every project at /wiki",
                    isOn: $model.toggles.wiki
                )
            }
        }
    }
}

// MARK: - Ask your AI

struct SetupAskAIStep: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel
    @State private var importing = false
    @State private var importError: String?

    init(model: OnboardingModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupHeader(title: "Ask your AI", subtitle: "Your AI looks at this Mac and fills in the details, so you don't have to.")

            Text(verbatim: "1. Copy this prompt into Cursor, Claude Code or any AI chat on this Mac.")
                .font(.system(size: 13, weight: .semibold))
            if let prompt = model.promptText {
                ScrollView {
                    Text(prompt)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(p.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 190)
                .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.border))
                SetupCopyButton(text: prompt, label: "Copy prompt", prominent: true)
                    .scaleEffect(1.08, anchor: .leading)
            } else {
                SetupNotice(kind: .bad, text: "This copy of Wolf Leader is missing its setup files (installer/PROMPT.md). Rebuild it with installer/mac/build-app.sh.")
            }

            Text(verbatim: "2. Paste your AI's reply here")
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 6)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.iniText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if model.iniText.isEmpty {
                    Text(verbatim: "Paste your AI's reply here. It starts with ```ini")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(p.textMuted)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 180)
            .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.border))
            HStack(spacing: 10) {
                Button {
                    if let text = SetupClipboard.text { model.iniText = text }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    importing = true
                } label: {
                    Label("Choose file…", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())
                if !model.iniText.isEmpty {
                    Button("Clear") { model.iniText = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(p.textMuted)
                }
            }
            if let importError {
                SetupNotice(kind: .bad, text: importError)
            }
            status
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
            importError = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    model.iniText = String(decoding: data, as: UTF8.self)
                } else {
                    importError = "Couldn't read \(url.lastPathComponent)."
                }
            case .failure(let error):
                importError = "Couldn't open that file: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.iniState {
        case .empty:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: 12))
                    .foregroundStyle(p.textMuted)
            }
        case .valid:
            SetupNotice(kind: .good, text: validSummary)
        case .invalid(let problems):
            VStack(alignment: .leading, spacing: 8) {
                Text(problems.count == 1 ? "One thing to fix. Ask your AI to correct it, or edit it above:" : "\(problems.count) things to fix. Ask your AI to correct them, or edit them above:")
                    .font(.system(size: 13))
                    .foregroundStyle(p.textMuted)
                ForEach(problems.prefix(6)) { problem in
                    VStack(alignment: .leading, spacing: 4) {
                        SetupNotice(kind: .bad, text: problem.line.map { "Line \($0): \(problem.message)" } ?? problem.message)
                        if let text = problem.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(p.textMuted)
                                .textSelection(.enabled)
                                .padding(.leading, 36)
                        }
                    }
                }
            }
        case .unavailable(let why):
            SetupNotice(kind: .warn, text: why)
        }
    }

    private var validSummary: String {
        let hub = model.value("wolf", "hub_url")
        let device = model.value("wolf", "device_name")
        let n = model.shares.count
        let shares = n == 0 ? "no network shares" : (n == 1 ? "1 network share" : "\(n) network shares")
        return "Looks good. \(device) will use the hub at \(hub), with \(shares)."
    }
}

// MARK: - Passwords

struct SetupPasswordsStep: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupHeader(
                title: "Passwords",
                subtitle: "Typed here, saved in your login Keychain, and never written to a file or shown to your AI."
            )
            if model.askShares.isEmpty {
                SetupNotice(kind: .info, text: "None of your shares need a password. Press Next.")
            }
            ForEach(model.askShares) { share in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password for \(share.user) on \(share.url)")
                            .font(.system(size: 13, weight: .semibold))
                        SecureField("Password", text: binding(for: share.section))
                            .textFieldStyle(.roundedBorder)
                        Text(SMBKeychain.has(host: share.host, user: share.user)
                             ? "Already in your Keychain. Leave it empty to keep the saved one."
                             : "Leave it empty and Finder will ask the first time it connects.")
                            .font(.system(size: 12))
                            .foregroundStyle(p.textMuted)
                    }
                }
            }
        }
    }

    private func binding(for section: String) -> Binding<String> {
        Binding(
            get: { model.passwords[section] ?? "" },
            set: { model.passwords[section] = $0 }
        )
    }
}

// MARK: - Git name

struct SetupGitStep: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "Git name", subtitle: "The name and email on commits Wolf Leader makes for you.")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    labeled("Name") {
                        TextField("Your Name", text: $model.gitName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled("Email") {
                        TextField("you@example.com", text: $model.gitEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Text(verbatim: "Only used for commits on this Mac. Made-up is fine, like you@example.com — it stops git from stopping to ask for a GitHub login.")
                .font(.system(size: 12))
                .foregroundStyle(p.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !model.gitEmail.isEmpty && !model.gitValid {
                Text(verbatim: "The email needs an @ and a dot, like you@example.com.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.warn)
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ field: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(p.textMuted)
                .frame(width: 60, alignment: .leading)
            field()
        }
    }
}

// MARK: - Review

struct SetupReviewStep: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeader(title: "Review", subtitle: "Here's what Setup will do. Press Install when it looks right.")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SetupSummaryRow(label: "Setup", value: model.path?.setupShortLabel ?? "Not chosen")
                    SetupSummaryRow(label: "Hub", value: model.value("wolf", "hub_url"))
                    SetupSummaryRow(label: "Agent connection", value: model.value("wolf", "mcp_url"))
                    SetupSummaryRow(label: "This Mac", value: "\(model.value("wolf", "device_name")), \(model.value("wolf", "timezone"))")
                    SetupSummaryRow(label: "Installs", value: installsText)
                    SetupSummaryRow(label: "Shares", value: sharesText)
                    SetupSummaryRow(label: "Git name", value: "\(model.gitName) <\(model.gitEmail)>")
                }
            }

            Text("Backups")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 4)
            if let backup = model.agentBackup {
                SetupNotice(kind: .good, text: "Your AI saved a backup to \(backup.path)\(backup.files.isEmpty ? "" : " (\(backup.files) files)").")
            } else if let reported = model.agentBackupReported {
                SetupNotice(kind: .warn, text: "Your AI said it saved a backup to \(reported), but that folder isn't on this Mac. That's okay, see below.")
            } else {
                SetupNotice(kind: .warn, text: "Your AI didn't make its own backup. That's okay, see below.")
            }
            SetupNotice(
                kind: .info,
                text: "Setup backs up everything it changes first, to ~/Library/Application Support/WolfLeader. If something goes wrong you can undo it from the last screen."
            )
            if model.path == .newOnThisMac {
                SetupNotice(kind: .info, text: "Building the hub in Docker downloads a lot. The first install can take 10–15 minutes.")
            }
            if model.installScript == nil {
                SetupNotice(kind: .bad, text: "This copy of Wolf Leader is missing its setup files. Rebuild it with installer/mac/build-app.sh.")
            }
            if let error = model.installError {
                SetupNotice(kind: .bad, text: error)
            }
            Text("macOS may ask to let Wolf Leader control System Events (to reconnect shares at login). Click OK.")
                .font(.system(size: 12))
                .foregroundStyle(p.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installsText: String {
        var items: [String] = []
        let t = model.toggles
        if t.client { items.append("Agent skills and rule") }
        if t.shares { items.append("Network shares") }
        if t.prereqs { items.append("Git and Python (if missing)") }
        if t.obsidian { items.append("Obsidian") }
        if model.path == .newOnThisMac {
            items.append(t.wiki ? "Hub in Docker, with the wiki" : "Hub in Docker")
        }
        return items.isEmpty ? "Only the git name and a hub check" : items.joined(separator: ", ")
    }

    private var sharesText: String {
        guard !model.shares.isEmpty else { return "None" }
        if !model.toggles.shares { return "Skipped (Network shares is off)" }
        return model.shares.map { share in
            share.isGuest ? "\(share.url) (guest)" : "\(share.url) as \(share.user)"
        }.joined(separator: "\n")
    }
}
