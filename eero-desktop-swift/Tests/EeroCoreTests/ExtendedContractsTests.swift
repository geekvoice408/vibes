import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EeroCore

/// Port of `Tests.ExtendedChecks`.
final class ExtendedContractsTests: XCTestCase {
    typealias X = ExtendedContracts
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10])

    func testInvitations() throws {
        XCTAssertEqual(try X.inviteCode("https://join.eero.com/invite?invite_code=sample_code-123"), "sample_code-123", "invitation link code is parsed without visiting the link")
        XCTAssertEqual(try X.inviteCode("https://eero.com/invite/sample_code-456"), "sample_code-456", "code taken from the last path segment")
        XCTAssertEqual(try X.inviteCode("https://join.eero.com/?inviteCode=a%2Bb%3D%3D"), "a+b==")
        XCTAssertEqual(try X.inviteCode("  plain-code  "), "plain-code")
        XCTAssertEqual(try X.inviteResponse("sample_code-123", false).serialized(), #"{"accept":false,"invite_code":"sample_code-123"}"#, "decline invitation uses API boolean response contract")
        FakeTransport.expectEeroError(.invalidArgument, "lookalike invitation hosts are rejected") { try X.inviteCode("https://join.eero.com.evil.example/?code=sample_code-123") }
        FakeTransport.expectEeroError(.invalidArgument, "plain http invitation rejected") { try X.inviteCode("http://join.eero.com/?code=sample_code-123") }
        FakeTransport.expectEeroError(.invalidArgument, "credentials in invitation rejected") { try X.inviteCode("https://user@join.eero.com/?code=sample_code-123") }
        FakeTransport.expectEeroError(.invalidArgument, "short codes rejected") { try X.inviteCode("abc") }
        FakeTransport.expectEeroError(.invalidArgument, "membership identifiers cannot alter API paths") { try X.identifier("1/../../account") }
        XCTAssertEqual(try X.identifier("17"), "17")
    }

    func testLicensesAndIsp() throws {
        let validate = try X.license("TEST-LICENSE"), activate = try X.license("TEST-LICENSE", "17")
        XCTAssertTrue(validate["network_id"].isNull && validate.s("software_key") == "TEST-LICENSE", "license validation does not activate for a network")
        XCTAssertTrue(!activate.b("auto_renew") && activate.s("network_id") == "17", "license activation defaults to renewal disabled")
        XCTAssertTrue(try X.license(" KEY1 ", "17", autoRenew: true).b("auto_renew"))
        FakeTransport.expectEeroError(.invalidArgument, "short license rejected") { try X.license("abc") }
        FakeTransport.expectEeroError(.invalidArgument, "control characters rejected") { try X.license("abc\u{7}def") }
        let isp = try X.pppoe(true, "user", "private-test-password", true, "100")
        XCTAssertTrue(isp.s("pppoe", "credentials", "username") == "user" && isp.s("vlan") == "100", "existing-network PPPoE and VLAN contract")
        XCTAssertTrue(try X.pppoe(true, "", "", false, "").get("pppoe", "credentials").isNull, "retaining PPPoE credentials never submits empty passwords")
        XCTAssertEqual(try X.pppoe(false, nil, nil, false, nil)["vlan"], .string(""))
        FakeTransport.expectEeroError(.invalidArgument, "new PPPoE credentials must be complete") { try X.pppoe(true, "", "", true, "100") }
        FakeTransport.expectEeroError(.invalidArgument, "invalid ISP VLAN IDs are rejected") { try X.pppoe(false, "", "", false, "4095") }
        FakeTransport.expectEeroError(.invalidArgument, "non-numeric VLAN rejected") { try X.pppoe(false, "", "", false, "ten") }
    }

    func testDnsPerformanceAndEmail() throws {
        let body = try X.dnsPerformance("1.1.1.1\n2606:4700:4700::1111\n1.1.1.1", 53)
        XCTAssertEqual(body["servers"].list.count, 2, "DNS performance accepts IPv4 and IPv6 resolver entries")
        XCTAssertEqual(body["servers"][0], .obj(("ip", "1.1.1.1"), ("port", 53)))
        FakeTransport.expectEeroError(.invalidArgument, "DNS performance rejects URLs before making requests") { try X.dnsPerformance("https://resolver.example", 53) }
        FakeTransport.expectEeroError(.invalidArgument, "port range enforced") { try X.dnsPerformance("1.1.1.1", 0) }
        FakeTransport.expectEeroError(.invalidArgument, "at most eight servers") { try X.dnsPerformance((1...9).map { "10.0.0.\($0)" }.joined(separator: ","), 53) }
        XCTAssertEqual(try X.email(" person@example.com "), "person@example.com")
        FakeTransport.expectEeroError(.invalidArgument, "invalid email rejected") { try X.email("person at example.com") }
    }

    func testPortalAssets() throws {
        XCTAssertEqual(try X.portalMime("logo.png", png, logo: true), "image/png", "portal upload verifies MIME from the file signature")
        XCTAssertEqual(try X.portalMime("logo.JPG", Data([255, 216, 255, 224, 0, 0, 0, 0]), logo: true), "image/jpeg")
        XCTAssertEqual(try X.portalMime("terms.pdf", Data("%PDF-1.7\n".utf8), logo: false), "application/pdf")
        FakeTransport.expectEeroError(.invalidArgument, "renaming a non-PDF does not bypass terms file validation") { try X.portalMime("terms.pdf", self.png, logo: false) }
        FakeTransport.expectEeroError(.invalidArgument, "tiny files rejected") { try X.portalMime("logo.png", Data([1, 2]), logo: true) }
        let job = try X.importJob("uploads/test/logo.png", logo: true, "5")
        XCTAssertTrue(job.s("import_job_type") == "CaptivePortalLogo" && job.s("metadata") == #"{"configuration-id":"5"}"#, "portal import uses API job type and serialized configuration metadata")
        XCTAssertEqual(try X.importJob("uploads/terms.pdf", logo: false, "5").s("import_job_type"), "CaptivePortalToS")
        FakeTransport.expectEeroError(.invalidData, "missing import path") { try X.importJob(" ", logo: true, "5") }
        for url in ["http://sample.s3.amazonaws.com/x", "https://sample.s3.amazonaws.com.evil.example/x", "https://api-user.e2ro.com/2.2/account",
                    "https://user@sample.s3.amazonaws.com/x", "https://127.0.0.1/x", "https://sample.s3.amazonaws.com:444/x"] {
            FakeTransport.expectEeroError(.invalidData, "untrusted storage URL rejected: " + url) { try X.uploadUrl(url) }
        }
        XCTAssertEqual(try X.uploadUrl("https://sample.s3.us-east-1.amazonaws.com/logo?signature=fake").host, "sample.s3.us-east-1.amazonaws.com")
    }

    /// Port of `StorageFake`: checks the isolated S3 PUT.
    final class StorageFake: HTTPTransport, @unchecked Sendable {
        var seen = false
        let status: Int
        init(status: Int = 200) { self.status = status }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            XCTAssertTrue(request.httpMethod == "PUT" && request.url?.host == "sample.s3.us-east-1.amazonaws.com", "portal upload uses returned HTTPS S3 PUT")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "eero authentication is never forwarded to asset storage")
            XCTAssertTrue(request.value(forHTTPHeaderField: "x-amz-server-side-encryption") == "aws:kms" && request.value(forHTTPHeaderField: "x-amz-server-side-encryption-aws-kms-key-id") == "test-kms-key", "portal upload preserves server KMS encryption headers")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type") == "image/png" && request.httpBody?.count == 8, "portal upload sends exact bytes and MIME type")
            seen = true
            return HTTPResponse(status: status)
        }
    }

    func testPortalUpload() async throws {
        let upload = JSON.obj(("signed_upload_url", "https://sample.s3.us-east-1.amazonaws.com/logo?signature=fake"), ("kms_key_id", "test-kms-key"))
        let storage = StorageFake()
        try await PortalUpload.send(upload, png, mime: "image/png", transport: storage)
        XCTAssertTrue(storage.seen, "isolated asset upload completed")
        let redirected = StorageFake(status: 302)
        let e = await FakeTransport.expectAsyncError(EeroError.self, "redirected uploads fail before import creation") {
            try await PortalUpload.send(upload, self.png, mime: "image/png", transport: redirected)
        }
        XCTAssertEqual(e?.kind, .invalidOperation)
        XCTAssertEqual(e?.message, "The storage service rejected the upload (302). No import was requested.")
        let noKey = JSON.obj(("signed_upload_url", "https://sample.s3.us-east-1.amazonaws.com/logo"))
        let k = await FakeTransport.expectAsyncError(EeroError.self, "missing KMS key rejected") {
            try await PortalUpload.send(noKey, self.png, mime: "image/png", transport: StorageFake())
        }
        XCTAssertEqual(k?.kind, .invalidData)
    }
}
