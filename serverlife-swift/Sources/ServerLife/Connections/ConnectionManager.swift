import Foundation
import Observation

// MARK: - preferences the connection layer resolves

extension Store {
    /// Global agent forwarding (settings.agentForward).
    var connAgentForward: Bool {
        get { setting("agentForward", false) }
        set { setSetting("agentForward", newValue) }
    }

    /// Hosts remembered as needing per-session MFA (settings.mfaHosts, host ids).
    var connMfaHosts: [String] {
        get { setting("mfaHosts", [String]()) }
        set { setSetting("mfaHosts", newValue) }
    }

    /// The MFA method tsh is told to use (settings.mfaMode, default "platform").
    var connMfaMode: String {
        get { setting("mfaMode", "platform") }
        set { setSetting("mfaMode", newValue) }
    }
}

/// Per-host preferences that decide how a connection is made.
@MainActor
enum ConnPrefs {
    /// `agentForwardFor`: the host's own setting, then its cluster's, then the
    /// global one. A missing key at a level means "no opinion".
    static func agentForward(for host: Host, settings: JSON? = nil) -> Bool {
        let s = settings ?? Store.shared.settings
        let hk = host.prefKey
        if !hk.isEmpty, let v = s["agentForwardHosts"].object?[hk] { return v.truthy }
        let ck = host.clusterPrefKey
        if !ck.isEmpty, let v = s["agentForwardClusters"].object?[ck] { return v.truthy }
        return s["agentForward"].truthy
    }

    /// The login explicitly remembered for a host (settings.hostUsers).
    static func explicitLogin(for host: Host, settings: JSON? = nil) -> String? {
        let s = settings ?? Store.shared.settings
        return s["hostUsers"][host.prefKey].string?.nilIfEmpty
    }

    /// `withHostPrefs`: fill what the host has preferences for, never
    /// overriding what the caller passed.
    static func apply(to opts: ConnectOptions, host: Host, settings: JSON? = nil) -> ConnectOptions {
        var o = opts
        if o.agentForward == nil { o.agentForward = agentForward(for: host, settings: settings) }
        if o.login?.isEmpty ?? true, let l = explicitLogin(for: host, settings: settings) { o.login = l }
        return o
    }

    /// Whether a host is remembered as needing per-session MFA.
    static func isMfaHost(_ host: Host) -> Bool { Store.shared.connMfaHosts.contains(host.id) }

    /// Remember (or forget) that a host needs per-session MFA, so the next
    /// connection goes straight to tsh. (The sidebar shows the status message.)
    static func setMfaHost(_ host: Host, _ remember: Bool) {
        var cur = Store.shared.connMfaHosts
        if remember { if !cur.contains(host.id) { cur.append(host.id) } } else { cur.removeAll { $0 == host.id } }
        Store.shared.connMfaHosts = cur
    }
}

// MARK: - manager

/// Every connection, by id (connections.js `ConnectionManager` plus the
/// `conn:*`, `term:*`, `forward:*` handlers of main.js).
@MainActor
@Observable
final class ConnectionManager {
    static let shared = ConnectionManager()

    /// In creation order.
    private(set) var connections: [Connection] = []

    @ObservationIgnored private var listeners: [UUID: (ConnEvent) -> Void] = [:]
    /// Asked before a connection is removed (files-service stops its watchers).
    @ObservationIgnored var willRemove: [(String) async -> Void] = []
    /// History recording. Defaults to writing `history` exactly as store.js
    /// `startHistory`/`endHistory` do; the data owner may replace these.
    @ObservationIgnored var startHistory: (JSON) -> String? = ConnectionManager.defaultStartHistory
    @ObservationIgnored var endHistory: (String, String?) -> Void = ConnectionManager.defaultEndHistory

    /// Where generated per-cluster ssh_configs go.
    var configDir: String { ConnRuntime.configDir }

    // MARK: events

