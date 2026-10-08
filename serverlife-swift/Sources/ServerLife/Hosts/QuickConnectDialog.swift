import AppKit
import SwiftUI

// The dialog half of quickconnect.js (⌘⌥C): one server, a console or a
// screen, typed in, nothing saved — with Test connect, a single command,
// Connect, the recent addresses, and Save as server….

/// Per-window memory of the last single command (quickconnect.js
/// `lastCommand`: kept for the life of the window, never persisted).
@MainActor
final class HostsWindowState: WindowFeature {
    var lastCommand = ""
    init(window: WindowModel) {}
}

extension QuickConnect {
    /// Open a session on a parsed target, remembering the address. A single
    /// command runs at the prompt of the session rather than instead of it.
    @MainActor
    static func connect(_ t: QuickTarget, window: WindowModel?) async {
        rememberTarget(targetLabel(t))
        do {
            switch t.kind {
            case "serial":
                try await HostsOpen.openDevice(Host.serial, ["kind": "serial", "path": JSON(t.path),
                                                             "baudRate": JSON(t.baudRate), "name": JSON(t.path)], window: window)
            case "telnet":
                try await HostsOpen.openDevice(Host.telnet, ["kind": "telnet", "host": .string(t.hostname),
                                                             "port": JSON(t.port), "name": .string(targetLabel(t)),
                                                             "newline": "crlf"], window: window)
            case "vnc":
                HostsOpen.openVnc(["name": .string(targetLabel(t)), "host": .string(t.hostname), "port": JSON(t.port),
                                   "scaling": "scale"], window: window)
            case "rdp":
                await HostsOpen.launchRdp(["name": .string(t.hostname), "hostname": .string(t.hostname),
                                           "port": JSON(t.port), "username": JSON(t.user.nilIfEmpty)], label: t.hostname)
            default:
                HostsOpen.openHost(quickHost(t), window: window, login: t.user.nilIfEmpty,
                                   startupCommand: t.command.nilIfEmpty)
            }
        } catch {
            HToast.error(hostsErrorText(error))
        }
    }

    /// `openQuickConnectDialog(initial)`. `initial` may carry `target`,
    /// `identityFile`, `proxyJump`, `command`.
    @MainActor
    static func openDialog(_ window: WindowModel?, initial: [String: String] = [:]) {
        let model = QuickConnectModel(window: window, initial: initial)
        let handle = Modal.sheet(window, title: "Quick connect", width: 700) { handle in
            QuickConnectView(model: model, close: { handle.close() })
        }
        model.closeDialog = { handle.close() }
    }
}

@MainActor
final class QuickConnectModel: ObservableObject {
    weak var window: WindowModel?
    var closeDialog: () -> Void = {}

    @Published var target: String { didSet { if target != oldValue { syncKind() } } }
    @Published var key: String
    @Published var jump: String
    @Published var cmd: String
    @Published var recent: [String]
    @Published var output = "Test connect and command output appear here."
    @Published var outputIsError = false
    @Published var meta = ""
    @Published var kind = "ssh"
    @Published var advice: Advice = .none
    @Published var debugText: String?
    @Published var debugUsed = false
    @Published var busy = false
    var lastOutput = ""

    enum Advice { case none, tooMany, denied }
    var adviceTarget: QuickTarget?

    static let says: [String: String] = [
        "ssh": "",
        "telnet": "Opens a telnet session. The key, jump host, test and single command are ssh\u{2019}s and do not apply.",
        "vnc": "Opens a VNC screen in a pane. The password is asked for when it connects and is not saved.",
        "rdp": "Opens this machine\u{2019}s own Remote Desktop client with this address.",
        "serial": "Opens the serial console at 115200 8N1 unless a speed is given \u{2014} /dev/ttyUSB0@9600.",
    ]

    init(window: WindowModel?, initial: [String: String]) {
        self.window = window
        let recent = QuickConnect.recentTargets
        self.recent = recent
        // The field opens on ssh, whatever was used last.
        let lastSsh = recent.first { (QuickConnect.parseTarget($0)?.kind ?? "ssh") == "ssh" }
        target = initial["target"] ?? lastSsh ?? ""
        key = initial["identityFile"] ?? ""
        jump = initial["proxyJump"] ?? ""
        cmd = initial["command"] ?? window?.feature(HostsWindowState.self).lastCommand ?? ""
        syncKind()
    }

