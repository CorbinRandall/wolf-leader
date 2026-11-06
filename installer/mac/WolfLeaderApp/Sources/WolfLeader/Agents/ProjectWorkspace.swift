import Foundation

/// Every project's files live on the server, in the git store the hub keeps for it
/// (`wolf-leader/git/<slug>.git`). Wolf Leader keeps its own working copy of each project for the
/// agents, pulls from the server before a chat starts, and pushes their changes back after each
/// reply. You never choose a folder: the server is the project's permanent home.
enum ProjectWorkspace {
    /// The SSH host for the server; `wolf` is the alias Wolf Leader's setup adds to ~/.ssh/config.
    static var sshHost: String { UserDefaults.standard.string(forKey: "wl.serverSSHHost") ?? "wolf" }

    static var root: URL { ConfigStore.supportDir.appendingPathComponent("projects", isDirectory: true) }
    static var looseRoot: URL { ConfigStore.supportDir.appendingPathComponent("loose-chats", isDirectory: true) }

    static func folder(slug: String) -> URL { root.appendingPathComponent(safe(slug), isDirectory: true) }

    /// A scratch folder for a chat that isn't part of a project yet.
    static func looseFolder(chatID: String) -> URL {
        let url = looseRoot.appendingPathComponent(chatID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isWorkspace(_ path: String) -> Bool { path.hasPrefix(root.path + "/") }

    private static func safe(_ slug: String) -> String {
        let cleaned = slug.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-")).nilIfEmpty ?? "project"
    }

    /// Get the project's copy up to date with the server. Returns a short note when something
    /// didn't work; the chat still runs, on the copy this Mac has.
    static func prepare(hub: HubClient, slug: String, path: String) async -> String? {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hasRepo = FileManager.default.fileExists(atPath: path + "/.git")
        guard let remote = await serverRemote(hub: hub, slug: slug) else {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return "Couldn't reach the project's folder on the server, so this chat works on this Mac's copy for now."
        }
        if hasRepo {
            _ = await git(["remote", "set-url", "origin", remote], in: path)
            let pull = await git(["pull", "--ff-only", "--quiet"], in: path)
            // An empty server repo has nothing to pull; that's fine.
            if pull.code != 0, !pull.output.contains("no such ref"), !pull.output.contains("couldn't find remote ref") {
                return "Couldn't bring in the server's latest changes: \(AgentText.oneLine(pull.output, limit: 200))"
            }
            return nil
        }
        if FileManager.default.fileExists(atPath: path) {
            // A folder without git (made while offline): connect it to the server instead of cloning over it.
            _ = await git(["init", "--quiet", "--initial-branch=main"], in: path)
            _ = await git(["remote", "add", "origin", remote], in: path)
            _ = await git(["pull", "--ff-only", "--quiet", "origin", "main"], in: path)
            return nil
        }
        let clone = await git(["clone", "--quiet", remote, path], in: root.path)
        if clone.code != 0 {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return "Couldn't copy the project from the server: \(AgentText.oneLine(clone.output, limit: 200))"
        }
        return nil
    }

    /// Save what the agent changed and send it to the server. Returns a note when it couldn't.
    static func sync(path: String, message: String) async -> String? {
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return nil }
        let hadCommits = await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: path).code == 0
        let status = await git(["status", "--porcelain"], in: path)
        if !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = await git(["add", "-A"], in: path)
            let commit = await git(["commit", "--quiet", "-m", message], in: path)
            if commit.code != 0 { return "Couldn't save the agent's changes: \(AgentText.oneLine(commit.output, limit: 200))" }
        }
        if !hadCommits, await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: path).code != 0 { return nil }
        // Nothing to send if this copy isn't ahead of the server.
        let ahead = await git(["rev-list", "--count", "@{u}..HEAD"], in: path)
        if ahead.code == 0, ahead.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0" { return nil }
        var push = await git(["push", "--quiet", "-u", "origin", "HEAD"], in: path)
        if push.code != 0 {
            // Someone saved to the server meanwhile: put these changes on top of theirs, then try once more.
            let rebase = await git(["pull", "--rebase", "--quiet"], in: path)
            if rebase.code != 0 {
                _ = await git(["rebase", "--abort"], in: path)
                return "The server has newer changes that clash with this chat's. They're kept here; nothing was overwritten."
            }
            push = await git(["push", "--quiet", "-u", "origin", "HEAD"], in: path)
        }
        return push.code == 0 ? nil : "Couldn't send the changes to the server: \(AgentText.oneLine(push.output, limit: 200))"
    }

    /// The project's git store on the server, as an SSH address. The hub makes it if it's missing.
    private static func serverRemote(hub: HubClient, slug: String) async -> String? {
        guard let raw = try? await hub.data("/api/projects/by-slug/\(slug)/repo", method: "POST",
                                             body: Data(#"{"client_os":"mac"}"#.utf8), timeout: 30),
              let reply = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let hubPath = reply["hub"] as? String else { return nil }
        // The hub sees the share as /srv/wolf inside its container; on the server it may be /srv/content.
        var candidates = [hubPath]
        if hubPath.hasPrefix("/srv/wolf/") { candidates.append("/srv/content/" + hubPath.dropFirst("/srv/wolf/".count)) }
        // The server's SSH name: the one that worked last time, then `wolf`, then every host in
        // ~/.ssh/config (e.g. `bbq`). Probes fail fast instead of waiting on a password prompt.
        var hosts: [String] = []
        for host in [UserDefaults.standard.string(forKey: "wl.serverSSHHost"), "wolf"].compactMap({ $0 }) + sshConfigHosts()
        where !hosts.contains(host) { hosts.append(host) }
        for host in hosts {
            for path in candidates {
                let remote = "\(host):\(path)"
                if await git(["ls-remote", "--quiet", remote], in: root.path).code == 0 {
                    UserDefaults.standard.set(host, forKey: "wl.serverSSHHost")
                    return remote
                }
            }
        }
        return nil
    }

    /// Named hosts in ~/.ssh/config (no wildcards).
    static func sshConfigHosts() -> [String] {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count > 1, parts[0].lowercased() == "host" else { continue }
            for name in parts.dropFirst().map(String.init) where !name.contains("*") && !name.contains("?") && !out.contains(name) {
                out.append(name)
            }
        }
        return out
    }

    @discardableResult
    static func git(_ args: [String], in directory: String) async -> (code: Int32, output: String) {
        await Task.detached { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var env = AgentLocator.environment
            // No port forwards (the `wolf` alias forwards the hub), no password prompts, fail fast.
            env["GIT_SSH_COMMAND"] = "ssh -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10"
            env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
