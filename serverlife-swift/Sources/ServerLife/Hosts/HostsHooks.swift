import AppKit
import SwiftUI

/// A group that can hold folders (sidebar.js `folderGroups()` entries, and
/// the hosts pane's leaf entries).
struct FolderGroup: Hashable, Identifiable {
    var key: String
    var label: String
    /// "teleport", "ssh" or "leaf".
    var kind: String
    // Leaves (and roots matched back to their profile) carry these.
    var proxy: String?
    var home: String?
    var cluster: String?
    var id: String { key }
}

/// What a host row shows about its heartbeat (heartbeat.js `isStale`,
/// `staleLabel`, `heartbeatAge`, `ageLabel`, `heartbeatLine`).
struct HostBeat {
    var stale: Bool
    var staleLabel: String
    /// nil when no heartbeat has been seen.
    var ageLabel: String?
    var line: String
}

/// What the folder views need from the sidebar and Teleport UI. Every hook
/// has a working default built from the published inventory and settings;
/// the sidebar replaces the ones it owns the real answer to (heartbeats,
/// requestable resources, its own group list) from its `install()`.
@MainActor
enum HostsHooks {
    /// sidebar.js `folderGroups()`.
    static var folderGroups: () -> [FolderGroup] = defaultFolderGroups
    /// sidebar.js `hostsInGroup(groupKey)`: the group's hosts before any filter.
    static var hostsInGroup: (String) -> [Host] = defaultHostsInGroup
    /// heartbeat.js; nil = nothing to show.
    static var heartbeat: (Host) -> HostBeat? = { _ in nil }
    /// requestable.js `requestableHosts({proxy, home, cluster})`.
    static var requestableHosts: (_ proxy: String, _ home: String?, _ cluster: String?) async -> (hosts: [Host], error: String?) = { _, _, _ in ([], nil) }
    /// watch.js `missingIn(groupKey, present)`: watched hosts that have gone.
    static var missingIn: (String, [Host]) -> [Host] = defaultMissingIn
    /// watch.js `isWatched`.
    static var isWatched: (Host) -> Bool = { h in
        let k = h.prefKey
        return !k.isEmpty && Store.shared.settingJSON("watchedHosts")[k].truthy
    }
    /// teleportpanel.js `leavesFor(profile)`.
    static var leavesFor: (TeleportProfile) -> [TeleportCluster] = { p in Inventory.shared.clusters(for: p).filter(\.leaf) }

    static var showWatchMark: Bool { Store.shared.settingJSON("showWatchMark") != .bool(false) }

    /// clustermarks.js `clusterIcon(groupKey)`.
    static func clusterIcon(_ groupKey: String) -> String {
        Store.shared.settingJSON("clusterIcons")[groupKey].string ?? ""
    }

    /// sidebar.js `hostIcon(host)`.
    static func hostIcon(_ host: Host) -> String {
        Store.shared.settingJSON("hostIcons")[host.prefKey].string ?? ""
    }

    // MARK: Defaults

    static func defaultFolderGroups() -> [FolderGroup] {
        var out: [FolderGroup] = []
        for p in Inventory.shared.profiles where !p.expired {
            out.append(FolderGroup(key: FolderModel.groupKey(for: p), label: p.cluster.nilIfEmpty ?? p.proxy, kind: "teleport"))
        }
        for r in configRoots() {
            out.append(FolderGroup(key: r.primary ? "ssh" : "ssh:" + r.file, label: r.label, kind: "ssh"))
        }
        return out
    }

    /// sidebar.js `configRoots()`.
    static func configRoots() -> [SSHConfigFile] {
        let files = Inventory.shared.sshConfigFiles
        if !files.isEmpty { return files }
        return [SSHConfigFile(file: "", label: "~/.ssh/config", primary: true, exists: true, size: 0)]
    }

    static func defaultHostsInGroup(_ groupKey: String) -> [Host] {
        if groupKey.isEmpty { return [] }
        if groupKey.hasPrefix("tp:") {
            let beams = Inventory.shared.beamNodeNames()
            for p in Inventory.shared.profiles where FolderModel.groupKey(for: p) == groupKey {
                return (Inventory.shared.nodesByKey[p.key] ?? []).filter { !beams.contains($0.name) }
            }
            return []
        }
        let roots = configRoots()
        guard let root = groupKey == "ssh" ? roots.first(where: \.primary) : roots.first(where: { "ssh:" + $0.file == groupKey })
        else { return [] }
        return Inventory.shared.sshHosts.filter { h in
            let cr = h.extra["configRoot"]?.string ?? ""
            return cr == root.file || (root.primary && cr.isEmpty)
        }
    }

