import Foundation
#if canImport(Security)
import Security
#endif

/// Persists the remembered eero session credential (replaces the DPAPI-backed `SessionStore`).
public protocol SessionStore: AnyObject, Sendable {
    func save(_ token: String) throws
    func load() -> String?
    func clear()
}

/// In-memory store for tests and preview mode.
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func save(_ token: String) { lock.lock(); value = token; lock.unlock() }
    public func load() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    public func clear() { lock.lock(); value = nil; lock.unlock() }
}

#if canImport(Security)
/// Keychain-backed store, the macOS equivalent of DPAPI current-user protection.
public final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    public let service: String
    public let account: String
    public init(service: String = "EeroDesktop.Session.v1", account: String = "eero") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func save(_ token: String) throws {
        clear()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { throw EeroError.operation("macOS could not save your session to the keychain (\(status)).") }
    }
    public func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public func clear() { SecItemDelete(query as CFDictionary) }
}
#endif
