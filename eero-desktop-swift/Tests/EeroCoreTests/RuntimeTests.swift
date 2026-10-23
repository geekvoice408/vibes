import XCTest
import Foundation
@testable import EeroCore

final class RuntimeTests: XCTestCase {
    func createBody() throws -> JSON {
        try RuntimeContracts.createNetwork("Test wifi", "sample-password", "America/Chicago", ["test_terms": true, "optional": false])
    }

    func testInvitationAndAutoSetupContracts() throws {
        XCTAssertEqual(RuntimeContracts.adminInvite(), JSON.obj(("invite_role", "admin")), "admin invitation uses serialized API invite_role field")
        XCTAssertEqual(RuntimeContracts.adminInvite().serialized(), #"{"invite_role":"admin"}"#)
        XCTAssertEqual(try RuntimeContracts.invitationResponse("invite-7", false), JSON.obj(("invite_id", "invite-7"), ("accept", false)), "member-promotion response uses invite_id and boolean acceptance")
        XCTAssertThrowsError(try RuntimeContracts.invitationResponse("../account", true), "incoming invitation IDs cannot change a resource path")
        for mode in ["OFF", "ZTS", "LTS", "DEFAULT"] { XCTAssertEqual(try RuntimeContracts.autoSetup(mode).s("mode"), mode, "API automatic setup mode " + mode) }
        XCTAssertThrowsError(try RuntimeContracts.autoSetup("enabled"), "unrecognized automatic setup modes rejected") {
            XCTAssertEqual($0 as? EeroError, .argument("Choose a supported automatic setup mode."))
        }
    }

    func testSerialValidation() throws {
        XCTAssertEqual(try RuntimeContracts.serial("  TESTSERIAL123 "), "TESTSERIAL123")
        for bad in ["short", "has space 123", "TESTSERIAL123\n", String(repeating: "A", count: 41), "../networks"] {
            XCTAssertThrowsError(try RuntimeContracts.serial(bad + "x"), bad) {
                XCTAssertEqual(($0 as? EeroError)?.message, "Enter the serial number printed on the eero or accessory.")
            }
        }
    }

    func testBluetoothAdvertisementParsing() {
        let id = UUID()
        var ble = BluetoothEero.advertisement(id, "3.0.0-1-AA==", -60)
        XCTAssertTrue(ble.inNetwork == true && ble.ethernet == nil, "BLE v3 reads membership without inventing an Ethernet flag")
        ble = BluetoothEero.advertisement(id, "4.0.0-Model-1", -47)
        XCTAssertTrue(ble.inNetwork == nil && ble.ethernet == true && ble.signal == -47, "BLE v4 reports Ethernet without inventing network membership")
        XCTAssertEqual(ble.version, "4.0.0")
        ble = BluetoothEero.advertisement(id, "eero Setup", -70)
        XCTAssertTrue(ble.version == nil && ble.inNetwork == nil && ble.ethernet == nil, "legacy setup advertisement remains unknown until read")
        ble = BluetoothEero.advertisement(id, "malformed", -70)
        XCTAssertNil(ble.version, "malformed BLE name does not crash discovery")
        ble = BluetoothEero.advertisement(id, nil, -70)
        XCTAssertEqual(ble.name, "eero Setup")
        XCTAssertNil(BluetoothEero.advertisement(id, "4-a-1", -1).version, "single-component versions are not System.Version values")
        XCTAssertEqual(UUID(uuidString: BluetoothContracts.eeroService), UUID(uuidString: "d99a3d3f-c1ef-4533-809d-82de05d509ca"), "BLE scanner filters the API eero setup service")
        XCTAssertEqual(BluetoothContracts.scanSeconds(90), 30); XCTAssertEqual(BluetoothContracts.scanSeconds(0), 1)
        XCTAssertEqual(BluetoothContracts.characteristicString(Data("SERIAL\0\r\n".utf8)), "SERIAL")
        XCTAssertEqual(BluetoothContracts.characteristicString(nil), "Unavailable")
        let info = BluetoothContracts.info(BluetoothEero.advertisement(id, "4.0.0-Sample-1", -47), serial: "S", firmware: "F")
        XCTAssertEqual(info["ethernet_connected"], true); XCTAssertEqual(info.s("already_in_network"), "Not reported")
        XCTAssertEqual(info.s("bluetooth_version"), "4.0.0"); XCTAssertEqual(info["signal_dbm"], -47)
        let ordered = BluetoothContracts.ordered([BluetoothEero.advertisement(UUID(), "a", -80), BluetoothEero.advertisement(UUID(), "b", -40)])
        XCTAssertEqual(ordered.map(\.name), ["b", "a"])
        XCTAssertEqual(BluetoothContracts.checkResult(candidates: 2)["gatt_writes"], 0)
    }

    func testNetworkCreationContract() throws {
        let create = try createBody()
        XCTAssertEqual(create.s("timezone", "value"), "America/Chicago")
        XCTAssertTrue(create.b("settings", "consents", "test_terms"))
        XCTAssertFalse(create.b("settings", "consents", "optional"), "network creation preserves timezone and explicit consent decisions")
        XCTAssertEqual(create.get("settings", "enabled_simple_setup_vendors"), .array([]))
        XCTAssertEqual(create.s("name"), "Test wifi")
        XCTAssertThrowsError(try RuntimeContracts.createNetwork("Test", "short", "America/Chicago", [:]), "invalid wifi password rejected before creating a network")
        XCTAssertThrowsError(try RuntimeContracts.createNetwork("Test", "sample-password", "Not a zone!", [:])) {
            XCTAssertEqual(($0 as? EeroError)?.message, "Enter an IANA timezone such as America/Chicago or Europe/London.")
        }
        XCTAssertThrowsError(try RuntimeContracts.createNetwork(String(repeating: "x", count: 33), "sample-password", "UTC", [:]))
        XCTAssertNoThrow(try RuntimeContracts.createNetwork("x", "sample-password", "America/Argentina/Buenos_Aires", [:]))
    }

    func testBrowserSessionVerification() async throws {
        let store = MemorySessionStore("existing-test")
        let fake = ServiceFakeTransport()
        fake.api("GET", "/2.2/account", cookie: "s=unverified-browser-test", status: 401, json: #"{"meta":{"code":401,"error":"error.session.invalid"}}"#)
        fake.api("GET", "/2.2/account", cookie: "s=verified-browser-test", setCookie: "s=rotated-browser-test; Path=/; Secure; HttpOnly")
        let api = EeroAPI(store: store, transport: fake)
        await api.restore()
        await serviceExpectError(ApiError.self, "website sign-in is checked against account API") { try await api.importBrowserSession("unverified-browser-test") }
        let signedIn = await api.signedIn
        XCTAssertTrue(signedIn && store.load() == "existing-test", "rejected browser session preserves the existing saved sign-in")
        try await api.importBrowserSession("verified-browser-test")
        XCTAssertEqual(store.load(), "rotated-browser-test", "verified browser session honors server cookie rotation")
        XCTAssertEqual(fake.remaining, 0, "browser session verification completed without extra requests")
    }

    func testWiredSetupCreatesOnceAndRetriesClaim() async throws {
        let create = try createBody()
        let store = MemorySessionStore("setup-test")
        let fake = ServiceFakeTransport()
        let claim = ["serial": "TESTSERIAL123", "location": "Office", "network": "/2.2/networks/new-7"]
        fake.api("POST", "/2.3/networks", cookie: "s=setup-test", body: create, json: #"{"meta":{"code":200},"data":{"url":"/2.2/networks/new-7"}}"#)
        fake.api("POST", "/2.2/eeros", query: "requireSession=true", cookie: "s=setup-test", form: claim, status: 409, json: #"{"meta":{"code":409,"error":"setup.not_ready"}}"#)
        fake.api("POST", "/2.2/eeros", query: "requireSession=true", cookie: "s=setup-test", form: claim)
        let api = EeroAPI(store: store, transport: fake)
        await api.restore()
        let setup = WiredNetworkSetup()
        try await setup.create(api, create, "TESTSERIAL123", "Office")
        await serviceExpectError(ApiError.self, "failed gateway addition remains recoverable") { try await setup.claim(api) }
        XCTAssertTrue(setup.createdURL == "/2.2/networks/new-7" && !setup.creationUncertain, "failed claim preserves the created network")
        let again = await serviceExpectError(EeroError.self, "claim failure cannot issue a second network creation") { try await setup.create(api, create, "TESTSERIAL123", "Office") }
        XCTAssertEqual(again?.kind, .invalidOperation)
        let destination = try await setup.claim(api)
        XCTAssertTrue(destination == "/2.2/networks/new-7" && setup.createdURL == nil, "retry claims the same network then clears completed setup state")
        XCTAssertEqual(fake.remaining, 0, "wired setup sent exactly one creation and two explicit claims")
        await serviceExpectError(EeroError.self, "claim without creation") { try await setup.claim(api) }
    }

    func testWiredSetupBlocksAfterAmbiguousCreation() async throws {
        let create = try createBody()
        let fake = ServiceFakeTransport()
        fake.api("POST", "/2.3/networks", cookie: "s=setup-test", status: 503, json: #"{"meta":{"code":503}}"#)
        let api = EeroAPI(store: MemorySessionStore("setup-test"), transport: fake)
        await api.restore()
        let setup = WiredNetworkSetup()
        await serviceExpectError(ApiError.self, "ambiguous network creation failure surfaced") { try await setup.create(api, create, "TESTSERIAL123", "Office") }
        XCTAssertTrue(setup.creationUncertain, "uncertain creation remains blocked for account review")
        let e = await serviceExpectError(EeroError.self, "ambiguous create is never silently repeated") { try await setup.create(api, create, "TESTSERIAL123", "Office") }
        XCTAssertEqual(e?.message, "A creation request was already sent. Review the network in your account before starting another setup.")
        XCTAssertEqual(fake.remaining, 0)
    }

    func testWiredSetupRejectsUnexpectedCreatedResource() async throws {
        let fake = ServiceFakeTransport()
        fake.api("POST", "/2.3/networks", cookie: "s=setup-test", json: #"{"data":{"url":"/2.2/networks/new-7/devices"}}"#)
        let api = EeroAPI(store: MemorySessionStore("setup-test"), transport: fake)
        await api.restore()
        let setup = WiredNetworkSetup()
        await serviceExpectError(EeroError.self, "invalid serial rejected before any request") { try await setup.create(api, try self.createBody(), "bad", "Office") }
        XCTAssertFalse(setup.creationUncertain)
        let e = await serviceExpectError(EeroError.self, "unexpected created URL") { try await setup.create(api, try self.createBody(), "TESTSERIAL123", "Office") }
        XCTAssertEqual(e?.message, "The server did not return a valid created network. Refresh your account before continuing.")
        XCTAssertTrue(setup.creationUncertain && setup.createdURL == nil)
    }
}