    /// The same group, allowing for the address having been written with a port.
    static func sameGroup(_ a: String?, _ b: String?) -> Bool {
        if a == b { return true }
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        let bare = { (k: String) in QuickConnect.replace(QuickConnect.re(#":\d+(?=$|@)"#), k) }
        return bare(a) == bare(b)
    }

    static func defaultMissingIn(_ groupKey: String, _ present: [Host]) -> [Host] {
        let here = Set(present.map(\.prefKey))
        return Store.shared.settingJSON("watchedHosts").entries.values
            .filter { sameGroup($0["group"].string, groupKey) }
            .filter { $0["missingSince"].truthy && !$0["requestableSince"].truthy && !here.contains($0["key"].stringish ?? "") }
            .map(ghostFrom)
    }

    /// watch.js `ghostFrom(record)`.
    static func ghostFrom(_ w: JSON) -> Host {
        var o: JSON = [:]
        o["id"] = .string("missing:\(w["key"].stringish ?? "")")
        o["type"] = w["type"]
        o["missing"] = true
        for k in ["group", "missingSince", "lastSeen", "name", "hostname", "alias", "uuid", "cluster", "proxy", "home", "addr", "tunnel"] {
            if !w[k].isNull { o[k] = w[k] }
        }
        o["watchKey"] = w["key"]
        o["labels"] = hostsOr(w["labels"], [:])
        return Host(json: o)
    }

    /// watch.js `goneFor(ms)`: "45s", "12m", "5h", "3d".
    static func goneFor(_ ms: Double?, now: Double = nowMs()) -> String {
        let secs = max(0, Int(((now - (ms ?? 0)) / 1000).rounded()))
        if secs < 90 { return "\(secs)s" }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 90 { return "\(mins)m" }
        let hours = Int((Double(mins) / 60).rounded())
        if hours < 48 { return "\(hours)h" }
        return "\(Int((Double(hours) / 24).rounded()))d"
    }

    /// watch.js `missingLine(host)`: the tooltip of a host that has gone.
    static func missingLine(_ host: Host) -> String {
        let since = host.extra["missingSince"]?.double
        let seen = host.extra["lastSeen"]?.double ?? since ?? 0
        let when = DateFormatter.localizedString(from: Date(timeIntervalSince1970: seen / 1000), dateStyle: .short, timeStyle: .medium)
        let labels = host.labels.filter { !$0.key.hasPrefix("teleport.internal/") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return [
            "Not in the inventory. You asked to be told about this one.",
            "Last seen \(when) (\(goneFor(since)) ago)",
            (host.hostname.map { $0 != host.name } ?? false) ? "hostname: \(host.hostname!)" : "",
            host.uuid.map { "node id: \($0)" } ?? "",
            host.addr.map { "last address: \($0)" } ?? "",
            host.cluster.map { "cluster: \($0)\(host.proxy.map { " (\($0))" } ?? "")" } ?? "",
            labels.isEmpty ? "" : "labels: \(labels.joined(separator: ", "))",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Acting on a host

    /// sidebar.js `requestAccessFor(host)`: a request with this node chosen.
    static func requestAccess(_ host: Host, window: WindowModel?) {
        let ps = Inventory.shared.profiles
        guard let p = ps.first(where: { $0.proxy == (host.proxy ?? "") && $0.homeDir == (host.home ?? TeleportHomes.defaultHome) })
            ?? ps.first(where: { $0.cluster == (host.cluster ?? "") })
        else { return HToast.error("Log in to that cluster first") }
        let cluster = host.cluster?.nilIfEmpty ?? p.cluster
        Actions.shared.perform("access-request-new", window: window, host: host, args: [
            "cluster": cluster, "proxy": p.proxy, "home": p.homeDir,
            "resourceIds": ["/\(cluster)/node/\(host.uuid ?? "")"],
        ])
    }

    /// The host list's right-click menu (`openHostMenu(e, host, {folder, groupKey})`):
    /// the sidebar's `host-menu` fills it.
    static func showHostMenu(_ host: Host, folder: HostFolder?, groupKey: String, window: WindowModel?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var args: [String: Any] = ["menu": menu, "groupKey": groupKey]
        if let folder { args["folderId"] = folder.id }
        if Actions.shared.isRegistered("host-menu") {
            Actions.shared.perform("host-menu", window: window, host: host, args: args)
        }
        let shown = menu.items.isEmpty
            ? CtxMenu.build([CtxItem("Open session") { HostsOpen.openFromList(host, window: window) }])
            : menu
        shown.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
