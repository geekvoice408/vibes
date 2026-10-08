import AppKit

/// The menu bar: main.js `buildMenu()`, item for item. Every custom item
/// performs an action id through `Actions` (the same ids the Electron main
/// process sent to the renderer as `menu` events).
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    static let shared = MainMenu()

    private enum K { static let cmd: NSEvent.ModifierFlags = [.command] }

    func install() {
        let main = NSMenu()

        // ServerLife
        let app = submenu(main, "ServerLife")
        add(app, "About ServerLife", "about")
        app.addItem(.separator())
        add(app, "Settings…", "settings", key: ",")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(); services.submenu = servicesMenu; NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide ServerLife", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ServerLife", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Session
        let s = submenu(main, "Session")
        add(s, "New Window", "new-window", key: "n", mods: [.command, .option])
        add(s, "New Session…", "new-session", key: "n")
        add(s, "Quick Connect…", "quick-connect", key: "c", mods: [.command, .option])
        add(s, "Add a Server…", "add-server", key: "n", mods: [.command, .shift])
        add(s, "New Local Shell", "new-local", key: "t")
        add(s, "Show/Hide Local Files", "local-files", key: "f", mods: [.command, .shift])
        add(s, "Duplicate Tab", "duplicate-tab", key: "d")
        s.addItem(.separator())
        add(s, "Split Right", "split-right", key: "d", mods: [.command, .shift])
        add(s, "Split Down", "split-down", key: "e", mods: [.command, .shift])
        add(s, "Split Right with Another Host…", "split-right-host", key: "d", mods: [.command, .option])
        add(s, "Split Down with Another Host…", "split-down-host", key: "e", mods: [.command, .option])
        let move = NSMenu(title: "Move Pane")
        add(move, "Left", "move-pane-left", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), mods: [.command, .shift])
        add(move, "Right", "move-pane-right", key: String(UnicodeScalar(NSRightArrowFunctionKey)!), mods: [.command, .shift])
        add(move, "Up", "move-pane-up", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.command, .shift])
        add(move, "Down", "move-pane-down", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: [.command, .shift])
        let moveItem = NSMenuItem(title: "Move Pane", action: nil, keyEquivalent: ""); moveItem.submenu = move
        s.addItem(moveItem)
        add(s, "Close Pane", "close-pane", key: "w")
        s.addItem(.separator())
        add(s, "Toggle Session Log", "toggle-log", key: "l", mods: [.command, .shift])
        s.addItem(.separator())
        add(s, "Command Snippets…", "snippets", key: "c", mods: [.command, .shift])
        add(s, "SSH Keys…", "keys", key: "k", mods: [.command, .shift])
        add(s, "Network Tools…", "nettools", key: "t", mods: [.command, .shift])
        add(s, "S3 Buckets…", "s3")
        add(s, "Run Macro…", "run-macro", key: "r", mods: [.command, .shift])
        add(s, "Multi-Exec…", "multiexec", key: "m", mods: [.command, .shift])
        add(s, "Toggle Broadcast Typing", "broadcast", key: "b", mods: [.command, .shift])
        s.addItem(.separator())
        let layouts = NSMenu(title: "Layouts")
        add(layouts, "Save Layout As…", "save-layout-as", key: "s", mods: [.command, .shift])
        add(layouts, "Load Layout…", "load-layout", key: "o", mods: [.command, .shift])
        layouts.addItem(.separator())
        add(layouts, "Manage Layouts…", "manage-layouts")
        layouts.addItem(.separator())
        add(layouts, "Remember Current Layout", "save-layout")
        add(layouts, "Forget Remembered Layout", "clear-layout")
        let layoutsItem = NSMenuItem(title: "Layouts", action: nil, keyEquivalent: ""); layoutsItem.submenu = layouts
        s.addItem(layoutsItem)
        s.addItem(.separator())
        add(s, "Disconnect", "disconnect")

        // Edit
        let e = submenu(main, "Edit")
        e.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = e.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        e.addItem(.separator())
        e.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        e.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        e.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        e.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        e.addItem(.separator())
        add(e, "Find in Terminal", "find", key: "f")
        add(e, "Clear Terminal", "clear-terminal", key: "k")

        // View
        let v = submenu(main, "View")
        add(v, "Show/Hide File Explorers", "toggle-files", key: "e")
        add(v, "Explorer Beside / Above Terminal", "explorer-position", key: "p", mods: [.command, .shift])
        add(v, "Show/Hide Hosts", "toggle-sidebar", key: "b")
        add(v, "Toggle Transfers", "toggle-transfers", key: "j")
        v.addItem(.separator())
        add(v, "Bigger Text", "zoom-in", key: "=")
        add(v, "Smaller Text", "zoom-out", key: "-")
        add(v, "Default Text Size", "zoom-reset", key: "0")
        v.addItem(.separator())
        let fs = v.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]

        // Teleport
        let t = submenu(main, "Teleport")
        add(t, "Refresh Inventory", "refresh", key: "r")
        add(t, "Profiles & Access Requests…", "teleport-panel")
        add(t, "Cluster Information…", "cluster-info")
        add(t, "Monitor Requestable Resources…", "request-monitor")
        t.addItem(.separator())
        add(t, "Session History…", "history", key: "y")
        add(t, "Recorded Sessions…", "recordings", key: "y", mods: [.command, .shift])
        t.addItem(.separator())
        add(t, "tsh login…", "tsh-login")

        // Window
        let w = submenu(main, "Window")
        w.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        w.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        w.addItem(.separator())
        // ⌘1…⌘9 jump to a tab; ⌘⌥← / ⌘⌥→ step through them.
        for i in 1...9 { add(w, "Tab \(i)", "tab-\(i)", key: "\(i)") }
        add(w, "Previous Tab", "tab-prev", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), mods: [.command, .option])
        add(w, "Next Tab", "tab-next", key: String(UnicodeScalar(NSRightArrowFunctionKey)!), mods: [.command, .option])
        w.addItem(.separator())
        w.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = w

        // Help
        let h = submenu(main, "Help")
        add(h, "Take the Tour…", "tour")
        add(h, "Guide — what everything does…", "guide", key: "/")
        h.addItem(.separator())
        add(h, "About ServerLife", "about")
        add(h, "Version History…", "version-history")
        h.addItem(.separator())
        add(h, "Teleport Documentation", "teleport-docs")
        NSApp.helpMenu = h

        NSApp.mainMenu = main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        item.submenu = m
        main.addItem(item)
        return m
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: String, key: String = "",
                     mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.representedObject = action
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc func fire(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Actions.shared.perform(id, ActionContext(window: WindowManager.shared.current()))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String else { return true }
        // Unregistered actions stay enabled so pressing one explains itself.
        if !Actions.shared.isRegistered(id) { return true }
        return Actions.shared.isEnabled(id, ActionContext(window: WindowManager.shared.focused))
    }
}
