import Foundation

/// Anything a terminal pane can draw: an `ssh -tt` channel on a
/// ControlMaster, `tsh ssh`, `tsh beams ssh`, a local shell, a serial port, a
/// telnet socket, one pane of a tmux control-mode session, `tsh play`.
///
/// The pane (Sessions) only ever talks to this. Callbacks are delivered on
/// the main actor.
@MainActor
protocol TerminalBackend: AnyObject {
    /// Output to draw.
    var onData: ((Data) -> Void)? { get set }
    /// The stream ended: an exit code when there is one, and a message worth
    /// showing in the pane when it ended badly.
    var onExit: ((Int32?, String?) -> Void)? { get set }
    /// Keystrokes and pastes.
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// Hang up. Must be safe to call more than once.
    func close()
    /// The foreground process's working directory, when it can be known
    /// without typing into the terminal (nil otherwise).
    func cwd() async -> String?
    /// "ssh", "tsh", "beam", "local", "serial", "telnet", "tmux", "command".
    var kind: String { get }
}

/// A TerminalBackend over a local pty process: local shells, `ssh -tt`,
/// `tsh ssh`, `tsh play`, `tsh latency` … anything that is a program on a pty.
@MainActor
final class PTYBackend: TerminalBackend {
    let process: PTYProcess
    let kind: String
    /// Setting it hands over anything that arrived before the pane attached.
    var onData: ((Data) -> Void)? { didSet { flushEarly() } }
    var onExit: ((Int32?, String?) -> Void)? {
        didSet { if let code = exited, let h = onExit { h(code, nil) } }
    }
    /// Bytes that arrived before anyone listened (the pane attaches after spawn).
    private var early = Data()
    private var exited: Int32?

    init(_ process: PTYProcess, kind: String) {
        self.process = process
        self.kind = kind
        process.onData = { [weak self] d in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let h = self.onData { h(d) } else { self.early.append(d) }
            }
        }
        process.onExit = { [weak self] code in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.exited = code
                self.onExit?(code, nil)  // late subscribers get it in onExit's didSet
            }
        }
    }

    /// Hand over anything buffered before the pane attached.
    func flushEarly() {
        guard !early.isEmpty, let h = onData else { return }
        let d = early; early = Data()
        h(d)
    }

    func write(_ data: Data) { process.write(data) }
    func resize(cols: Int, rows: Int) { process.resize(cols: cols, rows: rows) }
    func close() { process.terminate() }
    func cwd() async -> String? { process.foregroundCwd() }
    var hasExited: Bool { exited != nil }
}
