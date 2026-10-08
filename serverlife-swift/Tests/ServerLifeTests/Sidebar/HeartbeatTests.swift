import Testing
import Foundation
@testable import ServerLife

/// tests/heartbeat.test.mjs — heartbeat ages: read as of the list's read,
/// the TTL learnt off the freshest node, and both halves wrong only in the
/// direction that warns late.
extension SidebarStoreSuites { @MainActor @Suite struct SidebarHeartbeatTests {
    static let MIN: Double = 60000
    static let TTL: Double = 15 * 60000
    var MIN: Double { Self.MIN }

    init() {
        _ = sbFreshStore(["staleNodeMinutes": 2, "nodeRefreshSeconds": 10, "showHeartbeats": false, "quietNodeFilter": "all"])
        Heartbeat.reset()
        Heartbeat.clock = { nowMs() }
    }

    /// A cluster's list as it would be read now: each age is how long ago it spoke.
    func listFor(_ cluster: String, _ ages: [(String, Double)]) -> [ServerLife.Host] {
        let now = Heartbeat.clock()
        return ages.map { sbNode($0.0, [:], cluster: cluster, expires: now + Self.TTL - $0.1) }
    }

    func withClock(_ ms: Double, _ body: () -> Void) {
        let base = nowMs()
        Heartbeat.clock = { base + ms }
        body()
        Heartbeat.clock = { nowMs() }
    }

    func key(_ n: ServerLife.Host) -> String { Heartbeat.keyFor(n) }

    @Test func theIntervalIsReadOffTheFreshestNode() {
        let nodes = listFor("c-ttl", [("a", 5000), ("b", 90000), ("c", 200000)])
        Heartbeat.observe(key(nodes[0]), nodes)
        #expect(Heartbeat.heartbeatAge(nodes[0])! < MIN)
        #expect(Int((Heartbeat.heartbeatAge(nodes[1])! / 1000).rounded()) == 90)
        #expect(Int((Heartbeat.heartbeatAge(nodes[2])! / 1000).rounded()) == 200)
    }

    @Test func aNodeWithNoExpiryHasNoAge() {
        let n = sbNode("agentless", [:], cluster: "c-ttl")
        #expect(Heartbeat.heartbeatAge(n) == nil)
        #expect(!Heartbeat.isStale(n))
        #expect(Heartbeat.ageLabel(n) == "")
    }

    @Test func aClusterNobodyHasReadHasNoAges() {
        let n = sbNode("x", [:], cluster: "never-read", expires: nowMs() + Self.TTL)
        #expect(Heartbeat.heartbeatAge(n) == nil)
    }

    @Test func anSshHostIsNeverJudged() {
        var h = sbSshHost("a")
        h.expires = TPText.isoString(ms: nowMs())
        #expect(Heartbeat.heartbeatAge(h) == nil)
    }

