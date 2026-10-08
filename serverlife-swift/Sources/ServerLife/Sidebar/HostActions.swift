import AppKit
import SwiftUI

/// Port of hostactions.js — host actions that need a live connection but not
/// a terminal: port forwarding (and favourite tunnels), the server profile,
/// and running one command; plus choosing a host from the whole inventory.
@MainActor
enum SBHostActions {
    /// Get (or create and dial) a connection for a host. `fresh` skips reuse
    /// ("try that again as somebody else").
    static func ensureConnection(_ host: Host, login: String?, fresh: Bool = false) async throws -> String {
        let cm = ConnectionManager.shared
        if !fresh, let c = cm.connections.first(where: { $0.hostId == host.id && ($0.state == .connected || $0.state == .connecting) }) {
            if c.state != .connected { try await cm.connect(c.id) }
            return c.id
        }
        let c = try await cm.create(host: host, options: ConnectOptions(login: login))
        try await cm.connect(c.id)
        return c.id
    }

    // MARK: Choosing a host

    /// `pickHost`: search the whole inventory.
    static func pickHost(window: WindowModel?) async -> Host? {
        let all = Inventory.shared.allNodes + Inventory.shared.sshHosts
        return await SBModal.ask(window, width: 520) { finish in PickHostView(all: all, finish: finish) }
    }

    // MARK: Favourite tunnels

    /// What a favourite remembers about its host (whole, not an id).
    static func favoriteHostRef(_ host: Host) -> JSON {
        [
            "id": .string(host.id), "type": .string(host.type.isEmpty ? Host.ssh : host.type),
            "name": .string(host.name.nilIfEmpty ?? host.alias ?? ""), "alias": JSON(host.alias?.nilIfEmpty),
            "hostname": JSON(host.hostname?.nilIfEmpty), "uuid": JSON(host.uuid?.nilIfEmpty), "cluster": JSON(host.cluster?.nilIfEmpty),
            "proxy": JSON(host.proxy?.nilIfEmpty), "home": JSON(host.home?.nilIfEmpty),
            "direct": host.direct.map { JSON.encode($0) } ?? .null, "configFile": JSON(host.configFile?.nilIfEmpty),
        ]
    }

    static func saveForwardFavorite(_ host: Host, _ fwd: ForwardSpec, login: String?, name: String) throws {
        try SBData.addForwardFavorite([
            "name": .string(name), "kind": .string(fwd.kind), "bindPort": .number(Double(fwd.bindPort)),
            "bindAddr": .string(fwd.bindAddr ?? ""), "destHost": .string(fwd.destHost ?? ""),
            "destPort": .number(Double(fwd.destPort ?? 0)), "host": favoriteHostRef(host), "login": JSON(login?.nilIfEmpty),
        ])
    }

    nonisolated static func describeFavorite(_ f: JSON) -> String {
        let kind = f["kind"].string ?? "L"
        let bind = f["bindAddr"].string?.nilIfEmpty ?? "localhost"
        let bp = f["bindPort"].stringish ?? ""
        if kind == "D" { return "SOCKS5 on \(bind):\(bp)" }
        if kind == "L" { return "\(bind):\(bp) → \(f["destHost"].stringish ?? ""):\(f["destPort"].stringish ?? "")" }
        return "server:\(bp) → \(f["destHost"].stringish ?? ""):\(f["destPort"].stringish ?? "")"
    }

    /// Open a favourite: dial its host if needed, then put the tunnel back up.
    static func openForwardFavorite(_ fav: JSON, window: WindowModel?) async {
        SBActions.status("Opening tunnel…", seconds: 0)
        defer { StatusBus.shared.clear() }
        do {
            let host = Host(json: fav["host"])
            let id = try await ensureConnection(host, login: fav["login"].string?.nilIfEmpty)
            let kind = fav["kind"].string ?? "L"
            _ = try await ConnectionManager.shared.addForward(id, ForwardSpec(
                kind: kind, bindAddr: fav["bindAddr"].string?.nilIfEmpty, bindPort: fav["bindPort"].int ?? 0,
                destHost: fav["destHost"].string?.nilIfEmpty, destPort: (fav["destPort"].int ?? 0) == 0 ? nil : fav["destPort"].int))
            if let fid = fav["id"].string { SBData.markForwardFavoriteUsed(fid) }
            SBActions.toast("Tunnel open — " + describeFavorite(fav), .ok)
            (window ?? WindowManager.shared.focused)?.showDock("forwards")
        } catch {
            SBActions.toast(error.localizedDescription, .error)
        }
    }

