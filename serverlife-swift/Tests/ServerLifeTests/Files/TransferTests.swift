import Foundation
import Testing
@testable import ServerLife

/// Uploads and downloads through a real sftp-server: pipelining, resume,
/// cancel, pause, the speed limit, retry and reordering.
@Suite(.serialized) struct TransferTests {
    @Test func pipelinedRoundTripKeepsBytesModeAndTime() async throws {
        let dir = try scratchDir("rt"); defer { cleanup(dir) }
        let src = dir + "/src.bin"
        let data = randomData(3 * 1024 * 1024 + 123)   // not a multiple of the chunk
        try data.write(to: URL(fileURLWithPath: src))
        chmod(src, 0o640)
        Transfers.setLocalTimes(src, atime: 1_600_000_000, mtime: 1_650_000_000)
        let c = try await localSFTP(); defer { c.destroy() }

        let phases = PhaseLog()
        // The parent does not exist: an upload does not make directories (the queue does).
        await #expect(throws: (any Error).self) {
            try await Transfers.uploadFile(c, local: src, remote: dir + "/up/remote.bin")
        }

        try FileManager.default.createDirectory(atPath: dir + "/up", withIntermediateDirectories: true)
        let n = try await Transfers.uploadFile(c, local: src, remote: dir + "/up/remote.bin", Transfers.Options(
            onPhase: { phases.add($0) }))
        #expect(n == Int64(data.count))
        #expect(readData(dir + "/up/remote.bin") == data)
        let rst = LocalFS.stat(dir + "/up/remote.bin")!
        #expect(rst.mode & 0o777 == 0o640, "the mode follows the local file")
        #expect(rst.mtimeMs == 1_650_000_000_000, "and so does the time, so a later sync sees them as the same")
        #expect(phases.all.contains("the server is closing the file"))
        #expect(phases.all.contains("setting permissions"))
        #expect(phases.all.last == .some(nil))

        let back = dir + "/down/a/b/back.bin"   // parents are made for a download
        let m = try await Transfers.downloadFile(c, remote: dir + "/up/remote.bin", local: back)
        #expect(m == Int64(data.count))
        #expect(readData(back) == data)
        #expect(LocalFS.stat(back)!.mtimeMs == 1_650_000_000_000)

