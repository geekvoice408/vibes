import Testing
import Foundation
@testable import ServerLife

// Port of tests/reqmonitor.test.mjs (ReqMonitorLogic), plus the pure helpers
// of teleportpanel.js, livesessions.js and the store stand-in.

// MARK: - reqmonitor.test.mjs

private let G = ReqMonitorLogic.Group(proxy: "lab.example.com:443", home: nil, kind: "node", items: [])

private func res(_ id: String, _ name: String, _ labels: [String: String] = [:]) -> ReqMonitorLogic.Found {
    .init(id: id, name: name, labels: labels)
}

private let web1 = res("/lab/node/uuid-1", "web-1", ["env": "prod"])
private let web2 = res("/lab/node/uuid-2", "web-2", ["env": "prod"])

private func item(_ r: ReqMonitorLogic.Found, proxy: String = G.proxy, home: String? = nil, kind: String = "node") -> JSON {
    ["id": .string(r.id), "kind": .string(kind), "name": .string(r.name),
     "uuid": .string(String(r.id.split(separator: "/").last ?? "")), "cluster": "lab",
     "proxy": .string(proxy), "home": JSON(home), "labels": .object(r.labels.mapValues { .string($0) }),
     "addedAt": 1000, "lastSeen": 1000, "lastCheck": 1000, "missingSince": .null]
}

private func itemsOf(_ list: ReqMonitorLogic.Found...) -> [JSON] { list.map { item($0) } }

@Test func reqMonitorConfirmsAndFollowsDetails() {
    let renamed = res("/lab/node/uuid-1", "web-1-rebuilt", ["env": "prod", "role": "web"])
    let out = ReqMonitorLogic.applySearch(itemsOf(web1), group: G, resources: [renamed, web2], now: 5000)
    #expect(out.gone.isEmpty && out.back.isEmpty)
    #expect(out.items[0]["lastSeen"].double == 5000)
    #expect(out.items[0]["missingSince"].isNull)
    #expect(out.items[0]["name"].string == "web-1-rebuilt")
    #expect(out.items[0]["labels"] == ["env": "prod", "role": "web"])
}

@Test func reqMonitorGoneIsNoticedOnce() {
    let first = ReqMonitorLogic.applySearch(itemsOf(web1, web2), group: G, resources: [web2], now: 5000)
    #expect(first.gone.count == 1)
    #expect(first.gone[0]["name"].string == "web-1")
    #expect(first.items[0]["missingSince"].double == 5000)
    let second = ReqMonitorLogic.applySearch(first.items, group: G, resources: [web2], now: 9000)
    #expect(second.gone.isEmpty)
    #expect(second.items[0]["missingSince"].double == 5000)
    #expect(second.items[0]["lastCheck"].double == 9000)
}

@Test func reqMonitorKeepsLastSightingWhileGone() {
    let gone = ReqMonitorLogic.applySearch(itemsOf(web1), group: G, resources: [], now: 5000)
    let later = ReqMonitorLogic.applySearch(gone.items, group: G, resources: [], now: 9000)
    let rec = later.items[0]
    #expect(rec["lastSeen"].double == 1000)
    #expect(rec["name"].string == "web-1")
    #expect(rec["labels"] == ["env": "prod"])
}

@Test func reqMonitorComesBack() {
    let gone = ReqMonitorLogic.applySearch(itemsOf(web1), group: G, resources: [], now: 5000)
    let back = ReqMonitorLogic.applySearch(gone.items, group: G, resources: [web1], now: 9000)
    #expect(back.back.count == 1)
    #expect(back.items[0]["missingSince"].isNull)
    #expect(back.items[0]["lastSeen"].double == 9000)
}

