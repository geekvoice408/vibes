import AppKit
import SwiftUI

/// What `open-host` can be asked for (sessions.js `openHost` options).
struct OpenHostOptions {
    var login: String?
    var reuse = true
    var profileId: String?
    var startupCommand: String?
    var remoteStartPath: String?
    var x11: String?
    var transport: String?
    var mfaMode: String?
    var filesOnly = false
}

extension SessionsWindow {
    // MARK: Connections

    /// Dial (or reuse) a connection for a host and remember what it was for.
    func createConnection(_ host: Host, login: String?, x11: String? = nil, transport: String? = nil,
                          mfaMode: String? = nil) async throws -> String {
        let created = try await SessConn.create(host, login: login, x11: x11, transport: transport, mfaMode: mfaMode)
        let rec = SessConnRecord(id: created.id, host: host, login: login, x11: x11)
        // Two machines answering to one name: the first block of the node id
        // is the only thing that tells their tabs apart.
        if host.ambiguous == true, let u = host.uuid { rec.dupe = String(u.prefix(8)) }
        SessConnRecords.shared.set(rec)
        if created.transportForced == "no-ssh" {
            StatusBus.shared.show("No ssh client here — opening with tsh ssh", seconds: 6)
        } else if created.transportForced == "leaf" {
            StatusBus.shared.show("\(host.cluster ?? "") is a leaf cluster — opening with tsh ssh", seconds: 6)
        } else if host.ambiguous == true, let u = host.uuid {
            StatusBus.shared.show("Another node in \(host.cluster ?? "") is also called \(host.name) — opening the one with id \(u.prefix(8))",
                                  seconds: 8)
        }
        return created.id
    }

    /// Create (or reuse) a connection for a host, then open a session tab.
    @discardableResult
    func openHost(_ host: Host, _ o: OpenHostOptions = OpenHostOptions()) async -> SessionPane? {
        // An X11 session needs its own connection: forwarding is negotiated on
        // the master, so it cannot be switched on for an open one.
        var connId = (o.reuse && o.x11 == nil && o.transport == nil) ? SessConn.find(host: host, login: o.login) : nil
        if connId == nil {
            do { connId = try await createConnection(host, login: o.login, x11: o.x11, transport: o.transport, mfaMode: o.mfaMode) }
            catch { StatusBus.shared.toast(error.localizedDescription, kind: .error); return nil }
        } else if SessConnRecords.shared.get(connId) == nil {
            SessConnRecords.shared.set(SessConnRecord(id: connId!, host: host, login: o.login, x11: o.x11))
        }
        let label = SessConnRecords.shared.label(connId) ?? host.label
        let t = createTab(title: label, kind: "remote", connId: connId)
        let p = createPane(tabId: t.id, kind: .remote, connId: connId)
        t.root = .pane(p.id)
        activeTabId = t.id
        setActivePane(p.id)
        changed()

        // Files-only: the same connection, no terminal — the file browser is
        // the whole tab.
        if o.filesOnly {
            p.filesOnly = true
            p.explorerVisible = true
            Task { await connectPane(p, remoteStartPath: o.remoteStartPath, noTerminal: true) }
        } else {
            applyOpensWithFiles(p, host)
            Task { await connectPane(p, startupCommand: o.startupCommand, remoteStartPath: o.remoteStartPath) }
        }
        if let pid = o.profileId { SessionsWindow.markProfileUsed(pid) }
        return p
    }

    static func markProfileUsed(_ id: String) {
        Store.shared.markProfileUsed(id)
    }

    /// A pane opens with its file browser, or without it, according to the
    /// host: its own setting, its cluster's, else the global one.
    func applyOpensWithFiles(_ p: SessionPane, _ host: Host) {
        let s = Store.shared
        let hk = host.prefKey
        let perHost = s.settingJSON("openFilesHosts")
        if !hk.isEmpty, let v = perHost[hk].bool { p.explorerVisible = v; return }
        let ck = host.clusterPrefKey
        if !ck.isEmpty, let v = s.settingJSON("openFilesClusters")[ck].bool { p.explorerVisible = v; return }
        p.explorerVisible = s.settingJSON("explorersVisible").bool != false
    }

