import AppKit
import SwiftUI

/// What the host list does when asked: opening hosts every way it can,
/// refreshing one cluster, logging in from a lapsed one, launching a saved
/// profile — sidebar.js's verbs, with the original's status messages.
@MainActor
enum SBActions {
    static func status(_ text: String, seconds: Double = 6) { StatusBus.shared.show(text, seconds: seconds) }
    static func toast(_ text: String, _ kind: StatusBus.Kind = .info, seconds: Double = 5) {
        StatusBus.shared.toast(text, kind: kind, seconds: seconds)
    }
    static func label(_ h: Host) -> String { HostPrefs.label(h) }

    // MARK: Opening

    /// `open(host, login)`: tmux when the host says so, the MFA route for a
    /// node known to need it, else an ordinary session.
    static func open(_ host: Host, login: String? = nil, window: WindowModel?) {
        let who = login ?? HostPrefs.preferredLogin(host)
        if HostPrefs.opensInTmux(host) {
            var args: [String: Any] = ["session": HostPrefs.tmuxName(host), "tmux": true]
            if let who { args["login"] = who }
            Actions.shared.perform("open-host", window: window, host: host, args: args)
            return
        }
        if HostPrefs.isMfaHost(host.id) && host.type == Host.teleport { openMfa(host, login: who, window: window); return }
        statusUntilSettled("Connecting to \(label(host))\(who.map { " as \($0)" } ?? "")…", hostId: host.id)
        var args: [String: Any] = ["noTmux": true]
        if let who { args["login"] = who }
        Actions.shared.perform("open-host", window: window, host: host, args: args)
    }

    /// Show "Connecting…" until the host's connection settles (connected,
    /// failed or closed) — the original cleared it when `openHost` returned.
    static func statusUntilSettled(_ text: String, hostId: String) {
        StatusBus.shared.show(text, seconds: 0)
        let cm = ConnectionManager.shared
        var token: UUID?
        var done = false
        let finish: @MainActor () -> Void = {
            if done { return }
            done = true
            if let token { cm.unsubscribe(token) }
            if StatusBus.shared.message?.text == text { StatusBus.shared.clear() }
        }
        token = cm.subscribe { ev in
            guard case .state(let id, let st, _) = ev, [.connected, .error, .closed].contains(st) else { return }
            MainActor.assumeIsolated {
                guard cm.connection(id)?.hostId == hostId || cm.connection(id) == nil else { return }
                finish()
            }
        }
        after(120) { finish() }
    }

    static func mfaLabel(_ mode: String) -> String {
        ["platform": "Touch ID", "cross-platform": "security key", "otp": "OTP code", "browser": "browser", "auto": "automatic"][mode] ?? mode
    }

    /// `openMfa`: `tsh ssh`, so the MFA ceremony lands in the terminal.
    static func openMfa(_ host: Host, login: String?, window: WindowModel?) {
        let who = login ?? HostPrefs.preferredLogin(host)
        let mode = SB.store.settingJSON("mfaMode").string?.nilIfEmpty ?? "platform"
        if !HostPrefs.isMfaHost(host.id) { HostPrefs.setMfaHost(host, true) }
        statusUntilSettled("Connecting to \(host.name) with tsh (\(mfaLabel(mode)))…", hostId: host.id)
        // The host is now an MFA host, so open-host routes it to tsh with the
        // MFA mode and shows "Approve with Touch ID…" once the session is up.
        var args: [String: Any] = ["noTmux": true]
        if let who { args["login"] = who }
        Actions.shared.perform("open-host", window: window, host: host, args: args)
    }

    /// Put a host beside (`right`) or below (`down`) the focused pane.
    static func splitWith(_ host: Host, login: String?, dir: String, window: WindowModel?) {
        let who = login ?? HostPrefs.preferredLogin(host)
        statusUntilSettled("Opening \(label(host))…", hostId: host.id)
        var args: [String: Any] = ["split": dir, "noTmux": true]
        if let who { args["login"] = who }
        Actions.shared.perform("open-host", window: window, host: host, args: args)
    }

    /// X11 forwarding, warning first when there is no X server.
    static func openX11(_ host: Host, login: String?, window: WindowModel?) async {
        let who = login ?? HostPrefs.preferredLogin(host)
        let st = ConnectionManager.shared.x11Status()
        if !st.available {
            let go = await MiscUI.confirm(window, title: "No local X server detected", message: st.hint,
                                          detail: "You can still open the session, but graphical programs will fail with \"cannot open display\".",
                                          confirmLabel: "Open anyway")
            if !go { return }
        }
        let x = SB.store.settingJSON("x11").string ?? "off"
        let mode = x != "off" && !x.isEmpty ? x : "untrusted"
        statusUntilSettled("Connecting to \(label(host)) with X11…", hostId: host.id)
        var args: [String: Any] = ["x11": mode, "noTmux": true]
        if let who { args["login"] = who }
        Actions.shared.perform("open-host", window: window, host: host, args: args)
        toast("X11 forwarding on (\(mode)). Try: xeyes", .ok)
    }

