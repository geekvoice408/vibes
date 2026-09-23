import Foundation
import Security

/// Deterministic replacement for relying on AppKit's Password AutoFill heuristics, which never
/// populate a suggestion for a field until one has already been saved — and real cross-app
/// suggestion sharing needs an Associated Domains entitlement tied to a domain we host, which
/// doesn't apply here since a Teleport cluster's proxy address is an arbitrary domain controlled
/// by whoever runs that cluster, not us. Instead: save to the Keychain ourselves after a
/// successful local login, and look it up ourselves to prefill the form next time. Uses a plain
/// generic-password item (service = clusterURI, account = username) so it needs no entitlements
/// and shows up in Keychain Access under this app's name.
enum KeychainCredentialStore {
    private static let service = "dev.local.teleport-connect-native.login"

    static func save(clusterURI: String, username: String, password: String) {
        let account = "\(clusterURI)|\(username)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrLabel as String] = "Teleport Connect Native (\(clusterURI))"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Returns the most recently saved username/password for this cluster, if any.
    static func load(clusterURI: String) -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return nil
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("\(clusterURI)|"),
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { continue }
            let username = String(account.dropFirst(clusterURI.count + 1))
            return (username, password)
        }
        return nil
    }
}
