import Foundation
import CryptoKit

/// Everything a connection was built from (the `spec` object in
/// connections.js), and the argument vectors derived from it. A value type
/// with no side effects, so every transport/option combination is testable.
struct ConnSpec: Sendable {
    /// "ssh", "teleport" or "beam".
    var type: String
    /// e.g. "ubuntu@node.example-cluster", "ent", or a beam's name.
    var target: String
    var label: String
    /// `ssh -F`: the generated Teleport config, or the extra file an alias came from.
    var configFile: String?
    var login: String?
    /// The Teleport node (or beam) descriptor.
    var node: Host?
    /// The ssh host descriptor (alias or app-defined).
    var host: Host?
    /// A host defined in the app: its details ride on the command line.
    var direct: DirectSpec?
    /// A jump host on top of an alias (`-J`).
    var proxyJump: String?
    /// "off", "untrusted" (-X) or "trusted" (-Y).
    var x11: String = "off"
    var agentForward = false
    var compression = false
    var transport: ConnTransport = .mux
    var mfaMode: String?
    /// "no-ssh" or "leaf" when the tsh transport was not the one asked for.
    var transportForced: String?
    /// A beam: name, proxy, home.
    var beamName: String?
    var beamProxy: String?
    var x11Timeout: String?
    var timeout: TimeInterval?

    init(type: String, target: String, label: String? = nil) {
        self.type = type
        self.target = target
        self.label = label ?? target
    }

    /// Whether tsh is in use because there was no alternative (leaf, no ssh)
    /// rather than because the user asked for per-session MFA.
    var tshByNecessity: Bool { transport == .tsh && transportForced != nil }

    /// The id of the host the connection was opened for (sessions'
    /// `findConnectionForHost` matches on it).
    var hostId: String? { (node ?? host)?.id }

    /// The tsh home this connection belongs to — needed by ssh too, because a
    /// Teleport node over OpenSSH goes through `tsh proxy ssh`.
    var tshHome: String? {
        if let h = node?.home, !h.isEmpty { return h }
        return Tools.home(forProxy: node?.proxy)
    }

    // MARK: - ssh

    /// Args common to every ssh invocation for this connection (`sshArgs`).
    func sshArgs(controlPath: String?, _ extra: [String] = []) -> [String] {
        var a: [String] = []
        if let f = configFile, !f.isEmpty {
            a += ["-F", f]
            // Offer only the Teleport certificate: an agent full of keys
            // exhausts MaxAuthTries before the cert is ever tried.
            a += ["-o", "IdentitiesOnly=yes"]
        }
        if let controlPath { a += ["-o", "ControlPath=" + controlPath] }
        // -J overrides an alias's own ProxyJump; app-defined hosts get it via directArgs.
        if direct == nil, let j = proxyJump, !j.isEmpty { a += ["-J", j] }
        a += directArgs()
        return a + extra
    }

    /// Connection details for a host defined in the app (`directArgs`).
    func directArgs() -> [String] {
        guard let d = direct else { return [] }
        var a: [String] = []
        if let p = d.port, p != 0, p != 22 { a += ["-p", String(p)] }
        if let i = d.identityFile, !i.isEmpty { a += ["-i", i, "-o", "IdentitiesOnly=yes"] }
        if let j = d.proxyJump, !j.isEmpty { a += ["-J", j] }
        for raw in d.options ?? [] {
            for line in raw.components(separatedBy: "\n") {
                let t = line.trimmed
                if t.isEmpty { continue }
                a += ["-o", ConnText.replace(ConnSpec.leadingDashO, in: t, with: "")]
            }
        }
        // A host typed in by hand has no known key yet: accept on first use, pin thereafter.
        a += ["-o", "StrictHostKeyChecking=accept-new"]
        return a
    }

