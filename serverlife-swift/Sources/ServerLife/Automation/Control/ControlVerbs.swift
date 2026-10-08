import Foundation

/// What an outside program is allowed to ask for (main.js `CONTROL_VERBS`).
///
/// Reads are answered here where they can be (inventory, clusters, layouts,
/// tool paths); anything that opens or closes a session is asked of the
/// window, because that is where tabs and panes live. There is deliberately
/// no verb that runs an arbitrary command: `run_macro` runs something the
/// user wrote and can read, which is a line worth holding.
@MainActor
enum ControlVerbs {
    nonisolated static let mainVerbs: Set<String> = ["status", "list_hosts", "list_clusters", "login_command", "list_layouts",
                                         "list_beams", "list_forwards", "open_forward", "list_requests", "run_request",
                                         "sync_preview", "sync_apply"]

    nonisolated static var all: [String] { (mainVerbs.union(AutomationWindow.verbs)).sorted() }

    /// `handleControl` (minus the activity line, which the caller shows).
    static func handle(_ verb: String, _ p: JSON) async throws -> JSON {
        if AutomationWindow.verbs.contains(verb) { return try await AutomationWindow.ask(verb, p) }
        switch verb {
        case "status": return await status()
        case "list_hosts": return await listHosts(p)
        case "list_clusters": return await listClusters()
        case "login_command": return try await loginCommand(p)
        case "list_layouts": return ["layouts": .array(Store.shared.autoListLayouts())]
        case "list_beams": return await listBeams(p)
        case "list_forwards": return listForwards()
        case "open_forward": return try await openForward(p)
        case "list_requests": return listRequests()
        case "run_request": return try await runRequest(p)
        case "sync_preview": return try await syncPreview(p)
        case "sync_apply": return try await syncApply(p)
        default:
            throw AppError("Unknown verb \"\(verb)\". Known: \(all.joined(separator: ", "))")
        }
    }

    // MARK: reads

    static func status() async -> JSON {
        let tp = await Teleport.status()
        return [
            "app": "ServerLife",
            "version": .string(AppResources.version),
            "platform": "darwin",
            "windows": .number(Double(WindowManager.shared.windows.count)),
            "tsh": Teleport.tshStatus,
            "ssh": Tools.sshStatus,
            "clusters": .array(tp.profiles.map { p in
                ["cluster": .string(p.cluster), "proxy": .string(p.proxy), "user": .string(p.username),
                 "home": JSON(p.home), "expired": .bool(p.expired), "active": .bool(p.active)]
            }),
        ]
    }

    static func listHosts(_ p: JSON) async -> JSON {
        let s = Store.shared.settings
        let ssh = await SSHConfig.listSshHosts(extra: s["sshConfigFiles"].stringArray)
        let tp = await Teleport.status()
        let starred = Set(s["starredHosts"].stringArray)
        var hosts: [JSON] = []
        for prof in tp.profiles where !prof.expired {
            let r = await Teleport.listNodes(proxy: prof.proxy, cluster: prof.cluster, home: prof.homeDir)
            for n in r.items {
                // What the window would do with this host, so a caller does not
                // have to guess at the account or wonder why a session used another one.
                hosts.append([
                    "kind": "teleport", "name": .string(n.name), "cluster": JSON(n.cluster), "home": JSON(n.home),
                    "addr": JSON(n.addr), "labels": .object(n.labels.mapValues { .string($0) }), "logins": JSON(prof.logins),
                    "starred": .bool(starred.contains(n.id)),
                    "preferredUser": JSON(s["hostUsers"][n.prefKey].string?.nilIfEmpty),
                    "agentForward": .bool(ConnPrefs.agentForward(for: n)),
                ])
            }
        }
        for h in ssh {
            var o: JSON = ["kind": "ssh", "name": .string(h.alias ?? h.name),
                           // Which config file it came from; null means ~/.ssh/config.
                           "configFile": JSON(h.configFile),
                           "starred": .bool(starred.contains(h.id)),
                           "preferredUser": JSON(s["hostUsers"][h.prefKey].string?.nilIfEmpty)]
            if let u = h.user { o["user"] = .string(u) }
            if let hn = h.hostname { o["hostname"] = .string(hn) }
            if let port = h.port { o["port"] = .number(Double(port)) }
            hosts.append(o)
        }
        for prof in Store.shared.autoListProfiles() {
            hosts.append(["kind": "profile", "name": prof["name"], "type": prof["type"],
                          "cluster": prof["cluster"].string?.nilIfEmpty.map(JSON.string) ?? .null])
        }
        let q = (p["query"].stringish ?? "").lowercased()
        let matched = q.isEmpty ? hosts : hosts.filter { $0.text().lowercased().contains(q) }
        let limit = jsClamp(p["limit"].double ?? 200, 1, 1000)
        return ["count": .number(Double(matched.count)), "hosts": .array(Array(matched.prefix(limit)))]
    }

