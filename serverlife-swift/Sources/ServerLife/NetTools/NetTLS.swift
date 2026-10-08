import Foundation
import Network
import Security
import CryptoKit

// TLS certificates (Network.framework + SecTrust), HTTP checks and a
// Teleport proxy's /webapi/ping (URLSession).

enum NetTLS {
    /// Report what the server presents, including a chain that does not
    /// validate — "the certificate is expired" is the answer, not an error.
    static func info(host: String, port: String? = nil) async throws -> TLSResult {
        let parsed = NetCheck.splitHostPort(host)
        let h = try NetCheck.checkHost(parsed.host)
        let p = ntPort(ntNumberOr(port, Double(parsed.port ?? 443)))
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: p)), p > 0, p < 65536 else {
            return TLSResult(ok: false, host: h, port: p, error: "Port should be >= 0 and < 65536. Received \(p).")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<TLSResult, Never>) in
            let queue = DispatchQueue(label: "nettools.tls")
            final class State: @unchecked Sendable { var trust: SecTrust?; var done = false }
            let st = State()
            let tls = NWProtocolTLS.Options()
            let sec = tls.securityProtocolOptions
            if NetCheck.ipVersion(h) == 0 { sec_protocol_options_set_tls_server_name(sec, h) }
            sec_protocol_options_set_verify_block(sec, { _, trust, complete in
                st.trust = sec_trust_copy_ref(trust).takeRetainedValue()
                complete(true)
            }, queue)
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let conn = NWConnection(host: NWEndpoint.Host(h), port: nwPort, using: params)
            let finish: (TLSResult) -> Void = { r in
                guard !st.done else { return }
                st.done = true
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var r = TLSResult(ok: true, host: h, port: p)
                    if let meta = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        let m = meta.securityProtocolMetadata
                        r.proto = protocolName(sec_protocol_metadata_get_negotiated_tls_protocol_version(m))
                        r.cipherName = cipherName(sec_protocol_metadata_get_negotiated_tls_ciphersuite(m))
                        r.cipherVersion = r.proto
                        if let a = sec_protocol_metadata_get_negotiated_protocol(m) { r.alpn = String(cString: a) }
                    }
                    if let trust = st.trust { describe(trust, into: &r) }
                    finish(r)
                case .failed(let e):
                    finish(TLSResult(ok: false, host: h, port: p, error: message(e, h, p)))
                case .waiting(let e):
                    // Refused, unreachable or unresolvable: Network.framework
                    // would wait for the path to change; the original failed.
                    finish(TLSResult(ok: false, host: h, port: p, error: message(e, h, p)))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { finish(TLSResult(ok: false, host: h, port: p, error: "Timed out.")) }
        }
    }

    static func message(_ e: NWError, _ h: String, _ p: Int) -> String {
        switch e {
        case .posix(let code): return "connect \(NetSocket.code(code.rawValue)) \(h):\(p)"
        case .dns: return "getaddrinfo ENOTFOUND \(h)"
        case .tls(let s): return tlsMessage(s)
        default: return e.localizedDescription
        }
    }

    /// A handshake failure in words rather than an OSStatus.
    static func tlsMessage(_ s: OSStatus) -> String {
        let words: [OSStatus: String] = [
            -9805: "Client network socket disconnected before secure TLS connection was established",
            -9806: "Client network socket disconnected before secure TLS connection was established",
            -9816: "Client network socket disconnected before secure TLS connection was established",
            -9836: "The server does not support a TLS version this machine will use (protocol version alert)",
            -9824: "The server rejected the TLS handshake (handshake failure alert)",
            -9818: "No cipher suite in common with the server",
            -9800: "TLS protocol error — the far end may not be speaking TLS on this port",
            -9801: "The TLS negotiation failed",
            -9802: "The server sent a fatal TLS alert",
            -9819: "The server sent an unexpected TLS message",
            -9831: "The server does not trust this client's certificate authority",
            -9829: "The server rejected the client certificate",
            -9825: "The server reported a bad certificate",
            -9837: "The server asked for stronger security than was offered",
            -9838: "The server reported an internal error during the TLS handshake",
            -9844: "The server refused the TLS connection",
        ]
        if let w = words[s] { return w }
        if let m = SecCopyErrorMessageString(s, nil) as String?, !m.isEmpty { return "\(m) (\(s))" }
        return "TLS handshake failed (\(s))"
    }

    static func protocolName(_ v: tls_protocol_version_t) -> String {
        switch v {
        case .TLSv13: return "TLSv1.3"
        case .TLSv12: return "TLSv1.2"
        case .TLSv11: return "TLSv1.1"
        case .TLSv10: return "TLSv1"
        case .DTLSv12: return "DTLSv1.2"
        case .DTLSv10: return "DTLSv1"
        @unknown default: return "unknown"
        }
    }

    /// OpenSSL's names, as Node reported them.
    static func cipherName(_ c: tls_ciphersuite_t) -> String {
        let names: [UInt16: String] = [
            0x1301: "TLS_AES_128_GCM_SHA256", 0x1302: "TLS_AES_256_GCM_SHA384", 0x1303: "TLS_CHACHA20_POLY1305_SHA256",
            0xC02B: "ECDHE-ECDSA-AES128-GCM-SHA256", 0xC02C: "ECDHE-ECDSA-AES256-GCM-SHA384",
            0xC02F: "ECDHE-RSA-AES128-GCM-SHA256", 0xC030: "ECDHE-RSA-AES256-GCM-SHA384",
            0xCCA8: "ECDHE-RSA-CHACHA20-POLY1305", 0xCCA9: "ECDHE-ECDSA-CHACHA20-POLY1305",
            0xC009: "ECDHE-ECDSA-AES128-SHA", 0xC00A: "ECDHE-ECDSA-AES256-SHA",
            0xC013: "ECDHE-RSA-AES128-SHA", 0xC014: "ECDHE-RSA-AES256-SHA",
            0xC023: "ECDHE-ECDSA-AES128-SHA256", 0xC024: "ECDHE-ECDSA-AES256-SHA384",
            0xC027: "ECDHE-RSA-AES128-SHA256", 0xC028: "ECDHE-RSA-AES256-SHA384",
            0x009C: "AES128-GCM-SHA256", 0x009D: "AES256-GCM-SHA384", 0x002F: "AES128-SHA", 0x0035: "AES256-SHA",
            0x003C: "AES128-SHA256", 0x003D: "AES256-SHA256", 0x000A: "DES-CBC3-SHA",
        ]
        return names[c.rawValue] ?? String(format: "0x%04X", c.rawValue)
    }

    /// Subject, issuer, validity, SANs, serial and fingerprint of the leaf,
    /// the chain's names, and whether the system trusts it.
    static func describe(_ trust: SecTrust, into r: inout TLSResult) {
        var err: CFError?
        r.authorized = SecTrustEvaluateWithError(trust, &err)
        if !r.authorized { r.authorizationError = (err as Error?)?.localizedDescription ?? "untrusted" }
        let certs = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard let leaf = certs.first else { return }
        let v = values(leaf)
        r.subject = v.subject
        r.issuer = v.issuer
        if let from = v.notBefore { r.validFrom = opensslDate(from) }
        if let to = v.notAfter {
            r.validTo = opensslDate(to)
            r.daysLeft = Int((to.timeIntervalSinceNow / 86400).rounded())
        }
        if !v.san.isEmpty { r.san = v.san.joined(separator: ", ") }
        if let serial = SecCertificateCopySerialNumberData(leaf, nil) as Data? {
            r.serialNumber = serial.map { String(format: "%02X", $0) }.joined()
        }
        let der = SecCertificateCopyData(leaf) as Data
        r.fingerprint256 = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        r.chain = certs.map { c in
            let cv = values(c)
            return (TLSResult.dn(cv.subject) ?? (SecCertificateCopySubjectSummary(c) as String? ?? "?"),
                    TLSResult.dn(cv.issuer) ?? "?")
        }
    }

    /// "Mar  4 00:00:00 2025 GMT", the way Node printed certificate dates.
    static func opensslDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "MMM"
        let mon = f.string(from: d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let day = String(format: "%2d", cal.component(.day, from: d))
        f.dateFormat = "HH:mm:ss yyyy"
        return "\(mon) \(day) \(f.string(from: d)) GMT"
    }

    struct CertValues {
        var subject: [(String, String)] = []
        var issuer: [(String, String)] = []
        var notBefore: Date?
        var notAfter: Date?
        var san: [String] = []
    }

    static let oidNames: [String: String] = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.10": "O", "2.5.4.11": "OU",
        "2.5.4.5": "serialNumber", "1.2.840.113549.1.9.1": "emailAddress", "2.5.4.9": "street", "2.5.4.17": "postalCode",
    ]

    static func values(_ cert: SecCertificate) -> CertValues {
        var out = CertValues()
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore,
                    kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName] as CFArray
        guard let dict = SecCertificateCopyValues(cert, keys, nil) as? [String: Any] else { return out }
        func value(_ k: CFString) -> Any? { (dict[k as String] as? [String: Any])?[kSecPropertyKeyValue as String] }
        func names(_ k: CFString) -> [(String, String)] {
            ((value(k) as? [[String: Any]]) ?? []).compactMap { e in
                guard let label = e[kSecPropertyKeyLabel as String] as? String else { return nil }
                let v = (e[kSecPropertyKeyValue as String] as? String) ?? "\(e[kSecPropertyKeyValue as String] ?? "")"
                return (oidNames[label] ?? label, v)
            }
        }
        out.subject = names(kSecOIDX509V1SubjectName)
        out.issuer = names(kSecOIDX509V1IssuerName)
        func date(_ k: CFString) -> Date? {
            if let n = value(k) as? NSNumber { return Date(timeIntervalSinceReferenceDate: n.doubleValue) }
            if let d = value(k) as? Date { return d }
            return nil
        }
        out.notBefore = date(kSecOIDX509V1ValidityNotBefore)
        out.notAfter = date(kSecOIDX509V1ValidityNotAfter)
        for e in (value(kSecOIDSubjectAltName) as? [[String: Any]]) ?? [] {
            let label = e[kSecPropertyKeyLabel as String] as? String ?? ""
            guard let v = e[kSecPropertyKeyValue as String] as? String else { continue }
            if label.localizedCaseInsensitiveContains("DNS") { out.san.append("DNS:" + v) }
            else if label.localizedCaseInsensitiveContains("IP") { out.san.append("IP Address:" + v) }
            else if label.localizedCaseInsensitiveContains("Email") || label.localizedCaseInsensitiveContains("RFC 822") { out.san.append("email:" + v) }
            else if label.localizedCaseInsensitiveContains("URI") { out.san.append("URI:" + v) }
        }
        return out
    }

    // MARK: HTTP

    static let maxRedirects = 5

    /// An HTTP(S) check: status, headers, timing and the redirect chain.
    /// Bodies are read only far enough to show what came back.
    static func httpCheck(url: String, method: String = "GET", insecure: Bool = false, timeout: TimeInterval = 15) async throws -> HTTPResult {
        var raw = url.ntTrimmed
        if raw.isEmpty { throw AppError("Give a URL or host.") }
        if raw.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil { raw = "https://" + raw }
        guard let target = URL(string: raw.replacingOccurrences(of: " ", with: "%20")), let scheme = target.scheme?.lowercased(),
              target.host != nil else { throw AppError("That is not a valid URL.") }
        if !["http", "https"].contains(scheme) { throw AppError("Only http and https are supported.") }
        _ = try NetCheck.checkHost(target.host)
        let m = method.uppercased()
        if !["GET", "HEAD"].contains(m) { throw AppError("Only GET and HEAD are supported.") }

        var chain: [HTTPHop] = []
        var current = target
        for i in 0...maxRedirects {
            let res = try await HTTPFetch.once(current, method: m, insecure: insecure, timeout: timeout,
                                               headers: ["User-Agent": "ServerLife", "Accept": "*/*"], keep: 2048)
            let preview = String(decoding: res.body.prefix(2048), as: UTF8.self)
            chain.append(HTTPHop(url: normalised(current), status: res.status, statusMessage: res.reason,
                                 headers: res.headers, ms: res.ms, bytes: res.bytes, preview: String(preview.prefix(2048))))
            guard let loc = res.headers.first(where: { $0.0.lowercased() == "location" })?.1,
                  res.status >= 300, res.status < 400, i != maxRedirects else { break }
            guard let next = URL(string: loc, relativeTo: current)?.absoluteURL else { break }
            _ = try NetCheck.checkHost(next.host)
            current = next
        }
        return HTTPResult(chain: chain)
    }

    static func normalised(_ u: URL) -> String {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return u.absoluteString }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if c.percentEncodedPath.isEmpty { c.percentEncodedPath = "/" }
        return c.string ?? u.absoluteString
    }
}

