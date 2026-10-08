import AppKit
import SwiftUI

/// Network tools — the "why can't I reach this" panel (`openNetTools`).
///
/// One target at the top, a tool below it, and the target survives switching
/// tools, because the whole point is running several against the same host.
@MainActor
final class NetToolsModel: ObservableObject {
    /// The open panel's model, so a second request re-points it.
    static weak var current: NetToolsModel?

    weak var handle: ModalHandle?
    weak var window: WindowModel?

    enum Output {
        case help(String)
        case running(String)
        case loaded(name: String, why: String)
        case error(String)
        case result(NetDisplay)
    }

    @Published var target: String
    @Published var tool: String
    @Published var running = false
    @Published var output: Output
    /// The last result, kept so it can be saved after the fact.
    var lastText = ""
    var lastName = ""

    // Options
    @Published var ports = ""
    @Published var count = "5"
    @Published var method = "GET"
    @Published var telnetPort = "23"
    @Published var telnetNewline = "crlf"
    @Published var telnetEcho = false
    @Published var serialPath = ""
    @Published var serialBaud = "115200"
    @Published var serialDataBits = "8"
    @Published var serialParity = "none"
    @Published var serialStopBits = "1"
    @Published var serialFlow = "none"
    @Published var serialNewline = "cr"
    @Published var serialEcho = false

    // curl
    @Published var curlMethod = "GET"
    @Published var curlHeaders = ""
    @Published var curlBody = ""
    @Published var curlType = "application/json"
    @Published var curlBearer = ""
    @Published var curlUser = ""
    @Published var curlPass = ""
    @Published var curlInsecure = false
    @Published var curlFollow = true
    @Published var curlTimeout = "20"

    // Run on
    @Published var runOn = ""
    @Published var caps: HostCaps?
    @Published var sessions: [NTConnInfo] = []

    // Strips
    @Published var saved: [JSON] = []
    @Published var recents: [JSON] = []
    var savedId: String?

    /// The panel's own status line: it is a window of its own, so messages
    /// about it are shown in it rather than under whatever it covers.
    @Published var note: (text: String, kind: StatusBus.Kind)?
    private var noteClear: DispatchWorkItem?

    private let refresher = Repeater()

