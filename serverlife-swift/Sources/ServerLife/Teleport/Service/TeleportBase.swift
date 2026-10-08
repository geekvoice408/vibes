import Foundation

// The tsh-home half of teleport.js and the small text helpers every part of
// the Teleport service shares. Core/Tools.swift holds the tsh lookup, the
// configured home list and the proxy → home map; this adds what teleport.js
// layered on top: the default home, home names, `activeHomes`, the
// "first home to claim a proxy owns it" rule, and the error-text cleaning.

/// Several tsh profile directories at once (teleport.js "tsh homes").
///
/// `tsh` keeps everything about who you are under one directory,
/// `TELEPORT_HOME` (`~/.tsh` by default). The app holds a list of homes
/// instead: profiles are read from every one of them, each profile remembers
/// where it came from, and from then on every tsh command for that cluster runs
/// with that home in its environment (matched by the `--proxy` it carries —
/// see `Tools.runTsh`).
enum TeleportHomes {
    /// `DEFAULT_HOME`: `$TELEPORT_HOME` (expanded), else `~/.tsh` — the one
    /// definition, `TeleportSSH.defaultHome`.
    static var defaultHome: String { TeleportSSH.defaultHome }

    private static let lock = NSLock()
    /// Proxies this module registered with `Tools.registerHome` on the last
    /// status sweep, so a sweep can forget the ones that went away
    /// (teleport.js cleared `homeByProxy` at the start of every sweep).
    nonisolated(unsafe) private static var registered: Set<String> = []

    /// `expandHome` (`TeleportSSH.expandHome`): `~` and `~/…` expanded,
    /// anything else made absolute.
    static func expand(_ p: String?) -> String { TeleportSSH.expandHome(p) }

    /// `setHomes`: replace the configured list (expanded, de-duplicated).
    /// An empty list means "just the default". Forgets the proxy → home map.
    @discardableResult
    static func setHomes(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in list.map(expand) where !p.isEmpty && !seen.contains(p) {
            seen.insert(p); out.append(p)
        }
        Tools.homes = out
        forgetAllProxies()
        return out
    }

    /// `listHomes`: the configured directories, in order.
    static var configured: [String] { Tools.homes }

    /// `activeHomes`: what is configured, or the default one.
    static var active: [String] {
        let h = Tools.homes
        return h.isEmpty ? [defaultHome] : h
    }

    /// `homeName` (`TeleportSSH.homeName`): `~/.tsh-work` → "work"; the default home → "".
    static func name(_ home: String?) -> String { TeleportSSH.homeName(home) }

    /// `isDefaultHome` (`TeleportSSH.isDefaultHome`).
    static func isDefault(_ home: String?) -> Bool { TeleportSSH.isDefaultHome(home?.trimmed) }

    /// `homeForProxy` (Core's map, tolerating :443).
    static func home(forProxy proxy: String?) -> String? { Tools.home(forProxy: proxy) }

    /// Rebuild the proxy → home map from one status sweep. `claims` is in
    /// home order; the first home to claim a proxy owns it.
    static func setClaims(_ claims: [(proxy: String, home: String)]) {
        var owned: [String: String] = [:]
        for c in claims where !c.proxy.isEmpty && owned[c.proxy] == nil { owned[c.proxy] = c.home }
        lock.lock()
        let before = registered
        registered = Set(owned.keys)
        lock.unlock()
        for p in before where owned[p] == nil { Tools.registerHome(nil, forProxy: p) }
        for (p, h) in owned { Tools.registerHome(h, forProxy: p) }
    }

    /// Drop one proxy from the map (after its profile was removed).
    static func forget(proxy: String) {
        Tools.registerHome(nil, forProxy: proxy)
        lock.lock(); registered.remove(proxy); lock.unlock()
    }

    static func forgetAllProxies() {
        lock.lock()
        let all = registered
        registered = []
        lock.unlock()
        for p in all { Tools.registerHome(nil, forProxy: p) }
    }

