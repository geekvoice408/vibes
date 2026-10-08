import Testing
import Foundation
@testable import ServerLife

/// tests/quickconnect.test.mjs: what someone typed, turned into a connection.
@Suite struct HostsQuickConnectTests {
    func p(_ s: String) -> QuickTarget? { QuickConnect.parseTarget(s) }

    @Test func theSshShapesStillParseAsTheyDid() {
        #expect(p("ubuntu@10.0.0.5") == QuickTarget(kind: "ssh", user: "ubuntu", hostname: "10.0.0.5", port: 22))
        #expect(p("web-1.example.com:2222")?.port == 2222)
        #expect(p("ssh -p 2222 -i ~/.ssh/id_ed25519 ops@box")?.user == "ops")
        #expect(p("ssh -p 2222 -i ~/.ssh/id_ed25519 ops@box")?.identityFile == "~/.ssh/id_ed25519")
        #expect(p("ssh -p 2222 ops@box")?.port == 2222)
        #expect(p("nonsense with spaces") == nil)
    }

    @Test func aPastedCommandLineKeepsItsRemoteCommandVerbatim() {
        let t = p("ssh -J bastion -o StrictHostKeyChecking=no box uptime -p")
        #expect(t?.hostname == "box")
        #expect(t?.proxyJump == "bastion")
        #expect(t?.command == "uptime -p")
        #expect(t?.port == 22)
    }

    @Test func urlsBracketsAndScpPathsReadAsAddresses() {
        #expect(p("ssh://admin@10.1.1.1:2200")?.port == 2200)
        #expect(p("ssh://admin@10.1.1.1:2200")?.user == "admin")
        #expect(p("[fe80::1]:2222")?.hostname == "fe80::1")
        #expect(p("[fe80::1]:2222")?.port == 2222)
        #expect(p("fe80::1")?.hostname == "fe80::1")
        #expect(p("host:/var/log")?.hostname == "host")
        #expect(p("user:secret@host")?.user == "user")
    }

    @Test func aProtocolCanBeASchemeOrAFirstWord() {
        for s in ["telnet://switch-1", "telnet switch-1", "TELNET://switch-1"] {
            #expect(p(s)?.kind == "telnet", "\(s)")
            #expect(p(s)?.hostname == "switch-1", "\(s)")
        }
    }

    @Test func eachProtocolBringsItsOwnDefaultPort() {
        #expect(p("telnet://switch-1")?.port == 23)
        #expect(p("vnc://10.0.0.5")?.port == 5900)
        #expect(p("rdp://win-1")?.port == 3389)
        #expect(p("box")?.port == 22)
    }

    @Test func aPortGivenExplicitlyWinsOverTheProtocolDefault() {
        #expect(p("vnc://10.0.0.5:5901")?.port == 5901)
        #expect(p("telnet://10.0.0.9:2323")?.port == 2323)
    }

    @Test func aUserSurvivesInFrontOfAProtocolAddress() {
        let t = p("rdp administrator@win-1")
        #expect(t?.kind == "rdp")
        #expect(t?.user == "administrator")
        #expect(t?.hostname == "win-1")
    }

    @Test func aDevicePathIsASerialConsole() {
        for s in ["/dev/tty.usbserial-1410", "/dev/ttyUSB0", "/dev/cu.usbmodem1", "COM3", "serial:/dev/ttyS0"] {
            let t = p(s)
            #expect(t?.kind == "serial", "\(s)")
            #expect(t?.path == s.replacingOccurrences(of: "serial:", with: ""), "\(s)")
            #expect(t?.baudRate == 115200)
        }
    }

    @Test func aSpeedAfterThePathIsTakenAsTheSpeed() {
        #expect(p("/dev/ttyUSB0@9600")?.baudRate == 9600)
        #expect(p("/dev/ttyUSB0@9600")?.path == "/dev/ttyUSB0")
        #expect(p("/dev/ttyUSB0,57600")?.baudRate == 57600)
    }

    @Test func aPathThatIsNotADeviceIsNotAConsole() {
        #expect(p("/etc/hosts") == nil)
        #expect(p("/var/log/syslog") == nil)
        #expect(p("COMEDY")?.kind == "ssh")
        #expect(p("COM3")?.kind == "serial")
    }

    @Test func theLabelCarriesTheProtocolAndDropsADefaultPort() {
        let l = { (s: String) in QuickConnect.targetLabel(self.p(s)!) }
        #expect(l("ubuntu@10.0.0.5") == "ubuntu@10.0.0.5")
        #expect(l("box:2222") == "box:2222")
        #expect(l("telnet://switch-1") == "telnet://switch-1")
        #expect(l("telnet://switch-1:2323") == "telnet://switch-1:2323")
        #expect(l("vnc://10.0.0.5:5900") == "vnc://10.0.0.5")
        #expect(l("/dev/ttyUSB0") == "/dev/ttyUSB0")
        #expect(l("/dev/ttyUSB0@9600") == "/dev/ttyUSB0@9600")
        #expect(l("[fe80::1]:2222") == "[fe80::1]:2222")
    }

