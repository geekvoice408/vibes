import Foundation

/// Whatever tmux runs over: a connection, or this machine (localhost.js).
/// The tmux layer asks three things of it — run a command and report what it
/// printed, start one with a terminal in front of it, and say what kind of
/// link it is.
@MainActor
protocol TmuxHost: AnyObject {
    func execResult(_ cmd: String) async -> ProcResult
    /// With a timeout (seconds; nil = the host's default) — the original
    /// gave the probe and session list 15 s and has-session 10 s.
    func execResult(_ cmd: String, timeout: TimeInterval?) async -> ProcResult
    func spawnCommandPTY(_ cmd: String, cols: Int, rows: Int) throws -> PTYProcess
    /// "local", "ssh", "tsh", "beam" … A beam has no way to give tmux a
    /// terminal, so it runs `tmux -C` over pipes (`spawnCommandChannel`).
    var transportKind: String { get }
    /// A command over plain pipes, for `tmux -C` on a beam. The default says
    /// it cannot be done.
    func spawnCommandChannel(_ cmd: String) throws -> ByteChannel
}

extension TmuxHost {
    func execResult(_ cmd: String, timeout: TimeInterval?) async -> ProcResult { await execResult(cmd) }

    func spawnCommandChannel(_ cmd: String) throws -> ByteChannel {
        throw AppError("tmux over pipes is not available on this connection")
    }
}

/// What `probeTmux` found out.
struct TmuxProbe: Equatable {
    var ok: Bool
    var version: String?
    var major: Int?
    var minor: Int?
    /// 3.2 and newer: `pause-after` flow control.
    var flowControl: Bool = false
    /// Always false: only the far side needs tmux.
    var clientNeeded: Bool = false
    var reason: String?
    /// The command that fixes it, when tmux is missing.
    var install: String?

    var json: JSON {
        ["ok": .bool(ok), "version": JSON(version), "major": JSON(major), "minor": JSON(minor),
         "flowControl": .bool(flowControl), "clientNeeded": .bool(clientNeeded), "reason": JSON(reason),
         "install": JSON(install)]
    }
}

/// One session in `tmux list-sessions`.
struct TmuxSessionInfo: Equatable, Identifiable {
    var name: String
    var id: String
    var windows: Int
    var attached: Bool
    /// ms since the epoch, or nil.
    var created: Double?

    var json: JSON {
        ["name": .string(name), "id": .string(id), "windows": JSON(windows), "attached": .bool(attached),
         "created": JSON(created)]
    }
}

/// One tmux window as `windowList()` reports it.
struct TmuxWindow: Equatable, Identifiable {
    var id: String
    var name: String
    var active: Bool
    var layout: String
    var tree: TmuxLayout?
    var panes: [String]
    var zoomed: Bool
}

enum TmuxControl {
    /// Whether this host can do it, asked of the host (`probeTmux`). A missing
    /// tmux is not an error — it is the ordinary state of a machine nobody has
    /// set up yet — so it comes back as an answer whose reason names the
    /// command to run.
    @MainActor static func probe(_ host: TmuxHost) async -> TmuxProbe {
        let r = await host.execResult("tmux -V 2>/dev/null || command -v tmux || true", timeout: 15)
        return parseProbe((r.out + r.err).trimmed, local: host.transportKind == "local")
    }

