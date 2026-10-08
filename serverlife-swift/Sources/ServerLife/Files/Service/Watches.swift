import AppKit
import CoreServices
import Foundation
import Observation

/// Two things that are the same thing: a local file being watched, and
/// whatever it should be pushed to when it changes (src/main/watchdirs.js and
/// main.js's `watch:*` handlers).
///
///   - **Keep a directory up to date** — you edit a tree on this machine and
///     it lands on the server as you save, which is the whole build-deploy
///     loop for anything interpreted.
///   - **Edit a remote file in your own editor** — the file comes down to a
///     temporary copy, opens in whatever you use, and every save goes back up.
///
/// Both are a watch plus an upload, so both live here and appear in one list.
///
/// What it will not do: delete, or download. A watcher that mirrors deletions
/// is a watcher that can empty a server because a checkout was moved.
/// Removals are left to a deliberate sync, where they are previewed first.
@MainActor
@Observable
final class Watches {
    static let shared = Watches()

    /// One row of the dock's Watch panel (`watchdirs.list()`).
    struct View: Identifiable, Codable, Equatable, Sendable {
        var id: String
        /// "dir" | "edit"
        var kind: String
        var connId: String
        var label: String
        var localDir: String
        var localPath: String?
        var remoteDir: String?
        var remotePath: String?
        var started: Double
        var uploads: Int
        var errors: Int
        var lastFile: String?
        var lastAt: Double?
        var lastError: String?
        /// Always false on macOS (FSEvents watches recursively); kept for the
        /// shape the panel expects.
        var flatOnly: Bool
        /// Set when the editor could not be opened: the watch still runs and
        /// the panel can say where the file is.
        var openError: String?
    }

    /// One upload (or failed upload), for an activity line.
    struct Event: Sendable {
        var ok: Bool
        var rel: String
        var bytes: Int64?
        var error: String?
        var at: Double
    }

    /// The live list.
    private(set) var list: [View] = []
    /// Called after every upload attempt, with the watch id.
    @ObservationIgnored var onEvent: [(String, Event) -> Void] = []
    /// Replaces opening the editor (tests).
    @ObservationIgnored var openHook: ((String) throws -> Void)?

    @ObservationIgnored private var recs: [String: Rec] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var seq = 0

    /// Noise that would otherwise upload itself every few seconds.
    static let skipPatterns: [NSRegularExpression] = [
        #"(^|/)\.DS_Store$"#, #"(^|/)Thumbs\.db$"#,
        #"(^|/)\.git(/|$)"#, #"(^|/)node_modules(/|$)"#,
        #"(^|/)\.#"#, #"~$"#, #"\.swp$"#, #"\.tmp$"#, #"^\.~lock"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func skip(_ rel: String) -> Bool { skipPatterns.contains { $0.matches(rel) } }

    /// How long to wait after a change before uploading.
    ///
    /// An editor writing a file produces several events — truncate, write,
    /// rename — and uploading on the first one sends an empty file. This waits
    /// for the writes to stop, which is also what coalesces "save all" into one pass.
    static let settle: Double = 0.4

    final class Rec {
        var view: View
        var watcher: FSWatcher?
        var pending: [String: DispatchWorkItem] = [:]
        var lastSize: Int64 = -1
        var lastMtime: Double = -1
        init(view: View) { self.view = view }
    }

    // MARK: - Keep a folder up to date

    /// Watch a local directory and upload what changes (`watch:dir`).
    @discardableResult
    func watchDir(connId: String, localDir: String, remoteDir: String) throws -> View {
        guard !localDir.isEmpty, LocalFS.isDir(localDir) else { throw AppError("ENOENT: no such file or directory, watch '\(localDir)'") }
        seq += 1
        let id = "w\(seq)"
        let label = FilesBridge.connection(connId)?.label ?? connId
        let rec = Rec(view: View(id: id, kind: "dir", connId: connId, label: label, localDir: localDir, localPath: nil,
                                 remoteDir: remoteDir, remotePath: nil, started: nowMs(), uploads: 0, errors: 0,
                                 lastFile: nil, lastAt: nil, lastError: nil, flatOnly: false, openError: nil))
        let root = realPathOf(localDir)
        rec.watcher = FSWatcher(paths: [root]) { [weak self, weak rec] paths in
            guard let self, let rec else { return }
            for p in paths {
                guard let rel = Self.relative(p, root: root, alt: localDir), !rel.isEmpty, !Self.skip(rel) else { continue }
                rec.pending[rel]?.cancel()
                let w = DispatchWorkItem { [weak self, weak rec] in
                    MainActor.assumeIsolated {
                        guard let self, let rec else { return }
                        rec.pending[rel] = nil
                        Task { await self.pushDir(rec, rel) }
                    }
                }
                rec.pending[rel] = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: w)
            }
        }
        if rec.watcher == nil { rec.view.lastError = "Could not watch \(localDir)" }
        add(rec)
        return rec.view
    }

