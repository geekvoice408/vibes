#if os(macOS)
import AppKit
import Foundation
import NetworkExtension
import UniformTypeIdentifiers
import EeroCore

/// macOS replacement for `WindowsVpn`.
///
/// On Windows the app installs the signed WireGuard service and controls it through an elevated helper.
/// macOS only allows VPN tunnels to be created by a signed Network Extension, which this unofficial app
/// does not ship. Instead it:
///  (a) exports the Guardian WireGuard configuration as a `.conf` file for the official WireGuard app, and
///  (b) looks for an existing `NETunnelProviderManager` that belongs to the WireGuard app and can start or
///      stop it when macOS makes it visible to this app.
/// macOS normally only shows an app the VPN configurations it created itself, so (b) frequently finds
/// nothing; the WireGuard app (or System Settings > VPN) remains the reliable way to connect.
enum MacVpn {
    static let wireGuardAppBundle = "com.wireguard.macos"
    static let wireGuardExtensionBundle = "com.wireguard.macos.network-extension"
    static let wireGuardAppStore = "https://apps.apple.com/app/wireguard/id1451685025"

    /// Port of `WindowsVpn.Tunnel`: the tunnel name (and exported file name) for a VPN scope.
    static func tunnel(_ scope: String) throws -> String { try VpnConfig.tunnel(scope) }

    /// True when the official WireGuard app is installed (replaces `WindowsVpn.Installed`).
    static var wireGuardInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: wireGuardAppBundle) != nil }

    // MARK: Keys

    /// Port of `WindowsVpn.KeyPair` (`wg genkey` / `wg pubkey`): a Curve25519 key pair encoded as WireGuard base64.
    static func keyPair() throws -> (privateKey: String, publicKey: String) {
        let keys = try VpnConfig.keyPair()
        return (keys[0], keys[1])
    }

    // MARK: Local state (DPAPI file → Keychain)

    /// Per-network saved registration and profile (port of `VpnStore`). Holds the private key, so it lives in the Keychain.
    static func store(_ scope: String) -> KeychainSessionStore {
        KeychainSessionStore(service: "EeroDesktop.VPN.v1", account: scope)
    }

    // MARK: Export

    /// Writes the WireGuard configuration chosen by the user through a save panel. Returns the saved file, or nil when cancelled.
    @MainActor
    static func exportConfiguration(scope: String, profile: JSON) throws -> URL? {
        let fileName = try VpnConfig.configurationFileName(scope)
        let configuration = try VpnContracts.configuration(profile)
        let panel = NSSavePanel()
        panel.title = "Export WireGuard configuration"
        panel.message = "This file contains your Mac's private VPN key. Import it into the WireGuard app, then delete the exported copy."
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = Data(configuration.utf8)
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw EeroError.operation("macOS could not save the WireGuard configuration (" + error.localizedDescription + ").")
        }
        return url
    }

    // MARK: Tunnel control

    /// WireGuard-app tunnels visible to this app. Errors (e.g. missing entitlement) mean none are visible.
    static func wireGuardManagers() async -> [NETunnelProviderManager] {
        guard let all = try? await NETunnelProviderManager.loadAllFromPreferences() else { return [] }
        return all.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == wireGuardExtensionBundle }
    }

    /// The WireGuard tunnel imported from this network's exported file, if macOS exposes it.
    static func manager(_ scope: String) async -> NETunnelProviderManager? {
        guard let name = try? tunnel(scope) else { return nil }
        return await wireGuardManagers().first { $0.localizedDescription == name }
    }

    static func describe(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "Connected through the WireGuard app"
        case .connecting: return "Connecting…"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        case .invalid: return "WireGuard tunnel is not configured"
        case .disconnected: return "Disconnected"
        @unknown default: return "Disconnected"
        }
    }

    /// Port of `WindowsVpn.Status`.
    static func status(_ scope: String) async -> String {
        guard let m = await manager(scope) else { return "Disconnected" }
        return describe(m.connection.status)
    }

    /// Port of `WindowsVpn.Running`.
    static func running(_ scope: String) async -> Bool {
        guard let m = await manager(scope) else { return false }
        let s = m.connection.status
        return s != .disconnected && s != .invalid
    }

    /// Port of `WindowsVpn.AnotherTunnel`.
    static func anotherTunnel(_ scope: String) async -> Bool {
        guard let name = try? tunnel(scope) else { return false }
        return await wireGuardManagers().contains {
            ($0.localizedDescription ?? "").hasPrefix("Eero-") && $0.localizedDescription != name
                && $0.connection.status != .disconnected && $0.connection.status != .invalid
        }
    }

    /// Port of `WindowsVpn.Control("connect")` + `VpnTunnelLifecycle.Start`: starts the WireGuard app's tunnel
    /// and waits up to 15 seconds for macOS to report it connected; otherwise stops it again.
    static func connect(_ scope: String) async throws -> String {
        let name = try tunnel(scope)
        if await running(scope) { throw EeroError.operation(VpnConfig.alreadyRunningMessage) }
        if await anotherTunnel(scope) { throw EeroError.operation(VpnConfig.anotherTunnelMessage) }
        guard let m = await manager(scope) else {
            throw EeroError.operation("eero Desktop cannot see a WireGuard tunnel named \(name). Export the configuration, import it into the WireGuard app, and connect it there. macOS usually only lets the WireGuard app control its own tunnels.")
        }
        let connection = m.connection
        func active() -> Bool { connection.status != .disconnected && connection.status != .invalid }
        // macOS reports `.connected` once the WireGuard extension is up; this app cannot read its handshake time.
        try await VpnTunnelLifecycle.start(
            install: {
                do {
                    if !m.isEnabled { m.isEnabled = true; try await m.saveToPreferences(); try await m.loadFromPreferences() }
                    try connection.startVPNTunnel()
                } catch {
                    throw EeroError.operation("macOS did not allow eero Desktop to start the WireGuard tunnel (" + error.localizedDescription + "). Connect \(name) in the WireGuard app instead.")
                }
            },
            running: { active() },
            handshake: { connection.status == .connected },
            stop: { connection.stopVPNTunnel() },
            confirmed: {},
            attempts: VpnConfig.handshakeAttempts,
            wait: { try await Task.sleep(nanoseconds: 1_000_000_000) })
        return "Connected to Guardian. macOS reports the WireGuard tunnel is up."
    }

    /// Port of `WindowsVpn.Control("disconnect")`.
    static func disconnect(_ scope: String) async throws -> String {
        let name = try tunnel(scope)
        guard let m = await manager(scope) else {
            throw EeroError.operation("eero Desktop cannot see the \(name) tunnel. Disconnect it in the WireGuard app.")
        }
        m.connection.stopVPNTunnel()
        for _ in 0..<10 {
            if m.connection.status == .disconnected || m.connection.status == .invalid { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return VpnConfig.disconnectedMessage
    }
}
#endif
