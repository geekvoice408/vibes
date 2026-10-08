import Foundation

/// Recursive search, on this machine and on a server (src/main/findfiles.js
/// and main.js's `local:search` / `sftp:search`).
///
/// The file browser's filter only ever looked at what was already listed,
/// which answers "where in this folder" and not "where on this box" — the
/// question people actually arrive with. Two searches, because they are
/// different questions: a name, and a string inside the files.
///
/// On a server this is `find` and `grep`, built as arguments and quoted for
/// the shell exactly once, with a cap on results so a search of `/` cannot
/// fill the window or the connection. Locally it is a bounded walk in this
/// process, which costs nothing and avoids spawning anything at all.
enum FindFiles {
    /// Never walk into these locally: they are big, boring, and rarely the answer.
    static let skipDirs: Set<String> = [
        ".git", "node_modules", ".svn", ".hg", ".cache", "Library", ".Trash",
        ".npm", ".nvm", ".rustup", ".cargo", "venv", ".venv", "__pycache__",
    ]

    /// What to look for, and the budgets.
    ///
    /// Budgets, not just a result cap: a home directory is tens of thousands
    /// of entries three levels down and millions twelve levels down, so a
    /// search for a name that is not there walks the lot. The result cap only
    /// stops a search that is *finding* things; these stop one that is not,
    /// which is the case that hangs.
    struct Options: Codable, Sendable {
        var dir: String
        var pattern: String = ""
        var content: String = ""
        var caseSensitive = false
        /// "all" | "files" | "dirs"
        var kinds = "all"
        var limit = 400
        var maxDepth = 6
        var contentBytes = 2 * 1024 * 1024
        var maxEntries = 250_000
        var maxMs: Double = 6000

        init(dir: String, pattern: String = "", content: String = "", caseSensitive: Bool = false, kinds: String = "all",
             limit: Int = 400, maxDepth: Int = 6) {
            self.dir = dir; self.pattern = pattern; self.content = content; self.caseSensitive = caseSensitive
            self.kinds = kinds; self.limit = limit; self.maxDepth = maxDepth
        }
    }

    struct Hit: Codable, Sendable, Hashable {
        var path: String
        var name: String
        var type: FileType
        var size: Int64?
        var mtime: Double?
        /// Content searches: the 1-based line and the line itself.
        var line: Int?
        var excerpt: String?
    }

    struct Outcome: Codable, Sendable {
        var results: [Hit]
        /// Local only: how many entries were looked at.
        var scanned: Int?
        var truncated: Bool
        /// Local only: why it stopped — "time" or "entries" — so the window
        /// can say so rather than implying the tree holds nothing else.
        var stopped: String?
        var elapsedMs: Double?
        var `where`: String
        /// Remote only: the command that ran.
        var command: String?
    }

    /// Turn what someone typed into a glob `find -name` will accept.
    ///
    /// A bare word means "contains", because that is what a search box
    /// implies — requiring `*log*` to find `mylog.txt` is a rule nobody
    /// remembers. Anything already carrying a wildcard is left exactly as written.
    static func toGlob(_ pattern: String) -> String {
        let p = pattern.trimmed
        if p.isEmpty { return "*" }
        return p.contains(where: { "*?[]".contains($0) }) ? p : "*" + p + "*"
    }

    /// Does this name match the glob? Used for the local walk.
    static func globToRegex(_ glob: String, caseSensitive: Bool) -> NSRegularExpression? {
        var body = ""
        for ch in glob {
            switch ch {
            case ".", "+", "^", "$", "{", "}", "(", ")", "|", "\\": body += "\\" + String(ch)
            case "*": body += ".*"
            case "?": body += "."
            default: body.append(ch)
            }
        }
        return try? NSRegularExpression(pattern: "^" + body + "$", options: caseSensitive ? [] : [.caseInsensitive])
    }

    // MARK: - Local

