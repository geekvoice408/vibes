import AppKit
import SwiftUI

/// What a split can be asked for (`splitActivePane` options).
struct SplitOptions {
    var host: Host?
    var login: String?
    var transport: String?
    var local = false
    var filesOnly = false
    var cwd: String?
    var shell: String?
    var blank = false
    var remoteStartPath: String?
}

/// tmux's description of a window, for `openTmuxWindow` / `applyTmuxLayout`:
/// `[` is a column of panes and `{` a row.
indirect enum TmuxLayoutNode {
    case pane(String)
    case split(PaneSplit.Dir, [TmuxLayoutNode])
}

extension SessionsWindow {
    // MARK: Splitting

    /// Split the focused pane. With no host the new pane joins the same
    /// server; with one, a different machine goes beside the current one.
    @discardableResult
    func splitActivePane(_ dir: PaneSplit.Dir, _ o: SplitOptions = SplitOptions()) async -> SessionPane? {
        let cur = activePane
        // On a tmux pane a plain split is tmux's: a new pane in the session.
        if let cur, cur.kind == .tmux, o.host == nil, !o.local, let split = SessionsTmux.split, split(cur, dir) { return nil }
        guard let cur, let t = tab(cur.tabId) else {
            if let h = o.host {
                var oo = OpenHostOptions(); oo.login = o.login; oo.filesOnly = o.filesOnly
                return await openHost(h, oo)
            }
            if o.local { return openLocalShell(cwd: o.cwd, shell: o.shell, blank: o.blank) }
            return nil
        }
        var kind: PaneKind = cur.kind
        var connId = cur.connId
        if o.local || cur.kind == .device || cur.kind == .view || cur.kind == .tmux {
            kind = .local; connId = nil
        }
        if let h = o.host {
            do { connId = try await createConnection(h, login: o.login, transport: o.transport) }
            catch { StatusBus.shared.toast(error.localizedDescription, kind: .error); return nil }
            kind = .remote
        }
        let np = createPane(tabId: t.id, kind: kind, connId: connId, cwd: cur.cwd)
        t.root = PaneTree.splitting(t.root, at: cur.id, adding: np.id, dir: dir)
        setActivePane(np.id)
        changed()

        let filesOnly = o.filesOnly && np.kind == .remote
        if filesOnly {
            np.filesOnly = true
            np.explorerVisible = true
        } else if let h = o.host {
            applyOpensWithFiles(np, h)
        }

        if np.kind == .local {
            // A caller that knows where it should start (a layout) says so;
            // a plain split inherits from the pane it came from.
            startLocalTerm(np, cwd: o.cwd ?? cur.cwd, shell: o.shell, blank: o.blank)
        } else if SessConn.state(np.connId) == "connected" {
            if !filesOnly {
                do {
                    try await startRemoteTerm(np)
                    if let rs = o.remoteStartPath { sendToPane(np, "cd \(SessionsWindow.jsonQuote(rs))\n") }
                    np.status = "connected"
                } catch {
                    np.status = "error"
                    np.term?.writeln("\u{1b}[31m\(error.localizedDescription)\u{1b}[0m")
                }
            } else {
                np.status = "connected"
            }
        } else {
            Task { await connectPane(np, remoteStartPath: o.remoteStartPath, noTerminal: filesOnly) }
        }
        changed()
        return np
    }

    /// Choose a host, then split the focused pane with it.
    func pickHostForSplit(_ dir: PaneSplit.Dir) {
        let title = dir == .row ? "Split right with…" : "Split down with…"
        let done: ([String: Any]?) -> Void = { [weak self] choice in
            guard let self, let choice else { return }
            Task {
                if (choice["kind"] as? String) == "local" {
                    await self.splitActivePane(dir, SplitOptions(local: true))
                } else if let h = choice["host"] as? Host {
                    await self.splitActivePane(dir, SplitOptions(host: h, login: choice["login"] as? String))
                }
            }
        }
        if Actions.shared.isRegistered("pick-host") {
            Actions.shared.perform("pick-host", window: window, args: ["title": title, "includeLocal": true, "completion": done])
            return
        }
        Task {
            let r = await Modal.choose(window, title: title, message: "The host picker is not available in this build yet.",
                                       buttons: ["Local shell", "Cancel"])
            if r == 0 { done(["kind": "local"]) }
        }
    }

    // MARK: Moving

    /// Move the focused pane one place: swap with the pane a human would call
    /// "the next one that way", or lay it along the edge when there is none.
    @discardableResult
    func movePane(_ dir: String, _ paneId: String? = nil) -> Bool {
        guard let p = pane(paneId ?? activePaneId), let t = tab(p.tabId), t.root != nil else { return false }
        let others = t.paneIds.filter { $0 != p.id }.compactMap { pane($0) }
        if others.isEmpty { return false }
        if let target = nearestPane(p, others, dir) {
            t.root = PaneTree.swapping(t.root, p.id, target.id)
        } else {
            let moved = PaneTree.movingToEdge(t.root, p.id, dir)
            if moved == t.root { return false }
            t.root = PaneTree.clearingWeights(moved)
        }
        setActivePane(p.id)
        changed()
        focusActivePane()
        return true
    }

