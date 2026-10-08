import Testing
import Foundation
@testable import ServerLife

/// tests/folders.test.mjs — the folder model: membership (dragged in, claimed
/// by rule, taken back out), the tree, drops, export/import and the repair.
extension SidebarStoreSuites { @MainActor @Suite struct SidebarFolderModelTests {
    typealias F = FolderModel
    static let G = "tp:example:443"
    static let hosts: [ServerLife.Host] = [
        sbNode("web-1", ["env": "prod", "role": "web"]),
        sbNode("web-2", ["env": "prod", "role": "web"]),
        sbNode("api-1", ["env": "prod", "role": "api"]),
        sbNode("db-1", ["env": "dev", "role": "db"]),
        sbSshHost("jump"),
    ]
    var hosts: [ServerLife.Host] { Self.hosts }
    var G: String { Self.G }
    func names(_ l: [ServerLife.Host]) -> [String] { l.map { $0.name } }

    init() { _ = sbFreshStore(["hostFolders": [], "folderMembers": [:]]) }

    @Test func aHostIsFiledUnderItsUuid() {
        #expect(F.hostKey(sbNode("web-1")) == "uuid:uuid-web-1")
        var t = ServerLife.Host(type: ServerLife.Host.teleport, id: "", name: "x"); t.cluster = "c"; t.id = ""
        #expect(F.hostKey(t) == "tsh:c:x")
        #expect(F.hostKey(sbSshHost("jump")) == "ssh:jump")
        #expect(F.hostKey(nil) == "")
    }

    @Test func aFolderHoldsWhatWasDraggedIn() {
        let f = F.createFolder(name: "Mine", group: G)
        #expect(names(F.hostsInFolder(f, hosts)) == [])
        F.fileHost(hosts[0], f.id)
        #expect(names(F.hostsInFolder(F.folder(id: f.id), hosts)) == ["web-1"])
        #expect(F.isManualMember(hosts[0], f.id))
        #expect(F.isFiled(hosts[0], G))
        #expect(!F.isFiled(hosts[1], G))
    }

    @Test func aRuleFillsAFolderOnItsOwn() {
        let f = F.createFolder(name: "Prod", group: G, rule: "env=prod")
        #expect(names(F.hostsInFolder(f, hosts)) == ["web-1", "web-2", "api-1"])
        let late = sbNode("web-3", ["env": "prod", "role": "web"])
        #expect(F.hostsInFolder(f, hosts + [late]).contains(late))
        #expect(!F.isManualMember(late, f.id))
    }

    @Test func aBooleanRuleIsHonoured() {
        let f = F.createFolder(name: "Edge", group: G, rule: "env=prod and (role:web or role:api) and not name~^api")
        #expect(names(F.hostsInFolder(f, hosts)) == ["web-1", "web-2"])
    }

    @Test func handFiledAndRuleFilledLiveTogether() {
        let f = F.createFolder(name: "Prod plus", group: G, rule: "env=prod")
        F.fileHost(hosts[3], f.id)
        #expect(names(F.hostsInFolder(F.folder(id: f.id), hosts)) == ["web-1", "web-2", "api-1", "db-1"])
    }

    @Test func takingARuleMatchOutSticksAndCanBeUndone() {
        let f = F.createFolder(name: "Prod", group: G, rule: "env=prod")
        F.unfileHost(hosts[1], f.id)
        #expect(names(F.hostsInFolder(F.folder(id: f.id), hosts)) == ["web-1", "api-1"])
        #expect(F.isExcluded(hosts[1], f.id))
        #expect(!F.isFiled(hosts[1], G))
        F.clearExclusion(hosts[1], f.id)
        #expect(names(F.hostsInFolder(F.folder(id: f.id), hosts)) == ["web-1", "web-2", "api-1"])
    }

    @Test func filingAgainClearsTheExclusion() {
        let f = F.createFolder(name: "Prod", group: G, rule: "env=prod")
        F.unfileHost(hosts[0], f.id)
        #expect(F.isExcluded(hosts[0], f.id))
        F.fileHost(hosts[0], f.id)
        #expect(!F.isExcluded(hosts[0], f.id))
        #expect(F.hostsInFolder(F.folder(id: f.id), hosts).contains(hosts[0]))
    }

