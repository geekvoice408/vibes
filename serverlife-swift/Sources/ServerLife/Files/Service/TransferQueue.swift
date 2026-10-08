import Foundation
import Observation

/// What the transfers panel draws for one job (`queue.view()` in transfers.js).
struct TransferJobView: Identifiable, Equatable, Sendable, Codable {
    var id: String
    /// "upload" | "download" | "cross"
    var kind: String
    var label: String
    /// "queued" | "running" | "paused" | "done" | "error" | "cancelled".
    /// Paused is a state of its own to anything watching, even though the job
    /// is still sitting inside its run.
    var status: String
    var paused: Bool
    /// Set when a retry is picking up from what is already there.
    var resumed: Bool
    var totalBytes: Int64
    var doneBytes: Int64
    var fileIndex: Int
    var fileCount: Int
    var currentFile: String?
    /// What is happening when it is no longer about bytes: the tail of a
    /// transfer, so a full progress bar can say why it is not finished yet.
    var phase: String?
    var error: String?
    /// Bytes per second, sampled every 400 ms.
    var rate: Double
    var startedAt: Double?
    var endedAt: Double?
    /// The queue's speed limit, bytes per second (0 = none).
    var limit: Int
}

/// A job to add: `queue.add({...})` in transfers.js.
struct TransferJobSpec: Sendable {
    var kind: String
    var label: String
    var items: [Transfers.Item]
    var dirs: [String] = []
    /// What the user actually picked, before it was flattened into files. A
    /// tree's file list starts at some arbitrary leaf — often a dotfile
    /// several levels down — so nothing in `items` can say "this came from
    /// /home/ubuntu/web" once the walk has happened.
    var roots: [String] = []
    /// Server-to-server jobs bring their own executor.
    var customRun: (@Sendable (TransferRunContext) async throws -> Void)?
}

/// What a custom executor gets to report through.
struct TransferRunContext: Sendable {
    /// (done, total) — total 0 leaves the job's total alone.
    var onProgress: @Sendable (Int64, Int64) -> Void
    /// (name, 1-based index or nil)
    var setFile: @Sendable (String, Int?) -> Void
    var setPhase: @Sendable (String?) -> Void
    var isCancelled: @Sendable () -> Bool
    var gate: @Sendable () async -> Void
    var throttle: @Sendable (Int) async -> Void
}

/// A job that finished, announced separately from the progress stream so
/// whatever wants to keep a record of it does not have to watch every tick.
struct FinishedTransfer: Sendable {
    var kind: String
    var label: String
    var items: [Transfers.Item]
    var dirs: [String]
    var roots: [String]
    var bytes: Int64
    var endedAt: Double
    /// When it started (for "how fast" in a confirmation).
    var startedAt: Double? = nil
    /// The connection's label (added by the service, as connections.js did).
    var from: String = ""
}

/// The speed limit: one allowance per second, handed out in order.
///
/// A plain sliding window — crude next to a token bucket, and exactly as
/// accurate as anyone cares about for "don't saturate the uplink".
/// Serialised through one chain: a transfer runs sixteen chunk requests at
/// once, and an unserialised window let each of them see "over budget", wait
/// the same second in parallel and then reset the window — which came out at
/// four times the limit. Queuing the accounting behind itself makes the
/// allowance mean what it says.
final class TransferThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var limit = 0
    private var windowAt: Double = 0
    private var windowBytes = 0
    private var tail: Task<Void, Never>?

    var bytesPerSecond: Int {
        get { lock.lock(); defer { lock.unlock() }; return limit }
        set { lock.lock(); limit = max(0, newValue); lock.unlock() }
    }

    func spend(_ n: Int) async {
        let t: Task<Void, Never>? = lock.withLock {
            if limit == 0 { return nil }
            let prev = tail
            let t = Task { [self] in
                await prev?.value
                let now = Date().timeIntervalSince1970 * 1000
                let (over, wait) = lock.withLock { () -> (Bool, Double) in
                    if now - windowAt >= 1000 { windowAt = now; windowBytes = 0 }
                    windowBytes += n
                    return (windowBytes > limit, max(0, 1000 - (now - windowAt)))
                }
                if over {
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
                    lock.withLock {
                        windowAt = Date().timeIntervalSince1970 * 1000
                        windowBytes = 0
                    }
                }
            }
            tail = t
            return t
        }
        await t?.value
    }
}

