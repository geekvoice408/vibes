import Foundation

// The pure half of nettools.js (main and renderer): target validation, port
// lists, the curl argv, install hints, file names and the words each outcome
// is reported in. No I/O here, so all of it can be tested directly.

/// JavaScript's `Number(s)`, for porting `Number(x) || fallback` faithfully:
/// nil stands for NaN, and "" is 0 (falsy) exactly as in JS.
func ntNumber(_ s: String?) -> Double? {
    guard let s else { return 0 }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return 0 }
    if t.lowercased().hasPrefix("0x"), let v = Int(t.dropFirst(2), radix: 16) { return Double(v) }
    // Swift's Double() also reads "nan", "inf" and "infinity"; JS Number() reads
    // only "Infinity". Neither is a usable number anywhere here, so both are NaN.
    guard let d = Double(t), d.isFinite else { return nil }
    return d
}

/// A Double as an Int, or nil when it is not a whole number that fits —
/// `Int(Double)` traps on NaN, infinity and anything past Int.max.
func ntInt(_ d: Double?) -> Int? {
    guard let d, d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
    return Int(d)
}

/// A stored number as an Int (JSON.int traps on huge values).
func ntInt(_ j: JSON) -> Int? { ntInt(j.double) }

/// `parseInt(s, 10)`: leading digits after optional whitespace and sign;
/// nil (NaN) when there are none. Absurd lengths are capped rather than trapping.
func ntParseInt(_ s: String?) -> Int? {
    var t = Substring((s ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    var neg = false
    if let f = t.first, f == "-" || f == "+" { neg = f == "-"; t = t.dropFirst() }
    let digits = t.prefix { $0.isASCII && $0.isNumber }
    if digits.isEmpty { return nil }
    let v = digits.count > 15 ? 999_999_999_999_999 : (Int(digits) ?? 0)
    return neg ? -v : v
}

/// A port number for display and checks: out-of-range values are kept out of
/// range (so the range check says so) without trapping on conversion.
func ntPort(_ d: Double) -> Int { d > 65535 ? 65536 : d < 0 ? -1 : Int(d) }

/// `Number(s) || fallback` — nil, NaN and 0 all fall through.
func ntNumberOr(_ s: String?, _ fallback: Double) -> Double {
    guard let n = ntNumber(s), n != 0, n.isFinite else { return fallback }
    return n
}

/// `Math.min(Math.max(Number(v) || d, lo), hi)`.
func ntClamp(_ s: String?, _ d: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(ntNumberOr(s, d), lo), hi)
}

enum NetCheck {
    /// Hostnames, IPv4/IPv6 literals and nothing else. Belt-and-braces given
    /// every external command takes an argv, but it also keeps obvious
    /// nonsense out of the diagnostics before anything is spawned.
    static let hostRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:-]+$")

    static func checkHost(_ host: String?) throws -> String {
        var h = (host ?? "").ntTrimmed
        if h.hasPrefix("[") { h.removeFirst() }
        if h.hasSuffix("]") { h.removeLast() }
        if h.isEmpty { throw AppError("Give a host name or address.") }
        if h.count > 253 { throw AppError("That host name is too long.") }
        if !hostRe.matches(h) {
            throw AppError("Host names may only contain letters, digits, dot, dash, underscore and colon.")
        }
        return h
    }

    /// Strip a scheme and any path, so "https://proxy:443/web" still works.
    static func hostFromInput(_ value: String?) -> String {
        var v = (value ?? "").ntTrimmed
        if let r = v.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) {
            v.removeSubrange(r)
        }
        return String(v.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// `{ host, port }` from a target. A port that is not a number is nil
    /// (NaN in the original, which every caller treated as "no port").
    static func splitHostPort(_ value: String?) -> (host: String, port: Int?) {
        let v = hostFromInput(value)
        // [::1]:443
        if let m = firstMatch(#"^\[([^\]]+)\](?::(\d+))?$"#, v) {
            return (m[1] ?? "", m[2].flatMap { Int($0) })
        }
        // A bare IPv6 literal has more than one colon and no port.
        let colons = v.filter { $0 == ":" }.count
        if colons > 1 { return (v, nil) }
        let parts = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let h = parts.first ?? ""
        let p = parts.count > 1 ? parts[1] : ""
        guard !p.isEmpty, let n = ntNumber(p), n == n.rounded(), n != 0 else { return (h, nil) }
        return (h, ntPort(n))
    }

    /// Ports worth checking on a host you are trying to administer.
    static let defaultPorts = [22, 443, 3022, 3023, 3024, 3025, 3080]
    static let maxPorts = 32

    static func parsePorts(_ spec: String?) throws -> [Int] {
        guard let spec, !spec.isEmpty else { return defaultPorts }
        var out: [Int] = []
        for piece in spec.split(separator: ",", omittingEmptySubsequences: false) {
            let part = piece.ntTrimmed
            if part.isEmpty { continue }
            if let m = firstMatch(#"^(\d+)\s*-\s*(\d+)$"#, part) {
                let from = Double(m[1] ?? "") ?? 0
                let to = Double(m[2] ?? "") ?? 0
                if to < from { throw AppError("\"\(part)\" runs backwards.") }
                // A bounded list, deliberately: this is a reachability check
                // for one host, not a scanner.
                if to - from + 1 > Double(maxPorts) { throw AppError("Ranges are limited to \(maxPorts) ports.") }
                for i in 0...Int(to - from) { out.append(ntPort(from + Double(i))) }
            } else {
                guard let n = ntNumber(part), n == n.rounded() else {
                    throw AppError("\"\(part)\" is not a port number.")
                }
                out.append(ntPort(n))
            }
        }
        var seen = Set<Int>()
        let ports = out.filter { seen.insert($0).inserted }
        if ports.isEmpty { throw AppError("Give at least one port.") }
        if ports.contains(where: { $0 < 1 || $0 > 65535 }) { throw AppError("Ports run from 1 to 65535.") }
        if ports.count > maxPorts { throw AppError("At most \(maxPorts) ports at a time.") }
        return ports
    }

    /// The target, as telnet wants it: a host and a port (`telnetTarget` in
    /// the renderer). Takes what the shared target field holds — a bare
    /// name, `host:port`, `telnet://host:23`, even a URL left over from the
    /// last tool — and keeps only the address. Validated as tightly as the
    /// checks validate, because from a host this ends up on a command line.
    static func telnetTarget(_ value: String?, _ portField: String?) throws -> (host: String, port: Int) {
        var v = (value ?? "").ntTrimmed
        if let r = v.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) {
            v.removeSubrange(r)
        }
        v = String(v.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if let r = v.range(of: "^[^@]*@", options: .regularExpression) { v.removeSubrange(r) }
        var host = v
        var port: Double? = nil
        if let m = firstMatch(#"^\[([^\]]+)\](?::(\d+))?$"#, v) {
            host = m[1] ?? ""
            port = m[2].flatMap { Double($0) }
        } else if v.filter({ $0 == ":" }).count == 1 {
            let parts = v.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            host = parts[0]
            port = parts[1].isEmpty ? nil : (ntNumber(parts[1]) ?? .nan)
        }
        if host.isEmpty { throw AppError("Give a host") }
        if !hostRe.matches(host) || host.count > 253 {
            throw AppError("Host names may only contain letters, digits, dot, dash, underscore and colon.")
        }
        // `port || Number(portField) || 23`
        var n: Double = 23
        if let p = port, p != 0, !p.isNaN { n = p } else { n = ntNumberOr(portField, 23) }
        if n.isNaN || n != n.rounded() || n < 1 || n > 65535 { throw AppError("Ports run from 1 to 65535.") }
        return (host, Int(n))
    }

    /// Capture groups of the first match (index 0 is the whole match).
    static func firstMatch(_ pattern: String, _ s: String, options: NSRegularExpression.Options = []) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return String(s[rr])
        }
    }

    /// `net.isIP`: 4, 6 or 0.
    static func ipVersion(_ s: String) -> Int {
        var a4 = in_addr(), a6 = in6_addr()
        if inet_pton(AF_INET, s, &a4) == 1 { return 4 }
        if inet_pton(AF_INET6, s, &a6) == 1 { return 6 }
        return 0
    }
}