    static func listClusters() async -> JSON {
        let tp = await Teleport.status()
        return [
            "homes": .array(tp.homes.map { ["path": .string($0.path), "name": .string($0.name), "default": .bool($0.isDefault)] }),
            "clusters": .array(tp.profiles.map { p in
                ["cluster": .string(p.cluster), "proxy": .string(p.proxy), "user": .string(p.username),
                 "roles": JSON(p.roles), "logins": JSON(p.logins), "home": JSON(p.home), "homeName": .string(p.homeName),
                 "expired": .bool(p.expired), "active": .bool(p.active), "validUntil": JSON(p.validUntil)]
            }),
            "saved": .array(Store.shared.autoListTshLogins().map { t in
                ["name": t["name"], "proxy": t["proxy"], "user": t["user"], "home": t["home"].string?.nilIfEmpty.map(JSON.string) ?? .null]
            }),
        ]
    }

    /// The command to paste into a terminal. Reading it changes nothing.
    static func loginCommand(_ p: JSON) async throws -> JSON {
        let cluster = p["cluster"].string?.nilIfEmpty, proxy = p["proxy"].string?.nilIfEmpty
        func hit(_ c: String?, _ pr: String?) -> Bool { (cluster != nil && c == cluster) || (proxy != nil && pr == proxy) }
        let tp = await Teleport.status()
        var pProxy: String?, pUser: String?, pHome: String?
        if let prof = tp.profiles.first(where: { hit($0.cluster, $0.proxy) }) {
            pProxy = prof.proxy; pUser = prof.username; pHome = prof.homeDir
        } else if let saved = Store.shared.autoListTshLogins().first(where: { hit($0["cluster"].string, $0["proxy"].string) }) {
            pProxy = saved["proxy"].string; pUser = saved["user"].string; pHome = saved["home"].string
        }
        let targetProxy = proxy ?? pProxy?.nilIfEmpty
        guard let targetProxy else { throw AppError("No such cluster, and no proxy given.") }
        let o = Teleport.LoginOptions(proxy: targetProxy, user: p["user"].string?.nilIfEmpty ?? pUser?.nilIfEmpty,
                                      home: p["home"].string?.nilIfEmpty ?? pHome?.nilIfEmpty)
        return ["command": .string(Teleport.loginCommand(o))]
    }

    /// Beams, so a caller can name one before syncing to it. Cheap when no
    /// cluster has the service: the probe is cached.
    static func listBeams(_ p: JSON) async -> JSON {
        let only = p["proxy"].string?.nilIfEmpty
        let tp = await Teleport.status()
        var out: [JSON] = []
        for prof in tp.profiles where !prof.expired {
            if let only, prof.proxy != only { continue }
            let probe = await Beams.supported(proxy: prof.proxy, home: prof.homeDir)
            if !probe.ok { continue }
            let r = await Beams.list(proxy: prof.proxy, home: prof.homeDir)
            for b in r.items {
                out.append(["beam": .string(b.id), "uuid": .string(b.uuid), "cluster": .string(prof.cluster),
                            "proxy": .string(prof.proxy), "region": .string(b.region),
                            "expires": b.expires.map { .string(AutomationWindow.isoString(ms: $0)) } ?? .null])
            }
        }
        return ["count": .number(Double(out.count)), "beams": .array(out)]
    }

    // MARK: tunnels

    static func listen(_ addr: String?, _ port: Int) -> String { "\(addr?.nilIfEmpty ?? "localhost"):\(port)" }