    /// The connection without a terminal: files only, in a tab or a split.
    static func openFilesOnly(_ host: Host, login: String?, dir: String? = nil, window: WindowModel?) {
        let who = login ?? HostPrefs.preferredLogin(host)
        statusUntilSettled("Opening files on \(label(host))…", hostId: host.id)
        var args: [String: Any] = ["filesOnly": true]
        if let who { args["login"] = who }
        if let dir { args["split"] = dir }
        Actions.shared.perform("open-host", window: window, host: host, args: args)
    }

    /// `tsh latency ssh`, in its own tab.
    static func openLatency(_ host: Host, login: String?, window: WindowModel?) {
        do {
            let cmd = try Teleport.latencyCommand(proxy: host.proxy, cluster: host.cluster, node: host.name,
                                                  login: login ?? HostPrefs.preferredLogin(host), home: host.home)
            cmd.open(title: "\u{21C4} latency \u{00B7} \(host.name)", window: window)
            status("Measuring latency to \(host.name) — close the tab to stop")
        } catch {
            toast(error.localizedDescription, .error)
        }
    }

    /// Ask for access to a host that has become requestable.
    static func requestAccessFor(_ host: Host, window: WindowModel?) {
        let ps = Inventory.shared.profiles
        guard let p = ps.first(where: { $0.proxy == (host.proxy ?? "") && ($0.homeDir.nilIfEmpty) == (host.home?.nilIfEmpty) })
            ?? ps.first(where: { $0.cluster == host.cluster })
            ?? ps.first(where: { $0.proxy == (host.proxy ?? "") }) else {
            toast("Log in to that cluster first", .error)
            return
        }
        let cluster = host.cluster?.nilIfEmpty ?? p.cluster
        let id = "/\(cluster)/node/\(host.uuid ?? "")"
        Actions.shared.perform("access-request-new", window: window, host: host,
                               args: ["profileKey": p.key, "proxy": p.proxy, "home": p.homeDir, "cluster": cluster,
                                      "resourceIds": [id]])
    }

    /// Open everything in a folder, asking first past six.
    static func openEveryHostIn(_ folder: HostFolder, _ hosts: [Host], window: WindowModel?) async {
        let list = FolderModel.hostsInTree(folder, hosts)
        if list.isEmpty { toast("Nothing in that folder", .error); return }
        if list.count > 6 {
            let go = await MiscUI.confirm(window, title: "Open \(list.count) sessions?",
                                          message: "“\(folder.name)” holds \(list.count) hosts.",
                                          detail: "Each one is a tab and a connection.", confirmLabel: "Open \(list.count)")
            if !go { return }
        }
        for h in list { open(h, window: window) }
    }

    // MARK: Watching

    /// Say that watched hosts have gone, or come back.
    static func announceWatch(_ change: HostWatch.Change?) {
        guard let change else { return }
        for w in change.gone { toast(HostWatch.announcement(w, "gone"), .error, seconds: 12) }
        for w in change.back { toast(HostWatch.announcement(w, "back"), .ok, seconds: 8) }
    }

    // MARK: Refreshing

    static func refreshAll(notify: Bool) {
        Task { @MainActor in
            await Inventory.shared.refresh()
            let moved = FolderModel.repairFolderGroups(SB2.folderGroups().map(\.key))
            if moved > 0 { status("\(moved) folder\(moved == 1 ? "" : "s") restored to this list") }
            if notify {
                let inv = Inventory.shared
                status("\(inv.nodeCount) Teleport nodes · \(inv.sshHosts.count) SSH hosts")
            }
        }
    }

    static func refreshProfile(_ p: TeleportProfile) {
        Task { await Inventory.shared.refreshProfile(p) }
    }

    static func refreshSshConfigs(_ key: String = "ssh") {
        Task { await Inventory.shared.refreshSshConfigs(key: key) }
    }

    // MARK: Lapsed clusters

