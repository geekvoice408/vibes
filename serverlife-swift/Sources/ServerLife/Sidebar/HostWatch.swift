import Foundation

/// Port of watch.js — hosts you want to be told about when they stop existing.
///
/// Marking a host keeps its UUID and the last thing known about it (name,
/// address, labels, cluster, when last seen) in `settings.watchedHosts`,
/// keyed by `hostKey`. A host is only ever declared gone off the back of a
/// *successful* read of its group (`noteSeen`); an empty read needs a second,
/// ten minutes later, before it concludes anything; a host missing from the
/// node list is first looked for in `tsh request search` ("out of reach is
/// not gone"); a narrowed read concludes nothing about what it leaves out.
///
/// Absent hosts are drawn host-shaped from their record (`missingIn`,
/// `requestableIn`, `unconfirmedIn`, `orphanGhosts`) with flags in `extra` —
/// read them through the `Host` accessors at the bottom of this file.
@MainActor
enum HostWatch {
    /// Called after every write (the sidebar and hosts panes redraw from settings anyway).
    static var onChange: [() -> Void] = []

    private static var all: [String: JSON] { SB.store.settingJSON("watchedHosts").entries }

    static func isWatched(_ host: Host) -> Bool {
        let k = FolderModel.hostKey(host)
        return !k.isEmpty && all[k]?.truthy == true
    }

    /// What we last knew about a watched host, or nil.
    static func record(_ host: Host) -> JSON? { all[FolderModel.hostKey(host)] }

