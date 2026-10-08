import Foundation

/// What Fleet needs from features it does not own. Each has a fallback that
/// works from the store and the inventory alone; the owners set the real ones
/// from their `install()` (see Fleet/README.md).
@MainActor
enum FleetHooks {
    /// The hosts ticked in the window's sidebar, in tick order (sidebar
    /// `state.checkedHosts`). Unset, Fleet keeps its own set per window.
    static var checkedHosts: ((WindowModel) -> [String])?
    /// Tick exactly these hosts, as the sidebar would (and redraw it).
    static var setCheckedHosts: ((WindowModel, [String]) -> Void)?
    /// The host filter's query language (sidebar tags.js `compileQuery`):
    /// the predicate a query text stands for.
    static var compileQuery: ((String) -> (Host) -> Bool)?
    /// A host marked careful (sidebar `isCareful`). Fallback: settings.carefulHosts.
    static var isCareful: ((Host) -> Bool)?
    /// Hidden from the host list (sidebar). Fallback: settings.hiddenHosts.
    static var isHidden: ((Host) -> Bool)?
    /// The login to use for a host when none was named (sidebar `preferredLogin`).
    static var preferredLoginHook: ((Host) -> String?)?

    // MARK: Answers, with fallbacks

    /// The sidebar's ticks (`SidebarWindow.checkedHosts`), in inventory order.
    static func checked(_ w: WindowModel) -> [String] {
        if let f = checkedHosts { return f(w) }
        let set = w.feature(SidebarWindow.self).checkedHosts
        guard !set.isEmpty else { return [] }
        var out = allHosts.map(\.id).filter { set.contains($0) }
        out += set.filter { !out.contains($0) }.sorted()
        return out
    }

    static func setChecked(_ w: WindowModel, _ ids: [String]) {
        if let f = setCheckedHosts { f(w, ids); return }
        w.feature(SidebarWindow.self).checkedHosts = Set(ids)
    }

    static func careful(_ h: Host) -> Bool {
        if let f = isCareful { return f(h) }
        return HostPrefs.isCareful(h)
    }

    static func hidden(_ h: Host) -> Bool {
        if let f = isHidden { return f(h) }
        return HostPrefs.isHidden(h)
    }

    static func preferredLogin(_ h: Host) -> String? {
        if let f = preferredLoginHook { return f(h) }
        return HostPrefs.preferredLogin(h)
    }

    /// `findHostById`: Teleport nodes, then ssh_config hosts.
    static func hostById(_ id: String) -> Host? {
        for nodes in Inventory.shared.nodesByKey.values {
            if let n = nodes.first(where: { $0.id == id }) { return n }
        }
        if let h = Inventory.shared.sshHosts.first(where: { $0.id == id }) { return h }
        return SessionHooks.hostById?(id)
    }

    /// Every host in the inventory: Teleport nodes, then ssh_config hosts.
    static var allHosts: [Host] {
        Inventory.shared.nodesByKey.keys.sorted().flatMap { Inventory.shared.nodesByKey[$0] ?? [] } + Inventory.shared.sshHosts
    }

    static func query(_ text: String) -> (Host) -> Bool {
        if let f = compileQuery { return f(text) }
        let q = Tags.compileQuery(text)
        return { q.match($0) }
    }
}

