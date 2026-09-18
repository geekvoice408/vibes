import Foundation

/// Manages the lifecycle of a `tsh daemon start` subprocess (tshd), mirroring what
/// Teleport Connect's Electron main process does in mainProcess.ts.
public actor TshdProcess {
    public enum TshdProcessError: Error, CustomStringConvertible {
        case binaryNotFound
        case processExitedBeforeReady(status: Int32, output: String)
        case readyTimedOut(output: String)

        public var description: String {
            switch self {
            case .binaryNotFound:
                return "Could not locate the 'tsh' binary. Install it (e.g. `brew install teleport`) or ensure it's on PATH."
            case .processExitedBeforeReady(let status, let output):
                return "tshd exited with status \(status) before becoming ready.\n--- output ---\n\(output)"
            case .readyTimedOut(let output):
                return "Timed out waiting for tshd to report readiness.\n--- output so far ---\n\(output)"
            }
        }
    }

    /// The Unix domain socket path tshd is listening on once ready.
    public nonisolated let socketPath: String
    private nonisolated let supportDir: URL

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputBuffer: String = ""

    public init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcn-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.socketPath = dir.appendingPathComponent("tshd.sock").path
        self.supportDir = dir

        for sub in ["certs", "kubeconfigs", "agents"] {
            try? FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    /// Locates the `tsh` binary, preferring common install locations before falling back to PATH.
    public static func locateBinary() -> String? {
        let candidates = [
            "/usr/local/bin/tsh",
            "/opt/homebrew/bin/tsh",
            "/Applications/tsh.app/Contents/MacOS/tsh",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "tsh"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    /// A thread-safe "resume exactly once" box, since readabilityHandler/terminationHandler
    /// callbacks fire on Foundation-managed background queues, not on the actor.
    private final class ReadinessSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func resume(with result: Result<Void, Error>) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            switch result {
            case .success: cont?.resume()
            case .failure(let error): cont?.resume(throwing: error)
            }
        }
    }

    /// Starts `tsh daemon start --addr=unix://<socketPath>` and waits until it reports readiness
    /// (tshd prints `{CONNECT_GRPC_PORT: ...}` to stdout once its listener is bound — see
    /// lib/teleterm/apiserver/apiserver.go's sendBoundNetworkPortToStdout).
    public func start(timeout: Duration = .seconds(15)) async throws {
        guard let binary = Self.locateBinary() else {
            throw TshdProcessError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "daemon", "start",
            "--addr=unix://\(socketPath)",
            "--certs-dir=\(supportDir.appendingPathComponent("certs").path)",
            "--kubeconfigs-dir=\(supportDir.appendingPathComponent("kubeconfigs").path)",
            "--agents-dir=\(supportDir.appendingPathComponent("agents").path)",
            "--installation-id=\(UUID().uuidString)",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let readyMarker = "CONNECT_GRPC_PORT"
        let signal = ReadinessSignal()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendOutput(text) }
            if text.contains(readyMarker) {
                signal.resume(with: .success(()))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendOutput(text) }
        }
        process.terminationHandler = { proc in
            signal.resume(with: .failure(TshdProcessError.processExitedBeforeReady(
                status: proc.terminationStatus,
                output: ""
            )))
        }

        try process.run()
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            signal.resume(with: .failure(TshdProcessError.readyTimedOut(output: "")))
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            signal.setContinuation(continuation)
        }
    }

    private func appendOutput(_ text: String) {
        outputBuffer += text
    }

    public func collectedOutput() -> String {
        outputBuffer
    }

    /// Gracefully stops tshd (SIGTERM, matching terminateWithTimeout in mainProcess.ts).
    public func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        guard let process, process.isRunning else { return }
        process.terminationHandler = nil
        process.terminate()
        process.waitUntilExit()
    }
}