    static let leadingDashO = ConnText.re(#"^-o\s*"#)

    /// X11 flags; negotiated on the master, so sessions inherit it.
    func x11Args() -> [String] {
        if x11.isEmpty || x11 == "off" { return [] }
        var a = x11 == "trusted" ? ["-Y"] : ["-X"]
        a += ["-o", "ForwardX11Timeout=" + (x11Timeout ?? "596h")]
        return a
    }

    /// Agent forwarding and compression, properties of the master.
    func featureArgs() -> [String] {
        var a: [String] = []
        if agentForward { a.append("-A") }
        if compression { a.append("-C") }
        return a
    }

    /// The options that make the master the master (`BASE_OPTS`).
    static let baseOpts = [
        "-o", "ControlMaster=yes",
        "-o", "ControlPersist=no",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=no",
    ]

    /// The ControlMaster itself, held in the foreground on our pty.
    func masterArgs(controlPath: String) -> [String] {
        sshArgs(controlPath: controlPath, ConnSpec.baseOpts + x11Args() + featureArgs() + ["-N", target])
    }

    /// An interactive shell (or a command) over the master.
    func terminalSshArgs(controlPath: String, command: String?) -> [String] {
        var a = sshArgs(controlPath: controlPath, x11Args() + featureArgs() + ["-tt", target])
        if let command { a.append(command) }
        return a
    }

    /// A command on a pty that the caller owns (tmux control mode): no X11.
    func commandPtySshArgs(controlPath: String, command: String) -> [String] {
        sshArgs(controlPath: controlPath, featureArgs() + ["-tt", target, command])
    }

    // MARK: - tsh

    /// The host part of `tsh ssh`'s target: a UUID when the hostname is shared.
    func tshTarget() -> String {
        let n = node
        var hostPart: String
        if n?.ambiguous == true, let u = n?.uuid, !u.isEmpty { hostPart = u }
        else if let h = n?.hostname, !h.isEmpty { hostPart = h }
        else if let nm = n?.name, !nm.isEmpty { hostPart = nm }
        else {
            hostPart = target
            if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
            if let dot = hostPart.firstIndex(of: ".") { hostPart = String(hostPart[..<dot]) }
        }
        if let login, !login.isEmpty { return "\(login)@\(hostPart)" }
        return hostPart
    }

    /// Argv for `tsh ssh` against this connection's node (`tshArgs`).
    func tshArgs(_ extra: [String] = [], command: String? = nil) -> [String] {
        var a: [String] = []
        if let p = node?.proxy, !p.isEmpty { a.append("--proxy=" + p) }
        if let m = mfaMode, !m.isEmpty { a.append("--mfa-mode=" + m) }
        a.append("ssh")
        if let c = node?.cluster, !c.isEmpty { a.append("--cluster=" + c) }
        if agentForward { a.append("-A") }
        if x11 == "trusted" || x11 == "untrusted" { a.append("-X") }
        a += extra
        a.append(tshTarget())
        if let command { a.append(command) }
        return a
    }

    /// `tsh scp` argv (`tshScp`).
    func tshScpArgs(upload: Bool, localPaths: [String], remotePaths: [String], recursive: Bool) -> [String] {
        var a: [String] = []
        if let p = node?.proxy, !p.isEmpty { a.append("--proxy=" + p) }
        if let m = mfaMode, !m.isEmpty { a.append("--mfa-mode=" + m) }
        a.append("scp")
        if let c = node?.cluster, !c.isEmpty { a.append("--cluster=" + c) }
        if recursive { a.append("-r") }
        let t = tshTarget()
        if upload {
            a += localPaths
            a.append("\(t):\(remotePaths.first ?? "")")
        } else {
            a += remotePaths.map { "\(t):\($0)" }
            a.append(localPaths.first ?? "")
        }
        return a
    }

    // MARK: - beam

    /// `tsh beams ssh <name>` for a terminal, `tsh beams exec <name> -- cmd` for a command.
    func beamArgs(command: String? = nil) -> [String] {
        var a: [String] = []
        if let p = beamProxy, !p.isEmpty { a.append("--proxy=" + p) }
        a += ["beams"]
        if let command {
            a += ["exec", beamName ?? target, "--", command]
        } else {
            a += ["ssh", beamName ?? target]
        }
        return a
    }

    // MARK: - choosing the program

    /// The program and argv for running `command` non-interactively, by transport.
    func execInvocation(controlPath: String, command: String) -> (exe: String, args: [String]) {
        switch transport {
        case .beam: return (Tools.tsh, beamArgs(command: command))
        case .tsh: return (Tools.tsh, tshArgs([], command: command))
        case .mux: return (Tools.ssh, sshArgs(controlPath: controlPath, ["-T", target, command]))
        }
    }

    /// The program and argv for an interactive terminal, by transport.
    func terminalInvocation(controlPath: String, command: String?) -> (exe: String, args: [String]) {
        switch transport {
        case .beam: return (Tools.tsh, beamArgs(command: command))
        case .tsh: return (Tools.tsh, tshArgs([], command: command))
        case .mux: return (Tools.ssh, terminalSshArgs(controlPath: controlPath, command: command))
        }
    }

    /// The program and argv for the SFTP channel, by transport.
    func sftpInvocation(controlPath: String) -> (exe: String, args: [String]) {
        switch transport {
        case .beam: return (Tools.tsh, beamArgs(command: ConnText.sftpServerChain))
        case .tsh: return (Tools.tsh, tshArgs([], command: ConnText.sftpServerChain))
        case .mux: return (Tools.ssh, sshArgs(controlPath: controlPath, [target, "-s", "sftp"]))
        }
    }

    /// The flattened shape the history log stores (`historyEntryFor`).
    func historyEntry(user: String?, hostname: String?) -> JSON {
        var o: [String: JSON] = [
            "type": .string(type), "label": .string(label), "target": .string(target),
            "cluster": JSON(node?.cluster), "proxy": JSON(node?.proxy),
            "node": JSON(node?.name ?? host?.alias),
            "home": JSON(node?.home), "login": JSON(login),
            "user": JSON(user), "hostname": JSON(hostname),
        ]
        o["direct"] = direct.map { JSON.encode($0) } ?? .null
        return .object(o)
    }
}

/// Runtime directory for control sockets and generated configs.
///
/// The original used `$TMPDIR/serverlife-<uid>`. This one is `sl-<uid>`:
/// distinct, so the two apps can run side by side without one reusing (or
/// tearing down) the other's ControlMasters — both number their connections
/// from conn1 — and no longer, because OpenSSH binds `ControlPath` plus a
/// 17-character suffix and macOS allows 103 characters in a socket path
/// (a 10-digit uid must still fit).
enum ConnRuntime {
    static let dir: String = {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("sl-\(getuid())")
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }()

    /// Where generated per-cluster ssh_configs go (`manager.configDir`).
    static var configDir: String { (dir as NSString).appendingPathComponent("ssh-config") }

    /// Unix socket paths cap at ~104 chars, so the control path is a short hash.
    static func controlPath(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (dir as NSString).appendingPathComponent("c-" + hex.prefix(12))
    }
}
