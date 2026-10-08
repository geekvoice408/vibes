import AppKit
import SwiftUI

/// Tabs, panes, terminals, activity, highlighting, links, layouts, quit guard
/// (sessions.js, tabs.js, term.js, activity.js, highlight.js, links.js,
/// workspace.js, connectanim.js, quitguard.js and index.js's glue).
///
/// Owner: sessions. See Sessions/README.md for the API and extension points.
@MainActor
enum SessionsFeature {
    private static var terminating = false
    private static var lastFontSize: Double = 13

    static func install() {
        WorkspaceStore.captureAtLaunch()
        TermClickWatcher.install()
        MiscHooks.connectAnimPreview = { id in
            guard let a = ConnectAnim.byId(id) ?? (id == "rotate" ? ConnectAnim.all.randomElement() : nil) else {
                return AnyView(EmptyView())
            }
            return AnyView(ConnectSceneView(anim: a))
        }
        MiscHooks.windowHasSessions = { !$0.feature(SessionsWindow.self).tabs.isEmpty }
        PaneActivity.shared.screenOf = { id in SessionsCore.owner(ofPane: id)?.pane(id)?.term?.screenTail(16) }

        Slots.tabStrip = { AnyView(SessionsTabStrip(window: $0)) }
        Slots.workspace = { AnyView(SessionsWorkspaceView(window: $0)) }
        StatusItems.shared.register("session", order: 10) { AnyView(SessionStatusItem(window: $0)) }
        StatusItems.shared.register("broadcast", order: 20) { AnyView(BroadcastBadge(window: $0)) }
        // Forwards keep a session alive for the close and quit questions.
        if SessionHooks.forwardCount == nil {
            SessionHooks.forwardCount = { ConnectionManager.shared.connection($0)?.forwards.count ?? 0 }
        }

        WindowManager.shared.didOpen.append { model, options in
            let s = model.feature(SessionsWindow.self)
            s.watchFocusForZoom()
            if let adopt = options["adopt"] as? SessionPane {
                s.adoptPane(adopt)
                return
            }
            Task { @MainActor in
                await s.offerRestore(options: options)
                for hook in SessionHooks.afterStartup { await hook(model) }
            }
        }
        // A window closed on purpose does not come back; what ran in it ends.
        WindowManager.shared.didClose.append { model in
            let s = model.feature(SessionsWindow.self)
            if terminating { return }
            for t in s.tabs { s.closeTab(t.id) }
            s.saveDebounce.cancel()
            WorkspaceStore.clear(model.id)
        }
        AppDelegate.shouldTerminate.append { await QuitConfirm.confirm() }
        AppDelegate.willTerminate.append {
            terminating = true
            for s in SessionsCore.allWindows() {
                s.saveDebounce.cancel()
                s.saveWorkspaceNow()
            }
            for s in SessionsCore.allWindows() { for p in s.panes.values { s.endPaneSession(p) } }
        }

        lastFontSize = Store.shared.settingJSON("fontSize").double ?? 13
        _ = changedKeys(termKeys + highlightKeys + ["refreshSeconds", "showShellInTitle"])
        Store.shared.onSettingsChanged.append { applySettings() }
        observeTheme()
        installKeyboard()
        registerActions()
        startCwdLoop()
        // A connection that goes wrong says so, wherever it is shown.
        _ = ConnectionManager.shared.subscribe { ev in
            guard case .state(let id, let st, let error) = ev, st == .error, let error else { return }
            MainActor.assumeIsolated {
                StatusBus.shared.toast("\(SessConnRecords.shared.label(id) ?? SessConn.label(id) ?? id): \(error)", kind: .error)
            }
        }
    }

    private static let cwdLoop = Repeater()