    static func parseProbe(_ text: String, local: Bool) -> TmuxProbe {
        let re = try! NSRegularExpression(pattern: #"tmux\s+(?:next-)?(\d+)\.(\d+)([a-z])?"#, options: [.caseInsensitive])
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return TmuxProbe(
                ok: false, clientNeeded: false,
                reason: text.contains("/tmux")
                    ? "tmux is installed but did not report a version"
                    : (local ? "tmux is not installed on this machine" : "tmux is not installed on this host"),
                install: local ? "brew install tmux" : "apt install tmux · dnf install tmux · apk add tmux")
        }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: text) else { return nil }
            return String(text[rr])
        }
        let major = Int(group(1) ?? "") ?? 0
        let minor = Int(group(2) ?? "") ?? 0
        let version = "\(major).\(minor)\(group(3) ?? "")"
        // 2.1 is where control mode became usable at all; 3.2 added flow
        // control. Below 3.2 it still works, just without the brakes.
        let supported = major > 2 || (major == 2 && minor >= 1)
        return TmuxProbe(ok: supported, version: version, major: major, minor: minor,
                         flowControl: major > 3 || (major == 3 && minor >= 2), clientNeeded: false,
                         reason: supported ? nil : "tmux \(version) is too old for control mode (2.1 or newer)")
    }

    static let sessionsFormat = "#{session_name}\t#{session_id}\t#{session_windows}\t#{session_attached}\t#{session_created}"

    /// The sessions already running there (`listSessions`).
    @MainActor static func listSessions(_ host: TmuxHost) async -> [TmuxSessionInfo] {
        let r = await host.execResult("tmux list-sessions -F '\(sessionsFormat)' 2>/dev/null || true", timeout: 15)
        return parseSessions(r.out)
    }

    static func parseSessions(_ out: String) -> [TmuxSessionInfo] {
        var list: [TmuxSessionInfo] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let f = fields(String(line), sessionLine, count: 5) else { continue }
            let created = (Double(f[4]) ?? 0) * 1000
            list.append(TmuxSessionInfo(name: f[0], id: f[1], windows: Int(f[2]) ?? 0,
                                        attached: (Int(f[3]) ?? 0) > 0, created: created == 0 ? nil : created))
        }
        return list
    }

    /*
     * tmux 3.6 and newer replace a tab in -F output with "_" (non-printable
     * characters are sanitised, in control mode too), which leaves a name
     * containing "_" ambiguous. The other fields have shapes of their own, so
     * the line is matched from both ends instead of split.
     */
    static let sessionLine = try! NSRegularExpression(pattern: #"^(.*)[\t_](\$\d+)[\t_](\d+)[\t_](\d+)[\t_](\d+)$"#)
    static let windowLine = try! NSRegularExpression(
        pattern: #"^(@\d+)[\t_](.*)[\t_]([01])[\t_]([0-9a-fA-F]{4},[^\t_]*?)(?:[\t_]([01]))?$"#)

    /// The fields of a `-F` line: split on tabs when tmux kept them, else matched.
    static func fields(_ line: String, _ re: NSRegularExpression, count: Int) -> [String]? {
        let tabbed = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if tabbed.count >= count { return tabbed }
        guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : String(line[Range(r, in: line)!])
        }
    }
}

/// The stream a control client talks over: a pty (`tmux -CC`) or pipes (`tmux -C`).
@MainActor
final class TmuxStream {
    private let pty: PTYProcess?
    private let channel: ByteChannel?
    var onData: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?

    init(pty: PTYProcess) {
        self.pty = pty
        self.channel = nil
        pty.onData = { [weak self] d in MainActor.assumeIsolated { self?.onData?(d) } }
        pty.onExit = { [weak self] code in MainActor.assumeIsolated { self?.onExit?(code) } }
    }

    init(channel: ByteChannel) {
        self.pty = nil
        self.channel = channel
        channel.onData = { [weak self] d in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onData?(d) } }
        }
        channel.onClose = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onExit?(nil) } }
        }
    }

    func write(_ data: Data) {
        if let pty { pty.write(data) } else { channel?.write(data) }
    }

    func resize(cols: Int, rows: Int) { pty?.resize(cols: cols, rows: rows) }

    func kill() {
        if let pty { pty.terminate() } else { channel?.close() }
    }
}

/// One attached tmux session over one host (`TmuxSession` in tmuxctl.js).
///
/// Commands and their answers are matched by order rather than by the number
/// in the guard line: tmux answers in the order it was asked, every command
/// produces exactly one block, and a queue is both simpler and harder to get
/// subtly wrong.
@MainActor
final class TmuxSession {
    /// The id the registry knows it by (`tmux-…`).
    let id: String
    let host: TmuxHost
    private(set) var sessionName: String
    private(set) var cols: Int
    private(set) var rows: Int
    let flowControl: Bool
    let plain: Bool
    /// From the probe, when attached through `TmuxService`.
    var version: String?

    private let parser: TmuxParser
    private var pending: [CheckedContinuation<[String], Error>] = []
    /// Whether tmux's own opening block has gone past, and whether we have
    /// asked it anything yet. Matching that block to the first command shifts
    /// every answer after it by one — "it only works the second time".
    private var greeted = false
    private var sentAny = false
    private var stream: TmuxStream?
    private(set) var ready = false
    private var windowOrder: [String] = []
    private var windows: [String: WindowState] = [:]
    private(set) var activeWindow: String?
    private var pendingInput: [(pane: String, bytes: [UInt8])] = []
    private var flushScheduled = false
    private var paneBackends: [String: WeakPane] = [:]

    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var greetWaiter: CheckedContinuation<Void, Never>?

