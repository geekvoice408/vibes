import Foundation
import Testing
@testable import ServerLife

/// macros.js: variables, scopes, intervals; and the store records behind
/// snippets, macros, recent runs and favourite tunnels.
@MainActor
@Suite struct FleetMacroTests {
    @Test func theDeclarationBlockReadsDefaultsListsAndBlanks() {
        let v = Macros.parseVarSpec("service = teleport\nlevel = info | *warn | error\nlines =\n# a comment\nbad name = x\nflag")
        #expect(v == [MacroVar(name: "service", defaultValue: "teleport"),
                      MacroVar(name: "level", choices: ["info", "warn", "error"], defaultValue: "warn"),
                      MacroVar(name: "lines", defaultValue: ""),
                      MacroVar(name: "flag", defaultValue: "")])
        // The first choice is the default when none is starred.
        #expect(Macros.parseVarSpec("x = a | b")[0].defaultValue == "a")
        #expect(Macros.renderVarSpec(v) == "service = teleport\nlevel = info | *warn | error\nlines = \nflag = ")
    }

    @Test func blanksUsedButNotDeclaredAreAskedForAndUnusedOnesAreNot() {
        let vars = Macros.varsOf(command: "journalctl -u {{ service }} -n {{lines}} {{service}}",
                                 variables: nil, variableSpec: "service = teleport\nunused = 1")
        #expect(vars == [MacroVar(name: "service", defaultValue: "teleport"), MacroVar(name: "lines", defaultValue: "")])
        #expect(Macros.expand("a {{ x }} {{y}} {{x}}", ["x": "1"]) == "a 1 {{y}} 1")
    }

    @Test func scopesDecideWhereAMacroIsOffered() {
        var m = Macro(id: "m", category: "C", name: "n", description: "", command: "ls")
        #expect(Macros.runsOn(m, "local") && Macros.runsOn(m, "remote"))   // no scope: everywhere, as before
        m.whereScope = "hosts"
        #expect(!Macros.runsOn(m, "local") && Macros.runsOn(m, "remote"))
        m.whereScope = "local"
        #expect(Macros.runsOn(m, "local") && !Macros.runsOn(m, "remote"))
        #expect(Macros.runScopeLabel(nil) == "Hosts and the local shell")
        #expect(Macros.scopeLabel(nil) == "Host sessions only")
    }

    @Test func theBuiltInsAreHostCommandsExceptTheOnesThatSayOtherwise() {
        let b = Macros.builtins
        #expect(b.count == 20)
        #expect(b.allSatisfy { $0.builtin })
        #expect(Set(b.filter { $0.whereScope == "all" }.map(\.id)) == ["b:disk", "b:net", "b:os"])
        #expect(Set(b.filter { $0.whereScope == "local" }.map(\.id)) == ["b:tsh-ls", "b:tsh-ssh", "b:tsh-scp"])
        #expect(b.first { $0.id == "b:tp-restart" }?.confirm == true)
        #expect(b.first { $0.id == "b:tp-journal" }?.interactive == true)
    }

    @Test func intervalsReadAsAPersonWouldSayThem() {
        #expect(Macros.fmtEvery(45) == "45s")
        #expect(Macros.fmtEvery(120) == "2m")
        #expect(Macros.fmtEvery(90) == "1m 30s")
        #expect(Macros.fmtEvery(5400) == "1h 30m")
        #expect(Macros.fmtEvery(7200) == "2h")
        #expect(Macros.fmtEvery(0) == "1s")
    }
}

@MainActor
@Suite(.serialized) struct FleetStoreTests {
    init() {
        // A throwaway store: never the real sessions.json.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-fleet-tests-\(UUID().uuidString)")
        FleetStore.storeOverride = Store(dir: dir)
    }

    @Test func aRepeatedRunReplacesItsEarlierEntryAndTheListIsCapped() {
        FleetStore.addExecRun(["command": "uptime", "hostIds": ["b", "a"], "hosts": ["B", "A"], "ok": 2])
        FleetStore.addExecRun(["command": "df", "hostIds": ["a"]])
        FleetStore.addExecRun(["command": "  uptime ", "hostIds": ["a", "b"], "ok": 1, "failed": 1])
        let runs = FleetStore.execRuns()
        #expect(runs.map { $0["command"].string } == ["uptime", "df"])
        #expect(runs[0]["failed"].int == 1)
        #expect(FleetStore.addExecRun(["command": "   "]) == nil)
        for i in 0..<50 { FleetStore.addExecRun(["command": .string("c\(i)")]) }
        #expect(FleetStore.execRuns().count == 40)
        #expect(FleetStore.execRuns()[0]["command"].string == "c49")
    }

