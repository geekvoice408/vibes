import Foundation
import Testing
@testable import ServerLife

/// The 3D view's measurements (tests/cityscan.test.mjs). A building's height
/// and colours come from these numbers, so a scanner that miscounts draws a
/// city that lies — and the local walk and the remote find|awk have to tell
/// the same story.
@Suite struct CityScanTests {
    func tree() throws -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("cityscan-\(UUID().uuidString.prefix(8))")
        func put(_ rel: String, _ bytes: Int) throws {
            let p = (root as NSString).appendingPathComponent(rel)
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x78, count: bytes).write(to: URL(fileURLWithPath: p))
        }
        try put("app src/main.js", 100)
        try put("app src/deep/er/util.ts", 50)
        try put("app src/notes.md", 7)
        try put("logs/syslog.log.3", 400)
        try put("logs/app.log", 40)
        try put("pics/a.PNG", 30)
        try put("pics/b.tar.gz", 20)
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent("empty"), withIntermediateDirectories: true)
        try put("loose.txt", 5)            // in the directory itself: not under any folder
        return root
    }

    @Test func kinds() {
        #expect(FileKinds.kindOf("main.JS") == "code")
        #expect(FileKinds.kindOf("backup.tar.gz") == "archives")
        #expect(FileKinds.kindOf("syslog.log.3") == "logs")
        #expect(FileKinds.kindOf("report.2") == "other")
        #expect(FileKinds.kindOf(".bashrc") == "other")
        #expect(FileKinds.kindOf("Makefile") == "other")
        #expect(FileKinds.kindOf("server.pem") == "secrets")
    }

    @Test func localScan() async throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let r = try await CityScan.scanLocal(root)
        #expect(r.truncated == false)
        #expect(r.children.keys.sorted() == ["app src", "empty", "logs", "pics"])
        let app = try #require(r.children["app src"])
        #expect(app.bytes == 157)
        #expect(app.files == 3)
        #expect(app.dirs == 2)
        #expect(app.kinds == ["code": 150, "docs": 7])
        #expect(r.children["logs"]?.kinds == ["logs": 440])
        #expect(r.children["pics"]?.kinds == ["images": 30, "archives": 20])
        #expect(r.children["empty"]?.bytes == 0)
    }

    @Test func remoteCommandAgreesWithLocalWalk() async throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let out = await Proc.run("/bin/sh", ["-c", CityScan.remoteCommand(root)], timeout: 60)
        let remote = try CityScan.parseRemote(out.out, dir: root)
        let local = try await CityScan.scanLocal(root)
        #expect(remote.truncated == false)
        for name in ["app src", "logs", "pics"] {
            let a = try #require(remote.children[name]), b = try #require(local.children[name])
            #expect(a.bytes == b.bytes, "\(name)")
            #expect(a.files == b.files, "\(name)")
            #expect(a.dirs == b.dirs, "\(name)")
            #expect(a.kinds == b.kinds, "\(name)")
        }
    }

    @Test func remoteParsePartialAndErrors() throws {
        let partial = try CityScan.parseRemote("D\tlogs\t2\t0\t440\nX\tlogs\tlog\t440\n", dir: "/var")
        #expect(partial.truncated == true)
        #expect(partial.children["logs"]?.bytes == 440)
        #expect(partial.children["logs"]?.kinds == ["logs": 440])

        let capped = try CityScan.parseRemote("N\t300000\nEND\n", dir: "/", maxEntries: 300000)
        #expect(capped.truncated == true)

        #expect(throws: (any Error).self) { try CityScan.parseRemote("ERR cannot enter\n", dir: "/root") }
        do { _ = try CityScan.parseRemote("ERR cannot enter\n", dir: "/root") } catch {
            #expect(errorText(error).contains("Cannot read /root"))
        }
    }

    @Test func remoteCommandQuotesTheDirectory() {
        let cmd = CityScan.remoteCommand("/tmp/it's here")
        #expect(cmd.contains(#"cd '/tmp/it'\''s here'"#))
    }

    @Test func unreadableLocalRootSaysSo() async {
        do {
            _ = try await CityScan.scanLocal("/no/such/dir-\(UUID().uuidString)")
            Issue.record("expected an error")
        } catch {
            #expect(errorText(error).hasPrefix("Cannot read /no/such/dir-"))
        }
    }
}

