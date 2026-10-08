import AppKit
import Observation

/// A VNC screen: the RFB client noVNC was in the original, with the state a
/// pane needs to say what is happening — a black screen because the server
/// wants a password, because the host refused the connection, or because the
/// desktop is genuinely black are three different situations.
///
/// The password is only ever held for the handshake; it is never stored.
@MainActor
@Observable
final class VNCSession {
    enum State: Equatable {
        case idle
        case connecting
        /// The server asked for a password (VNC Authentication).
        case authenticating
        case connected
        /// "Could not connect" — the reason, in words meant for people.
        case failed(String)
        /// "Session ended" — the server closed a session that was running.
        case ended(String)
        /// We hung up, or the password prompt was cancelled.
        case closed

        var isLive: Bool { self == .connecting || self == .authenticating || self == .connected }
    }

    /// The three ways to show a remote screen in a pane.
    enum Scaling: String, CaseIterable {
        /// Scale the screen to fit the pane (the default).
        case scale
        /// Ask the server to match the pane (ExtendedDesktopSize servers),
        /// scaling whatever it does not match.
        case resize
        /// Full size, scroll to see the rest.
        case none

        init(_ s: String?) { self = Scaling(rawValue: s ?? "") ?? .scale }
    }

    struct Options: Equatable {
        var shared = true
        var viewOnly = false
        /// Picture quality 0…9 (the form offers 9, 8, 6, 4, 2, 0); default 6.
        var quality = 6
        /// Compression 0…9; default 2.
        var compression = 2
        var scaling: Scaling = .scale
        /// Copy the remote clipboard here when the far side copies.
        var clipboard = true

        init() {}

        /// From a saved profile / `openVncSession` spec (`viewOnly`,
        /// `scaling`, `quality`, `compression`, `shared`, `clipboard`).
        init(json j: JSON) {
            shared = j["shared"].bool ?? true
            viewOnly = j["viewOnly"].truthy
            quality = VNCSession.clamp(j["quality"].double, 0, 9, 6)
            compression = VNCSession.clamp(j["compression"].double, 0, 9, 2)
            scaling = Scaling(j["scaling"].string)
            clipboard = j["clipboard"].bool ?? true
        }
    }

    nonisolated static func clamp(_ v: Double?, _ lo: Int, _ hi: Int, _ dflt: Int) -> Int {
        guard let v, v.isFinite else { return dflt }
        return max(lo, min(hi, Int(v)))
    }

    private(set) var state: State = .idle
    private(set) var host = ""
    private(set) var port = 5900
    private(set) var desktopName = ""
    private(set) var width = 0
    private(set) var height = 0
    private(set) var cursor: RFBCursor?
    /// Whether the server will take SetDesktopSize (it spoke ExtendedDesktopSize).
    private(set) var supportsRemoteResize = false
    var options: Options
    var viewOnly: Bool {
        get { options.viewOnly }
        set { options.viewOnly = newValue }
    }
    var scaling: Scaling {
        get { options.scaling }
        set { options.scaling = newValue }
    }

    /// "Connecting to host:5900…" — the target as the pane shows it.
    var target: String { "\(host):\(port)" }

    @ObservationIgnored private var client: RFBClient?
    @ObservationIgnored private(set) var framebuffer: RFBFramebuffer?
    /// Bumped on every framebuffer update; the view redraws on it.
    @ObservationIgnored private(set) var frame = 0
    @ObservationIgnored weak var view: VNCFramebufferView?

    /// Asked when the server wants a password and none was given. Return nil
    /// to give up (the session closes). Default: the original's prompt —
    /// "VNC password" / "<host> is asking for a password" / Connect.
    @ObservationIgnored var onPasswordNeeded: ((VNCSession) async -> String?)?
    /// The far side copied something (ServerCutText). Default: put it on the
    /// local clipboard, unless `options.clipboard` is false.
    @ObservationIgnored var onClipboard: ((String) -> Void)?
    /// Every state change.
    @ObservationIgnored var onState: ((State) -> Void)?
    @ObservationIgnored var onBell: (() -> Void)?
    /// A message worth a status line (a refused remote resize).
    @ObservationIgnored var onNotice: ((String) -> Void)?

    private static var live: [ObjectIdentifier: WeakSession] = [:]
    private struct WeakSession { weak var s: VNCSession? }

    init(options: Options = Options()) {
        self.options = options
    }

    /// Hang up every session (on quit).
    static func closeAll() {
        for (_, w) in live { w.s?.disconnect() }
        live = [:]
    }