@Test func reqMonitorOtherClusterKindHomeUntouched() {
    let elsewhere = item(web2, proxy: "other.example.com:443")
    let a = ReqMonitorLogic.applySearch(itemsOf(web1) + [elsewhere], group: G, resources: [web1], now: 5000)
    #expect(a.gone.isEmpty)
    #expect(a.items[1]["lastCheck"].double == 1000)

    let app = item(res("/lab/app/grafana", "grafana"), kind: "app")
    let b = ReqMonitorLogic.applySearch(itemsOf(web1) + [app], group: G, resources: [web1], now: 5000)
    #expect(b.gone.isEmpty)
    #expect(b.items[1]["missingSince"].isNull)

    let otherHome = item(web1, home: "/tmp/other-tsh")
    let c = ReqMonitorLogic.applySearch(itemsOf(web1) + [otherHome], group: G, resources: [], now: 5000)
    #expect(c.gone.count == 1)
    #expect(c.items[1]["missingSince"].isNull)
}

@Test func reqMonitorGroupsSearches() {
    let items = itemsOf(web1, web2) + [item(res("/lab/app/grafana", "g"), kind: "app"), item(web1, proxy: "other.example.com:443")]
    let groups = ReqMonitorLogic.groupsOf(items)
    #expect(groups.count == 3)
    #expect(groups.first { $0.kind == "node" && $0.proxy == G.proxy }?.items.count == 2)
}