    /// Subscribe to pushes (state, log, info, forwards, serverInfo, logging,
    /// terminalExit, changed). Returns a token for `unsubscribe`.
    @discardableResult
    func subscribe(_ f: @escaping (ConnEvent) -> Void) -> UUID {
        let k = UUID()
        listeners[k] = f
        return k
    }

    func unsubscribe(_ token: UUID) { listeners[token] = nil }

    private func emit(_ e: ConnEvent) { for l in listeners.values { l(e) } }

    // MARK: lookup

    func connection(_ id: String) -> Connection? { connections.first { $0.id == id } }

    /// `requireConn`.
    func require(_ id: String) throws -> Connection {
        guard let c = connection(id) else { throw AppError("No such connection: " + id) }
        return c
    }

    /// `findConnectionForHost`: an open (or opening) connection to this host as this login.
    func find(host: Host, login: String?) -> Connection? {
        connections.first { c in
            c.hostId == host.id && (c.login?.nilIfEmpty) == (login?.nilIfEmpty)
                && [.connected, .connecting, .prompting, .idle].contains(c.state)
        }
    }

    /// `targetConnection`'s reuse rule: something open that is the same host
    /// (by name or alias), cluster and login, or the same beam.
    func findOpen(name: String?, beam: String? = nil, cluster: String? = nil, login: String? = nil) -> Connection? {
        for c in connections where [.connected, .connecting, .idle].contains(c.state) {
            if let beam, c.transport == .beam, c.spec.beamName == beam { return c }
            if let name, beam == nil {
                let node = c.spec.node ?? c.spec.host
                let n = node?.name.nilIfEmpty ?? node?.alias ?? c.target
                if n == name && (cluster == nil || node?.cluster == cluster) && (login == nil || c.login == login) {
                    return c
                }
            }
        }
        return nil
    }

    /// Every active tunnel across every connection.
    func allForwards() -> [Forward] { connections.flatMap { $0.forwards } }

    /// `conn:list`: the shape the control socket and automation report.
    func list() -> [JSON] {
        connections.map { c in
            ["id": .string(c.id), "label": .string(c.label), "type": .string(c.type), "target": .string(c.target),
             "state": .string(c.state.rawValue), "error": JSON(c.lastError), "homeDir": JSON(c.homeDir),
             "user": JSON(c.remoteUser), "hostname": JSON(c.remoteHostname),
             "transport": .string(c.transportKind), "transportForced": JSON(c.transportForced),
             "terminals": JSON(c.terminalIds), "forwards": .array(c.forwards.map { $0.json })]
        }
    }

    // MARK: create / connect / disconnect

    /// Build (but do not dial) a connection for a host descriptor. Teleport
    /// nodes get a freshly generated tsh ssh_config; leaf-cluster nodes and
    /// machines with no ssh client are forced onto tsh (`transportForced`).
    func create(host: Host, options: ConnectOptions = ConnectOptions()) async throws -> Connection {
        let opts = ConnPrefs.apply(to: options, host: host)
        let x11Asked = opts.x11.map { $0 != "off" && !$0.isEmpty } ?? false
        if opts.reuse && !x11Asked && opts.transport == nil, let c = find(host: host, login: opts.login) {
            return c
        }
        let spec = try await buildSpec(host: host, opts: opts)
        return register(Connection(spec: spec))
    }

