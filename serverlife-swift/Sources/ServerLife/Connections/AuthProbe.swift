import Foundation

/// Why an SSH login was refused, read out of `ssh -vv` (authprobe.js).
///
/// Reproduces the attempt verbosely — `BatchMode=yes`, so it can never
/// authenticate — and reports what was offered, in order, and what the server
/// said, which is the evidence behind "too many authentication failures".
enum AuthProbe {
    struct Options {
        var port: Int?
        var identityFile: String?
        var proxyJump: String?
        /// Default true when an identity file is named.
        var identitiesOnly: Bool?
        /// One `-o` option per line (`Key value` or `-o Key value`).
        var extraOptions: String?
        var timeout: TimeInterval?
        init(port: Int? = nil, identityFile: String? = nil, proxyJump: String? = nil, identitiesOnly: Bool? = nil,
             extraOptions: String? = nil, timeout: TimeInterval? = nil) {
            self.port = port; self.identityFile = identityFile; self.proxyJump = proxyJump
            self.identitiesOnly = identitiesOnly; self.extraOptions = extraOptions; self.timeout = timeout
        }
    }

    struct Summary: Sendable, Equatable {
        var offered: [String] = []
        var considered: [String] = []
        var accepted: String?
        var methods: String?
        var methodsTried: [String] = []
        var tooMany = false
        var denied = false
        /// A *named* identity file ssh could not read.
        var missingIdentity: String?
        /// More offers than sshd's default MaxAuthTries (6) and nothing accepted.
        var pastLimit = false
        /// The server's own last word.
        var finalError = ""
    }

    struct Result: Sendable {
        var ok: Bool
        var command: String
        var transcript: String
        var summary: Summary
    }

    /// The ssh argv for the probe.
    static func args(target: String, _ o: Options) -> [String] {
        var a = ["-vv", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
        if let p = o.port, p != 0, p != 22 { a += ["-p", String(p)] }
        if let i = o.identityFile, !i.isEmpty {
            a += ["-i", i]
            if o.identitiesOnly != false { a += ["-o", "IdentitiesOnly=yes"] }
        }
        if let j = o.proxyJump, !j.isEmpty { a += ["-J", j] }
        for line in (o.extraOptions ?? "").components(separatedBy: "\n") {
            let t = line.trimmed
            if !t.isEmpty { a += ["-o", ConnText.replace(ConnSpec.leadingDashO, in: t, with: "")] }
        }
        a += [target, "true"]
        return a
    }

    /// Run one verbose, non-interactive attempt and summarise it.
    static func run(target: String, _ o: Options = Options()) async -> Result {
        let a = args(target: target, o)
        let r = await Proc.run(Tools.ssh, a, timeout: o.timeout ?? 30)
        let text = r.err + r.out
        return Result(ok: r.ok, command: (["ssh"] + a).joined(separator: " "), transcript: text, summary: summarise(text))
    }

    private static let offer = ConnText.re(#"^debug\d*:\s+Offering (?:public key|RSA public key|host key)[:\s]+(.*)$"#, ci: true)
    private static let send = ConnText.re(#"^debug\d*:\s+Authentications that can continue:\s*(.*)$"#, ci: true)
    private static let trying = ConnText.re(#"^debug\d*:\s+Trying private key:\s*(.*)$"#, ci: true)
    private static let willSend = ConnText.re(#"^debug\d*:\s+Will attempt key:\s*(.*)$"#, ci: true)
    private static let accepted = ConnText.re(#"^debug\d*:\s+Server accepts key:\s*(.*)$"#, ci: true)
    private static let nextMethod = ConnText.re(#"^debug\d*:\s+Next authentication method:\s*(.*)$"#, ci: true)
    private static let debugLine = ConnText.re(#"^debug\d*:"#)

    /// The few facts worth reading out of a -vv transcript.
    static func summarise(_ text: String) -> Summary {
        let lines = text.components(separatedBy: "\n").map { $0.trimmed }
        var s = Summary()
        for line in lines {
            if let m = ConnText.match(offer, line) { s.offered.append(m[1].trimmed); continue }
            if let m = ConnText.match(accepted, line) { s.accepted = m[1].trimmed; continue }
            if let m = ConnText.match(send, line) { s.methods = m[1].trimmed; continue }
            if let m = ConnText.match(trying, line) ?? ConnText.match(willSend, line) { s.considered.append(m[1].trimmed); continue }
            if let m = ConnText.match(nextMethod, line) { s.methodsTried.append(m[1].trimmed); continue }
        }
        s.tooMany = ConnText.test(ConnText.re(#"too many authentication failures"#, ci: true), text)
        s.denied = ConnText.test(ConnText.re(#"permission denied"#, ci: true), text)
        if let m = ConnText.match(ConnText.re(#"identity file (.+?) not accessible"#, ci: true), text) {
            s.missingIdentity = m[1].trimmed
        }
        s.pastLimit = s.accepted == nil && s.offered.count > 6
        s.finalError = lines.filter { !$0.isEmpty && !ConnText.test(debugLine, $0) }.suffix(4).joined(separator: "\n")
        return s
    }
}

/// `x11:status`: is there a local X server to forward to? On macOS XQuartz
/// provides it and sets DISPLAY for its own clients.
struct X11Status: Sendable, Equatable {
    var available: Bool
    var display: String?
    var installed: Bool
    var hint: String

    static func current(display: String? = ProcessInfo.processInfo.environment["DISPLAY"],
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> X11Status {
        let d = display?.nilIfEmpty
        let installed = ["/opt/X11/bin/Xquartz", "/Applications/Utilities/XQuartz.app", "/opt/X11"].contains(where: exists)
        let hint = !installed
            ? "XQuartz is not installed. Install it (brew install --cask xquartz), log out and back in."
            : d == nil
                ? "XQuartz is installed but DISPLAY is not set for this app. Launch XQuartz, then restart ServerLife from a terminal so it inherits DISPLAY."
                : "XQuartz detected."
        return X11Status(available: d != nil && installed, display: d, installed: installed, hint: hint)
    }
}

/// `tools:status`: whether ssh and tsh are actually here.
enum ToolsStatus {
    static var current: JSON { ["tsh": Tools.tshStatus, "ssh": Tools.sshStatus] }
}