    @Test func foldersAreScopedToTheirGroup() {
        let f = F.createFolder(name: "Elsewhere", group: "tp:other:443", rule: "env=prod")
        #expect(F.foldersForHost(hosts[0], G).isEmpty)
        #expect(!F.isFiled(hosts[0], G))
        #expect(F.foldersForHost(hosts[0], "tp:other:443").map(\.id) == [f.id])
        #expect(!F.groupHasFolders(G))
        #expect(F.groupHasFolders("tp:other:443"))
    }

    @Test func foldersNestAndATreeCountsEachHostOnce() {
        let top = F.createFolder(name: "Top", group: G)
        let mid = F.createFolder(name: "Mid", group: G, parent: top.id)
        F.fileHost(hosts[0], top.id)
        F.fileHost(hosts[0], mid.id)
        F.fileHost(hosts[1], mid.id)
        #expect(F.folders(in: G).map(\.name) == ["Top"])
        #expect(F.folders(in: G, parent: top.id).map(\.name) == ["Mid"])
        #expect(F.folderPath(F.folder(id: mid.id)!).map(\.name) == ["Top", "Mid"])
        #expect(F.rootOf(F.folder(id: mid.id)!).id == top.id)
        #expect(names(F.hostsInTree(F.folder(id: top.id)!, hosts)) == ["web-1", "web-2"])
        #expect(F.subtreeIds(top.id).sorted() == [top.id, mid.id].sorted())
    }

    @Test func aFolderCannotGoInsideItselfOrItsChild() {
        let a = F.createFolder(name: "A", group: G)
        let b = F.createFolder(name: "B", group: G, parent: a.id)
        #expect(!F.reparentFolder(a.id, a.id))
        #expect(!F.reparentFolder(a.id, b.id))
        #expect(F.folder(id: a.id)?.parent == nil)
        #expect(F.reparentFolder(b.id, nil))
        #expect(F.folder(id: b.id)?.parent == nil)
    }

    @Test func deletingAFolderTakesItsSubtreeAndMembership() {
        let a = F.createFolder(name: "A", group: G)
        let b = F.createFolder(name: "B", group: G, parent: a.id)
        F.fileHost(hosts[0], b.id)
        F.deleteFolder(a.id)
        #expect(F.allFolders().isEmpty)
        #expect(SB.store.settingJSON("folderMembers").entries.isEmpty)
        #expect(!F.isFiled(hosts[0], G))
    }

    @Test func aDropWithNothingToClashWithJustFilesIt() async {
        let f = F.createFolder(name: "A", group: G)
        let r = await F.fileHostsInto([hosts[0]], f, G)
        #expect(r?.count == 1 && r?.mode == "move")
        #expect(F.isManualMember(hosts[0], f.id))
    }

    @Test func aDropInsideTheSameTreeMovesWithoutAsking() async {
        let top = F.createFolder(name: "Top", group: G)
        let mid = F.createFolder(name: "Mid", group: G, parent: top.id)
        F.fileHost(hosts[0], top.id)
        let r = await F.fileHostsInto([hosts[0]], mid, G)
        #expect(r?.mode == "move")
        #expect(names(F.hostsInFolder(F.folder(id: top.id), hosts)) == [])
        #expect(names(F.hostsInFolder(F.folder(id: mid.id), hosts)) == ["web-1"])
    }

    @Test func severalHostsLandInOneGo() async {
        let f = F.createFolder(name: "A", group: G)
        let r = await F.fileHostsInto([hosts[0], hosts[1], hosts[4]], f, G)
        #expect(r?.count == 3)
        #expect(names(F.hostsInFolder(F.folder(id: f.id), hosts)) == ["web-1", "web-2", "jump"])
    }