/// Per-connection transfer queue: one job at a time, in order — the
/// TransferQueue class of transfers.js.
@MainActor
@Observable
final class TransferQueue {
    /// The live view, refreshed on every change and every 400 ms while a job runs.
    private(set) var jobs: [TransferJobView] = []
    /// Whether the queue as a whole is held. Separate from each job's own flag
    /// so that a file dropped in while everything is paused waits with the
    /// rest — starting it immediately is the opposite of what "pause all" was
    /// asked to do.
    private(set) var allPaused = false

    /// Bytes per second across the whole queue, 0 for no limit. One bucket
    /// rather than one per job, because the thing being protected is the link.
    var limit: Int { throttle.bytesPerSecond }

    @ObservationIgnored let getSftp: () async throws -> SFTPClient
    @ObservationIgnored private var records: [String: Job] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var running = false
    @ObservationIgnored let throttle = TransferThrottle()
    @ObservationIgnored var onUpdate: [([TransferJobView]) -> Void] = []
    @ObservationIgnored var onFinished: [(FinishedTransfer) -> Void] = []

    nonisolated(unsafe) private static var jobSeq = 0

    init(getSftp: @escaping () async throws -> SFTPClient) {
        self.getSftp = getSftp
    }

    // MARK: - Job record

    /// Mutable job state, shared with the transfer's own tasks.
    final class Job: @unchecked Sendable {
        let lock = NSLock()
        let id: String
        let kind: String
        let label: String
        let items: [Transfers.Item]
        let dirs: [String]
        let roots: [String]
        let customRun: (@Sendable (TransferRunContext) async throws -> Void)?
        var totalBytes: Int64
        var doneBytes: Int64 = 0
        var fileIndex = 0
        var fileCount: Int
        var currentFile: String?
        var phase: String?
        var status = "queued"
        /// Held between chunks rather than torn down, so resuming is instant
        /// and nothing has to be re-authenticated or re-opened.
        var paused = false
        /// Set by retry(): pick up where the interrupted copy stopped.
        var resume = false
        var error: String?
        var startedAt: Double?
        var endedAt: Double?
        var rate: Double = 0
        var aborted = false
        var gateWaiters: [CheckedContinuation<Void, Never>] = []
        var lastTick: Double = 0
        var lastBytes: Int64 = 0

        init(id: String, spec: TransferJobSpec) {
            self.id = id
            kind = spec.kind; label = spec.label; items = spec.items; dirs = spec.dirs; roots = spec.roots
            customRun = spec.customRun
            totalBytes = spec.items.reduce(0) { $0 + $1.size }
            fileCount = spec.items.count
        }

        func with<R>(_ body: (Job) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(self) }

        var isAborted: Bool { with { $0.aborted } }

        /// Wait here while paused.
        func gate() async {
            if !with({ $0.paused }) { return }
            // One continuation per waiter, resumed by release(); the transfer
            // simply waits inside its chunk loop, which keeps every handle open
            // and means resuming costs nothing.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if !paused { lock.unlock(); c.resume(); return }
                gateWaiters.append(c)
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            let w = gateWaiters; gateWaiters = []
            lock.unlock()
            w.forEach { $0.resume() }
        }

        func view(limit: Int) -> TransferJobView {
            with { j in
                TransferJobView(
                    id: j.id, kind: j.kind, label: j.label,
                    status: j.paused && (j.status == "queued" || j.status == "running") ? "paused" : j.status,
                    paused: j.paused, resumed: j.resume,
                    totalBytes: j.totalBytes, doneBytes: j.doneBytes,
                    fileIndex: j.fileIndex, fileCount: j.fileCount,
                    currentFile: j.currentFile, phase: j.phase, error: j.error, rate: j.rate,
                    startedAt: j.startedAt, endedAt: j.endedAt, limit: limit)
            }
        }
    }

