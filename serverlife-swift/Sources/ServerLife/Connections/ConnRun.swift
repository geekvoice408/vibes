import Foundation

/// `Proc.run`, plus the signal that killed the child (Core's ProcResult does
/// not record `terminationReason`). Used for remote commands so a killed one
/// reads "The command was killed on <host> (SIGTERM)." as in the original.
struct ConnRunResult: Sendable {
    var result: ProcResult
    /// The signal number when the child died of one (not for our own timeout kill).
    var signal: Int32?
}

enum ConnRun {
    static func run(_ exe: String, _ args: [String], env: [String: String?] = [:], cwd: String? = nil,
                    timeout: TimeInterval? = nil) async -> ConnRunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(exe, args, env: env, cwd: cwd, timeout: timeout))
            }
        }
    }

    static func runSync(_ exe: String, _ args: [String], env: [String: String?] = [:], cwd: String? = nil,
                        timeout: TimeInterval? = nil) -> ConnRunResult {
        guard let resolved = Proc.which(exe) else {
            return ConnRunResult(result: ProcResult(code: -1, stdout: Data(), stderr: Data(),
                                                    spawnError: "\(exe): command not found"), signal: nil)
        }
        let p = SpawnProcess()
        p.executableURL = URL(fileURLWithPath: resolved)
        p.arguments = args
        p.environment = Proc.environment(env)
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        let outReader = StreamReader(outPipe.fileHandleForReading)
        let errReader = StreamReader(errPipe.fileHandleForReading)
        do { try p.run() } catch {
            return ConnRunResult(result: ProcResult(code: -1, stdout: Data(), stderr: Data(),
                                                    spawnError: "\(exe): \(error.localizedDescription)"), signal: nil)
        }
        outReader.start(); errReader.start()
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
        let signalled = p.terminationReason == .uncaughtSignal
        let r = ProcResult(code: p.terminationStatus, stdout: outReader.finish(), stderr: errReader.finish(),
                           timedOut: timedOut)
        return ConnRunResult(result: r, signal: signalled && !timedOut ? p.terminationStatus : nil)
    }

    /// Node's signal names (macOS numbering).
    static func signalName(_ n: Int32) -> String {
        let names = ["", "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGEMT", "SIGFPE",
                     "SIGKILL", "SIGBUS", "SIGSEGV", "SIGSYS", "SIGPIPE", "SIGALRM", "SIGTERM", "SIGURG",
                     "SIGSTOP", "SIGTSTP", "SIGCONT", "SIGCHLD", "SIGTTIN", "SIGTTOU", "SIGIO", "SIGXCPU",
                     "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGWINCH", "SIGINFO", "SIGUSR1", "SIGUSR2"]
        return n > 0 && Int(n) < names.count ? names[Int(n)] : "signal \(n)"
    }

    /// A pty child's exit code as PTYProcess reports it: 128+N for signal N.
    static func ptySignal(_ code: Int32) -> Int32? {
        code > 128 && code < 160 ? code - 128 : nil
    }
}
