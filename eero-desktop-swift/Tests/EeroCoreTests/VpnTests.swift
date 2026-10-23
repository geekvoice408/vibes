import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EeroCore

final class VpnTests: XCTestCase {
    let key = Data(repeating: 7, count: 32).base64EncodedString()

    func testSha256KnownVectors() {
        XCTAssertEqual(EeroSHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(EeroSHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(EeroSHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testEligibility() {
        XCTAssertTrue(VpnContracts.canRegister(JSON.obj(("seats_available", true))))
        XCTAssertFalse(VpnContracts.canRegister(JSON.obj(("seats_available", false))), "VPN registration requires a reported available device slot")
        XCTAssertFalse(VpnContracts.canRegister(JSON.obj()))
        XCTAssertFalse(VpnContracts.canRegister(JSON.obj(("seats_available", "true"))), "missing or malformed VPN eligibility never enables registration")
        let full = VpnContracts.eligibilityMessage(JSON.obj(("seats_available", false)))
        XCTAssertTrue(full.contains("device slots") && !full.contains("does not have permission"), "full VPN device allowance is distinct from account permission denial")
        XCTAssertTrue(VpnContracts.eligibilityMessage(JSON.obj()).contains("has not been confirmed"))
        let denied: Result<JSON, Error> = .failure(ApiError(code: 403, error: "", session: false))
        XCTAssertFalse(VpnContracts.canRegister(denied))
        XCTAssertTrue(VpnContracts.eligibilityMessage(denied).contains("provider"), "VPN entitlement rejection explains provider availability without offering registration")
        XCTAssertTrue(VpnContracts.eligibilityMessage(error: ApiError(code: 402, error: "", session: false)).contains("eligible active benefit"))
        XCTAssertTrue(VpnContracts.eligibilityMessage(error: ApiError(code: 503, error: "", session: false)).contains("Try again"), "VPN subscription and temporary service errors stay distinct")
        XCTAssertTrue(VpnContracts.eligibilityMessage(error: ApiError(code: 404, error: "", session: false)).contains("not provided"))
        XCTAssertTrue(VpnContracts.canRegister(.success(JSON.obj(("seats_available", true)))))
    }

    func testProfileAndConfiguration() throws {
        let profile = try VpnContracts.profile(key, "new-york-1.sgw.guardianapp.com", JSON.obj(("server-public-key", key), ("mapped-ipv4-address", "10.20.0.2"), ("mapped-ipv6-address", "fd00::2")))
        let configuration = try VpnContracts.configuration(profile)
        XCTAssertTrue(configuration.contains("AllowedIPs = 0.0.0.0/0, ::/0") && configuration.contains("DNS = 1.1.1.1, 1.0.0.1") && configuration.contains(":51821"), "Guardian WireGuard config covers both address families with SDK DNS and endpoint port")
        XCTAssertTrue(!configuration.contains("PostUp") && !configuration.contains("PreUp") && configuration.contains("10.20.0.2/32, fd00::2/128"), "generated VPN config has validated addresses and no command hooks")
        XCTAssertEqual(configuration, "[Interface]\nPrivateKey = \(key)\nAddress = 10.20.0.2/32, fd00::2/128\nDNS = 1.1.1.1, 1.0.0.1\n\n[Peer]\nPublicKey = \(key)\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = new-york-1.sgw.guardianapp.com:51821\nPersistentKeepalive = 25\n")
        for bad in ["evil.test", "guardianapp.com.evil.test", "good.sgw.guardianapp.com\nPostUp=bad", "good.sgw.guardianapp.com:443", "good.sgw.guardianapp.com\n"] {
            XCTAssertThrowsError(try VpnContracts.gateway(bad), "VPN gateway cannot redirect credentials or inject configuration") {
                XCTAssertEqual(($0 as? EeroError)?.kind, .invalidData)
            }
        }
        XCTAssertEqual(try VpnContracts.gateway("NY-1.SGW.guardianapp.com"), "ny-1.sgw.guardianapp.com")
        XCTAssertThrowsError(try VpnContracts.profile(key, "valid.sgw.guardianapp.com", JSON.obj(("server-public-key", key), ("mapped-ipv4-address", "10.0.0.2/8"))), "VPN server cannot inject a broad interface prefix")
        for bad in ["127.0.0.1", "0.0.0.0", "fd00::2", "10.0.0.256", ""] {
            XCTAssertThrowsError(try VpnContracts.profile(key, "valid.sgw.guardianapp.com", JSON.obj(("server-public-key", key), ("mapped-ipv4-address", bad))), bad)
        }
        for bad in ["::1", "::", "10.0.0.1", "fd00::2/64"] {
            XCTAssertThrowsError(try VpnContracts.profile(key, "valid.sgw.guardianapp.com", JSON.obj(("server-public-key", key), ("mapped-ipv4-address", "10.0.0.2"), ("mapped-ipv6-address", bad))), bad)
        }
        XCTAssertEqual(try VpnContracts.profile(key, "v.sgw.guardianapp.com", JSON.obj(("server-public-key", key), ("mapped-ipv4-address", "10.0.0.2/32"))).s("ipv6"), "")
        XCTAssertThrowsError(try VpnContracts.key(Data(count: 32).base64EncodedString()), "all-zero keys rejected")
        XCTAssertThrowsError(try VpnContracts.key(Data(repeating: 1, count: 31).base64EncodedString()))
        XCTAssertThrowsError(try VpnContracts.key("not base64!")) { XCTAssertEqual(($0 as? EeroError)?.message, "A VPN key is invalid.") }
        XCTAssertEqual(try VpnContracts.key(" " + key + "\n"), key)
        XCTAssertEqual(try VpnContracts.subscriber(JSON.obj(("guardian_id", "i"), ("guardian_secret", "s"))), JSON.obj(("ep-grd-subscriber-identifier", "i"), ("ep-grd-subscriber-secret", "s")))
        XCTAssertThrowsError(try VpnContracts.subscriber(JSON.obj(("guardian_id", "i"))))
    }

    func testScopeAndTunnelNames() throws {
        let scope = try VpnContracts.scope("account-1", "network-1")
        XCTAssertNotEqual(scope, try VpnContracts.scope("account-2", "network-1"))
        XCTAssertNotEqual(scope, try VpnContracts.scope("account-1", "network-2"))
        XCTAssertEqual(scope.count, 24)
        XCTAssertTrue(try VpnConfig.tunnel(scope).count < 40, "VPN profile names isolate accounts and networks without exposing identifiers")
        XCTAssertEqual(scope, String(EeroSHA256.hex(Data("account-1\nnetwork-1".utf8)).prefix(24)))
        XCTAssertThrowsError(try VpnContracts.scope("", "network"))
        XCTAssertThrowsError(try VpnConfig.tunnel("../invalid")) { XCTAssertEqual(($0 as? EeroError)?.message, "Invalid VPN profile.") }
        XCTAssertEqual(try VpnConfig.configurationFileName(scope), "Eero-" + scope + ".conf")
        XCTAssertThrowsError(try VpnConfig.action("restart"))
    }

    func testHandshakeParsing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(VpnConfig.freshHandshake("peerkey=\t1699999950\n", now: now))
        XCTAssertFalse(VpnConfig.freshHandshake("peerkey=\t0\n", now: now))
        XCTAssertFalse(VpnConfig.freshHandshake("peerkey=\t1699999000\n", now: now))
        XCTAssertFalse(VpnConfig.freshHandshake("garbage", now: now))
        XCTAssertTrue(VpnConfig.freshHandshake(at: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(VpnConfig.freshHandshake(at: nil, now: now))
        XCTAssertTrue(VpnConfig.requestExpired(now.addingTimeInterval(-601), now: now))
        XCTAssertFalse(VpnConfig.requestExpired(now.addingTimeInterval(-60), now: now))
    }

    func testTunnelLifecycle() async throws {
        final class Counter: @unchecked Sendable { var probes = 0, stops = 0, confirmations = 0 }
        struct Failure: Error {}
        var c = Counter()
        try await VpnTunnelLifecycle.start(install: {}, running: { true }, handshake: { c.probes += 1; return c.probes == 3 }, stop: { c.stops += 1 }, confirmed: { c.confirmations += 1 }, attempts: 5, wait: {})
        XCTAssertTrue(c.probes == 3 && c.stops == 0 && c.confirmations == 1, "delayed VPN startup retries before confirming one fresh handshake")

        c = Counter()
        do {
            try await VpnTunnelLifecycle.start(install: {}, running: { true }, handshake: { false }, stop: { c.stops += 1 }, confirmed: { c.confirmations += 1 }, attempts: 3, wait: {})
            XCTFail("handshake failure")
        } catch let e as EeroError { XCTAssertEqual(e.kind, .invalidOperation) }
        XCTAssertTrue(c.stops == 1 && c.confirmations == 0, "VPN handshake failure removes the tunnel and cannot report connected")

        c = Counter()
        do { try await VpnTunnelLifecycle.start(install: { throw Failure() }, running: { true }, handshake: { true }, stop: { c.stops += 1 }, confirmed: {}, attempts: 1, wait: {}); XCTFail() }
        catch is Failure {}
        XCTAssertEqual(c.stops, 1, "partially installed VPN service is removed after an installation error")

        c = Counter()
        do { try await VpnTunnelLifecycle.start(install: { throw Failure() }, running: { false }, handshake: { true }, stop: { c.stops += 1 }, confirmed: {}, attempts: 1, wait: {}); XCTFail() }
        catch is Failure {}
        XCTAssertEqual(c.stops, 0, "failed install without a service does not issue an unrelated stop")

        do { try await VpnTunnelLifecycle.start(install: {}, running: { true }, handshake: { false }, stop: { throw Failure() }, confirmed: {}, attempts: 1, wait: {}); XCTFail() }
        catch is VpnCleanupError {}
        catch { XCTFail("failed VPN cleanup is reported explicitly instead of claiming disconnected: \(error)") }

        c = Counter()
        do { try await VpnTunnelLifecycle.start(install: {}, running: { true }, handshake: { true }, stop: { c.stops += 1 }, confirmed: { throw Failure() }, attempts: 1, wait: {}); XCTFail() }
        catch is Failure {}
        XCTAssertEqual(c.stops, 1, "VPN rolls back if its successful connection cannot be reported to the app")
    }

    func testGuardianDeviceListUsesPartnerFields() async throws {
        let fake = ServiceFakeTransport()
        let publishable = VpnContracts.publishableKey
        fake.enqueue { r in
            XCTAssertEqual(r.url?.host, VpnContracts.partnerHost)
            XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"), "Guardian receives no eero API cookie")
            XCTAssertEqual(r.value(forHTTPHeaderField: "GRD-Connect-Publishable-Key"), publishable)
            let body = try JSON.parse(r.httpBody ?? Data())
            XCTAssertTrue(body.s("ep-grd-subscriber-identifier") == "sample-id" && body.s("connect-publishable-key") == publishable, "Guardian device list uses partner subscriber fields and publishable routing key")
            return .json(JSON.array([JSON.obj(("ep-grd-device-uuid", "device-1"), ("ep-grd-device-nickname", "Mac"))]))
        }
        let guardian = GuardianAPI(transport: fake)
        let devices = try await guardian.devices(JSON.obj(("guardian_id", "sample-id"), ("guardian_secret", "sample-secret")))
        XCTAssertEqual(devices.list.count, 1, "Guardian device list is parsed without exposing secrets in UI details")
        let e = await serviceExpectError(EeroError.self, "Guardian API refuses off-provider credential destinations") { try await guardian.send("POST", "evil.test", "/api/v1/test", JSON.obj()) }
        XCTAssertEqual(e?.kind, .invalidData)
        for path in ["/other", "/api/v1/../x", "/api/v1/a b", "/api/v1/#x", "/api/v1\\x"] {
            await serviceExpectError(EeroError.self, path) { try await guardian.send("GET", VpnContracts.serverHost, path) }
        }
        await serviceExpectError(EeroError.self, "uppercase host") { try await guardian.send("GET", "A.sgw.guardianapp.com", "/api/v1/x") }
        XCTAssertEqual(fake.remaining, 0, "all service test requests were exercised without any real account calls")
    }

    func testGuardianRemoveDeviceAndErrors() async throws {
        let fake = ServiceFakeTransport()
        fake.enqueue { r in
            XCTAssertEqual(r.url?.path, "/api/v1.2/partners/subscriber/device/delete")
            let body = try JSON.parse(r.httpBody ?? Data())
            XCTAssertEqual(body.s("ep-grd-device-uuid"), "device-1")
            XCTAssertEqual(body.s("ep-grd-subscriber-secret"), "s")
            return .init(text: "")
        }
        fake.enqueue { _ in .init(status: 500, text: "{}") }
        fake.enqueue { r in
            XCTAssertEqual(r.httpMethod, "GET"); XCTAssertNil(r.httpBody)
            XCTAssertNil(r.value(forHTTPHeaderField: "GRD-Connect-Publishable-Key"))
            return .init(text: "not json")
        }
        let guardian = GuardianAPI(transport: fake)
        let creds = JSON.obj(("guardian_id", "i"), ("guardian_secret", "s"))
        let removed = try await guardian.removeDevice(creds, "device-1")
        XCTAssertEqual(removed, .object([:]))
        await serviceExpectError(EeroError.self, "invalid device id") { try await guardian.removeDevice(creds, "../x") }
        let failure = await serviceExpectError(EeroError.self, "HTTP failure") { _ = try await guardian.regions() }
        XCTAssertEqual(failure?.message, "Guardian could not complete the request (HTTP 500). Check your benefit eligibility and try again.")
        await serviceExpectError(EeroError.self, "malformed response") { _ = try await guardian.regions() }
        XCTAssertEqual(fake.remaining, 0)
    }

    func testGuardianProvisioning() async throws {
        let fake = ServiceFakeTransport()
        let key = self.key
        fake.enqueue { r in
            let body = try JSON.parse(r.httpBody ?? Data())
            XCTAssertTrue(r.url?.host == VpnContracts.serverHost && r.url?.path == "/api/v1.3/servers/hostnames-for-region" && body.s("region") == "test-city", "VPN provisioning selects an online server in the requested city")
            XCTAssertNil(r.value(forHTTPHeaderField: "GRD-Connect-Publishable-Key"))
            XCTAssertTrue(body["connect-publishable-key"].isNull)
            return .json(JSON.array([
                JSON.obj(("hostname", "offline.sgw.guardianapp.com"), ("offline", true)),
                JSON.obj(("hostname", "busy.sgw.guardianapp.com"), ("offline", false), ("capacity-score", 9)),
                JSON.obj(("hostname", "online.sgw.guardianapp.com"), ("offline", false), ("capacity-score", 2)),
            ]))
        }
        fake.enqueue { r in
            let body = try JSON.parse(r.httpBody ?? Data())
            XCTAssertTrue(r.url?.path == "/api/v1.2/subscriber-credential/create" && body.s("validation-method") == "pe-token" && body.s("pe-token") == "test-pet", "VPN provisioning exchanges a device PE token for a subscriber credential")
            return .json(JSON.obj(("subscriber-credential", "test-subscriber")))
        }
        fake.enqueue { r in
            let body = try JSON.parse(r.httpBody ?? Data())
            XCTAssertTrue(r.url?.host == "online.sgw.guardianapp.com" && r.url?.path == "/api/v1.4/device-credentials" && body.s("transport-protocol") == "wireguard" && body.s("public-key") == key, "Guardian receives the public key on the selected gateway")
            XCTAssertTrue(body["private_key"].isNull && r.value(forHTTPHeaderField: "Cookie") == nil, "VPN private key and eero cookie are never sent to Guardian")
            XCTAssertEqual(body.s("subscriber-credential"), "test-subscriber")
            return .json(JSON.obj(("server-public-key", key), ("mapped-ipv4-address", "10.20.0.2")))
        }
        let guardian = GuardianAPI(transport: fake)
        let provisioned = try await guardian.createProfile("test-pet", "test-city", key, key)
        XCTAssertTrue(provisioned.s("gateway") == "online.sgw.guardianapp.com" && fake.remaining == 0, "complete simulated Guardian provisioning produces a validated profile")
        XCTAssertEqual(provisioned.s("ipv4"), "10.20.0.2/32")

        let e = await serviceExpectError(EeroError.self, "unregistered device") { _ = try await guardian.createProfile(nil, "x", key, key) }
        XCTAssertEqual(e?.message, "Register this Mac first.")
        fake.enqueue { _ in .json(JSON.array([JSON.obj(("hostname", "offline.sgw.guardianapp.com"), ("offline", true))])) }
        let none = await serviceExpectError(EeroError.self, "no online server") { _ = try await guardian.createProfile("pet", "x", key, key) }
        XCTAssertEqual(none?.message, "Guardian did not return an online server for that region.")
    }
}
