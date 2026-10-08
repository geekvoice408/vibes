import AppKit
import SwiftUI

/// profiles.js: the editor for one saved profile — SSH, Teleport, serial,
/// telnet, VNC and RDP in one record and one list — and the helpers the
/// lists use to describe one.
@MainActor
enum Profiles {
    /// The port a protocol uses when nobody has said otherwise.
    static func defaultPort(for type: String, initial: JSON = [:]) -> Int {
        if let d = initial["devicePort"].int, d != 0, initial["type"].string == type { return d }
        switch type {
        case "telnet": return 23
        case "vnc": return 5900
        case "rdp": return 3389
        default: return 22
        }
    }

    /// What a saved connection says about itself in a list (`profileMeta`).
    static func meta(_ p: JSON) -> String {
        let type = p["type"].string
        if type == "teleport" { return "\(p["node"].stringish ?? "null") @ \(p["cluster"].stringish ?? "null")" }
        if type == "serial" { return "\(p["path"].stringish ?? "") · \(p["baudRate"].truthy ? p["baudRate"].stringish ?? "" : "115200")" }
        if type == "telnet" || type == "vnc" || type == "rdp" {
            let port = p["devicePort"].truthy ? (p["devicePort"].stringish ?? "") : String(defaultPort(for: type ?? "", initial: p))
            return "\(p["host"].stringish ?? ""):\(port)"
        }
        return hostsOr(p["alias"], hostsOr(p["hostname"], "")).stringish ?? ""
    }

    /// sidebar.js `profileKindLabel`.
    static func kindLabel(_ p: JSON) -> String {
        ["teleport": "tsh", "serial": "serial", "telnet": "telnet", "vnc": "vnc", "rdp": "rdp"][p["type"].string ?? ""] ?? "ssh"
    }

    /// `openProfileEditor(initial)`: `initial` is a stored profile (edit) or
    /// a partial one (new). Calls `onSaved` with the stored record.
    static func openEditor(_ window: WindowModel?, initial: JSON = [:], onSaved: ((JSON) -> Void)? = nil) {
        let model = ProfileEditorModel(window: window, initial: initial)
        Modal.sheet(window, title: model.isEdit ? "Edit profile" : "New profile", width: 600) { handle in
            ProfileEditorView(model: model) { result in
                handle.close()
                guard let result else { return }
                let saved = HostsData.upsertProfile(result)
                StatusBus.shared.show("Saved profile “\(saved["name"].stringish ?? "")”")
                onSaved?(saved)
            }
        }
        model.loadPorts()
    }
}

@MainActor
final class ProfileEditorModel: ObservableObject {
    weak var window: WindowModel?
    let initial: JSON
    var isEdit: Bool { initial["id"].truthy }

    @Published var name: String
    @Published var type: String { didSet { if type != oldValue { syncType() } } }
    // ssh
    @Published var alias: String
    @Published var user: String
    @Published var jump: String
    @Published var hostname: String
    @Published var port: String
    // teleport
    @Published var clusterKey: String
    @Published var node: String
    @Published var login: String
    // serial
    @Published var devPath: String
    @Published var portPick = "" { didSet { if !portPick.isEmpty { devPath = portPick } } }
    @Published var ports: [SerialPortInfo] = []
    @Published var baud: String
    @Published var dataBits: String
    @Published var parity: String
    @Published var stopBits: String
    @Published var flow: String
    // telnet / vnc / rdp
    @Published var devHost: String
    @Published var devPort: String
    var devPortAuto = true
    var lastAutoPort: String?
    @Published var newline: String { didSet { if !settingNewline { newlineAuto = false } } }
    var newlineAuto = true
    var settingNewline = false
    @Published var localEcho: Bool
    @Published var viewOnly: Bool
    @Published var scaling: String
    @Published var quality: String
    @Published var rdpUser: String
    @Published var rdpDomain: String
    @Published var rdpFull: Bool
    @Published var rdpWidth: String
    @Published var rdpHeight: String
    @Published var rdpClip: Bool
    @Published var rdpDrives: Bool
    @Published var rdpGateway: String
    // shared
    @Published var folderId: String
    @Published var startCmd: String
    @Published var remotePath: String
    @Published var localPath: String

