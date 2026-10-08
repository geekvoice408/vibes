import Foundation

/// The result of a finished child process.
struct ProcResult: Sendable {
    var code: Int32
    var stdout: Data
    var stderr: Data
    var timedOut = false
    /// Set when the process could not be started at all.
    var spawnError: String?

    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self) }
    var ok: Bool { code == 0 && !timedOut && spawnError == nil }

    /// stderr if there is any, else stdout, trimmed — the text worth showing
    /// when something failed.
    var message: String {
        if let e = spawnError { return e }
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Errors thrown by services; `message` is meant to be shown as-is.
struct AppError: LocalizedError, CustomStringConvertible {
    var message: String
    var code: String?
    init(_ message: String, code: String? = nil) { self.message = message; self.code = code }
    var errorDescription: String? { message }
    var description: String { message }
}

/// Running external programs: `child_process.execFile` / `spawn` in the
/// original. Arguments always go as an array — nothing here goes through a
/// shell unless the caller explicitly runs one.
enum Proc {
    /// The PATH children get. A Dock launch inherits a bare PATH, so the
    /// login shell's PATH and the usual tool directories are added (once).
    static let path: String = {
        var parts: [String] = []
        func add(_ p: String) { if !p.isEmpty, !parts.contains(p) { parts.append(p) } }
        let env = ProcessInfo.processInfo.environment
        (env["PATH"] ?? "").split(separator: ":").forEach { add(String($0)) }
        if let login = loginShellPath() { login.split(separator: ":").forEach { add(String($0)) } }
        let home = NSHomeDirectory()
        for p in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                  "/usr/bin", "/bin", "/usr/sbin", "/sbin", home + "/.tsh/bin", home + "/bin", home + "/.local/bin",
                  "/Applications/Teleport Connect.app/Contents/MacOS/tsh.app/Contents/MacOS",
                  "/Applications/tsh.app/Contents/MacOS"] {
            add(p)
        }
        return parts.joined(separator: ":")
    }()

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = SpawnProcess()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// The environment for a child: ours, the augmented PATH, then `extra`
    /// (a nil value removes the variable).
    static func environment(_ extra: [String: String?] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        // Never hand a child Electron's or Xcode's leftovers.
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        // A Dock launch has no locale; main.js set LANG=en_US.UTF-8 for the
        // whole app so tmux, ssh's SendEnv and tsh all see UTF-8.
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in extra {
            if let v { env[k] = v } else { env.removeValue(forKey: k) }
        }
        return env
    }

    /// Resolve the PATH (it runs a login shell) on a background thread at
    /// launch, so the first child spawned from the main actor never waits.
    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async { _ = path }
    }

    /// Find an executable on the augmented PATH.
    static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run to completion and collect output. Never throws: a spawn failure
    /// comes back as `spawnError` with code -1, a timeout as `timedOut`.
    static func run(_ exe: String, _ args: [String], env: [String: String?] = [:], cwd: String? = nil,
                    stdin: Data? = nil, timeout: TimeInterval? = nil) async -> ProcResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(exe, args, env: env, cwd: cwd, stdin: stdin, timeout: timeout))
            }
        }
    }

    /// Blocking variant of `run`, for background threads only.
    static func runSync(_ exe: String, _ args: [String], env: [String: String?] = [:], cwd: String? = nil,
                        stdin: Data? = nil, timeout: TimeInterval? = nil) -> ProcResult {
        guard let resolved = which(exe) else {
            return ProcResult(code: -1, stdout: Data(), stderr: Data(), spawnError: "\(exe): command not found")
        }
        let p = SpawnProcess()
        p.executableURL = URL(fileURLWithPath: resolved)
        p.arguments = args
        p.environment = environment(env)
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        p.standardInput = inPipe ?? FileHandle.nullDevice
        let outReader = StreamReader(outPipe.fileHandleForReading)
        let errReader = StreamReader(errPipe.fileHandleForReading)
        do { try p.run() } catch {
            return ProcResult(code: -1, stdout: Data(), stderr: Data(), spawnError: "\(exe): \(error.localizedDescription)")
        }
        outReader.start(); errReader.start()
        if let inPipe, let stdin {
            let h = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? h.write(contentsOf: stdin)
                try? h.close()
            }
        }
        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning {
                if Date() >= deadline {
                    timedOut = true
                    p.terminate()
                    let grace = Date().addingTimeInterval(2)
                    while p.isRunning && Date() < grace { usleep(20_000) }
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    break
                }
                usleep(10_000)
            }
        }
        p.waitUntilExit()
        // After a timeout kill, don't also wait out the full EOF grace.
        let grace: TimeInterval = timedOut ? 0.3 : 3
        return ProcResult(code: p.terminationStatus, stdout: outReader.finish(grace: grace),
                          stderr: errReader.finish(grace: grace), timedOut: timedOut)
    }
}

