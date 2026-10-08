import Foundation

/// `Number(opts.timeout) || 20` for a stored value, kept within Int range
/// (the request clamps it to 1…300 anyway).
func ntStoredTimeout(_ j: JSON) -> Int {
    guard let d = j.double, d.isFinite, d != 0 else { return 20 }
    return Int(max(-1_000_000, min(d, 1_000_000)))
}

/// The curl request builder's options (`curlOpts()` in the renderer). Stored
/// in saved requests and recent runs as JSON with the original's keys.
struct CurlOptions: Equatable {
    var method = "GET"
    var url = ""
    var headers = ""
    var body = ""
    var contentType = "application/json"
    var bearer = ""
    var basicUser = ""
    var basicPass = ""
    var insecure = false
    var followRedirects = true
    var timeout = 20
    /// `127.0.0.1:port` of a SOCKS proxy over a session, when run on a host.
    var proxy: String?
    var http2 = false
    var compressed = false

    var json: JSON {
        var o: [String: JSON] = [
            "method": .string(method), "url": .string(url), "headers": .string(headers), "body": .string(body),
            "contentType": .string(contentType), "bearer": .string(bearer), "basicUser": .string(basicUser),
            "basicPass": .string(basicPass), "insecure": .bool(insecure), "followRedirects": .bool(followRedirects),
            "timeout": .number(Double(timeout)),
        ]
        if http2 { o["http2"] = true }
        if compressed { o["compressed"] = true }
        return .object(o)
    }

    /// From a stored `opts` (a missing contentType is "" there: `?? ''`).
    init() {}
    init(json o: JSON, url: String? = nil) {
        method = o["method"].string ?? "GET"
        self.url = url ?? o["url"].string ?? ""
        headers = o["headers"].string ?? ""
        body = o["body"].string ?? ""
        contentType = o["contentType"].string ?? ""
        bearer = o["bearer"].string ?? ""
        basicUser = o["basicUser"].string ?? ""
        basicPass = o["basicPass"].string ?? ""
        insecure = o["insecure"].truthy
        followRedirects = o["followRedirects"].bool != false
        timeout = ntStoredTimeout(o["timeout"])
        http2 = o["http2"].truthy
        compressed = o["compressed"].truthy
    }
}

/// A finished curl request, split into its parts.
struct CurlHop: Equatable {
    var httpVersion = ""
    var status = 0
    var statusText = ""
    /// In arrival order; a repeated header is joined with ", ".
    var headers: [(String, String)] = []

    static func == (a: CurlHop, b: CurlHop) -> Bool {
        a.httpVersion == b.httpVersion && a.status == b.status && a.statusText == b.statusText
            && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0 == name }?.1 ?? headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

struct CurlResult {
    var ok = false
    var method = "GET"
    var url = ""
    var command = ""
    var status = 0
    var statusText = ""
    var httpVersion = ""
    var headers: [(String, String)] = []
    /// Every hop when there was more than one.
    var hops: [CurlHop] = []
    var contentType = ""
    var body = ""
    var bytes = 0
    var ms: Double = 0
    var stderr = ""
    var exitCode: Int32? = 0
    /// The body as drawn (pretty JSON, bounded) and whether it was cut.
    var display = ""
    var displayCut = false

    var json: JSON {
        func hj(_ h: [(String, String)]) -> JSON { .object(Dictionary(h, uniquingKeysWith: { a, _ in a }).mapValues { .string($0) }) }
        return [
            "ok": .bool(ok), "method": .string(method), "url": .string(url), "command": .string(command),
            "status": .number(Double(status)), "statusText": .string(statusText), "httpVersion": .string(httpVersion),
            "headers": hj(headers),
            "hops": .array(hops.map { ["httpVersion": .string($0.httpVersion), "status": .number(Double($0.status)),
                                        "statusText": .string($0.statusText), "headers": hj($0.headers)] }),
            "contentType": .string(contentType), "body": .string(body), "bytes": .number(Double(bytes)),
            "ms": .number(ms), "stderr": .string(stderr), "exitCode": JSON(exitCode.map { Int($0) }),
        ]
    }
}

/// A request, as curl would make it.
///
/// The real binary rather than URLSession: what people want from this is the
/// answer their `curl` would give — the same proxy variables, the same CA
/// store, the same HTTP/2 — and a command line they can paste elsewhere. So
/// the argv is built once and used for both. Nothing goes near a shell: the
/// argv goes to the process as an array, and the printable command is quoted
/// separately for display only.
enum NetCurl {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    static func clampTimeout(_ t: Int) -> Int { min(max(t != 0 ? t : 20, 1), 300) }

