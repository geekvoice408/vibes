import Foundation

/// Directory synchronisation: walk both sides, work out what differs, and say
/// so before anything moves (src/main/syncdirs.js, plus main.js's
/// `applySyncPlan` and `describePlan`).
///
/// The whole value of a sync tool is the sentence "here is what I am about to
/// do" — a transfer that silently overwrote the wrong side is worse than no
/// sync at all. So the planner only ever *plans*. Applying a plan is a list
/// of ordinary transfers handed to the connection's queue, which means sync
/// inherits its progress, its cancellation and its rates for free.
///
/// Two deliberate refusals:
///   - **Symlinks are never followed and never transferred.** Following one
///     turns a sync into an unbounded walk, and copying one replaces a link
///     with the bytes it pointed at. They are counted and reported instead.
///   - **Deleting is opt-in, per direction, and never in both-ways mode.**
enum SyncPlanner {
    /// Names that are noise in every tree and would only ever cause churn.
    static let alwaysSkip: Set<String> = [".DS_Store", "Thumbs.db", ".localized"]

    /// How far apart two timestamps can be and still count as the same file.
    /// SFTP carries mtime in whole seconds while a local stat has
    /// milliseconds, so a file that was just copied compares unequal to
    /// itself. Two seconds absorbs that without hiding a real edit.
    static let mtimeSlackMs: Double = 2000

    struct Limits: Sendable {
        var maxEntries = 200_000
        var maxMs: Double = 45_000
    }

    struct FileStat: Sendable, Equatable {
        var size: Int64
        var mtime: Double
    }

    struct Tree: Sendable {
        var files: [String: FileStat] = [:]
        var dirs: Set<String> = []
        var links = 0
        var truncated = false
        var exists = true
    }

    /// The plan actions that change something, as opposed to reporting
    /// (`SYNC_DOING` in main.js).
    static let doingOps: Set<String> = ["upload", "download", "deleteRemote", "deleteLocal", "rmdirRemote", "rmdirLocal"]

    /// One row of the plan. `op` is upload, download, deleteRemote,
    /// deleteLocal, rmdirRemote, rmdirLocal, same or skip.
    struct Action: Codable, Hashable, Sendable {
        var op: String
        var rel: String
        var size: Int64
        var why: String
        /// Set (true or false) on one-direction overwrites: true when what is
        /// being replaced is newer — the one case worth flagging.
        var overwritesNewer: Bool?
        var dir: Bool?
        var doing: Bool { SyncPlanner.doingOps.contains(op) }
    }

    struct Summary: Codable, Sendable, Equatable {
        var upload = 0, download = 0, deleteRemote = 0, deleteLocal = 0, rmdirRemote = 0, rmdirLocal = 0
        /// What deleting *would* remove, when it is switched off. Without this
        /// the dialog has nothing to say about a file the source no longer
        /// has, and "sync did not remove my deletion" looks like a bug rather
        /// than an option that is off.
        var wouldDelete = 0
        var same = 0, skip = 0
        var bytes: Int64 = 0
        var overwritesNewer = 0
        var links = 0
        var truncated = false
        var localMissing = false
        var remoteMissing = false
    }

    struct Plan: Codable, Sendable {
        var localDir: String
        var remoteDir: String
        /// "up" (local → remote), "down", or "both" (newer wins, nothing deleted).
        var direction: String
        /// "both" (size and time), "size", or "time".
        var compare: String
        var actions: [Action]
        var dirsUp: [String]
        var dirsDown: [String]
        var summary: Summary
    }

    struct Request: Codable, Sendable {
        var localDir: String
        var remoteDir: String
        var direction = "up"
        var del = false
        var compare = "both"
        init(localDir: String, remoteDir: String, direction: String = "up", del: Bool = false, compare: String = "both") {
            self.localDir = localDir; self.remoteDir = remoteDir; self.direction = direction; self.del = del; self.compare = compare
        }
    }

    // MARK: - Walking

    private static func relJoin(_ rel: String, _ name: String) -> String { rel.isEmpty ? name : rel + "/" + name }

    /// Walk a local tree into files and directories, relative to `root`.
    static func walkLocal(_ root: String, limits: Limits = Limits()) async -> Tree {
        let started = Date()
        var t = Tree()
        func walk(_ rel: String) {
            if t.truncated { return }
            let abs = rel.isEmpty ? root : (root as NSString).appendingPathComponent(rel)
            guard let names = try? LocalFS.readdir(abs) else { return }
            for name in names {
                if t.files.count >= limits.maxEntries || Date().timeIntervalSince(started) * 1000 > limits.maxMs {
                    t.truncated = true
                    return
                }
                if alwaysSkip.contains(name) { continue }
                let childRel = relJoin(rel, name)
                // Gone or unreadable: it is left out of the comparison.
                guard let st = LocalFS.lstat((root as NSString).appendingPathComponent(childRel)) else { continue }
                if st.isLink { t.links += 1; continue }
                if st.isDir { t.dirs.insert(childRel); walk(childRel); continue }
                if !st.isFile { continue }
                t.files[childRel] = FileStat(size: st.size, mtime: st.mtimeMs)
            }
        }
        t.exists = LocalFS.isDir(root)
        if t.exists { walk("") }
        return t
    }