    /// The directory each visible shell is in, read from its process every
    /// refresh interval (settings.refreshSeconds; 0 = off) — for the titles,
    /// and for the file browser to follow. Only the tab you are looking at,
    /// and only panes whose file browser is showing: a probe on a remote host
    /// is an exec, which on a recorded cluster is an audit entry.
    static func startCwdLoop() {
        let secs = Store.shared.settingJSON("refreshSeconds").double ?? 5
        cwdLoop.start(every: max(0, secs)) {
            if WindowManager.shared.windows.contains(where: { $0.nsWindow?.attachedSheet != nil }) { return }
            for s in SessionsCore.allWindows() {
                for id in s.panesOf(s.activeTabId) {
                    guard let p = s.pane(id), p.hasTerm else { continue }
                    if p.explorerVisible || !PaneAccessories.shared.hasProvider { s.probeCwd(p) }
                }
            }
        }
    }

    /// Settings changed: terminals take the new font, scrollback and cursor
    /// (the size only if the setting itself changed, so a pane's own ⌘+ is
    /// kept), and every pane re-reads its highlight rules.
    private static var lastSeen: [String: JSON] = [:]

    /// Which of the watched settings changed since last time.
    private static func changedKeys(_ keys: [String]) -> Set<String> {
        var out = Set<String>()
        for k in keys {
            let v = Store.shared.settingJSON(k)
            if lastSeen[k] != v { out.insert(k) }
            lastSeen[k] = v
        }
        return out
    }

    private static let termKeys = ["fontSize", "fontFamily", "scrollback", "cursorBlink"]
    private static let highlightKeys = ["highlight", "highlightRules", "hiddenHighlightRules", "highlightHosts"]

    /// Only what changed is applied: a settings write about something else
    /// (a window moved, a login remembered) leaves the terminals alone — a
    /// cursor shape the program set must survive it.
    private static func applySettings() {
        let changed = changedKeys(termKeys + highlightKeys + ["refreshSeconds", "showShellInTitle"])
        if changed.isEmpty { return }
        if changed.contains("refreshSeconds") { startCwdLoop() }
        let fs = Store.shared.settingJSON("fontSize").double ?? 13
        let sizeChanged = changed.contains("fontSize")
        lastFontSize = fs
        let termChanged = !changed.isDisjoint(with: termKeys)
        let hlChanged = !changed.isDisjoint(with: highlightKeys)
        for s in SessionsCore.allWindows() {
            for p in s.panes.values {
                if termChanged { p.term?.applySettings(fontSize: sizeChanged ? CGFloat(fs) : p.term?.fontSize) }
                if hlChanged { p.applyHighlightSettings() }
                if changed.contains("showShellInTitle") { p.titleRevision += 1 }
            }
        }
    }

