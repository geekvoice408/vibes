import AppKit
import SwiftUI

/// SSH key management (keys.js): what keys exist, what the agent holds,
/// generating a new pair, and installing a public key on a host — the
/// `ssh-copy-id` step, done over the connection that is already open.
@MainActor
final class KeysModel: ObservableObject {
    @Published var loading = true
    @Published var keys: [SSHKey] = []
    @Published var agent = AgentState()
    @Published var error: String?
    @Published var sessions: [NTConnInfo] = []
    @Published var identities: [(alias: String, identityFile: String)] = []
    weak var window: WindowModel?

    init(window: WindowModel?) { self.window = window }

    func load() {
        loading = true
        sessions = NTConnections.connected
        // Which ssh_config hosts name a key with IdentityFile.
        identities = Inventory.shared.sshHosts.compactMap { h in
            h.identityFile.map { (alias: h.alias ?? h.name, identityFile: $0) }
        }
        Task { @MainActor in
            async let k = SSHKeys.listKeys()
            async let a = SSHKeys.agentKeys()
            let (kk, aa) = await (k, a)
            keys = kk
            agent = aa
            loading = false
        }
    }

    /// Plain `ssh-add` — load the default identities. Useful precisely when
    /// our own probe of the agent has failed, so it stays available then.
    func addDefaults() {
        StatusBus.shared.show("Running ssh-add…", seconds: 0)
        Task { @MainActor in
            let r = await SSHKeys.addToAgent(nil)
            StatusBus.shared.clear()
            if r.ok { StatusBus.shared.toast(r.output.ntTrimmed.isEmpty ? "Default keys added to ssh-agent" : r.output.ntTrimmed, kind: .ok, seconds: 6) }
            else { StatusBus.shared.toast(r.output.isEmpty ? "ssh-add failed" : r.output, kind: .error, seconds: 9) }
            load()
        }
    }

    func addToAgent(_ k: SSHKey) {
        guard let path = k.privatePath else { return }
        Task { @MainActor in
            // Ask for the passphrase up front: ssh-add cannot prompt usefully
            // from a GUI app. Fall back to the subprocess only when the key's
            // own header was inconclusive.
            let encrypted: Bool
            if let e = k.encrypted { encrypted = e } else { encrypted = await SSHKeys.isEncrypted(path) }
            var passphrase: String? = nil
            if encrypted {
                guard let p = await Modal.prompt(window, title: "Key passphrase",
                                                 message: "Passphrase for \(k.name)\nUsed once to add the key to your agent; it is not stored.",
                                                 placeholder: "Passphrase", ok: "Add", secure: true) else { return }
                passphrase = p
            }
            StatusBus.shared.show("Adding to agent…", seconds: 0)
            let r = await SSHKeys.addToAgent(path, passphrase: passphrase)
            StatusBus.shared.clear()
            if r.ok { StatusBus.shared.toast("Added to ssh-agent", kind: .ok) }
            else { StatusBus.shared.toast(r.output.isEmpty ? "ssh-add failed" : r.output, kind: .error) }
            load()
        }
    }

    func usedBy(_ k: SSHKey) -> [String] {
        identities.filter { SSHKeys.sameKeyPath($0.identityFile, k) }.map(\.alias)
    }
}

@MainActor
enum KeysDialog {
    static func open(_ window: WindowModel?) {
        let model = KeysModel(window: window)
        Modal.sheet(window, title: "SSH keys", width: 700, height: 600, resizable: true, autosave: "keys") { handle in
            KeysView(model: model, handle: handle)
        }
        model.load()
    }

    /// Install a public key on one of the connected sessions.
    static func installFlow(_ key: SSHKey, _ sessions: [NTConnInfo], window: WindowModel?) {
        guard let first = sessions.first else { return }
        let choice = Local(first.id)
        Modal.sheet(window, title: "Install public key", width: 480) { handle in
            InstallKeyView(key: key, sessions: sessions, choice: choice) { id in
                handle.close()
                guard let id else { return }
                Task { @MainActor in
                    StatusBus.shared.show("Installing key…", seconds: 0)
                    do {
                        let r = try await SSHKeys.install(connId: id, publicKey: key.publicKey)
                        StatusBus.shared.toast(r.alreadyPresent ? "Key was already installed" : "Key installed", kind: .ok)
                    } catch {
                        StatusBus.shared.toast(error.localizedDescription, kind: .error)
                    }
                    StatusBus.shared.clear()
                }
            }
        }
    }

