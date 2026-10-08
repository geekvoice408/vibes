import SwiftUI

/// Per-window sidebar state (each Electron renderer had its own): which tab,
/// the filter, collapsed groups and folders, and the hosts ticked for
/// multi-exec (`state.checkedHosts`, which fleet reads).
@MainActor
@Observable
final class SidebarWindow: WindowFeature {
    @ObservationIgnored weak var window: WindowModel?

    /// hosts | saved | teleport
    var tab = "hosts"
    /// profiles | macros | s3
    var savedView = "profiles"
    /// What the filter box holds (raw, as typed).
    var filterField = ""
    /// The filter in force (trimmed; set 120 ms after typing stops).
    private(set) var filterText = ""
    @ObservationIgnored private(set) var filterMatch = Tags.compileQuery("")
    /// Collapsed group keys (not persisted, as the original).
    var collapsed: Set<String> = []
    /// Shut folders, for this run of the app.
    var foldersShut: Set<String> = []
    /// Host ids ticked for multi-exec.
    var checkedHosts: Set<String> = []
    /// Bumped when something drawn changed outside observation (requestable rows arriving).
    var tick = 0

    @ObservationIgnored let debounce = Debouncer(0.12)

    required init(window: WindowModel) { self.window = window }

    /// Set the host filter from anywhere — the box, a chip, the tag browser —
    /// keeping the field, the parsed query and the list in step.
    func setFilter(_ text: String, fromInput: Bool = false) {
        let t = text.trimmed
        filterMatch = Tags.compileQuery(t)
        filterText = t
        if !fromInput { filterField = t }
    }

    /// The field changed: apply after a short pause, as the original's debounce.
    func fieldChanged(_ value: String) {
        debounce.call { [weak self] in self?.setFilter(value, fromInput: true) }
    }

    func filterByTag(_ key: String, _ value: String) {
        setFilter(Tags.toggleTerm(filterText, Tags.termFor(key, value)))
    }

    func toggleTerm(_ term: String) { setFilter(Tags.toggleTerm(filterText, term)) }

    func hostMatches(_ h: Host) -> Bool { filterMatch.match(h) }

    /// `matches(text)` for the saved lists: a plain substring test.
    func matches(_ text: String?) -> Bool {
        filterText.isEmpty || (text ?? "").lowercased().contains(filterText.lowercased())
    }

    func toggleChecked(_ id: String) {
        if checkedHosts.contains(id) { checkedHosts.remove(id) } else { checkedHosts.insert(id) }
    }
}

/// The requestable nodes of each group, fetched on demand and kept briefly
/// (sidebar.js `reqCache`): a search is a round trip to the proxy.
@MainActor
@Observable
final class SBRequestableCache {
    static let shared = SBRequestableCache()
    static let ttlMs: Double = 120000
    private(set) var revision = 0
    @ObservationIgnored private var entries: [String: (at: Double, hosts: [Host], fetching: Bool)] = [:]

    func forget(_ key: String) { entries.removeValue(forKey: key) }

    /// The requestable nodes of one cluster, or an empty list while the
    /// answer is on its way (the redraw when it lands puts them on screen).
    func hosts(for p: TeleportProfile) -> [Host] {
        _ = revision
        let key = FolderModel.groupKey(for: p)
        guard HostPrefs.showRequestable(key) else { return [] }
        let hit = entries[key]
        if let hit, nowMs() - hit.at < Self.ttlMs { return hit.hosts }
        if hit?.fetching != true {
            entries[key] = (hit?.at ?? 0, hit?.hosts ?? [], true)
            Task { @MainActor in
                let r = await Requestable.hosts(proxy: p.proxy, home: p.homeDir.nilIfEmpty, cluster: p.cluster)
                self.entries[key] = (nowMs(), r.hosts, false)
                self.revision += 1
            }
        }
        return hit?.hosts ?? []
    }
}

/// One `ssh_config` file the list draws a group for.
struct SBConfigRoot: Hashable {
    var file: String
    var label: String
    var primary: Bool
    var exists: Bool
    var key: String { primary ? "ssh" : "ssh:" + file }
}

