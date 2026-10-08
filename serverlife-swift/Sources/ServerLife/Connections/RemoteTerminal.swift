import Foundation

/// A terminal on a connection: `ssh -tt` over the master, `tsh ssh`, or
/// `tsh beams ssh`, on a local pty. Tees to a session log when one is
/// running (escape sequences stripped), and answers `cwd()` by probing the
/// remote shell over the master (never on tsh or beam transports).
@MainActor
final class RemoteTerminal: TerminalBackend {
    let id: String
    /// "ssh", "tsh" or "beam".
    let kind: String
    let process: PTYProcess
    weak var connection: Connection?

    var onData: ((Data) -> Void)? { didSet { flushEarly() } }
    var onExit: ((Int32?, String?) -> Void)? {
        didSet { if let code = exited, let h = onExit { h(code, nil) } }
    }

    private var early = Data()
    private(set) var exited: Int32?
    private var logHandle: FileHandle?
    /// The session log being written, if any.
    private(set) var logPath: String?
    private(set) var cols: Int
    private(set) var rows: Int

    init(id: String, kind: String, process: PTYProcess, connection: Connection, cols: Int, rows: Int) {
        self.id = id
        self.kind = kind
        self.process = process
        self.connection = connection
        self.cols = cols
        self.rows = rows
        process.onData = { [weak self] d in MainActor.assumeIsolated { self?.received(d) } }
        process.onExit = { [weak self] code in MainActor.assumeIsolated { self?.ended(code) } }
    }

    private func received(_ d: Data) {
        if let logHandle {
            let text = ConnText.stripAnsi(String(decoding: d, as: UTF8.self))
            try? logHandle.write(contentsOf: Data(text.utf8))
        }
        if let h = onData { h(d) } else { early.append(d) }
    }

    private func ended(_ code: Int32) {
        exited = code
        connection?.terminalEnded(id, code: code)
        onExit?(code, nil)
    }

    private func flushEarly() {
        guard !early.isEmpty, let h = onData else { return }
        let d = early; early = Data()
        h(d)
    }

    func write(_ data: Data) { process.write(data) }

    func write(_ text: String) { process.write(text) }

    func resize(cols: Int, rows: Int) {
        process.resize(cols: max(2, cols), rows: max(2, rows))
        self.cols = cols; self.rows = rows
    }

    func close() {
        if let connection { connection.closeTerminal(id) } else { kill() }
    }

    /// Hang up the pty without touching the connection's bookkeeping.
    func kill() {
        _ = stopLog()
        process.terminate()
    }

    func cwd() async -> String? { await connection?.terminalCwd(id) }

    var hasExited: Bool { exited != nil }

    // MARK: logging

    var logState: LogState { LogState(active: logHandle != nil, path: logPath) }

    func startLog(path: String, label: String) throws {
        _ = stopLog()
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { throw AppError("Could not open \(path) for writing") }
        h.seekToEndOfFile()
        try? h.write(contentsOf: Data("\n==== ServerLife session log - \(label) - \(ConnClock.iso()) ====\n".utf8))
        logHandle = h
        logPath = path
    }

    /// Stop logging; returns the path that was being written.
    func stopLog() -> String? {
        guard let h = logHandle else { return nil }
        let p = logPath
        try? h.write(contentsOf: Data("\n==== ended \(ConnClock.iso()) ====\n".utf8))
        try? h.close()
        logHandle = nil
        logPath = nil
        return p
    }
}

/// JavaScript's `new Date().toISOString()`.
enum ConnClock {
    nonisolated(unsafe) private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    static func iso(_ d: Date = Date()) -> String { fmt.string(from: d) }
}
