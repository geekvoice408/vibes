import Foundation

// Access requests: the request half of teleport.js (list/show/create/assume/
// drop, the requestable search, role probing, resource-name resolution).

/// One resource named by a request.
struct RequestResource: Codable, Hashable, Sendable {
    var kind: String
    /// Raw: for a node this is the UUID.
    var name: String
    var sub: String
    var cluster: String
    /// `/cluster/kind/name[/sub]`, as `--resource=` takes it.
    var id: String
    /// What a human would recognise once resolved; nil when unresolved.
    var label: String?
}

/// One access request (`tsh request ls`).
struct AccessRequest: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var user: String
    var roles: [String]
    var resources: [RequestResource]
    /// NONE | PENDING | APPROVED | DENIED | PROMOTED | UNKNOWN
    var state: String
    var reason: String
    var created: String?
    /// When the request stops accepting review.
    var expires: String?
    /// The roles cannot be assumed before this.
    var assumeStartTime: String?
    /// Access ends here, however often it is assumed.
    var maxDuration: String?
    /// The elevated certificate itself expires.
    var sessionTtl: String?
    var reviewers: [String]
    var proxy: String?

    /// requestwatch.js `isLive`: pending, or approved and still usable.
    func isLive(now: Double = nowMs()) -> Bool {
        if state == "PENDING" { return true }
        guard state == "APPROVED" || state == "PROMOTED" else { return false }
        let until = TPText.parseDate(maxDuration?.nilIfEmpty ?? expires) ?? 0
        return until == 0 || until > now
    }
}

/// Something this user could ask for (`tsh request search`).
struct RequestableResource: Codable, Hashable, Sendable {
    /// `ResourceID`: the string `tsh request create --resource=` wants.
    var id: String
    var kind: String
    /// Hostname for nodes, the friendly name otherwise.
    var name: String
    /// `Name`: the UUID for nodes.
    var uuid: String
    var cluster: String
    var proxy: String?
    var labels: [String: String]
}

struct RequestableRole: Codable, Hashable, Sendable {
    var name: String
    var description: String
}

extension Teleport {
    /// `REQUEST_KINDS`: what `tsh request search --kind=` accepts, most useful first.
    static let requestKinds = [
        "node", "app", "db", "kube_cluster", "windows_desktop", "linux_desktop",
        "user_group", "saml_idp_service_provider", "git_server",
        "aws_ic_account", "aws_ic_account_assignment",
    ]

    // MARK: - Listing

    /// `listRequests`: the logged-in user's requests, including assumed ones.
    /// `resolveNames` turns node UUIDs into hostnames (a `request search` per
    /// kind, cached two minutes; `refresh` skips the cache).
    static func listRequests(proxy: String?, home: String?, resolveNames: Bool = true,
                             refresh: Bool = false) async -> TshList<AccessRequest> {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["request", "ls", "--format=json"]
        let r = await run(args, home: home, timeout: 30)
        if !r.ok { return .failed(TPText.tshError(r, "")) }
        guard var requests = parseRequests(r.out.isEmpty ? "[]" : r.out, proxy: proxy) else {
            return .failed("unparseable request list")
        }
        if resolveNames { await attachResourceNames(&requests, proxy: proxy, home: home, refresh: refresh) }
        return TshList(ok: true, error: nil, items: requests)
    }

