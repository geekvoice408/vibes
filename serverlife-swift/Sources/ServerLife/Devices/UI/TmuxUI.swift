import AppKit
import SwiftUI

/*
 * tmux sessions, shown as tabs and panes (tmux.js).
 *
 * The thing this buys is simple enough to say in one sentence: the work stops
 * belonging to the connection. Close the lid, lose the wifi, quit the app by
 * accident, and what was running on the server is still running on the
 * server, with its scrollback, waiting. Everything else in this file is in
 * service of making that not feel like a different application.
 *
 * tmux owns the layout. A window's arrangement is decided on the far side and
 * drawn here, and a split made in this window is a command sent there and a
 * new layout drawn when it comes back. Two authorities over one layout is how
 * two clients looking at the same session end up disagreeing about it.
 */

/// What a pane showing a tmux pane carries (`pane.tmuxId`, `tmuxPane`,
/// `tmuxHost`, `tmuxWindowName`), kept in `SessionPane.attachments["tmux"]`.
@MainActor
final class TmuxPaneInfo {
    let sessionId: String
    let pane: String
    var host: String
    var windowName: String
    init(sessionId: String, pane: String, host: String, windowName: String) {
        self.sessionId = sessionId
        self.pane = pane
        self.host = host
        self.windowName = windowName
    }
}

/// One attached session as this app shows it (`sessions` map in tmux.js):
/// which tab shows which tmux window, which pane shows which tmux pane.
@MainActor
final class TmuxRecord {
    let session: TmuxSession
    var id: String { session.id }
    /// The connection id, or `local` for this machine.
    let connId: String
    let host: Host
    /// So Reattach comes back as the same user.
    let login: String?
    var name: String
    let version: String?
    /// tmux window → tab id, in the order they were shown.
    var tabOrder: [String] = []
    var tabs: [String: String] = [:]
    /// What each window is called (`tab.tmuxName`).
    var windowNames: [String: String] = [:]
    /// tmux pane → pane id.
    var panes: [String: String] = [:]
    var trees: [String: TmuxLayout] = [:]
    let sizeTimer = Debouncer(0.12)
    var lastSize: String?
    var lastSelected: String?

    init(session: TmuxSession, connId: String, host: Host, login: String?, name: String, version: String?) {
        self.session = session
        self.connId = connId
        self.host = host
        self.login = login
        self.name = name
        self.version = version
    }

    var isLocal: Bool { connId == TmuxLocalHost.localId }
    var hostName: String { host.name.nilIfEmpty ?? host.alias ?? "" }

    func setTab(_ win: String, _ tabId: String) {
        if tabs[win] == nil { tabOrder.append(win) }
        tabs[win] = tabId
    }

    func removeTab(_ win: String) {
        tabs.removeValue(forKey: win)
        tabOrder.removeAll { $0 == win }
    }

    /// The tmux window a tab shows.
    func window(ofTab tabId: String) -> String? { tabs.first { $0.value == tabId }?.key }
}

@MainActor
enum ConsolesTmux {
    /// Attached sessions by id.
    static var records: [String: TmuxRecord] = [:]

    /// Whether tmux on this machine is offered at all (not on Windows; always here).
    static let localSupported = true

    // MARK: Lookups

    static func info(_ p: SessionPane?) -> TmuxPaneInfo? { p?.attachments["tmux"] as? TmuxPaneInfo }

    /// The session a pane belongs to (`tmuxSessionOf`).
    static func record(of p: SessionPane?) -> TmuxRecord? { info(p).flatMap { records[$0.sessionId] } }

    /// Whether this window still has a control client on the session.
    static func attached(_ sessionId: String?) -> Bool { sessionId.map { records[$0] != nil } ?? false }

    /// The pane a tmux pane id is showing in, if any.
    static func paneRecord(_ rec: TmuxRecord, _ tmuxPane: String) -> SessionPane? {
        guard let id = rec.panes[tmuxPane] else { return nil }
        return SessionsCore.owner(ofPane: id)?.pane(id)
    }

