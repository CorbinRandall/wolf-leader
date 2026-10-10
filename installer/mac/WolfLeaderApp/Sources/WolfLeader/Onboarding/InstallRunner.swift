import Foundation

/// Runs a bash script with Process and streams its merged stdout/stderr into `lines`.
/// The env passed to `run` is added to the app's environment and is never written to `lines`.
@MainActor
final class InstallRunner: ObservableObject {
    @Published var lines: [String] = []
    @Published var running = false
    @Published var exitCode: Int32?

    private var process: Process?
    private var pending = Data()
    private var readerDone = false
    private var exitStatus: Int32?
    /// Bumped on every run so late callbacks from an earlier run are ignored.
    private var generation = 0

    func run(script: URL, args: [String], env: [String: String]) {
        guard !running else { return }
        generation += 1
        let gen = generation
        lines = []
        exitCode = nil
        pending = Data()
        readerDone = false
        exitStatus = nil
        running = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path] + args
        proc.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        proc.environment = environment

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading

        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.receive(data, gen: gen)
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.exited(status, gen: gen, reader: reader)
                }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            reader.readabilityHandler = nil
            lines.append("Could not start \(script.lastPathComponent): \(error.localizedDescription)")
            exitCode = -1
            running = false
        }
    }

    /// Stops a running script (SIGTERM). `exitCode` is set when it has exited.
    func stop() {
        guard running, let proc = process, proc.isRunning else { return }
        proc.terminate()
    }

    private func receive(_ data: Data, gen: Int) {
        guard gen == generation, exitCode == nil else { return }
        if data.isEmpty {
            readerDone = true
            if exitStatus != nil { complete() }
            return
        }
        pending.append(data)
        var newLines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            newLines.append(Self.clean(pending[pending.startIndex..<nl]))
            pending.removeSubrange(pending.startIndex...nl)
        }
        if !newLines.isEmpty { lines.append(contentsOf: newLines) }
    }

    private func exited(_ status: Int32, gen: Int, reader: FileHandle) {
        guard gen == generation, exitCode == nil else { return }
        exitStatus = status
        if readerDone {
            complete()
            return
        }
        // A background child (tee, a daemon) can keep the pipe open after bash exits; don't wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.exitCode == nil else { return }
                reader.readabilityHandler = nil
                self.complete()
            }
        }
    }

    private func complete() {
        if !pending.isEmpty {
            lines.append(Self.clean(pending[...]))
            pending = Data()
        }
        exitCode = exitStatus ?? -1
        running = false
        process = nil
    }

    private static func clean(_ bytes: Data) -> String {
        var s = String(decoding: bytes, as: UTF8.self)
        if s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