    private struct WindowState {
        var name: String?
        var active = false
        var layout: String?
        var tree: TmuxLayout?
        var activePane: String?
        var zoomed = false
    }

    private struct WeakPane { weak var backend: TmuxPaneBackend? }

    // MARK: Events (the `on(…)` listeners in the original)

    /// Pane output: pane id ("%3"), bytes, and how far behind (ms) under flow control.
    var onOutput: ((String, Data, Int) -> Void)?
    var onWindows: (([TmuxWindow]) -> Void)?
    var onLayout: ((_ window: String, _ layout: String, _ tree: TmuxLayout?) -> Void)?
    var onWindowClose: ((String) -> Void)?
    var onActiveWindow: ((String) -> Void)?
    /// A pane paused (true) or continued (false) by flow control.
    var onPause: ((_ pane: String, _ paused: Bool) -> Void)?
    /// `%session-changed` / `%session-renamed`: the session's name now.
    var onSessionName: ((String) -> Void)?
    /// `%exit`: tmux ended this client (reason, when it gave one).
    var onExitNotice: ((String?) -> Void)?
    /// The client process itself went away.
    var onClientExit: ((Int32?) -> Void)?
    /// Set by `TmuxService`: the session is over — the reason, and whether it
    /// is still on the host (true), gone (false), or unknown (nil: the
    /// connection went with it).
    var onEnded: ((_ reason: String?, _ alive: Bool?) -> Void)?
    /// The registry's own listener for `%exit` and the client exiting.
    var endHook: ((String?) -> Void)?

    init(id: String = TmuxSession.newId(), host: TmuxHost, sessionName: String? = nil, cols: Int = 100,
         rows: Int = 30, flowControl: Bool = true) {
        self.id = id
        self.host = host
        self.sessionName = (sessionName?.isEmpty == false) ? sessionName! : "serverlife"
        self.cols = cols
        self.rows = rows
        self.flowControl = flowControl
        self.plain = host.transportKind == "beam"
        self.parser = TmuxParser(plain: plain)
    }

    /// `tmux-<ms base36>-<5 random>`, as main.js named them.
    nonisolated static func newId() -> String {
        let ms = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "tmux-\(ms)-" + String((0..<5).map { _ in chars.randomElement()! })
    }

    /// The command that attaches (or creates).
    func startCommand(attach: Bool = true) -> String {
        let name = shellQuote(sessionName)
        let mode = plain ? "-C" : "-CC"
        // `new-session -A` is attach-or-create in one command, which avoids
        // the race between asking whether a session exists and attaching.
        return attach
            ? "tmux \(mode) new-session -A -s \(name) -x \(cols) -y \(rows)"
            : "tmux \(mode) new-session -s \(name) -x \(cols) -y \(rows)"
    }

    /// Attach, or create if there is nothing to attach to.
    func start(attach: Bool = true) async throws {
        let cmd = startCommand(attach: attach)
        let s: TmuxStream = plain
            ? TmuxStream(channel: try host.spawnCommandChannel(cmd))
            : TmuxStream(pty: try host.spawnCommandPTY(cmd, cols: cols, rows: rows))
        stream = s
        s.onData = { [weak self] d in
            guard let self else { return }
            for ev in self.parser.feed(d) { self.handle(ev) }
        }
        s.onExit = { [weak self] code in
            guard let self else { return }
            self.ready = false
            self.failAll(AppError("the tmux client exited"))
            if let w = self.readyWaiter { self.readyWaiter = nil; w.resume(throwing: AppError("the session ended before it opened")) }
            if let g = self.greetWaiter { self.greetWaiter = nil; g.resume() }
            self.onClientExit?(code)
            self.endHook?("the connection closed")
        }

        if !ready {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                readyWaiter = c
                after(25) { [weak self] in
                    guard let self, let w = self.readyWaiter else { return }
                    self.readyWaiter = nil
                    w.resume(throwing: AppError("tmux did not enter control mode — is tmux installed on this host?"))
                }
            }
        }

