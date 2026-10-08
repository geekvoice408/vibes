import Foundation

/// Serial, telnet, tmux control mode, RFB (VNC) client, RDP launch (devices.js, tmuxctl.js, rdp.js …).
///
/// Owner: devices-service (see CLAUDE.md → Ownership). See README.md in this
/// directory for the public API. Nothing here registers actions: the panes
/// and dialogs that use these services belong to the consoles owner.
@MainActor
enum DevicesServiceFeature {
    static func install() {
        // On the way out: consoles closed, tmux clients dropped (the sessions
        // stay on their servers), VNC sockets hung up — as main.js did on quit.
        AppDelegate.willTerminate.append {
            DeviceSessions.shared.closeAll()
            TmuxService.shared.closeAll()
            VNCSession.closeAll()
        }
    }
}
