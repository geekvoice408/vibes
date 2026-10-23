import XCTest
import Foundation
@testable import EeroCore

/// EeroAPI parts of AmazonNativeTests.cs (the Amazon portal/PKCE flow is covered with its own port).
final class AmazonNativeTests: XCTestCase {
    func testAmazonLoginRequiresAccountIdentity() async throws {
        let store = MemorySessionStore("previous-session")
        let fake = ServiceFakeTransport()
        fake.api("POST", "/2.2/login/amazon", cookie: nil, form: ["auth_token": "test-amazon-access", "create_account": "false"], json: #"{"data":{"user_token":"candidate-session"}}"#)
        fake.api("GET", "/2.2/account", cookie: "s=candidate-session", json: #"{"data":{}}"#)
        let api = EeroAPI(store: store, transport: fake)
        await api.restore()
        let e = await serviceExpectError(EeroError.self, "Amazon login refuses a success-shaped response without an actual eero account identity") {
            _ = try await api.amazonSignIn(accessToken: "test-amazon-access")
        }
        XCTAssertEqual(e?.kind, .invalidData)
        let signedIn = await api.signedIn
        XCTAssertTrue(signedIn && store.load() == "previous-session", "an incomplete Amazon account response preserves the previous verified session")
    }

    func testAmazonLoginSavesRotatedSession() async throws {
        let store = MemorySessionStore("previous-session")
        let fake = ServiceFakeTransport()
        fake.api("POST", "/2.2/login/amazon", cookie: nil, form: ["auth_token": "test-amazon-access", "create_account": "false"], json: #"{"data":{"user_token":"candidate-session"}}"#)
        fake.api("GET", "/2.2/account", cookie: "s=candidate-session", json: #"{"data":{"user_id":"test-user"}}"#, setCookie: "s=verified-session; Secure; HttpOnly")
        let api = EeroAPI(store: store, transport: fake)
        await api.setRemember(true)
        let account = try await api.amazonSignIn(accessToken: "test-amazon-access")
        let signedIn = await api.signedIn
        XCTAssertTrue(signedIn && store.load() == "verified-session" && account.s("user_id") == "test-user" && fake.remaining == 0,
                      "Amazon login saves only the rotated eero session after verifying an existing account")
    }

    func testCancelledAmazonLoginPreservesRememberedSession() async throws {
        let store = MemorySessionStore("verified-session")
        let fake = ServiceFakeTransport()
        fake.enqueue { _ in .json(JSON.obj(("data", JSON.obj(("user_token", "candidate-session"))))) }
        fake.enqueue { _ in serviceCancelCurrentTask(); return .json(JSON.obj(("data", JSON.obj(("user_id", "test-user"))))) }
        let api = EeroAPI(store: store, transport: fake)
        await api.restore()
        let result = await Task { try await api.amazonSignIn(accessToken: "test-amazon-access") }.result
        if case .failure(let error) = result {
            XCTAssertTrue(error is CancellationError, "closing consumer Amazon sign-in cancels verification before committing its candidate session")
        } else { XCTFail("closing consumer Amazon sign-in cancels verification before committing its candidate session") }
        let signedIn = await api.signedIn
        XCTAssertTrue(signedIn && store.load() == "verified-session", "cancelled consumer Amazon login preserves the remembered session")
    }
}