    static func generateFlow(window: WindowModel?, then: @escaping @MainActor () -> Void) {
        Modal.sheet(window, title: "Generate SSH key", width: 480) { handle in
            GenerateKeyView { res in
                handle.close()
                guard let res else { return }
                Task { @MainActor in
                    StatusBus.shared.show("Generating…", seconds: 0)
                    do {
                        let k = try await SSHKeys.generate(name: res.name, type: res.type, comment: res.comment, passphrase: res.passphrase)
                        StatusBus.shared.toast("Created \(k.name) (\(k.type ?? res.type))", kind: .ok)
                    } catch {
                        StatusBus.shared.toast(error.localizedDescription, kind: .error)
                    }
                    StatusBus.shared.clear()
                    then()
                }
            }
        }
    }

    /// Clear a stale host key after a server is rebuilt.
    static func forgetHostKey(_ hostname: String?, window: WindowModel?) {
        Task { @MainActor in
            var name = hostname?.ntTrimmed ?? ""
            if name.isEmpty {
                guard let n = await Modal.prompt(window, title: "Forget host key", message: "Hostname as it appears in known_hosts",
                                                 ok: "Look up"), !n.ntTrimmed.isEmpty else { return }
                name = n.ntTrimmed
            }
            let entries = await SSHKeys.knownHostEntries(name)
            if entries.isEmpty { StatusBus.shared.toast("No known_hosts entry for \(name)", kind: .info); return }
            let ok = await Modal.confirm(window, title: "Forget host key",
                message: "Remove \(entries.count) known_hosts entr\(entries.count == 1 ? "y" : "ies") for \(name)?\n\n"
                    + entries.map { "\($0.type) \($0.key)" }.joined(separator: "\n")
                    + "\n\nThe next connection will ask you to accept the new key. Only do this if you "
                    + "expected the host to change — a rebuild, a re-image, a new IP.",
                ok: "Forget", destructive: true)
            guard ok else { return }
            do {
                let n = try await SSHKeys.forgetHost(name)
                StatusBus.shared.toast("Removed \(n) entr\(n == 1 ? "y" : "ies")", kind: .ok)
            } catch {
                StatusBus.shared.toast(error.localizedDescription, kind: .error)
            }
        }
    }
}

// MARK: - Views

struct KeysView: View {
    @ObservedObject var model: KeysModel
    let handle: ModalHandle

    var body: some View {
        DialogScaffold(title: "SSH keys", subtitle: "~/.ssh") {
            content
        } footer: {
            Button("Run ssh-add") { model.addDefaults() }.buttonStyle(.ghost)
            Button("Generate new key…") { KeysDialog.generateFlow(window: model.window) { model.load() } }.buttonStyle(.ghost)
            Button("Refresh") { model.load() }.buttonStyle(.ghost)
            Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        let p = Theme.shared.p
        if model.loading && model.keys.isEmpty {
            NTEmpty(text: "Reading ~/.ssh…")
        } else if let e = model.error {
            NTEmpty(text: e, color: p.red)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                agentRow
                let (agentOnly, extraCount) = SSHKeys.agentOnly(model.agent.keys, local: model.keys)
                if model.keys.isEmpty && agentOnly.isEmpty {
                    NTEmpty(text: "No keypairs found in ~/.ssh.")
                } else {
                    if model.keys.isEmpty {
                        NTEmpty(text: "No keypairs in ~/.ssh — the agent\u{2019}s own identities are below.").padding(.vertical, -8)
                    }
                    ForEach(model.keys) { k in keyCard(k) }
                    if !agentOnly.isEmpty {
                        p.borderSoft.frame(height: 1).padding(.top, 16)
                        Text((extraCount == agentOnly.count
                              ? "In the agent only — \(agentOnly.count)"
                              : "In the agent only — \(agentOnly.count) identities, \(extraCount) entries").uppercased())
                            .font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(p.muted)
                            .padding(.top, 12).padding(.bottom, 9)
                        Text("Loaded in ssh-agent with no keypair in ~/.ssh — from the login keychain, a "
                             + "hardware token, another agent, or a Teleport certificate. They will be offered "
                             + "to servers, but there is no file here to manage.")
                            .font(.system(size: 11.5)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 10)
                        ForEach(Array(agentOnly.enumerated()), id: \.offset) { _, a in agentCard(a) }
                    }
                }
            }
        }
    }

