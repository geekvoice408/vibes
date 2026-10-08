import AppKit
import SwiftUI

/// A connection to a host for something that is not a terminal: the open one
/// for that host and login if there is one, else a new one, dialled.
@MainActor
enum FleetConn {
    static func ensure(_ host: Host, login: String?) async throws -> String {
        let cm = ConnectionManager.shared
        if let c = cm.find(host: host, login: login), c.state == .connected { return c.id }
        let c = try await cm.create(host: host, options: ConnectOptions(login: login, reuse: true))
        try await cm.connect(c.id)
        return c.id
    }
}

/// "Run a command…" with its output in a dialog — the sidebar's
/// `run-command` (hostactions.js `openRunCommandDialog`) when it is there,
/// else this faithful stand-in, so a macro can always run headless.
@MainActor
enum FleetRunCommand {
    static var lastQuickCommand = ""

    static func open(host: Host, login: String?, command: String, title: String?, window: WindowModel?) {
        if Actions.shared.isRegistered("run-command") {
            Actions.shared.perform("run-command", window: window, host: host,
                                   args: ["login": login as Any, "command": command, "title": title ?? "", "autoRun": true])
            return
        }
        Modal.sheet(window, title: title ?? "Run a command", width: 720) { handle in
            RunView(host: host, login: login, initial: command, title: title, autoRun: true, handle: handle)
        }
    }

    private struct RunView: View {
        let host: Host
        let login: String?
        let title: String?
        let autoRun: Bool
        let handle: ModalHandle
        @StateObject private var cmd: Local<String>
        @StateObject private var output = Local("Output appears here.")
        @StateObject private var failed = LocalFlag()
        @StateObject private var meta = Local("")
        @StateObject private var running = LocalFlag()
        @StateObject private var connId = Local<String?>(nil)
        @StateObject private var lastOutput = Local("")
        @StateObject private var started = LocalFlag()

        init(host: Host, login: String?, initial: String, title: String?, autoRun: Bool, handle: ModalHandle) {
            self.host = host; self.login = login; self.title = title; self.autoRun = autoRun; self.handle = handle
            // A caller that supplies a command (a macro, say) has already chosen it.
            _cmd = StateObject(wrappedValue: Local(initial.isEmpty ? FleetRunCommand.lastQuickCommand : initial))
        }

        private func run() {
            let c = cmd.value.trimmed
            guard !c.isEmpty else { StatusBus.shared.toast("Enter a command", kind: .error); return }
            guard !running.on else { return }
            running.on = true
            FleetRunCommand.lastQuickCommand = c
            output.value = "Running\u{2026}"
            failed.on = false
            meta.value = ""
            let t0 = nowMs()
            Task { @MainActor in
                defer { running.on = false }
                do {
                    let id: String
                    if let existing = connId.value { id = existing } else {
                        id = try await FleetConn.ensure(host, login: login)
                        connId.value = id
                    }
                    let r = try await ConnectionManager.shared.exec(id, c)
                    lastOutput.value = r.stdout
                    output.value = r.stdout.trimmed.nilIfEmpty ?? "(no output)"
                    meta.value = "Finished in \(Fmt.duration(ms: nowMs() - t0)) \u{00B7} \(r.stdout.utf8.count) bytes"
                } catch {
                    // A non-zero exit arrives here too; the message is the server's stderr.
                    let msg = (error as? AppError)?.message ?? error.localizedDescription
                    lastOutput.value = msg
                    output.value = msg.nilIfEmpty ?? "Command failed"
                    failed.on = true
                    meta.value = "Failed after \(Fmt.duration(ms: nowMs() - t0))"
                }
            }
        }

        var body: some View {
            let p = Theme.shared.p
            DialogScaffold(title: title?.nilIfEmpty ?? "Run a command", subtitle: host.name.nilIfEmpty ?? host.alias ?? "") {
                VStack(alignment: .leading, spacing: 0) {
                    MiscField(label: "Command", hint: "Enter runs it \u{00B7} Shift+Enter for a new line") {
                        TextField("systemctl status nginx", text: $cmd.value, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(3...8)
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                            .onSubmit { run() }
                    }
                    Text("Output").font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 5)
                    ScrollView {
                        Text(output.value)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(failed.on ? p.red : p.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                    }
                    .frame(minHeight: 64, maxHeight: 320)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    if !meta.value.isEmpty { MiscHint(text: meta.value).padding(.top, 6) }
                }
            } footer: {
                Button("Copy output") {
                    if lastOutput.value.isEmpty { StatusBus.shared.toast("Nothing to copy yet"); return }
                    Clipboard.write(lastOutput.value)
                    StatusBus.shared.show("Output copied")
                }.buttonStyle(.ghost)
                Button("Save as snippet") {
                    let c = cmd.value.trimmed
                    guard !c.isEmpty else { StatusBus.shared.toast("Enter a command first", kind: .error); return }
                    Task { @MainActor in await Snippets.edit(["command": .string(c)], window: nil) }
                }.buttonStyle(.ghost)
                Button("Run") { run() }.buttonStyle(.primary)
                Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            }
            .onAppear {
                // Handed a command, get on with it rather than making the user press Run.
                if autoRun && !started.on && !cmd.value.trimmed.isEmpty { started.on = true; run() }
            }
        }
    }
}