        // Let the opening block go past before asking anything, with a grace
        // period rather than a wait without end.
        if !greeted {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                greetWaiter = c
                after(1.5) { [weak self] in
                    guard let self, let g = self.greetWaiter else { return }
                    self.greetWaiter = nil
                    g.resume()
                }
            }
        }

        if flowControl {
            // Without this a client that falls behind a flood of output simply
            // falls further behind. With it tmux pauses the pane and says so.
            _ = try? await command("refresh-client -f pause-after=10")
        }
        _ = await refreshWindows()
    }

    private func handle(_ ev: TmuxEvent) {
        switch ev {
        case .probe(let answer):
            // Only ever before control mode; the parser guarantees it.
            stream?.write(Data(answer.utf8))
        case .ready:
            ready = true
            if let w = readyWaiter { readyWaiter = nil; w.resume() }
        case .result(_, let flags, let error, let lines):
            if !greeted {
                greeted = true
                if let g = greetWaiter { greetWaiter = nil; g.resume() }
                // tmux's own opening block: before we asked anything, or
                // carrying the flag that says it is not a reply.
                if !sentAny || flags == "0" { break }
            }
            guard !pending.isEmpty else { break }
            let p = pending.removeFirst()
            if error { p.resume(throwing: AppError(lines.isEmpty ? "tmux command failed" : lines.joined(separator: "\n"))) }
            else { p.resume(returning: lines) }
        case .layout(let win, let layout, let tree):
            var w = windows[win] ?? WindowState()
            w.layout = layout
            w.tree = tree
            setWindow(win, w)
            onLayout?(win, layout, tree)
        case .windowAdd(let win):
            setWindow(win, windows[win] ?? WindowState())
            onWindows?(windowList())
            Task { _ = await self.refreshWindows() }
        case .windowClose(let win):
            windows.removeValue(forKey: win)
            windowOrder.removeAll { $0 == win }
            onWindowClose?(win)
            onWindows?(windowList())
        case .windowRenamed(let win, let name):
            var w = windows[win] ?? WindowState()
            w.name = name
            setWindow(win, w)
            onWindows?(windowList())
        case .activeWindow(_, let win):
            activeWindow = win
            onActiveWindow?(win)
        case .activePane(let win, let pane):
            var w = windows[win] ?? WindowState()
            w.activePane = pane
            setWindow(win, w)
        case .output(let pane, let data, let age):
            let d = Data(data)
            paneBackends[pane]?.backend?.deliver(d)
            onOutput?(pane, d, age ?? 0)
        case .pause(let pane):
            paneBackends[pane]?.backend?.paused = true
            onPause?(pane, true)
        case .continue(let pane):
            paneBackends[pane]?.backend?.paused = false
            onPause?(pane, false)
        case .session(_, let name):
            onSessionName?(name)
        case .sessionRenamed(let name):
            sessionName = name.isEmpty ? sessionName : name
            onSessionName?(name)
        case .exit(let reason):
            ready = false
            onExitNotice?(reason)
            endHook?(reason)
        default:
            break
        }
    }

    private func setWindow(_ id: String, _ w: WindowState) {
        if windows[id] == nil { windowOrder.append(id) }
        windows[id] = w
    }

    private func failAll(_ err: Error) {
        let p = pending
        pending = []
        p.forEach { $0.resume(throwing: err) }
    }

    /// Run one tmux command and get its block back. A `%error` block throws
    /// with tmux's own words.
    @discardableResult
    func command(_ cmd: String) async throws -> [String] {
        guard let stream else { throw AppError("not attached") }
        sentAny = true
        return try await withCheckedThrowingContinuation { c in
            pending.append(c)
            stream.write(Data((cmd + "\n").utf8))
        }
    }

    /// Keystrokes for a pane: hex, because `send-keys` otherwise reads its
    /// argument as key names, and batched on a short timer so someone typing
    /// quickly does not generate forty round trips.
    func writePane(_ pane: String, _ data: Data) {
        if let i = pendingInput.firstIndex(where: { $0.pane == pane }) { pendingInput[i].bytes += Array(data) }
        else { pendingInput.append((pane, Array(data))) }
        if flushScheduled { return }
        flushScheduled = true
        after(0.006) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let batch = self.pendingInput
            self.pendingInput = []
            for (pane, bytes) in batch where !bytes.isEmpty {
                Task { _ = try? await self.command("send-keys -t \(pane) -H \(Tmux.hexKeys(bytes))") }
            }
        }
    }

    /// The size of this client, which is what decides the size of the panes:
    /// tmux sizes a window to its smallest attached client, and there is no
    /// per-pane resize a control client may ask for.
    func resize(cols: Int, rows: Int) async {
        self.cols = cols
        self.rows = rows
        guard ready else { return }
        stream?.resize(cols: max(2, cols), rows: max(2, rows))
        _ = try? await command("refresh-client -C \(max(10, cols)),\(max(5, rows))")
    }

    /// What is on a pane's screen now, so a reattached pane is not blank.
    func capture(_ pane: String, lines: Int = 2000) async throws -> String {
        try await command("capture-pane -p -e -J -S -\(lines) -t \(pane)").joined(separator: "\n")
    }

    /// Let a pane that flow control paused carry on
    /// (`refresh-client -A '%N:continue'`, tmux 3.2+).
    func continuePane(_ pane: String) async {
        _ = try? await command("refresh-client -A '\(pane):continue'")
    }

    static let windowsFormat = "#{window_id}\t#{window_name}\t#{window_active}\t#{window_layout}\t#{window_zoomed_flag}"

    @discardableResult
    func refreshWindows() async -> [TmuxWindow] {
        let lines = (try? await command("list-windows -F '\(TmuxSession.windowsFormat)'")) ?? []
        for line in lines {
            guard let f = TmuxControl.fields(line, TmuxControl.windowLine, count: 4), f.count >= 4 else { continue }
            var w = windows[f[0]] ?? WindowState()
            w.name = f[1]
            w.active = f[2] == "1"
            w.layout = f[3]
            w.tree = TmuxLayout.safe(f[3])
            w.zoomed = f.count > 4 && f[4] == "1"
            setWindow(f[0], w)
            if w.active { activeWindow = f[0] }
        }
        let list = windowList()
        onWindows?(list)
        return list
    }

    func windowList() -> [TmuxWindow] {
        windowOrder.compactMap { id in
            guard let w = windows[id] else { return nil }
            return TmuxWindow(id: id, name: w.name ?? "", active: w.active, layout: w.layout ?? "", tree: w.tree,
                              panes: w.tree?.panes ?? [], zoomed: w.zoomed)
        }
    }

    /// The active pane of a window, as tmux last reported it.
    func activePane(of window: String) -> String? { windows[window]?.activePane }

    /// A TerminalBackend (kind "tmux") for one pane, made once and reused.
    func backend(for pane: String) -> TmuxPaneBackend {
        if let b = paneBackends[pane]?.backend { return b }
        let b = TmuxPaneBackend(session: self, pane: pane)
        paneBackends = paneBackends.filter { $0.value.backend != nil }
        paneBackends[pane] = WeakPane(backend: b)
        return b
    }

    /// Leave the session running on the server.
    func detach() async {
        _ = try? await command("detach-client")
        close()
    }

    /// End it for good.
    func kill() async {
        _ = try? await command("kill-session -t \(shellQuote(sessionName))")
        close()
    }

    func close() {
        pendingInput = []
        failAll(AppError("detached"))
        let s = stream
        stream = nil
        s?.kill()
        ready = false
    }
}

