import Testing
import Foundation
@testable import ServerLife

// The pure parts of tmux.js / vnc.js and the console openers (ConsolesText).
// The original had no renderer tests for these files; tmuxctl/devices tests
// are ported under Devices/.

private func layout(_ s: String) -> TmuxLayout { try! TmuxLayout.parse(s) }

@Suite struct TmuxWindowShapeTests {
    @Test func aSinglePaneIsAPane() {
        let n = ConsolesText.node(layout("b25d,80x24,0,0,1"))
        guard case .pane(let p) = n else { Issue.record("not a pane"); return }
        #expect(p == "%1")
    }

    @Test func bracketsAreAColumnAndBracesARow() {
        // [ … ] stacks panes (col); { … } puts them side by side (row).
        let col = ConsolesText.node(layout("abcd,80x24,0,0[80x12,0,0,1,80x11,0,13,2]"))
        guard case .split(let d1, let k1) = col else { Issue.record("not a split"); return }
        #expect(d1 == .col)
        #expect(k1.count == 2)
        let row = ConsolesText.node(layout("abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"))
        guard case .split(let d2, _) = row else { Issue.record("not a split"); return }
        #expect(d2 == .row)
    }

    @Test func panesAreCountedThroughNestedSplits() {
        let t = layout("abcd,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}")
        #expect(ConsolesText.paneCount(t) == 3)
        #expect(ConsolesText.paneCount(nil) == 0)
    }
}

@Suite struct TmuxClientSizeTests {
    @Test func sideBySideAddsWidthsAndADividerColumn() {
        let t = layout("abcd,81x24,0,0{40x24,0,0,1,40x24,41,0,2}")
        let size = ConsolesText.clientSize(t) { p in p == "%1" ? (40, 24) : (40, 20) }
        #expect(size?.cols == 81)
        #expect(size?.rows == 24)
    }

    @Test func stackedAddsHeightsAndADividerRow() {
        let t = layout("abcd,80x25,0,0[80x12,0,0,1,80x12,0,13,2]")
        let size = ConsolesText.clientSize(t) { _ in (80, 12) }
        #expect(size?.cols == 80)
        #expect(size?.rows == 25)
    }

    @Test func panesWithoutASizeYetAreLeftOut() {
        let t = layout("abcd,81x24,0,0{40x24,0,0,1,40x24,41,0,2}")
        let size = ConsolesText.clientSize(t) { p in p == "%1" ? (40, 24) : (0, 0) }
        #expect(size?.cols == 40)
        #expect(ConsolesText.clientSize(t) { _ in (0, 0) } == nil)
    }
}

@Suite struct TmuxWordingTests {
    @Test func theThreeWaysASessionStopsBeingShown() {
        let gone = ConsolesText.ended(name: "work", host: "web-1", reason: nil, alive: false)
        #expect(gone.word == "ended")
        #expect(gone.title == "tmux session “work” has ended")
        #expect(gone.sub == "Nothing is running in it any more on web-1.")
        let left = ConsolesText.ended(name: "work", host: "web-1", reason: "detached", alive: true)
        #expect(left.word == "detached")
        #expect(left.title == "Detached from “work”")
        #expect(left.sub == "It is still running on web-1, with everything in it.")
        let lost = ConsolesText.ended(name: "work", host: "web-1", reason: "the connection closed", alive: nil)
        #expect(lost.word == "disconnected")
        #expect(lost.title == "Lost the connection to “work”")
        #expect(lost.sub == "It may still be running on web-1 (the connection closed).")
        #expect(ConsolesText.ended(name: "w", host: "h", reason: nil, alive: nil).sub == "It may still be running on h.")
    }

    @Test func theEndedLineUsesPlainQuotes() {
        let line = ConsolesText.endedLine(title: "Detached from “work”", sub: "It is still running on h, with everything in it.")
        #expect(line == "\r\n\u{1b}[90m[Detached from \"work\" — It is still running on h, with everything in it.]\u{1b}[0m")
    }

    @Test func aSessionNameCannotHoldAColonOrAFullStop() {
        #expect(ConsolesText.validateSessionName("  ") == "Give it a name")
        #expect(ConsolesText.validateSessionName("db:1") == "A tmux session name cannot contain : or .")
        #expect(ConsolesText.validateSessionName("v1.2") == "A tmux session name cannot contain : or .")
        #expect(ConsolesText.validateSessionName("db-migration") == nil)
    }

