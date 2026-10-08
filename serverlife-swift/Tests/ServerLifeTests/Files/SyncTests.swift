import Foundation
import Testing
@testable import ServerLife

/// Planning and applying a directory sync against a real sftp-server.
@Suite(.serialized) struct SyncTests {
    /// Two trees side by side; the "remote" one is reached over SFTP.
    private func trees() throws -> (root: String, local: String, remote: String) {
        let root = try scratchDir("sync")
        let local = root + "/local", remote = root + "/remote"
        try writeFile(local + "/same.txt", "same")
        try writeFile(remote + "/same.txt", "same")
        try writeFile(local + "/newer-here.txt", "local edit")
        try writeFile(remote + "/newer-here.txt", "old")
        try writeFile(local + "/newer-there.txt", "old")
        try writeFile(remote + "/newer-there.txt", "remote edit")
        try writeFile(local + "/only-here.txt", "x")
        try writeFile(remote + "/gone/deep/only-there.txt", "y")
        try writeFile(local + "/.DS_Store", "noise")
        try FileManager.default.createDirectory(atPath: local + "/empty-here", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: local + "/link", withDestinationPath: local + "/same.txt")
        let t0: Double = 1_700_000_000
        for p in ["/same.txt"] {
            Transfers.setLocalTimes(local + p, atime: t0, mtime: t0)
            Transfers.setLocalTimes(remote + p, atime: t0, mtime: t0)
        }
        Transfers.setLocalTimes(local + "/newer-here.txt", atime: t0, mtime: t0 + 100)
        Transfers.setLocalTimes(remote + "/newer-here.txt", atime: t0, mtime: t0)
        Transfers.setLocalTimes(local + "/newer-there.txt", atime: t0, mtime: t0)
        Transfers.setLocalTimes(remote + "/newer-there.txt", atime: t0, mtime: t0 + 100)
        return (root, local, remote)
    }

