import Foundation
import Observation

/// One connection to one host (connections.js `Connection`).
///
/// Each owns one OpenSSH ControlMaster. Authentication happens once, there;
/// terminals, exec, the SFTP channel and port forwards then ride that socket
/// with no further prompts. The master runs on a pty so password, passphrase,
/// host-key and Teleport MFA prompts surface as `state == .prompting` /
/// `prompt` and are answered with `writeMaster`.
///
/// The tsh transport (per-session MFA, leaf clusters, no ssh client) has no
/// master: every channel is its own `tsh ssh`. A beam has none either: `tsh
/// beams ssh` for terminals, `tsh beams exec` for everything else.
@MainActor
@Observable
final class Connection: Identifiable {
    let id: String
    let spec: ConnSpec
    let controlPath: String

    // MARK: observed state

    /// idle → connecting → (prompting) → connected; error / closed.
    private(set) var state: ConnState = .idle
    /// The last error (kept until the next connect attempt).
    private(set) var lastError: String?
    /// The master's output and the app's own notes, last 500 chunks.
    private(set) var log: [ConnLogLine] = []
    /// Home directory, remote user and hostname, once connected over the master.
    private(set) var info = ConnInfo()
    private(set) var forwards: [Forward] = []
    /// The most recent prompt text while `state == .prompting`.
    private(set) var prompt: String?
    /// Whether the last failed connect looked like per-session MFA (offer tsh).
    private(set) var lastErrorMfaLikely = false
    /// The last server profile read (`conn:serverInfo` push).
    private(set) var serverInfo: ServerInfo?
    /// Open terminals' ids, in opening order.
    private(set) var terminalIds: [String] = []
    /// Session-log state per terminal id (`term:logging` push).
    private(set) var logging: [String: LogState] = [:]

    // MARK: internals

    @ObservationIgnored var onEvent: ((ConnEvent) -> Void)?
    @ObservationIgnored private(set) var master: PTYProcess?
    @ObservationIgnored private var connecting: Task<Void, Error>?
    @ObservationIgnored private let health = Repeater()
    @ObservationIgnored private var healthBusy = false
    @ObservationIgnored private(set) var terminals: [String: RemoteTerminal] = [:]
    @ObservationIgnored private var forwardProcs: [String: RunningProcess] = [:]
    @ObservationIgnored private var sftpChannels: [ConnByteChannel] = []
    @ObservationIgnored private var sftpClosedByPeer = false
    @ObservationIgnored private var historyCache: ShellHistory?
    @ObservationIgnored var toolsCache: HostTools?
    @ObservationIgnored var historyId: String?

    nonisolated(unsafe) private static var connSeq = 0
    nonisolated(unsafe) static var fwdSeq = 0

    init(spec: ConnSpec, id: String? = nil) {
        if let id { self.id = id } else { Connection.connSeq += 1; self.id = "conn\(Connection.connSeq)" }
        self.spec = spec
        self.controlPath = ConnRuntime.controlPath(for: "\(self.id)|\(spec.target)|\(spec.configFile ?? "")")
    }

    // MARK: descriptive

    var label: String { spec.label }
    var target: String { spec.target }
    /// "ssh", "teleport" or "beam".
    var type: String { spec.type }
    var transport: ConnTransport { spec.transport }
    /// "mux", "tsh" or "beam" — for the tmux layer.
    var transportKind: String { spec.transport.rawValue }
    /// "no-ssh" or "leaf" when tsh was not the transport asked for.
    var transportForced: String? { spec.transportForced }
    var tshByNecessity: Bool { spec.tshByNecessity }
    var login: String? { spec.login }
    var x11: String { spec.x11 }
    var error: String? { lastError }
    var homeDir: String? { info.homeDir }
    var remoteUser: String? { info.user }
    var remoteHostname: String? { info.hostname }
    var hostId: String? { spec.hostId }

    /// The host descriptor this connection was opened for.
    var host: Host {
        if let h = spec.node ?? spec.host { return h }
        return Host(type: spec.type == "teleport" ? Host.teleport : spec.type, id: "", name: spec.target)
    }