/// A group that can hold folders (`folderGroups`).
struct SBFolderGroup: Hashable {
    var key: String
    var label: String
    var kind: String
}

/// The host list's shared logic (sidebar.js), independent of any one window.
@MainActor
enum SB2 {
    static var inv: Inventory { Inventory.shared }

    /// `configRoots`: the files to draw a group for, never empty.
    static func configRoots() -> [SBConfigRoot] {
        let files = inv.sshConfigFiles
        if !files.isEmpty { return files.map { SBConfigRoot(file: $0.file, label: $0.label, primary: $0.primary, exists: $0.exists) } }
        return [SBConfigRoot(file: "", label: "~/.ssh/config", primary: true, exists: true)]
    }

    static func sshHosts(of root: SBConfigRoot, _ list: [Host]) -> [Host] {
        list.filter { ($0.configRoot ?? "") == root.file || (root.primary && ($0.configRoot ?? "").isEmpty) }
    }

    /// Every group that can hold folders.
    static func folderGroups() -> [SBFolderGroup] {
        var out: [SBFolderGroup] = []
        for p in inv.profiles where !p.expired {
            out.append(SBFolderGroup(key: FolderModel.groupKey(for: p), label: p.cluster.nilIfEmpty ?? p.proxy, kind: "teleport"))
        }
        for r in configRoots() { out.append(SBFolderGroup(key: r.key, label: r.label, kind: "ssh")) }
        return out
    }

    /// The hosts a group is made of — the list the sidebar draws, before the filter.
    static func hostsInGroup(_ groupKey: String) -> [Host] {
        if groupKey.isEmpty { return [] }
        if groupKey.hasPrefix("tp:") {
            for p in inv.profiles where FolderModel.groupKey(for: p) == groupKey { return inv.nodes(for: p) }
            return []
        }
        let roots = configRoots()
        let root = groupKey == "ssh" ? roots.first { $0.primary } : roots.first { "ssh:" + $0.file == groupKey }
        guard let root else { return [] }
        return sshHosts(of: root, inv.sshHosts)
    }

    /// Which group's list a host is drawn in — the scope its folders live in.
    static func groupKeyForHost(_ host: Host?) -> String {
        guard let host else { return "" }
        if host.type == Host.teleport {
            let p = inv.profiles.first { $0.cluster == host.cluster && ($0.home?.nilIfEmpty) == (host.home?.nilIfEmpty) }
            return p.map { FolderModel.groupKey(for: $0) } ?? ""
        }
        if host.type != Host.ssh { return "" }
        let roots = configRoots()
        guard let root = roots.first(where: { $0.file == (host.configRoot ?? "") }) ?? roots.first(where: { $0.primary }) else { return "" }
        return root.key
    }

    /// A group key that names a real list (not the Starred or Watched gatherings).
    static func realGroupKey(_ key: String?, for host: Host) -> String {
        if let key, !key.isEmpty, key != "starred", key != "gone" { return key }
        return groupKeyForHost(host)
    }

    /// Find the host descriptor for an id (nodes, then ssh_config hosts).
    static func hostById(_ id: String) -> Host? {
        for list in inv.nodesByKey.values { if let n = list.first(where: { $0.id == id }) { return n } }
        return inv.sshHosts.first { $0.id == id }
    }

    /// Every starred host that still exists, in the order starred.
    static func starredHosts() -> [Host] {
        var byId: [String: Host] = [:]
        for n in inv.allNodes { byId[n.id] = n }
        for h in inv.sshHosts { byId[h.id] = h }
        return HostPrefs.starredIds.compactMap { byId[$0] }
    }

    /// Quiet: stopped heartbeating, or watched and gone/unchecked.
    static func isQuiet(_ h: Host) -> Bool { h.watchMissing || h.watchUnconfirmed || Heartbeat.isStale(h) }

    /// Hidden, quiet filter, then the query.
    static func visibleHost(_ h: Host, _ sw: SidebarWindow) -> Bool {
        if HostPrefs.isHidden(h) && !HostPrefs.showHiddenHosts { return false }
        let quiet = Heartbeat.quietFilter
        if quiet == "hide" && isQuiet(h) && !h.watchMissing && !h.watchUnconfirmed { return false }
        if quiet == "only" && !isQuiet(h) { return false }
        return sw.hostMatches(h)
    }

