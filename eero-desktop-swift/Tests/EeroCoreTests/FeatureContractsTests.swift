import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EeroCore

/// Port of `Tests.FeatureChecks` plus the validation, phone, sign-in and diagnostics checks from `Tests.RunAsync`.
final class FeatureContractsTests: XCTestCase {
    typealias F = FeatureContracts

    func testReservationAndMacNormalization() throws {
        XCTAssertEqual(try F.reservation("Server", "0200.0000.0001", "192.168.4.20").serialized(),
                       #"{"description":"Server","ip":"192.168.4.20","mac":"02:00:00:00:00:01"}"#, "API reservation fields and MAC normalization")
        XCTAssertEqual(try F.mac("AA-BB-CC-DD-EE-FF"), "aa:bb:cc:dd:ee:ff")
        FakeTransport.expectEeroError(.invalidArgument, "short MAC rejected") { try F.mac("aa:bb:cc") }
        FakeTransport.expectEeroError(.invalidArgument, "IPv6 reservation rejected") { try F.reservation("x", "020000000001", "::1") }
    }

    func testAddresses() throws {
        XCTAssertEqual(try F.address(" 10.0.0.1 ", .inet), "10.0.0.1")
        XCTAssertEqual(try F.address("2606:4700:4700:0:0:0:0:1111", .inet6), "2606:4700:4700::1111")
        FakeTransport.expectEeroError(.invalidArgument, "IPv4 octet out of range") { try F.address("256.1.1.1", .inet) }
        FakeTransport.expectEeroError(.invalidArgument, "IPv4 short form rejected") { try F.address("10.1", .inet) }
        FakeTransport.expectEeroError(.invalidArgument, "IPv6 family mismatch") { try F.address("10.0.0.1", .inet6) }
        do { _ = try F.address("x", .inet6) } catch let e as EeroError { XCTAssertEqual(e.message, "Enter a valid IPv6 address.") }
    }

    func testPortForwarding() throws {
        let forward = try F.forward("192.168.4.20", "8000-8010", "9000-9010", "both", " Example ", true)
        XCTAssertTrue(forward.s("gateway_port") == "8000-8010" && forward.s("client_port") == "9000-9010" && forward.s("protocol") == "both",
                      "API port-forward contract uses gateway_port/client_port/both")
        XCTAssertEqual(forward.s("description"), "Example")
        XCTAssertEqual(forward["enabled"], .bool(true))
        FakeTransport.expectEeroError(.invalidArgument, "mismatched forwarded ranges rejected") { try F.forward("192.168.4.20", "8000-8010", "9000", "tcp", "Example", true) }
        FakeTransport.expectEeroError(.invalidArgument, "bad protocol rejected") { try F.forward("192.168.4.20", "80", "80", "icmp", "Example", true) }
        FakeTransport.expectEeroError(.invalidArgument, "out-of-range ports rejected") { try F.portRange("70000") }
        FakeTransport.expectEeroError(.invalidArgument, "descending range rejected") { try F.portRange("90-80") }
        FakeTransport.expectEeroError(.invalidArgument, "three-part range rejected") { try F.portRange("1-2-3") }
        XCTAssertEqual(try F.portRange("443"), "443")
        XCTAssertEqual(try F.portRange("443-443"), "443")
        XCTAssertEqual(try F.portRange(" 8000-8010 "), "8000-8010")
    }

    func testDns() throws {
        XCTAssertEqual(try F.dns(false, "", true).s("dns", "mode"), "automatic", "API automatic DNS enum")
        let dns = try F.dns(true, "1.1.1.1\n2606:4700:4700::1111", false)
        XCTAssertEqual(dns.get("dns", "custom", "ips").list.count, 2, "mixed IPv4/IPv6 custom DNS payload")
        XCTAssertEqual(dns.s("dns", "mode"), "custom")
        XCTAssertEqual(try F.dns(true, "1.1.1.1\r\n8.8.8.8", true).get("dns", "custom", "ips").list.count, 2)
        FakeTransport.expectEeroError(.invalidArgument, "invalid DNS server rejected") { try F.dns(true, "not-an-ip", false) }
        FakeTransport.expectEeroError(.invalidArgument, "custom requires a server") { try F.dns(true, " ", false) }
        FakeTransport.expectEeroError(.invalidArgument, "at most four servers") { try F.dns(true, "1.1.1.1,1.0.0.1,8.8.8.8,8.8.4.4,9.9.9.9", false) }
    }

    func testDhcp() throws {
        let bridge = try F.dhcp("bridge", "", "", "", "", true)
        XCTAssertEqual(bridge.s("connection", "mode"), "bridged", "API bridge mode serializes as bridged")
        XCTAssertTrue(bridge["dhcp"].isNull)
        let manual = try F.dhcp("custom", "192.168.4.0", "255.255.255.0", "192.168.4.10", "192.168.4.200", false)
        XCTAssertEqual(manual.s("dhcp", "custom", "start_ip"), "192.168.4.10", "manual DHCP payload")
        XCTAssertEqual(manual.s("connection", "mode"), "nat")
        XCTAssertEqual(try F.dhcp("automatic", "", "", "", "", false).s("dhcp", "mode"), "automatic")
        FakeTransport.expectEeroError(.invalidArgument, "DHCP addresses outside subnet rejected") { try F.dhcp("custom", "192.168.4.0", "255.255.255.0", "192.168.5.10", "192.168.5.20", false) }
        FakeTransport.expectEeroError(.invalidArgument, "noncontiguous subnet mask rejected") { try F.dhcp("custom", "192.168.4.0", "255.0.255.0", "192.168.4.10", "192.168.4.20", false) }
        FakeTransport.expectEeroError(.invalidArgument, "broadcast excluded") { try F.dhcp("custom", "192.168.4.0", "255.255.255.0", "192.168.4.10", "192.168.4.255", false) }
        FakeTransport.expectEeroError(.invalidArgument, "unknown mode") { try F.dhcp("static", "", "", "", "", false) }
    }

    func testSchedules() throws {
        let schedule = try F.schedule("Bedtime", ["MON", "TUE", "MON"], "22:00", "07:00", true)
        XCTAssertTrue(schedule.s("start") == "22:00" && schedule["days"].list.count == 2, "API scheduled-pause fields and overnight times")
        let power = try F.schedule("Night", ["MON"], "22:00", "07:00", true, power: true)
        XCTAssertTrue(power.s("start_time") == "22:00" && power["start"].isNull, "power schedules use distinct start_time/end_time fields")
        FakeTransport.expectEeroError(.invalidArgument, "empty schedule days rejected") { try F.schedule("Bedtime", [], "22:00", "07:00", true) }
        FakeTransport.expectEeroError(.invalidArgument, "unknown day rejected") { try F.schedule("Bedtime", ["MONDAY"], "22:00", "07:00", true) }
        FakeTransport.expectEeroError(.invalidArgument, "ambiguous zero-length schedule rejected") { try F.schedule("Bedtime", ["MON"], "22:00", "22:00", true) }
        FakeTransport.expectEeroError(.invalidArgument, "non-24h time rejected") { try F.schedule("Bedtime", ["MON"], "7:00", "22:00", true) }
        FakeTransport.expectEeroError(.invalidArgument, "blank schedule name rejected") { try F.schedule(" ", ["MON"], "07:00", "22:00", true) }
    }

    func testDomainsAndQr() throws {
        XCTAssertEqual(try F.domain("Example.COM."), "example.com", "website rule normalization")
        XCTAssertEqual(try F.domain("bücher.example"), "xn--bcher-kva.example", "IDN converted to ASCII")
        XCTAssertEqual(try F.domain("例え.テスト"), "xn--r8jz45g.xn--zckzah")
        FakeTransport.expectEeroError(.invalidArgument, "website rules reject URLs and paths") { try F.domain("https://example.com/path") }
        FakeTransport.expectEeroError(.invalidArgument, "single label rejected") { try F.domain("localhost") }
        FakeTransport.expectEeroError(.invalidArgument, "IP literal rejected") { try F.domain("192.168.1.1") }
        FakeTransport.expectEeroError(.invalidArgument, "empty label rejected") { try F.domain("a..com") }
        XCTAssertEqual(F.wifiQr("Home;Wifi", #"pass:word\test"#), #"WIFI:T:WPA;S:Home\;Wifi;P:pass\:word\\test;;"#, "wifi QR payload escapes reserved characters")
        XCTAssertEqual(F.wifiQr("Open", ""), "WIFI:T:nopass;S:Open;P:;;")
        XCTAssertEqual(F.deviceTypes.count, 45)
    }

    func testCatalog() {
        let paths = FeatureCatalog.entries.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count, "feature paths are unique")
        XCTAssertEqual(FeatureCatalog.entries.count, 71)
        XCTAssertEqual(FeatureCatalog.parent("Settings/Advanced networking/DNS"), "Settings/Advanced networking", "settings breadcrumb")
        XCTAssertEqual(FeatureCatalog.parent("Help"), "Home")
        XCTAssertEqual(FeatureCatalog.root("Home/Profiles/Profile"), "Home", "profile remains grouped under Home")
        XCTAssertEqual(FeatureCatalog.children("Settings/Advanced networking/DNS").map(\.path), ["Settings/Advanced networking/DNS/DNS performance"])
        XCTAssertEqual(FeatureCatalog.children("Help").map(\.title), ["Support history", "Contact support", "Service availability"])
        let notifications = FeatureCatalog.entry("Settings/Notifications/Windows notifications")
        XCTAssertEqual(notifications?.title, "Mac notifications", "local-platform route displays as Mac")
        XCTAssertEqual(notifications?.parent, "Settings/Notifications")
        XCTAssertEqual(FeatureEntry("Help", "", "").parent, "")
        XCTAssertNotNil(FeatureCatalog.entry("Help/Service availability")?.limitation)
        for e in FeatureCatalog.entries {
            XCTAssertFalse(e.description.contains("Windows"), "no Windows wording in " + e.path)
            XCTAssertFalse((e.limitation ?? "").contains("Windows"), "no Windows wording in " + e.path)
        }
        XCTAssertEqual(try EeroAPI.resource("/2.4/networks/1/placement/wifi_coverage_scan").scheme, "https", "coverage scan API version allowed only on trusted host")
    }

    func testValidation() {
        XCTAssertNoThrow(try Validation.validateSsid("Home"))
        XCTAssertNoThrow(try Validation.validatePassword("password123"))
        XCTAssertNoThrow(try Validation.validateName(" Name "))
        FakeTransport.expectEeroError(.invalidArgument, "SSID byte limit enforced") { try Validation.validateSsid(String(repeating: "界", count: 12)) }
        FakeTransport.expectEeroError(.invalidArgument, "empty SSID rejected") { try Validation.validateSsid("  ") }
        FakeTransport.expectEeroError(.invalidArgument, "wifi password length enforced") { try Validation.validatePassword("short") }
        FakeTransport.expectEeroError(.invalidArgument, "non-ASCII password rejected") { try Validation.validatePassword("pässword123") }
        FakeTransport.expectEeroError(.invalidArgument, "long password rejected") { try Validation.validatePassword(String(repeating: "a", count: 64)) }
        FakeTransport.expectEeroError(.invalidArgument, "blank name rejected") { try Validation.validateName("   ") }
        FakeTransport.expectEeroError(.invalidArgument, "long name rejected") { try Validation.validateName(String(repeating: "n", count: 101)) }
        do { try Validation.validatePassword("x") } catch { XCTAssertEqual(userMessage(error), "Use a wifi password with 8–63 printable ASCII characters.") }
    }

    func testPhoneInput() throws {
        XCTAssertEqual(PhoneInput.formatForDisplay("2025550123"), "+1 (202) 555-0123", "10-digit phone auto formatting")
        XCTAssertEqual(PhoneInput.formatForDisplay("12025550123"), "+1 (202) 555-0123", "11-digit phone auto formatting")
        XCTAssertEqual(PhoneInput.formatForDisplay("+12025550123"), "+1 (202) 555-0123", "international +1 formatting")
        XCTAssertEqual(try PhoneInput.normalize("+1 (202) 555-0123"), "+12025550123", "formatted phone normalizes for API")
        XCTAssertEqual(PhoneInput.formatForDisplay("20255"), "20255", "partial phone remains editable")
        XCTAssertEqual(PhoneInput.formatForDisplay("+1 (202) 555-012"), "+1 (202) 555-012", "backspace does not restore deleted digits")
        XCTAssertEqual(try PhoneInput.normalize("+44 (20) 7946 0958"), "+442079460958", "international country code preserved")
        XCTAssertEqual(PhoneInput.formatForDisplay("+44 (20) 7946 0958"), "+442079460958")
        XCTAssertEqual(PhoneInput.formatForDisplay("person@example.com"), "person@example.com", "email not modified by phone formatter")
        XCTAssertEqual(PhoneInput.preserveCaret("2025550123", 10, "+1 (202) 555-0123"), 17, "caret remains at end after phone formatting")
        XCTAssertEqual(PhoneInput.preserveCaret("2025550123", 3, "+1 (202) 555-0123"), 9, "caret keeps following digits when editing middle")
        FakeTransport.expectEeroError(.invalidArgument, "incomplete phone rejected before login") { try PhoneInput.normalize("+1 20255") }
        FakeTransport.expectEeroError(.invalidArgument, "overlong phone is never silently truncated") { try PhoneInput.normalize("2025550123123456789") }
        FakeTransport.expectEeroError(.invalidArgument, "leading zero country code rejected") { try PhoneInput.normalize("+044 20 7946 0958") }
        FakeTransport.expectEeroError(.invalidArgument, "letters rejected") { try PhoneInput.normalize("call me") }
    }

    func testConnectionDiagnostics() {
        let blocked = URLError(.cannotConnectToHost, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertEqual(ConnectionDiagnostics.category(blocked), "network_access_blocked", "sandbox network access denied identified")
        XCTAssertEqual(ConnectionDiagnostics.nativeCode(blocked), Int(EPERM))
        XCTAssertTrue(userMessage(blocked).contains("Applications folder"), "blocked network message explains normal desktop launch")
        XCTAssertEqual(ConnectionDiagnostics.category(URLError(.cannotFindHost)), "dns_failure", "DNS error distinguished from general connectivity")
        XCTAssertEqual(ConnectionDiagnostics.category(URLError(.dnsLookupFailed)), "dns_failure")
        XCTAssertEqual(ConnectionDiagnostics.category(URLError(.serverCertificateUntrusted)), "tls_failure", "TLS error distinguished from general connectivity")
        XCTAssertEqual(ConnectionDiagnostics.category(URLError(.secureConnectionFailed)), "tls_failure")
        XCTAssertEqual(ConnectionDiagnostics.category(URLError(.timedOut)), "timeout", "timeout distinguished from general connectivity")
        XCTAssertEqual(ConnectionDiagnostics.category(CancellationError()), "timeout")
        XCTAssertEqual(ConnectionDiagnostics.category(URLError(.cannotConnectToHost)), "connection_refused")
        XCTAssertEqual(ConnectionDiagnostics.category(POSIXError(.ECONNREFUSED)), "connection_refused")
        XCTAssertEqual(ConnectionDiagnostics.category(URLError(.notConnectedToInternet)), "network_unreachable")
        let lost = URLError(.networkConnectionLost)
        XCTAssertEqual(ConnectionDiagnostics.category(lost), "connection_failure")
        XCTAssertEqual(ConnectionDiagnostics.nativeCode(lost), URLError.Code.networkConnectionLost.rawValue)
        XCTAssertTrue(userMessage(lost).contains("(macOS error -1005)"))
        XCTAssertEqual(ConnectionDiagnostics.userMessage(EeroError.data("x")), "The connection to eero failed. Use Check connection for details, or restart the app from the Applications folder.")
        XCTAssertTrue(userMessage(URLError(.cannotFindHost)).hasPrefix("macOS could not resolve api-user.e2ro.com"))
    }

    func testConnectionTestRunner() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eero-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appendingPathComponent("ok.json").path
        let good = FakeTransport([FakeStep(method: "GET", path: "/2.2/account", json: #"{"meta":{"code":401,"error":"error.session.missing"}}"#, status: 401)])
        let code = await ConnectionDiagnostics.run(path: ok, transport: good)
        XCTAssertEqual(code, 0)
        let report = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: ok)))
        XCTAssertTrue(report.b("ok"))
        XCTAssertEqual(report.s("endpoint"), "https://api-user.e2ro.com")
        let unexpected = FakeTransport([FakeStep(method: "GET", path: "/2.2/account")])
        let bad = dir.appendingPathComponent("bad.json").path
        let failed = await ConnectionDiagnostics.run(path: bad, transport: unexpected)
        XCTAssertEqual(failed, 1)
        let failure = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: bad)))
        XCTAssertFalse(failure.b("ok"))
        XCTAssertEqual(failure.s("category"), "connection_failure")
        XCTAssertEqual(failure.s("exception_type"), "EeroError")
        XCTAssertEqual(failure.s("native_code"), "0")
    }

    func testSignInContracts() throws {
        XCTAssertTrue(SignInContracts.ssoReturn(URL(string: "https://app.eero.com/auth/index.html?token=abc")!))
        XCTAssertTrue(SignInContracts.ssoReturn(URL(string: "https://app.eero.com:443/auth/index.html")!))
        XCTAssertTrue(SignInContracts.ssoReturn(URL(string: "eero://jumpto/auth?token=abc")!))
        XCTAssertFalse(SignInContracts.ssoReturn(URL(string: "https://user@app.eero.com/auth/index.html")!))
        XCTAssertFalse(SignInContracts.ssoReturn(URL(string: "https://app.eero.com.evil.example/auth/index.html")!))
        XCTAssertFalse(SignInContracts.ssoReturn(URL(string: "http://app.eero.com/auth/index.html")!))
        XCTAssertFalse(SignInContracts.ssoReturn(URL(string: "https://app.eero.com:8443/auth/index.html")!))
        XCTAssertFalse(SignInContracts.ssoReturn(URL(string: "https://app.eero.com/auth/other.html")!))
        let p = try SignInContracts.parameters("?token=a%2Bb&name=Test+Person&flag")
        XCTAssertEqual(p, ["token": "a+b", "name": "Test Person", "flag": ""])
        FakeTransport.expectEeroError(.invalidData, "duplicate parameters rejected") { try SignInContracts.parameters("#token=a&token=b") }
        XCTAssertEqual(try SignInContracts.providerUrl("my_isp-1"),
                       "https://sso.eero.com/?idp=my_isp-1&redirect=https%3A%2F%2Fapp.eero.com%2Fauth%2Findex.html&clientID=28971b56-0016-4416-bef8-689caac23011")
        FakeTransport.expectEeroError(.invalidArgument, "provider identifiers cannot alter the URL") { try SignInContracts.providerUrl("a&b") }
        XCTAssertEqual(try SignInContracts.returnToken(URL(string: "https://app.eero.com/auth/index.html?token=tok123")!), "tok123")
        FakeTransport.expectEeroError(.invalidOperation, "missing token") { try SignInContracts.returnToken(URL(string: "https://app.eero.com/auth/index.html")!) }
        let providers = try JSON.parse(#"{"data":[{"name":"ISP","idp":"isp"},{"name":"","idp":"x"}]}"#)
        XCTAssertEqual(try SignInContracts.providerChoices(providers), ["ISP": "isp"])
        FakeTransport.expectEeroError(.invalidOperation, "no providers") { try SignInContracts.providerChoices(.array([])) }
    }

    func testRegistrationContracts() throws {
        XCTAssertEqual(try RegistrationContracts.country(" ca "), "CA")
        FakeTransport.expectEeroError(.invalidArgument, "three-letter country rejected") { try RegistrationContracts.country("USA") }
        FakeTransport.expectEeroError(.invalidArgument, "bad email rejected") { try RegistrationContracts.email("person@example") }
        let details = try RegistrationContracts.details(name: " Test Person ", email: " person@example.com ", phone: "(202) 555-0123")
        XCTAssertEqual(details.name, "Test Person"); XCTAssertEqual(details.email, "person@example.com"); XCTAssertEqual(details.phone, "+12025550123")
        let agreements = try JSON.parse(#"[{"name":"terms","requires_consent":true,"localized_consent":"I agree to the terms"},{"name":"marketingEmails","requires_consent":false},{"name":""}]"#).list
        XCTAssertEqual(RegistrationContracts.consentLabel(agreements[0]), "I agree to the terms")
        XCTAssertEqual(RegistrationContracts.consentLabel(agreements[1]), "Marketing Emails")
        XCTAssertEqual(RegistrationContracts.humanize("ipv6_upstream"), "IPv6")
        XCTAssertEqual(RegistrationContracts.humanize("privacy_policy"), "Privacy Policy")
        FakeTransport.expectEeroError(.invalidArgument, "required consent enforced") {
            try RegistrationContracts.consentChoices(agreements, accepted: { _ in false }, legalAccepted: true)
        }
        let choices = try RegistrationContracts.consentChoices(agreements, accepted: { $0 == "terms" }, legalAccepted: false)
        XCTAssertEqual(choices, .object(["terms": true, "marketingEmails": false]))
        FakeTransport.expectEeroError(.invalidArgument, "generic legal consent required when no agreements") {
            try RegistrationContracts.consentChoices([], accepted: { _ in true }, legalAccepted: false)
        }
        XCTAssertEqual(try RegistrationContracts.consentChoices([], accepted: { _ in true }, legalAccepted: true), .object([:]))
    }
}
