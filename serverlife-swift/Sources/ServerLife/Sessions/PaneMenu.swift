import AppKit
import SwiftUI

extension SessionsWindow {
    /// Enough of a URL to recognise it in a menu row, the middle taken out.
    nonisolated static func shortLink(_ url: String, max: Int = 52) -> String {
        guard url.count > max else { return url }
        let head = Int(ceil(Double(max - 1) * 0.62))
        return String(url.prefix(head)) + "…" + String(url.suffix(max - 1 - head))
    }

    /// The pane's right-click menu (sessions.js `onPaneContextMenu`).
    func paneMenu(_ paneId: String, at point: NSPoint) -> NSMenu? {
        guard let p = pane(paneId), let window else { return nil }
        setActivePane(paneId)
        let m = NSMenu()
        m.autoenablesItems = false
        let hasSel = p.term?.hasSelection ?? false
        let link = p.term?.linkAt(point)
        let many = panesOf(p.tabId).count >= 2

        // What only this kind of pane can do goes first.
        let top = PaneMenuItems.shared.items(.top, p, window)
        top.forEach { m.addItem($0) }
        if p.kind == .device && p.reconnect != nil {
            m.sessAdd(p.hasTerm ? "Close this console" : "Open it again") { [weak self] in
                guard let self else { return }
                if p.hasTerm { self.endPaneSession(p); self.routeExit(p, code: nil, reason: nil) }
                else { p.reconnectArmed = false; Task { await self.restartDevice(p) } }
            }
        }
        if !top.isEmpty || (p.kind == .device && p.reconnect != nil) { m.addItem(.separator()) }
        if p.kind == .local && !p.isHosts {
            m.sessAdd("Open in tmux on this machine\u{2026}",
                      tooltip: "A tmux session here — what runs in it keeps running when this window closes") {
                Actions.shared.perform("tmux-open", window: window, host: Host.localMachine)
            }
            m.addItem(.separator())
        }
        if let link {
            let open = m.sessAdd("Open link", tooltip: link) { Task { await TermLinks.openLink(link, window: window) } }
            if #available(macOS 14.4, *) { open.subtitle = SessionsWindow.shortLink(link) }
            m.sessAdd("Copy link", tooltip: link) { Clipboard.write(link); StatusBus.shared.show("Link copied") }
            m.addItem(.separator())
        }
        m.sessAdd("Copy", key: "⌘C", enabled: hasSel) { Clipboard.write(p.term?.selectionText ?? "") }
        m.sessAdd("Paste", key: "⌘V") { [weak self] in
            let t = Clipboard.read()
            if !t.isEmpty, p.hasTerm { _ = self; p.backend?.write(Data(t.utf8)) }
        }
        m.addItem(.separator())
        m.sessAdd("Split right — same host", key: "⌘⇧D") { [weak self] in Task { await self?.splitActivePane(.row) } }
        m.sessAdd("Split down — same host", key: "⌘⇧E") { [weak self] in Task { await self?.splitActivePane(.col) } }
        m.sessAdd("Split right — another host…") { [weak self] in self?.pickHostForSplit(.row) }
        m.sessAdd("Split down — another host…") { [weak self] in self?.pickHostForSplit(.col) }
        let move = NSMenu()
        move.sessAdd("Left", key: "⌘⇧←") { [weak self] in self?.movePane("left", paneId) }
        move.sessAdd("Right", key: "⌘⇧→") { [weak self] in self?.movePane("right", paneId) }
        move.sessAdd("Up", key: "⌘⇧↑") { [weak self] in self?.movePane("up", paneId) }
        move.sessAdd("Down", key: "⌘⇧↓") { [weak self] in self?.movePane("down", paneId) }
        let moveItem = NSMenuItem(title: "Move this pane", action: nil, keyEquivalent: "")
        moveItem.submenu = move
        moveItem.isEnabled = many
        m.addItem(moveItem)
        m.sessAdd("Move to its own window",
                  tooltip: "Keeps the session and the scrollback — or drag the pane out of the window") { [weak self] in
            self?.popPaneToWindow(paneId)
        }
        m.sessAdd("Move to its own tab", enabled: many,
                  tooltip: "Keeps the session, the scrollback and anything running in it") { [weak self] in
            self?.movePaneToNewTab(paneId)
        }
        m.sessAdd("Duplicate tab", key: "⌘D") { [weak self] in Task { await self?.duplicateActiveTab() } }
        m.addItem(.separator())
        m.sessAdd("Command history on this host…", enabled: p.kind == .remote && p.connId != nil,
                  tooltip: p.kind == .remote ? "Search everything this account has run here, and reuse it"
                                             : "Read from the server — open it on a host session") {
            Actions.shared.perform("command-history", window: window, paneId: p.id, connId: p.connId)
        }
        let middle = PaneMenuItems.shared.items(.middle, p, window)
        middle.forEach { m.addItem($0) }
        m.addItem(.separator())
        m.sessAdd("Snippets…", key: "⌘⇧C") { Actions.shared.perform("snippets", window: window, paneId: p.id) }
        m.sessAdd("Save selection as snippet…", enabled: hasSel) {
            Actions.shared.perform("snippet-from-selection", window: window, paneId: p.id,
                                   args: ["text": p.term?.selectionText ?? ""])
        }
        m.addItem(.separator())
        m.sessAdd("Save this terminal to a file\u{2026}", tooltip: "Everything in the buffer, scrollback included") { [weak self] in
            Task { await self?.savePaneText(p) }
        }
        m.sessAdd("Copy everything") {
            let text = p.term?.allText() ?? ""
            if text.isEmpty { StatusBus.shared.show("Nothing in this terminal yet"); return }
            Clipboard.write(text)
            StatusBus.shared.show("Terminal copied")
        }
        m.addItem(.separator())
        m.sessAdd("Clear") { p.term?.clearScreen() }
        m.sessAdd("Reconnect", enabled: p.kind != .local) { [weak self] in Task { await self?.reconnectPane(p) } }
        m.addItem(.separator())
        m.sessAdd("Close pane", key: "⌘W") { [weak self] in self?.closePane(paneId) }
        return m
    }

