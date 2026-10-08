import Foundation
import Testing
@testable import ServerLife

@Suite struct LocalFSTests {
    @Test func listingInfoAndTreeSize() async throws {
        let dir = try scratchDir("local"); defer { cleanup(dir) }
        try writeFile(dir + "/a.txt", "hello")
        try writeFile(dir + "/sub/b.txt", "12345678")
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/sub")
        try FileManager.default.createSymbolicLink(atPath: dir + "/broken", withDestinationPath: dir + "/nope")
        chmod(dir + "/a.txt", 0o640)

        let l = try await LocalFS.listing(dir)
        #expect(l.path == dir)
        let by = Dictionary(uniqueKeysWithValues: l.entries.map { ($0.name, $0) })
        #expect(by["a.txt"]?.type == .file && by["a.txt"]?.modeString == "-rw-r-----" && by["a.txt"]?.mode == 0o640)
        #expect(by["a.txt"]?.owner == NSUserName())
        #expect(by["sub"]?.type == .directory && by["sub"]?.modeString.hasPrefix("d") == true)
        #expect(by["link"]?.type == .symlink && by["link"]?.targetType == .directory && by["link"]?.modeString.hasPrefix("l") == true)
        #expect(by["broken"]?.targetType == .broken)

        let info = try await LocalFS.info(dir)
        #expect(info.type == .directory && info.files == 3 && info.dirs == 1)
        let linfo = try await LocalFS.info(dir + "/link")
        #expect(linfo.type == .symlink && linfo.target == dir + "/sub")

        let t = await LocalFS.treeSize(dir)
        #expect(t == LocalFS.TreeSize(bytes: 13, files: 4, dirs: 1, truncated: false), "links are counted, never followed")
        #expect(await LocalFS.treeSize(dir, maxEntries: 1).truncated)
    }

    @Test func changingThings() async throws {
        let dir = try scratchDir("lchange"); defer { cleanup(dir) }
        try LocalFS.ensureDir(dir + "/x/y/z")
        try LocalFS.ensureDir(dir + "/x/y/z")   // already there: fine
        try writeFile(dir + "/x/y/z/f", "f")
        try LocalFS.rename(dir + "/x", dir + "/w")
        #expect(LocalFS.isDir(dir + "/w/y/z"))
        try FileManager.default.createSymbolicLink(atPath: dir + "/ln", withDestinationPath: dir + "/w")
        try LocalFS.remove([dir + "/ln"])
        #expect(LocalFS.isDir(dir + "/w"), "removing a link to a folder leaves the folder")
        try LocalFS.remove([dir + "/w"])
        #expect(!FileManager.default.fileExists(atPath: dir + "/w"))
        #expect(LocalFS.parentOf("/") == "/" && LocalFS.parentOf("/a/b") == "/a")
        #expect(throws: AppError.self) { try LocalFS.rename(dir + "/missing", dir + "/m2") }
    }

