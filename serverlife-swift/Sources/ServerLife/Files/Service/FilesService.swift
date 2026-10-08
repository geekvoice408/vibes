import Foundation
import Observation

/// The files service: one SFTP channel and one transfer queue per open
/// connection, and the operations main.js exposed as `sftp:*`, `xfer:*` and
/// `sync:*`.
///
/// Connections are the connections owner's; this keeps, per connection id,
/// the lazily-opened `SFTPClient` (connections.js `getSftp()`) and the
/// `TransferQueue` (connections.js `this.queue`). Call `connectionClosed(_:)`
/// when a session goes away.
@MainActor
@Observable
final class FilesService {
    static let shared = FilesService()

    /// Every connection's transfer queue, by connection id — what the
    /// transfers panel draws.
    private(set) var queues: [String: TransferQueue] = [:]

    @ObservationIgnored private var clients: [String: SFTPClient] = [:]
    @ObservationIgnored private var opening: [String: Task<SFTPClient, Error>] = [:]
    /// What happens to a finished job (tests replace it to keep the store untouched).
    @ObservationIgnored var onJobFinished: (FinishedTransfer) -> Void = { DownloadHistory.record($0) }

    // MARK: - SFTP channels

    /// The connection's SFTP client, opened on first use and kept.
    func sftp(_ connId: String) async throws -> SFTPClient {
        if let c = clients[connId], !c.closed { return c }
        if let t = opening[connId] { return try await t.value }
        // (A tsh channel the far side dropped is refused by the connection
        // layer until the user asks again: re-opening costs an MFA approval.)
        let transport = FilesBridge.connection(connId)?.transport ?? "mux"
        // A tsh or beam channel may be waiting on an MFA approval.
        let timeout: TimeInterval = transport == "tsh" || transport == "beam" ? 120 : 30
        let t = Task { @MainActor [weak self] () throws -> SFTPClient in
            let ch = try await FilesBridge.openChannel(connId)
            let c = SFTPClient(channel: ch)
            c.onClose { [weak self] _ in
                Task { @MainActor in self?.clientClosed(connId, c) }
            }
            do { try await c.connect(timeout: timeout) } catch { c.destroy(); throw error }
            return c
        }
        opening[connId] = t
        do {
            let c = try await t.value
            opening[connId] = nil
            clients[connId] = c
            return c
        } catch {
            opening[connId] = nil
            throw error
        }
    }

    private func clientClosed(_ connId: String, _ c: SFTPClient) {
        guard clients[connId] === c else { return }
        clients[connId] = nil
    }

    /// The session has gone: its channel, its queue and its watches go with it.
    /// A watcher whose connection has gone would upload into nothing, and its
    /// row would claim to be live.
    ///
    /// The queue is not cancelled, as in the original, where it simply went
    /// away with its connection: destroying the channel fails whatever is
    /// mid-transfer ("SFTP closed"), and anything still queued fails when it
    /// asks for a channel the queue no longer has — errors, not "cancelled".
    func connectionClosed(_ connId: String) {
        Watches.shared.stopForConnection(connId)
        opening[connId]?.cancel()
        opening[connId] = nil
        queues.removeValue(forKey: connId)
        clients.removeValue(forKey: connId)?.destroy()
    }

    // MARK: - Queues

    /// The connection's transfer queue (created on first use). A speed limit
    /// is a preference about the link, so a queue made later starts with
    /// whatever limit is already in force.
    func queue(_ connId: String) -> TransferQueue {
        if let q = queues[connId] { return q }
        final class Ref { weak var q: TransferQueue? }
        let ref = Ref()
        let q = TransferQueue(getSftp: { @MainActor [weak self] in
            // A queue whose connection has gone gets no new channel.
            guard let self, let mine = ref.q, self.queues[connId] === mine else {
                throw AppError("That connection is not open any more.")
            }
            return try await self.sftp(connId)
        })
        ref.q = q
        q.setLimit(Store.shared.filesTransferLimitKb * 1024)
        // Passed on with the connection's own label attached: the record of a
        // download wants to say which server it came off.
        q.onFinished.append { [weak self] job in
            var j = job
            j.from = FilesBridge.connection(connId)?.label ?? ""
            self?.onJobFinished(j)
        }
        queues[connId] = q
        return q
    }

    /// `xfer:limit`: the speed limit is a preference, so it is applied to every
    /// queue — the one being changed and any other connection already open.
    /// Returns the stored KB/s.
    @discardableResult
    func setLimit(kbPerSecond: Double) -> Int {
        let bytes = Int(max(0, kbPerSecond) * 1024)
        Store.shared.filesTransferLimitKb = Int((Double(bytes) / 1024).rounded())
        for q in queues.values { q.setLimit(bytes) }
        return Store.shared.filesTransferLimitKb
    }

    // MARK: - sftp:*

    /// `sftp:home`.
    func home(_ connId: String) async throws -> String {
        let s = try await sftp(connId)
        if let h = FilesBridge.connection(connId)?.homeDir?.nilIfEmpty { return h }
        return try await s.realpath(".")
    }

    /// `sftp:list`. Always hands back an absolute path: the UI shows it and
    /// navigates from it, and "." or "~" would break going to the parent.
    /// Symlink targets are resolved so the UI knows what is enterable.
    func list(_ connId: String, _ dir: String?) async throws -> FileListing {
        let s = try await sftp(connId)
        let target: String
        if let dir, !dir.isEmpty, dir != "~", dir != "." {
            target = (try? await s.realpath(dir)) ?? dir
        } else {
            target = try await s.realpath(".")
        }
        let entries = try await s.list(target)
        let resolved = await withTaskGroup(of: (Int, FileEntry).self) { g in
            for (i, e) in entries.enumerated() where e.type == .symlink { g.addTask { (i, await s.resolveEntry(e)) } }
            var out = entries
            for await (i, e) in g { out[i] = e }
            return out
        }
        return FileListing(path: target, entries: resolved)
    }

