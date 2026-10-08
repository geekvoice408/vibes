import Foundation
import Testing
@testable import ServerLife

/// store.js record methods (Data/StoreRecords.swift) and backup.js
/// (Data/Backup.swift): caps, dedupe and ordering per collection, always on a
/// throwaway `Store(dir:)`.
@MainActor
@Suite struct StoreRecordsTests {
    let s: Store

    init() {
        s = Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("sl-data-tests-\(UUID().uuidString)"))
    }

    private func ids(_ l: [JSON]) -> [String] { l.compactMap { $0["id"].string } }

    // MARK: profiles and folders

    @Test func profileCreateFillsTheFullShapeAndUpdateMerges() {
        let p = s.upsertProfile(["alias": "web1", "quality": 0, "extra": "kept"])
        #expect(p["id"].string?.hasPrefix("p_") == true)
        #expect(p["name"] == "web1" && p["type"] == "ssh" && p["clipboard"] == true && p["quality"] == 0)
        #expect(p["useCount"] == 0 && p["lastUsed"].isNull && p["tags"] == [])
        #expect(p["extra"].isNull)   // a new record has only store.js's fields
        let u = s.upsertProfile(["id": p["id"], "name": "Web", "custom": 1])
        #expect(u["name"] == "Web" && u["alias"] == "web1" && u["custom"] == 1)
        #expect(s.listProfiles().count == 1)
        s.markProfileUsed(p["id"].string); s.markProfileUsed(p["id"].string)
        #expect(s.getProfile(p["id"].string)?["useCount"] == 2)
        #expect(s.upsertProfile(["name": "x"])["name"] == "x")
        #expect(s.upsertProfile(["id": "nope"])["name"] == "Untitled")   // unknown id → new record
        #expect(s.listProfiles().count == 3)
    }

    @Test func deletingAFolderUnfilesItsProfiles() {
        let f = s.upsertFolder(["name": "Prod"])
        #expect(f["id"].string?.hasPrefix("f_") == true && f["parentId"].isNull)
        let p = s.upsertProfile(["name": "a", "folderId": f["id"]])
        #expect(s.upsertFolder(["id": f["id"], "name": "Production"])["name"] == "Production")
        s.deleteFolder(f["id"].string!)
        #expect(s.listFolders().isEmpty)
        #expect(s.getProfile(p["id"].string)?["folderId"].isNull == true)
        #expect(s.upsertFolder([:])["name"] == "New folder")
    }

    // MARK: history

    @Test func historyIsNewestFirstCappedAt500AndEndsOnce() {
        let first = s.startHistory(["type": "ssh", "label": "a", "target": "a"])
        #expect(first["id"].string?.hasPrefix("h_") == true && first["endedAt"].isNull)
        for i in 0..<510 { s.startHistory(["type": "ssh", "label": .string("n\(i)")]) }
        #expect(s["history"].items.count == 500)
        #expect(s.listHistory().count == 200 && s.listHistory(limit: 3).first?["label"] == "n509")
        let h = s.listHistory(limit: 1)[0]["id"].string!
        #expect(s.endHistory(h, error: "boom")?["error"] == "boom")
        #expect(s.endHistory(h) == JSON?.none)
        s.clearHistory()
        #expect(s.listHistory().isEmpty)
    }

    @Test func recentIsOnePerDestinationRemembersSuccessAndSplitsPorts() {
        func h(_ t: String, _ at: Double, error: String? = nil, port: Int? = nil) -> JSON {
            var r: JSON = ["type": "ssh", "label": .string(t), "target": .string(t), "startedAt": .number(at), "error": JSON(error)]
            if let port { r["direct"] = ["port": .number(Double(port))] }
            return r
        }
        let r = Store.listRecent([h("a", 5, error: "refused"), h("b", 4), h("a", 3), h("c", 2, port: 22), h("c", 1, port: 2222)], limit: 20)
        #expect(r.map { $0["label"].string! } == ["a", "b", "c", "c"])
        #expect(r[0]["count"] == 2 && r[0]["error"].isNull && r[0]["lastOkAt"] == 3 && r[0]["at"] == 5)
        #expect(Store.listRecent([h("a", 1), h("b", 2), h("c", 3)], limit: 2).count == 2)
        #expect(Store.listRecent([h("a", 1)], limit: 0).isEmpty)
    }

    // MARK: workspaces and layouts

    @Test func workspacesKeepW1InStepAndListInSlotOrder() {
        s.saveWorkspace(["tabs": [["t": 1]]], slot: "w10")
        s.saveWorkspace(["tabs": [["t": 1]]], slot: "w2")
        s.saveWorkspace(["tabs": []], slot: "w3")
        let w1 = s.saveWorkspace(["tabs": [["t": 1]]], slot: "w1")
        #expect(w1?["slot"] == "w1" && w1?["savedAt"].truthy == true)
        #expect(s["workspace"] == w1!)
        #expect(s.listWorkspaces().map { $0["slot"].string! } == ["w1", "w2", "w10"])
        s.saveWorkspace(nil, slot: "w1")
        #expect(s["workspace"].isNull && s.getWorkspace("w1") == JSON?.none)
        s.clearWorkspace("w2")
        #expect(s.getWorkspace("w2") == JSON?.none && s.getWorkspace("w10") != JSON?.none)
        s.clearWorkspace()
        #expect(s.listWorkspaces().isEmpty)
    }

    @Test func layoutsOverwriteByNameCaseInsensitivelyAndTrackTheDefault() {
        let a = s.saveLayout(name: "Morning", workspace: ["v": 1])
        #expect(a["id"].string?.hasPrefix("l_") == true && a["isDefault"] == false)
        let b = s.saveLayout(name: "MORNING", workspace: ["v": 2])
        #expect(b["id"] == a["id"] && b["name"] == "MORNING" && s.listLayouts().count == 1)
        #expect(s.setDefaultLayout(a["id"].string) == a["id"].string)
        #expect(s.listLayouts()[0]["isDefault"] == true && s.getDefaultLayout()?["workspace"] == ["v": 2])
        #expect(s.setDefaultLayout("missing") == nil)
        s.setDefaultLayout(a["id"].string)
        s.deleteLayout(a["id"].string!)
        #expect(s["defaultLayoutId"].isNull && s.listLayouts().isEmpty)
        #expect(s.saveLayout(name: "", workspace: [:])["name"] == "Layout")
    }

    // MARK: snippets and macros

    @Test func snippetsNameFromTheFirstLineAndCountUse() {
        let sn = s.upsertSnippet(["command": .string("echo " + String(repeating: "x", count: 60) + "\nsecond")])
        #expect(sn["id"].string?.hasPrefix("s_") == true && sn["name"].string?.count == 40)
        #expect(s.upsertSnippet([:])["name"] == "Snippet")
        s.markSnippetUsed(sn["id"].string!)
        #expect(s.listSnippets()[0]["useCount"] == 1 && s.listSnippets()[0]["lastUsed"].truthy)
        s.deleteSnippet(sn["id"].string!)
        #expect(s.listSnippets().count == 1)
    }

    @Test func macroDefaultsPinsHiddenAndCategoryOrder() {
        let m = s.upsertMacro(["command": "uptime", "where": "nowhere", "repeatSeconds": 2.5])
        #expect(m["id"].string?.hasPrefix("m_") == true && m["category"] == "Custom" && m["where"] == "all")
        #expect(m["repeatSeconds"] == 3 && s.upsertMacro(["repeatSeconds": -4])["repeatSeconds"] == 0)
        let id = m["id"].string!
        s.setMacroPin("other", icon: "🔥🔥🔥🔥🔥", where: "local")
        s.setMacroPin(id, icon: "A")
        let pins = s.setMacroPin("other", icon: "B")
        #expect(pins.map { $0["id"].string! } == ["other", id])                    // re-pin keeps place
        #expect(pins[0]["icon"] == "B" && pins[0]["where"] == "local" && pins[1]["where"] == "hosts")
        s.deleteMacro(id)
        #expect(s.listMacros()["pins"].items.count == 1)                            // pin dropped with macro
        #expect(s.setMacroCategoryOrder(["b", "", "a", "b"]) == ["b", "a"])
        s["hiddenMacros"] = ["x", "x"]
        #expect(s.setMacroHidden("y", true) == ["x", "y"])
        #expect(s.setMacroHidden("x", false) == ["y"])
        #expect(s.markMacroUsed("missing") == JSON?.none)
    }

    // MARK: downloads, exec runs, net

    @Test func downloadsDedupeByPathMoveToTopAndCapAt300() {
        let a = s.addDownload(["localPath": "/tmp/a.txt", "bytes": 5])
        #expect(a?["id"].string?.hasPrefix("dl_") == true && a?["name"] == "a.txt" && a?["files"] == 1)
        s.addDownload(["localPath": "/tmp/b.txt"])
        let again = s.addDownload(["localPath": "/tmp/a.txt", "bytes": 9])
        #expect(again?["id"] == a?["id"] && again?["bytes"] == 9)
        #expect(s["downloads"].items.first?["localPath"] == "/tmp/a.txt" && s["downloads"].items.count == 2)
        #expect(s.addDownload(["name": "x"]) == JSON?.none)
        for i in 0..<310 { s.addDownload(["localPath": .string("/tmp/f\(i)")]) }
        #expect(s["downloads"].items.count == 300 && s.listDownloads().count == 300)
        s.clearDownloads()
        #expect(s.listDownloads().isEmpty)
    }

    @Test func execRunsReplaceTheSameCommandOnTheSameHostsAndCapAt40() {
        s.addExecRun(["command": "uptime", "hostIds": ["b", "a"]])
        s.addExecRun(["command": "df", "hostIds": ["a"]])
        let r = s.addExecRun(["command": " uptime ", "hostIds": ["a", "b", ""], "selector": ["query": "env=prod"]])
        #expect(r?["id"].string?.hasPrefix("mx_") == true && r?["hostIds"] == ["a", "b"])
        #expect(r?["selector"] == ["proxy": "", "query": "env=prod"])
        #expect(s.listExecRuns().map { $0["command"].string! } == ["uptime", "df"])
        #expect(s.addExecRun(["command": "  "]) == JSON?.none)
        for i in 0..<50 { s.addExecRun(["command": .string("c\(i)")]) }
        #expect(s.listExecRuns().count == 40 && s.listExecRuns()[0]["command"] == "c49")
    }

    @Test func netRequestsKeepSavedAtAndSortByLastRun() {
        let a = s.saveNetRequest(["target": "https://a", "on": ["label": "web"]])
        #expect(a["id"].string?.hasPrefix("req_") == true && a["name"] == "https://a" && a["tool"] == "curl")
        #expect(a["on"] == ["hostId": nil, "label": "web", "type": "ssh"])
        let b = s.saveNetRequest(["name": " B ", "target": "https://b", "lastRunAt": 5])
        #expect(b["name"] == "B")
        var a2 = a; a2["lastRunAt"] = .number(nowMs() + 1000)
        #expect(s.saveNetRequest(a2)["savedAt"] == a["savedAt"])
        #expect(ids(s.listNetRequests()) == [a["id"].string!, b["id"].string!])
        s.deleteNetRequest(a["id"].string!)
        #expect(s.listNetRequests().count == 1)
    }

    @Test func netRunsAreEveryRunNewestFirstCappedAt25() {
        // store.js compares a three-part key with a two-part one, so a repeat
        // is never replaced: Recent is every run.
        s.addNetRun(["tool": "ping", "target": "h"])
        let r = s.addNetRun(["tool": "ping", "target": "h", "ok": false, "summary": .string(String(repeating: "s", count: 200))])
        #expect(r["id"].string?.hasPrefix("run_") == true && r["ok"] == false && r["summary"].string?.count == 160)
        #expect(s.listNetRuns().count == 2 && s.listNetRuns()[0]["id"] == r["id"])
        for i in 0..<30 { s.addNetRun(["tool": "dig", "target": .string("t\(i)")]) }
        #expect(s.listNetRuns().count == 25)
        s.clearNetRuns()
        #expect(s.listNetRuns().isEmpty)
    }

    // MARK: forward favourites

    @Test func forwardFavoritesDedupeOnHostPortAndKind() throws {
        #expect(throws: AppError.self) { try s.addForwardFavorite(["host": ["id": "h"]]) }
        #expect(throws: AppError.self) { try s.addForwardFavorite(["bindPort": 80]) }
        let a = try s.addForwardFavorite(["host": ["id": "h"], "bindPort": "8080", "destHost": " db ", "destPort": 5432])
        #expect(a["id"].string?.hasPrefix("fwd_") == true && a["bindPort"] == 8080 && a["destHost"] == "db" && a["kind"] == "L")
        s.markForwardFavoriteUsed(a["id"].string!)
        let b = try s.addForwardFavorite(["host": ["id": "h"], "bindPort": 8080, "name": "again"])
        #expect(b["id"] == a["id"] && b["lastUsedAt"].truthy && b["name"] == "again")
        let d = try s.addForwardFavorite(["host": ["id": "h"], "bindPort": 8080, "kind": "D", "destHost": "x", "destPort": 1])
        #expect(d["destHost"] == "" && d["destPort"] == 0 && s.listForwardFavorites().count == 2)
        #expect(s.updateForwardFavorite(d["id"].string!, ["id": "hijack", "name": "n"])?["id"] == d["id"])
        #expect(s.updateForwardFavorite("missing", [:]) == JSON?.none)
        s.deleteForwardFavorite(d["id"].string!)
        #expect(s.listForwardFavorites().count == 1)
    }

    // MARK: session notes, tsh logins, request templates

    @Test func sessionNotesDeleteEmptyRecordsAndKeepEarlierDetails() {
        #expect(s.upsertSessionNote(["sid": "1", "note": "  "]) == JSON?.none)
        let a = s.upsertSessionNote(["sid": "1", "flagged": true, "node": "web"])
        #expect(a?["note"] == "" && a?["node"] == "web" && a?["playable"] == true && a?["home"].isNull == true)
        let b = s.upsertSessionNote(["sid": "1", "note": "deploy"])
        #expect(b?["flagged"] == true && b?["node"] == "web" && b?["createdAt"] == a?["createdAt"])
        s.upsertSessionNote(["sid": "2", "flagged": true])
        s.mutate("sessionNotes") { l in l[0]["updatedAt"] = 1 }   // "1" is older
        #expect(s.listSessionNotes().first?["sid"] == "2")
        #expect(s.upsertSessionNote(["sid": "1", "flagged": false, "note": ""]) == JSON?.none)
        #expect(s.deleteSessionNote("2").isEmpty)
    }

    @Test func tshLoginsAreOnePerProxyUserHomeAndSortByUse() {
        let a = s.upsertTshLogin(["proxy": "p:443", "user": "alice"])
        #expect(a["id"].string?.hasPrefix("tl_") == true && a["name"] == "p:443" && a["home"] == "" && a["lastUsed"] == 0)
        let a2 = s.upsertTshLogin(["proxy": "p:443", "user": "alice", "home": "", "ttl": "8h"])
        #expect(a2["id"] == a["id"] && a2["ttl"] == "8h")
        let b = s.upsertTshLogin(["proxy": "p:443", "user": "bob", "cluster": "prod"])
        #expect(b["name"] == "prod" && s.listTshLogins().count == 2)
        s.markTshLoginUsed(a["id"].string!)
        #expect(ids(s.listTshLogins()) == [a["id"].string!, b["id"].string!])
        #expect(s.listTshLogins()[0]["useCount"] == 1)
        s.deleteTshLogin(a["id"].string!)
        #expect(ids(s.listTshLogins()) == [b["id"].string!])
    }

    @Test func requestTemplatesTrimResourcesAndFilterOnProxyOrCluster() {
        let t = s.upsertRequestTemplate(["proxy": "p:443", "cluster": "prod",
                                         "resources": [["id": "/prod/node/1", "kind": "node", "labels": ["a": "b"]], ["name": "noid"]]])
        #expect(t["id"].string?.hasPrefix("rq_") == true && t["name"] == "Saved request")
        #expect(t["resources"] == [["id": "/prod/node/1", "kind": "node", "name": "", "cluster": ""]])
        let u = s.upsertRequestTemplate(["proxy": "other:443", "cluster": "dev"])
        #expect(s.listRequestTemplates(proxy: "p:443").count == 1)
        #expect(s.listRequestTemplates(proxy: "changed:3080", cluster: "prod").count == 1)
        #expect(s.listRequestTemplates().count == 2)
        s.markRequestTemplateUsed(t["id"].string!)
        #expect(ids(s.listRequestTemplates()) == [t["id"].string!, u["id"].string!])
        let m = s.upsertRequestTemplate(["id": t["id"], "resources": [["id": "x", "junk": 1]]])
        #expect(m["resources"] == [["id": "x", "name": "", "cluster": ""]] && m["cluster"] == "prod")
    }

    // MARK: S3

    @Test func s3TargetsRewriteTheRecordButKeepCreatedAt() {
        let a = s.upsertS3Target(["bucket": "logs"])
        #expect(a["id"].string?.hasPrefix("s3_") == true && a["name"] == "logs" && a["credentials"] == ["mode": "env"])
        #expect(a["defaultStorageClass"] == "STANDARD")
        let b = s.upsertS3Target(["id": a["id"], "bucket": "logs2", "pathStyle": true])
        #expect(b["createdAt"] == a["createdAt"] && b["name"] == "logs2" && s.listS3Targets().count == 1)
        s.deleteS3Target(a["id"].string!)
        #expect(s.listS3Targets().isEmpty)
    }

    // MARK: backup

    @Test func backupMergeAddsByIdAndReplaceOverwrites() throws {
        s.upsertSnippet(["command": "a"])
        let existing = s.listSnippets()[0]
        s["hiddenMacros"] = ["x"]
        let doc = try Backup.parse(Backup.envelope("settings", [
            "snippets": .array([existing, ["id": "new", "command": "b"], ["command": "noid"], nil]),
            "hiddenMacros": ["x", "y"], "settings": ["theme": "nord"], "defaultLayoutId": "l_1",
        ]).text())
        #expect(Backup.describe(doc)["counts"]["snippets"] == 4)
        let r = Backup.applyImport(s, doc)
        #expect(r["added"]["snippets"] == 2 && s.listSnippets().count == 3)
        #expect(s["hiddenMacros"] == ["x", "y"] && s.settings["theme"] == "nord" && s["defaultLayoutId"].isNull)
        Backup.applyImport(s, doc, mode: "replace")
        #expect(s.listSnippets().count == 4 && s["defaultLayoutId"] == "l_1")
        let all = Backup.exportAll(s)
        #expect(all["format"] == "serverlife.backup" && all["counts"]["snippets"] == 4 && all["data"]["history"].isNull)
        s.upsertMacro(["command": "m1"]); s.upsertMacro(["command": "m2"])
        let one = Backup.exportMacros(s, [s.listMacros()["macros"][0]["id"].string!])
        #expect(one["counts"]["macros"] == 1 && one["data"]["hiddenMacros"] == [])
        #expect(throws: AppError.self) { try Backup.parse(#"{"format":"serverlife.backup","version":"2","data":{}}"#) }
        #expect(throws: AppError.self) { try Backup.parse(#"{"format":"serverlife.backup","version":1}"#) }
    }
}