    /// The home to put in a command's environment when the caller knows one,
    /// or the one the proxy belongs to (`opts.home || homeForProxy(opts.proxy)`).
    static func resolve(_ home: String?, proxy: String?) -> String? {
        if let h = home?.trimmed, !h.isEmpty { return h }
        return TeleportHomes.home(forProxy: proxy)
    }
}

/// Text helpers shared by the Teleport service files.
enum TPText {
    /// `plain`: tsh colours its errors; the UI shows them as text.
    static func plain(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression).trimmed
    }

    /// `tshError`: no colour codes, no ERROR: prefix, and a fallback.
    static func tshError(_ r: ProcResult, _ fallback: String) -> String {
        let raw = r.err.isEmpty ? r.out : r.err
        let text = plain(raw.isEmpty ? r.spawnError : raw)
        let t = text.replacingOccurrences(of: #"^ERROR:\s*"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmed
        return t.isEmpty ? fallback : t
    }

    /// `(r.stderr || r.stdout)` with colour removed: what a failed run said.
    static func errText(_ r: ProcResult) -> String {
        let raw = !r.err.isEmpty ? r.err : (!r.out.isEmpty ? r.out : (r.spawnError ?? ""))
        return plain(raw)
    }

    /// Capture groups of the first match (group 0 is the whole match).
    static func match(_ pattern: String, _ s: String, _ opts: NSRegularExpression.Options = []) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return String(s[rr])
        }
    }

    /// Every match's capture groups.
    static func matches(_ pattern: String, _ s: String, _ opts: NSRegularExpression.Options = []) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
                return String(s[rr])
            }
        }
    }

    static func test(_ pattern: String, _ s: String, _ opts: NSRegularExpression.Options = []) -> Bool {
        match(pattern, s, opts) != nil
    }

    static func escapeRegex(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    /// `Date.parse` for what tsh prints: RFC 3339 with or without (any
    /// number of) fractional digits, and the `2026-10-06 03:24:39 -0700 PDT`
    /// form of the text output. Milliseconds since the epoch.
    static func parseDate(_ s: String?) -> Double? {
        guard var t = s?.trimmed, !t.isEmpty else { return nil }
        // Fractions beyond milliseconds trip the formatter; JS ignores them.
        if let m = match(#"\.(\d+)"#, t), let frac = m[1], frac.count > 3, let r = t.range(of: "." + frac) {
            t.replaceSubrange(r, with: "." + frac.prefix(3))
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d.timeIntervalSince1970 * 1000 }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d.timeIntervalSince1970 * 1000 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss ZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            // Trailing zone abbreviations ("PDT") are not something to rely on.
            let cleaned = t.replacingOccurrences(of: #"\s+[A-Z]{2,5}$"#, with: "", options: .regularExpression)
            if let d = f.date(from: cleaned) { return d.timeIntervalSince1970 * 1000 }
        }
        return nil
    }

    /// `new Date(ms).toISOString()`.
    static func isoString(ms: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// `localeCompare(…, { sensitivity: 'base', numeric: true })`.
    static func ascending(_ a: String, _ b: String) -> Bool { namesAscending(a, b) }

    /// JavaScript `String(x).slice(0, n)` on UTF-16 units, close enough on characters.
    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }
}

// MARK: - Shapes

/// One tsh profile, as `tsh status` reports it (teleport.js `statusIn` + `status`).
struct TeleportProfile: Codable, Hashable, Identifiable, Sendable {
    /// Host and port, no scheme: `example.teleport.sh:443`.
    var proxy: String
    /// The cluster the certificate currently points at ("" if tsh did not say).
    var cluster: String
    var username: String
    var logins: [String]
    var roles: [String]
    /// Ids of assumed access requests.
    var activeRequests: [String]
    /// `kind/name` of each resource a narrowed certificate allows.
    var allowedResources: [String]
    /// As tsh printed it (RFC 3339 from JSON; `2026-10-06 03:24:39 -0700 PDT` from text).
    var validUntil: String?
    var active: Bool
    var expired: Bool
    /// The home it came from, or nil for the default home.
    var home: String?
    /// The home it came from, always set (the default home included).
    var homeDir: String
    /// `TeleportHomes.name(homeDir)`: "" for the default home.
    var homeName: String

