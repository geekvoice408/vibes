import Darwin
import Foundation
import Security

/// One HTTP exchange with S3 (`requestOnce` in s3.js), over URLSession.
///
/// - Redirects are never followed: a bucket in another region answers 301
///   with the right region in a header, and the caller retries itself.
/// - With a `S3Tunnel`, every request goes through `tsh proxy aws`'s local
///   HTTPS proxy and the certificate it presents is checked against the CA
///   bundle it printed (as awsproxy.js `tunnelAgent` did).
/// - A request body is streamed from a file; a response body is collected in
///   memory, or streamed into `sinkPath` when the answer is a 200.
final class S3HTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        /// The body, unless it was written to the sink.
        var body: Data
        /// Bytes written to the sink.
        var written: Int64
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    private let tunnel: S3Tunnel?
    private let sinkPath: String?
    private let onSent: ((Int64) -> Void)?
    private let onReceived: ((Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Response, Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var sink: FileHandle?
    private var written: Int64 = 0
    private var sinkError: Error?
    /// Why the tunnel's certificate was refused, shown instead of "Cancelled".
    private var trustError: String?

    private init(tunnel: S3Tunnel?, sinkPath: String?, onSent: ((Int64) -> Void)?, onReceived: ((Int64, Int64) -> Void)?) {
        self.tunnel = tunnel
        self.sinkPath = sinkPath
        self.onSent = onSent
        self.onReceived = onReceived
    }

    /// Send one request. `uploadFrom` streams a file as the body.
    static func send(_ request: URLRequest, tunnel: S3Tunnel?, uploadFrom: String? = nil, sinkPath: String? = nil,
                     onSent: ((Int64) -> Void)? = nil, onReceived: ((Int64, Int64) -> Void)? = nil) async throws -> Response {
        // Into a file: through curl, which writes the object's bytes exactly as
        // S3 sends them. URLSession decodes any Content-Encoding (gzip, br …)
        // whatever the request says, and the original never did.
        if let sinkPath, uploadFrom == nil { return try await curlDownload(request, tunnel: tunnel, sinkPath: sinkPath) }
        let me = S3HTTP(tunnel: tunnel, sinkPath: sinkPath, onSent: onSent, onReceived: onReceived)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let t = tunnel {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: t.proxyHost,
                kCFNetworkProxiesHTTPSPort as String: t.proxyPort,
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: t.proxyHost,
                kCFNetworkProxiesHTTPPort as String: t.proxyPort,
            ]
        }
        let session = URLSession(configuration: config, delegate: me, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task: URLSessionTask = uploadFrom.map { session.uploadTask(with: request, fromFile: URL(fileURLWithPath: $0)) }
            ?? session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Response, Error>) in
                me.lock.lock(); me.continuation = c; me.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<Response, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        try? sink?.close()
        sink = nil
        c?.resume(with: result)
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if let sinkPath, self.response?.statusCode == 200 {
            do {
                try LocalFS.ensureParentDir(sinkPath)
                FileManager.default.createFile(atPath: sinkPath, contents: nil)
                guard let h = FileHandle(forWritingAtPath: sinkPath) else { throw AppError("Could not write \(sinkPath)") }
                sink = h
            } catch {
                sinkError = error
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let sink {
            do { try sink.write(contentsOf: data) } catch { sinkError = error; dataTask.cancel(); return }
            written += Int64(data.count)
            onReceived?(written, response?.expectedContentLength ?? -1)
        } else {
            body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let sinkError { finish(.failure(sinkError)); return }
        if let trustError { finish(.failure(AppError(trustError))); return }
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { finish(.failure(AppError("Cancelled"))); return }
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut { finish(.failure(AppError("S3 request timed out."))); return }
            if let tunnel, let url = task.originalRequest?.url, let host = url.host {
                // URLSession does not say what the proxy answered to CONNECT;
                // ask it the same question directly, so a refusal reads as one.
                let target = "\(host):\(url.port ?? (url.scheme == "http" ? 80 : 443))"
                DispatchQueue.global().async {
                    let probe = S3HTTP.probeConnect(tunnel, target: target)
                    switch probe {
                    case .refused(let code): self.finish(.failure(AppError("Local AWS proxy refused the tunnel: HTTP \(code)")))
                    case .unreachable(let why): self.finish(.failure(AppError("Local AWS proxy is not answering: \(why)")))
                    case .accepted: self.finish(.failure(AppError(ns.localizedDescription)))
                    }
                }
                return
            }
            finish(.failure(AppError(ns.localizedDescription)))
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in response?.allHeaderFields ?? [:] { headers[String(describing: k)] = String(describing: v) }
        finish(.success(Response(status: response?.statusCode ?? 0, headers: headers, body: body, written: written)))
    }

    /// A GET written straight to `sinkPath` (the body is kept in memory only
    /// when the answer is not a 200, so its error can be read).
    static func curlDownload(_ request: URLRequest, tunnel: S3Tunnel?, sinkPath: String) async throws -> Response {
        guard let url = request.url?.absoluteString else { throw AppError("Invalid URL") }
        try LocalFS.ensureParentDir(sinkPath)
        let headerFile = NSTemporaryDirectory() + "serverlife-s3-h-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: headerFile) }
        var args = ["-sS", "--raw", "-o", sinkPath, "-D", headerFile, "--connect-timeout", "60",
                    "--speed-time", "60", "--speed-limit", "1", "-X", request.httpMethod ?? "GET"]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { args += ["-H", "\(k): \(v)"] }
        if let t = tunnel {
            args += ["--proxy", "http://\(t.proxyHost):\(t.proxyPort)"]
            // As the original: verified against the proxy's CA bundle, else accepted.
            if let ca = t.caBundle, FileManager.default.fileExists(atPath: ca) { args += ["--cacert", ca] } else { args.append("-k") }
        }
        args.append(url)
        let r = await Proc.run("/usr/bin/curl", args)
        let headText = (try? String(contentsOfFile: headerFile, encoding: .utf8)) ?? ""
        // With a proxy the CONNECT answer comes first; the last block is S3's.
        let blocks = headText.components(separatedBy: "\r\n\r\n").filter { $0.hasPrefix("HTTP/") }
        guard let last = blocks.last else {
            try? FileManager.default.removeItem(atPath: sinkPath)
            if tunnel != nil, let code = blocks.first.flatMap({ Int($0.split(separator: " ").dropFirst().first ?? "") }), code != 200 {
                throw AppError("Local AWS proxy refused the tunnel: HTTP \(code)")
            }
            if r.code == 28 { throw AppError("S3 request timed out.") }
            var msg = r.err.trimmed
            if msg.hasPrefix("curl: ") { msg = String(msg.dropFirst(6)) }
            msg = msg.replacingOccurrences(of: #"^\(\d+\) "#, with: "", options: .regularExpression)
            throw AppError(msg.isEmpty ? "S3 request failed (curl exit \(r.code))" : msg)
        }
        var lines = last.components(separatedBy: "\r\n")
        let status = Int(lines.removeFirst().split(separator: " ").dropFirst().first ?? "") ?? 0
        if tunnel != nil, blocks.count == 1, status != 200, r.code == 56 {
            try? FileManager.default.removeItem(atPath: sinkPath)
            throw AppError("Local AWS proxy refused the tunnel: HTTP \(status)")
        }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[String(l[..<i])] = String(l[l.index(after: i)...]).trimmed } }
        let size = ((try? FileManager.default.attributesOfItem(atPath: sinkPath))?[.size] as? NSNumber)?.int64Value ?? 0
        if status == 200 { return Response(status: status, headers: headers, body: Data(), written: size) }
        let body = (try? Data(contentsOf: URL(fileURLWithPath: sinkPath))) ?? Data()
        try? FileManager.default.removeItem(atPath: sinkPath)
        return Response(status: status, headers: headers, body: body, written: 0)
    }

    enum ProbeResult: Equatable { case accepted, refused(Int), unreachable(String) }

    /// `CONNECT host:port` to the local proxy, and its status code.
    static func probeConnect(_ t: S3Tunnel, target: String, timeout: Int = 5) -> ProbeResult {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(t.proxyHost, String(t.proxyPort), &hints, &res) == 0, let ai = res else {
            return .unreachable("cannot resolve \(t.proxyHost)")
        }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return .unreachable(String(cString: strerror(errno))) }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
            return .unreachable(String(cString: strerror(errno)))
        }
        let req = Array("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n".utf8)
        guard req.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == req.count else {
            return .unreachable(String(cString: strerror(errno)))
        }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return .unreachable(n == 0 ? "connection closed" : String(cString: strerror(errno))) }
        let line = String(decoding: buf[0..<n], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return .unreachable("unreadable answer: \(line)") }
        return code == 200 ? .accepted : .refused(code)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let tunnel, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // The proxy presents its own certificate for the AWS host; the CA
        // bundle tsh printed is exactly what makes that verifiable.
        guard let bundle = tunnel.caBundle, let anchors = S3HTTP.certificates(pemFile: bundle), !anchors.isEmpty else {
            // As the original: without a CA bundle the proxy's certificate is accepted.
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var err: CFError?
        if SecTrustEvaluateWithError(trust, &err) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            trustError = (err.map { ($0 as Error).localizedDescription } ?? "").nilIfEmpty
                ?? "The local AWS proxy's certificate could not be verified."
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Certificates out of a PEM file.
    static func certificates(pemFile: String) -> [SecCertificate]? {
        guard let text = try? String(contentsOfFile: pemFile, encoding: .utf8) else { return nil }
        var out: [SecCertificate] = []
        let parts = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
        for p in parts {
            guard let end = p.range(of: "-----END CERTIFICATE-----") else { continue }
            let b64 = p[..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
            if let der = Data(base64Encoded: b64), let c = SecCertificateCreateWithData(nil, der as CFData) { out.append(c) }
        }
        return out
    }
}
