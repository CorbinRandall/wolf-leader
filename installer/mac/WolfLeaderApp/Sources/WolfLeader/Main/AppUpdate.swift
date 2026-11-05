import AppKit
import Foundation

/// The newest GitHub release that carries a Mac disk image.
struct AppRelease: Equatable {
    let tag: String
    let version: String
    let dmg: URL
    let size: Int64
    let page: URL?
}

/// How this app replaces itself.
enum AppChannel: Equatable {
    /// Release builds following main: download the newest release's .dmg.
    case release
    /// Dev builds, or a build following another branch: download that branch and build it here.
    case source
}

/// Where the in-app update is.
enum AppPhase: Equatable {
    case idle
    /// Fraction 0...1, or nil when GitHub didn't send a size.
    case downloading(Double?)
    case building
    case installing
    case relaunching(String)
    case failed(String)

    var active: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }
}

enum VersionOrder {
    /// "2.10.0" is newer than "2.9.3". A leading v is ignored; missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            return t.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Downloads one file and reports progress (URLSession's async download reports none).
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void

    private init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func run(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let job = ProgressDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: job, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            job.lock.lock()
            job.continuation = c
            job.lock.unlock()
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("WolfLeader-mac/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        progress(expected > 0 ? Double(written) / Double(expected) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.http(http.statusCode)))
            return
        }
        // The temporary file is deleted when this returns, so move it now.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// Swaps a new copy of this app in for the running one, keeping everything the app stores outside
/// its bundle (Application Support: settings, chats, projects, the built-in hub; UserDefaults; Keychain).
enum AppSwap {
    static var updatesDir: URL { ConfigStore.supportDir.appendingPathComponent("updates", isDirectory: true) }
    static var backupsDir: URL { ConfigStore.supportDir.appendingPathComponent("app-backups", isDirectory: true) }
    /// Kept between updates so the next source build only recompiles what changed.
    static var sourceDir: URL { updatesDir.appendingPathComponent("source", isDirectory: true) }

    /// Can Swift build here without macOS offering to install developer tools?
    static var hasSwift: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/swift")
            || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    }

    /// Why the running copy can't be replaced in place, or nil when it can.
    static func blocker() -> String? {
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else {
            return "This copy isn't running from an .app (Xcode or swift run), so it can't replace itself."
        }
        if current.path.hasPrefix("/Volumes/") {
            return "Wolf Leader is running from the disk image. Drag it to Applications, open it from there, then update."
        }
        if current.path.contains("/AppTranslocation/") {
            return "macOS is running this copy from a temporary location. Move Wolf Leader to Applications, open it from there, then update."
        }
        let parent = current.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return "This Mac account can't write to \(parent), so the app can't replace itself there."
        }
        return nil
    }

    /// Checks the new copy is this same app with an intact signature. Returns its version.
    static func validate(_ app: URL) async throws -> String {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let id = info["CFBundleIdentifier"] as? String else {
            throw UpdateError.step("The new app has no Info.plist.")
        }
        guard id == Bundle.main.bundleIdentifier else {
            throw UpdateError.step("The download is a different app (\(id)), so it wasn't installed.")
        }
        let check = await MainProcess.run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        guard check.code == 0 else {
            throw UpdateError.step("The new app's signature doesn't check out, so it wasn't installed. \(check.output)")
        }
        return (info["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// Snapshots settings and chats, then starts a small script that waits for this app to quit,
    /// moves it into app-backups, moves the new copy into its place and opens it. If any move
    /// fails, the old app is put back and reopened.
    static func installAndRelaunch(_ newApp: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let stamp = timestamp()
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: updatesDir, withIntermediateDirectories: true)

        // Nothing in Application Support is touched by the swap; this copy is a safety net.
        let data = backupsDir.appendingPathComponent("data-\(stamp)", isDirectory: true)
        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        for name in ["config.json", "chats"] {
            let src = ConfigStore.supportDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: data.appendingPathComponent(name))
            }
        }

        let appName = current.deletingPathExtension().lastPathComponent
        let previous = backupsDir.appendingPathComponent("\(appName) \(BuildInfo.version) \(stamp).app")
        let script = updatesDir.appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), current.path,
                       newApp.path, previous.path, backupsDir.path,
                       updatesDir.appendingPathComponent("swap.log").path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// Leftovers from earlier downloads (the swap moves the app out; the rest can go).
    static func cleanUp() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: updatesDir, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("work-") {
            try? fm.removeItem(at: item)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static let swapScript = #"""
    #!/bin/bash
    # Wolf Leader self-update: wait for the app to quit, swap the bundle, open the new one.
    # swap.sh <pid> <installed.app> <new.app> <previous-copy.app> <backups-dir> <log>
    pid=$1 old=$2 new=$3 keep=$4 backups=$5 log=$6
    exec >>"$log" 2>&1
    echo "== $(date) $new -> $old"
    for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then
      echo "the app was still running after 60 s; nothing changed"
      exit 1
    fi
    if ! mv "$old" "$keep"; then
      echo "couldn't move the old app aside; nothing changed"
      open "$old"; exit 1
    fi
    if ! mv "$new" "$old"; then
      echo "couldn't move the new app in; putting the old one back"
      mv "$keep" "$old"; open "$old"; exit 1
    fi
    xattr -dr com.apple.quarantine "$old" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$old" >/dev/null 2>&1 || true
    # Keep the two newest previous versions and five data snapshots.
    ls -1dt "$backups"/*.app 2>/dev/null | tail -n +3 | while IFS= read -r d; do rm -rf "$d"; done
    ls -1dt "$backups"/data-* 2>/dev/null | tail -n +6 | while IFS= read -r d; do rm -rf "$d"; done
    echo "swapped; opening $old"
    open "$old"
    """#
}
