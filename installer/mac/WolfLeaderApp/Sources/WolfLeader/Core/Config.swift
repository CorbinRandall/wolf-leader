import Foundation
import Security

/// How this Mac relates to Wolf Leader. Chosen on the first setup screen.
enum SetupPath: String, Codable, CaseIterable {
    /// Wolf Leader already runs on another computer; connect this Mac to it.
    case connectExisting
    /// Wolf Leader is already on this Mac; refresh its files.
    case updateThisMac
    /// New user; host the hub on an always-on computer (NAS, home server, LXC).
    case newOnServer
    /// New user; host the hub on this Mac with Docker (experimental).
    case newOnThisMac

    /// Mode string install.sh understands (see installer/CONFIG.md).
    var installMode: String {
        switch self {
        case .connectExisting, .newOnServer: return "connect"
        case .updateThisMac: return "update"
        case .newOnThisMac: return "new"
        }
    }
}

struct ShareConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    /// e.g. smb://wolf.local/wolf
    var url: String
    /// Username, or empty for guest. The password lives in the Keychain, never here.
    var user: String
    /// "wolf" for the drive holding projects, vault and git remotes; otherwise "extra".
    var role: String = "extra"

    var host: String { URL(string: url)?.host ?? "" }
    var shareName: String { URL(string: url)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "" }
    /// Where macOS mounts it, e.g. /Volumes/wolf
    var mountPoint: String { "/Volumes/" + (shareName.split(separator: "/").first.map(String.init) ?? shareName) }
}

/// An original (SQLite) Wolf Leader hub the setup prompt found, from the `[original]` section.
/// Kept after an upgrade so Settings can downgrade back to it.
struct OriginalHub: Codable, Equatable {
    /// this | ssh | manual
    var location: String
    /// The original Wolf Leader folder on the hub computer.
    var folder: String
    /// user@host, empty unless location == "ssh".
    var sshTarget: String
    var sshPort: String
    /// Path of the private key file on this Mac; empty means ssh's defaults.
    var sshKey: String
    var upgraded = false

    var canRun: Bool { (location == "this" || location == "ssh") && !folder.isEmpty }
    var runsWhere: String { location == "ssh" ? "\(sshTarget) (over SSH)" : "this Mac" }

    /// Arguments for scripts/wolf-og-migrate.sh; action is "upgrade" or "revert".
    func args(_ action: String, hubURL: String) -> [String] {
        var a = ["--\(action)", "--yes", "--old", folder]
        a += action == "upgrade" ? ["--url", hubURL] : ["--bring", "yes"]
        if location == "ssh" {
            a += ["--ssh", sshTarget, "--ssh-port", sshPort.isEmpty ? "22" : sshPort]
            if !sshKey.isEmpty { a += ["--ssh-key", sshKey] }
        }
        return a
    }

    static var script: URL? {
        guard let url = Payload.root?.appendingPathComponent("scripts/wolf-og-migrate.sh"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// What to paste on the hub computer when the app can't log in to it.
    static func manualCommand(repoURL: String, branch: String, action: String) -> String {
        let repo = repoURL.replacingOccurrences(of: "https://github.com/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let raw = "https://raw.githubusercontent.com/\(repo)/\(branch)/scripts/wolf-og-migrate.sh"
        return "curl -fsSL \(raw) -o wolf-og-migrate.sh && bash wolf-og-migrate.sh --\(action)"
    }
}

struct WolfConfig: Codable {
    var setupComplete = false
    var setupPath: SetupPath?
    var hubURL = "http://wolf.local:6971"
    var mcpURL = "http://wolf.local:6972/mcp"
    var deviceName = Host.current().localizedName ?? "Mac"
    var shares: [ShareConfig] = []
    /// Folder of the backup made by the last install (contains restore.sh).
    var lastBackupPath: String?
    /// Where update checks look. Defaults come from the build (Info.plist).
    var repoURL: String = BuildInfo.repoURL
    var branch: String = BuildInfo.branch
    /// Set when setup found an original hub; `upgraded` once the upgrade ran.
    var original: OriginalHub?

    var wolfShare: ShareConfig? { shares.first { $0.role == "wolf" } ?? shares.first }
    /// Obsidian vault on the wolf share, if that share is mounted.
    var vaultPath: String? {
        guard let s = wolfShare else { return nil }
        let p = s.mountPoint + "/wolf-leader/vault"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
    var wikiURL: URL? { URL(string: hubURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/wiki/") }
}

final class ConfigStore: ObservableObject {
    @Published var config: WolfConfig
    /// Settings > "Run setup again" sets this to show onboarding without losing the config.
    @Published var showOnboarding = false

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WolfLeader", isDirectory: true)
    }
    private static var file: URL { supportDir.appendingPathComponent("config.json") }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode(WolfConfig.self, from: data) {
            config = saved
        } else {
            config = WolfConfig()
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) { try? data.write(to: Self.file, options: .atomic) }
    }

    var hub: HubClient { HubClient(baseURL: config.hubURL) }
}

enum BuildInfo {
    private static func plist(_ key: String) -> String? {
        let v = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return (v?.isEmpty == false) ? v : nil
    }
    /// Where update checks look when the build carries no git info (zip or Xcode builds).
    static let defaultRepoURL = "https://github.com/Vapor-Nexus/wolf-leader"
    static let defaultBranch = "feat/background-memory-installer"

    static var version: String { plist("CFBundleShortVersionString") ?? "dev" }
    /// Commit the app was built from (set by build-app.sh from a git checkout).
    static var gitSHA: String? { plist("WLGitSHA") }
    static var branch: String { plist("WLGitBranch") ?? defaultBranch }
    static var repoURL: String { plist("WLRepoURL") ?? defaultRepoURL }
}

/// Files bundled with the app: installer/mac/install.sh, ini.sh, examples/, hub sources.
enum Payload {
    static var root: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("payload"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("installer/mac/install.sh").path) {
            return res
        }
        // Running from Xcode / `swift run`: use the repo this package lives in.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("installer/mac/install.sh").path) ? url : nil
    }
}

/// SMB passwords in the login Keychain (same entry Finder uses, so mounting works without prompts).
enum SMBKeychain {
    static func save(host: String, user: String, password: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = host
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func has(host: String, user: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(host: String, user: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
