import Foundation

/// This machine, shaped like a connection — for tmux and nothing else
/// (localhost.js). Answering `execResult`, `spawnCommandPTY` and
/// `transportKind` for the local machine is all it takes for every tmux
/// feature to work on this Mac exactly as on a server.
@MainActor
final class TmuxLocalHost: TmuxHost {
    /// The connection id the original used for it (`LOCAL_ID`).
    static let localId = "local"
    static let shared = TmuxLocalHost()

    let id = TmuxLocalHost.localId
    let transportKind = "local"
    let label = "this machine"
    let homeDir = NSHomeDirectory()

    /// The environment a tmux command should see (`localEnv`). Homebrew's
    /// directories are on the augmented PATH already (Proc.path); TMUX is
    /// removed because a ServerLife launched from inside tmux would otherwise
    /// make every `tmux new-session` refuse to nest.
    static func env(_ extra: [String: String?] = [:]) -> [String: String?] {
        var e: [String: String?] = ["TERM": "xterm-256color", "TMUX": nil, "TMUX_PANE": nil, "ELECTRON_RUN_AS_NODE": nil]
        // An app started from the Dock has no locale, and tmux without one
        // prints every non-ASCII character as `_` — a session called café is
        // listed as caf_. As main.js did: a locale the user set is left alone.
        let pe = ProcessInfo.processInfo.environment
        if (pe["LANG"] ?? "").isEmpty && (pe["LC_ALL"] ?? "").isEmpty && (pe["LC_CTYPE"] ?? "").isEmpty {
            e["LANG"] = "en_US.UTF-8"
        }
        for (k, v) in extra { e[k] = v }
        return e
    }

    func execResult(_ cmd: String) async -> ProcResult {
        await execResult(cmd, timeout: nil)
    }

    func execResult(_ cmd: String, timeout: TimeInterval?) async -> ProcResult {
        await Proc.run("/bin/sh", ["-c", cmd], env: Self.env(), cwd: homeDir, timeout: timeout ?? 20)
    }

    /// `exec`: stdout, or throw with stderr.
    func exec(_ cmd: String) async throws -> String {
        let r = await execResult(cmd)
        if !r.ok { throw AppError(r.err.trimmed.isEmpty ? (r.spawnError ?? "exited with code \(r.code)") : r.err.trimmed) }
        return r.out
    }

    func spawnCommandPTY(_ cmd: String, cols: Int = 100, rows: Int = 30) throws -> PTYProcess {
        if cmd.isEmpty { throw AppError("no command given") }
        return try PTYProcess(exe: "/bin/sh", args: ["-c", cmd], env: Self.env(), cwd: homeDir, cols: cols, rows: rows)
    }

    func spawnCommandChannel(_ cmd: String) throws -> ByteChannel {
        if cmd.isEmpty { throw AppError("no command given") }
        return try ProcessChannel("/bin/sh", ["-c", cmd], env: Self.env(), cwd: homeDir)
    }
}