    /// Three states, not two: running, not answering, and no ssh-add to ask
    /// with — only the middle one is worth retrying.
    private var agentRow: some View {
        let p = Theme.shared.p
        let agent = model.agent
        let agentFps = Set(agent.keys.map(\.fingerprint))
        let fromDisk = model.keys.filter { $0.fingerprint.map { agentFps.contains($0) } ?? false }.count
        let elsewhere = agent.keys.count - fromDisk
        let text = agent.missing ? "ssh-add not found — key management needs an OpenSSH client"
            : agent.running
                ? "ssh-agent running — \(agent.keys.count) key\(agent.keys.count == 1 ? "" : "s") loaded"
                    + (elsewhere > 0 ? ", \(fromDisk) from ~/.ssh and \(elsewhere) from elsewhere" : "")
                : "ssh-agent not reachable"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(agent.missing ? p.red : agent.running ? p.green : p.amber).frame(width: 8, height: 8)
                Text(text).font(.system(size: 12))
                if !agent.missing && !agent.running {
                    Button("Try ssh-add") { model.addDefaults() }.buttonStyle(.ghostSmall)
                        .help("Run ssh-add for the default identities and report what it says")
                }
            }
            if agent.missing {
                Text("Keys are still listed from ~/.ssh, but they cannot be added to the agent from here.")
                    .font(.system(size: 11)).foregroundStyle(p.textDim)
            } else if !agent.running, let e = agent.error, !e.isEmpty {
                Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textDim).textSelection(.enabled)
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
        .padding(.bottom, 14)
    }

    private func keyCard(_ k: SSHKey) -> some View {
        let p = Theme.shared.p
        let inAgent = k.fingerprint.map { fp in model.agent.keys.contains { $0.fingerprint == fp } } ?? false
        let usedBy = model.usedBy(k)
        return KeyCard {
            NTFlow(spacing: 9) {
                Text(k.name).font(.system(size: 13, weight: .semibold))
                if let t = k.type { KeyTag(text: t) }
                if let b = k.bits { KeyTag(text: "\(b) bit") }
                if k.encrypted == true { KeyTag(text: "passphrase") }
                if k.encrypted == false { KeyTag(text: "no passphrase") }
                if inAgent { KeyState(text: "IN AGENT", color: p.green) }
                if !k.permissionsOk { KeyState(text: "PERMISSIONS", color: p.red) }
            }
        } meta: {
            if let fp = k.fingerprint { Text(fp) }
            if let c = k.comment { Text(c) }
            Text(k.privatePath ?? k.publicPath).opacity(0.75)
            if let m = k.mtime { Text("modified " + Fmt.date(ms: m)).opacity(0.75) }
            if !usedBy.isEmpty {
                Text("used by \(usedBy.count) ssh_config host\(usedBy.count == 1 ? "" : "s"): \(usedBy.prefix(6).joined(separator: ", "))\(usedBy.count > 6 ? "…" : "")")
            }
            if !k.hasPrivate { Text("public key only — no private key alongside it").foregroundStyle(p.amber) }
            if !k.permissionsOk, let mode = k.privMode {
                Text("private key is \(String(mode, radix: 8)) — sshd ignores anything looser than 600").foregroundStyle(p.red)
            }
        } actions: {
            Button("Copy public key") { Clipboard.write(k.publicKey); StatusBus.shared.show("Public key copied") }.buttonStyle(.ghost)
            // Install on any connected session: ssh-copy-id without the extra authentication.
            if !model.sessions.isEmpty {
                Button("Install on server…") { KeysDialog.installFlow(k, model.sessions, window: model.window) }.buttonStyle(.primary)
            }
            if k.hasPrivate && !inAgent && !model.agent.missing {
                Button("Add to agent") { model.addToAgent(k) }.buttonStyle(.ghost)
            }
        }
    }

    private func agentCard(_ a: SSHKeys.AgentOnly) -> some View {
        let p = Theme.shared.p
        let tp = SSHKeys.teleportIdentity(a.key.comment)
        let types = a.types.isEmpty ? [a.key.type].compactMap { $0 } : a.types
        return KeyCard {
            NTFlow(spacing: 9) {
                Text(tp.map { "\($0.user) @ \($0.cluster)" } ?? (a.key.comment.flatMap { $0.isEmpty ? nil : $0 } ?? "unnamed identity"))
                    .font(.system(size: 13, weight: .semibold))
                if tp != nil { KeyTag(text: "teleport") }
                ForEach(types, id: \.self) { KeyTag(text: $0) }
                if let b = a.key.bits { KeyTag(text: "\(b) bit") }
                KeyState(text: "IN AGENT", color: p.green)
            }
        } meta: {
            if let tp, tp.proxy != tp.cluster { Text("proxy " + tp.proxy) }
            if tp != nil { Text("short-lived certificate from tsh login").opacity(0.75) }
            if a.entries > 1 {
                Text("\(a.entries) agent entries share this fingerprint — the certificate and the key it signs").opacity(0.75)
            }
            Text(a.key.fingerprint)
        } actions: {
            Button("Copy fingerprint") { Clipboard.write(a.key.fingerprint); StatusBus.shared.show("Fingerprint copied") }.buttonStyle(.ghost)
        }
    }
}