    @Test func planUpWithoutDelete() async throws {
        let t = try trees(); defer { cleanup(t.root) }
        let c = try await localSFTP(); defer { c.destroy() }
        let p = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, direction: "up"))
        let byRel = Dictionary(uniqueKeysWithValues: p.actions.map { ($0.rel, $0) })
        #expect(byRel["same.txt"]?.op == "same" && byRel["same.txt"]?.why == "same size and time")
        #expect(byRel["newer-here.txt"]?.op == "upload" && byRel["newer-here.txt"]?.overwritesNewer == false)
        #expect(byRel["newer-there.txt"]?.op == "upload" && byRel["newer-there.txt"]?.overwritesNewer == true,
                "uploading over something newer is flagged")
        #expect(byRel["only-here.txt"]?.op == "upload" && byRel["only-here.txt"]?.why == "not on the server")
        #expect(byRel["gone/deep/only-there.txt"]?.op == "skip" && byRel["gone/deep/only-there.txt"]?.why == "only on the server")
        #expect(byRel[".DS_Store"] == nil, "noise is never compared")
        #expect(p.summary.links == 1, "links are counted, never followed")
        #expect(p.summary.wouldDelete == 1 && p.summary.overwritesNewer == 1)
        #expect(p.summary.upload == 3 && p.summary.rmdirRemote == 0)
        #expect(p.dirsUp == ["empty-here"] && p.dirsDown.isEmpty)
        #expect(!p.summary.localMissing && !p.summary.remoteMissing)
    }

    @Test func planDownWithDeleteRemovesFoldersDeepestFirst() async throws {
        let t = try trees(); defer { cleanup(t.root) }
        let c = try await localSFTP(); defer { c.destroy() }
        let p = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, direction: "up", del: true))
        let rm = p.actions.filter { $0.op == "rmdirRemote" }.map(\.rel)
        #expect(rm == ["gone/deep", "gone"])
        #expect(p.actions.contains { $0.op == "deleteRemote" && $0.rel == "gone/deep/only-there.txt" })

        let both = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, direction: "both", del: true))
        #expect(!both.actions.contains { $0.op.hasPrefix("delete") || $0.op.hasPrefix("rmdir") }, "never deletes both ways")
        #expect(both.actions.first { $0.rel == "newer-there.txt" }?.op == "download")
        #expect(both.actions.first { $0.rel == "newer-here.txt" }?.op == "upload")

        let size = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, compare: "size"))
        #expect(size.actions.first { $0.rel == "newer-here.txt" }?.op == "upload", "different lengths")
        #expect(size.actions.first { $0.rel == "same.txt" }?.why == "same size")
        // An editor rewriting a file to the same length, with a new time.
        try writeFile(t.local + "/same.txt", "SAME")
        let sizeOnly = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, compare: "size"))
        #expect(sizeOnly.actions.first { $0.rel == "same.txt" }?.op == "same", "time ignored")
        let timeToo = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, compare: "both"))
        #expect(timeToo.actions.first { $0.rel == "same.txt" }?.op == "upload")

        let missing = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.root + "/nope"))
        #expect(missing.summary.remoteMissing)
    }

    @Test @MainActor func applyMovesFilesAndKeepsWhatWasUnticked() async throws {
        let t = try trees(); defer { cleanup(t.root) }
        let c = try await localSFTP(); defer { c.destroy() }
        let q = TransferQueue(getSftp: { c })
        let p = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, direction: "up", del: true))
        // Untick the remote file's deletion: its folders' removal goes too,
        // because a recursive RMDIR would take the file anyway.
        let kept = p.actions.filter { $0.doing && $0.op != "deleteRemote" }
        let r = await SyncPlanner.apply(p, kept, queue: q, sftp: c)
        #expect(r.uploads == 3 && r.removed == 0 && r.jobs.count == 1)
        let end = Date().addingTimeInterval(10)
        while q.jobs.first?.status != "done" && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(readData(t.remote + "/only-here.txt") == Data("x".utf8))
        #expect(readData(t.remote + "/newer-there.txt") == Data("old".utf8))
        #expect(LocalFS.isDir(t.remote + "/empty-here"), "an empty folder is created too")
        #expect(readData(t.remote + "/gone/deep/only-there.txt") != nil)

        // Running it again finds nothing to do: uploads carried their times.
        let again = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, direction: "up"))
        #expect(again.summary.upload == 0)
    }

    @Test @MainActor func emptinessIsRecheckedBeforeRmdir() async throws {
        let t = try trees(); defer { cleanup(t.root) }
        let c = try await localSFTP(); defer { c.destroy() }
        let q = TransferQueue(getSftp: { c })
        let p = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: t.local, remoteDir: t.remote, direction: "up", del: true))
        // Something arrives after the plan was made.
        try writeFile(t.remote + "/gone/late.txt", "late")
        let r = await SyncPlanner.apply(p, p.actions.filter { $0.op.hasPrefix("delete") || $0.op.hasPrefix("rmdir") }, queue: q, sftp: c)
        #expect(r.removed == 2, "the file and the now-empty deep folder")
        #expect(r.failures == ["gone: kept — still has 1 item(s) in it"])
        #expect(readData(t.remote + "/gone/late.txt") != nil)
    }

    @Test func itemsAndDescribe() {
        let p = SyncPlanner.Plan(localDir: "/l", remoteDir: "/r", direction: "up", compare: "both",
                                 actions: [.init(op: "upload", rel: "a/b.txt", size: 3, why: "not on the server"),
                                           .init(op: "same", rel: "c", size: 1, why: "same size and time")],
                                 dirsUp: ["empty"], dirsDown: [], summary: .init())
        let i = SyncPlanner.items(p, p.actions)
        #expect(i.uploads == [Transfers.Item(local: "/l/a/b.txt", remote: "/r/a/b.txt", size: 3)])
        #expect(i.upDirs == ["/r/a", "/r/empty"])
        let d = SyncPlanner.describe(p, limit: 1)
        #expect(d["actionCount"].int == 1 && d["actions"][0]["path"].string == "a/b.txt" && d["truncated"].bool == false)
    }

    @Test @MainActor func newNestedFoldersAreCreatedParentsFirst() async throws {
        let root = try scratchDir("nest"); defer { cleanup(root) }
        try writeFile(root + "/local/sub/inner/deep/f.txt", "f")
        try writeFile(root + "/local/sub/g.txt", "g")
        try FileManager.default.createDirectory(atPath: root + "/remote", withIntermediateDirectories: true)
        let c = try await localSFTP(); defer { c.destroy() }
        let q = TransferQueue(getSftp: { c })
        let p = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: root + "/local", remoteDir: root + "/remote"))
        let i = SyncPlanner.items(p, p.actions)
        #expect(i.upDirs == [root + "/remote/sub", root + "/remote/sub/inner", root + "/remote/sub/inner/deep"])
        _ = await SyncPlanner.apply(p, p.actions.filter(\.doing), queue: q, sftp: c)
        let end = Date().addingTimeInterval(10)
        while !["done", "error"].contains(q.jobs.first?.status ?? "") && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(q.jobs.first?.status == "done", "\(q.jobs.first?.error ?? "")")
        #expect(readData(root + "/remote/sub/inner/deep/f.txt") == Data("f".utf8))

        // And downwards.
        try writeFile(root + "/remote/x/y/z.txt", "z")
        let d = await SyncPlanner.plan(c, SyncPlanner.Request(localDir: root + "/local", remoteDir: root + "/remote", direction: "down"))
        #expect(SyncPlanner.items(d, d.actions).downDirs == [root + "/local/x", root + "/local/x/y"])
    }
}
