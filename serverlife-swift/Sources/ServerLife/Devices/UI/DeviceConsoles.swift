import AppKit
import SwiftUI

/// A pane's stand-in while its console is being opened: the tab exists at
/// once (a port can take a moment, a telnet host longer), and the real
/// `DeviceBackend` replaces this when it answers.
@MainActor
final class PendingDeviceBackend: TerminalBackend {
    let kind: String
    var onData: ((Data) -> Void)?
    var onExit: ((Int32?, String?) -> Void)?
    init(kind: String) { self.kind = kind }
    func write(_ data: Data) {}
    func resize(cols: Int, rows: Int) {}
    func close() {}
    func cwd() async -> String? { nil }
}

/*
 * Serial consoles and telnet sessions, in tabs of their own (sessions.js
 * `openDeviceSession` / `startDeviceSession`), and Remote Desktop handed to
 * this machine's own client.
 *
 * Shaped like a local shell rather than like a host, because that is what it
 * is: a terminal with something on the other end of it and no connection, no
 * file browser and no second channel. The spec is what the saved connection
 * holds, so the same code serves the Saved list, the `+` picker, quick
 * connect and the network tools.
 */
@MainActor
enum ConsolesDevices {
    /// The original's device spec, from a host descriptor: `kind`, `name`,
    /// `path`, `baudRate`, `dataBits`, `parity`, `stopBits`, `rtscts`, `xon`,
    /// `xoff`, `host`, `port`, `newline`, `localEcho`, `startupCommand`.
    static func spec(_ h: Host, kind: String) -> JSON {
        var j = ConsolesDevices.options(h)
        j["kind"] = .string(kind)
        j["type"] = .string(kind)
        // A descriptor built without a name takes its hostname as one; the
        // tab should then read `host:port`, as a one-off always did.
        if kind == "telnet", h.name == h.hostname || h.name == j["host"].string { j["name"] = .null }
        if kind == "serial", h.name == h.extra["path"]?.string { j["name"] = .null }
        return j
    }

    /// Every option a device descriptor carries, as one object in the
    /// original's names. Profiles and quick connect put the saved-profile
    /// fields on `Host.extra` (`path`, `baudRate`, `host`, `devicePort`,
    /// `newline`, `localEcho`, `viewOnly`, `scaling`, `quality`, `username`,
    /// `startupCommand` …); those win, and the descriptor's own fields fill
    /// whatever they leave out (`hostname` → `host`, `port`, `user`, `name`).
    /// Booleans that arrive as "true"/"false" strings are read as booleans.
    static func options(_ h: Host) -> JSON {
        var j: JSON = .object(h.extra)
        for (k, v) in h.json.entries where j[k].isNull && !v.isNull { j[k] = v }
        if j["host"].isNull, let hn = h.hostname ?? h.extra["hostname"]?.string { j["host"] = .string(hn) }
        if j["hostname"].isNull, let hn = j["host"].string { j["hostname"] = .string(hn) }
        if j["port"].isNull, let dp = j["devicePort"].int { j["port"] = JSON(dp) }
        for key in ["rtscts", "xon", "xoff", "localEcho", "viewOnly", "shared", "clipboard", "fullscreen", "multimon",
                    "printers", "drives", "adminSession"] {
            if let s = j[key].string { j[key] = .bool(s == "true" || s == "1" || s == "on") }
        }
        return j
    }

    /// Open a console in a tab (or split): the tab first, then the port.
    /// `startupCommand` (on the descriptor, or passed here) is typed once
    /// the console is open.
    static func open(_ h: Host, kind: String, window: WindowModel, split: String? = nil, startupCommand: String? = nil) {
        var spec = spec(h, kind: kind)
        if let startupCommand, !startupCommand.isEmpty { spec["startupCommand"] = .string(startupCommand) }
        let title = ConsolesText.deviceTitle(spec)
        var saved = Host(json: spec)
        saved.type = kind
        saved.extra.removeValue(forKey: "password")
        // The profile's startup command is typed once, when it is opened from
        // the profile; a layout restored at launch only reopens the port
        // (the original's spec never held it) — it must not run `reload` on a
        // switch again.
        saved.extra.removeValue(forKey: "startupCommand")
        let pending = PendingDeviceBackend(kind: kind)
        weak var paneRef: SessionPane?
        let reconnect: () async throws -> TerminalBackend = {
            /*
             * Opening again after it ended, without losing what is on the
             * screen: a console is unplugged and plugged back in, a device is
             * power-cycled. What was printed before it went is usually the
             * reason you were watching.
             */
            try await openBackend(spec, pane: paneRef)
        }
        var args: [String: Any] = ["backend": pending, "title": title, "reconnect": reconnect]
        if let split { args["split"] = split }
        Actions.shared.perform("open-backend", window: window, host: saved, args: args)
        guard let p = SessionsCore.allWindows().flatMap({ Array($0.panes.values) }).first(where: { $0.backend === pending }),
              let s = p.owner else { return }
        paneRef = p
        /*
         * Nothing is open until the port answers (the original set `termId`
         * only then): the stand-in comes off at once, so the pane menu does
         * not offer "Close this console" for a console that is not there yet,
         * and keystrokes go nowhere.
         */
        s.endPaneSession(p)
        p.status = "connecting"
        Task { await start(p, s, spec) }
    }

