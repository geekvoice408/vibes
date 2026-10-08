import Foundation

// Shapes shared by every file source (this machine, a connection's SFTP, and —
// from the automation owner — S3). Field names match the objects the
// Electron app's `sftp:list` / `local:list` handed the renderer, so the
// control socket and anything else that serialises them stays compatible.

/// What an entry is. `broken` only ever appears as a symlink's `targetType`.
enum FileType: String, Codable, Sendable, Hashable {
    case file, directory, symlink, special, broken
}

/// One row of a listing.
struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var type: FileType
    /// For a symlink: what it points at (`file`, `directory`, `special`,
    /// `broken`), so the UI knows what is enterable. nil for anything else.
    var targetType: FileType?
    var size: Int64 = 0
    /// Remote: the full SFTP mode, file-type bits included (as sftp.js kept
    /// it). Local: permission bits only (`st_mode & 0o7777`, as local.js).
    /// Use `perm` when only the permission bits are wanted.
    var mode: UInt32?
    /// `drwxr-xr-x`.
    var modeString: String
    /// ms since the epoch, nil when unknown.
    var mtime: Double?
    var atime: Double?
    var uid: UInt32?
    var gid: UInt32?
    /// Account names — from the server's own `ls -l` line remotely, from the
    /// local account databases here. nil when not known (show the number).
    var owner: String?
    var group: String?
    var links: Int?
    /// SFTP only: the server's `ls -l` line for this entry.
    var longname: String?
    /// S3 and other sources can carry anything else here.
    var extra: [String: JSON]? = nil

    /// A directory, or a link to one.
    var isDirectoryLike: Bool { type == .directory || targetType == .directory }
    var perm: UInt32 { (mode ?? 0) & 0o7777 }

    var json: JSON { JSON.encode(self) }
}

/// A listing: the absolute path actually listed (the UI shows it and
/// navigates from it) and its entries.
struct FileListing: Sendable {
    var path: String
    var entries: [FileEntry]
}

/// The file mode constants sftp.js used.
enum FileMode {
    static let S_IFMT: UInt32 = 0o170000
    static let S_IFDIR: UInt32 = 0o040000
    static let S_IFLNK: UInt32 = 0o120000
    static let S_IFREG: UInt32 = 0o100000

    /// `entryType` from sftp.js.
    static func type(_ mode: UInt32?) -> FileType {
        guard let mode else { return .file }
        switch mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        case S_IFREG: return .file
        default: return .special
        }
    }

    /// `modeString` from sftp.js: the type letter from the mode's own bits.
    static func string(_ mode: UInt32?) -> String {
        guard let mode else { return "?---------" }
        let t: String
        switch mode & S_IFMT {
        case S_IFDIR: t = "d"
        case S_IFLNK: t = "l"
        case S_IFREG: t = "-"
        default: t = "?"
        }
        return t + bits(mode)
    }

    /// `modeString(mode, isDir, isLink)` from local.js: the type letter from
    /// what lstat said.
    static func string(_ mode: UInt32, isDir: Bool, isLink: Bool) -> String {
        (isLink ? "l" : isDir ? "d" : "-") + bits(mode)
    }

    private static func bits(_ mode: UInt32) -> String {
        let letters = Array("rwxrwxrwx")
        var s = ""
        for i in 0..<9 { s.append((mode & (1 << (8 - UInt32(i)))) != 0 ? letters[i] : "-") }
        return s
    }
}

/// Owner, group and link count out of an SFTP `longname`.
///
/// `longname` is whatever the server's own `ls -l` would print, which is not a
/// specified format — so this reads it only when it looks like one: a mode
/// string first, then a link count, then two names. Anything else gives nil
/// and the caller falls back to the numeric uid/gid.
func parseLongname(_ longname: String?) -> (links: Int, owner: String, group: String)? {
    let parts = (longname ?? "").trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard parts.count >= 6 else { return nil }
    guard let re = try? NSRegularExpression(pattern: #"^[-dlbcps?][-rwxSsTt]{9}[.+@]?$"#), re.matches(parts[0]) else { return nil }
    guard let links = Int(parts[1]), parts[1].allSatisfy(\.isNumber) else { return nil }
    return (links, parts[2], parts[3])
}

/// `p.split('/').pop()` — the last segment, "" after a trailing slash.
func fsLastSegment(_ p: String) -> String {
    p.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? p
}