    // MARK: - Public API

    @discardableResult
    func setLimit(_ bytesPerSecond: Int) -> Int {
        throttle.bytesPerSecond = max(0, bytesPerSecond)
        emit()
        return limit
    }

    /// Queue a job; returns its id ("job1", "job2", …).
    @discardableResult
    func add(_ spec: TransferJobSpec) -> String {
        Self.jobSeq += 1
        let id = "job\(Self.jobSeq)"
        let rec = Job(id: id, spec: spec)
        if allPaused { rec.paused = true }
        records[id] = rec
        order.append(id)
        emit()
        pump()
        return id
    }

    func cancel(_ id: String) {
        guard let j = records[id] else { return }
        // A paused job is waiting on its gate; let it go so it can see the abort.
        j.with { $0.paused = false; $0.aborted = true }
        j.release()
        j.with { if $0.status == "queued" { $0.status = "cancelled"; $0.endedAt = nowMs() } }
        emit()
    }

    func pause(_ id: String) {
        guard let j = records[id], ["queued", "running"].contains(j.with({ $0.status })) else { return }
        j.with { $0.paused = true }
        emit()
    }

    func resume(_ id: String) {
        guard let j = records[id], j.with({ $0.paused }) else { return }
        // Letting one job go means the queue is no longer wholly held.
        allPaused = false
        j.with { $0.paused = false }
        j.release()
        emit()
        // A queued job that was paused has to be picked up again.
        pump()
    }

    func pauseAll() {
        allPaused = true
        for j in records.values where ["queued", "running"].contains(j.with({ $0.status })) { j.with { $0.paused = true } }
        emit()
    }

    func resumeAll() {
        allPaused = false
        for j in records.values where j.with({ $0.paused }) {
            j.with { $0.paused = false }
            j.release()
        }
        emit()
        pump()
    }

    /// Run a failed or cancelled job again, picking up any partial files.
    ///
    /// The same job rather than a new one: it already knows its item list, its
    /// directories and what it was called, and keeping the row means the
    /// history of "this failed, then it worked" stays in one place.
    func retry(_ id: String) {
        guard let j = records[id], ["error", "cancelled"].contains(j.with({ $0.status })) else { return }
        j.with {
            $0.aborted = false; $0.status = "queued"; $0.paused = false; $0.resume = true
            $0.error = nil; $0.phase = nil; $0.doneBytes = 0; $0.fileIndex = 0; $0.currentFile = nil
            $0.startedAt = nil; $0.endedAt = nil; $0.rate = 0; $0.lastBytes = 0
        }
        emit()
        pump()
    }

    /// Move a queued job one place earlier (delta < 0) or later. Only among
    /// the queued ones: reordering around a job that is already running would
    /// say something untrue about what happens next.
    func move(_ id: String, _ delta: Int) {
        guard let at = order.firstIndex(of: id), let j = records[id], j.with({ $0.status }) == "queued" else { return }
        let target = max(0, min(order.count - 1, at + (delta < 0 ? -1 : 1)))
        if target == at { return }
        if let other = records[order[target]], other.with({ $0.status }) == "running" { return }
        order.remove(at: at)
        order.insert(id, at: target)
        emit()
    }

