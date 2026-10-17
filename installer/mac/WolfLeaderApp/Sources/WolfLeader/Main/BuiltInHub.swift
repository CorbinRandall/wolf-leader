import Foundation

/// "Just this Mac": the hub runs from a copy of the one inside this app. When the app is newer
/// than that copy (the person installed an update), refresh it, so the app and hub always match.
enum BuiltInHub {
    #if arch(arm64)
    static let target = "mac-arm64"
    #else
    static let target = "mac-x86_64"
    #endif

    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("hub/\(target)") }
    static var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WolfLeader/runtime")
    }

    static func version(_ dir: URL?) -> String? {
        guard let dir else { return nil }
        return (try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Refreshes the hub when it is out of date. Returns true when it ran the refresh.
    @discardableResult
    static func refreshIfNeeded(config: WolfConfig) async -> Bool {
        guard config.setupPath == .newOnThisMac,
              let have = version(bundled), have != version(installed),
              let script = Payload.root?.appendingPathComponent("installer/mac/install.sh") else { return false }
        let run = await MainProcess.run("/bin/bash", [script.path, "--ini", "auto", "--mode", "update", "--toggles", ""])
        return run.code == 0
    }
}
