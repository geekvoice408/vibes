import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so tests can replace the network (the Windows client used an HttpMessageHandler).
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var setCookies: [String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], setCookies: [String] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.setCookies = setCookies; self.body = body
    }
    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession transport with cookies and redirects disabled, matching the Windows HttpClientHandler.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 30
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    public override init() { super.init() }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
        let cookieHeader = http.value(forHTTPHeaderField: "Set-Cookie")
        return HTTPResponse(status: http.statusCode, headers: headers, setCookies: cookieHeader.map { [$0] } ?? [], body: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Account identity verified from a browser-issued session (port of `VerifiedBrowserIdentity`).
public struct VerifiedBrowserIdentity: Sendable {
    public let account: JSON
    let sessionCredential: String
}

/// eero cloud API client (port of `EeroApi`). An actor serialises requests like the Windows SemaphoreSlim gate.
public actor EeroAPI {
    public static let origin = "https://api-user.e2ro.com"
    public static let userAgent = "EeroDesktop/1.0.0 (macOS; unofficial)"

    private let transport: HTTPTransport
    private let store: SessionStore
    private var pending: String?
    private var registering = false
    private var token: String?
    public var remember = false

    public init(store: SessionStore, transport: HTTPTransport = URLSessionTransport()) {
        self.store = store
        self.transport = transport
    }

    public var signedIn: Bool { !(token ?? "").isEmpty }
    public var isPending: Bool { !(pending ?? "").isEmpty }
    public var isRegistering: Bool { registering }
    public func setRemember(_ value: Bool) { remember = value }

    @discardableResult
    public func restore() -> Bool {
        let saved = store.load()
        do { token = try saved.map(EeroAPI.validToken) } catch { store.clear(); token = nil }
        remember = signedIn
        return signedIn
    }

    public func checkConnection() async throws {
        do { _ = try await raw("GET", "account", nil, credential: nil, form: false, session: false) }
        catch let e as ApiError where e.code == 401 { return }
        throw EeroError.data("eero returned an unexpected response to the connection check.")
    }

    /// Resolves an API path to a trusted URL on api-user.e2ro.com (port of `EeroApi.Resource`).
    public static func resource(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw EeroError.argument("The server did not provide a resource URL.") }
        let untrusted = EeroError.argument("Untrusted API resource URL.")
        var text: String
        if path.hasPrefix("/") { text = origin + path }
        else if path.lowercased().hasPrefix("https://") { text = path }
        else if path.lowercased().hasPrefix("http:") || path.contains("://") { throw untrusted }
        else { text = origin + "/2.2/" + path.drop(while: { $0 == "/" }) }
        guard let c = URLComponents(string: text), let url = c.url else { throw untrusted }
        let p = c.percentEncodedPath
        // Reject dot segments (including percent-encoded ones) so the version-prefix check below cannot be escaped.
        let segments = p.split(separator: "/", omittingEmptySubsequences: false).map { $0.removingPercentEncoding ?? String($0) }
        if segments.contains(where: { $0 == "." || $0 == ".." }) { throw untrusted }
        guard c.scheme == "https", c.host == "api-user.e2ro.com", c.port == nil || c.port == 443,
              c.user == nil, c.password == nil, c.fragment == nil,
              p.hasPrefix("/2.2/") || p.hasPrefix("/2.3/") || p.hasPrefix("/2.4/") else { throw untrusted }
        return url
    }

    static func validToken(_ t: String?) throws -> String {
        if let t, t.hasPrefix("eero-web-") { throw EeroError.data("This retired preview session requires a fresh email or phone sign-in.") }
        guard let t, !t.isEmpty, t.count <= 8192,
              !t.unicodeScalars.contains(where: { $0.value <= 32 || $0.value >= 127 || $0 == ";" || $0 == "," })
        else { throw EeroError.data("eero returned an invalid session credential.") }
        return t
    }

    private func commit(_ t: String) throws {
        token = try EeroAPI.validToken(t)
        if remember { try store.save(token!) } else { store.clear() }
    }

    struct Reply { var data: JSON; var cookie: String? }

    static func formEncode(_ body: JSON) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let pairs = (body.object ?? [:]).sorted { $0.key < $1.key }.map { k, v -> String in
            let value: String
            if case .bool(let b) = v { value = b ? "true" : "false" } else { value = v.string }
            func enc(_ s: String) -> String { (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: "%20", with: "+") }
            return enc(k) + "=" + enc(value)
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private func raw(_ method: String, _ path: String, _ body: JSON?, credential: String?, form: Bool, session: Bool) async throws -> Reply {
        var req = URLRequest(url: try EeroAPI.resource(path))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(EeroAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential, !credential.isEmpty { req.setValue("s=" + (try EeroAPI.validToken(credential)), forHTTPHeaderField: "Cookie") }
        if let body {
            if form {
                req.httpBody = EeroAPI.formEncode(body)
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            } else {
                req.httpBody = body.data
                req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        let response = try await transport.send(req)
        try Task.checkCancellation()
        var envelope: JSON = .null
        if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { envelope = try JSON.parse(response.body) }
            catch { if response.isSuccess { throw EeroError.data("eero returned an unexpected response. Please try again later.") } }
        }
        var code = response.status
        if let parsed = Int(envelope.s("meta", "code")) { code = parsed }
        if !response.isSuccess || code < 200 || code >= 300 {
            throw ApiError(code: response.isSuccess ? code : response.status, error: envelope.s("meta", "error"), session: session)
        }
        var cookie: String?
        for s in response.setCookies {
            let ns = s as NSString
            let re = try NSRegularExpression(pattern: #"(?:^|,\s*)s=([^; ,]+)"#)
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                cookie = try EeroAPI.validToken(ns.substring(with: m.range(at: 1)))
            }
        }
        return Reply(data: envelope["data"], cookie: cookie)
    }

    public func beginLogin(_ identifier: String) async throws {
        pending = nil; registering = false; token = nil; store.clear()
        let reply = try await raw("POST", "login", .obj(("login", identifier)), credential: nil, form: true, session: false)
        pending = try EeroAPI.validToken(reply.data.s("user_token"))
    }

    public func verify(_ code: String) async throws {
        guard isPending else { throw EeroError.operation("Request a verification code first.") }
        if registering { throw EeroError.operation("Use account registration verification for this code.") }
        let reply = try await raw("POST", "login/verify", .obj(("code", code)), credential: pending, form: true, session: false)
        try commit(reply.cookie ?? reply.data.first("user_token", "session_token").nilIfEmpty ?? pending!)
        pending = nil
    }

    public func cancelLogin() { pending = nil; registering = false }

    public func importBrowserSession(_ credential: String) async throws {
        let candidate = try EeroAPI.validToken(credential)
        let verified = try await raw("GET", "account", nil, credential: candidate, form: false, session: true)
        try Task.checkCancellation()
        try commit(verified.cookie ?? candidate)
        pending = nil; registering = false
    }

    public func inspectBrowserSession(_ credential: String) async throws -> VerifiedBrowserIdentity {
        let candidate = try EeroAPI.validToken(credential)
        let reply = try await raw("GET", "account", nil, credential: candidate, form: false, session: true)
        return VerifiedBrowserIdentity(account: reply.data, sessionCredential: reply.cookie ?? candidate)
    }

    /// Commits a session previously verified by `inspectBrowserSession`.
    public func adopt(_ identity: VerifiedBrowserIdentity) throws {
        try commit(identity.sessionCredential); pending = nil; registering = false
    }

    public func amazonSignIn(accessToken: String) async throws -> JSON {
        let login = try await raw("POST", "login/amazon", .obj(("auth_token", try EeroAPI.validToken(accessToken)), ("create_account", false)), credential: nil, form: true, session: false)
        let candidate = try login.cookie ?? EeroAPI.validToken(login.data.s("user_token"))
        let verified = try await raw("GET", "account", nil, credential: candidate, form: false, session: true)
        if verified.data.isNull || (verified.data.first("user_id", "id", "url").isEmpty && verified.data["email"].isNull) {
            throw EeroError.data("eero did not return a valid account identity.")
        }
        try Task.checkCancellation()
        try commit(verified.cookie ?? candidate); pending = nil; registering = false
        return verified.data
    }

    public func registrationConsents(country: String) async throws -> JSON {
        let q = country.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? country
        return try await raw("GET", "consents/account?country=" + q, nil, credential: nil, form: false, session: false).data
    }

    public func beginRegistration(name: String, email: String, phone: String) async throws {
        pending = nil; token = nil; registering = false; store.clear()
        let r = try await raw("POST", "register", .obj(("name", name), ("email", email), ("phone", phone), ("send_verification", true)), credential: nil, form: true, session: false)
        pending = try EeroAPI.validToken(r.data.s("user_token")); registering = true
    }

    public func verifyRegistration(code: String, country: String, consents: JSON) async throws {
        guard isPending, registering else { throw EeroError.operation("Start account creation first.") }
        let r = try await raw("POST", "register/verify", .obj(("code", code), ("country", country), ("consents", consents)), credential: pending, form: false, session: false)
        try commit(r.cookie ?? r.data.first("user_token", "session_token").nilIfEmpty ?? pending!)
        pending = nil; registering = false
    }

    public func resend() async throws {
        guard isPending else { throw EeroError.operation("Request a verification code first.") }
        let r = try await raw("POST", registering ? "register/phone/resend" : "login/resend", nil, credential: pending, form: false, session: false)
        if let updated = r.cookie ?? r.data.s("user_token").nilIfEmpty { pending = try EeroAPI.validToken(updated) }
    }

    /// Authenticated request with automatic session refresh (port of `EeroApi.Send`).
    @discardableResult
    public func send(_ method: String, _ path: String, _ body: JSON? = nil, form: Bool = false) async throws -> JSON {
        guard signedIn else { throw ApiError(code: 401, error: "session.missing", session: true) }
        var r: Reply
        do { r = try await raw(method, path, body, credential: token, form: form, session: true) }
        catch let ex as ApiError where ex.code == 401 && ex.apiError == "error.session.refresh" {
            let fresh = try await raw("POST", "login/refresh", nil, credential: token, form: false, session: true)
            try commit(fresh.cookie ?? fresh.data.s("user_token").nilIfEmpty ?? token!)
            r = try await raw(method, path, body, credential: token, form: form, session: true)
        }
        if let c = r.cookie { try commit(c) }
        return r.data
    }

    public func logout() async {
        if signedIn { _ = try? await send("POST", "logout") }
        forget()
    }

    public func forget() { token = nil; pending = nil; registering = false; remember = false; store.clear() }

    /// Current session credential, for handing to an embedded web view (service browser).
    public var sessionCredential: String? { token }
}