/// `.req-card`.
struct KeyCard<Head: View, Meta: View, Actions: View>: View {
    @ViewBuilder var head: () -> Head
    @ViewBuilder var meta: () -> Meta
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            head().padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 2) { meta() }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted).textSelection(.enabled)
            HStack(spacing: 7) { actions() }.padding(.top, 9)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.borderSoft))
        .padding(.bottom, 9)
    }
}

struct KeyTag: View {
    let text: String
    var body: some View { Badge(text: text) }
}

/// `.req-state`.
struct KeyState: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).kerning(0.4)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

struct InstallKeyView: View {
    let key: SSHKey
    let sessions: [NTConnInfo]
    @ObservedObject var choice: Local<String>
    let done: (String?) -> Void
    var body: some View {
        DialogScaffold(title: "Install public key", subtitle: key.name, scroll: false) {
            VStack(alignment: .leading, spacing: 12) {
                FormRow(label: "Target session") {
                    Picker("", selection: $choice.value) {
                        ForEach(sessions) { Text($0.label).tag($0.id) }
                    }.labelsHidden().fixedSize()
                }
                NTHint(text: "Appends the key to ~/.ssh/authorized_keys on that server if it is not already there, "
                       + "and fixes the directory permissions sshd requires.")
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Install") { done(choice.value) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

struct GenerateKeyView: View {
    struct Result { var name, type, comment, passphrase: String }
    let done: (Result?) -> Void
    @StateObject private var name = Local("id_serverlife")
    @StateObject private var type = Local("ed25519")
    @StateObject private var comment = Local("")
    @StateObject private var pass = Local("")

    var body: some View {
        DialogScaffold(title: "Generate SSH key", scroll: false) {
            VStack(alignment: .leading, spacing: 12) {
                FormRow(label: "File name", hint: "Created in ~/.ssh") {
                    TextField("id_ed25519", text: $name.value).textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Type") {
                    Picker("", selection: $type.value) {
                        Text("Ed25519 (recommended)").tag("ed25519")
                        Text("ECDSA").tag("ecdsa")
                        Text("RSA 4096").tag("rsa")
                    }.labelsHidden().fixedSize()
                }
                FormRow(label: "Comment") {
                    TextField("optional comment", text: $comment.value).textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Passphrase", hint: "An empty passphrase means anyone with the file can use the key.") {
                    SecureField("optional but recommended", text: $pass.value).textFieldStyle(.roundedBorder)
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Generate") {
                let n = name.value.ntTrimmed
                if n.isEmpty { StatusBus.shared.toast("Give the key a file name", kind: .error); return }
                done(Result(name: n, type: type.value, comment: comment.value.ntTrimmed, passphrase: pass.value))
            }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
