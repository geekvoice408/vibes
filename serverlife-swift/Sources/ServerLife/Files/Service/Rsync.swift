import Foundation

/// rsync, driven from the file browser (src/main/rsync.js, the `rsync:*`
/// handlers, connections.js `rsyncTransport()`, and the pure command builders
/// from the renderer's rsyncsync.js so the dialog and its tests share one).
///
/// The browser's own synchronise walks both folders over SFTP and copies what
/// differs, which is honest work and the right answer for a handful of files.
/// It is the wrong answer for a tree: rsync compares by rolling checksum,
/// sends only the changed blocks, and has spent thirty years on exactly this
/// problem.
///
/// What it needs that SFTP does not is a shell to run itself on the far side.
/// It rides ssh, so it works where there is an ssh connection to ride — and
/// where there is not, it says so rather than failing halfway.
enum Rsync {
    /// Where a Homebrew or MacPorts rsync would be, ahead of the system one.
    static let candidates = [
        "/opt/homebrew/bin/rsync",
        "/usr/local/bin/rsync",
        "/opt/local/bin/rsync",
        "/usr/bin/rsync",
        "/bin/rsync",
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?
    nonisolated(unsafe) private static var running: [String: RunningProcess] = [:]

    /// Why this machine cannot run the rsync sync at all, or "" if it can.
    /// (The original refused on Windows; macOS always may try.)
    static func unsupportedReason() -> String { "" }

    /// The best rsync on this machine, not merely the first.
    ///
    /// macOS ships `openrsync` at /usr/bin/rsync, which answers to "rsync
    /// version 2.6.9 compatible" and has neither `--info=progress2` nor
    /// `--protect-args`. A Homebrew rsync alongside it is a real 3.x.
    /// Preferring the one with the features, and recording which it is, is
    /// what lets the caller build a command line the binary will accept.
    /// Whatever is on PATH counts too: an rsync under a version manager, in
    /// ~/bin, or in a Nix profile is as real as one in /usr/bin.
    static func find(searchPath: String = Proc.path, candidates: [String] = Rsync.candidates, useCache: Bool = true) -> String? {
        if useCache { lock.lock(); let c = cached; lock.unlock(); if let c { return c } }
        var seen: [String] = []
        for p in candidates where FileManager.default.fileExists(atPath: p) { seen.append(p) }
        for dir in searchPath.split(separator: ":") where !dir.isEmpty {
            let p = (String(dir) as NSString).appendingPathComponent("rsync")
            if !seen.contains(p) && FileManager.default.fileExists(atPath: p) { seen.append(p) }
        }
        guard let first = seen.first else { return nil }
        if useCache { lock.lock(); cached = first; lock.unlock() }
        return first
    }

    struct Version: Equatable, Sendable {
        var line: String
        var major: Int
        var minor: Int
        /// openrsync claims 2.6.9 compatibility and means it: the modern
        /// flags are not there, whatever the binary is called.
        var openrsync: Bool
    }

    static func parseVersion(_ stdout: String) -> Version {
        let line = stdout.components(separatedBy: "\n").first ?? ""
        var major = 0, minor = 0
        if let re = try? NSRegularExpression(pattern: #"version\s+(\d+)\.(\d+)(?:\.(\d+))?"#),
           let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            major = Int((line as NSString).substring(with: m.range(at: 1))) ?? 0
            minor = Int((line as NSString).substring(with: m.range(at: 2))) ?? 0
        }
        return Version(line: line.trimmed, major: major, minor: minor,
                       openrsync: stdout.range(of: "openrsync", options: .caseInsensitive) != nil)
    }

    static func versionOf(_ bin: String) async -> Version? {
        let r = await Proc.run(bin, ["--version"], timeout: 8)
        guard r.ok else { return nil }
        return parseVersion(r.out)
    }

    /// What the command builder may use. An old rsync gets a plainer command
    /// rather than a clever one that fails on the first flag it has never
    /// heard of.
    struct Features: Codable, Equatable, Sendable {
        /// --info=progress2
        var infoProgress: Bool
        /// -s, for paths with spaces
        var protectArgs: Bool

        static func of(_ v: Version) -> Features {
            let modern = !v.openrsync && (v.major > 3 || (v.major == 3 && v.minor >= 1))
            return Features(infoProgress: modern, protectArgs: modern)
        }
    }

    struct Check: Codable, Sendable {
        var ok: Bool
        var error: String?
        var unsupported: Bool?
        var bin: String?
        var version: String?
        var features: Features?
    }

    /// `rsync:check`: is rsync usable here, and which flags may the command use?
    static func check() async -> Check {
        let no = unsupportedReason()
        if !no.isEmpty { return Check(ok: false, error: no, unsupported: true) }
        guard let bin = find() else {
            return Check(ok: false, error: "rsync was not found on this machine. Install it (brew install rsync) and try again.")
        }
        guard let v = await versionOf(bin) else { return Check(ok: false, error: "\(bin) would not report its version.") }
        return Check(ok: true, bin: bin, version: v.line, features: .of(v))
    }

    // MARK: - Transport

    struct Transport: Codable, Sendable {
        var ok: Bool
        var reason: String?
        var target: String?
        var argv: [String]?
        /// argv joined with spaces: what goes after `-e`.
        var shell: String?
    }

    /// `rsync:transport` — what `rsync -e` needs to reach this connection, or
    /// why it cannot (the connection layer's `rsyncTransport()`).
    ///
    /// rsync runs itself on the far side over a shell of our choosing, so it
    /// can ride the ControlMaster this connection is already holding: no
    /// second authentication, no second Teleport session, and on a recorded
    /// cluster no extra entry in the audit log beyond the exec itself.
    @MainActor
    static func transport(_ connId: String) -> Transport {
        guard let t = FilesBridge.rsyncTransport(connId) else {
            return Transport(ok: false, reason: "That connection is not open any more.")
        }
        return Transport(ok: t.ok, reason: t.reason, target: t.target, argv: t.ok ? t.argv : nil, shell: t.shell)
    }

    // MARK: - Running

    /// One piece of streamed output. `stream` is "sys" (the command line),
    /// "out" or "err".
    struct Output: Sendable {
        var id: String
        var text: String
        var stream: String
    }

    struct Done: Sendable {
        var id: String
        /// nil when it was ended by a signal.
        var code: Int32?
        var signal: String?
        var error: String?
        /// `explain(code)`.
        var message: String
    }

    /// Start a run. Output is streamed as it arrives rather than collected: a
    /// long sync is the case that matters, and a progress meter that appears
    /// after it finishes is not a progress meter. Callbacks arrive on a
    /// background thread.
    @discardableResult
    static func run(id: String, args: [String], onOut: @escaping @Sendable (Output) -> Void,
                    onDone: @escaping @Sendable (Done) -> Void) throws -> (id: String, bin: String) {
        guard let bin = find() else { throw AppError("rsync was not found on this machine.") }
        lock.lock()
        if running[id] != nil { lock.unlock(); throw AppError("That run is already going.") }
        lock.unlock()
        onOut(Output(id: id, text: "$ \(bin) \(args.joined(separator: " "))\n", stream: "sys"))
        // No shell: every argument is passed as it was built, so a path with a
        // space in it needs no quoting and cannot be re-split into two paths.
        let p: RunningProcess
        do {
            p = try RunningProcess(bin, args,
                                   onStdout: { onOut(Output(id: id, text: String(decoding: $0, as: UTF8.self), stream: "out")) },
                                   onStderr: { onOut(Output(id: id, text: String(decoding: $0, as: UTF8.self), stream: "err")) })
        } catch {
            onDone(Done(id: id, code: -1, signal: nil, error: errorText(error), message: explain(-1)))
            return (id, bin)
        }
        p.closeStdin()
        lock.lock(); running[id] = p; lock.unlock()
        p.onExit { status in
            lock.lock(); running[id] = nil; lock.unlock()
            let bySignal = p.process.terminationReason == .uncaughtSignal
            let code: Int32? = bySignal ? nil : status
            onDone(Done(id: id, code: code, signal: bySignal ? signalName(status) : nil, error: nil, message: explain(code)))
        }
        return (id, bin)
    }

    /// Stop a run. SIGINT lets rsync tidy up; if it will not go, insist
    /// shortly after.
    @discardableResult
    static func cancel(_ id: String) -> Bool {
        lock.lock(); let p = running[id]; lock.unlock()
        guard let p else { return false }
        p.signal(SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { p.signal(SIGKILL) }
        return true
    }

    static func cancelAll() {
        lock.lock(); let ids = Array(running.keys); lock.unlock()
        ids.forEach { cancel($0) }
    }

    static func isRunning(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return running[id] != nil }

    private static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGINT: return "SIGINT"
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        case SIGHUP: return "SIGHUP"
        default: return "SIG\(s)"
        }
    }

