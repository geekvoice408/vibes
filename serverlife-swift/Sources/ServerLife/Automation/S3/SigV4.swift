import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3 (the signing half of s3.js).
///
/// Implemented here rather than pulling in the AWS SDK: the whole of it is a
/// few hashes, it adds no dependency, and it keeps S3 on the same footing as
/// the hand-written SFTP client next door. `sign` is checked against AWS's
/// published S3 test vectors (Tests/ServerLifeTests/Automation) without a
/// network or an account.
enum SigV4 {
    static let service = "s3"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    /// sha256("") — the payload hash of a request with no body.
    static let emptyHash = sha256Hex(Data())

    struct Credentials: Sendable, Equatable {
        var accessKeyId: String
        var secretAccessKey: String
        var sessionToken: String?
    }

    struct Signed: Sendable {
        /// Every header to send, Authorization included (names as given).
        var headers: [String: String]
        var signature: String
        var canonicalRequest: String
        var stringToSign: String
    }

    // MARK: hashing

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ s: String) -> String { sha256Hex(Data(s.utf8)) }

    static func hmac(_ key: Data, _ data: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: SymmetricKey(data: key)))
    }

    /// kSigning = HMAC chain over day, region, service, "aws4_request".
    static func signingKey(secret: String, day: String, region: String, service: String = SigV4.service) -> Data {
        let kDate = hmac(Data(("AWS4" + secret).utf8), day)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }

    // MARK: encoding

    /// `encodeRfc3986`: encodeURIComponent, plus `!'()*` — so only
    /// `A-Z a-z 0-9 - _ . ~` stay as they are.
    static func encodeRfc3986(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"),
                 UInt8(ascii: "."), UInt8(ascii: "~"):
                out.unicodeScalars.append(UnicodeScalar(b))
            default:
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// Each path segment is encoded, but the separators are not — S3 treats
    /// the key as a path, and encoding the slashes would ask for a different object.
    static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false).map { encodeRfc3986(String($0)) }.joined(separator: "/")
    }

    /// Sorted by encoded name, then encoded value; nil values are left out.
    static func canonicalQuery(_ query: [String: String?]) -> String {
        var pairs: [(String, String)] = []
        for (k, v) in query { if let v { pairs.append((encodeRfc3986(k), encodeRfc3986(v))) } }
        pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// `20130524T000000Z` and `20130524`.
    static func amzDate(_ d: Date) -> (full: String, day: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let full = f.string(from: d)
        return (full, String(full.prefix(8)))
    }

    // MARK: signing

    /// Sign a request and return the headers to send (`signRequest`).
    static func sign(method: String, host: String, canonicalUri: String, query: [String: String?] = [:],
                     headers: [String: String] = [:], payloadHash: String = SigV4.emptyHash, region: String,
                     credentials: Credentials, date: Date = Date()) -> Signed {
        let (full, day) = amzDate(date)
        let scope = "\(day)/\(region)/\(service)/aws4_request"

        // Insertion order matters only for which value wins a duplicate name:
        // the caller's headers come last, as in the original's object spread.
        var all: [(String, String)] = [("host", host), ("x-amz-content-sha256", payloadHash), ("x-amz-date", full)]
        if let t = credentials.sessionToken, !t.isEmpty { all.append(("x-amz-security-token", t)) }
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { all.append((k, v)) }

        var lookup: [String: String] = [:]
        var sent: [String: String] = [:]
        var sentNameFor: [String: String] = [:]
        for (k, v) in all {
            let lower = k.lowercased()
            lookup[lower] = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prev = sentNameFor[lower] { sent.removeValue(forKey: prev) }
            sentNameFor[lower] = k
            sent[k] = v
        }
        let names = lookup.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lookup[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let canonicalRequest = [method, canonicalUri, canonicalQuery(query), canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", full, scope, sha256Hex(canonicalRequest)].joined(separator: "\n")
        let key = signingKey(secret: credentials.secretAccessKey, day: day, region: region)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: key)))
            .map { String(format: "%02x", $0) }.joined()

        sent["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return Signed(headers: sent, signature: signature, canonicalRequest: canonicalRequest, stringToSign: stringToSign)
    }
}
