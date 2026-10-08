import Testing
import Foundation
@testable import ServerLife

/// tests/watch.test.mjs — watching for a disappearance: it must notice, and
/// it must not cry wolf.
extension SidebarStoreSuites { @MainActor @Suite struct SidebarHostWatchTests {
    typealias W = HostWatch
    static let G = "tp:example:443"
    var G: String { Self.G }
    let web1 = sbNode("web-1", ["env": "prod"])
    let web2 = sbNode("web-2", ["env": "prod"])
    let db1 = sbNode("db-1", ["env": "prod"])

    init() {
        _ = sbFreshStore(["watchedHosts": [:], "nodeRefreshSeconds": 10])
        W.forgetEmptyReads()
        Requestable.invalidate()
        Requestable.search = { _, _, _ in TshList(ok: true, error: nil, items: []) }
    }

    func rec(_ h: ServerLife.Host) -> JSON { W.record(h) ?? .null }

    func stubSearch(_ hosts: [ServerLife.Host]) {
        let res = hosts.map { RequestableResource(id: "/c1/node/\($0.uuid!)", kind: "node", name: $0.name, uuid: $0.uuid!,
                                                  cluster: "c1", proxy: nil, labels: [:]) }
        Requestable.invalidate()
        Requestable.search = { _, _, _ in TshList(ok: true, error: nil, items: res) }
    }

    func node(_ name: String, _ labels: [String: String], addr: String) -> ServerLife.Host {
        var h = sbNode(name, labels); h.addr = addr; return h
    }

    @Test func markingKeepsIdAndLastKnownDetails() {
        W.setWatched(web1, G, true)
        #expect(W.isWatched(web1))
        let r = rec(web1)
        #expect(r["uuid"].string == "uuid-web-1")
        #expect(r["name"].string == "web-1")
        #expect(r["cluster"].string == "c1")
        #expect(r["group"].string == G)
        #expect(r["labels"] == ["env": "prod"])
        #expect((r["lastSeen"].double ?? 0) > 0)
        #expect(r["missingSince"].isNull)
        #expect(W.watchCount() == 1)
    }

    @Test func unmarkingTakesTheRecord() {
        W.setWatched(web1, G, true)
        W.toggleWatch(web1, G)
        #expect(!W.isWatched(web1))
        #expect(W.watchCount() == 0)
    }

    @Test func aListedHostIsRefreshed() async {
        W.setWatched(web1, G, true)
        let moved = node("web-1", ["env": "prod", "role": "web"], addr: "10.0.0.9:3022")
        await W.noteSeen(G, [moved, web2])
        let r = rec(web1)
        #expect(r["missingSince"].isNull)
        #expect(r["addr"].string == "10.0.0.9:3022")
        #expect(r["labels"] == ["env": "prod", "role": "web"])
        #expect(W.missingIn(G, [moved, web2]).isEmpty)
    }

