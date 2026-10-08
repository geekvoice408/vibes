import Foundation

// The pure pieces of explorer.js and rsyncsync.js: sorting, icons, the name
// filter, permission text and its explanation, the comparison verdict, the
// commands Permissions-and-owner runs, the starred-folder id scheme. Kept free
// of any UI or state so they can be tested on their own.

enum XP {
    /// A directory, or a link to one (`isDir` in explorer.js).
    static func isDir(_ e: FileEntry) -> Bool { e.type == .directory || e.targetType == .directory }

    /// `shq`: quote a path for a remote shell — paths contain spaces and worse.
    static func shq(_ p: String) -> String { shellQuote(p) }

    // MARK: - Sorting

    /// `sortEntries` from util.js.
    ///
    /// Folders first unless that is turned off; then by the key, in the sort's
    /// direction. Ties break on the name, and *not* in the sort's direction:
    /// two files of the same size, or written in the same second, have to
    /// come out in a fixed order or the list reshuffles itself every time it
    /// is drawn.
    static func sortEntries(_ entries: [FileEntry], key: String = "name", dir: Int = 1,
                            foldersFirst: Bool = true) -> [FileEntry] {
        // Stable: equal elements keep the order they arrived in, as JS's sort does.
        let indexed = Array(entries.enumerated())
        return indexed.sorted { x, y in
            let r = order(x.element, y.element, key: key, dir: dir, foldersFirst: foldersFirst)
            if r != 0 { return r < 0 }
            return x.offset < y.offset
        }.map(\.element)
    }

    private static func order(_ a: FileEntry, _ b: FileEntry, key: String, dir: Int, foldersFirst: Bool) -> Int {
        let ad = isDir(a), bd = isDir(b)
        if foldersFirst && ad != bd { return ad ? -1 : 1 }
        var r = 0
        if key == "size" {
            r = a.size == b.size ? 0 : (a.size < b.size ? -1 : 1)
        } else if key == "mtime" {
            let am = a.mtime ?? 0, bm = b.mtime ?? 0
            r = am == bm ? 0 : (am < bm ? -1 : 1)
        } else {
            r = cmp(a.name, b.name)
        }
        if r != 0 { return r * dir }
        return key == "name" ? 0 : cmp(a.name, b.name)
    }

    private static func cmp(_ a: String, _ b: String) -> Int {
        switch compareNames(a, b) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    // MARK: - Icons

    /// `fileIcon` from util.js.
    static func fileIcon(_ e: FileEntry) -> String {
        if isDir(e) { return "\u{1F4C1}" }
        if e.type == .symlink { return "\u{1F517}" }
        let ext = (e.name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? "").lowercased()
        if let m = e.mode, m & 0o111 != 0, e.type == .file { return "\u{2699}" }
        if ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp"].contains(ext) { return "\u{1F5BC}" }
        if ["zip", "gz", "tar", "tgz", "bz2", "xz", "7z", "rar", "zst"].contains(ext) { return "\u{1F4E6}" }
        if ["js", "ts", "py", "go", "rs", "c", "h", "cpp", "java", "rb", "php", "sh", "bash", "zsh"].contains(ext) { return "\u{1F4C4}" }
        if ["json", "yaml", "yml", "toml", "ini", "conf", "cfg", "xml"].contains(ext) { return "\u{2699}" }
        if ["md", "txt", "log", "rst"].contains(ext) { return "\u{1F4DD}" }
        if ["pem", "key", "crt", "cer", "pub"].contains(ext) { return "\u{1F511}" }
        return "\u{1F4C4}"
    }

    // MARK: - Name filter

    /// A predicate over entry names, or nil for "everything" (`_matcher`).
    ///
    /// Plain text matches anywhere in the name, because that is what a few
    /// remembered letters of a filename are. `*` and `?` turn it into a glob
    /// anchored at both ends, so `*.log` means what it does in a shell rather
    /// than matching a file called `mylog.txt`.
    static func matcher(_ filter: String) -> ((String) -> Bool)? {
        let q = filter.trimmed.lowercased()
        if q.isEmpty { return nil }
        if q.contains("*") || q.contains("?") {
            var body = ""
            for ch in q {
                if ch == "*" { body += ".*" } else if ch == "?" { body += "." }
                else { body += NSRegularExpression.escapedPattern(for: String(ch)) }
            }
            // A half-typed glob can still be an invalid pattern; fall back to a
            // substring match rather than failing on every keystroke.
            guard let re = try? NSRegularExpression(pattern: "^" + body + "$", options: [.dotMatchesLineSeparators]) else {
                return { $0.lowercased().contains(q) }
            }
            return { re.matches($0.lowercased()) }
        }
        return { $0.lowercased().contains(q) }
    }

    // MARK: - Permissions

    /// `permText`: permissions as both forms, plus the bits a mode string
    /// hides in plain sight. The octal is four digits when setuid, setgid or
    /// the sticky bit is set, which is the form you would type into chmod.
    static func permText(mode: UInt32?, modeString: String?) -> String {
        let m = mode ?? 0
        var special: [String] = []
        if m & 0o4000 != 0 { special.append("setuid") }
        if m & 0o2000 != 0 { special.append("setgid") }
        if m & 0o1000 != 0 { special.append("sticky") }
        let octal = m & 0o7000 != 0 ? pad(String(m & 0o7777, radix: 8), 4) : pad(String(m & 0o777, radix: 8), 3)
        return "\(modeString ?? "")  (\(octal))".trimmed + (special.isEmpty ? "" : "  · " + special.joined(separator: ", "))
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: "0", count: n - s.count) + s
    }

