import AppKit
import SwiftUI

/// The host list: groups, rows, tags, heartbeats, watched hosts, the host
/// menu and its dialogs (sidebar.js, hostactions.js, tags.js, tagbrowser.js,
/// heartbeat.js, nodewatch.js hooks, narrowed.js, clustermarks.js,
/// requestable.js, watch.js, the folder model of folders.js).
///
/// Owner: sidebar. Action ids and extension points: README.md here.
@MainActor
enum SidebarFeature {
    static func install() {
        Slots.sidebar = { AnyView(SidebarRoot(window: $0)) }
        registerActions()
        installHooks()
        StatusItems.shared.register("sidebar.checked", order: 30) { w in AnyView(SBCheckedStatus(window: w)) }
    }

    private static func registerActions() {
        let a = Actions.shared

        // ⌘R: refresh everything, and say what came back.
        a.register("refresh") { _ in SBActions.refreshAll(notify: true) }

        // The host context menu, appended to someone else's NSMenu (hosts
        // pane, folder browser). args: `menu` NSMenu, `groupKey`, `folderId`.
        a.register("host-menu") { ctx in
            guard let host = ctx.host, let menu = ctx.arg("menu", as: NSMenu.self) else { return }
            let folder = FolderModel.folder(id: ctx.arg("folderId", as: String.self))
            let built = CtxMenu.build(SBMenus.hostMenu(host, groupKey: ctx.arg("groupKey", as: String.self), folder: folder, window: ctx.window))
            for item in built.items {
                built.removeItem(item)
                menu.addItem(item)
            }
        }

        // clustermarks.js: the icon/colour entries, for any list that shows clusters.
        a.register("cluster-mark-menu") { ctx in
            guard let menu = ctx.arg("menu", as: NSMenu.self),
                  let key = ctx.arg("profileKey", as: String.self), let p = Inventory.shared.profile(forKey: key) else { return }
            let built = CtxMenu.build(ClusterMarks.menu(p, window: ctx.window))
            for item in built.items { built.removeItem(item); menu.addItem(item) }
        }

        // hostactions.js dialogs.
        a.register("run-command") { ctx in
            guard let host = ctx.host else { return }
            SBHostActions.openRunCommand(host, login: ctx.arg("login") ?? HostPrefs.loginOptions(host).first, connId: ctx.connId,
                                         command: ctx.arg("command"), title: ctx.arg("title"),
                                         autoRun: ctx.arg("autoRun", as: Bool.self) ?? true, window: ctx.window)
        }
        a.register("port-forward") { ctx in
            let login: String? = ctx.arg("login") ?? ctx.host.flatMap { HostPrefs.preferredLogin($0) }
            SBHostActions.openPortForward(ctx.host, login: login, connId: ctx.connId, preset: ctx.arg("preset", as: JSON.self), window: ctx.window)
        }
        a.register("forward-favorite-open") { ctx in
            guard let fav = ctx.arg("favorite", as: JSON.self) else { return }
            Task { await SBHostActions.openForwardFavorite(fav, window: ctx.window) }
        }
        a.register("server-profile") { ctx in
            guard let host = ctx.host else { return }
            SBHostActions.openServerInfo(host, login: ctx.arg("login") ?? HostPrefs.preferredLogin(host), connId: ctx.connId, window: ctx.window)
        }
        // Choose a host from the whole inventory (hostactions.js `pickHost`).
        // args: `completion: (Host?) -> Void`.
        a.register("choose-host") { ctx in
            let done = ctx.arg("completion", as: ((Host?) -> Void).self)
            Task { let h = await SBHostActions.pickHost(window: ctx.window); done?(h) }
        }
        a.register("ssh-config-files") { ctx in SBDialogs.sshConfigFiles(window: ctx.window) }
        a.register("tag-browser") { ctx in
            SBTagBrowser.open(window: ctx.window, getFilter: ctx.arg("getFilter", as: (() -> String).self),
                              setFilter: ctx.arg("setFilter", as: ((String?) -> Void).self))
        }
        a.register("host-tags") { ctx in if let h = ctx.host { SBTagBrowser.openHostTags(h, window: ctx.window) } }
        // Open a host the way the host list does (sidebar.js `openHostFromList`).
        a.register("open-host-from-list") { ctx in
            guard let h = ctx.host else { return }
            SBActions.open(h, login: ctx.arg("login"), window: ctx.window)
        }
        // Ask for access to a requestable / watched-requestable host.
        a.register("request-access-for") { ctx in if let h = ctx.host { SBActions.requestAccessFor(h, window: ctx.window) } }
        // Stop watching everything (Settings' "Stop watching all").
        a.register("watch-forget-all") { _ in HostWatch.forgetAll() }
        // Only under --snapshot: step through the tabs and sub-tabs so each can be looked at.
        if CommandLine.arguments.contains("--snapshot") {
            a.register("sidebar-debug-next-tab") { ctx in
                guard let sw = ctx.window?.feature(SidebarWindow.self) else { return }
                let order = [("hosts", "profiles"), ("saved", "profiles"), ("saved", "macros"), ("saved", "s3"), ("teleport", "profiles")]
                let i = order.firstIndex { $0.0 == sw.tab && ($0.0 != "saved" || $0.1 == sw.savedView) } ?? 0
                let next = order[(i + 1) % order.count]
                sw.tab = next.0; sw.savedView = next.1
            }
        }
    }

