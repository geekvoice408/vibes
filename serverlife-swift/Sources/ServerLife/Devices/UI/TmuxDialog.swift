import AppKit
import SwiftUI

/*
 * The "open in tmux" dialog: which session, on a host that may already have
 * several. Asked rather than assumed, because attaching to the wrong one is
 * the one mistake here that looks like data loss: your work is not gone, it
 * is in the session you did not pick.
 */
@MainActor
final class TmuxDialogModel: ObservableObject {
    let host: Host
    let label: String
    @Published var waiting: String
    @Published var ready = false
    /// The load finished without an answer (dialling failed): the button
    /// reads "Attach" again but stays disabled, as the original's did.
    @Published var settled = false
    @Published var probe: TmuxProbe?
    @Published var existing: [TmuxSessionInfo] = []
    @Published var pick = ""
    @Published var name: String

    init(host: Host) {
        self.host = host
        label = ConsolesText.hostLabel(host)
        waiting = "Connecting to \(label)…"
        name = Store.shared.settingJSON("tmuxSessionName").string?.nilIfEmpty ?? "serverlife"
    }

    /// What Attach opens: the picked session, else the typed name.
    var choice: String { pick.nilIfEmpty ?? name.trimmed.nilIfEmpty ?? "serverlife" }
}

extension ConsolesTmux {
    /*
     * The dialog opens before the host has been asked anything. Finding out
     * what is already running there means dialling first, and on a node behind
     * a proxy that is ten or twenty seconds. Showing the dialog with
     * "connecting" in it is the same wait with something to look at, and
     * Escape still works.
     */
    static func openDialog(_ host: Host, login: String?, window: WindowModel) {
        let model = TmuxDialogModel(host: host)
        let s = window.feature(SessionsWindow.self)
        var handle: ModalHandle?
        handle = Modal.sheet(window, title: "tmux on \(model.label)", width: 520) { h in
            TmuxDialogView(model: model, cancel: { h.close() }, attach: {
                guard model.ready else { return }
                let session = model.choice
                h.close()
                Task { await ConsolesTmux.open(host, login: login, session: session, window: window) }
            })
        }
        Task {
            let connId: String
            do {
                connId = try await dial(host, login: login, in: s)
            } catch {
                model.waiting = error.localizedDescription
                model.settled = true
                return
            }
            guard let th = tmuxHost(connId) else { model.settled = true; return }
            let probe = await TmuxService.shared.probe(th)
            if !probe.ok {
                handle?.close()
                await explainMissingTmux(host, probe, window: window)
                return
            }
            model.waiting = "tmux \(probe.version ?? "") — reading the sessions already running there…"
            let existing = await TmuxService.shared.listSessions(th)
            guard handle?.closed == false else { return }
            model.probe = probe
            model.existing = existing
            model.pick = existing.first?.name ?? ""
            model.ready = true
        }
    }
}

struct TmuxDialogView: View {
    @ObservedObject var model: TmuxDialogModel
    let cancel: () -> Void
    let attach: () -> Void

    var body: some View {
        DialogScaffold(title: "tmux on \(model.label)", width: 520, scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !model.ready {
                    MiscHint(text: model.waiting, size: 11.5)
                } else {
                    MiscField(label: "Session", hint: model.existing.isEmpty
                              ? "Nothing is running there yet"
                              : "Already running there — attaching picks up where it was left") {
                        Picker("", selection: $model.pick) {
                            ForEach(model.existing) { s in Text(ConsolesText.sessionOption(s)).tag(s.name) }
                            Text(model.existing.isEmpty ? "Start a session" : "A new session…").tag("")
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.pick.isEmpty {
                        MiscField(label: "Name") {
                            TextField("serverlife", text: $model.name)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(attach)
                        }
                    }
                    MiscHint(text: "tmux \(model.probe?.version ?? "") on \(model.label). What runs in a tmux session keeps running when "
                             + "this window goes away — a dropped connection, a closed laptop, a restarted app — "
                             + "and reattaching brings back the scrollback with it.", size: 11.5)
                        .padding(.top, 10)
                }
            }
        } footer: {
            Button("Cancel") { cancel() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(model.ready || model.settled ? "Attach" : "Connecting…") { attach() }
                .buttonStyle(.primary)
                .disabled(!model.ready)
                .keyboardShortcut(.defaultAction)
        }
    }
}
