import Foundation

/// A drop-in for the parts of Foundation's `Process` this app uses, built on
/// `posix_spawn`.
///
/// Why not `Process`: it passes arguments through the file-system
/// representation, which decomposes Unicode (`ü` → `u` + combining
/// diaeresis). A remote Linux host then looks for a different filename, so
/// `find`, `grep`, macros, multi-exec and rsync on a path like `héllo.txt`
/// all failed (found by the live test). Node passed the bytes through as
/// they were; so does this.
///
/// Children inherit only stdin/stdout/stderr (POSIX_SPAWN_CLOEXEC_DEFAULT),
/// so a pipe or socket the app holds never leaks into ssh or tsh.
final class SpawnProcess: @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String] = []
    var environment: [String: String]?
    var currentDirectoryURL: URL?
    /// `Pipe` or `FileHandle` (e.g. `FileHandle.nullDevice`); nil inherits ours.
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    /// Called once on a background thread after the child has exited.
    var terminationHandler: ((SpawnProcess) -> Void)?

    private let lock = NSLock()
    private let exitedSignal = DispatchSemaphore(value: 0)
    private var pid: pid_t = 0
    private var status: Int32 = 0
    private var finished = false
    private var started = false

    var processIdentifier: Int32 { lock.lock(); defer { lock.unlock() }; return pid }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started && !finished
    }

    /// Exit code, or the signal number when killed by one (as `Process`).
    var terminationStatus: Int32 {
        lock.lock(); defer { lock.unlock() }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f
    }

    var terminationReason: Process.TerminationReason {
        lock.lock(); defer { lock.unlock() }
        return (status & 0x7f) == 0 ? .exit : .uncaughtSignal
    }

    private static func fd(_ io: Any?, write: Bool) -> Int32? {
        switch io {
        case let p as Pipe: return write ? p.fileHandleForWriting.fileDescriptor : p.fileHandleForReading.fileDescriptor
        case let h as FileHandle: return h.fileDescriptor
        default: return nil
        }
    }

    func run() throws {
        guard let exe = executableURL?.path else { throw AppError("No executable") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // stdin from the read end, stdout/stderr to the write ends.
        for (target, io, write) in [(Int32(0), standardInput, false), (1, standardOutput, true), (2, standardError, true)] {
            if let f = SpawnProcess.fd(io, write: write) {
                posix_spawn_file_actions_adddup2(&actions, f, target)
            } else {
                posix_spawn_file_actions_adddup2(&actions, target, target)   // inherit ours explicitly
            }
        }
        if let cwd = currentDirectoryURL?.path {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }
        var flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attr, flags)
        var noSignals = sigset_t(); sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for s in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGCHLD] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        _ = flags

        // Arguments and environment go as their UTF-8 bytes, untouched.
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + arguments).map { strdup($0) } + [nil]
        let envDict = environment ?? ProcessInfo.processInfo.environment
        let envp: [UnsafeMutablePointer<CChar>?] = envDict.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var child: pid_t = 0
        let rc = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                posix_spawn(&child, exe, &actions, &attr, a.baseAddress, e.baseAddress)
            }
        }
        guard rc == 0 else { throw AppError("\((exe as NSString).lastPathComponent): \(String(cString: strerror(rc)))") }

        // The parent's copies of the child's pipe ends must go, or readers
        // never see EOF and writers never see the child leave.
        if let p = standardOutput as? Pipe { try? p.fileHandleForWriting.close() }
        if let p = standardError as? Pipe { try? p.fileHandleForWriting.close() }
        if let p = standardInput as? Pipe { try? p.fileHandleForReading.close() }

        lock.lock(); pid = child; started = true; lock.unlock()
        let t = Thread { [self] in
            var st: Int32 = 0
            while waitpid(child, &st, 0) < 0 && errno == EINTR {}
            lock.lock(); status = st; finished = true; let h = terminationHandler; lock.unlock()
            exitedSignal.signal()
            h?(self)
        }
        t.name = "SpawnProcess.wait"
        t.start()
    }

    func terminate() { if isRunning { kill(processIdentifier, SIGTERM) } }

    func waitUntilExit() {
        guard started else { return }
        exitedSignal.wait()
        exitedSignal.signal()   // let any other waiter through too
    }
}
