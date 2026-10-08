import Foundation

/// The per-host and per-cluster preferences of sidebar.js: preferred username,
/// remembered logins, MFA hosts, agent forwarding / tmux / file browser at
/// three levels, colour, icon, careful, stars, hidden hosts, the manual host
/// order and group order. Same settings keys as the original; per-host prefs
/// are keyed by `host.prefKey`, per-cluster by `host.clusterPrefKey`.
@MainActor
enum HostPrefs {
    private static var s: JSON { SB.store.settings }
    private static func set(_ key: String, _ v: JSON) { SB.store.updateSettings([key: v]) }
    private static func say(_ text: String) { StatusBus.shared.show(text) }

    nonisolated static func label(_ h: Host) -> String { h.name.nilIfEmpty ?? h.alias ?? "" }

    /// A three-level answer: on/off and where it came from ("host", "cluster",
    /// "default", or "mfa" for tmux).
    struct Level: Equatable { var on: Bool; var from: String }

    // MARK: MFA hosts (by host id, as the original)

    static func isMfaHost(_ id: String) -> Bool { s["mfaHosts"].stringArray.contains(id) }

    static func setMfaHost(_ host: Host, _ remember: Bool) {
        var cur = s["mfaHosts"].stringArray.filter { $0 != host.id }
        if remember { cur.append(host.id) }
        set("mfaHosts", JSON(cur))
        say(remember ? "\(label(host)) remembered as an MFA server" : "\(label(host)) no longer marked as MFA")
    }

    // MARK: Logins

    /// The username set deliberately for this host, if any.
    static func preferredUser(_ host: Host) -> String { s["hostUsers"][host.prefKey].string ?? "" }

    static func setPreferredUser(_ host: Host, _ value: String) {
        var map = s["hostUsers"].entries
        if value.isEmpty { map.removeValue(forKey: host.prefKey) } else { map[host.prefKey] = .string(value) }
        set("hostUsers", .object(map))
        say(value.isEmpty ? "Preferred username cleared" : "\(label(host)) will connect as \(value)")
    }

    /// The logins the cluster certificate grants (the profile in the node's
    /// own tsh home first), or the ssh host's user.
    static func loginOptions(_ host: Host) -> [String] {
        if host.type == Host.teleport {
            let ps = Inventory.shared.profiles
            let p = ps.first { $0.cluster == host.cluster && ($0.home?.nilIfEmpty) == (host.home?.nilIfEmpty) }
                ?? ps.first { $0.cluster == host.cluster }
            return p?.logins ?? []
        }
        return host.user.map { [$0] } ?? []
    }

    /// Which login to connect as: the pinned one, else the one that last
    /// worked (if the cluster still grants it), else the cluster's first.
    static func preferredLogin(_ host: Host) -> String? {
        let explicit = preferredUser(host)
        if !explicit.isEmpty { return explicit }
        let remembered = s["hostLogins"][host.id].string
        let options = loginOptions(host)
        if let r = remembered, !r.isEmpty, options.isEmpty || options.contains(r) { return r }
        return options.first
    }

    /// Remember the login that actually connected for this host.
    static func rememberLogin(_ hostId: String, _ login: String?) {
        guard !hostId.isEmpty, let login, !login.isEmpty else { return }
        var map = s["hostLogins"].entries
        if map[hostId]?.string == login { return }
        map[hostId] = .string(login)
        set("hostLogins", .object(map))
    }

    // MARK: Three-level switches

    private static func level(_ host: Host, hostKey: String, clusterKey: String, defaultOn: Bool) -> Level {
        let hk = host.prefKey
        if !hk.isEmpty, let v = s[hostKey].object?[hk] { return Level(on: v.truthy, from: "host") }
        let ck = host.clusterPrefKey
        if !ck.isEmpty, let v = s[clusterKey].object?[ck] { return Level(on: v.truthy, from: "cluster") }
        return Level(on: defaultOn, from: "default")
    }

