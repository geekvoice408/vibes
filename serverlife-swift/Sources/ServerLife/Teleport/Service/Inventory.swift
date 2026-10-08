import AppKit
import Foundation
import Observation

/// The app's live host inventory: ssh_config hosts, tsh profiles, nodes and
/// trusted clusters per profile, beams per proxy, live access requests — and
/// the loading/refresh logic the Electron renderer had (sidebar.js
/// `refreshInventory`/`refreshProfile`/`refreshSshConfigs`, nodewatch.js,
/// beams.js `refreshBeams` + loop, requestwatch.js, teleportpanel.js
/// `autoLoginSavedClusters`/`runLoginInShell`).
///
/// One instance for the whole app (the original had one per window; the
/// data is the same). Loops only do work while some window is visible.
///
/// **Change signal.** The collections are not individually observed: reading
/// any of them goes through an accessor that reads a counter, so SwiftUI (or
/// `withObservationTracking`) is invalidated only when that counter moves:
///
/// - `generation` — hosts, profiles, nodes, clusters, errors, tool info
///   (bumped by every full load, and by the background loops only when what
///   would be drawn actually changed — names, addresses, labels, expiry,
///   profile state; plus the sidebar's own `nodeSignatureExtra`).
/// - `beamsGeneration` — beams and the beams probe (only on change).
/// - `requestsGeneration` — live access requests (only on change).
///
/// `loading` and `refreshingGroups` are plain observed properties.
@MainActor
@Observable
final class Inventory {
    static let shared = Inventory()

    // MARK: Change counters

    private(set) var generation = 0
    private(set) var beamsGeneration = 0
    private(set) var requestsGeneration = 0
    /// A full load is running (`state.loadingInventory`).
    private(set) var loading = false
    /// Profiles (by `TeleportProfile.key`) or ssh config roots (by file path,
    /// or "ssh") whose own refresh is running, for a busy heading.
    private(set) var refreshingGroups: Set<String> = []
    /// Whether at least one full load has finished.
    private(set) var loadedOnce = false

    // MARK: Storage (read through the accessors below)

    @ObservationIgnored private var _sshHosts: [Host] = []
    @ObservationIgnored private var _sshConfigFiles: [SSHConfigFile] = []
    @ObservationIgnored private var _managedSshHosts: [String] = []
    @ObservationIgnored private var _profiles: [TeleportProfile] = []
    @ObservationIgnored private var _nodes: [String: [Host]] = [:]
    @ObservationIgnored private var _clusters: [String: [TeleportCluster]] = [:]
    @ObservationIgnored private var _teleportError: String?
    @ObservationIgnored private var _tshInfo: JSON?
    @ObservationIgnored private var _toolInfo: JSON?
    @ObservationIgnored private var _homeErrors: [Teleport.HomeError] = []
    @ObservationIgnored private var _beams: [String: [Beam]] = [:]
    @ObservationIgnored private var _beamSupport: [String: BeamSupport] = [:]
    @ObservationIgnored private var _requests: [String: [AccessRequest]] = [:]