    func say(_ text: String, kind: StatusBus.Kind = .info, seconds: Double = 6) {
        noteClear?.cancel()
        note = text.isEmpty ? nil : (text, kind)
        guard !text.isEmpty, seconds > 0 else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.note = nil } }
        noteClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    init(host: String?, tool: String, preset: JSON?, runOn: String, window: WindowModel?) {
        self.window = window
        let t = NetTool.find(tool) != nil ? tool : "ping"
        self.tool = t
        target = host ?? NetToolsModel.suggestTarget()
        output = .help(t)
        if let o = preset?["opts"], o.object != nil {
            curlMethod = o["method"].string ?? "GET"
            curlHeaders = o["headers"].string ?? ""
            curlBody = o["body"].string ?? ""
            curlType = o["contentType"].string ?? "application/json"
            curlBearer = o["bearer"].string ?? ""
            curlUser = o["basicUser"].string ?? ""
            curlPass = o["basicPass"].string ?? ""
            curlInsecure = o["insecure"].truthy
            curlFollow = o["followRedirects"].bool != false
            curlTimeout = String(ntStoredTimeout(o["timeout"]))
        }
        savedId = preset?["id"].string
        syncSessions()
        // Opened from a session's own header: start pointed at that host.
        if !runOn.isEmpty, sessions.contains(where: { $0.id == runOn }) { self.runOn = runOn }
        // What that host has — always asked on open, as the original's render did.
        loadCaps()
        reloadStrips()
        refresher.start(every: 2) { [weak self] in self?.syncSessions() }
    }

    func stop() { refresher.stop() }

    // MARK: Derived

    var needsTarget: Bool { !["local", "serial"].contains(tool) }
    var onLabel: String { runOn.isEmpty ? "" : (NTConnections.info(runOn)?.label ?? "that host") }

    /// Default to a logged-in proxy, since that is usually what is being debugged.
    static func suggestTarget() -> String { proxyNow() }
    static func proxyNow() -> String {
        let ps = Inventory.shared.profiles
        return (ps.first { !$0.expired } ?? ps.first)?.proxy ?? ""
    }

    var curlOpts: CurlOptions {
        var o = CurlOptions()
        o.method = curlMethod
        o.url = target.ntTrimmed
        o.headers = curlHeaders
        o.body = curlBody
        o.contentType = curlType
        o.bearer = curlBearer.ntTrimmed
        o.basicUser = curlUser.ntTrimmed
        o.basicPass = curlPass
        o.insecure = curlInsecure
        o.followRedirects = curlFollow
        // `parseInt(curlTimeout.value, 10) || 20`
        o.timeout = ntParseInt(curlTimeout).flatMap { $0 != 0 ? $0 : nil } ?? 20
        return o
    }

    /// The command, shown as it will be run: built from the same argv the
    /// request uses, so what is previewed, copied and sent cannot drift apart.
    var curlPreview: String {
        do { return try NetCurl.commandFor(curlOpts) } catch { return error.localizedDescription }
    }

    /// Whether a tool is greyed for the chosen host, and the words for it.
    func toolState(_ t: NetTool) -> (blocked: Bool, label: String) {
        let missing = runOn.isEmpty ? nil : NetTool.missing(t, caps)
        let blocked = !runOn.isEmpty && (!t.remote || missing != nil)
        let label = (t.id == "local" && !runOn.isEmpty ? "That host" : t.label)
            + (!t.remote && !runOn.isEmpty ? "  — from this machine only" : "")
            + (missing.map { "  — no \($0) on that host" } ?? "")
        return (blocked, label)
    }

    // MARK: Sessions and capabilities

    func syncSessions() {
        let now = NTConnections.connected
        if now != sessions { sessions = now }
        if !runOn.isEmpty && !now.contains(where: { $0.id == runOn }) {
            runOn = ""
            loadCaps()
        }
    }

    func setRunOn(_ id: String) {
        runOn = id
        loadCaps()
        output = .help(tool)
    }

    func loadCaps(refresh: Bool = false) {
        caps = nil
        guard !runOn.isEmpty else { syncOptions(); return }
        let id = runOn
        Task { @MainActor in
            do {
                let c = try await NetRemote.hostTools(id, refresh: refresh)
                if runOn == id { caps = c }
            } catch {
                if runOn == id {
                    // `{ error, tools: {} }`: a host that could not be probed
                    // is treated as having nothing, so nothing is pressed blind.
                    var c = HostCaps(); c.error = error.localizedDescription
                    caps = refresh ? nil : c
                }
            }
            syncOptions()
        }
    }

    /// A tool that cannot run on the chosen host is not left selected.
    func syncOptions() {
        if !runOn.isEmpty, !NetTool.canRunRemotely(tool) || NetTool.missing(NetTool.find(tool), caps) != nil {
            tool = "ports"
        }
    }

    func selectTool(_ id: String) {
        tool = id
        syncOptions()
        output = .help(tool)
    }

    /// Point "Run on" back at a saved host — only at a session that is open:
    /// dialling a server because a chip was clicked would be a surprise.
    func applyHostRef(_ ref: JSON) {
        guard ref.object != nil else { runOn = ""; loadCaps(); return }
        syncSessions()
        if let conn = NetRemote.connFor(ref) {
            runOn = conn.id
            loadCaps()
            return
        }
        runOn = ""
        loadCaps()
        say("\(ref["label"].stringish ?? "That host") is not open — running from this machine instead", seconds: 7)
    }

    // MARK: Strips

    func reloadStrips() {
        saved = NetSaved.requests()
        recents = NetSaved.runs()
    }

    func runSaved(_ r: JSON) {
        target = r["target"].stringish ?? ""
        let o = r["opts"]
        curlMethod = o["method"].string ?? "GET"
        curlHeaders = o["headers"].string ?? ""
        curlBody = o["body"].string ?? ""
        curlType = o["contentType"].string ?? ""
        curlBearer = o["bearer"].string ?? ""
        curlUser = o["basicUser"].string ?? ""
        curlPass = o["basicPass"].string ?? ""
        curlInsecure = o["insecure"].truthy
        curlFollow = o["followRedirects"].bool != false
        curlTimeout = String(ntStoredTimeout(o["timeout"]))
        savedId = r["id"].string
        applyHostRef(r["on"])
        run()
    }

    func runRecent(_ r: JSON) {
        // Stored by either app; an unknown or empty id is not a tool.
        let id = r["tool"].string ?? ""
        tool = NetTool.find(id) != nil ? id : "ping"
        target = r["target"].stringish ?? ""
        applyHostRef(r["on"])
        // A run's own options come back with it, so "again" means the same
        // call and not just the same URL.
        let o = r["opts"]
        if tool == "curl" && o.object != nil {
            curlMethod = o["method"].string ?? "GET"
            curlHeaders = o["headers"].string ?? ""
            curlBody = o["body"].string ?? ""
            curlType = o["contentType"].string ?? ""
            curlBearer = o["bearer"].string ?? ""
            curlInsecure = o["insecure"].truthy
            curlFollow = o["followRedirects"].bool != false
            curlTimeout = String(ntStoredTimeout(o["timeout"]))
        } else if o.object != nil {
            if o["count"].truthy { count = o["count"].stringish ?? count }
            if o["ports"].truthy { ports = o["ports"].stringish ?? ports }
            if o["method"].truthy { method = o["method"].stringish ?? method }
            if o["port"].truthy { telnetPort = o["port"].stringish ?? telnetPort }
        }
        syncOptions()
        run()
    }

    func renameSaved(_ r: JSON) {
        Task { @MainActor in
            guard let name = await NTAsk.prompt(handle?.window, title: "Rename request", label: "Name",
                                                value: r["name"].stringish ?? "", ok: "Save"), !name.isEmpty else { return }
            var rec = r; rec["name"] = .string(name)
            NetSaved.saveRequest(rec)
            reloadStrips()
        }
    }

    func copySavedAsCurl(_ r: JSON) {
        let o = CurlOptions(json: r["opts"], url: r["target"].stringish ?? "")
        guard let cmd = try? NetCurl.commandFor(o) else { return }
        Clipboard.write(cmd)
        say("Copied the curl command")
    }

    func deleteSaved(_ r: JSON) {
        Task { @MainActor in
            guard await NTAsk.confirm(handle?.window, title: "Delete request",
                                      message: "Delete \u{201C}\(r["name"].stringish ?? "")\u{201D}?", ok: "Delete", danger: true) else { return }
            let id = r["id"].string ?? ""
            NetSaved.deleteRequest(id)
            if savedId == id { savedId = nil }
            reloadStrips()
        }
    }

    func saveCurrentRequest() {
        let t = target.ntTrimmed
        if t.isEmpty { say("Give a URL first", kind: .error); return }
        let existing = savedId
        Task { @MainActor in
            guard let name = await NTAsk.prompt(handle?.window, title: existing != nil ? "Update saved request" : "Save this request",
                                                label: "Name", value: "\(curlMethod) \(NetText.shortUrl(t))", ok: "Save"),
                  !name.isEmpty else { return }
            // Kept by host rather than by connection: an id does not survive
            // the day, and "that request, from that server" is what is saved.
            NetSaved.saveRequest(["id": JSON(existing), "name": .string(name), "tool": "curl", "target": .string(t),
                                  "opts": curlOpts.json, "on": runOn.isEmpty ? .null : NetRemote.hostRef(runOn)])
            reloadStrips()
            say("Saved \u{201C}\(name)\u{201D}")
        }
    }

    // MARK: Examples

    struct Example {
        let name: String
        let why: String
        var target = ""
        var opts: [String: String] = [:]
        var curl: CurlExample?
    }

    /// The two or three things people actually run with each tool, with the
    /// target already shaped correctly — a logged-in proxy where one exists.
    func examples(for id: String) -> [Example] {
        let proxy = NetToolsModel.proxyNow()
        let px = proxy.isEmpty ? nil : proxy
        if id == "curl" {
            return CurlExample.all(proxy: Inventory.shared.profiles.first?.proxy).map { Example(name: $0.name, why: $0.why, curl: $0) }
        }
        let table: [String: [Example]] = [
            "ping": [
                Example(name: "Is this host answering?", why: "Five packets, then loss and round-trip times", target: px ?? "example.com", opts: ["count": "5"]),
                Example(name: "Watch for flapping", why: "Twenty packets — enough to see loss that comes and goes", target: px ?? "example.com", opts: ["count": "20"]),
                Example(name: "A gateway on the LAN", why: "Rules out the local network before blaming anything else", target: "192.168.1.1", opts: ["count": "5"]),
            ],
            "traceroute": [
                Example(name: "Where does it stop?", why: "The hop where a route dies is usually the answer", target: px ?? "example.com"),
                Example(name: "Path to a public resolver", why: "A known-good target, to tell \"my link\" from \"their host\"", target: "1.1.1.1"),
            ],
            "dns": [
                Example(name: "What does this name resolve to?", why: "A, AAAA, CNAME, MX, TXT, NS and SRV in one go", target: px ?? "example.com"),
                Example(name: "Reverse lookup an address", why: "PTR — which name claims this IP", target: "8.8.8.8"),
                Example(name: "A Teleport SRV record", why: "How clients discover a proxy when SRV is used", target: "_teleport._tcp.example.com"),
            ],
            "ports": [
                Example(name: "The usual Teleport ports", why: "Proxy web, SSH proxy, tunnel and node ports", target: px ?? "example.com", opts: ["ports": "443,3023,3024,3025,3080"]),
                Example(name: "Just SSH", why: "Is 22 open at all, and how quickly does it answer", target: "example.com", opts: ["ports": "22"]),
                Example(name: "A database behind a tunnel", why: "Check the local end of a port forward", target: "localhost", opts: ["ports": "5432,3306,6379"]),
            ],
            "telnet": [
                Example(name: "A switch or terminal server", why: "Port 23, and whatever login prompt it gives", target: "switch-1", opts: ["port": "23"]),
                Example(name: "What is on this SSH port?", why: "An SSH server names its version before anything else", target: px ?? "example.com", opts: ["port": "22"]),
                Example(name: "A mail server\u{2019}s greeting", why: "SMTP says who it is the moment you connect", target: "smtp.example.com", opts: ["port": "25"]),
                Example(name: "A console server line", why: "Terminal servers put each serial line on its own port", target: "console-1", opts: ["port": "2001"]),
            ],
            "serial": [
                Example(name: "Most things made this century", why: "115200 8N1, no flow control", opts: ["baud": "115200"]),
                Example(name: "Older network gear", why: "Cisco and friends at 9600 8N1 — the console default for decades", opts: ["baud": "9600"]),
            ],
            "tls": [
                Example(name: "When does this certificate expire?", why: "Chain, SANs, cipher and days left", target: px ?? "example.com:443"),
                Example(name: "A certificate on a non-standard port", why: "Written host:port, that port is the one inspected", target: "example.com:8443"),
            ],
            "http": [
                Example(name: "Does it answer, and how fast?", why: "Status, timing, size and the redirect chain", target: px.map { "https://" + $0 } ?? "https://example.com", opts: ["method": "GET"]),
                Example(name: "Headers only", why: "A HEAD request — caching, content type, redirects", target: "https://example.com", opts: ["method": "HEAD"]),
            ],
            "whois": [
                Example(name: "Who owns this domain?", why: "Registrar, dates and name servers", target: "example.com"),
                Example(name: "Who owns this address?", why: "The network it belongs to, and to whom", target: "8.8.8.8"),
            ],
            "teleport": [
                Example(name: "What is this cluster running?", why: "Version, edition, auth connector and every listener, without logging in", target: px ?? "teleport.example.com"),
            ],
            "local": [
                Example(name: "This machine", why: "Interfaces and resolvers, when the problem might be here"),
            ],
        ]
        return table[id] ?? []
    }

    func loadExample(_ x: Example) {
        if let c = x.curl {
            tool = "curl"
            target = c.url
            curlMethod = c.method
            curlHeaders = c.headers
            curlBody = c.body
            curlType = c.contentType
            curlBearer = c.bearer
            if let t = c.timeout { curlTimeout = String(t) }
        } else {
            // A serial example is about the speed, not a host — leave the
            // target alone for the next tool rather than blanking it.
            if tool != "serial" { target = x.target }
            if let v = x.opts["count"] { count = v }
            if let v = x.opts["ports"] { ports = v }
            if let v = x.opts["method"] { method = v }
            if let v = x.opts["port"] { telnetPort = v }
            if let v = x.opts["baud"] { serialBaud = v }
        }
        syncOptions()
        output = .loaded(name: x.name, why: x.why)
        say("Loaded: \(x.name)")
    }

    // MARK: Sessions that end the errand

    func serialHost(_ path: String) -> Host {
        var j: JSON = [
            "type": "serial", "kind": "serial", "path": .string(path), "name": .string(path),
            "baudRate": .number(ntNumberOr(serialBaud, 115200)), "dataBits": .number(ntNumberOr(serialDataBits, 8)),
            "parity": .string(serialParity), "stopBits": .number(ntNumberOr(serialStopBits, 1)),
            "rtscts": .bool(serialFlow == "rtscts"), "xon": .bool(serialFlow == "xonxoff"), "xoff": .bool(serialFlow == "xonxoff"),
            "newline": .string(serialNewline), "localEcho": .bool(serialEcho),
        ]
        j["id"] = .string("serial:" + path)
        return Host(json: j)
    }

    func openSerial(_ path: String) {
        let p = path.ntTrimmed
        if p.isEmpty { say("Choose a serial port first", kind: .error); return }
        serialPath = p
        let h = serialHost(p)
        handle?.close()
        Actions.shared.perform("serial-open", window: window, host: h)
    }

    func saveSerial(_ path: String) {
        let p = path.ntTrimmed
        if p.isEmpty { say("Choose a serial port first", kind: .error); return }
        var j = serialHost(p).json
        j.removeKey("kind")
        j.removeKey("id")
        // The editor is a sheet on the main window; bring that window forward
        // so it is not opened behind this panel.
        (window ?? WindowManager.shared.focused)?.nsWindow?.makeKeyAndOrderFront(nil)
        Actions.shared.perform("new-profile", window: window, args: ["profile": j])
    }

    /// Telnet to the target: from here with the app's own client, or from the
    /// chosen host with that host's `telnet` in a terminal there.
    func openTelnet() {
        let t: (host: String, port: Int)
        do { t = try NetCheck.telnetTarget(target, telnetPort) } catch {
            say(error.localizedDescription, kind: .error); return
        }
        if !runOn.isEmpty {
            if let caps, !caps.tools.contains("telnet") {
                say("No telnet on \(NTConnections.info(runOn)?.label ?? "that host") — "
                    + "install the telnet package there, or open it from this machine", kind: .error)
                return
            }
            let label = NTConnections.info(runOn)?.label ?? "host"
            let id = runOn
            handle?.close()
            NTConnections.openTerminal(id, startupCommand: "telnet \(t.host) \(t.port)", title: "\(t.host):\(t.port) via \(label)",
                                       window: window)
            return
        }
        let h = Host(json: ["type": "telnet", "kind": "telnet", "id": .string("telnet:\(t.host):\(t.port)"),
                            "hostname": .string(t.host), "host": .string(t.host), "port": .number(Double(t.port)),
                            "name": .string("\(t.host):\(t.port)"), "newline": .string(telnetNewline),
                            "localEcho": .bool(telnetEcho)])
        handle?.close()
        Actions.shared.perform("telnet-open", window: window, host: h)
    }

    // MARK: Running

    func run() {
        if running { return }
        let t = target.ntTrimmed
        if needsTarget && t.isEmpty { say("Give a host", kind: .error); return }
        running = true
        let tool = self.tool
        output = .running("Running \(NetTool.label(tool))…")
        say("\(NetTool.label(tool)) \(t)…", seconds: 0)
        let on = runOn
        let opts: JSON = tool == "curl" ? curlOpts.json
            : ["count": .string(count), "ports": .string(ports.ntTrimmed), "method": .string(method), "port": .string(telnetPort)]
        let onRef = on.isEmpty ? JSON.null : NetRemote.hostRef(on)
        Task { @MainActor in
            var ok = true
            var summary = ""
            do {
                let r = try await dispatch(tool, t, on: on)
                output = .result(r.display)
                lastText = r.text.isEmpty ? r.display.plainText : r.text
                lastName = r.name
                summary = r.note
            } catch {
                ok = false
                summary = error.localizedDescription
                output = .error(summary)
                lastText = summary
                lastName = "\(tool)-\(NetText.safeName(t)).txt"
            }
            running = false
            say("")
            // Remembered whatever the outcome: a run that failed is one of the
            // ones most worth repeating. Not the serial list, though.
            if tool != "serial" {
                NetSaved.addRun(["tool": .string(tool), "target": .string(t), "opts": opts, "on": onRef,
                                 "ok": .bool(ok), "summary": .string(summary)])
            }
            if tool == "curl", let id = savedId,
               let rec = NetSaved.requests().first(where: { $0["id"].string == id }) {
                NetSaved.saveRequest(["id": .string(id), "name": rec["name"], "tool": "curl", "target": .string(t),
                                      "opts": curlOpts.json, "on": rec["on"], "lastRunAt": .number(nowMs())])
            }
            reloadStrips()
        }
    }

    struct Dispatched {
        var display: NetDisplay
        var text: String
        var name: String
        var note: String
    }

    /// Run one tool and hand back what to show, what to save, and one line
    /// for the recent list — the three things every tool has to produce.
    func dispatch(_ tool: String, _ target: String, on: String) async throws -> Dispatched {
        let safe = NetText.safeName
        if !on.isEmpty {
            let label = onLabel
            switch tool {
            case "ping":
                let r = try await NetRemote.hostPing(on, host: target, count: count)
                let note = NetText.pingNote(text: r.text, missing: r.missing)
                return Dispatched(display: .remoteText(r, label: label), text: r.text,
                                  name: "ping-from-\(safe(label))-to-\(safe(target)).txt", note: note.isEmpty ? "from \(label)" : note)
            case "traceroute":
                let r = try await NetRemote.hostTrace(on, host: target)
                return Dispatched(display: .remoteText(r, label: label), text: r.text,
                                  name: "traceroute-from-\(safe(label))-to-\(safe(target)).txt",
                                  note: r.missing != nil ? "no traceroute on \(label)" : "\(r.tool ?? "") · from \(label)")
            case "ports":
                let r = try await NetRemote.hostPorts(on, host: target, ports: ports.ntTrimmed)
                let open = r.results.filter { $0.open == true }.count
                return Dispatched(display: .remotePorts(r, label: label), text: NetText.pretty(r.json),
                                  name: "ports-from-\(safe(label))-to-\(safe(target)).json",
                                  note: "\(open) of \(r.results.count) open from \(label)")
            case "telnet":
                // From a host, "is anything listening" is the port check; the
                // conversation itself is the host's own telnet.
                let t = try NetCheck.telnetTarget(target, telnetPort)
                let r = try await NetRemote.hostPorts(on, host: t.host, ports: String(t.port))
                let p = r.results.first
                let hasTelnet = caps.map { $0.tools.contains("telnet") } ?? true
                return Dispatched(display: .remoteTelnet(r, host: t.host, port: t.port, label: label, hasTelnet: hasTelnet),
                                  text: NetText.pretty(r.json), name: "telnet-from-\(safe(label))-to-\(safe(t.host))-\(t.port).json",
                                  note: "\(PortStateInfo.of(state: p?.state, open: p?.open).label) from \(label)")
            case "curl":
                let r = try await NetRemote.hostCurl(on, curlOpts)
                return Dispatched(display: .curl(r, from: label), text: r.body,
                                  name: "response-from-\(safe(label))\(NetText.bodyExt(r.contentType))",
                                  note: "\(r.status) \(r.statusText) · \(Fmt.bytes(r.bytes)) · \(Fmt.duration(ms: r.ms)) · from \(label)")
            case "local":
                let f = try await NetRemote.hostFacts(on)
                return Dispatched(display: .hostFacts(f, label: label), text: f.ntText, name: "\(safe(label))-network.txt", note: f.hostname)
            default:
                throw AppError("\(NetTool.label(tool)) runs from this machine only for now.")
            }
        }
        switch tool {
        case "ping":
            let r = try await NetLocal.ping(host: target, count: count)
            return Dispatched(display: .text(r), text: r.text, name: "ping-\(safe(target)).txt", note: NetText.firstLine(r.text))
        case "traceroute":
            let r = try await NetLocal.traceroute(host: target)
            return Dispatched(display: .text(r), text: r.text, name: "traceroute-\(safe(target)).txt", note: NetText.firstLine(r.text))
        case "dns":
            let r = try await NetLocal.lookup(host: target)
            return Dispatched(display: .dns(r), text: NetText.pretty(r.json), name: "dns-\(safe(target)).json",
                              note: r.records.filter { !$0.values.isEmpty }.map(\.type).joined(separator: ", "))
        case "ports":
            let r = try await NetLocal.portCheck(host: target, ports: ports.ntTrimmed)
            let open = r.results.filter { $0.state == "open" }.map { String($0.port) }
            return Dispatched(display: .ports(r), text: NetText.pretty(r.json), name: "ports-\(safe(target)).json",
                              note: open.isEmpty ? "nothing open" : "open: " + open.joined(separator: ", "))
        case "telnet":
            let t = try NetCheck.telnetTarget(target, telnetPort)
            let r = try await NetLocal.telnetProbe(host: t.host, port: String(t.port))
            return Dispatched(display: .telnet(r), text: r.text, name: "telnet-\(safe(t.host))-\(t.port).txt",
                              note: r.state == "open"
                                ? (r.guess ?? (r.text.isEmpty ? "open, said nothing" : String(NetText.firstLine(r.text).prefix(80))))
                                : PortStateInfo.of(state: r.state).label)
        case "serial":
            let ports = await DeviceSessions.shared.listPorts()
            return Dispatched(display: .serial(ports),
                              text: ports.map { [$0.path, $0.label].filter { !$0.isEmpty }.joined(separator: "  ") }.joined(separator: "\n"),
                              name: "serial-ports.txt", note: "\(ports.count) port\(ports.count == 1 ? "" : "s")")
        case "tls":
            let r = try await NetTLS.info(host: target)
            let cn = r.subject.first { $0.0 == "CN" }?.1
            return Dispatched(display: .tls(r), text: NetText.pretty(r.json), name: "tls-\(safe(target)).json",
                              note: cn.map { "\($0), \(r.daysLeft.map(String.init) ?? "?") days left" } ?? "")
        case "http":
            let r = try await NetTLS.httpCheck(url: target, method: method)
            return Dispatched(display: .http(r), text: NetText.pretty(r.json), name: "http-\(safe(target)).json",
                              note: "\(r.final?.status ?? 0) \(r.final?.statusMessage ?? "")".ntTrimmed)
        case "curl":
            let r = try await NetCurl.request(curlOpts)
            return Dispatched(display: .curl(r, from: nil), text: r.body, name: "response-\(safe(target))\(NetText.bodyExt(r.contentType))",
                              note: "\(r.status) \(r.statusText) · \(Fmt.bytes(r.bytes)) · \(Fmt.duration(ms: r.ms))")
        case "whois":
            let r = try await NetLocal.whois(host: target)
            return Dispatched(display: .text(r), text: r.text, name: "whois-\(safe(target)).txt", note: NetText.firstLine(r.text))
        case "teleport":
            let r = try await WebAPIPing.ping(proxy: target)
            let json: JSON = ["url": .string(r.url), "ms": .number(Double(r.ms)), "ping": r.ping]
            return Dispatched(display: .teleport(r), text: NetText.pretty(json), name: "webapi-ping-\(safe(target)).json",
                              note: r.note)
        case "local":
            let r = NetLocal.localInfo()
            return Dispatched(display: .local(r), text: NetText.pretty(r.json), name: "this-machine.json", note: r.hostname)
        default:
            throw AppError("Unknown tool")
        }
    }

    // MARK: Footer

    /// What the result area shows, as text (`body.innerText`).
    var outputText: String {
        switch output {
        case .help(let id):
            let typical = NetHelp.typical(id)
            return ([NetHelp.hint(id)] + (typical.isEmpty ? [] : ["Typical things to run"] + typical)
                    + ["Examples\u{2026} fills any of these in for you."]).joined(separator: "\n")
        case .running(let t): return t
        case .loaded(let name, let why): return [name, why, "Edit anything and press Run."].joined(separator: "\n")
        case .error(let m): return m
        case .result(let d): return d.plainText
        }
    }

    func copyOutput() {
        let text = outputText.ntTrimmed
        if text.isEmpty { say("Nothing to copy"); return }
        Clipboard.write(text)
        say("Output copied")
    }

    func saveOutput() {
        // `lastText || body.innerText`
        let text = lastText.isEmpty ? outputText.ntTrimmed : lastText
        if text.isEmpty { say("Nothing to save yet"); return }
        let name = lastName.isEmpty ? "\(tool)-\(NetText.safeName(target)).txt" : lastName
        Task { @MainActor in
            if let url = await NTAsk.saveText(handle?.window, text, defaultName: name) {
                say("Output saved to \(url.path)", kind: .ok)
            }
        }
    }
}

