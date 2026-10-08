import Foundation

/// A shell offered in the "open a shell" menu (`listShells`).
struct ShellInfo: Hashable, Sendable, Identifiable {
    var path: String
    var name: String
    /// Whether a no-rc ("blank configuration") start is possible.
    var canBlank: Bool
    /// The one a plain "local shell" opens.
    var isDefault: Bool
    /// "your login shell", or "".
    var note: String
    var id: String { path }
}

/// A local shell that was opened: the backend plus what was actually started.
struct LocalShellSession {
    let backend: LocalTerminal
    let shell: String
    let blank: Bool
    let args: [String]
}

/// A local tab's backend: a PTYBackend whose cwd is the *shell's own*
/// working directory (local.js read `lsof -p <shell pid> -d cwd`), so a
/// foreground program that changes directory itself (a build tool, `git -C`,
/// an editor) does not move "follow terminal folder" or the pane title.
@MainActor
final class LocalTerminal: TerminalBackend {
    let inner: PTYBackend
    init(_ inner: PTYBackend) { self.inner = inner }

    var process: PTYProcess { inner.process }
    var kind: String { inner.kind }
    var onData: ((Data) -> Void)? {
        get { inner.onData }
        set { inner.onData = newValue }
    }
    var onExit: ((Int32?, String?) -> Void)? {
        get { inner.onExit }
        set { inner.onExit = newValue }
    }
    func write(_ data: Data) { inner.write(data) }
    func resize(cols: Int, rows: Int) { inner.resize(cols: max(2, cols), rows: max(2, rows)) }
    func close() { inner.close() }
    func cwd() async -> String? { PTYProcess.cwd(of: inner.process.pid) }
    var hasExited: Bool { inner.hasExited }
}

/// Local shell terminals (the shell half of local.js): the login shell, the
/// other shells on this machine, and "blank configuration" starts that read no
/// rc files. The cwd is read from the shell process (proc_pidinfo on its
/// pid), never by typing `pwd`.
@MainActor
final class LocalShells {
    static let shared = LocalShells()

    /// Open local terminals, so quitting can hang them all up.
    private var open: [WeakPTY] = []

    // MARK: pure helpers

    /// `defaultShell`: $SHELL, else the account's shell, else /bin/bash.
    nonisolated static func defaultShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return "/bin/bash"
    }

    /// POSIX shells take -l for a login shell.
    nonisolated static func loginArgs(_ shellPath: String) -> [String] {
        ConnText.test(ConnText.re(#"/(bash|zsh|sh|fish|ksh)$"#), shellPath) ? ["-l"] : []
    }

    /// Start without reading any startup file; each shell spells it differently.
    nonisolated static func blankArgs(_ shellPath: String) -> [String] {
        let name = (shellPath as NSString).lastPathComponent
        switch name {
        case "bash": return ["--noprofile", "--norc"]
        case "zsh": return ["-f", "-d"]          // no rc files, no global ones
        case "fish": return ["--no-config"]
        case "tcsh", "csh": return ["-f"]
        case "ksh", "mksh": return ["-p"]
        // sh reads no rc file when neither login nor ENV-interactive: plain is already blank.
        default: return []
        }
    }

    /// `/etc/shells` plus the usual system and Homebrew paths, only what exists
    /// and is executable, login shell first.
    nonisolated static func listShells(etcShells: String? = nil, loginShell: String? = nil,
                                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [ShellInfo] {
        var seen = Set<String>()
        var out: [ShellInfo] = []
        let def = defaultShell()
        func add(_ p: String, _ note: String = "") {
            if p.isEmpty || seen.contains(p) { return }
            seen.insert(p)
            guard isExecutable(p) else { return }
            let name = (p as NSString).lastPathComponent
            out.append(ShellInfo(path: p, name: name, canBlank: !blankArgs(p).isEmpty || name == "sh",
                                 isDefault: p == def, note: note))
        }
        add(loginShell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "", "your login shell")
        let text = etcShells ?? (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmed
            if !t.isEmpty && !t.hasPrefix("#") { add(t) }
        }
        for p in ["/bin/bash", "/bin/zsh", "/bin/sh", "/bin/ksh", "/bin/tcsh", "/bin/dash",
                  "/usr/bin/bash", "/usr/bin/zsh", "/usr/bin/fish",
                  "/opt/homebrew/bin/bash", "/opt/homebrew/bin/zsh", "/opt/homebrew/bin/fish",
                  "/usr/local/bin/bash", "/usr/local/bin/zsh", "/usr/local/bin/fish"] {
            add(p)
        }
        return out
    }

    /// The program and argv a local tab starts (`LocalTerminals.open`).
    nonisolated static func invocation(shell: String?, blank: Bool, command: String? = nil,
                                       args: [String]? = nil) -> (file: String, args: [String]) {
        if let command, !command.isEmpty { return (command, args ?? []) }
        let file = shell?.nilIfEmpty ?? defaultShell()
        // A blank start is deliberately not a login shell: -l reads the profile it avoids.
        return (file, blank ? blankArgs(file) : loginArgs(file))
    }

    // MARK: API

    func shells() -> [ShellInfo] { LocalShells.listShells() }

    /// A local shell on a pty: the login shell, another shell, or a blank one.
    func open(shell: String?, blank: Bool, cwd: String?, cols: Int, rows: Int) throws -> TerminalBackend {
        try openSession(shell: shell, blank: blank, cwd: cwd, cols: cols, rows: rows).backend
    }

    /// The same, saying which shell actually started.
    func openSession(shell: String? = nil, blank: Bool = false, cwd: String? = nil, cols: Int = 100, rows: Int = 30,
                     command: String? = nil, args: [String]? = nil, teleportHome: String? = nil,
                     env extra: [String: String?] = [:]) throws -> LocalShellSession {
        let inv = LocalShells.invocation(shell: shell, blank: blank, command: command, args: args)
        var env: [String: String?] = ["TERM": "xterm-256color", "ELECTRON_RUN_AS_NODE": nil]
        if let h = teleportHome?.nilIfEmpty { env["TELEPORT_HOME"] = h }
        if blank && command == nil { env["SERVERLIFE_BLANK_SHELL"] = "1" }
        for (k, v) in extra { env[k] = v }
        var isDir: ObjCBool = false
        let dir: String
        if let c = cwd?.expandingTilde, FileManager.default.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue {
            dir = c
        } else {
            dir = NSHomeDirectory()
        }
        let p = try PTYProcess(exe: inv.file, args: inv.args, env: env, cwd: dir, cols: cols, rows: rows)
        open.removeAll { $0.p == nil || $0.p?.isRunning == false }
        open.append(WeakPTY(p))
        let kind = command == nil ? "local" : "command"
        return LocalShellSession(backend: LocalTerminal(PTYBackend(p, kind: kind)), shell: inv.file, blank: blank && command == nil,
                                 args: inv.args)
    }

    /// Hang up every local terminal (quitting).
    func closeAll() {
        for w in open { w.p?.terminate(grace: 0.5) }
        open = []
    }

    private final class WeakPTY {
        weak var p: PTYProcess?
        init(_ p: PTYProcess) { self.p = p }
    }
}
