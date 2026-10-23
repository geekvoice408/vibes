import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Raised when VPN startup failed and the tunnel could not be removed (port of `VpnCleanupException`).
public struct VpnCleanupError: Error, LocalizedError, Equatable, Sendable {
    public init() {}
    public var message: String { "VPN startup failed and automatic disconnect failed. Open the VPN settings to deactivate the eero tunnel." }
    public var errorDescription: String? { message }
}

/// Start-and-verify sequence for a WireGuard tunnel (port of `VpnTunnelLifecycle`): install, wait for a
/// fresh handshake, and roll back (stop) on any failure so the app never reports a tunnel that is not working.
public enum VpnTunnelLifecycle {
    public static func start(install: () async throws -> Void, running: () async -> Bool, handshake: () async -> Bool,
                             stop: () async throws -> Void, confirmed: () async throws -> Void, attempts: Int,
                             wait: () async throws -> Void) async throws {
        var installed = false
        do {
            try await install(); installed = true
            for _ in 0..<max(0, attempts) {
                try await wait()
                if await handshake() { try await confirmed(); return }
            }
            throw EeroError.operation("Guardian did not complete a VPN handshake. The tunnel was removed to restore your connection.")
        } catch {
            if installed { try await cleanup(stop) } else if await running() { try await cleanup(stop) }
            throw error
        }
    }

    private static func cleanup(_ stop: () async throws -> Void) async throws {
        do { try await stop() } catch { throw VpnCleanupError() }
    }
}

/// Platform-neutral WireGuard tunnel naming, handshake parsing and key handling (pure parts of WindowsVpn.cs).
public enum VpnConfig {
    /// Tunnel name for a profile scope from `VpnContracts.scope`.
    public static func tunnel(_ scope: String?) throws -> String {
        guard let scope, CoreBPattern.matches(scope, "[a-f0-9]{24}") else { throw EeroError.argument("Invalid VPN profile.") }
        return "Eero-" + scope
    }

    /// File name used when exporting a profile's WireGuard configuration.
    public static func configurationFileName(_ scope: String) throws -> String { try tunnel(scope) + ".conf" }

    public static let actions = ["connect", "disconnect"]

    public static func action(_ value: String) throws -> String {
        if !actions.contains(value) { throw EeroError.argument("Unsupported VPN action.") }
        return value
    }

    /// Default handshake verification: 15 one-second probes.
    public static let handshakeAttempts = 15

    /// True if `wg show <tunnel> latest-handshakes` output reports a handshake within 180 seconds of `now`.
    public static func freshHandshake(_ output: String, now: Date = Date()) -> Bool {
        let seconds = now.timeIntervalSince1970
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count == 2, let epoch = Int64(parts[1]), epoch > 0, abs(seconds - Double(epoch)) < 180 { return true }
        }
        return false
    }

    /// True if a handshake timestamp (from NetworkExtension runtime configuration) is fresh.
    public static func freshHandshake(at date: Date?, now: Date = Date()) -> Bool {
        guard let date, date.timeIntervalSince1970 > 0 else { return false }
        return abs(now.timeIntervalSince(date)) < 180
    }

    /// Requests older than ten minutes (or dated in the future by as much) are refused.
    public static func requestExpired(_ created: Date?, now: Date = Date()) -> Bool {
        guard let created else { return true }
        return abs(now.timeIntervalSince(created)) > 600
    }

    public static let requestExpiredMessage = "The VPN request expired. Try again."
    public static let alreadyRunningMessage = "Disconnect the existing Mac tunnel before reconnecting or changing region."
    public static let anotherTunnelMessage = "Another eero VPN is active on this Mac. Disconnect it before connecting this network's VPN."
    public static let connectedMessage = "Connected to Guardian. WireGuard handshake verified."
    public static let disconnectedMessage = "VPN disconnected."

    #if canImport(CryptoKit)
    /// Generates a WireGuard (Curve25519) key pair: [private, public], base64 encoded.
    public static func keyPair() throws -> [String] {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let priv = try VpnContracts.key(privateKey.rawRepresentation.base64EncodedString())
        let pub = try VpnContracts.key(privateKey.publicKey.rawRepresentation.base64EncodedString())
        return [priv, pub]
    }

    /// Derives the public key for a base64 WireGuard private key.
    public static func publicKey(_ privateKey: String) throws -> String {
        guard let raw = Data(base64Encoded: try VpnContracts.key(privateKey)),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { throw EeroError.data("A VPN key is invalid.") }
        return try VpnContracts.key(key.publicKey.rawRepresentation.base64EncodedString())
    }
    #endif
}
