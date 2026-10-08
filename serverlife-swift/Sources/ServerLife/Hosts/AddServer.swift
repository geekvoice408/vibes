import AppKit
import SwiftUI

/// addserver.js (⌘⇧N): defining a new server, written either to the
/// managed block of ~/.ssh/config or kept in the app only — the dialog says
/// which is which rather than picking for you.
@MainActor
enum AddServer {
    struct Initial {
        var name = ""
        var hostname = ""
        var user = ""
        var port = 22
        var identityFile = ""
        var proxyJump = ""
        var extraOptions = ""
        var destination = "config"
    }

    struct Result {
        var alias: String
        var hostname: String
        var user: String
        var port: Int
        var identityFile: String
        var proxyJump: String
        var extraOptions: String
        var destination: String
        var saveProfile: Bool

        var direct: DirectSpec {
            DirectSpec(hostname: hostname, user: user.nilIfEmpty, port: port, identityFile: identityFile.nilIfEmpty,
                       proxyJump: proxyJump.nilIfEmpty, extraOptions: extraOptions)
        }
    }

    static func openDialog(_ window: WindowModel?, initial: Initial = Initial()) {
        let model = AddServerModel(window: window, initial: initial)
        Modal.sheet(window, title: "Add a server", width: 660) { handle in
            AddServerView(model: model) { res in
                handle.close()
                if let res { Task { @MainActor in await commit(res, window: window) } }
            }
        }
    }

    /// What happens after "Add server".
    static func commit(_ res: Result, window: WindowModel?) async {
        if res.destination == "config" {
            var entry = ManagedSSHHost(alias: res.alias, hostname: res.hostname, user: res.user.nilIfEmpty, port: res.port,
                                       identityFile: res.identityFile.nilIfEmpty, proxyJump: res.proxyJump.nilIfEmpty,
                                       extraOptions: res.extraOptions)
            do {
                do {
                    _ = try SSHConfig.addHost(entry)
                } catch {
                    let msg = hostsErrorText(error)
                    // The one refusal worth offering to override.
                    guard msg.contains("already defines") else { throw error }
                    let ok = await MiscUI.confirm(window, title: "Alias already in use", message: msg,
                                                  detail: "Adding it anyway means two Host blocks with the same name; ssh uses the first it finds, which may not be this one.",
                                                  confirmLabel: "Add anyway", danger: true)
                    if !ok { return }
                    entry.force = true
                    _ = try SSHConfig.addHost(entry)
                }
            } catch {
                HToast.error(hostsErrorText(error))
                return
            }
            StatusBus.shared.show("Added \(res.alias) to ~/.ssh/config")
            HToast.ok("\(res.alias) added to ~/.ssh/config")
        } else {
            StatusBus.shared.show("Saved \(res.alias)")
        }

        if res.saveProfile || res.destination == "app" {
            HostsData.upsertProfile([
                "name": .string(res.alias),
                "type": "ssh",
                "alias": res.destination == "config" ? .string(res.alias) : .null,
                "hostname": .string(res.hostname),
                "user": JSON(res.user.nilIfEmpty),
                "port": JSON(res.port),
                "identityFile": JSON(res.identityFile.nilIfEmpty),
                // App-only hosts carry everything needed to dial them.
                "direct": res.destination == "app" ? [
                    "hostname": .string(res.hostname),
                    "user": JSON(res.user.nilIfEmpty),
                    "port": JSON(res.port),
                    "identityFile": JSON(res.identityFile.nilIfEmpty),
                    "proxyJump": JSON(res.proxyJump.nilIfEmpty),
                    "extraOptions": .string(res.extraOptions),
                ] : .null,
            ])
        }
        await Inventory.shared.refresh()
    }

    /// Dial the host once and report what happened, before committing to it.
    static func testConnection(_ h: Result) async {
        StatusBus.shared.show("Testing \(h.alias)…", seconds: 0)
        var connId: String?
        do {
            var host = Host(type: Host.ssh, id: "ssh:" + h.alias, name: h.alias)
            host.alias = h.alias
            host.direct = h.direct
            let c = try await ConnectionManager.shared.create(host: host, options: ConnectOptions(login: h.user.nilIfEmpty))
            connId = c.id
            try await ConnectionManager.shared.connect(c.id)
            let who = try await ConnectionManager.shared.exec(c.id, "id -un; hostname; uname -sr").stdout
            let parts = who.trimmed.components(separatedBy: "\n")
            func at(_ i: Int) -> String { i < parts.count ? parts[i] : "undefined" }
            HToast.ok("Connected — \(at(0))@\(at(1)) (\(at(2)))", seconds: 7)
        } catch {
            HToast.error("Could not connect: " + hostsErrorText(error), seconds: 9)
        }
        StatusBus.shared.clear()
        if let connId { ConnectionManager.shared.disconnect(connId) }
    }

