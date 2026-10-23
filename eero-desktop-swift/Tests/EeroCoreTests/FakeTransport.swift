import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EeroCore

/// One expected request and its canned response (port of `Tests.Step`).
struct FakeStep {
    var method: String
    var path: String
    var cookie: String? = nil
    var body: String? = nil
    var contentType: String? = nil
    var json: String? = nil
    var setCookie: String? = nil
    var query: String? = nil
    var status = 200
}

/// Scripted HTTP transport that checks each request against the next expected step (port of `Tests.Fake`).
/// Form bodies are compared as unordered key/value pairs and JSON bodies structurally, because the Swift client
/// serialises keys in sorted order rather than insertion order.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [FakeStep]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [FakeStep] = []) { self.steps = steps }

    var remaining: Int { lock.lock(); defer { lock.unlock() }; return steps.count }

    private func take(_ r: URLRequest) -> FakeStep? {
        lock.lock(); defer { lock.unlock() }
        requests.append(r)
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    func send(_ r: URLRequest) async throws -> HTTPResponse {
        guard let s = take(r) else {
            XCTFail("Unexpected request: \(r.httpMethod ?? "") \(r.url?.path ?? "")")
            throw URLError(.badServerResponse)
        }
        let url = r.url!
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(r.httpMethod, s.method, "request \(s.method) \(s.path)")
        XCTAssertEqual(c.percentEncodedPath, s.path, "request \(s.method) \(s.path)")
        if let q = s.query { XCTAssertEqual("?" + (c.percentEncodedQuery ?? ""), q, "correct query parameters") }
        XCTAssertEqual(c.host, "api-user.e2ro.com", "HTTPS trusted host")
        XCTAssertEqual(c.scheme, "https", "HTTPS trusted host")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Cookie"), s.cookie, "correct cookie scope for \(s.path)")
        let mediaType = r.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        if let body = s.body {
            let actual = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
            if mediaType == "application/json" {
                XCTAssertEqual(try? JSON.parse(actual), try? JSON.parse(body), "request payload for \(s.path)")
            } else {
                XCTAssertEqual(Set(actual.split(separator: "&")), Set(body.split(separator: "&")), "request payload for \(s.path): \(actual)")
            }
        }
        if let ct = s.contentType { XCTAssertEqual(mediaType, ct, "request content type") }
        let text = s.json ?? #"{"meta":{"code":200},"data":{}}"#
        return HTTPResponse(status: s.status, headers: ["Content-Type": "application/json; charset=utf-8"],
                            setCookies: s.setCookie.map { [$0] } ?? [], body: Data(text.utf8))
    }
}

extension FakeTransport {
    /// Asserts that `body` throws an `EeroError` of the given kind.
    static func expectEeroError<T>(_ kind: EeroError.Kind, _ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        do { _ = try body(); XCTFail("expected failure: " + message, file: file, line: line) }
        catch let e as EeroError { XCTAssertEqual(e.kind, kind, message, file: file, line: line) }
        catch { XCTFail("unexpected error \(error): " + message, file: file, line: line) }
    }

    static func expectAsyncError<E: Error>(_ type: E.Type, _ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async -> E? {
        do { try await body(); XCTFail("expected failure: " + message, file: file, line: line); return nil }
        catch let e as E { return e }
        catch { XCTFail("unexpected error \(error): " + message, file: file, line: line); return nil }
    }
}
