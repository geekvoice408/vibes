import Foundation

// Value types of the connection layer (connections.js, local.js, authprobe.js).

/// `idle|connecting|prompting|connected|error|closed`, as connections.js.
enum ConnState: String, Sendable {
    case idle, connecting, prompting, connected, error, closed
}

/// How a connection reaches its host.
///
/// - `mux`: OpenSSH ControlMaster (through `tsh proxy ssh` for a Teleport
///   node): one authentication serves every channel.
/// - `tsh`: `tsh ssh` directly — per-session MFA, leaf clusters, no ssh client.
/// - `beam`: `tsh beams ssh` / `tsh beams exec`.
enum ConnTransport: String, Sendable {
    case mux, tsh, beam
}

/// Options for `ConnectionManager.create` (`manager.create(host, opts)` plus
/// `withHostPrefs`). nil means "no opinion": the host's preferences decide.
struct ConnectOptions {
    var login: String?
    /// "trusted" (-Y), "untrusted" (-X), or nil/"off".
    var x11: String?
    /// "tsh" to dial with `tsh ssh` (per-session MFA); nil for the shared connection.
    var transport: String?
    /// `--mfa-mode=` for tsh ("platform", "browser", "otp", …).
    var mfaMode: String?
    /// nil → resolved host → cluster → global (`agentForwardFor`).
    var agentForward: Bool?
    var compression: Bool?
    /// Reuse an open connection to the same host and login when there is one
    /// (`openHost`'s `reuse`). Never applies with x11 or a transport asked for,
    /// because those are negotiated on the master. Default false: create
    /// always creates, like `manager.create`.
    var reuse: Bool = false
    /// Seconds to wait for the master before giving up (spec.timeout; default 120).
    var timeout: TimeInterval?
    /// ForwardX11Timeout (spec.x11Timeout; default "596h").
    var x11Timeout: String?

    init(login: String? = nil, x11: String? = nil, transport: String? = nil, mfaMode: String? = nil,
         agentForward: Bool? = nil, compression: Bool? = nil, reuse: Bool = false,
         timeout: TimeInterval? = nil, x11Timeout: String? = nil) {
        self.login = login; self.x11 = x11; self.transport = transport; self.mfaMode = mfaMode
        self.agentForward = agentForward; self.compression = compression; self.reuse = reuse
        self.timeout = timeout; self.x11Timeout = x11Timeout
    }
}

/// One line (chunk) of a connection's log. `stream` is "out" (the master's
/// pty) or "sys" (what the app itself says).
struct ConnLogLine: Identifiable, Sendable, Equatable {
    let id = UUID()
    var t: Double
    var text: String
    var stream: String
}

/// What the identity probe found after connecting (`conn:info`).
struct ConnInfo: Sendable, Equatable {
    var homeDir: String?
    var user: String?
    var hostname: String?
}

/// The result of a command run over a connection.
struct ExecResult: Sendable {
    var code: Int32
    var stdout: String
    var stderr: String
    var durationMs: Double
    var timedOut: Bool = false
    /// Why it failed, in words that do not contain the command (`_execError`);
    /// nil when it succeeded.
    var error: String?
    var ok: Bool { error == nil }
}

/// Options for a remote terminal (`term:open`).
struct TerminalOptions {
    /// The terminal's id (for logging); generated when nil.
    var id: String?
    var cols: Int = 100
    var rows: Int = 30
    /// Run this instead of a login shell (`openTerminal({command})`).
    var command: String?
    /// Typed into the shell once it starts, as `connectPane` did.
    var startupCommand: String?
    /// `cd`'d into once the shell starts, as `connectPane` did.
    var remoteStartPath: String?

    init(id: String? = nil, cols: Int = 100, rows: Int = 30, command: String? = nil,
         startupCommand: String? = nil, remoteStartPath: String? = nil) {
        self.id = id; self.cols = cols; self.rows = rows; self.command = command
        self.startupCommand = startupCommand; self.remoteStartPath = remoteStartPath
    }
}

/// A port forward to add. kind: "L" local, "R" remote, "D" dynamic SOCKS.
struct ForwardSpec: Codable, Hashable, Sendable {
    var kind: String
    var bindAddr: String?
    var bindPort: Int
    var destHost: String?
    var destPort: Int?
    var label: String?

