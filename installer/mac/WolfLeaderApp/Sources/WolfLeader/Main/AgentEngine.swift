import AppKit
import Foundation
import WebKit

/// The agent engine behind Chats: Wolf Code (a t3code fork) running headless on this Mac.
/// It drives Claude Code, Codex and the other agent CLIs, and saves every chat to the hub.
/// The app starts it on first use, signs the Chats page in, and stops it on quit.
@MainActor
final class AgentEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case starting(String)
        case ready
        case failed(String)
    }

    static let shared = AgentEngine()
    static let port = BuildInfo.isDev ? 13790 : 13780

    @Published private(set) var state: State = .idle
    /// One web view for the whole app, so a chat keeps running while you visit other pages.
    let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }()

    private var process: Process?
    private var hubURL = ""
    private var baseURL: URL { URL(string: "http://127.0.0.1:\(Self.port)")! }

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AgentEngine.shared.stop() }
        }
    }

    // MARK: Where things are

    static var dataDir: URL { ConfigStore.supportDir.appendingPathComponent("agents", isDirectory: true) }

    /// The Wolf Code checkout. Dev builds point at a clone; WL_AGENTS_ENGINE overrides it.
    static var engineDir: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["WL_AGENTS_ENGINE"],
            Bundle.main.object(forInfoDictionaryKey: "WLAgentsEngineDir") as? String,
            Bundle.main.resourceURL?.appendingPathComponent("agents").path,
            home.appendingPathComponent("Projects/wolf-code").path,
        ]
        for case let path? in candidates where !path.isEmpty {
            let entry = URL(fileURLWithPath: path).appendingPathComponent("apps/server/src/bin.ts")
            if FileManager.default.fileExists(atPath: entry.path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Wolf Code needs Node 26. Apps opened from Finder get a bare PATH, so look in the usual places.
    static var nodePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [ProcessInfo.processInfo.environment["WL_NODE"]]
        let local = "\(home)/.local"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: local) {
            candidates += entries.filter { $0.hasPrefix("node-v26") }.sorted().reversed()
                .map { "\(local)/\($0)/bin/node" }
        }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The agent CLIs (claude, codex, cursor-agent, ...) live in these folders; the engine needs them on PATH.
    static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.cursor/bin", "\(home)/.bun/bin",
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let node = nodePath { dirs.insert((node as NSString).deletingLastPathComponent, at: 0) }
        return dirs.joined(separator: ":")
    }

    // MARK: Lifecycle

    /// Starts the engine if needed and signs the Chats page in. Safe to call repeatedly.
    func open(hubURL: String) async {
        if case .ready = state, hubURL == self.hubURL { return }
        if case .starting = state { return }
        self.hubURL = hubURL
        guard let engine = Self.engineDir else {
            state = .failed("Wolf Code isn't on this Mac. Clone it to ~/Projects/wolf-code, or set WL_AGENTS_ENGINE.")
            return
        }
        guard let node = Self.nodePath else {
            state = .failed("Node 26 isn't installed. Wolf Code needs it to run the agents.")
            return
        }
        state = .starting("Starting the agents…")
        if await !isUp() {
            do {
                try launch(node: node, engine: engine)
            } catch {
                state = .failed("Couldn't start the agents: \(error.localizedDescription)")
                return
            }
            for _ in 0..<120 where await !isUp() {
                if process?.isRunning == false {
                    state = .failed("The agent engine stopped while starting. See \(Self.logFile.path).")
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard await isUp() else {
                state = .failed("The agents didn't start in time. See \(Self.logFile.path).")
                return
            }
        }
        state = .starting("Signing in…")
        guard let pairing = await mintPairingURL(node: node, engine: engine) else {
            state = .failed("Couldn't sign in to the agents. See \(Self.logFile.path).")
            return
        }
        webView.load(URLRequest(url: pairing))
        state = .ready
    }

    func restart() async {
        stop()
        state = .idle
        await open(hubURL: hubURL)
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    static var logFile: URL { dataDir.appendingPathComponent("engine.log") }

    private func launch(node: String, engine: URL) throws {
        try FileManager.default.createDirectory(at: Self.dataDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.currentDirectoryURL = engine
        process.arguments = [
            "apps/server/src/bin.ts", "serve", "--mode", "web", "--host", "127.0.0.1",
            "--port", String(Self.port), "--no-browser", "--base-dir", Self.dataDir.path,
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPath
        // Every chat saves to the hub this app is connected to.
        env["WOLF_LEADER_URL"] = hubURL
        process.environment = env
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    private func isUp() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse) != nil
    }

    /// A short-lived sign-in link from the engine's own `pair` command.
    private func mintPairingURL(node: String, engine: URL) async -> URL? {
        let run = await MainProcess.run(node, [
            engine.appendingPathComponent("apps/server/src/bin.ts").path, "pair",
            "--base-dir", Self.dataDir.path, "--label", "Wolf Leader app", "--ttl", "5m",
        ])
        guard run.code == 0,
              let line = run.output.split(separator: "\n").first(where: { $0.hasPrefix("Pairing URL:") })
        else { return nil }
        return URL(string: line.dropFirst("Pairing URL:".count).trimmingCharacters(in: .whitespaces))
    }
}