/// One HTTP request with no redirect following, a byte cap and an optional
/// "accept any certificate".
final class HTTPFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response {
        var status: Int
        var reason: String
        var headers: [(String, String)]
        var body: Data
        var bytes: Int
        var ms: Int
    }

    private let insecure: Bool
    private let keep: Int
    private let tooLarge: String?
    private var body = Data()
    private var bytes = 0
    private var response: HTTPURLResponse?
    private var cont: CheckedContinuation<Response, Error>?
    private let started = Date()
    private let lock = NSLock()

    private init(insecure: Bool, keep: Int, tooLarge: String?) {
        self.insecure = insecure
        self.keep = keep
        self.tooLarge = tooLarge
    }

    static func once(_ url: URL, method: String, insecure: Bool, timeout: TimeInterval, headers: [String: String],
                     keep: Int, tooLarge: String? = nil) async throws -> Response {
        let f = HTTPFetch(insecure: insecure, keep: keep, tooLarge: tooLarge)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 4
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        // Directly, as Node's http did: through a system proxy the answer and
        // the timing would be the proxy's, not this machine's.
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg, delegate: f, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await withCheckedThrowingContinuation { c in
            f.cont = c
            session.dataTask(with: req).resume()
        }
    }

    private func finish(_ r: Result<Response, Error>) {
        lock.lock()
        let c = cont; cont = nil
        lock.unlock()
        c?.resume(with: r)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if insecure, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let t = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: t))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes += data.count
        if body.count < keep { body.append(data.prefix(keep - body.count)) }
        if let tooLarge, bytes > keep {
            dataTask.cancel()
            finish(.failure(AppError(tooLarge)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.code == NSURLErrorTimedOut { finish(.failure(AppError("Timed out."))) }
            else { finish(.failure(AppError(ns.localizedDescription))) }
            return
        }
        guard let r = response ?? (task.response as? HTTPURLResponse) else {
            finish(.failure(AppError("No response.")))
            return
        }
        let headers = r.allHeaderFields.compactMap { k, v -> (String, String)? in
            guard let k = k as? String else { return nil }
            return (k.lowercased(), "\(v)")
        }.sorted { $0.0 < $1.0 }
        finish(.success(Response(status: r.statusCode, reason: HTTPFetch.reason(r.statusCode), headers: headers,
                                 body: body, bytes: bytes, ms: Int((Date().timeIntervalSince(started) * 1000).rounded()))))
    }

    /// The standard reason phrase (URLSession does not hand over the server's own).
    static func reason(_ code: Int) -> String {
        let t: [Int: String] = [
            100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
            204: "No Content", 205: "Reset Content", 206: "Partial Content", 300: "Multiple Choices", 301: "Moved Permanently",
            302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
            400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 406: "Not Acceptable", 407: "Proxy Authentication Required", 408: "Request Timeout",
            409: "Conflict", 410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Payload Too Large",
            414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed",
            418: "I'm a Teapot", 421: "Misdirected Request", 422: "Unprocessable Entity", 425: "Too Early", 426: "Upgrade Required",
            428: "Precondition Required", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
            451: "Unavailable For Legal Reasons", 500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
            503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
        ]
        return t[code] ?? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }
}