    var sshOnly: Bool { kind == "ssh" }
    var note: String { Self.says[kind] ?? "" }

    func syncKind() {
        kind = QuickConnect.parseTarget(target)?.kind ?? "ssh"
    }

    var lastCommand: String {
        get { window?.feature(HostsWindowState.self).lastCommand ?? "" }
        set { window?.feature(HostsWindowState.self).lastCommand = newValue }
    }

    /// Read the form, or complain and return nil.
    func collect() -> QuickTarget? {
        guard let t = QuickConnect.parseTarget(target) else {
            HToast.error("Enter a hostname, or user@host:port")
            return nil
        }
        // A pasted command line can carry these; typed fields win where both exist.
        let identityFile = key.trimmed.nilIfEmpty ?? t.identityFile
        let proxyJump = jump.trimmed.nilIfEmpty ?? t.proxyJump
        // Reflect back what was parsed out of a paste.
        if !t.identityFile.isEmpty && key.trimmed.isEmpty { key = t.identityFile }
        if !t.proxyJump.isEmpty && jump.trimmed.isEmpty { jump = t.proxyJump }
        if !t.command.isEmpty && cmd.trimmed.isEmpty { cmd = t.command }
        if !t.command.isEmpty || !t.identityFile.isEmpty || !t.proxyJump.isEmpty
            || QuickConnect.test(QuickConnect.re(#"^ssh\s"#, ci: true), target.trimmed) {
            target = QuickConnect.targetLabel(t)
        }
        var out = t
        out.identityFile = identityFile
        out.proxyJump = proxyJump
        out.command = cmd.trimmed
        return out
    }

    func report(_ text: String, ok: Bool) {
        output = text
        outputIsError = !ok
        if ok { hideAdvice() }
    }

    func hideAdvice() { advice = .none; debugText = nil; debugUsed = false }

    /// What went wrong, in terms of what to do about it.
    func explain(_ text: String, _ t: QuickTarget) {
        let tooMany = text.range(of: "too many authentication failures", options: .caseInsensitive) != nil
        let denied = text.range(of: "permission denied", options: .caseInsensitive) != nil
        if !tooMany && !denied { return hideAdvice() }
        debugText = nil
        debugUsed = false
        adviceTarget = t
        advice = tooMany ? .tooMany : .denied
    }

    /// Dial, run one command, hang up — a throwaway connection, never one of
    /// the app's managed sessions.
    func dialOnce(running: String, command: @escaping (QuickTarget) -> String,
                  done: @escaping (String, QuickTarget) -> Void) {
        guard let t = collect(), !busy else { return }
        busy = true
        let t0 = nowMs()
        report(running, ok: true)
        meta = ""
        Task { @MainActor in
            var connId: String?
            do {
                var h = Host(json: ["type": "ssh", "name": .string(QuickConnect.targetLabel(t))])
                h.direct = QuickConnect.quickHost(t).direct
                let c = try await ConnectionManager.shared.create(host: h, options: ConnectOptions(login: t.user.nilIfEmpty))
                connId = c.id
                try await ConnectionManager.shared.connect(c.id)
                let out = try await ConnectionManager.shared.exec(c.id, command(t)).stdout
                lastOutput = out
                done(out, t)
                meta = "\(Fmt.duration(ms: nowMs() - t0)) · \(out.utf16.count) bytes"
                QuickConnect.rememberTarget(QuickConnect.targetLabel(t))
            } catch {
                let msg = hostsErrorText(error)
                lastOutput = msg
                report(msg.isEmpty ? "Could not connect" : msg, ok: false)
                meta = "Failed after \(Fmt.duration(ms: nowMs() - t0))"
                explain(msg, t)
            }
            if let connId { ConnectionManager.shared.disconnect(connId) }
            busy = false
        }
    }

    /// Prove the address and the credentials work before anything is built on them.
    func testConnect() {
        dialOnce(running: "Connecting…", command: { _ in "id -un; hostname; uname -sr; uptime" }) { [weak self] out, _ in
            let lines = out.trimmed.components(separatedBy: "\n")
            func at(_ i: Int) -> String? { i < lines.count ? lines[i] : nil }
            self?.report([
                "Connected as  \(at(0) ?? "undefined")",
                "Host          \(at(1) ?? "undefined")",
                "Kernel        \(at(2) ?? "undefined")",
                (at(3)?.isEmpty == false) ? "Uptime        \(at(3)!.trimmed)" : "",
            ].filter { !$0.isEmpty }.joined(separator: "\n"), ok: true)
        }
    }

    /// One command, output here, no terminal.
    func runCommand() {
        if cmd.trimmed.isEmpty {
            HToast.error("Enter a command to run")
            return
        }
        lastCommand = cmd.trimmed
        dialOnce(running: "Running…", command: { $0.command }) { [weak self] out, _ in
            self?.report(out.trimmed.isEmpty ? "(no output)" : out.trimmed, ok: true)
        }
    }

    /// Open a real session tab. With a command in the box, run it at the prompt.
    func connect() {
        guard let t = collect() else { return }
        lastCommand = t.command
        closeDialog()
        let w = window
        Task { @MainActor in await QuickConnect.connect(t, window: w) }
    }

    func saveAsServer() {
        guard let t = collect() else { return }
        closeDialog()
        AddServer.openDialog(window, initial: AddServer.Initial(
            name: t.hostname.components(separatedBy: ".")[0], hostname: t.hostname, user: t.user,
            port: t.port, identityFile: t.identityFile, proxyJump: t.proxyJump))
    }

    func copyOutput() {
        if lastOutput.isEmpty { return HToast.info("Nothing to copy yet") }
        Clipboard.write(lastOutput)
        StatusBus.shared.show("Output copied")
    }

    func forget() {
        QuickConnect.clearHistory()
        recent = []
    }

    func browseKey() {
        Task { @MainActor in
            if let p = await SSHConfig.pickKey(window: window) { key = p }
        }
    }

    /// Offer the keys this machine has, then retry with one of them.
    func pickKeyAndRetry() {
        let t = adviceTarget
        Task { @MainActor in
            let keys = await SSHKeys.listKeys()
            let agent = await SSHKeys.agentKeys()
            let files = keys.filter { $0.privatePath != nil }
            let inAgent = Set(agent.keys.map(\.fingerprint).filter { !$0.isEmpty })
            let chosen: String? = await withCheckedContinuation { cont in
                var answered = false
                let finish: (String?) -> Void = { v in if !answered { answered = true; cont.resume(returning: v) } }
                let h = Modal.sheet(window, title: "Offer one key only", width: 620) { handle in
                    OneKeyView(subtitle: t.map(QuickConnect.targetLabel), held: agent.keys.count, files: files,
                               inAgent: inAgent, window: window) { v in finish(v); handle.close() }
                }
                h.onClose.append { finish(nil) }
            }
            guard let chosen else { return }
            key = chosen
            StatusBus.shared.show("Retrying with " + chosen)
            testConnect()
        }
    }

    /// The verbose attempt, laid out: what was offered, and what came back.
    func showDebug() {
        guard let t = adviceTarget else { return }
        let target = !t.user.isEmpty ? "\(t.user)@\(t.hostname)" : t.hostname
        if target.isEmpty { return }
        debugUsed = true
        debugText = "Running ssh -vv …"
        let opts = AuthProbe.Options(port: t.port, identityFile: key.trimmed.nilIfEmpty, proxyJump: jump.trimmed.nilIfEmpty)
        Task { @MainActor in
            let r = await ConnectionManager.shared.authProbe(target: target, options: opts)
            let s = r.summary
            let offered = s.offered.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let lines = [
                r.command,
                "",
                s.methods.map { "Server accepts:      \($0)" } ?? "",
                !s.offered.isEmpty ? "Keys offered (\(s.offered.count)):\n" + offered
                    : "No keys were offered at all — nothing in the agent and no identity file matched.",
                s.accepted.map { "\nAccepted:            \($0)" } ?? "",
                s.tooMany ? "\nThe server stopped after \(s.offered.count) attempt(s): MaxAuthTries reached." : "",
                s.pastLimit ? "\nsshd allows 6 attempts by default and counts every offer above, so "
                    + "anything after the sixth was never assessed. Offer one key instead." : "",
                s.missingIdentity.map { "\nThis identity file could not be read: \($0)" } ?? "",
                s.finalError.isEmpty ? "" : "\n\(s.finalError)",
            ].filter { !$0.isEmpty }
            debugText = lines.joined(separator: "\n")
            lastOutput = debugText ?? ""
        }
    }
}

private struct QuickConnectView: View {
    @ObservedObject var model: QuickConnectModel
    let close: () -> Void
    @FocusState private var focus: Field?
    enum Field { case target, key, jump, cmd }

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Quick connect", subtitle: "A server, a console or a screen — nothing saved", width: 700) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Server", hint: "user@host, host:port, a whole ssh command line pasted in — or another "
                          + "protocol: telnet://switch-1, vnc://10.0.0.5:5901, rdp://win-1, /dev/ttyUSB0") {
                    HStack(spacing: 4) {
                        TextField("ubuntu@10.0.0.5   ·   web-1.example.com:2222", text: $model.target)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .focused($focus, equals: .target)
                            .onSubmit { model.connect() }
                        if !model.recent.isEmpty {
                            // The datalist: every remembered address.
                            Menu {
                                ForEach(model.recent, id: \.self) { r in Button(r) { model.target = r } }
                            } label: { Image(systemName: "chevron.down") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                        }
                    }
                }
                if !model.note.isEmpty {
                    MiscHint(text: model.note).padding(.top, -2).padding(.bottom, 8)
                }
                if !model.recent.isEmpty {
                    recentRow.padding(.bottom, 10)
                }
                HFieldRow {
                    MiscField(label: "Private key", hint: "Optional — otherwise your agent and defaults are used") {
                        HStack(spacing: 6) {
                            HField(placeholder: "~/.ssh/id_ed25519 (optional)", text: $model.key, disabled: !model.sshOnly) { model.connect() }
                                .focused($focus, equals: .key)
                            Button("Browse…") { model.browseKey() }.buttonStyle(.ghostSmall).disabled(!model.sshOnly)
                        }
                    }
                    MiscField(label: "Jump host (ProxyJump)", hint: "Optional — reach it through a bastion") {
                        HField(placeholder: "bastion.example.com (optional)", text: $model.jump, disabled: !model.sshOnly) { model.connect() }
                            .focused($focus, equals: .jump)
                    }
                }
                MiscField(label: "Single command", hint: "With a command here, Run command answers in this window and Connect "
                          + "opens a session that starts by running it") {
                    HField(placeholder: "uptime — leave empty to open a shell", text: $model.cmd, mono: true, disabled: !model.sshOnly) {
                        // Enter on the command box runs the command; elsewhere it connects.
                        if !model.cmd.trimmed.isEmpty { model.runCommand() } else { model.connect() }
                    }
                    .focused($focus, equals: .cmd)
                }
                Text("Result").font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 5)
                ScrollView {
                    Text(model.output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(model.outputIsError ? p.red : p.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                }
                .frame(minHeight: 52, maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                if !model.meta.isEmpty {
                    Text(model.meta).font(.system(size: 11)).foregroundStyle(p.textDim).padding(.top, 6)
                }
                if model.advice != .none { adviceView.padding(.top, 10) }
            }
        } footer: {
            Button("Save as server…") { model.saveAsServer() }.buttonStyle(.ghost).disabled(!model.sshOnly)
            Button("Copy output") { model.copyOutput() }.buttonStyle(.ghost)
            Spacer()
            Button("Test connect") { model.testConnect() }.buttonStyle(.ghost).disabled(!model.sshOnly)
            Button("Run command") { model.runCommand() }.buttonStyle(.ghost).disabled(!model.sshOnly)
            Button("Connect") { model.connect() }.buttonStyle(.primary)
        }
        .onAppear { after(0.05) { focus = .target } }
    }