    var sshHosts: [Host] { _ = generation; return _sshHosts }
    /// Which ssh_config files the hosts came from (a configured-but-missing file still has a heading).
    var sshConfigFiles: [SSHConfigFile] { _ = generation; return _sshConfigFiles }
    /// Aliases inside the ServerLife-managed block of ~/.ssh/config.
    var managedSshHosts: [String] { _ = generation; return _managedSshHosts }
    /// Every profile from every tsh home (expired ones included).
    var profiles: [TeleportProfile] { _ = generation; return _profiles }
    /// Profiles whose certificate is still valid.
    var liveProfiles: [TeleportProfile] { profiles.filter { !$0.expired } }
    /// Node lists by profile key (`TeleportProfile.key`, state.js `tpKey`).
    /// Unfiltered: beams' own `beam-<uuid>` nodes are still in here — use
    /// `nodes(for:)` for the list to draw.
    var nodesByKey: [String: [Host]] { _ = generation; return _nodes }
    /// Root + leaf clusters by profile key (`tsh clusters`).
    var clustersByKey: [String: [TeleportCluster]] { _ = generation; return _clusters }
    /// "Not logged in to Teleport", or why tsh could not be read; nil when logged in.
    var teleportError: String? { _ = generation; return _teleportError }
    /// What the last status read knew about the tsh binary (`Teleport.tshStatus`).
    var tshInfo: JSON? { _ = generation; return _tshInfo }
    /// tsh and ssh as last found (`Teleport.toolStatus`: `{tsh, ssh}`).
    var toolInfo: JSON? { _ = generation; return _toolInfo }
    var homeErrors: [Teleport.HomeError] { _ = generation; return _homeErrors }
    /// Beams by proxy, for the clusters that have the service.
    var beamsByProxy: [String: [Beam]] { _ = beamsGeneration; return _beams }
    /// The beams probe by proxy.
    var beamSupport: [String: BeamSupport] { _ = beamsGeneration; return _beamSupport }
    /// Live access requests (pending, or approved and usable) by profile key.
    var accessRequests: [String: [AccessRequest]] { _ = requestsGeneration; return _requests }

    // MARK: Hooks for other features

    /// Called with every node list that was actually read (full load, one
    /// profile's refresh, the background loop), before change detection —
    /// the sidebar's heartbeat `observe`, narrowed `noteRead` and watched-host
    /// `noteSeen` go here.
    @ObservationIgnored var nodesRead: [@MainActor (TeleportProfile, [Host]) async -> Void] = []
    /// Extra text folded into a node list's change signature (the sidebar's
    /// `heartbeatSignature`, so overdue badges keep counting). Key, nodes.
    @ObservationIgnored var nodeSignatureExtra: (@MainActor (String, [Host]) -> String)?
    /// Run near the end of every full load, before `loading` clears (folder
    /// repairs, saved profiles, macros, S3 targets …).
    @ObservationIgnored var afterLoad: [@MainActor () async -> Void] = []
    /// Event callbacks, the `state.emit('inventory'|'beams'|'requests')` of the original.
    @ObservationIgnored var onInventory: [@MainActor () -> Void] = []
    @ObservationIgnored var onBeams: [@MainActor () -> Void] = []
    @ObservationIgnored var onRequests: [@MainActor () -> Void] = []

    // MARK: Private state

    @ObservationIgnored private var fullLoad: Task<Void, Never>?
    @ObservationIgnored private var lastSig: [String: String] = [:]
    @ObservationIgnored private let nodeTimer = Repeater()
    @ObservationIgnored private let beamTimer = Repeater()
    @ObservationIgnored private let requestTimer = Repeater()
    @ObservationIgnored private var nodeInFlight = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastHomes: [String] = []
    @ObservationIgnored private var lastTshPath = ""
    @ObservationIgnored private var lastNodeSeconds: Double = -1

    private init() {}

    // MARK: - Lookups

    func profile(forKey key: String) -> TeleportProfile? { profiles.first { $0.key == key } }

    /// The profile a host belongs to (by proxy and home, else by cluster).
    func profile(for host: Host) -> TeleportProfile? {
        let ps = profiles
        let home = host.home ?? ""
        return ps.first { $0.proxy == host.proxy && ($0.home ?? "") == home }
            ?? ps.first { $0.cluster == host.cluster && ($0.home ?? "") == home }
    }

    /// The nodes to list for a profile: its node list without the
    /// `beam-<uuid>` nodes a running beam also registers as.
    func nodes(for p: TeleportProfile) -> [Host] {
        let beams = beamNodeNames()
        return (nodesByKey[p.key] ?? []).filter { !beams.contains($0.name) }
    }

    /// Every node of every profile (unfiltered).
    var allNodes: [Host] { nodesByKey.values.flatMap { $0 } }