    /// Every watched host that is missing, drawn in a group or orphaned.
    static func allGhosts() -> [Host] {
        let groups = folderGroups()
        return groups.flatMap { HostWatch.missingIn($0.key, hostsInGroup($0.key)) } + HostWatch.orphanGhosts(groups.map(\.key))
    }

    static func quietCount(_ sw: SidebarWindow) -> Int {
        (inv.allNodes + allGhosts()).filter { isQuiet($0) && sw.hostMatches($0) }.count
    }

    static func goneCount(_ sw: SidebarWindow) -> Int { allGhosts().filter { sw.hostMatches($0) }.count }

    /// The label a human would actually sort by.
    static let labelPriority = ["env", "environment", "tier", "role", "service", "app", "team", "region", "az", "os"]

    static func lastSegment(_ k: String) -> String {
        k.lowercased().split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? k.lowercased()
    }

    /// "dev +9": the most telling label, and how many more.
    static func labelSummary(_ node: Host) -> String {
        let entries = Tags.labelEntries(node)
        if entries.isEmpty { return "" }
        let preferred = labelPriority.lazy.compactMap { k in entries.first { lastSegment($0.key) == k } }.first
        let (k, v) = preferred.map { ($0.key, $0.value) } ?? (entries[0].key, entries[0].value)
        let text = v.count > 12 ? String(v.prefix(11)) + "…" : v
        let shown = text.range(of: "^(true|false)$", options: [.regularExpression, .caseInsensitive]) != nil ? k : text
        return entries.count > 1 ? "\(shown) +\(entries.count - 1)" : shown
    }

    /// The badge after an ssh host's name.
    static func sshLabel(_ h: Host) -> String { h.viaTsh ? "tsh" : (h.proxied ? "proxy" : (h.user ?? "")) }

    /// The connection state of a host's live connection, if any.
    static func connectionState(_ hostId: String) -> ConnState? {
        ConnectionManager.shared.connections.first { $0.hostId == hostId }?.state
    }

    /// Whether tsh itself is missing.
    static func tshMissing() -> Bool { inv.tshMissing }

    /// Windows-only in the original (no OpenSSH client).
    static func sshMissing() -> Bool {
        if let f = inv.toolInfo?["ssh"]["found"].bool { return !f }
        return false
    }

    /// The short name a home is known by.
    static func homeLabel(_ home: String) -> String {
        inv.profiles.first { $0.homeDir == home || $0.home == home }?.homeName.nilIfEmpty ?? home
    }

    /// The saved cluster record behind a live profile (teleportpanel.js `savedClusterFor`).
    static func savedClusterFor(_ p: TeleportProfile) -> JSON? {
        let same = Inventory.savedLogins().filter {
            Teleport.proxyAddress($0["proxy"].stringish) == Teleport.proxyAddress(p.proxy)
                && ($0["home"].stringish ?? "") == (p.home ?? "")
        }
        return same.first { ($0["user"].stringish ?? "") == p.username } ?? same.first
    }
}

// MARK: - Rows

/// One host row's placement.
struct SBHostItem {
    var host: Host
    var label: String
    var groupKey: String?
    var depth: Int = 0
    var folder: HostFolder?
}

/// What the Hosts tab draws, in order.
enum SBItem: Identifiable {
    case host(SBHostItem)
    case folder(HostFolder, count: Int, depth: Int, groupKey: String)
    case more(groupKey: String, hidden: Int)
    case empty(id: String, lines: [String], kind: SBEmptyKind)
    case narrowed(TeleportProfile, granted: Int)
    case expired(TeleportProfile)
    case beamHead(proxy: String, count: Int)
    case beam(Beam)
    case beamAdd(TeleportProfile, first: Bool)
    case local(String)