    @Test func theSessionPickerSaysWhatIsThere() {
        let one = TmuxSessionInfo(name: "work", id: "$1", windows: 1, attached: false, created: nil)
        let many = TmuxSessionInfo(name: "ops", id: "$2", windows: 3, attached: true, created: nil)
        #expect(ConsolesText.sessionOption(one) == "work — 1 window")
        #expect(ConsolesText.sessionOption(many) == "ops — 3 windows, attached elsewhere")
        #expect(ConsolesText.attachedNote(windows: 1, panes: 2)
                == "Attached — 1 window, 2 panes. Reading back what is on them…")
    }

    @Test func aPaneIsNamedByItsWindowNotItsId() {
        #expect(ConsolesText.tmuxPaneTitle(window: "vim", host: "web-1", pane: "%7", long: false) == "vim · web-1")
        #expect(ConsolesText.tmuxPaneTitle(window: "vim", host: "web-1", pane: "%7", long: true) == "vim · web-1 · tmux %7")
        #expect(ConsolesText.tmuxPaneTitle(window: nil, host: "", pane: nil, long: false) == "tmux")
    }

    @Test func aCapturedScreenLosesItsEmptyRows() {
        #expect(ConsolesText.primeText("$ ls\nfile\n\n\n   \n") == "$ ls\r\nfile\r\n")
        #expect(ConsolesText.primeText("\n\n  \n") == nil)
    }

    @Test func theFiveLayoutsKeepTheirTmuxNames() {
        #expect(ConsolesText.layouts.map(\.name) == ["even-horizontal", "even-vertical", "main-horizontal", "main-vertical", "tiled"])
    }
}

@Suite struct ConsoleOpeningTests {
    @Test func aConsoleIsCalledByItsNameElseItsAddress() {
        #expect(ConsolesText.deviceTitle(["kind": "telnet", "host": "switch-1", "port": 2001]) == "switch-1:2001")
        #expect(ConsolesText.deviceTitle(["kind": "telnet", "host": "switch-1"]) == "switch-1:23")
        #expect(ConsolesText.deviceTitle(["kind": "serial", "path": "/dev/cu.usbserial-1410"]) == "/dev/cu.usbserial-1410")
        #expect(ConsolesText.deviceTitle(["kind": "serial"]) == "serial")
        #expect(ConsolesText.deviceTitle(["kind": "serial", "name": "core-sw console", "path": "/dev/x"]) == "core-sw console")
    }

    @Test func aSerialConsoleSaysWhatItOpened() {
        #expect(ConsolesText.deviceGreeting(kind: "serial", label: "/dev/cu.x · 115200 8N1") == "[serial — /dev/cu.x · 115200 8N1]")
    }

    @Test func portsInThePickerOpenAt115200() {
        var p = SerialPortInfo(path: "/dev/cu.usbserial-1410")
        #expect(ConsolesText.serialPortMeta(p) == "115200 8N1")
        p.label = "FTDI · USB Serial"
        #expect(ConsolesText.serialPortMeta(p) == "FTDI · USB Serial · 115200 8N1")
    }

    @Test func rdpSaysWhereItOpened() {
        #expect(ConsolesText.rdpOpened("win-1", client: "system") == "win-1 opened in your Remote Desktop client")
        #expect(ConsolesText.rdpOpened("win-1", client: "mstsc") == "win-1 opened in Remote Desktop Connection")
    }

    @Test func aScreenDefaultsToDisplayZero() {
        #expect(ConsolesText.vncTarget(host: "10.0.0.5", port: nil) == "10.0.0.5:5900")
        #expect(ConsolesText.vncTarget(host: "10.0.0.5", port: 5901) == "10.0.0.5:5901")
    }

