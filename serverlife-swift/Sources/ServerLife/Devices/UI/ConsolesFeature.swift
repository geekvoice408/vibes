import AppKit
import SwiftUI

/// tmux, VNC, serial, telnet and RDP panes and dialogs (tmux.js, vnc.js, and
/// the console openers in sessions.js / sidebar.js / quickconnect.js).
///
/// Owner: consoles (see CLAUDE.md → Ownership, and README.md here).
@MainActor
enum ConsolesFeature {
    static func install() {
        let a = Actions.shared

        // tmux-open: host; args `login`, `session` (attach to it straight
        // away; without it, or with `dialog: true`, the dialog that asks which).
        a.register("tmux-open") { ctx in
            guard let host = ctx.host else { return }
            let window = ctx.window ?? WindowManager.shared.current()
            let login: String? = ctx.arg("login")
            if ctx.arg("dialog", as: Bool.self) != true, let session: String = ctx.arg("session"), !session.isEmpty {
                Task { await ConsolesTmux.open(host, login: login, session: session, window: window) }
            } else {
                ConsolesTmux.openDialog(host, login: login, window: window)
            }
        }
        a.register("serial-open") { ctx in
            guard let host = ctx.host else { return }
            ConsolesDevices.open(host, kind: Host.serial, window: ctx.window ?? WindowManager.shared.current(),
                                 split: ctx.arg("split"), startupCommand: ctx.arg("startupCommand"))
        }
        a.register("telnet-open") { ctx in
            guard let host = ctx.host else { return }
            ConsolesDevices.open(host, kind: Host.telnet, window: ctx.window ?? WindowManager.shared.current(),
                                 split: ctx.arg("split"), startupCommand: ctx.arg("startupCommand"))
        }
        a.register("vnc-open") { ctx in
            guard let host = ctx.host else { return }
            var h = host
            if let pw: String = ctx.arg("password") { h.extra["password"] = .string(pw) }
            ConsolesVNC.open(h, window: ctx.window ?? WindowManager.shared.current(), split: ctx.arg("split"))
        }
        a.register("rdp-open") { ctx in
            guard let host = ctx.host else { return }
            Task { await ConsolesDevices.launchRDP(host) }
        }
        // serial-ports: args `reply` ([SerialPortInfo]) -> Void, or
        // `replyJSON` (JSON array of the original's port objects) -> Void.
        a.register("serial-ports") { ctx in
            let reply = ctx.arg("reply", as: (([SerialPortInfo]) -> Void).self)
            let replyJSON = ctx.arg("replyJSON", as: ((JSON) -> Void).self)
            Task {
                let ports = await ConsolesDevices.ports()
                reply?(ports)
                replyJSON?(.array(ports.map(\.json)))
            }
        }

        // The pane's own commands, at the top of its right-click menu.
        PaneMenuItems.shared.register("consoles.device", section: .top) { p, w in ConsolesDevices.paneMenuItems(p, w) }
        PaneMenuItems.shared.register("consoles.tmux", section: .top) { p, w in ConsolesTmux.paneMenuItems(p, w) }
        PaneHeaderItems.shared.register("consoles.tmux", slot: .tmuxControls) { p in ConsolesTmux.headerControls(p) }
        PaneHeaderItems.shared.register("consoles.vnc", slot: .tmuxControls) { p in ConsolesVNC.headerControls(p) }

        // On a tmux pane a plain split (⌘⇧D, ⌘⇧E) is tmux's.
        SessionsTmux.split = { p, dir in
            guard ConsolesTmux.info(p) != nil else { return false }
            ConsolesTmux.split(p, dir)
            return true
        }
        // Closing a pane here closes the view of it, never the session.
        SessionHooks.paneClosing.append { p in ConsolesTmux.forget(p) }
        WindowManager.shared.didOpen.append { model, _ in
            ConsolesTmux.observeFocus(model.feature(SessionsWindow.self))
        }
        if CommandLine.arguments.contains("--snapshot") { installSnapshotDemos() }
    }

    /// Ids for `--snapshot` only, so the panes and dialogs can be looked at
    /// without a server: tmux on this machine (run the snapshot with
    /// TMUX_TMPDIR set to keep it off the everyday tmux server), a screen
    /// and a telnet target that refuse, and the "no tmux" dialog.
    private static func installSnapshotDemos() {
        let a = Actions.shared
        a.register("consoles-demo-tmux") { ctx in
            a.perform("tmux-open", window: ctx.window, host: Host.localMachine, args: ["session": "sl-consoles-demo"])
        }
        a.register("consoles-demo-tmux-split") { ctx in
            guard let p = ctx.window?.feature(SessionsWindow.self).activePane else { return }
            ConsolesTmux.split(p, .row)
        }
        a.register("consoles-demo-dump") { ctx in
            guard let s = ctx.window?.feature(SessionsWindow.self) else { return }
            for rec in ConsolesTmux.records.values { print("DUMP rec panes", rec.panes) }
            for t in s.tabs { print("DUMP tab", t.id, t.paneIds) }
            for p in s.panes.values {
                let b = p.backend as? TmuxPaneBackend
                print("DUMP pane", p.id, ConsolesTmux.info(p)?.pane ?? "-", b?.pane ?? "-",
                      p.term.map { ObjectIdentifier($0).hashValue } ?? 0, p.term?.superview != nil, p.overlay?.title ?? "-", p.overlay?.alt?.label ?? "-", p.tmuxEnded ?? "-")
            }
        }
        a.register("consoles-demo-tmux-dialog") { ctx in a.perform("tmux-open", window: ctx.window, host: Host.localMachine) }
        a.register("consoles-demo-vnc") { ctx in
            a.perform("vnc-open", window: ctx.window, host: Host(json: ["type": "vnc", "host": "127.0.0.1", "port": 5999]))
        }
        a.register("consoles-demo-telnet") { ctx in
            a.perform("telnet-open", window: ctx.window, host: Host(json: ["type": "telnet", "host": "127.0.0.1", "port": 1]))
        }
        a.register("consoles-demo-missing") { ctx in
            Task {
                await ConsolesTmux.explainMissingTmux(Host(json: ["type": "ssh", "alias": "web-1"]),
                                                      TmuxControl.parseProbe("", local: false), window: ctx.window)
            }
        }
    }
}
