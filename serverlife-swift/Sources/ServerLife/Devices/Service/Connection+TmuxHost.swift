import Foundation

/// A connection is something tmux can run over: `execResult`, a pty for
/// `tmux -CC`, and — on a beam, which has no terminal to give — pipes for
/// `tmux -C`.
extension Connection: TmuxHost {
    func execResult(_ cmd: String) async -> ProcResult {
        await execResult(cmd, timeout: nil)
    }

    func spawnCommandChannel(_ cmd: String) throws -> ByteChannel {
        try TmuxPipeChannel { onData, onExit in
            try self.spawnCommandPipe(cmd, onData: onData, onExit: onExit)
        }
    }
}

/// A `RunningProcess` (stdout and stderr together) as a `ByteChannel`, for
/// `tmux -C` over `tsh beams exec`. Output that arrives before anyone
/// listens is kept.
final class TmuxPipeChannel: ByteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var proc: RunningProcess?
    private var pending: [Data] = []
    private var dataHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable (String?) -> Void)?
    private var closedWith: String??

    init(_ start: (@escaping @Sendable (Data) -> Void, @escaping @Sendable (Int32) -> Void) throws -> RunningProcess) throws {
        proc = try start({ [weak self] d in
            guard let self else { return }
            self.lock.lock()
            if let h = self.dataHandler { self.lock.unlock(); h(d) } else { self.pending.append(d); self.lock.unlock() }
        }, { [weak self] code in
            guard let self else { return }
            let reason: String? = code == 0 ? nil : "exited with code \(code)"
            self.lock.lock()
            self.closedWith = .some(reason)
            let h = self.closeHandler
            self.lock.unlock()
            h?(reason)
        })
    }

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

    func write(_ data: Data) { proc?.write(data) }

    func close() {
        proc?.closeStdin()
        proc?.terminate(grace: 1)
    }
}