/// One tmux pane as a terminal backend (kind "tmux"). Keystrokes go to the
/// pane with `send-keys -H`; output arrives from the session's `%output`.
///
/// It never ends on its own: what an ended or detached session looks like is
/// the window's business (see `TmuxSession.onEnded`); call `finish` to
/// deliver `onExit` when a pane should end. `close()` only stops this view —
/// the pane on the server is not killed.
@MainActor
final class TmuxPaneBackend: TerminalBackend {
    let pane: String
    private(set) weak var session: TmuxSession?
    let kind = "tmux"
    private var early = Data()
    private var closed = false
    private var exitInfo: (Int32?, String?)?
    /// Whether flow control has paused this pane right now.
    var paused = false
    /// The grid size the pane reports; the window turns the sizes of all its
    /// panes into one client size for `TmuxSession.resize`.
    private(set) var cols = 0
    private(set) var rows = 0
    /// Called on every resize — the window decides what the client size is.
    var onResize: ((Int, Int) -> Void)?

    var onData: ((Data) -> Void)? {
        didSet {
            guard !early.isEmpty, let h = onData else { return }
            let d = early; early = Data(); h(d)
        }
    }
    var onExit: ((Int32?, String?) -> Void)? {
        didSet { if let e = exitInfo, let h = onExit { h(e.0, e.1) } }
    }