    /// The same group, allowing for the address having been written with and
    /// without its port.
    nonisolated static func sameGroup(_ a: String?, _ b: String?) -> Bool {
        if a == b { return true }
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        func bare(_ k: String) -> String {
            k.replacingOccurrences(of: #":\d+(?=$|@)"#, with: "", options: .regularExpression, range: k.range(of: #":\d+(?=$|@)"#, options: .regularExpression))
        }
        return bare(a) == bare(b)
    }

    /// Every watched record filed against one group.
    static func watchedIn(_ groupKey: String) -> [JSON] {
        all.values.filter { sameGroup($0["group"].string, groupKey) }.sorted { ($0["key"].string ?? "") < ($1["key"].string ?? "") }
    }

    /// Watched hosts that are gone (or unchecked, or askable) and have nowhere
    /// to be drawn, given the groups that are being drawn. Never reported as
    /// gone: their cluster cannot be checked now.
    static func orphanGhosts(_ drawnKeys: [String] = [], now: Double = nowMs()) -> [Host] {
        let drawn = drawnKeys.filter { !$0.isEmpty }
        let after = unconfirmedAfterMs()
        let loose = all.values.filter { w in !drawn.contains { sameGroup(w["group"].string, $0) } }
            .sorted { ($0["key"].string ?? "") < ($1["key"].string ?? "") }
        return loose
            .filter { w in w["missingSince"].truthy || w["requestableSince"].truthy || now - (w["lastSeen"].double ?? 0) > after }
            .map { w in
                var g = ghostFrom(w)
                g.extra["missing"] = false
                if w["requestableSince"].truthy {
                    g.extra["requestable"] = true
                    g.extra["requestableSince"] = w["requestableSince"]
                } else {
                    g.extra["unconfirmed"] = true
                }
                return g
            }
    }

    static func watchCount() -> Int { all.count }

    /// Whether a watched host wears its bell (on by default).
    static var showWatchMark: Bool { SB.store.settingJSON("showWatchMark").bool != false }

    /// Stop watching everything.
    static func forgetAll() { save([:]) }

    /// The watched hosts that are currently missing, wherever they were.
    static func missingHosts() -> [JSON] { all.values.filter { $0["missingSince"].truthy } }

    // MARK: Writing

    private static func save(_ map: [String: JSON]) {
        SB.store.updateSettings(["watchedHosts": .object(map)])
        onChange.forEach { $0() }
    }

    /// Everything worth keeping about a host that may be about to disappear.
    static func snapshot(_ host: Host, _ groupKey: String) -> [String: JSON] {
        [
            "key": .string(FolderModel.hostKey(host)),
            "group": .string(groupKey),
            "type": .string(host.type.isEmpty ? Host.teleport : host.type),
            "uuid": JSON(host.uuid?.nilIfEmpty),
            "name": .string(host.name.nilIfEmpty ?? host.alias ?? ""),
            "hostname": .string(host.hostname ?? ""),
            "alias": JSON(host.alias?.nilIfEmpty),
            "cluster": JSON(host.cluster?.nilIfEmpty),
            "proxy": JSON(host.proxy?.nilIfEmpty),
            "home": JSON(host.home?.nilIfEmpty),
            "addr": .string(host.addr ?? ""),
            "tunnel": .bool(host.tunnel == true),
            "labels": .object(host.labels.mapValues { .string($0) }),
            "lastSeen": .number(nowMs()),
            "missingSince": .null,
        ]
    }

    private static func merged(_ base: JSON?, _ patch: [String: JSON]) -> JSON {
        var o = base?.object ?? [:]
        for (k, v) in patch { o[k] = v }
        return .object(o)
    }

    static func setWatched(_ host: Host, _ groupKey: String, _ on: Bool) {
        let k = FolderModel.hostKey(host)
        guard !k.isEmpty else { return }
        var map = all
        if on { map[k] = merged(map[k], snapshot(host, groupKey)) } else { map.removeValue(forKey: k) }
        save(map)
        let n = host.name.nilIfEmpty ?? host.alias ?? ""
        StatusBus.shared.show(on ? "Watching \(n) — you will be told if it leaves the inventory" : "No longer watching \(n)")
    }

    static func toggleWatch(_ host: Host, _ groupKey: String) { setWatched(host, groupKey, !isWatched(host)) }

    /// Stop watching, and take the record with it.
    static func forget(_ key: String) {
        var map = all
        map.removeValue(forKey: key)
        save(map)
    }

    // MARK: Noticing

    /// When each group last answered with nothing at all (in memory on purpose).
    private static var emptyReadAt: [String: Double] = [:]
    static let emptyCorroborationMs: Double = 10 * 60000

    static func forgetEmptyReads(_ groupKey: String? = nil) {
        if let groupKey { emptyReadAt.removeValue(forKey: groupKey) } else { emptyReadAt = [:] }
    }

    /// What changed in one `noteSeen`, for the caller to announce.
    struct Change {
        var gone: [JSON]
        var back: [JSON]
        var askable: [JSON]
    }

    /// Of the records missing from a list, which are requestable instead?
    /// A failed search says nothing either way.
    private static func requestableAmong(_ records: [JSON]) async -> [String: RequestableResource] {
        var out: [String: RequestableResource] = [:]
        var groups: [String: (proxy: String, home: String?, items: [JSON])] = [:]
        var order: [String] = []
        for w in records {
            guard let uuid = w["uuid"].string, !uuid.isEmpty, let proxy = w["proxy"].string, !proxy.isEmpty else { continue }
            let key = "\(proxy)\u{0}\(w["home"].string ?? "")"
            if groups[key] == nil { groups[key] = (proxy, w["home"].string?.nilIfEmpty, []); order.append(key) }
            groups[key]!.items.append(w)
        }
        for k in order {
            let g = groups[k]!
            let idx = await Requestable.index(proxy: g.proxy, home: g.home, kind: "node")
            if idx.error != nil { continue }
            for w in g.items {
                if let uuid = w["uuid"].string, let r = idx.byUuid[uuid], let key = w["key"].string { out[key] = r }
            }
        }
        return out
    }

    /// A group's list has just been read: update the records and work out
    /// what has gone, come back or become requestable. `partial` is a list
    /// known to be incomplete (a narrowed certificate). nil when nothing changed
    /// worth saying.
    @discardableResult
    static func noteSeen(_ groupKey: String, _ hosts: [Host], now: Double = nowMs(), partial: Bool = false) async -> Change? {
        let watched = watchedIn(groupKey)
        if watched.isEmpty { return nil }

        let emptyRead = hosts.isEmpty
        if partial {
            // A narrowed read neither starts nor ends a run of empty reads.
        } else if emptyRead {
            if emptyReadAt[groupKey] == nil { emptyReadAt[groupKey] = now }
        } else {
            emptyReadAt.removeValue(forKey: groupKey)
        }
        let mayConclude = !emptyRead || (now - (emptyReadAt[groupKey] ?? now)) >= emptyCorroborationMs

        var byKey: [String: Host] = [:]
        for h in hosts { byKey[FolderModel.hostKey(h)] = h }
        var map = all
        var gone: [JSON] = [], back: [JSON] = [], askable: [JSON] = []
        var changed = false

        let absent = partial ? [] : watched.filter { byKey[$0["key"].string ?? ""] == nil }
        let requestable = absent.isEmpty ? [:] : await requestableAmong(absent)

        for w in watched {
            let key = w["key"].string ?? ""
            if let host = byKey[key] {
                if w["missingSince"].truthy || w["requestableSince"].truthy { back.append(w); changed = true }
                var patch = snapshot(host, groupKey)
                patch["requestableSince"] = .null
                map[key] = merged(w, patch)
                changed = true
            } else if partial {
                continue
            } else if requestable[key] != nil {
                if !w["requestableSince"].truthy {
                    let rec = merged(w, ["missingSince": .null, "requestableSince": .number(now)])
                    map[key] = rec
                    askable.append(rec)
                    changed = true
                } else if w["missingSince"].truthy {
                    map[key] = merged(w, ["missingSince": .null])
                    changed = true
                }
            } else if !w["missingSince"].truthy && mayConclude {
                let rec = merged(w, ["missingSince": .number(now), "requestableSince": .null])
                map[key] = rec
                gone.append(rec)
                changed = true
            }
        }

        if !changed { return nil }
        save(map)
        if !askable.isEmpty { Requestable.invalidate() }
        return gone.isEmpty && back.isEmpty && askable.isEmpty ? nil : Change(gone: gone, back: back, askable: askable)
    }

    /// The sentence to show when a watched host goes, or comes back.
    nonisolated static func announcement(_ w: JSON, _ kind: String) -> String {
        let name = w["name"].stringish ?? ""
        let where_ = w["cluster"].string?.nilIfEmpty ?? w["group"].string ?? ""
        return kind == "gone" ? "\(name) is no longer in \(where_) — you were watching it" : "\(name) is back in \(where_)"
    }

    // MARK: Drawing

    /// The gone hosts a group should draw (not requestable, not present).
    static func missingIn(_ groupKey: String, _ present: [Host] = []) -> [Host] {
        let here = Set(present.map(FolderModel.hostKey))
        return watchedIn(groupKey)
            .filter { $0["missingSince"].truthy && !$0["requestableSince"].truthy && !here.contains($0["key"].string ?? "") }
            .map(ghostFrom)
    }

    /// Watched hosts that are out of reach but askable for.
    static func requestableIn(_ groupKey: String, _ present: [Host] = []) -> [Host] {
        let here = Set(present.map(FolderModel.hostKey))
        return watchedIn(groupKey)
            .filter { $0["requestableSince"].truthy && !here.contains($0["key"].string ?? "") }
            .map { w in
                var g = ghostFrom(w)
                g.extra["missing"] = false
                g.extra["requestable"] = true
                g.extra["requestableSince"] = w["requestableSince"]
                return g
            }
    }

    /// A record, drawn as the host it used to be.
    static func ghostFrom(_ w: JSON) -> Host {
        let key = w["key"].string ?? ""
        var h = Host(type: w["type"].string ?? Host.teleport, id: "missing:\(key)", name: w["name"].stringish ?? "")
        h.extra["missing"] = true
        h.extra["watchKey"] = .string(key)
        h.extra["group"] = w["group"]
        h.extra["missingSince"] = w["missingSince"]
        h.extra["lastSeen"] = w["lastSeen"]
        h.hostname = w["hostname"].string
        h.alias = w["alias"].string
        h.uuid = w["uuid"].string
        h.cluster = w["cluster"].string
        h.proxy = w["proxy"].string
        h.home = w["home"].string
        h.addr = w["addr"].string
        h.tunnel = w["tunnel"].bool
        h.labels = w["labels"].entries.compactMapValues(\.stringish)
        return h
    }

    /// How long without a successful read before a watch is "unchecked":
    /// six polls, never less than five minutes.
    static func unconfirmedAfterMs() -> Double {
        let secs = SB.store.settingJSON("nodeRefreshSeconds").double ?? 0
        let poll = secs > 0 && secs.isFinite ? secs : 30
        return max(5 * 60000, poll * 6000)
    }

    static func unconfirmedIn(_ groupKey: String, _ present: [Host] = [], now: Double = nowMs()) -> [Host] {
        let here = Set(present.map(FolderModel.hostKey))
        let after = unconfirmedAfterMs()
        return watchedIn(groupKey)
            .filter { w in !w["missingSince"].truthy && !w["requestableSince"].truthy
                && !here.contains(w["key"].string ?? "") && now - (w["lastSeen"].double ?? 0) > after }
            .map { w in
                var g = ghostFrom(w)
                g.extra["missing"] = false
                g.extra["unconfirmed"] = true
                return g
            }
    }

    /// `toLocaleString` for the tooltips.
    nonisolated static func localeString(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// The tooltip for a host nobody has been able to check.
    static func unconfirmedLine(_ host: Host) -> String {
        let when = host.watchLastSeen.map(localeString) ?? "never"
        return [
            "Not confirmed. The cluster it is in could not be read, so this says nothing",
            "about the host itself — only that nobody has been able to look.",
            "Last confirmed \(when) (\(goneFor(host.watchLastSeen ?? 0)) ago)",
            host.watchMissingSince.map { "It was absent from the last list that could be read (\(localeString($0)))." } ?? "",
            host.uuid.map { "node id: \($0)" } ?? "",
            host.cluster?.nilIfEmpty.map { "cluster: \($0)" } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "30s", "20m", "5h", "6d" — how long something has been gone.
    nonisolated static func goneFor(_ ms: Double, now: Double = nowMs()) -> String {
        let secs = max(0, Int(((now - ms) / 1000).rounded()))
        if secs < 90 { return "\(secs)s" }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 90 { return "\(mins)m" }
        let hours = Int((Double(mins) / 60).rounded())
        if hours < 48 { return "\(hours)h" }
        return "\(Int((Double(hours) / 24).rounded()))d"
    }

    /// The tooltip for a host that is not there any more.
    static func missingLine(_ host: Host) -> String {
        let when = localeString(host.watchLastSeen ?? host.watchMissingSince ?? 0)
        let labels = host.labels.sorted { $0.key < $1.key }.filter { !$0.key.hasPrefix("teleport.internal/") }.map { "\($0.key)=\($0.value)" }
        let hn = host.hostname ?? ""
        return [
            "Not in the inventory. You asked to be told about this one.",
            "Last seen \(when) (\(goneFor(host.watchMissingSince ?? 0)) ago)",
            !hn.isEmpty && hn != host.name ? "hostname: \(hn)" : "",
            host.uuid.map { "node id: \($0)" } ?? "",
            host.addr?.nilIfEmpty.map { "last address: \($0)" } ?? "",
            host.cluster?.nilIfEmpty.map { "cluster: \($0)\(host.proxy?.nilIfEmpty.map { " (\($0))" } ?? "")" } ?? "",
            labels.isEmpty ? "" : "labels: \(labels.joined(separator: ", "))",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The flags a host-shaped row carries (watch.js ghosts, requestable.js rows,
/// narrowed.js held-back nodes), read from `extra`.
extension Host {
    /// Watched, and gone from a successful read of its cluster.
    var watchMissing: Bool { extra["missing"]?.bool == true }
    /// Watched, and nobody has been able to check it.
    var watchUnconfirmed: Bool { extra["unconfirmed"]?.bool == true }
    /// Out of reach but requestable (a watched one, or a requestable-node row).
    var isRequestableRow: Bool { extra["requestable"]?.bool == true }
    /// Out of reach while an assumed request narrows the certificate.
    var isHeldBack: Bool { extra["heldBack"]?.bool == true }
    var heldBy: [String] { extra["heldBy"]?.stringArray ?? [] }
    /// The watch record's key (ghost rows).
    var watchKey: String? { extra["watchKey"]?.string }
    var watchGroup: String? { extra["group"]?.string }
    var watchMissingSince: Double? { extra["missingSince"]?.double }
    var watchLastSeen: Double? { extra["lastSeen"]?.double }
    var requestableSince: Double? { extra["requestableSince"]?.double }
    /// The resource id of a requestable-node row (`/cluster/node/uuid`).
    var requestResourceId: String? { extra["resourceId"]?.string }
    /// ssh_config extras.
    var configRoot: String? { extra["configRoot"]?.string }
    var viaTsh: Bool { extra["viaTsh"]?.bool == true }
    var proxied: Bool { extra["proxied"]?.bool == true }
}