// MARK: - Tools

/// One entry in the tool list. `remote` says whether it can run *on* a chosen
/// host as well as from here; `needs` names what a host must have (any one).
struct NetTool: Hashable {
    let id: String
    let label: String
    var remote = false
    var needs: [String] = []

    /// The original's TOOLS, in its order.
    static let all: [NetTool] = [
        NetTool(id: "ping", label: "Ping", remote: true, needs: ["ping"]),
        NetTool(id: "curl", label: "HTTP request (curl)", remote: true),
        NetTool(id: "traceroute", label: "Traceroute", remote: true, needs: ["traceroute", "tracepath", "mtr"]),
        NetTool(id: "dns", label: "DNS"),
        NetTool(id: "ports", label: "Port check", remote: true),
        NetTool(id: "telnet", label: "Telnet", remote: true),
        NetTool(id: "tls", label: "TLS certificate"),
        NetTool(id: "http", label: "HTTP"),
        NetTool(id: "whois", label: "Whois"),
        NetTool(id: "serial", label: "Serial console"),
        NetTool(id: "teleport", label: "Teleport cluster"),
        NetTool(id: "local", label: "This machine", remote: true),
    ]

    static func find(_ id: String) -> NetTool? { all.first { $0.id == id } }
    static func label(_ id: String) -> String { find(id)?.label ?? id }
    static func canRunRemotely(_ id: String) -> Bool { find(id)?.remote ?? false }