    // MARK: Port forward

    static func openPortForward(_ host: Host?, login: String?, connId: String? = nil, preset: JSON? = nil, window: WindowModel?) {
        Task {
            guard let res: PortForwardView.Result = await SBModal.ask(window, width: 560, content: { finish in
                PortForwardView(subtitle: host.map(HostPrefs.label) ?? "", preset: preset, finish: finish)
            }) else { return }
            SBActions.status("Opening tunnel…", seconds: 0)
            defer { StatusBus.shared.clear() }
            do {
                let id: String
                if let connId { id = connId } else if let host { id = try await ensureConnection(host, login: login) } else { return }
                let rec = try await ConnectionManager.shared.addForward(id, res.spec)
                let desc = rec.kind == "D" ? "SOCKS5 on localhost:\(rec.bindPort)"
                    : rec.kind == "L" ? "localhost:\(rec.bindPort) → \(rec.destHost ?? ""):\(rec.destPort.map(String.init) ?? "")"
                    : "server:\(rec.bindPort) → \(rec.destHost ?? ""):\(rec.destPort.map(String.init) ?? "")"
                if res.favorite {
                    do {
                        guard let host else { throw AppError("Nothing to open this on — the host is no longer in the list.") }
                        try saveForwardFavorite(host, res.spec, login: login, name: res.favoriteName)
                    } catch { SBActions.toast("Tunnel is open, but it was not saved: " + error.localizedDescription, .error) }
                }
                SBActions.toast("Tunnel open — " + desc, .ok)
                (window ?? WindowManager.shared.focused)?.showDock("forwards")
            } catch {
                SBActions.toast(error.localizedDescription, .error)
            }
        }
    }

    // MARK: Server profile

    static func openServerInfo(_ host: Host, login: String?, connId: String? = nil, window: WindowModel?) {
        let model = ServerInfoModel(host: host, login: login, connId: connId, window: window)
        Modal.sheet(window, title: "Server profile", width: 600) { handle in
            ServerInfoView(model: model) { handle.close() }
        }
        model.load(refresh: false)
    }

    // MARK: Run a command

    /// The last ad-hoc command, offered for the empty case.
    static var lastQuickCommand = ""

    static func openRunCommand(_ host: Host, login: String?, connId: String? = nil, command: String? = nil,
                               title: String? = nil, autoRun: Bool = true, window: WindowModel?) {
        let model = RunCommandModel(host: host, login: login, connId: connId, command: command ?? lastQuickCommand)
        Modal.sheet(window, title: title ?? "Run a command", width: 720) { handle in
            RunCommandView(model: model, title: title ?? "Run a command", window: window) { handle.close() }
        }
        if command != nil && autoRun { model.run() }
    }
}

// MARK: - Pick a host

private struct PickHostView: View {
    let all: [Host]
    let finish: (Host?) -> Void
    @StateObject private var q = Local("")
    @FocusState private var focused: Bool