@Test func reqMonitorInterval() {
    #expect(ReqMonitorLogic.monitorMinutes(.null) == 5)
    let cases: [(JSON, Int)] = [(1, 1), (0, 5), (-4, 5), (0.2, 1), (90, 60), (15, 15), ("x", 5)]
    for (given, want) in cases { #expect(ReqMonitorLogic.monitorMinutes(given) == want) }
}

@Test func reqMonitorKeyIdentity() {
    let a: JSON = ["id": "/lab/node/uuid-1", "proxy": "p", "home": .null]
    var b = a; b["home"] = "/tmp/h"
    var c = a; c["proxy"] = "q"
    var d = a; d["id"] = "/lab/node/uuid-2"
    #expect(ReqMonitorLogic.monitorKey(a) == ReqMonitorLogic.monitorKey(a))
    for x in [b, c, d] { #expect(ReqMonitorLogic.monitorKey(a) != ReqMonitorLogic.monitorKey(x)) }
}

@Test func reqMonitorMissingDetail() {
    let gone = ReqMonitorLogic.applySearch(itemsOf(web1), group: G, resources: [], now: 5000)
    let line = ReqMonitorLogic.missingDetail(gone.items[0])
    #expect(line.contains("Not in tsh request search"))
    #expect(line.contains("id: /lab/node/uuid-1"))
    #expect(line.contains("cluster: lab"))
    #expect(line.contains("labels: env=prod"))
}

@Test func reqMonitorAgo() {
    let now = nowMs()
    #expect(ReqMonitorLogic.ago(0) == "")
    #expect(ReqMonitorLogic.ago(now - 30_000, now: now).hasSuffix("s"))
    #expect(ReqMonitorLogic.ago(now - 20 * 60000, now: now) == "20m")
    #expect(ReqMonitorLogic.ago(now - 5 * 3_600_000, now: now) == "5h")
    #expect(ReqMonitorLogic.ago(now - 6 * 86_400_000, now: now) == "6d")
}

@Test func reqMonitorReconcileKeepsGone() {
    let items = itemsOf(web1, web2) + [{ var r = item(res("/lab/node/uuid-3", "retired-db-1")); r["missingSince"] = 4000; return r }(),
                                       item(web1, proxy: "other.example.com:443")]
    let out = ReqMonitorLogic.reconcileForProfile(items, proxy: G.proxy, home: nil, pickedIds: ["/lab/node/uuid-1"])
    #expect(out.map { "\($0["name"].string!)@\($0["proxy"].string!)" } ==
            ["web-1@lab.example.com:443", "retired-db-1@lab.example.com:443", "web-1@other.example.com:443"])
    #expect(ReqMonitorLogic.reconcileForProfile(itemsOf(web1, web2), proxy: "other.example.com:443", home: nil, pickedIds: []).count == 2)
}

private let statusKey = ReqMonitorLogic.groupStatusKey(proxy: G.proxy, home: nil, kind: "node")

@Test func reqMonitorUncheckedStates() {
    let now = nowMs()
    var r = item(web1); r["lastCheck"] = .number(now)
    let failed: JSON = [statusKey: ["okAt": 1000, "failAt": 2000, "error": "proxy unreachable"]]
    #expect(ReqMonitorLogic.rowState(r, status: failed, minutes: 5, now: now) == "unchecked")
    #expect(ReqMonitorLogic.groupError(r, status: failed).contains("proxy unreachable"))
    let ok: JSON = [statusKey: ["okAt": 3000, "failAt": 2000]]
    #expect(ReqMonitorLogic.rowState(r, status: ok, minutes: 5, now: now) == "ok")
    #expect(ReqMonitorLogic.groupError(r, status: ok) == "")

    var fresh = item(web1); fresh["lastCheck"] = .number(now - 60000)
    var stale = item(web1); stale["lastCheck"] = .number(now - 4 * 3_600_000)
    #expect(ReqMonitorLogic.rowState(fresh, status: [:], minutes: 5, now: now) == "ok")
    #expect(ReqMonitorLogic.rowState(stale, status: [:], minutes: 5, now: now) == "unchecked")
}

@Test func reqMonitorVerdictWithheldWhileUnreachable() {
    let now = nowMs()
    var r = item(web1); r["missingSince"] = 4000; r["lastCheck"] = .number(now)
    #expect(ReqMonitorLogic.rowState(r, status: [statusKey: ["okAt": .number(now)]], minutes: 5, now: now) == "gone")
    #expect(ReqMonitorLogic.rowState(r, status: [statusKey: ["okAt": 1000, "failAt": 9000]], minutes: 5, now: now) == "unchecked")
    #expect(ReqMonitorLogic.uncheckedDetail(r, status: [statusKey: ["failAt": 9000]]).contains("absent from the last search that worked"))
    let line = ReqMonitorLogic.uncheckedDetail(item(web1), status: [statusKey: ["failAt": 2000, "error": "certificate has expired"]])
    #expect(line.contains("says nothing"))
    #expect(line.contains("reason: certificate has expired"))
    #expect(line.contains("Last confirmed"))
}

@Test func reqMonitorEmptySearchInconclusive() {
    var r = item(web1); r["lastCheck"] = .number(nowMs())
    let status: JSON = [statusKey: ["okAt": 1000, "failAt": 2000, "emptyAt": 2000,
                                    "error": "the search returned nothing — roles, or a cluster that cannot answer for this kind"]]
    #expect(ReqMonitorLogic.rowState(r, status: status, minutes: 5, now: nowMs()) == "unchecked")
    #expect(ReqMonitorLogic.uncheckedDetail(r, status: status).contains("returned nothing"))
    #expect(ReqMonitorLogic.emptyCorroborationMs >= 10 * 60000)
}

@MainActor @Test func reqMonitorPaneNeverOpensItselfUnlessAsked() {
    let s = tuiFreshStore()
    defer { TUIData.store = .shared }
    #expect(ReqMonitor.autoOpenPane() == false)
    s.updateSettings(["requestMonitorOpen": true])
    #expect(ReqMonitor.autoOpenPane() == false)
    s.updateSettings(["requestMonitorAutoOpen": true])
    #expect(ReqMonitor.autoOpenPane() == true)
}

// MARK: - teleportpanel.js helpers

@MainActor @Test func panelFormatting() {
    let now = 1_000_000_000_000.0
    #expect(TUI.formatUntil(nil) == "unknown")
    #expect(TUI.formatUntil("garbage") == "garbage")
    #expect(TUI.formatUntil(TPText.isoString(ms: now + 45 * 60000), now: now) == "45m")
    #expect(TUI.formatUntil(TPText.isoString(ms: now + 192 * 60000), now: now) == "3h 12m")
    #expect(TUI.formatUntil(TPText.isoString(ms: now + (2 * 24 + 4) * 3_600_000), now: now) == "2d 4h")
    #expect(TUI.formatUntil(TPText.isoString(ms: now - 120_000), now: now) == "expired")
    #expect(TUI.formatSpan(59) == "59m")
    #expect(TUI.formatSpan(61) == "1h 1m")
    #expect(TUI.formatSpan(60 * 25) == "1d 1h")
    #expect(TUI.firstLine("\nUsage: tsh\n\u{1b}[31mERROR: boom\u{1b}[0m\n") == "ERROR: boom")
    #expect(TUI.firstLine("") == nil)
}

@MainActor @Test func panelShellQuote() {
    #expect(TUI.shellQuote("--proxy=lab.example.com:443") == "--proxy=lab.example.com:443")
    #expect(TUI.shellQuote("--reason=two words") == "--reason='two words'")
    #expect(TUI.shellQuote("--reason=it's") == "--reason='it'\\''s'")
    #expect(TUI.shellQuote("a b") == "'a b'")
    #expect(TUI.shellQuote("tsh") == "tsh")
}

@MainActor @Test func panelFutureIso() {
    let now = 1_000_000_000_000.0
    #expect(TUI.futureIso(Date(timeIntervalSince1970: now / 1000), now: now) == "")
    #expect(TUI.futureIso(Date(timeIntervalSince1970: (now + 30_000) / 1000), now: now) == "")
    #expect(TUI.futureIso(Date(timeIntervalSince1970: (now + 3_600_000) / 1000), now: now) == TPText.isoString(ms: now + 3_600_000))
    #expect(TUI.futureIso(nil) == "")
}

@MainActor @Test func panelAsPrefillDurations() {
    let created = "2026-10-06T10:00:00Z"
    let r = AccessRequest(id: "r1", user: "alice", roles: ["db"],
                          resources: [RequestResource(kind: "node", name: "uuid-1", sub: "", cluster: "lab", id: "/lab/node/uuid-1", label: "web-1")],
                          state: "APPROVED", reason: "", created: created, expires: "2026-10-06T17:56:00Z", assumeStartTime: nil,
                          maxDuration: "2026-10-06T14:00:00Z", sessionTtl: "2026-10-06T10:30:00Z", reviewers: ["bob"], proxy: "p")
    let p = TeleportProfile(proxy: "p", cluster: "lab")
    let f = AccessRequestsUI.asPrefill(r, p)
    #expect(f.requestTtl == "7h56m")
    #expect(f.maxDuration == "4h")
    #expect(f.sessionTtl == "30m")
    #expect(f.resources.first?.name == "web-1")
    #expect(f.reviewers == ["bob"])
    #expect(AccessRequestsUI.span(nil, "2026-10-06T14:00:00Z") == "")
    #expect(AccessRequestsUI.suggestedName(r, f.resources) == "web-1")
    var r2 = r; r2.reason = String(repeating: "x", count: 60)
    #expect(AccessRequestsUI.suggestedName(r2, f.resources) == String(repeating: "x", count: 47) + "…")
}

@MainActor @Test func panelClusterKeyAndLabels() {
    #expect(TUI.clusterKey(TeleportProfile(proxy: "p:443")) == "tp:p:443")
    #expect(TUI.clusterKey(TeleportProfile(proxy: "p:443", home: "/h")) == "tp:p:443@/h")
    let c = TeleportCluster(name: "leaf", leaf: true, status: "online", selected: false, labels: ["z": "1", "a": "2"])
    #expect(TeleportPanel.clusterLabels(c) == "a=2 · z=1")
    #expect(TeleportPanel.clusterLabels(nil) == "")
}

@MainActor @Test func liveSessionsJoinLine() {
    let s = ActiveSession(id: "sid-1", kind: "k8s", state: "running", created: nil, target: "kc", hostname: "", address: "",
                          kubeCluster: "kc", cluster: "lab", login: "", owner: "", command: "", reason: "", participants: [], joinable: true)
    #expect(LiveSessionsUI.joinCommandLine(s, mode: "observer", proxy: "p:443") == "tsh --proxy=p:443 kube join --mode=observer --cluster=lab sid-1")
    #expect(LiveSessionsUI.age(TPText.isoString(ms: 1_000_000_000_000 - 125 * 60000), now: 1_000_000_000_000) == "2h 5m")
}

@MainActor @Test func beamsTarNote() {
    let b = Beam(id: "b1", uuid: "u", owner: "", region: "", requestedRegion: "", url: "", expires: nil, proxy: "p", home: nil)
    let m = BeamOutputModel(b)
    m.up = true; m.local = "/Users/x/proj/"; m.remote = "/home/beams"
    #expect(m.tarNote.contains("tar czf proj.tar.gz -C '/Users/x' 'proj'"))
    #expect(m.tarNote.contains("then in the beam: tar xzf proj.tar.gz -C '/home/beams'"))
    #expect(BeamsUI.host(b).id == "beam:p:b1")
}

// MARK: - store stand-in

@MainActor @Test func dataStandInRecords() {
    _ = tuiFreshStore()
    defer { TUIData.store = .shared }

    let a = TUIData.upsertTshLogin(["proxy": "p:443", "user": "alice"])
    #expect(a["name"].string == "p:443")
    #expect(a["id"].string?.hasPrefix("tl_") == true)
    // Same proxy and user: an update, not a second record.
    let b = TUIData.upsertTshLogin(["proxy": "p:443", "user": "alice", "authConnector": "okta"])
    #expect(b["id"] == a["id"])
    #expect(TUIData.listTshLogins().count == 1)
    #expect(TUIData.listTshLogins()[0]["authConnector"].string == "okta")
    TUIData.deleteTshLogin(a["id"].string!)
    #expect(TUIData.listTshLogins().isEmpty)

    let t = TUIData.upsertRequestTemplate(["name": "x", "proxy": "p", "cluster": "lab",
                                           "resources": [["id": "/lab/node/u", "kind": "node", "name": "web", "labels": ["a": "b"]]]])
    #expect(t["resources"][0]["labels"].isNull)
    #expect(TUIData.listRequestTemplates(proxy: "nope", cluster: "lab").count == 1)
    #expect(TUIData.listRequestTemplates(proxy: "nope", cluster: "other").isEmpty)

    #expect(TUIData.upsertSessionNote(["sid": "s1", "flagged": true, "node": "n"])?["flagged"] == true)
    #expect(TUIData.upsertSessionNote(["sid": "s1", "note": "hi"])?["flagged"] == true)
    // Neither a flag nor a note: the record goes.
    #expect(TUIData.upsertSessionNote(["sid": "s1", "flagged": false, "note": ""]) == nil)
    #expect(TUIData.listSessionNotes().isEmpty)
}

/// A throwaway store (never the real sessions.json).
@MainActor
private func tuiFreshStore() -> Store {
    let s = Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("sl-tui-tests-\(UUID().uuidString)"))
    TUIData.store = s
    return s
}

