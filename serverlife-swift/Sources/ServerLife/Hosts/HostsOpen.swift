import AppKit
import Foundation

/// How the hosts feature opens things: every session goes through the
/// owning feature's action id (CLAUDE.md), so nothing here knows how a tab
/// or a pane is built.
@MainActor
enum HostsOpen {
    /// sessions.js `openHost(host, opts)` → `open-host`.
    static func openHost(_ host: Host, window: WindowModel? = nil, login: String? = nil,
                         startupCommand: String? = nil, remoteStartPath: String? = nil,
                         localStartPath: String? = nil, profileId: String? = nil, split: String? = nil) {
        var args: [String: Any] = [:]
        if let login, !login.isEmpty { args["login"] = login }
        if let startupCommand, !startupCommand.isEmpty { args["startupCommand"] = startupCommand }
        if let remoteStartPath, !remoteStartPath.isEmpty { args["remoteStartPath"] = remoteStartPath }
        if let localStartPath, !localStartPath.isEmpty { args["localStartPath"] = localStartPath }
        if let profileId { args["profileId"] = profileId }
        if let split { args["split"] = split }
        Actions.shared.perform("open-host", window: window, host: host, args: args)
    }

    /// sidebar.js `openHostFromList(host)` → `open-host-from-list`: the
    /// pinned or remembered login, tmux when the host always uses it, and
    /// the MFA route — the same open the host list uses.
    static func openFromList(_ host: Host, window: WindowModel? = nil) {
        let id = Actions.shared.isRegistered("open-host-from-list") ? "open-host-from-list" : "open-host"
        Actions.shared.perform(id, window: window, host: host)
    }

    /// sidebar.js `requestAccessFor(host)` → `request-access-for`.
    static func requestAccess(_ host: Host, window: WindowModel? = nil) {
        if Actions.shared.isRegistered("request-access-for") {
            Actions.shared.perform("request-access-for", window: window, host: host)
        } else {
            HostsHooks.requestAccess(host, window: window)
        }
    }

    /// sessions.js `openLocalShell(undefined, { shell, title })` → `open-local`.
    static func openLocalShell(window: WindowModel? = nil, shell: String? = nil, title: String? = nil) {
        var args: [String: Any] = [:]
        if let shell { args["shell"] = shell }
        if let title { args["title"] = title }
        Actions.shared.perform("open-local", window: window, args: args)
    }

    /// The device descriptor the consoles owner's `serial-open` /
    /// `telnet-open` / `vnc-open` / `rdp-open` take. Its `extra` carries the
    /// original `openDeviceSession` / `openVncSession` option names (`kind`,
    /// `name`, `path`, `baudRate`, `dataBits`, `parity`, `stopBits`, `rtscts`,
    /// `xon`, `xoff`, `host`, `port`, `newline`, `localEcho`, `viewOnly`,
    /// `scaling`, `quality`, …), so `host.json` is exactly that object.
    static func deviceHost(_ kind: String, _ options: JSON) -> Host {
        var o = options
        o["kind"] = .string(kind)
        let name = o["name"].string ?? o["path"].string ?? o["host"].string ?? kind
        var h = Host(type: kind, id: "\(kind):\(name)", name: name)
        for (k, v) in o.entries where !v.isNull && !["name", "type", "id"].contains(k) { h.extra[k] = v }
        if kind != Host.serial, let host = o["host"].string { h.hostname = host }
        if let port = o["port"].int { h.port = port }
        return h
    }

    /// sessions.js `openDeviceSession({ kind: 'serial' | 'telnet', … })`.
    ///
    /// Through `serial-open` / `telnet-open` when the consoles owner has them;
    /// otherwise the device is opened here and handed to `open-backend`, so a
    /// console still opens in a build without the consoles' own panes.
    static func openDevice(_ kind: String, _ options: JSON, window: WindowModel? = nil) async throws {
        let id = kind == Host.serial ? "serial-open" : "telnet-open"
        let host = deviceHost(kind, options)
        if Actions.shared.isRegistered(id) {
            Actions.shared.perform(id, window: window, host: host)
            return
        }
        var o = options
        o["kind"] = .string(kind)
        let backend = try await DeviceSessions.shared.open(o)
        Actions.shared.perform("open-backend", window: window, host: host,
                               args: ["backend": backend as TerminalBackend, "title": host.name])
        if let cmd = options["startupCommand"].string, !cmd.isEmpty {
            var line = cmd
            while line.hasSuffix("\n") { line.removeLast() }
            backend.write(Data((line + "\n").utf8))
        }
    }

    /// sessions.js `openVncSession({ name, host, port, … })` → `vnc-open`.
    static func openVnc(_ options: JSON, window: WindowModel? = nil) {
        Actions.shared.perform("vnc-open", window: window, host: deviceHost(Host.vnc, options))
    }

    /// `rdp:launch`, and the status line saying where it went.
    /// `label` is what the line names (the profile's name, or the hostname).
    static func launchRdp(_ options: JSON, label: String) async {
        do {
            let r = try await RDPLauncher.launch(RDPConnection(json: options))
            StatusBus.shared.show("\(label) opened in \(r.client == "mstsc" ? "Remote Desktop Connection" : r.client == "system" ? "your Remote Desktop client" : r.client)")
        } catch {
            StatusBus.shared.toast(hostsErrorText(error), kind: .error)
        }
    }

    /// `send-text` to a pane (or the focused one).
    static func sendText(_ text: String, enter: Bool, paneId: String? = nil, window: WindowModel? = nil) {
        Actions.shared.perform("send-text", window: window, paneId: paneId, args: ["text": text, "enter": enter])
    }
}

/// The text of an error the way the original showed `e.message`.
func hostsErrorText(_ e: Error) -> String {
    if let a = e as? AppError { return a.message }
    return e.localizedDescription
}