    @Test func aLabelParsesBackToTheSameThing() {
        for s in ["ubuntu@10.0.0.5", "box:2222", "telnet://switch-1:2323", "vnc://10.0.0.5:5901", "rdp://win-1", "/dev/ttyUSB0@9600"] {
            let first = p(s)!
            let again = p(QuickConnect.targetLabel(first))!
            #expect(again.kind == first.kind, "\(s)")
            #expect(again.hostname == first.hostname, "\(s)")
            #expect(again.port == first.port, "\(s)")
            #expect(again.path == first.path, "\(s)")
            #expect(again.baudRate == first.baudRate, "\(s)")
        }
    }

    @Test func aQuickHostIsKeyedByTheWholeAddress() {
        let h = QuickConnect.quickHost(p("ops@box:2222")!)
        #expect(h.id == "direct:ops@box:2222")
        #expect(h.direct?.port == 2222)
        #expect(h.direct?.user == "ops")
        #expect(h.alias == nil)
        #expect(QuickConnect.quickHost(p("box")!).id == "direct:@box:22")
    }

    @Test func tokenizeRespectsQuotes() {
        #expect(QuickConnect.tokenize(#"ssh -i "my key" 'a b'"#) == ["ssh", "-i", "my key", "a b"])
    }
}

/// The recents list (store.js listRecent) and the launcher's descriptions.
@Suite struct HostsRecentTests {
    func h(_ type: String, _ node: String, at: Double, error: String? = nil, login: String? = nil, port: Int? = nil) -> JSON {
        var o: JSON = ["type": .string(type), "label": .string(node), "node": .string(node), "startedAt": .number(at),
                       "error": JSON(error), "login": JSON(login)]
        if let port { o["direct"] = ["hostname": .string(node), "port": JSON(port)] }
        return o
    }

    @Test func oneEntryPerDestinationNewestFirst() {
        let list = HostsData.listRecent([h("ssh", "a", at: 3), h("ssh", "b", at: 2), h("ssh", "a", at: 1)], limit: 20)
        #expect(list.map { $0["node"].string } == ["a", "b"])
        #expect(list[0]["count"].int == 2)
        #expect(list[0]["at"].double == 3)
    }

    @Test func aDestinationThatEverWorkedIsNotMarkedFailed() {
        let list = HostsData.listRecent([h("ssh", "a", at: 3, error: "refused"), h("ssh", "a", at: 1)], limit: 20)
        #expect(list[0]["error"].isNull)
        #expect(list[0]["lastOkAt"].double == 1)
    }

    @Test func thePortAndTheLoginArePartOfTheIdentity() {
        let list = HostsData.listRecent([h("ssh", "a", at: 3, port: 22), h("ssh", "a", at: 2, port: 2222),
                                         h("ssh", "a", at: 1, login: "root", port: 22)], limit: 20)
        #expect(list.count == 3)
    }

    @Test func theLimitIsHonoured() {
        let list = HostsData.listRecent((0..<30).map { h("ssh", "n\($0)", at: Double(100 - $0)) }, limit: 5)
        #expect(list.count == 5)
        #expect(HostsData.listRecent([h("ssh", "a", at: 1)], limit: 0).isEmpty)
    }

    @MainActor @Test func aRecentReadsAsAccountThenHostThenCluster() {
        let now = 10_000_000.0
        let r: JSON = ["type": "teleport", "node": "web-1", "cluster": "prod", "login": "ubuntu", "at": .number(now - 300_000)]
        #expect(NewSession.recentMeta(r, now: now) == "ubuntu@web-1  ·  prod  ·  5m ago")
        let s: JSON = ["type": "ssh", "target": "ops@box", "at": .number(now - 30_000)]
        #expect(NewSession.recentMeta(s, now: now) == "ops@box  ·  just now")
        #expect(NewSession.ago(now - 100_000_000, now: now) == "yesterday")
        #expect(NewSession.ago(now - 3 * 86_400_000, now: now) == "3d ago")
    }

    @MainActor @Test func onlyWhatReadsLikeAnAddressIsOfferedAsAQuickConnect() {
        #expect(NewSession.typedTarget("web") == nil)
        #expect(NewSession.typedTarget("web-1.example.com")?.hostname == "web-1.example.com")
        #expect(NewSession.typedTarget("ubuntu@box")?.user == "ubuntu")
        #expect(NewSession.typedTarget("telnet switch")?.kind == "telnet")
        #expect(NewSession.typedTarget("two words") == nil)
    }
}

