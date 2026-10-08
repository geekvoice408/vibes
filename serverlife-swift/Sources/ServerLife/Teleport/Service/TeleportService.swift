import AppKit
import Foundation

/// tsh integration: the port of src/main/teleport.js (profiles, nodes,
/// clusters, login/logout, profile removal, web links) and of the main.js
/// `teleport:*` handlers. Access requests are in TeleportRequests.swift,
/// recordings and live sessions in TeleportRecordings.swift.
///
/// Every function that names a proxy takes the tsh `home` too. Pass the
/// profile's `homeDir` when you have it — two homes can hold the same proxy —
/// or nil to let `Tools.runTsh` find the home from the proxy.
///
/// Not here: `writeClusterSshConfig`, `teleportSshTarget` (`sshTarget`) and
/// `isLeafCluster` are in Connections/TeleportSSH.swift. `listClusters` here
/// keeps that file's leaf cache warm via `TeleportSSH.recordClusters`.
enum Teleport {
    // MARK: - Running tsh

    static func run(_ args: [String], home: String? = nil, timeout: TimeInterval = 25) async -> ProcResult {
        await Tools.runTsh(args, home: home?.nilIfEmpty, timeout: timeout)
    }

    /// `findTsh()`.
    static var tshPath: String { Tools.tsh }

    /// `tshStatus()`: Core's report plus the default home and whether it exists.
    static var tshStatus: JSON {
        var j = Tools.tshStatus
        j["home"] = .string(TeleportHomes.defaultHome)
        j["homeExists"] = .bool(FileManager.default.fileExists(atPath: TeleportHomes.defaultHome))
        return j
    }

    /// `tools:status`: tsh and ssh as they were found.
    static var toolStatus: JSON { ["tsh": tshStatus, "ssh": Tools.sshStatus] }

