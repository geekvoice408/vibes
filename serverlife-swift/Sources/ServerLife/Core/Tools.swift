import Foundation

/// Finding the external programs everything is built on: the port of
/// sshbin.js and the tsh-locating half of teleport.js (`findTsh`, `tshEnv`,
/// `homeForProxy`). Shared by the connection layer and the Teleport layer.
///
/// Thread-safe: read from background tasks as well as the main actor.
enum Tools {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sshCache: String?
    nonisolated(unsafe) private static var sshOverride: String?
    nonisolated(unsafe) private static var sshSearched: [String] = []
    nonisolated(unsafe) private static var tshCache: String?
    nonisolated(unsafe) private static var tshOverride: String?
    nonisolated(unsafe) private static var tshSearched: [String] = []
    /// Extra tsh homes (settings.tshHomes, expanded), in order.
    nonisolated(unsafe) private static var homesList: [String] = []
    /// proxy → tsh home, learned when profiles are read (teleport.js homeByProxy).
    nonisolated(unsafe) private static var homeByProxyMap: [String: String] = [:]

    // MARK: ssh

    /// An explicit path from Settings (`sshPath`) always wins over the search.
    @discardableResult
    static func setSshPath(_ p: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        let t = (p ?? "").trimmed
        sshOverride = t.isEmpty ? nil : t
        sshCache = nil
        return sshOverride
    }

    static var ssh: String {
        lock.lock(); defer { lock.unlock() }
        if let c = sshCache { return c }
        if let o = sshOverride { sshCache = o; return o }
        let env = ProcessInfo.processInfo.environment
        sshSearched = [env["SSH_PATH"], "/usr/bin/ssh", "/usr/local/bin/ssh", "/opt/homebrew/bin/ssh"].compactMap { $0 }
        for p in sshSearched where FileManager.default.fileExists(atPath: p) { sshCache = p; return p }
        sshCache = Proc.which("ssh") ?? "ssh"
        return sshCache!
    }

    static var sshAvailable: Bool {
        let p = ssh
        return p.contains("/") && FileManager.default.isExecutableFile(atPath: p)
    }

    /// `sshStatus()`: what Settings shows about the OpenSSH client.
    static var sshStatus: JSON {
        let p = ssh
        lock.lock(); defer { lock.unlock() }
        return ["path": .string(p), "found": .bool(FileManager.default.isExecutableFile(atPath: p)),
                "override": JSON(sshOverride), "searched": JSON(sshSearched), "optionalHere": false]
    }

    /// Another OpenSSH tool (ssh-keygen, ssh-add, sftp …): beside ssh first, then PATH.
    static func tool(_ name: String) -> String {
        let beside = (ssh as NSString).deletingLastPathComponent + "/" + name
        if FileManager.default.isExecutableFile(atPath: beside) { return beside }
        return Proc.which(name) ?? name
    }

    static func toolAvailable(_ name: String) -> Bool {
        let p = tool(name)
        return p.contains("/") && FileManager.default.isExecutableFile(atPath: p)
    }

    // MARK: tsh

    @discardableResult
    static func setTshPath(_ p: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        let t = (p ?? "").trimmed
        tshOverride = t.isEmpty ? nil : t
        tshCache = nil
        return tshOverride
    }

    static var tsh: String {
        lock.lock(); defer { lock.unlock() }
        if let c = tshCache { return c }
        if let o = tshOverride { tshCache = o; return o }
        let env = ProcessInfo.processInfo.environment
        tshSearched = [env["TSH_PATH"], "/usr/local/bin/tsh", "/opt/homebrew/bin/tsh",
                       "/Applications/Teleport Connect.app/Contents/Resources/bin/tsh", "/usr/bin/tsh"].compactMap { $0 }
        for p in tshSearched where FileManager.default.fileExists(atPath: p) { tshCache = p; return p }
        tshCache = Proc.which("tsh") ?? "tsh"
        return tshCache!
    }

    static var tshAvailable: Bool {
        let p = tsh
        return p.contains("/") && FileManager.default.isExecutableFile(atPath: p)
    }

    static var tshStatus: JSON {
        let p = tsh
        lock.lock(); defer { lock.unlock() }
        return ["path": .string(p), "found": .bool(FileManager.default.isExecutableFile(atPath: p)),
                "override": JSON(tshOverride), "searched": JSON(tshSearched)]
    }

    // MARK: tsh homes

    /// settings.tshHomes, as the Teleport layer last set them.
    static var homes: [String] {
        get { lock.lock(); defer { lock.unlock() }; return homesList }
        set { lock.lock(); homesList = newValue.map { $0.expandingTilde }; lock.unlock() }
    }

    static func registerHome(_ home: String?, forProxy proxy: String) {
        lock.lock(); defer { lock.unlock() }
        homeByProxyMap[proxy] = home ?? ""
    }

    /// `homeForProxy`: the home a proxy's profile lives in, tolerating :443.
    static func home(forProxy proxy: String?) -> String? {
        guard let proxy, !proxy.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let bare = proxy.hasSuffix(":443") ? String(proxy.dropLast(4)) : proxy
        let h = homeByProxyMap[proxy] ?? homeByProxyMap[bare] ?? homeByProxyMap[proxy + ":443"]
        return (h?.isEmpty ?? true) ? nil : h
    }

    /// `tshEnv(home)`: TELEPORT_HOME only when a home is actually in play.
    static func tshEnv(home: String?) -> [String: String?] {
        var env: [String: String?] = [:]
        if let h = home?.trimmed, !h.isEmpty { env["TELEPORT_HOME"] = h.expandingTilde }
        else if let first = homes.first { env["TELEPORT_HOME"] = first }
        return env
    }

    /// Run tsh with the right home. `home` nil → inferred from `--proxy=` in args.
    static func runTsh(_ args: [String], home: String? = nil, timeout: TimeInterval = 25,
                       stdin: Data? = nil, env extra: [String: String?] = [:]) async -> ProcResult {
        let h = home ?? Tools.home(forProxy: proxyInArgs(args))
        var env = tshEnv(home: h)
        for (k, v) in extra { env[k] = v }
        return await Proc.run(tsh, args, env: env, stdin: stdin, timeout: timeout)
    }

    /// The `--proxy=` a set of arguments carries, if any.
    static func proxyInArgs(_ args: [String]) -> String? {
        for a in args {
            if a.hasPrefix("--proxy=") { return String(a.dropFirst("--proxy=".count)) }
            if a.hasPrefix("--proxy ") { return String(a.dropFirst("--proxy ".count)) }
        }
        return nil
    }
}
