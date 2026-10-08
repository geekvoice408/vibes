import AppKit
import SwiftUI

/// The only file that touches Sessions' types: it answers `XPPanes` from
/// `SessionPane`s, puts the explorer beside each pane's terminal
/// (`PaneAccessories`), follows the shell's directory (`SessionHooks`), and
/// tears a pane's explorers down when the pane closes.
@MainActor
enum XPSessionsGlue {
    static func install() {
        XPPanes.info = { id in
            guard let s = SessionsCore.owner(ofPane: id), let p = s.pane(id) else { return nil }
            let shown = p.explorerVisible || p.filesOnly
            return XPPaneInfo(kind: p.kind.rawValue, connId: p.connId, tabId: p.tabId, explorerVisible: shown,
                              onScreen: shown && p.tabId == s.activeTabId, cwd: p.cwd, hasTerm: p.hasTerm,
                              tmuxAttached: p.kind == .tmux && p.tmuxEnded == nil, window: s.window)
        }
        XPPanes.activePaneId = { w in
            (w ?? WindowManager.shared.focused).map { $0.feature(SessionsWindow.self).activePaneId } ?? nil
        }
        XPPanes.setVisible = { id, v in
            guard let s = SessionsCore.owner(ofPane: id), let p = s.pane(id) else { return }
            s.setExplorerVisible(p, v)
            // Nothing is polled while this side is hidden, so the lists about
            // to appear may be stale — bring them up to date on the way in.
            if v { after(0.05) { XPFiles.catchUpVisible(id) } }
        }
        XPPanes.send = { id, text in
            guard let s = SessionsCore.owner(ofPane: id), let p = s.pane(id) else { return }
            s.sendToPane(p, text)
        }
        XPPanes.allPaneIds = { w in
            (w ?? WindowManager.shared.focused).map { Array($0.feature(SessionsWindow.self).panes.keys) } ?? []
        }

        PaneAccessories.shared.provider = { pane in
            AnyView(ExplorerPaneView(entry: XPPaneExplorers.shared.entry(pane.id)))
        }
        // The pane's directory changed (the cwd loop, or a `cd` just typed).
        SessionHooks.cwdChanged.append { p in XPFiles.followPaneNow(p.id) }
        SessionHooks.paneClosing.append { p in XPPaneExplorers.shared.close(p.id) }
    }
}