    private static func setLevel(_ mapKey: String, _ key: String, _ value: Bool?) {
        var map = s[mapKey].entries
        if let value { map[key] = .bool(value) } else { map.removeValue(forKey: key) }
        set(mapKey, .object(map))
    }

    private static func clusterValue(_ mapKey: String, _ key: String) -> Bool? {
        s[mapKey].object?[key].map(\.truthy)
    }

    // Agent forwarding

    static func agentForward(_ host: Host) -> Level {
        level(host, hostKey: "agentForwardHosts", clusterKey: "agentForwardClusters", defaultOn: s["agentForward"].truthy)
    }

    static func setAgentForward(_ host: Host, _ value: Bool?) {
        setLevel("agentForwardHosts", host.prefKey, value)
        let st = agentForward(host)
        say(value == nil
            ? "\(label(host)): agent forwarding follows the \(st.from) setting (\(st.on ? "on" : "off"))"
            : "\(label(host)): agent forwarding \(value! ? "on" : "off")")
    }

    static func setAgentForwardForCluster(_ key: String, _ value: Bool?) {
        setLevel("agentForwardClusters", key, value)
        say(value == nil ? "Agent forwarding for \(key) follows the global preference"
                         : "Agent forwarding \(value! ? "on" : "off") for \(key)")
    }

    static func clusterAgentForward(_ key: String) -> Bool? { clusterValue("agentForwardClusters", key) }

    static var globalAgentForward: Bool { s["agentForward"].truthy }

    // tmux

    static func tmux(_ host: Host) -> Level {
        if isMfaHost(host.id) { return Level(on: false, from: "mfa") }
        return level(host, hostKey: "tmuxHosts", clusterKey: "tmuxClusters", defaultOn: s["tmuxDefault"].bool == true)
    }

    static func opensInTmux(_ host: Host) -> Bool { tmux(host).on }

    /// The tmux session to attach to: per host if said, else the global name.
    static func tmuxName(_ host: Host) -> String {
        let hk = host.prefKey
        if !hk.isEmpty, let n = s["tmuxSessionNames"][hk].string, !n.isEmpty { return n }
        return s["tmuxSessionName"].string?.nilIfEmpty ?? "serverlife"
    }

    static func setTmux(_ host: Host, _ value: Bool?) {
        setLevel("tmuxHosts", host.prefKey, value)
        let st = tmux(host)
        say(value == nil
            ? "\(label(host)): follows the \(st.from == "cluster" ? "cluster" : "global") setting (\(st.on ? "tmux" : "plain session"))"
            : "\(label(host)): \(value! ? "always opens in tmux" : "never opens in tmux")")
    }

    static func setTmuxForCluster(_ key: String, _ value: Bool?) { setLevel("tmuxClusters", key, value) }

    static func clusterTmux(_ key: String) -> Bool? { clusterValue("tmuxClusters", key) }

    static var tmuxDefault: Bool { s["tmuxDefault"].truthy }

    static func setTmuxEverywhere(_ on: Bool) {
        set("tmuxDefault", .bool(on))
        say(on ? "New sessions open in tmux everywhere — hosts and clusters can still say otherwise"
               : "New sessions are plain again")
    }

    static func setTmuxName(_ host: Host, _ name: String) {
        var names = s["tmuxSessionNames"].entries
        let n = name.trimmed
        if n.isEmpty { names.removeValue(forKey: host.prefKey) } else { names[host.prefKey] = .string(n) }
        set("tmuxSessionNames", .object(names))
        say("tmux session: \(tmuxName(host))")
    }

    // The file browser

    static var globalOpenFiles: Bool { s["explorersVisible"].bool != false }

    static func openFiles(_ host: Host) -> Level {
        level(host, hostKey: "openFilesHosts", clusterKey: "openFilesClusters", defaultOn: globalOpenFiles)
    }