    var nodeCount: Int { nodesByKey.values.reduce(0) { $0 + $1.count } }

    func clusters(for p: TeleportProfile) -> [TeleportCluster] { clustersByKey[p.key] ?? [] }

    /// Find a host by id among nodes, ssh hosts and beams' hosts.
    func host(id: String) -> Host? {
        allNodes.first { $0.id == id } ?? sshHosts.first { $0.id == id }
    }

    /// Whether tsh itself was not found (as opposed to not logged in).
    var tshMissing: Bool {
        let info = toolInfo?["tsh"] ?? tshInfo
        if let f = info?["found"].bool { return !f }
        return !Tools.tshAvailable
    }

    /// The sidebar's tsh badge (`updateTshBadge`): text and kind ("", ok, warn, err).
    var badge: (text: String, kind: String) {
        if loading && !loadedOnce { return ("Loading…", "") }
        let ps = profiles
        if !ps.isEmpty {
            let live = ps.filter { !$0.expired }.count
            let expired = ps.count - live
            let text = "\(nodeCount) nodes · \(live) profile\(live == 1 ? "" : "s")" + (expired > 0 ? " · \(expired) expired" : "")
            return (text, expired > 0 && live == 0 ? "err" : expired > 0 ? "warn" : "ok")
        }
        if tshMissing { return ("tsh not found", "err") }
        return ("tsh: not logged in", "warn")
    }

    // MARK: - Visibility

    /// `!document.hidden` for the app: some window is on screen.
    var anyWindowVisible: Bool {
        WindowManager.shared.windows.contains { w in
            guard let nw = w.nsWindow else { return false }
            return nw.isVisible && !nw.isMiniaturized && nw.occlusionState.contains(.visible)
        }
    }

    // MARK: - Start