    @MainActor @Test func aDeviceSpecIsTheOriginalShapeFromAHost() {
        var h = Host(json: ["type": "telnet", "hostname": "switch-1", "port": 2001])
        var j = ConsolesDevices.spec(h, kind: "telnet")
        #expect(j["kind"].string == "telnet")
        #expect(j["host"].string == "switch-1")
        #expect(j["port"].int == 2001)
        #expect(j["name"].isNull)       // so the tab reads host:port
        #expect(ConsolesText.deviceTitle(j) == "switch-1:2001")
        h = Host(json: ["type": "serial", "name": "Lab", "path": "/dev/cu.x", "baudRate": 9600])
        j = ConsolesDevices.spec(h, kind: "serial")
        #expect(SerialOptions(json: j).baudRate == 9600)
        #expect(SerialOptions(json: j).path == "/dev/cu.x")
        #expect(ConsolesText.deviceTitle(j) == "Lab")
        // A saved profile's names for the address.
        h = Host(json: ["type": "vnc", "name": "Kiosk", "host": "10.0.0.5", "devicePort": 5901, "viewOnly": true])
        j = ConsolesVNC.spec(h)
        #expect(j["host"].string == "10.0.0.5")
        #expect(j["port"].int == 5901)
        #expect(VNCSession.Options(json: j).viewOnly)
    }
}

@Suite struct DeviceOptionsFromExtraTests {
    @MainActor @Test func aSavedSerialProfileKeepsEveryOption() {
        let h = HostsOpen.deviceHost(Host.serial, [
            "name": "Lab switch", "path": "/dev/cu.usbserial-1410", "baudRate": 9600, "dataBits": 7,
            "parity": "even", "stopBits": 2, "rtscts": true, "newline": "crlf", "localEcho": "true",
            "startupCommand": "show version",
        ])
        let j = ConsolesDevices.spec(h, kind: Host.serial)
        let o = SerialOptions(json: j)
        #expect(o.path == "/dev/cu.usbserial-1410")
        #expect(o.baudRate == 9600 && o.dataBits == 7 && o.stopBits == 2 && o.parity == "even")
        #expect(o.rtscts && o.newline == "crlf" && o.localEcho)
        #expect(j["startupCommand"].string == "show version")
        #expect(ConsolesText.deviceTitle(j) == "Lab switch")
    }

    @MainActor @Test func aTelnetProfileReadsItsDevicePort() {
        var h = Host(type: Host.telnet, id: "p_1", name: "core-1")
        h.extra = ["host": "10.0.0.9", "devicePort": 2001, "newline": "cr", "localEcho": true]
        let t = TelnetOptions(json: ConsolesDevices.spec(h, kind: Host.telnet))
        #expect(t.host == "10.0.0.9" && t.port == 2001 && t.newline == "cr" && t.localEcho)
        // Quick connect: no name of its own, so the tab says host:port.
        let q = HostsOpen.deviceHost(Host.telnet, ["host": "switch-1", "port": 23, "newline": "crlf"])
        #expect(ConsolesText.deviceTitle(ConsolesDevices.spec(q, kind: Host.telnet)) == "switch-1:23")
    }

    @MainActor @Test func vncAndRdpOptionsComeFromExtraToo() {
        var v = Host(type: Host.vnc, id: "p_2", name: "Kiosk")
        v.extra = ["host": "10.0.0.5", "devicePort": 5901, "viewOnly": true, "scaling": "none", "quality": 2]
        let vj = ConsolesVNC.spec(v)
        let vo = VNCSession.Options(json: vj)
        #expect(vj["host"].string == "10.0.0.5" && vj["port"].int == 5901)
        #expect(vo.viewOnly && vo.scaling == .none && vo.quality == 2)
        var r = Host(type: Host.rdp, id: "p_3", name: "Win")
        r.extra = ["host": "win-1", "devicePort": 3390, "username": "admin", "domain": "CORP", "fullscreen": true,
                   "drives": true, "gateway": "gw.example"]
        let c = RDPConnection(json: ConsolesDevices.options(r))
        #expect(c.hostname == "win-1" && c.port == 3390 && c.username == "admin" && c.domain == "CORP")
        #expect(c.fullscreen && c.drives && c.gateway == "gw.example")
    }
}

@Suite struct TmuxCheckTimeoutTests {
    @Test func checksGiveUpWhenTheOriginalDid() {
        #expect(TimedTmuxHost.timeout(for: "tmux -V 2>/dev/null || command -v tmux || true") == 15)
        #expect(TimedTmuxHost.timeout(for: "tmux list-sessions -F '…' 2>/dev/null || true") == 15)
        #expect(TimedTmuxHost.timeout(for: "tmux has-session -t '=work' 2>/dev/null && echo yes || echo no") == 10)
    }
}
