import AppKit
import SwiftUI
import Observation

/// One window's tabs and panes: the per-window half of state.js and the
/// orchestration in sessions.js. Get it with `window.feature(SessionsWindow.self)`.
@MainActor
@Observable
final class SessionsWindow: WindowFeature {
    @ObservationIgnored weak var window: WindowModel?
    var tabs: [SessionTab] = []
    var panes: [String: SessionPane] = [:]
    var activeTabId: String?
    var activePaneId: String?
    /// Broadcast typing: keystrokes go to every remote pane in the tab.
    var broadcast = false
    /// Where ⌘+/⌘− act: the pane you are in, or the host list.
    @ObservationIgnored var zoomRegion = "panes"
    @ObservationIgnored private var typedLine: [String: String] = [:]
    @ObservationIgnored private var lastTitle: String?
    @ObservationIgnored let saveDebounce = Debouncer(1.2)
    /// Set while a layout is being restored, so it is not saved half-built.
    @ObservationIgnored var restoring = false
    /// Where each tab is in the window (top-left origin), for right-clicks.
    @ObservationIgnored var tabFrames: [String: CGRect] = [:]
    @ObservationIgnored private var focusObservation: NSKeyValueObservation?

    /// ⌘+/⌘− follow keyboard focus too: tabbing into the host list makes
    /// them size the host list.
    func watchFocusForZoom() {
        guard focusObservation == nil, let nsw = window?.nsWindow else { return }
        focusObservation = nsw.observe(\.firstResponder, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let model = self.window, let v = w.firstResponder as? NSView,
                          let content = w.contentView, v.window === w else { return }
                    let r = v.convert(v.bounds, to: content)
                    self.zoomRegion = (model.sidebarVisible && r.midX < model.sidebarWidth) ? "sidebar" : "panes"
                }
            }
        }
    }

    init(window: WindowModel) {
        self.window = window
    }

    // MARK: Lookups

    func tab(_ id: String?) -> SessionTab? { id.flatMap { i in tabs.first { $0.id == i } } }
    func pane(_ id: String?) -> SessionPane? { id.flatMap { panes[$0] } }
    func panesOf(_ tabId: String?) -> [String] { tab(tabId)?.paneIds ?? [] }
    var activeTab: SessionTab? { tab(activeTabId) }
    var activePane: SessionPane? { pane(activePaneId) }

    /// The connection backing the focused pane (what the file browser follows).
    var activeConnId: String? {
        guard let p = activePane, p.kind == .remote else { return nil }
        return p.connId
    }

    // MARK: Tabs and panes

    @discardableResult
    func createTab(title: String, kind: String, connId: String?) -> SessionTab {
        let t = SessionTab(title: title, kind: kind, connId: connId)
        tabs.append(t)
        changed()
        return t
    }

    func removeTab(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if activeTabId == id {
            let next = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
            activeTabId = next?.id
            activePaneId = next?.firstPane
        }
        changed()
    }

    /// Back to the pane you were last in, not to the first one.
    func setActiveTab(_ id: String) {
        guard activeTabId != id else { return }
        activeTabId = id
        let t = tab(id)
        if let remembered = t?.lastPaneId, panes[remembered]?.tabId == id {
            activePaneId = remembered
        } else {
            activePaneId = t?.firstPane
        }
        changed()
    }

    func setActivePane(_ id: String?) {
        guard activePaneId != id else { return }
        activePaneId = id
        guard let p = pane(id) else { return }
        if p.tabId != activeTabId { activeTabId = p.tabId }
        tab(p.tabId)?.lastPaneId = p.id
    }

    func addPane(_ p: SessionPane) {
        panes[p.id] = p
        p.owner = self
        changed()
    }

    /// Take a pane out of its tab's layout without destroying it (moving).
    @discardableResult
    func detachPane(_ id: String) -> SessionPane? {
        guard let p = panes[id] else { return nil }
        if let t = tab(p.tabId) { t.root = PaneTree.removing(id, from: t.root) }
        changed()
        return p
    }

    /// A pane that is going away: out of the map and the tree.
    func removePane(_ id: String) {
        guard let p = panes.removeValue(forKey: id) else { return }
        PaneActivity.shared.forget(id)
        typedLine.removeValue(forKey: id)
        if let t = tab(p.tabId) { t.root = PaneTree.removing(id, from: t.root) }
        changed()
    }

    /// Something about the tabs changed: keep the window title and the saved
    /// layout in step (`state.emit('tabs')`).
    func changed() {
        syncWindowTitle()
        if !restoring { saveDebounce.call { [weak self] in self?.saveWorkspaceNow() } }
    }

    /// Name the window after what is open in it, so the Window menu lists
    /// `web-01, db-02` rather than three entries called ServerLife.
    func syncWindowTitle() {
        let names = tabs.map { t in SessConnRecords.shared.label(t.connId) ?? t.title }
        let title = names.isEmpty ? "ServerLife"
            : names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
        guard title != lastTitle else { return }
        lastTitle = title
        window?.title = title
        window?.nsWindow?.title = title
    }

    // MARK: Creating a pane

    /// `createPane`: the pane, its terminal wired to this window, highlight
    /// rules read, and the explorer shown or not as the setting says.
    @discardableResult
    func createPane(tabId: String, kind: PaneKind, connId: String?, cwd: String? = nil) -> SessionPane {
        let p = SessionPane(tabId: tabId, kind: kind, connId: connId)
        p.cwd = cwd
        wireTerm(p)
        addPane(p)
        p.applyHighlightSettings()
        // A console and a screen open without the file browser; a tmux pane
        // keeps it — there is a real host under it.
        let explorers = Store.shared.settingJSON("explorersVisible").bool != false
        p.explorerVisible = (kind == .remote || kind == .local || kind == .tmux) ? explorers : false
        SessionHooks.paneCreated.forEach { $0(p) }
        return p
    }

    /// Point a pane's terminal at this window's handlers. Done again when a
    /// pane moves to another window.
    func wireTerm(_ p: SessionPane) {
        guard let term = p.term else { return }
        let id = p.id
        term.onInput = { [weak self] d in self?.handleInput(id, d) }
        term.onResize = { [weak self] c, r in self?.handleResize(id, c, r) }
        term.onTitle = { [weak self] t in
            guard let p = self?.pane(id) else { return }
            p.remoteTitle = t
        }
        term.onFocus = { [weak self] in self?.setActivePane(id) }
        term.menuProvider = { [weak self] pt in self?.paneMenu(id, at: pt) }
        term.onSearchResults = { [weak self] index, count in
            guard let p = self?.pane(id) else { return }
            p.searchIndex = index
            p.searchCount = count
        }
    }

    // MARK: The byte stream

    /// Attach a running backend to a pane (and its output to the screen).
    func attach(_ p: SessionPane, _ backend: TerminalBackend) {
        p.backend = backend
        p.hasTerm = true
        p.status = "connected"
        backend.onData = { [weak p] d in
            guard let p, let owner = p.owner else { return }
            owner.writeToPane(p, d)
        }
        backend.onExit = { [weak p, weak backend] code, reason in
            guard let p, let owner = p.owner, let backend, p.backend === backend else { return }
            owner.routeExit(p, code: code, reason: reason)
        }
        syncPtySize(p)
    }

    /// Bytes on their way to a pane's screen: activity marks, the session log,
    /// keyword highlighting, the MFA watch.
    func writeToPane(_ p: SessionPane, _ data: Data) {
        PaneActivity.shared.noteOutput(p.id, bytes: data)
        watchForMfaFailure(p, data)
        guard let term = p.term else { return }
        guard let compiled = p.highlight else {
            if !p.pendingBytes.isEmpty { term.write(p.pendingBytes); p.pendingBytes = Data() }
            term.write(data)
            return
        }
        let (complete, rest) = SessionsCore.splitUTF8(p.pendingBytes + data)
        p.pendingBytes = rest
        let text = String(decoding: complete, as: UTF8.self)
        term.write(text: Highlight.chunk(text, compiled, &p.highlightState))
    }

    /// Keystrokes from a pane's terminal.
    func handleInput(_ paneId: String, _ data: Data) {
        guard let p = pane(paneId) else { return }
        // A console whose session has ended still takes one keystroke: the
        // one that opens it again.
        if p.kind == .device && !p.hasTerm {
            if p.reconnectArmed, data.contains(13) || data.contains(10) {
                p.reconnectArmed = false
                p.term?.writeln("")
                Task { await self.restartDevice(p) }
            }
            return
        }
        guard p.hasTerm else { return }
        if p.kind == .remote || p.kind == .local { noteTyped(p, data) }
        if broadcast && p.kind == .remote {
            for pid in panesOf(p.tabId) {
                if let o = pane(pid), o.hasTerm, o.kind == .remote { o.backend?.write(data) }
            }
            return
        }
        p.backend?.write(data)
    }

    /// Programmatically send text to a pane's shell (cd, startup commands).
    func sendToPane(_ p: SessionPane, _ text: String) {
        guard p.hasTerm else { return }
        p.backend?.write(Data(text.utf8))
    }

    func handleResize(_ paneId: String, _ cols: Int, _ rows: Int) {
        guard let p = pane(paneId), p.hasTerm else { return }
        p.backend?.resize(cols: cols, rows: rows)
    }

    /// Tell the pty how big the terminal is, now and once more after the next
    /// layout — a fit that lands before the pty exists is otherwise lost.
    func syncPtySize(_ p: SessionPane, again: Bool = true) {
        guard let t = p.term?.getTerminal() else { return }
        handleResize(p.id, t.cols, t.rows)
        if again {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.panes[p.id] != nil else { return }
                    self.syncPtySize(p, again: false)
                }
            }
        }
    }

    /// What has been typed on the current line, so a `cd` can be spotted as
    /// it is sent. Crude on purpose: it only ever adds a check.
    private func noteTyped(_ p: SessionPane, _ data: Data) {
        var line = typedLine[p.id] ?? ""
        for ch in String(decoding: data, as: UTF8.self) {
            if ch == "\r" || ch == "\n" || ch == "\r\n" {
                if SessionsCore.changesDirectory(line),
                   Store.shared.settingJSON("followTerminalFolder").bool != false, p.explorerVisible || !PaneAccessories.shared.hasProvider {
                    // After the shell has had a moment to actually move.
                    after(0.45) { [weak self] in
                        guard let self, let pane = self.pane(p.id), pane.tabId == self.activeTabId else { return }
                        SessionHooks.directoryChangeTyped.forEach { $0(pane) }
                        self.probeCwd(pane)
                    }
                }
                line = ""
            } else if ch == "\u{03}" || ch == "\u{15}" {
                line = ""
            } else if ch == "\u{7f}" || ch == "\u{08}" {
                if !line.isEmpty { line.removeLast() }
            } else if let s = ch.unicodeScalars.first, s.value >= 32 {
                line.append(ch)
            }
        }
        typedLine[p.id] = String(line.suffix(200))
    }

    /// Read a pane's directory from its process (never by typing `pwd`).
    /// A pane over tsh or a beam keeps the directory it started in: a probe
    /// there would cost another MFA prompt.
    func probeCwd(_ p: SessionPane) {
        guard p.hasTerm, let backend = p.backend else { return }
        if p.kind == .remote {
            guard SessConn.state(p.connId) == "connected" else { return }
            let tr = SessConn.transport(p.connId)
            if tr == "tsh" || tr == "beam" { return }
        } else if p.kind != .local { return }
        Task {
            guard let cwd = await backend.cwd(), !cwd.isEmpty, cwd != p.cwd else { return }
            p.cwd = cwd
            SessionHooks.cwdChanged.forEach { $0(p) }
            changed()
        }
    }

    // MARK: Endings

    /// A tsh session that exits without reaching a shell is watched for the
    /// MFA ceremony having been abandoned.
    private func watchForMfaFailure(_ p: SessionPane, _ data: Data) {
        guard p.kind == .remote, SessConn.transport(p.connId) == "tsh" else { return }
        p.mfaTail = String((p.mfaTail + String(decoding: data, as: UTF8.self)).suffix(1200))
        let t = p.mfaTail
        if t.range(of: "[$#%>]\\s$", options: .regularExpression) != nil
            || t.range(of: "Welcome to|Last login", options: [.regularExpression, .caseInsensitive]) != nil {
            p.mfaSucceeded = true
        }
    }

    /// The program in a pane finished.
    func routeExit(_ p: SessionPane, code: Int32?, reason: String?) {
        if let f = p.onExit { p.onExit = nil; f(code) }
        stopLog(p)
        p.backend = nil
        p.hasTerm = false
        p.status = "closed"
        let why = reason.map { " — \($0)" } ?? ((code ?? 0) != 0 ? " — exit \(code!)" : "")
        p.term?.writeln("\r\n\u{1b}[90m[session ended\(why)]\u{1b}[0m")
        if p.kind == .device { offerReconnect(p) }
        offerMfaAlternatives(p)
        changed()
    }

    /// A console that ended can be opened again under what it printed.
    func offerReconnect(_ p: SessionPane) {
        guard p.reconnect != nil else { return }
        p.term?.writeln("\u{1b}[90m[press Enter to reconnect]\u{1b}[0m")
        p.reconnectArmed = true
    }

    func restartDevice(_ p: SessionPane) async {
        guard let reopen = p.reconnect else { return }
        do {
            let b = try await reopen()
            p.reconnectArmed = false
            attach(p, b)
            p.term?.window?.makeFirstResponder(p.term)
            changed()
        } catch {
            p.status = "error"
            p.term?.writeln("\r\n\u{1b}[31m\(error.localizedDescription)\u{1b}[0m")
            offerReconnect(p)
        }
    }

    /// Stop whatever this pane was running.
    func endPaneSession(_ p: SessionPane) {
        stopLog(p)
        if let b = p.backend {
            p.backend = nil
            b.onData = nil
            b.onExit = nil
            b.close()
        }
        p.hasTerm = false
    }

    /// Close a pane and what runs in it. Unconditional: `requestClosePane`
    /// is the one that asks.
    func closePane(_ paneId: String) {
        guard let p = pane(paneId) else { return }
        let tabId = p.tabId
        SessionHooks.paneClosing.forEach { $0(p) }
        endPaneSession(p)
        let connId = p.connId
        p.disposeTerm()
        p.onClose?(); p.onClose = nil
        removePane(paneId)
        guard let t = tab(tabId), t.root != nil else {
            closeTab(tabId, skipPanes: true, extraConns: [connId].compactMap { $0 })
            return
        }
        releaseConnections([connId].compactMap { $0 })
        if let first = t.firstPane { setActivePane(first) }
        changed()
    }

    /// Close a tab. Its connection goes once nothing else uses it.
    func closeTab(_ tabId: String, skipPanes: Bool = false, extraConns: [String] = []) {
        guard let t = tab(tabId) else { return }
        var conns = extraConns
        if let c = t.connId { conns.append(c) }
        if !skipPanes {
            for pid in t.paneIds {
                guard let p = pane(pid) else { continue }
                SessionHooks.paneClosing.forEach { $0(p) }
                endPaneSession(p)
                if let c = p.connId { conns.append(c) }
                p.disposeTerm()
                p.onClose?(); p.onClose = nil
                PaneActivity.shared.forget(pid)
                panes.removeValue(forKey: pid)
            }
        }
        removeTab(tabId)
        releaseConnections(conns)
        focusActivePane()
    }

    /// Drop the connections no tab or pane in any window is using any more.
    func releaseConnections(_ ids: [String]) {
        for id in Set(ids) {
            let used = SessionsCore.allWindows().contains { w in
                w.tabs.contains { $0.connId == id } || w.panes.values.contains { $0.connId == id }
            }
            if !used {
                SessConn.disconnect(id)
                SessConnRecords.shared.remove(id)
            }
        }
    }

    // MARK: Focus

    /// Put the keyboard where the eye already is — after a deliberate switch.
    func focusActivePane() {
        guard let nsw = window?.nsWindow, nsw.attachedSheet == nil else { return }
        let id = activePaneId
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.pane(id), p.tabId == self.activeTabId, let t = p.term,
                      t.window != nil else { return }
                t.window?.makeFirstResponder(t)
            }
        }
    }

    // MARK: Session log

    /// Tee a remote terminal's output to a file (the connection's log API:
    /// escape sequences stripped, a header and a footer).
    func startLog(_ p: SessionPane, path: String) throws {
        guard let c = p.connId, let t = SessConn.termId(p.backend) else { throw AppError("No such terminal") }
        p.logPath = try SessConn.startLog(c, termId: t, path: path)
    }

    @discardableResult
    func stopLog(_ p: SessionPane) -> String? {
        guard p.logPath != nil else { return nil }
        p.logPath = nil
        guard let c = p.connId, let t = SessConn.termId(p.backend) else { return nil }
        return SessConn.stopLog(c, termId: t)
    }
}
