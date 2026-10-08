import CryptoKit
import Foundation
import Security

/// A stored S3 secret is encrypted with a key kept in the login Keychain, so
/// sessions.json never holds one in the clear (main.js `sealSecret` /
/// `openSecret`, which used Electron's safeStorage). Where the Keychain is
/// unavailable the key is refused rather than written plainly — environment
/// credentials still work.
///
/// Values are `enc:` + base64(AES-GCM sealed box). The Electron app's `enc:`
/// values were sealed by Chromium's own key and cannot be opened here; such a
/// bucket asks for its key to be entered again.
enum S3Secrets {
    static let service = "ServerLife S3 secrets"
    static let account = "s3-target-key"

    static let refusal = "This system has no secure keychain available, so an access key cannot be stored. Use environment credentials instead."

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SymmetricKey?

    /// The key, created on first use. nil when the Keychain cannot be used.
    static func key(create: Bool) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 {
            cached = SymmetricKey(data: d)
            return cached
        }
        guard create else { return nil }
        let k = SymmetricKey(size: .bits256)
        let data = k.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: data,
                                  kSecAttrLabel as String: "ServerLife — key for stored S3 secrets",
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cached = k
        return k
    }

    /// `sealSecret`: nil for nothing to store.
    static func seal(_ plain: String?) throws -> String? {
        guard let plain, !plain.isEmpty else { return nil }
        guard let k = key(create: true) else { throw AppError(refusal) }
        return try seal(plain, key: k)
    }

    static func seal(_ plain: String, key: SymmetricKey) throws -> String {
        guard let box = try? AES.GCM.seal(Data(plain.utf8), using: key), let combined = box.combined else {
            throw AppError(refusal)
        }
        return "enc:" + combined.base64EncodedString()
    }

    /// `openSecret`: anything not starting `enc:` was stored plainly and is
    /// returned as it is.
    static func open(_ stored: String?) throws -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        guard stored.hasPrefix("enc:") else { return stored }
        guard let k = key(create: false) else { throw undecryptable }
        return try open(stored, key: k)
    }

    static func open(_ stored: String, key: SymmetricKey) throws -> String {
        guard stored.hasPrefix("enc:") else { return stored }
        guard let d = Data(base64Encoded: String(stored.dropFirst(4))), let box = try? AES.GCM.SealedBox(combined: d),
              let plain = try? AES.GCM.open(box, using: key) else { throw undecryptable }
        return String(decoding: plain, as: UTF8.self)
    }

    static var undecryptable: AppError {
        AppError("The stored secret key cannot be read on this machine. Edit the bucket and enter the key again.")
    }
}
