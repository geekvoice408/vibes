import Foundation
import Testing
@testable import ServerLife

/// Live: SFTP through FilesService / SFTPFileSource, the transfer queue,
/// sync, watches, find and rsync — all inside ~/serverlife-swift-test.
@Suite("Live files", .serialized, liveEnabled)
@MainActor
struct LiveFilesTests {

    @Test("SFTPFileSource: list, stat, mkdir, rename, chmod, read/write, remove; odd names")
    func sftpSource() async throws {
        let c = try await Live.connect()
        let dir = try await Live.scratch(c, "sftp")
        let src = SFTPFileSource(connId: c.id)
        #expect(src.label == c.label)

        let home = try await src.home()
        #expect(home == c.homeDir)
        let lh = try await src.list(nil)
        #expect(lh.path == home)
        #expect(lh.entries.contains { $0.name == LiveEnv.scratchName && $0.type == .directory })
        let viaTilde = try await src.list("~")
        #expect(viaTilde.path == home)

        let sub = src.join(dir, "a folder ü ✓")
        try await src.mkdir(sub)
        do { try await src.mkdir(sub); Issue.record("mkdir of an existing folder succeeded") }
        catch { Live.say("mkdir existing → \(errorText(error))") }

        let file = src.join(sub, "héllo wörld — 1.txt")
        let body = "line one\nzwei ✓\n"
        try await src.writeText(file, body)
        #expect(try await src.readText(file) == body)
        let st = try await src.stat(file)
        #expect(st.type == .file)
        #expect(st.size == Int64(body.utf8.count))
        #expect(st.name == "héllo wörld — 1.txt")
        #expect(st.path == file)

        let listing = try await src.list(sub)
        #expect(listing.path == sub)
        #expect(listing.entries.map(\.name) == ["héllo wörld — 1.txt"])
        let e = listing.entries[0]
        #expect(e.owner?.isEmpty == false)
        #expect(e.modeString.hasPrefix("-rw"))
        #expect((e.mtime ?? 0) > 1_600_000_000_000)

        try await src.chmod(file, mode: 0o640)
        #expect(((try await src.stat(file)).mode ?? 0) & 0o777 == 0o640)
        // The same file named in a shell command (precomposed é/ö in the path).
        let viaShell = try await c.execReport("stat -c %a \(shellQuote(file))")
        Live.say("exec with a precomposed non-ASCII path: code=\(viaShell.code) err=\(viaShell.error ?? "-")")
        #expect(viaShell.stdout.trimmed == "640", "a non-ASCII path in an exec command does not reach the host unchanged")

        let renamed = src.join(sub, "renamed (2).txt")
        try await src.rename(file, to: renamed)
        #expect(try await src.readText(renamed) == body)
        do { _ = try await src.stat(file); Issue.record("old name still there") }
        catch { #expect(errorText(error).contains("No such file")) ; Live.say("stat missing → \(errorText(error))") }

        // symlink is resolved in listings
        // (a glob, so the command itself stays ASCII)
        _ = try await c.exec("cd \(shellQuote(dir)) && ln -s \"$PWD\"/a\\ folder* 'link to folder'")
        let withLink = try await src.list(dir)
        let link = withLink.entries.first { $0.name == "link to folder" }
        #expect(link?.type == .symlink)
        #expect(link?.targetType == .directory)
        #expect(link?.isDirectoryLike == true)

        // binary refusal / missing
        _ = try await c.exec("head -c 4096 /dev/urandom > \(shellQuote(dir + "/bin.dat"))")
        // (sftp:readFile in the original does not refuse binary either — only size)
        do { _ = try await src.readText(dir + "/bin.dat"); Live.say("readText binary → read (as the original)") }
        catch { Live.say("readText binary → \(errorText(error))") }
        do { _ = try await src.readText(dir + "/nope.txt"); Issue.record("missing file read") }
        catch { Live.say("readText missing → \(errorText(error))") ; #expect(errorText(error).contains("nope.txt")) }
        do { _ = try await src.readText(dir + "/bin.dat", maxBytes: 100); Issue.record("too-large file read") }
        catch { Live.say("readText over maxBytes → \(errorText(error))") }

        // recursive delete of a tree (and the link itself, not its target)
        for d in ["/deep", "/deep/er", "/deep/er/still"] { try await src.mkdir(sub + d) }
        try await src.writeText(sub + "/deep/a b.txt", "")
        try await src.writeText(sub + "/deep/er/still/z", "z")
        try await src.remove([try #require(link)])
        #expect((try? await src.stat(sub))?.type == .directory, "removing a link removed its target")
        let subEntry = try #require((try await src.list(dir)).entries.first { $0.name == "a folder ü ✓" })
        try await src.remove([subEntry])
        let after = try await src.list(dir)
        #expect(!after.entries.contains { $0.name == "a folder ü ✓" })

        // search capability through the source
        #expect(src.capabilities.contains(.search))

        _ = try await c.exec("rm -rf \(shellQuote(Live.guardScratch(dir)))")
        await Live.teardown(c)
    }

    @Test("transfers: multi-MB upload/download with bytes and mtime; folders")
    func transfersBasic() async throws {
        let c = try await Live.connect()
        let dir = try await Live.scratch(c, "xfer")
        let local = try LiveLocal.dir("xfer")
        defer { LiveLocal.remove(local) }
        let svc = FilesService.shared
        let q = svc.queue(c.id)
        q.setLimit(0)

        let big = local + "/big file u.bin"
        try LiveLocal.write(big, LiveLocal.random(6 * 1024 * 1024 + 123))
        LiveLocal.setMtime(big, 1_600_000_000)
        chmod(big, 0o640)
        let t0 = Date()
        let up = try await svc.upload(c.id, localPaths: [big], remoteDir: dir)
        let upv = await Live.finish(q, up)
        let secs = Date().timeIntervalSince(t0)
        Live.say("upload 6MB: \(upv?.status ?? "?") in \(String(format: "%.1f", secs))s error=\(upv?.error ?? "-")")
        #expect(upv?.status == "done")
        #expect(upv?.doneBytes == upv?.totalBytes)
        #expect(upv?.label == "big file u.bin → \(dir)")
        let rbig = dir + "/big file u.bin"
        #expect(try await Live.remoteSha(c, rbig) == LiveLocal.sha(big))
        #expect(try await Live.remoteMtime(c, rbig) == 1_600_000_000)
        #expect((try await c.exec("stat -c %a \(shellQuote(rbig))")).trimmed == "640")

        // and back
        let back = try LiveLocal.dir("back")
        defer { LiveLocal.remove(back) }
        _ = try await c.exec("touch -d @1500000000 \(shellQuote(rbig))")
        let entry = try await SFTPFileSource(connId: c.id).stat(rbig)
        let down = try await svc.download(c.id, entries: [entry], localDir: back)
        let dv = await Live.finish(q, down)
        #expect(dv?.status == "done")
        #expect(LiveLocal.sha(back + "/big file u.bin") == LiveLocal.sha(big))
        #expect(LiveLocal.mtime(back + "/big file u.bin") == 1_500_000_000)

        // folders both ways
        let tree = local + "/tree"
        try LiveLocal.write(tree + "/a.txt", "A")
        try LiveLocal.write(tree + "/sub dir/b.txt", "BB")
        try LiveLocal.write(tree + "/sub dir/deeper/c.bin", LiveLocal.random(70_000))
        try FileManager.default.createDirectory(atPath: tree + "/empty", withIntermediateDirectories: true)
        let fu = try await svc.upload(c.id, localPaths: [tree], remoteDir: dir)
        let fuv = await Live.finish(q, fu)
        #expect(fuv?.status == "done")
        #expect(fuv?.fileCount == 3)
        let listing = (try await c.exec("cd \(shellQuote(dir + "/tree")) && find . | sort")).trimmed
        Live.say("uploaded tree: \(listing.replacingOccurrences(of: "\n", with: " | "))")
        #expect(listing.contains("./empty"))
        #expect(listing.contains("./sub dir/deeper/c.bin"))
        #expect(try await Live.remoteSha(c, dir + "/tree/sub dir/deeper/c.bin") == LiveLocal.sha(tree + "/sub dir/deeper/c.bin"))

        let rtree = try await SFTPFileSource(connId: c.id).stat(dir + "/tree")
        #expect(rtree.type == .directory)
        let fd = try await svc.download(c.id, entries: [rtree], localDir: back)
        let fdv = await Live.finish(q, fd)
        #expect(fdv?.status == "done")
        #expect(LiveLocal.sha(back + "/tree/sub dir/deeper/c.bin") == LiveLocal.sha(tree + "/sub dir/deeper/c.bin"))
        #expect(FileManager.default.fileExists(atPath: back + "/tree/empty"))
        #expect((try? String(contentsOfFile: back + "/tree/sub dir/b.txt", encoding: .utf8)) == "BB")

        q.clearFinished()
        #expect(q.jobs.isEmpty)
        _ = try await c.exec("rm -rf \(shellQuote(Live.guardScratch(dir)))")
        await Live.teardown(c)
    }

    @Test("transfers: speed limit, pause/resume, cancel, retry-with-resume")
    func transfersControl() async throws {
        let c = try await Live.connect()
        let dir = try await Live.scratch(c, "ctl")
        let local = try LiveLocal.dir("ctl")
        defer { LiveLocal.remove(local) }
        let svc = FilesService.shared
        let q = svc.queue(c.id)

        // speed limit roughly honoured: 3 MB at 1 MB/s
        q.setLimit(1024 * 1024)
        let f1 = local + "/limited.bin"
        try LiveLocal.write(f1, LiveLocal.random(3 * 1024 * 1024))
        let j1 = try await svc.upload(c.id, localPaths: [f1], remoteDir: dir)
        var rates: [Double] = []
        await Live.waitUntil(30, every: 0.4) {
            if let v = Live.job(q, j1), v.status == "running", v.rate > 0 { rates.append(v.rate) }
            return Live.job(q, j1)?.status == "done" || Live.job(q, j1)?.status == "error"
        }
        let v1 = try #require(Live.job(q, j1))
        let took = ((v1.endedAt ?? 0) - (v1.startedAt ?? 0)) / 1000
        Live.say("3MB at 1MB/s limit took \(String(format: "%.2f", took))s; sampled rates KB/s: \(rates.map { Int($0 / 1024) })")
        #expect(v1.status == "done")
        #expect(v1.limit == 1024 * 1024)
        #expect(took >= 2.0, "limit not honoured: \(took)s")
        #expect(took <= 6.5, "far slower than the limit: \(took)s")
        #expect(try await Live.remoteSha(c, dir + "/limited.bin") == LiveLocal.sha(f1))

        // pause / resume (still limited so there is time to look)
        let f2 = local + "/pausable.bin"
        try LiveLocal.write(f2, LiveLocal.random(4 * 1024 * 1024))
        let j2 = try await svc.upload(c.id, localPaths: [f2], remoteDir: dir)
        #expect(await Live.waitUntil(15) { (Live.job(q, j2)?.doneBytes ?? 0) > 300_000 })
        q.pause(j2)
        #expect(Live.job(q, j2)?.status == "paused")
        #expect(Live.job(q, j2)?.paused == true)
        try? await Task.sleep(nanoseconds: 1_200_000_000)   // let in-flight chunks land
        let held = Live.job(q, j2)?.doneBytes ?? 0
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let stillHeld = Live.job(q, j2)?.doneBytes ?? 0
        Live.say("paused at \(held), 1.5s later \(stillHeld)")
        #expect(stillHeld == held, "bytes moved while paused")
        q.resume(j2)
        let v2 = await Live.finish(q, j2)
        #expect(v2?.status == "done")
        #expect(try await Live.remoteSha(c, dir + "/pausable.bin") == LiveLocal.sha(f2))

        // pauseAll holds a job added later
        q.pauseAll()
        let f3 = local + "/later.bin"
        try LiveLocal.write(f3, LiveLocal.random(200_000))
        let j3 = try await svc.upload(c.id, localPaths: [f3], remoteDir: dir)
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(Live.job(q, j3)?.status == "paused")
        #expect(Live.job(q, j3)?.doneBytes == 0)
        q.resumeAll()
        #expect((await Live.finish(q, j3))?.status == "done")

        // cancel mid-way, then retry picks up from what the server has
        let f4 = local + "/resumable.bin"
        try LiveLocal.write(f4, LiveLocal.random(5 * 1024 * 1024))
        let j4 = try await svc.upload(c.id, localPaths: [f4], remoteDir: dir)
        #expect(await Live.waitUntil(15) { (Live.job(q, j4)?.doneBytes ?? 0) > 1_500_000 })
        q.cancel(j4)
        let cv = await Live.finish(q, j4, timeout: 20)
        #expect(cv?.status == "cancelled")
        let partial = Int((try await c.exec("stat -c %s \(shellQuote(dir + "/resumable.bin"))")).trimmed) ?? 0
        Live.say("cancelled upload left \(partial) of \(5 * 1024 * 1024) bytes on the server")
        #expect(partial > 0 && partial < 5 * 1024 * 1024)
        var firstAfterRetry: Int64?
        let tok = q.onUpdate.count
        q.onUpdate.append { jobs in
            if firstAfterRetry == nil, let v = jobs.first(where: { $0.id == j4 }), v.status == "running", v.doneBytes > 0 {
                firstAfterRetry = v.doneBytes
            }
        }
        q.retry(j4)
        #expect(Live.job(q, j4)?.resumed == true)
        let rv = await Live.finish(q, j4)
        q.onUpdate.remove(at: tok)
        Live.say("retry: first progress \(firstAfterRetry ?? -1), status \(rv?.status ?? "?")")
        #expect(rv?.status == "done")
        #expect((firstAfterRetry ?? 0) >= Int64(partial) - 512 * 1024, "retry restarted from zero instead of resuming")
        #expect(try await Live.remoteSha(c, dir + "/resumable.bin") == LiveLocal.sha(f4), "resumed upload is corrupt")

        // download cancel + retry-resume
        let back = try LiveLocal.dir("ctl-back")
        defer { LiveLocal.remove(back) }
        let re = try await SFTPFileSource(connId: c.id).stat(dir + "/resumable.bin")
        let j5 = try await svc.download(c.id, entries: [re], localDir: back)
        #expect(await Live.waitUntil(15) { (Live.job(q, j5)?.doneBytes ?? 0) > 1_500_000 })
        q.cancel(j5)
        #expect((await Live.finish(q, j5, timeout: 20))?.status == "cancelled")
        q.retry(j5)
        #expect((await Live.finish(q, j5))?.status == "done")
        #expect(LiveLocal.sha(back + "/resumable.bin") == LiveLocal.sha(f4), "resumed download is corrupt")

        // cancel a queued job
        q.pauseAll()
        let j6 = try await svc.upload(c.id, localPaths: [f3], remoteDir: dir)
        q.cancel(j6)
        #expect(Live.job(q, j6)?.status == "cancelled")
        q.resumeAll()

        q.setLimit(0)
        _ = try await c.exec("rm -rf \(shellQuote(Live.guardScratch(dir)))")
        await Live.teardown(c)
        #expect(svc.queues[c.id] == nil, "queue kept after the connection closed")
    }

    @Test("sync plan/apply up, down, both, delete; watch one cycle")
    func syncAndWatch() async throws {
        let c = try await Live.connect()
        let rdir = try await Live.scratch(c, "sync")
        let ldir = try LiveLocal.dir("sync")
        defer { LiveLocal.remove(ldir) }
        let svc = FilesService.shared
        let q = svc.queue(c.id)
        q.setLimit(0)

        try LiveLocal.write(ldir + "/one.txt", "one")
        try LiveLocal.write(ldir + "/sub/two.txt", "two two")
        try LiveLocal.write(ldir + "/sub/inner/three ü.txt", "three")
        try LiveLocal.write(ldir + "/.DS_Store", "noise")

        let up = try await svc.syncPlan(c.id, .init(localDir: ldir, remoteDir: rdir, direction: "up"))
        Live.say("plan up: \(up.summary) ops=\(up.actions.map { "\($0.op):\($0.rel)" })")
        #expect(up.summary.upload == 3)
        #expect(!up.actions.contains { $0.rel.contains(".DS_Store") && $0.op == "upload" })
        let ar = try await svc.syncApply(c.id, up)
        #expect(ar.uploads == 3)
        #expect(ar.failures.isEmpty)
        await Live.idle(q)
        Live.say("sync up jobs: \(q.jobs.map { "\($0.label) \($0.status) \($0.fileIndex)/\($0.fileCount) err=\($0.error ?? "-")" })")
        let inner = (try? await SFTPFileSource(connId: c.id).list(rdir + "/sub/inner"))?.entries.map(\.name) ?? []
        #expect(inner.map(\.precomposedStringWithCanonicalMapping) == ["three ü.txt"])

        let again = try await svc.syncPlan(c.id, .init(localDir: ldir, remoteDir: rdir, direction: "up"))
        Live.say("plan up again: \(again.summary)")
        #expect(again.summary.upload == 0, "a just-synced tree plans uploads again: \(again.actions.filter(\.doing).map(\.rel))")

        // down: server-side change and a new file
        _ = try await c.exec("printf 'changed on server' > \(shellQuote(rdir + "/one.txt")) && touch -d '+1 hour' \(shellQuote(rdir + "/one.txt"))"
                             + " && mkdir -p \(shellQuote(rdir + "/fromserver")) && printf x > \(shellQuote(rdir + "/fromserver/new.txt"))")
        let down = try await svc.syncPlan(c.id, .init(localDir: ldir, remoteDir: rdir, direction: "down"))
        Live.say("plan down: \(down.summary) ops=\(down.actions.filter(\.doing).map { "\($0.op):\($0.rel)" })")
        #expect(down.summary.download == 2)
        _ = try await svc.syncApply(c.id, down)
        await Live.idle(q)
        #expect((try? String(contentsOfFile: ldir + "/one.txt", encoding: .utf8)) == "changed on server")
        #expect(FileManager.default.fileExists(atPath: ldir + "/fromserver/new.txt"))

        // both: one new each side
        try LiveLocal.write(ldir + "/localonly.txt", "L")
        _ = try await c.exec("printf R > \(shellQuote(rdir + "/remoteonly.txt"))")
        let both = try await svc.syncPlan(c.id, .init(localDir: ldir, remoteDir: rdir, direction: "both"))
        Live.say("plan both: \(both.summary)")
        #expect(both.summary.upload == 1 && both.summary.download == 1)
        _ = try await svc.syncApply(c.id, both)
        await Live.idle(q)
        #expect(FileManager.default.fileExists(atPath: ldir + "/remoteonly.txt"))
        #expect((try await c.exec("cat \(shellQuote(rdir + "/localonly.txt"))")) == "L")

        // delete option (up): local removals mirrored on the server, folders too
        try FileManager.default.removeItem(atPath: ldir + "/sub")
        try FileManager.default.removeItem(atPath: ldir + "/localonly.txt")
        let del = try await svc.syncPlan(c.id, .init(localDir: ldir, remoteDir: rdir, direction: "up", del: true))
        Live.say("plan up+delete: \(del.summary) ops=\(del.actions.filter(\.doing).map { "\($0.op):\($0.rel)" })")
        #expect(del.summary.deleteRemote >= 3)
        #expect(del.summary.rmdirRemote >= 2)
        let dr = try await svc.syncApply(c.id, del)
        Live.say("apply delete: removed=\(dr.removed) failures=\(dr.failures)")
        #expect(dr.failures.isEmpty)
        let remaining = (try await c.exec("cd \(shellQuote(rdir)) && find . | sort")).trimmed
        Live.say("remote after delete-sync: \(remaining.replacingOccurrences(of: "\n", with: " | "))")
        #expect(!remaining.contains("./sub"))
        #expect(!remaining.contains("localonly"))
        #expect(remaining.contains("./one.txt"))

        // watch: one cycle
        let wl = try LiveLocal.dir("watch")
        defer { LiveLocal.remove(wl) }
        let wr = rdir + "/watched"
        let w = try Watches.shared.watchDir(connId: c.id, localDir: wl, remoteDir: wr)
        try? await Task.sleep(nanoseconds: 700_000_000)
        try LiveLocal.write(wl + "/nested/new file.txt", "watched ✓")
        try LiveLocal.write(wl + "/skip.swp", "nope")
        let got = await Live.waitUntil(12) { (Watches.shared.list.first { $0.id == w.id }?.uploads ?? 0) >= 1 }
        let wv = Watches.shared.list.first { $0.id == w.id }
        Live.say("watch: uploads=\(wv?.uploads ?? -1) errors=\(wv?.errors ?? -1) last=\(wv?.lastFile ?? "-") err=\(wv?.lastError ?? "-")")
        #expect(got)
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect((try? await c.exec("cat \(shellQuote(wr + "/nested/new file.txt"))")) == "watched ✓")
        #expect((try? await c.exec("test -e \(shellQuote(wr + "/skip.swp")) && echo y || echo n"))?.trimmed == "n")
        Watches.shared.stop(w.id)
        #expect(!Watches.shared.list.contains { $0.id == w.id })

        _ = try await c.exec("rm -rf \(shellQuote(Live.guardScratch(rdir)))")
        await Live.teardown(c)
    }

    @Test("find files: remote name and content search, cap")
    func findFiles() async throws {
        let c = try await Live.connect()
        let dir = try await Live.scratch(c, "find")
        _ = try await c.exec("cd \(shellQuote(dir)) && mkdir -p 'a b/c' && for i in 1 2 3 4 5 6 7 8 9 10; do "
                             + "printf 'needle %s\\nhay\\n' $i > \"a b/c/file$i.log\"; done && printf 'nothing' > other.txt "
                             + "&& printf 'NEEDLE upper' > 'a b/Upper.TXT'")
        let src = SFTPFileSource(connId: c.id)

        let names = try await src.search(FindFiles.Options(dir: dir, pattern: "file"))
        Live.say("name search: \(names.results.count) truncated=\(names.truncated) cmd=\(names.command ?? "-")")
        #expect(names.results.count == 10)
        #expect(!names.truncated)
        #expect(names.results.allSatisfy { $0.type == .file && ($0.size ?? 0) > 0 && $0.mtime != nil })

        let capped = try await src.search(FindFiles.Options(dir: dir, pattern: "*.log", limit: 3))
        #expect(capped.results.count == 3)
        #expect(capped.truncated)

        let dirs = try await src.search(FindFiles.Options(dir: dir, pattern: "c", kinds: "dirs"))
        #expect(dirs.results.map(\.name).contains("c"))
        #expect(dirs.results.allSatisfy { $0.type == .directory })

        let content = try await src.search(FindFiles.Options(dir: dir, content: "needle"))
        Live.say("content search: \(content.results.count) first=\(content.results.first.map { "\($0.name):\($0.line ?? -1):\($0.excerpt ?? "")" } ?? "-")")
        #expect(content.results.count == 11)   // case-insensitive: 10 logs + Upper.TXT
        #expect(content.results.allSatisfy { $0.line == 1 })
        let cs = try await src.search(FindFiles.Options(dir: dir, content: "NEEDLE", caseSensitive: true))
        #expect(cs.results.map(\.name) == ["Upper.TXT"])
        let narrowed = try await src.search(FindFiles.Options(dir: dir, pattern: "*.TXT", content: "needle"))
        #expect(narrowed.results.map(\.name) == ["Upper.TXT"])
        let ccap = try await src.search(FindFiles.Options(dir: dir, content: "needle", limit: 4))
        #expect(ccap.results.count == 4)
        #expect(ccap.truncated)

        let none = try await src.search(FindFiles.Options(dir: dir, pattern: "zzz-nothing"))
        #expect(none.results.isEmpty)

        _ = try await c.exec("rm -rf \(shellQuote(Live.guardScratch(dir)))")
        await Live.teardown(c)
    }

    @Test("rsync over the ControlMaster: dry run, real run")
    func rsync() async throws {
        let check = await Rsync.check()
        Live.say("rsync check: ok=\(check.ok) bin=\(check.bin ?? "-") version=\(check.version ?? "-") features=\(String(describing: check.features))")
        try #require(check.ok)
        let c = try await Live.connect()
        let dir = try await Live.scratch(c, "rsync")
        let local = try LiveLocal.dir("rsync")
        defer { LiveLocal.remove(local) }
        try LiveLocal.write(local + "/x.txt", "x")
        try LiveLocal.write(local + "/with space/y ü.txt", "yy")

        let t = Rsync.transport(c.id)
        Live.say("rsync transport: ok=\(t.ok) shell=\(t.shell ?? "-") reason=\(t.reason ?? "-")")
        #expect(t.ok)
        #expect(t.target == c.target)
        let remoteSide = Rsync.Side(kind: "remote", label: c.label, target: t.target)
        let localSide = Rsync.Side(kind: "local", label: "this machine")
        var opts = Rsync.Options(from: Rsync.endpoint(localSide, local), to: Rsync.endpoint(remoteSide, dir + "/dest"))
        opts.features = check.features ?? opts.features
        opts.shellArg = t.shell
        opts.dryRun = true

        func run(_ o: Rsync.Options) async -> (Rsync.Done, String) {
            let buf = LockedText()
            let id = "live-" + UUID().uuidString
            let done: Rsync.Done = await withCheckedContinuation { cont in
                do {
                    try Rsync.run(id: id, args: Rsync.buildArgs(o), onOut: { buf.append($0.text) }, onDone: { cont.resume(returning: $0) })
                } catch {
                    cont.resume(returning: Rsync.Done(id: id, code: -1, signal: nil, error: errorText(error), message: errorText(error)))
                }
            }
            return (done, buf.text)
        }

        let (dry, dryOut) = await run(opts)
        Live.say("rsync dry run: \(dry.message) code=\(String(describing: dry.code))\n\(dryOut.suffix(600))")
        #expect(dry.code == 0)
        #expect(dryOut.contains("y ü.txt"))
        #expect((try await c.exec("test -e \(shellQuote(dir + "/dest")) && echo y || echo n")).trimmed == "n")

        opts.dryRun = false
        let (real, realOut) = await run(opts)
        Live.say("rsync real: \(real.message) code=\(String(describing: real.code))\n\(realOut.suffix(400))")
        #expect(real.code == 0)
        #expect((try await c.exec("cat \(shellQuote(dir + "/dest/x.txt"))")) == "x")
        let names = (try? await SFTPFileSource(connId: c.id).list(dir + "/dest/with space"))?.entries.map { Array($0.name.unicodeScalars).map { String($0.value, radix: 16) } } ?? []
        Live.say("rsync remote name scalars: \(names)")
        #expect(names.count == 1)

        // the transport rides the master: no extra master process left behind
        let extra = await Live.processesMentioning(c.controlPath).filter { $0.contains("ControlMaster=no") }
        Live.say("processes with ControlMaster=no after rsync: \(extra)")
        #expect(extra.isEmpty, "rsync left ssh behind: \(extra)")

        _ = try await c.exec("rm -rf \(shellQuote(Live.guardScratch(dir)))")
        await Live.teardown(c)

        // after disconnect the transport refuses
        let gone = Rsync.transport(c.id)
        #expect(!gone.ok)
        #expect(gone.reason == "That connection is not open any more.")
    }
}