    /// The spec `create` builds (separated for testing the non-spawning branches).
    func buildSpec(host: Host, opts: ConnectOptions) async throws -> ConnSpec {
        func common(_ s: inout ConnSpec, transport: ConnTransport) {
            s.login = opts.login?.nilIfEmpty
            s.x11 = opts.x11?.nilIfEmpty ?? "off"
            s.agentForward = opts.agentForward ?? false
            s.compression = opts.compression ?? false
            s.transport = transport
            s.mfaMode = opts.mfaMode?.nilIfEmpty
            s.timeout = opts.timeout
            s.x11Timeout = opts.x11Timeout
        }

        // A beam: no ssh_config, no target, no OpenSSH at all.
        if host.type == Host.beam {
            var s = ConnSpec(type: "beam", target: host.name, label: "\(host.name) (beam)")
            s.node = host
            s.beamName = host.name
            s.beamProxy = host.proxy ?? ""
            s.transport = .beam
            return s
        }

        var transport: ConnTransport = opts.transport == "tsh" ? .tsh : .mux
        let haveSsh = Tools.sshAvailable
        if !haveSsh {
            if host.type != Host.teleport {
                throw AppError("No OpenSSH client found on this machine, and a plain SSH host needs one. Teleport nodes work without it.")
            }
            transport = .tsh
        }

        if host.type == Host.teleport {
            var leafForced = false
            if transport != .tsh,
               await TeleportSSH.isLeafCluster(proxy: host.proxy, cluster: host.cluster, home: host.home) {
                transport = .tsh
                leafForced = true
            }
            let configFile = transport == .tsh ? nil
                : try await TeleportSSH.writeClusterSshConfig(dir: configDir, proxy: host.proxy, cluster: host.cluster,
                                                              home: host.home)
            let target = TeleportSSH.sshTarget(host, login: opts.login?.nilIfEmpty)
            let cl = host.cluster ?? ""
            let label = host.ambiguous == true && host.uuid?.isEmpty == false
                ? "\(host.name) (\(cl)) · \(String(host.uuid!.prefix(8)))"
                : "\(host.name) (\(cl))"
            var s = ConnSpec(type: "teleport", target: target, label: label)
            s.configFile = configFile
            s.node = host
            common(&s, transport: transport)
            s.transportForced = !haveSsh ? "no-ssh" : (leafForced ? "leaf" : nil)
            return s
        }

        if let d = host.direct {
            // A server defined in the app: the details go on the command line.
            let user = opts.login?.nilIfEmpty ?? d.user?.nilIfEmpty
            let target = user.map { "\($0)@\(d.hostname)" } ?? d.hostname
            var s = ConnSpec(type: "ssh", target: target,
                             label: host.name.nilIfEmpty ?? host.alias?.nilIfEmpty ?? d.hostname)
            s.direct = d
            s.host = host
            common(&s, transport: transport)
            return s
        }

        let alias = host.alias?.nilIfEmpty ?? host.name
        let login = opts.login?.nilIfEmpty
        var s = ConnSpec(type: "ssh", target: login.map { "\($0)@\(alias)" } ?? alias,
                         label: alias + (login.map { " (\($0))" } ?? ""))
        // An alias from an extra config file only exists inside it: `ssh -F`.
        s.configFile = host.configFile?.nilIfEmpty
        s.proxyJump = host.proxyJump?.nilIfEmpty
        s.host = host
        common(&s, transport: transport)
        return s
    }

    /// Track a connection and forward its events.
    @discardableResult
    func register(_ c: Connection) -> Connection {
        connections.append(c)
        c.onEvent = { [weak self] e in self?.emit(e) }
        emit(.changed)
        return c
    }

    /// `conn:connect`: dial, and record the attempt in the history (failed
    /// attempts too). A failure that looks like per-session MFA throws an
    /// AppError with code "mfa" (the original appended " [mfa]").
    func connect(_ id: String) async throws {
        let c = try require(id)
        do {
            try await c.connect()
        } catch {
            if let h = startHistory(c.historyEntry) { endHistory(h, (error as? AppError)?.message ?? error.localizedDescription) }
            throw error
        }
        if c.historyId == nil { c.historyId = startHistory(c.historyEntry) }
    }

    /// `conn:disconnect`: end the history entry, let others let go, tear down.
    func disconnect(_ id: String) {
        Task { await disconnectAndWait(id) }
    }

    func disconnectAndWait(_ id: String) async {
        guard let c = connection(id) else { return }
        if let h = c.historyId { endHistory(h, nil); c.historyId = nil }
        for f in willRemove { await f(id) }
        await c.disconnect()
        connections.removeAll { $0.id == id }
        emit(.changed)
    }