    /// The same walk over SFTP.
    static func walkRemote(_ sftp: SFTPClient, _ root: String, limits: Limits = Limits()) async -> Tree {
        let started = Date()
        var t = Tree()
        func walk(_ rel: String) async {
            if t.truncated { return }
            let abs = rel.isEmpty ? root : Posix.join(root, rel)
            guard let entries = try? await sftp.list(abs) else { return }
            for e in entries {
                if t.files.count >= limits.maxEntries || Date().timeIntervalSince(started) * 1000 > limits.maxMs {
                    t.truncated = true
                    return
                }
                if alwaysSkip.contains(e.name) { continue }
                let childRel = relJoin(rel, e.name)
                if e.type == .symlink { t.links += 1; continue }
                if e.type == .directory { t.dirs.insert(childRel); await walk(childRel); continue }
                if e.type != .file { continue }
                t.files[childRel] = FileStat(size: e.size, mtime: e.mtime ?? 0)
            }
        }
        if let a = try? await sftp.stat(root) { t.exists = a.isDirectory } else { t.exists = false }
        if t.exists { await walk("") }
        return t
    }

    // MARK: - Planning

    /// Whether two files count as already in sync.
    ///
    /// `both` — size and time — is the honest default: it is the only one of
    /// the three that never calls two different files the same. `size` suits
    /// an artefact directory where the clock is noise; `time` suits a source
    /// tree where an editor rewrites a file to the same length.
    static func sameFile(_ a: FileStat, _ b: FileStat, _ criterion: String = "both") -> Bool {
        let sameSize = a.size == b.size
        let sameTime = abs(a.mtime - b.mtime) <= mtimeSlackMs
        if criterion == "size" { return sameSize }
        if criterion == "time" { return sameTime }
        return sameSize && sameTime
    }

    static func plan(_ sftp: SFTPClient, _ req: Request) async -> Plan {
        async let l = walkLocal(req.localDir)
        async let r = walkRemote(sftp, req.remoteDir)
        return compare(local: await l, remote: await r, req)
    }

