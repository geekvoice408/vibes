import AppKit
import SceneKit
import Testing
@testable import ServerLife

/// A host with nothing behind it but a folder.
@MainActor
private final class BareHost: CityExplorerHost {
    var path: String
    var entries: [FileEntry]
    init(_ path: String, _ entries: [FileEntry]) { self.path = path; self.entries = entries }
    var cityPath: String? { path }
    var cityEntries: [FileEntry] { entries }
    func cityShownEntries() -> [FileEntry] { entries }
    var cityShowHidden: Bool { false }
    var citySourceKey: String { "local" }
    var citySourceKind: FileSourceKind { .local }
    var cityConnId: String? { nil }
    func cityMatcher() -> ((String) -> Bool)? { nil }
    var cityFilterActive: Bool { false }
    var citySelection: Set<String> = []
    func citySelectionChanged(lastClicked: String?) {}
    func cityNavigate(_ path: String) async throws {}
    func cityGoParent() async throws {}
    func cityOpen(_ entry: FileEntry) {}
    func cityContextMenu(_ entry: FileEntry?, event: NSEvent, in view: NSView) {}
    func cityFocusFilter() {}
    func cityClearFilter() {}
    var cityMaximized = false
    var city: CityController?
}

@MainActor
@Suite struct CityLifecycleTests {
    /// Closing a city frees it: the controller, its SCNView and the scene
    /// (with its 4096×2048 night backdrop) — no cycle keeps them.
    @Test func destroyFreesControllerViewAndScene() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("city-life-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir + "/a/b", withIntermediateDirectories: true)
        try Data(count: 5000).write(to: URL(fileURLWithPath: dir + "/a/x.js"))
        try Data(count: 100).write(to: URL(fileURLWithPath: dir + "/loose.txt"))
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let entries = try await LocalFS.list(dir)

        weak var wc: CityController?
        weak var wv: SCNView?
        weak var ws: SCNScene?
        do {
            let host = BareHost(dir, entries)
            let c = CityController(host: host)
            host.city = c
            c.sync()
            _ = c.view                       // what the explorer would draw
            try await Task.sleep(nanoseconds: 600_000_000)   // let the scan land and rebuild
            #expect(!c.items.isEmpty)
            wc = c; wv = c.scnView; ws = c.scene
            c.destroy()
            host.city = nil
        }
        // Let pending main-actor work (observation, scan tasks) drain.
        for _ in 0..<20 where wc != nil || wv != nil || ws != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(wc == nil, "controller freed")
        #expect(wv == nil, "SCNView freed")
        #expect(ws == nil, "scene freed")
    }

    @Test func hugeRemoteNumbersDoNotTrap() throws {
        let r = try CityScan.parseRemote("D\tbig\t1e300\t99999999999999999999\t1e30\nN\t1e40\nEND\n", dir: "/")
        #expect(r.children["big"]?.files == Int.max)
        #expect(r.children["big"]?.dirs == Int.max)
        #expect(r.truncated == true)
    }

    @Test func localErrorIsNodesWording() async {
        do { _ = try await CityScan.scanLocal("/no/such/x") } catch {
            #expect(errorText(error) == "Cannot read /no/such/x: ENOENT: no such file or directory, scandir '/no/such/x'")
        }
    }

    @Test func hslMatchesThree() {
        // three 0.186: setHSL(0, 0.62, 0.5) is linear (0.81, 0.19, 0.19);
        // getHex() encodes it to sRGB → 0xe87979.
        let c = CityProcRules.hsl(0, 0.62, 0.5)
        #expect((c >> 16) & 0xff == 232)
        #expect((c >> 8) & 0xff == 121)
        #expect(c & 0xff == 121)
    }
}