    /// Dial the connection and attach a shell to the pane.
    func connectPane(_ p: SessionPane, startupCommand: String? = nil, remoteStartPath: String? = nil,
                     noTerminal: Bool = false) async {
        guard let connId = p.connId else { return }
        p.status = "connecting"
        showOverlay(p, PaneOverlay(title: "Connecting to \(SessConnRecords.shared.label(connId) ?? "")…",
                                   sub: SessConn.target(connId) ?? "", showLog: true))
        do {
            try await SessConn.connect(connId)
            // Stick with whatever login worked for this host next time.
            if let rec = SessConnRecords.shared.get(connId), let login = rec.login {
                SessionsWindow.rememberLogin(rec.hostId, login)
            }
            hideOverlay(p)
            if !noTerminal { try await startRemoteTerm(p) }
            p.status = "connected"
            p.applyHighlightSettings()
            p.remoteHome = SessConn.homeDir(connId)
            p.cwd = remoteStartPath ?? p.cwd ?? p.remoteHome
            if let rs = remoteStartPath { sendToPane(p, "cd \(SessionsWindow.jsonQuote(rs))\n") }
            if let sc = startupCommand { sendToPane(p, SessionsWindow.withNewline(sc)) }
            changed()
        } catch {
            let msg = error.localizedDescription
            p.status = "error"
            p.error = msg
            // Per-session MFA and a login the node will not take both fail the
            // shared path the same way, so both remedies are offered.
            let authFailed = (error as? AppError)?.code == "mfa" || msg.hasSuffix(" [mfa]")
            let teleport = SessConn.type(connId) == "teleport"
            var o = PaneOverlay(title: "Connection failed", sub: SessConn.target(connId) ?? "",
                                error: msg.hasSuffix(" [mfa]") ? String(msg.dropLast(6)) : msg, showLog: true)
            o.retry = { [weak self, weak p] in
                guard let self, let p else { return }
                Task { await self.connectPane(p, startupCommand: startupCommand, remoteStartPath: remoteStartPath, noTerminal: noTerminal) }
            }
            if authFailed && teleport {
                o.alt = .init(label: "Connect with MFA (tsh ssh)") { [weak self, weak p] in
                    guard let self, let p else { return }
                    Task { await self.reopenWithMfa(p) }
                }
                let rec = SessConnRecords.shared.get(connId)
                let opts = (rec.flatMap { SessionHooks.loginOptions?($0.host) } ?? []).filter { !$0.isEmpty && $0 != rec?.login }
                o.logins = .init(current: rec?.login, options: opts) { [weak self, weak p] login in
                    guard let self, let p else { return }
                    Task { await self.reopenWithLogin(p, login) }
                }
            }
            showOverlay(p, o)
            changed()
        }
    }

    static func rememberLogin(_ hostId: String, _ login: String) {
        guard !hostId.isEmpty, !login.isEmpty else { return }
        if Store.shared.settingJSON("hostLogins")[hostId].string == login { return }
        Store.shared.mutateSetting("hostLogins") { $0[hostId] = .string(login) }
    }

    /// `JSON.stringify` of a path, which is how the original quoted a `cd`.
    static func jsonQuote(_ s: String) -> String { JSON.string(s).text() }

    static func withNewline(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") { t.removeLast() }
        return t + "\n"
    }