    /// The window holding a tab.
    static func owner(ofTab tabId: String) -> SessionsWindow? {
        SessionsCore.allWindows().first { $0.tab(tabId) != nil }
    }

    static func tab(_ tabId: String?) -> SessionTab? {
        guard let tabId else { return nil }
        return owner(ofTab: tabId)?.tab(tabId)
    }

    /// What a pane of a tmux window says in its header and on its tab.
    static func title(_ p: SessionPane, _ long: Bool) -> String? {
        guard let i = info(p) else { return nil }
        return ConsolesText.tmuxPaneTitle(window: i.windowName, host: i.host, pane: i.pane, long: long)
    }

    // MARK: Dialling

    /// This machine, or the connection a host's sessions ride.
    static func tmuxHost(_ connId: String) -> TmuxHost? {
        if connId == TmuxLocalHost.localId { return TimedTmuxHost(TmuxLocalHost.shared) }
        return ConnectionManager.shared.connection(connId).map { TimedTmuxHost($0) }
    }

    /// A connection id for a host: this machine's needs no dialling
    /// (`ensureConnection` otherwise — an open one is reused).
    static func dial(_ host: Host, login: String?, in s: SessionsWindow, created: ((String) -> Void)? = nil) async throws -> String {
        if host.isLocal { return TmuxLocalHost.localId }
        if let existing = SessConn.find(host: host, login: login) {
            if SessConnRecords.shared.get(existing) == nil {
                SessConnRecords.shared.set(SessConnRecord(id: existing, host: host, login: login, x11: nil))
            }
            created?(existing)
            if SessConn.state(existing) != "connected" { try await SessConn.connect(existing) }
            return existing
        }
        let id = try await s.createConnection(host, login: login)
        created?(id)
        try await SessConn.connect(id)
        return id
    }

    static func isMfaHost(_ host: Host) -> Bool {
        Store.shared.settingJSON("mfaHosts").stringArray.contains(host.id)
    }

    // MARK: Opening