    var id: String {
        switch self {
        case .host(let h): return "h|\(h.groupKey ?? "")|\(h.folder?.id ?? "")|\(h.host.id)"
        case .folder(let f, _, _, _): return "f|\(f.id)"
        case .more(let k, _): return "more|\(k)"
        case .empty(let id, _, _): return "e|\(id)"
        case .narrowed(let p, _): return "n|\(p.key)"
        case .expired(let p): return "x|\(p.key)"
        case .beamHead(let px, _): return "bh|\(px)"
        case .beam(let b): return "b|\(b.proxy)|\(b.id)"
        case .beamAdd(let p, _): return "ba|\(p.proxy)"
        case .local(let k): return "l|\(k)"
        }
    }
}

/// What an empty-state block offers.
enum SBEmptyKind {
    case plain
    case noNodes
    case filterMiss
    case tpError(missing: Bool)
    case noSsh
    case sshEmpty(primary: Bool, showButton: Bool)
}

/// A badge on a group heading.
enum SBGroupTag {
    case home(TeleportProfile)
    case leaf(TeleportProfile)
    case requests(TeleportProfile)
    case expired
    case refresh(key: String, title: String, profile: TeleportProfile?)
    case beams(Int)
    case active
    case gathered
    case missingFile(String)
    case extraFile(String)
    case gone(Int)
    case unchecked(Int)
}

struct SBGroup: Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var count: Int
    var profile: TeleportProfile?
    var tags: [SBGroupTag] = []
    var items: [SBItem]
}

/// The panel's entries: groups, and the notes that sit between them.
enum SBEntry: Identifiable {
    case group(SBGroup)
    case note(id: String, lines: [String], kind: SBEmptyKind)
    var id: String {
        switch self {
        case .group(let g): return "G|" + g.key
        case .note(let id, _, _): return "N|" + id
        }
    }
}

@MainActor
extension SB2 {
    /// A group's rows: its folders (nested, with what is in them), then the
    /// hosts not filed anywhere — with watched ghosts first, and the per-group cap.
    static func groupRows(_ groupKey: String, _ hostsIn: [Host], _ sw: SidebarWindow, labelFor: (Host) -> String) -> [SBItem] {
        var rows: [SBItem] = []
        let filtering = !sw.filterText.isEmpty
        let ghosts = (HostWatch.missingIn(groupKey, hostsIn) + HostWatch.requestableIn(groupKey, hostsIn)
            + HostWatch.unconfirmedIn(groupKey, hostsIn)).filter { visibleHost($0, sw) }
        let hosts = ghosts.isEmpty ? hostsIn : ghosts + hostsIn

        func walk(_ parent: String?, _ depth: Int) {
            for f in FolderModel.folders(in: groupKey, parent: parent) {
                let deep = FolderModel.hostsInTree(f, hosts)
                if filtering && deep.isEmpty { continue }
                rows.append(.folder(f, count: deep.count, depth: depth, groupKey: groupKey))
                if sw.foldersShut.contains(f.id) { continue }
                walk(f.id, depth + 1)
                for h in HostPrefs.orderHosts(FolderModel.hostsInFolder(f, hosts), groupKey) {
                    rows.append(.host(SBHostItem(host: h, label: labelFor(h), groupKey: groupKey, depth: depth + 1, folder: f)))
                }
            }
        }
        walk(nil, 0)

        let loose = FolderModel.showFiledHosts ? hosts : hosts.filter { !FolderModel.isFiled($0, groupKey) }
        for h in HostPrefs.orderHosts(loose, groupKey) {
            rows.append(.host(SBHostItem(host: h, label: labelFor(h), groupKey: groupKey)))
        }

        let limit = HostPrefs.hostLimit
        if limit == 0 || filtering { return rows }
        var shown = 0, hidden = 0
        var capped: [SBItem] = []
        for r in rows {
            guard case .host(let item) = r, !item.host.watchMissing else { capped.append(r); continue }
            if shown < limit { capped.append(r); shown += 1 } else { hidden += 1 }
        }
        if hidden > 0 { capped.append(.more(groupKey: groupKey, hidden: hidden)) }
        return capped
    }