    var body: some View {
        let query = q.value.trimmed.lowercased()
        let shown = Array((query.isEmpty ? all : all.filter {
            "\($0.name) \($0.alias ?? "") \($0.hostname ?? "") \($0.cluster ?? "")".lowercased().contains(query)
        }).prefix(300))
        DialogScaffold(title: "Choose a host", subtitle: "\(all.count) host\(all.count == 1 ? "" : "s") in the list", width: 520) {
            VStack(alignment: .leading, spacing: 4) {
                MiscField(label: "Host") {
                    TextField("Search hosts…", text: $q.value).textFieldStyle(.roundedBorder)
                        .focused($focused).onAppear { DispatchQueue.main.async { focused = true } }
                }
                ForEach(shown, id: \.id) { h in
                    SBPickerRow(title: h.name.nilIfEmpty ?? h.alias ?? "") {
                        SBTag(text: h.type == Host.teleport ? (h.cluster?.nilIfEmpty ?? "tsh") : "ssh")
                    } action: { finish(h) }
                }
                if shown.isEmpty { MiscHint(text: "No matches.", size: 12).padding(10) }
                MiscHint(text: "\(shown.count) shown\(shown.count < all.count ? " of \(all.count)" : "")").padding(.top, 8)
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .frame(height: 520)
    }
}

// MARK: - Port forward dialog

private struct PortForwardView: View {
    struct Result { var spec: ForwardSpec; var favorite: Bool; var favoriteName: String }
    static let kinds: [(value: String, label: String)] = [
        ("L", "Local  (-L)  — a port on this Mac reaches a remote service"),
        ("R", "Remote (-R)  — a port on the server reaches a local service"),
        ("D", "Dynamic (-D) — SOCKS5 proxy through the server"),
    ]

    let subtitle: String
    let finish: (Result?) -> Void
    @StateObject private var kind: Local<String>
    @StateObject private var bindPort: Local<String>
    @StateObject private var destHost: Local<String>
    @StateObject private var destPort: Local<String>
    @StateObject private var bindAddr: Local<String>
    @StateObject private var fav: Local<Bool>
    @StateObject private var favName: Local<String>

    init(subtitle: String, preset: JSON?, finish: @escaping (Result?) -> Void) {
        self.subtitle = subtitle
        self.finish = finish
        let pr = preset ?? .null
        _kind = StateObject(wrappedValue: Local(pr["kind"].string ?? "L"))
        _bindPort = StateObject(wrappedValue: Local(pr["bindPort"].stringish?.nilIfEmpty ?? "8080"))
        _destHost = StateObject(wrappedValue: Local(pr["destHost"].string?.nilIfEmpty ?? "localhost"))
        _destPort = StateObject(wrappedValue: Local(pr["destPort"].int.flatMap { $0 == 0 ? nil : String($0) } ?? "80"))
        _bindAddr = StateObject(wrappedValue: Local(pr["bindAddr"].string ?? ""))
        _fav = StateObject(wrappedValue: Local(pr["name"].truthy))
        _favName = StateObject(wrappedValue: Local(pr["name"].string ?? ""))
    }

    private var explain: String {
        let bp = bindPort.value.isEmpty ? "?" : bindPort.value
        let dh = destHost.value.isEmpty ? "?" : destHost.value
        let dp = destPort.value.isEmpty ? "?" : destPort.value
        switch kind.value {
        case "L": return "localhost:\(bp) on this Mac → \(dh):\(dp) as seen from the server."
        case "R": return "Port \(bp) on the server → \(dh):\(dp) as seen from this Mac. Needs GatewayPorts on the server to accept non-local clients."
        default: return "SOCKS5 proxy on localhost:\(bp); point a browser or curl at it to exit through the server."
        }
    }

    private func create() {
        guard let port = Int(bindPort.value.trimmed), port >= 1, port <= 65535 else {
            SBActions.toast("Enter a valid listen port", .error); return
        }
        if kind.value != "D" {
            if destHost.value.trimmed.isEmpty { SBActions.toast("Destination host is required", .error); return }
            if (Int(destPort.value.trimmed) ?? 0) == 0 { SBActions.toast("Enter a valid destination port", .error); return }
        }
        let spec = ForwardSpec(kind: kind.value, bindAddr: bindAddr.value.trimmed.nilIfEmpty, bindPort: port,
                               destHost: kind.value == "D" ? nil : destHost.value.trimmed,
                               destPort: kind.value == "D" ? nil : Int(destPort.value.trimmed))
        finish(Result(spec: spec, favorite: fav.value, favoriteName: favName.value.trimmed))
    }

    var body: some View {
        DialogScaffold(title: "Port forward", subtitle: subtitle, width: 560) {
            VStack(alignment: .leading, spacing: 4) {
                MiscField(label: "Type") { OptionPicker(options: Self.kinds.map { SettingsDialog.Option(value: $0.value, label: $0.label) }, selection: $kind.value) }
                HStack(alignment: .top, spacing: 10) {
                    MiscField(label: "Listen port") { TextField("", text: $bindPort.value).textFieldStyle(.roundedBorder) }
                    MiscField(label: "Listen address (optional)") {
                        TextField("localhost (default)", text: $bindAddr.value).textFieldStyle(.roundedBorder)
                    }
                }
                if kind.value != "D" {
                    HStack(alignment: .top, spacing: 10) {
                        MiscField(label: "Destination host") { TextField("localhost", text: $destHost.value).textFieldStyle(.roundedBorder) }
                        MiscField(label: "Destination port") { TextField("", text: $destPort.value).textFieldStyle(.roundedBorder) }
                    }
                }
                MiscHint(text: explain, size: 11.5)
                VStack(alignment: .leading, spacing: 4) {
                    MiscCheck(label: "Keep this as a favourite", isOn: $fav.value)
                    if fav.value {
                        MiscField(label: "Name it") { TextField("Database on the replica", text: $favName.value).textFieldStyle(.roundedBorder) }
                    }
                }
                .padding(.top, 10)
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Create tunnel") { create() }.buttonStyle(.primary)
        }
    }
}

// MARK: - Server profile

@MainActor
final class ServerInfoModel: ObservableObject {
    let host: Host
    let window: WindowModel?
    @Published var currentLogin: String?
    @Published var info: ServerInfo?
    @Published var loadingText: String?
    @Published var error: String?
    private var id: String?

    init(host: Host, login: String?, connId: String?, window: WindowModel?) {
        self.host = host; self.currentLogin = login; self.id = connId; self.window = window
    }

    func load(refresh: Bool, retryAs: String? = nil) {
        if let retryAs { currentLogin = retryAs; id = nil }
        error = nil
        loadingText = (refresh ? "Refreshing" : "Probing server") + (currentLogin.map { " as \($0)…" } ?? "…")
        Task { @MainActor in
            do {
                let cid: String
                if let id { cid = id } else { cid = try await SBHostActions.ensureConnection(host, login: currentLogin, fresh: retryAs != nil) }
                self.id = cid
                let i = try await ConnectionManager.shared.serverInfo(cid, refresh: refresh)
                if retryAs != nil { HostPrefs.rememberLogin(host.id, currentLogin) }
                self.info = i
                self.loadingText = nil
            } catch {
                self.loadingText = nil
                self.info = nil
                self.error = error.localizedDescription
            }
        }
    }

    func tryAnother() {
        Task {
            let who = await SBDialogs.pickLogin(HostPrefs.loginOptions(host), host: host, title: "Read the profile as",
                                                subtitle: HostPrefs.label(host),
                                                note: currentLogin.map { "\($0) did not work. Pick another account on this host." },
                                                window: window)
            if let who { load(refresh: true, retryAs: who) }
        }
    }

    func copy() {
        guard let info else { return }
        // The probe's own order, as Object.entries(info) gave it.
        let order = ["kernel_sys", "kernel", "arch", "hostname", "user", "shell", "os_pretty", "os_name", "os_version", "os_id",
                     "uptime", "cpus", "cpu_model", "mem_total_kb", "mem_avail_kb", "load", "disk_root", "virt", "init",
                     "users_online", "pkg", "has_docker", "has_kubectl", "has_podman"]
        var lines: [String] = order.compactMap { k in info.values[k].map { "\(k)=\($0)" } }
        lines += info.values.keys.filter { !order.contains($0) }.sorted().map { "\($0)=\(info.values[$0]!)" }
        lines.append("osLabel=\(info.osLabel)")
        if let partial = info.partial { lines.append("partial=\(partial)") }
        Clipboard.write(lines.joined(separator: "\n"))
        SBActions.status("Server profile copied")
    }

    nonisolated static func distroGlyph(_ osId: String, _ kernelSys: String?) -> String {
        func has(_ p: String) -> Bool { osId.range(of: p, options: .regularExpression) != nil }
        if kernelSys == "Darwin" || osId == "macos" { return "\u{1F34E}" }
        if has("ubuntu") { return "\u{1F7E0}" }
        if has("debian") { return "\u{1F300}" }
        if has("rhel|centos|rocky|alma|fedora") { return "\u{1F3A9}" }
        if has("amzn|amazon") { return "\u{1F4E6}" }
        if has("alpine") { return "\u{1F3D4}" }
        if has("suse") { return "\u{1F98E}" }
        if has("arch") { return "\u{1F3F9}" }
        if has("bsd") { return "\u{1F608}" }
        return "\u{1F427}"
    }
}

private struct ServerInfoView: View {
    @ObservedObject var model: ServerInfoModel
    let close: () -> Void

    var body: some View {
        DialogScaffold(title: "Server profile", subtitle: HostPrefs.label(model.host), width: 600) {
            content
        } footer: {
            Button("Copy") { model.copy() }.buttonStyle(.ghost)
            Button("Refresh") { model.load(refresh: true) }.buttonStyle(.ghost)
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .frame(minHeight: 260)
    }

    @ViewBuilder private var content: some View {
        let p = Theme.shared.p
        if let t = model.loadingText {
            Text(t).font(.system(size: 12)).foregroundStyle(p.muted).padding(14)
        } else if let e = model.error {
            let options = HostPrefs.loginOptions(model.host).filter { $0 != model.currentLogin }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.currentLogin.map { "Could not read the server profile as \($0)" } ?? "Could not read the server profile")
                    .font(.system(size: 13, weight: .semibold))
                Text(e).font(.system(size: 12)).foregroundStyle(p.red).textSelection(.enabled)
                MiscHint(text: options.isEmpty
                         ? "The profile is one command run over this session. A host behind a restricted shell or a forced command will refuse it while the terminal itself still works."
                         : "This cluster also grants \(options.joined(separator: ", ")) on this host’s behalf. If the account does not exist on the box, the profile fails exactly like this while another login works fine.",
                         size: 11.5).padding(.top, 4)
                HStack(spacing: 6) {
                    Button("Try another user…") { model.tryAnother() }.buttonStyle(GhostButtonStyle(small: true, prominent: true))
                        .help("Dial again as a different account and remember it if it works")
                    Button(model.currentLogin.map { "Try \($0) again" } ?? "Try again") { model.load(refresh: true) }.buttonStyle(.ghostSmall)
                }
                .padding(.top, 6)
            }
            .padding(.vertical, 14).padding(.horizontal, 2)
        } else if let info = model.info {
            infoBody(info, p)
        }
    }

    private func infoBody(_ info: ServerInfo, _ p: Palette) -> some View {
        let osId = (info["os_id"] ?? "").lowercased()
        let tooling = [info["has_docker"] != nil ? "docker" : nil, info["has_kubectl"] != nil ? "kubectl" : nil,
                       info["has_podman"] != nil ? "podman" : nil].compactMap { $0 }.joined(separator: ", ")
        let cpu: String? = info["cpu_model"].map { "\(info["cpus"] ?? "?") × \($0)" } ?? info["cpus"]
        let mem: String? = info.memTotal.map { "\(Fmt.bytes($0)) total\(info.memAvail.map { " · \(Fmt.bytes($0)) available" } ?? "")" }
        let virt = info["virt"].flatMap { $0 == "none" ? nil : $0 }
        let rows: [(String, String?)] = [
            ("Hostname", info["hostname"]), ("Logged in as", info["user"]), ("Login shell", info["shell"]),
            ("Uptime", info["uptime"]), ("Load average", info["load"]), ("CPU", cpu), ("Memory", mem),
            ("Disk /", info["disk_root"]), ("Virtualisation", virt), ("Init system", info["init"]),
            ("Package manager", info["pkg"]), ("Users online", info["users_online"]), ("Tooling", tooling.nilIfEmpty),
        ]
        let tags = Tags.labelEntries(model.host)
        return VStack(alignment: .leading, spacing: 0) {
            if let partial = info.partial {
                Text("Some of this is missing — \(partial)").font(.system(size: 11)).foregroundStyle(p.amber).padding(.bottom, 12)
            }
            HStack(spacing: 11) {
                Text(ServerInfoModel.distroGlyph(osId, info["kernel_sys"])).font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.osLabel.nilIfEmpty ?? "Unknown system").font(.system(size: 15, weight: .semibold))
                    Text("\(info["kernel_sys"] ?? "") \(info["kernel"] ?? "") · \(info["arch"] ?? "")")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(p.muted)
                }
            }
            .padding(.bottom, 13)
            p.borderSoft.frame(height: 1).padding(.bottom, 14)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows.filter { ($0.1 ?? "").isEmpty == false }, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(.system(size: 12)).foregroundStyle(p.muted).frame(width: 132, alignment: .leading)
                        Text(r.1 ?? "").font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            if !tags.isEmpty {
                p.borderSoft.frame(height: 1).padding(.top, 15).padding(.bottom, 13)
                Text("Teleport tags (\(tags.count))").font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 7)
                SBFlow(spacing: 4) {
                    ForEach(tags, id: \.key) { t in
                        SBChip(key: t.key, value: t.value.isEmpty ? "—" : t.value, size: 11, help: "\(t.key) = \(t.value)") {}
                    }
                }
            }
            MiscHint(text: "Probed \(Fmt.date(ms: info.fetchedAt)) over the existing connection.", size: 11).padding(.top, 14)
        }
    }
}

