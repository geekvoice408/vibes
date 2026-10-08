import AppKit
import Foundation
import SwiftUI

/// Teleport tab, access requests, request monitor, recordings, live sessions, beams UI (teleportpanel.js …).
///
/// Owner: teleport-ui (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here. Action ids and their args
/// are listed in README.md.
@MainActor
enum TeleportUIFeature {
    static func install() {
        let a = Actions.shared

        // MARK: Menu ids

        /// `openTeleportPanel`: the requests of the active profile, or a login.
        a.register("teleport-panel") { ctx in
            if let p = TUI.activeProfile() { AccessRequestsUI.openRequestsDialog(p, window: ctx.window) }
            else { TeleportPanel.openLoginDialog(window: ctx.window) }
        }
        a.register("cluster-info") { ctx in
            // From the menu bar (no host, no proxy) the original only opened
            // the Teleport tool with the logged-in proxy filled in, and ran
            // nothing; the profile row's button asks about its own proxy.
            if ctx.host == nil, ctx.args["proxy"] == nil, Actions.shared.isRegistered("nettools") {
                Actions.shared.perform("nettools", window: ctx.window, args: ["tool": "teleport"])
                return
            }
            let proxy = ctx.arg("proxy", as: String.self) ?? TUI.profile(from: ctx)?.proxy ?? ctx.host?.proxy
            TeleportPanel.openClusterInfo(proxy: proxy, window: ctx.window)
        }
        a.register("request-monitor") { ctx in ReqMonitor.toggle(ctx.window) }
        a.register("recordings") { ctx in
            let tab = ctx.arg("tab", as: String.self)
            if let h = ctx.host, h.isTeleport || h.isBeam, tab == nil || tab == "recordings" {
                RecordingsUI.open(tab: "recordings", filter: h.name, proxy: h.proxy, window: ctx.window)
            } else {
                RecordingsUI.open(tab: tab ?? "recordings", filter: ctx.arg("filter", as: String.self),
                                  proxy: ctx.arg("proxy", as: String.self), home: ctx.arg("home", as: String.self),
                                  window: ctx.window)
            }
        }
        a.register("tsh-login") { ctx in
            var pre = TeleportPanel.LoginPrefill(proxy: ctx.arg("proxy", as: String.self) ?? "", home: ctx.arg("home", as: String.self) ?? "",
                                                 user: ctx.arg("user", as: String.self) ?? "",
                                                 cluster: ctx.arg("cluster", as: String.self) ?? "")
            if !pre.proxy.isEmpty, let saved = TUIData.listTshLogins().first(where: {
                Teleport.proxyAddress($0["proxy"].stringish) == Teleport.proxyAddress(pre.proxy)
                    && ($0["home"].stringish ?? "") == pre.home && (pre.user.isEmpty || $0["user"].stringish == pre.user)
            }) {
                pre = TeleportPanel.LoginPrefill(record: saved)
            }
            TeleportPanel.openLoginDialog(pre, window: ctx.window)
        }
        a.register("tsh-status") { ctx in
            guard let p = TUI.profile(from: ctx) ?? TUI.activeProfile() else { TUIStatus.toast("No Teleport profile", "error"); return }
            Task { await TeleportPanel.openClusterStatus(p, window: ctx.window) }
        }

        // MARK: Cross-feature ids

        a.register("access-request-new") { ctx in
            guard let p = TUI.profile(from: ctx) ?? TUI.activeProfile() else {
                TUIStatus.toast("Log in to that cluster first", "error"); return
            }
            var resources: [ReqResource] = ctx.arg("resources", as: [ReqResource].self) ?? []
            for id in ctx.arg("resourceIds", as: [String].self) ?? [] where !resources.contains(where: { $0.id == id }) {
                var r = resourceFromId(id, profile: p)
                // The host the request came from knows the name a human uses.
                if let h = ctx.host, let uuid = h.uuid, !uuid.isEmpty, id.hasSuffix("/node/" + uuid) {
                    r.name = h.name; r.labels = h.labels
                }
                resources.append(r)
            }
            if resources.isEmpty, let h = ctx.host, h.isTeleport, let uuid = h.uuid {
                // sidebar.js `requestAccessFor(host)`: the id as the cluster writes it.
                let cluster = h.cluster?.nilIfEmpty ?? p.cluster
                resources = [ReqResource(id: "/\(cluster)/node/\(uuid)", kind: "node", name: h.name, cluster: cluster,
                                         uuid: uuid, labels: h.labels)]
            }
            Task { await AccessRequestsUI.openCreateRequest(p, prefill: .init(resources: resources), window: ctx.window) }
        }
        a.register("access-requests") { ctx in
            AccessRequestsUI.openRequestsDialog(TUI.profile(from: ctx), window: ctx.window)
        }
        a.register("access-requests-menu") { ctx in RequestWatchUI.showRequestsMenu(window: ctx.window) }
        a.register("live-sessions") { ctx in
            if let h = ctx.host, h.isTeleport || h.isBeam, ctx.arg("proxy", as: String.self) == nil {
                LiveSessionsUI.open(for: h, window: ctx.window)
                return
            }
            let p = TUI.profile(from: ctx)
            let proxy = ctx.arg("proxy", as: String.self) ?? p?.proxy
            guard let proxy else { TUIStatus.toast("No Teleport profile", "error"); return }
            LiveSessionsUI.open(proxy: proxy, home: ctx.arg("home", as: String.self) ?? p?.homeDir,
                                match: ctx.arg("match", as: [String].self),
                                title: ctx.arg("title", as: String.self) ?? "Active sessions",
                                subtitle: ctx.arg("subtitle", as: String.self) ?? p.map(TUI.name), window: ctx.window)
        }
        a.register("request-monitor-add") { ctx in
            guard let p = TUI.profile(from: ctx) else { ReqMonitor.openPane(ctx.window); ReqMonitor.addDialog(ctx.window); return }
            ReqMonitor.openPane(ctx.window)
            Task { await ReqMonitor.addForProfile(p, window: ctx.window) }
        }

        // Profile actions the sidebar's cluster heading offers.
        a.register("tsh-logout") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.doLogout(p, window: ctx.window) }
        }
        a.register("tsh-make-active") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.makeProfileActive(p) }
        }
        a.register("tsh-remove-profile") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.removeExpiredProfile(p, window: ctx.window) }
        }
        a.register("tsh-copy-login") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            TeleportPanel.copyLoginCommand(p)
        }
        a.register("tsh-config") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            Task { await TeleportPanel.openTshConfigDialog(p, window: ctx.window) }
        }
        a.register("tsh-relogin") { ctx in
            // The heading's "Log in again": the saved record, else a dialog for this proxy.
            guard let p = TUI.profile(from: ctx) else { return }
            if let saved = TeleportPanel.savedClusterFor(p) { TeleportPanel.loginFromSaved(saved, window: ctx.window) }
            else { TeleportPanel.openLoginDialog(.init(proxy: p.proxy, home: p.homeDir), window: ctx.window) }
        }
        a.register("cluster-switch") { ctx in
            guard let p = TUI.profile(from: ctx) else { return }
            TeleportPanel.openClusterSwitcher(p, window: ctx.window)
        }
        a.register("cluster-web") { ctx in
            let p = TUI.profile(from: ctx)
            TeleportPanel.openClusterWeb(proxy: ctx.arg("proxy", as: String.self) ?? p?.proxy,
                                         cluster: ctx.arg("cluster", as: String.self) ?? p?.cluster)
        }

        // Beams.
        a.register("beam-start") { ctx in
            guard let p = TUI.profile(from: ctx) else { TUIStatus.toast("Log in to a cluster first", "error"); return }
            Task { await BeamsUI.start(p, window: ctx.window) }
        }
        a.register("beam-menu") { ctx in
            guard let b = BeamsUI.beam(from: ctx) else { return }
            if let menu = ctx.arg("menu", as: NSMenu.self) { BeamsUI.appendMenu(menu, b, window: ctx.window) }
            else { BeamsUI.showMenu(b, window: ctx.window) }
        }
        a.register("beam-open") { ctx in
            guard let b = BeamsUI.beam(from: ctx) else { return }
            BeamsUI.open(b, filesOnly: ctx.arg("filesOnly", as: Bool.self) ?? false, window: ctx.window)
        }
        a.register("beam-delete") { ctx in
            guard let b = BeamsUI.beam(from: ctx) else { return }
            Task { await BeamsUI.remove(b, window: ctx.window) }
        }

        // The Sessions dialog's history tab: menu id `history` belongs to the
        // hosts owner; filled in here only if nobody else has registered it.
        a.register("sessions-history") { ctx in RecordingsUI.open(tab: "history", window: ctx.window) }
        if !a.isRegistered("history") {
            a.register("history") { ctx in RecordingsUI.open(tab: "history", window: ctx.window) }
        }

        ReqMonitor.install()

        // What the sidebar draws from here.
        SidebarHooks.teleportTab = { w in AnyView(TeleportTabView(window: w)) }
        SidebarHooks.leafClusterTag = { p, w in
            TeleportPanel.leavesFor(p).isEmpty ? nil : AnyView(LeafClusterTag(p: p, window: w))
        }
        SidebarHooks.clusterSwitchMenuItem = { p, w in TeleportPanel.clusterSwitchMenuItem(p, window: w) }
        SidebarHooks.beamMenu = { b, w in BeamsUI.menuItems(b, window: w) }

        // Only under --snapshot: the tab in a panel of its own, so it can be
        // looked at before the sidebar embeds it.
        if CommandLine.arguments.contains("--snapshot") {
            a.register("teleport-ui-debug-tab") { ctx in
                guard let w = ctx.window else { return }
                Modal.panel(id: "tui-debug-tab", title: "Teleport tab", width: 320, height: 760) { _ in
                    VStack(spacing: 0) {
                        // Two made-up profiles, to see the row with something in it.
                        ProfileRow(p: TeleportProfile(proxy: "lab.example.com:443", cluster: "lab", username: "alice@example.com",
                                                      logins: ["root", "ubuntu"], roles: ["access"], activeRequests: ["4a1b"],
                                                      validUntil: TPText.isoString(ms: nowMs() + 5 * 3600_000), active: true,
                                                      home: "/tmp/tsh-work", homeDir: "/tmp/tsh-work", homeName: "work"), window: w)
                        ProfileRow(p: TeleportProfile(proxy: "old.example.com:443", cluster: "old", username: "alice",
                                                      validUntil: "2024-01-01T00:00:00Z", expired: true), window: w)
                        TeleportTabView(window: w)
                    }.background(Theme.shared.p.panel)
                }
            }
        }
    }

    /// `/cluster/kind/name[/sub]` → a resource the request dialog can show.
    static func resourceFromId(_ id: String, profile p: TeleportProfile) -> ReqResource {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let cluster = parts.count > 1 ? parts[1] : p.cluster
        let kind = parts.count > 2 ? parts[2] : "node"
        let name = parts.count > 3 ? parts[3] : id
        var label = name
        if kind == "node", let n = Inventory.shared.nodes(for: p).first(where: { $0.uuid == name }) { label = n.name }
        return ReqResource(id: id, kind: kind, name: label, cluster: cluster, uuid: kind == "node" ? name : "")
    }
}