/// profiles.js helpers.
@MainActor @Suite struct HostsProfileTests {
    @Test func defaultPortsFollowTheProtocol() {
        #expect(Profiles.defaultPort(for: "telnet") == 23)
        #expect(Profiles.defaultPort(for: "vnc") == 5900)
        #expect(Profiles.defaultPort(for: "rdp") == 3389)
        #expect(Profiles.defaultPort(for: "ssh") == 22)
        #expect(Profiles.defaultPort(for: "vnc", initial: ["type": "vnc", "devicePort": 5901]) == 5901)
        #expect(Profiles.defaultPort(for: "rdp", initial: ["type": "vnc", "devicePort": 5901]) == 3389)
    }

    @Test func aSavedConnectionDescribesItself() {
        #expect(Profiles.meta(["type": "teleport", "node": "web-1", "cluster": "prod"]) == "web-1 @ prod")
        #expect(Profiles.meta(["type": "serial", "path": "/dev/ttyUSB0"]) == "/dev/ttyUSB0 · 115200")
        #expect(Profiles.meta(["type": "vnc", "host": "10.0.0.5"]) == "10.0.0.5:5900")
        #expect(Profiles.meta(["type": "telnet", "host": "sw", "devicePort": 2323]) == "sw:2323")
        #expect(Profiles.meta(["type": "ssh", "alias": "web"]) == "web")
        #expect(Profiles.meta(["type": "ssh", "hostname": "10.0.0.1"]) == "10.0.0.1")
        #expect(Profiles.kindLabel(["type": "teleport"]) == "tsh")
        #expect(Profiles.kindLabel([:]) == "ssh")
    }
}

/// folders.js dialog helpers (the model itself is tested by the sidebar).
@MainActor @Suite struct HostsFolderDialogTests {
    @Test func insertingPutsTheAndInForYou() {
        #expect(FolderDialogs.insert("env=prod", into: "") == "env=prod")
        #expect(FolderDialogs.insert("role:web", into: "env=prod") == "env=prod and role:web")
        #expect(FolderDialogs.insert("or", into: "env=prod", operator: true) == "env=prod or ")
        #expect(FolderDialogs.insert("role:web", into: "env=prod or ") == "env=prod or role:web")
        #expect(FolderDialogs.insert("(", into: "", operator: true) == "( ")
        #expect(FolderDialogs.insert("a:", into: "(") == "( a:")
    }

    @Test func theRuleNoteSaysWhatItMatchesRightNow() {
        var a = Host(type: Host.teleport, id: "a", name: "web-1"); a.labels = ["env": "prod"]
        var b = Host(type: Host.teleport, id: "b", name: "db-1"); b.labels = ["env": "dev"]
        let none = FolderDialogs.ruleNote("", hosts: [a, b])
        #expect(none.text == "No rule: the folder holds only what you drag into it.")
        let hit = FolderDialogs.ruleNote("env=prod", hosts: [a, b])
        #expect(hit.text == "Matches 1 of 2 in this group right now.")
        #expect(hit.hits == ["web-1"])
        #expect(!hit.warn)
        let miss = FolderDialogs.ruleNote("env=staging", hosts: [a, b])
        #expect(miss.warn)
    }

    @Test func anExportIsNamedForItsGroup() {
        #expect(FolderDialogs.exportFileName(nil) == "serverlife-folders.json")
        #expect(FolderDialogs.exportFileName("tp:lab.example.com:443") == "serverlife-folders-tp_lab.example.com_443.json")
    }

    @Test func goneForReadsInTheLargestSensibleUnit() {
        let now = 1_000_000_000.0
        #expect(HostsHooks.goneFor(now - 30_000, now: now) == "30s")
        #expect(HostsHooks.goneFor(now - 600_000, now: now) == "10m")
        #expect(HostsHooks.goneFor(now - 5 * 3_600_000, now: now) == "5h")
        #expect(HostsHooks.goneFor(now - 3 * 86_400_000, now: now) == "3d")
        #expect(HostsHooks.sameGroup("tp:lab.example.com:443", "tp:lab.example.com"))
        #expect(!HostsHooks.sameGroup("tp:a", "tp:b"))
    }

    @Test func leafKeysSplitIntoGroupAndCluster() {
        #expect(HostsPane.leafOf("tp:p::leaf-1")?.cluster == "leaf-1")
        #expect(HostsPane.leafOf("tp:p::leaf-1")?.group == "tp:p")
        #expect(HostsPane.leafOf("tp:p") == nil)
    }
}
