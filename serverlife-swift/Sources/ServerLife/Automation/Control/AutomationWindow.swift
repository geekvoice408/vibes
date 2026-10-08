import Foundation

/// The window's half of the control socket (automation.js).
///
/// Tabs, panes and the live inventory belong to a window, so the verbs that
/// touch them are answered here, in the focused window. A throw becomes an
/// error the caller can read, which is the whole point of an interface
/// something else drives.
///
/// Nothing in here types into a session or runs a command of the caller's
/// choosing. Opening, closing, arranging and running a *saved* macro is the
/// extent of it.
@MainActor
enum AutomationWindow {
    nonisolated static let verbs: Set<String> = ["list_sessions", "list_macros", "open_session", "list_tmux", "open_sessions",
                                     "close_session", "load_layout", "save_layout", "run_macro", "focus_window"]

    /// main.js `askRenderer` timeouts, per verb.
    static func timeout(_ verb: String) -> Double {
        switch verb {
        case "open_session", "list_tmux", "run_macro": return 120
        case "open_sessions", "load_layout": return 300
        default: return 60
        }
    }

    /// `askRenderer`: ask the window the user is looking at, and give up
    /// after a while — a window that never answers must not leave the caller hanging.
    static func ask(_ verb: String, _ params: JSON) async throws -> JSON {
        guard let w = WindowManager.shared.focused ?? WindowManager.shared.windows.first else {
            throw AppError("No ServerLife window is open.")
        }
        let limit = timeout(verb)
        // Whichever comes first answers; the window's work is left to finish
        // either way (it was asked to open things, and may yet).
        final class Once: @unchecked Sendable {
            let lock = NSLock()
            var cont: CheckedContinuation<JSON, Error>?
            func resume(_ r: Result<JSON, Error>) {
                let c: CheckedContinuation<JSON, Error>? = lock.withLock { let c = cont; cont = nil; return c }
                c?.resume(with: r)
            }
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            once.cont = c
            Task { @MainActor in
                do { once.resume(.success(try await handle(verb, params, window: w))) } catch { once.resume(.failure(error)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                once.resume(.failure(AppError("The window did not answer \"\(verb)\" in time.")))
            }
        }
    }

    static func handle(_ verb: String, _ p: JSON, window w: WindowModel) async throws -> JSON {
        switch verb {
        case "list_sessions": return try listSessions(w)
        case "open_session":
            let opened = try await openOne(p, window: w)
            return ["opened": opened["label"], "transport": .string(opened["transport"].string?.nilIfEmpty ?? "mux")]
        case "open_sessions": return try await openSessions(p, window: w)
        case "list_tmux": return try await listTmux(p)
        case "close_session": return try closeSession(p, window: w)
        case "load_layout": return try await loadLayout(p, window: w)
        case "save_layout": return try saveLayout(p, window: w)
        case "list_macros": return try listMacros(w)
        case "run_macro": return try await runMacro(p, window: w)
        case "focus_window": return ["slot": .string(w.id), "tabs": .number(Double(w.feature(SessionsWindow.self).tabs.count))]
        default: throw AppError("Unknown action \"\(verb)\"")
        }
    }

    // MARK: verbs

    static func listSessions(_ w: WindowModel) throws -> JSON {
        let s = w.feature(SessionsWindow.self)
        return ["tabs": .array(s.tabs.enumerated().map { i, t in
            let panes: [JSON] = s.panesOf(t.id).map { id in
                let p = s.pane(id)
                let conn = p?.connId.flatMap { ConnectionManager.shared.connection($0) }
                let local = p?.kind == .local
                // A VNC screen is a view pane here; the original called it "vnc".
                let kind = p.map { $0.kind == .view ? "vnc" : $0.kind.rawValue } ?? "unknown"
                return ["kind": .string(kind),
                        "host": conn.map { .string($0.label) } ?? (local ? "local" : .null),
                        "state": .string(conn?.state.rawValue ?? (local ? "connected" : "idle")),
                        "filesOnly": .bool(p?.filesOnly ?? false)]
            }
            return ["index": .number(Double(i)), "title": .string(t.title), "active": .bool(t.id == s.activeTabId),
                    "panes": .array(panes)]
        })]
    }

    /// Open several at once — the reason this interface exists. Failures are
    /// reported per entry rather than aborting the rest: a set of sessions
    /// where one host is down should still give you the others.
    static func openSessions(_ p: JSON, window w: WindowModel) async throws -> JSON {
        guard let sessions = p["sessions"].array, !sessions.isEmpty else { throw AppError("Give a \"sessions\" array.") }
        let stopOnError = p["stopOnError"].truthy
        var results: [JSON] = []
        for spec in sessions {
            do {
                let opened = try await openOne(spec, window: w)
                results.append(["ok": true, "host": opened["label"]])
            } catch {
                let host = spec["host"].string?.nilIfEmpty ?? "(unnamed)"
                results.append(["ok": false, "host": .string(host), "error": .string(s3Message(error))])
                if stopOnError { break }
            }
        }
        let good = results.filter { $0["ok"].bool == true }.count
        StatusBus.shared.show("Automation opened \(good) of \(results.count) session(s)")
        return ["opened": .number(Double(good)), "failed": .number(Double(results.count - good)), "results": .array(results)]
    }

    /// What tmux has running on a host, so a caller can decide whether to
    /// resume rather than start. Dials the host to ask.
    static func listTmux(_ p: JSON) async throws -> JSON {
        guard let raw = p["host"].stringish?.nilIfEmpty else { throw AppError("Give a \"host\".") }
        try await ensureInventory()
        guard let host = try findHost(raw.trimmed, cluster: p["cluster"].string?.nilIfEmpty) else {
            throw AppError("No host matching \"\(raw)\".")
        }
        /*
         * The same account the app would use, unless one is named.
         *
         * tmux sessions belong to the user that started them, and connecting
         * as the Teleport principal rather than the login the host is actually
         * opened with answers "nothing is running there" about an account
         * nobody uses — while the sessions sit under the other one.
         */
        let login = p["login"].string?.nilIfEmpty ?? AutoHostPrefs.preferredLogin(host)
        let conn = try await ensureConnection(host, login: login)
        let probe = await TmuxService.shared.probe(conn)
        let label = host.name.nilIfEmpty ?? host.alias ?? ""
        if !probe.ok { return ["host": .string(label), "available": false, "reason": JSON(probe.reason)] }
        let sessions = await TmuxService.shared.listSessions(conn)
        return [
            "host": .string(label), "available": true, "version": JSON(probe.version),
            "sessions": .array(sessions.map { s in
                ["name": .string(s.name), "windows": .number(Double(s.windows)), "attached": .bool(s.attached),
                 "created": s.created.map { .string(isoString(ms: $0)) } ?? .null]
            }),
        ]
    }

    static func closeSession(_ p: JSON, window w: WindowModel) throws -> JSON {
        let s = w.feature(SessionsWindow.self)
        if p["all"].truthy {
            let n = s.tabs.count
            for t in s.tabs { s.closeTab(t.id) }
            return ["closed": .number(Double(n))]
        }
        let tab: SessionTab?
        if case .number(let n) = p["index"] {
            // Only a whole number that names a tab; anything else is no such tab.
            tab = n.isFinite && n >= 0 && n < Double(s.tabs.count) && n == n.rounded() ? s.tabs[Int(n)] : nil
        } else {
            tab = s.tabs.first { $0.title == p["title"].string }
        }
        guard let tab else { throw AppError("No such session.") }
        let title = tab.title
        s.closeTab(tab.id)
        return ["closed": 1, "title": .string(title)]
    }

    static func loadLayout(_ p: JSON, window w: WindowModel) async throws -> JSON {
        let layouts = Store.shared.autoListLayouts()
        let id = p["id"].string?.nilIfEmpty
        let name = p["name"].string
        let layout = id != nil ? layouts.first { $0["id"].string == id } : layouts.first { $0["name"].string == name }
        guard let layout else {
            let have = layouts.compactMap { $0["name"].string }.joined(separator: ", ")
            throw AppError("No layout named \"\(name?.nilIfEmpty ?? id ?? "undefined")\". Have: \(have.isEmpty ? "none" : have)")
        }
        let s = w.feature(SessionsWindow.self)
        // Replaces what is open, exactly as loading it from the menu does.
        for t in s.tabs { s.closeTab(t.id) }
        await s.restoreWorkspace(layout["workspace"])
        return ["loaded": layout["name"], "tabs": .number(Double(layout["workspace"]["tabs"].items.count))]
    }

    static func saveLayout(_ p: JSON, window w: WindowModel) throws -> JSON {
        guard let name = p["name"].stringish?.nilIfEmpty else { throw AppError("Give a \"name\" for the layout.") }
        let ws = w.feature(SessionsWindow.self).captureWorkspace()
        if ws["tabs"].items.isEmpty { throw AppError("Nothing is open to save.") }
        let saved = Store.shared.autoSaveLayout(name: name, workspace: ws)
        return ["saved": saved["name"], "tabs": .number(Double(ws["tabs"].items.count))]
    }

    static func listMacros(_ w: WindowModel) throws -> JSON {
        guard let list = AutomationHooks.listMacros else { throw notYet("Listing macros") }
        return ["macros": .array(list(w).map { m in
            ["name": m["name"], "category": .string(m["category"].string?.nilIfEmpty ?? "Custom"),
             "description": .string(m["description"].string ?? ""), "command": m["command"],
             "builtin": .bool(m["builtin"].truthy), "confirm": .bool(m["confirm"].truthy),
             "interactive": .bool(m["interactive"].truthy),
             "repeatSeconds": .number(m["repeatSeconds"].double ?? 0)]
        })]
    }

    static func runMacro(_ p: JSON, window w: WindowModel) async throws -> JSON {
        guard let list = AutomationHooks.listMacros, let run = AutomationHooks.runMacro else { throw notYet("Running a macro") }
        let macros = list(w)
        let name = p["name"].stringish ?? ""
        guard let macro = macros.first(where: { $0["name"].string == name || ($0["name"].string ?? "").lowercased() == name.lowercased() }) else {
            throw AppError("No macro named \"\(p["name"].stringish ?? "undefined")\". Have: \(macros.compactMap { $0["name"].string }.joined(separator: ", "))")
        }
        guard w.feature(SessionsWindow.self).activePane?.hasTerm == true else { throw AppError("No session is focused to run it in.") }
        try await run(w, macro, p["allPanes"].truthy)
        return ["ran": macro["name"], "command": macro["command"]]
    }

    // MARK: opening one

    /// Resolve one session spec and open it. A host is named the way a person
    /// would name it — the node's hostname, an ssh_config alias, a saved
    /// profile's name, or "local" — and matched against the inventory rather
    /// than requiring an internal id.
    static func openOne(_ spec: JSON, window w: WindowModel) async throws -> JSON {
        let name = (spec["host"].stringish ?? spec["name"].stringish ?? "").trimmed
        if name.isEmpty { throw AppError("Each session needs a \"host\".") }
        let split = spec["split"].string?.nilIfEmpty

        let sw = w.feature(SessionsWindow.self)
        if name == "local" || name == "local shell" {
            if let split { _ = await sw.splitActivePane(split == "down" ? .col : .row, SplitOptions(local: true)) }
            else { sw.openLocalShell() }
            return ["label": "local shell", "transport": "local"]
        }

        try await ensureInventory()
        guard let host = try findHost(name, cluster: spec["cluster"].string?.nilIfEmpty) else {
            throw AppError("No host matching \"\(name)\". Try list_hosts to see what is available.")
        }
        let label = host.name.nilIfEmpty ?? host.alias ?? name

        // Same reasoning as list_tmux: automation opens a host as the app would.
        let login = spec["login"].string?.nilIfEmpty ?? AutoHostPrefs.preferredLogin(host)
        let filesOnly = spec["filesOnly"].truthy
        var args: [String: Any] = ["filesOnly": filesOnly]
        if let login { args["login"] = login }

        /*
         * In tmux, if asked — or if this host is set to open that way.
         *
         * Reading the preference matters more here than the flag does: a host
         * the user has told the app to always open in tmux should not become
         * an ordinary session because something else opened it.
         */
        // Only a missing `tmux` defers to the host's setting; null is "no".
        let wantsTmux = spec.object?["tmux"] == nil ? AutoHostPrefs.opensInTmux(host) : spec["tmux"].truthy
        if wantsTmux && !filesOnly {
            if ConnPrefs.isMfaHost(host) { throw AppError("\(label) asks for MFA per session, so it cannot run in tmux.") }
            if split != nil { throw AppError("A tmux session opens in a tab of its own, not a split.") }
            let session = spec["tmuxSession"].string?.nilIfEmpty ?? AutoHostPrefs.tmuxName(host)
            guard Actions.shared.isRegistered("tmux-open") else { throw AppError("Could not open tmux on \(label).") }
            args["session"] = session
            Actions.shared.perform("tmux-open", window: w, host: host, args: args)
            return ["label": .string(label), "transport": "tmux", "session": .string(session)]
        }
        if let split {
            let o = SplitOptions(host: host, login: login, filesOnly: filesOnly)
            guard await sw.splitActivePane(split == "down" ? .col : .row, o) != nil else {
                throw AppError("Nothing is focused to split.")
            }
            return ["label": .string(label)]
        }
        // Only the login and files-only, as the original passed.
        var o = OpenHostOptions()
        o.login = login
        o.filesOnly = filesOnly
        guard let pane = await sw.openHost(host, o) else { throw AppError("Could not open \(label).") }
        let conn = pane.connId.flatMap { ConnectionManager.shared.connection($0) }
        return ["label": .string(conn?.label ?? label), "transport": JSON(conn?.transportKind)]
    }

    /// Match a name against Teleport nodes, ssh_config aliases and saved profiles.
    static func findHost(_ name: String, cluster: String?) throws -> Host? {
        let inv = Inventory.shared
        let nodes = inv.allNodes
        for n in nodes where cluster == nil || n.cluster == cluster {
            if n.name == name || n.hostname == name || n.uuid == name { return n }
        }
        if let ssh = inv.sshHosts.first(where: { $0.alias == name }) { return ssh }

        if let profile = Store.shared.autoListProfiles().first(where: { $0["name"].string == name }) {
            if profile["type"].string == "teleport" {
                let node = profile["node"].string ?? ""
                var h = Host(type: Host.teleport, id: "tsh:\(profile["cluster"].string ?? ""):\(node)", name: node)
                h.hostname = node
                h.cluster = profile["cluster"].string
                h.proxy = profile["proxy"].string
                h.home = profile["home"].string?.nilIfEmpty
                return h
            }
            let alias = profile["alias"].string ?? ""
            var h = Host(type: Host.ssh, id: "ssh:" + alias, name: profile["name"].string ?? alias)
            h.alias = alias
            h.configFile = profile["configFile"].string?.nilIfEmpty
            return h
        }

        // Nothing exact: one unambiguous partial match is still a clear intent.
        let lower = name.lowercased()
        var partial: [Host] = nodes.filter { $0.name.lowercased().contains(lower) }
        partial += inv.sshHosts.filter { ($0.alias ?? "").lowercased().contains(lower) }
        if partial.count == 1 { return partial[0] }
        if partial.count > 1 {
            throw AppError("\"\(name)\" matches \(partial.count) hosts: "
                + partial.prefix(8).map { $0.name.nilIfEmpty ?? $0.alias ?? "" }.joined(separator: ", "))
        }
        return nil
    }

    /// The inventory, read once if nothing has been read yet.
    static func ensureInventory() async throws {
        let inv = Inventory.shared
        if inv.allNodes.isEmpty && inv.sshHosts.isEmpty { await inv.refresh() }
    }

    /// `ensureConnection`: an open connection to this host as this login, or a new one.
    static func ensureConnection(_ host: Host, login: String?) async throws -> Connection {
        let mgr = ConnectionManager.shared
        let c = try await mgr.create(host: host, options: ConnectOptions(login: login, reuse: true))
        if c.state != .connected { try await mgr.connect(c.id) }
        return c
    }

    static func notYet(_ what: String) -> AppError {
        AppError("\(what) is not available to automation in this build yet.")
    }

    nonisolated static func isoString(ms: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

/// The per-host preferences the sidebar resolves (sidebar.js
/// `preferredLogin`, `loginOptionsFor`, `tmuxState`, `tmuxNameFor`), read
/// straight from settings with the same keys.
@MainActor
enum AutoHostPrefs {
    static func loginOptions(_ host: Host) -> [String] {
        if host.isTeleport {
            // The certificate that carries the logins belongs to a profile in
            // one tsh home; with the same cluster in two homes those sets can differ.
            let profiles = Inventory.shared.profiles
            let p = profiles.first { $0.cluster == host.cluster && ($0.home ?? "") == (host.home ?? "") }
                ?? profiles.first { $0.cluster == host.cluster }
            return p?.logins ?? []
        }
        return host.user.map { [$0] } ?? []
    }

    /// Said deliberately for this host wins; then whatever last worked (if
    /// the cluster still grants it); then the first login the cluster grants.
    static func preferredLogin(_ host: Host) -> String? {
        let s = Store.shared.settings
        if let explicit = s["hostUsers"][host.prefKey].string?.nilIfEmpty { return explicit }
        let options = loginOptions(host)
        if let remembered = s["hostLogins"][host.id].string?.nilIfEmpty, options.isEmpty || options.contains(remembered) {
            return remembered
        }
        return options.first
    }

    /// `tmuxState(host).on`: never on an MFA host; else host, cluster, default.
    static func opensInTmux(_ host: Host) -> Bool {
        if ConnPrefs.isMfaHost(host) { return false }
        let s = Store.shared.settings
        let hk = host.prefKey
        if !hk.isEmpty, let v = s["tmuxHosts"].object?[hk] { return v.truthy }
        let ck = host.clusterPrefKey
        if !ck.isEmpty, let v = s["tmuxClusters"].object?[ck] { return v.truthy }
        return s["tmuxDefault"].bool == true
    }

    static func tmuxName(_ host: Host) -> String {
        let s = Store.shared.settings
        let hk = host.prefKey
        if !hk.isEmpty, let n = s["tmuxSessionNames"][hk].string?.nilIfEmpty { return n }
        return s["tmuxSessionName"].string?.nilIfEmpty ?? "serverlife"
    }
}
