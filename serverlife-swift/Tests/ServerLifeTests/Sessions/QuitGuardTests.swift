import Testing
import Foundation
@testable import ServerLife

// Port of tests/quitguard.test.mjs: the failure that matters is the false alarm.

private typealias P = QuitGuard.PaneInfo
private func census(_ tabs: [QuitGuard.TabInfo], _ conns: [String: QuitGuard.ConnInfo] = [:],
                    forwards: [String: Int] = [:]) -> QuitGuard.Census {
    QuitGuard.Census(tabs: tabs, conn: { conns[$0] }, forwards: { forwards[$0] ?? 0 })
}

@Test func quitLocalShellsNeverCount() {
    let s = census([.init(id: "t1", title: "zsh", panes: [P(id: "p1", kind: "local", hasTerm: true, status: "connected")])])
    #expect(QuitGuard.liveSessions(s).isEmpty)
}

@Test func quitConnectedRemoteCounts() {
    let s = census([.init(id: "t1", title: "web-1", panes: [P(id: "p1", kind: "remote", connId: "c1", hasTerm: true, status: "connected")])],
                   ["c1": .init(state: "connected", type: "teleport", label: "web-1.prod")])
    #expect(QuitGuard.liveSessions(s) == [.init(kind: "teleport", name: "web-1.prod")])
}

@Test func quitDeadRemotesDoNotCount() {
    let s = census([
        .init(id: "t1", title: nil, panes: [P(id: "p1", kind: "remote", connId: "c1", hasTerm: false, status: "error")]),
        .init(id: "t2", title: nil, panes: [P(id: "p2", kind: "remote", connId: "c2", hasTerm: false, status: "connecting")]),
        .init(id: "t3", title: nil, panes: [P(id: "p3", kind: "remote", connId: "c3", hasTerm: false, status: "closed")]),
    ], ["c1": .init(state: "error", label: "a"), "c2": .init(state: "connecting", label: "b"), "c3": .init(state: "connected", label: "c")])
    #expect(QuitGuard.liveSessions(s).isEmpty)
}

@Test func quitForwardKeepsEndedShellLive() {
    let s = census([.init(id: "t1", title: nil, panes: [P(id: "p1", kind: "remote", connId: "c1", hasTerm: false, status: "closed")])],
                   ["c1": .init(state: "connected", type: "ssh", label: "db-jump")], forwards: ["c1": 1])
    #expect(QuitGuard.liveSessions(s) == [.init(kind: "ssh", name: "db-jump")])
}

@Test func quitFilesOnlyCounts() {
    let s = census([
        .init(id: "t1", title: nil, panes: [P(id: "p1", kind: "remote", connId: "c1", hasTerm: false, status: "connected", filesOnly: true)]),
        .init(id: "t2", title: nil, panes: [P(id: "p2", kind: "remote", connId: nil, hasTerm: false, status: "idle")]),
    ], ["c1": .init(state: "connected", type: "ssh", label: "files")])
    #expect(QuitGuard.liveSessions(s) == [.init(kind: "ssh", name: "files")])
}

@Test func quitTmuxTabCountedOnce() {
    let s = census([
        .init(id: "t1", title: "tmux: build", panes: [P(id: "p1", kind: "tmux", hasTerm: true, status: "connected"),
                                                       P(id: "p2", kind: "tmux", hasTerm: true, status: "connected")]),
        .init(id: "t2", title: "tmux: old", panes: [P(id: "p3", kind: "tmux", hasTerm: false, status: "closed")]),
    ])
    #expect(QuitGuard.liveSessions(s) == [.init(kind: "tmux", name: "tmux: build")])
}

@Test func quitConsolesAndScreensWhileConnected() {
    let s = census([
        .init(id: "t1", title: nil, panes: [P(id: "p1", kind: "device", hasTerm: true, status: "connected", title: "switch-1", deviceKind: "telnet")]),
        .init(id: "t2", title: nil, panes: [P(id: "p2", kind: "device", hasTerm: false, status: "closed", title: "usb0", deviceKind: "serial")]),
        .init(id: "t3", title: nil, panes: [P(id: "p3", kind: "vnc", hasTerm: false, status: "connected", title: "kvm:5900")]),
        .init(id: "t4", title: nil, panes: [P(id: "p4", kind: "vnc", hasTerm: false, status: "closed", title: "gone:5900")]),
    ])
    #expect(QuitGuard.liveSessions(s) == [.init(kind: "telnet", name: "switch-1"), .init(kind: "vnc", name: "kvm:5900")])
}

@Test func closingCountsLivePanesButNotTmuxOrLocal() {
    let s = census([
        .init(id: "t1", title: "web-1", panes: [P(id: "p1", kind: "remote", connId: "c1", hasTerm: true, status: "connected"),
                                                 P(id: "p2", kind: "local", hasTerm: true, status: "connected")]),
        .init(id: "t2", title: "tmux", panes: [P(id: "p3", kind: "tmux", hasTerm: true, status: "connected")]),
    ], ["c1": .init(state: "connected", type: "ssh", label: "web-1")])
    #expect(QuitGuard.liveSessionsIn(s, tabIds: ["t1"]).map(\.name) == ["web-1"])
    #expect(QuitGuard.liveSessionsIn(s, tabIds: ["t2"]).isEmpty)
    #expect(QuitGuard.liveSessionsIn(s, paneIds: ["p2"]).isEmpty)
    #expect(QuitGuard.liveSessionsIn(s, paneIds: ["p1"]).count == 1)
}
