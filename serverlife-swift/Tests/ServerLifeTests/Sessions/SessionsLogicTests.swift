import Testing
import Foundation
@testable import ServerLife

@Test func treeSplitSwapRemove() {
    var root: PaneNode? = .pane("a")
    root = PaneTree.splitting(root, at: "a", adding: "b", dir: .row)
    root = PaneTree.splitting(root, at: "b", adding: "c", dir: .col)
    #expect(root?.paneIds == ["a", "b", "c"])
    #expect(root?.firstPane == "a")
    #expect(PaneTree.neighbours(of: "b", in: root) == ["c"])
    root = PaneTree.swapping(root, "a", "c")
    #expect(root?.paneIds == ["c", "b", "a"])
    root = PaneTree.removing("b", from: root)
    #expect(root?.paneIds == ["c", "a"])
    root = PaneTree.removing("c", from: root)
    #expect(root == .pane("a"))
    #expect(PaneTree.removing("a", from: root) == nil)
}

@Test func treeMoveToEdge() {
    let root = PaneTree.splitting(.pane("a"), at: "a", adding: "b", dir: .row)
    let moved = PaneTree.movingToEdge(root, "b", "up")
    guard case .split(let s) = moved else { Issue.record("not a split"); return }
    #expect(s.dir == .col)
    #expect(moved?.paneIds == ["b", "a"])
    #expect(PaneTree.movingToEdge(.pane("a"), "a", "left") == .pane("a"))
}

@Test func treeWeightsResetWhenChildrenChange() {
    var root = PaneTree.splitting(.pane("a"), at: "a", adding: "b", dir: .row)
    root = PaneTree.splitting(root, at: "b", adding: "c", dir: .row)
    guard case .split(let outer) = root else { Issue.record("not a split"); return }
    root = PaneTree.settingWeights(root, splitId: outer.id, [0.3, 0.7])
    guard case .split(let w) = root else { return }
    #expect(w.weights == [0.3, 0.7])
    root = PaneTree.removing("a", from: root)
    #expect(root?.paneIds == ["b", "c"])
}

@Test @MainActor func shortCwdLikeTheOriginal() {
    let home = "/Users/steven"
    #expect(SessionsCore.shortCwd("/Users/steven", home: home) == "~")
    #expect(SessionsCore.shortCwd("/Users/steven/src", home: home) == "~/src")
    #expect(SessionsCore.shortCwd("/var/log", home: home) == "/var/log")
    #expect(SessionsCore.shortCwd("/Users/steven/src/serverlife/deep/inside", home: home) == "deep/inside")
    #expect(SessionsCore.shortCwd("/opt/very/long/path/to/somewhere", home: home) == "…/to/somewhere")
    #expect(SessionsCore.shortCwd(nil, home: home) == "")
}

@Test @MainActor func titleParts() {
    #expect(SessionsCore.remoteWho(login: "ubuntu", host: "tele1c", dupe: nil) == "ubuntu@tele1c")
    #expect(SessionsCore.remoteWho(login: nil, host: "web", dupe: "a1b2c3d4") == "web \u{00b7} a1b2c3d4")
    #expect(SessionsCore.stripBracket("web-1 (prod)") == "web-1")
    #expect(SessionsCore.bracketed("web-1 (prod)") == "prod")
}

@Test @MainActor func typedCdIsSpotted() {
    #expect(SessionsCore.changesDirectory("cd /tmp"))
    #expect(SessionsCore.changesDirectory("make && cd build"))
    #expect(SessionsCore.changesDirectory("popd"))
    #expect(!SessionsCore.changesDirectory("echo cdrom"))
    #expect(!SessionsCore.changesDirectory("abcd x"))
}

@Test @MainActor func utf8SplitKeepsCharactersWhole() {
    let d = Data("héllo €".utf8)
    let cut = d.prefix(d.count - 1)
    let (complete, rest) = SessionsCore.splitUTF8(Data(cut))
    #expect(String(decoding: complete, as: UTF8.self) == "héllo ")
    #expect(rest.count == 2)
    #expect(SessionsCore.splitUTF8(d).rest.isEmpty)
}

@Test @MainActor func stripAnsiForLogs() {
    #expect(SessionsCore.stripAnsi("\u{1b}[1;31merror\u{1b}[0m\rnext\r\n") == "error\nnext\r\n")
    #expect(SessionsCore.stripAnsi("\u{1b}]0;title\u{07}x") == "x")
}

@Test func highlightWrapsAndRestores() {
    let rules = [Highlight.Rule(id: "e", pattern: "error", color: "red", background: true)]
    let c = Highlight.compile(rules)
    var hs = Highlight.State()
    let out = Highlight.chunk("an error here", c, &hs)
    #expect(out == "an \u{1b}[1;97;41merror\u{1b}[0m here")
    // The program's own colour is put back after the highlight.
    var hs2 = Highlight.State()
    let red = Highlight.chunk("\u{1b}[31mbad error line", c, &hs2)
    #expect(red == "\u{1b}[31mbad \u{1b}[1;97;41merror\u{1b}[0m\u{1b}[31m line")
    // Stands aside on the alternate screen.
    var hs3 = Highlight.State()
    #expect(Highlight.chunk("\u{1b}[?1049herror", c, &hs3) == "\u{1b}[?1049herror")
    #expect(hs3.alt)
    #expect(Highlight.chunk("\u{1b}[?1049lerror", c, &hs3).contains("41merror"))
}

@Test func highlightBuiltinsAndOverlaps() {
    let c = Highlight.compile(Highlight.defaultRules)
    var hs = Highlight.State()
    let out = Highlight.chunk("connection refused; retrying", c, &hs)
    #expect(out.contains("\u{1b}[1;97;41mrefused"))
    #expect(out.contains("\u{1b}[1;30;43mretrying"))
    #expect(Highlight.compile([Highlight.Rule(id: "bad", pattern: "(", regex: true)]) == nil)
    // A literal rule is escaped.
    let lit = Highlight.compile([Highlight.Rule(id: "l", pattern: "a.b", color: "green", background: false)])
    var hs4 = Highlight.State()
    #expect(Highlight.chunk("axb a.b", lit, &hs4) == "axb \u{1b}[1;32ma.b\u{1b}[0m")
}

@Test @MainActor func describeSavedTabs() {
    let tab: JSON = ["title": "web", "root": ["type": "split", "dir": "row", "children": [
        ["type": "pane", "pane": ["kind": "remote", "target": "ubuntu@web-1", "login": "ubuntu", "cwd": "/srv/app"]],
        ["type": "pane", "pane": ["kind": "local", "cwd": .string(NSHomeDirectory())]],
        ["type": "pane", "pane": ["kind": "remote", "target": "ubuntu@web-1", "login": "ubuntu", "cwd": "/srv/app"]],
    ]]]
    #expect(SessionsWindow.describeTabTargets(tab) == ["ubuntu@web-1: /srv/app", "local shell: ~"])
    #expect(WorkspaceStore.countPanes(tab["root"]) == 3)
}

@Test @MainActor func connectAnimMotionStaysOnTrack() {
    for a in ConnectAnim.all {
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let f = a.frame(t)
            #expect(f.x >= -0.11 && f.x <= 1.1, "\(a.id) at \(t)")
            #expect(f.opacity >= -0.01 && f.opacity <= 1.01)
        }
    }
    #expect(ConnectAnim.all.count == 30)
}
