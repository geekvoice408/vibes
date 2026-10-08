import Foundation

/// The parts of teleport.js that dialling a node needs: the generated
/// per-cluster ssh_config (`tsh config`), the ssh target a node is addressed
/// by, and whether a cluster is a trusted leaf. The teleport-service owner
/// calls these rather than duplicating them; its `listClusters` should feed
/// `TeleportSSH.recordClusters` so the leaf cache stays warm.
enum TeleportSSH {
    /// `DEFAULT_HOME`: $TELEPORT_HOME or ~/.tsh.
    static let defaultHome: String = {
        if let h = ProcessInfo.processInfo.environment["TELEPORT_HOME"], !h.isEmpty { return expandHome(h) }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".tsh")
    }()

    /// `expandHome`: "" for nothing, ~ expanded, relative paths resolved.
    static func expandHome(_ p: String?) -> String {
        let raw = (p ?? "").trimmed
        if raw.isEmpty { return "" }
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return (NSHomeDirectory() as NSString).appendingPathComponent(String(raw.dropFirst(2))) }
        if raw.hasPrefix("/") { return (raw as NSString).standardizingPath }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(raw) as NSString).standardizingPath
    }

    /// `homeName`: a short name for a home ("" for the default one).
    static func homeName(_ home: String?) -> String {
        let h = expandHome(home)
        if h.isEmpty || h == defaultHome { return "" }
        let base = (h as NSString).lastPathComponent
        if ConnText.test(ConnText.re(#"^\.?tsh$"#, ci: true), base) {
            let parent = (h as NSString).deletingLastPathComponent
            return parent == NSHomeDirectory() ? "tsh" : (parent as NSString).lastPathComponent
        }
        let stripped = ConnText.replace(ConnText.re(#"^\.?tsh[-_.]?"#, ci: true), in: base, with: "")
        return stripped.isEmpty ? base : stripped
    }

    static func isDefaultHome(_ home: String?) -> Bool {
        guard let home, !home.isEmpty else { return true }
        return expandHome(home) == defaultHome
    }

    /// `plain`: tsh colours its errors; the UI shows text.
    static func plain(_ text: String) -> String {
        ConnText.replace(ConnText.re(#"\x1b\[[0-9;]*m"#), in: text, with: "").trimmed
    }

    // MARK: ssh_config

    /// `clusterSshConfigText`: the ssh_config block `tsh config` writes.
    static func clusterSshConfigText(proxy: String?, home: String?) async throws -> String {
        var args: [String] = []
        if let proxy, !proxy.isEmpty { args.append("--proxy=" + proxy) }
        args.append("config")
        let r = await Tools.runTsh(args, home: home)
        if !r.ok || !r.out.contains("Host") {
            let msg = (r.err.isEmpty ? (r.out.isEmpty ? (r.spawnError ?? "unknown") : r.out) : r.err).trimmed
            throw AppError("tsh config failed: " + msg)
        }
        return r.out
    }

    /// The file name a cluster's config is written under.
    static func configFileName(proxy: String?, cluster: String?, home: String?) -> String {
        let tag = [homeName(home), (cluster?.nilIfEmpty ?? proxy?.nilIfEmpty) ?? "default"]
            .filter { !$0.isEmpty }.joined(separator: "-")
        let safe = ConnText.replace(ConnText.re(#"[^\w.-]"#), in: tag, with: "_")
        return "tsh-\(safe).conf"
    }

    /// The body written: tsh's config plus non-interactive, still-strict host keys.
    static func configBody(_ tshConfig: String) -> String {
        tshConfig + "\nHost *\n    StrictHostKeyChecking accept-new\n"
    }

    /// `writeClusterSshConfig`: write the config OpenSSH dials nodes with
    /// (through `tsh proxy ssh`). Returns the path.
    static func writeClusterSshConfig(dir: String, proxy: String?, cluster: String?, home: String?) async throws -> String {
        let text = try await clusterSshConfigText(proxy: proxy, home: home)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = (dir as NSString).appendingPathComponent(configFileName(proxy: proxy, cluster: cluster, home: home))
        try Data(configBody(text).utf8).write(to: URL(fileURLWithPath: file))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        return file
    }

    /// `teleportSshTarget`: `<node>.<cluster>`, by UUID when the hostname is
    /// shared with another node, prefixed with the login when there is one.
    static func sshTarget(_ node: Host, login: String?) -> String {
        let name: String
        if node.ambiguous == true, let u = node.uuid, !u.isEmpty { name = u }
        else { name = node.hostname?.nilIfEmpty ?? node.uuid ?? "" }
        let host = "\(name).\(node.cluster ?? "")"
        if let login, !login.isEmpty { return "\(login)@\(host)" }
        return host
    }

    // MARK: leaf clusters

    struct ClusterInfo: Sendable, Hashable {
        var name: String
        var leaf: Bool
        var status: String
        var selected: Bool
        var labels: JSON
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var leafNames: [String: Set<String>] = [:]

    private static func leafKey(proxy: String?, home: String?) -> String {
        JSON.array([.string(expandHome(home)), .string(proxy ?? "")]).text()
    }

    /// Feed the leaf cache from a cluster listing (teleport-service calls this
    /// from its own `listClusters`).
    static func recordClusters(proxy: String?, home: String?, clusters: [ClusterInfo]) {
        lock.lock(); defer { lock.unlock() }
        leafNames[leafKey(proxy: proxy, home: home)] = Set(clusters.filter { $0.leaf }.map { $0.name })
    }

    /// `toCluster`.
    static func toCluster(_ c: JSON) -> ClusterInfo {
        ClusterInfo(name: (c["cluster_name"].stringish ?? "").trimmed,
                    leaf: (c["cluster_type"].stringish ?? "").lowercased() == "leaf",
                    status: (c["status"].stringish ?? "").trimmed,
                    selected: c["selected"].truthy,
                    labels: c["labels"])
    }

    /// Parse `tsh clusters --format=json` (anything before the first `[` is noise).
    static func parseClusters(_ out: String) -> [ClusterInfo]? {
        guard let at = out.firstIndex(of: "[") else { return nil }
        guard let arr = JSON.tryParse(String(out[at...])).array else { return nil }
        return arr.map(toCluster).filter { !$0.name.isEmpty }
    }

    /// `listClusters`: `tsh clusters --format=json`, and remember the leaves.
    static func listClusters(proxy: String?, home: String?) async -> (ok: Bool, clusters: [ClusterInfo], error: String?) {
        var args = ["clusters", "--format=json"]
        if let proxy, !proxy.isEmpty { args.append("--proxy=" + proxy) }
        let r = await Tools.runTsh(args, home: home, timeout: 30)
        if let clusters = parseClusters(r.out) {
            recordClusters(proxy: proxy, home: home, clusters: clusters)
            return (true, clusters, nil)
        }
        let msg = plain(r.err.isEmpty ? r.out : r.err)
        return (false, [], msg.isEmpty ? "tsh clusters returned nothing to read" : msg)
    }

    /// `isLeafCluster`: whether a node's cluster is a trusted leaf, which
    /// forces the tsh transport (so the leaf issues the certificate). A cold
    /// cache costs one `tsh clusters`; if that cannot be read the answer is no.
    static func isLeafCluster(proxy: String?, cluster: String?, home: String?) async -> Bool {
        guard let cluster, !cluster.isEmpty else { return false }
        let key = leafKey(proxy: proxy, home: home)
        if cachedLeaves(key) == nil { _ = await listClusters(proxy: proxy, home: home) }
        return cachedLeaves(key)?.contains(cluster) ?? false
    }

    private static func cachedLeaves(_ key: String) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return leafNames[key]
    }
}
