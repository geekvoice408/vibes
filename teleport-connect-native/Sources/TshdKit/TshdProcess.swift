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
    /// The Unix domain socket path our own TshdEventsServer listens on — tshd calls back into
    /// this to ask us to prompt for MFA, hardware key touches, relogin, etc. (see
    /// service.proto's UpdateTshdEventsServerAddress: "This RPC needs to be made before any
    /// other from this service.").
    public nonisolated let eventsSocketPath: String
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
        self.eventsSocketPath = dir.appendingPathComponent("tshde.sock").path
        self.supportDir = dir

        for sub in ["certs", "kubeconfigs", "agents", "fakebin"] {
            try? FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        // tshd's SSO login flow shells out to the literal `open` command to launch the system
        // browser (lib/client/sso/redirector.go's OpenURLInBrowser, via exec.LookPath("open") on
        // Darwin) with no flag or env var to suppress it. Since we control the PATH of the tshd
        // subprocess we spawn, shadow `open` with a no-op script placed earlier in PATH — this
        // silently no-ops the browser launch without touching tsh's source. tshd still always
        // prints the clickable SSO URL to its own stderr regardless (same function, a few lines
        // later), which awaitSSOLoginURL(timeout:) below scans for so we can open it ourselves.
        let fakeOpen = dir.appendingPathComponent("fakebin/open")
        try? "#!/bin/sh\nexit 0\n".write(to: fakeOpen, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
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
    public func start(
        timeout: Duration = .seconds(15),
        addKeysToAgent: String = "auto",
        hardwareKeyAgentEnabled: Bool = false
    ) async throws {
        guard let binary = Self.locateBinary() else {
            throw TshdProcessError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = [
            "daemon", "start",
            "--addr=unix://\(socketPath)",
            "--certs-dir=\(supportDir.appendingPathComponent("certs").path)",
            "--kubeconfigs-dir=\(supportDir.appendingPathComponent("kubeconfigs").path)",
            "--agents-dir=\(supportDir.appendingPathComponent("agents").path)",
            "--installation-id=\(UUID().uuidString)",
            "--add-keys-to-agent=\(addKeysToAgent)",
        ]
        if hardwareKeyAgentEnabled {
            arguments.append("--hardware-key-agent")
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let fakeBinDir = supportDir.appendingPathComponent("fakebin").path
        environment["PATH"] = fakeBinDir + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

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

    private var ssoURLContinuation: CheckedContinuation<URL?, Never>?
    /// Where in `outputBuffer` the current SSO attempt started watching from. Without this,
    /// a second SSO login in the same running app session would match the *first* attempt's
    /// (by-then-closed) local callback URL out of the accumulated history — surfacing as a
    /// blank WebView followed by "connection refused" when falling back to a real browser.
    private var ssoSearchMarker: String.Index?

    private func appendOutput(_ text: String) {
        outputBuffer += text
        guard ssoURLContinuation != nil, let marker = ssoSearchMarker else { return }
        if let url = Self.extractSSOLoginURL(from: String(outputBuffer[marker...])) {
            resolveSSOURLWaiter(url)
        }
    }

    /// Waits for tshd to print the clickable SSO login URL (lib/client/sso/redirector.go's
    /// processLoginURL — printed to stderr unconditionally, whether or not a browser actually
    /// opened) during an in-flight Login RPC. Call this concurrently with the Login call.
    ///
    /// Only ever matches output appended after this call starts, so a stale URL from an earlier
    /// SSO attempt (a different cluster, or a retry) in this same process can't be picked up.
    public func awaitSSOLoginURL(timeout: Duration = .seconds(20)) async -> URL? {
        let marker = outputBuffer.endIndex
        ssoSearchMarker = marker
        if let url = Self.extractSSOLoginURL(from: String(outputBuffer[marker...])) {
            return url
        }
        return await withCheckedContinuation { continuation in
            self.ssoURLContinuation = continuation
            Task {
                try? await Task.sleep(for: timeout)
                await self.resolveSSOURLWaiterIfPending(nil)
            }
        }
    }

    private func resolveSSOURLWaiter(_ url: URL?) {
        guard let continuation = ssoURLContinuation else { return }
        ssoURLContinuation = nil
        continuation.resume(returning: url)
    }

    private func resolveSSOURLWaiterIfPending(_ url: URL?) {
        resolveSSOURLWaiter(url)
    }

    private static func extractSSOLoginURL(from text: String) -> URL? {
        guard let range = text.range(of: #"http://127\.0\.0\.1:\d+/[\w-]+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
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
