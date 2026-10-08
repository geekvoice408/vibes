import AppKit
import Foundation

/// This machine's filesystem: the file-browsing half of src/main/local.js,
/// fsx.js, and main.js's `local:*` handlers. (Local shells are the
/// connections owner's.)
///
/// Everything here is safe to call from any task; the blocking calls run on
/// whatever executor the caller is on, so call from a background task for big
/// trees (the async functions are nonisolated and do that for you).
fileprivate func fs_stat_buffer() -> stat { stat() }
fileprivate func fs_stat_call(_ p: String, _ st: inout stat) -> Int32 { stat(p, &st) }
fileprivate func fs_lstat_call(_ p: String, _ st: inout stat) -> Int32 { lstat(p, &st) }

enum LocalFS {
    // MARK: - stat

    /// lstat/stat, the fields the listings use.
    struct Stat {
        var mode: UInt32
        var size: Int64
        var mtimeMs: Double
        var atimeMs: Double
        var ctimeMs: Double
        var birthtimeMs: Double
        var uid: UInt32
        var gid: UInt32
        var nlink: Int
        var isDir: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
        var isFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
        var isLink: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
    }

    static func lstat(_ p: String) -> Stat? { doStat(p, follow: false) }
    static func stat(_ p: String) -> Stat? { doStat(p, follow: true) }

    /// Like `lstat`, but throws the system's reason.
    static func lstatOrThrow(_ p: String) throws -> Stat {
        if let s = lstat(p) { return s }
        throw nodeError("lstat", p)
    }
    static func statOrThrow(_ p: String) throws -> Stat {
        if let s = stat(p) { return s }
        throw nodeError("stat", p)
    }

