import Foundation

/// Port of requestable.js — what a cluster would let you ask for, by node id.
///
/// `tsh ls` is what you can reach; `tsh request search` is what you could ask
/// to reach. A node moves between them without changing in any way, so
/// absence from the first is never a verdict on its own. Kept behind a short
/// cache (60 s) because a check per watched host per poll would otherwise be
/// a `tsh` invocation each.
@MainActor
enum Requestable {
    static let ttlMs: Double = 60000

    struct Index {
        var at: Double
        /// uuid (or name, for apps and databases) → resource.
        var byUuid: [String: RequestableResource]
        /// The resources in the order the search returned them.
        var resources: [RequestableResource]
        var error: String?
    }

    /// The search itself (tests replace it).
    static var search: (_ proxy: String?, _ home: String?, _ kind: String) async -> TshList<RequestableResource> = { proxy, home, kind in
        await Teleport.searchRequestable(proxy: proxy, kind: kind, home: home)
    }

    private static var cache: [String: Index] = [:]

    private static func keyOf(proxy: String?, home: String?, kind: String) -> String {
        "\(proxy ?? "")\u{0}\(home ?? "")\u{0}\(kind.isEmpty ? "node" : kind)"
    }

    /// Forget everything cached, so the next question asks the cluster again.
    static func invalidate() { cache = [:] }

    /// Forget one cluster and kind.
    static func invalidate(proxy: String?, home: String?, kind: String = "node") {
        cache.removeValue(forKey: keyOf(proxy: proxy, home: home, kind: kind))
    }

    /// The requestable resources of one cluster and kind, indexed by UUID.
    /// An empty index (with `error`) on failure, never a throw: callers use
    /// this to soften a conclusion, so a failed lookup must leave them where they were.
    static func index(proxy: String?, home: String? = nil, kind: String = "node", force: Bool = false) async -> Index {
        let key = keyOf(proxy: proxy, home: home, kind: kind)
        if !force, let hit = cache[key], nowMs() - hit.at < ttlMs { return hit }
        var entry = Index(at: nowMs(), byUuid: [:], resources: [], error: nil)
        let r = await search(proxy, home, kind)
        if r.ok {
            for x in r.items {
                entry.resources.append(x)
                if !x.uuid.isEmpty { entry.byUuid[x.uuid] = x }
                // Apps and databases are named rather than identified by a UUID.
                if !x.name.isEmpty && entry.byUuid[x.name] == nil { entry.byUuid[x.name] = x }
            }
        } else {
            entry.error = r.error ?? "request search failed"
        }
        cache[key] = entry
        return entry
    }

    /// Is this node requestable on its cluster right now?
    static func isRequestable(uuid: String?, proxy: String?, home: String? = nil, kind: String = "node") async -> Bool {
        guard let uuid, !uuid.isEmpty else { return false }
        return await index(proxy: proxy, home: home, kind: kind).byUuid[uuid] != nil
    }

    /// Whether a resource is in the inventory already held — nil for "cannot
    /// say" (no list for that profile).
    static func inInventory(_ uuid: String?, proxy: String?, home: String? = nil) -> Bool? {
        guard let uuid, !uuid.isEmpty else { return nil }
        let inv = Inventory.shared
        for p in inv.profiles {
            if p.proxy != (proxy ?? "") { continue }
            if (p.homeDir.nilIfEmpty) != (home?.nilIfEmpty) { continue }
            guard let nodes = inv.nodesByKey[p.key] else { return nil }
            return nodes.contains { $0.uuid == uuid || $0.name == uuid }
        }
        return nil
    }

    /// The requestable resources of a cluster, shaped like hosts (`requestable`
    /// in extra, `id` `req:<resource id>`), sorted by name.
    static func hosts(proxy: String, home: String? = nil, cluster: String = "", kind: String = "node",
                      force: Bool = false) async -> (hosts: [Host], error: String?) {
        let idx = await index(proxy: proxy, home: home, kind: kind, force: force)
        var out: [Host] = []
        var seen = Set<String>()
        for r in idx.resources where !seen.contains(r.id) {
            seen.insert(r.id)
            var h = Host(type: Host.teleport, id: "req:\(r.id)", name: r.name.nilIfEmpty ?? r.uuid)
            h.extra["requestable"] = true
            h.extra["resourceId"] = .string(r.id)
            h.extra["kind"] = .string(r.kind.nilIfEmpty ?? kind)
            h.hostname = r.name
            h.uuid = r.uuid.nilIfEmpty ?? r.name
            h.cluster = r.cluster.nilIfEmpty ?? cluster
            h.proxy = proxy
            h.home = home
            h.labels = r.labels
            h.addr = ""
            h.tunnel = false
            out.append(h)
        }
        out.sort { namesAscending($0.name, $1.name) }
        return (out, idx.error)
    }
}