    /// Tunnels: what is open, and what has been kept. A caller setting up
    /// someone's work needs to know which ports are already listening before
    /// it opens more.
    static func listForwards() -> JSON {
        let open = ConnectionManager.shared.allForwards().map { f -> JSON in
            ["connection": .string(f.connLabel.nilIfEmpty ?? f.connId), "kind": .string(f.kind),
             "listen": .string(listen(f.bindAddr, f.bindPort)),
             "destination": f.kind == "D" ? .null : .string("\(f.destHost ?? ""):\(f.destPort.map(String.init) ?? "")")]
        }
        let favs = Store.shared.autoListForwardFavorites().map { f -> JSON in
            let kind = f["kind"].string ?? "L"
            return ["id": f["id"], "name": .string(f["name"].string ?? ""), "kind": .string(kind),
                    "listen": .string(listen(f["bindAddr"].string, f["bindPort"].int ?? 0)),
                    "destination": kind == "D" ? .null : .string("\(f["destHost"].stringish ?? ""):\(f["destPort"].stringish ?? "")"),
                    "host": .string(f["host"]["name"].string ?? ""), "login": f["login"].string?.nilIfEmpty.map(JSON.string) ?? .null,
                    "lastUsed": f["lastUsedAt"].double.map { .string(AutomationWindow.isoString(ms: $0)) } ?? .null]
        }
        return ["open": .array(open), "favorites": .array(favs)]
    }

    /// Open a tunnel that was already saved — by name or by id, never by
    /// arbitrary ports. The caller can only ask for something the user
    /// defined, which is what keeps this from being "open any port to
    /// anywhere on my machine".
    static func openForward(_ p: JSON) async throws -> JSON {
        // `name || id`: an empty name falls through to the id.
        let name = p["name"].stringish?.nilIfEmpty, id = p["id"].stringish?.nilIfEmpty
        let want = (name ?? id ?? "").trimmed.lowercased()
        if want.isEmpty { throw AppError("Name a favourite. list_forwards has them.") }
        let favs = Store.shared.autoListForwardFavorites()
        guard let fav = favs.first(where: { $0["id"].string == (id ?? "") })
            ?? favs.first(where: { ($0["name"].string ?? "").lowercased() == want })
            ?? favs.first(where: { ($0["name"].string ?? "").lowercased().contains(want) }) else {
            let known = favs.map { $0["name"].string?.nilIfEmpty ?? $0["id"].string ?? "" }.joined(separator: ", ")
            throw AppError("No saved tunnel called \"\(name ?? id ?? "")\". Known: \(known.isEmpty ? "none" : known)")
        }
        let host = fav["host"]
        let (conn, _) = try await targetConnection(
            host: host["type"].string == "teleport" ? host["name"].string : (host["alias"].string ?? host["name"].string),
            beam: nil, cluster: host["cluster"].string?.nilIfEmpty, proxy: nil, login: fav["login"].string?.nilIfEmpty)
        let kind = fav["kind"].string ?? "L"
        let rec = try await ConnectionManager.shared.addForward(conn.id, ForwardSpec(
            kind: kind, bindAddr: fav["bindAddr"].string ?? "", bindPort: fav["bindPort"].int ?? 0,
            destHost: fav["destHost"].string ?? "", destPort: fav["destPort"].int.flatMap { $0 > 0 ? $0 : nil }))
        if let fid = fav["id"].string { Store.shared.autoMarkForwardFavoriteUsed(fid) }
        return ["opened": true, "name": .string(fav["name"].string?.nilIfEmpty ?? fav["id"].string ?? ""),
                "kind": .string(rec.kind), "listen": .string(listen(rec.bindAddr, rec.bindPort)),
                "destination": rec.kind == "D" ? .null : .string("\(rec.destHost ?? ""):\(rec.destPort.map(String.init) ?? "")"),
                "host": .string(host["name"].string ?? "")]
    }

    // MARK: saved HTTP requests

    static func listRequests() -> JSON {
        ["requests": .array(Store.shared.autoListNetRequests().map { r in
            ["id": r["id"], "name": r["name"], "method": .string(r["opts"]["method"].string?.nilIfEmpty ?? "GET"),
             "url": r["target"], "lastRun": r["lastRunAt"].double.map { .string(AutomationWindow.isoString(ms: $0)) } ?? .null]
        })]
    }