    /// `version()`: "18.11.2", or the first line tsh printed, or nil.
    static func version() async -> String? {
        let r = await run(["version", "--client"])
        if !r.ok && r.out.isEmpty { return nil }
        if let m = TPText.match(#"Teleport\s+v([0-9.]+)"#, r.out), let v = m[1] { return v }
        let first = r.out.trimmed.components(separatedBy: "\n").first ?? ""
        return first.isEmpty ? nil : first
    }

    // MARK: - Status

    struct HomeError: Sendable { var home: String; var name: String; var error: String; var missing: Bool }
    struct HomeSummary: Sendable { var path: String; var name: String; var isDefault: Bool }

    /// `status()`: profiles from every configured home, merged.
    struct Status {
        var loggedIn: Bool
        var profiles: [TeleportProfile]
        /// Whether tsh was found travels with every status read (`tshStatus`).
        var tsh: JSON
        var homes: [HomeSummary]
        /// The first home's error when there are no profiles at all.
        var error: String?
        var homeErrors: [HomeError]
    }

    /// One home's read (`statusIn`).
    struct HomeStatus { var profiles: [TeleportProfile]; var error: String?; var missing = false }

    /// Profiles from every configured home, each tagged with the home it came
    /// from. Rebuilds the proxy → home map: the first home to claim a proxy
    /// owns it (the order in Settings is also a precedence list). Two homes
    /// holding the same cluster are two profiles, not one.
    static func status() async -> Status {
        let dirs = TeleportHomes.active
        let results = await withTaskGroup(of: (Int, HomeStatus).self) { g -> [HomeStatus] in
            for (i, d) in dirs.enumerated() { g.addTask { (i, await statusIn(home: d)) } }
            var out = [HomeStatus](repeating: HomeStatus(profiles: []), count: dirs.count)
            for await (i, r) in g { out[i] = r }
            return out
        }
        var profiles: [TeleportProfile] = []
        var errors: [HomeError] = []
        var claims: [(proxy: String, home: String)] = []
        for (i, r) in results.enumerated() {
            let home = dirs[i]
            let name = TeleportHomes.name(home)
            if let e = r.error, r.profiles.isEmpty { errors.append(HomeError(home: home, name: name, error: e, missing: r.missing)) }
            for var p in r.profiles {
                if !p.proxy.isEmpty { claims.append((p.proxy, home)) }
                p.home = TeleportHomes.isDefault(home) ? nil : home
                p.homeDir = home
                p.homeName = name
                profiles.append(p)
            }
        }
        TeleportHomes.setClaims(claims)
        return Status(
            loggedIn: !profiles.isEmpty, profiles: profiles, tsh: tshStatus,
            homes: dirs.map { HomeSummary(path: $0, name: TeleportHomes.name($0), isDefault: TeleportHomes.isDefault($0)) },
            error: profiles.isEmpty ? errors.first?.error : nil, homeErrors: errors)
    }

    /// `statusIn(home)`: JSON first, the text form if that is unavailable.
    static func statusIn(home: String) async -> HomeStatus {
        let j = await run(["status", "--format=json"], home: home)
        if j.ok, j.out.trimmed.hasPrefix("{"), let parsed = parseStatusJSON(j.out) { return HomeStatus(profiles: parsed) }
        let t = await run(["status"], home: home)
        if !t.out.contains("Profile URL") {
            let message = TPText.plain(t.err.isEmpty ? t.out : t.err)
            if !message.isEmpty, t.spawnError == nil { return HomeStatus(profiles: [], error: message) }
            // No output at all means the binary never ran: a missing tsh, not
            // a missing login, and the difference is the whole fix.
            let missing = t.spawnError != nil
            return HomeStatus(profiles: [], error: "Could not run tsh (\(tshPath)). " + (missing
                ? "The file is not there — set its path in Settings → Locate tsh."
                : "It exited without output."), missing: missing)
        }
        return HomeStatus(profiles: parseStatusText(t.out))
    }

    /// `tsh status --format=json` → profiles (active first, no duplicates).
    /// nil when the text is not that JSON.
    static func parseStatusJSON(_ text: String, now: Double = nowMs()) -> [TeleportProfile]? {
        guard let data = try? JSON.parse(text), data.object != nil else { return nil }
        func toProfile(_ p: JSON, _ active: Bool) -> TeleportProfile? {
            guard p.object != nil else { return nil }
            let url = p["profile_url"].string
            let proxy = url.map { $0.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression) }
                ?? p["proxy"].stringish ?? ""
            let validUntil = p["valid_until"].string
            let expired = validUntil.flatMap { TPText.parseDate($0) }.map { $0 < now } ?? false
            // Each entry is `{ id: { cluster, kind, name } }`; older tsh put the
            // fields at the top level. Read either.
            let allowed = p["allowed_resources"].items.map { r -> String in
                let id = r["id"].isNull ? r : r["id"]
                return "\(id["kind"].stringish ?? "undefined")/\(id["name"].stringish ?? "undefined")"
            }
            return TeleportProfile(
                proxy: proxy, cluster: p["cluster"].stringish ?? "", username: p["username"].stringish ?? "",
                logins: p["logins"].items.compactMap(\.stringish), roles: p["roles"].items.compactMap(\.stringish),
                activeRequests: p["active_requests"].items.map { $0.stringish ?? $0.text() },
                allowedResources: allowed, validUntil: validUntil, active: active, expired: expired)
        }
        var out: [TeleportProfile] = []
        if let a = toProfile(data["active"], true) { out.append(a) }
        for p in data["profiles"].items {
            if let conv = toProfile(p, false), !out.contains(where: { $0.proxy == conv.proxy && $0.cluster == conv.cluster }) {
                out.append(conv)
            }
        }
        return out
    }