    /// Wait until the pane's terminal is on screen at its real size, so the
    /// program starts at the size it will be drawn at (a shell started at
    /// 80x24 and resized at once reprints its prompt, with zsh's `%`).
    func awaitLayout(_ p: SessionPane) async {
        for _ in 0..<25 {
            if let t = p.term, t.window != nil, t.frame.width > 40, t.frame.height > 20 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func startRemoteTerm(_ p: SessionPane) async throws {
        guard let connId = p.connId else { return }
        await awaitLayout(p)
        let t = p.term?.getTerminal()
        let b = try await SessConn.openTerminal(connId, cols: t?.cols ?? 100, rows: t?.rows ?? 30)
        attach(p, b)
        if p.tabId == activeTabId { focusActivePane() }
    }

    // MARK: Local shells, commands, backends, views

    /// A local tab. With `command` it runs that program instead of a shell
    /// (tsh play, tsh latency, tsh login --user …).
    @discardableResult
    func openLocalShell(cwd: String? = nil, shell: String? = nil, blank: Bool = false, title: String? = nil,
                        command: String? = nil, args: [String]? = nil, env: [String: String] = [:],
                        onExit: ((Int32?) -> Void)? = nil) -> SessionPane {
        let t = createTab(title: title ?? "Local shell", kind: "local", connId: nil)
        let p = createPane(tabId: t.id, kind: .local, connId: nil, cwd: cwd)
        p.title = title ?? "local"
        t.root = .pane(p.id)
        activeTabId = t.id
        setActivePane(p.id)
        changed()
        startLocalTerm(p, cwd: cwd, shell: shell, blank: blank, command: command, args: args, env: env, onExit: onExit)
        return p
    }

    func startLocalTerm(_ p: SessionPane, cwd: String?, shell: String? = nil, blank: Bool = false, command: String? = nil,
                        args: [String]? = nil, env: [String: String] = [:], onExit: ((Int32?) -> Void)? = nil) {
        Task {
            await awaitLayout(p)
            guard panes[p.id] != nil || p.owner != nil else { return }
            spawnLocal(p, cwd: cwd, shell: shell, blank: blank, command: command, args: args, env: env, onExit: onExit)
        }
    }

    private func spawnLocal(_ p: SessionPane, cwd: String?, shell: String?, blank: Bool, command: String?,
                            args: [String]?, env: [String: String], onExit: ((Int32?) -> Void)?) {
        let t = p.term?.getTerminal()
        do {
            let (b, shellPath) = try SessConn.openLocal(shell: shell, blank: blank, cwd: cwd, cols: t?.cols ?? 100,
                                                        rows: t?.rows ?? 30, command: command, args: args, env: env)
            if let onExit { p.onExit = onExit }
            if let command { p.attachments["command"] = command }
            p.shellName = command == nil ? (shell ?? shellPath).split(separator: "/").last.map(String.init) : nil
            p.blankShell = blank
            // A shell opened with no cwd starts at home: say so at once.
            p.cwd = cwd ?? p.cwd ?? NSHomeDirectory()
            attach(p, b)
            if p.tabId == activeTabId { focusActivePane() }
            changed()
        } catch {
            p.status = "error"
            p.term?.writeln("\u{1b}[31m\(error.localizedDescription)\u{1b}[0m")
        }
    }

    /// A tab (or a split) for any TerminalBackend: a serial console, a telnet
    /// session, a tmux pane.
    @discardableResult
    func openBackend(_ backend: TerminalBackend, title: String, host: Host?, split: PaneSplit.Dir?,
                     reconnect: (() async throws -> TerminalBackend)? = nil, greeting: String? = nil) -> SessionPane {
        let kind: PaneKind = backend.kind == "tmux" ? .tmux : (backend.kind == "local" || backend.kind == "command") ? .local : .device
        let p = placeNewPane(kind: kind, connId: nil, title: title, split: split)
        p.title = title
        p.host = host
        p.reconnect = reconnect
        if let greeting { p.term?.writeln("\u{1b}[90m\(greeting)\u{1b}[0m") }
        attach(p, backend)
        focusActivePane()
        changed()
        return p
    }

    /// A pane showing something that is not a terminal (a VNC screen, a
    /// hosts list). Splitting, dragging, closing and the tab strip carry on
    /// without knowing.
    @discardableResult
    func openViewPane(title: String, host: Host?, split: PaneSplit.Dir?, isHosts: Bool = false, hostsGroup: String? = nil,
                      view: @escaping () -> AnyView, onClose: (() -> Void)?) -> SessionPane {
        let p = placeNewPane(kind: .view, connId: nil, title: title, split: split)
        p.title = title
        p.host = host
        p.isHosts = isHosts
        p.hostsGroup = hostsGroup
        p.content = view
        p.onClose = onClose
        p.status = "connected"
        p.explorerVisible = false
        changed()
        return p
    }

    /// A new tab, or a split beside the focused pane.
    func placeNewPane(kind: PaneKind, connId: String?, title: String, split: PaneSplit.Dir?) -> SessionPane {
        if let split, let cur = activePane, let t = tab(cur.tabId) {
            let p = createPane(tabId: t.id, kind: kind, connId: connId, cwd: nil)
            t.root = PaneTree.splitting(t.root, at: cur.id, adding: p.id, dir: split)
            setActivePane(p.id)
            changed()
            return p
        }
        let t = createTab(title: title, kind: "local", connId: connId)
        let p = createPane(tabId: t.id, kind: kind, connId: connId)
        t.root = .pane(p.id)
        activeTabId = t.id
        setActivePane(p.id)
        changed()
        return p
    }

    /// A new tab on a connection that is already open, running one command.
    @discardableResult
    func openOnConnection(_ connId: String, startupCommand: String?, title: String?) async throws -> SessionPane {
        guard SessConn.exists(connId) else { throw AppError("That session is no longer open") }
        let t = createTab(title: title ?? SessConnRecords.shared.label(connId) ?? "", kind: "remote", connId: connId)
        let p = createPane(tabId: t.id, kind: .remote, connId: connId)
        t.root = .pane(p.id)
        activeTabId = t.id
        setActivePane(p.id)
        changed()
        if SessConn.state(connId) == "connected" {
            try await startRemoteTerm(p)
            if let sc = startupCommand { sendToPane(p, SessionsWindow.withNewline(sc)) }
            changed()
        } else {
            Task { await connectPane(p, startupCommand: startupCommand) }
        }
        return p
    }

    // MARK: Reopening differently

    func reopenWithLogin(_ p: SessionPane, _ login: String) async {
        guard let rec = SessConnRecords.shared.get(p.connId) else { return }
        guard let host = SessionsCore.host(forId: rec.hostId) else {
            StatusBus.shared.toast("Host is no longer in the inventory", kind: .error); return
        }
        let tabId = p.tabId
        closePane(p.id)
        if tab(tabId) != nil { closeTab(tabId) }
        var o = OpenHostOptions(); o.login = login; o.reuse = false
        await openHost(host, o)
    }

    /// Reopen using `tsh ssh`, which prompts for MFA in the terminal.
    func reopenWithMfa(_ p: SessionPane) async {
        guard let rec = SessConnRecords.shared.get(p.connId) else { return }
        guard let host = SessionsCore.host(forId: rec.hostId) else {
            StatusBus.shared.toast("Host is no longer in the inventory", kind: .error); return
        }
        let tabId = p.tabId
        closePane(p.id)
        if tab(tabId) != nil { closeTab(tabId) }
        var o = OpenHostOptions()
        o.login = rec.login; o.transport = "tsh"; o.reuse = false
        o.mfaMode = Store.shared.settingJSON("mfaMode").string ?? "platform"
        await openHost(host, o)
    }

    /// An MFA session that never opened gets a way forward instead of a dead
    /// terminal.
    @discardableResult
    func offerMfaAlternatives(_ p: SessionPane) -> Bool {
        guard p.kind == .remote, let connId = p.connId, SessConn.transport(connId) == "tsh", !p.mfaOffered,
              !p.mfaSucceeded else { return false }
        let re = try? NSRegularExpression(pattern: "authentication canceled|authenticate: .*cancel|MFA authentication with \\w+ failed|failed to verify WebAuthn|ERROR: authenticate",
                                          options: [.caseInsensitive])
        guard re?.firstMatch(in: p.mfaTail, range: NSRange(location: 0, length: (p.mfaTail as NSString).length)) != nil else { return false }
        p.mfaOffered = true
        let current = SessConn.mfaMode(connId) ?? Store.shared.settingJSON("mfaMode").string ?? "platform"
        var o = PaneOverlay(title: "MFA was not completed",
                            sub: "\(SessConnRecords.shared.label(connId) ?? "") — tried \(SessionsCore.mfaLabel(current))",
                            error: "The prompt was cancelled or timed out, so the session did not open.")
        o.mfa = .init(current: current, retry: { [weak self, weak p] mode in
            guard let self, let p else { return }
            Task { await self.retryWithMfaMode(p, mode) }
        }, copyCommand: {
            let line = SessConn.log(connId).first { $0.stream == "sys" && $0.text.hasPrefix("$ ") }
            let cmd = line.map { String($0.text.dropFirst(2)).trimmed } ?? ""
            Clipboard.write(cmd)
            StatusBus.shared.show("Command copied — run it in Terminal if the OS prompt will not appear here")
        })
        showOverlay(p, o)
        return true
    }

    func retryWithMfaMode(_ p: SessionPane, _ mode: String) async {
        guard let rec = SessConnRecords.shared.get(p.connId) else { return }
        guard let host = SessionsCore.host(forId: rec.hostId) else {
            StatusBus.shared.toast("Host is no longer in the inventory", kind: .error); return
        }
        let tabId = p.tabId
        closePane(p.id)
        if tab(tabId) != nil { closeTab(tabId) }
        // Remember the working method so the next connection starts with it.
        Store.shared.setSetting("mfaMode", mode)
        var o = OpenHostOptions()
        o.login = rec.login; o.transport = "tsh"; o.reuse = false; o.mfaMode = mode
        await openHost(host, o)
    }

    func reconnectPane(_ p: SessionPane) async {
        guard p.kind == .remote else { return }
        endPaneSession(p)
        p.term?.clearScreen()
        await connectPane(p)
    }

    // MARK: Overlays

    func showOverlay(_ p: SessionPane, _ o: PaneOverlay) {
        var o = o
        if o.error == nil, o.scene == nil { o.scene = ConnectAnim.pick() }
        p.overlaySawPrompt = o.promptInput
        p.overlay = o
    }

    func hideOverlay(_ p: SessionPane) { p.overlay = nil; p.overlaySawPrompt = false }

    /// One more line in an open overlay's log (`noteOverlay`).
    func noteOverlay(_ p: SessionPane, _ text: String) {
        guard p.overlay != nil else { return }
        var t = text
        while t.hasSuffix("\n") { t.removeLast() }
        p.overlay?.notes += t + "\n"
    }
}
