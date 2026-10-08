import Foundation
import Observation

/// One host's part of a multi-exec run (`results` in multiexec.js).
struct MultiExecResult: Identifiable, Equatable {
    var connId: String
    var label: String
    /// pending | running | done | error | timeout | cancelled
    var status = "pending"
    var exitCode: Int32?
    var stdout = ""
    var stderr = ""
    var startedAt: Double?
    var endedAt: Double?
    var durationMs: Double?
    var id: String { connId }
}

/// `run.view()`: what the panel draws and what is saved as results.
struct MultiExecView: Identifiable, Equatable {
    var id: String
    var command: String
    var startedAt: Double
    var endedAt: Double?
    var running: Bool { endedAt == nil }
    var results: [MultiExecResult]
}

/// Multi-exec: run one command across many hosts at once (multiexec.js and
/// main.js `multiexec:*`).
///
/// Each host runs over its own ControlMaster, so a command fans out without
/// re-authenticating anywhere. Results stream back per host as they arrive
/// rather than all at the end, and one slow or dead host never blocks the rest.
@MainActor
@Observable
final class MultiExecService {
    static let shared = MultiExecService()

    struct Options {
        var concurrency = 8
        /// Milliseconds.
        var timeout: Double = 120_000
        var stopOnError = false
    }

    /// Every run this session, newest first (`state.multiRuns`).
    private(set) var runs: [MultiExecView] = []
    @ObservationIgnored private var procs: [String: [String: RunningProcess]] = [:]
    @ObservationIgnored private var cancelled: Set<String> = []
    @ObservationIgnored private var seq = 0
    /// Called with the final view when a run finishes (`multiexec:done`).
    @ObservationIgnored var onDone: [(MultiExecView) -> Void] = []

    /// Above this much output a host's stream keeps only its tail.
    nonisolated static let outputCap = 400_000

    func view(_ id: String) -> MultiExecView? { runs.first { $0.id == id } }

    /// Changed in place: copying a view out and back would copy every
    /// host's output with it.
    private func update(_ id: String, _ body: (inout MultiExecView) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        body(&runs[i])
    }

    /// Output read on the pipes' threads, handed to the main actor in batches
    /// (every 100 ms) rather than chunk by chunk, so a chatty fan-out does not
    /// redraw the panel thousands of times a second.
    @ObservationIgnored private let pending = MXOutputBuffer()
    @ObservationIgnored private let flusher = Repeater()

    private func flushOutput() {
        let batch = pending.drain()
        if batch.isEmpty {
            if procs.values.allSatisfy(\.isEmpty) { flusher.stop() }
            return
        }
        for b in batch {
            updateResult(b.runId, b.connId) { r in
                if !b.out.isEmpty { r.stdout += b.out; r.stdout = MultiExecService.tail(r.stdout) }
                if !b.err.isEmpty { r.stderr += b.err; r.stderr = MultiExecService.tail(r.stderr) }
            }
        }
    }

    /// The last `outputCap` bytes of a stream, starting on a character.
    nonisolated static func tail(_ s: String, cap: Int = outputCap) -> String {
        let u = s.utf8
        guard u.count > cap else { return s }
        var start = u.index(u.endIndex, offsetBy: -cap)
        while start < u.endIndex, (u[start] & 0xC0) == 0x80 { start = u.index(after: start) }
        return String(s[start...])
    }

    private func updateResult(_ runId: String, _ connId: String, _ body: (inout MultiExecResult) -> Void) {
        update(runId) { v in
            if let j = v.results.firstIndex(where: { $0.connId == connId }) { body(&v.results[j]) }
        }
    }

    /// `multiexec:run`: `connIds` are already-created connections. Answers as
    /// soon as the run is under way.
    @discardableResult
    func run(_ connIds: [String], command: String, options: Options = Options()) async -> MultiExecView {
        let cm = ConnectionManager.shared
        let conns = connIds.compactMap { cm.connection($0) }
        // Ensure each master is up before fanning out; connecting in parallel
        // is fine because each connection has its own control socket.
        await withTaskGroup(of: Void.self) { g in
            for c in conns { g.addTask { @MainActor in try? await c.connect() } }
        }
        seq += 1
        let runId = "run\(seq)"
        var results: [MultiExecResult] = conns.map { MultiExecResult(connId: $0.id, label: $0.label) }
        var live: [Connection] = []
        for (i, c) in conns.enumerated() {
            if c.state == .connected { live.append(c); continue }
            results[i].status = "error"
            results[i].stderr = c.error ?? "not connected"
            results[i].endedAt = nowMs()
        }
        let view = MultiExecView(id: runId, command: command, startedAt: nowMs(), endedAt: nil, results: results)
        runs.insert(view, at: 0)
        procs[runId] = [:]
        let opts = options
        Task { @MainActor in await self.start(runId, live, command, opts) }
        return view
    }