    /// What a tool needs on the chosen host and has not got, or nil. Until the
    /// probe has answered nothing is declared missing: greying a tool out on
    /// no evidence is worse than letting it be pressed.
    static func missing(_ tool: NetTool?, _ caps: HostCaps?) -> String? {
        guard let tool, !tool.needs.isEmpty, let caps else { return nil }
        return tool.needs.contains { caps.tools.contains($0) } ? nil : tool.needs[0]
    }
}

/// What the chosen host can do (`hostTools()` in connections.js, plus the
/// `hints` main.js added).
struct HostCaps: Equatable {
    var tools: Set<String> = []
    var devtcp = false
    var ncFlavour = ""
    var busybox = false
    var pkg = ""
    var os = ""
    var canForward = false
    var canProbeDirect = false
    var transport = ""
    var at: Double = 0
    var hints: [(tool: String, hint: String)] = []
    /// Set when the probe itself failed (`{ error, tools: {} }`): no tools.
    var error: String?

    static func == (a: HostCaps, b: HostCaps) -> Bool {
        a.tools == b.tools && a.devtcp == b.devtcp && a.pkg == b.pkg && a.os == b.os && a.at == b.at
            && a.error == b.error && a.transport == b.transport
    }
}

enum NetInstall {
    /// Which package installs a tool, for an honest hint rather than a shrug.
    /// Ordered as the original's object, so hints list in the same order.
    static let packages: [(tool: String, pkgs: [String: String])] = [
        ("dig", ["apt": "dnsutils", "dnf": "bind-utils", "yum": "bind-utils", "zypper": "bind-utils", "apk": "bind-tools", "pacman": "bind", "brew": "bind"]),
        ("host", ["apt": "dnsutils", "dnf": "bind-utils", "yum": "bind-utils", "zypper": "bind-utils", "apk": "bind-tools"]),
        ("nslookup", ["apt": "dnsutils", "dnf": "bind-utils", "yum": "bind-utils"]),
        ("traceroute", ["apt": "traceroute", "dnf": "traceroute", "yum": "traceroute", "zypper": "traceroute", "apk": "traceroute", "pacman": "traceroute"]),
        ("tracepath", ["apt": "iputils-tracepath", "dnf": "iputils", "yum": "iputils"]),
        ("mtr", ["apt": "mtr-tiny", "dnf": "mtr", "yum": "mtr", "apk": "mtr", "pacman": "mtr"]),
        ("nc", ["apt": "netcat-openbsd", "dnf": "nmap-ncat", "yum": "nmap-ncat", "zypper": "netcat-openbsd", "apk": "netcat-openbsd", "pacman": "openbsd-netcat"]),
        ("curl", ["apt": "curl", "dnf": "curl", "yum": "curl", "zypper": "curl", "apk": "curl", "pacman": "curl", "brew": "curl"]),
        ("openssl", ["apt": "openssl", "dnf": "openssl", "yum": "openssl", "zypper": "openssl", "apk": "openssl", "pacman": "openssl"]),
        ("ping", ["apt": "iputils-ping", "dnf": "iputils", "yum": "iputils", "apk": "iputils"]),
        ("whois", ["apt": "whois", "dnf": "whois", "yum": "whois", "apk": "whois"]),
        ("python3", ["apt": "python3", "dnf": "python3", "yum": "python3", "apk": "python3"]),
    ]