    private func pushDir(_ rec: Rec, _ rel: String) async {
        guard recs[rec.view.id] === rec else { return }
        let local = (rec.view.localDir as NSString).appendingPathComponent(rel)
        guard let st = LocalFS.lstat(local) else { return }      // gone again
        if st.isLink || st.isDir { return }
        let remote = Posix.join(rec.view.remoteDir ?? "/", rel)
        do {
            let sftp = try await FilesService.shared.sftp(rec.view.connId)
            // The parent may be new; mkdir the chain and ignore "exists".
            await Self.mkdirp(sftp, Posix.parent(remote))
            try await Transfers.uploadFile(sftp, local: local, remote: remote)
            rec.view.uploads += 1
            rec.view.lastFile = rel
            rec.view.lastAt = nowMs()
            rec.view.lastError = nil
            emit(rec, Event(ok: true, rel: rel, bytes: st.size, at: rec.view.lastAt!))
        } catch {
            rec.view.errors += 1
            rec.view.lastError = errorText(error)
            rec.view.lastAt = nowMs()
            emit(rec, Event(ok: false, rel: rel, error: rec.view.lastError, at: rec.view.lastAt!))
        }
    }

    // MARK: - Edit in my editor

    /// Bring a remote file down, open it, and push every save back (`watch:edit`).
    ///
    /// The temporary copy keeps the original name so the editor gets its
    /// syntax highlighting right, under a per-edit directory so two files
    /// called `config.yaml` cannot collide.
    @discardableResult
    func editRemote(connId: String, remotePath: String) async throws -> View {
        seq += 1
        let id = "e\(seq)"
        let name = Posix.basename(remotePath).nilIfEmpty ?? "file"
        var rnd = [UInt8](repeating: 0, count: 5)
        arc4random_buf(&rnd, 5)
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "serverlife-edit-" + rnd.map { String(format: "%02x", $0) }.joined())
        try LocalFS.ensureDir(dir)
        let local = (dir as NSString).appendingPathComponent(name)

        let sftp = try await FilesService.shared.sftp(connId)
        try await Transfers.downloadFile(sftp, remote: remotePath, local: local)

        let label = FilesBridge.connection(connId)?.label ?? connId
        let rec = Rec(view: View(id: id, kind: "edit", connId: connId, label: label, localDir: dir, localPath: local,
                                 remoteDir: nil, remotePath: remotePath, started: nowMs(), uploads: 0, errors: 0,
                                 lastFile: nil, lastAt: nil, lastError: nil, flatOnly: false, openError: nil))
        if let st = LocalFS.stat(local) { rec.lastSize = st.size; rec.lastMtime = st.mtimeMs }