    /// The history record for this connection (`historyEntryFor`).
    var historyEntry: JSON { spec.historyEntry(user: info.user, hostname: info.hostname) }

    // MARK: environment and argv

    /// Environment for anything this connection spawns: tsh's TELEPORT_HOME
    /// (ssh needs it too, for `tsh proxy ssh`) and ssh's own directory on PATH.
    func procEnv(_ extra: [String: String?] = [:]) -> [String: String?] {
        var env = Tools.tshEnv(home: spec.tshHome)
        let dir = (Tools.ssh as NSString).deletingLastPathComponent
        if !dir.isEmpty, dir != ".", !Proc.path.split(separator: ":").contains(Substring(dir)) {
            env["PATH"] = Proc.path + ":" + dir
        }
        for (k, v) in extra { env[k] = v }
        return env
    }

    func sshArgs(_ extra: [String] = []) -> [String] { spec.sshArgs(controlPath: controlPath, extra) }
    func tshArgs(_ extra: [String] = [], command: String? = nil) -> [String] { spec.tshArgs(extra, command: command) }
    func beamArgs(command: String? = nil) -> [String] { spec.beamArgs(command: command) }

    /// How to run `command` on this host non-interactively (for multi-exec,
    /// which streams and cancels its own processes).
    func execInvocation(_ command: String) -> (exe: String, args: [String], env: [String: String?]) {
        let inv = spec.execInvocation(controlPath: controlPath, command: command)
        return (inv.exe, inv.args, procEnv())
    }

    // MARK: log and state

    func pushLog(_ text: String, _ stream: String = "out") {
        let entry = ConnLogLine(t: nowMs(), text: text, stream: stream)
        log.append(entry)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        onEvent?(.log(id: id, line: entry))
    }

    private func setState(_ s: ConnState, error err: String? = nil) {
        if state == s && err == nil { return }
        state = s
        if let err { lastError = err }
        if s != .prompting { prompt = nil }
        onEvent?(.state(id: id, state: s, error: lastError))
        onEvent?(.changed)
    }

    // MARK: connect

    /// True if the control socket is live (`ssh -O check`).
    func checkMaster() async -> Bool {
        let r = await Proc.run(Tools.ssh, sshArgs(["-O", "check", target]), env: procEnv(), timeout: 8)
        return r.ok
    }

    /// Dial (or reuse) the connection. Concurrent callers share one attempt;
    /// a finished attempt is never reused, so reconnecting after a drop works.
    func connect() async throws {
        if state == .connected { return }
        if let t = connecting { return try await t.value }
        let t = Task { @MainActor [self] in
            do {
                try await self.establish()
                self.connecting = nil
            } catch {
                let e = error as? AppError
                self.lastErrorMfaLikely = e?.code == "mfa"
                self.setState(.error, error: e?.message ?? error.localizedDescription)
                self.connecting = nil
                throw error
            }
        }
        connecting = t
        try await t.value
    }

    private func establish() async throws {
        setState(.connecting)
        lastError = nil

        // A beam has no master: `tsh beams ssh` is the session, `tsh beams
        // exec` every other channel. Connected at once, so the file browser
        // can open beside a terminal not yet started.
        if transport == .beam {
            pushLog("$ \(Tools.tsh) \(beamArgs().joined(separator: " "))\n", "sys")
            setState(.connected)
            return
        }
        // `tsh ssh` performs its own MFA ceremony per session: the terminal is the session.
        if transport == .tsh {
            pushLog("$ \(Tools.tsh) \(tshArgs().joined(separator: " "))\n", "sys")
            pushLog("Per-session MFA: the prompt appears in the terminal.\n", "sys")
            setState(.connected)
            return
        }

        // Reuse a still-live master from a previous run.
        if FileManager.default.fileExists(atPath: controlPath) {
            if await checkMaster() {
                pushLog("Reusing existing control connection.\n", "sys")
                await afterConnect()
                return
            }
            // A socket with nothing listening: OpenSSH will not start a new
            // master on an existing path, so it has to go first.
            pushLog("Removing the dead control socket before reconnecting.\n", "sys")
            unlink(controlPath)
        }

        let args = spec.masterArgs(controlPath: controlPath)
        pushLog("$ ssh \(args.joined(separator: " "))\n", "sys")
        try await runMaster(args)
        await afterConnect()
    }

