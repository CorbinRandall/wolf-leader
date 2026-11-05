import Foundation

/// Runs an agent's command-line tool and exchanges one JSON object per line over stdin/stdout.
final class JSONLineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var errorTail = ""
    private let lock = NSLock()

    /// Called on the main thread, in order, for every JSON object the tool prints.
    var onMessage: ([String: Any]) -> Void = { _ in }
    /// Called on the main thread when the tool exits, with the end of its error output.
    var onExit: (Int32, String) -> Void = { _, _ in }

    init(executable: String, args: [String], cwd: String, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock()
            self.errorTail = String((self.errorTail + String(decoding: data, as: UTF8.self)).suffix(4000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // Let the last lines of output arrive before reporting the exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.lock.lock(); let tail = self.errorTail; self.lock.unlock()
                self.onExit(proc.terminationStatus, tail)
            }
        }
        try process.run()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in self?.onMessage(object) }
        }
    }

    func send(_ object: [String: Any]) {
        guard process.isRunning,
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// JSON-RPC over a JSONLineProcess: Codex's app-server and the Agent Client Protocol both use it.
@MainActor
final class JSONRPCPeer {
    let process: JSONLineProcess
    /// Codex's app-server leaves out the "jsonrpc" field; ACP requires it.
    private let tagged: Bool
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    var onNotification: (String, [String: Any]) -> Void = { _, _ in }
    /// A request from the agent to us (approvals, file reads). Answer with `respond`.
    var onRequest: (Any, String, [String: Any]) -> Void = { _, _, _ in }
    var onExit: (String) -> Void = { _ in }

    init(process: JSONLineProcess, tagged: Bool) {
        self.process = process
        self.tagged = tagged
        process.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        process.onExit = { [weak self] code, tail in
            MainActor.assumeIsolated {
                guard let self else { return }
                let why = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = why.isEmpty ? "The agent stopped (exit \(code))." : AgentText.oneLine(why, limit: 400)
                for (_, waiter) in self.pending { waiter.resume(throwing: AgentError.failed(reason)) }
                self.pending.removeAll()
                self.onExit(reason)
            }
        }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { waiter in
            pending[id] = waiter
            process.send(envelope(["id": id, "method": method, "params": params]))
        }
    }

    func notify(_ method: String, _ params: [String: Any]? = nil) {
        var message: [String: Any] = ["method": method]
        if let params { message["params"] = params }
        process.send(envelope(message))
    }

    func respond(_ id: Any, result: [String: Any]) {
        process.send(envelope(["id": id, "result": result]))
    }

    func respondError(_ id: Any, message: String) {
        process.send(envelope(["id": id, "error": ["code": -32601, "message": message]]))
    }

    private func envelope(_ message: [String: Any]) -> [String: Any] {
        guard tagged else { return message }
        var tagged = message
        tagged["jsonrpc"] = "2.0"
        return tagged
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if let method, let id = message["id"] {
            onRequest(id, method, params)
        } else if let method {
            onNotification(method, params)
        } else if let id = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue, let waiter = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                waiter.resume(throwing: AgentError.failed(error["message"] as? String ?? "The agent returned an error."))
            } else {
                waiter.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
        }
    }
}