    private static func doStat(_ p: String, follow: Bool) -> Stat? {
        var st = fs_stat_buffer()
        let r = follow ? fs_stat_call(p, &st) : fs_lstat_call(p, &st)
        guard r == 0 else { return nil }
        func ms(_ t: timespec) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1_000_000 }
        return Stat(mode: UInt32(st.st_mode), size: Int64(st.st_size), mtimeMs: ms(st.st_mtimespec),
                    atimeMs: ms(st.st_atimespec), ctimeMs: ms(st.st_ctimespec), birthtimeMs: ms(st.st_birthtimespec),
                    uid: st.st_uid, gid: st.st_gid, nlink: Int(st.st_nlink))
    }

    /// Node's names and texts (libuv's) for the errors a file browser meets.
    static let errnoText: [Int32: (code: String, text: String)] = [
        ENOENT: ("ENOENT", "no such file or directory"), EACCES: ("EACCES", "permission denied"),
        EEXIST: ("EEXIST", "file already exists"), ENOTEMPTY: ("ENOTEMPTY", "directory not empty"),
        ENOTDIR: ("ENOTDIR", "not a directory"), EISDIR: ("EISDIR", "illegal operation on a directory"),
        EPERM: ("EPERM", "operation not permitted"), EXDEV: ("EXDEV", "cross-device link not permitted"),
        EINVAL: ("EINVAL", "invalid argument"), EBUSY: ("EBUSY", "resource busy or locked"),
        ELOOP: ("ELOOP", "too many symbolic links encountered"), ENAMETOOLONG: ("ENAMETOOLONG", "name too long"),
        EROFS: ("EROFS", "read-only file system"), ENOSPC: ("ENOSPC", "no space left on device"),
        EMFILE: ("EMFILE", "too many open files"), EIO: ("EIO", "i/o error"), EBADF: ("EBADF", "bad file descriptor"),
        EDQUOT: ("EDQUOT", "disk quota exceeded"), EFBIG: ("EFBIG", "file too large"),
    ]

    /// An error worded the way Node's fs errors were:
    /// `ENOENT: no such file or directory, rename '/a' -> '/b'`.
    static func nodeError(_ syscall: String, _ path: String? = nil, dest: String? = nil, _ code: Int32 = errno) -> AppError {
        let (name, text) = errnoText[code] ?? ("UNKNOWN", String(cString: strerror(code)).lowercased())
        var msg = "\(name): \(text), \(syscall)"
        if let path { msg += " '\(path)'" }
        if let dest { msg += " -> '\(dest)'" }
        return AppError(msg, code: name)
    }

    /// The POSIX errno behind a Foundation error, when there is one.
    static func posixCode(_ error: Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
        switch CocoaError.Code(rawValue: ns.code) {
        case .fileNoSuchFile, .fileReadNoSuchFile: return ENOENT
        case .fileReadNoPermission, .fileWriteNoPermission: return EACCES
        case .fileWriteFileExists: return EEXIST
        case .fileWriteOutOfSpace: return ENOSPC
        case .fileWriteVolumeReadOnly: return EROFS
        default: return nil
        }
    }

    /// A Foundation error in Node's wording, for `syscall` on `path`.
    static func nodeError(_ error: Error, _ syscall: String, _ path: String) -> AppError {
        if let c = posixCode(error) { return nodeError(syscall, path, c) }
        return AppError(error.localizedDescription)
    }

    /// Directory entry names (no `.`/`..`), or throws (`scandir`).
    static func readdir(_ dir: String) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: dir) } catch { throw nodeError(error, "scandir", dir) }
    }

    // MARK: - Account names

    /// uid/gid to account names, cached for the life of the process. A uid
    /// that is not known gives nil and the caller shows the number, which is
    /// the truth rather than a guess.
    private static let idLock = NSLock()
    nonisolated(unsafe) private static var userNames: [UInt32: String?] = [:]
    nonisolated(unsafe) private static var groupNames: [UInt32: String?] = [:]

    static func userName(_ uid: UInt32?) -> String? {
        guard let uid else { return nil }
        idLock.lock(); defer { idLock.unlock() }
        if let c = userNames[uid] { return c }
        var name: String?
        if let pw = getpwuid(uid), let n = pw.pointee.pw_name { name = String(cString: n) }
        userNames[uid] = name
        return name
    }

    static func groupName(_ gid: UInt32?) -> String? {
        guard let gid else { return nil }
        idLock.lock(); defer { idLock.unlock() }
        if let c = groupNames[gid] { return c }
        var name: String?
        if let gr = getgrgid(gid), let n = gr.pointee.gr_name { name = String(cString: n) }
        groupNames[gid] = name
        return name
    }

    // MARK: - Listing

    static func entry(_ full: String, name: String? = nil) -> FileEntry? {
        guard let st = lstat(full) else { return nil }
        var targetType: FileType?
        if st.isLink {
            if let s2 = stat(full) { targetType = s2.isDir ? .directory : .file } else { targetType = .broken }
        }
        let type: FileType = st.isLink ? .symlink : st.isDir ? .directory : st.isFile ? .file : .special
        return FileEntry(
            name: name ?? (full as NSString).lastPathComponent,
            path: full,
            type: type,
            targetType: targetType,
            size: st.size,
            mode: st.mode & 0o7777,
            modeString: FileMode.string(st.mode, isDir: st.isDir, isLink: st.isLink),
            mtime: st.mtimeMs,
            atime: st.atimeMs,
            // Carried on every entry so the details columns cost no extra
            // call: lstat has already been paid for.
            uid: st.uid, gid: st.gid,
            owner: userName(st.uid),
            group: groupName(st.gid),
            links: st.nlink)
    }

    /// `local.list`: every entry of a directory, lstat'd.
    static func list(_ dir: String) async throws -> [FileEntry] {
        let names = try readdir(dir)
        return names.compactMap { entry((dir as NSString).appendingPathComponent($0), name: $0) }
    }

    /// `local:list`: "" or "~" means home.
    static func listing(_ dir: String?) async throws -> FileListing {
        let target = (dir ?? "").isEmpty || dir == "~" ? home : dir!.expandingTilde
        return FileListing(path: target, entries: try await list(target))
    }

    // MARK: - Info

    struct Info: Codable, Sendable {
        var path: String
        var name: String
        var type: FileType
        var target: String?
        var size: Int64
        var mode: UInt32
        var modeString: String
        var uid: UInt32
        var gid: UInt32
        var owner: String?
        var group: String?
        var mtime: Double
        var atime: Double
        var ctime: Double
        var birthtime: Double
        var links: Int
        /// Immediate children, for a directory; nil otherwise (or unreadable).
        var files: Int?
        var dirs: Int?
    }

    /// What a folder (or file) actually is: the stat every file manager
    /// shows, plus an immediate child count. The recursive total is
    /// deliberately not computed here — on a deep tree that is a walk of
    /// everything, and it belongs behind a button the user presses knowingly.
    static func info(_ p: String) async throws -> Info {
        let st = try lstatOrThrow(p)
        var target: String?
        if st.isLink { target = try? FileManager.default.destinationOfSymbolicLink(atPath: p) }
        let type: FileType = st.isLink ? .symlink : st.isDir ? .directory : st.isFile ? .file : .special
        var files: Int?, dirs: Int?
        if st.isDir {
            if let names = try? readdir(p) {
                var f = 0, d = 0
                for n in names {
                    // withFileTypes semantics: a link to a directory counts as a file.
                    if let s = lstat((p as NSString).appendingPathComponent(n)), s.isDir { d += 1 } else { f += 1 }
                }
                files = f; dirs = d
            }
        }
        let base = (p as NSString).lastPathComponent
        return Info(path: p, name: base.isEmpty ? p : base, type: type, target: target, size: st.size,
                    mode: st.mode & 0o7777, modeString: FileMode.string(st.mode, isDir: st.isDir, isLink: st.isLink),
                    uid: st.uid, gid: st.gid, owner: userName(st.uid), group: groupName(st.gid),
                    mtime: st.mtimeMs, atime: st.atimeMs, ctime: st.ctimeMs, birthtime: st.birthtimeMs,
                    links: st.nlink, files: files, dirs: dirs)
    }

    struct TreeSize: Codable, Sendable, Equatable {
        var bytes: Int64
        var files: Int
        var dirs: Int
        var truncated: Bool
    }

    /// Add a tree up. Capped so that "get info" on `/` cannot turn into a job
    /// that never ends — what comes back says whether it stopped early.
    static func treeSize(_ root: String, maxEntries: Int = 400_000, maxMs: Double = 20_000) async -> TreeSize {
        let started = Date()
        var bytes: Int64 = 0, files = 0, dirs = 0, truncated = false
        var stack = [root]
        while let dir = stack.popLast() {
            if files + dirs >= maxEntries || Date().timeIntervalSince(started) * 1000 > maxMs { truncated = true; break }
            guard let names = try? readdir(dir) else { continue }
            for n in names {
                let full = (dir as NSString).appendingPathComponent(n)
                guard let st = lstat(full) else { files += 1; continue }
                if st.isLink { files += 1; continue }   // never follow: loops
                if st.isDir { dirs += 1; stack.append(full); continue }
                files += 1
                bytes += st.size
            }
        }
        return TreeSize(bytes: bytes, files: files, dirs: dirs, truncated: truncated)
    }

    // MARK: - Changing things

    /// `local:mkdir` (and fsx.ensureDir): make the directory and its parents;
    /// one that is already there is success.
    static func ensureDir(_ dir: String) throws {
        if dir.isEmpty || isDir(dir) { return }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            if isDir(dir) { return }
            throw nodeError(error, "mkdir", dir)
        }
    }

    /// Ensure the directory a file is about to be written into exists.
    static func ensureParentDir(_ file: String) throws {
        let dir = (file as NSString).deletingLastPathComponent
        // At a root there is nothing to create.
        if dir.isEmpty || dir == file || isRoot(dir) { return }
        try ensureDir(dir)
    }

    /// `fsx.parentDir`: the parent of a path, or nil when it has none.
    static func parentDir(_ p: String) -> String? {
        let dir = (p as NSString).deletingLastPathComponent
        return !dir.isEmpty && dir != p ? dir : nil
    }

    static func isRoot(_ dir: String) -> Bool { dir == "/" }

    static func isDir(_ p: String) -> Bool { stat(p)?.isDir ?? false }

    /// `removeEntry`: a directory (not a link to one) goes with everything in
    /// it; anything else is unlinked.
    static func removeEntry(_ p: String) throws {
        let st = try lstatOrThrow(p)
        if st.isDir && !st.isLink {
            do { try FileManager.default.removeItem(atPath: p) } catch {
                if lstat(p) != nil { throw nodeError(error, "rm", p) }
            }
        } else if Darwin.unlink(p) != 0 {
            throw nodeError("unlink", p)
        }
    }

    /// `local:remove`.
    static func remove(_ paths: [String]) throws {
        for p in paths { try removeEntry(p) }
    }

    /// `local:rename` — rename(2), which replaces an existing file as fs.rename did.
    static func rename(_ a: String, _ b: String) throws {
        if Darwin.rename(a, b) != 0 { throw nodeError("rename", a, dest: b) }
    }

    /// `local.parentOf`: the parent, or the path itself at the root.
    static func parentOf(_ p: String) -> String {
        let up = (p as NSString).deletingLastPathComponent
        return up.isEmpty || up == p ? p : up
    }

    static var home: String { NSHomeDirectory() }

    struct Place: Codable, Sendable, Equatable {
        var name: String
        var path: String
    }

    /// Common places worth one click.
    static func shortcuts() -> [Place] {
        let h = home
        let tmp = (NSTemporaryDirectory() as NSString).standardizingPath
        return [
            Place(name: "Home", path: h),
            Place(name: "Desktop", path: h + "/Desktop"),
            Place(name: "Documents", path: h + "/Documents"),
            Place(name: "Downloads", path: h + "/Downloads"),
            Place(name: "Root", path: "/"),
            Place(name: "Temp", path: tmp),
        ].filter { isDir($0.path) }
    }

    struct ExistingDir: Codable, Sendable, Equatable {
        var given: String
        var path: String
    }

    /// Of the paths given, the ones that are directories on this machine.
    ///
    /// Used for the automatically-starred folders: a star that points at
    /// something which is not there is worse than no star, and only the app
    /// knows which of a configured list actually exists.
    static func existingDirs(_ paths: [String]) -> [ExistingDir] {
        var out: [ExistingDir] = []
        for raw in paths {
            let p = raw.trimmed
            if p.isEmpty { continue }
            let full = p == "~" ? home : (p.hasPrefix("~/") ? home + "/" + p.dropFirst(2) : p)
            if isDir(full) { out.append(ExistingDir(given: p, path: full)) }
        }
        return out
    }

    // MARK: - Finder and other applications

    /// `local:reveal`: show it selected in Finder.
    @MainActor static func reveal(_ p: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    /// `local:open`: open with the default application.
    @MainActor static func open(_ p: String) throws {
        guard FileManager.default.fileExists(atPath: p) else { throw AppError("Failed to open path: \(p)") }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: p)) { throw AppError("Failed to open path: \(p)") }
    }

    /// `local:openWith`: `open -a <app> <file>` — an argument array, never a
    /// shell: these are paths, and a path can contain anything.
    static func openWith(_ filePath: String, app appPath: String) async throws {
        if filePath.isEmpty || appPath.isEmpty { throw AppError("A file and an application are needed.") }
        if access(filePath, F_OK) != 0 { throw nodeError("access", filePath) }
        let r = await Proc.run("/usr/bin/open", ["-a", appPath, filePath], timeout: 20)
        if !r.ok {
            let m = r.err.trimmed
            throw AppError(m.isEmpty ? (r.spawnError ?? "Could not open it.") : m)
        }
    }

    // MARK: - Text (the inline editor)

    struct Text: Codable, Sendable {
        var text: String
        var size: Int64
        var mtime: Double
    }

    /// A local file as text, for the same editor the remote side gets.
    ///
    /// Capped, and checked for being text at all. An editor handed four
    /// megabytes of ELF is a hung window and a mangled file if it is then
    /// saved, so both are refused here with a reason.
    static func readText(_ p: String, max: Int? = nil) async throws -> Text {
        let cap = min(max ?? 2 * 1024 * 1024, 16 * 1024 * 1024)
        let st = try statOrThrow(p)
        if !st.isFile { throw AppError("That is not a file.") }
        if st.size > Int64(cap) {
            func mb(_ n: Int64) -> String { String(format: "%.1f MB", Double(n) / (1024 * 1024)) }
            throw AppError("\(mb(st.size)) is too large to edit here — the limit is \(mb(Int64(cap))). Open it with an application instead.")
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: p)) } catch { throw nodeError(error, "open", p) }
        // A NUL byte in the first few kilobytes is the oldest test there is
        // and still the right one.
        if data.prefix(8000).contains(0) { throw AppError("This looks like a binary file, not text.") }
        return Text(text: String(decoding: data, as: UTF8.self), size: st.size, mtime: st.mtimeMs)
    }

    static func writeText(_ p: String, _ text: String) throws {
        do { try Data(text.utf8).write(to: URL(fileURLWithPath: p)) } catch { throw nodeError(error, "open", p) }
    }
}