    @Test func textForTheEditor() async throws {
        let dir = try scratchDir("ltext"); defer { cleanup(dir) }
        try LocalFS.writeText(dir + "/t.txt", "héllo\n")
        #expect(try await LocalFS.readText(dir + "/t.txt").text == "héllo\n")
        try Data([0x7f, 0x45, 0x4c, 0x46, 0, 1]).write(to: URL(fileURLWithPath: dir + "/bin"))
        await #expect { try await LocalFS.readText(dir + "/bin") } throws: { errorText($0) == "This looks like a binary file, not text." }
        try Data(count: 3 * 1024 * 1024).write(to: URL(fileURLWithPath: dir + "/big"))
        await #expect { try await LocalFS.readText(dir + "/big") } throws: {
            errorText($0) == "3.0 MB is too large to edit here — the limit is 2.0 MB. Open it with an application instead."
        }
        await #expect { try await LocalFS.readText(dir) } throws: { errorText($0) == "That is not a file." }
    }

    @Test func placesAndStars() {
        let s = LocalFS.shortcuts()
        #expect(s.first == LocalFS.Place(name: "Home", path: NSHomeDirectory()))
        #expect(s.contains { $0.name == "Root" && $0.path == "/" })
        let e = LocalFS.existingDirs(["~", "  ", "/definitely/not/here", "/tmp"])
        #expect(e.map(\.given) == ["~", "/tmp"] && e[0].path == NSHomeDirectory())
    }

    @Test func fileSourceProtocolOverLocal() async throws {
        let dir = try scratchDir("lsrc"); defer { cleanup(dir) }
        let src: FileSource = LocalFileSource.shared
        try await src.mkdir(dir + "/n")
        try await src.writeText(dir + "/n/f.txt", "abc")
        #expect(try await src.readText(dir + "/n/f.txt") == "abc")
        try await src.rename(dir + "/n/f.txt", to: dir + "/n/g.txt")
        #expect(try await src.stat(dir + "/n/g.txt").size == 3)
        try await src.chmod(dir + "/n/g.txt", mode: 0o600)
        #expect(try await src.list(dir + "/n").entries.map(\.modeString) == ["-rw-------"])
        try await src.remove([try await src.stat(dir + "/n")])
        #expect(!FileManager.default.fileExists(atPath: dir + "/n"))
        #expect(src.join("/a", "b") == "/a/b" && src.parent(of: "/a/b") == "/a")
    }
}

/// The service end to end, with the connection layer replaced by a local
/// sftp-server: listings, edits, watches, cross-server copies and the
/// download history's bookkeeping.
@Suite(.serialized) @MainActor struct FilesServiceTests {
    static let a = "test-conn-a", b = "test-conn-b"

    private func install() {
        // Never the real store: a recorded download would be saved to disk.
        FilesService.shared.onJobFinished = { _ in }
        FilesBridge.openChannel = { _ in try ProcessChannel("/usr/libexec/sftp-server", []) }
        FilesBridge.connection = { id in
            guard id == Self.a || id == Self.b else { return nil }
            var h = ServerLife.Host(type: "ssh", id: "ssh:" + id, name: id)
            h.alias = id
            return FilesConn(id: id, label: id == Self.a ? "web-1" : "web-2", type: "ssh", transport: "mux",
                             target: "ubuntu@" + id, host: h, login: "ubuntu", homeDir: nil)
        }
    }

