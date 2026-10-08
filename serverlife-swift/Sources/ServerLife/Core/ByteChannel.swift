import Foundation

/// A two-way byte stream with no structure of its own. SFTP is spoken over
/// one (the stdin/stdout of `ssh -s sftp`, `tsh ssh … sftp-server`, `tsh
/// beams exec … sftp-server`, or a local `sftp-server` in tests); so is the
/// tmux control protocol.
///
/// `onData`/`onClose` are called on a background thread, in order.
protocol ByteChannel: AnyObject, Sendable {
    var onData: (@Sendable (Data) -> Void)? { get set }
    /// Called once, with an error message when the far end went away badly.
    var onClose: (@Sendable (String?) -> Void)? { get set }
    func write(_ data: Data)
    func close()
}

/// A ByteChannel over a child process's stdin/stdout. stderr is collected so
/// a failure can say what the far side said ("subsystem request failed …").
final class ProcessChannel: ByteChannel, @unchecked Sendable {
    private var proc: RunningProcess?
    private let lock = NSLock()
    private var stderrBuf = Data()
    private var pending: [Data] = []
    private var dataHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable (String?) -> Void)?
    private var closedWith: String??

    var onData: (@Sendable (Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return dataHandler }
        set {
            lock.lock()
            dataHandler = newValue
            let backlog = pending; pending = []
            lock.unlock()
            if let newValue { backlog.forEach { newValue($0) } }
        }
    }

    var onClose: (@Sendable (String?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closeHandler }
        set {
            lock.lock()
            closeHandler = newValue
            let done = closedWith
            lock.unlock()
            if let done, let newValue { newValue(done) }
        }
    }

    /// What the process has written to stderr so far.
    var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrBuf, as: UTF8.self)
    }

    var pid: Int32 { proc?.pid ?? 0 }

    /// The process's exit status once it has gone (nil while running), so a
    /// failure can say `exited (127)` the way sftp.js did.
    var exitStatus: Int32? {
        lock.lock(); defer { lock.unlock() }
        return exitCode
    }
    private var exitCode: Int32?

    init(_ exe: String, _ args: [String], env: [String: String?] = [:], cwd: String? = nil) throws {
        proc = try RunningProcess(exe, args, env: env, cwd: cwd, onStdout: { [weak self] d in
            guard let self else { return }
            self.lock.lock()
            if let h = self.dataHandler { self.lock.unlock(); h(d) } else { self.pending.append(d); self.lock.unlock() }
        }, onStderr: { [weak self] d in
            guard let self else { return }
            self.lock.lock()
            self.stderrBuf.append(d)
            // sftp.js kept the last 8000 bytes: enough to explain, never huge.
            if self.stderrBuf.count > 8000 { self.stderrBuf = self.stderrBuf.suffix(8000) }
            self.lock.unlock()
        }, onExit: { [weak self] code in
            guard let self else { return }
            let err = self.stderrText.trimmed
            let reason: String? = code == 0 ? nil : (err.isEmpty ? "exited with code \(code)" : err)
            self.lock.lock()
            self.exitCode = code
            self.closedWith = .some(reason)
            let h = self.closeHandler
            self.lock.unlock()
            h?(reason)
        })
    }

    func write(_ data: Data) { proc?.write(data) }

    func close() {
        proc?.closeStdin()
        proc?.terminate(grace: 1)
    }
}

extension ProcessChannel: SFTPChannelExitStatus {}