    static func args(_ o: CurlOptions) throws -> (args: [String], method: String) {
        let up = o.method.uppercased()
        let method = methods.contains(up) ? up : "GET"
        // Fail quietly on progress, but keep the error text; include the
        // response headers; never read a local .curlrc that could change the result.
        var args = ["-sS", "-q", "-i", "--max-time", String(clampTimeout(o.timeout)), "-X", method]
        if o.followRedirects { args += ["-L", "--max-redirs", "5"] }
        // Through a host rather than from here: `--socks5-hostname` resolves
        // the name at the *proxy*, which is the whole point.
        if let p = o.proxy, !p.isEmpty { args += ["--socks5-hostname", p] }
        if o.insecure { args.append("-k") }
        if o.http2 { args.append("--http2") }
        if o.compressed { args.append("--compressed") }

        let lines = headerLines(o.headers)
        for h in lines { args += ["-H", h] }

        let bearer = o.bearer.ntTrimmed
        if !bearer.isEmpty { args += ["-H", "Authorization: Bearer " + bearer] }
        else if !o.basicUser.isEmpty { args += ["-u", "\(o.basicUser):\(o.basicPass)"] }

        if !o.body.isEmpty && !["GET", "HEAD"].contains(method) {
            // --data-binary, so a JSON body with newlines arrives as written.
            args += ["--data-binary", o.body]
            let hasType = lines.contains { $0.range(of: #"^content-type\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil }
            if !hasType && !o.contentType.isEmpty { args += ["-H", "Content-Type: " + o.contentType] }
        }
        args += ["--", try checkUrl(o.url)]
        return (args, method)
    }

    static func headerLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { ($0.hasSuffix("\r") ? String($0.dropLast()) : $0).ntTrimmed }
            .filter { !$0.isEmpty && $0.contains(":") }
    }

    /// Validates and normalises a URL the way `new URL(...).toString()` does
    /// for http(s): scheme and host lower-cased, a default port dropped, an
    /// empty path written as "/".
    static func checkUrl(_ url: String) throws -> String {
        let u = url.ntTrimmed
        if u.isEmpty { throw AppError("Give a URL.") }
        let hasScheme = u.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) != nil
        let raw = (hasScheme ? u : "https://" + u).replacingOccurrences(of: " ", with: "%20")
        guard var c = URLComponents(string: raw), let scheme = c.scheme?.lowercased() else {
            throw AppError("That is not a URL curl can fetch.")
        }
        if !["http", "https"].contains(scheme) {
            // Anything the WHATWG parser would also have rejected says so first.
            if c.host == nil && c.path.isEmpty { throw AppError("That is not a URL curl can fetch.") }
            throw AppError("Only http and https URLs are fetched here.")
        }
        guard let host = c.host, !host.isEmpty else { throw AppError("That is not a URL curl can fetch.") }
        c.scheme = scheme
        c.host = host.lowercased()
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        if c.percentEncodedPath.isEmpty { c.percentEncodedPath = "/" }
        guard let s = c.string else { throw AppError("That is not a URL curl can fetch.") }
        return s
    }