    /// Open the port or socket and say what was opened.
    static func openBackend(_ spec: JSON, pane: SessionPane?) async throws -> DeviceBackend {
        var j = spec
        if let t = pane?.term?.getTerminal() {
            j["cols"] = JSON(t.cols > 0 ? t.cols : 100)
            j["rows"] = JSON(t.rows > 0 ? t.rows : 30)
        }
        let b = try await DeviceSessions.shared.open(j)
        /*
         * A serial console says what it opened and at what speed, because
         * nothing else will. Telnet has already printed its own three lines —
         * Trying, Connected to, Escape character — and a banner above them
         * would be this app talking over a conversation forty years old.
         */
        if !b.greeted {
            pane?.term?.writeln("\u{1b}[90m\(ConsolesText.deviceGreeting(kind: b.kind, label: b.label))\u{1b}[0m")
        }
        return b
    }

    private static func start(_ p: SessionPane, _ s: SessionsWindow, _ spec: JSON) async {
        do {
            let b = try await openBackend(spec, pane: p)
            // Closed while it opened, or opened again from the menu meanwhile.
            guard let owner = p.owner, owner.panes[p.id] != nil, p.backend == nil else { b.close(); return }
            p.reconnectArmed = false
            owner.attach(p, b)
            if p.tabId == owner.activeTabId { owner.focusActivePane() }
            owner.changed()
            if let cmd = spec["startupCommand"].string, !cmd.isEmpty {
                owner.sendToPane(p, SessionsWindow.withNewline(cmd))
            }
        } catch {
            let owner = p.owner ?? s
            guard owner.panes[p.id] != nil, p.backend == nil else { return }
            owner.endPaneSession(p)
            p.status = "error"
            p.term?.writeln("\r\n\u{1b}[31m\(error.localizedDescription)\u{1b}[0m")
            owner.offerReconnect(p)
            owner.changed()
        }
    }

    // MARK: Pane menu

    /// "Send break" on a serial console.
    static func paneMenuItems(_ p: SessionPane, _ window: WindowModel) -> [NSMenuItem] {
        guard p.kind == .device else { return [] }
        let serial = p.host?.type == Host.serial || (p.backend as? DeviceBackend)?.kind == "serial"
            || (p.backend as? PendingDeviceBackend)?.kind == "serial"
        guard serial else { return [] }
        let item = SessMenuItem("Send break", enabled: p.backend is DeviceBackend,
                                tooltip: "A long break on the line — how you interrupt a boot loader") {
            guard let b = p.backend as? DeviceBackend else { return }
            Task {
                do { try await b.sendBreak(ms: 300); StatusBus.shared.show("Break sent") }
                catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
            }
        }
        return [item]
    }

    // MARK: Ports

    /// The serial ports there are right now (for the `+` picker).
    static func ports() async -> [SerialPortInfo] { await DeviceSessions.shared.listPorts() }

    // MARK: Remote Desktop

    /*
     * RDP opens in this machine's own client with the settings written into
     * the file it reads. It is a bundle of virtual channels, and a viewer that
     * implements the drawing orders and none of the rest is a demo.
     */
    static func launchRDP(_ h: Host) async {
        var j = options(h)
        if j["port"].isNull { j["port"] = 3389 }
        var c = RDPConnection(json: j)
        if c.name == nil || c.name?.isEmpty == true { c.name = c.hostname }
        do {
            let r = try await openRDP(c)
            StatusBus.shared.show(ConsolesText.rdpOpened(c.name ?? c.hostname, client: r))
        } catch {
            StatusBus.shared.toast(error.localizedDescription, kind: .error)
        }
    }

    static let noRDPClient = "No RDP client is set up to open .rdp files — install "
        + "Windows App (formerly Microsoft Remote Desktop) from the App Store"

    /*
     * rdp.js handed the file to the system (`shell.openPath`), so whatever
     * the user has made the default for .rdp — Royal TSX, Jump Desktop, the
     * Microsoft client — is what opens it. Only when nothing claims .rdp is a
     * Microsoft client looked for by bundle id.
     */
    static func openRDP(_ c: RDPConnection) async throws -> String {
        if c.hostname.isEmpty { throw AppError("No hostname") }
        let file = RDPLauncher.rdpPath(c.name ?? c.hostname)
        do {
            try RDPLauncher.rdpFile(c).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw AppError("Could not write \(file.path): \(error.localizedDescription)")
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: file) ?? RDPLauncher.clientApp(for: file) else {
            throw AppError(noRDPClient)
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do { _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: cfg) }
        catch { throw AppError(noRDPClient) }
        return "system"
    }
}
