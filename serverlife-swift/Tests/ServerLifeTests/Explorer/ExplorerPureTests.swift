import Testing
import Foundation
@testable import ServerLife

private func xpEntry(_ name: String, dir: Bool = false, size: Int64 = 0, mtime: Double? = nil, mode: UInt32? = nil,
                     link: FileType? = nil) -> FileEntry {
    FileEntry(name: name, path: "/x/" + name, type: link != nil ? .symlink : dir ? .directory : .file, targetType: link,
              size: size, mode: mode, modeString: dir ? "drwxr-xr-x" : "-rw-r--r--", mtime: mtime)
}

@MainActor @Suite struct ExplorerPureTests {
    @Test func sortingIsCaseInsensitiveNumericAndFoldersFirst() {
        let list = [xpEntry("node-10"), xpEntry("Downloads", dir: true), xpEntry("node-2"), xpEntry("docs", dir: true),
                    xpEntry("a.txt")]
        #expect(XP.sortEntries(list).map(\.name) == ["docs", "Downloads", "a.txt", "node-2", "node-10"])
        // Folders mixed in when that is turned off.
        #expect(XP.sortEntries(list, foldersFirst: false).map(\.name) == ["a.txt", "docs", "Downloads", "node-2", "node-10"])
        // Reversed name order keeps folders first.
        #expect(XP.sortEntries(list, dir: -1).map(\.name) == ["Downloads", "docs", "node-10", "node-2", "a.txt"])
    }

    @Test func tiesBreakOnTheNameNotInTheSortsDirection() {
        let list = [xpEntry("b", size: 5), xpEntry("a", size: 5), xpEntry("c", size: 9)]
        #expect(XP.sortEntries(list, key: "size", dir: -1).map(\.name) == ["c", "a", "b"])
        #expect(XP.sortEntries(list, key: "size", dir: 1).map(\.name) == ["a", "b", "c"])
        let t = [xpEntry("y", mtime: 10), xpEntry("x", mtime: 10)]
        #expect(XP.sortEntries(t, key: "mtime", dir: -1).map(\.name) == ["x", "y"])
    }

    @Test func linkToADirectoryIsAFolder() {
        let l = xpEntry("lnk", link: .directory)
        #expect(XP.isDir(l))
        #expect(XP.fileIcon(l) == "\u{1F4C1}")
        #expect(XP.fileIcon(xpEntry("x", link: .file)) == "\u{1F517}")
        #expect(XP.fileIcon(xpEntry("run.sh", mode: 0o755)) == "\u{2699}")
        #expect(XP.fileIcon(xpEntry("photo.PNG")) == "\u{1F5BC}")
        #expect(XP.fileIcon(xpEntry("notes.md")) == "\u{1F4DD}")
        #expect(XP.fileIcon(xpEntry("id_rsa.pub")) == "\u{1F511}")
    }

    @Test func plainTextMatchesAnywhereAGlobIsAnchored() {
        let m = XP.matcher("log")!
        #expect(m("mylog.txt"))
        #expect(m("LOGS"))
        let g = XP.matcher("*.log")!
        #expect(g("app.log"))
        #expect(!g("mylog.txt"))
        #expect(!g("app.log.1"))
        let q = XP.matcher("id_?sa")!
        #expect(q("id_rsa"))
        #expect(XP.matcher("   ") == nil)
        // Regex characters in a glob are literal.
        #expect(XP.matcher("a+b*")!("a+bc"))
        #expect(!XP.matcher("a+b*")!("aab"))
    }

    @Test func permissionsReadInBothForms() {
        #expect(XP.permText(mode: 0o100755, modeString: "-rwxr-xr-x") == "-rwxr-xr-x  (755)")
        #expect(XP.permText(mode: 0o104755, modeString: "-rwsr-xr-x") == "-rwsr-xr-x  (4755)  · setuid")
        #expect(XP.permText(mode: 0o41777, modeString: "drwxrwxrwt") == "drwxrwxrwt  (1777)  · sticky")
        #expect(XP.octal(0o100644) == "644")
        #expect(XP.octal(0o7) == "007")
    }

    @Test func ownerTextPrefersNamesAndCollapsesTheSame() {
        #expect(XP.ownerText(owner: "root", group: "root", uid: 0, gid: 0) == "root")
        #expect(XP.ownerText(owner: "ubuntu", group: "adm", uid: 1, gid: 2) == "ubuntu:adm")
        #expect(XP.ownerText(owner: nil, group: nil, uid: 1001, gid: 1002) == "1001:1002")
        #expect(XP.ownerText(owner: nil, group: nil, uid: nil, gid: nil) == "")
    }

