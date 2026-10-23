import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EeroCore

/// Scripted HTTP transport for service tests (port of the Windows `ServiceFake` and `Fake` handlers).
/// Each queued step receives one request and returns its reply; requests beyond the script fail.
final class ServiceFakeTransport: HTTPTransport, HTTPStreamingTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var setCookie: String?
        var body: AsyncThrowingStream<Data, Error>
        init(status: Int = 200, setCookie: String? = nil, text: String) {
            self.status = status; self.setCookie = setCookie
            let data = Data(text.utf8)
            body = AsyncThrowingStream { c in c.yield(data); c.finish() }
        }
        init(status: Int = 200, setCookie: String? = nil, body: AsyncThrowingStream<Data, Error>) {
            self.status = status; self.setCookie = setCookie; self.body = body
        }
        static func json(_ value: JSON) -> Reply { Reply(text: value.serialized()) }
    }
    typealias Step = @Sendable (URLRequest) async throws -> Reply

    private let lock = NSLock()
    private var steps: [Step] = []
    private(set) var requests: [URLRequest] = []

    var remaining: Int { lock.lock(); defer { lock.unlock() }; return steps.count }

    func enqueue(_ step: @escaping Step) { lock.lock(); steps.append(step); lock.unlock() }

    /// eero API step with the checks of the Windows `Fake` handler.
    func api(_ method: String, _ path: String, query: String? = nil, cookie: String?, body: JSON? = nil, form: [String: String]? = nil,
             status: Int = 200, json: String? = nil, setCookie: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        enqueue { r in
            let c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(r.httpMethod, method, "request method", file: file, line: line)
            XCTAssertEqual(c.percentEncodedPath, path, "request path", file: file, line: line)
            if let query { XCTAssertEqual(c.percentEncodedQuery, query, "correct query parameters", file: file, line: line) }
            XCTAssertEqual(c.host, "api-user.e2ro.com", "trusted host", file: file, line: line)
            XCTAssertEqual(c.scheme, "https", "HTTPS", file: file, line: line)
            XCTAssertEqual(r.value(forHTTPHeaderField: "Cookie"), cookie, "correct cookie scope", file: file, line: line)
            if let body { XCTAssertEqual(try? JSON.parse(r.httpBody ?? Data()), body, "request payload", file: file, line: line) }
            if let form {
                XCTAssertEqual(ServiceFakeTransport.formFields(r.httpBody), form, "form payload", file: file, line: line)
                XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded", "form content type", file: file, line: line)
            }
            return Reply(status: status, setCookie: setCookie, text: json ?? #"{"meta":{"code":200},"data":{}}"#)
        }
    }

    static func formFields(_ data: Data?) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: data ?? Data(), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    private func take(_ request: URLRequest) -> Step? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    private func next(_ request: URLRequest) async throws -> Reply {
        guard let step = take(request) else {
            XCTFail("Unexpected service request: \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
            throw URLError(.cannotConnectToHost)
        }
        return try await step(request)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let reply = try await next(request)
        var data = Data()
        for try await chunk in reply.body { data.append(chunk) }
        return HTTPResponse(status: reply.status, setCookies: reply.setCookie.map { [$0] } ?? [], body: data)
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let reply = try await next(request)
        return HTTPStreamResponse(status: reply.status, setCookies: reply.setCookie.map { [$0] } ?? [], body: reply.body)
    }
}

/// Asserts that `body` throws an error of type `E` and returns it.
@discardableResult
func serviceExpectError<E: Error>(_ type: E.Type, _ message: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () async throws -> Void) async -> E? {
    do { try await body(); XCTFail("Expected \(E.self): " + message, file: file, line: line); return nil }
    catch let e as E { return e }
    catch { XCTFail("Expected \(E.self) but got \(error): " + message, file: file, line: line); return nil }
}

/// Cancels the task running the current request (the Windows tests cancelled a CancellationTokenSource).
func serviceCancelCurrentTask() { withUnsafeCurrentTask { $0?.cancel() } }

/// Thread-safe collector for values delivered from streams.
final class ServiceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

final class ServiceIntegrationTests: XCTestCase {
    static let chatStream = "{\"type\":\"InitialMessage\",\"content\":\"héllo { \\\"braces\\\" } 😀\"}\n{\"type\":\"MessageDelta\",\"content\":\"tail\",\"finished\":true}"

    func chat() throws -> JSON { try ConversationContracts.request("network-1", "conversation-1", "Check connectivity", mcpToken: "test-mcp") }

    func testRetiredPreviewCredentialsAreRejected() async {
        let store = MemorySessionStore("eero-web-v1.retired-preview")
        let fake = ServiceFakeTransport()
        let api = EeroAPI(store: store, transport: fake)
        let restored = await api.restore()
        XCTAssertFalse(restored); XCTAssertNil(store.load(), "retired Insight credentials cannot be restored as native API cookies")
        let e = await serviceExpectError(EeroError.self, "retired web credentials are rejected before making native API requests") {
            try await api.importBrowserSession("eero-web-v1.retired-preview")
        }
        XCTAssertEqual(e?.kind, .invalidData)
        let signedIn = await api.signedIn
        XCTAssertTrue(fake.requests.isEmpty && !signedIn, "rejecting a retired preview credential makes no request and leaves the app signed out")
    }

    func testJsonObjectStreamFramesAcrossChunkSizes() throws {
        let bytes = Array(Data(Self.chatStream.utf8))
        let chars = Array(Self.chatStream)
        for chunk in 1...9 {
            for useBytes in [true, false] {
                let parser = JsonObjectStream()
                var messages: [JSON] = []
                if useBytes {
                    for start in stride(from: 0, to: bytes.count, by: chunk) {
                        try parser.feed(Data(bytes[start..<min(start + chunk, bytes.count)])) { messages.append($0) }
                    }
                } else {
                    for start in stride(from: 0, to: chars.count, by: chunk) {
                        try parser.feed(String(chars[start..<min(start + chunk, chars.count)])) { messages.append($0) }
                    }
                }
                try parser.finish()
                XCTAssertEqual(messages.count, 2, "chat JSON framing across chunk size \(chunk)")
                XCTAssertTrue(messages.first?.s("content").contains("😀") == true)
                XCTAssertEqual(messages.last?.s("content"), "tail")
            }
        }
    }

    func testJsonObjectStreamRejectsTruncatedAndForeignStreams() throws {
        let parser = JsonObjectStream()
        try parser.feed("{\"message\":") { _ in XCTFail("no value expected") }
        XCTAssertThrowsError(try parser.finish(), "truncated chat stream is reported, not accepted as a complete reply") {
            XCTAssertEqual(($0 as? EeroError)?.message, "The chat response was interrupted. Reload history before sending again.")
        }
        XCTAssertThrowsError(try JsonObjectStream().feed("<html>") { _ in }, "HTML cannot masquerade as a chat stream") {
            XCTAssertEqual(($0 as? EeroError)?.message, "The chat service returned an unsupported stream.")
        }
        XCTAssertThrowsError(try JsonObjectStream().feed("{\"a\":" + String(repeating: "1", count: JsonObjectStream.objectLimit)) { _ in }) {
            XCTAssertEqual(($0 as? EeroError)?.message, "A chat response exceeded the size limit.")
        }
        var values: [JSON] = []
        try JsonObjectStream().feed("  \n{\"a\":[1,{\"b\":\"]}\"}]} {\"c\":\"\\\\\"}") { values.append($0) }
        XCTAssertEqual(values, [JSON.obj(("a", JSON.array([1, JSON.obj(("b", "]}"))]))), JSON.obj(("c", "\\"))])
    }

    func testConversationRequestContract() throws {
        XCTAssertThrowsError(try ConversationContracts.request("network", nil, String(repeating: "x", count: 8001)), "chat message length is checked before sending")
        XCTAssertThrowsError(try ConversationContracts.request("network", nil, "   "))
        XCTAssertThrowsError(try ConversationContracts.request(" ", nil, "hi")) {
            XCTAssertEqual(($0 as? EeroError)?.message, "Select a network before opening chat.")
        }
        let chat = try chat()
        XCTAssertEqual(chat.s("context", "focused_network_id"), "network-1")
        XCTAssertEqual(chat.get("context", "client_capabilities", "opt_in_widgets"), .array([]), "chat sends network context and no unsupported opt-in widgets")
        XCTAssertEqual(chat.s("conversation_id"), "conversation-1")
        XCTAssertEqual(chat.s("mcp_token"), "test-mcp")
        XCTAssertEqual(chat.s("message"), "Check connectivity")
        let grant = try ConversationContracts.request("network-1", "conversation-1", nil, permission: JSON.obj(("approved", false), ("interrupt_id", "permission-1")))
        XCTAssertFalse(grant.b("permission_grant", "approved"))
        XCTAssertEqual(grant.s("permission_grant", "interrupt_id"), "permission-1", "declining a permission sends the exact interrupt ID without granting it")
        XCTAssertTrue(grant["message"].isNull)
        XCTAssertEqual(ConversationContracts.error(ApiError(code: 403, error: "error.conversations.not_available", session: true)), "eero has not enabled chat for this account or network.")
        XCTAssertEqual(ConversationContracts.error(ApiError(code: 403, error: "error.conversations.user_blocked", session: true)), "eero has restricted chat access for this account.")
        XCTAssertEqual(ConversationContracts.error(ApiError(code: 429, error: "", session: true)), "eero is limiting requests. Wait a few minutes before trying again.")
    }

    func testAuthenticatedChatStreamRotatesCookie() async throws {
        let chat = try chat()
        let fake = ServiceFakeTransport()
        fake.api("GET", "/2.2/account", cookie: "s=stream-session", json: #"{"meta":{"code":200},"data":{}}"#)
        fake.enqueue { r in
            XCTAssertEqual(r.httpMethod, "PUT"); XCTAssertEqual(r.url?.path, "/2.2/conversations/messages")
            XCTAssertEqual(r.value(forHTTPHeaderField: "Cookie"), "s=stream-session")
            XCTAssertEqual(try? JSON.parse(r.httpBody ?? Data()), chat)
            return .init(setCookie: "s=stream-rotated; Secure; HttpOnly", text: Self.chatStream)
        }
        fake.api("GET", "/2.2/account", cookie: "s=stream-rotated", json: #"{"data":{}}"#)
        let store = MemorySessionStore()
        let api = EeroAPI(store: store, transport: fake)
        await api.setRemember(true)
        try await api.importBrowserSession("stream-session")
        var values: [JSON] = []
        try await ConversationClient(api: api, transport: fake).stream(chat) { values.append($0) }
        try await api.send("GET", "account")
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(fake.remaining, 0, "authenticated chat stream rotates its cookie and releases the API gate")
        XCTAssertEqual(store.load(), "stream-rotated")
    }

    func testChatRetriesOnceAfterSessionRefresh() async throws {
        let chat = try chat()
        let fake = ServiceFakeTransport()
        fake.api("GET", "/2.2/account", cookie: "s=old-chat")
        fake.enqueue { r in
            XCTAssertEqual(r.value(forHTTPHeaderField: "Cookie"), "s=old-chat")
            return .init(status: 401, text: #"{"meta":{"code":401,"error":"error.session.refresh"}}"#)
        }
        fake.api("POST", "/2.2/login/refresh", cookie: "s=old-chat", json: #"{"data":{"user_token":"fresh-chat"}}"#)
        fake.enqueue { r in
            XCTAssertEqual(r.value(forHTTPHeaderField: "Cookie"), "s=fresh-chat", "chat retries with the refreshed session")
            return .init(text: Self.chatStream)
        }
        let api = EeroAPI(store: MemorySessionStore(), transport: fake)
        try await api.importBrowserSession("old-chat")
        let box = ServiceBox<JSON>()
        for try await value in ConversationClient(api: api, transport: fake).values(chat) { box.append(value) }
        XCTAssertEqual(box.values.count, 2)
        XCTAssertEqual(fake.remaining, 0)
        let credential = await api.sessionCredential
        XCTAssertEqual(credential, "fresh-chat")

        // A second refresh rejection is surfaced rather than retried forever.
        fake.enqueue { _ in .init(status: 401, text: #"{"meta":{"code":401,"error":"error.session.refresh"}}"#) }
        fake.api("POST", "/2.2/login/refresh", cookie: "s=fresh-chat", json: #"{"data":{}}"#)
        fake.enqueue { _ in .init(status: 401, text: #"{"meta":{"code":401,"error":"error.session.refresh"}}"#) }
        let e = await serviceExpectError(ApiError.self, "repeated refresh rejection") {
            try await ConversationClient(api: api, transport: fake).stream(chat) { _ in }
        }
        XCTAssertEqual(e?.code, 401)
        XCTAssertEqual(fake.remaining, 0)
    }

    func testChatRequiresSignIn() async throws {
        let api = EeroAPI(store: MemorySessionStore(), transport: ServiceFakeTransport())
        let e = await serviceExpectError(ApiError.self, "signed-out chat") {
            try await ConversationClient(api: api, transport: ServiceFakeTransport()).stream(try self.chat()) { _ in }
        }
        XCTAssertEqual(e?.apiError, "session.missing")
    }

    func testChatCancellationStopsDelivery() async throws {
        let chat = try chat()
        let fake = ServiceFakeTransport()
        fake.api("GET", "/2.2/account", cookie: "s=cancel-session")
        fake.enqueue { _ in .init(text: Self.chatStream) }
        fake.api("GET", "/2.2/account", cookie: "s=cancel-session")
        let api = EeroAPI(store: MemorySessionStore(), transport: fake)
        try await api.importBrowserSession("cancel-session")
        let seen = ServiceBox<JSON>()
        let task = Task { try await ConversationClient(api: api, transport: fake).stream(chat) { seen.append($0); serviceCancelCurrentTask() } }
        let result = await task.result
        if case .success = result { XCTFail("chat cancellation aborts delivery inside a buffered response") }
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
        try await api.send("GET", "account")
        XCTAssertEqual(seen.values.count, 1)
        XCTAssertEqual(fake.remaining, 0, "cancelled chat releases the API gate without delivering later events")
    }

    func testChatStreamingDoesNotBlockOtherRequests() async throws {
        let chat = try chat()
        let fake = ServiceFakeTransport()
        let started = ServiceBox<Bool>()
        let held = ServiceBox<AsyncThrowingStream<Data, Error>.Continuation>()
        fake.enqueue { _ in
            started.append(true)
            return .init(body: AsyncThrowingStream<Data, Error> { held.append($0) })
        }
        fake.enqueue { r in
            XCTAssertEqual(r.httpMethod, "GET", "normal account refresh runs while chat is awaiting its next chunk")
            return .json(JSON.obj(("data", JSON.obj())))
        }
        let api = EeroAPI(store: MemorySessionStore("preserved-session"), transport: fake)
        await api.restore()
        let streaming = Task { try await ConversationClient(api: api, transport: fake).stream(chat) { _ in } }
        while started.values.isEmpty { await Task.yield() }
        try await api.send("GET", "account")
        streaming.cancel()
        let result = await streaming.result
        if case .success = result { XCTFail("cancelled stream should not complete normally") }
        XCTAssertEqual(fake.remaining, 0, "chat streaming does not lock out refresh or sign-out operations")
    }

    func testChatErrorEnvelopeAndOversizeStream() async throws {
        let fake = ServiceFakeTransport()
        fake.enqueue { _ in .init(status: 403, text: #"{"meta":{"code":403,"error":"error.conversations.user_blocked"}}"#) }
        let api = EeroAPI(store: MemorySessionStore("chat-session"), transport: fake)
        await api.restore()
        let e = await serviceExpectError(ApiError.self, "chat rejection") {
            try await ConversationClient(api: api, transport: fake).stream(try self.chat()) { _ in }
        }
        XCTAssertEqual(e.map(ConversationContracts.error), "eero has restricted chat access for this account.")
        fake.enqueue { _ in .init(text: "{\"a\":1}{\"b\":") }
        let interrupted = await serviceExpectError(EeroError.self, "interrupted stream") {
            try await ConversationClient(api: api, transport: fake).stream(try self.chat()) { _ in }
        }
        XCTAssertEqual(interrupted, JsonObjectStream.interrupted)
    }

    func testRejectedAmazonLoginPreservesSession() async throws {
        let fake = ServiceFakeTransport()
        fake.api("GET", "/2.2/account", cookie: "s=old-session")
        fake.api("POST", "/2.2/login/amazon", cookie: nil, form: ["auth_token": "test-amazon", "create_account": "false"], json: #"{"data":{"user_token":"candidate-amazon"}}"#)
        fake.api("GET", "/2.2/account", cookie: "s=candidate-amazon", status: 403, json: #"{"meta":{"code":403}}"#)
        fake.api("GET", "/2.2/account", cookie: "s=old-session")
        let api = EeroAPI(store: MemorySessionStore(), transport: fake)
        try await api.importBrowserSession("old-session")
        await serviceExpectError(ApiError.self, "Amazon sign-in is rejected if eero cannot verify the resulting account") {
            _ = try await api.amazonSignIn(accessToken: "test-amazon")
        }
        try await api.send("GET", "account")
        let signedIn = await api.signedIn
        XCTAssertTrue(signedIn && fake.remaining == 0, "rejected Amazon login preserves the existing verified eero session")
    }

    func testBillingReturnRecognisesOnlyCompletionCallbacks() {
        XCTAssertTrue(BillingContracts.return(URL(string: "eero://jumpto/pluspurchasecomplete")!))
        XCTAssertTrue(BillingContracts.return("eero://jumpto/datapackpurchasecomplete/"))
        XCTAssertTrue(BillingContracts.return("https://app.eero.com/businesspurchasecomplete/index.html"))
        XCTAssertTrue(BillingContracts.return("https://app.eero.com:443/jumpto/pluspurchasecomplete"))
        XCTAssertFalse(BillingContracts.return(URL(string: "eero://jumpto/reset")!))
        XCTAssertFalse(BillingContracts.return(URL(string: "https://app.eero.com.evil.test/pluspurchasecomplete")!))
        XCTAssertFalse(BillingContracts.return("https://user@app.eero.com/pluspurchasecomplete"))
        XCTAssertFalse(BillingContracts.return("http://app.eero.com/pluspurchasecomplete"))
        XCTAssertFalse(BillingContracts.return("https://app.eero.com:8443/pluspurchasecomplete"))
        XCTAssertFalse(BillingContracts.return("https://app.eero.com/other/pluspurchasecomplete"))
    }

    func testInspectedProviderIdentityIsNotCommittedUntilImported() async throws {
        let store = MemorySessionStore()
        let fake = ServiceFakeTransport()
        fake.api("GET", "/2.2/account", cookie: "s=provider-candidate", json: #"{"data":{"name":"Sample person"}}"#, setCookie: "s=provider-rotated; Secure; HttpOnly")
        fake.api("GET", "/2.2/account", cookie: "s=provider-rotated", setCookie: "s=provider-final; Secure; HttpOnly")
        let api = EeroAPI(store: store, transport: fake)
        await api.setRemember(true)
        let identity = try await api.inspectBrowserSession("provider-candidate")
        let signedIn = await api.signedIn
        XCTAssertFalse(signedIn); XCTAssertNil(store.load())
        XCTAssertEqual(identity.account.s("name"), "Sample person", "provider identity can be reviewed without signing in or saving credentials")
        XCTAssertFalse(identity.account.serialized().contains("provider-rotated"), "reviewed identity does not serialize its session credential")
        try await api.importBrowserSession(identity.sessionCredential)
        XCTAssertEqual(store.load(), "provider-final", "reviewed provider sign-in preserves cookie rotation through final verification")
    }

    func testCancelledAlternateSignInPreservesSavedSession() async {
        let store = MemorySessionStore("preserved-session")
        let fake = ServiceFakeTransport()
        fake.enqueue { _ in serviceCancelCurrentTask(); return .json(JSON.obj(("data", JSON.obj()))) }
        let api = EeroAPI(store: store, transport: fake)
        await api.restore()
        let result = await Task { try await api.importBrowserSession("cancelled-candidate") }.result
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError, "closing a sign-in window cancels candidate verification") }
        else { XCTFail("closing a sign-in window cancels candidate verification") }
        let signedIn = await api.signedIn
        XCTAssertTrue(signedIn && store.load() == "preserved-session", "cancelled alternate sign-in cannot replace the saved session")
    }
}
