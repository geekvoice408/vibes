import Foundation

/// Everything Sessions asks of the connection layer, in one place
/// (`ConnectionManager` / `LocalShells`, owned by Connections). Reads go
/// through the observable `Connection`, so a SwiftUI view that reads
/// `SessConn.state(id)` redraws when it changes.
@MainActor
enum SessConn {
    struct Created {
        var id: String
        var label: String
        var target: String
        var type: String
        var transport: String
        var transportForced: String?
    }

    static var cm: ConnectionManager { ConnectionManager.shared }

    static func create(_ host: Host, login: String?, x11: String? = nil, transport: String? = nil,
                       mfaMode: String? = nil) async throws -> Created {
        var o = ConnectOptions()
        o.login = login
        o.x11 = x11
        o.transport = transport
        o.mfaMode = mfaMode
        let c = try await cm.create(host: host, options: o)
        return Created(id: c.id, label: c.label, target: c.target, type: c.type, transport: c.transportKind,
                       transportForced: c.transportForced)
    }

    static func connect(_ id: String) async throws { try await cm.connect(id) }
    static func disconnect(_ id: String) { cm.disconnect(id) }

    private static func c(_ id: String?) -> Connection? { id.flatMap { cm.connection($0) } }

    static func exists(_ id: String?) -> Bool { c(id) != nil }
    /// idle | connecting | prompting | connected | error | closed
    static func state(_ id: String?) -> String { c(id)?.state.rawValue ?? "closed" }
    static func label(_ id: String?) -> String? { c(id)?.label }
    static func target(_ id: String?) -> String? { c(id)?.target }
    /// teleport | ssh | beam
    static func type(_ id: String?) -> String? { c(id)?.type }
    /// mux | tsh | beam
    static func transport(_ id: String?) -> String? { c(id)?.transportKind }
    static func transportForced(_ id: String?) -> String? { c(id)?.transportForced }
    static func lastError(_ id: String?) -> String? { c(id)?.lastError }
    static func homeDir(_ id: String?) -> String? { c(id)?.homeDir }
    /// The node's hostname as the far side reported it (no cluster suffix).
    static func hostname(_ id: String?) -> String? { c(id)?.remoteHostname }
    static func cluster(_ id: String?) -> String? { c(id)?.host.cluster }
    static func user(_ id: String?) -> String? { c(id)?.login ?? c(id)?.remoteUser }
    static func remoteUser(_ id: String?) -> String? { c(id)?.remoteUser }
    static func mfaMode(_ id: String?) -> String? { c(id)?.spec.mfaMode }

    /// The connection log: master output and the app's own notes.
    static func log(_ id: String?) -> [(stream: String, text: String)] { (c(id)?.log ?? []).map { ($0.stream, $0.text) } }
    static func logText(_ id: String?) -> String { (c(id)?.log ?? []).map(\.text).joined() }

    /// Answer a password / passphrase / MFA prompt on the master.
    static func writeMaster(_ id: String, _ text: String) { cm.writeMaster(id, text) }

    static func openTerminal(_ id: String, cols: Int, rows: Int) async throws -> TerminalBackend {
        var o = TerminalOptions()
        o.cols = cols
        o.rows = rows
        return try await cm.openTerminal(id, options: o)
    }

    /// An open connection to this host as this login, if there is one.
    static func find(host: Host, login: String?) -> String? { cm.find(host: host, login: login)?.id }

    /// Session logging rides the remote terminal (escape sequences stripped).
    static func termId(_ b: TerminalBackend?) -> String? { (b as? RemoteTerminal)?.id }
    static func startLog(_ id: String, termId: String, path: String) throws -> String { try cm.startLog(id, termId: termId, path: path) }
    static func stopLog(_ id: String, termId: String) -> String? { (try? cm.stopLog(id, termId: termId)) ?? nil }
    static func logActive(_ id: String?, termId: String?) -> Bool {
        guard let id, let termId else { return false }
        return (try? cm.logState(id, termId: termId))?.active ?? false
    }
    static func defaultLogFileName(_ id: String) -> String? { c(id)?.defaultLogFileName }

    static func openLocal(shell: String?, blank: Bool, cwd: String?, cols: Int, rows: Int, command: String? = nil,
                          args: [String]? = nil, env: [String: String] = [:]) throws -> (backend: TerminalBackend, shell: String) {
        var e: [String: String?] = [:]
        for (k, v) in env { e[k] = v }
        let s = try LocalShells.shared.openSession(shell: shell, blank: blank, cwd: cwd, cols: cols, rows: rows,
                                                   command: command, args: args, env: e)
        return (s.backend, s.shell)
    }

    static func shells() -> [ShellInfo] { LocalShells.shared.shells() }
}
