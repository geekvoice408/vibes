import Foundation

/// sidebar.js `launchProfile`, `reloadProfiles`' callers, and profiles.js
/// `openRecent` / `profileForNode` — opening something saved or remembered.
@MainActor
extension Profiles {
    /// The Teleport profile a node belongs to — matched on its home as well
    /// as its cluster, since one cluster can be in two homes.
    static func profileForNode(_ n: Host?) -> TeleportProfile? {
        guard let n else { return nil }
        let ps = Inventory.shared.profiles
        return ps.first { $0.cluster == (n.cluster ?? "") && ($0.home ?? nil) == (n.home ?? nil) }
            ?? ps.first { $0.cluster == (n.cluster ?? "") }
    }

    /// sidebar.js `homeLabel`: a home's short name, or the path itself.
    static func homeLabel(_ home: String) -> String {
        let p = Inventory.shared.profiles.first { $0.homeDir == home || $0.home == home }
        return (p?.homeName.isEmpty == false ? p?.homeName : nil) ?? home
    }

    /// The host descriptor a Teleport or SSH profile opens.
    static func host(for p: JSON) -> Host {
        func s(_ k: String) -> String? { p[k].truthy ? p[k].stringish : nil }
        if p["type"].string == "teleport" {
            let cluster = s("cluster") ?? "", node = s("node") ?? ""
            // Matches the id listNodes gives a node from the same home.
            let id = s("home").map { "tsh:\(homeLabel($0)):\(cluster):\(node)" } ?? "tsh:\(cluster):\(node)"
            var h = Host(type: Host.teleport, id: id, name: node)
            h.hostname = node
            h.cluster = s("cluster")
            h.proxy = s("proxy")
            h.home = s("home")
            return h
        }
        if p["direct"].truthy, let d = p["direct"].decode(DirectSpec.self) {
            // A profile with its own connection details needs no ssh_config entry.
            var h = Host(type: Host.ssh, id: "app:" + (s("id") ?? ""), name: s("name") ?? "")
            h.alias = s("name")
            h.direct = d
            h.user = s("user"); h.hostname = s("hostname"); h.port = p["port"].int
            return h
        }
        var h = Host(json: ["type": "ssh", "id": .string("ssh:" + (p["alias"].stringish ?? "null")), "alias": p["alias"]])
        h.user = s("user"); h.hostname = s("hostname"); h.port = p["port"].int
        // A bastion named on the profile applies even when the rest comes from ssh_config.
        h.proxyJump = s("proxyJump")
        return h
    }

    /// Open a saved connection — whatever kind it is.
    static func launch(_ p: JSON, window: WindowModel?) async {
        let type = p["type"].string ?? "ssh"
        let name = p["name"].stringish ?? ""
        let id = p["id"].string
        func pick(_ keys: [String]) -> JSON {
            var o: JSON = [:]
            for k in keys where !p[k].isNull { o[k] = p[k] }
            return o
        }
        if type == "serial" || type == "telnet" {
            StatusBus.shared.show("Opening \(name)…", seconds: 0)
            var o = pick(["path", "baudRate", "dataBits", "parity", "stopBits", "rtscts", "xon", "xoff",
                          "host", "newline", "localEcho"])
            o["kind"] = .string(type)
            o["name"] = .string(name)
            if !p["devicePort"].isNull { o["port"] = p["devicePort"] }
            // Typed once the console is open (the original sent it to the new pane).
            if let cmd = p["startupCommand"].string, !cmd.isEmpty { o["startupCommand"] = .string(cmd) }
            do { try await HostsOpen.openDevice(type, o, window: window) } catch { HToast.error(hostsErrorText(error)) }
            StatusBus.shared.clear()
            HostsData.markUsed(id)
            return
        }
        if type == "vnc" {
            var o = pick(["viewOnly", "scaling", "quality"])
            o["name"] = .string(name)
            o["host"] = p["host"]
            o["port"] = hostsOr(p["devicePort"], 5900)
            HostsOpen.openVnc(o, window: window)
            HostsData.markUsed(id)
            return
        }
        if type == "rdp" {
            var o = pick(["username", "domain", "fullscreen", "width", "height", "clipboard", "drives", "gateway"])
            o["name"] = .string(name)
            o["hostname"] = p["host"]
            o["port"] = hostsOr(p["devicePort"], 3389)
            await HostsOpen.launchRdp(o, label: name)
            HostsData.markUsed(id)
            return
        }
        // `open-host` is fire-and-forget: the line stays until the session's
        // own status replaces it (or it fades). It marks the profile used
        // (profileId), as sessions.js did.
        StatusBus.shared.show("Connecting to \(name)…")
        HostsOpen.openHost(host(for: p), window: window, login: p["login"].string,
                           startupCommand: p["startupCommand"].string, remoteStartPath: p["remoteStartPath"].string,
                           profileId: id)
        if let path = p["localStartPath"].string?.nilIfEmpty {
            Actions.shared.perform("files-local-path", window: window, args: ["path": path])
        }
    }

    /// Reopen something from the recents list. The live inventory is
    /// preferred where it still has the host (it carries the uuid and labels).
    static func openRecent(_ r: JSON, window: WindowModel?) {
        func s(_ k: String) -> String? { r[k].truthy ? r[k].stringish : nil }
        let type = r["type"].string
        if type == "local" { return HostsOpen.openLocalShell(window: window) }

        if type == "teleport" {
            // The same cluster can be in two homes; reopen the one used.
            let key = TeleportProfile.key(cluster: s("cluster"), proxy: nil, home: s("home"))
            let nodes = Inventory.shared.nodesByKey[key] ?? []
            let live = nodes.first { $0.name == (s("node") ?? "") }
            var host: Host
            if let live { host = live } else {
                host = Host(type: Host.teleport, id: "tsh:\(s("cluster") ?? "null"):\(s("node") ?? "null")", name: s("node") ?? "")
                host.hostname = s("node")
                host.cluster = s("cluster")
                host.proxy = s("proxy")
                host.home = s("home")
            }
            let login = s("login") ?? profileForNode(host)?.logins.first
            return HostsOpen.openHost(host, window: window, login: login)
        }

        // Dialled by details rather than an alias: the recorded details are
        // what reopens it, built through quickHost so the id matches.
        if r["direct"]["hostname"].truthy {
            let d = r["direct"]
            let login = s("login") ?? (d["user"].truthy ? d["user"].stringish ?? "" : "")
            var t = QuickTarget()
            t.user = login
            t.hostname = d["hostname"].stringish ?? ""
            t.port = d["port"].int.flatMap { $0 != 0 ? $0 : nil } ?? 22
            t.identityFile = d["identityFile"].truthy ? d["identityFile"].stringish ?? "" : ""
            t.proxyJump = d["proxyJump"].truthy ? d["proxyJump"].stringish ?? "" : ""
            var host = QuickConnect.quickHost(t)
            if let l = s("label") { host.name = l }
            host.direct?.extraOptions = d["extraOptions"].truthy ? d["extraOptions"].stringish : ""
            return HostsOpen.openHost(host, window: window, login: login.nilIfEmpty)
        }

        let alias = s("node") ?? s("target")
        if let live = Inventory.shared.sshHosts.first(where: { $0.alias == s("node") }) {
            return HostsOpen.openHost(live, window: window, login: s("login"))
        }
        var host = Host(type: Host.ssh, id: "ssh:\(alias ?? "null")", name: s("label") ?? alias ?? "")
        host.alias = alias
        HostsOpen.openHost(host, window: window, login: s("login"))
    }
}
