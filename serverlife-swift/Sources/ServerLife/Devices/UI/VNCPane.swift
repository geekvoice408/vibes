import AppKit
import SwiftUI

/*
 * A VNC screen in a pane (vnc.js).
 *
 * Everything hard about this lives elsewhere — the RFB client decodes the
 * screen — so what is left here is the part a viewer usually gets wrong:
 * saying what is happening. A screen that is black because the server wants
 * a password, because the host refused the connection, or because the desktop
 * is genuinely black are three different situations that look identical, and
 * a blank pane that explains nothing is the commonest complaint about every
 * VNC client ever written.
 */
@MainActor
final class VNCPaneModel {
    let session: VNCSession
    /// The original's `vncSpec`: name, host, port, viewOnly, scaling,
    /// quality, compression, shared, clipboard. Never a password.
    let spec: JSON
    let host: String
    let port: Int
    weak var pane: SessionPane?

    init(spec: JSON) {
        self.spec = spec
        host = spec["host"].stringish ?? spec["hostname"].stringish ?? ""
        port = spec["port"].int.flatMap { $0 > 0 ? $0 : nil } ?? spec["devicePort"].int.flatMap { $0 > 0 ? $0 : nil } ?? 5900
        /*
         * Scaling rather than clipping, unless asked otherwise: a remote
         * desktop is nearly always bigger than the pane it lands in, and a
         * viewer that clips shows you the top-left eighth of someone's screen
         * with no indication that there is more.
         */
        session = VNCSession(options: VNCSession.Options(json: spec))
        session.onPasswordNeeded = { s in
            await Modal.prompt(nil, title: "VNC password", message: "\(s.host) is asking for a password",
                               ok: "Connect", secure: true)
        }
        session.onState = { [weak self] st in self?.stateChanged(st) }
        session.onNotice = { msg in StatusBus.shared.show(msg) }
    }

    var target: String { ConsolesText.vncTarget(host: host, port: port) }

    /// Open (or reopen) the screen this pane is for. The password, if the
    /// spec carried one for this connect, is used once and never kept.
    func connect(password: String? = nil) {
        session.connect(host: host, port: port, password: password)
    }

    private func stateChanged(_ st: VNCSession.State) {
        guard let p = pane else { return }
        switch st {
        case .connecting, .authenticating: p.status = "connecting"
        case .connected: p.status = "connected"
        case .failed: p.status = "error"
        case .ended, .closed, .idle: p.status = "closed"
        }
        p.owner?.changed()
    }

    /// Send a key combination the operating system would otherwise eat.
    func sendCtrlAltDel() {
        guard session.state == .connected else { StatusBus.shared.toast("Not connected", kind: .error); return }
        session.sendCtrlAltDel()
        StatusBus.shared.show("Sent Ctrl+Alt+Del")
    }

    /// Paste the local clipboard into the remote session.
    func paste() {
        guard session.state == .connected else { StatusBus.shared.toast("Not connected", kind: .error); return }
        let text = Clipboard.read()
        if text.isEmpty { return }
        session.paste(text)
        StatusBus.shared.show("Pasted into the remote session")
    }

    func reconnect() {
        session.disconnect()
        connect()
    }

    /// The screen's own menu: the right-click menu while nothing is drawn,
    /// and the header button's always (a connected screen takes the
    /// right-click itself).
    func menuItems() -> [CtxItem] {
        [
            CtxItem("Send Ctrl+Alt+Del", icon: "\u{2328}") { [weak self] in self?.sendCtrlAltDel() },
            CtxItem("Paste into the session", key: "⌘V", icon: "\u{2935}") { [weak self] in self?.paste() },
            CtxItem("Reconnect", icon: "\u{21BB}") { [weak self] in self?.reconnect() },
        ]
    }
}

@MainActor
enum ConsolesVNC {
    /// The original's VNC spec from a host descriptor.
    static func spec(_ h: Host) -> JSON {
        var j = ConsolesDevices.options(h)
        j["type"] = .string(Host.vnc)
        j["kind"] = .string(Host.vnc)
        if h.name == h.hostname || h.name == j["host"].string { j["name"] = .null }
        return j
    }

    /// A screen, drawn into a pane (`openVncSession`).
    static func open(_ h: Host, window: WindowModel, split: String? = nil) {
        var spec = spec(h)
        // A password handed over with the request is used for this connect
        // only: it is never part of what a layout saves.
        let password = spec["password"].string
        spec.removeKey("password")
        let model = VNCPaneModel(spec: spec)
        let title = spec["name"].string?.nilIfEmpty ?? model.target
        var saved = Host(json: spec)
        saved.type = Host.vnc
        var args: [String: Any] = [
            "title": title,
            "view": { AnyView(VNCPaneView(model: model)) } as () -> AnyView,
            "onClose": { model.session.disconnect() } as () -> Void,
        ]
        if let split { args["split"] = split }
        Actions.shared.perform("open-view-pane", window: window, host: saved, args: args)
        if let p = window.feature(SessionsWindow.self).activePane, p.kind == .view, p.title == title {
            model.pane = p
            p.attachments["vnc"] = model
            p.status = "connecting"
        }
        model.connect(password: password)
    }

    static func model(_ p: SessionPane?) -> VNCPaneModel? { p?.attachments["vnc"] as? VNCPaneModel }

    /// The menu button in a screen's header: right-click goes to the remote
    /// screen when connected, so the screen's commands need somewhere else.
    static func headerControls(_ p: SessionPane) -> AnyView? {
        guard let m = model(p) else { return nil }
        return AnyView(VNCHeaderButton(model: m))
    }
}

private struct VNCHeaderButton: View {
    let model: VNCPaneModel
    var body: some View {
        Button {
            CtxMenu.show(model.menuItems())
        } label: {
            Text("screen \u{25BE}").font(.system(size: 10.5))
        }
        .buttonStyle(GhostButtonStyle(small: true))
        .help("Send Ctrl+Alt+Del, paste the clipboard, reconnect")
    }
}

/// The pane's content: the screen, with a note over it until it is up.
struct VNCPaneView: View {
    let model: VNCPaneModel

    var body: some View {
        let p = Theme.shared.p
        let st = model.session.state
        ZStack {
            Color.black
            VNCView(session: model.session)
            if st != .connected {
                note(st, p)
                    .contextMenu { menu() }
            }
        }
    }

    @ViewBuilder
    private func menu() -> some View {
        Button("Send Ctrl+Alt+Del") { model.sendCtrlAltDel() }
        Button("Paste into the session") { model.paste() }
        Button("Reconnect") { model.reconnect() }
    }

    @ViewBuilder
    private func note(_ st: VNCSession.State, _ p: Palette) -> some View {
        VStack(spacing: 4) {
            switch st {
            case .failed(let why):
                failure("Could not connect", why, p)
            case .ended(let why):
                failure("Session ended", why, p)
            case .closed:
                failure("Not connected", "the connection was closed", p)
            default:
                Text("Connecting to \(model.target)…").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bg)
        .foregroundStyle(p.textDim)
    }

    /// Say what went wrong, and offer the one thing worth doing about it.
    @ViewBuilder
    private func failure(_ title: String, _ why: String, _ p: Palette) -> some View {
        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
        Text("\(model.target) — \(why)").font(.system(size: 12)).textSelection(.enabled)
        Text(ConsolesText.vncTunnelHint)
            .font(.system(size: 11)).foregroundStyle(p.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 330)
            .padding(.top, 10)
        Button("Try again") { model.connect() }
            .buttonStyle(.primary)
            .padding(.top, 12)
    }
}