    /// Connect (or reconnect). `password` is used for this handshake only.
    func connect(host: String, port: Int = 5900, password: String? = nil) {
        client?.stop()
        self.host = host
        self.port = port > 0 ? port : 5900
        desktopName = ""
        cursor = nil
        supportsRemoteResize = false
        guard !host.isEmpty else { setState(.failed("No host given")); return }
        let c = RFBClient(host: host, port: self.port, password: password,
                          options: .init(shared: options.shared, quality: options.quality, compression: options.compression))
        client = c
        framebuffer = c.framebuffer
        c.onEvent = { [weak self, weak c] ev in
            MainActor.assumeIsolated {
                guard let self, let c, self.client === c else { return }
                self.handle(ev)
            }
        }
        c.passwordProvider = { [weak self] in
            // On the protocol thread: ask on the main actor and wait.
            let sem = DispatchSemaphore(value: 0)
            var answer: String?
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { sem.signal(); return }
                    Task { @MainActor in
                        answer = await self.askPassword()
                        sem.signal()
                    }
                }
            }
            sem.wait()
            return answer
        }
        VNCSession.live = VNCSession.live.filter { $0.value.s != nil }
        VNCSession.live[ObjectIdentifier(self)] = WeakSession(s: self)
        setState(.connecting)
        c.start()
    }

    private func askPassword() async -> String? {
        if let h = onPasswordNeeded { return await h(self) }
        return await Modal.prompt(nil, title: "VNC password", message: "\(host) is asking for a password",
                                  ok: "Connect", secure: true)
    }

    /// Hang up. Safe to call more than once.
    func disconnect() {
        guard let c = client else { return }
        c.stop()
        if state.isLive { setState(.closed) }
    }

    private func setState(_ s: State) {
        guard s != state else { return }
        state = s
        onState?(s)
    }

    private func handle(_ ev: RFBEvent) {
        switch ev {
        case .authenticating:
            setState(.authenticating)
        case .connected(let w, let h, let name):
            width = w; height = h; desktopName = name
            setState(.connected)
            view?.sessionResized()
            view?.connectedNow()
        case .resized(let w, let h):
            width = w; height = h
            view?.sessionResized()
        case .damage:
            frame &+= 1
            if let c = client { supportsRemoteResize = c.supportsRemoteResize }
            view?.framebufferChanged()
        case .cursor(let c):
            cursor = c
            view?.cursorChanged()
        case .clipboard(let text):
            if let h = onClipboard { h(text) } else if options.clipboard { Clipboard.write(text) }
        case .bell:
            onBell?()
        case .resizeRefused(let msg):
            onNotice?(msg)
        case .failed(let msg):
            client = nil
            setState(.failed(msg))
        case .ended(let msg):
            client = nil
            setState(.ended(msg))
        case .closed:
            client = nil
            if state.isLive { setState(.closed) }
        }
    }

    // MARK: - Input (ignored in view-only mode)

    func sendKey(_ keysym: UInt32, down: Bool) {
        guard !options.viewOnly, state == .connected else { return }
        client?.sendKey(keysym, down: down)
    }

    func sendPointer(x: Int, y: Int, mask: UInt8) {
        guard !options.viewOnly, state == .connected else { return }
        client?.sendPointer(x: x, y: y, mask: mask)
    }

    /// Ctrl+Alt+Del, which the system would otherwise eat.
    func sendCtrlAltDel() {
        sendKey(VNCKeys.controlL, down: true)
        sendKey(VNCKeys.altL, down: true)
        sendKey(VNCKeys.delete, down: true)
        sendKey(VNCKeys.delete, down: false)
        sendKey(VNCKeys.altL, down: false)
        sendKey(VNCKeys.controlL, down: false)
    }

    /// Ctrl+Esc — the Windows key's job, which no local keyboard will send.
    func sendCtrlEsc() {
        sendKey(VNCKeys.controlL, down: true)
        sendKey(VNCKeys.escape, down: true)
        sendKey(VNCKeys.escape, down: false)
        sendKey(VNCKeys.controlL, down: false)
    }

    /// Put text on the remote clipboard (ClientCutText).
    func paste(_ text: String) {
        guard !options.viewOnly, state == .connected, !text.isEmpty else { return }
        client?.sendClipboard(text)
    }

    /// "Paste the local clipboard into the remote session". False when there
    /// was nothing to paste or no session.
    @discardableResult
    func pasteLocalClipboard() -> Bool {
        let text = Clipboard.read()
        guard state == .connected, !options.viewOnly, !text.isEmpty else { return false }
        client?.sendClipboard(text)
        return true
    }

    /// Ask the server to match a size (the "resize" scaling mode).
    func requestRemoteSize(width w: Int, height h: Int) {
        guard state == .connected, supportsRemoteResize, w > 0, h > 0, w != width || h != height else { return }
        client?.requestDesktopSize(width: w, height: h)
    }
}