    /// Spawn the master on a pty and wait for its socket to answer.
    private func runMaster(_ args: [String]) async throws {
        let gate = ConnGate()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            gate.cont = cont
            let p: PTYProcess
            do {
                p = try PTYProcess(exe: Tools.ssh, args: args, env: procEnv(["TERM": "xterm-256color"]),
                                   cwd: NSHomeDirectory(), cols: 100, rows: 30)
            } catch {
                gate.finish(error)
                return
            }
            master = p
            p.onData = { [weak self] d in MainActor.assumeIsolated { self?.masterOutput(d) } }
            // The master runs in the foreground, so its exit means something:
            // before we are up, authentication or dialling failed; after, the
            // connection dropped.
            p.onExit = { [weak self, weak p] code in
                MainActor.assumeIsolated { self?.masterExited(p, code: code, gate: gate) }
            }
            // The master never prints "ready": poll the control socket.
            gate.poll = Task { @MainActor [weak self] in
                while !gate.settled {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !gate.settled, let self else { return }
                    if await self.checkMaster() { gate.finish(nil) }
                }
            }
            let timeout = spec.timeout ?? 120
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    let waiting = self?.state == .prompting
                    gate.finish(AppError("Connection timed out. " + (waiting
                        ? "Authentication is still waiting for input."
                        : "The host did not respond.")))
                }
            }
            gate.timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    private func masterOutput(_ d: Data) {
        let text = String(decoding: d, as: UTF8.self)
        pushLog(text, "out")
        if ConnText.isPrompt(text) {
            let lines = ConnText.stripAnsi(text).components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
            prompt = lines.last ?? text.trimmed
            setState(.prompting)
        }
    }

    private func masterExited(_ p: PTYProcess?, code: Int32, gate: ConnGate) {
        if master === p || p == nil { master = nil }
        if !gate.settled {
            let tail = log.filter { $0.stream == "out" }.suffix(14).map { $0.text }.joined()
            let sig = ConnRun.ptySignal(code).map { ", signal \(ConnRun.signalName($0))" } ?? ""
            var err = AppError(ConnText.cleanupError(tail) ?? "Connection failed (ssh exited with code \(code)\(sig))")
            // Lets the UI offer the tsh transport rather than a retry that fails the same way.
            if type == "teleport" && ConnText.looksLikeMfa(tail) { err.code = "mfa" }
            gate.finish(err)
        } else if state != .closed && master == nil {
            health.stop()
            setState(.error, error: "Connection closed")
            teardownChildren()
            connecting = nil
        }
    }

    /// `ssh -O check` every 15 s; asked twice (3 s apart) before believing a
    /// miss, because one slow check after a wake from sleep is not a dead master.
    private func startHealthCheck() {
        health.start(every: 15) { [weak self] in
            guard let self, !self.healthBusy else { return }
            self.healthBusy = true
            Task { @MainActor in
                defer { self.healthBusy = false }
                guard self.state == .connected else { return }
                if await self.checkMaster() { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.state == .connected else { return }
                if !(await self.checkMaster()) {
                    self.health.stop()
                    self.setState(.error, error: "Control connection lost")
                    self.teardownChildren()
                    self.connecting = nil
                }
            }
        }
    }

    private func afterConnect() async {
        setState(.connected)
        startHealthCheck()
        // Cheap identity probe over the mux; also warms the channel path.
        if let out = try? await exec(ConnText.identityProbe) {
            let parts = out.trimmed.components(separatedBy: "\n")
            info = ConnInfo(homeDir: parts.count > 0 ? parts[0].nilIfEmpty : nil,
                            user: parts.count > 1 ? parts[1].nilIfEmpty : nil,
                            hostname: parts.count > 2 ? parts[2].nilIfEmpty : nil)
            onEvent?(.info(id: id, info: info))
        }
    }

    /// Write the master's pty (answers password / passphrase / MFA prompts).
    func writeMaster(_ text: String) {
        master?.write(text)
    }

    // MARK: exec

    /// Run a command and report what happened; never throws. Default timeout 20 s.
    func execResult(_ command: String, timeout: TimeInterval? = nil) async -> ProcResult {
        await execRun(command, timeout: timeout).result
    }

    private func execRun(_ command: String, timeout: TimeInterval?) async -> ConnRunResult {
        let inv = spec.execInvocation(controlPath: controlPath, command: command)
        return await ConnRun.run(inv.exe, inv.args, env: procEnv(), timeout: timeout ?? 20)
    }

    /// The same run, with the failure (if any) put into words (`execResult`).
    func execReport(_ command: String, timeout: TimeInterval? = nil) async -> ExecResult {
        let started = Date()
        let rr = await execRun(command, timeout: timeout)
        let r = rr.result
        let ms = (Date().timeIntervalSince(started) * 1000).rounded()
        return ExecResult(code: r.code, stdout: r.out, stderr: r.err, durationMs: ms, timedOut: r.timedOut,
                          error: execError(r, signal: rr.signal))
    }

    /// stdout, or throws the reason (`exec`). `keepOutput`: return stdout+stderr
    /// even on failure when there is any (a ping that lost every packet).
    func exec(_ command: String, timeout: TimeInterval? = nil, keepOutput: Bool = false) async throws -> String {
        let r = await execReport(command, timeout: timeout)
        if let e = r.error {
            if keepOutput && !(r.stdout.isEmpty && r.stderr.isEmpty) { return r.stdout + r.stderr }
            throw AppError(e)
        }
        return r.stdout
    }

    /// `_execError`: why a remote command failed, without the command in it.
    func execError(_ r: ProcResult, signal: Int32? = nil) -> String? {
        if r.ok { return nil }
        let via = transport == .mux ? "ssh" : "tsh"
        let text = r.err.trimmed
        if !text.isEmpty {
            return text.count <= 400 ? text : (ConnText.firstProblem(text).nilIfEmpty ?? String(text.prefix(400)))
        }
        let place = label.isEmpty ? target : label
        if r.timedOut { return "\(place) did not answer within the time allowed." }
        if r.spawnError != nil { return "The \(via) client could not be found to run this." }
        if let signal { return "The command was killed on \(place) (\(ConnRun.signalName(signal)))." }
        return "The command exited \(r.code) on \(place) and printed no error."
    }

    // MARK: SFTP

    /// A fresh SFTP byte stream: `ssh -s sftp` over the master, `tsh ssh …
    /// sftp-server` (one MFA approval), or `tsh beams exec … sftp-server`.
    func openSFTPChannel() async throws -> ByteChannel {
        try await connect()
        if transport == .tsh {
            // Re-opening costs another approval, so a dropped channel waits for the user.
            if sftpClosedByPeer {
                sftpClosedByPeer = false
                throw AppError("The file channel closed. Press Refresh to reopen it (needs MFA approval).")
            }
            pushLog("Opening a file channel (approve MFA once).\n", "sys")
        }
        let inv = spec.sftpInvocation(controlPath: controlPath)
        let inner = try ProcessChannel(inv.exe, inv.args, env: procEnv())
        let ch = ConnByteChannel(inner)
        ch.ownerClosed = { [weak self, weak ch] byPeer in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let ch else { return }
                    let wasOpen = self.sftpChannels.contains { $0 === ch }
                    self.sftpChannels.removeAll { $0 === ch }
                    if wasOpen && byPeer && self.transport == .tsh { self.sftpClosedByPeer = true }
                }
            }
        }
        sftpChannels.append(ch)
        return ch
    }

    // MARK: terminals

    /// An interactive shell (or `options.command`) over the connection.
    func openTerminal(_ options: TerminalOptions) async throws -> RemoteTerminal {
        try await connect()
        let inv = spec.terminalInvocation(controlPath: controlPath, command: options.command)
        let p = try PTYProcess(exe: inv.exe, args: inv.args, env: procEnv(["TERM": "xterm-256color"]),
                               cwd: NSHomeDirectory(), cols: options.cols, rows: options.rows)
        let tid = options.id ?? uid("term")
        let kind = transport == .mux ? "ssh" : transport.rawValue
        let t = RemoteTerminal(id: tid, kind: kind, process: p, connection: self, cols: options.cols, rows: options.rows)
        terminals[tid] = t
        terminalIds.append(tid)
        if let path = options.remoteStartPath, !path.isEmpty {
            p.write("cd \(JSON.string(path).text())\n")
        }
        if let cmd = options.startupCommand, !cmd.isEmpty {
            var c = cmd
            while c.hasSuffix("\n") { c.removeLast() }
            p.write(c + "\n")
        }
        return t
    }

    func terminal(_ termId: String) -> RemoteTerminal? { terminals[termId] }

    func writeTerminal(_ termId: String, _ data: Data) { terminals[termId]?.write(data) }

    func resizeTerminal(_ termId: String, cols: Int, rows: Int) { terminals[termId]?.resize(cols: cols, rows: rows) }

    func closeTerminal(_ termId: String) {
        guard let t = terminals[termId] else { return }
        _ = stopLogging(termId)
        t.kill()
        terminals.removeValue(forKey: termId)
        terminalIds.removeAll { $0 == termId }
    }

    /// Called by a terminal whose program exited.
    func terminalEnded(_ termId: String, code: Int32) {
        if let t = terminals[termId], t.logPath != nil { _ = stopLogging(termId) }
        terminals.removeValue(forKey: termId)
        terminalIds.removeAll { $0 == termId }
        onEvent?(.terminalExit(id: id, termId: termId, code: code))
    }

    /// A command on this connection, on a pty the caller owns (tmux control
    /// mode). Not registered as a terminal; does not connect first.
    func spawnCommandPTY(_ command: String, cols: Int = 100, rows: Int = 30) throws -> PTYProcess {
        if command.isEmpty { throw AppError("no command given") }
        let exe: String, args: [String]
        switch transport {
        case .beam: (exe, args) = (Tools.tsh, beamArgs(command: command))
        case .tsh: (exe, args) = (Tools.tsh, tshArgs([], command: command))
        case .mux: (exe, args) = (Tools.ssh, spec.commandPtySshArgs(controlPath: controlPath, command: command))
        }
        return try PTYProcess(exe: exe, args: args, env: procEnv(["TERM": "xterm-256color"]),
                              cwd: NSHomeDirectory(), cols: cols, rows: rows)
    }

    /// A command on a beam over plain pipes (`spawnCommandPipe`): `tsh beams
    /// exec` never gives the far side a terminal, and a local pty only gets
    /// in the way. stdout and stderr both arrive on `onData` (background thread).
    func spawnCommandPipe(_ command: String, onData: @escaping @Sendable (Data) -> Void,
                          onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningProcess {
        if command.isEmpty { throw AppError("no command given") }
        return try RunningProcess(Tools.tsh, beamArgs(command: command), env: procEnv(), cwd: NSHomeDirectory(),
                                  onStdout: onData, onStderr: onData, onExit: onExit)
    }

    // MARK: session logging

    /// Tee a terminal's output to a file (escape sequences stripped).
    @discardableResult
    func startLogging(_ termId: String, path: String) throws -> String {
        guard let t = terminals[termId] else { throw AppError("No such terminal") }
        _ = stopLogging(termId)
        try t.startLog(path: path, label: label)
        logging[termId] = LogState(active: true, path: path)
        onEvent?(.logging(id: id, termId: termId, path: path, active: true))
        return path
    }

    @discardableResult
    func stopLogging(_ termId: String) -> String? {
        guard let t = terminals[termId], let p = t.stopLog() else { return nil }
        logging[termId] = nil
        onEvent?(.logging(id: id, termId: termId, path: p, active: false))
        return p
    }

    func loggingState(_ termId: String) -> LogState {
        terminals[termId]?.logState ?? LogState(active: false, path: nil)
    }

    /// The name the save dialog suggests: `<label>-<stamp>.log`.
    var defaultLogFileName: String {
        let safe = ConnText.replace(ConnText.re(#"[^\w.-]+"#), in: label, with: "_")
        let stamp = String(ConnClock.iso().replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-").prefix(19))
        return "\(safe)-\(stamp).log"
    }

    /// Best-effort cwd of the remote shell, for "follow terminal folder".
    /// Only over the mux: elsewhere every exec is an approval or an audit entry.
    func terminalCwd(_ termId: String) async -> String? {
        guard terminals[termId] != nil, transport == .mux else { return nil }
        guard let out = try? await exec(ConnText.cwdProbe, timeout: 8) else { return nil }
        let cwd = out.trimmed.components(separatedBy: "\n").last ?? ""
        return cwd.hasPrefix("/") ? cwd : nil
    }

    // MARK: rsync and tsh scp

    /// What `rsync -e` needs to ride this connection, or why it cannot.
    func rsyncTransport() -> RsyncTransport {
        switch transport {
        case .tsh:
            return RsyncTransport(ok: false, reason: "This node authenticates per session (MFA), so every rsync would raise its own prompt. Use the file browser\u{2019}s own synchronise for it.")
        case .beam:
            return RsyncTransport(ok: false, reason: "A beam is reached through tsh rather than ssh, so rsync cannot ride it.")
        case .mux:
            break
        }
        if state != .connected {
            return RsyncTransport(ok: false, reason: "Connect the session first: rsync rides the connection it already holds.")
        }
        let argv = ["ssh"] + sshArgs(["-o", "ControlMaster=no"])
        return RsyncTransport(ok: true, reason: nil, target: target, argv: argv, shell: argv.joined(separator: " "))
    }

    enum ScpDirection { case upload, download }

    /// Copy with `tsh scp` on a pty (each call does its own MFA ceremony).
    /// Upload: `localPaths` → `remotePaths[0]`. Download: `remotePaths` → `localPaths[0]`.
    func tshScp(_ direction: ScpDirection, localPaths: [String], remotePaths: [String], recursive: Bool = true,
                onOutput: ((String) -> Void)? = nil) async throws -> String {
        let args = spec.tshScpArgs(upload: direction == .upload, localPaths: localPaths, remotePaths: remotePaths,
                                   recursive: recursive)
        let p = try PTYProcess(exe: Tools.tsh, args: args, env: procEnv(["TERM": "xterm-256color"]), cols: 100, rows: 24)
        var out = ""
        return try await withCheckedThrowingContinuation { cont in
            p.onData = { [weak self] d in
                MainActor.assumeIsolated {
                    let s = String(decoding: d, as: UTF8.self)
                    out += s
                    if out.count > 20000 { out = String(out.suffix(20000)) }
                    onOutput?(s)
                    self?.onEvent?(.log(id: self?.id ?? "", line: ConnLogLine(t: nowMs(), text: s, stream: "out")))
                }
            }
            p.onExit = { code in
                MainActor.assumeIsolated {
                    if code == 0 { cont.resume(returning: out); return }
                    let clean = ConnText.flatten(out)
                    let msg = ConnText.cleanupError(clean) ?? String(clean.suffix(200)).nilIfEmpty ?? "tsh scp failed (\(code))"
                    cont.resume(throwing: AppError(msg))
                }
            }
        }
    }

    // MARK: port forwarding

    private func controlCommand(_ op: String, kind: String, spec s: String) async throws -> String {
        let r = await Proc.run(Tools.ssh, sshArgs(["-O", op, "-\(kind)", s, target]), env: procEnv(), timeout: 15)
        let out = (r.err + r.out).trimmed
        if !r.ok { throw AppError(ConnText.cleanupError(out) ?? out.nilIfEmpty ?? r.spawnError ?? "ssh -O \(op) failed") }
        return out
    }

    /// Hold a tunnel with its own process; it fails fast if the port is taken.
    private func holdTunnel(_ exe: String, _ args: [String], settle: TimeInterval) async throws -> RunningProcess {
        let gate = ConnGate()
        let errBuf = LockedText()
        var proc: RunningProcess?
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            gate.cont = cont
            do {
                proc = try RunningProcess(exe, args, env: procEnv(), onStdout: { _ in }, onStderr: { d in
                    errBuf.append(String(decoding: d, as: UTF8.self))
                }, onExit: { code in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            gate.finish(AppError(ConnText.cleanupError(errBuf.text) ?? "tunnel failed (exit \(code))"))
                        }
                    }
                })
            } catch {
                gate.finish(error)
                return
            }
            let work = DispatchWorkItem { MainActor.assumeIsolated { gate.finish(nil) } }
            gate.timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        }
        return proc!
    }

    /// Add -L/-R/-D: `ssh -O forward` on the master (no extra authentication),
    /// or a `tsh ssh -N` process on the tsh transport. Beams refuse.
    func addForward(_ fwd: ForwardSpec) async throws -> Forward {
        try await connect()
        let s = fwd.specString
        if forwards.contains(where: { $0.kind == fwd.kind && $0.spec == s }) {
            throw AppError("That forward already exists")
        }
        if transport == .beam {
            throw AppError("A beam does not take port forwards — publish the service instead (right-click the beam → Publish a service…).")
        }
        var proc: RunningProcess?
        if transport == .tsh {
            proc = try await holdTunnel(Tools.tsh, tshArgs(["-\(fwd.kind)", s, "-N"]), settle: 1.5)
        } else {
            _ = try await controlCommand("forward", kind: fwd.kind, spec: s)
        }
        Connection.fwdSeq += 1
        let rec = Forward(id: "fwd\(Connection.fwdSeq)", kind: fwd.kind, spec: s,
                          bindAddr: fwd.bindAddr?.nilIfEmpty ?? (fwd.kind == "R" ? "" : "localhost"),
                          bindPort: fwd.bindPort, destHost: fwd.destHost?.nilIfEmpty, destPort: fwd.destPort,
                          label: fwd.label ?? "", createdAt: nowMs(), connId: id, connLabel: label)
        if let proc { forwardProcs[rec.id] = proc }
        forwards.append(rec)
        onEvent?(.forwards(id: id, forwards: forwards))
        return rec
    }

    @discardableResult
    func removeForward(_ fwdId: String) async -> Bool {
        guard let f = forwards.first(where: { $0.id == fwdId }) else { return false }
        if let p = forwardProcs.removeValue(forKey: fwdId) {
            p.terminate()
        } else {
            // `-O cancel` fails if the master already dropped it; either way it leaves the list.
            _ = try? await controlCommand("cancel", kind: f.kind, spec: f.spec)
        }
        forwards.removeAll { $0.id == fwdId }
        onEvent?(.forwards(id: id, forwards: forwards))
        return true
    }

    func listForwards() -> [Forward] { forwards }

    // MARK: host facts

    /// "Server profile": distro, kernel, arch, CPU, memory, disk,
    /// virtualisation, init and package manager in one round trip. Cached
    /// until `refresh`. A partial answer is kept, with the reason in `partial`.
    func fetchServerInfo(refresh: Bool = false) async throws -> ServerInfo {
        if let serverInfo, !refresh { return serverInfo }
        // Refused only where tsh was chosen *for* per-session MFA.
        if transport == .tsh && !tshByNecessity {
            throw AppError("Server profile needs a command session, which on a per-session-MFA host means another approval. Run it from the terminal instead.")
        }
        try await connect()
        let r = await execReport(ConnText.infoScript, timeout: 25)
        let values = ConnText.parseKeyValues(r.stdout)
        if values.isEmpty {
            throw AppError(r.error ?? "\(label.isEmpty ? target : label) ran the profile probe but printed nothing. A restricted shell or a forced command will do that.")
        }
        let info = ConnText.serverInfo(from: values, partial: r.error)
        serverInfo = info
        onEvent?(.serverInfo(id: id, info: info))
        return info
    }

    /// What this account has typed on this host, read from the history files
    /// (one exec for all of them), newest first, each command once.
    func shellHistory(limit: Int = 1000, refresh: Bool = false) async throws -> ShellHistory {
        if let historyCache, !refresh { return historyCache }
        let r = await execReport(ConnText.historyScript, timeout: 25)
        let entries = ConnText.parseHistory(r.stdout)
        if entries.isEmpty, let e = r.error { throw AppError(e) }
        let h = ShellHistory(entries: ConnText.dedupeNewestFirst(entries, limit: limit),
                             truncated: entries.count >= 4000, at: nowMs())
        historyCache = h
        return h
    }

    // MARK: teardown

    private func teardownChildren() {
        for tid in Array(terminals.keys) { closeTerminal(tid) }
        for (_, p) in forwardProcs { p.terminate() }
        forwardProcs = [:]
        if !forwards.isEmpty {
            forwards = []
            onEvent?(.forwards(id: id, forwards: []))
        }
        let chans = sftpChannels
        sftpChannels = []
        chans.forEach { $0.close() }
    }

    /// Close everything and the master (`ssh -O exit`), and remove the socket.
    func disconnect() async {
        setState(.closed)
        health.stop()
        teardownChildren()
        if transport == .mux {
            _ = await Proc.run(Tools.ssh, sshArgs(["-O", "exit", target]), env: procEnv(), timeout: 6)
        }
        master?.terminate()
        master = nil
        connecting = nil
        if FileManager.default.fileExists(atPath: controlPath) { unlink(controlPath) }
    }

    /// Quitting, step 1 (main actor): mark closed, stop the health check and
    /// tear down children. Returns what step 2 needs to run off the main thread.
    func beginShutdown() -> (args: [String], env: [String: String?], master: PTYProcess?, controlPath: String)? {
        setState(.closed)
        health.stop()
        teardownChildren()
        connecting = nil
        let m = master
        master = nil
        guard transport == .mux else { m?.terminate(grace: 0.5); return nil }
        return (sshArgs(["-O", "exit", target]), procEnv(), m, controlPath)
    }
}