    /// Compare two walked trees and return the work.
    static func compare(local: Tree, remote: Tree, _ req: Request) -> Plan {
        let direction = req.direction, del = req.del, cmp = req.compare
        var actions: [Action] = []
        let both = direction == "both"
        let names = Set(local.files.keys).union(remote.files.keys)

        // JavaScript's default sort: UTF-16 code units.
        for rel in names.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }) {
            let l = local.files[rel], r = remote.files[rel]
            if let l, r == nil {
                if direction == "up" || both {
                    actions.append(Action(op: "upload", rel: rel, size: l.size, why: "not on the server"))
                } else if del {
                    actions.append(Action(op: "deleteLocal", rel: rel, size: l.size, why: "not on the server"))
                } else {
                    actions.append(Action(op: "skip", rel: rel, size: l.size, why: "only here"))
                }
                continue
            }
            if let r, l == nil {
                if direction == "down" || both {
                    actions.append(Action(op: "download", rel: rel, size: r.size, why: "not on this machine"))
                } else if del {
                    actions.append(Action(op: "deleteRemote", rel: rel, size: r.size, why: "not on this machine"))
                } else {
                    actions.append(Action(op: "skip", rel: rel, size: r.size, why: "only on the server"))
                }
                continue
            }
            guard let l, let r else { continue }
            if sameFile(l, r, cmp) {
                actions.append(Action(op: "same", rel: rel, size: l.size,
                                      why: cmp == "size" ? "same size" : cmp == "time" ? "same time" : "same size and time"))
                continue
            }
            let localNewer = l.mtime > r.mtime + mtimeSlackMs
            let why = localNewer ? "newer here" : "newer on the server"
            if both {
                actions.append(Action(op: localNewer ? "upload" : "download", rel: rel, size: localNewer ? l.size : r.size, why: why))
            } else if direction == "up" {
                // Uploading something the server has newer is the one case
                // worth flagging rather than doing quietly.
                actions.append(Action(op: "upload", rel: rel, size: l.size, why: why, overwritesNewer: !localNewer))
            } else {
                actions.append(Action(op: "download", rel: rel, size: r.size, why: why, overwritesNewer: localNewer))
            }
        }

        // Directories that only exist on one side have to be created before
        // any file lands in them; the transfer queue makes them, so they only
        // need listing when they are empty of work.
        let dirsUp = local.dirs.subtracting(remote.dirs).sorted(by: jsLess)
        let dirsDown = remote.dirs.subtracting(local.dirs).sorted(by: jsLess)

        /*
         * Folders the other side no longer has.
         *
         * Deleting the files inside a folder and leaving the folder is not what
         * "make these two the same" means. Deepest first, so each one is empty
         * by the time it is removed — and a folder that still has something in
         * it (a row the user unticked, a file this walk never saw) fails to
         * remove and is reported rather than forced.
         */
        if del && direction != "both" {
            let gone = direction == "up" ? dirsDown : dirsUp
            let deepestFirst = gone.sorted { x, y in
                let dx = x.split(separator: "/", omittingEmptySubsequences: false).count
                let dy = y.split(separator: "/", omittingEmptySubsequences: false).count
                if dx != dy { return dx > dy }
                return y.localizedCompare(x) == .orderedAscending
            }
            for rel in deepestFirst {
                actions.append(Action(op: direction == "up" ? "rmdirRemote" : "rmdirLocal", rel: rel, size: 0,
                                      why: direction == "up" ? "folder not on this machine" : "folder not on the server",
                                      dir: true))
            }
        }

        func count(_ op: String) -> Int { actions.filter { $0.op == op }.count }
        var s = Summary()
        s.upload = count("upload"); s.download = count("download")
        s.deleteRemote = count("deleteRemote"); s.deleteLocal = count("deleteLocal")
        s.rmdirRemote = count("rmdirRemote"); s.rmdirLocal = count("rmdirLocal")
        s.wouldDelete = count("skip"); s.same = count("same"); s.skip = count("skip")
        s.bytes = actions.filter { $0.op == "upload" || $0.op == "download" }.reduce(0) { $0 + $1.size }
        s.overwritesNewer = actions.filter { $0.overwritesNewer == true }.count
        s.links = local.links + remote.links
        s.truncated = local.truncated || remote.truncated
        s.localMissing = !local.exists
        s.remoteMissing = !remote.exists
        return Plan(localDir: req.localDir, remoteDir: req.remoteDir, direction: direction, compare: cmp, actions: actions,
                    dirsUp: direction == "down" ? [] : dirsUp, dirsDown: direction == "up" ? [] : dirsDown, summary: s)
    }

    private static func jsLess(_ a: String, _ b: String) -> Bool { Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16)) }

    /// Turn a plan into the transfer items the queue takes. Only the actions
    /// the caller kept: the preview is editable, so what comes back here may
    /// be a subset of what was planned.
    static func items(_ planned: Plan, _ actions: [Action])
        -> (uploads: [Transfers.Item], downloads: [Transfers.Item], upDirs: [String], downDirs: [String]) {
        var uploads: [Transfers.Item] = [], downloads: [Transfers.Item] = []
        for a in actions {
            let local = (planned.localDir as NSString).appendingPathComponent(a.rel)
            let remote = Posix.join(planned.remoteDir, a.rel)
            if a.op == "upload" { uploads.append(Transfers.Item(local: local, remote: remote, size: a.size)) }
            else if a.op == "download" { downloads.append(Transfers.Item(local: local, remote: remote, size: a.size)) }
        }
        func unique(_ xs: [String]) -> [String] { var seen = Set<String>(); return xs.filter { seen.insert($0).inserted } }
        // Folders with nothing in them to transfer, which the queue would
        // otherwise never create, are added after the files' own parents.
        // Parents before children: the queue makes each folder with a plain
        // MKDIR, which fails when the folder above it does not exist yet.
        func parentsFirst(_ xs: [String]) -> [String] {
            xs.sorted { x, y in
                let dx = x.split(separator: "/").count, dy = y.split(separator: "/").count
                return dx != dy ? dx < dy : jsLess(x, y)
            }
        }
        let upDirs = parentsFirst(unique(uploads.map { Posix.parent($0.remote) } + planned.dirsUp.map { Posix.join(planned.remoteDir, $0) })
            .filter { !$0.isEmpty && $0 != "." })
        let downDirs = parentsFirst(unique(downloads.map { ($0.local as NSString).deletingLastPathComponent }
            + planned.dirsDown.map { (planned.localDir as NSString).appendingPathComponent($0) }))
        return (uploads, downloads, upDirs, downDirs)
    }

    // MARK: - Applying

    struct ApplyResult: Codable, Sendable {
        var jobs: [String]
        var uploads: Int
        var downloads: Int
        var removed: Int
        var failures: [String]
    }

    /// Apply a reviewed plan (`applySyncPlan`). Transfers go through the
    /// connection's own queue, so a sync is visible, cancellable and
    /// rate-reported like anything else. Deletions are done here and counted
    /// back, since there is no queue for "remove this".
    ///
    /// Shared by the dialog and the control socket so both behave identically
    /// — including the one protection that cannot be left to the caller: a
    /// folder removal is recursive on the other side (a Teleport node's SFTP
    /// service implements RMDIR as a recursive delete), so a list that keeps a
    /// file but removes the folder above it would lose the file anyway. Such a
    /// folder is dropped from the work: unticking a file unticks its folder's
    /// removal.
    static func apply(_ planned: Plan, _ actions: [Action], queue: TransferQueue, sftp: SFTPClient) async -> ApplyResult {
        let keptInside = Set(planned.actions
            .filter { a in a.op.hasPrefix("delete") && !actions.contains(where: { k in k.rel == a.rel && k.op == a.op }) }
            .map(\.rel))
        let list = keptInside.isEmpty ? actions : actions.filter { a in
            !(a.op.hasPrefix("rmdir") && keptInside.contains { $0 == a.rel || $0.hasPrefix(a.rel + "/") })
        }

        let (uploads, downloads, upDirs, downDirs) = items(planned, list)
        var jobs: [String] = []
        if !uploads.isEmpty {
            jobs.append(await queue.add(TransferJobSpec(kind: "upload", label: "sync ↑ \(uploads.count) file(s) → \(planned.remoteDir)",
                                                        items: uploads, dirs: upDirs, roots: [planned.localDir])))
        }
        if !downloads.isEmpty {
            jobs.append(await queue.add(TransferJobSpec(kind: "download", label: "sync ↓ \(downloads.count) file(s) → \(planned.localDir)",
                                                        items: downloads, dirs: downDirs, roots: [planned.remoteDir])))
        }

        var removed = 0
        var failures: [String] = []
        for a in list {
            do {
                switch a.op {
                case "deleteRemote":
                    try await sftp.remove(Posix.join(planned.remoteDir, a.rel))
                    removed += 1
                case "deleteLocal":
                    let p = (planned.localDir as NSString).appendingPathComponent(a.rel)
                    // `rm -f`: one already gone is not a failure.
                    if Darwin.unlink(p) != 0 && errno != ENOENT { throw LocalFS.nodeError("unlink", p) }
                    removed += 1
                case "rmdirRemote":
                    /*
                     * Emptiness is checked here, not left to the server.
                     *
                     * A Teleport node's SFTP service implements RMDIR as a
                     * recursive delete, so handing it a folder that still
                     * contains something destroys that something — a file the
                     * walk never saw, one added since the plan was made, or one
                     * this sync deliberately ignores (`.DS_Store`). Nothing may
                     * be deleted that the plan did not list, so the folder is
                     * looked at first and kept if anything is in it.
                     */
                    let dir = Posix.join(planned.remoteDir, a.rel)
                    let left = (try? await sftp.list(dir)) ?? []
                    if !left.isEmpty {
                        failures.append("\(a.rel): kept — still has \(left.count) item(s) in it")
                    } else {
                        try await sftp.rmdir(dir)
                        removed += 1
                    }
                case "rmdirLocal":
                    // The same rule locally, where rmdir does refuse a
                    // non-empty directory — checked anyway, so both sides read
                    // the same way.
                    let dir = (planned.localDir as NSString).appendingPathComponent(a.rel)
                    let left = (try? LocalFS.readdir(dir)) ?? []
                    if !left.isEmpty {
                        failures.append("\(a.rel): kept — still has \(left.count) item(s) in it")
                    } else {
                        if Darwin.rmdir(dir) != 0 { throw LocalFS.nodeError("rmdir", dir) }
                        removed += 1
                    }
                default: break
                }
            } catch {
                let msg = errorText(error)
                let notEmpty = msg.range(of: "not empty|ENOTEMPTY|failure", options: [.regularExpression, .caseInsensitive]) != nil
                failures.append("\(a.rel): \(notEmpty && a.dir == true ? "still has something in it" : msg)")
            }
        }
        return ApplyResult(jobs: jobs, uploads: uploads.count, downloads: downloads.count, removed: removed, failures: failures)
    }

    /// A plan, summarised for a caller that cannot see the dialog (the
    /// control socket). The action list is capped: a first sync of a large
    /// tree is thousands of lines, and an agent needs the shape of the work
    /// and a sample of it, not every path.
    static func describe(_ planned: Plan, limit: Int = 200) -> JSON {
        let doing = planned.actions.filter(\.doing)
        return [
            "localDir": .string(planned.localDir),
            "remoteDir": .string(planned.remoteDir),
            "direction": .string(planned.direction),
            "compare": .string(planned.compare),
            "summary": JSON.encode(planned.summary),
            "actionCount": .number(Double(doing.count)),
            "actions": .array(doing.prefix(limit).map {
                ["op": .string($0.op), "path": .string($0.rel), "bytes": .number(Double($0.size)), "why": .string($0.why)]
            }),
            "truncated": .bool(doing.count > limit),
        ]
    }
}