/// Reads a pipe on its own thread with blocking reads.
///
/// Deliberately not `FileHandle.bytes` / AsyncBytes: those stop delivering
/// once the parent writes to the child's stdin (found the hard way in the
/// Beams port). `finish()` waits for EOF but gives up after a grace period,
/// because a grandchild that inherited the pipe can hold it open forever.
final class StreamReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let done = DispatchSemaphore(value: 0)
    private let onChunk: ((Data) -> Void)?

    init(_ handle: FileHandle, onChunk: ((Data) -> Void)? = nil) {
        self.handle = handle
        self.onChunk = onChunk
    }

    func start() {
        let t = Thread { [self] in
            let fd = handle.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n > 0 {
                    let d = Data(chunk[0..<n])
                    if let onChunk { onChunk(d) } else { lock.lock(); buffer.append(d); lock.unlock() }
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            done.signal()
        }
        t.name = "StreamReader"
        t.start()
    }

    /// Wait (bounded) for EOF and return everything read.
    func finish(grace: TimeInterval = 3) -> Data {
        if done.wait(timeout: .now() + grace) == .timedOut {
            try? handle.close()
            _ = done.wait(timeout: .now() + 1)
        }
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// A long-lived child with streaming output and a writable stdin
/// (`spawn` in the original): tunnels, `tsh` logins, multi-exec channels,
/// rsync runs, SFTP channels over `ssh -s sftp`.
///
/// Callbacks arrive on a background thread; hop to the main actor yourself.
final class RunningProcess: @unchecked Sendable {
    let process = SpawnProcess()
    private var stdinPipe = Pipe()
    private var outReader: StreamReader?
    private var errReader: StreamReader?
    private let lock = NSLock()
    private var exited = false
    private var exitHandlers: [(Int32) -> Void] = []

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// Starts immediately. Throws when the executable cannot be found or run.
    init(_ exe: String, _ args: [String], env: [String: String?] = [:], cwd: String? = nil,
         onStdout: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
         onExit: ((Int32) -> Void)? = nil) throws {
        guard let resolved = Proc.which(exe) else { throw AppError("\(exe): command not found") }
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = args
        process.environment = Proc.environment(env)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdinPipe
        if let onExit { exitHandlers.append(onExit) }
        let out = StreamReader(outPipe.fileHandleForReading, onChunk: onStdout)
        let err = StreamReader(errPipe.fileHandleForReading, onChunk: onStderr)
        outReader = out; errReader = err
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            // Let the readers drain what the child wrote before it exited.
            DispatchQueue.global().async {
                _ = out.finish(grace: 2); _ = err.finish(grace: 0.5)
                self.lock.lock()
                self.exited = true
                let handlers = self.exitHandlers
                self.lock.unlock()
                handlers.forEach { $0(p.terminationStatus) }
            }
        }
        try process.run()
        out.start(); err.start()
    }

    func onExit(_ handler: @escaping (Int32) -> Void) {
        lock.lock()
        if exited {
            lock.unlock()
            handler(process.terminationStatus)
            return
        }
        exitHandlers.append(handler)
        lock.unlock()
    }

    func write(_ data: Data) {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func write(_ text: String) { write(Data(text.utf8)) }

    func closeStdin() { try? stdinPipe.fileHandleForWriting.close() }

    /// SIGTERM, then SIGKILL after `grace` seconds if it is still there.
    func terminate(grace: TimeInterval = 2) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    func signal(_ sig: Int32) { if process.isRunning { kill(process.processIdentifier, sig) } }

    /// Wait for exit from async code.
    func wait() async -> Int32 {
        await withCheckedContinuation { cont in onExit { cont.resume(returning: $0) } }
    }
}