        // Empty files work both ways.
        try Data().write(to: URL(fileURLWithPath: dir + "/empty"))
        try await Transfers.uploadFile(c, local: dir + "/empty", remote: dir + "/up/empty")
        try await Transfers.downloadFile(c, remote: dir + "/up/empty", local: dir + "/down/empty")
        #expect(readData(dir + "/down/empty") == Data())
    }

    @Test func resumeOnlyWhenAskedAndFromWhatIsThere() async throws {
        let dir = try scratchDir("resume"); defer { cleanup(dir) }
        let data = randomData(1_000_000)
        try data.write(to: URL(fileURLWithPath: dir + "/remote.bin"))
        let c = try await localSFTP(); defer { c.destroy() }

        // A partial local copy, as an interrupted download leaves.
        try data.prefix(300_000).write(to: URL(fileURLWithPath: dir + "/local.bin"))
        let first = FirstValue()
        let moved = try await Transfers.downloadFile(c, remote: dir + "/remote.bin", local: dir + "/local.bin",
                                                     Transfers.Options(onProgress: { d, _ in first.set(d) }, resume: true))
        #expect(first.value == 300_000, "progress starts from what is on disk")
        #expect(moved == 1_000_000)
        #expect(readData(dir + "/local.bin") == data)

        // Not asked to resume: whatever was there is replaced, not appended to.
        try Data(repeating: 7, count: 2_000_000).write(to: URL(fileURLWithPath: dir + "/local2.bin"))
        try await Transfers.downloadFile(c, remote: dir + "/remote.bin", local: dir + "/local2.bin")
        #expect(readData(dir + "/local2.bin") == data)

        // Uploads resume from what the server already has.
        try data.write(to: URL(fileURLWithPath: dir + "/src.bin"))
        try Data(data.prefix(123_456)).write(to: URL(fileURLWithPath: dir + "/partial.bin"))
        let ufirst = FirstValue()
        try await Transfers.uploadFile(c, local: dir + "/src.bin", remote: dir + "/partial.bin",
                                       Transfers.Options(onProgress: { d, _ in ufirst.set(d) }, resume: true))
        #expect(ufirst.value == 123_456)
        #expect(readData(dir + "/partial.bin") == data)
    }

    @Test func cancelStopsBetweenChunks() async throws {
        let dir = try scratchDir("cancel"); defer { cleanup(dir) }
        try randomData(4_000_000).write(to: URL(fileURLWithPath: dir + "/big"))
        let c = try await localSFTP(); defer { c.destroy() }
        let calls = Transfers.Counter()
        do {
            // Let a few chunks through, then say stop.
            try await Transfers.downloadFile(c, remote: dir + "/big", local: dir + "/out", Transfers.Options(
                isCancelled: { calls.add(1) > 20 }))
            Issue.record("expected cancellation")
        } catch {
            #expect(errorText(error) == "cancelled")
        }
    }

    @Test func parallelChunksRunsEveryIndexOnceAndStopsOnError() async throws {
        let hits = HitSet()
        try await Transfers.parallelChunks(16, 1000) { hits.insert($0) }
        #expect(hits.count == 1000)
        let after = Transfers.Counter()
        await #expect(throws: AppError.self) {
            try await Transfers.parallelChunks(4, 1000) { i in
                if i == 10 { throw AppError("boom") }
                if i > 200 { after.add(1) }
            }
        }
        #expect(after.value < 800, "workers stop taking work after a failure")
    }

    @Test func planUploadAndDownloadWalkTrees() async throws {
        let dir = try scratchDir("plan"); defer { cleanup(dir) }
        try writeFile(dir + "/site/index.html", "x")
        try writeFile(dir + "/site/css/a.css", "yy")
        try FileManager.default.createDirectory(atPath: dir + "/site/empty", withIntermediateDirectories: true)
        let up = try await Transfers.planUpload(dir + "/site", remoteDir: "/srv")
        #expect(Set(up.dirs) == ["/srv/site", "/srv/site/css", "/srv/site/empty"])
        #expect(Set(up.files.map(\.remote)) == ["/srv/site/index.html", "/srv/site/css/a.css"])
        #expect(up.files.reduce(0) { $0 + $1.size } == 3)

        let c = try await localSFTP(); defer { c.destroy() }
        let down = try await Transfers.planDownload(c, remotePath: dir + "/site", localDir: "/tmp/x")
        #expect(Set(down.dirs) == ["/tmp/x/site", "/tmp/x/site/css", "/tmp/x/site/empty"])
        #expect(Set(down.files.map(\.local)) == ["/tmp/x/site/index.html", "/tmp/x/site/css/a.css"])
        let one = try await Transfers.planDownload(c, remotePath: dir + "/site/index.html", localDir: "/tmp/x")
        #expect(one.files == [Transfers.Item(local: "/tmp/x/index.html", remote: dir + "/site/index.html", size: 1)])
    }

    // MARK: - The queue

    @MainActor
    private func makeQueue() -> (TransferQueue, Box<SFTPClient?>) {
        let box = Box<SFTPClient?>(nil)
        let q = TransferQueue(getSftp: {
            if let c = box.value, !c.closed { return c }
            let c = try await localSFTP()
            box.value = c
            return c
        })
        return (q, box)
    }

    @MainActor
    private func waitFor(_ timeout: Double = 20, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test @MainActor func queueRunsJobsAndAnnouncesFinished() async throws {
        let dir = try scratchDir("q"); defer { cleanup(dir) }
        try writeFile(dir + "/a/one.txt", "one")
        try writeFile(dir + "/a/sub/two.txt", "two!")
        let (q, box) = makeQueue(); defer { box.value?.destroy() }
        var finished: [FinishedTransfer] = []
        q.onFinished.append { finished.append($0) }
        let plan = try await Transfers.planUpload(dir + "/a", remoteDir: dir + "/remote")
        try FileManager.default.createDirectory(atPath: dir + "/remote", withIntermediateDirectories: true)
        let id = q.add(TransferJobSpec(kind: "upload", label: "a → remote", items: plan.files, dirs: plan.dirs))
        await waitFor { q.jobs.first?.status == "done" }
        let v = try #require(q.jobs.first { $0.id == id })
        #expect(v.status == "done" && v.doneBytes == 7 && v.totalBytes == 7 && v.fileIndex == 2 && v.fileCount == 2)
        #expect(readData(dir + "/remote/a/sub/two.txt") == Data("two!".utf8))
        #expect(finished.count == 1 && finished[0].bytes == 7)
        q.clearFinished()
        #expect(q.jobs.isEmpty)
    }

    @Test @MainActor func pauseHoldsBetweenChunksAndResumeCarriesOn() async throws {
        let dir = try scratchDir("pause"); defer { cleanup(dir) }
        let data = randomData(1_200_000)
        try data.write(to: URL(fileURLWithPath: dir + "/big"))
        let (q, box) = makeQueue(); defer { box.value?.destroy() }
        q.setLimit(300 * 1024)   // slow enough to catch it running
        let id = q.add(TransferJobSpec(kind: "download", label: "big", items: [Transfers.Item(local: dir + "/out", remote: dir + "/big", size: Int64(data.count))]))
        await waitFor { (q.jobs.first?.doneBytes ?? 0) > 0 }
        q.pause(id)
        #expect(q.jobs[0].status == "paused" && q.jobs[0].paused)
        try await Task.sleep(nanoseconds: 1_200_000_000)   // let in-flight chunks land
        let held = q.jobs[0].doneBytes
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(q.jobs[0].doneBytes == held, "nothing moves while paused")
        #expect(held < Int64(data.count))
        q.resume(id)
        q.setLimit(0)
        await waitFor { q.jobs[0].status == "done" }
        #expect(q.jobs[0].status == "done")
        #expect(readData(dir + "/out") == data)
    }

    @Test @MainActor func pauseAllHoldsNewJobsAndReorderAmongQueued() async throws {
        let dir = try scratchDir("hold"); defer { cleanup(dir) }
        for n in ["a", "b", "c"] { try writeFile(dir + "/\(n)", n) }
        let (q, box) = makeQueue(); defer { box.value?.destroy() }
        q.pauseAll()
        let ids = ["a", "b", "c"].map { n in
            q.add(TransferJobSpec(kind: "download", label: n, items: [Transfers.Item(local: dir + "/out/\(n)", remote: dir + "/\(n)", size: 1)]))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(q.jobs.allSatisfy { $0.status == "paused" }, "a file dropped in while held waits with the rest")
        q.move(ids[2], -1)
        #expect(q.jobs.map(\.label) == ["a", "c", "b"])
        q.move(ids[0], -1)   // already first
        #expect(q.jobs.map(\.label) == ["a", "c", "b"])
        q.cancel(ids[1])
        #expect(q.jobs.first { $0.id == ids[1] }?.status == "cancelled")
        q.resumeAll()
        await waitFor { q.jobs.filter { $0.status == "done" }.count == 2 }
        #expect(readData(dir + "/out/a") == Data("a".utf8) && readData(dir + "/out/c") == Data("c".utf8))
        #expect(readData(dir + "/out/b") == nil)
        q.move(ids[2], 1)   // not queued any more: nothing happens
        #expect(q.jobs.map(\.label) == ["a", "c", "b"])
    }

    @Test @MainActor func retryAfterCancelResumesFromThePartialFile() async throws {
        let dir = try scratchDir("retry"); defer { cleanup(dir) }
        let data = randomData(900_000)
        try data.write(to: URL(fileURLWithPath: dir + "/big"))
        let (q, box) = makeQueue(); defer { box.value?.destroy() }
        q.setLimit(200 * 1024)
        let id = q.add(TransferJobSpec(kind: "download", label: "big", items: [Transfers.Item(local: dir + "/out", remote: dir + "/big", size: Int64(data.count))]))
        await waitFor { (q.jobs.first?.doneBytes ?? 0) > 200_000 }
        q.cancel(id)
        await waitFor { q.jobs[0].status == "cancelled" }
        #expect(q.jobs[0].status == "cancelled")
        let partial = LocalFS.stat(dir + "/out")?.size ?? 0
        #expect(partial > 0 && partial < Int64(data.count))
        q.setLimit(0)
        q.retry(id)
        #expect(q.jobs[0].resumed)
        await waitFor { q.jobs[0].status == "done" }
        #expect(q.jobs[0].status == "done")
        #expect(readData(dir + "/out") == data)
        #expect(!q.jobs[0].resumed, "a finished job has nothing to pick up")
    }

    @Test @MainActor func speedLimitIsOneAllowanceAcrossTheQueue() async throws {
        let dir = try scratchDir("limit"); defer { cleanup(dir) }
        let data = randomData(640 * 1024)
        try data.write(to: URL(fileURLWithPath: dir + "/f"))
        let (q, box) = makeQueue(); defer { box.value?.destroy() }
        q.setLimit(256 * 1024)
        #expect(q.limit == 256 * 1024)
        let started = Date()
        q.add(TransferJobSpec(kind: "download", label: "f", items: [Transfers.Item(local: dir + "/out", remote: dir + "/f", size: Int64(data.count))]))
        await waitFor { q.jobs[0].status == "done" }
        let elapsed = Date().timeIntervalSince(started)
        #expect(q.jobs[0].status == "done")
        #expect(q.jobs[0].limit == 256 * 1024)
        // 640 KB at 256 KB/s: two full waits, not sixteen chunks each taking the whole allowance.
        #expect(elapsed >= 1.6, "took \(elapsed)s")
        #expect(elapsed < 6, "took \(elapsed)s")
    }

    @Test @MainActor func customRunJobsReportThroughTheContext() async throws {
        let (q, _) = makeQueue()
        let id = q.add(TransferJobSpec(kind: "cross", label: "x", items: [Transfers.Item(local: "", remote: "/a", size: 10)],
                                       customRun: { ctx in
            ctx.setFile("a", 1)
            ctx.onProgress(5, 20)
            ctx.setPhase("halfway")
            try await Task.sleep(nanoseconds: 100_000_000)
        }))
        await waitFor { q.jobs[0].status == "done" }
        let v = try #require(q.jobs.first { $0.id == id })
        #expect(v.status == "done" && v.totalBytes == 20 && v.doneBytes == 20 && v.currentFile == "a" && v.phase == nil)

        let bad = q.add(TransferJobSpec(kind: "cross", label: "y", items: [], customRun: { _ in throw AppError("tsh scp failed (exit 1)") }))
        await waitFor { q.jobs.first { $0.id == bad }?.status == "error" }
        #expect(q.jobs.first { $0.id == bad }?.error == "tsh scp failed (exit 1)")
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String?] = []
    func add(_ p: String?) { lock.withLock { items.append(p) } }
    var all: [String?] { lock.withLock { items } }
}

final class FirstValue: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64?
    func set(_ x: Int64) { lock.withLock { if v == nil { v = x } } }
    var value: Int64? { lock.withLock { v } }
}

final class HitSet: @unchecked Sendable {
    private let lock = NSLock()
    private var s = Set<Int>()
    func insert(_ i: Int) { lock.withLock { _ = s.insert(i) } }
    var count: Int { lock.withLock { s.count } }
}