    private func nearestPane(_ p: SessionPane, _ others: [SessionPane], _ dir: String) -> SessionPane? {
        let r = p.frame
        let horizontal = dir == "left" || dir == "right"
        let back = dir == "left" || dir == "up"
        var best: SessionPane?
        var bestGap = CGFloat.infinity
        for o in others {
            let f = o.frame
            let overlap = horizontal ? min(r.maxY, f.maxY) - max(r.minY, f.minY) : min(r.maxX, f.maxX) - max(r.minX, f.minX)
            if overlap <= 1 { continue }
            let gap = horizontal ? (back ? r.minX - f.maxX : f.minX - r.maxX) : (back ? r.minY - f.maxY : f.minY - r.maxY)
            if gap < -1 { continue }
            if gap < bestGap { bestGap = gap; best = o }
        }
        return best
    }

    /// Swap two panes' places in their tab.
    @discardableResult
    func swapPanes(_ a: String, _ b: String) -> Bool {
        guard let pa = pane(a), let pb = pane(b), a != b, pa.tabId == pb.tabId, let t = tab(pa.tabId) else { return false }
        t.root = PaneTree.swapping(t.root, a, b)
        changed()
        return true
    }

    /// Give a pane a tab of its own. Nothing is reconnected.
    @discardableResult
    func movePaneToNewTab(_ paneId: String? = nil) -> Bool {
        guard let p = pane(paneId ?? activePaneId), let from = tab(p.tabId) else { return false }
        if from.paneIds.count < 2 {
            StatusBus.shared.show("That pane already has a tab to itself")
            return false
        }
        detachPane(p.id)
        from.root = PaneTree.clearingWeights(from.root)
        let title = SessConnRecords.shared.label(p.connId) ?? p.title ?? (p.kind == .local ? "Local shell" : "Session")
        let t = createTab(title: title, kind: p.kind == .local ? "local" : p.kind.rawValue, connId: p.connId)
        p.tabId = t.id
        t.root = .pane(p.id)
        activeTabId = t.id
        setActivePane(p.id)
        changed()
        focusActivePane()
        return true
    }

    /// Move a pane into another tab, beside whatever is there.
    @discardableResult
    func movePaneToTab(_ paneId: String, _ tabId: String, dir: PaneSplit.Dir = .row) -> Bool {
        guard let p = pane(paneId), let t = tab(tabId), p.tabId != tabId else { return false }
        let from = tab(p.tabId)
        detachPane(paneId)
        from?.root = PaneTree.clearingWeights(from?.root)
        p.tabId = tabId
        if let host = t.firstPane {
            t.root = PaneTree.clearingWeights(PaneTree.splitting(t.root, at: host, adding: paneId, dir: dir))
        } else {
            t.root = .pane(paneId)
        }
        // A tab emptied by the move has nothing left to draw.
        if let from, from.id != tabId, from.paneIds.isEmpty { closeTab(from.id, skipPanes: true) }
        activeTabId = tabId
        setActivePane(paneId)
        changed()
        focusActivePane()
        return true
    }

    /// Move a pane into a window of its own. The session is not restarted and
    /// nothing reconnects: the pane object itself moves, terminal and all.
    @discardableResult
    func popPaneToWindow(_ paneId: String? = nil) -> Bool {
        guard let p = pane(paneId ?? activePaneId) else { return false }
        if p.isHosts { StatusBus.shared.show("A hosts pane belongs to its window"); return false }
        if !p.hasTerm && p.kind != .view { StatusBus.shared.show("That pane has nothing running in it yet"); return false }
        guard let t = tab(p.tabId) else { return false }
        let alone = t.paneIds.count < 2
        // Let go of it here without closing anything.
        // The new window takes the pane before anything here is released, so
        // its connection is never seen unused in between.
        PaneActivity.shared.forget(p.id)
        detachPane(p.id)
        panes.removeValue(forKey: p.id)
        if activePaneId == p.id { activePaneId = t.firstPane }
        WindowManager.shared.open(options: ["adopt": p])
        if alone { closeTab(t.id, skipPanes: true) } else { t.root = PaneTree.clearingWeights(t.root) }
        changed()
        return true
    }

    /// The other side of it: a window started to receive a pane.
    func adoptPane(_ p: SessionPane) {
        let title = SessConnRecords.shared.label(p.connId) ?? p.title ?? (p.kind == .local ? "Local shell" : "Session")
        let t = createTab(title: title, kind: p.kind == .local ? "local" : p.kind.rawValue, connId: p.connId)
        p.tabId = t.id
        panes[p.id] = p
        p.owner = self
        wireTerm(p)
        t.root = .pane(p.id)
        activeTabId = t.id
        setActivePane(p.id)
        changed()
        // The pty is still sized for the window it came from.
        after(0.1) { [weak self] in
            self?.syncPtySize(p)
            self?.focusActivePane()
        }
    }