// MARK: - Run a command

@MainActor
final class RunCommandModel: ObservableObject {
    let host: Host
    let login: String?
    private var id: String?
    @Published var command: String
    @Published var output = "Output appears here."
    @Published var failed = false
    @Published var meta = ""
    private var running = false
    private var lastOutput = ""

    init(host: Host, login: String?, connId: String?, command: String) {
        self.host = host; self.login = login; self.id = connId; self.command = command
    }

    func run() {
        let cmd = command.trimmed
        if cmd.isEmpty { SBActions.toast("Enter a command", .error); return }
        if running { return }
        running = true
        SBHostActions.lastQuickCommand = cmd
        output = "Running…"; failed = false; meta = ""
        let t0 = nowMs()
        Task { @MainActor in
            defer { self.running = false }
            do {
                let cid: String
                if let id { cid = id } else { cid = try await SBHostActions.ensureConnection(host, login: login) }
                self.id = cid
                let r = try await ConnectionManager.shared.exec(cid, cmd)
                lastOutput = r.stdout
                output = r.stdout.trimmed.nilIfEmpty ?? "(no output)"
                failed = false
                meta = "Finished in \(Fmt.duration(ms: nowMs() - t0)) · \(r.stdout.utf8.count) bytes"
            } catch {
                lastOutput = error.localizedDescription
                output = error.localizedDescription.nilIfEmpty ?? "Command failed"
                failed = true
                meta = "Failed after \(Fmt.duration(ms: nowMs() - t0))"
            }
        }
    }

