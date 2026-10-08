import Foundation
import CShim

/// A child process on a pseudo-terminal: what node-pty was in the original.
///
/// Used for every interactive stream — `ssh -tt` terminals, the ControlMaster
/// itself (so password/passphrase/MFA prompts can be answered), `tsh ssh`,
/// `tsh beams ssh`, local shells, `tsh play`, `tsh latency`.
///
/// `onData` and `onExit` are delivered on the main queue, in order.
final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    let masterFd: Int32
    private let readQueue = DispatchQueue(label: "pty.read")
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let lock = NSLock()
    private var closed = false
    private(set) var exitCode: Int32?
    private var pendingExit = false

    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Spawn `exe` (resolved on the augmented PATH) with `args` (not including
    /// argv[0]) on a new pty of the given size.
    init(exe: String, args: [String], env: [String: String?] = [:], cwd: String? = nil,
         cols: Int = 80, rows: Int = 24, argv0: String? = nil) throws {
        guard let path = Proc.which(exe) else { throw AppError("\(exe): command not found") }
        var environment = Proc.environment(env)
        if environment["TERM"] == nil { environment["TERM"] = "xterm-256color" }
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment["COLORTERM"] = "truecolor"
        let envList = environment.map { "\($0.key)=\($0.value)" }
        let argv = [argv0 ?? (path as NSString).lastPathComponent] + args
        var size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
        let dir = cwd.map { ($0 as NSString).expandingTildeInPath }

        // Everything the child touches is prepared before fork: after it,
        // only async-signal-safe calls are made.
        let cPath = strdup(path)!
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = envList.map { strdup($0) } + [nil]
        let cDir = dir.map { strdup($0)! }
        defer {
            free(cPath)
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
            if let cDir { free(cDir) }
        }

        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &size)
        if child < 0 { throw AppError("Could not open a terminal: \(String(cString: strerror(errno)))") }
        if child == 0 {
            if let cDir { _ = chdir(cDir) }
            cArgv.withUnsafeBufferPointer { a in
                cEnv.withUnsafeBufferPointer { e in
                    _ = execve(cPath, a.baseAddress, e.baseAddress)
                }
            }
            _exit(127)
        }
        pid = child
        masterFd = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        startReading()
        watchExit()
    }

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            var collected = Data()
            while true {
                let n = read(self.masterFd, &buf, buf.count)
                if n > 0 { collected.append(contentsOf: buf[0..<n]); if collected.count > 1 << 20 { break } }
                else if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
                else {
                    // EOF or EIO: the slave side is gone.
                    self.readSource?.cancel()
                    break
                }
            }
            if !collected.isEmpty {
                DispatchQueue.main.async { self.onData?(collected) }
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let deliverExit = self.pendingExit
            self.lock.unlock()
            if deliverExit { self.deliverExit() }
        }
        readSource = src
        src.resume()
    }

    private func watchExit() {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            let code: Int32
            if (status & 0x7f) == 0 { code = (status >> 8) & 0xff } else { code = 128 + (status & 0x7f) }
            self.lock.lock()
            self.exitCode = code
            self.lock.unlock()
            self.exitSource?.cancel()
            // Drain anything left in the pty before reporting the exit, so the
            // last lines of output are not lost behind the exit event.
            self.readQueue.asyncAfter(deadline: .now() + 0.05) {
                self.lock.lock(); self.pendingExit = true; self.lock.unlock()
                if self.readSource?.isCancelled ?? true { self.deliverExit() } else { self.readSource?.cancel() }
            }
        }
        exitSource = src
        src.resume()
    }

    private func deliverExit() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let code = exitCode ?? 0
        lock.unlock()
        close(masterFd)
        DispatchQueue.main.async { self.onExit?(code) }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitCode == nil
    }

    func write(_ data: Data) {
        guard isRunning else { return }
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(masterFd, p, left)
                if n > 0 { left -= n; p = p.advanced(by: n) }
                else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000) }
                else { break }
            }
        }
    }

    func write(_ text: String) { write(Data(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        guard isRunning else { return }
        var size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &size)
    }

    /// SIGHUP first (what closing a terminal sends), then SIGKILL.
    func terminate(grace: TimeInterval = 1.5) {
        guard isRunning else { return }
        kill(pid, SIGHUP)
        let p = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if self?.isRunning == true { kill(p, SIGKILL) }
        }
    }

    func signal(_ sig: Int32) { if isRunning { kill(pid, sig) } }

    /// The foreground process group's working directory, for "follow the
    /// terminal" and pane titles (read from the process, never by typing pwd).
    func foregroundCwd() -> String? {
        let pgid = tcgetpgrp(masterFd)
        let target = pgid > 0 ? pgid : pid
        return PTYProcess.cwd(of: target) ?? PTYProcess.cwd(of: pid)
    }

    /// Name of the foreground process (e.g. "vim", "zsh").
    func foregroundName() -> String? {
        let pgid = tcgetpgrp(masterFd)
        guard pgid > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        let n = proc_name(pgid, &name, UInt32(name.count))
        return n > 0 ? String(cString: name) : nil
    }

    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard n == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
