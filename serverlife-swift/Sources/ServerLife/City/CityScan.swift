import Foundation

/// What is under each folder of a directory, for the 3D view (cityscan.js).
///
/// A building's height is the bytes underneath that folder and its colour is
/// what those bytes are, so one directory needs one walk: for every immediate
/// child, the total size, how many files and folders are inside, and the bytes
/// per kind of file. Locally that is a bounded walk; on a server it is one
/// `find` piped through `awk`, so what comes back over the wire is a few lines
/// per folder rather than one per file.
struct CityRec: Equatable, Sendable {
    var bytes: Double = 0
    var files = 0
    var dirs = 0
    /// kind (FileKinds) → bytes
    var kinds: [String: Double] = [:]
    /// The walk ran out of budget inside this folder.
    var partial = false

    mutating func addFile(_ name: String, _ size: Double) {
        bytes += size
        files += 1
        let k = FileKinds.kindOf(name)
        kinds[k, default: 0] += size
    }
}

struct CityScanResult: Sendable {
    var path: String
    var children: [String: CityRec]
    var truncated: Bool
    var scanned: Int
}

enum CityScan {
    /// Walk a local directory. Never follows symlinks — they loop — and stops
    /// at a budget, saying so, because a home directory can be millions of entries.
    static func scanLocal(_ root: String, maxEntries: Int = 300_000, maxMs: Double = 15_000) async throws -> CityScanResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try scanLocalSync(root, maxEntries: maxEntries, maxMs: maxMs) })
            }
        }
    }

    private struct DirEnt { var name: String; var isDir: Bool; var isLink: Bool }

    /// readdir with the dirent's own type (no stat, like `withFileTypes`).
    private static func readDir(_ path: String) throws -> [DirEnt] {
        guard let d = opendir(path) else { throw AppError(nodeMessage(errno, "scandir", path)) }
        defer { closedir(d) }
        var out: [DirEnt] = []
        while let ep = readdir(d) {
            let name = withUnsafePointer(to: ep.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var type = ep.pointee.d_type
            if type == UInt8(DT_UNKNOWN) {
                var st = stat()
                if lstat(path + "/" + name, &st) == 0 {
                    let fmt = st.st_mode & S_IFMT
                    type = fmt == S_IFDIR ? UInt8(DT_DIR) : fmt == S_IFLNK ? UInt8(DT_LNK) : UInt8(DT_REG)
                }
            }
            out.append(DirEnt(name: name, isDir: type == UInt8(DT_DIR), isLink: type == UInt8(DT_LNK)))
        }
        return out
    }

    /// Node's fs error text: `ENOENT: no such file or directory, scandir '/x'`.
    static func nodeMessage(_ code: Int32, _ syscall: String, _ path: String) -> String {
        let names: [Int32: String] = [ENOENT: "ENOENT", EACCES: "EACCES", ENOTDIR: "ENOTDIR", EPERM: "EPERM",
                                      ELOOP: "ELOOP", EMFILE: "EMFILE", ENFILE: "ENFILE", ENAMETOOLONG: "ENAMETOOLONG",
                                      EIO: "EIO", EBUSY: "EBUSY", ENOMEM: "ENOMEM"]
        var text = String(cString: strerror(code))
        if let f = text.first { text = f.lowercased() + text.dropFirst() }
        return "\(names[code] ?? "E\(code)"): \(text), \(syscall) '\(path)'"
    }

    static func scanLocalSync(_ root: String, maxEntries: Int = 300_000, maxMs: Double = 15_000) throws -> CityScanResult {
        let started = Date()
        var children: [String: CityRec] = [:]
        var seen = 0
        var truncated = false

        let top: [DirEnt]
        do { top = try readDir(root) } catch { throw AppError("Cannot read \(root): \(errorText(error))") }
        // (the message is Node's: "EACCES: permission denied, scandir '/x'")

        for d in top {
            if !d.isDir || d.isLink { continue }
            var rec = CityRec()
            var stack = [(root as NSString).appendingPathComponent(d.name)]
            while let dir = stack.popLast() {
                if seen >= maxEntries || Date().timeIntervalSince(started) * 1000 > maxMs { truncated = true; break }
                guard let entries = try? readDir(dir) else { continue }
                for e in entries {
                    seen += 1
                    let full = dir + "/" + e.name
                    if e.isLink { continue }
                    if e.isDir { rec.dirs += 1; stack.append(full); continue }
                    var st = stat()
                    // Gone or unreadable: it counts as empty.
                    let size = lstat(full, &st) == 0 ? Double(st.st_size) : 0
                    rec.addFile(e.name, size)
                }
            }
            if truncated { rec.partial = true }
            children[d.name] = rec
        }
        return CityScanResult(path: root, children: children, truncated: truncated, scanned: seen)
    }

    /// One shell command that answers the same question on a server.
    ///
    /// GNU find prints size and path itself; BSD and busybox find do not have
    /// `-printf`, so they fall back to `stat` — which spells "format" `-c` on
    /// busybox and `-f` on BSD, where busybox's `-f` means something else
    /// entirely. Size goes first so a path with spaces survives. Either way awk
    /// adds it up per top-level folder and extension and prints only the
    /// totals. `timeout` and `head` keep a scan of `/` from running all afternoon.
    static func remoteCommand(_ dir: String, maxEntries: Int = 300_000, seconds: Int = 20) -> String {
        let awk = [
            #"BEGIN{FS="\t"}"#,
            #"{p=$3; sub(/^\.\//,"",p); n=index(p,"/"); if(n==0) next;"#,
            #" t=substr(p,1,n-1); seen[t]=1;"#,
            #" if($1=="d"){D[t]++; next}"#,
            #" if($1!="f") next;"#,
            #" b=p; sub(/.*\//,"",b); e=""; m=split(b,a,"."); if(m>1 && a[1]!="") e=tolower(a[m]);"#,
            #" if(e ~ /^[0-9]+$/ && m>2 && tolower(a[m-1])=="log") e="log";"#,
            #" if(length(e)>10) e="";"#,
            #" F[t]++; B[t]+=$2; X[t "\t" e]+=$2}"#,
            #"END{for(t in seen) printf "D\t%s\t%d\t%d\t%.0f\n", t, F[t], D[t], B[t];"#,
            #" for(k in X) printf "X\t%s\t%.0f\n", k, X[k]; print "N\t" NR; print "END"}"#,
        ].joined()
        let to = #"$(command -v timeout >/dev/null 2>&1 && echo "timeout \#(seconds)")"#
        return [
            "cd \(shellQuote(dir)) 2>/dev/null || { echo \"ERR cannot enter\"; exit 0; }",
            "if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then",
            #"  \#(to) find . -mindepth 2 -xdev \( -type f -o -type d \) -printf '%y\t%s\t%P\n' 2>/dev/null;"#,
            "else",
            "  if stat -c %s . >/dev/null 2>&1; then SF=-c; FMT='%s %n'; else SF=-f; FMT='%z %N'; fi;",
            #"  \#(to) find . -mindepth 2 -xdev -type f -exec stat $SF "$FMT" {} + 2>/dev/null |"#,
            #"    awk '{s=$1; sub(/^[^ ]+ /,""); print "f\t" s "\t" $0}';"#,
            #"  \#(to) find . -mindepth 2 -xdev -type d 2>/dev/null | awk '{print "d\t0\t" $0}';"#,
            "fi | head -n \(maxEntries) | awk '\(awk.replacingOccurrences(of: "'", with: #"'\''"#))'",
        ].joined(separator: "\n")
    }

    /// Turn the awk totals back into the same shape `scanLocal` returns.
    static func parseRemote(_ text: String, dir: String, maxEntries: Int = 300_000) throws -> CityScanResult {
        var children: [String: CityRec] = [:]
        var complete = false
        var rows = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("ERR ") { throw AppError("Cannot read \(dir)") }
            if line == "END" { complete = true; continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f[0] == "N" { rows = f.count > 1 ? jsInt(f[1]) : 0; continue }
            if f[0] == "D" && f.count >= 5 {
                var rec = children[f[1]] ?? CityRec()
                rec.files = jsInt(f[2])
                rec.dirs = jsInt(f[3])
                rec.bytes = jsNumber(f[4])
                children[f[1]] = rec
            } else if f[0] == "X" && f.count >= 4 {
                var rec = children[f[1]] ?? CityRec()
                let k = FileKinds.extKind[f[2]] ?? "other"
                rec.kinds[k, default: 0] += jsNumber(f[3])
                children[f[1]] = rec
            }
        }
        return CityScanResult(path: dir, children: children, truncated: !complete || rows >= maxEntries, scanned: rows)
    }

    /// A JS number as a count: huge values clamp instead of trapping.
    static func jsInt(_ s: String) -> Int {
        let d = jsNumber(s)
        if d >= 9.2e18 { return Int.max }
        if d <= -9.2e18 { return Int.min }
        return Int(d)
    }

    /// `Number(s) || 0`.
    static func jsNumber(_ s: String) -> Double {
        let t = s.trimmed
        if t.isEmpty { return 0 }
        guard let d = Double(t), d.isFinite else { return 0 }
        return d
    }
}