    static func opensWithFiles(_ host: Host) -> Bool { openFiles(host).on }

    static func setOpenFiles(_ host: Host, _ value: Bool?) {
        setLevel("openFilesHosts", host.prefKey, value)
        let st = openFiles(host)
        say(value == nil
            ? "\(label(host)): the file browser follows the \(st.from) setting (\(st.on ? "on" : "off"))"
            : "\(label(host)): new sessions open \(value! ? "with" : "without") the file browser")
    }

    static func setOpenFilesForCluster(_ key: String, _ value: Bool?) {
        setLevel("openFilesClusters", key, value)
        say(value == nil ? "The file browser on \(key) follows the global preference"
                         : "Sessions on \(key) open \(value! ? "with" : "without") the file browser")
    }

    static func clusterOpenFiles(_ key: String) -> Bool? { clusterValue("openFilesClusters", key) }

    // MARK: Colour, icon, careful

    static func hostColorValue(_ host: Host) -> String { s["hostColors"][host.prefKey].string ?? "" }
    static func hostColorHex(_ host: Host) -> String {
        let v = hostColorValue(host)
        return HostColor.all.first { $0.value == v && !v.isEmpty }?.hex ?? ""
    }

    static func setHostColor(_ host: Host, _ value: String) {
        var map = s["hostColors"].entries
        if value.isEmpty { map.removeValue(forKey: host.prefKey) } else { map[host.prefKey] = .string(value) }
        set("hostColors", .object(map))
        say(value.isEmpty ? "Colour cleared for \(label(host))" : "\(label(host)) is \(value)")
    }

    static func hostIcon(_ host: Host) -> String { s["hostIcons"][host.prefKey].string ?? "" }

    static func setHostIcon(_ host: Host, _ icon: String) {
        var map = s["hostIcons"].entries
        if icon.isEmpty { map.removeValue(forKey: host.prefKey) } else { map[host.prefKey] = .string(icon) }
        set("hostIcons", .object(map))
        say(icon.isEmpty ? "Icon cleared" : "\(label(host)) is \(icon)")
    }

    static func isCareful(_ host: Host) -> Bool { s["carefulHosts"].stringArray.contains(host.prefKey) }

    static func setCareful(_ host: Host, _ on: Bool) {
        var list = s["carefulHosts"].stringArray.filter { $0 != host.prefKey }
        if on { list.append(host.prefKey) }
        set("carefulHosts", JSON(list))
        say(on ? "\(label(host)) is marked careful — multi-exec will ask first"
               : "\(label(host)) is no longer marked careful")
    }

    // MARK: Stars

    static var starredIds: [String] { s["starredHosts"].stringArray }

    static func isStarred(_ h: Host) -> Bool { starredIds.contains(h.id) }

    /// Appended, not prepended: a list built up over weeks should not reshuffle.
    static func setStarred(_ host: Host, _ on: Bool) {
        var list = starredIds.filter { $0 != host.id }
        if on { list.append(host.id) }
        set("starredHosts", JSON(list))
        say(on ? "Starred \(label(host))" : "Unstarred \(label(host))")
    }

    /// "inline" (top of their own group) or "group" (a Starred group).
    static var starredMode: String { s["starredMode"].string == "group" ? "group" : "inline" }

    static func setStarredMode(_ mode: String) {
        set("starredMode", .string(mode == "group" ? "group" : "inline"))
        say(mode == "group" ? "Starred hosts are gathered in their own group" : "Starred hosts sit at the top of their own group")
    }

    // MARK: Hidden hosts

    static func isHidden(_ h: Host) -> Bool { s["hiddenHosts"].stringArray.contains(h.id) }
    static var showHiddenHosts: Bool { s["showHiddenHosts"].truthy }