    init(proxy: String, cluster: String = "", username: String = "", logins: [String] = [], roles: [String] = [],
         activeRequests: [String] = [], allowedResources: [String] = [], validUntil: String? = nil,
         active: Bool = false, expired: Bool = false, home: String? = nil, homeDir: String = TeleportHomes.defaultHome,
         homeName: String = "") {
        self.proxy = proxy; self.cluster = cluster; self.username = username; self.logins = logins
        self.roles = roles; self.activeRequests = activeRequests; self.allowedResources = allowedResources
        self.validUntil = validUntil; self.active = active; self.expired = expired; self.home = home
        self.homeDir = homeDir; self.homeName = homeName
    }

    /// The profile key (`tpKey` in state.js) — see `TeleportProfile.key(cluster:proxy:home:)`.
    var key: String { TeleportProfile.key(cluster: cluster, proxy: proxy, home: home) }
    var id: String { key }

    /// `tpKey(p)`: the key a profile's nodes, clusters and requests are kept under.
    ///
    /// `cluster || proxy`, and when the profile is from a non-default home,
    /// `"<cluster>@@<home>"` where `<home>` is the expanded home directory
    /// (`profile.home`, which is nil for the default home). A profile in the
    /// default home keeps the bare cluster name, which is what every stored
    /// setting already refers to.
    static func key(cluster: String?, proxy: String?, home: String?) -> String {
        let c = (cluster?.isEmpty == false ? cluster : proxy) ?? ""
        if let h = home, !h.isEmpty { return "\(c)@@\(h)" }
        return c
    }

    /// Milliseconds since the epoch of `validUntil`, when it parses.
    var validUntilMs: Double? { TPText.parseDate(validUntil) }
}

/// One cluster behind a proxy (`tsh clusters`): the root and every trusted leaf.
struct TeleportCluster: Codable, Hashable, Sendable {
    var name: String
    var leaf: Bool
    var status: String
    var selected: Bool
    var labels: [String: String]?
}

/// The outcome of a tsh read: `ok`, an error to show, and what was read.
struct TshList<T> {
    var ok: Bool
    var error: String?
    var items: [T]
    static func failed(_ error: String) -> TshList { TshList(ok: false, error: error, items: []) }
}

/// The outcome of a tsh command run for its effect.
struct TshOutput: Sendable {
    var ok: Bool
    var output: String
}

/// A command for the UI to run in a terminal tab through `open-command`
/// (the `{command, args, teleportHome}` the original's `*Args` handlers returned).
struct TshCommand: Sendable {
    var command: String
    var args: [String]
    /// TELEPORT_HOME for the child, or nil to leave it alone.
    var teleportHome: String?

    var env: [String: String] {
        guard let h = teleportHome, !h.isEmpty else { return [:] }
        return ["TELEPORT_HOME": TeleportHomes.expand(h)]
    }

    /// Run it in a new terminal tab (`open-command`).
    @MainActor
    func open(title: String, window: WindowModel? = nil, onExit: ((Int32?) -> Void)? = nil) {
        var args: [String: Any] = ["title": title, "exe": command, "argv": self.args, "env": env]
        if let onExit { args["onExit"] = onExit }
        Actions.shared.perform("open-command", ActionContext(window: window, args: args))
    }
}

extension Host {
    /// A Teleport node's heartbeat expiry in ms since the epoch, or nil for a
    /// node that never expires (teleport.js `parseExpiry`: the zero date and
    /// anything before 2000 are "no expiry").
    var nodeExpiresMs: Double? {
        guard let t = TPText.parseDate(expires), t > 946_684_800_000 else { return nil }
        return t
    }

    /// The short name of the tsh home a node was read from ("" for the default).
    var nodeHomeName: String { extra["homeName"]?.string ?? "" }
}

/// A value behind a lock, usable from async code (the lock is taken only in
/// synchronous helpers). For the service's small caches.
final class TPLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    @discardableResult
    func mutate<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