    /// The octal a mode field is prefilled with: `(mode & 0o7777).toString(8).padStart(3, '0')`.
    static func octal(_ mode: UInt32?) -> String { pad(String((mode ?? 0) & 0o7777, radix: 8), 3) }

    /// `ownerText`: `owner:group`, preferring names over numbers, one value
    /// when both are the same.
    static func ownerText(owner: String?, group: String?, uid: UInt32?, gid: UInt32?) -> String {
        let o = owner?.nilIfEmpty ?? uid.map { String($0) } ?? ""
        let g = group?.nilIfEmpty ?? gid.map { String($0) } ?? ""
        if o.isEmpty && g.isEmpty { return "" }
        if g.isEmpty || o == g { return o }
        return "\(o):\(g)"
    }

    static func ownerText(_ e: FileEntry) -> String { ownerText(owner: e.owner, group: e.group, uid: e.uid, gid: e.gid) }

    /// What `explainPermissions` puts on screen, as data.
    struct PermExplanation: Equatable {
        struct Lane: Equatable { var bits: String; var who: String }
        struct Line: Equatable { var label: String; var text: String }
        var intro: String
        var lanes: [Lane]
        var lines: [Line]
        var notes: [String]
        var octalNote: String
    }

    /// The permission bits, read back in words — chosen for what this entry
    /// actually is: `x` on a file is "run it", on a directory it is "go
    /// through it".
    static func explainPermissions(mode: UInt32?, modeString: String?, owner: String?, group: String?,
                                   folder: Bool) -> PermExplanation {
        let m = mode ?? 0
        let who: [(label: String, of: String, shift: UInt32)] = [
            ("Owner", owner.map { "\($0)" } ?? "the owning account", 6),
            ("Group", group.map { "members of \($0)" } ?? "the owning group", 3),
            ("Others", "everyone else with an account on the machine", 0),
        ]
        let verbs = folder
            ? (r: "list what is in it", w: "create, rename and delete things in it", x: "enter it and reach what is inside")
            : (r: "read it", w: "change or overwrite it", x: "run it as a program")

        var bits = String((modeString ?? "").dropFirst().prefix(9))
        while bits.count < 9 { bits += "-" }
        let chars = Array(bits)
        var lanes: [PermExplanation.Lane] = []
        for (i, label) in ["Owner", "Group", "Others"].enumerated() {
            let b = String(chars[(i * 3)..<(i * 3 + 3)])
            lanes.append(.init(bits: b.isEmpty ? "---" : b, who: label))
        }

        var lines: [PermExplanation.Line] = []
        for w in who {
            var can: [String] = []
            if m & (4 << w.shift) != 0 { can.append(verbs.r) }
            if m & (2 << w.shift) != 0 { can.append(verbs.w) }
            if m & (1 << w.shift) != 0 { can.append(verbs.x) }
            let sentence = !can.isEmpty
                ? "can " + (can.count > 1 ? can.dropLast().joined(separator: ", ") + " and " + can.last! : can[0])
                : (folder ? "cannot see inside it or enter it" : "cannot read it at all")
            lines.append(.init(label: w.label + ": ", text: "\(w.of) \(sentence)."))
        }

        var notes: [String] = []
        if folder && (m & 0o111) == 0 {
            notes.append("Nobody has the execute bit, so this directory cannot be entered by anyone — "
                + "a path through it fails even where the listing is readable.")
        }
        if folder && (m & 0o1000) != 0 {
            notes.append("The sticky bit is set: anyone may create things here, but only the owner of a "
                + "file (or of the directory) may delete or rename it. This is what makes /tmp safe to share.")
        }
        if !folder && (m & 0o4000) != 0 {
            notes.append("Setuid is set: this program runs with the privileges of its owner"
                + (owner.map { " (\($0))" } ?? "") + ", not of whoever starts it.")
        }
        if !folder && (m & 0o2000) != 0 {
            notes.append("Setgid is set: this program runs with the privileges of its group"
                + (group.map { " (\($0))" } ?? "") + ", not of whoever starts it.")
        }
        if folder && (m & 0o2000) != 0 {
            notes.append("Setgid is set on the directory: new files inside inherit its group"
                + (group.map { " (\($0))" } ?? "") + " rather than the creator’s.")
        }
        if !folder && (m & 0o111) != 0 && (m & 0o444) == 0 {
            notes.append("It is executable but not readable — a script needs to be read to be interpreted, "
                + "so this only works for a compiled binary.")
        }
        if (m & 0o002) != 0 {
            notes.append("The last group includes write: anyone with an account can change "
                + (folder ? "what is in this directory" : "this file") + ".")
        }
        let octalNote = "The octal form adds the same three permissions up per group: read is 4, write is 2, "
            + "execute is 1. So 6 is read and write, 7 is all three, 5 is read and execute — "
            + "and \(pad(String(m & 0o777, radix: 8), 3)) is what this one has."
        return PermExplanation(
            intro: "Nine letters in three groups of three — owner, then group, then everyone else. "
                + "A letter means the permission is granted, a dash means it is not.",
            lanes: lanes, lines: lines, notes: notes, octalNote: octalNote)
    }