    /// Walk a local tree, matching names and optionally file contents.
    ///
    /// Breadth-first with a depth cap and a result cap, so a mistaken search of
    /// `/` stops rather than running for a minute. Unreadable directories are
    /// skipped silently — a permission error on one folder is not a failed search.
    static func searchLocal(_ o: Options) async throws -> Outcome {
        if o.dir.isEmpty { throw AppError("Which folder? A starting directory is needed.") }
        guard let re = globToRegex(toGlob(o.pattern), caseSensitive: o.caseSensitive) else {
            return Outcome(results: [], scanned: 0, truncated: false, stopped: nil, elapsedMs: 0, where: o.dir)
        }
        let needle = o.content
        let started = Date()
        func elapsed() -> Double { Date().timeIntervalSince(started) * 1000 }
        var results: [Hit] = []
        var scanned = 0
        var truncated = false
        var stopped: String?
        var queue: [(dir: String, depth: Int)] = [(o.dir, 0)]
        var qi = 0

        outer: while qi < queue.count && results.count < o.limit {
            if elapsed() > o.maxMs { stopped = "time"; break }
            if scanned > o.maxEntries { stopped = "entries"; break }
            let (here, depth) = queue[qi]; qi += 1
            guard let names = try? LocalFS.readdir(here) else { continue }
            for name in names {
                if results.count >= o.limit { truncated = true; break }
                // Checked inside the loop too: one directory can hold a hundred
                // thousand files, which is long enough to matter on its own.
                if scanned & 0x3ff == 0 && elapsed() > o.maxMs { stopped = "time"; break outer }
                let full = (here as NSString).appendingPathComponent(name)
                let st = LocalFS.lstat(full)
                let isDir = st?.isDir ?? false
                scanned += 1
                if isDir && depth < o.maxDepth && !skipDirs.contains(name) { queue.append((full, depth + 1)) }
                if o.kinds == "files" && isDir { continue }
                if o.kinds == "dirs" && !isDir { continue }
                if !re.matches(name) { continue }

                // With a content search, a name match is only a candidate.
                if !needle.isEmpty && !isDir {
                    guard let fst = LocalFS.stat(full), fst.size <= Int64(o.contentBytes),
                          let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else { continue }
                    let text = String(decoding: data, as: UTF8.self)
                    guard let r = text.range(of: needle, options: o.caseSensitive ? [] : [.caseInsensitive]) else { continue }
                    let line = text[..<r.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                    results.append(Hit(path: full, name: name, type: .file, line: line, excerpt: excerpt(text, at: r.lowerBound)))
                    continue
                }
                if !needle.isEmpty && isDir { continue }
                let s2 = LocalFS.stat(full)
                results.append(Hit(path: full, name: name, type: isDir ? .directory : .file, size: s2?.size, mtime: s2?.mtimeMs))
            }
        }
        return Outcome(results: results, scanned: scanned,
                       truncated: truncated || stopped != nil || qi < queue.count,
                       stopped: stopped, elapsedMs: elapsed(), where: o.dir)
    }

    /// One line around a hit, trimmed for a list.
    static func excerpt(_ text: String, at: String.Index) -> String {
        let start = text[..<at].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[at...].firstIndex(of: "\n") ?? text.endIndex
        return String(text[start..<end].prefix(300)).trimmed
    }

    // MARK: - Remote

    /// The command for a remote search.
    ///
    /// `find` for names; `grep -rIn` when there is text to look for, which also
    /// does the walking. Both get `2>/dev/null` so an unreadable directory
    /// does not fill the result with noise, and `head` so the cap is enforced
    /// on the server rather than by reading a million lines over the wire.
    static func remoteCommand(_ o: Options) throws -> String {
        if o.dir.isEmpty { throw AppError("Which folder? A starting directory is needed.") }
        let glob = toGlob(o.pattern)
        let nameFlag = o.caseSensitive ? "-name" : "-iname"
        let typeFlag = o.kinds == "files" ? " -type f" : o.kinds == "dirs" ? " -type d" : ""
        let limit = o.limit > 0 ? o.limit : 200
        if !o.content.isEmpty {
            // `-I` skips binaries, `-s` silences unreadable files, and the name
            // pattern becomes --include so a search can be narrowed to *.conf.
            let include = o.pattern.isEmpty ? "" : " --include=\(shellQuote(glob))"
            let ci = o.caseSensitive ? "" : " -i"
            return "grep -rIn\(ci)\(include) -e \(shellQuote(o.content)) -- \(shellQuote(o.dir)) 2>/dev/null | head -n \(limit)"
        }
        // `-printf` is GNU; BSD find does not have it. The type and size are
        // worth having, so it is tried and the caller falls back to plain
        // paths when the output comes back empty.
        let depth = o.maxDepth > 0 ? o.maxDepth : 12
        return "find \(shellQuote(o.dir)) -maxdepth \(depth)\(typeFlag) \(nameFlag) \(shellQuote(glob)) "
            + "-printf '%y\\t%s\\t%T@\\t%p\\n' 2>/dev/null | head -n \(limit)"
    }

    /// The same search without `-printf`, for a `find` that does not have it.
    static func remoteCommandPlain(_ o: Options) -> String {
        let glob = toGlob(o.pattern)
        let nameFlag = o.caseSensitive ? "-name" : "-iname"
        let typeFlag = o.kinds == "files" ? " -type f" : o.kinds == "dirs" ? " -type d" : ""
        let depth = o.maxDepth > 0 ? o.maxDepth : 12
        let limit = o.limit > 0 ? o.limit : 200
        return "find \(shellQuote(o.dir)) -maxdepth \(depth)\(typeFlag) \(nameFlag) \(shellQuote(glob)) -print 2>/dev/null | head -n \(limit)"
    }

    private static let grepLine = try! NSRegularExpression(pattern: #"^(.*?):(\d+):(.*)$"#)

    /// Parse whichever of the three output shapes came back.
    static func parseRemote(_ text: String, content: String = "", limit: Int = 400) -> (results: [Hit], truncated: Bool) {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
        var results: [Hit] = []
        for line in lines {
            if results.count >= limit { break }
            if !content.isEmpty {
                // grep -n: path:line:text
                let ns = line as NSString
                guard let m = grepLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                let p = ns.substring(with: m.range(at: 1))
                results.append(Hit(path: p, name: fsLastSegment(p), type: .file,
                                   line: Int(ns.substring(with: m.range(at: 2))),
                                   excerpt: String(ns.substring(with: m.range(at: 3)).trimmed.prefix(300))))
                continue
            }
            if line.contains("\t") {
                let parts = line.components(separatedBy: "\t")
                let p = parts.dropFirst(3).joined(separator: "\t")
                if parts.count < 4 || p.isEmpty { continue }
                let y = parts[0]
                let t = Double(parts[2]) ?? 0
                results.append(Hit(path: p, name: fsLastSegment(p),
                                   type: y == "d" ? .directory : y == "l" ? .symlink : .file,
                                   size: Int64(parts[1]) ?? 0, mtime: t != 0 ? (t * 1000).rounded() : nil))
                continue
            }
            results.append(Hit(path: line, name: fsLastSegment(line), type: .file))
        }
        return (results, lines.count >= limit)
    }

    /// `sftp:search`: the same search on a server, over the connection already open.
    ///
    /// `find -printf` is GNU-only, so a run that comes back with nothing is
    /// tried again in the portable form before reporting an empty result — a
    /// BSD or busybox host should answer the question too, just with less detail.
    @MainActor
    static func searchRemote(connId: String, _ o: Options) async throws -> Outcome {
        let cmd = try remoteCommand(o)
        var out = try await FilesBridge.run(connId, cmd)
        var parsed = parseRemote(out, content: o.content, limit: o.limit)
        if parsed.results.isEmpty && o.content.isEmpty {
            out = (try? await FilesBridge.run(connId, remoteCommandPlain(o))) ?? ""
            parsed = parseRemote(out, content: o.content, limit: o.limit)
        }
        return Outcome(results: parsed.results, scanned: nil, truncated: parsed.truncated, stopped: nil, elapsedMs: nil,
                       where: o.dir, command: cmd)
    }
}
