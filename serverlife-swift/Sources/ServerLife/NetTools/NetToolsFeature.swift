import Foundation

/// Network tools and SSH keys (nettools.js both halves, keys.js, sshkeys.js).
///
/// Owner: nettools (see CLAUDE.md → Ownership). Actions:
///
/// - `nettools` — the Network tools panel. args: `connId` (or ctx.connId)
///   preselects Run on; `host` String target (runs at once, as the original
///   did when opened against a host); `tool` id; `preset` JSON (a saved request).
/// - `webapi-ping` — the panel on the Teleport cluster tool. args: `proxy`
///   String (falls back to ctx.host's proxy); runs at once.
/// - `keys` — the SSH keys dialog.
/// - `forget-host-key` — host (known_hosts name derived as the sidebar did),
///   or args `hostname` String; with neither, asks for one.
@MainActor
enum NetToolsFeature {
    static func install() {
        let a = Actions.shared
        a.register("nettools") { ctx in
            let connId = ctx.arg("connId", as: String.self) ?? ctx.connId ?? ""
            open(window: ctx.window, host: ctx.arg("host", as: String.self), tool: ctx.arg("tool", as: String.self),
                 preset: ctx.arg("preset", as: JSON.self), runOn: connId)
        }
        a.register("webapi-ping") { ctx in
            let proxy = ctx.arg("proxy", as: String.self) ?? ctx.host?.proxy ?? ctx.host?.cluster
            open(window: ctx.window, host: proxy, tool: "teleport", preset: nil, runOn: "")
        }
        a.register("keys") { ctx in KeysDialog.open(ctx.window) }
        a.register("forget-host-key") { ctx in
            var name = ctx.arg("hostname", as: String.self)
            if name == nil, let h = ctx.host {
                name = h.isTeleport ? "\(h.name).\(h.cluster ?? "")" : (h.hostname ?? h.direct?.hostname ?? h.alias)
            }
            KeysDialog.forgetHostKey(name, window: ctx.window)
        }
    }

    /// `openNetTools({ host, tool, preset, runOn })`.
    static func open(window: WindowModel?, host: String?, tool: String?, preset: JSON?, runOn: String) {
        let host = host.flatMap { $0.isEmpty ? nil : $0 }
        if let m = NetToolsModel.current, let h = m.handle, !h.closed {
            // Nothing asked for: bring the open panel forward as it is.
            if host == nil && tool == nil && preset == nil && runOn.isEmpty {
                h.window.makeKeyAndOrderFront(nil)
                return
            }
            // Asked for something specific: each openNetTools call in the
            // original was a fresh window — Run on back to this machine unless
            // a session was named, the tool as asked, and run when given a
            // host. Re-pointing the open one instead could run a different
            // tool on a server nobody chose.
            h.close()
        }
        let model = NetToolsModel(host: host, tool: tool ?? "ping", preset: preset, runOn: runOn, window: window)
        NetToolsModel.current = model
        // Lived in while debugging, and the useful size depends on what is
        // being read — a traceroute is tall, a response body is wide.
        let handle = Modal.panel(id: "nettools", title: "Network tools", width: 780, height: 660, autosave: "nettools") { _ in
            NetToolsView(model: model)
        }
        model.handle = handle
        handle.onClose.append { model.stop() }
        // Opened against a specific host — the caller already said what to ask.
        if host != nil { model.run() }
    }
}