    @Test func starringTheSameTunnelTwiceKeepsOneRow() throws {
        let host: JSON = ["id": "tsh:prod:n1", "type": "teleport", "name": "n1"]
        let a = try FleetStore.addForwardFavorite(["kind": "L", "bindPort": 5432, "destHost": "10.0.4.12", "destPort": 5432, "host": host])
        let b = try FleetStore.addForwardFavorite(["kind": "L", "bindPort": 5432, "destHost": "10.0.4.13", "destPort": 5432,
                                                   "host": host, "name": "replica"])
        #expect(a["id"] == b["id"])
        #expect(FleetStore.forwardFavorites().count == 1)
        #expect(FleetStore.forwardFavorites()[0]["destHost"].string == "10.0.4.13")
        let d = try FleetStore.addForwardFavorite(["kind": "D", "bindPort": 1080, "destHost": "x", "destPort": 9, "host": host])
        #expect(d["destHost"].string == "" && d["destPort"].int == 0)
        #expect(throws: AppError.self) { try FleetStore.addForwardFavorite(["kind": "L", "host": host]) }
        #expect(throws: AppError.self) { try FleetStore.addForwardFavorite(["kind": "L", "bindPort": 1]) }
    }

    @Test func pinsAppendKeepTheirPlaceAndGoWithTheirMacro() {
        let m = FleetStore.upsertMacro(["command": "uptime\nmore", "where": "nowhere"])
        let id = m["id"].string!
        #expect(m["name"].string == "uptime" && m["category"].string == "Custom" && m["where"].string == "all")
        FleetStore.setMacroPin("b:disk", icon: "💾")
        FleetStore.setMacroPin(id, icon: "▶", where: "local")
        FleetStore.setMacroPin("b:disk", icon: "📊")        // re-pinning keeps its place
        #expect(FleetStore.macroPins().map { $0["id"].string } == ["b:disk", id])
        #expect(FleetStore.macroPins()[0]["icon"].string == "📊" && FleetStore.macroPins()[0]["where"].string == "hosts")
        FleetStore.deleteMacro(id)
        #expect(FleetStore.macroPins().map { $0["id"].string } == ["b:disk"])
    }

    @Test func snippetsAreNamedFromTheirCommandAndCountUse() {
        let s = FleetStore.upsertSnippet(["command": "sudo tail -f /var/log/syslog"])
        FleetStore.markSnippetUsed(s["id"].string!)
        #expect(FleetStore.snippets()[0]["name"].string == "sudo tail -f /var/log/syslog")
        #expect(FleetStore.snippets()[0]["useCount"].int == 1)
        let sorted = Snippets.sorted(FleetStore.snippets() + [["name": "a", "command": "x", "useCount": 0]], filter: "")
        #expect(sorted.first?["id"] == s["id"])
    }

    @Test func categoriesFollowTheSavedOrderThenTeleportFirst() {
        FleetStore.setMacroCategoryOrder([])
        let cats = Macros.shared.categories(Macros.builtins + [Macro(id: "x", category: "Custom", name: "x", description: "", command: "x"),
                                                                Macro(id: "y", category: "Alpha", name: "y", description: "", command: "y")])
        #expect(cats.map(\.0) == ["Teleport", "Alpha", "System", "Custom"])
        FleetStore.setMacroCategoryOrder(["System", "System", ""])
        #expect(FleetStore.macroCategoryOrder() == ["System"])
    }
}

@Suite struct FleetAuditFixTests {
    @Test func outputKeepsItsTailByBytesAndStartsOnACharacter() {
        let s = String(repeating: "é", count: 10)            // 20 bytes
        let t = MultiExecService.tail(s, cap: 7)
        #expect(t == "ééé")                                     // 7 bytes would split a character
        #expect(MultiExecService.tail("short", cap: 100) == "short")
    }

    @Test func aCharacterSplitAcrossReadsWaitsUntilItIsWhole() {
        let b = MXOutputBuffer()
        let bytes = Array("aé".utf8)                            // 61 C3 A9
        b.append("r", "c", isOut: true, Data(bytes[0..<2]))
        #expect(b.drain().first?.out == "a")
        b.append("r", "c", isOut: true, Data(bytes[2...]))
        #expect(b.drain().first?.out == "é")
        #expect(b.drain().isEmpty)
    }

    @Test func aButtonScopeIsNarrowedToWhereTheMacroRuns() {
        #expect(MacroDialogs.clampPin("all", run: "hosts") == "hosts")
        #expect(MacroDialogs.clampPin("local", run: "hosts") == "hosts")
        #expect(MacroDialogs.clampPin("local", run: "all") == "local")
        #expect(MacroDialogs.clampPin("hosts", run: "hosts") == "hosts")
    }

    @Test func readErrorsAreWordedAsJsYamlWordsThem() {
        do { _ = try YAMLReader.load("a: \"x"); Issue.record("no error") } catch {
            #expect(String(describing: error) == "unexpected end of the stream within a double quoted scalar (1:6)\n\n 1 | a: \"x\n----------^")
        }
    }
}