        // The directory, not the file: editors that save by writing a new file
        // and renaming it over the old one would leave a watch on the file
        // itself looking at a name that no longer exists.
        let root = realPathOf(dir)
        rec.watcher = FSWatcher(paths: [root]) { [weak self, weak rec] paths in
            guard let self, let rec else { return }
            guard paths.contains(where: { Self.relative($0, root: root, alt: dir) == name }) else { return }
            rec.pending["file"]?.cancel()
            let w = DispatchWorkItem { [weak self, weak rec] in
                MainActor.assumeIsolated {
                    guard let self, let rec else { return }
                    rec.pending["file"] = nil
                    Task { await self.pushEdit(rec) }
                }
            }
            rec.pending["file"] = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: w)
        }
        add(rec)
        // Handing it to the editor last: if opening fails there is still a
        // watcher and a path, and the caller can say where the file is.
        do { try openInEditor(local) } catch {
            rec.view.openError = errorText(error)
            refresh()
        }
        return rec.view
    }

    private func pushEdit(_ rec: Rec) async {
        guard recs[rec.view.id] === rec, let local = rec.view.localPath, let remote = rec.view.remotePath else { return }
        guard let st = LocalFS.stat(local) else { return }
        // An editor can touch the file without changing it (and some write
        // twice); uploading only on a real change keeps the audit log honest.
        if st.size == rec.lastSize && st.mtimeMs == rec.lastMtime { return }
        rec.lastSize = st.size
        rec.lastMtime = st.mtimeMs
        let name = (local as NSString).lastPathComponent
        do {
            let s = try await FilesService.shared.sftp(rec.view.connId)
            try await Transfers.uploadFile(s, local: local, remote: remote)
            rec.view.uploads += 1
            rec.view.lastAt = nowMs()
            rec.view.lastError = nil
            emit(rec, Event(ok: true, rel: name, bytes: st.size, at: rec.view.lastAt!))
        } catch {
            rec.view.errors += 1
            rec.view.lastError = errorText(error)
            rec.view.lastAt = nowMs()
            emit(rec, Event(ok: false, rel: name, error: rec.view.lastError, at: rec.view.lastAt!))
        }
    }

    /// The editor the OS already associates with the file type, unless the
    /// user has named one in Settings — a preference that exists because
    /// "open in my editor" means a specific editor to most people. Split on
    /// spaces so `code -w` and `subl` both work; the path is passed as its own
    /// argument and never through a shell.
    func openInEditor(_ path: String) throws {
        if let openHook { try openHook(path); return }
        let cmd = Store.shared.filesExternalEditor.trimmed
        if cmd.isEmpty {
            try LocalFS.open(path)
            return
        }
        let parts = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard let exe = Proc.which(parts[0]) else { throw AppError("spawn \(parts[0]) ENOENT") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(parts.dropFirst()) + [path]
        p.environment = Proc.environment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw AppError("spawn \(parts[0]): \(error.localizedDescription)") }
    }

    // MARK: - Stopping

    /// Stop one watch. A remote edit also takes its temporary copy with it.
    func stop(_ id: String, keepTemp: Bool = false) {
        guard let rec = recs.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        rec.watcher?.stop()
        rec.pending.values.forEach { $0.cancel() }
        if rec.view.kind == "edit" && !keepTemp {
            // A leftover temp dir is harmless.
            try? FileManager.default.removeItem(atPath: rec.view.localDir)
        }
        refresh()
    }

    /// Everything belonging to a connection that has gone away.
    func stopForConnection(_ connId: String) {
        for id in order where recs[id]?.view.connId == connId { stop(id) }
    }

    /// Every watch (the app is quitting).
    func stopAll() {
        for id in order { stop(id) }
    }

    // MARK: - Helpers

    private func add(_ rec: Rec) {
        recs[rec.view.id] = rec
        order.append(rec.view.id)
        refresh()
    }

    private func emit(_ rec: Rec, _ e: Event) {
        refresh()
        onEvent.forEach { $0(rec.view.id, e) }
    }

    private func refresh() {
        let v = order.compactMap { recs[$0]?.view }
        if v != list { list = v }
    }

    static func relative(_ path: String, root: String, alt: String) -> String? {
        for r in [root, alt] {
            let base = r.hasSuffix("/") ? r : r + "/"
            if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
            if path == r { return "" }
        }
        return nil
    }

    static func mkdirp(_ sftp: SFTPClient, _ dir: String) async {
        if dir.isEmpty || dir == "/" || dir == "." { return }
        var at = dir.hasPrefix("/") ? "" : "."
        for p in dir.split(separator: "/") {
            at = at.isEmpty ? "/" + p : at + "/" + p
            try? await sftp.mkdir(at)
        }
    }
}

/// The real path (FSEvents reports /private/var for /var).
func realPathOf(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

/// A recursive, file-level FSEvents watch delivering absolute paths on the
/// main queue (fs.watch(dir, { recursive: true }) in the original).
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let callback: ([String]) -> Void

    init?(paths: [String], latency: Double = 0.05, _ callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.callback(Array(arr.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        if !FSEventStreamStart(s) {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
            return nil
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
