import Testing
import Foundation
@testable import ServerLife

// Port of tests/tmux.test.mjs, plus the probe and session-list parsing and a
// live session against this machine's tmux (on a private socket) when there is one.

private func feed(_ p: TmuxParser, _ chunks: String...) -> [TmuxEvent] { chunks.flatMap { p.feed($0) } }

private func outputs(_ evs: [TmuxEvent]) -> [(String, String, Int?)] {
    evs.compactMap { if case .output(let p, let d, let a) = $0 { return (p, String(decoding: d, as: UTF8.self), a) }; return nil }
}

private func isReady(_ e: TmuxEvent) -> Bool { if case .ready = e { return true }; return false }
private func isResult(_ e: TmuxEvent) -> Bool { if case .result = e { return true }; return false }
private func isProbe(_ e: TmuxEvent) -> Bool { if case .probe = e { return true }; return false }

@Suite struct TmuxProtocolTests {
    // output escaping

    @Test func escapeSequencesSurvive() {
        #expect(Tmux.unescapeOutput("\\033[1m\\033[7m%\\033[27m\\033[1m\\033[0m")
            == "\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m")
        #expect(Tmux.unescapeOutput("hello\\015\\012") == "hello\r\n")
    }

    @Test func literalBackslashIsNotAnEscape() {
        #expect(Tmux.unescapeOutput("\\134033") == "\\033")
        #expect(Tmux.unescapeOutput("C:\\134Users") == "C:\\Users")
        #expect(Tmux.unescapeOutput("\\033\\134") == "\u{1b}\\")
    }

    @Test func lookalikesAreLeftAlone() {
        #expect(Tmux.unescapeOutput("\\12") == "\\12")
        #expect(Tmux.unescapeOutput("\\899") == "\\899")
        #expect(Tmux.unescapeOutput("plain text") == "plain text")
        #expect(Tmux.unescapeOutput("") == "")
    }

    @Test func keystrokesGoOutAsHex() {
        #expect(Tmux.hexKeys("ls") == "0x6c 0x73")
        #expect(Tmux.hexKeys("\r") == "0x0d")
        #expect(Tmux.hexKeys("\u{03}") == "0x03")
        #expect(Tmux.hexKeys("é") == "0xc3 0xa9")
    }

    // layouts

    @Test func singlePane() throws {
        let t = try TmuxLayout.parse("aafd,120x40,0,0,0")
        #expect(t == .pane(w: 120, h: 40, x: 0, y: 0, pane: "%0"))
    }

    @Test func horizontalSplitIsAColumn() throws {
        let t = try TmuxLayout.parse("3aab,120x40,0,0[120x20,0,0,0,120x19,0,21,2]")
        #expect(t.dir == "col")
        #expect(t.children.count == 2)
        #expect(t.panes == ["%0", "%2"])
        #expect(t.children[1].y == 21)
    }

    @Test func nestedSplits() throws {
        let t = try TmuxLayout.parse("bb62,279x82,0,0[279x41,0,0,1,279x40,0,42{139x40,0,42,2,139x40,140,42,3}]")
        #expect(t.dir == "col")
        #expect(t.children[1].dir == "row")
        #expect(t.panes == ["%1", "%2", "%3"])
        #expect(t.json["children"][1]["dir"].string == "row")
    }

    @Test func nonsenseIsRefused() {
        #expect(throws: TmuxLayout.ParseError.self) { try TmuxLayout.parse("abcd,120x40,0,0[") }
        #expect(throws: TmuxLayout.ParseError.self) { try TmuxLayout.parse("abcd,notanumber") }
        do { _ = try TmuxLayout.parse("abcd,120x40,0,0[") } catch { #expect("\(error)".hasPrefix("bad layout at")) }
    }

    // protocol

    @Test func nothingIsProtocolBeforeDCS() {
        let p = TmuxParser()
        let evs = feed(p, "Welcome to Ubuntu 24.04\r\n12 updates can be applied\r\n")
        #expect(evs.filter { if case .preamble = $0 { return true }; return false }.count == 1)
        #expect(!evs.contains(where: isReady))
        #expect(outputs(evs).isEmpty)
    }

    @Test func probesAnsweredOnlyBeforeControlMode() {
        let p = TmuxParser()
        let before = feed(p, "\u{1b}]11;?\u{1b}\\\u{1b}[6n")
        let answers = before.compactMap { if case .probe(let a) = $0 { return a }; return nil }
        #expect(answers == ["\u{1b}[1;1R", "\u{1b}]11;rgb:1212/1414/1a1a\u{1b}\\"])
        _ = feed(p, Tmux.DCS)
        let after = feed(p, "%output %0 \\033]11;?\\033\\134\n")
        #expect(!after.contains(where: isProbe))
    }

    @Test func dcsInSameReadAsBanner() {
        let p = TmuxParser()
        let evs = feed(p, "motd here\r\n\(Tmux.DCS)%begin 1 2 0\r\n%end 1 2 0\r\n%window-add @0\r\n")
        #expect(evs.contains(where: isReady))
        #expect(evs.contains(where: isResult))
        #expect(evs.contains(.windowAdd("@0")))
    }

    @Test func dcsSplitAcrossReads() {
        let p = TmuxParser()
        let dcs = Tmux.DCS
        let cut = dcs.index(dcs.startIndex, offsetBy: 3)
        var evs = feed(p, "banner\r\n" + String(dcs[..<cut]))
        #expect(!evs.contains(where: isReady))
        evs = feed(p, String(dcs[cut...]) + "%window-add @3\n")
        #expect(evs.contains(where: isReady))
        #expect(evs.contains(.windowAdd("@3")))
    }

    static let beamOpening = "%begin 1791124214 267 0\n%end 1791124214 267 0\n%window-add @0\n%sessions-changed\n%session-changed $0 slprobe\n"

    @Test func beamStartsWithFirstLine() {
        let p = TmuxParser(plain: true)
        let evs = feed(p, Self.beamOpening)
        #expect(evs.first == .ready)
        #expect(evs.contains { if case .result(_, "0", _, _) = $0 { return true }; return false })
        #expect(evs.contains(.windowAdd("@0")))
        #expect(evs.filter(isReady).count == 1)
    }

    @Test func beamNeverAnswersProbes() {
        let p = TmuxParser(plain: true)
        let evs = feed(p, Self.beamOpening, "%output %0 \\033]11;?\\033\\134\\033[6n\n")
        #expect(!evs.contains(where: isProbe))
        #expect(outputs(evs).contains { $0.0 == "%0" })
    }

    @Test func beamWarningBeforeTmuxIsNoise() {
        let p = TmuxParser(plain: true)
        let before = feed(p, "WARNING: your credentials expire in 5 minutes\n")
        #expect(!before.contains(where: isReady))
        #expect(before.contains { if case .noise = $0 { return true }; return false })
        let after = feed(p, Self.beamOpening)
        #expect(after.first == .ready)
    }

    @Test func plainLinesBeforeDCSAreBanner() {
        let p = TmuxParser()
        let evs = feed(p, "%begin 1 2 0\n")
        #expect(!evs.contains(where: isReady) && !evs.contains(where: isResult))
    }

    @Test func outputIsTaggedWithPane() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, "%output %2 hello\\015\\012\n")
        #expect(evs == [.output(pane: "%2", data: Array("hello\r\n".utf8), age: nil)])
    }

    @Test func halfLineIsNotInterpreted() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        #expect(feed(p, "%output %0 \\03").isEmpty)
        #expect(feed(p, "3[1mbold\n") == [.output(pane: "%0", data: Array("\u{1b}[1mbold".utf8), age: nil)])
    }

    @Test func commandBlockIsOneResult() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, "%begin 1790971668 285 1\n@0 zsh aafd,120x40,0,0,0\n%end 1790971668 285 1\n")
        #expect(evs == [.result(num: "285", flags: "1", error: false, lines: ["@0 zsh aafd,120x40,0,0,0"])])
    }

    @Test func openingBlockIsMarkedNotAReply() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let open = feed(p, "%begin 1790971667 279 0\n%end 1790971667 279 0\n")
        #expect(open == [.result(num: "279", flags: "0", error: false, lines: [])])
        let mine = feed(p, "%begin 1790971668 285 1\n@0 zsh\n%end 1790971668 285 1\n")
        #expect(mine == [.result(num: "285", flags: "1", error: false, lines: ["@0 zsh"])])
    }

    @Test func failedCommandIsAResult() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, "%begin 1 2 1\nparse error: unknown command\n%error 1 2 1\n")
        #expect(evs == [.result(num: "2", flags: "1", error: true, lines: ["parse error: unknown command"])])
    }

    @Test func linesInsideBlockAreNotNotifications() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, "%begin 1 2 1\n%output %0 this is captured text\n%end 1 2 1\n")
        #expect(evs == [.result(num: "2", flags: "1", error: false, lines: ["%output %0 this is captured text"])])
    }

    @Test func layoutChangeCarriesTree() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, "%layout-change @0 3aab,120x40,0,0[120x20,0,0,0,120x19,0,21,2] 3aab,120x40,0,0[120x20,0,0,0,120x19,0,21,2] -\n")
        guard case .layout(let win, let layout, let tree) = evs.first else { Issue.record("no layout"); return }
        #expect(win == "@0")
        #expect(layout.hasPrefix("3aab,"))
        #expect(tree?.panes == ["%0", "%2"])
    }

    @Test func windowAndSessionNotifications() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, ["%window-add @1", "%window-renamed @1 vim", "%window-pane-changed @0 %2",
                           "%session-window-changed $0 @1", "%session-changed $0 serverlife", "%window-close @1",
                           "%exit"].joined(separator: "\n") + "\n")
        #expect(evs == [.windowAdd("@1"), .windowRenamed(window: "@1", name: "vim"), .activePane(window: "@0", pane: "%2"),
                        .activeWindow(session: "$0", window: "@1"), .session(id: "$0", name: "serverlife"),
                        .windowClose("@1"), .exit(nil)])
        #expect(feed(p, "%exit detached\n") == [.exit("detached")])
        #expect(feed(p, "%unlinked-window-add @7\n%sessions-changed\n")
            == [.windowAdd("@7"), .sessionsChanged])
    }

    /// `%session-renamed $0 newname` (checked against tmux 3.7c): the id is
    /// not part of the name. Older tmux sent the name alone.
    @Test func sessionRenamedCarriesOnlyTheName() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        #expect(feed(p, "%session-renamed $0 newname\n") == [.sessionRenamed("newname")])
        #expect(feed(p, "%session-renamed $12 two words\n") == [.sessionRenamed("two words")])
        #expect(feed(p, "%session-renamed work\n") == [.sessionRenamed("work")])
    }

    @Test func flowControlOutputCarriesAge() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, "%extended-output %0 1200 : still\\040going\n")
        #expect(evs == [.output(pane: "%0", data: Array("still going".utf8), age: 1200)])
        #expect(feed(p, "%pause %0\n%continue %0\n") == [.pause("%0"), .continue("%0")])
    }

    @Test func outputKeepsRawUTF8() {
        let p = TmuxParser()
        _ = feed(p, Tmux.DCS)
        let evs = feed(p, "%output %1 ─é\n")
        #expect(outputs(evs).first?.1 == "─é")
    }

    @Test func quoting() {
        #expect(shellQuote("serverlife") == "'serverlife'")
        #expect(shellQuote("it's") == "'it'\\''s'")
        #expect(shellQuote("; rm -rf /") == "'; rm -rf /'")
    }

    // probe and sessions

    @Test func probeParsing() {
        let ok = TmuxControl.parseProbe("tmux 3.4", local: false)
        #expect(ok.ok && ok.version == "3.4" && ok.flowControl && !ok.clientNeeded && ok.reason == nil)
        let next = TmuxControl.parseProbe("tmux next-3.6", local: false)
        #expect(next.ok && next.version == "3.6")
        let letter = TmuxControl.parseProbe("tmux 3.3a", local: true)
        #expect(letter.version == "3.3a" && letter.flowControl)
        let old = TmuxControl.parseProbe("tmux 3.1c", local: false)
        #expect(old.ok && !old.flowControl)
        let ancient = TmuxControl.parseProbe("tmux 1.8", local: false)
        #expect(!ancient.ok && ancient.reason == "tmux 1.8 is too old for control mode (2.1 or newer)")
        let missing = TmuxControl.parseProbe("", local: false)
        #expect(!missing.ok && missing.reason == "tmux is not installed on this host")
        #expect(missing.install == "apt install tmux · dnf install tmux · apk add tmux")
        let missingHere = TmuxControl.parseProbe("", local: true)
        #expect(missingHere.reason == "tmux is not installed on this machine" && missingHere.install == "brew install tmux")
        let odd = TmuxControl.parseProbe("/usr/bin/tmux", local: false)
        #expect(odd.reason == "tmux is installed but did not report a version")
    }

    @MainActor @Test func localTmuxGetsAUTF8Locale() {
        let pe = ProcessInfo.processInfo.environment
        let env = TmuxLocalHost.env()
        if (pe["LANG"] ?? "").isEmpty && (pe["LC_ALL"] ?? "").isEmpty && (pe["LC_CTYPE"] ?? "").isEmpty {
            #expect(env["LANG"] == .some("en_US.UTF-8"))
        } else {
            #expect(env["LANG"] == nil, "a locale the user set is left alone")
        }
        #expect(env.keys.contains("TMUX") && env["TMUX"]! == nil)
    }

    @Test func sessionListParsing() {
        let out = "work\t$0\t3\t1\t1790000000\nscratch\t$1\t1\t0\t0\nbroken line\n"
        let s = TmuxControl.parseSessions(out)
        #expect(s.count == 2)
        #expect(s[0] == TmuxSessionInfo(name: "work", id: "$0", windows: 3, attached: true, created: 1_790_000_000_000))
        #expect(s[1].created == nil && !s[1].attached)
        // tmux 3.6+ prints the tabs as "_": names with underscores still parse.
        let sanitised = TmuxControl.parseSessions("my_work_1_$3_2_0_1791406165\nx_$0_1_1_1791406165\n")
        #expect(sanitised.map(\.name) == ["my_work_1", "x"])
        #expect(sanitised[0].id == "$3" && sanitised[0].windows == 2 && !sanitised[0].attached)
        #expect(sanitised[1].attached)
        let w = TmuxControl.fields("@4_vim_my_file_1_bb62,279x82,0,0[279x41,0,0,1,279x40,0,42,2]_0", TmuxControl.windowLine, count: 4)
        #expect(w == ["@4", "vim_my_file", "1", "bb62,279x82,0,0[279x41,0,0,1,279x40,0,42,2]", "0"])
        let tabbed = TmuxControl.fields("@0\tzsh\t1\taafd,120x40,0,0,0\t1", TmuxControl.windowLine, count: 4)
        #expect(tabbed == ["@0", "zsh", "1", "aafd,120x40,0,0,0", "1"])
    }

    @MainActor @Test func startCommand() {
        let s = TmuxSession(host: TmuxLocalHost.shared, sessionName: "it's", cols: 120, rows: 34)
        #expect(s.startCommand() == "tmux -CC new-session -A -s 'it'\\''s' -x 120 -y 34")
        #expect(s.startCommand(attach: false) == "tmux -CC new-session -s 'it'\\''s' -x 120 -y 34")
        #expect(TmuxSession(host: TmuxLocalHost.shared).sessionName == "serverlife")
    }
}