    @Test func theExplanationIsAboutThisEntry() {
        let d = XP.explainPermissions(mode: 0o1777, modeString: "drwxrwxrwt", owner: "root", group: "root", folder: true)
        #expect(d.lanes.map(\.bits) == ["rwx", "rwx", "rwt"])
        #expect(d.lines[0].text == "root can list what is in it, create, rename and delete things in it and enter it and reach what is inside.")
        #expect(d.notes.contains { $0.hasPrefix("The sticky bit is set") })
        #expect(d.notes.contains { $0.hasPrefix("The last group includes write") })
        #expect(d.octalNote.hasSuffix("and 777 is what this one has."))

        let f = XP.explainPermissions(mode: 0o4111, modeString: "---s--x--x", owner: "root", group: nil, folder: false)
        #expect(f.lines[1].text == "the owning group can run it as a program.")
        #expect(f.notes.contains("Setuid is set: this program runs with the privileges of its owner (root), not of whoever starts it."))
        #expect(f.notes.contains { $0.hasPrefix("It is executable but not readable") })

        let shut = XP.explainPermissions(mode: 0o600, modeString: "drw-------", owner: nil, group: nil, folder: true)
        #expect(shut.lines[2].text == "everyone else with an account on the machine cannot see inside it or enter it.")
        #expect(shut.notes.first?.hasPrefix("Nobody has the execute bit") == true)
    }

    @Test func permissionCommandsAreTheOnesShown() {
        let p = ["/srv/a b", "/srv/c"]
        #expect(XP.permissionCommands(paths: p, mode: "755", owner: "", group: "", recursive: false)
                == ["chmod 755 '/srv/a b' '/srv/c'"])
        #expect(XP.permissionCommands(paths: p, mode: "", owner: "www", group: "web", recursive: true)
                == ["chown -R www:web '/srv/a b' '/srv/c'"])
        #expect(XP.permissionCommands(paths: ["/x"], mode: " ", owner: "", group: "adm", recursive: false) == ["chgrp adm '/x'"])
        #expect(XP.permissionCommands(paths: ["/x"], mode: "", owner: "", group: "", recursive: true).isEmpty)
        #expect(XP.permissionScript(["chmod 1 x", "chgrp a x"]) == "chmod 1 x && echo __ok__; chgrp a x && echo __ok__")
    }

    @Test func comparingTwoLists() {
        let a = xpEntry("f", size: 10, mtime: 100_000)
        #expect(XP.compareVerdict(a, nil) == "only")
        #expect(XP.compareVerdict(a, xpEntry("f", size: 10, mtime: 101_500)) == "same")
        #expect(XP.compareVerdict(a, xpEntry("f", size: 10, mtime: 90_000)) == "newer")
        #expect(XP.compareVerdict(a, xpEntry("f", size: 11, mtime: 110_000)) == "older")
        #expect(XP.compareVerdict(a, xpEntry("f", size: 11, mtime: 100_000)) == "differs")
        #expect(XP.compareVerdict(xpEntry("d", dir: true), xpEntry("d", size: 5)) == "same")
        let m = XP.compareMap([a, xpEntry("g")], [xpEntry("f", size: 10, mtime: 100_000)])
        #expect(m == ["f": "same", "g": "only"])
    }

    @Test func pathsAndNames() {
        #expect(XP.parentLocal("/Users/me/x/") == "/Users/me")
        #expect(XP.parentLocal("/Users") == "/")
        #expect(XP.parentLocal("/") == "/")
        #expect(XP.shortPath("/home/me/projects/thing", home: "/home/me") == "~/projects/thing")
        #expect(XP.shortPath("/a/very/long/path/that/goes/on/and/on/forever/x", max: 20, home: "") == "…on/and/on/forever/x")
        #expect(XP.appName("/Applications/Visual Studio Code.app") == "Visual Studio Code")
        #expect(XP.builtinFavoriteId(kind: "host", path: "~/Desktop") == "builtin-host-Desktop")
        #expect(XP.builtinFavoriteId(kind: "local", path: "/var/log") == "builtin-local-var-log")
        #expect(XP.builtinFavoriteId(kind: "host", path: "~") == "builtin-host-")
        #expect(XP.builtinLabel("~") == "Home")
        #expect(XP.builtinLabel("/etc") == "etc")
    }

    @Test func parseKvIgnoresMalformedLines() {
        let d = XP.parseKv("kind=directory\nsize=4096\nnonsense\n=x\nfs=/dev/sda1 12% used, 9K free\n")
        #expect(d == ["kind": "directory", "size": "4096", "fs": "/dev/sda1 12% used, 9K free"])
        #expect(XP.remoteInfoCommand("/a b").contains("stat -c 'kind=%F"))
        #expect(XP.remoteInfoCommand("/a b").contains("'/a b'"))
    }

    @Test func signatureNoticesRealChangesOnly() {
        let a = [xpEntry("x", size: 1, mtime: 5), xpEntry("y")]
        #expect(XP.signature(a) == XP.signature(a.reversed()))
        #expect(XP.signature(a) != XP.signature([xpEntry("x", size: 2, mtime: 5), xpEntry("y")]))
    }

    @Test func keepingAnythingInsideAFolderKeepsTheFolder() {
        let acts = [
            SyncPlanner.Action(op: "rmdirRemote", rel: "old", size: 0, why: "", dir: true),
            SyncPlanner.Action(op: "deleteRemote", rel: "old/a.txt", size: 1, why: ""),
            SyncPlanner.Action(op: "rmdirRemote", rel: "older", size: 0, why: "", dir: true),
        ]
        #expect(XP.syncExcludesFor(acts[1], in: acts) == ["oldrmdirRemote"])
        #expect(XP.syncExcludesFor(acts[0], in: acts).isEmpty)
    }

    /// tests/rsync.test.mjs — starred folders are offered per side, and only folders.
    @Test func starredFoldersPerSideAndOnlyFolders() {
        let favs: [JSON] = [
            ["path": "/Users/me/site", "scope": "local", "kind": "dir"],
            ["path": "/Users/me/notes.md", "scope": "local", "kind": "file"],
            ["path": "/var/log", "scope": "hosts", "kind": "dir", "label": "logs"],
            ["path": "/srv/app", "scope": "uuid:abc", "kind": "dir"],
        ]
        #expect(XPFavoriteStore.starredFolders(local: true, favorites: favs).map(\.path) == ["/Users/me/site"])
        #expect(XPFavoriteStore.starredFolders(local: false, favorites: favs).map(\.label) == ["logs", "/srv/app"])
    }

    @Test func searchNotesSayWhyTheyStopped() {
        var o = FindFiles.Outcome(results: [], scanned: 12, truncated: false, stopped: "time", elapsedMs: 6200, where: "local")
        o.results = [FindFiles.Hit(path: "/a", name: "a", type: .file)]
        #expect(XPSearch.note(o) == "1 result — stopped after 6s; narrow the name or lower the depth  ·  12 entries looked at")
        o.stopped = nil; o.truncated = true; o.scanned = nil
        #expect(XPSearch.note(o) == "1 result — stopped at the result cap, so narrow it if the one you want is missing")
    }
}