    /*
     * Attach to a session on a host, creating it if it is not there.
     *
     * The probe happens first and its failure is the interesting one: a host
     * without tmux is the ordinary state of a machine nobody has set up, and
     * the useful answer names the one command that fixes it — and says that
     * nothing is needed on this machine.
     */
    @discardableResult
    static func open(_ host: Host, login: String?, session: String = "serverlife", window: WindowModel) async -> TmuxRecord? {
        let label = ConsolesText.hostLabel(host)
        let session = session.isEmpty ? "serverlife" : session
        /*
         * The last word on MFA hosts, for the paths that do not come through
         * the host menu — automation, a saved layout, a keyboard shortcut.
         */
        if isMfaHost(host) {
            StatusBus.shared.toast("\(label) asks for MFA per session — tmux is not available on it", kind: .error)
            return nil
        }
        let s = window.feature(SessionsWindow.self)
        /*
         * The tab comes first, before anything is dialled. Attaching is four
         * round trips — dial, ask whether tmux is there, attach, read back
         * what is on each pane — and on a node behind a Teleport proxy that is
         * twenty seconds. A click that appears to do nothing is a click people
         * make twice.
         */
        let (tab, pane) = s.openPendingTab(title: "tmux · \(label)")
        func alive() -> Bool { SessionsCore.owner(ofPane: pane.id) != nil }
        func owner() -> SessionsWindow { pane.owner ?? s }
        func step(_ text: String) { owner().noteOverlay(pane, text) }
        func fail(_ message: String) {
            var o = PaneOverlay(title: "Could not open tmux", sub: label, error: message, showLog: true)
            o.retry = {
                let w = owner()
                w.closePane(pane.id)
                Task { await ConsolesTmux.open(host, login: login, session: session, window: w.window ?? window) }
            }
            owner().showOverlay(pane, o)
            StatusBus.shared.clear()
        }

        s.showOverlay(pane, PaneOverlay(title: "Opening tmux on \(label)…", sub: "session “\(session)”", showLog: true))
        step("Connecting…")

        let connId: String
        do {
            /*
             * Once the pane knows its connection, the master's own output —
             * host key prompts, MFA, "connection established" — streams into
             * this overlay like any other session's.
             */
            connId = try await dial(host, login: login, in: s) { id in
                if id != TmuxLocalHost.localId { pane.connId = id }
            }
        } catch {
            if alive() { fail(error.localizedDescription) }
            return nil
        }
        guard alive() else { return nil }          // cancelled while dialling
        let local = connId == TmuxLocalHost.localId
        pane.connId = local ? nil : connId
        step(local ? "Looking for tmux on this machine…" : "Connected. Looking for tmux on the host…")

        guard let th = tmuxHost(connId) else { fail("That session is no longer open"); return nil }
        let probe = await TmuxService.shared.probe(th)
        guard alive() else { return nil }
        if !probe.ok {
            owner().closePane(pane.id)
            StatusBus.shared.clear()
            await explainMissingTmux(host, probe, window: window)
            return nil
        }
        step("tmux \(probe.version ?? "") is there\(probe.flowControl ? "" : " (no flow control below 3.2)").")
        step("Attaching to “\(session)”…")

        let attached: TmuxSession
        do {
            attached = try await TmuxService.shared.attach(th, session: session, cols: 120, rows: 34) { sess in
                wire(sess)
            }
        } catch {
            if alive() { fail(error.localizedDescription) }
            return nil
        }
        guard alive() else {
            // Cancelled while attaching: the session is real, so detach rather
            // than leave a control client nobody is watching.
            await TmuxService.shared.detach(attached.id)
            return nil
        }

        let rec = TmuxRecord(session: attached, connId: connId, host: host, login: login, name: session,
                             version: attached.version)
        records[rec.id] = rec

        let windows = attached.windowList()
        let paneCount = windows.reduce(0) { $0 + $1.panes.count }
        step(ConsolesText.attachedNote(windows: windows.count, panes: paneCount))

        /*
         * The pane that has been showing the progress becomes the session's
         * first pane, rather than being thrown away and replaced — so the tab
         * does not blink, and the overlay is lifted off something that is
         * already the right pane.
         */
        if let first = windows.first, let firstPane = first.panes.first {
            let name = first.name.nilIfEmpty ?? "tmux"
            rec.windowNames[first.id] = name
            tab.tmux = true
            // The tab's stored title too: automation and saved layouts read it.
            tab.title = "\(name) \u{00b7} \(label)"
            if let tree = first.tree { rec.trees[first.id] = tree }
            bindPane(rec, pane, firstPane, first.name)
            rec.setTab(first.id, tab.id)
            owner().applyTmuxLayout(tabId: tab.id, tree: ConsolesText.node(first.tree),
                                    bind: { p, tp in bindPane(rec, p, tp, first.name) },
                                    paneFor: { tp in paneRecord(rec, tp) })
            owner().hideOverlay(pane)
            for p in first.panes { prime(rec, p) }
        } else {
            owner().hideOverlay(pane)
        }

        // Any further windows get tabs of their own.
        showWindows(rec, Array(windows.dropFirst()), in: owner())
        sendSize(rec)
        StatusBus.shared.show("tmux \(attached.version ?? "") on \(label) — \(ConsolesText.plural(windows.count, "window"))")
        return rec
    }

    /// The session's events, routed to the record once there is one.
    private static func wire(_ sess: TmuxSession) {
        let id = sess.id
        sess.onLayout = { win, _, tree in routeLayout(id, win, tree) }
        sess.onWindows = { list in routeWindows(id, list) }
        sess.onPause = { pane, paused in routePause(id, pane, paused) }
        sess.onEnded = { reason, alive in routeEnded(id, reason: reason, alive: alive) }
    }