    /// Run one of them. Again the same principle: a request the user wrote and
    /// can read, not a URL of the caller's choosing.
    static func runRequest(_ p: JSON) async throws -> JSON {
        let name = p["name"].stringish?.nilIfEmpty, id = p["id"].stringish?.nilIfEmpty
        let want = (name ?? id ?? "").trimmed.lowercased()
        if want.isEmpty { throw AppError("Name a saved request. list_requests has them.") }
        let all = Store.shared.autoListNetRequests()
        guard let req = all.first(where: { $0["id"].string == (id ?? "") })
            ?? all.first(where: { ($0["name"].string ?? "").lowercased() == want })
            ?? all.first(where: { ($0["name"].string ?? "").lowercased().contains(want) }) else {
            let known = all.compactMap { $0["name"].string }.joined(separator: ", ")
            throw AppError("No saved request called \"\(name ?? id ?? "")\". Known: \(known.isEmpty ? "none" : known)")
        }
        let r = try await NetCurl.request(CurlOptions(json: req["opts"], url: req["target"].string ?? ""))
        Store.shared.autoMarkNetRequestRun(req)
        let limit = p["limit"].double ?? 4000
        let cap = jsClamp(limit, 200, 200_000)
        let body = r.body
        return ["name": req["name"], "method": .string(r.method), "url": .string(r.url), "status": .number(Double(r.status)),
                "statusText": .string(r.statusText), "ms": .number(r.ms), "bytes": .number(Double(r.bytes)),
                "contentType": .string(r.contentType), "body": .string(String(body.prefix(cap))),
                "truncated": .bool(Double(body.count) > limit)]
    }

    /// `Math.max(lo, Math.min(hi, v))` as a count, without trapping on huge
    /// or fractional numbers (slice truncates; NaN gives the low end).
    nonisolated static func jsClamp(_ v: Double, _ lo: Int, _ hi: Int) -> Int {
        if v.isNaN { return lo }
        return Int(max(Double(lo), min(Double(hi), v)).rounded(.towardZero))
    }

    // MARK: sync

    /// What a synchronise would do, without doing it. The preview is the
    /// point: an agent about to copy or delete files on a server should be
    /// able to show its work first.
    static func syncPreview(_ p: JSON) async throws -> JSON {
        let (conn, target) = try await targetConnection(p)
        let planned = try await FilesService.shared.syncPlan(conn.id, syncRequest(p))
        var out = SyncPlanner.describe(planned)
        out["target"] = target
        return out
    }

    /// Run a synchronise. Deletions are opt-in with `delete`, exactly as in
    /// the dialog: a caller that does not ask for them gets a copy-only sync,
    /// the safe reading of an ambiguous instruction.
    static func syncApply(_ p: JSON) async throws -> JSON {
        let (conn, target) = try await targetConnection(p)
        let planned = try await FilesService.shared.syncPlan(conn.id, syncRequest(p))
        let doing = planned.actions.filter(\.doing)
        var out = SyncPlanner.describe(planned)
        out["target"] = target
        if doing.isEmpty {
            out["applied"] = false
            out["reason"] = "already in sync"
            return out
        }
        let r = try await FilesService.shared.syncApply(conn.id, planned, actions: doing)
        out.merge(JSON.encode(r))
        out["applied"] = true
        /*
         * "Permission denied" on a server is nearly always the wrong account
         * rather than the wrong path, and the message never says which account
         * it was. Transfers report through the queue, so this only annotates
         * what it can see here.
         */
        let denied = r.failures.contains { $0.range(of: "permission denied", options: .caseInsensitive) != nil }
        if denied, let login = target["login"].string?.nilIfEmpty {
            out["hint"] = .string("Connected as \"\(login)\" — a permission failure usually means that "
                + "account cannot write there. Pass a different login to sync as someone else.")
        }
        return out
    }

    static func syncRequest(_ p: JSON) -> SyncPlanner.Request {
        SyncPlanner.Request(localDir: p["local"].string ?? "", remoteDir: p["remote"].string ?? "",
                            direction: p["direction"].string?.nilIfEmpty ?? "up", del: p["delete"].truthy,
                            compare: p["compare"].string?.nilIfEmpty ?? "both")
    }

    // MARK: connections by name

    static func targetConnection(_ p: JSON) async throws -> (Connection, JSON) {
        try await targetConnection(host: p["host"].string?.nilIfEmpty, beam: p["beam"].string?.nilIfEmpty,
                                   cluster: p["cluster"].string?.nilIfEmpty, proxy: p["proxy"].string?.nilIfEmpty,
                                   login: p["login"].string?.nilIfEmpty)
    }