    init(kind: String, bindAddr: String? = nil, bindPort: Int, destHost: String? = nil, destPort: Int? = nil,
         label: String? = nil) {
        self.kind = kind; self.bindAddr = bindAddr; self.bindPort = bindPort
        self.destHost = destHost; self.destPort = destPort; self.label = label
    }

    /// `Connection.forwardSpec`: `[bind:]port[:host:port]`.
    var specString: String {
        let bind = (bindAddr?.isEmpty == false) ? "\(bindAddr!):" : ""
        if kind == "D" { return "\(bind)\(bindPort)" }
        return "\(bind)\(bindPort):\(destHost ?? ""):\(destPort.map(String.init) ?? "")"
    }
}

/// An open forward (`listForwards()` entries).
struct Forward: Identifiable, Hashable, Sendable {
    var id: String
    var kind: String
    var spec: String
    var bindAddr: String
    var bindPort: Int
    var destHost: String?
    var destPort: Int?
    var label: String
    var createdAt: Double
    var connId: String
    var connLabel: String

    var json: JSON {
        ["id": .string(id), "kind": .string(kind), "spec": .string(spec), "bindAddr": .string(bindAddr),
         "bindPort": .number(Double(bindPort)), "destHost": JSON(destHost), "destPort": JSON(destPort),
         "label": .string(label), "createdAt": .number(createdAt), "connId": .string(connId),
         "connLabel": .string(connLabel)]
    }
}

/// "Server profile": one round trip that describes the box.
struct ServerInfo: Sendable {
    /// Every `key=value` the probe printed (non-empty values only):
    /// kernel_sys, kernel, arch, hostname, user, shell, os_pretty, os_name,
    /// os_version, os_id, uptime, cpus, cpu_model, mem_total_kb, mem_avail_kb,
    /// load, disk_root, virt, init, users_online, pkg, has_docker, has_kubectl,
    /// has_podman.
    var values: [String: String]
    var memTotal: Double?
    var memAvail: Double?
    /// os_pretty, else "os_name os_version", else kernel_sys, else "Unknown".
    var osLabel: String
    var fetchedAt: Double
    /// Set when the probe failed part-way: the picture is incomplete.
    var partial: String?

    subscript(key: String) -> String? { values[key] }

    var json: JSON {
        var o: [String: JSON] = values.mapValues { .string($0) }
        if let memTotal { o["memTotal"] = .number(memTotal) }
        if let memAvail { o["memAvail"] = .number(memAvail) }
        o["osLabel"] = .string(osLabel)
        o["fetchedAt"] = .number(fetchedAt)
        if let partial { o["partial"] = .string(partial) }
        return .object(o)
    }
}

/// One remembered command from a shell history file.
struct ShellHistoryEntry: Hashable, Sendable {
    var command: String
    /// "bash", "zsh", "fish", "sh", or "" before any file marker.
    var shell: String
    /// ms since epoch, when the file recorded one.
    var at: Double?
}

struct ShellHistory: Sendable {
    var entries: [ShellHistoryEntry]
    /// True when a file had at least 4000 lines (only the tail was read).
    var truncated: Bool
    var at: Double
}

/// Whether a terminal is being logged to a file (`term:logState`).
struct LogState: Sendable, Equatable {
    var active: Bool
    var path: String?
}

/// `rsyncTransport()`: what `rsync -e` needs to ride this connection, or why not.
struct RsyncTransport: Sendable {
    var ok: Bool
    var reason: String?
    var target: String?
    var argv: [String] = []
    var shell: String?
}

/// Events, for code that wants pushes rather than observation. The same
/// facts are also observable properties on `Connection`.
enum ConnEvent {
    case state(id: String, state: ConnState, error: String?)
    case log(id: String, line: ConnLogLine)
    case info(id: String, info: ConnInfo)
    case forwards(id: String, forwards: [Forward])
    case serverInfo(id: String, info: ServerInfo)
    case logging(id: String, termId: String, path: String?, active: Bool)
    case terminalExit(id: String, termId: String, code: Int32?)
    /// The list of connections changed (created, removed, or a state changed).
    case changed
}