    @Test func anExportCarriesTheTreeRulesAndMembership() {
        let a = F.createFolder(name: "A", group: G, rule: "env=prod", icon: "🔥", color: "red")
        _ = F.createFolder(name: "B", group: G, parent: a.id)
        F.fileHost(hosts[3], a.id)
        _ = F.createFolder(name: "Other", group: "tp:other:443")
        let data = F.exportData(G)
        #expect(data["kind"].string == "serverlife-folders")
        #expect(data["groups"].stringArray == [G])
        #expect(data["folders"].items.map { $0["name"].string ?? "" } == ["A", "B"])
        #expect(data["folders"][0]["icon"].string == "🔥")
        #expect(data["folders"][0]["color"].string == "red")
        #expect(data["members"].entries.values.first?["in"].stringArray == [F.hostKey(hosts[3])])
        #expect(!data.text().contains("password"))
    }

    @Test func anImportLandsOnTheSameMachinesWithNewIds() throws {
        let a = F.createFolder(name: "A", group: G, rule: "env=prod")
        F.fileHost(hosts[3], a.id)
        let text = F.exportData(G).text()
        _ = sbFreshStore(["hostFolders": [], "folderMembers": [:]])
        let out = F.importData(try F.parseImport(text), mode: "merge")
        #expect(out.folders == 1)
        let back = F.allFolders()[0]
        #expect(back.id != a.id)
        #expect(back.rule == "env=prod")
        #expect(names(F.hostsInFolder(back, hosts)) == ["web-1", "web-2", "api-1", "db-1"])
    }

    @Test func importingTwiceCopiesAndReplaceOverwrites() throws {
        _ = F.createFolder(name: "A", group: G)
        let text = F.exportData(G).text()
        F.importData(try F.parseImport(text), mode: "merge")
        #expect(F.allFolders().count == 2)
        F.importData(try F.parseImport(text), mode: "replace")
        #expect(F.allFolders().count == 1)
    }

    @Test func anImportCanBeLandedInAnotherGroup() throws {
        _ = F.createFolder(name: "A", group: G, rule: "env=prod")
        let text = F.exportData(G).text()
        _ = sbFreshStore(["hostFolders": [], "folderMembers": [:]])
        F.importData(try F.parseImport(text), mode: "merge", remap: "tp:elsewhere:443")
        #expect(F.allFolders()[0].group == "tp:elsewhere:443")
    }

    @Test func aFileThatIsNotOursIsRefusedByName() {
        #expect(throws: AppError.self) { try F.parseImport("not json") }
        do { _ = try F.parseImport("not json") } catch { #expect("\(error)".contains("not JSON")) }
        do { _ = try F.parseImport(#"{"kind":"something-else"}"#) } catch { #expect("\(error)".contains("not a ServerLife folder export")) }
        do { _ = try F.parseImport(#"{"kind":"serverlife-folders"}"#) } catch { #expect("\(error)".contains("no folders")) }
    }

    @Test func foldersFiledUnderAProxyAddressAreMoved() {
        SB.store.updateSettings(["hostFolders": [
            ["id": "f1", "name": "Orphan", "group": "example:443", "parent": nil, "rule": ""],
            ["id": "f2", "name": "Fine", "group": .string(G), "parent": nil, "rule": ""],
            ["id": "f3", "name": "Unknown cluster", "group": "gone.example:443", "parent": nil, "rule": ""],
        ]])
        #expect(F.repairFolderGroups([G, "ssh"]) == 1)
        #expect(F.folder(id: "f1")?.group == G)
        #expect(F.folder(id: "f2")?.group == G)
        #expect(F.folder(id: "f3")?.group == "gone.example:443")
    }

    @Test func aFolderShowsItsOwnIconOrTheOpenAndShutOnes() {
        let plain = F.createFolder(name: "Plain", group: G)
        let fancy = F.createFolder(name: "Fancy", group: G, icon: "🔥", color: "red")
        #expect(F.folderIcon(plain, open: false) == "\u{1F4C1}")
        #expect(F.folderIcon(plain, open: true) == "\u{1F4C2}")
        #expect(F.folderIcon(fancy, open: true) == "🔥")
        #expect(F.folderColorHex(fancy) == "#f85149")
        #expect(F.folderColorHex(plain) == "")
    }
}
}