    private var recentRow: some View {
        let p = Theme.shared.p
        return HFlow(spacing: 5) {
            Text("Recent").font(.system(size: 11)).foregroundStyle(p.muted)
            ForEach(Array(model.recent.prefix(8)), id: \.self) { r in
                Button { model.target = r; focus = .target } label: {
                    Text(r).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(p.panel3))
                }
                .buttonStyle(.plain)
                .help(r)
            }
            Button("Forget") { model.forget() }.buttonStyle(.ghostSmall).help("Drop the remembered list")
        }
    }

    @ViewBuilder private var adviceView: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 8) {
            if model.advice == .tooMany {
                Text("The server hung up on the number of attempts, not on a bad key")
                    .font(.system(size: 12, weight: .semibold))
                Text("Your agent offers every identity it holds, one at a time, and sshd stops accepting "
                     + "attempts after MaxAuthTries — six by default. With more keys than that in the agent, "
                     + "the right one can be refused for being seventh in the queue, or never reached at all. "
                     + "Nothing here says the key is wrong.")
                    .font(.system(size: 11.5)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true)
                (Text("The fix is to name one key and offer only that. Filling in ")
                 + Text("Private key").bold()
                 + Text(" above does exactly that — it adds ")
                 + Text("-i <key> -o IdentitiesOnly=yes").font(.system(size: 11, design: .monospaced))
                 + Text(", so the agent’s other identities are never sent."))
                    .font(.system(size: 11.5)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The server refused the credentials it was offered").font(.system(size: 12, weight: .semibold))
                Text("Either the login name is not the right one for this host, or none of the keys offered "
                     + "is installed for it. The debug button below lists exactly what was offered, which is "
                     + "usually enough to tell which of the two it is.")
                    .font(.system(size: 11.5)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("Pick one key and retry…") { model.pickKeyAndRetry() }.buttonStyle(GhostButtonStyle(small: true, prominent: true))
                Button("Debug info") { model.showDebug() }.buttonStyle(.ghostSmall).disabled(model.debugUsed)
                    .help("Runs one verbose attempt and lists what was offered and what the server said")
            }
            if let d = model.debugText {
                ScrollView {
                    Text(d).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.amber.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.amber.opacity(0.4)))
    }
}

/// "Offer one key only": the keys in ~/.ssh, marked with what the agent holds.
private struct OneKeyView: View {
    let subtitle: String?
    let held: Int
    let files: [SSHKey]
    let inAgent: Set<String>
    weak var window: WindowModel?
    let done: (String?) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Offer one key only", subtitle: subtitle, width: 620) {
            VStack(alignment: .leading, spacing: 0) {
                if held > 0 {
                    Text("Your agent is holding \(held) identit\(held == 1 ? "y" : "ies"), and every one of them "
                         + "is offered before anything else. That is what uses up the server’s attempt limit.")
                        .font(.system(size: 11.5)).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                }
                if files.isEmpty {
                    HEmpty(text: "No private keys found in ~/.ssh.")
                } else {
                    HListBox(maxHeight: 320) {
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(files) { k in
                                    Button { done(k.privatePath) } label: {
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(k.name.isEmpty ? (k.privatePath ?? "") : k.name).font(.system(size: 12.5))
                                                Text([k.type ?? "", k.bits.map { "\($0) bits" } ?? "", k.fingerprint ?? ""]
                                                    .filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                                    .font(.system(size: 11)).foregroundStyle(p.muted)
                                            }
                                            Spacer()
                                            if k.encrypted == true { HTag(text: "passphrase", warn: true) }
                                            if let f = k.fingerprint, inAgent.contains(f) { HTag(text: "in agent") }
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(4)
                        }
                    }
                    MiscHint(text: "The chosen key goes in the Private key field, and only it is offered.").padding(.top, 9)
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Browse…") {
                Task { @MainActor in
                    if let p = await SSHConfig.pickKey(window: window) { done(p) }
                }
            }.buttonStyle(.ghost)
        }
    }
}