    /// `preferredLoginFor`: the caller's, else the one set for the host, else
    /// whatever last worked, else the first the cluster grants.
    static func preferredLogin(_ host: Host, login: String?, logins: [String] = []) -> String? {
        if let login { return login }
        let s = Store.shared.settings
        return s["hostUsers"][host.prefKey].string?.nilIfEmpty ?? s["hostLogins"][host.id].string?.nilIfEmpty ?? logins.first
    }

    /// Resolve what a caller named into a connection, dialling one if needed.
    ///
    /// Callers outside the window think in names — a node, an ssh_config
    /// alias, a beam — not connection ids, and should not have to open a
    /// session (with a terminal and a tab) just to copy files. An already-open
    /// connection to the same thing is reused rather than dialled twice.
    static func targetConnection(host: String?, beam: String?, cluster: String?, proxy: String?,
                                 login: String?) async throws -> (Connection, JSON) {
        if host == nil && beam == nil { throw AppError("Name a host or a beam to sync with.") }
        let mgr = ConnectionManager.shared

        // Something already open that is the same thing. A named login has to
        // match: the same host as two accounts is two views of the filesystem.
        if let c = mgr.findOpen(name: beam == nil ? host : nil, beam: beam, cluster: cluster, login: login) {
            if let beam { return (c, ["beam": .string(beam), "reused": true]) }
            let node = c.spec.node ?? c.spec.host
            return (c, ["host": JSON(host), "cluster": JSON(node?.cluster), "login": JSON(c.login), "reused": true])
        }

        if let beam {
            let tp = await Teleport.status()
            for prof in tp.profiles where !prof.expired {
                if let proxy, prof.proxy != proxy { continue }
                let r = await Beams.list(proxy: prof.proxy, home: prof.homeDir)
                guard let found = r.items.first(where: { $0.id == beam || $0.uuid == beam }) else { continue }
                var h = Host(type: Host.beam, id: "", name: found.id)
                h.proxy = prof.proxy
                h.home = prof.home
                h.id = Host.defaultId(h)
                let conn = try await mgr.create(host: h)
                try await mgr.connect(conn.id)
                return (conn, ["beam": .string(found.id), "cluster": .string(prof.cluster), "proxy": .string(prof.proxy)])
            }
            throw AppError("No beam called \"\(beam)\" on any logged-in cluster.")
        }

        let name = host ?? ""
        // A Teleport node, by hostname, in whichever cluster has it.
        let tp = await Teleport.status()
        for prof in tp.profiles where !prof.expired {
            if let cluster, prof.cluster != cluster { continue }
            let r = await Teleport.listNodes(proxy: prof.proxy, cluster: prof.cluster, home: prof.homeDir)
            guard var node = r.items.first(where: { $0.name == name || $0.hostname == name }) else { continue }
            node.type = Host.teleport
            /*
             * The same login the window would use. `tsh config` writes the
             * Teleport username as the ssh user, which is a cluster principal
             * and often not an account on the node; a caller outside the window
             * has to get the same treatment or it silently connects as the
             * wrong person.
             */
            let as_ = preferredLogin(node, login: login, logins: prof.logins)
            let conn = try await mgr.create(host: node, options: ConnectOptions(login: as_, agentForward: ConnPrefs.agentForward(for: node)))
            try await mgr.connect(conn.id)
            return (conn, ["host": .string(node.name), "cluster": JSON(node.cluster), "proxy": JSON(node.proxy), "login": JSON(as_)])
        }

        // An ssh_config alias.
        let ssh = await SSHConfig.listSshHosts(extra: Store.shared.settings["sshConfigFiles"].stringArray)
        if let alias = ssh.first(where: { $0.alias == name }) {
            var h = Host(type: Host.ssh, id: alias.id, name: alias.alias ?? name)
            h.alias = alias.alias
            h.configFile = alias.configFile
            let as_ = preferredLogin(alias, login: login)
            let conn = try await mgr.create(host: h, options: ConnectOptions(login: as_, agentForward: ConnPrefs.agentForward(for: alias)))
            try await mgr.connect(conn.id)
            return (conn, ["host": .string(alias.alias ?? name), "login": JSON(as_)])
        }

        throw AppError("No host or beam called \"\(name)\". Use list_hosts or list_beams for the names.")
    }
}