@MainActor @Test func loginHomeFallsBackToDefault() {
    let homes = ["~/.tsh-work", "/opt/tsh-lab"]
    #expect(LoginDialogModel.configuredHome(NSHomeDirectory() + "/.tsh-work", in: homes) == "~/.tsh-work")
    #expect(LoginDialogModel.configuredHome("/opt/tsh-lab", in: homes) == "/opt/tsh-lab")
    #expect(LoginDialogModel.configuredHome("/somewhere/else", in: homes) == "")
    #expect(LoginDialogModel.configuredHome("", in: homes) == "")
}

@MainActor @Test func savedTemplateKeepsStartTime() {
    let f = AccessRequestsUI.Prefill(template: ["id": "rq_1", "assumeStartTime": "2030-01-01T10:00:00Z"])
    #expect(f.assumeStartTime == "2030-01-01T10:00:00Z")
}

@MainActor @Test func savedRequestsMatchedByProxyOnly() {
    let s = Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("sl-tui-tests-\(UUID().uuidString)"))
    TUIData.store = s
    defer { TUIData.store = .shared }
    TUIData.upsertRequestTemplate(["name": "a", "proxy": "one:443", "cluster": "prod"])
    TUIData.upsertRequestTemplate(["name": "b", "proxy": "two:443", "cluster": "prod"])
    #expect(TUIData.listRequestTemplates(proxy: "one:443").map { $0["name"].string } == ["a"])
}