    let clusterOptions: [(value: String, label: String)]
    let folderOptions: [(value: String, label: String)]

    init(window: WindowModel?, initial i: JSON) {
        self.window = window
        self.initial = i
        func s(_ k: String) -> String { i[k].truthy ? (i[k].stringish ?? "") : "" }
        let t = i["type"].string ?? "ssh"
        name = s("name")
        type = t
        alias = s("alias")
        user = s("user")
        jump = i["proxyJump"].truthy ? s("proxyJump") : (i["direct"]["proxyJump"].stringish ?? "")
        hostname = i["hostname"].truthy ? s("hostname") : (i["direct"]["hostname"].stringish ?? "")
        port = String(i["port"].int.flatMap { $0 != 0 ? $0 : nil } ?? i["direct"]["port"].int.flatMap { $0 != 0 ? $0 : nil } ?? 22)

        let profiles = Inventory.shared.profiles
        clusterOptions = profiles.map { p in
            (p.key, "\(p.cluster)\(p.homeName.isEmpty ? "" : " · " + p.homeName)\(p.expired ? " (expired)" : "")")
        }
        let wanted = TeleportProfile.key(cluster: i["cluster"].string, proxy: nil, home: i["home"].string)
        let fallback = profiles.first?.key ?? ""
        let pick = wanted.isEmpty ? fallback : wanted
        clusterKey = profiles.contains { $0.key == pick } ? pick : fallback
        node = s("node")
        login = s("login")

        devPath = s("path")
        baud = i["baudRate"].truthy ? s("baudRate") : "115200"
        dataBits = i["dataBits"].truthy ? s("dataBits") : "8"
        parity = i["parity"].truthy ? s("parity") : "none"
        stopBits = i["stopBits"].truthy ? s("stopBits") : "1"
        flow = i["rtscts"].truthy ? "rtscts" : (i["xon"].truthy ? "xonxoff" : "none")

        devHost = s("host")
        devPort = i["devicePort"].truthy ? s("devicePort") : String(Profiles.defaultPort(for: t, initial: i))
        newline = i["newline"].truthy ? s("newline") : (t == "telnet" ? "crlf" : "cr")
        localEcho = i["localEcho"].truthy
        viewOnly = i["viewOnly"].truthy
        scaling = i["scaling"].truthy ? s("scaling") : "scale"
        quality = i["quality"].isNull ? "6" : (i["quality"].stringish ?? "6")
        rdpUser = s("username")
        rdpDomain = s("domain")
        rdpFull = i["fullscreen"].truthy
        rdpWidth = i["width"].truthy ? s("width") : "1440"
        rdpHeight = i["height"].truthy ? s("height") : "900"
        rdpClip = i["clipboard"] != .bool(false)
        rdpDrives = i["drives"].truthy
        rdpGateway = s("gateway")

        folderOptions = [("", "Ungrouped")] + HostsData.profileFolders.map { ($0["id"].stringish ?? "", $0["name"].stringish ?? "") }
        let fid = s("folderId")
        folderId = folderOptions.contains { $0.value == fid } ? fid : ""
        startCmd = i["startupCommand"].string ?? ""
        remotePath = s("remoteStartPath")
        localPath = s("localStartPath")
        syncType()
    }

    func loadPorts() {
        Task { @MainActor in ports = await DeviceSessions.shared.listPorts() }
    }

    var portOptions: [(value: String, label: String)] {
        [("", "Ports found now…")] + ports.map { ($0.path, $0.label.isEmpty ? $0.path : "\($0.path) — \($0.label)") }
    }

    /// A port typed into stops following the protocol.
    func devPortEdited() {
        if devPort != lastAutoPort { devPortAuto = false }
    }

    /// What follows the type: a port nobody has typed into, and what Enter
    /// sends until someone says otherwise.
    func syncType() {
        if devPortAuto {
            let v = String(Profiles.defaultPort(for: type, initial: initial))
            lastAutoPort = v
            devPort = v
        }
        if newlineAuto {
            settingNewline = true
            newline = initial["newline"].truthy ? (initial["newline"].string ?? "cr") : (type == "telnet" ? "crlf" : "cr")
            settingNewline = false
        }
    }

