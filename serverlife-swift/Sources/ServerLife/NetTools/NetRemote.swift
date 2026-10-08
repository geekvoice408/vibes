import Foundation

// The same tools, run against a host rather than from here: main.js's
// `net:host*` handlers over the connections owner's probes
// (`Connection.hostTools`, `hostFacts`, `probePorts`, `hostPing`,
// `hostTrace`, `withSocks` in Connections/ConnNetProbes.swift).

/// A session the tools can run on, as the window lists it.
struct NTConnInfo: Identifiable, Equatable {
    let id: String
    var label: String
    var hostId: String?
    var type: String
    /// "mux" (ssh ControlMaster), "tsh" or "beam".
    var transport: String
    var host: Host?
}

/// The sessions, through ConnectionManager.
@MainActor
enum NTConnections {
    /// Sessions that are connected now.
    static var connected: [NTConnInfo] {
        ConnectionManager.shared.connections.filter { $0.state == .connected }.map {
            NTConnInfo(id: $0.id, label: $0.label, hostId: $0.hostId, type: $0.type, transport: $0.transport.rawValue, host: $0.host)
        }
    }

    static func info(_ id: String) -> NTConnInfo? { connected.first { $0.id == id } }

    static func require(_ id: String) throws -> Connection { try ConnectionManager.shared.require(id) }

    /// Run a shell command on the session's host and return its stdout.
    static func exec(_ id: String, _ command: String, timeout: TimeInterval = 30, keepOutput: Bool = false) async throws -> String {
        try await require(id).exec(command, timeout: timeout, keepOutput: keepOutput)
    }

    /// A terminal on that session's host running `startupCommand`
    /// (`openOnConnection` in sessions.js).
    static func openTerminal(_ id: String, startupCommand: String, title: String, window: WindowModel? = nil) {
        Actions.shared.perform("open-on-connection", window: window, connId: id,
                               args: ["connId": id, "startupCommand": startupCommand, "title": title])
    }
}

extension HostFacts {
    var ntText: String { [hostname, "", addresses, "", routes, "", resolvers].joined(separator: "\n") }
}

@MainActor
enum NetRemote {
    /// What the chosen host can do, and what it would need installed — the
    /// answer drives the tool list: a tool that cannot run is greyed with the
    /// reason and the command that would fix it.
    static func hostTools(_ connId: String, refresh: Bool = false) async throws -> HostCaps {
        let t = try await NTConnections.require(connId).hostTools(refresh: refresh)
        return caps(from: t)
    }

    nonisolated static func caps(from t: HostTools) -> HostCaps {
        var c = HostCaps()
        c.tools = t.tools; c.devtcp = t.devtcp; c.ncFlavour = t.ncFlavour; c.busybox = t.busybox
        c.pkg = t.pkg; c.os = t.os; c.canForward = t.canForward; c.canProbeDirect = t.canProbeDirect
        c.transport = t.transport; c.at = t.at
        c.hints = hints(tools: t.tools, devtcp: t.devtcp, pkg: t.pkg)
        return c
    }

    /// Only what is actually missing. A tool with a working stand-in on the
    /// box is not missing anything: `tracepath` and `mtr` answer the
    /// traceroute question.
    nonisolated static func hints(tools: Set<String>, devtcp: Bool, pkg: String) -> [(tool: String, hint: String)] {
        let covered: [String: Bool] = [
            "traceroute": tools.contains("tracepath") || tools.contains("mtr"),
            "dig": tools.contains("host") || tools.contains("nslookup"),
            "nc": devtcp || tools.contains("ncat") || tools.contains("python3"),
        ]
        return NetInstall.packages.map(\.tool)
            .filter { !tools.contains($0) && covered[$0] != true }
            .map { ($0, NetInstall.hint($0, pkg)) }
            .filter { !$0.1.isEmpty }
    }

