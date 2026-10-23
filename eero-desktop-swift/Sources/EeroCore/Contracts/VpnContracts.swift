import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Guardian VPN validation and WireGuard profile builders (port of `VpnContracts` in GuardianVpn.cs).
public enum VpnContracts {
    public static let partnerHost = "wifi-connect-api.guardianapp.com"
    public static let serverHost = "connect-api.guardianapp.com"
    /// Publishable routing identifier used by eero's Guardian integration; not an account credential.
    public static let publishableKey = "pk_2B2CE7masv5UM6JYgPTVUJ3JF"

    /// Explains a Guardian availability response (`J.Get(availability, "seats_available")`).
    public static func eligibilityMessage(_ availability: JSON) -> String {
        guard case .bool(let seats) = availability["seats_available"] else {
            return "Guardian VPN eligibility has not been confirmed. Check eligibility before installing the Mac VPN configuration or registering a device."
        }
        return seats
            ? "Guardian reports a VPN device slot is available for this network."
            : "No Guardian VPN device slots are currently available. If your service includes Guardian, manage registered devices or check benefit activation."
    }

    /// Explains a failed availability request (the `ApiException` branch of `EligibilityMessage`).
    public static func eligibilityMessage(error: Error) -> String {
        if let error = error as? ApiError {
            if error.code == 402 { return "Guardian VPN requires an eligible active benefit. Some internet providers do not include Guardian with their service." }
            if error.code == 403 { return "Guardian VPN is not enabled for this network, or your account does not have permission to use it. Your internet provider may not offer this benefit." }
            if error.code == 404 || error.code == 405 { return "Guardian VPN availability is not provided for this network or service version." }
            return error.message
        }
        return userMessage(error)
    }

    public static func eligibilityMessage(_ availability: Result<JSON, Error>) -> String {
        switch availability {
        case .success(let value): return eligibilityMessage(value)
        case .failure(let error): return eligibilityMessage(error: error)
        }
    }

    public static func canRegister(_ availability: JSON) -> Bool {
        if case .bool(true) = availability["seats_available"] { return true }
        return false
    }

    public static func canRegister(_ availability: Result<JSON, Error>) -> Bool {
        if case .success(let value) = availability { return canRegister(value) }
        return false
    }

    /// Opaque per-account, per-network VPN profile scope (24 lowercase hex characters).
    public static func scope(_ account: String, _ network: String) throws -> String {
        if account.isEmpty || network.isEmpty { throw EeroError.argument("Sign in and select a network first.") }
        return String(EeroSHA256.hex(Data((account + "\n" + network).utf8)).prefix(24))
    }

    public static func gateway(_ host: String?) throws -> String {
        let host = host ?? ""
        guard CoreBPattern.matches(host, #"[a-z0-9][a-z0-9-]{0,62}\.sgw\.guardianapp\.com"#, caseInsensitive: true) else {
            throw EeroError.data("Guardian returned an unsupported VPN server.")
        }
        return host.lowercased()
    }

    /// Validates a base64 WireGuard key (32 bytes, not all zero) and returns its canonical encoding.
    public static func key(_ value: String?) throws -> String {
        let invalid = EeroError.data("A VPN key is invalid.")
        var compact = ""
        compact.unicodeScalars.append(contentsOf: (value ?? "").unicodeScalars.filter { !" \t\r\n".unicodeScalars.contains($0) })
        guard var bytes = Data(base64Encoded: compact) else { throw invalid }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        if bytes.count != 32 || bytes.allSatisfy({ $0 == 0 }) { throw invalid }
        return bytes.base64EncodedString()
    }

    enum Family { case v4, v6 }

    static func address(_ value: String?, _ family: Family) throws -> String {
        let invalid = EeroError.data("Guardian returned an invalid tunnel address.")
        let parts = (value ?? "").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let canonical = canonicalAddress(parts[0], family) else { throw invalid }
        let prefix = family == .v4 ? 32 : 128
        if parts.count == 2 && parts[1] != String(prefix) { throw EeroError.data("Guardian returned an unsupported tunnel prefix.") }
        return canonical + "/" + String(prefix)
    }

    /// Parses an IP literal of the given family, rejecting loopback and unspecified addresses.
    static func canonicalAddress(_ text: String, _ family: Family) -> String? {
        if text.isEmpty || text.contains("%") { return nil }
        if family == .v4 {
            var a = in_addr()
            guard inet_pton(AF_INET, text, &a) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: &a) { Array($0) }
            if bytes[0] == 127 || bytes.allSatisfy({ $0 == 0 }) { return nil }
            var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &a, &out, socklen_t(out.count)) != nil else { return nil }
            return String(cString: out)
        } else {
            var a = in6_addr()
            guard inet_pton(AF_INET6, text, &a) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: &a) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) { return nil }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return nil }
            var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &a, &out, socklen_t(out.count)) != nil else { return nil }
            return String(cString: out)
        }
    }

    /// Builds a validated tunnel profile from Guardian's device-credential response.
    public static func profile(_ privateKey: String, _ gateway: String, _ response: JSON) throws -> JSON {
        let ipv6 = response.s("mapped-ipv6-address")
        return JSON.obj(
            ("private_key", try key(privateKey)),
            ("server_key", try key(response.s("server-public-key"))),
            ("ipv4", try address(response.s("mapped-ipv4-address"), .v4)),
            ("ipv6", ipv6.isEmpty ? "" : try address(ipv6, .v6)),
            ("gateway", try self.gateway(gateway)))
    }

    /// WireGuard configuration text for a validated profile (no command hooks).
    public static func configuration(_ profile: JSON) throws -> String {
        let ipv4 = try address(profile.s("ipv4"), .v4)
        var ipv6 = profile.s("ipv6")
        if !ipv6.isEmpty { ipv6 = ", " + (try address(ipv6, .v6)) }
        return "[Interface]\nPrivateKey = " + (try key(profile.s("private_key"))) + "\nAddress = " + ipv4 + ipv6
            + "\nDNS = 1.1.1.1, 1.0.0.1\n\n[Peer]\nPublicKey = " + (try key(profile.s("server_key")))
            + "\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = " + (try gateway(profile.s("gateway"))) + ":51821\nPersistentKeepalive = 25\n"
    }

    public static func subscriber(_ credentials: JSON) throws -> JSON {
        let id = credentials.s("guardian_id"), secret = credentials.s("guardian_secret")
        if id.isEmpty || secret.isEmpty { throw EeroError.data("eero did not return Guardian account credentials.") }
        return JSON.obj(("ep-grd-subscriber-identifier", id), ("ep-grd-subscriber-secret", secret))
    }
}

/// Whole-string regular expression matching (ICU `$` would also accept a trailing newline).
enum CoreBPattern {
    static func matches(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: caseInsensitive ? [.caseInsensitive] : []) else { return false }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: ns.length)) else { return false }
        return m.range.location == 0 && m.range.length == ns.length
    }
}

/// Portable SHA-256 (CryptoKit is unavailable on Linux), used for opaque VPN and notification scopes.
public enum EeroSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    }

    /// Lowercase hexadecimal digest.
    public static func hex(_ data: Data) -> String { hash(data).map { String(format: "%02x", $0) }.joined() }
}