    /// Tear everything down on the way out: every master told to exit in
    /// parallel off the main thread, with an overall cap (the original's
    /// `Promise.all` of disconnects). Blocks for at most `cap` seconds.
    func shutdown(cap: TimeInterval = 6) {
        let jobs = connections.compactMap { $0.beginShutdown() }
        connections = []
        guard !jobs.isEmpty else { return }
        let group = DispatchGroup()
        let ssh = Tools.ssh
        for j in jobs {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Proc.runSync(ssh, j.args, env: j.env, timeout: max(1, cap - 1))
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + cap)
        for j in jobs {
            j.master?.terminate(grace: 0.5)
            if FileManager.default.fileExists(atPath: j.controlPath) { unlink(j.controlPath) }
        }
    }

    // MARK: per-id conveniences (the IPC surface)

    func writeMaster(_ id: String, _ text: String) { connection(id)?.writeMaster(text) }

    /// Run a command; throws the reason on failure (as `conn:exec`). The
    /// result carries code, stdout, stderr and durationMs.
    func exec(_ id: String, _ command: String, timeout: TimeInterval? = nil) async throws -> ExecResult {
        let c = try require(id)
        let r = await c.execReport(command, timeout: timeout)
        if let e = r.error { throw AppError(e) }
        return r
    }

    /// The same, never throwing for a failed command (only for a missing connection).
    func execResult(_ id: String, _ command: String, timeout: TimeInterval? = nil) async throws -> ExecResult {
        try await require(id).execReport(command, timeout: timeout)
    }

    func openSFTPChannel(_ id: String) async throws -> ByteChannel {
        try await require(id).openSFTPChannel()
    }

    func openTerminal(_ id: String, options: TerminalOptions) async throws -> TerminalBackend {
        try await require(id).openTerminal(options)
    }

    func addForward(_ id: String, _ fwd: ForwardSpec) async throws -> Forward {
        try await require(id).addForward(fwd)
    }

    func removeForward(_ id: String, _ fwdId: String) async throws {
        _ = try await require(id).removeForward(fwdId)
    }

    /// `forward:list`: one connection's, or every one's.
    func listForwards(_ id: String?) throws -> [Forward] {
        if let id { return try require(id).forwards }
        return allForwards()
    }

    func serverInfo(_ id: String, refresh: Bool = false) async throws -> ServerInfo {
        try await require(id).fetchServerInfo(refresh: refresh)
    }

    func shellHistory(_ id: String, limit: Int = 1000, refresh: Bool = false) async throws -> ShellHistory {
        try await require(id).shellHistory(limit: limit, refresh: refresh)
    }

    @discardableResult
    func startLog(_ id: String, termId: String, path: String) throws -> String {
        try require(id).startLogging(termId, path: path)
    }

    @discardableResult
    func stopLog(_ id: String, termId: String) throws -> String? {
        try require(id).stopLogging(termId)
    }

    func logState(_ id: String, termId: String) throws -> LogState {
        try require(id).loggingState(termId)
    }

    func terminalCwd(_ id: String, termId: String) async -> String? {
        await connection(id)?.terminalCwd(termId)
    }

    func x11Status() -> X11Status { X11Status.current() }
    func toolsStatus() -> JSON { ToolsStatus.current }
    func authProbe(target: String, options: AuthProbe.Options = AuthProbe.Options()) async -> AuthProbe.Result {
        await AuthProbe.run(target: target, options)
    }

    // MARK: default history recording (store.js startHistory / endHistory, in Data/)

    static func defaultStartHistory(_ entry: JSON) -> String? {
        Store.shared.startHistory(entry)["id"].string
    }

    static func defaultEndHistory(_ id: String, _ error: String?) {
        Store.shared.endHistory(id, error: error)
    }
}