    private func waitFor(_ timeout: Double = 30, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func listingsAndEdits() async throws {
        install()
        defer { FilesService.shared.connectionClosed(Self.a) }
        let dir = try scratchDir("svc"); defer { cleanup(dir) }
        try writeFile(dir + "/d/f.txt", "one")
        try FileManager.default.createSymbolicLink(atPath: dir + "/d/l", withDestinationPath: dir + "/d")
        let svc = FilesService.shared
        let home = try await svc.home(Self.a)
        #expect(home == realPath(FileManager.default.currentDirectoryPath))
        let l = try await svc.list(Self.a, dir + "/d/../d")
        #expect(l.path == dir + "/d", "always an absolute, resolved path")
        #expect(l.entries.first { $0.name == "l" }?.targetType == .directory)

        try await svc.writeFile(Self.a, dir + "/d/f.txt", "two")
        #expect(try await svc.readFile(Self.a, dir + "/d/f.txt") == "two")
        try await svc.mkdir(Self.a, dir + "/d/n")
        try await svc.rename(Self.a, dir + "/d/n", dir + "/d/m")
        try await svc.remove(Self.a, try await svc.list(Self.a, dir + "/d").entries.filter { $0.name == "m" || $0.name == "l" })
        #expect(LocalFS.isDir(dir + "/d"), "a link to a folder is removed as a link")
        #expect(!LocalFS.isDir(dir + "/d/m"))

        // The same through the FileSource seam the explorer uses.
        let src: FileSource = SFTPFileSource(connId: Self.a)
        #expect(src.id == "sftp:" + Self.a && src.capabilities.contains(.transfers))
        #expect(try await src.stat(dir + "/d/f.txt").size == 3)
    }

    @Test func uploadsAndDownloadsThroughTheQueue() async throws {
        install()
        defer { FilesService.shared.connectionClosed(Self.a) }
        let dir = try scratchDir("svcq"); defer { cleanup(dir) }
        try writeFile(dir + "/local/site/index.html", "<h1>")
        try FileManager.default.createDirectory(atPath: dir + "/remote", withIntermediateDirectories: true)
        let svc = FilesService.shared
        let up = try await svc.upload(Self.a, localPaths: [dir + "/local/site"], remoteDir: dir + "/remote")
        let q = svc.queue(Self.a)
        await waitFor { q.jobs.first { $0.id == up }?.status == "done" }
        #expect(q.jobs.first { $0.id == up }?.label == "site → \(dir)/remote")
        #expect(readData(dir + "/remote/site/index.html") == Data("<h1>".utf8))

        let entry = try await svc.list(Self.a, dir + "/remote").entries[0]
        let down = try await svc.download(Self.a, entries: [entry], localDir: dir + "/back")
        await waitFor { q.jobs.first { $0.id == down }?.status == "done" }
        #expect(readData(dir + "/back/site/index.html") == Data("<h1>".utf8))
    }

    @Test func crossServerCopyRelaysThroughThisMachine() async throws {
        install()
        defer { FilesService.shared.connectionClosed(Self.a); FilesService.shared.connectionClosed(Self.b) }
        let dir = try scratchDir("cross"); defer { cleanup(dir) }
        try writeFile(dir + "/src/app/conf/a.yaml", "a: 1")
        try writeFile(dir + "/src/single.txt", "s")
        try FileManager.default.createDirectory(atPath: dir + "/dest", withIntermediateDirectories: true)
        let svc = FilesService.shared
        let route = try svc.crossPlan(Self.a, Self.b)
        #expect(route.mode == "relay")
        #expect(route.reason == "At least one endpoint is a plain SSH host. Files will be downloaded to this machine and uploaded to the destination.")
        let entries = try await svc.list(Self.a, dir + "/src").entries
        let started = try await svc.cross(Self.a, entries: entries, to: Self.b, destDir: dir + "/dest")
        #expect(started.fileCount == 2 && started.totalBytes == 5 && started.mode == "relay")
        let q = svc.queue(Self.b)
        await waitFor { q.jobs.first { $0.id == started.jobId }?.status == "done" }
        let v = q.jobs.first { $0.id == started.jobId }
        #expect(v?.status == "done" && v?.label == "web-1: 2 items → web-2:\(dir)/dest")
        #expect(readData(dir + "/dest/app/conf/a.yaml") == Data("a: 1".utf8))
        #expect(readData(dir + "/dest/single.txt") == Data("s".utf8))
        await #expect(throws: AppError.self) { try await svc.cross(Self.a, entries: entries, to: Self.a, destDir: "/") }
    }

    @Test func routes() {
        var n1 = ServerLife.Host(type: "teleport", id: "t1", name: "n1"); n1.proxy = "p:443"; n1.cluster = "c1"; n1.hostname = "n1"
        var n2 = n1; n2.name = "n2"; n2.hostname = "n2"
        var n3 = n1; n3.cluster = "leaf"
        func conn(_ h: ServerLife.Host, _ type: String = "teleport") -> FilesConn {
            FilesConn(id: h.name, label: h.name, type: type, transport: "mux", target: "root@" + h.name, host: h, login: "root")
        }
        let direct = CrossTransfer.planRoute(conn(n1), conn(n2))
        #expect(direct == .init(mode: "direct", reason: "Both nodes are on c1; tsh will copy them server-to-server."))
        #expect(CrossTransfer.planRoute(conn(n1), conn(n3)).reason.hasPrefix("The nodes are on different Teleport clusters."))
        #expect(CrossTransfer.scpTarget(conn(n2), "/srv/") == "root@n2:/srv/")
    }

    /// Every upload event for one watch, as it happens.
    final class EventLog {
        var events: [Watches.Event] = []
        func rels() -> [String] { events.map(\.rel) }
    }

    private func record(_ id: @escaping () -> String?) -> EventLog {
        let log = EventLog()
        Watches.shared.onEvent = [{ wid, e in if wid == id() { log.events.append(e) } }]
        return log
    }

    /// Do `change` until the watch reports an event satisfying `done`.
    ///
    /// FSEvents gives no "now watching" signal and, under load, may not report
    /// a change made in the stream's first moments, so the change is repeated
    /// (each time with fresh content) until the watch has seen one. Waits are
    /// on the watch's own events, never on a fixed sleep.
    private func repeatUntil(_ log: EventLog, timeout: Double = 60, change: (Int) throws -> Void,
                             done: (Watches.Event) -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < end {
            let before = log.events.count
            try change(attempt)
            attempt += 1
            await waitFor(5) { log.events.dropFirst(before).contains(where: done) }
            if log.events.contains(where: done) { return }
        }
        Issue.record("the watch never reported the change")
    }

    @Test func watchingAFolderUploadsSavesAndIgnoresNoise() async throws {
        install()
        defer { Watches.shared.onEvent = []; Watches.shared.stopAll(); FilesService.shared.connectionClosed(Self.a) }
        let dir = try scratchDir("watch"); defer { cleanup(dir) }
        try FileManager.default.createDirectory(atPath: dir + "/local", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/remote", withIntermediateDirectories: true)
        var wid: String?
        let log = record { wid }
        let w = try Watches.shared.watchDir(connId: Self.a, localDir: dir + "/local", remoteDir: dir + "/remote")
        wid = w.id
        #expect(w.kind == "dir" && w.label == "web-1")

        // Noise first, then the real file: by the time the real file's upload
        // is reported, the noise has had its events too.
        var last = ""
        try await repeatUntil(log, change: { n in
            try writeFile(dir + "/local/.git/HEAD", "ref \(n)")
            try writeFile(dir + "/local/x.swp", "scratch \(n)")
            last = "v\(n)"
            try writeFile(dir + "/local/new/deep.txt", last)
        }, done: { $0.ok && $0.rel == "new/deep.txt" })
        await waitFor(30) { readData(dir + "/remote/new/deep.txt") == Data(last.utf8) }
        #expect(readData(dir + "/remote/new/deep.txt") == Data(last.utf8))
        #expect(log.rels().allSatisfy { $0 == "new/deep.txt" }, "noise is never uploaded: \(log.rels())")
        #expect(!FileManager.default.fileExists(atPath: dir + "/remote/.git"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/remote/x.swp"))
        #expect((Watches.shared.list.first { $0.id == w.id }?.uploads ?? 0) >= 1)

        // Deleting here never deletes there. A later file's upload proves the
        // deletion's events have been seen and ignored.
        try FileManager.default.removeItem(atPath: dir + "/local/new/deep.txt")
        try await repeatUntil(log, change: { n in try writeFile(dir + "/local/after.txt", "after \(n)") },
                              done: { $0.ok && $0.rel == "after.txt" })
        #expect(readData(dir + "/remote/new/deep.txt") != nil)
        FilesService.shared.connectionClosed(Self.a)
        #expect(!Watches.shared.list.contains { $0.id == w.id }, "a watch goes with its session")
    }

    @Test func editInMyEditorUploadsEverySaveAndCleansUp() async throws {
        install()
        var opened: [String] = []
        Watches.shared.openHook = { opened.append($0) }
        defer {
            Watches.shared.openHook = nil; Watches.shared.onEvent = []
            Watches.shared.stopAll(); FilesService.shared.connectionClosed(Self.a)
        }
        let dir = try scratchDir("edit"); defer { cleanup(dir) }
        try writeFile(dir + "/config.yaml", "a: 1\n")
        var wid: String?
        let log = record { wid }
        let v = try await Watches.shared.editRemote(connId: Self.a, remotePath: dir + "/config.yaml")
        wid = v.id
        let local = try #require(v.localPath)
        #expect(opened == [local] && local.hasSuffix("/config.yaml"))
        #expect(readData(local) == Data("a: 1\n".utf8))

        // An atomic save: write a sibling, rename it over the file.
        var last = ""
        try await repeatUntil(log, change: { n in
            last = "a: \(n + 2)\n"
            try Data(last.utf8).write(to: URL(fileURLWithPath: local), options: .atomic)
        }, done: { $0.ok })
        await waitFor(30) { readData(dir + "/config.yaml") == Data(last.utf8) }
        #expect(readData(dir + "/config.yaml") == Data(last.utf8))
        #expect(log.events.allSatisfy(\.ok) && log.rels().allSatisfy { $0 == "config.yaml" })
        #expect((Watches.shared.list.first { $0.id == v.id }?.uploads ?? 0) >= 1)
        Watches.shared.stop(v.id)
        #expect(!FileManager.default.fileExists(atPath: v.localDir), "the temporary copy goes with the watch")
    }

    @Test func downloadHistoryRemembersFoldersAndLooseFiles() {
        let job = FinishedTransfer(kind: "download", label: "x", items: [
            Transfers.Item(local: "/dl/site/index.html", remote: "/srv/site/index.html", size: 10),
            Transfers.Item(local: "/dl/site/css/a.css", remote: "/srv/site/css/a.css", size: 5),
            Transfers.Item(local: "/dl/notes.txt", remote: "/home/u/notes.txt", size: 3),
        ], dirs: ["/dl/site", "/dl/site/css"], roots: ["/srv/site", "/home/u/notes.txt"], bytes: 18, endedAt: 0, from: "web-1")
        let rows = DownloadHistory.plan(job)
        #expect(rows == [
            .init(localPath: "/dl/site", name: "site", source: "/srv/site", kind: "folder", bytes: 15, files: 2),
            .init(localPath: "/dl/notes.txt", name: "notes.txt", source: "/home/u/notes.txt", kind: "file", bytes: 3, files: 1),
        ])
        var up = job; up.kind = "upload"
        #expect(DownloadHistory.plan(up).isEmpty, "an upload leaves nothing here to find")
        #expect(DownloadHistory.check(["/", "/definitely/not"]) == ["/": true, "/definitely/not": false])
    }
}

@Suite struct FilesWordingTests {
    @Test func nodeStyleErrors() throws {
        let dir = try scratchDir("words"); defer { cleanup(dir) }
        try writeFile(dir + "/a", "a")
        #expect { try LocalFS.rename(dir + "/a", dir + "/no/b") } throws: {
            errorText($0) == "ENOENT: no such file or directory, rename '\(dir)/a' -> '\(dir)/no/b'"
        }
        #expect { _ = try LocalFS.lstatOrThrow(dir + "/x") } throws: {
            errorText($0) == "ENOENT: no such file or directory, lstat '\(dir)/x'"
        }
    }

    @Test func transportExitMessages() {
        #expect(SFTPClient.exitMessage("sftp-server not found on this host", status: 127)
                == "sftp transport exited (127): sftp-server not found on this host")
        #expect(SFTPClient.exitMessage("exited with code 255", status: nil) == "sftp transport exited (255)")
        #expect(SFTPClient.exitMessage(nil, status: nil) == "sftp transport exited (0)")
        #expect(SFTPClient.exitMessage("Permission denied", status: nil) == "sftp transport exited: Permission denied")
    }
}
