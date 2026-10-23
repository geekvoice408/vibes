import XCTest
import Foundation
@testable import EeroCore

final class EverydayTests: XCTestCase {
    func testBackupOrderAndDiagnostics() throws {
        XCTAssertEqual(try EverydayContracts.backupOrder(["backup-2", "backup-1"]).serialized(), #"{"rearranged_ids":["backup-2","backup-1"]}"#, "backup priorities preserve every UUID in the chosen order")
        XCTAssertThrowsError(try EverydayContracts.backupOrder(["same", "same"]), "duplicate backup priority entries rejected before request") {
            XCTAssertEqual($0 as? EeroError, .argument("Each saved backup network must appear exactly once."))
        }
        XCTAssertThrowsError(try EverydayContracts.backupOrder([]), "empty backup reorder rejected")
        XCTAssertThrowsError(try EverydayContracts.backupOrder(["../x"]))
        for symptom in ["internet_slow", "internet_offline", "connection_drops", "eeros_red"] {
            let body = try EverydayContracts.symptom(symptom)
            XCTAssertTrue(body.s("symptom") == symptom && body["device"].isNull, "network-wide diagnostics symptom " + symptom)
        }
        XCTAssertThrowsError(try EverydayContracts.symptom("reboot"), "diagnostics cannot substitute a restart action")
    }

    func testOffersAndReferrals() throws {
        XCTAssertEqual(try EverydayContracts.offers(["product-1", "product-1", "product-2"])["product_ids"].list.count, 2, "offer request uses unique product_ids from eligible plans")
        XCTAssertEqual(try EverydayContracts.offers(["product-2", "product-1"])["product_ids"], ["product-2", "product-1"])
        XCTAssertEqual(try EverydayContracts.referral("network-1", "product-2"), JSON.obj(("product_id", "product-2"), ("network_id", "network-1")), "referral URL and email use API product_id/network_id contract")
        XCTAssertThrowsError(try EverydayContracts.offers(["bad\nproduct"]), "control characters in returned product IDs rejected") {
            XCTAssertEqual(($0 as? EeroError)?.message, "eero did not return a valid product identifier.")
        }
        XCTAssertThrowsError(try EverydayContracts.offers([]))
        XCTAssertThrowsError(try EverydayContracts.offers((0...50).map { "p\($0)" })) {
            XCTAssertEqual(($0 as? EeroError)?.message, "Select between one and fifty available products.")
        }
        XCTAssertThrowsError(try EverydayContracts.productId(String(repeating: "x", count: 201)))
        XCTAssertThrowsError(try EverydayContracts.referral("network/1", "product"))
    }

    func testGuardianAndThreadCredentials() throws {
        let credentials = try EverydayContracts.guardianLogin(JSON.obj(("guardian_id", "sample-user"), ("guardian_secret", "sample-secret")))
        XCTAssertTrue(credentials["Guardian username"] == "sample-user" && credentials["Guardian password"] == "sample-secret", "Guardian account bridge uses returned provider credentials")
        XCTAssertThrowsError(try EverydayContracts.guardianLogin(JSON.obj(("guardian_id", "only-user"))), "incomplete Guardian credentials cannot appear as successful sign-in") {
            XCTAssertEqual(($0 as? EeroError)?.kind, .invalidOperation)
        }
        let thread = try EverydayContracts.threadCredentials(JSON.obj(("name", "Sample Thread"), ("master_key", "sample-key"), ("active_operational_dataset", "sample-dataset"), ("unrelated_secret", "excluded")))
        XCTAssertTrue(thread.count == 2 && thread["unrelated secret"] == nil, "Thread reveal includes only explicit supported credential fields")
        XCTAssertEqual(thread["master key"], "sample-key")
        XCTAssertThrowsError(try EverydayContracts.threadCredentials(JSON.obj(("name", "x")))) {
            XCTAssertEqual(($0 as? EeroError)?.message, "This network did not return Thread credentials for your account.")
        }
    }

    func testNotificationJournal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eero-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("notifications.json")
        var journal = NotificationJournal(fileURL: path)
        let first = JSON.obj(("uuid", "notice-1"), ("body", "sample-sensitive-body"))
        let second = JSON.obj(("uuid", "notice-2"), ("body", "second-body"))
        XCTAssertEqual(try journal.observe("account-A", "/2.2/networks/1", [first]).count, 0, "first notification check seeds without announcing old history")
        try journal.save()
        let stored = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        XCTAssertFalse(stored.contains("sample-sensitive-body") || stored.contains("notice-1") || stored.contains("account-A") || stored.contains("networks"),
                       "persisted notification cursor contains no plaintext account/events")
        #if !os(Windows)
        let permissions = (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
        #endif
        journal = NotificationJournal(path.path)
        XCTAssertEqual(try journal.observe("account-A", "/2.2/networks/1", [second, first]).count, 1, "new notifications after process restart are detected")
        XCTAssertEqual(try journal.observe("account-A", "/2.2/networks/1", [second, first]).count, 0, "repeated notification history is not announced again")
        XCTAssertEqual(try journal.observe("account-B", "/2.2/networks/1", [second, first]).count, 0, "notification cursors are isolated by account")
        XCTAssertEqual(try journal.observe("account-A", "/2.2/networks/2", [second, first]).count, 0, "notification cursors are isolated by network")
        let third = JSON.obj(("uuid", "notice-3"))
        let fresh = try journal.observe("account-A", "/2.2/networks/1", [third, second, first])
        XCTAssertTrue(fresh.count == 1 && fresh[0].s("uuid") == "notice-3", "only unseen notification identifiers produce alerts")
        try journal.save()
        journal = NotificationJournal(fileURL: path)
        XCTAssertEqual(try journal.observe("account-A", "/2.2/networks/1", [third, second, first]).count, 0, "cursor persistence suppresses duplicates on a second restart")
        try Data("corrupt-cache".utf8).write(to: path)
        journal = NotificationJournal(fileURL: path)
        XCTAssertEqual(try journal.observe("account-A", "/2.2/networks/1", [first]).count, 0, "corrupt notification cache recovers with a quiet initial seed")
        XCTAssertThrowsError(try journal.observe("account-A", "https://outside.example/2.2/networks/1", [first]), "notification history cannot be scoped to an untrusted API resource") {
            XCTAssertEqual(($0 as? EeroError)?.kind, .invalidArgument)
        }
    }

    func testNotificationJournalOrderingAndLimits() throws {
        let journal = NotificationJournal(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-" + UUID().uuidString))
        _ = try journal.observe("a", "/2.2/networks/1", [])
        let page = (1...3).reversed().map { JSON.obj(("id", "n\($0)")) } + [JSON.obj(("uuid", "")), JSON.obj(("uuid", "bad\u{7}id"))]
        let fresh = try journal.observe("a", "/2.2/networks/1", page)
        XCTAssertEqual(fresh.map { $0.s("id") }, ["n1", "n2", "n3"], "alerts are delivered oldest first; invalid identifiers ignored")
        let many = (0..<60).reversed().map { JSON.obj(("uuid", "m\($0)")) }
        XCTAssertEqual(try journal.observe("a", "/2.2/networks/1", many).count, 50, "only the newest fifty entries are considered")
        for i in 0..<70 { _ = try journal.observe("acct-\(i)", "/2.2/networks/1", [JSON.obj(("uuid", "x"))]) }
        XCTAssertEqual(try journal.observe("acct-69", "/2.2/networks/1", [JSON.obj(("uuid", "y"))]).count, 1, "recent scopes survive the 64-scope limit")
        XCTAssertEqual(try journal.observe("acct-0", "/2.2/networks/1", [JSON.obj(("uuid", "y"))]).count, 0, "oldest scopes are evicted and reseed quietly")
    }
}
