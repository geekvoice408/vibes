import Foundation

// The parsing half of quickconnect.js: what someone typed or pasted, turned
// into connection details. Pure, and tested on its own.

/// A parsed quick-connect target (`parseTarget`'s object).
struct QuickTarget: Equatable {
    /// `ssh`, `telnet`, `vnc`, `rdp` or `serial`.
    var kind = "ssh"
    var user = ""
    var hostname = ""
    var port = 22
    var identityFile = ""
    var proxyJump = ""
    var command = ""
    /// Serial only.
    var path: String?
    var baudRate: Int?
}

enum QuickConnect {
    /// The protocols quick connect can speak, and the port each assumes.
    static let schemes: [String: Int] = ["ssh": 22, "telnet": 23, "vnc": 5900, "rdp": 3389]

    /// How many addresses are remembered (`RECENT_MAX`).
    static let recentMax = 12

    // MARK: Small JavaScript equivalents

    static func re(_ p: String, ci: Bool = false) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : [])
    }

    static func groups(_ r: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let rg = m.range(at: i)
            guard rg.location != NSNotFound, let r = Range(rg, in: s) else { return nil }
            return String(s[r])
        }
    }

    static func test(_ r: NSRegularExpression, _ s: String) -> Bool { r.matches(s) }

    static func replace(_ r: NSRegularExpression, _ s: String, with t: String = "") -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    /// `parseInt(s, 10)`: leading whitespace, optional sign, digits; nil for NaN.
    static func parseInt(_ s: String?) -> Int? {
        guard let s else { return nil }
        var t = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        var sign = 1
        if t.first == "-" { sign = -1; t = t.dropFirst() } else if t.first == "+" { t = t.dropFirst() }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let v = Int(digits) else { return nil }
        return sign * v
    }

    // MARK: Parsing

    private static let tokenRe = re(#""[^"]*"|'[^']*'|\S+"#)
    private static let quoteEnds = re(#"^["']|["']$"#)

    /// Split on whitespace, respecting quotes, so a pasted command line survives.
    static func tokenize(_ s: String) -> [String] {
        let ns = s as NSString
        return tokenRe.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            replace(quoteEnds, ns.substring(with: $0.range))
        }
    }

    private static let serialRe = re(#"^(?:serial:)?((?:/dev/[\w.\-/]+)|(?:COM\d+))(?:[@,](\d{3,7}))?$"#, ci: true)

    /// A serial port, which is a path rather than an address: `/dev/…` or
    /// `COM<n>`, with an optional speed after `@` or `,`.
    static func parseSerial(_ s: String) -> QuickTarget? {
        guard let m = groups(serialRe, s), let path = m[1] else { return nil }
        var t = QuickTarget()
        t.kind = "serial"
        t.port = 0
        t.path = path
        t.baudRate = m[2].flatMap { parseInt($0) } ?? 115200
        return t
    }

    private static let schemeUrl = re(#"^(ssh|telnet|vnc|rdp)://"#, ci: true)
    private static let schemeWord = re(#"^(ssh|telnet|vnc|rdp)\s+"#, ci: true)
    private static let sshCommand = re(#"^ssh\s"#, ci: true)
    private static let valueFlag = re(#"^-[oFEbcDLRWQmS]$"#)
    private static let sshUrl = re(#"^ssh://"#, ci: true)
    private static let trailingPath = re(#"/.*$"#)
    private static let trailingColon = re(#":$"#)
    private static let bracketed = re(#"^\[([^\]]+)\](?::(\d+))?$"#)
    private static let allDigits = re(#"^\d+$"#)
    private static let whitespace = re(#"\s"#)

    /// Parse what someone typed or pasted into connection details: `host`,
    /// `user@host`, `host:2222`, `user@host:2222`, bracketed and bare IPv6,
    /// an `ssh://` URL, a whole `ssh` command line, another protocol as a
    /// scheme or a first word, or a serial port. nil when there is no
    /// hostname in it.
    static func parseTarget(_ raw: String?) -> QuickTarget? {
        var out = QuickTarget()
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        if let serial = parseSerial(s) { return serial }

        if let m = groups(schemeUrl, s) ?? groups(schemeWord, s), let word = m[1] {
            out.kind = word.lowercased()
            out.port = schemes[out.kind] ?? 22
            if out.kind != "ssh" {
                s = String(s.dropFirst((m[0] ?? "").count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if test(sshCommand, s) {
            let toks = Array(tokenize(s).dropFirst())
            s = ""
            var i = 0
            while i < toks.count {
                let t = toks[i]
                func next() -> String? { i += 1; return i < toks.count ? toks[i] : nil }
                if t == "-p" { let v = parseInt(next()) ?? 0; out.port = v != 0 ? v : 22 }
                else if t == "-i" { out.identityFile = next() ?? "" }
                else if t == "-J" { out.proxyJump = next() ?? "" }
                else if t == "-l" { out.user = next() ?? "" }
                // Flags that take a value we have no field for; skip both tokens.
                else if test(valueFlag, t) { i += 1 }
                else if t.hasPrefix("-") { i += 1; continue }
                else {
                    // The first bare word is the target; everything after it is
                    // the remote command, verbatim.
                    s = t
                    if i + 1 < toks.count { out.command = toks[(i + 1)...].joined(separator: " ") }
                    break
                }
                i += 1
            }
        }

        s = replace(sshUrl, s)
        // A trailing path from an scp-style or URL paste, and scp's colon with it.
        s = replace(trailingColon, replace(trailingPath, s))
        if s.isEmpty { return nil }

        // A password in a URL is not something to carry around silently.
        if let at = s.range(of: "@", options: .backwards) {
            let before = String(s[..<at.lowerBound])
            let u = before.components(separatedBy: ":")[0]
            if !u.isEmpty { out.user = u }
            s = String(s[at.upperBound...])
        }

        if let b = groups(bracketed, s) {
            out.hostname = b[1] ?? ""
            if let p = b[2] { out.port = parseInt(p) ?? out.port }
        } else {
            let parts = s.components(separatedBy: ":")
            // Two parts with digits last is host:port; more colons is bare IPv6.
            if parts.count == 2, test(allDigits, parts[1]) {
                out.hostname = parts[0]
                out.port = parseInt(parts[1]) ?? out.port
            } else {
                out.hostname = s
            }
        }

        if out.hostname.isEmpty || test(whitespace, out.hostname) { return nil }
        if !(out.port >= 1 && out.port <= 65535) { return nil }
        return out
    }

    /// How the target reads back — the label on the tab and in the history list.
    static func targetLabel(_ t: QuickTarget) -> String {
        if t.kind == "serial" {
            let b = t.baudRate ?? 0
            return (t.path ?? "") + (b != 0 && b != 115200 ? "@\(b)" : "")
        }
        let host = t.hostname.contains(":") ? "[\(t.hostname)]" : t.hostname
        let def = schemes[t.kind.isEmpty ? "ssh" : t.kind] ?? 22
        let addr = (t.user.isEmpty ? "" : "\(t.user)@") + host + (t.port != def ? ":\(t.port)" : "")
        return !t.kind.isEmpty && t.kind != "ssh" ? "\(t.kind)://\(addr)" : addr
    }

    /// The host descriptor `open-host` understands, built from a parsed
    /// target. The id is the whole address, so two quick connects to
    /// different boxes are never taken for the same host, and one reopened
    /// from the recent list lands on the same id as the original.
    static func quickHost(_ t: QuickTarget) -> Host {
        var h = Host(type: Host.ssh, id: "direct:\(t.user)@\(t.hostname):\(t.port)", name: targetLabel(t))
        h.direct = DirectSpec(hostname: t.hostname, user: t.user.nilIfEmpty, port: t.port,
                              identityFile: t.identityFile.nilIfEmpty, proxyJump: t.proxyJump.nilIfEmpty,
                              extraOptions: "")
        return h
    }

    // MARK: Recent targets (settings.quickConnects)

    @MainActor static var recentTargets: [String] {
        Store.shared.settingJSON("quickConnects").items.compactMap { $0.string }
    }

    /// Remember a target string, newest first. Only the address is kept.
    @MainActor static func rememberTarget(_ str: String) {
        let next = [str] + recentTargets.filter { $0 != str }
        Store.shared.setSettingJSON("quickConnects", JSON(Array(next.prefix(recentMax))))
    }

    /// Drop the remembered list (also when the session history is cleared).
    @MainActor static func clearHistory() {
        Store.shared.setSettingJSON("quickConnects", .array([]))
    }
}