    static func setHidden(_ h: Host, _ hide: Bool) {
        var list = s["hiddenHosts"].stringArray.filter { $0 != h.id }
        if hide { list.append(h.id) }
        set("hiddenHosts", JSON(list))
        say(hide ? "Hid \(label(h))" : "Restored \(label(h))")
    }

    static func toggleShowHidden() { set("showHiddenHosts", .bool(!showHiddenHosts)) }

    // MARK: Order

    /// The order hosts appear in within one group: a manual (dragged) order
    /// first, then stars (when inline), then the order they arrived in.
    static func orderHosts(_ list: [Host], _ groupKey: String) -> [Host] {
        let manual = s["hostOrder"][groupKey].stringArray
        var pos: [String: Int] = [:]
        for (i, id) in manual.enumerated() where pos[id] == nil { pos[id] = i }
        let starFirst = starredMode == "inline"
        let starred = Set(starredIds)
        return list.enumerated().sorted { a, b in
            let ma = pos[a.element.id], mb = pos[b.element.id]
            if ma != nil || mb != nil {
                if let ma, let mb { return ma < mb }
                return ma != nil
            }
            if starFirst {
                let sa = starred.contains(a.element.id) ? 0 : 1, sb = starred.contains(b.element.id) ? 0 : 1
                if sa != sb { return sa < sb }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func hasHostOrder(_ groupKey: String) -> Bool { s["hostOrder"][groupKey].truthy }

    /// Write a group's manual order (empty clears it).
    static func saveHostOrder(_ groupKey: String, _ ids: [String]) {
        var map = s["hostOrder"].entries
        if ids.isEmpty { map.removeValue(forKey: groupKey) } else { map[groupKey] = JSON(ids) }
        set("hostOrder", .object(map))
    }

    static var groupOrder: [String] { s["hostGroupOrder"].stringArray }

    static func saveGroupOrder(_ keys: [String]) { set("hostGroupOrder", JSON(keys)) }

    /// The user's arrangement first, then anything new in the order built;
    /// the Starred group pinned to the top unless the saved order names it.
    nonisolated static func orderedGroupKeys(_ keys: [String], order: [String]) -> [String] {
        let pinStarred = !order.contains("starred")
        var rank: [String: Int] = [:]
        for (i, k) in order.enumerated() where rank[k] == nil { rank[k] = i }
        return keys.enumerated().sorted { a, b in
            if pinStarred {
                let sa = a.element == "starred" ? 0 : 1, sb = b.element == "starred" ? 0 : 1
                if sa != sb { return sa < sb }
            }
            let ra = rank[a.element] ?? (order.count + a.offset)
            let rb = rank[b.element] ?? (order.count + b.offset)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Display toggles

    static var showTags: Bool { s["showHostTags"].truthy }
    static func toggleShowTags() { set("showHostTags", .bool(!showTags)) }
    static func toggleShowHeartbeats() { set("showHeartbeats", .bool(!Heartbeat.showHeartbeats)) }

    /// Move the quiet filter on (all → hide → only → all), or set it.
    static func setQuietFilter(_ mode: String? = nil) {
        let next = mode ?? ["all": "hide", "hide": "only", "only": "all"][Heartbeat.quietFilter]!
        set("quietNodeFilter", .string(next))
    }

    /// How many hosts a group lists before it offers the pane (0 = no cap).
    static var hostLimit: Int {
        let v = s["sidebarHostLimit"]
        let n = v.isNull ? 20 : (v.int ?? 0)
        return max(0, n)
    }

    // MARK: Requestable nodes in a group

    static func showRequestable(_ groupKey: String) -> Bool { s["requestableGroups"][groupKey].truthy }

    static func setShowRequestable(_ groupKey: String, _ on: Bool) {
        var map = s["requestableGroups"].entries
        if on { map[groupKey] = true } else { map.removeValue(forKey: groupKey) }
        set("requestableGroups", .object(map))
        say(on ? "Also listing what this cluster would let you ask for" : "Showing only what you can reach on this cluster")
    }
}
