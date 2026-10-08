import SwiftUI

/// Folders, folder browser, hosts pane, saved profiles, add server, quick connect, history (folders.js …).
///
/// Owner: hosts (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here.
@MainActor
enum HostsFeature {
    static func install() {
        let a = Actions.shared

        a.register("quick-connect") { ctx in
            var initial: [String: String] = [:]
            for k in ["target", "identityFile", "proxyJump", "command"] { if let v = ctx.arg(k, as: String.self) { initial[k] = v } }
            QuickConnect.openDialog(ctx.window, initial: initial)
        }

        a.register("add-server") { ctx in
            var i = AddServer.Initial()
            if let v = ctx.arg("name", as: String.self) { i.name = v }
            if let v = ctx.arg("hostname", as: String.self) { i.hostname = v }
            if let v = ctx.arg("user", as: String.self) { i.user = v }
            if let v = ctx.arg("port", as: Int.self) { i.port = v }
            if let v = ctx.arg("identityFile", as: String.self) { i.identityFile = v }
            if let v = ctx.arg("proxyJump", as: String.self) { i.proxyJump = v }
            if let v = ctx.arg("extraOptions", as: String.self) { i.extraOptions = v }
            if let v = ctx.arg("destination", as: String.self) { i.destination = v }
            AddServer.openDialog(ctx.window, initial: i)
        }

        // ⌘Y: Teleport → Session History… opened recordings.js's Sessions
        // dialog on its "Connection history" tab (index.js), which is
        // teleport-ui's. Forwarded there.
        a.register("history") { ctx in
            Actions.shared.perform("recordings", window: ctx.window, args: ["tab": "history"])
        }

        // history.js — the pane menu's "Command history on this host…".
        a.register("command-history") { ctx in
            CommandHistory.open(ctx.window, paneId: ctx.paneId, connId: ctx.connId)
        }

        a.register("edit-profile") { ctx in
            if let p = profileArg(ctx) { Profiles.openEditor(ctx.window, initial: p) }
            else { HToast.error("That profile is not there any more") }
        }
        a.register("new-profile") { ctx in
            Profiles.openEditor(ctx.window, initial: ctx.arg("profile", as: JSON.self) ?? [:])
        }
        a.register("launch-profile") { ctx in
            guard let p = profileArg(ctx) else { return }
            Task { @MainActor in await Profiles.launch(p, window: ctx.window) }
        }

        // profiles.js `openNewSessionDialog`. sessions owns the menu id
        // `new-session`; it is filled here only when nobody registered it.
        a.register("new-session-dialog") { ctx in NewSession.open(ctx.window) }
        if !a.isRegistered("new-session") {
            a.register("new-session") { ctx in NewSession.open(ctx.window) }
        }

        // profiles.js `pickHost`: args `title`, `includeLocal` Bool, and
        // `reply: (HostPick?) -> Void` or (as sessions calls it)
        // `completion: ([String: Any]?) -> Void` with ["kind": "local"] or
        // ["kind": "host", "host": Host, "login": String?].
        a.register("pick-host") { ctx in
            let reply = ctx.arg("reply", as: ((HostPick?) -> Void).self)
            let completion = ctx.arg("completion", as: (([String: Any]?) -> Void).self)
            NewSession.pickHost(ctx.window, title: ctx.arg("title", as: String.self) ?? "Choose a host",
                                includeLocal: ctx.arg("includeLocal", as: Bool.self) ?? true) { pick in
                reply?(pick)
                guard let completion else { return }
                guard let pick else { return completion(nil) }
                if pick.kind == "local" || pick.host == nil { return completion(["kind": "local"]) }
                var d: [String: Any] = ["kind": "host", "host": pick.host!]
                if let l = pick.login { d["login"] = l }
                completion(d)
            }
        }

        // addserver.js `removeManagedHost`: `host` (its alias) or args `alias`.
        a.register("remove-managed-host") { ctx in
            guard let alias = ctx.arg("alias", as: String.self) ?? ctx.host?.alias else { return }
            Task { @MainActor in await AddServer.removeManagedHost(alias, window: ctx.window) }
        }

        // folderview.js: args `groupKey`, `folderId`.
        a.register("folders-browser") { ctx in
            FolderBrowser.open(ctx.window, groupKey: ctx.arg("groupKey", as: String.self), folderId: ctx.arg("folderId", as: String.self))
        }
        // hostspane.js: args `groupKey`, `split` "right"/"down" (also `dir`).
        a.register("hosts-pane") { ctx in
            HostsPane.open(ctx.window, groupKey: ctx.arg("groupKey", as: String.self),
                           split: ctx.arg("split", as: String.self) ?? ctx.arg("dir", as: String.self))
        }
        // folders.js `openFolderDialog`: args `groupKey`, `parentId` (new
        // inside), `folderId` (edit), `hosts` [Host] (default: the group's),
        // `completion: (HostFolder?) -> Void` (the folder made/edited, nil when cancelled).
        a.register("folder-dialog") { ctx in
            guard let g = ctx.arg("groupKey", as: String.self) ?? ctx.arg("folderId", as: String.self).flatMap({ FolderModel.folder(id: $0)?.group })
            else { return }
            FolderDialogs.openFolderDialog(ctx.window, group: g, parent: ctx.arg("parentId", as: String.self),
                                           folder: ctx.arg("folderId", as: String.self).flatMap { FolderModel.folder(id: $0) },
                                           hosts: ctx.arg("hosts", as: [Host].self) ?? HostsHooks.hostsInGroup(g),
                                           done: ctx.arg("completion", as: ((HostFolder?) -> Void).self))
        }
        // folders.js `exportFoldersDialog(groupKey)` / `importFoldersDialog(groups)`.
        a.register("folders-export") { ctx in
            Task { @MainActor in await FolderDialogs.exportFolders(ctx.window, groupKey: ctx.arg("groupKey", as: String.self)) }
        }
        a.register("folders-import") { ctx in
            Task { @MainActor in await FolderDialogs.importFolders(ctx.window, groups: HostsHooks.folderGroups()) }
        }

        FolderDialogs.install()
    }

    /// The Saved tab's profiles list, for the sidebar to embed.
    static func savedList(_ window: WindowModel?, _ filter: String) -> AnyView {
        AnyView(SavedProfilesList(window: window, filter: filter))
    }

    private static func profileArg(_ ctx: ActionContext) -> JSON? {
        if let p = ctx.arg("profile", as: JSON.self) { return p }
        return HostsData.profile(ctx.arg("profileId", as: String.self))
    }
}