    static func parseRequests(_ text: String, proxy: String?) -> [AccessRequest]? {
        guard let raw = try? JSON.parse(text) else { return nil }
        let names = [0: "NONE", 1: "PENDING", 2: "APPROVED", 3: "DENIED", 4: "PROMOTED"]
        return raw.items.map { x in
            let spec = x["spec"], meta = x["metadata"]
            let st = spec["state"]
            let state = st.string ?? (st.int.flatMap { names[$0] } ?? "UNKNOWN")
            let resources = spec["resource_ids"].items.map { r2 -> RequestResource in
                let sub = r2["sub_resource_name"].stringish ?? ""
                let kind = r2["kind"].stringish ?? "", name = r2["name"].stringish ?? ""
                let cluster = r2["cluster"].stringish ?? ""
                return RequestResource(kind: kind, name: name, sub: sub, cluster: cluster,
                                       id: "/\(cluster)/\(kind)/\(name)" + (sub.isEmpty ? "" : "/" + sub), label: nil)
            }
            return AccessRequest(
                id: meta["name"].stringish?.nilIfEmpty ?? spec["id"].stringish ?? "",
                user: spec["user"].stringish ?? "", roles: spec["roles"].items.compactMap(\.stringish),
                resources: resources, state: state, reason: spec["request_reason"].stringish ?? "",
                created: spec["created"].string,
                expires: spec["expires"].string?.nilIfEmpty ?? meta["expires"].string?.nilIfEmpty,
                assumeStartTime: spec["assume_start_time"].string?.nilIfEmpty,
                maxDuration: spec["max_duration"].string?.nilIfEmpty,
                sessionTtl: spec["session_ttl"].string?.nilIfEmpty,
                reviewers: spec["suggested_reviewers"].items.compactMap(\.stringish), proxy: proxy)
        }
    }

    // MARK: - Name resolution

    private static let nameCache = TPLocked<[String: (at: Double, names: [String: String])]>([:])
    private static let nameTTLms: Double = 120_000

    /// uuid → name for one kind on one proxy (`resourceNamesFor`).
    static func resourceNames(proxy: String?, kind: String, home: String?, refresh: Bool) async -> [String: String] {
        let key = "\(proxy ?? "")|\(kind)"
        let hit = nameCache.get()[key]
        if !refresh, let hit, nowMs() - hit.at < nameTTLms { return hit.names }
        var names: [String: String] = [:]
        let res = await searchRequestable(proxy: proxy, kind: kind, home: home)
        if res.ok { for r in res.items where !r.uuid.isEmpty && !r.name.isEmpty { names[r.uuid] = r.name } }
        // Nodes the user can already reach are in the inventory even when the
        // search comes back empty — a request approved and assumed.
        if kind == "node" {
            let inv = await listNodes(proxy: proxy, cluster: nil, home: home)
            if inv.ok {
                for n in inv.items {
                    if let u = n.uuid, !u.isEmpty, !n.name.isEmpty, names[u] == nil { names[u] = n.name }
                }
            }
        }
        nameCache.mutate { $0[key] = (nowMs(), names) }
        return names
    }

    /// `attachResourceNames`: label each resource whose name resolves to
    /// something different. Best effort throughout.
    static func attachResourceNames(_ requests: inout [AccessRequest], proxy: String?, home: String?, refresh: Bool) async {
        var kinds = Set<String>()
        for req in requests { for r in req.resources where !r.kind.isEmpty { kinds.insert(r.kind) } }
        if kinds.isEmpty { return }
        let byKind = await withTaskGroup(of: (String, [String: String]).self) { g -> [String: [String: String]] in
            for k in kinds { g.addTask { (k, await resourceNames(proxy: proxy, kind: k, home: home, refresh: refresh)) } }
            var out: [String: [String: String]] = [:]
            for await (k, m) in g { out[k] = m }
            return out
        }
        for i in requests.indices {
            for j in requests[i].resources.indices {
                let r = requests[i].resources[j]
                if let label = byKind[r.kind]?[r.name], label != r.name { requests[i].resources[j].label = label }
            }
        }
    }

    // MARK: - Requestable search

    /// `parseLabelString`: `k=v,k2=v2` where values may contain commas.
    static func parseLabelString(_ s: String?) -> [String: String] {
        var out: [String: String] = [:]
        var lastKey: String?
        for piece in (s ?? "").components(separatedBy: ",") {
            if let eq = piece.firstIndex(of: "="), eq != piece.startIndex,
               !piece[..<eq].contains(where: { $0.isWhitespace }) {
                let k = String(piece[..<eq])
                lastKey = k
                out[k] = String(piece[piece.index(after: eq)...])
            } else if let k = lastKey {
                out[k, default: ""] += "," + piece
            }
        }
        return out
    }