    /// The expired block's "tsh login": the saved record's details; a
    /// terminal only for local auth (a named user and no connector, or "local").
    static func loginExpired(_ p: TeleportProfile, window: WindowModel?) async {
        let saved = SB2.savedClusterFor(p)
        let o = Teleport.LoginOptions(proxy: p.proxy, cluster: p.cluster.nilIfEmpty ?? saved?["cluster"].stringish?.nilIfEmpty,
                                      user: saved?["user"].stringish?.nilIfEmpty,
                                      authConnector: saved?["authConnector"].stringish?.nilIfEmpty,
                                      ttl: saved?["ttl"].stringish?.nilIfEmpty, mfaMode: saved?["mfaMode"].stringish?.nilIfEmpty,
                                      home: p.homeDir)
        if o.user != nil && (o.authConnector == nil || o.authConnector == "local") {
            Inventory.shared.runLoginInTerminal(o, window: window)
            return
        }
        status("Running tsh login…", seconds: 0)
        let r = await Teleport.login(o)
        StatusBus.shared.clear()
        if r.ok {
            toast("Logged in", .ok)
            await Inventory.shared.refresh()
        } else {
            toast("Login failed — copy the command and run it in a terminal", .error)
        }
    }

    /// Put the `tsh login` for a profile on the clipboard (TELEPORT_HOME in
    /// front of it outside the default home), from the saved record's details.
    static func copyLoginCommand(_ p: TeleportProfile) {
        let saved = SB2.savedClusterFor(p)
        let cmd = Teleport.loginCommand(Teleport.LoginOptions(
            proxy: p.proxy, cluster: p.cluster.nilIfEmpty ?? saved?["cluster"].stringish?.nilIfEmpty,
            user: saved?["user"].stringish?.nilIfEmpty, authConnector: saved?["authConnector"].stringish?.nilIfEmpty,
            ttl: saved?["ttl"].stringish?.nilIfEmpty, mfaMode: saved?["mfaMode"].stringish?.nilIfEmpty,
            home: p.homeDir.nilIfEmpty ?? p.home))
        Clipboard.write(cmd)
        status("Copied: " + cmd, seconds: 8)
    }

    /// Delete a dead profile's files, after naming every one.
    static func removeExpiredProfile(_ p: TeleportProfile, window: WindowModel?) async {
        let files = Teleport.profileFiles(proxy: p.proxy, home: p.homeDir)
        let name = p.cluster.nilIfEmpty ?? p.proxy
        let go = await MiscUI.confirm(window, title: "Remove \(name)?",
            message: files.isEmpty ? "There is nothing left of this profile to delete."
                : "This deletes \(files.count) item\(files.count == 1 ? "" : "s") from your tsh home.",
            detail: (files + ["", "The cluster stops being listed here and by tsh status. Nothing on the",
                              "cluster itself is touched, and logging in again recreates the profile."]).joined(separator: "\n"),
            confirmLabel: "Remove")
        if !go { return }
        let r = Teleport.removeProfile(proxy: p.proxy, home: p.homeDir)
        if !r.ok { toast(r.error ?? "Could not remove that profile", .error); return }
        status("Removed \(name)")
        await Inventory.shared.refresh()
    }

    /// The narrowed note's "Drop request".
    static func dropRequest(_ p: TeleportProfile) async {
        status("Dropping the request…", seconds: 0)
        let r = await Teleport.dropRequest(p.activeRequests, proxy: p.proxy, home: p.homeDir)
        StatusBus.shared.clear()
        if !r.ok { toast("Could not drop it: " + (r.output.nilIfEmpty ?? "tsh failed"), .error); return }
        toast("Request dropped", .ok)
        await Inventory.shared.refresh()
    }

    /// "Log in…" on a lapsed cluster's heading: the saved record, else proxy and home.
    static func relogin(_ p: TeleportProfile, window: WindowModel?) {
        if let saved = SB2.savedClusterFor(p) {
            if let id = saved["id"].string { Inventory.markSavedLoginUsed(id) }
            Actions.shared.perform("tsh-login", window: window, args: [
                "proxy": saved["proxy"].stringish ?? p.proxy, "user": saved["user"].stringish ?? "",
                "cluster": saved["cluster"].stringish ?? "", "home": saved["home"].stringish ?? "",
            ])
        } else {
            Actions.shared.perform("tsh-login", window: window, args: ["proxy": p.proxy, "home": p.homeDir])
        }
    }

    // MARK: Saved profiles

    /// The profile a host would be saved as ("Save as profile…").
    static func profileFromHost(_ host: Host) -> JSON {
        if host.type == Host.teleport {
            return ["name": .string(host.name), "type": "teleport", "node": .string(host.name),
                    "cluster": JSON(host.cluster), "proxy": JSON(host.proxy),
                    "login": .string(HostPrefs.loginOptions(host).first ?? "")]
        }
        return ["name": JSON(host.alias), "type": "ssh", "alias": JSON(host.alias), "hostname": JSON(host.hostname),
                "user": JSON(host.user), "port": JSON(host.port)]
    }

    /// Import, then reload everything it may have changed (`runImport`).
    static func runImport(window: WindowModel?) {
        let reply: (Bool) -> Void = { ok in
            if ok { Task { @MainActor in await Inventory.shared.refresh() } }
        }
        Actions.shared.perform("backup-import", window: window, args: ["reply": reply])
    }
}