    /// A copy-pasteable form of the same call, for a terminal or a ticket.
    static func command(_ args: [String]) -> String {
        let safe = try! NSRegularExpression(pattern: #"^[\w@%+=:,./-]+$"#)
        return "curl " + args.map { safe.matches($0) ? $0 : "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }

    static func commandFor(_ o: CurlOptions) throws -> String { command(try args(o).args) }

    /// Run it, and split the response into headers and body. `-i` puts the
    /// headers in stdout, so a redirect chain arrives as several header
    /// blocks; all of them are kept, because "which hop set that cookie" is a
    /// question this is used to answer.
    static func request(_ o: CurlOptions) async throws -> CurlResult {
        let (args, method) = try args(o)
        let started = Date()
        // 24 MB of output, as the original's maxBuffer: past that curl is
        // stopped and what arrived is shown, marked as cut short.
        let r = await NetProc.run("curl", args, timeout: TimeInterval(clampTimeout(o.timeout) + 5),
                                  maxBuffer: NetCurl.maxBuffer)
        let ms = (Date().timeIntervalSince(started) * 1000).rounded()
        if r.spawnError != nil { throw AppError("curl was not found on this machine.") }
        let failed = !r.ok
        if failed && r.stdout.isEmpty {
            var msg = r.err.ntTrimmed
            if msg.isEmpty { msg = r.timedOut ? "curl timed out" : "Command failed: curl (exit \(r.code))" }
            if msg.hasPrefix("curl:") { msg = String(msg.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            throw AppError(msg)
        }
        var res = parse(r.out)
        res.method = method
        res.url = args.last ?? ""
        res.command = command(args)
        res.ms = ms
        res.stderr = r.err.ntTrimmed
        if r.overflowed {
            res.stderr = [res.stderr, "stdout maxBuffer length exceeded"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        // A non-zero exit with output still says something went wrong late on.
        res.exitCode = failed ? (r.timedOut || r.overflowed ? nil : r.code) : 0
        // Formatted here, off the main thread and once, not in the view.
        (res.display, res.displayCut) = displayText(res.body, contentType: res.contentType)
        return res
    }

    /// Header blocks, then whatever is left is the body.
    static func parse(_ text: String) -> CurlResult {
        var blocks: [String] = []
        var rest = text
        let statusRe = try! NSRegularExpression(pattern: #"^HTTP/[\d.]+ \d{3}"#)
        // On NSString: Swift's own regex ranges treat "\r\n" as one character.
        let blankLine = try! NSRegularExpression(pattern: #"\r?\n\r?\n"#)
        while statusRe.matches(rest) {
            let ns = rest as NSString
            let cut = blankLine.rangeOfFirstMatch(in: rest, range: NSRange(location: 0, length: ns.length))
            guard cut.location != NSNotFound else { blocks.append(rest); rest = ""; break }
            blocks.append(ns.substring(to: cut.location))
            rest = ns.substring(from: cut.location + cut.length)
        }
        let hops: [CurlHop] = blocks.map { b in
            var lines = b.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
                .filter { !$0.isEmpty }
            let statusLine = lines.isEmpty ? "" : lines.removeFirst()
            let m = NetCheck.firstMatch(#"^HTTP/([\d.]+)\s+(\d{3})\s*(.*)$"#, statusLine)
            var headers: [(String, String)] = []
            for l in lines {
                guard let i = l.firstIndex(of: ":"), i > l.startIndex else { continue }
                let k = l[..<i].ntTrimmed
                let v = l[l.index(after: i)...].ntTrimmed
                if let at = headers.firstIndex(where: { $0.0 == k }) { headers[at].1 += ", " + v }
                else { headers.append((k, v)) }
            }
            return CurlHop(httpVersion: m?[1] ?? "", status: Int(m?[2] ?? "") ?? 0, statusText: m?[3] ?? "", headers: headers)
        }
        var r = CurlResult()
        let last = hops.last
        r.ok = last.map { $0.status < 400 } ?? false
        r.status = last?.status ?? 0
        r.statusText = last?.statusText ?? ""
        r.httpVersion = last?.httpVersion ?? ""
        r.headers = last?.headers ?? []
        r.hops = hops.count > 1 ? hops : []
        r.contentType = last.map { h in h.headers.first { $0.0 == "Content-Type" }?.1 ?? h.headers.first { $0.0 == "content-type" }?.1 ?? "" } ?? ""
        r.body = rest
        r.bytes = rest.utf8.count
        return r
    }

    /// The original's maxBuffer for curl.
    static let maxBuffer = 24 * 1024 * 1024
    /// How much of a body is drawn; the rest is in Copy body / Save output….
    static let drawLimit = 512 * 1024

    /// The body as drawn: pretty JSON (when it is JSON and not huge), cut to
    /// `drawLimit` characters. Returns whether it was cut.
    static func displayText(_ body: String, contentType: String) -> (String, Bool) {
        let pretty = body.utf8.count <= 8 * 1024 * 1024 ? displayBody(body, contentType: contentType) : body
        let u = pretty.utf16
        if u.count <= drawLimit { return (pretty, false) }
        return (String(decoding: Array(u.prefix(drawLimit)), as: UTF16.self), true)
    }

    /// Pretty JSON when the response says it is JSON, else the body as it came.
    static func displayBody(_ body: String, contentType: String) -> String {
        guard contentType.range(of: "json", options: .caseInsensitive) != nil, !body.ntTrimmed.isEmpty,
              let d = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return body }
        return String(decoding: out, as: UTF8.self).replacingOccurrences(of: " : ", with: ": ")
    }
}

/// Worked curl examples: the shapes people need, filled in ready to edit.
struct CurlExample {
    let name: String
    let why: String
    let method: String
    let url: String
    var headers = ""
    var body = ""
    var contentType = ""
    var bearer = ""
    var timeout: Int? = nil

    static func all(proxy: String?) -> [CurlExample] {
        [
            CurlExample(name: "GET a JSON API", why: "Read an endpoint and pretty-print what comes back",
                        method: "GET", url: "https://api.github.com/repos/gravitational/teleport",
                        headers: "Accept: application/json", contentType: "application/json"),
            CurlExample(name: "GET with a bearer token", why: "The usual shape for an API behind OAuth or a service token",
                        method: "GET", url: "https://api.example.com/v1/me",
                        headers: "Accept: application/json", contentType: "application/json", bearer: "PASTE_TOKEN_HERE"),
            CurlExample(name: "POST JSON", why: "Create something. The body is sent exactly as typed.",
                        method: "POST", url: "https://api.example.com/v1/things", headers: "Accept: application/json",
                        body: "{\n  \"name\": \"example\",\n  \"enabled\": true\n}", contentType: "application/json"),
            CurlExample(name: "POST a form", why: "An old-fashioned form post — key=value&key=value",
                        method: "POST", url: "https://example.com/login", body: "username=admin&password=hunter2",
                        contentType: "application/x-www-form-urlencoded"),
            CurlExample(name: "PATCH one field", why: "Change part of a resource without sending the whole thing",
                        method: "PATCH", url: "https://api.example.com/v1/things/42", headers: "Accept: application/json",
                        body: "{ \"enabled\": false }", contentType: "application/json"),
            CurlExample(name: "DELETE a resource", why: "And see whether it answers 204 or an error worth reading",
                        method: "DELETE", url: "https://api.example.com/v1/things/42", headers: "Accept: application/json"),
            CurlExample(name: "Post to a webhook", why: "Slack, Teams, an alertmanager receiver — a JSON body to a URL",
                        method: "POST", url: "https://hooks.example.com/services/T000/B000/XXXX",
                        body: "{ \"text\": \"ServerLife was here\" }", contentType: "application/json"),
            CurlExample(name: "Health check", why: "Is it up, what does it say, and how long did it take",
                        method: "GET", url: "https://example.com/healthz", timeout: 5),
            CurlExample(name: "HEAD — headers only", why: "Content type, length, caching and redirects, without the body",
                        method: "HEAD", url: "https://example.com/large-file.iso"),
            CurlExample(name: "A Teleport proxy", why: "The unauthenticated ping every cluster answers",
                        method: "GET", url: proxy.map { "https://\($0)/webapi/ping" } ?? "https://teleport.example.com/webapi/ping",
                        headers: "Accept: application/json"),
        ]
    }
}