/// The city's traffic (tests/procscan.test.mjs). Each ps prints its columns
/// its own way, and a parser that loses a process to a space in its name
/// draws a town missing a car.
@Suite struct ProcScanTests {
    @Test func gnuAndBsdOutput() {
        let out = ProcScan.parse([
            "  633 44.3 111152 _windowserver /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            "    1  0.0  12000 root /sbin/launchd",
            " 4242  3,5 204800 steven /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ].joined(separator: "\n"))
        let byPid = Dictionary(uniqueKeysWithValues: out.map { ($0.pid, $0) })
        #expect(byPid[633]?.name == "WindowServer")
        #expect(byPid[633]?.cpu == 44.3)
        #expect(byPid[633]?.mem == Double(111152 * 1024))
        #expect(byPid[4242]?.name == "Google Chrome")
        #expect(byPid[4242]?.cpu == 3.5, "a comma decimal is still a number")
        #expect(byPid[1]?.user == "root")
    }

    @Test func busyboxHasNoCpuColumn() {
        let out = ProcScan.parse("  12 20480 root nginx\n  13 4096 www sh")
        #expect(out.map { "\($0.pid) \($0.cpu) \($0.name)" } == ["12 0.0 nginx", "13 0.0 sh"])
    }

    @Test func busiestFirstAndOnlyTheTop() {
        let lines = (0..<60).map { "\($0 + 1) \($0) 1024 u p\($0)" }
        let out = ProcScan.parse(lines.joined(separator: "\n"), top: 5)
        #expect(out.count == 5)
        #expect(out[0].name == "p59")
    }

    @Test func junkIsSkipped() {
        #expect(ProcScan.parse("PID %CPU RSS USER COMMAND\n\nps: something odd\n").isEmpty)
    }

    @Test func localPsAnswers() async throws {
        let procs = try await ProcScan.scanLocal()
        #expect(!procs.isEmpty)
        #expect(procs.count <= 40)
    }
}

/// The parts of the view that are rules rather than pictures.
@Suite struct CityRulesTests {
    @Test func seededMatchesTheJavaScript() {
        // Values from cityarch.js's `seeded` in node.
        #expect(cityHash("today|/Users/x/src") == 319083111)
        let r = CitySeeded("today|/Users/x/src")
        #expect(abs(r.next() - 0.42519116029143333) < 1e-12)
        #expect(abs(r.next() - 0.3912959396839142) < 1e-12)
        #expect(abs(r.next() - 0.3657188178040087) < 1e-12)
        #expect(cityHash("mideast|é☃") == 3194881656)
        let r2 = CitySeeded("mideast|é☃")
        #expect(abs(r2.next() - 0.114961868384853) < 1e-12)
    }

    @Test func styles() {
        #expect(CityStyle.byId("nope").id == "today")
        #expect(CityStyle.byId("deco").label == "Art Deco — 1930s skyline")
        #expect(CityStyle.groups == ["Now", "Around the world", "Through time"])
        #expect(CityStyle.all.count == 10)
    }

    @Test func bandsFoldSliversIntoOther() {
        var rec = CityRec()
        rec.bytes = 1000
        rec.kinds = ["code": 600, "logs": 20, "images": 300, "other": 80]
        let b = CityKinds.bands(rec)
        #expect(b.map(\.0) == ["code", "images", "other"])
        #expect(b.last?.1 == 100)
        #expect(CityKinds.summary(rec) == "Code 60% · Images 30% · Other 10%")
        #expect(CityKinds.bands(CityRec()).isEmpty)
    }

    @Test func sizes() {
        #expect(CityKinds.heightFor(0) == 3)
        #expect(CityKinds.footFor(0) == 10)
        #expect(CityKinds.footFor(1_000_000_000) == 26)
        #expect(CityKinds.crateFor(0) == 0.45)
        #expect(CityKinds.crateFor(1e15) == 2.8)
    }

    @Test func chaseRouteStaysOnTheGrid() throws {
        let xs: [Float] = [-54, -18, 18, 54], zs: [Float] = [-8, -44, -80]
        for _ in 0..<50 {
            let r = try #require(cityChaseRoute(xs: xs, zs: zs))
            #expect(r.length > 140)   // in from 70 outside and out again
            // Every point is on a street (give or take the lane), or outside town.
            for k in stride(from: Float(0), through: r.length, by: 3) {
                let p = r.at(k)
                let onX = xs.contains { abs($0 - p.x) <= 2.7 }, onZ = zs.contains { abs($0 - p.z) <= 2.7 }
                #expect(onX || onZ)
            }
        }
        #expect(cityChaseRoute(xs: [0], zs: [0, 1]) == nil)
    }

    @Test func procKinds() {
        let MB = 1024.0 * 1024
        #expect(CityProcRules.kindFor(CityProc(pid: 1, cpu: 70, mem: 0, user: "u", name: "x"), rocketSlots: 1) == .rocket)
        #expect(CityProcRules.kindFor(CityProc(pid: 1, cpu: 70, mem: 0, user: "u", name: "x"), rocketSlots: 0) == .car)
        #expect(CityProcRules.kindFor(CityProc(pid: 1, cpu: 1, mem: 500 * MB, user: "u", name: "x"), rocketSlots: 0) == .boat)
        #expect(CityProcRules.colorFor("root") == CityProcRules.hsl(0, 0.62, 0.5))
    }
}