    /// Terminals carry their own palette and must be told when it changes.
    private static func observeTheme() {
        withObservationTracking {
            _ = Theme.shared.p
            _ = Theme.shared.terminal
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for s in SessionsCore.allWindows() { for p in s.panes.values { p.term?.applyTheme() } }
                    observeTheme()
                }
            }
        }
    }

    /// ⌘+ (Shift+=) and the keypad's + and −, which are not the menu's
    /// accelerators, are caught before a terminal can take them; and where
    /// the last click was decides what they size.
    private static func installKeyboard() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command), !mods.contains(.option), !mods.contains(.control) else { return e }
            let ch = e.charactersIgnoringModifiers ?? ""
            let keypad = mods.contains(.numericPad)
            let dir = (ch == "+" || (keypad && ch == "+")) ? 1 : (keypad && ch == "-") ? -1 : 0
            if dir == 0 { return e }
            return MainActor.assumeIsolated {
                guard let w = WindowManager.shared.model(for: e.window) else { return e }
                w.feature(SessionsWindow.self).zoom(dir)
                return nil
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            MainActor.assumeIsolated {
                guard let nsw = e.window, nsw.sheetParent == nil, let w = WindowManager.shared.model(for: nsw),
                      w.nsWindow === nsw else { return }
                let s = w.feature(SessionsWindow.self)
                let x = e.locationInWindow.x
                s.zoomRegion = (w.sidebarVisible && x < w.sidebarWidth) ? "sidebar" : "panes"
                // Right-clicking a tab shows it before its menu opens.
                if e.type == .rightMouseDown, let content = nsw.contentView {
                    let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
                    if let t = s.tabs.first(where: { s.tabFrames[$0.id]?.contains(p) == true }) {
                        s.setActiveTab(t.id)
                        s.focusActivePane()
                    }
                }
            }
            return e
        }
    }

    private static func sw(_ ctx: ActionContext) -> SessionsWindow? { ctx.window?.feature(SessionsWindow.self) }

    // MARK: Actions

    private static func registerActions() {
        let a = Actions.shared
        a.register("new-session") { ctx in
            if a.isRegistered("new-session-dialog") { a.perform("new-session-dialog", ctx) }
            else { StatusBus.shared.show("The New session dialog is not available in this build yet", kind: .warn) }
        }
        a.register("new-local") { ctx in sw(ctx)?.openLocalShell() }
        a.register("duplicate-tab") { ctx in Task { await sw(ctx)?.duplicateActiveTab() } }
        let hasPane: @MainActor (ActionContext) -> Bool = { sw($0)?.activePane != nil }
        a.register("split-right", enabled: hasPane) { ctx in Task { await sw(ctx)?.splitActivePane(.row) } }
        a.register("split-down", enabled: hasPane) { ctx in Task { await sw(ctx)?.splitActivePane(.col) } }
        a.register("split-right-host") { ctx in sw(ctx)?.pickHostForSplit(.row) }
        a.register("split-down-host") { ctx in sw(ctx)?.pickHostForSplit(.col) }
        for d in ["left", "right", "up", "down"] {
            a.register("move-pane-\(d)") { ctx in sw(ctx)?.movePane(d) }
        }
        a.register("close-pane") { ctx in Task { await sw(ctx)?.closeActive() } }
        a.register("toggle-log") { ctx in Task { await sw(ctx)?.toggleSessionLog() } }
        a.register("broadcast") { ctx in sw(ctx)?.toggleBroadcast() }
        a.register("disconnect") { ctx in
            guard let s = sw(ctx), let t = s.activeTabId else { return }
            Task { await s.requestCloseTab(t) }
        }
        a.register("find") { ctx in
            // A focused file list takes ⌘F for its own name filter.
            if XPFiles.focusFilterIfListFocused(window: ctx.window) { return }
            sw(ctx)?.focusPaneSearch()
        }
        a.register("clear-terminal") { ctx in sw(ctx)?.activePane?.term?.clearScreen() }
        a.register("zoom-in") { ctx in sw(ctx)?.zoom(1) }
        a.register("zoom-out") { ctx in sw(ctx)?.zoom(-1) }
        a.register("zoom-reset") { ctx in sw(ctx)?.zoom(0) }
        for i in 1...9 { a.register("tab-\(i)") { ctx in sw(ctx)?.selectTab(index: i - 1) } }
        a.register("tab-prev") { ctx in sw(ctx)?.stepTab(-1) }
        a.register("tab-next") { ctx in sw(ctx)?.stepTab(1) }
        a.register("save-layout-as") { ctx in Task { await sw(ctx)?.saveLayoutAs() } }
        a.register("load-layout") { ctx in Task { await sw(ctx)?.loadLayoutDialog() } }
        a.register("manage-layouts") { ctx in sw(ctx)?.manageLayouts() }
        a.register("save-layout") { ctx in
            sw(ctx)?.saveWorkspaceNow()
            StatusBus.shared.show("Current layout remembered")
        }
        a.register("clear-layout") { ctx in
            if let id = ctx.window?.id { WorkspaceStore.clear(id) }
            StatusBus.shared.show("Saved layout cleared")
        }
        a.register("highlights") { ctx in
            HighlightEditor.open(ctx.window, hostKey: ctx.arg("hostKey"), hostLabel: ctx.arg("hostLabel") ?? "")
        }

        // Cross-feature ids (CLAUDE.md).
        a.register("open-host") { ctx in openHostAction(ctx) }
        a.register("open-local") { ctx in
            guard let s = sw(ctx) else { return }
            let shell: String? = ctx.arg("shell"), cwd: String? = ctx.arg("cwd"), title: String? = ctx.arg("title")
            let blank = ctx.arg("blank", as: Bool.self) ?? false
            if let d = splitDir(ctx.arg("split")) {
                Task {
                    let p = await s.splitActivePane(d, SplitOptions(local: true, cwd: cwd, shell: shell, blank: blank))
                    if let title, let p { p.title = title; p.attachments["named"] = true }
                }
            } else {
                let p = s.openLocalShell(cwd: cwd, shell: shell, blank: blank, title: title)
                if title != nil { p.attachments["named"] = true }
            }
        }
        a.register("open-command") { ctx in
            guard let s = sw(ctx), let exe: String = ctx.arg("exe") else { return }
            s.openLocalShell(cwd: ctx.arg("cwd"), title: ctx.arg("title"), command: exe, args: ctx.arg("argv") ?? [],
                             env: ctx.arg("env") ?? [:], onExit: ctx.arg("onExit", as: ((Int32?) -> Void).self))
        }
        a.register("open-backend") { ctx in
            guard let s = sw(ctx), let b = ctx.arg("backend", as: TerminalBackend.self) else { return }
            s.openBackend(b, title: ctx.arg("title") ?? b.kind, host: ctx.host ?? ctx.arg("host"),
                          split: splitDir(ctx.arg("split")),
                          reconnect: ctx.arg("reconnect", as: (() async throws -> TerminalBackend).self),
                          greeting: ctx.arg("greeting"))
        }
        a.register("open-view-pane") { ctx in
            guard let s = sw(ctx), let view = ctx.arg("view", as: (() -> AnyView).self) else { return }
            s.openViewPane(title: ctx.arg("title") ?? "", host: ctx.host ?? ctx.arg("host"), split: splitDir(ctx.arg("split")),
                           isHosts: ctx.arg("isHosts", as: Bool.self) ?? false, hostsGroup: ctx.arg("hostsGroup"),
                           view: view, onClose: ctx.arg("onClose", as: (() -> Void).self))
        }
        a.register("open-on-connection") { ctx in
            guard let s = sw(ctx), let c = ctx.connId ?? ctx.arg("connId") else { return }
            Task {
                do { try await s.openOnConnection(c, startupCommand: ctx.arg("startupCommand"), title: ctx.arg("title")) }
                catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
            }
        }
        a.register("send-text") { ctx in
            guard let s = sw(ctx), let text: String = ctx.arg("text") else { return }
            let p = (ctx.paneId.flatMap { SessionsCore.owner(ofPane: $0)?.pane($0) }) ?? s.activePane
            guard let p, let owner = p.owner else { StatusBus.shared.toast("Open a session first", kind: .error); return }
            owner.sendToPane(p, text + ((ctx.arg("enter", as: Bool.self) ?? false) ? "\r" : ""))
        }
        a.register("send-text-all") { ctx in
            guard let s = sw(ctx), let text: String = ctx.arg("text") else { return }
            let tabId = ctx.paneId.flatMap { s.pane($0)?.tabId } ?? s.activeTabId
            let suffix = (ctx.arg("enter", as: Bool.self) ?? false) ? "\r" : ""
            for id in s.panesOf(tabId) {
                if let p = s.pane(id), p.kind == .remote, p.hasTerm { s.sendToPane(p, text + suffix) }
            }
        }
    }

    private static func splitDir(_ s: String?) -> PaneSplit.Dir? {
        switch s { case "right", "row": return .row; case "down", "col": return .col; default: return nil }
    }

    /// Does opening a session on this host mean attaching to tmux? (sidebar
    /// `tmuxState`): never for a host known to need per-session MFA.
    static func opensInTmux(_ host: Host) -> Bool {
        let s = Store.shared
        if s.settingJSON("mfaHosts").stringArray.contains(host.id) { return false }
        let hk = host.prefKey
        if !hk.isEmpty, let v = s.settingJSON("tmuxHosts")[hk].bool { return v }
        let ck = host.clusterPrefKey
        if !ck.isEmpty, let v = s.settingJSON("tmuxClusters")[ck].bool { return v }
        return s.settingJSON("tmuxDefault").bool == true
    }

    static func tmuxName(_ host: Host) -> String {
        let s = Store.shared
        let hk = host.prefKey
        if !hk.isEmpty, let n = s.settingJSON("tmuxSessionNames")[hk].string, !n.isEmpty { return n }
        return s.settingJSON("tmuxSessionName").string?.nilIfEmpty ?? "serverlife"
    }

    /// `open-host`: open a host the way the host list opens it.
    private static func openHostAction(_ ctx: ActionContext) {
        guard let host = ctx.host else { return }
        var target = ctx.window ?? WindowManager.shared.current()
        if ctx.arg("newWindow", as: Bool.self) == true { target = WindowManager.shared.open() }
        let s = target.feature(SessionsWindow.self)
        var login: String? = ctx.arg("login")
        if login == nil {
            login = SessionHooks.preferredLogin?(host) ?? Store.shared.settingJSON("hostLogins")[host.id].string
        }
        // A host set to always use tmux opens there instead.
        let wantsTmux = ctx.arg("tmux", as: Bool.self) == true
            || (ctx.arg("noTmux", as: Bool.self) != true && ctx.arg("filesOnly", as: Bool.self) != true
                && ctx.arg("transport", as: String.self) == nil && !host.isDevice && !host.isLocal && opensInTmux(host))
        if wantsTmux {
            var args = ctx.args
            args["login"] = login
            args["session"] = ctx.arg("tmuxSession") ?? tmuxName(host)
            Actions.shared.perform("tmux-open", window: target, host: host, args: args)
            return
        }
        var o = OpenHostOptions()
        o.login = login
        o.transport = ctx.arg("transport")
        o.x11 = ctx.arg("x11")
        o.filesOnly = ctx.arg("filesOnly", as: Bool.self) ?? false
        o.profileId = ctx.arg("profileId")
        o.startupCommand = ctx.arg("startupCommand")
        o.remoteStartPath = ctx.arg("remoteStartPath")
        o.mfaMode = ctx.arg("mfaMode")
        // A host known to need MFA skips the shared path, which cannot satisfy it.
        var mfaToast: String?
        if o.transport == nil, host.isTeleport, Store.shared.settingJSON("mfaHosts").stringArray.contains(host.id) {
            let mode = Store.shared.settingJSON("mfaMode").string ?? "platform"
            o.transport = "tsh"; o.reuse = false; o.mfaMode = mode
            mfaToast = mode == "platform" ? "Approve with Touch ID when prompted" : "Answer the MFA prompt in the terminal"
        }
        if o.transport != nil { o.reuse = false }
        let localStart: String? = ctx.arg("localStartPath")
        Task {
            let pane: SessionPane?
            if let d = splitDir(ctx.arg("split")) {
                pane = await s.splitActivePane(d, SplitOptions(host: host, login: o.login, transport: o.transport,
                                                               filesOnly: o.filesOnly, remoteStartPath: o.remoteStartPath))
            } else {
                pane = await s.openHost(host, o)
            }
            if let pane, let localStart { pane.attachments["localStartPath"] = localStart }
            if let mfaToast { StatusBus.shared.toast(mfaToast, seconds: 6) }
        }
    }
}

/// `#status-conn`: what the focused pane is connected to.
struct SessionStatusItem: View {
    let window: WindowModel
    var body: some View {
        let s = window.feature(SessionsWindow.self)
        let text = SessionStatusItem.text(s) + (SessionHooks.statusExtra?(window).map { t in
            t.isEmpty ? "" : (SessionStatusItem.text(s).isEmpty ? t : "  ·  " + t) } ?? "")
        if !text.isEmpty { Text(text).lineLimit(1).truncationMode(.tail) }
    }

    static func text(_ s: SessionsWindow) -> String {
        guard let p = s.activePane else { return "" }
        if p.kind == .local { return "Local shell" }
        guard p.kind == .remote, let id = p.connId, SessConn.exists(id) else { return "" }
        let st = SessConn.state(id)
        if let u = SessConn.remoteUser(id), let h = SessConn.hostname(id) { return "\(u)@\(h) · \(st)" }
        return "\(SessConnRecords.shared.label(id) ?? "") — \(st)"
    }
}