/// This machine's tmux on a private server socket, so nothing the user runs
/// is touched.
@MainActor
private final class PrivateTmuxHost: TmuxHost {
    let socketName = "sltest-\(UUID().uuidString.prefix(8))"
    let transportKind = "local"
    private func rewrite(_ cmd: String) -> String {
        cmd.replacingOccurrences(of: "tmux ", with: "tmux -L \(socketName) -f /dev/null ")
    }
    func execResult(_ cmd: String) async -> ProcResult { await TmuxLocalHost.shared.execResult(rewrite(cmd)) }
    func spawnCommandPTY(_ cmd: String, cols: Int, rows: Int) throws -> PTYProcess {
        try TmuxLocalHost.shared.spawnCommandPTY(rewrite(cmd), cols: cols, rows: rows)
    }
    func killServer() async { _ = await TmuxLocalHost.shared.execResult("tmux -L \(socketName) kill-server") }
}

@Suite(.serialized) struct TmuxLiveTests {
    static var hasTmux: Bool { Proc.which("tmux") != nil }

    @MainActor @Test(.enabled(if: TmuxLiveTests.hasTmux)) func attachTypeCaptureKill() async throws {
        let host = PrivateTmuxHost()
        defer { Task { await host.killServer() } }
        let probe = await TmuxService.shared.probe(host)
        #expect(probe.ok)
        var windowsSeen: [[TmuxWindow]] = []
        let s = try await TmuxService.shared.attach(host, session: "sl-test", cols: 90, rows: 25) { s in
            s.onWindows = { windowsSeen.append($0) }
        }
        #expect(TmuxService.shared.sessions[s.id] != nil)
        let wins = s.windowList()
        #expect(wins.count == 1)
        #expect(wins.first?.active == true && wins.first?.name.isEmpty == false, "list-windows was understood")
        let pane = try #require(wins.first?.panes.first)
        #expect(!windowsSeen.isEmpty)

        let backend = s.backend(for: pane)
        #expect(backend.kind == "tmux")
        var out = Data()
        backend.onData = { out.append($0) }
        backend.write(Data("echo sl-marker-$((6*7))\r".utf8))
        for _ in 0..<100 where !String(decoding: out, as: UTF8.self).contains("sl-marker-42") {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        #expect(String(decoding: out, as: UTF8.self).contains("sl-marker-42"))
        let screen = try await s.capture(pane, lines: 50)
        #expect(screen.contains("sl-marker-42"))

        // A command that fails throws tmux's own words.
        await #expect(throws: AppError.self) { try await s.command("no-such-command") }
        // Commands after a failure still line up with their answers.
        let name = try await s.command("display-message -p '#{session_name}'")
        #expect(name == ["sl-test"])

        let list = await TmuxService.shared.listSessions(host)
        #expect(list.contains { $0.name == "sl-test" && $0.attached })

        _ = try await s.command("split-window -h")
        for _ in 0..<50 where (s.windowList().first?.panes.count ?? 0) < 2 { try await Task.sleep(nanoseconds: 30_000_000) }
        #expect(s.windowList().first?.panes.count == 2)

        // Renamed from elsewhere: the session keeps its real name, so End
        // still finds it and "still there?" still asks about the right one.
        _ = try await s.command("rename-session -t sl-test sl-renamed")
        for _ in 0..<100 where s.sessionName != "sl-renamed" { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(s.sessionName == "sl-renamed")
        #expect(await TmuxService.shared.stillThere(s) == true)

        var ended: (String?, Bool?)?
        s.onEnded = { ended = ($0, $1) }
        await TmuxService.shared.kill(s.id)
        #expect(await TmuxService.shared.stillThere(s) == false, "kill-session found it by its new name")
        #expect(ended?.0 == "ended" && ended?.1 == false)
        #expect(TmuxService.shared.sessions[s.id] == nil)
        await host.killServer()
    }

    @MainActor @Test(.enabled(if: TmuxLiveTests.hasTmux)) func detachLeavesItRunning() async throws {
        let host = PrivateTmuxHost()
        let s = try await TmuxService.shared.attach(host, session: "sl-detach")
        var ended: (String?, Bool?)?
        s.onEnded = { ended = ($0, $1) }
        await TmuxService.shared.detach(s.id)
        #expect(ended?.0 == "detached" && ended?.1 == true)
        let alive = await TmuxService.shared.stillThere(s)
        #expect(alive == true)
        await host.killServer()
        #expect(await TmuxService.shared.stillThere(s) == false)
    }
}