    @Test func theAgeIsTakenAsOfTheRead() {
        let nodes = listFor("c-clock", [("fresh", 5000), ("old", 9 * MIN)])
        Heartbeat.observe(key(nodes[0]), nodes)
        let atRead = Heartbeat.heartbeatAge(nodes[1])
        withClock(10000) { #expect(Heartbeat.heartbeatAge(nodes[1]) == atRead) }
    }

    @Test func pastTheGracePeriodNothingIsJudged() {
        let nodes = listFor("c-grace", [("fresh", 5000), ("old", 9 * MIN)])
        Heartbeat.observe(key(nodes[0]), nodes)
        #expect(Heartbeat.isStale(nodes[1]))
        withClock(4 * MIN) {
            #expect(Heartbeat.heartbeatAge(nodes[0]) == nil)
            #expect(Heartbeat.heartbeatAge(nodes[1]) == nil)
            #expect(!Heartbeat.isStale(nodes[1]), "a stale list must not make every node look quiet")
        }
    }

    @Test func theGraceFollowsTheRefreshInterval() {
        SB.store.updateSettings(["nodeRefreshSeconds": 300])
        let nodes = listFor("c-slow", [("fresh", 5000), ("old", 9 * MIN)])
        Heartbeat.observe(key(nodes[0]), nodes)
        withClock(10 * MIN) { #expect(Heartbeat.heartbeatAge(nodes[1]) != nil) }
        withClock(20 * MIN) { #expect(Heartbeat.heartbeatAge(nodes[1]) == nil) }
    }

    @Test func staleIsTheUsersThresholdAndZeroTurnsItOff() {
        let nodes = listFor("c-thresh", [("fresh", 5000), ("three", 3 * MIN), ("nine", 9 * MIN)])
        Heartbeat.observe(key(nodes[0]), nodes)
        SB.store.updateSettings(["staleNodeMinutes": 2])
        #expect(nodes.filter { Heartbeat.isStale($0) }.map(\.name) == ["three", "nine"])
        SB.store.updateSettings(["staleNodeMinutes": 5])
        #expect(nodes.filter { Heartbeat.isStale($0) }.map(\.name) == ["nine"])
        SB.store.updateSettings(["staleNodeMinutes": 0])
        #expect(nodes.filter { Heartbeat.isStale($0) }.map(\.name) == [])
    }

    @Test func theLabelsReadAsMinutes() {
        let nodes = listFor("c-label", [("fresh", 5000), ("seven", 7 * MIN), ("hours", 70 * MIN)])
        Heartbeat.observe(key(nodes[0]), nodes)
        #expect(Heartbeat.ageLabel(nodes[0]) == "<1m")
        #expect(Heartbeat.ageLabel(nodes[1]) == "7m")
        #expect(Heartbeat.ageLabel(nodes[2]) == "1h 10m")
        #expect(Heartbeat.staleLabel(nodes[0]) == "")
        #expect(Heartbeat.staleLabel(nodes[1]) == "7m")
    }

    @Test func theTooltipSaysHowLongIsLeft() {
        let nodes = listFor("c-tip", [("fresh", 5000), ("nine", 9 * MIN)])
        Heartbeat.observe(key(nodes[0]), nodes)
        #expect(Heartbeat.heartbeatLine(nodes[0]).range(of: #"^last heartbeat: \d+s ago$"#, options: .regularExpression) != nil)
        let line = Heartbeat.heartbeatLine(nodes[1])
        #expect(line.contains("9 minutes ago"))
        #expect(line.contains("may be gone"))
        #expect(line.contains("6 minutes left"))
    }

    @Test func theSignatureOnlyCarriesWhatIsDrawn() {
        let nodes = listFor("c-sig", [("fresh", 5000), ("nine", 9 * MIN)])
        Heartbeat.observe(key(nodes[0]), nodes)
        SB.store.updateSettings(["showHeartbeats": false, "staleNodeMinutes": 2])
        let quietOnly = Heartbeat.heartbeatSignature(nodes)
        #expect(quietOnly.contains("nine"))
        #expect(!quietOnly.contains("fresh"))
        SB.store.updateSettings(["showHeartbeats": true])
        let all = Heartbeat.heartbeatSignature(nodes)
        #expect(all.contains("fresh") && all.contains("nine"))
        SB.store.updateSettings(["showHeartbeats": false, "staleNodeMinutes": 0])
        #expect(Heartbeat.heartbeatSignature(nodes) == "")
    }

    @Test func theQuietFilterAndHeartbeatToggleReadTheirSettings() {
        #expect(Heartbeat.quietFilter == "all")
        #expect(!Heartbeat.showHeartbeats)
        SB.store.updateSettings(["quietNodeFilter": "only", "showHeartbeats": true])
        #expect(Heartbeat.quietFilter == "only")
        #expect(Heartbeat.showHeartbeats)
        SB.store.updateSettings(["quietNodeFilter": "nonsense"])
        #expect(Heartbeat.quietFilter == "all")
    }
}
}