    /// Apply the tsh settings, do the first full load, start the loops, then
    /// log in saved clusters flagged `autoLogin`. Called once from install().
    func start() {
        guard !started else { return }
        started = true
        applyToolSettings(force: true)
        Store.shared.onSettingsChanged.append { [weak self] in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        Task { @MainActor in
            await self.refresh()
            self.startNodeLoop()
            self.startBeamsLoop()
            self.startRequestLoop()
            // Not awaited by anything: a login can take as long as an SSO round trip.
            await self.autoLoginSavedClusters()
        }
    }

    private func applyToolSettings(force: Bool) {
        let homes: [String] = Store.shared.setting("tshHomes", [String]())
        let tshPath: String = Store.shared.setting("tshPath", "")
        if force || homes != lastHomes {
            lastHomes = homes
            TeleportHomes.setHomes(homes)
        }
        if force || tshPath != lastTshPath {
            lastTshPath = tshPath
            Tools.setTshPath(tshPath)
        }
    }

    private func settingsChanged() {
        let homesBefore = lastHomes
        applyToolSettings(force: false)
        // A changed home list is a changed inventory: the clusters on screen
        // came from the old set of directories.
        if lastHomes != homesBefore { Task { await refresh() } }
        if refreshInterval != lastNodeSeconds { startNodeLoop() }
    }

    // MARK: - Full load (refreshInventory)

    /// Re-read everything: ssh_config hosts, tsh status, nodes and clusters
    /// of every live profile, the managed aliases, beams and requests.
    /// Concurrent calls share one load.
    func refresh() async {
        if let t = fullLoad { await t.value; return }
        let t = Task { @MainActor in await self.performFullLoad() }
        fullLoad = t
        await t.value
        fullLoad = nil
    }

    private func performFullLoad() async {
        loading = true
        let extra: [String] = Store.shared.setting("sshConfigFiles", [String]())
        async let sshRes = SSHConfig.listSshHosts(extra: extra)
        async let tpRes = Teleport.status()
        _toolInfo = Teleport.toolStatus
        _sshHosts = await sshRes
        _sshConfigFiles = SSHConfig.listConfigFiles(extra)
        let st = await tpRes
        _tshInfo = st.tsh
        _profiles = st.profiles
        _homeErrors = st.homeErrors
        _teleportError = st.loggedIn ? nil : (st.error ?? "Not logged in to Teleport")

        // Nodes and trusted clusters of every profile whose certificate is
        // still valid — a leaf is not a profile, so nothing else would mention one.
        let live = st.profiles.filter { !$0.expired }
        let reads = await Inventory.readProfiles(live)
        var nodes: [String: [Host]] = [:]
        var clusters: [String: [TeleportCluster]] = [:]
        for (p, n, c) in reads {
            nodes[p.key] = n.ok ? n.items : []
            // Best effort: an old tsh, or a proxy that will not answer, means no leaf badge.
            clusters[p.key] = c.ok ? c.items : []
        }
        _nodes = nodes
        _clusters = clusters
        for (p, n, _) in reads where n.ok { await notifyRead(p, n.items) }
        for (k, list) in nodes { lastSig[k] = signature(k, list) }

        for hook in afterLoad { await hook() }
        _managedSshHosts = SSHConfig.managedAliases()

        // Beams come after the profiles, since those decide which clusters to ask.
        await refreshBeams()
        // Requests too: the loop starts before any profile is known.
        await refreshRequests()

        loading = false
        loadedOnce = true
        bump()
    }

    /// `nodes + clusters` for each profile, concurrently across profiles.
    private nonisolated static func readProfiles(_ ps: [TeleportProfile])
        async -> [(TeleportProfile, TshList<Host>, TshList<TeleportCluster>)] {
        await withTaskGroup(of: (Int, TshList<Host>, TshList<TeleportCluster>).self) { g in
            for (i, p) in ps.enumerated() {
                g.addTask {
                    async let n = Teleport.listNodes(proxy: p.proxy, cluster: p.cluster, home: p.homeDir)
                    async let c = Teleport.listClusters(proxy: p.proxy, home: p.homeDir)
                    return (i, await n, await c)
                }
            }
            var out: [(Int, TshList<Host>, TshList<TeleportCluster>)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { (ps[$0.0], $0.1, $0.2) }
        }
    }

    private func notifyRead(_ p: TeleportProfile, _ nodes: [Host]) async {
        for hook in nodesRead { await hook(p, nodes) }
    }

    private func bump() {
        generation += 1
        onInventory.forEach { $0() }
    }

    // MARK: - One profile / the ssh configs

    /// `refreshProfile`: re-read one profile's nodes, clusters and beams;
    /// everything else is left as it was.
    func refreshProfile(_ p: TeleportProfile) async {
        await withGroupBusy(p.key) {
            async let n = Teleport.listNodes(proxy: p.proxy, cluster: p.cluster, home: p.homeDir)
            async let c = Teleport.listClusters(proxy: p.proxy, home: p.homeDir)
            let (nodes, clusters) = await (n, c)
            self._nodes[p.key] = nodes.ok ? nodes.items : []
            self._clusters[p.key] = clusters.ok ? clusters.items : []
            if nodes.ok {
                await self.notifyRead(p, nodes.items)
                self.lastSig[p.key] = self.signature(p.key, nodes.items)
            }
            if self.beamsSupported(p.proxy) { await self.refreshBeams(refresh: true, proxy: p.proxy) }
            self.bump()
            let count = self._nodes[p.key]?.count ?? 0
            StatusBus.shared.show("\(p.cluster.nilIfEmpty ?? p.proxy): \(count) node\(count == 1 ? "" : "s")")
        }
    }

    /// `refreshSshConfigs`: re-read every ssh_config file (one cannot be read
    /// alone); `key` is the heading that shows as busy.
    func refreshSshConfigs(key: String = "ssh") async {
        await withGroupBusy(key) {
            let extra: [String] = Store.shared.setting("sshConfigFiles", [String]())
            self._sshHosts = await SSHConfig.listSshHosts(extra: extra)
            self._sshConfigFiles = SSHConfig.listConfigFiles(extra)
            self._managedSshHosts = SSHConfig.managedAliases()
            self.bump()
            let n = self._sshHosts.count, f = self._sshConfigFiles.count
            StatusBus.shared.show("\(n) host\(n == 1 ? "" : "s") in \(f) config file\(f == 1 ? "" : "s")")
        }
    }

    private func withGroupBusy(_ key: String, _ body: @MainActor () async -> Void) async {
        refreshingGroups.insert(key)
        await body()
        refreshingGroups.remove(key)
    }

    // MARK: - Background node loop (nodewatch.js)

    /// `refreshInterval`: settings.nodeRefreshSeconds (default 10; 0 = off).
    var refreshInterval: Double {
        let v = Store.shared.settingJSON("nodeRefreshSeconds")
        if v.isNull { return 10 }
        return max(0, v.double ?? 0)
    }

    /// Start (or restart, after the interval changed) the node loop: each
    /// tick re-reads `tsh status` and every live profile's `tsh ls`, but
    /// only while a window is visible, no full load is running and the last
    /// tick has finished.
    func startNodeLoop() {
        nodeTimer.stop()
        let s = refreshInterval
        lastNodeSeconds = s
        guard s > 0 else { return }
        nodeTimer.start(every: s) { [weak self] in self?.nodeTick() }
    }

    func stopNodeLoop() { nodeTimer.stop() }

    private func nodeTick() {
        guard anyWindowVisible, !nodeInFlight, !loading else { return }
        nodeInFlight = true
        Task { @MainActor in
            defer { self.nodeInFlight = false }
            // Expiry first, and nodes after it: a cluster that just came back
            // has its nodes read in the same pass; one that just lapsed is not asked.
            let byClock = self.markExpiredByClock()
            let byStatus = await self.refreshProfiles()
            let nodes = await self.refreshNodes(emit: false)
            if byClock || byStatus || nodes { self.bump() }
        }
    }

    /// Expiry from the clock alone: only ever moves a profile *into* expiry.
    @discardableResult
    func markExpiredByClock(now: Double = nowMs()) -> Bool {
        var changed = false
        for i in _profiles.indices {
            guard let until = _profiles[i].validUntilMs else { continue }
            let expired = until < now
            if expired != _profiles[i].expired { _profiles[i].expired = expired; changed = true }
        }
        return changed
    }

    private static func profileSignature(_ ps: [TeleportProfile]) -> String {
        ps.map { [$0.key, $0.username, $0.validUntil ?? "", $0.expired ? "x" : "", $0.active ? "a" : "",
                  $0.activeRequests.joined(separator: ",")].joined(separator: "|") }.joined(separator: ";")
    }

    /// `refreshProfiles`: re-read `tsh status` (a local read). A failed read
    /// leaves the profiles alone. Returns whether anything changed.
    @discardableResult
    func refreshProfiles() async -> Bool {
        let res = await Teleport.status()
        // An error with no profiles is "could not read", not "logged out of everything".
        if res.error != nil && res.profiles.isEmpty && !_profiles.isEmpty { return false }
        if Inventory.profileSignature(res.profiles) == Inventory.profileSignature(_profiles) { return false }
        _profiles = res.profiles
        _tshInfo = res.tsh
        _homeErrors = res.homeErrors
        _teleportError = res.loggedIn ? nil : (res.error ?? "Not logged in to Teleport")
        return true
    }

    /// What a node list *is*, cheaply comparable: ids, names, addresses,
    /// tunnel flags and labels, plus the sidebar's heartbeat signature.
    func signature(_ key: String, _ nodes: [Host]) -> String {
        let base = nodes.map { n in
            [n.id, n.name, n.addr ?? "", n.tunnel == true ? "t" : "",
             n.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")]
                .joined(separator: "\u{1}")
        }.joined(separator: "\u{2}")
        return base + "\u{3}" + (nodeSignatureExtra?(key, nodes) ?? "")
    }

    /// `refreshNodes`: re-read every live profile's nodes. Failures are per
    /// cluster and silent, and keep the previous list. Returns whether any
    /// list changed; `emit` bumps `generation` when one did.
    @discardableResult
    func refreshNodes(emit: Bool = true) async -> Bool {
        let live = _profiles.filter { !$0.expired }
        if live.isEmpty { return false }
        let reads = await withTaskGroup(of: (Int, TshList<Host>).self) { g -> [(TeleportProfile, TshList<Host>)] in
            for (i, p) in live.enumerated() {
                g.addTask { (i, await Teleport.listNodes(proxy: p.proxy, cluster: p.cluster, home: p.homeDir)) }
            }
            var out: [(Int, TshList<Host>)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { (live[$0.0], $0.1) }
        }
        var changed = false
        for (p, r) in reads where r.ok {
            await notifyRead(p, r.items)
            let key = p.key
            let before = lastSig[key] ?? signature(key, _nodes[key] ?? [])
            let now = signature(key, r.items)
            _nodes[key] = r.items
            if now == before { continue }
            lastSig[key] = now
            changed = true
        }
        if changed && emit { bump() }
        return changed
    }

    // MARK: - Beams (renderer beams.js)

    /// The profiles worth asking about beams: logged in, and not hidden.
    var beamProfiles: [TeleportProfile] {
        let hidden = Set(Store.shared.setting("hiddenBeamProxies", [String]()))
        return liveProfiles.filter { !hidden.contains($0.proxy) }
    }

    /// Marked by hand as having beams (settings.beamProxies), whatever the probe says.
    func markedAsBeams(_ proxy: String) -> Bool {
        Store.shared.setting("beamProxies", [String]()).contains(proxy)
    }

    func beamsSupported(_ proxy: String) -> Bool {
        markedAsBeams(proxy) || (beamSupport[proxy]?.ok ?? false)
    }

    func beamsFor(_ proxy: String) -> [Beam] { beamsByProxy[proxy] ?? [] }

    /// `beam-<uuid>` / `beam-<id>`: the node names running beams register as.
    func beamNodeNames() -> Set<String> {
        var names = Set<String>()
        for list in beamsByProxy.values {
            for b in list {
                if !b.uuid.isEmpty { names.insert("beam-" + b.uuid) }
                if !b.id.isEmpty { names.insert("beam-" + b.id) }
            }
        }
        return names
    }

    /// `refreshBeams`: probe (cached per proxy unless `refresh`) and list
    /// every beams-capable cluster, or just `proxy`'s.
    func refreshBeams(refresh: Bool = false, proxy: String? = nil) async {
        let wanted = proxy.map { px in beamProfiles.filter { $0.proxy == px } } ?? beamProfiles
        let marked = Set(Store.shared.setting("beamProxies", [String]()))
        let results = await withTaskGroup(of: (String, BeamSupport, TshList<Beam>?).self) { g in
            for p in wanted {
                g.addTask {
                    let probe = await Beams.supported(proxy: p.proxy, home: p.homeDir, refresh: refresh)
                    if !probe.ok && !marked.contains(p.proxy) { return (p.proxy, probe, nil) }
                    return (p.proxy, probe, await Beams.list(proxy: p.proxy, home: p.homeDir))
                }
            }
            var out: [(String, BeamSupport, TshList<Beam>?)] = []
            for await r in g { out.append(r) }
            return out
        }
        let beforeBeams = _beams, beforeSupport = _beamSupport
        for (px, probe, list) in results {
            _beamSupport[px] = probe
            if let list { _beams[px] = list.ok ? list.items : [] } else { _beams.removeValue(forKey: px) }
        }
        if _beams != beforeBeams || _beamSupport != beforeSupport {
            beamsGeneration += 1
            onBeams.forEach { $0() }
        }
    }

    /// Re-read beams every minute while a window is visible and some cluster has them.
    func startBeamsLoop() {
        beamTimer.start(every: 60) { [weak self] in
            guard let self, self.anyWindowVisible else { return }
            guard self.beamProfiles.contains(where: { self.beamsSupported($0.proxy) }) else { return }
            Task { await self.refreshBeams() }
        }
    }

    func stopBeamsLoop() { beamTimer.stop() }

    /// `hideBeamsFor`: stop listing beams for a cluster.
    func hideBeamsFor(_ proxy: String) {
        var hidden = Store.shared.setting("hiddenBeamProxies", [String]())
        if !hidden.contains(proxy) { hidden.append(proxy) }
        Store.shared.setSetting("hiddenBeamProxies", hidden)
        _beams.removeValue(forKey: proxy)
        beamsGeneration += 1
        onBeams.forEach { $0() }
    }

    func showBeamsFor(_ proxy: String) async {
        Store.shared.setSetting("hiddenBeamProxies", Store.shared.setting("hiddenBeamProxies", [String]()).filter { $0 != proxy })
        await refreshBeams(refresh: true)
    }

    /// `setMarkedAsBeams`: treat a cluster as having beams, or stop.
    func setMarkedAsBeams(_ proxy: String, _ marked: Bool) async {
        var set = Store.shared.setting("beamProxies", [String]())
        set.removeAll { $0 == proxy }
        if marked { set.append(proxy) }
        Store.shared.setSetting("beamProxies", set)
        await refreshBeams(refresh: true)
        StatusBus.shared.show(marked ? "Listing beams for this cluster" : "No longer treating this cluster as beams")
    }

    // MARK: - Access requests (requestwatch.js)

    func requestsFor(_ p: TeleportProfile) -> [AccessRequest] { accessRequests[p.key] ?? [] }

    /// Every live request across every logged-in cluster, with its profile key.
    func allLiveRequests() -> [(profileKey: String, request: AccessRequest)] {
        accessRequests.sorted { $0.key < $1.key }.flatMap { k, list in list.map { (k, $0) } }
    }

    /// Pending review, versus approved and ready to assume.
    func requestSummary(_ list: [AccessRequest]? = nil) -> (pending: Int, approved: Int, total: Int) {
        let l = list ?? allLiveRequests().map(\.request)
        let pending = l.filter { $0.state == "PENDING" }.count
        let approved = l.filter { $0.state == "APPROVED" || $0.state == "PROMOTED" }.count
        return (pending, approved, l.count)
    }

    /// `refreshRequests`: names are not resolved (that costs a search per
    /// cluster; the dialog does it when someone looks). Failures are silent.
    func refreshRequests() async {
        let live = _profiles.filter { !$0.expired }
        let before = _requests
        if live.isEmpty {
            _requests = [:]
        } else {
            let results = await withTaskGroup(of: (TeleportProfile, TshList<AccessRequest>).self) { g in
                for p in live { g.addTask { (p, await Teleport.listRequests(proxy: p.proxy, home: p.homeDir, resolveNames: false)) } }
                var out: [(TeleportProfile, TshList<AccessRequest>)] = []
                for await r in g { out.append(r) }
                return out
            }
            let now = nowMs()
            for (p, r) in results {
                let mine = r.items.filter { $0.isLive(now: now) && ($0.user.isEmpty || $0.user == p.username) }
                if mine.isEmpty { _requests.removeValue(forKey: p.key) } else { _requests[p.key] = mine }
            }
            // Profiles that are no longer live take their requests with them.
            let keys = Set(live.map(\.key))
            for k in _requests.keys where !keys.contains(k) { _requests.removeValue(forKey: k) }
        }
        if _requests != before {
            requestsGeneration += 1
            onRequests.forEach { $0() }
        }
    }

    /// Every 90 seconds while a window is visible.
    func startRequestLoop() {
        requestTimer.start(every: 90) { [weak self] in
            guard let self, self.anyWindowVisible else { return }
            Task { await self.refreshRequests() }
        }
    }

    func stopRequestLoop() { requestTimer.stop() }

    // MARK: - Logins

    /// `autoLoginSavedClusters`: saved clusters with `autoLogin` whose
    /// certificate is gone, **one at a time** (an SSO login opens a browser).
    /// A saved login naming a user opens a terminal tab instead.
    func autoLoginSavedClusters() async {
        let saved = Inventory.savedLogins()
        let wanted = saved.filter { $0["autoLogin"].truthy }
        if wanted.isEmpty { return }
        let live = _profiles
        let needed = wanted.filter { t in
            let p = live.first { $0.proxy == (t["proxy"].stringish ?? "")
                && TeleportHomes.expand($0.home) == TeleportHomes.expand(t["home"].stringish) }
            return p == nil || p!.expired
        }
        if needed.isEmpty { return }
        var done = 0
        for t in needed {
            let name = t["name"].stringish ?? t["proxy"].stringish ?? "Cluster"
            StatusBus.shared.show("Logging in to \(name)…", seconds: 0)
            let opts = Inventory.loginOptions(t)
            if opts.user != nil {
                runLoginInTerminal(opts, title: "tsh login \u{00b7} \(name)")
                continue
            }
            let r = await Teleport.login(opts)
            if r.ok {
                done += 1
                if let id = t["id"].string { Inventory.markSavedLoginUsed(id) }
            } else {
                StatusBus.shared.toast("\(name): automatic login failed — log in from the Teleport tab", kind: .error, seconds: 7)
            }
        }
        StatusBus.shared.clear()
        if done > 0 {
            await refresh()
            StatusBus.shared.show("Logged in to \(done) saved cluster\(done == 1 ? "" : "s")", seconds: 6)
        }
    }

    /// `runLoginInShell`: `tsh login` in a terminal tab (a login that names a
    /// user is heading for a prompt); the inventory is re-read when it exits.
    func runLoginInTerminal(_ o: Teleport.LoginOptions, title: String? = nil, window: WindowModel? = nil) {
        let label = o.cluster?.nilIfEmpty ?? o.proxy ?? ""
        let cmd = Teleport.loginCommandArgs(o)
        cmd.open(title: title ?? "tsh login \u{00b7} \(label)", window: window) { code in
            Task { @MainActor in
                await Inventory.shared.refresh()
                StatusBus.shared.show(code == 0 ? "Logged in to \(label)"
                                      : "tsh login exited with \(code.map(String.init) ?? "?") — the tab has what it said",
                                      seconds: 8)
            }
        }
        if let u = o.user?.nilIfEmpty { StatusBus.shared.show("Finish the login in this tab — it is asking as \(u)", seconds: 9) }
    }

    /// Saved cluster logins (store `tshLogins`), most recently used first.
    static func savedLogins() -> [JSON] {
        Store.shared.listTshLogins()
    }

    /// A saved login record as login options.
    static func loginOptions(_ t: JSON) -> Teleport.LoginOptions {
        Teleport.LoginOptions(proxy: t["proxy"].stringish, cluster: t["cluster"].stringish?.nilIfEmpty,
                              user: t["user"].stringish?.nilIfEmpty, authConnector: t["authConnector"].stringish?.nilIfEmpty,
                              ttl: t["ttl"].stringish?.nilIfEmpty, mfaMode: t["mfaMode"].stringish?.nilIfEmpty,
                              extraArgs: t["extraArgs"].stringArray, home: t["home"].stringish?.nilIfEmpty)
    }

    /// store.js `markTshLoginUsed`.
    static func markSavedLoginUsed(_ id: String) {
        Store.shared.markTshLoginUsed(id)
    }
}