    /// `sudo apt install dnsutils`, or "" if we cannot say.
    static func hint(_ tool: String?, _ pkgManager: String?) -> String {
        guard let tool, let pm = pkgManager,
              let pkg = packages.first(where: { $0.tool == tool })?.pkgs[pm] else { return "" }
        let verbs = ["apt": "apt install", "dnf": "dnf install", "yum": "yum install", "zypper": "zypper install",
                     "apk": "apk add", "pacman": "pacman -S", "brew": "brew install"]
        guard let verb = verbs[pm] else { return "" }
        return "\(pm == "brew" ? "" : "sudo ")\(verb) \(pkg)"
    }
}

// MARK: - Outcomes

/// How each port outcome reads, and what it means. "closed" was two answers
/// wearing one word: a refusal is a host that answered, silence is a firewall
/// or a wrong address, and only the first is fixable on the far end.
struct PortStateInfo {
    let cls: String
    let label: String
    let why: String

    static let table: [String: PortStateInfo] = [
        "open": PortStateInfo(cls: "open", label: "open", why: "the connection was accepted"),
        "closed": PortStateInfo(cls: "closed", label: "refused", why: "the host answered — nothing is listening on that port"),
        "filtered": PortStateInfo(cls: "unknown", label: "no answer", why: "nothing came back before the timeout — dropped, most likely by a firewall"),
        "dns": PortStateInfo(cls: "unknown", label: "unknown name", why: "the name could not be resolved from there"),
        "error": PortStateInfo(cls: "unknown", label: "error", why: "the connection could not be attempted"),
        "unknown": PortStateInfo(cls: "unknown", label: "unknown", why: "the check could not be completed"),
    ]

    /// `state` carries the verdict; a result without one has only open/closed.
    static func of(state: String?, open: Bool? = nil) -> PortStateInfo {
        if let s = state, let v = table[s] { return v }
        return table[open == true ? "open" : open == false ? "closed" : "unknown"]!
    }
}

enum NetText {
    static func firstLine(_ text: String?) -> String {
        (text ?? "").split(separator: "\n").map { $0.ntTrimmed }.first { !$0.isEmpty } ?? ""
    }

    /// A file-name-safe version of a target.
    static func safeName(_ s: String?) -> String {
        var v = s ?? ""
        if v.isEmpty { v = "output" }
        if let r = v.range(of: "^[a-z]+://", options: [.regularExpression, .caseInsensitive]) { v.removeSubrange(r) }
        v = v.replacingOccurrences(of: "[^A-Za-z0-9_.-]+", with: "_", options: .regularExpression)
        let out = String(v.prefix(60))
        return out.isEmpty ? "output" : out
    }

    static func shortUrl(_ u: String) -> String {
        let full = u.range(of: "^[a-z]+://", options: [.regularExpression, .caseInsensitive]) != nil ? u : "https://" + u
        guard let c = URLComponents(string: full), let host = c.host, !host.isEmpty else { return u }
        var path = c.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        return host.lowercased() + (c.port.map { ":\($0)" } ?? "") + path
    }

    static func bodyExt(_ type: String?) -> String {
        let t = type ?? ""
        if t.contains("json") { return ".json" }
        if t.contains("html") { return ".html" }
        if t.contains("xml") { return ".xml" }
        if t.contains("csv") { return ".csv" }
        return ".txt"
    }

    /// The line of ping's summary worth putting in the recent list.
    static func pingNote(text: String, missing: String?) -> String {
        if missing != nil { return "no ping on that host" }
        let loss = NetCheck.firstMatch(#"([\d.]+)% packet loss"#, text)?[1]
        let rtt = NetCheck.firstMatch(#"=\s*([\d.]+)/([\d.]+)/([\d.]+)"#, text)?[2]
        return [loss.map { "\($0)% loss" }, rtt.map { "\($0)ms avg" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// `JSON.stringify(x, null, 2)` as the original wrote results to disk.
    static func pretty(_ j: JSON) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: j.any,
                                                  options: [.prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]) else { return j.text() }
        // Foundation indents with two spaces already (macOS 10.15+); keep it.
        return String(decoding: d, as: UTF8.self).replacingOccurrences(of: " : ", with: ": ")
    }
}

extension StringProtocol {
    /// `trimmed` for strings and substrings alike.
    var ntTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