    /*
     * What to say when the host has no tmux. Worth a dialog rather than a
     * toast: it is the one failure here that the person can do something
     * about, and the something is a single command they will want to copy.
     */
    static func explainMissingTmux(_ host: Host, _ probe: TmuxProbe, window: WindowModel?) async {
        let local = host.isLocal
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let h = Modal.sheet(window, title: local ? "This machine has no tmux" : "This host has no tmux", width: 520) { handle in
                MissingTmuxView(local: local, probe: probe) { handle.close() }
            }
            h.onClose.append { cont.resume() }
        }
    }

    /// One tab per tmux window, each laid out the way tmux says.
    static func showWindows(_ rec: TmuxRecord, _ windows: [TmuxWindow], in s: SessionsWindow) {
        for w in windows {
            if rec.tabs[w.id] != nil { continue }
            /*
             * Not until its layout is known. tmux announces a new window with
             * only its id, and the list that follows a moment later is the one
             * with its panes. A tab built from the announcement was a pane
             * bound to nothing, and since the window then had a tab, the real
             * layout arriving next was skipped.
             */
            guard let tree = w.tree else { continue }
            let name = w.name.nilIfEmpty ?? "tmux"
            rec.windowNames[w.id] = name
            rec.trees[w.id] = tree
            let tab = s.openTmuxWindow(title: "\(name) · \(rec.hostName)", tree: ConsolesText.node(tree),
                                       bind: { p, tp in bindPane(rec, p, tp, w.name) })
            rec.setTab(w.id, tab.id)
            for p in w.panes { prime(rec, p) }
        }
        sendSize(rec)
    }

    static func bindPane(_ rec: TmuxRecord, _ p: SessionPane, _ tmuxPane: String, _ windowName: String?) {
        let previous = info(p)?.windowName
        p.kind = .tmux
        p.attachments["tmux"] = TmuxPaneInfo(sessionId: rec.id, pane: tmuxPane, host: rec.hostName,
                                             windowName: windowName?.nilIfEmpty ?? previous ?? "tmux")
        /*
         * The connection the control stream rides is a connection like any
         * other, so the pane carries it: the file browser reads the server's
         * files, the network tools run from the host, and the highlight rules
         * are the ones set for it.
         */
        p.connId = rec.isLocal ? nil : rec.connId
        if rec.isLocal { p.host = Host.localMachine }
        p.titleProvider = { pane, long in ConsolesTmux.title(pane, long) }
        p.titleRevision += 1
        rec.panes[tmuxPane] = p.id
        let backend = rec.session.backend(for: tmuxPane)
        backend.onResize = { [weak rec] _, _ in if let rec { sendSize(rec) } }
        let s = p.owner ?? SessionsCore.owner(ofPane: p.id)
        s?.attach(p, backend)
        p.applyHighlightSettings()
        /*
         * One file browser per session. Every pane in a tmux session is on the
         * same host, so a second browser shows the same server again and takes
         * half of the new pane to do it. So a new pane opens without one while
         * any pane of the session, on any of its tabs, already shows one.
         */
        if p.explorerVisible, let s {
            let others = Array(rec.panes.values) + s.panesOf(p.tabId)
            let another = others.contains { id in
                id != p.id && (SessionsCore.owner(ofPane: id)?.pane(id)?.explorerVisible ?? false)
            }
            if another { s.setExplorerVisible(p, false) }
        }
    }

    /*
     * Fill a pane with what is already on that tmux pane's screen. Without
     * this a reattached session is a wall of blank panes until something next
     * prints — the difference between "it reconnected" and "my work is back".
     */
    static func prime(_ rec: TmuxRecord, _ tmuxPane: String) {
        Task {
            guard paneRecord(rec, tmuxPane) != nil,
                  let text = try? await rec.session.capture(tmuxPane, lines: 2000),
                  let out = ConsolesText.primeText(text),
                  let p = paneRecord(rec, tmuxPane), let owner = p.owner else { return }
            owner.writeToPane(p, Data(out.utf8))
        }
    }

    // MARK: Sizing

    /*
     * Tell tmux how big this client is. tmux sizes a window to its smallest
     * attached client, and there is no per-pane resize a control client may
     * ask for — so the only lever is the size of the whole client. Debounced,
     * because dragging a divider produces a resize per frame.
     */
    static func sendSize(_ rec: TmuxRecord) {
        rec.sizeTimer.call { [weak rec] in
            guard let rec, records[rec.id] != nil, let size = clientSize(rec) else { return }
            let key = "\(size.cols)x\(size.rows)"
            if rec.lastSize == key { return }
            rec.lastSize = key
            Task { await rec.session.resize(cols: size.cols, rows: size.rows) }
        }
    }

    /*
     * Measured over tmux's own layout rather than the tab's, because a tab can
     * also hold panes tmux knows nothing about — another server split in
     * beside it. Counting those would make every line wrap one column early.
     */
    static func clientSize(_ rec: TmuxRecord) -> (cols: Int, rows: Int)? {
        guard let win = activeWindow(rec), let tree = rec.trees[win] else { return nil }
        return ConsolesText.clientSize(tree) { tp in
            guard let b = paneRecord(rec, tp)?.backend as? TmuxPaneBackend else { return (0, 0) }
            return (b.cols, b.rows)
        }
    }

    static func activeWindow(_ rec: TmuxRecord) -> String? {
        for s in SessionsCore.allWindows() {
            if let t = s.activeTabId, let w = rec.window(ofTab: t) { return w }
        }
        return rec.tabOrder.first
    }

    // MARK: Events from the far side

    static func routeLayout(_ id: String, _ win: String, _ tree: TmuxLayout?) {
        guard let rec = records[id], let tree else { return }
        rec.trees[win] = tree
        guard let tabId = rec.tabs[win], let s = owner(ofTab: tabId) else { return }
        s.applyTmuxLayout(tabId: tabId, tree: ConsolesText.node(tree),
                          bind: { p, tp in
                              bindPane(rec, p, tp, rec.windowNames[win])
                              prime(rec, tp)
                          },
                          paneFor: { tp in paneRecord(rec, tp) })
        // Panes that have gone take their mapping with them.
        for (tp, paneId) in rec.panes where SessionsCore.owner(ofPane: paneId) == nil {
            rec.panes.removeValue(forKey: tp)
        }
        sendSize(rec)
    }

    static func routeWindows(_ id: String, _ windows: [TmuxWindow]) {
        guard let rec = records[id] else { return }
        let home = rec.tabs.values.compactMap { owner(ofTab: $0) }.first ?? SessionsCore.allWindows().first
        if let home { showWindows(rec, windows, in: home) }
        /*
         * A window is renamed by whatever is running in it — the shell sets it
         * to the command — so the tab follows rather than keeping the name it
         * had when it was opened.
         */
        for w in windows {
            guard let tabId = rec.tabs[w.id], let s = owner(ofTab: tabId), let tab = s.tab(tabId) else { continue }
            let name = w.name.nilIfEmpty ?? "tmux"
            if rec.windowNames[w.id] == w.name { continue }
            rec.windowNames[w.id] = name
            tab.title = "\(name) \u{00b7} \(rec.hostName)"
            for pid in s.panesOf(tabId) {
                guard let p = s.pane(pid), let i = info(p) else { continue }
                i.windowName = name
                p.titleRevision += 1
            }
        }
        // A window closed on the far side closes the tab that was showing it.
        let live = Set(windows.map(\.id))
        for win in rec.tabOrder where !live.contains(win) {
            guard let tabId = rec.tabs[win] else { continue }
            rec.removeTab(win)
            owner(ofTab: tabId)?.closeTab(tabId)
        }
    }

    static func routePause(_ id: String, _ tmuxPane: String, _ paused: Bool) {
        guard let rec = records[id], let p = paneRecord(rec, tmuxPane) else { return }
        // Flow control is tmux protecting the client from a flood. Saying so
        // beats a pane that has silently stopped moving.
        p.term?.writeln(paused
            ? "\r\n\u{1b}[33m[tmux paused this pane — it was producing output faster than this window could take it]\u{1b}[0m"
            : "\u{1b}[90m[resumed]\u{1b}[0m")
        // tmux holds a paused pane until the client asks it to carry on.
        if paused { Task { await rec.session.continuePane(tmuxPane) } }
    }

    /*
     * This window is no longer attached to a session — and whether the
     * session is still there (`alive`: true, false, or nil when the
     * connection went with it).
     *
     * Every pane is made to look like what it now is: its tmux menu gone,
     * "ended" or "detached" in its title bar and on its tab, and on the first
     * pane of each tab a notice saying which, with Reattach only when there
     * is something to reattach to. The terminal text is left behind the
     * notice, so the last thing on screen can still be read and copied.
     */
    static func routeEnded(_ id: String, reason: String?, alive: Bool?) {
        guard let rec = records.removeValue(forKey: id) else { return }
        let host = rec.host.name.nilIfEmpty ?? rec.host.alias ?? "the host"
        let e = ConsolesText.ended(name: rec.name, host: host, reason: reason, alive: alive)
        for win in rec.tabOrder {
            guard let tabId = rec.tabs[win], let s = owner(ofTab: tabId) else { continue }
            if let tab = s.tab(tabId) {
                tab.tmuxEnded = e.word
                tab.title = "\(rec.windowNames[win] ?? "tmux") · \(host) — \(e.word)"
            }
            var first = true
            for pid in s.panesOf(tabId) {
                guard let p = s.pane(pid), info(p)?.sessionId == id else { continue }
                p.tmuxEnded = e.word
                let b = p.backend as? TmuxPaneBackend
                s.endPaneSession(p)
                b?.finish(reason: e.word)
                p.status = "closed"
                p.titleRevision += 1
                p.term?.writeln(ConsolesText.endedLine(title: e.title, sub: e.sub))
                if first {
                    first = false
                    var o = PaneOverlay(title: e.title, sub: e.sub,
                                        error: alive == false ? "This pane shows what was on screen when it ended." : nil)
                    if alive != false {
                        o.alt = .init(label: "Reattach") { [weak s] in
                            guard let s else { return }
                            s.closeTab(tabId)
                            if let w = s.window {
                                Task { await ConsolesTmux.open(rec.host, login: rec.login, session: rec.name, window: w) }
                            }
                        }
                    }
                    s.showOverlay(p, o)
                }
            }
            s.changed()
        }
        PaneHeaderItems.shared.revision += 1
        StatusBus.shared.show("\(e.title) — \(e.sub)")
    }

    /// A pane closed in this window: stop routing to it, leave the session alone.
    static func forget(_ p: SessionPane) {
        guard let i = info(p), let rec = records[i.sessionId] else { return }
        rec.panes.removeValue(forKey: i.pane)
        /*
         * The last pane closing means nothing is looking at this session any
         * more, so the control client detaches — and the session carries on
         * running on the server, which is the entire point. Killing it here
         * would turn closing a tab into losing the work.
         */
        let anyLeft = rec.panes.values.contains { $0 != p.id && SessionsCore.owner(ofPane: $0) != nil }
        if anyLeft { return }
        records.removeValue(forKey: rec.id)
        Task { await TmuxService.shared.detach(rec.id) }
    }

    // MARK: Commands from this side

    static func send(_ p: SessionPane, _ cmd: String) async {
        guard let rec = record(of: p) else {
            StatusBus.shared.toast("This pane is no longer attached to tmux", kind: .error)
            return
        }
        do { try await rec.session.command(cmd) } catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
    }

    /// Split the tmux pane this pane is showing, and let tmux say what happened.
    static func split(_ p: SessionPane, _ dir: PaneSplit.Dir) {
        guard let rec = record(of: p), let i = info(p) else {
            let msg = p.tmuxEnded.map { "This tmux session has \($0 == "ended" ? "ended" : "been left") \u{2014} nothing to split" }
                ?? "Not attached to tmux"
            StatusBus.shared.toast(msg, kind: .error)
            return
        }
        // tmux's -h is a vertical divider (side by side); ours is called 'row'.
        let flag = dir == .row ? "-h" : "-v"
        Task {
            do { try await rec.session.command("split-window \(flag) -t \(i.pane)") }
            catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
        }
    }

    static func newWindow(_ p: SessionPane) {
        guard let rec = record(of: p) else { return }
        Task {
            do { try await rec.session.command("new-window") }
            catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
        }
    }

    /// Leave it running on the server.
    static func detach(_ sessionId: String) async {
        guard records[sessionId] != nil else { return }
        await TmuxService.shared.detach(sessionId)
        StatusBus.shared.show("Detached — the session is still running on the server")
    }

    /// End it for good, which is the only action here that destroys work.
    static func kill(_ sessionId: String, window: WindowModel?) async {
        guard let rec = records[sessionId] else { return }
        let ok = await MiscUI.confirm(window, title: "End this tmux session?",
                                      message: "Everything running in “\(rec.name)” on \(ConsolesText.hostLabel(rec.host, "")) will be killed.",
                                      detail: "Detaching instead leaves it running, which is what makes the session worth having.",
                                      confirmLabel: "End the session", danger: true)
        guard ok else { return }
        await TmuxService.shared.kill(sessionId)
    }

    /*
     * Rename the session. The name is how you find it again — from this app,
     * from `tmux ls` on the host, from a colleague's terminal — and a session
     * called `serverlife` on four machines tells you nothing; one called
     * `db-migration` tells you not to kill it.
     */
    static func renameSession(_ sessionId: String, window: WindowModel?) async {
        guard let rec = records[sessionId] else { return }
        let hostName = rec.host.name.nilIfEmpty ?? rec.host.alias ?? "the host"
        guard let next = await MiscUI.prompt(window, title: "Rename this tmux session", label: "On \(hostName)",
                                             value: rec.name, confirmLabel: "Rename",
                                             validate: { ConsolesText.validateSessionName($0) }) else { return }
        let name = next.trimmed
        if name.isEmpty || name == rec.name { return }
        do {
            try await rec.session.command("rename-session -t \(shellQuote(rec.name)) \(shellQuote(name))")
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
            return
        }
        rec.name = name
        /*
         * The host now opens this one. Without that, "Open session" would go
         * on using the name it had before and start a *second* session beside
         * the renamed one — which is how a session someone named because it
         * mattered becomes a session they cannot find.
         */
        let key = rec.host.prefKey
        var pinned = false
        if !key.isEmpty, Store.shared.settingJSON("tmuxSessionNames")[key].string != name {
            Store.shared.mutateSetting("tmuxSessionNames") { $0[key] = .string(name) }
            pinned = true
        }
        let who = rec.host.name.nilIfEmpty ?? rec.host.alias ?? ""
        StatusBus.shared.show(pinned ? "Renamed to “\(name)” — \(who) now opens this session" : "Renamed to “\(name)”")
        refreshTitles(rec)
    }

    /*
     * Rename the window this pane is in — which is what the tab is called.
     * tmux names a window after whatever is running in it; naming one by hand
     * stops that for that window, which is the point.
     */
    static func renameWindow(_ p: SessionPane, window: WindowModel?) async {
        guard let rec = record(of: p), let win = rec.window(ofTab: p.tabId) else { return }
        guard let next = await MiscUI.prompt(window, title: "Rename this window", label: "What the tab is called",
                                             value: rec.windowNames[win] ?? "", confirmLabel: "Rename") else { return }
        do {
            try await rec.session.command("rename-window -t \(win) \(shellQuote(next.trimmed.nilIfEmpty ?? "window"))")
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
        }
    }

    static func refreshTitles(_ rec: TmuxRecord) {
        for id in rec.panes.values { SessionsCore.owner(ofPane: id)?.pane(id)?.titleRevision += 1 }
    }

    /*
     * Keep tmux's idea of the active pane in step with the focused one. A
     * control client that never says which pane it is looking at leaves
     * "the current pane" pointing at whatever was active when it attached,
     * and everything that defaults to it then goes to the wrong place.
     */
    static func followFocus(_ p: SessionPane?) {
        guard let p, let i = info(p), let rec = records[i.sessionId] else { return }
        if rec.lastSelected == i.pane { return }
        rec.lastSelected = i.pane
        Task {
            _ = try? await rec.session.command("select-pane -t \(i.pane)")
            /*
             * Where that pane's shell actually is, so the file browser can
             * follow the terminal as it does on an ordinary session. Asked on
             * focus rather than polled: every question is a command round trip.
             */
            guard let lines = try? await rec.session.command("display-message -p -t \(i.pane) '#{pane_current_path}'"),
                  let dir = lines.first?.trimmed, !dir.isEmpty, p.cwd != dir else { return }
            p.cwd = dir
            SessionHooks.cwdChanged.forEach { $0(p) }
        }
    }

    /// Watch each window's focused pane for `followFocus`.
    static func observeFocus(_ s: SessionsWindow) {
        withObservationTracking {
            _ = s.activePaneId
        } onChange: { [weak s] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let s, s.window != nil else { return }
                    followFocus(s.activePane)
                    observeFocus(s)
                }
            }
        }
    }
}