    var clusterProfile: TeleportProfile? { Inventory.shared.profiles.first { $0.key == clusterKey } }

    var showSsh: Bool { type == "ssh" }
    var showTeleport: Bool { type == "teleport" }
    var showSerial: Bool { type == "serial" }
    var showNet: Bool { ["telnet", "vnc", "rdp"].contains(type) }
    var showLine: Bool { type == "serial" || type == "telnet" }
    var showExtras: Bool { type != "vnc" && type != "rdp" }
    var showPaths: Bool { type == "ssh" || type == "teleport" }

    /// Validate and build the record, or toast why not.
    func result() -> JSON? {
        let t = type
        func trimmedOrNull(_ s: String) -> JSON { s.trimmed.isEmpty ? .null : .string(s.trimmed) }
        func int(_ s: String) -> JSON { QuickConnect.parseInt(s).map { JSON($0) } ?? .null }
        if name.trimmed.isEmpty { HToast.error("Name is required"); return nil }
        // An alias or a hostname: one of the two has to say where to connect.
        if t == "ssh" && alias.trimmed.isEmpty && hostname.trimmed.isEmpty {
            HToast.error("Give an ssh_config alias, or a hostname to dial directly"); return nil
        }
        if t == "teleport" && node.trimmed.isEmpty { HToast.error("Node hostname is required"); return nil }
        if t == "serial" && devPath.trimmed.isEmpty { HToast.error("Name the serial port"); return nil }
        if ["telnet", "vnc", "rdp"].contains(t) && devHost.trimmed.isEmpty { HToast.error("Host is required"); return nil }

        let sshPort = QuickConnect.parseInt(port).flatMap { $0 != 0 ? $0 : nil } ?? 22
        let net = ["telnet", "vnc", "rdp"].contains(t)
        let line = ["serial", "telnet"].contains(t)
        let cp = clusterProfile
        var r: JSON = [:]
        r["id"] = initial["id"].truthy ? initial["id"] : .null
        if r["id"].isNull { r.removeKey("id") }
        r["name"] = .string(name.trimmed)
        r["type"] = .string(t)
        r["folderId"] = folderId.isEmpty ? .null : .string(folderId)
        r["alias"] = trimmedOrNull(alias)
        r["user"] = trimmedOrNull(user)
        r["hostname"] = t == "ssh" ? trimmedOrNull(hostname) : .null
        r["port"] = t == "ssh" ? JSON(sshPort) : .null
        r["proxyJump"] = t == "ssh" ? trimmedOrNull(jump) : .null
        // A profile with a hostname of its own needs no ssh_config entry, so
        // it carries what a connection needs; one with only an alias lets
        // ssh_config answer (the jump host goes as -J either way).
        r["direct"] = t == "ssh" && !hostname.trimmed.isEmpty ? [
            "hostname": .string(hostname.trimmed),
            "user": trimmedOrNull(user),
            "port": JSON(sshPort),
            "identityFile": hostsOr(initial["direct"]["identityFile"], .null),
            "proxyJump": trimmedOrNull(jump),
            "extraOptions": hostsOr(initial["direct"]["extraOptions"], ""),
        ] : .null
        r["cluster"] = t == "teleport" ? JSON(cp?.cluster.nilIfEmpty) : .null
        r["proxy"] = t == "teleport" ? JSON(cp?.proxy.nilIfEmpty) : .null
        r["home"] = t == "teleport" ? JSON(cp?.home) : .null
        r["node"] = trimmedOrNull(node)
        r["login"] = trimmedOrNull(login)
        r["startupCommand"] = .string(startCmd)
        r["remoteStartPath"] = .string(remotePath.trimmed)
        r["localStartPath"] = .string(localPath.trimmed)

        r["path"] = t == "serial" ? .string(devPath.trimmed) : .null
        r["baudRate"] = t == "serial" ? int(baud) : .null
        r["dataBits"] = t == "serial" ? int(dataBits) : .null
        r["parity"] = t == "serial" ? .string(parity) : .null
        r["stopBits"] = t == "serial" ? int(stopBits) : .null
        r["rtscts"] = t == "serial" ? .bool(flow == "rtscts") : .null
        r["xon"] = t == "serial" ? .bool(flow == "xonxoff") : .null
        r["xoff"] = t == "serial" ? .bool(flow == "xonxoff") : .null

        r["host"] = net ? .string(devHost.trimmed) : .null
        r["devicePort"] = net ? JSON(QuickConnect.parseInt(devPort).flatMap { $0 != 0 ? $0 : nil }
                                     ?? Profiles.defaultPort(for: t)) : .null
        r["newline"] = line ? .string(newline) : .null
        r["localEcho"] = line ? .bool(localEcho) : .null

        r["viewOnly"] = t == "vnc" ? .bool(viewOnly) : .null
        r["scaling"] = t == "vnc" ? .string(scaling) : .null
        r["quality"] = t == "vnc" ? int(quality) : .null

        r["username"] = t == "rdp" ? trimmedOrNull(rdpUser) : .null
        r["domain"] = t == "rdp" ? trimmedOrNull(rdpDomain) : .null
        r["fullscreen"] = t == "rdp" ? .bool(rdpFull) : .null
        r["width"] = t == "rdp" ? int(rdpWidth) : .null
        r["height"] = t == "rdp" ? int(rdpHeight) : .null
        r["clipboard"] = t == "rdp" ? .bool(rdpClip) : .null
        r["drives"] = t == "rdp" ? .bool(rdpDrives) : .null
        r["gateway"] = t == "rdp" ? trimmedOrNull(rdpGateway) : .null
        return r
    }
}