    /// The text form of `tsh status`, scraped.
    static func parseStatusText(_ text: String) -> [TeleportProfile] {
        var out: [TeleportProfile] = []
        var cur: TeleportProfile?
        for line in text.components(separatedBy: "\n") {
            if let m = TPText.match(#"^\s*(?:>\s*)?Profile URL:\s*(.+)$"#, line), let url = m[1] {
                if let c = cur { out.append(c) }
                let proxy = url.trimmed.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                cur = TeleportProfile(proxy: proxy, active: line.contains(">"))
                continue
            }
            guard cur != nil else { continue }
            guard let kv = TPText.match(#"^\s{2,}([A-Za-z ]+):\s*(.*)$"#, line), let k0 = kv[1] else { continue }
            let k = k0.trimmed.lowercased()
            let v = (kv[2] ?? "").trimmed
            let list = v.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
            switch k {
            case "cluster": cur?.cluster = v
            case "logged in as": cur?.username = v
            case "logins": cur?.logins = list
            case "roles": cur?.roles = list
            case "valid until":
                cur?.validUntil = v.replacingOccurrences(of: #"\s*\[.*$"#, with: "", options: .regularExpression)
                cur?.expired = v.range(of: "EXPIRED", options: .caseInsensitive) != nil
            default: break
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// `statusText`: `tsh status` as it prints it, for people to compare
    /// against a terminal, paste into a ticket and read the extensions out of.
    struct StatusText: Sendable {
        var ok: Bool
        var text: String
        /// Which home it was read from, since the same cluster can be in two.
        var home: String
        var proxy: String
        /// Which cluster tsh put first.
        var activeCluster: String
        /// Whether that first block is about `proxy`.
        var activeMatches: Bool
    }

    static func statusText(proxy: String?, home: String?) async -> StatusText {
        let r = await run(["status"], home: home)
        let text = r.out.trimmed.isEmpty ? r.err.trimmed : r.out.trimmed
        let first = TPText.match(#"^\s*Cluster:\s*(\S+)"#, text, .anchorsMatchLines)?[1] ?? ""
        let p = proxy ?? ""
        return StatusText(
            ok: !text.isEmpty, text: text.isEmpty ? "tsh printed nothing." : text,
            home: home?.nilIfEmpty ?? TeleportHomes.defaultHome, proxy: p, activeCluster: first,
            activeMatches: !first.isEmpty && !p.isEmpty
                ? text.components(separatedBy: "\n").prefix(6).contains { $0.contains(p) } : true)
    }

    /// `teleport:homes`: what each tsh home holds, for the preferences list.
    struct HomesReport {
        struct Home {
            var path: String; var name: String; var isDefault: Bool; var exists: Bool
            var profiles: [TeleportProfile]
            var error: String?
        }
        var configured: [String]
        var defaultHome: String
        var tsh: JSON
        var ssh: JSON
        var homes: [Home]
    }

    /// `teleport:homes` as the original's JSON (`MiscHooks.teleportHomes`).
    static func homesReportJSON() async -> JSON {
        let r = await homesReport()
        return [
            "configured": JSON(r.configured), "defaultHome": .string(r.defaultHome), "tsh": r.tsh, "ssh": r.ssh,
            "homes": .array(r.homes.map { h in
                ["path": .string(h.path), "name": .string(h.name), "default": .bool(h.isDefault),
                 "exists": .bool(h.exists), "error": JSON(h.error),
                 "profiles": .array(h.profiles.map {
                     ["cluster": .string($0.cluster), "proxy": .string($0.proxy),
                      "username": .string($0.username), "expired": .bool($0.expired)]
                 })]
            }),
        ]
    }

    static func homesReport() async -> HomesReport {
        let dirs = TeleportHomes.active
        let st = await status()
        let configured: [String] = await MainActor.run { Store.shared.setting("tshHomes", [String]()) }
        return HomesReport(
            configured: configured, defaultHome: TeleportHomes.defaultHome, tsh: tshStatus, ssh: Tools.sshStatus,
            homes: dirs.map { dir in
                HomesReport.Home(path: dir, name: TeleportHomes.name(dir), isDefault: TeleportHomes.isDefault(dir),
                                 exists: FileManager.default.fileExists(atPath: dir),
                                 profiles: st.profiles.filter { $0.homeDir == dir },
                                 error: st.homeErrors.first { $0.home == dir }?.error)
            })
    }

    // MARK: - Clusters

    /// `listClusters`: the root and every trusted leaf behind a proxy, from
    /// `tsh clusters --format=json` (JSON only: the table truncates names).
    /// Feeds the connection layer's leaf cache (`TeleportSSH.recordClusters`),
    /// which `TeleportSSH.isLeafCluster` reads on the way into every connection.
    static func listClusters(proxy: String?, home: String?) async -> TshList<TeleportCluster> {
        var args = ["clusters", "--format=json"]
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        let r = await run(args, home: home, timeout: 30)
        if let clusters = parseClusters(r.out) {
            TeleportSSH.recordClusters(proxy: proxy, home: home, clusters: clusters.map {
                TeleportSSH.ClusterInfo(name: $0.name, leaf: $0.leaf, status: $0.status, selected: $0.selected,
                                        labels: $0.labels.map { .object($0.mapValues { .string($0) }) } ?? .null)
            })
            return TshList(ok: true, error: nil, items: clusters)
        }
        let e = TPText.errText(r)
        return .failed(e.isEmpty ? "tsh clusters returned nothing to read" : e)
    }

    static func parseClusters(_ text: String) -> [TeleportCluster]? {
        guard let at = text.firstIndex(of: "["), let data = try? JSON.parse(String(text[at...])),
              let arr = data.array else { return nil }
        return arr.map { c in
            TeleportCluster(
                name: (c["cluster_name"].stringish ?? "").trimmed,
                // Anything that is not spelled "leaf" is the cluster you logged into.
                leaf: (c["cluster_type"].stringish ?? "").lowercased() == "leaf",
                status: (c["status"].stringish ?? "").trimmed,
                selected: c["selected"].truthy,
                labels: c["labels"].object?.compactMapValues(\.stringish))
        }.filter { !$0.name.isEmpty }
    }

    // MARK: - Nodes

    /// `listNodes`: a cluster's node inventory as host descriptors, sorted by
    /// name (case-insensitive, numeric), with shared hostnames marked
    /// `ambiguous`. `cluster` is the profile's cluster (it goes into ids).
    static func listNodes(proxy: String?, cluster: String?, home: String?) async -> TshList<Host> {
        var args = ["ls", "--format=json"]
        if let c = cluster?.nilIfEmpty { args.append("--cluster=" + c) }
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        let r = await run(args, home: home, timeout: 45)
        if !r.ok { return .failed(TPText.tshError(r, "tsh ls failed")) }
        guard let nodes = parseNodes(r.out.isEmpty ? "[]" : r.out, proxy: proxy, cluster: cluster, home: home) else {
            return .failed("unparseable tsh ls output")
        }
        return TshList(ok: true, error: nil, items: nodes)
    }

    /// The pure half of `listNodes`, for tests.
    static func parseNodes(_ text: String, proxy: String?, cluster: String?, home: String?) -> [Host]? {
        guard let raw = try? JSON.parse(text) else { return nil }
        let isDefault = TeleportHomes.isDefault(home)
        let hName = TeleportHomes.name(home)
        var nodes: [Host] = raw.items.map { n in
            let meta = n["metadata"], spec = n["spec"]
            let metaName = meta["name"].stringish ?? ""
            let hostname = spec["hostname"].stringish?.nilIfEmpty ?? metaName
            var labels = meta["labels"].entries.compactMapValues(\.stringish)
            for (k, v) in spec["cmd_labels"].entries {
                // Dynamic (command) labels: the value is the command's result.
                if v.object != nil { labels[k] = v["result"].stringish ?? "" } else if let s = v.stringish { labels[k] = s }
            }
            // Ids reach settings, so a host in the default home keeps the id it
            // has always had; another home's host carries the home in its id.
            let id = isDefault ? "tsh:\(cluster ?? ""):\(metaName)"
                               : "tsh:\(hName.isEmpty ? (home ?? "") : hName):\(cluster ?? ""):\(metaName)"
            var h = Host(type: Host.teleport, id: id, name: hostname)
            h.hostname = hostname
            h.uuid = metaName
            let addr = spec["addr"].stringish ?? ""
            let useTunnel = spec["use_tunnel"].truthy
            h.addr = !addr.isEmpty ? addr : (useTunnel ? "tunnel" : "")
            h.tunnel = useTunnel || addr.isEmpty
            h.subKind = n["sub_kind"].stringish?.nilIfEmpty ?? "teleport"
            // When the cluster will forget this node: the heartbeat source.
            // Zero dates (never expires) are recorded as no expiry at all.
            if let e = meta["expires"].string, let t = TPText.parseDate(e), t > 946_684_800_000 { h.expires = e }
            h.cluster = cluster
            h.proxy = proxy
            h.home = isDefault ? nil : home
            h.extra["homeName"] = .string(hName)
            h.labels = labels
            return h
        }
        nodes.sort { TPText.ascending($0.name, $1.name) }
        markAmbiguous(&nodes)
        return nodes
    }

    /// `markAmbiguous`: a hostname shared with another node in the same list.
    static func markAmbiguous(_ nodes: inout [Host]) {
        var count: [String: Int] = [:]
        for n in nodes { count[n.hostname ?? "", default: 0] += 1 }
        for i in nodes.indices { nodes[i].ambiguous = (count[nodes[i].hostname ?? ""] ?? 0) > 1 }
    }

    // MARK: - ssh_config text

    /// `clusterSshConfigText`: the ssh_config block `tsh config` writes
    /// (the connection layer's, `TeleportSSH.clusterSshConfigText`).
    static func clusterSshConfigText(proxy: String?, home: String?) async throws -> String {
        try await TeleportSSH.clusterSshConfigText(proxy: proxy, home: home)
    }

    // MARK: - Login / logout / switch

    struct LoginOptions: Sendable {
        var proxy: String?
        var cluster: String?
        var user: String?
        var authConnector: String?
        var ttl: String?
        var mfaMode: String?
        var extraArgs: [String] = []
        var home: String?
        init(proxy: String? = nil, cluster: String? = nil, user: String? = nil, authConnector: String? = nil,
             ttl: String? = nil, mfaMode: String? = nil, extraArgs: [String] = [], home: String? = nil) {
            self.proxy = proxy; self.cluster = cluster; self.user = user; self.authConnector = authConnector
            self.ttl = ttl; self.mfaMode = mfaMode; self.extraArgs = extraArgs; self.home = home
        }
    }

    /// `proxyAddress`: host and port, nothing else — the scheme, a user pasted
    /// along with it and any path are dropped; the port is kept.
    static func proxyAddress(_ value: String?) -> String {
        var v = (value ?? "").trimmed
        v = v.replacingOccurrences(of: #"^[a-z][a-z0-9+.-]*://"#, with: "", options: [.regularExpression, .caseInsensitive])
        v = v.replacingOccurrences(of: #"^[^/@]*@"#, with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
        return v.trimmed
    }

    /// `loginArgs`: the cluster is `tsh login`'s positional argument (it has
    /// no `--cluster` flag); extra flags pass through verbatim.
    static func loginArgs(_ o: LoginOptions) -> [String] {
        var args = ["login"]
        let addr = proxyAddress(o.proxy)
        if !addr.isEmpty { args.append("--proxy=" + addr) }
        if let u = o.user?.nilIfEmpty { args.append("--user=" + u) }
        if let a = o.authConnector?.nilIfEmpty { args.append("--auth=" + a) }
        if let t = o.ttl?.nilIfEmpty { args.append("--ttl=" + t) }
        if let m = o.mfaMode?.nilIfEmpty { args.append("--mfa-mode=" + m) }
        args.append(contentsOf: o.extraArgs.filter { !$0.isEmpty })
        if let c = o.cluster?.nilIfEmpty { args.append(c) }
        return args
    }

    /// `login`: in the background (SSO opens a browser and waits, so 5 minutes).
    /// A login that names a user must go to a terminal instead — use
    /// `loginCommandArgs` and `TshCommand.open`, or `Inventory.runLoginInTerminal`.
    static func login(_ o: LoginOptions) async -> ProcResult {
        await run(loginArgs(o), home: o.home, timeout: 300)
    }

    /// `teleport:loginArgs`: the login as an argv for a terminal tab.
    static func loginCommandArgs(_ o: LoginOptions) -> TshCommand {
        TshCommand(command: tshPath, args: loginArgs(o), teleportHome: TeleportHomes.resolve(o.home, proxy: o.proxy))
    }

    /// `loginCommand`: the same login as a line to paste, TELEPORT_HOME included
    /// when it is not the default home.
    static func loginCommand(_ o: LoginOptions) -> String {
        let home = TeleportHomes.expand(o.home)
        var parts: [String] = []
        if !home.isEmpty && home != TeleportHomes.expand(TeleportHomes.defaultHome) {
            parts.append("TELEPORT_HOME=" + quote(home))
        }
        parts.append("tsh")
        parts.append(contentsOf: loginArgs(o).map(quote))
        return parts.joined(separator: " ")
    }

    /// Quote only what a shell would otherwise mangle.
    static func quote(_ v: String) -> String {
        TPText.test(#"^[\w@%+=:,./-]+$"#, v) ? v : "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `switchProfile`: make a profile the active one, or point it at another
    /// cluster in its trust web, with the whole saved login command.
    static func switchProfile(_ o: LoginOptions) async -> TshOutput {
        let r = await run(loginArgs(o), home: o.home, timeout: 180)
        if r.ok { markCurrentProfile(proxy: o.proxy, home: o.home) }
        return TshOutput(ok: r.ok, output: TPText.plain("\(r.out)\n\(r.err)"))
    }

    /// `markCurrentProfile`: write tsh's `current-profile` (tsh 18 does not
    /// record a switch to a still-valid profile). Only when that home really
    /// has a profile by that name.
    @discardableResult
    static func markCurrentProfile(proxy: String?, home: String?) -> Bool {
        let name = proxyAddress(proxy).replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
        if name.isEmpty { return false }
        var dir = TeleportHomes.expand(home)
        if dir.isEmpty { dir = TeleportHomes.expand(TeleportHomes.home(forProxy: proxy)) }
        if dir.isEmpty { dir = TeleportHomes.defaultHome }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir + "/\(name).yaml") else { return false }
        let file = dir + "/current-profile"
        guard fm.createFile(atPath: file, contents: Data((name + "\n").utf8), attributes: [.posixPermissions: 0o640])
        else { return false }
        return true
    }

    /// `logout`: with no proxy, every profile in the home; with one, that cluster.
    static func logout(proxy: String?, user: String? = nil, home: String?) async -> TshOutput {
        var args = ["logout"]
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        if let u = user?.nilIfEmpty { args.append("--user=" + u) }
        let r = await run(args, home: home, timeout: 60)
        return TshOutput(ok: r.ok, output: TPText.plain(r.err.isEmpty ? r.out : r.err))
    }

    // MARK: - Removing a dead profile

    struct ProfilePaths: Sendable {
        var dir: String, yaml: String, keys: String, current: String, name: String, names: [String]
    }

    /// `profilePaths`: what `tsh status` would list for a profile, on disk.
    /// nil for anything that is not a plain `host[:port]`.
    static func profilePaths(proxy: String?, home: String?) -> ProfilePaths? {
        var dir = TeleportHomes.expand(home)
        if dir.isEmpty { dir = TeleportHomes.defaultHome }
        let proxyName = (proxy ?? "").trimmed
        guard !proxyName.isEmpty, TPText.test(#"^[A-Za-z0-9._-]+(:\d+)?$"#, proxyName), !proxyName.contains("..")
        else { return nil }
        let host = String(proxyName.split(separator: ":", omittingEmptySubsequences: false)[0])
        var candidates = [proxyName]
        if host != proxyName { candidates.append(host) }
        let fm = FileManager.default
        let yaml = candidates.map { dir + "/\($0).yaml" }.first { fm.fileExists(atPath: $0) } ?? dir + "/\(host).yaml"
        let keys = candidates.map { dir + "/keys/\($0)" }.first { fm.fileExists(atPath: $0) } ?? dir + "/keys/\(host)"
        let name = ((yaml as NSString).lastPathComponent as NSString).deletingPathExtension
        return ProfilePaths(dir: dir, yaml: yaml, keys: keys, current: dir + "/current-profile", name: name, names: candidates)
    }

    /// `removeProfile`: delete a profile's files (not `tsh logout`, which can
    /// hang on a proxy that no longer answers). Reports what actually went.
    static func removeProfile(proxy: String?, home: String?) -> (ok: Bool, removed: [String], error: String?) {
        guard let paths = profilePaths(proxy: proxy, home: home) else {
            return (false, [], "That does not look like a proxy address.")
        }
        let fm = FileManager.default
        var removed: [String] = []
        if fm.fileExists(atPath: paths.yaml) {
            do { try fm.removeItem(atPath: paths.yaml) } catch { return (false, [], error.localizedDescription) }
        }
        if fm.fileExists(atPath: paths.yaml) { return (false, [], "The profile file is still there.") }
        removed.append(paths.yaml)
        if fm.fileExists(atPath: paths.keys) {
            if (try? fm.removeItem(atPath: paths.keys)) != nil { removed.append(paths.keys) }
        }
        if fm.fileExists(atPath: paths.current),
           let cur = try? String(contentsOfFile: paths.current, encoding: .utf8).trimmed,
           cur == paths.name || paths.names.contains(cur) {
            if (try? fm.removeItem(atPath: paths.current)) != nil { removed.append(paths.current) }
        }
        for n in paths.names { TeleportHomes.forget(proxy: n) }
        return (true, removed, nil)
    }

    /// `profileFiles`: what removing a profile would delete, for a dialog.
    static func profileFiles(proxy: String?, home: String?) -> [String] {
        guard let p = profilePaths(proxy: proxy, home: home) else { return [] }
        return [p.yaml, p.keys].filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Web UI links

    /// `webClusterUrl`: a cluster's page in the Teleport web UI. `section`:
    /// resources (default) | nodes | audit | sessions.
    static func webClusterUrl(proxy: String?, cluster: String?, section: String = "resources") -> String? {
        guard let proxy else { return nil }
        let host = proxy.trimmed
            .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
        if host.isEmpty { return nil }
        let name = (cluster ?? "").trimmed
        if name.isEmpty { return "https://\(host)/web" }
        let path = ["resources": "resources", "nodes": "resources", "audit": "audit/events",
                    "sessions": "session-recordings"][section] ?? "resources"
        return "https://\(host)/web/cluster/\(uriComponent(name))/\(path)"
    }

    /// `teleport:openWebCluster`: built and opened here, so nothing hands an
    /// arbitrary URL to the browser.
    @MainActor @discardableResult
    static func openWebCluster(proxy: String?, cluster: String?, section: String = "resources") throws -> String {
        guard let url = webClusterUrl(proxy: proxy, cluster: cluster, section: section), let u = URL(string: url) else {
            throw AppError("No proxy address for this cluster, so there is no web UI to open")
        }
        NSWorkspace.shared.open(u)
        return url
    }

    /// `encodeURIComponent`.
    static func uriComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Terminal commands

    /// `latencyArgs`: `tsh latency ssh [user@]host`, which draws a TUI and so
    /// has to be given a real terminal.
    static func latencyArgs(proxy: String?, cluster: String?, node: String?, login: String?) throws -> [String] {
        guard let node = node?.nilIfEmpty else { throw AppError("Which node? A hostname is needed.") }
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["latency", "ssh"]
        if let c = cluster?.nilIfEmpty { args.append("--cluster=" + c) }
        args.append(login?.nilIfEmpty.map { "\($0)@\(node)" } ?? node)
        return args
    }

    /// `teleport:latencyArgs`.
    static func latencyCommand(proxy: String?, cluster: String?, node: String?, login: String?, home: String?) throws -> TshCommand {
        TshCommand(command: tshPath, args: try latencyArgs(proxy: proxy, cluster: cluster, node: node, login: login),
                   teleportHome: TeleportHomes.resolve(home, proxy: proxy))
    }
}