/// "This host has no tmux": the reason, what to do about it, and the one
/// command, in a box it can be copied from.
struct MissingTmuxView: View {
    let local: Bool
    let probe: TmuxProbe
    let close: () -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: local ? "This machine has no tmux" : "This host has no tmux", width: 520, scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(probe.reason ?? "tmux is not installed there.")
                    .font(.system(size: 13)).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
                MiscHint(text: local
                    ? "Install it here, then open tmux again. Sessions on a server need it on the server instead, never here."
                    : "Only the server needs it — nothing is installed on this machine. ServerLife speaks tmux’s control protocol itself, over the connection that is already open.",
                    size: 11.5)
                    .padding(.bottom, 10)
                Text(probe.install ?? "apt install tmux")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
            }
        } footer: {
            Button("Close") { close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

/// A tmux host whose checks give up when the original's did (tmuxctl.js
/// probe and `list-sessions` 15 s; main.js `has-session` 10 s), so a dropped
/// connection is reported as lost after ten seconds rather than twenty.
/// Everything else is passed straight through.
@MainActor
final class TimedTmuxHost: TmuxHost {
    let base: TmuxHost
    init(_ base: TmuxHost) { self.base = base }

    nonisolated static func timeout(for cmd: String) -> TimeInterval { cmd.contains("has-session") ? 10 : 15 }

    var transportKind: String { base.transportKind }

    func execResult(_ cmd: String) async -> ProcResult {
        let t = TimedTmuxHost.timeout(for: cmd)
        if let c = base as? Connection { return await c.execResult(cmd, timeout: t) }
        if let l = base as? TmuxLocalHost { return await l.execResult(cmd, timeout: t) }
        return await base.execResult(cmd)
    }

    func spawnCommandPTY(_ cmd: String, cols: Int, rows: Int) throws -> PTYProcess {
        try base.spawnCommandPTY(cmd, cols: cols, rows: rows)
    }

    func spawnCommandChannel(_ cmd: String) throws -> ByteChannel { try base.spawnCommandChannel(cmd) }
}