    func realpath(_ connId: String, _ p: String) async throws -> String { try await sftp(connId).realpath(p) }
    func mkdir(_ connId: String, _ p: String) async throws { try await sftp(connId).mkdir(p) }
    func rename(_ connId: String, _ a: String, _ b: String) async throws { try await sftp(connId).rename(a, b) }
    func chmod(_ connId: String, _ p: String, mode: UInt32) async throws { try await sftp(connId).chmod(p, mode) }
    func stat(_ connId: String, _ p: String) async throws -> SFTPClient.Attrs { try await sftp(connId).stat(p) }

    /// `sftp:remove`: a directory (not a link to one) goes recursively.
    func remove(_ connId: String, _ entries: [FileEntry]) async throws {
        let s = try await sftp(connId)
        for e in entries {
            if e.isDirectoryLike && e.type != .symlink { try await s.removeTree(e.path) }
            else { try await s.remove(e.path) }
        }
    }

    /// `sftp:readFile`, for the inline editor.
    func readFile(_ connId: String, _ p: String, maxBytes: Int = 2 * 1024 * 1024) async throws -> String {
        String(decoding: try await sftp(connId).readFile(p, maxBytes: maxBytes), as: UTF8.self)
    }

    /// `sftp:writeFile`.
    func writeFile(_ connId: String, _ p: String, _ text: String) async throws {
        try await sftp(connId).writeFile(p, Data(text.utf8))
    }

    /// `sftp:search`.
    func search(_ connId: String, _ o: FindFiles.Options) async throws -> FindFiles.Outcome {
        try await FindFiles.searchRemote(connId: connId, o)
    }

    // MARK: - xfer:*

    /// `xfer:upload`: local files and folders into a remote directory. Returns the job id.
    @discardableResult
    func upload(_ connId: String, localPaths: [String], remoteDir: String) async throws -> String {
        _ = try await sftp(connId)
        var items: [Transfers.Item] = [], dirs: [String] = []
        for lp in localPaths {
            let plan = try await Transfers.planUpload(lp, remoteDir: remoteDir)
            items += plan.files; dirs += plan.dirs
        }
        let label = localPaths.count == 1 ? (localPaths[0] as NSString).lastPathComponent : "\(localPaths.count) items"
        return queue(connId).add(TransferJobSpec(kind: "upload", label: "\(label) → \(remoteDir)", items: items, dirs: dirs))
    }

    /// `xfer:download`: remote entries into a local directory. Returns the job id.
    @discardableResult
    func download(_ connId: String, entries: [FileEntry], localDir: String) async throws -> String {
        let s = try await sftp(connId)
        var items: [Transfers.Item] = [], dirs: [String] = []
        for e in entries {
            let plan = try await Transfers.planDownload(s, remotePath: e.path, localDir: localDir, known: e)
            items += plan.files; dirs += plan.dirs
        }
        let label = entries.count == 1 ? (entries[0].name.isEmpty ? Posix.basename(entries[0].path) : entries[0].name)
                                       : "\(entries.count) items"
        return queue(connId).add(TransferJobSpec(kind: "download", label: "\(label) → \(localDir)", items: items, dirs: dirs,
                                                 roots: entries.map(\.path).filter { !$0.isEmpty }))
    }

    /// `xfer:crossPlan`: which route a server-to-server copy would take, without starting it.
    func crossPlan(_ srcConnId: String, _ destConnId: String) throws -> CrossTransfer.Route {
        CrossTransfer.planRoute(try FilesBridge.require(srcConnId), try FilesBridge.require(destConnId))
    }

    /// `xfer:cross`.
    func cross(_ srcConnId: String, entries: [FileEntry], to destConnId: String, destDir: String,
               mode: String? = nil) async throws -> CrossTransfer.Started {
        let src = try FilesBridge.require(srcConnId)
        let dest = try FilesBridge.require(destConnId)
        if src.id == dest.id { throw AppError("Source and destination are the same session") }
        async let a = sftp(srcConnId)
        async let b = sftp(destConnId)
        _ = try await (a, b)
        return try await CrossTransfer.transfer(src: src, dest: dest, entries: entries, destDir: destDir, mode: mode)
    }

    // Queue controls (`xfer:cancel` …) are methods on `queue(connId)`.

    // MARK: - sync:*

    /// `sync:plan`: what a sync would do, without doing any of it.
    func syncPlan(_ connId: String, _ req: SyncPlanner.Request) async throws -> SyncPlanner.Plan {
        await SyncPlanner.plan(try await sftp(connId), req)
    }

    /// `sync:apply`: a reviewed plan, with whichever actions survived the
    /// review (all of them when `actions` is nil).
    func syncApply(_ connId: String, _ planned: SyncPlanner.Plan, actions: [SyncPlanner.Action]? = nil) async throws -> SyncPlanner.ApplyResult {
        let s = try await sftp(connId)
        return await SyncPlanner.apply(planned, actions ?? planned.actions, queue: queue(connId), sftp: s)
    }
}

extension Store {
    /// settings.transferLimitKb — KB/s across every transfer, 0 for none.
    var filesTransferLimitKb: Int {
        get { setting("transferLimitKb", 0) }
        set { setSetting("transferLimitKb", newValue) }
    }

    /// settings.externalEditor — the command for *Edit in my editor…*, or "" for the OS default.
    var filesExternalEditor: String { setting("externalEditor", "") }
}