/// Settles a continuation once, whichever of exit / poll / timeout comes first.
@MainActor
final class ConnGate {
    var cont: CheckedContinuation<Void, Error>?
    private(set) var settled = false
    var poll: Task<Void, Never>?
    var timeout: DispatchWorkItem?

    func finish(_ error: Error?) {
        guard !settled else { return }
        settled = true
        poll?.cancel()
        timeout?.cancel()
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
        cont = nil
    }
}

/// Text collected from a background thread.
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = ""
    func append(_ s: String) { lock.lock(); buf += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buf }
}

/// A ByteChannel that tells its connection when it closes, and whether the
/// far side closed it (vs. the consumer or a teardown).
final class ConnByteChannel: ByteChannel, @unchecked Sendable {
    private let inner: ProcessChannel
    private let lock = NSLock()
    private var closeHandler: (@Sendable (String?) -> Void)?
    private var closedWith: String??
    private var closedByUs = false
    var ownerClosed: (@Sendable (Bool) -> Void)?

    init(_ inner: ProcessChannel) {
        self.inner = inner
        inner.onClose = { [weak self] reason in
            guard let self else { return }
            self.lock.lock()
            self.closedWith = .some(reason)
            let h = self.closeHandler
            let byPeer = !self.closedByUs
            let owner = self.ownerClosed
            self.lock.unlock()
            owner?(byPeer)
            h?(reason)
        }
    }

    var onData: (@Sendable (Data) -> Void)? {
        get { inner.onData }
        set { inner.onData = newValue }
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

    /// What the far side wrote to stderr ("subsystem request failed …").
    var stderrText: String { inner.stderrText }
    var pid: Int32 { inner.pid }

    func write(_ data: Data) { inner.write(data) }

    func close() {
        lock.lock(); closedByUs = true; lock.unlock()
        inner.close()
    }
}