/// The model, against this machine's filesystem.
@MainActor @Suite struct ExplorerModelTests {
    func scratch() throws -> String {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("sl-xp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: base + "/sub/deeper", withIntermediateDirectories: true)
        for f in ["a.log", "b.txt", ".hidden", "sub/inner.log"] { FileManager.default.createFile(atPath: base + "/" + f, contents: Data("x".utf8)) }
        return (base as NSString).resolvingSymlinksInPath
    }

    @Test func navigatesFiltersExpandsAndMoves() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ex = ExplorerModel(source: .local)
        defer { ex.destroy() }
        try await ex.navigate(dir)
        #expect(ex.view.path == dir)
        let shown = ex.flat().map(\.name)
        #expect(shown.contains("sub") && shown.contains("a.log"))

        // A filter that matches only inside an expanded folder keeps that folder.
        let sub = ex.view.entries.first { $0.name == "sub" }!
        await ex.toggleExpand(sub)
        ex.filterChanged("inner*")
        #expect(ex.flat().map(\.name) == ["sub", "inner.log"])
        ex.clearFilter()

        // Arrow keys from nothing land on the first row, then step.
        ex.moveSelection(1)
        #expect(ex.selected().map(\.name) == ["sub"])
        ex.moveSelection(1)
        #expect(ex.selected().map(\.name) == ["deeper"])

        // A move into a folder is a rename; a folder cannot go inside itself.
        let a = ex.view.entries.first { $0.name == "a.log" }!
        await ex.moveInto([a], sub.path)
        #expect(FileManager.default.fileExists(atPath: dir + "/sub/a.log"))
        await ex.moveInto([sub], sub.path + "/deeper")
        #expect(FileManager.default.fileExists(atPath: dir + "/sub"))

        // History goes back.
        try await ex.navigate(sub.path)
        await ex.historyGo(-1)
        #expect(ex.view.path == dir)
        await ex.goParent()
        #expect(ex.view.path == XP.parentLocal(dir))
    }

    @Test func backgroundRefreshKeepsTheSelection() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ex = ExplorerModel(source: .local)
        defer { ex.destroy() }
        try await ex.navigate(dir)
        ex.view.selection = [dir + "/b.txt"]
        FileManager.default.createFile(atPath: dir + "/new.txt", contents: Data())
        await ex.autoRefresh()
        #expect(ex.view.entries.contains { $0.name == "new.txt" })
        #expect(ex.view.selection == [dir + "/b.txt"])
    }
}