    /// The beams inside a cluster's group.
    static func beamItems(_ p: TeleportProfile, _ sw: SidebarWindow) -> [SBItem] {
        guard inv.beamsSupported(p.proxy) else { return [] }
        let all = BeamsUI.visibleBeams(p.proxy)
        let f = sw.filterText.lowercased()
        let list = f.isEmpty ? all : all.filter { JSON.encode($0).text().lowercased().contains(f) }
        if !f.isEmpty && list.isEmpty { return [] }
        var rows: [SBItem] = [.beamHead(proxy: p.proxy, count: all.count)]
        rows += list.map { .beam($0) }
        rows.append(.beamAdd(p, first: list.isEmpty))
        return rows
    }

    /// Everything the Hosts tab draws (`renderHostsTab`), groups in the user's order.
    static func hostsTab(_ sw: SidebarWindow) -> [SBEntry] {
        var entries: [SBEntry] = []
        if inv.loading && inv.nodesByKey.isEmpty && inv.sshHosts.isEmpty {
            return [.note(id: "loading", lines: ["Loading inventory…"], kind: .plain)]
        }

        // Starred, gathered.
        if HostPrefs.starredMode == "group" {
            let starred = starredHosts().filter { visibleHost($0, sw) }
            if !starred.isEmpty {
                entries.append(.group(SBGroup(key: "starred", title: "Starred", count: starred.count, tags: [.gathered],
                    items: starred.map { h in .host(SBHostItem(host: h, label: h.type == Host.teleport ? labelSummary(h) : (h.viaTsh ? "tsh" : (h.user ?? "")), groupKey: "starred")) })))
            }
        }

        // Teleport clusters.
        let beamNodes = inv.beamNodeNames()
        for p in inv.profiles {
            let key = FolderModel.groupKey(for: p)
            let nodes = inv.nodesByKey[p.key] ?? []
            let reachable = nodes.filter { !beamNodes.contains($0.name) }
            let askable = SBRequestableCache.shared.hosts(for: p)
            var have = Set(reachable.compactMap(\.uuid))
            let held = Narrowed.heldBack(for: p, reachable: reachable)
            for h in held { if let u = h.uuid { have.insert(u) } }
            let shown = (reachable + held + askable.filter { !have.contains($0.uuid ?? "") }).filter { visibleHost($0, sw) }
            let title = p.cluster.nilIfEmpty ?? p.proxy
            if p.expired {
                let ghosts = (HostWatch.missingIn(key, []) + HostWatch.unconfirmedIn(key, [])).filter { visibleHost($0, sw) }
                var items: [SBItem] = ghosts.map { .host(SBHostItem(host: $0, label: labelSummary($0), groupKey: key)) }
                items.append(.expired(p))
                entries.append(.group(SBGroup(key: key, title: title, count: 0, profile: p,
                    tags: [.home(p), .requests(p), .expired, .refresh(key: key, title: "Re-read this cluster", profile: p)],
                    items: items)))
                continue
            }
            let beamRows = beamItems(p, sw)
            if shown.isEmpty && beamRows.isEmpty && !sw.filterText.isEmpty { continue }
            var rows = groupRows(key, shown, sw) { labelSummary($0) }
            if Narrowed.isNarrowed(p) { rows.insert(.narrowed(p, granted: reachable.count), at: 0) }
            if rows.isEmpty { rows = [.empty(id: key + "|none", lines: ["No nodes visible."], kind: .noNodes)] }
            var tags: [SBGroupTag] = [.home(p), .leaf(p), .requests(p),
                                      .refresh(key: key, title: "Re-read this cluster: its nodes, its leaves and its beams", profile: p)]
            let beams = BeamsUI.visibleBeams(p.proxy).count
            if inv.beamsSupported(p.proxy) && beams > 0 { tags.append(.beams(beams)) }
            if p.active { tags.append(.active) }
            entries.append(.group(SBGroup(key: key, title: title, count: shown.count, profile: p, tags: tags, items: rows + beamRows)))
        }

        if !sw.filterText.isEmpty && inv.profiles.contains(where: { !$0.expired })
            && !inv.allNodes.contains(where: { visibleHost($0, sw) }) {
            entries.append(.note(id: "filtermiss", lines: [
                "No Teleport node matches \(sw.filterText).",
                "Tags match as key=value, key:partial, key=a,b for either, or -key=value to exclude.",
            ], kind: .filterMiss))
        }

        if let err = inv.teleportError, inv.profiles.isEmpty {
            let missing = tshMissing()
            entries.append(.group(SBGroup(key: "tp:none", title: "Teleport", count: 0, items: [
                .empty(id: "tp:none", lines: [
                    missing ? "tsh was not found on this machine." : err,
                    missing ? "Clusters are read through tsh, so nothing can be listed until it is located."
                            : "Run tsh login, then Refresh.",
                ], kind: .tpError(missing: missing)),
            ])))
        }

        // ssh_config hosts, one group per file.
        let sshShown = inv.sshHosts.filter { visibleHost($0, sw) }
        let noSsh = sshMissing()
        for root in configRoots() {
            let mine = sshHosts(of: root, sshShown)
            if !root.primary && !sw.filterText.isEmpty && mine.isEmpty { continue }
            let sshRows = groupRows(root.key, mine, sw) { sshLabel($0) }
            var rows: [SBItem] = []
            if root.primary && noSsh {
                rows.append(.empty(id: "nossh", lines: ["No ssh client on this machine.",
                                                         "These hosts need OpenSSH; Teleport nodes open with tsh ssh instead."], kind: .noSsh))
            }
            if sshRows.isEmpty {
                let line = !sw.filterText.isEmpty ? "No matches." : !root.exists ? "That file is not there." : "No hosts in \(root.label)."
                rows.append(.empty(id: root.key + "|none", lines: [line], kind: .sshEmpty(primary: root.primary, showButton: sw.filterText.isEmpty)))
            } else {
                rows += sshRows
            }
            var tags: [SBGroupTag] = []
            if !root.exists { tags.append(.missingFile(root.file)) }
            if !root.primary { tags.append(.extraFile(root.file)) }
            tags.append(.refresh(key: root.key, title: "Re-read the ssh config files", profile: nil))
            entries.append(.group(SBGroup(key: root.key, title: root.label, count: mine.count, tags: tags, items: rows)))
        }

        // This machine.
        entries.append(.group(SBGroup(key: "local", title: "Local", count: 3,
                                      items: [.local("shell"), .local("keys"), .local("nettools")])))

        // Watched hosts with nowhere left to be drawn.
        let orphans = HostWatch.orphanGhosts(folderGroups().map(\.key)).filter { sw.hostMatches($0) }
        if !orphans.isEmpty {
            let goneN = orphans.filter(\.watchMissing).count
            var tags: [SBGroupTag] = []
            if goneN > 0 { tags.append(.gone(goneN)) }
            if orphans.count - goneN > 0 { tags.append(.unchecked(orphans.count - goneN)) }
            entries.append(.group(SBGroup(key: "gone", title: "Watched", count: orphans.count, tags: tags,
                items: orphans.map { .host(SBHostItem(host: $0, label: labelSummary($0), groupKey: $0.watchGroup ?? "gone")) })))
        }

        return applyGroupOrder(entries)
    }

    /// Put the groups in the user's order, each into a slot another occupied,
    /// so the notes between them stay where they were written.
    static func applyGroupOrder(_ entries: [SBEntry]) -> [SBEntry] {
        let order = HostPrefs.groupOrder
        let groups = entries.compactMap { e -> SBGroup? in if case .group(let g) = e { return g }; return nil }
        guard groups.count >= 2, !order.isEmpty else { return entries }
        let orderedKeys = HostPrefs.orderedGroupKeys(groups.map(\.key), order: order)
        var byKey: [String: SBGroup] = [:]
        for g in groups { byKey[g.key] = g }
        var i = 0
        return entries.map { e in
            guard case .group = e else { return e }
            defer { i += 1 }
            return .group(byKey[orderedKeys[i]]!)
        }
    }

    /// The keys of the groups as they are on screen (for reordering).
    static func groupKeysOnScreen(_ sw: SidebarWindow) -> [String] {
        hostsTab(sw).compactMap { e -> String? in if case .group(let g) = e { return g.key }; return nil }
    }
}