    init(session: TmuxSession, pane: String) {
        self.session = session
        self.pane = pane
    }

    func deliver(_ d: Data) {
        guard !closed else { return }
        if let h = onData { h(d) } else { early.append(d) }
    }

    func write(_ data: Data) {
        guard !closed, let session, exitInfo == nil else { return }
        session.writePane(pane, data)
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        onResize?(cols, rows)
    }

    func close() { closed = true }

    /// End this pane's stream (delivers `onExit` once).
    func finish(code: Int32? = nil, reason: String?) {
        guard exitInfo == nil else { return }
        exitInfo = (code, reason)
        onExit?(code, reason)
    }

    func cwd() async -> String? {
        guard let session else { return nil }
        let out = try? await session.command("display-message -p -t \(pane) '#{pane_current_path}'")
        return out?.first?.trimmed.nilIfEmpty
    }
}

/// Attached tmux sessions by id — the logic of main.js's `tmux:*` handlers.
@MainActor
final class TmuxService {
    static let shared = TmuxService()
    private(set) var sessions: [String: TmuxSession] = [:]

    /// `tmux:probe`.
    func probe(_ host: TmuxHost) async -> TmuxProbe { await TmuxControl.probe(host) }

    /// `tmux:sessions`.
    func listSessions(_ host: TmuxHost) async -> [TmuxSessionInfo] { await TmuxControl.listSessions(host) }

    /// `tmux:attach`: probe, attach-or-create `session` (default
    /// "serverlife"), and keep it until it ends. `configure` runs before the
    /// client starts, so callbacks see the first windows and layouts.
    /// Throws the probe's reason when tmux is missing or too old.
    func attach(_ host: TmuxHost, session name: String? = nil, cols: Int = 100, rows: Int = 30,
                configure: ((TmuxSession) -> Void)? = nil) async throws -> TmuxSession {
        let probe = await TmuxControl.probe(host)
        if !probe.ok { throw AppError(probe.reason ?? "tmux is not available on this host") }
        let s = TmuxSession(host: host, sessionName: name, cols: cols > 0 ? cols : 100, rows: rows > 0 ? rows : 30,
                            flowControl: probe.flowControl)
        s.version = probe.version
        configure?(s)
        s.endHook = { [weak self, weak s] reason in
            guard let self, let s else { return }
            Task { await self.finish(s, reason: reason) }
        }
        sessions[s.id] = s
        do {
            try await s.start()
        } catch {
            sessions.removeValue(forKey: s.id)
            s.close()
            throw error
        }
        return s
    }

    /// Whether the session is still on the host, asked of the host: tmux
    /// tells a control client only `%exit`, whatever happened. `=` makes the
    /// name an exact match; nil when the connection itself is gone.
    func stillThere(_ s: TmuxSession) async -> Bool? {
        let r = await s.host.execResult("tmux has-session -t \(shellQuote("=" + s.sessionName)) 2>/dev/null && echo yes || echo no", timeout: 10)
        let out = r.out
        if (try? NSRegularExpression(pattern: #"\byes\b"#))?.matches(out) == true { return true }
        if (try? NSRegularExpression(pattern: #"\bno\b"#))?.matches(out) == true { return false }
        return nil
    }

    private func finish(_ s: TmuxSession, reason: String?) async {
        guard sessions[s.id] != nil else { return }
        sessions.removeValue(forKey: s.id)
        let alive = await stillThere(s)
        s.onEnded?(reason, alive)
    }

    /// `requireTmux`.
    func session(_ id: String) throws -> TmuxSession {
        guard let s = sessions[id] else { throw AppError("that tmux session is not attached any more") }
        return s
    }

    /// `tmux:detach`: leave it running, and say so (alive: true).
    func detach(_ id: String) async {
        guard let s = sessions.removeValue(forKey: id) else { return }
        await s.detach()
        s.onEnded?("detached", true)
    }

    /// `tmux:kill`: end it for good (alive: false).
    func kill(_ id: String) async {
        guard let s = sessions.removeValue(forKey: id) else { return }
        await s.kill()
        s.onEnded?("ended", false)
    }

    /// On the way out.
    func closeAll() {
        for (_, s) in sessions { s.close() }
        sessions = [:]
    }
}
