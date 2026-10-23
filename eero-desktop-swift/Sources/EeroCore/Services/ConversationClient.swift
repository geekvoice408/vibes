import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Response whose body arrives incrementally.
public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var setCookies: [String]
    public var body: AsyncThrowingStream<Data, Error>
    public init(status: Int, headers: [String: String] = [:], setCookies: [String] = [], body: AsyncThrowingStream<Data, Error>) {
        self.status = status; self.headers = headers; self.setCookies = setCookies; self.body = body
    }
    public var isSuccess: Bool { (200..<300).contains(status) }

    /// Reads the remaining body (used for error envelopes), up to `limit` bytes.
    public func collect(limit: Int = 4 * 1024 * 1024) async throws -> Data {
        var data = Data()
        for try await chunk in body { data.append(chunk); if data.count > limit { break } }
        return data
    }
}

/// Streaming HTTP abstraction (the Windows client used `HttpCompletionOption.ResponseHeadersRead`).
public protocol HTTPStreamingTransport: Sendable {
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// URLSession streaming transport with cookies and redirects disabled.
public final class URLSessionStreamingTransport: NSObject, HTTPStreamingTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 60
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    public override init() { super.init() }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        #if canImport(Darwin)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data(); chunk.reserveCapacity(2048)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= 2048 { continuation.yield(chunk); chunk = Data() }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); bytes.task.cancel() }
        }
        #else
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = AsyncThrowingStream<Data, Error> { c in c.yield(data); c.finish() }
        #endif
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
        let cookie = http.value(forHTTPHeaderField: "Set-Cookie")
        return HTTPStreamResponse(status: http.statusCode, headers: headers, setCookies: cookie.map { [$0] } ?? [], body: body)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Streams eero chat replies (port of `EeroApi.StreamConversation`). It borrows the signed-in session from
/// `EeroAPI`, retries once after an explicit session-refresh rejection, commits rotated cookies back into the
/// API, and does not hold the API while reading a long reply, so refresh, switching and sign-out stay available.
/// Cancel the calling task to stop delivery.
public struct ConversationClient: Sendable {
    public static let streamLimit = 8 * 1024 * 1024
    private let api: EeroAPI
    private let transport: HTTPStreamingTransport

    public init(api: EeroAPI, transport: HTTPStreamingTransport = URLSessionStreamingTransport()) {
        self.api = api; self.transport = transport
    }

    public func stream(_ body: JSON, receive: (JSON) async throws -> Void) async throws {
        var response: HTTPStreamResponse?
        for attempt in 0..<2 {
            guard let token = await api.sessionCredential, !token.isEmpty else { throw ApiError(code: 401, error: "session.missing", session: true) }
            let r = try await transport.stream(try request("PUT", "/2.2/conversations/messages", body, token))
            try Task.checkCancellation()
            if !r.isSuccess {
                let envelope = (try? JSON.parse(try await r.collect())) ?? .null
                let failure = ApiError(code: r.status, error: envelope.s("meta", "error"), session: true)
                guard attempt == 0 && failure.code == 401 && failure.apiError == "error.session.refresh" else { throw failure }
                try await refresh(token)
                continue
            }
            if let cookie = ConversationClient.sessionCookie(r.setCookies) { try await adopt(cookie) }
            response = r
            break
        }
        guard let response else { throw ApiError(code: 401, error: "error.session.refresh", session: true) }
        let parser = JsonObjectStream()
        var total = 0
        for try await chunk in response.body {
            try Task.checkCancellation()
            total += chunk.count
            if total > ConversationClient.streamLimit { throw EeroError.data("The chat response exceeded the size limit.") }
            var values: [JSON] = []
            try parser.feed(chunk) { values.append($0) }
            for value in values { try Task.checkCancellation(); try await receive(value) }
        }
        try Task.checkCancellation()
        try parser.finish()
    }

    /// Convenience wrapper that delivers values as an async sequence; cancelling iteration stops the request.
    public func values(_ body: JSON) -> AsyncThrowingStream<JSON, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { try await stream(body) { continuation.yield($0) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(_ method: String, _ path: String, _ body: JSON?, _ token: String) throws -> URLRequest {
        var req = URLRequest(url: try EeroAPI.resource(path))
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue(EeroAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("s=" + (try EeroAPI.validToken(token)), forHTTPHeaderField: "Cookie")
        if let body {
            req.httpBody = body.data
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// `POST login/refresh` with the current credential, committing the refreshed session into `EeroAPI`.
    private func refresh(_ token: String) async throws {
        let r = try await transport.stream(try request("POST", "login/refresh", nil, token))
        try Task.checkCancellation()
        let text = try await r.collect()
        var envelope: JSON = .null
        if !String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { envelope = try JSON.parse(text) }
            catch { if r.isSuccess { throw EeroError.data("eero returned an unexpected response. Please try again later.") } }
        }
        var code = r.status
        if let parsed = Int(envelope.s("meta", "code")) { code = parsed }
        if !r.isSuccess || code < 200 || code >= 300 {
            throw ApiError(code: r.isSuccess ? code : r.status, error: envelope.s("meta", "error"), session: true)
        }
        try await adopt(ConversationClient.sessionCookie(r.setCookies) ?? envelope["data"].s("user_token").nilIfEmpty ?? token)
    }

    private func adopt(_ credential: String) async throws {
        try await api.adopt(VerifiedBrowserIdentity(account: .null, sessionCredential: try EeroAPI.validToken(credential)))
    }

    static func sessionCookie(_ setCookies: [String]) -> String? {
        var cookie: String?
        guard let re = try? NSRegularExpression(pattern: #"(?:^|,\s*)s=([^; ,]+)"#) else { return nil }
        for s in setCookies {
            let ns = s as NSString
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) { cookie = ns.substring(with: m.range(at: 1)) }
        }
        return cookie
    }
}
