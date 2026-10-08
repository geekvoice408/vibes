import Foundation

/// Port of heartbeat.js — how long ago a node last said anything, and whether
/// that is long enough to be worth a warning.
///
/// The cluster does not publish a "last seen" time; it publishes
/// `metadata.expires`, the moment it will give up on the node. Each heartbeat
/// pushes that a full announce-TTL into the future, so
/// `age = TTL - (expires - read)`. The TTL is not in the output either: it is
/// read off the freshest node of each cluster (`observe`), rounded up to the
/// minute and only ever raised. Ages are taken as of the moment the list was
/// read, and past a grace period not at all — not looking is not the same as
/// nobody answering.
@MainActor
enum Heartbeat {
    /// Minutes of silence before a node is called stale. 0 turns it off.
    static let defaultMinutes: Double = 2

    /// The announce TTL each cluster appears to use (ms), keyed like the node lists.
    private(set) static var ttls: [String: Double] = [:]
    /// When each cluster's list was last actually read (ms).
    private(set) static var seenAt: [String: Double] = [:]
    /// The clock (tests move it).
    static var clock: () -> Double = { nowMs() }

    private static var settings: JSON { SB.store.settings }

    /// How old a list may be before it can no longer be judged: three polls,
    /// never less than ninety seconds.
    static func grace() -> Double {
        let secs = settings["nodeRefreshSeconds"].double ?? 0
        return max(90000, secs * 3000)
    }

    /// The node-list key for a node (`tpKey({cluster, proxy, home})`).
    nonisolated static func keyFor(_ node: Host) -> String {
        TeleportProfile.key(cluster: node.cluster, proxy: node.proxy, home: node.home)
    }

    /// Learn a cluster's announce TTL from a list that was just read.
    static func observe(_ key: String, _ nodes: [Host]) {
        let now = clock()
        seenAt[key] = now
        var mx: Double = 0
        for n in nodes {
            guard let e = n.nodeExpiresMs else { continue }
            mx = max(mx, e - now)
        }
        if mx <= 0 { return }
        let ttl = (mx / 60000).rounded(.up) * 60000
        if ttl > (ttls[key] ?? 0) { ttls[key] = ttl }
    }

    /// Forget everything learned (tests).
    static func reset() { ttls = [:]; seenAt = [:] }

    /// Ms since this node last heartbeated, or nil when it is not a question
    /// this node answers.
    static func heartbeatAge(_ node: Host?) -> Double? {
        guard let node, node.type == Host.teleport, let exp = node.nodeExpiresMs else { return nil }
        let key = keyFor(node)
        guard let ttl = ttls[key], ttl > 0 else { return nil }
        guard let read = seenAt[key], clock() - read <= grace() else { return nil }
        return max(0, ttl - (exp - read))
    }

    /// Silence past which a node is called stale, in ms. 0 means never.
    static func staleAfter() -> Double {
        let v = settings["staleNodeMinutes"]
        let m = v.isNull ? defaultMinutes : (v.double ?? 0)
        return max(0, m) * 60000
    }

    /// Whether every node's row spells out how long ago it last checked in.
    static var showHeartbeats: Bool { settings["showHeartbeats"].truthy }

    /// all | hide | only (anything else reads as all).
    static var quietFilter: String {
        let v = settings["quietNodeFilter"].string
        return v == "hide" || v == "only" ? v! : "all"
    }

    /// "<1m", "7m", "1h 10m"; "" when there is no age.
    static func ageLabel(_ node: Host?) -> String {
        guard let age = heartbeatAge(node) else { return "" }
        let mins = Int((age / 60000).rounded(.down))
        if mins < 1 { return "<1m" }
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }

    /// Is this node overdue, by the user's own definition?
    static func isStale(_ node: Host?) -> Bool {
        let limit = staleAfter()
        if limit == 0 { return false }
        guard let age = heartbeatAge(node) else { return false }
        return age >= limit
    }

    /// The age as a badge, or "" for a node that is not stale.
    static func staleLabel(_ node: Host?) -> String {
        guard isStale(node), let age = heartbeatAge(node) else { return "" }
        let mins = Int((age / 60000).rounded(.down))
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }

    /// The tooltip's version, for any node that has an age.
    static func heartbeatLine(_ node: Host?) -> String {
        guard let node, let age = heartbeatAge(node) else { return "" }
        let mins = Int((age / 60000).rounded(.down))
        let when = mins < 1 ? "\(Int((age / 1000).rounded(.down)))s ago" : staleAgeText(mins)
        if !isStale(node) { return "last heartbeat: \(when)" }
        let key = keyFor(node)
        let ttl = ttls[key] ?? 0
        let left = max(0, Int((((node.nodeExpiresMs ?? 0) - (seenAt[key] ?? clock())) / 60000).rounded()))
        return "last heartbeat: \(when) — the agent may be gone.\n"
            + "The cluster drops a node \(Int((ttl / 60000).rounded())) minutes after its last heartbeat; "
            + "this one has \(left) minute\(left == 1 ? "" : "s") left."
    }

    private static func staleAgeText(_ mins: Int) -> String {
        mins < 60 ? "\(mins) minute\(mins == 1 ? "" : "s") ago" : "\(mins / 60)h \(mins % 60)m ago"
    }

    /// The part of a node list's heartbeat worth redrawing for: every node's
    /// minute while ages are shown, else only the stale ones'.
    static func heartbeatSignature(_ nodes: [Host]) -> String {
        let everyone = showHeartbeats
        if !everyone && staleAfter() == 0 { return "" }
        return nodes.map { n -> String in
            let age = (everyone || isStale(n)) ? heartbeatAge(n) : nil
            return age.map { n.id + ":" + String(Int(($0 / 60000).rounded(.down))) } ?? ""
        }.joined()
    }
}