    /// `removeManagedHost`: take a host this app added out of ~/.ssh/config.
    static func removeManagedHost(_ alias: String, window: WindowModel?) async {
        let ok = await MiscUI.confirm(window, title: "Remove from ~/.ssh/config", message: "Delete the “\(alias)” entry?",
                                      detail: "Only entries inside the ServerLife block are touched.",
                                      confirmLabel: "Remove", danger: true)
        if !ok { return }
        do {
            if !(try SSHConfig.removeHost(alias)) { return HToast.info("That host was not added by ServerLife") }
            StatusBus.shared.show("Removed \(alias) from ~/.ssh/config")
            await Inventory.shared.refresh()
        } catch {
            HToast.error(hostsErrorText(error))
        }
    }
}

@MainActor
final class AddServerModel: ObservableObject {
    weak var window: WindowModel?
    @Published var name: String
    @Published var hostname: String
    @Published var user: String
    @Published var port: String
    @Published var jump: String
    @Published var key: String
    @Published var extra: String
    @Published var destination: String
    @Published var saveProfile = true
    @Published var testing = false

    init(window: WindowModel?, initial: AddServer.Initial) {
        self.window = window
        name = initial.name
        hostname = initial.hostname
        user = initial.user
        port = String(initial.port)
        jump = initial.proxyJump
        key = initial.identityFile
        extra = initial.extraOptions
        destination = initial.destination
    }

    var note: String {
        destination == "config"
            ? "Added inside a marked ServerLife block. Your own entries are never reformatted, and a backup is taken first."
            : "Connection details are passed to ssh directly. Nothing else on this machine will know about this host."
    }

    func collect() -> AddServer.Result? {
        let alias = name.trimmed
        let host = hostname.trimmed
        if alias.isEmpty { HToast.error("Give the server a name"); return nil }
        if alias.contains(where: { $0.isWhitespace }) { HToast.error("The name cannot contain spaces"); return nil }
        if host.isEmpty { HToast.error("Hostname or IP is required"); return nil }
        let p = QuickConnect.parseInt(port) ?? 0
        return AddServer.Result(alias: alias, hostname: host, user: user.trimmed, port: p != 0 ? p : 22,
                                identityFile: key.trimmed, proxyJump: jump.trimmed, extraOptions: extra,
                                destination: destination, saveProfile: saveProfile)
    }

    func test() {
        guard let h = collect(), !testing else { return }
        testing = true
        Task { @MainActor in
            await AddServer.testConnection(h)
            testing = false
        }
    }

    func browse() {
        Task { @MainActor in if let p = await SSHConfig.pickKey(window: window) { key = p } }
    }
}

private struct AddServerView: View {
    @ObservedObject var model: AddServerModel
    let done: (AddServer.Result?) -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        DialogScaffold(title: "Add a server", width: 660) {
            VStack(alignment: .leading, spacing: 0) {
                HFieldRow {
                    MiscField(label: "Name / alias", hint: "How you will refer to it") {
                        HField(placeholder: "web-1", text: $model.name).focused($nameFocused)
                    }
                    MiscField(label: "Hostname or IP") {
                        HField(placeholder: "web-1.example.com or 10.0.0.5", text: $model.hostname)
                    }
                }
                HFieldRow {
                    MiscField(label: "User") { HField(placeholder: NSUserName().isEmpty ? "ubuntu" : NSUserName(), text: $model.user) }
                    MiscField(label: "Port") { HNumberField(text: $model.port) }
                }
                MiscField(label: "Private key", hint: "Optional — otherwise your agent and defaults are used") {
                    HStack(spacing: 6) {
                        HField(placeholder: "~/.ssh/id_ed25519 (optional)", text: $model.key)
                        Button("Browse…") { model.browse() }.buttonStyle(.ghostSmall)
                    }
                }
                MiscField(label: "Jump host (ProxyJump)", hint: "Optional — reach this host through a bastion") {
                    HField(placeholder: "bastion.example.com (optional)", text: $model.jump)
                }
                MiscField(label: "Extra ssh options", hint: "One per line, as they appear in ssh_config") {
                    HTextArea(text: $model.extra, placeholder: "ServerAliveInterval 30\nForwardAgent yes")
                }
                MiscRule()
                MiscField(label: "Where to save it") {
                    HSelect(options: [
                        ("config", "Write to ~/.ssh/config — usable by ssh, scp and everything else"),
                        ("app", "Save in ServerLife only — leaves ~/.ssh/config untouched"),
                    ], selection: $model.destination)
                }
                MiscHint(text: model.note)
                MiscCheck(label: "Also save as a profile in the Saved tab", isOn: $model.saveProfile).padding(.top, 10)
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Test connection") { model.test() }.buttonStyle(.ghost).disabled(model.testing)
            Button("Add server") { if let r = model.collect() { done(r) } }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .onAppear { after(0.05) { nameFocused = true } }
    }
}
