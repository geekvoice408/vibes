import AppKit
import SwiftUI

/// The file explorer panes (explorer.js, files.js, rsyncsync.js, watch.js).
///
/// Owner: explorer (see CLAUDE.md → Ownership). Registers the explorer's menu
/// actions, hooks the explorers into Sessions' panes (ExplorerSessionsGlue),
/// and starts the background refresh tick.
@MainActor
enum ExplorerFeature {
    static func install() {
        let a = Actions.shared
        // ⌘E — the focused pane's explorer (the tab-wide and app-wide sweeps
        // are on the pane button's right-click menu).
        a.register("toggle-files") { ctx in XPFiles.toggleFocusedExplorer(ctx.window) }
        // ⌘⇧P — beside or above the terminal.
        a.register("explorer-position") { ctx in XPFiles.setExplorerPosition(ctx.arg("position", as: String.self)) }
        // ⌘⇧F — the local list under the focused pane; args `path` shows that folder.
        a.register("local-files") { ctx in XPFiles.openLocalFiles(ctx.window, path: ctx.arg("path", as: String.self), show: ctx.arg("show", as: Bool.self) == true) }
        // Every pane's explorer at once; args `visible` (Bool, omitted = toggle).
        a.register("explorers-all") { ctx in XPFiles.toggleAllExplorers(ctx.arg("visible", as: Bool.self), window: ctx.window) }
        // A saved profile's local start path; args `path`.
        a.register("files-local-path") { ctx in
            guard let p = ctx.arg("path", as: String.self) else { return }
            Task { await XPFiles.setLocalPath(p, window: ctx.window) }
        }
        // The title-bar file-browser button's right-click menu; args `menu` NSMenu to fill.
        a.register("files-button-menu") { ctx in
            guard let menu = ctx.arg("menu", as: NSMenu.self) else { return }
            let built = CtxMenu.build(XPFiles.buttonMenuItems(window: ctx.window))
            for it in built.items { built.removeItem(it); menu.addItem(it) }
        }
        // For --snapshot checks of the explorer outside a pane.
        a.register("debug-explorer-panel") { _ in XPDebug.openPanel() }
        // …and one of its dialogs (env XP_DIALOG: goto | search | info | edit | rsync | max).
        a.register("debug-explorer-dialog") { _ in XPDebug.dialog(ProcessInfo.processInfo.environment["XP_DIALOG"] ?? "") }

        MiscHooks.settingsSaved.append { _, _ in XPFiles.settingsChanged() }
        XPSessionsGlue.install()
        XPS3.install()
        XPFiles.start()
    }
}

@MainActor
enum XPDebug {
    static var model: ExplorerModel?
    static func openPanel() {
        let m = model ?? ExplorerModel(source: .local)
        model = m
        Modal.panel(id: "debug-explorer", title: "Explorer", width: 560, height: 520) { _ in
            ExplorerView(ex: m)
        }
    }

    static func dialog(_ which: String) {
        if which == "max", let pid = XPPanes.activePaneId(nil) {
            XPPaneExplorers.shared.entry(pid).main.maximized = true
            return
        }
        guard let m = model, let e = m.view.entries.first(where: { !XP.isDir($0) && !$0.name.hasPrefix(".") }) else { return }
        let d = m.view.entries.first(where: XP.isDir)
        Task {
            switch which {
            case "goto": await XPDialogs.goToPath(m)
            case "search": await XPSearch.open(m)
            case "info": await XPDialogs.info(m, d ?? e)
            case "edit": await XPDialogs.editor(m, e, local: true)
            case "rsync": await XPRsyncDialog.open(m)
            default: break
            }
        }
    }
}
