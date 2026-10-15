import Foundation

/// Runs the bundled history scanner (scripts/wolf-import.py) on this Mac. It reads the AI tools'
/// own files here, and talks to the hub over its API.
enum ToolBridge {
    enum BridgeError: LocalizedError {
        case missing, failed(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "The scanner is missing from this copy of the app."
            case .failed(let why): return why
            }
        }
    }

    static var script: URL? {
        guard let root = Payload.root else { return nil }
        let url = root.appendingPathComponent("scripts/wolf-import.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// One command whose answer is a single JSON object.
    static func json(_ args: [String], hubURL: String) async throws -> [String: Any] {
        guard let script else { throw BridgeError.missing }
        let run = await MainProcess.run("/usr/bin/python3", [script.path] + args + ["--api", hubURL])
        // Python warnings share the output; the answer is the last line that is a JSON object.
        let line = run.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? ""
        guard run.code == 0, let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            let tail = run.output.split(separator: "\n").suffix(3).joined(separator: " ")
            throw BridgeError.failed(tail.isEmpty ? "The scanner stopped without an answer." : tail)
        }
        return object
    }

    /// The import, which reports one JSON line per step while it runs.
    static func stream(_ args: [String], hubURL: String, onEvent: @escaping @MainActor ([String: Any]) -> Void) async throws -> Int32 {
        guard let script else { throw BridgeError.missing }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path] + args + ["--api", hubURL]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let lines = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                for line in lines.add(handle.availableData) {
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        nonisolated(unsafe) let event = event
                        Task { @MainActor in onEvent(event) }
                    }
                }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Splits a stream of output into whole lines. The pipe calls in from one queue at a time.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func add(_ chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