    /// `searchRequestable`: what this user could ask for, by kind.
    static func searchRequestable(proxy: String?, kind: String = "node", search: String? = nil, labels: String? = nil,
                                  query: String? = nil, kubeCluster: String? = nil, home: String?) async -> TshList<RequestableResource> {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["request", "search", "--kind=" + kind, "--format=json"]
        if let v = search?.nilIfEmpty { args.append("--search=" + v) }
        if let v = labels?.nilIfEmpty { args.append("--labels=" + v) }
        if let v = query?.nilIfEmpty { args.append("--query=" + v) }
        if let v = kubeCluster?.nilIfEmpty { args.append("--kube-cluster=" + v) }
        let r = await run(args, home: home, timeout: 60)
        if !r.ok {
            let msg = TPText.errText(r)
            return .failed(msg.isEmpty ? "tsh request search --kind=\(kind) failed" : msg)
        }
        guard let items = parseRequestable(r.out.isEmpty ? "[]" : r.out, kind: kind, proxy: proxy) else {
            return .failed("unparseable search output")
        }
        return TshList(ok: true, error: nil, items: items)
    }

    static func parseRequestable(_ text: String, kind: String, proxy: String?) -> [RequestableResource]? {
        guard let raw = try? JSON.parse(text) else { return nil }
        var out = raw.items.map { x -> RequestableResource in
            let id = x["ResourceID"].stringish ?? ""
            let cluster = id.hasPrefix("/") ? (id.split(separator: "/", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? "") : ""
            return RequestableResource(id: id, kind: kind,
                                       name: x["Hostname"].stringish?.nilIfEmpty ?? x["Name"].stringish ?? "",
                                       uuid: x["Name"].stringish ?? "", cluster: cluster, proxy: proxy,
                                       labels: parseLabelString(x["Labels"].stringish))
        }.filter { !$0.id.isEmpty }
        out.sort { TPText.ascending($0.name, $1.name) }
        return out
    }

    /// `searchRequestableRoles`: roles this user may request, with descriptions.
    static func searchRequestableRoles(proxy: String?, home: String?) async -> TshList<RequestableRole> {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["request", "search", "--roles", "--format=json"]
        let r = await run(args, home: home, timeout: 45)
        if !r.ok {
            let msg = TPText.errText(r)
            return .failed(msg.isEmpty ? "tsh request search --roles failed" : msg)
        }
        guard let raw = try? JSON.parse(r.out.isEmpty ? "[]" : r.out) else { return .failed("unparseable role list") }
        return TshList(ok: true, error: nil, items: parseRequestableRoles(raw))
    }

    /// `parseRequestableRoles`: `{ Role, Description }` as tsh spells it, plus
    /// the other shapes the same answer has come in. Sorted by name.
    static func parseRequestableRoles(_ raw: JSON) -> [RequestableRole] {
        var out: [RequestableRole] = []
        for x in raw.items {
            if let s = x.string { out.append(RequestableRole(name: s, description: "")); continue }
            let name = [x["Role"], x["role"], x["Name"], x["name"]].compactMap { $0.stringish?.nilIfEmpty }.first ?? ""
            if name.isEmpty { continue }
            let d = [x["Description"], x["description"]].compactMap { $0.stringish?.nilIfEmpty }.first ?? ""
            out.append(RequestableRole(name: name, description: d))
        }
        out.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return out
    }

    // MARK: - Show / assume / drop

    static func showRequest(_ id: String, proxy: String?, home: String?) async -> (ok: Bool, text: String) {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["request", "show", id]
        let r = await run(args, home: home)
        return (r.ok, (r.out.isEmpty ? r.err : r.out).trimmed)
    }

    /// Assume an approved request by re-logging in with it attached.
    static func assumeRequest(_ id: String, proxy: String?, home: String?) async -> TshOutput {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["login", "--request-id=" + id]
        let r = await run(args, home: home, timeout: 120)
        return TshOutput(ok: r.ok, output: (r.out + r.err).trimmed)
    }

    /// Drop assumed roles from the current identity.
    static func dropRequest(_ ids: [String], proxy: String?, home: String?) async -> TshOutput {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["request", "drop"] + ids
        let r = await run(args, home: home, timeout: 60)
        return TshOutput(ok: r.ok, output: (r.out + r.err).trimmed)
    }

    // MARK: - Create

    struct RequestSpec: Sendable {
        var proxy: String?
        var roles: [String] = []
        var resources: [String] = []
        var reason: String?
        var requestTtl: String?
        var sessionTtl: String?
        var maxDuration: String?
        var assumeStartTime: String?
        var reviewers: [String] = []
        var nowait = true
        var home: String?
        init(proxy: String? = nil, roles: [String] = [], resources: [String] = [], reason: String? = nil,
             requestTtl: String? = nil, sessionTtl: String? = nil, maxDuration: String? = nil,
             assumeStartTime: String? = nil, reviewers: [String] = [], nowait: Bool = true, home: String? = nil) {
            self.proxy = proxy; self.roles = roles; self.resources = resources; self.reason = reason
            self.requestTtl = requestTtl; self.sessionTtl = sessionTtl; self.maxDuration = maxDuration
            self.assumeStartTime = assumeStartTime; self.reviewers = reviewers; self.nowait = nowait; self.home = home
        }
    }

    /// `createRequestArgs`: built in one place so the dialog can show (and
    /// copy) exactly what it will run. `--resource` is repeated, not joined.
    static func createRequestArgs(_ o: RequestSpec) -> [String] {
        var args: [String] = []
        if let p = o.proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["request", "create"]
        if !o.roles.isEmpty { args.append("--roles=" + o.roles.joined(separator: ",")) }
        for id in o.resources { args.append("--resource=" + id) }
        if let v = o.reason?.nilIfEmpty { args.append("--reason=" + v) }
        if !o.reviewers.isEmpty { args.append("--reviewers=" + o.reviewers.joined(separator: ",")) }
        if let v = o.requestTtl?.nilIfEmpty { args.append("--request-ttl=" + v) }
        if let v = o.sessionTtl?.nilIfEmpty { args.append("--session-ttl=" + v) }
        if let v = o.maxDuration?.nilIfEmpty { args.append("--max-duration=" + v) }
        if let v = o.assumeStartTime?.nilIfEmpty { args.append("--assume-start-time=" + v) }
        if o.nowait { args.append("--nowait") }
        return args
    }

    /// `teleport:requestPreview`: `["tsh", …createRequestArgs]`.
    static func requestPreview(_ o: RequestSpec) -> [String] { ["tsh"] + createRequestArgs(o) }

    struct CreatedRequest: Sendable {
        var ok: Bool
        var output: String
        /// From "Request ID: <uuid>".
        var requestId: String?
        /// The roles tsh stopped to ask about (see `roleChoicesFrom`).
        var roleChoices: [String]
        var needsReason: Bool
    }

    /// `createRequest` (with `--nowait`, so it returns as PENDING).
    static func createRequest(_ o: RequestSpec) async -> CreatedRequest {
        let r = await run(createRequestArgs(o), home: o.home, timeout: 120)
        let output = (r.out + r.err).trimmed
        let id = TPText.match(#"Request ID:\s*(\S+)"#, output, .caseInsensitive)?[1] ?? nil
        return CreatedRequest(
            ok: r.ok, output: output, requestId: id,
            roleChoices: r.ok ? [] : roleChoicesFrom(output),
            needsReason: !r.ok && TPText.test("reason", output, .caseInsensitive)
                && TPText.test("required|must be", output, .caseInsensitive))
    }

    /// `roleChoicesFrom`: the roles tsh was about to make you choose between.
    static func roleChoicesFrom(_ output: String) -> [String] {
        let text = output
        guard TPText.test(#"prompt response|choose (a )?role|select (a )?role|available roles"#, text, .caseInsensitive)
        else { return [] }
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let m = TPText.match(#"^\s*(?:\[\d+\]|\d+[.)])\s+([A-Za-z0-9_.@/-]{2,})\s*$"#, line), let v = m[1] { out.append(v) }
        }
        if out.isEmpty, let m = TPText.match(#"roles?[^\[\n]*\[([^\]]+)\]"#, text, .caseInsensitive), let inner = m[1],
           inner.contains(",") {
            for bit in inner.components(separatedBy: ",") {
                let v = bit.trimmed
                if TPText.test(#"^[A-Za-z0-9_.@/-]{2,}$"#, v) { out.append(v) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// `rolesForResources`: the roles these resources were granted through
    /// before, out of your own request history (the union, each once, in order).
    static func rolesForResources(_ requests: [AccessRequest], _ resourceIds: [String]) -> [String] {
        let want = Set(resourceIds.filter { !$0.isEmpty })
        if want.isEmpty { return [] }
        var out: [String] = []
        for req in requests {
            let ids = req.resources.map(\.id).filter { !$0.isEmpty }
            guard ids.contains(where: { want.contains($0) }) else { continue }
            for role in req.roles where !out.contains(role) { out.append(role) }
        }
        return out
    }

    // MARK: - Probe

    /// A role name no cluster can have, so a probe can never raise a request.
    static let probeRole = "__serverlife_probe__"

    struct ProbeResult: Sendable {
        var ok: Bool
        /// Roles a reason is required for.
        var roles: [String]
        var reasonRequired: Bool
        /// The cluster's own `request_prompt`, when it printed one.
        var prompt: String
    }

    /// `probeRequest`: what the cluster will want for a request on these
    /// resources, read from the refusal of a request that cannot succeed.
    static func probeRequest(proxy: String?, home: String?, resources: [String]) async -> ProbeResult {
        if resources.isEmpty { return ProbeResult(ok: false, roles: [], reasonRequired: false, prompt: "") }
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["request", "create", "--roles=" + probeRole, "--nowait"]
        for id in resources { args.append("--resource=" + id) }
        let r = await run(args, home: home, timeout: 45)
        let out = TPText.plain(r.out + "\n" + r.err)
        let p = readProbe(out)
        return ProbeResult(ok: true, roles: p.roles, reasonRequired: p.reasonRequired, prompt: p.prompt)
    }

    /// `readProbe`: everything the refusal says, separated from its phrasing.
    static func readProbe(_ output: String) -> (roles: [String], reasonRequired: Bool, prompt: String) {
        var roles: [String] = []
        func add(_ r: String?) { if let r, !roles.contains(r) { roles.append(r) } }
        for m in TPText.matches(#"required for role\s+"([^"]+)""#, output, .caseInsensitive) { add(m[1]) }
        for m in TPText.matches(#"role\s+"([^"]+)"\s+requires? a reason"#, output, .caseInsensitive) { add(m[1]) }
        roles.removeAll { $0 == probeRole }
        let reasonRequired = TPText.test(#"reason must be specified|reason is required|requires? a reason"#, output, .caseInsensitive)
        var prompt = ""
        let lines = output.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }
        if let at = lines.firstIndex(where: { TPText.test(#"reason must be specified|reason is required"#, $0, .caseInsensitive) }) {
            let next = at + 1 < lines.count ? lines[at + 1] : ""
            if !next.isEmpty, !TPText.test(#"^(ERROR|Hint:|Creating request)"#, next, .caseInsensitive), !next.hasPrefix("tsh ") {
                prompt = next
            }
        }
        return (roles, reasonRequired, prompt)
    }
}