    @Test func aHostThatLeavesIsNoticedOnce() async throws {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1, web2])
        await W.noteSeen(G, [web2])
        let first = rec(web1)["missingSince"].double
        #expect(first != nil)
        try await Task.sleep(nanoseconds: 5_000_000)
        await W.noteSeen(G, [web2])
        #expect(rec(web1)["missingSince"].double == first)
    }

    @Test func aMissingHostIsDrawnFromTheRecord() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1])
        await W.noteSeen(G, [db1])
        let ghosts = W.missingIn(G, [])
        #expect(ghosts.count == 1)
        let g = ghosts[0]
        #expect(g.watchMissing)
        #expect(g.name == "web-1")
        #expect(g.uuid == "uuid-web-1")
        #expect(g.cluster == "c1")
        #expect(g.labels == ["env": "prod"])
        #expect(g.id.hasPrefix("missing:"))
        #expect(Tags.compileQuery("env=prod").match(g))
        #expect(Tags.compileQuery("name=web-1").match(g))
    }

    @Test func aHostThatComesBackStopsBeingMissing() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [db1])
        #expect(W.missingIn(G, []).count == 1)
        await W.noteSeen(G, [web1])
        #expect(rec(web1)["missingSince"].isNull)
        #expect(W.missingIn(G, [web1]).isEmpty)
    }

    @Test func aGroupNeverReadDeclaresNothing() {
        W.setWatched(web1, G, true)
        #expect(W.missingIn(G, []).isEmpty)
        #expect(W.missingHosts().isEmpty)
    }

    @Test func anotherGroupsReadSaysNothing() async {
        W.setWatched(web1, G, true)
        await W.noteSeen("tp:somewhere-else:443", [])
        #expect(rec(web1)["missingSince"].isNull)
        #expect(W.missingIn(G, []).isEmpty)
    }

    @Test func aPresentHostIsNeverAGhost() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [db1])
        #expect(W.missingIn(G, []).count == 1)
        #expect(W.missingIn(G, [web1]).isEmpty)
    }

    @Test func sshHostsCanBeWatched() async {
        let jump = sbSshHost("jump")
        W.setWatched(jump, "ssh", true)
        await W.noteSeen("ssh", [sbSshHost("bastion")])
        let ghosts = W.missingIn("ssh", [])
        #expect(ghosts.count == 1)
        #expect(ghosts[0].alias == "jump")
        #expect(ghosts[0].type == "ssh")
    }

    @Test func goneForReadsInTheLargestUsefulUnit() {
        let now = nowMs()
        #expect(W.goneFor(now - 30 * 1000).hasSuffix("s"))
        #expect(W.goneFor(now - 20 * 60000).hasSuffix("m"))
        #expect(W.goneFor(now - 5 * 3600000).hasSuffix("h"))
        #expect(W.goneFor(now - 6 * 86400000).hasSuffix("d"))
    }

    @Test func theTooltipSaysWhatTheClusterNoLongerCan() async {
        W.setWatched(node("web-1", [:], addr: "10.0.0.9:3022"), G, true)
        await W.noteSeen(G, [db1])
        let line = W.missingLine(W.missingIn(G, [])[0])
        #expect(line.contains("Not in the inventory"))
        #expect(line.contains("Last seen"))
        #expect(line.contains("uuid-web-1"))
        #expect(line.contains("10.0.0.9:3022"))
    }

    @Test func theBellCanBeTurnedOffWithoutTheWatch() async {
        W.setWatched(web1, G, true)
        #expect(W.showWatchMark)
        SB.store.updateSettings(["showWatchMark": false])
        #expect(!W.showWatchMark)
        #expect(W.isWatched(web1))
        await W.noteSeen(G, [db1])
        #expect(W.missingIn(G, []).count == 1)
    }

    @Test func anOrphanIsDrawnButNotAsAVerdict() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [db1])
        #expect(W.orphanGhosts([G]).isEmpty)
        let loose = W.orphanGhosts(["tp:other:443"])
        #expect(loose.count == 1)
        #expect(loose[0].name == "web-1")
        #expect(!loose[0].watchMissing)
        #expect(loose[0].watchUnconfirmed)
        #expect(loose[0].watchGroup == G)
        #expect(loose[0].watchMissingSince != nil)
        #expect(W.unconfirmedLine(loose[0]).contains("absent from the last list that could be read"))
        #expect(W.orphanGhosts([]).map(\.id) == loose.map(\.id))
    }

    @Test func aPresentWatchedHostIsNotAnOrphan() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1])
        #expect(W.orphanGhosts([]).isEmpty)
    }

    @Test func theSameClusterWithAndWithoutItsPort() async {
        W.setWatched(web1, "tp:lab.example.com:443", true)
        await W.noteSeen("tp:lab.example.com", [db1])
        #expect(rec(web1)["missingSince"].double != nil)
        #expect(W.missingIn("tp:lab.example.com", []).count == 1)
        #expect(W.missingIn("tp:lab.example.com:443", []).count == 1)
        #expect(W.orphanGhosts(["tp:lab.example.com"]).isEmpty)
    }

    @Test func whatWasKnownIsNeverOverwrittenAfterwards() async throws {
        let before = node("web-1", ["env": "prod", "role": "web"], addr: "10.0.4.9:3022")
        W.setWatched(before, G, true)
        await W.noteSeen(G, [before])
        let seenAt = rec(before)["lastSeen"].double
        try await Task.sleep(nanoseconds: 5_000_000)
        await W.noteSeen(G, [db1])
        try await Task.sleep(nanoseconds: 5_000_000)
        await W.noteSeen(G, [web2])
        let r = rec(before)
        #expect(r["lastSeen"].double == seenAt)
        #expect(r["addr"].string == "10.0.4.9:3022")
        #expect(r["labels"] == ["env": "prod", "role": "web"])
        #expect(r["hostname"].string == "web-1")
        #expect(r["cluster"].string == "c1")
    }

    @Test func theTooltipCarriesTheDetails() async {
        let h = node("web-1", ["env": "prod", "teleport.internal/resource-id": "x-1"], addr: "10.0.4.9:3022")
        W.setWatched(h, G, true)
        await W.noteSeen(G, [db1])
        let line = W.missingLine(W.missingIn(G, [])[0])
        #expect(line.contains("node id: uuid-web-1"))
        #expect(line.contains("last address: 10.0.4.9:3022"))
        #expect(line.contains("cluster: c1"))
        #expect(line.contains("labels: env=prod"))
        #expect(!line.contains("resource-id"))
    }

    @Test func everythingCanBeUnwatchedAtOnce() {
        W.setWatched(web1, G, true)
        W.setWatched(web2, G, true)
        #expect(W.watchCount() == 2)
        W.forgetAll()
        #expect(W.watchCount() == 0)
        #expect(W.missingIn(G, []).isEmpty)
    }

    @Test func aWatchedHostGoesUnconfirmedOnceReadsStop() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1])
        #expect(W.unconfirmedIn(G, [web1]).isEmpty)
        #expect(W.unconfirmedIn(G, []).isEmpty)
        let later = nowMs() + 4 * 3600000
        let loose = W.unconfirmedIn(G, [], now: later)
        #expect(loose.count == 1)
        #expect(loose[0].watchUnconfirmed)
        #expect(!loose[0].watchMissing)
        #expect(loose[0].name == "web-1")
    }

    @Test func aHostJudgedGoneIsGoneNotUnconfirmed() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [db1])
        #expect(W.unconfirmedIn(G, [], now: nowMs() + 4 * 3600000).isEmpty)
        #expect(W.missingIn(G, []).count == 1)
    }

    @Test func aClusterNotListedReportsEverythingUnchecked() async {
        W.setWatched(web1, G, true)
        W.setWatched(web2, G, true)
        await W.noteSeen(G, [web1, web2])
        await W.noteSeen(G, [web1, db1])
        let loose = W.orphanGhosts(["tp:somewhere-else:443"], now: nowMs() + 4 * 3600000)
        #expect(loose.map(\.name).sorted() == ["web-1", "web-2"])
        #expect(loose.allSatisfy { !$0.watchMissing })
        #expect(loose.first { $0.name == "web-2" }?.watchMissingSince != nil)
        #expect(loose.first { $0.name == "web-1" }?.watchMissingSince == nil)
    }

    @Test func theUnconfirmedTooltipBlamesTheCluster() {
        W.setWatched(web1, G, true)
        let line = W.unconfirmedLine(W.unconfirmedIn(G, [], now: nowMs() + 4 * 3600000)[0])
        #expect(line.contains("could not be read"))
        #expect(line.contains("says nothing"))
        #expect(line.contains("Last confirmed"))
    }

    @Test func anEmptyReadMarksNothingQuickly() async {
        W.setWatched(web1, G, true)
        W.setWatched(web2, G, true)
        await W.noteSeen(G, [web1, web2])
        let t0 = nowMs()
        for at in [t0, t0 + 1000, t0 + 60000, t0 + 5 * 60000] { await W.noteSeen(G, [], now: at) }
        #expect(rec(web1)["missingSince"].isNull)
        #expect(rec(web2)["missingSince"].isNull)
        #expect(W.missingIn(G, []).isEmpty)
    }

    @Test func aClusterThatStaysEmptyIsEventuallyBelieved() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1])
        let t0 = nowMs()
        await W.noteSeen(G, [], now: t0)
        #expect(rec(web1)["missingSince"].isNull)
        let change = await W.noteSeen(G, [], now: t0 + 11 * 60000)
        #expect(rec(web1)["missingSince"].double == t0 + 11 * 60000)
        #expect(change?.gone.count == 1)
    }

    @Test func aListInBetweenClearsTheCount() async {
        W.setWatched(web1, G, true)
        let t0 = nowMs()
        await W.noteSeen(G, [], now: t0)
        await W.noteSeen(G, [web1], now: t0 + 60000)
        await W.noteSeen(G, [], now: t0 + 11 * 60000)
        #expect(rec(web1)["missingSince"].isNull)
    }

    @Test func oneHostAbsentFromOthersIsDetectedAtOnce() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1, web2, db1])
        let change = await W.noteSeen(G, [web2, db1])
        #expect(change?.gone.count == 1)
        #expect(rec(web1)["missingSince"].double != nil)
    }

    @Test func aRequestableHostIsNotCalledGone() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1, db1])
        stubSearch([web1])
        let change = await W.noteSeen(G, [db1])
        let r = rec(web1)
        #expect(r["missingSince"].isNull)
        #expect(r["requestableSince"].double != nil)
        #expect(change?.gone.count == 0)
        #expect(change?.askable.count == 1)
        #expect(W.missingIn(G, []).isEmpty)
        let askable = W.requestableIn(G, [])
        #expect(askable.count == 1)
        #expect(askable[0].isRequestableRow)
        #expect(!askable[0].watchMissing)
        #expect(askable[0].name == "web-1")
        // And it is not drawn twice.
        #expect(W.unconfirmedIn(G, [], now: nowMs() + 4 * 3600000).isEmpty)
    }

    @Test func anEmptyListDoesNotStopAWrongVerdictBeingCorrected() async {
        W.setWatched(web1, G, true)
        var map = SB.store.settingJSON("watchedHosts").entries
        let k = map.keys.first!
        map[k]!["missingSince"] = .number(nowMs() - 7_200_000)
        SB.store.updateSettings(["watchedHosts": .object(map)])
        stubSearch([web1])
        await W.noteSeen(G, [])
        #expect(rec(web1)["missingSince"].isNull)
        #expect(rec(web1)["requestableSince"].double != nil)
    }

    @Test func comingBackToStandingAccessClearsIt() async {
        W.setWatched(web1, G, true)
        stubSearch([web1])
        await W.noteSeen(G, [db1])
        #expect(rec(web1)["requestableSince"].double != nil)
        let change = await W.noteSeen(G, [web1, db1])
        #expect(rec(web1)["requestableSince"].isNull)
        #expect(rec(web1)["missingSince"].isNull)
        #expect(change?.back.count == 1)
        #expect(W.requestableIn(G, []).isEmpty)
    }

    @Test func aFailedSearchLeavesTheVerdictAlone() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1, db1])
        Requestable.invalidate()
        Requestable.search = { _, _, _ in TshList.failed("proxy unreachable") }
        await W.noteSeen(G, [db1])
        #expect(rec(web1)["missingSince"].double != nil)
        #expect(rec(web1)["requestableSince"].isNull)
    }

    @Test func aNarrowedReadSaysNothingAboutWhatItLeavesOut() async {
        W.setWatched(web1, G, true)
        W.setWatched(web2, G, true)
        await W.noteSeen(G, [web1, web2, db1])
        Requestable.search = { _, _, _ in Issue.record("must not be asked"); return TshList(ok: true, error: nil, items: []) }
        let change = await W.noteSeen(G, [db1], partial: true)
        #expect((change?.gone.count ?? 0) == 0)
        #expect(rec(web1)["missingSince"].isNull)
        #expect(rec(web1)["requestableSince"].isNull)
        #expect(W.missingIn(G, [db1]).isEmpty)
    }

    @Test func butWhatANarrowedReadListsCountsAsSeen() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web2, db1])
        #expect(rec(web1)["missingSince"].double != nil)
        let change = await W.noteSeen(G, [web1], partial: true)
        #expect(change?.back.count == 1)
        #expect(rec(web1)["missingSince"].isNull)
    }

    @Test func anEmptyNarrowedReadDoesNotStartTheClock() async {
        W.setWatched(web1, G, true)
        await W.noteSeen(G, [web1, db1])
        let t0 = nowMs()
        await W.noteSeen(G, [], now: t0, partial: true)
        await W.noteSeen(G, [], now: t0 + 11 * 60 * 1000)
        #expect(rec(web1)["missingSince"].isNull)
    }
}
}
