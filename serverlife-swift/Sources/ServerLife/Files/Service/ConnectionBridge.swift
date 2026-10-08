import Foundation

/// What the files service needs to know about an open connection.
///
/// Everything here comes from the connections owner's `ConnectionManager`;
/// this is the only file that touches it, so the files service has one seam
/// (and tests replace the hooks below rather than the manager).
struct FilesConn: Sendable {
    var id: String
    /// What the UI calls it — the transfer labels and download history use it.
    var label: String
    /// "teleport", "ssh", "beam", …
    var type: String
    /// "mux" (ssh over the ControlMaster), "tsh" (per-session MFA / leaf
    /// cluster), "beam".
    var transport: String
    /// "ubuntu@node.cluster" or an ssh alias.
    var target: String
    var host: Host
    /// The login asked for, or the remote user the identity probe found
    /// (`conn.spec.login || conn.remoteUser`).
    var login: String?
    /// The remote home the identity probe found, if it has run.
    var homeDir: String?
}

@MainActor
enum FilesBridge {
    /// Open a fresh SFTP byte stream for a connection.
    static var openChannel: (String) async throws -> ByteChannel = { connId in
        try await ConnectionManager.shared.openSFTPChannel(connId)
    }

    /// Run a command on a connection and return its stdout. Throws the connection layer's own explanation when the command fails.
    static var exec: (String, String, TimeInterval) async throws -> String = { connId, cmd, timeout in
        try await ConnectionManager.shared.exec(connId, cmd, timeout: timeout).stdout
    }

    /// The connection, or nil when it is not open any more.
    static var connection: (String) -> FilesConn? = { connId in
        guard let c = ConnectionManager.shared.connection(connId) else { return nil }
        return FilesConn(id: connId, label: c.label, type: c.type, transport: c.transportKind, target: c.target,
                         host: c.host, login: c.login?.nilIfEmpty ?? c.remoteUser, homeDir: c.homeDir)
    }

    static func require(_ connId: String) throws -> FilesConn {
        guard let c = connection(connId) else { throw AppError("That connection is not open any more.") }
        return c
    }

    /// `conn.exec(cmd)` from the original: stdout, or a thrown error when the
    /// command failed.
    static func run(_ connId: String, _ cmd: String, timeout: TimeInterval = 20) async throws -> String {
        try await exec(connId, cmd, timeout)
    }

    /// `rsyncTransport()` of the connection.
    static var rsyncTransport: (String) -> RsyncTransport? = { connId in
        ConnectionManager.shared.connection(connId)?.rsyncTransport()
    }
}