    /// Write a terminal's buffer out to a file, as plain text.
    func savePaneText(_ p: SessionPane) async {
        let text = p.term?.allText() ?? ""
        if text.isEmpty { StatusBus.shared.show("Nothing in this terminal yet"); return }
        let raw = p.kind == .local ? "local" : (SessConnRecords.shared.label(p.connId) ?? "session")
        let label = raw.replacingOccurrences(of: "[^\\w.-]+", with: "_", options: .regularExpression)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        let name = "\(label)-\(f.string(from: Date())).txt"
        if let url = await SessionsWindow.savePanel(window, title: "Save terminal output", name: name, types: nil),
           (try? Data(text.utf8).write(to: url)) != nil {
            StatusBus.shared.show("Saved \(url.path)")
            StatusBus.shared.toast("Terminal saved — \(label)", kind: .ok)
        }
    }

    // MARK: Menu-bar commands

    /// ⌘W: the focused pane, asking first if it is live.
    func closeActive() async {
        if let p = activePane { await requestClosePane(p.id) }
        else if let t = activeTabId { await requestCloseTab(t) }
    }

    func selectTab(index: Int) {
        guard index >= 0, index < tabs.count else { return }
        setActiveTab(tabs[index].id)
        focusActivePane()
    }

    func stepTab(_ by: Int) {
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == activeTabId } ?? 0
        let next = tabs[(i + by + tabs.count) % tabs.count]
        setActiveTab(next.id)
        focusActivePane()
    }

    /// ⌘+/⌘−/⌘0: the pane you are in, or the host list when that is where
    /// you clicked last.
    func zoom(_ dir: Int) {
        if zoomRegion == "sidebar" { SessionsWindow.zoomSidebar(dir); return }
        guard let p = activePane, let t = p.term else { return }
        let base = SessionTermView.settingFontSize
        t.setFontSize(dir == 0 ? base : t.fontSize + CGFloat(dir))
        StatusBus.shared.show("Text in this pane: \(Int(t.fontSize))px\(dir == 0 ? " (the setting)" : "")")
    }

    static func zoomSidebar(_ dir: Int) {
        let base = 13
        func clamp(_ n: Int) -> Int { max(10, min(22, n)) }
        let now = clamp(Store.shared.settingJSON("sidebarFontSize").int ?? base)
        let next = dir == 0 ? base : clamp(now + dir)
        Store.shared.setSetting("sidebarFontSize", next)
        StatusBus.shared.show("Host list text: \(next)px\(next == base ? " (default)" : "")")
    }

    /// ⌘⇧L: start or stop writing the focused terminal's output to a file.
    func toggleSessionLog() async {
        guard let p = activePane, p.kind == .remote, p.hasTerm else {
            StatusBus.shared.toast("Focus a remote terminal first", kind: .error); return
        }
        if p.logPath != nil || SessConn.logActive(p.connId, termId: SessConn.termId(p.backend)) {
            p.logPath = p.logPath ?? ""
            if let path = stopLog(p) { StatusBus.shared.show("Session log saved: " + path) }
            return
        }
        let name = p.connId.flatMap { SessConn.defaultLogFileName($0) } ?? "session.log"
        guard let url = await SessionsWindow.savePanel(window, title: "Save session log", name: name, directory: "~/Documents",
                                                        types: ["log", "txt"]) else { return }
        do {
            try startLog(p, path: url.path)
            StatusBus.shared.show("Logging this session to " + url.path)
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
        }
    }

    func toggleBroadcast() {
        broadcast.toggle()
        StatusBus.shared.show(broadcast ? "Broadcast typing ON — keystrokes go to every pane in this tab" : "Broadcast typing off")
    }
}

/// The BROADCAST mark in the status bar while broadcast typing is on.
struct BroadcastBadge: View {
    let window: WindowModel
    var body: some View {
        let p = Theme.shared.p
        if window.feature(SessionsWindow.self).broadcast {
            Text("BROADCAST")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(p.amber)
                .help("Broadcast typing is on — keystrokes go to every pane in this tab (⌘⇧B)")
        }
    }
}

import UniformTypeIdentifiers

extension SessionsWindow {
    /// A save panel with the original's title (and filter, for the log).
    static func savePanel(_ owner: WindowModel?, title: String, name: String, directory: String? = nil,
                          types: [String]?) async -> URL? {
        let p = NSSavePanel()
        p.title = title
        p.nameFieldStringValue = name
        p.canCreateDirectories = true
        if let directory { p.directoryURL = URL(fileURLWithPath: directory.expandingTilde) }
        if let types { p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) } }
        if let parent = owner?.nsWindow {
            return await withCheckedContinuation { c in p.beginSheetModal(for: parent) { c.resume(returning: $0 == .OK ? p.url : nil) } }
        }
        return p.runModal() == .OK ? p.url : nil
    }
}