    func duplicateActiveTab() async {
        guard let p = activePane else { return }
        if p.kind == .local {
            openLocalShell(cwd: p.cwd)
            return
        }
        guard p.kind == .remote, let connId = p.connId, SessConn.exists(connId) || SessConnRecords.shared.get(connId) != nil else { return }
        let t = createTab(title: SessConnRecords.shared.label(connId) ?? "", kind: "remote", connId: connId)
        let np = createPane(tabId: t.id, kind: .remote, connId: connId)
        t.root = .pane(np.id)
        activeTabId = t.id
        setActivePane(np.id)
        changed()
        if SessConn.state(connId) == "connected" {
            do { try await startRemoteTerm(np) } catch { np.term?.writeln("\u{1b}[31m\(error.localizedDescription)\u{1b}[0m") }
        } else {
            await connectPane(np)
        }
    }

    // MARK: tmux (for consoles)

    /// A tab with one empty pane, for a session that is still being opened;
    /// the waiting happens inside it, with the usual overlay and Cancel.
    func openPendingTab(title: String?) -> (tab: SessionTab, pane: SessionPane) {
        let t = createTab(title: title ?? "tmux", kind: "local", connId: nil)
        let p = createPane(tabId: t.id, kind: .tmux, connId: nil)
        t.root = .pane(p.id)
        activeTabId = t.id
        setActivePane(p.id)
        changed()
        return (t, p)
    }

    /// A tab whose panes are the panes of a tmux window, shaped as tmux says.
    @discardableResult
    func openTmuxWindow(title: String?, tree: TmuxLayoutNode?, bind: (SessionPane, String) -> Void) -> SessionTab {
        let t = createTab(title: title ?? "tmux", kind: "local", connId: nil)
        t.tmux = true
        t.root = buildTmux(t.id, tree, bind: bind, paneFor: { _ in nil }) ?? .pane(createPane(tabId: t.id, kind: .tmux, connId: nil).id)
        activeTabId = t.id
        if let f = t.firstPane { setActivePane(f) }
        changed()
        return t
    }

    private func buildTmux(_ tabId: String, _ node: TmuxLayoutNode?, bind: (SessionPane, String) -> Void,
                           paneFor: (String) -> SessionPane?) -> PaneNode? {
        guard let node else { return nil }
        switch node {
        case .pane(let tp):
            if let existing = paneFor(tp), panes[existing.id] != nil { return .pane(existing.id) }
            let p = createPane(tabId: tabId, kind: .tmux, connId: nil)
            bind(p, tp)
            return .pane(p.id)
        case .split(let dir, let kids):
            let built = kids.compactMap { buildTmux(tabId, $0, bind: bind, paneFor: paneFor) }
            if built.isEmpty { return nil }
            if built.count == 1 { return built[0] }
            return .split(PaneSplit(dir: dir, children: built))
        }
    }

    /// Re-shape an open tmux tab to a layout that changed on the server.
    /// Panes still there keep their terminal; panes tmux knows nothing about
    /// stay exactly where the user put them.
    @discardableResult
    func applyTmuxLayout(tabId: String, tree: TmuxLayoutNode?, bind: (SessionPane, String) -> Void,
                         paneFor: (String) -> SessionPane?) -> PaneNode? {
        guard let t = tab(tabId), let tmuxRoot = buildTmux(tabId, tree, bind: bind, paneFor: paneFor) else { return nil }
        var placed = false
        func splice(_ n: PaneNode?) -> PaneNode? {
            guard let n else { return nil }
            switch n {
            case .pane(let id):
                if pane(id)?.kind != .tmux { return n }
                if placed { return nil }
                placed = true
                return tmuxRoot
            case .split(var s):
                let kids = s.children.compactMap { splice($0) }
                if kids.isEmpty { return nil }
                if kids.count == 1 { return kids[0] }
                s.children = kids
                return .split(s)
            }
        }
        var root = splice(t.root)
        if !placed { root = root.map { .split(PaneSplit(dir: .row, children: [tmuxRoot, $0])) } ?? tmuxRoot }
        let kept = Set(root?.paneIds ?? [])
        for id in panes.values.filter({ $0.tabId == tabId }).map(\.id) where !kept.contains(id) {
            guard let p = pane(id), p.kind == .tmux else { continue }
            SessionHooks.paneClosing.forEach { $0(p) }
            p.disposeTerm()
            PaneActivity.shared.forget(id)
            panes.removeValue(forKey: id)
        }
        t.root = PaneTree.clearingWeights(root)
        if pane(activePaneId) == nil, let f = t.firstPane { setActivePane(f) }
        changed()
        return root
    }
}

/// Hooks the tmux UI (consoles) sets so Sessions can hand tmux what is
/// tmux's to do.
@MainActor
enum SessionsTmux {
    /// A plain split on a tmux pane: return true when tmux took it.
    static var split: ((SessionPane, PaneSplit.Dir) -> Bool)?
}