    func copyOutput() {
        if lastOutput.isEmpty { SBActions.toast("Nothing to copy yet", .info); return }
        Clipboard.write(lastOutput)
        SBActions.status("Output copied")
    }
}

private struct RunCommandView: View {
    @ObservedObject var model: RunCommandModel
    let title: String
    let window: WindowModel?
    let close: () -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: title, subtitle: HostPrefs.label(model.host), width: 720) {
            VStack(alignment: .leading, spacing: 4) {
                MiscField(label: "Command", hint: "Enter runs it · Shift+Enter for a new line") {
                    SBCommandEditor(text: $model.command, placeholder: "systemctl status nginx") { model.run() }
                        .frame(height: 78)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                }
                Text("Output").font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 1)
                ScrollView {
                    Text(model.output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(model.failed ? p.red : p.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                }
                .frame(minHeight: 64, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                if !model.meta.isEmpty { MiscHint(text: model.meta, size: 11).padding(.top, 6) }
            }
        } footer: {
            Button("Copy output") { model.copyOutput() }.buttonStyle(.ghost)
            Button("Save as snippet") {
                let cmd = model.command.trimmed
                if cmd.isEmpty { SBActions.toast("Enter a command first", .error); return }
                Actions.shared.perform("snippet-from-selection", window: window, args: ["text": cmd])
            }.buttonStyle(.ghost)
            Button("Run") { model.run() }.buttonStyle(.primary)
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }
}

/// A plain multi-line editor where Return submits and Shift+Return adds a line.
struct SBCommandEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.string = text
        tv.textContainerInset = NSSize(width: 4, height: 5)
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(Theme.shared.p.bg)
        tv.textColor = NSColor(Theme.shared.p.text)
        tv.insertionPointColor = NSColor(Theme.shared.p.text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = v.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SBCommandEditor
        init(_ p: SBCommandEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tv.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// A wrapping row of small views (the tag chips).
struct SBFlow: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            let w = min(sz.width, width)
            if x > 0 && x + w > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += w + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            let w = min(sz.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: sz.height))
            x += w + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
