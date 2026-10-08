import Foundation

/// A host descriptor: anything that can be opened — a Teleport node, an
/// ssh_config alias, a server defined in the app, a beam, a serial console, a
/// telnet target, a VNC screen, an RDP connection, or this machine.
///
/// The JavaScript passed these around as plain objects with whichever fields
/// applied. This keeps the same field names (so stored records and the
/// control-socket protocol stay compatible) and keeps anything it does not
/// model in `extra`, so nothing is lost on a round trip.
struct Host: Hashable, Identifiable {
    /// `teleport`, `ssh`, `beam`, `local`, `serial`, `telnet`, `vnc`, `rdp`.
    var type: String
    var id: String
    var name: String

    // Teleport
    var hostname: String?
    var uuid: String?
    var cluster: String?
    var proxy: String?
    /// The tsh home (TELEPORT_HOME) the node's profile lives in; nil = default.
    var home: String?
    var addr: String?
    var labels: [String: String] = [:]
    var tunnel: Bool?
    /// Whether another node in the same cluster shares this hostname.
    var ambiguous: Bool?
    /// Node expiry as tsh reports it (ISO date) — the heartbeat source.
    var expires: String?
    var subKind: String?

    // ssh_config / app-defined
    var alias: String?
    var user: String?
    var port: Int?
    var configFile: String?
    var proxyJump: String?
    var identityFile: String?
    var direct: DirectSpec?

    /// Everything else the JavaScript carried (missing, missingSince,
    /// requestable, lastSeen, viaTsh, comment, source, …).
    var extra: [String: JSON] = [:]

    init(type: String, id: String, name: String) {
        self.type = type
        self.id = id
        self.name = name
    }

    static let teleport = "teleport", ssh = "ssh", beam = "beam", local = "local",
               serial = "serial", telnet = "telnet", vnc = "vnc", rdp = "rdp"

    var isTeleport: Bool { type == Host.teleport }
    var isBeam: Bool { type == Host.beam }
    var isSSH: Bool { type == Host.ssh }
    var isLocal: Bool { type == Host.local }
    /// Serial, telnet, VNC and RDP: no ControlMaster, no SFTP.
    var isDevice: Bool { [Host.serial, Host.telnet, Host.vnc, Host.rdp].contains(type) }

    /// `hostPrefKey` from store.js: the key every per-host preference is
    /// stored under. A Teleport node's uuid wins, because a hostname is a
    /// label that changes on a rename.
    var prefKey: String {
        if let uuid, !uuid.isEmpty { return "uuid:" + uuid }
        if type == Host.teleport, !name.isEmpty { return "tsh:\(cluster ?? ""):\(name)" }
        if !id.isEmpty { return id }
        if let alias { return "ssh:" + alias }
        return ""
    }

    /// `clusterPrefKey` from store.js: a proxy, or "ssh" for plain SSH.
    var clusterPrefKey: String {
        if type == Host.teleport || type == Host.beam { return proxy?.nilIfEmpty ?? cluster ?? "" }
        return "ssh"
    }

    var label: String { name.isEmpty ? (alias ?? hostname ?? id) : name }
}

/// A server defined in the app (not in ssh_config): its details ride on the
/// ssh command line.
struct DirectSpec: Codable, Hashable {
    var hostname: String
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?
    /// Extra ssh options as the original stores them: one string, one
    /// `Key value` (or `-o Key=value`) per line.
    var extraOptions: String?

    /// `extraOptions` split into non-empty lines.
    var options: [String]? {
        get {
            guard let e = extraOptions else { return nil }
            let lines = e.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines
        }
        set { extraOptions = newValue?.joined(separator: "\n") }
    }

    private enum CodingKeys: String, CodingKey { case hostname, user, port, identityFile, proxyJump, extraOptions }

    init(hostname: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil,
         proxyJump: String? = nil, options: [String]? = nil, extraOptions: String? = nil) {
        self.hostname = hostname; self.user = user; self.port = port
        self.identityFile = identityFile; self.proxyJump = proxyJump
        self.extraOptions = extraOptions ?? options?.joined(separator: "\n")
    }
}

extension Host: Codable {
    private static let known: Set<String> = ["type", "id", "name", "hostname", "uuid", "cluster", "proxy", "home",
        "addr", "labels", "tunnel", "ambiguous", "expires", "subKind", "alias", "user", "port", "configFile",
        "proxyJump", "identityFile", "direct"]

    init(from decoder: Decoder) throws {
        let j = try JSON(from: decoder)
        self.init(json: j)
    }

    func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    init(json j: JSON) {
        let type = j["type"].string ?? Host.ssh
        let name = j["name"].stringish ?? j["alias"].string ?? j["hostname"].string ?? ""
        let id = j["id"].string ?? ""
        self.init(type: type, id: id, name: name)
        hostname = j["hostname"].stringish
        uuid = j["uuid"].string
        cluster = j["cluster"].string
        proxy = j["proxy"].string
        home = j["home"].string
        addr = j["addr"].string
        if let l = j["labels"].object { labels = l.compactMapValues { $0.stringish } }
        tunnel = j["tunnel"].bool
        ambiguous = j["ambiguous"].bool
        expires = j["expires"].string
        subKind = j["subKind"].string
        alias = j["alias"].string
        user = j["user"].string
        port = j["port"].int
        configFile = j["configFile"].string
        proxyJump = j["proxyJump"].string
        identityFile = j["identityFile"].string
        if !j["direct"].isNull { direct = j["direct"].decode(DirectSpec.self) }
        for (k, v) in j.entries where !Host.known.contains(k) { extra[k] = v }
        if self.id.isEmpty { self.id = Host.defaultId(self) }
    }

    var json: JSON {
        var o: [String: JSON] = extra
        o["type"] = .string(type)
        o["id"] = .string(id)
        o["name"] = .string(name)
        func put(_ k: String, _ v: String?) { if let v { o[k] = .string(v) } }
        put("hostname", hostname); put("uuid", uuid); put("cluster", cluster); put("proxy", proxy)
        put("home", home); put("addr", addr); put("expires", expires); put("subKind", subKind)
        put("alias", alias); put("user", user); put("configFile", configFile); put("proxyJump", proxyJump)
        put("identityFile", identityFile)
        if !labels.isEmpty { o["labels"] = .object(labels.mapValues { .string($0) }) }
        if let tunnel { o["tunnel"] = .bool(tunnel) }
        if let ambiguous { o["ambiguous"] = .bool(ambiguous) }
        if let port { o["port"] = .number(Double(port)) }
        if let direct { o["direct"] = JSON.encode(direct) }
        return .object(o)
    }

    /// The id the JavaScript would have given a descriptor built without one.
    static func defaultId(_ h: Host) -> String {
        switch h.type {
        case Host.teleport: return "tsh:\(h.cluster ?? ""):\(h.name)"
        case Host.ssh: return "ssh:" + (h.alias ?? h.name)
        case Host.beam: return "beam:\(h.proxy ?? ""):\(h.name)"
        case Host.local: return "local"
        default: return "\(h.type):\(h.name)"
        }
    }

    /// This machine.
    static let localMachine = Host(type: Host.local, id: "local", name: "this machine")
}
