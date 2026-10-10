import AppKit
import SwiftUI

struct SharesView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p

    @State private var mounted: Set<UUID> = []
    @State private var passwords: [UUID: String] = [:]
    @State private var messages: [UUID: String] = [:]
    @State private var editor: ShareDraft? = nil
    @State private var removing: ShareConfig? = nil

    var body: some View {
        MainPage {
            WLPageHeader(title: "Shares", subtitle: "Network drives this Mac connects to. Passwords stay in your login Keychain.") {
                Button {
                    editor = ShareDraft(original: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Add share")
                    }
                }
                .buttonStyle(OutlineButtonStyle())
            }
            if store.config.shares.isEmpty {
                MainNotice(
                    symbol: "externaldrive.badge.plus",
                    title: "No shares yet",
                    message: "Add the drive that holds your Wolf Leader projects, vault and git history, for example smb://wolf.local/wolf."
                ) {
                    Button("Add share") { editor = ShareDraft(original: nil) }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ForEach(store.config.shares) { share in
                    shareCard(share)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                refreshMounted()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(item: $editor) { draft in
            ShareEditorSheet(draft: draft) { saved, password in
                save(saved, replacing: draft.original, password: password)
            }
            .environment(\.palette, p)
            .environmentObject(store)
        }
        .confirmationDialog(
            "Remove this share?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { share in
            Button("Remove", role: .destructive) { remove(share) }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { share in
            Text("Wolf Leader forgets \(share.url) and deletes its saved password from your Keychain. Files on the share are not touched.")
        }
    }

    // MARK: Card

    private func shareCard(_ share: ShareConfig) -> some View {
        let isMounted = mounted.contains(share.id)
        let hasUser = !share.user.trimmingCharacters(in: .whitespaces).isEmpty
        let hasPassword = hasUser && SMBKeychain.has(host: share.host, user: share.user)
        return WLGroup(
            title: share.shareName.isEmpty ? share.url : share.shareName,
            subtitle: share.url,
            icon: share.role == "wolf" ? "externaldrive.fill.badge.person.crop" : "externaldrive"
        ) {
            WLRow(title: "Status", detail: isMounted ? "Mounted at \(share.mountPoint)" : "Not mounted on this Mac") {
                HStack(spacing: 8) {
                    MainTag(text: share.role == "wolf" ? "Wolf Leader drive" : "Other share",
                            color: share.role == "wolf" ? p.accent2 : p.textMuted)
                    WLStatusPill(text: isMounted ? "Connected" : "Not connected", kind: isMounted ? .good : .neutral)
                }
            }
            WLDivider()
            WLRow(
                title: "Sign-in",
                detail: hasUser ? "Signs in as \(share.user)\(hasPassword ? " · password saved in Keychain" : "")" : "Guest access"
            ) {
                HStack(spacing: 8) {
                    if isMounted {
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: share.mountPoint))
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else {
                        if hasUser {
                            SecureField(hasPassword ? "Password (saved)" : "Password", text: passwordBinding(share.id))
                                .mainField()
                                .frame(width: 180)
                                .onSubmit { connect(share) }
                        }
                        Button("Connect") { connect(share) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
            WLDivider()
            WLRow(title: "Manage", detail: "Change the address, user or role, or forget this share.") {
                HStack(spacing: 8) {
                    Button("Edit") { editor = ShareDraft(original: share) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Remove") { removing = share }
                        .buttonStyle(OutlineButtonStyle(tint: p.bad))
                }
            }
            if let message = messages[share.id] {
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundStyle(p.textMuted)
            }
        }
    }

    private func passwordBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { passwords[id] ?? "" }, set: { passwords[id] = $0 })
    }

    // MARK: Actions

    private func refreshMounted() {
        var now: Set<UUID> = []
        for share in store.config.shares where Self.isMounted(share) {
            now.insert(share.id)
        }
        if now != mounted { mounted = now }
    }

    static func isMounted(_ share: ShareConfig) -> Bool {
        let url = URL(fileURLWithPath: share.mountPoint)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isVolumeKey])
        return values?.isVolume ?? false
    }

    static func connectURL(_ share: ShareConfig) -> URL? {
        let host = share.host
        guard !host.isEmpty else { return nil }
        let user = share.user.trimmingCharacters(in: .whitespaces)
        let userPart = user.isEmpty ? "" : (user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user) + "@"
        let name = share.shareName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share.shareName
        return URL(string: "smb://\(userPart)\(host)/\(name)")
    }

    private func connect(_ share: ShareConfig) {
        let user = share.user.trimmingCharacters(in: .whitespaces)
        if let pw = passwords[share.id], !pw.isEmpty, !user.isEmpty {
            if SMBKeychain.save(host: share.host, user: user, password: pw) {
                passwords[share.id] = nil
            } else {
                messages[share.id] = "Couldn't save the password in your Keychain. Finder will ask for it."
            }
        }
        guard let url = Self.connectURL(share) else {
            messages[share.id] = "This share address doesn't look right. Edit it to fix."
            return
        }
        if NSWorkspace.shared.open(url) {
            messages[share.id] = "Asked Finder to connect. If it asks for a password, tick \u{201C}Remember this password\u{201D}."
        } else {
            messages[share.id] = "Finder couldn't open \(url.absoluteString)."
        }
        Task {
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(2))
                refreshMounted()
                if mounted.contains(share.id) {
                    messages[share.id] = nil
                    return
                }
            }
        }
    }

    private func save(_ share: ShareConfig, replacing original: ShareConfig?, password: String) {
        var shares = store.config.shares
        if share.role == "wolf" {
            for i in shares.indices where shares[i].id != share.id { shares[i].role = "extra" }
        }
        if let original, let i = shares.firstIndex(where: { $0.id == original.id }) {
            shares[i] = share
        } else {
            shares.append(share)
        }
        store.config.shares = shares
        store.save()
        let user = share.user.trimmingCharacters(in: .whitespaces)
        if !password.isEmpty, !user.isEmpty, !SMBKeychain.save(host: share.host, user: user, password: password) {
            messages[share.id] = "Saved the share, but couldn't save its password in your Keychain."
        }
        refreshMounted()
    }

    private func remove(_ share: ShareConfig) {
        let user = share.user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty, !share.host.isEmpty {
            SMBKeychain.delete(host: share.host, user: user)
        }
        store.config.shares.removeAll { $0.id == share.id }
        store.save()
        removing = nil
        mounted.remove(share.id)
        messages[share.id] = nil
        passwords[share.id] = nil
    }
}

struct ShareDraft: Identifiable {
    let id = UUID()
    /// nil when adding a new share.
    let original: ShareConfig?
}

private struct ShareEditorSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let draft: ShareDraft
    let onSave: (ShareConfig, String) -> Void

    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var role = "wolf"
    @State private var problem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.original == nil ? "Add share" : "Edit share")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(p.text)

            field("Share address") {
                TextField("smb://wolf.local/wolf", text: $url)
                    .mainField()
            }
            field("Username", hint: "Leave empty for guest access.") {
                TextField("wolf", text: $user)
                    .mainField()
            }
            field("Password", hint: draft.original == nil
                  ? "Saved in your login Keychain, never in a file."
                  : "Leave empty to keep the saved password.") {
                SecureField("Password", text: $password)
                    .mainField()
            }
            field("What's on it") {
                Picker("", selection: $role) {
                    Text("Wolf Leader drive (projects, vault, git)").tag("wolf")
                    Text("Other share").tag("extra")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .foregroundStyle(p.text)
            }

            if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(p.bad)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? "Add share" : "Save") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 460)
        .background(p.background)
        .onAppear {
            if let s = draft.original {
                url = s.url
                user = s.user
                role = s.role == "wolf" ? "wolf" : "extra"
            }
        }
    }

    private func field<Content: View>(_ title: String, hint: String? = nil,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.textMuted)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(p.textMuted)
            }
        }
    }

    private func submit() {
        guard let parsed = Self.normalize(url) else {
            problem = "Use an address like smb://wolf.local/wolf (server, then share name)."
            return
        }
        var name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty, let fromURL = parsed.user { name = fromURL }
        var share = draft.original ?? ShareConfig(url: parsed.url, user: name)
        share.url = parsed.url
        share.user = name
        share.role = role
        onSave(share, password)
        dismiss()
    }

    /// Accepts smb://host/share, host/share or \\host\share; returns a clean smb:// URL (no user or
    /// password in it) plus any user that was typed into the address.
    static func normalize(_ raw: String) -> (url: String, user: String?)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\\\\") {
            s = "smb://" + s.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        if !s.lowercased().hasPrefix("smb://") {
            if s.contains("://") { return nil }
            s = "smb://" + s
        }
        s = s.replacingOccurrences(of: " ", with: "%20")
        guard let comps = URLComponents(string: s),
              let host = comps.host, !host.isEmpty,
              comps.password == nil else { return nil }
        let path = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        return ("smb://\(host)/\(path)", comps.user)
    }
}