    private func start(_ runId: String, _ targets: [Connection], _ command: String, _ o: Options) async {
        let queue = MXQueue(targets)
        let workers = min(max(1, o.concurrency), targets.count)
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<workers {
                g.addTask { @MainActor in
                    while true {
                        if self.cancelled.contains(runId) { return }
                        guard let t = queue.next() else { return }
                        await self.runOne(runId, t, command, timeout: o.timeout)
                        if o.stopOnError, self.view(runId)?.results.first(where: { $0.connId == t.id })?.status != "done" {
                            self.cancel(runId)
                            return
                        }
                    }
                }
            }
        }
        update(runId) { $0.endedAt = nowMs() }
        procs[runId] = nil
        if let v = view(runId) { onDone.forEach { $0(v) } }
    }

    private func runOne(_ runId: String, _ conn: Connection, _ command: String, timeout: Double) async {
        guard !cancelled.contains(runId) else { return }
        let connId = conn.id
        updateResult(runId, connId) { $0.status = "running"; $0.startedAt = nowMs() }
        /*
         * No TTY (`ssh -T`), so stdout/stderr stay separate and the remote
         * command sees a clean non-interactive environment. A connection on
         * the tsh transport has no ssh in the picture at all — the node
         * demands per-session MFA, or this machine has no OpenSSH client — so
         * the command goes through `tsh ssh` exactly as its own sessions do;
         * a beam through `tsh beams exec`. The environment carries the
         * connection's tsh home either way (ssh reaches a Teleport node
         * through `tsh proxy ssh`).
         */
        let inv = conn.execInvocation(command)
        let buffer = pending
        let cap: (Bool, Data) -> Void = { isOut, d in buffer.append(runId, connId, isOut: isOut, d) }
        if !flusher.isRunning { flusher.start(every: 0.1) { [weak self] in self?.flushOutput() } }
        let proc: RunningProcess
        do {
            proc = try RunningProcess(inv.exe, inv.args, env: inv.env,
                                      onStdout: { cap(true, $0) }, onStderr: { cap(false, $0) })
        } catch {
            let msg = (error as? AppError)?.message ?? error.localizedDescription
            updateResult(runId, connId) { r in
                r.stderr += msg
                r.exitCode = nil
                r.endedAt = nowMs()
                r.durationMs = r.endedAt! - (r.startedAt ?? r.endedAt!)
                r.status = self.cancelled.contains(runId) ? "cancelled" : "error"
            }
            return
        }
        proc.closeStdin()
        procs[runId]?[connId] = proc
        var killedBy: String?
        let timer = DispatchWorkItem { killedBy = "timeout"; proc.signal(SIGKILL) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout / 1000, execute: timer)
        let code = await proc.wait()
        timer.cancel()
        // Let queued output callbacks land before the result is closed.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
        procs[runId]?[connId] = nil
        flushOutput()
        updateResult(runId, connId) { r in
            // A process killed by a signal has no exit code (Node gives null).
            let signalled = proc.process.terminationReason == .uncaughtSignal
            r.exitCode = signalled ? nil : code
            r.endedAt = nowMs()
            r.durationMs = r.endedAt! - (r.startedAt ?? r.endedAt!)
            if killedBy == "timeout" { r.status = "timeout" }
            else if self.cancelled.contains(runId) { r.status = "cancelled" }
            else { r.status = !signalled && code == 0 ? "done" : "error" }
        }
    }

    /// `multiexec:cancel`.
    func cancel(_ runId: String) {
        cancelled.insert(runId)
        for p in (procs[runId] ?? [:]).values { p.signal(SIGKILL) }
        update(runId) { v in
            for i in v.results.indices where v.results[i].status == "pending" || v.results[i].status == "running" {
                v.results[i].status = "cancelled"
            }
        }
    }

    /// `multiexec:clear`: forget the finished runs.
    func clear() {
        runs.removeAll { !$0.running }
    }
}

/// The hosts still to run, shared by a run's workers (all on the main actor).
@MainActor
private final class MXQueue {
    private var items: [Connection]
    init(_ items: [Connection]) { self.items = items }
    func next() -> Connection? { items.isEmpty ? nil : items.removeFirst() }
}

/// Bytes from the children's pipes, per run and host, until the next flush.
/// A UTF-8 sequence split across reads is held back until it is whole.
final class MXOutputBuffer: @unchecked Sendable {
    struct Batch { var runId: String; var connId: String; var out: String; var err: String }
    private let lock = NSLock()
    private var order: [String] = []
    private var bufs: [String: (runId: String, connId: String, out: Data, err: Data)] = [:]

    func append(_ runId: String, _ connId: String, isOut: Bool, _ d: Data) {
        let key = runId + "\u{0}" + connId
        lock.lock(); defer { lock.unlock() }
        if bufs[key] == nil { bufs[key] = (runId, connId, Data(), Data()); order.append(key) }
        if isOut { bufs[key]!.out.append(d) } else { bufs[key]!.err.append(d) }
    }

    func drain() -> [Batch] {
        lock.lock(); defer { lock.unlock() }
        var out: [Batch] = []
        for key in order {
            guard var b = bufs[key] else { continue }
            let (o, oRest) = MXOutputBuffer.split(b.out)
            let (e, eRest) = MXOutputBuffer.split(b.err)
            b.out = oRest; b.err = eRest
            bufs[key] = b
            if !o.isEmpty || !e.isEmpty {
                out.append(Batch(runId: b.runId, connId: b.connId, out: String(decoding: o, as: UTF8.self),
                                 err: String(decoding: e, as: UTF8.self)))
            }
        }
        return out
    }

    /// Complete characters, and an incomplete trailing sequence to keep.
    static func split(_ d: Data) -> (Data, Data) {
        let n = d.count
        guard n > 0 else { return (d, Data()) }
        let bytes = [UInt8](d.suffix(4))
        var i = bytes.count - 1
        var back = 0
        while i >= 0 && back < 4 && (bytes[i] & 0xC0) == 0x80 { i -= 1; back += 1 }
        guard i >= 0 else { return (d, Data()) }
        let lead = bytes[i]
        let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        let have = bytes.count - i
        if have < need {
            let cut = n - have
            return (Data(d.prefix(cut)), Data(d.suffix(have)))
        }
        return (d, Data())
    }
}
