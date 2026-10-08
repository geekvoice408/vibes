import Testing
import Foundation
@testable import ServerLife

@Test func jsonRoundTrip() throws {
    let j = try JSON.parse(#"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#)
    #expect(j["a"].int == 1)
    #expect(j["b"][0].bool == true)
    #expect(j["b"][1].isNull)
    #expect(j["c"]["d"].double == 2.5)
    #expect(j["missing"]["deeper"].isNull)
    let back = try JSON.parse(j.text())
    #expect(back == j)
}

@Test func hostPrefKeys() {
    var h = Host(type: "teleport", id: "", name: "web-1")
    h.cluster = "c1"
    #expect(h.prefKey == "tsh:c1:web-1")
    h.uuid = "abc"
    #expect(h.prefKey == "uuid:abc")
    let s = Host(json: ["type": "ssh", "alias": "ent"])
    #expect(s.id == "ssh:ent")
    #expect(s.clusterPrefKey == "ssh")
}

@Test func formatting() {
    #expect(Fmt.bytes(512) == "512 B")
    #expect(Fmt.bytes(1536) == "1.50 KB")
    #expect(Fmt.duration(ms: 350) == "350ms")
    #expect(Fmt.duration(ms: 192_000) == "3m 12s")
    #expect(Posix.parent("/a/b/") == "/a")
    #expect(Posix.basename("/a/b") == "b")
    #expect(shellQuote("it's") == "'it'\\''s'")
    #expect(compareNames("node-2", "node-10") == .orderedAscending)
}

@Test func procRunsAndTimesOut() async {
    let r = await Proc.run("/bin/echo", ["hi"])
    #expect(r.ok && r.out == "hi\n")
    let t = await Proc.run("/bin/sleep", ["5"], timeout: 0.3)
    #expect(t.timedOut)
}

@Test @MainActor func storeDefaultsMerge() {
    let s = Store(dir: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sl-test-\(UUID())"))
    s.apply(parsed: ["settings": ["fontSize": 15], "profiles": "junk", "workspace": ["tabs": []]])
    #expect(s.setting("fontSize", 0) == 15)
    #expect(s.setting("mfaMode", "") == "platform")
    #expect(s["profiles"].array?.isEmpty == true)
    #expect(s["workspaces"]["w1"]["slot"].string == "w1")
}

@Test @MainActor func sharedStoreIsIsolatedUnderTests() {
    #expect(Store.shared.file.path.contains("serverlife-tests-"))
}


@Test func jsonIntNeverTraps() {
    #expect(JSON.number(1e20).int == nil)
    #expect(JSON.number(-1e20).int == nil)
    #expect(JSON.number(42).int == 42)
}

@Test func jsStyleJSONText() {
    let j: JSON = ["b": [], "a": ["x": 1, "s": "a/b\n"], "c": [:]]
    #expect(j.jsText(indent: 2) == "{\n  \"a\": {\n    \"s\": \"a/b\\n\",\n    \"x\": 1\n  },\n  \"b\": [],\n  \"c\": {}\n}")
    #expect(j.jsText() == "{\"a\":{\"s\":\"a/b\\n\",\"x\":1},\"b\":[],\"c\":{}}")
}

@Test @MainActor func storeSavesAtomicallyAndKeepsUnreadable() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sl-atomic-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: dir.appendingPathComponent("sessions.json"))
    let s = Store(dir: dir)
    s.load()
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names.contains { $0.hasPrefix("sessions.json.corrupt-") })
    s.setSetting("fontSize", 17)
    s.saveNow()
    let back = try JSON.parse(Data(contentsOf: dir.appendingPathComponent("sessions.json")))
    #expect(back["settings"]["fontSize"].int == 17)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions.json.tmp").path))
}

@Test func argumentsKeepTheirUnicodeBytes() async {
    // Precomposed é (U+00E9) must reach the child as C3 A9, not e + U+0301.
    let r = await Proc.run("/usr/bin/printf", ["%s", "h\u{00E9}llo"])
    #expect(Array(r.stdout) == [0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F])
    let t = await Proc.run("/bin/sleep", ["10"], timeout: 0.5)
    #expect(t.timedOut)
}
