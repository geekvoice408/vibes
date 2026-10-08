import Foundation
import CommonCrypto

/// VNC Authentication (security type 2): the 16-byte challenge encrypted with
/// DES under the password — truncated or zero-padded to 8 bytes, each byte's
/// bits reversed (the quirk every VNC implementation inherited).
enum VNCAuth {
    /// The key VNC derives from a password.
    static func key(from password: String) -> [UInt8] {
        // Latin-1 where possible, as the reference viewers do.
        var bytes: [UInt8] = password.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
        if bytes.count > 8 { bytes = Array(bytes.prefix(8)) }
        while bytes.count < 8 { bytes.append(0) }
        return bytes.map(reverseBits)
    }

    static func reverseBits(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }

    /// The response to a 16-byte challenge.
    static func response(challenge: [UInt8], password: String) throws -> [UInt8] {
        try desECB(key: key(from: password), data: challenge)
    }

    struct CryptError: Error, CustomStringConvertible { var description: String }

    /// Single DES, ECB, no padding — for whole 8-byte blocks.
    static func desECB(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        precondition(key.count == 8 && data.count % 8 == 0)
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == data.count else {
            throw CryptError(description: "DES failed (\(status))")
        }
        return out
    }
}