    private static func installHooks() {
        let inv = Inventory.shared
        // nodewatch.js: every list actually read feeds the heartbeat TTLs,
        // the narrowed-request memory and the disappearance watch.
        inv.nodesRead.append { p, nodes in
            Heartbeat.observe(p.key, nodes)
            Narrowed.noteRead(p, nodes)
            let change = await HostWatch.noteSeen(FolderModel.groupKey(for: p), nodes, partial: Narrowed.isNarrowed(p))
            SBActions.announceWatch(change)
        }
        inv.nodeSignatureExtra = { _, nodes in Heartbeat.heartbeatSignature(nodes) }
        // Folders made from a heading before 0.6.2 went in under the proxy address.
        inv.afterLoad.append {
            let moved = FolderModel.repairFolderGroups(SB2.folderGroups().map(\.key))
            if moved > 0 { SBActions.status("\(moved) folder\(moved == 1 ? "" : "s") restored to this list") }
        }

        SessionHooks.hostById = { SB2.hostById($0) }
        SessionHooks.preferredLogin = { HostPrefs.preferredLogin($0) }
        if SessionHooks.loginOptions == nil { SessionHooks.loginOptions = { HostPrefs.loginOptions($0) } }
        if SessionHooks.waitForInventory == nil {
            SessionHooks.waitForInventory = {
                var waited = 0.0
                while !Inventory.shared.loadedOnce && waited < 30 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    waited += 0.2
                }
            }
        }

        // What the hosts owner's folder views and hosts pane draw.
        HostsHooks.heartbeat = { h in
            let age = Heartbeat.heartbeatAge(h)
            let stale = Heartbeat.isStale(h)
            if age == nil && !stale { return nil }
            return HostBeat(stale: stale, staleLabel: Heartbeat.staleLabel(h), ageLabel: age == nil ? nil : Heartbeat.ageLabel(h),
                            line: Heartbeat.heartbeatLine(h))
        }
        HostsHooks.requestableHosts = { proxy, home, cluster in
            await Requestable.hosts(proxy: proxy, home: home, cluster: cluster ?? "")
        }
        HostsHooks.folderGroups = { SB2.folderGroups().map { FolderGroup(key: $0.key, label: $0.label, kind: $0.kind) } }
        HostsHooks.hostsInGroup = { SB2.hostsInGroup($0) }
        HostsHooks.missingIn = { HostWatch.missingIn($0, $1) }
        HostsHooks.isWatched = { HostWatch.isWatched($0) }
    }
}

/// "N selected for multi-exec" in the status bar.
private struct SBCheckedStatus: View {
    let window: WindowModel
    var body: some View {
        let n = window.feature(SidebarWindow.self).checkedHosts.count
        if n > 0 { Text("\(n) selected for multi-exec") }
    }
}
