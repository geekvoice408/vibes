import Foundation

/// The download history in the dock: what was pulled, from which host, how
/// big, when, and where it landed (main.js `recordDownloads` and the
/// `downloads:*` handlers).
///
/// The rows live in the store's top-level `downloads` array, in store.js's
/// shape. The store methods (`addDownload`, `listDownloads`, …) belong to the
/// data owner; until theirs are published the small `fs…` helpers at the
/// bottom of this file do the same thing, with the same rules.
@MainActor
enum DownloadHistory {
    struct Row: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var localPath: String
        var name: String
        /// Where it came from: a remote path, or an s3:// key.
        var source: String
        /// The host or bucket, as the UI labels it.
        var from: String
        /// "file" | "folder"
        var kind: String
        var bytes: Int64
        var files: Int
        var at: Double
    }

    /// Newest first (`downloads:list`).
    static func list() -> [Row] { Store.shared.fsListDownloads() }

    /// `downloads:forget` — never touches the file itself.
    @discardableResult
    static func forget(_ id: String) -> [Row] {
        Store.shared.fsDeleteDownload(id)
        return list()
    }

    /// `downloads:clear`.
    static func clear() { Store.shared.fsClearDownloads() }

    /// `downloads:check`: whether each file is still where it was put. Asked
    /// for the whole list at once rather than per row, so the panel can grey
    /// out what has been moved or deleted instead of offering an Open that
    /// silently does nothing.
    static func check(_ paths: [String]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for p in paths { out[p] = FileManager.default.fileExists(atPath: p) }
        return out
    }

    /// Add one row (S3 downloads call this too). Same path → the old row is
    /// moved to the top with the new details.
    @discardableResult
    static func add(localPath: String, name: String? = nil, source: String = "", from: String = "",
                    kind: String = "file", bytes: Int64 = 0, files: Int = 1) -> Row? {
        Store.shared.fsAddDownload(localPath: localPath, name: name, source: source, from: from, kind: kind,
                                   bytes: bytes, files: files)
    }

    /// A row `record` would add (pure, for tests and previews).
    struct Planned: Equatable, Sendable {
        var localPath: String
        var name: String
        var source: String
        var kind: String
        var bytes: Int64
        var files: Int
    }

    /// Remember a finished download job.
    ///
    /// Only downloads: an upload leaves nothing on this machine to go and
    /// find. A flat selection of files is remembered file by file, which is
    /// what makes "open the one I pulled down" possible; a folder is
    /// remembered as the folder, because a tree of two thousand files is one
    /// gesture and would otherwise bury everything else. The per-job cap is
    /// the same idea for a very wide selection.
    @discardableResult
    static func record(_ job: FinishedTransfer) -> [Row] {
        plan(job).compactMap {
            add(localPath: $0.localPath, name: $0.name, source: $0.source, from: job.from, kind: $0.kind,
                bytes: $0.bytes, files: $0.files)
        }
    }

    nonisolated static func plan(_ job: FinishedTransfer) -> [Planned] {
        guard job.kind == "download" else { return [] }
        let items = job.items.filter { !$0.local.isEmpty }
        if items.isEmpty { return [] }
        var rows: [Planned] = []
        let sep = "/"

        /*
         * Downloading a directory brings its local directories with it, so the
         * top-level ones — those with no other local dir above them — are the
         * folders that were asked for. One selection can hold both folders and
         * loose files, so both are recorded: a row per folder, then a row per
         * file that is not inside one of them.
         */
        var seen = Set<String>()
        let dirs = job.dirs.filter { seen.insert($0).inserted }.sorted { $0.count < $1.count }
        let tops = dirs.filter { d in !dirs.contains { o in o != d && d.hasPrefix(o + sep) } }

        for top in tops {
            // The remote folder as it was asked for; the first file's own
            // directory would name whichever leaf the walk happened to reach first.
            let topName = (top as NSString).lastPathComponent
            let source = job.roots.first { Posix.basename($0) == topName }
                ?? (tops.count == 1 ? (job.roots.first ?? "") : "")
            let inside = items.filter { $0.local.hasPrefix(top + sep) }
            rows.append(Planned(localPath: top, name: topName, source: source, kind: "folder",
                                bytes: inside.reduce(0) { $0 + $1.size }, files: inside.count))
        }

        // Loose files, capped: a very wide selection is still a list to read.
        let loose = items.filter { i in !tops.contains { i.local.hasPrefix($0 + sep) } }
        for i in loose.prefix(20) {
            rows.append(Planned(localPath: i.local, name: (i.local as NSString).lastPathComponent, source: i.remote,
                                kind: "file", bytes: i.size, files: 1))
        }
        return rows
    }
}

// Stand-ins for the data owner's store.js ports (addDownload, listDownloads,
// deleteDownload, clearDownloads). Same rules: newest first, one row per
// local path, at most 300 rows.
extension Store {
    fileprivate func fsListDownloads() -> [DownloadHistory.Row] {
        list("downloads", as: DownloadHistory.Row.self).sorted { $0.at > $1.at }
    }

    fileprivate func fsAddDownload(localPath: String, name: String?, source: String, from: String, kind: String,
                                   bytes: Int64, files: Int) -> DownloadHistory.Row? {
        if localPath.isEmpty { return nil }
        let now = nowMs()
        var rows = self["downloads"].items
        if let i = rows.firstIndex(where: { $0["localPath"].string == localPath }) {
            var merged = rows.remove(at: i)
            merged.merge(["name": .string(name ?? fsLastSegment(localPath)), "source": .string(source), "from": .string(from),
                          "kind": .string(kind), "bytes": .number(Double(bytes)), "files": .number(Double(files)),
                          "at": .number(now)])
            rows.insert(merged, at: 0)
            self["downloads"] = .array(rows)
            return merged.decode(DownloadHistory.Row.self)
        }
        let row = DownloadHistory.Row(id: newId("dl"), localPath: localPath, name: name ?? fsLastSegment(localPath),
                                      source: source, from: from, kind: kind, bytes: bytes, files: max(1, files), at: now)
        rows.insert(JSON.encode(row), at: 0)
        if rows.count > 300 { rows = Array(rows.prefix(300)) }
        self["downloads"] = .array(rows)
        return row
    }

    fileprivate func fsDeleteDownload(_ id: String) {
        mutate("downloads") { $0 = .array($0.items.filter { $0["id"].string != id }) }
    }

    fileprivate func fsClearDownloads() {
        self["downloads"] = .array([])
    }
}
