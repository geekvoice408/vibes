import Testing
import Foundation
@testable import ServerLife

/// The host list's ordering and summary rules (sidebar.js `orderHosts`,
/// `orderedGroups`, `labelSummary`, narrowed.js `heldBackFor`).
extension SidebarStoreSuites {
    @MainActor @Suite struct SidebarLogicTests {
        init() { _ = sbFreshStore(["starredHosts": [], "starredMode": "inline", "hostOrder": [:]]) }

        @Test func aDraggedOrderOutranksStarsWhichOutrankArrival() {
            let hs = ["a", "b", "c", "d"].map { sbNode($0) }
            SB.store.updateSettings(["starredHosts": ["tsh:c1:c"]])
            #expect(HostPrefs.orderHosts(hs, "g").map(\.name) == ["c", "a", "b", "d"])
            HostPrefs.saveHostOrder("g", ["tsh:c1:d"])
            #expect(HostPrefs.orderHosts(hs, "g").map(\.name) == ["d", "c", "a", "b"])
            SB.store.updateSettings(["starredMode": "group"])
            #expect(HostPrefs.orderHosts(hs, "g").map(\.name) == ["d", "a", "b", "c"])
        }

        @Test func groupsFollowTheSavedOrderNewOnesBehindAndStarredPinned() {
            let keys = ["starred", "tp:a", "ssh", "local", "tp:b"]
            #expect(HostPrefs.orderedGroupKeys(keys, order: ["ssh", "tp:a"]) == ["starred", "ssh", "tp:a", "local", "tp:b"])
            #expect(HostPrefs.orderedGroupKeys(keys, order: ["ssh", "starred"]) == ["ssh", "starred", "tp:a", "local", "tp:b"])
        }

        @Test func theSummaryPicksTheLabelPeopleSortBy() {
            #expect(SB2.labelSummary(sbNode("x", ["zone": "a", "aws/env": "production-east", "role": "web"])) == "production-… +2")
            #expect(SB2.labelSummary(sbNode("x", ["gpu": "true"])) == "gpu")
            #expect(SB2.labelSummary(sbNode("x", [:])) == "")
        }

        @Test func aNarrowedReadHoldsBackTheRestOfTheLastFullList() {
            Narrowed.reset()
            var p = TeleportProfile(proxy: "px:443", cluster: "c1")
            let all = [sbNode("a"), sbNode("b"), sbNode("c")]
            Narrowed.noteRead(p, all)
            #expect(Narrowed.heldBack(for: p, reachable: [all[0]]).isEmpty)
            p.allowedResources = ["node/uuid-a"]
            p.activeRequests = ["req-1"]
            Narrowed.noteRead(p, [all[0]])
            let held = Narrowed.heldBack(for: p, reachable: [all[0]])
            #expect(held.map(\.name) == ["b", "c"])
            #expect(held.allSatisfy { $0.isHeldBack && $0.heldBy == ["req-1"] })
        }

        @Test func threeLevelsHostThenClusterThenGlobal() {
            let h = sbNode("a")
            SB.store.updateSettings(["agentForward": false])
            #expect(HostPrefs.agentForward(h) == .init(on: false, from: "default"))
            HostPrefs.setAgentForwardForCluster(h.clusterPrefKey, true)
            #expect(HostPrefs.agentForward(h) == .init(on: true, from: "cluster"))
            HostPrefs.setAgentForward(h, false)
            #expect(HostPrefs.agentForward(h) == .init(on: false, from: "host"))
            HostPrefs.setMfaHost(h, true)
            #expect(HostPrefs.tmux(h).from == "mfa")
        }
    }
}