    func clearFinished() {
        for (id, j) in records where ["done", "error", "cancelled"].contains(j.with({ $0.status })) {
            records.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
        emit()
    }

    /// Cancel everything (the connection is going away).
    func cancelAll() {
        for id in order { cancel(id) }
    }

    func view() -> [TransferJobView] {
        let l = limit
        return order.compactMap { records[$0]?.view(limit: l) }
    }

    /// Whether anything is queued or running.
    var isBusy: Bool { jobs.contains { ["queued", "running", "paused"].contains($0.status) } }

    // MARK: - Running

    private func emit() {
        let v = view()
        if v != jobs { jobs = v }
        onUpdate.forEach { $0(v) }
    }

    private nonisolated func emitSoon() {
        Task { @MainActor [weak self] in self?.emit() }
    }

    private func pump() {
        if running { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            while let next = order.compactMap({ records[$0] })
                .first(where: { j in j.with { $0.status == "queued" && !$0.paused } }) {
                await run(next)
            }
        }
    }

    private func run(_ job: Job) async {
        let now = nowMs()
        job.with { $0.status = "running"; $0.startedAt = now; $0.lastTick = now }
        emit()

        let timer = Repeater()
        timer.start(every: 0.4) { [weak self] in
            let t = nowMs()
            job.with { j in
                let dt = (t - j.lastTick) / 1000
                if dt > 0.2 {
                    j.rate = Double(j.doneBytes - j.lastBytes) / dt
                    j.lastBytes = j.doneBytes
                    j.lastTick = t
                }
            }
            self?.emit()
        }

        let throttle = self.throttle
        let gate: @Sendable () async -> Void = { await job.gate() }
        let spend: @Sendable (Int) async -> Void = { await throttle.spend($0) }
        let cancelled: @Sendable () -> Bool = { job.isAborted }

        do {
            if let custom = job.customRun {
                let ctx = TransferRunContext(
                    onProgress: { done, total in job.with { $0.doneBytes = done; if total > 0 { $0.totalBytes = total } } },
                    setFile: { name, index in job.with { $0.currentFile = name; if let index, index > 0 { $0.fileIndex = index } } },
                    setPhase: { [weak self] p in job.with { $0.phase = p }; self?.emitSoon() },
                    isCancelled: cancelled, gate: gate, throttle: spend)
                try await custom(ctx)
                job.with { $0.status = "done"; $0.phase = nil; $0.doneBytes = $0.totalBytes }
            } else {
                let sftp = try await getSftp()
                if job.kind == "upload" {
                    for d in job.dirs { try? await sftp.mkdir(d) }   // ignore "already exists"
                } else {
                    for d in job.dirs { try? LocalFS.ensureDir(d) }
                }
                var base: Int64 = 0
                let resume = job.with { $0.resume }
                for (i, item) in job.items.enumerated() {
                    if job.isAborted { throw AppError("cancelled") }
                    job.with { $0.fileIndex = i + 1; $0.currentFile = job.kind == "upload" ? item.local : item.remote }
                    emit()
                    let b = base
                    let opts = Transfers.Options(
                        onProgress: { d, _ in job.with { $0.doneBytes = b + d } },
                        // Straight out rather than on the next tick: the point
                        // of the phase is to explain a pause, so it has to
                        // appear when the pause starts.
                        onPhase: { [weak self] p in job.with { $0.phase = p }; self?.emitSoon() },
                        isCancelled: cancelled, gate: gate, throttle: spend, resume: resume)
                    if job.kind == "upload" {
                        try await Transfers.uploadFile(sftp, local: item.local, remote: item.remote, opts)
                    } else {
                        try await Transfers.downloadFile(sftp, remote: item.remote, local: item.local, opts)
                    }
                    base += item.size
                    job.with { $0.doneBytes = base }
                }
                // Only a retry resumes; a job that finishes has nothing to pick up.
                job.with { $0.status = "done"; $0.phase = nil; $0.doneBytes = $0.totalBytes; $0.resume = false }
            }
        } catch {
            let msg = errorText(error)
            job.with { $0.status = $0.aborted ? "cancelled" : "error"; $0.error = msg }
        }
        timer.stop()
        let ended = nowMs()
        job.with { $0.endedAt = ended }
        if job.with({ $0.status }) == "done" {
            let f = FinishedTransfer(kind: job.kind, label: job.label, items: job.items, dirs: job.dirs, roots: job.roots,
                                     bytes: job.with { $0.totalBytes }, endedAt: ended, startedAt: job.with { $0.startedAt })
            onFinished.forEach { $0(f) }
        }
        emit()
    }
}