    /// The commands *Permissions and owner…* runs: `chmod`, then `chown
    /// user:group` (both in one call) or `chgrp` for a group on its own.
    static func permissionCommands(paths: [String], mode: String, owner: String, group: String,
                                   recursive: Bool) -> [String] {
        let R = recursive ? " -R" : ""
        let quoted = paths.map(shq).joined(separator: " ")
        var out: [String] = []
        let mode = mode.trimmed, owner = owner.trimmed, group = group.trimmed
        if !mode.isEmpty { out.append("chmod\(R) \(mode) \(quoted)") }
        if !owner.isEmpty { out.append("chown\(R) \(owner)\(group.isEmpty ? "" : ":" + group) \(quoted)") }
        else if !group.isEmpty { out.append("chgrp\(R) \(group) \(quoted)") }
        return out
    }

    /// The one round trip the commands go in: a refusal on the chown is
    /// reported rather than hidden behind a successful chmod.
    static func permissionScript(_ cmds: [String]) -> String {
        cmds.joined(separator: " && echo __ok__; ") + " && echo __ok__"
    }

    // MARK: - Get info

    /// `parseKv`: `key=value` lines from a shell probe, ignoring anything malformed.
    static func parseKv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let i = line.firstIndex(of: "="), i != line.startIndex else { continue }
            out[String(line[..<i]).trimmed] = String(line[line.index(after: i)...]).trimmed
        }
        return out
    }

    /// One `stat` over the connection that is already open. GNU and BSD stat
    /// take different format flags, so the command tries GNU first and falls
    /// back — which covers Linux, the BSDs and macOS without asking which.
    static func remoteInfoCommand(_ path: String) -> String {
        let q = shq(path)
        return "{ stat -c 'kind=%F\\nsize=%s\\nmode=%A\\noct=%a\\nowner=%U\\ngroup=%G\\nmtime=%Y\\natime=%X\\ninode=%i\\nlinks=%h' \(q) 2>/dev/null"
            + " || stat -f 'kind=%HT\\nsize=%z\\nmode=%Sp\\noct=%Lp\\nowner=%Su\\ngroup=%Sg\\nmtime=%m\\natime=%a\\ninode=%i\\nlinks=%l' \(q); }; "
            + "[ -L \(q) ] && echo \"link=$(readlink \(q) 2>/dev/null)\"; "
            + "if [ -d \(q) ]; then "
            + "echo \"files=$(find \(q) -maxdepth 1 -mindepth 1 ! -type d 2>/dev/null | wc -l)\"; "
            + "echo \"dirs=$(find \(q) -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)\"; "
            + "echo \"fs=$(df -Pk \(q) 2>/dev/null | tail -1 | awk '{print $1\" \"$5\" used, \"$4\"K free\"}')\"; fi"
    }

    static func remoteSizeCommand(_ path: String) -> String {
        let q = shq(path)
        return "du -sk \(q) 2>/dev/null | awk '{print $1}'; find \(q) 2>/dev/null | wc -l"
    }

    // MARK: - Paths

    /// `parentLocal`.
    static func parentLocal(_ p: String) -> String {
        if p.isEmpty { return p }
        var t = p
        while t.hasSuffix("/") { t.removeLast() }
        guard let i = t.lastIndex(of: "/") else { return "/" }
        if i == t.startIndex { return "/" }
        return String(t[..<i])
    }

    /// `shortPath`: a path short enough for a narrow column, shortened at the
    /// *front* — the end of a path is the part that identifies it.
    static func shortPath(_ p: String, max: Int = 34, home: String = NSHomeDirectory()) -> String {
        var out = p
        if !home.isEmpty && out.hasPrefix(home) { out = "~" + out.dropFirst(home.count) }
        if out.count <= max { return out }
        return "\u{2026}" + out.suffix(max - 1)
    }

    /// `/Applications/Visual Studio Code.app` → `Visual Studio Code`.
    static func appName(_ p: String) -> String {
        let last = p.split(separator: "/").last.map(String.init) ?? p
        let name = last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
        return name.isEmpty ? p : name
    }

    // MARK: - Background refresh

    /// `signature`: what a listing is, for "did anything change".
    static func signature(_ entries: [FileEntry]) -> String {
        entries.map { e in
            "\(e.name)\u{0}\(e.type.rawValue)\u{0}\(e.size)\u{0}\(e.mtime.map { String($0) } ?? "")\u{0}\(e.mode.map { String($0) } ?? "")"
        }.sorted().joined(separator: "\u{1}")
    }

    // MARK: - Compare

    /// One entry against its namesake in the other list: only, same, newer,
    /// older or differs (same timestamp, different size). A folder is a folder.
    static func compareVerdict(_ a: FileEntry, _ b: FileEntry?) -> String {
        guard let b else { return "only" }
        if isDir(a) || isDir(b) { return "same" }
        let am = a.mtime ?? 0, bm = b.mtime ?? 0
        if a.size == b.size && abs(am - bm) <= 2000 { return "same" }
        if am > bm + 2000 { return "newer" }
        if bm > am + 2000 { return "older" }
        return "differs"
    }

    static func compareMap(_ mine: [FileEntry], _ theirs: [FileEntry]) -> [String: String] {
        var t: [String: FileEntry] = [:]
        for e in theirs { t[e.name] = e }
        var out: [String: String] = [:]
        for e in mine { out[e.name] = compareVerdict(e, t[e.name]) }
        return out
    }

    static let compareTitles = ["only": "Only in this list", "newer": "Newer here than in the other list",
                                "older": "Older here than in the other list",
                                "differs": "Same timestamp, different size"]
    static let compareGlyphs = ["only": "＋", "newer": "↑", "older": "↓", "differs": "≠"]

    // MARK: - Starred folders

    /// The id a built-in starred folder is known by, so hiding one survives a
    /// restart: `builtin-<kind>-<path with non-word runs as dashes>`.
    static func builtinFavoriteId(kind: String, path: String) -> String {
        var s = ""
        var inRun = false
        for ch in path {
            if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII || ch == "_" { s.append(ch); inRun = false }
            else if !inRun { s.append("-"); inRun = true }
        }
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        return "builtin-\(kind)-\(s)"
    }

    /// What a built-in starred folder is called.
    static func builtinLabel(_ p: String) -> String {
        if p == "~" { return "Home" }
        let b = Posix.basename(p)
        return b.isEmpty ? p : b
    }

    // MARK: - Sync dialog

    struct SyncOp { let glyph: String; let label: String }
    static let syncOps: [String: SyncOp] = [
        "upload": SyncOp(glyph: "↑", label: "upload"),
        "download": SyncOp(glyph: "↓", label: "download"),
        "deleteRemote": SyncOp(glyph: "✕", label: "delete on server"),
        "deleteLocal": SyncOp(glyph: "✕", label: "delete here"),
        "rmdirRemote": SyncOp(glyph: "⊘", label: "remove folder on server, with anything in it"),
        "rmdirLocal": SyncOp(glyph: "⊘", label: "remove folder here, with anything in it"),
        "same": SyncOp(glyph: "=", label: "identical"),
        "skip": SyncOp(glyph: "·", label: "left alone"),
    ]

    /// Unticking a deletion keeps the folders above it: a Teleport node's
    /// RMDIR is recursive, so keeping anything inside a folder must keep the
    /// folder. Returns the keys (`rel + op`) to exclude as well.
    static func syncExcludesFor(_ a: SyncPlanner.Action, in actions: [SyncPlanner.Action]) -> [String] {
        guard a.op.hasPrefix("delete") else { return [] }
        return actions.filter { $0.op.hasPrefix("rmdir") && (a.rel == $0.rel || a.rel.hasPrefix($0.rel + "/")) }
            .map { $0.rel + $0.op }
    }
}