private struct ProfileEditorView: View {
    @ObservedObject var model: ProfileEditorModel
    let done: (JSON?) -> Void

    var body: some View {
        DialogScaffold(title: model.isEdit ? "Edit profile" : "New profile", width: 600) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Name") { HField(placeholder: "My server", text: $model.name) }
                MiscField(label: "Type") {
                    HSelect(options: [
                        ("ssh", "SSH (ssh_config host)"), ("teleport", "Teleport node"), ("serial", "Serial console"),
                        ("telnet", "Telnet"), ("vnc", "VNC screen"), ("rdp", "Remote Desktop (RDP)"),
                    ], selection: $model.type)
                }
                if model.showSsh { sshBlock }
                if model.showTeleport { tpBlock }
                if model.showSerial { serialBlock }
                if model.showNet {
                    HFieldRow {
                        MiscField(label: "Host") { HField(placeholder: "10.0.0.5 or console.example.com", text: $model.devHost) }
                        MiscField(label: "Port") { HNumberField(text: $model.devPort) { model.devPortEdited() } }
                    }
                }
                if model.type == "vnc" { vncBlock }
                if model.type == "rdp" { rdpBlock }
                if model.showLine {
                    MiscField(label: "Enter sends") {
                        HSelect(options: [
                            ("cr", "CR — most network gear"), ("lf", "LF — most Unix consoles"),
                            ("crlf", "CRLF — telnet default, and some appliances"),
                        ], selection: $model.newline)
                    }
                    MiscCheck(label: "Show what I type (local echo)", isOn: $model.localEcho)
                }
                MiscField(label: "Folder") { HSelect(options: model.folderOptions, selection: $model.folderId) }
                if model.showExtras {
                    MiscRule().padding(.top, 4)
                    MiscField(label: "Startup command", hint: "Sent to the session once it is open") {
                        HTextArea(text: $model.startCmd, placeholder: "e.g. sudo -i\ntail -f /var/log/syslog", height: 58)
                    }
                    if model.showPaths {
                        HFieldRow {
                            MiscField(label: "Remote start folder") { HField(placeholder: "/var/log", text: $model.remotePath) }
                            MiscField(label: "Local start folder") { HField(placeholder: "~/Downloads", text: $model.localPath) }
                        }
                    }
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(model.isEdit ? "Save" : "Create") { if let r = model.result() { done(r) } }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .frame(maxHeight: 760)
    }

    private var sshBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "SSH host alias", hint: "Must match a Host entry in ~/.ssh/config, unless a hostname is given below") {
                HField(placeholder: "host alias from ~/.ssh/config", text: $model.alias)
            }
            HFieldRow {
                MiscField(label: "Login user (optional)") { HField(placeholder: "optional override", text: $model.user) }
                MiscField(label: "Jump host (ProxyJump, optional)") {
                    HField(placeholder: "bastion.example.com, or user@bastion:2222", text: $model.jump)
                }
            }
            HFieldRow {
                MiscField(label: "Hostname (optional)") { HField(placeholder: "optional — dial this directly", text: $model.hostname) }
                MiscField(label: "Port") { HNumberField(text: $model.port) }
            }
        }
    }

    private var tpBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "Cluster") { HSelect(options: model.clusterOptions, selection: $model.clusterKey) }
            MiscField(label: "Node hostname") { HField(placeholder: "node hostname", text: $model.node) }
            MiscField(label: "Login") { HField(placeholder: "ubuntu", text: $model.login) }
        }
    }

    private var serialBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "Serial port", hint: "The device file for the adapter — it does not have to be plugged in to save this") {
                HField(placeholder: "/dev/tty.usbserial-1410 or COM3", text: $model.devPath)
            }
            MiscField(label: "Ports on this machine now") { HSelect(options: model.portOptions, selection: $model.portPick) }
            HFieldRow {
                MiscField(label: "Speed") {
                    HSelect(options: [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600].map { (String($0), String($0)) },
                            selection: $model.baud)
                }
                MiscField(label: "Data bits") { HSelect(options: ["8", "7", "6", "5"].map { ($0, $0) }, selection: $model.dataBits) }
                MiscField(label: "Parity") {
                    HSelect(options: [("none", "None"), ("even", "Even"), ("odd", "Odd")], selection: $model.parity)
                }
                MiscField(label: "Stop bits") { HSelect(options: [("1", "1"), ("2", "2")], selection: $model.stopBits) }
            }
            MiscField(label: "Flow control", hint: "Hardware flow control on a console cable that has no CTS wire looks exactly "
                      + "like a dead port — leave it off unless the device asks for it") {
                HSelect(options: [("none", "None"), ("rtscts", "Hardware (RTS/CTS)"), ("xonxoff", "Software (XON/XOFF)")],
                        selection: $model.flow)
            }
        }
    }

    private var vncBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiscField(label: "Display") {
                HSelect(options: [("scale", "Scale the screen to fit the pane"), ("resize", "Ask the server to match the pane"),
                                  ("none", "Full size, scroll to see the rest")], selection: $model.scaling)
            }
            MiscField(label: "Picture quality") {
                HSelect(options: ["9", "8", "6", "4", "2", "0"].map { v in
                    (v, v + (v == "9" ? " — best picture" : v == "0" ? " — smallest" : ""))
                }, selection: $model.quality)
            }
            MiscCheck(label: "View only — watch without touching anything", isOn: $model.viewOnly)
            MiscHint(text: "The password is asked for when you connect and is not saved here \u{2014} "
                     + "ServerLife keeps its settings in a plain file, and a VNC password in one "
                     + "is a VNC password in every backup of it.").padding(.top, 8).padding(.bottom, 10)
        }
    }

    private var rdpBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HFieldRow {
                MiscField(label: "User") { HField(placeholder: "Administrator", text: $model.rdpUser) }
                MiscField(label: "Domain") { HField(placeholder: "CORP (optional)", text: $model.rdpDomain) }
            }
            MiscCheck(label: "Open full screen", isOn: $model.rdpFull)
            HFieldRow {
                MiscField(label: "Width") { HNumberField(text: $model.rdpWidth) }
                MiscField(label: "Height") { HNumberField(text: $model.rdpHeight) }
            }
            MiscCheck(label: "Share the clipboard", isOn: $model.rdpClip)
            MiscCheck(label: "Share my home folder as a drive", isOn: $model.rdpDrives)
            MiscField(label: "RD Gateway") { HField(placeholder: "rdgateway.example.com (optional)", text: $model.rdpGateway) }
            MiscHint(text: "Opens in this machine\u{2019}s own Remote Desktop client with these settings. "
                     + "RDP is not drawn inside ServerLife: it is a bundle of virtual channels \u{2014} "
                     + "drives, printers, smart cards, audio \u{2014} and half an implementation of it "
                     + "would be worse than the client the platform already has.").padding(.top, 8).padding(.bottom, 10)
        }
    }
}