    /// The exit codes worth explaining. rsync has about thirty and most of
    /// them are "something went wrong"; these are the ones with a specific,
    /// actionable cause that the output alone does not make obvious.
    static let codes: [Int32: String] = [
        1: "syntax or usage error",
        2: "protocol incompatibility — the rsync on the far side is too old",
        3: "errors selecting input or output files",
        5: "error starting the client-server protocol — often no rsync on the far side",
        10: "error in socket I/O",
        11: "error in file I/O",
        12: "error in the rsync protocol data stream",
        20: "interrupted",
        23: "some files could not be transferred — check the errors above",
        24: "some files vanished while it was running",
        30: "timed out",
        127: "rsync was not found on the far side",
    ]

    static func explain(_ code: Int32?) -> String {
        guard let code else { return "rsync exited null." }
        if code == 0 { return "Finished." }
        if let c = codes[code] { return "rsync exited \(code): \(c)" }
        return "rsync exited \(code)."
    }

    // MARK: - Building the command (rsyncsync.js)

    /// One end of a run.
    struct Side: Sendable {
        /// "local" | "remote"
        var kind: String
        var label: String
        /// For a remote side: what rsync should ssh to (the connection's target).
        var target: String?
    }

    /// A path as rsync should see it. The trailing slash is the difference
    /// between the folder and its contents.
    static func endpoint(_ side: Side, _ path: String, contents: Bool = true) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        if contents { p += "/" }
        if side.kind == "local" { return p }
        return "\(side.target ?? side.label):\(p)"
    }

    struct Options: Sendable {
        var from: String
        var to: String
        var archive = true
        var compress = true
        var del = false
        var dryRun = true
        var excludes: [String] = []
        var extra = ""
        var features = Features(infoProgress: false, protectArgs: false)
        var checksum = false
        var times = true
        /// The ssh to ride, one argument however long.
        var shellArg: String?
    }

    /// Build the argument list. Pure, and the part worth testing: everything
    /// the user ticked has to land as a flag, nothing else may, and the two
    /// paths go last in the order the direction says.
    static func buildArgs(_ o: Options) -> [String] {
        var args: [String] = []
        if o.archive { args.append("-a") } else if o.times { args.append("-rt") }
        if o.compress { args.append("-z") }
        args.append("-h")                                   // human-readable sizes
        if o.checksum { args.append("-c") }
        if o.del { args.append("--delete") }
        if o.dryRun { args.append("-n") }
        // A progress meter the caller can actually read, where the binary has it.
        args.append(o.features.infoProgress ? "--info=progress2,stats2" : "--progress")
        args.append("-v")
        // Paths with spaces survive the remote shell without the caller quoting.
        if o.features.protectArgs { args.append("-s") }
        for x in o.excludes {
            let v = x.trimmed
            if !v.isEmpty { args += ["--exclude", v] }
        }
        for x in o.extra.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) { args.append(String(x)) }
        if let s = o.shellArg, !s.isEmpty { args += ["-e", s] }
        args += [o.from, o.to]
        return args
    }

    /// The command as a line of text, for the dialog to show and for the log.
    static func commandLine(_ args: [String]) -> String {
        (["rsync"] + args.map { a in
            a.contains(where: { $0.isWhitespace })
                ? "\"" + a.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                : a
        }).joined(separator: " ")
    }
}