    /// The command that would install a missing tool on *that* host.
    static func hintFor(_ conn: Connection, _ tool: String?) async -> String? {
        guard let tool else { return nil }
        let caps = try? await conn.hostTools()
        let h = NetInstall.hint(tool, caps?.pkg)
        return h.isEmpty ? nil : h
    }

    static func hostFacts(_ connId: String) async throws -> HostFacts {
        try await NTConnections.require(connId).hostFacts()
    }

    nonisolated static func portResult(_ p: PortProbe) -> PortResult {
        PortResult(port: p.port, state: p.state, ms: Int(p.ms), detail: nil, open: p.open, how: p.how, banner: p.banner, error: p.error)
    }

    /// Can that host reach this address and port? Parsed exactly as the
    /// local check parses it: the same "host:port" shorthand, ranges and cap.
    static func hostPorts(_ connId: String, host target: String, ports spec: String?, timeoutMs: Int = 4000) async throws -> PortsResult {
        let conn = try NTConnections.require(connId)
        let sp = NetCheck.splitHostPort(target)
        let h = try NetCheck.checkHost(sp.host)
        let ports = (spec?.isEmpty == false) ? try NetCheck.parsePorts(spec) : (sp.port.map { [$0] } ?? NetCheck.defaultPorts)
        if ports.contains(where: { $0 < 1 || $0 > 65535 }) { throw AppError("Ports run from 1 to 65535.") }
        let results = await conn.probePorts(h, ports: Array(ports.prefix(NetCheck.maxPorts)), timeout: Double(timeoutMs) / 1000)
            .map(portResult)
        return PortsResult(host: h, results: results, from: conn.label, how: results.first { $0.how != nil }?.how)
    }

    /// Ping, run by the host; `missing` rather than an error when it has none.
    static func hostPing(_ connId: String, host target: String, count: String?) async throws -> TextRun {
        let conn = try NTConnections.require(connId)
        let h = try NetCheck.checkHost(NetCheck.splitHostPort(target).host)
        let r = await conn.hostPing(h, count: Int(ntClamp(count, 5, 1, 20)))
        return TextRun(host: h, ok: r.ok, text: r.text, command: r.command, missing: r.missing,
                       hint: await hintFor(conn, r.missing), tool: r.tool, from: conn.label)
    }

    static func hostTrace(_ connId: String, host target: String, maxHops: String? = nil) async throws -> TextRun {
        let conn = try NTConnections.require(connId)
        let h = try NetCheck.checkHost(NetCheck.splitHostPort(target).host)
        let r = await conn.hostTrace(h, maxHops: Int(ntClamp(maxHops, 20, 1, 40)))
        return TextRun(host: h, ok: r.ok, text: r.text, command: r.command, missing: r.missing,
                       hint: await hintFor(conn, r.missing), tool: r.tool, from: conn.label)
    }

    /// An HTTP request made *by* that host, through a SOCKS proxy over the
    /// session — the name is resolved and the connection made on the far side.
    static func hostCurl(_ connId: String, _ opts: CurlOptions) async throws -> CurlResult {
        try await NTConnections.require(connId).withSocks { proxy in
            var o = opts
            o.proxy = proxy
            return try await NetCurl.request(o)
        }
    }

    /// The host a connection is on, in the form a saved request keeps: an id
    /// is gone by tomorrow, the host is what "run that again, from there" means.
    static func hostRef(_ connId: String) -> JSON {
        guard let c = NTConnections.info(connId) else { return .null }
        return ["hostId": JSON(c.hostId), "label": .string(c.label), "type": .string(c.type)]
    }

    /// A connection to that host, if one is open.
    static func connFor(_ ref: JSON) -> NTConnInfo? {
        guard ref.object != nil else { return nil }
        let hostId = ref["hostId"].string ?? ""
        for c in NTConnections.connected {
            if !hostId.isEmpty, c.hostId == hostId { return c }
            if hostId.isEmpty, c.label == ref["label"].string { return c }
        }
        return nil
    }
}
