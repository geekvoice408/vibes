import Foundation

/// One place files live, as the explorer sees it: this machine, a
/// connection's SFTP, or (from the automation owner) an S3 bucket.
///
/// The explorer draws whatever a source lists and asks the source to make
/// changes; it never needs to know which kind it has, except through
/// `capabilities` for the things not every kind can do. Paths are POSIX
/// strings in every source (an S3 source uses its keys/prefixes as paths).
///
/// Implementations: `LocalFileSource.shared`, `SFTPFileSource(connId:)`.
/// S3 adds its own type conforming to this protocol in Automation/.
protocol FileSource: AnyObject, Sendable {
    /// Stable identity: "local", "sftp:<connId>", "s3:<targetId>".
    var id: String { get }
    /// What the UI calls it ("this machine", the session's label, the bucket).
    @MainActor var label: String { get }
    var kind: FileSourceKind { get }
    var capabilities: FileSourceCapabilities { get }

    /// Where a fresh pane opens.
    func home() async throws -> String
    /// A directory's entries, with the absolute path actually listed (nil,
    /// "", "~" mean home). Symlinks come back with `targetType` resolved.
    func list(_ dir: String?) async throws -> FileListing
    /// One entry, following links.
    func stat(_ path: String) async throws -> FileEntry
    func mkdir(_ path: String) async throws
    /// Rename or move within this source.
    func rename(_ from: String, to: String) async throws
    /// Remove entries; directories (not links to them) go recursively.
    func remove(_ entries: [FileEntry]) async throws
    /// A whole small text file for the inline editor; refuses large files
    /// with a message to show.
    func readText(_ path: String, maxBytes: Int) async throws -> String
    func writeText(_ path: String, _ text: String) async throws
    /// Permission bits (`capabilities.chmod`).
    func chmod(_ path: String, mode: UInt32) async throws
    /// Recursive name/content search (`capabilities.search`).
    func search(_ options: FindFiles.Options) async throws -> FindFiles.Outcome

    func parent(of path: String) -> String
    func join(_ dir: String, _ name: String) -> String
}

enum FileSourceKind: String, Sendable, Codable {
    case local, sftp, s3
}

struct FileSourceCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let chmod = FileSourceCapabilities(rawValue: 1 << 0)
    static let search = FileSourceCapabilities(rawValue: 1 << 1)
    /// Symlinks, owners and link counts mean something here.
    static let posix = FileSourceCapabilities(rawValue: 1 << 2)
    /// Can run commands (Get info's stat/du, permissions-and-owner, rsync).
    static let exec = FileSourceCapabilities(rawValue: 1 << 3)
    /// Can be watched for changes (keep a folder up to date).
    static let watch = FileSourceCapabilities(rawValue: 1 << 4)
    /// Open / reveal / open with — only this machine.
    static let open = FileSourceCapabilities(rawValue: 1 << 5)
    /// A transfer queue exists for it (uploads/downloads to and from local).
    static let transfers = FileSourceCapabilities(rawValue: 1 << 6)
}

extension FileSource {
    func parent(of path: String) -> String { Posix.parent(path) }
    func join(_ dir: String, _ name: String) -> String { Posix.join(dir, name) }
    func readText(_ path: String) async throws -> String { try await readText(path, maxBytes: 2 * 1024 * 1024) }
}

/// This machine.
final class LocalFileSource: FileSource, @unchecked Sendable {
    static let shared = LocalFileSource()
    let id = "local"
    @MainActor var label: String { "this machine" }
    let kind = FileSourceKind.local
    let capabilities: FileSourceCapabilities = [.chmod, .search, .posix, .watch, .open]

    func home() async throws -> String { LocalFS.home }
    func list(_ dir: String?) async throws -> FileListing { try await LocalFS.listing(dir) }
    func stat(_ path: String) async throws -> FileEntry {
        guard var e = LocalFS.entry(path) else { throw LocalFS.nodeError("lstat", path) }
        if e.type == .symlink, let s = LocalFS.stat(path) {
            e.size = s.size
        }
        return e
    }
    func mkdir(_ path: String) async throws { try LocalFS.ensureDir(path) }
    func rename(_ from: String, to: String) async throws { try LocalFS.rename(from, to) }
    func remove(_ entries: [FileEntry]) async throws { try LocalFS.remove(entries.map(\.path)) }
    func readText(_ path: String, maxBytes: Int) async throws -> String { try await LocalFS.readText(path, max: maxBytes).text }
    func writeText(_ path: String, _ text: String) async throws { try LocalFS.writeText(path, text) }
    func chmod(_ path: String, mode: UInt32) async throws {
        if Darwin.chmod(path, mode_t(mode & 0o7777)) != 0 { throw LocalFS.nodeError("chmod", path) }
    }
    func search(_ options: FindFiles.Options) async throws -> FindFiles.Outcome { try await FindFiles.searchLocal(options) }
    func parent(of path: String) -> String { LocalFS.parentOf(path) }
    func join(_ dir: String, _ name: String) -> String { (dir as NSString).appendingPathComponent(name) }
}

/// A connection's files over SFTP.
final class SFTPFileSource: FileSource, @unchecked Sendable {
    let connId: String
    var id: String { "sftp:" + connId }
    let kind = FileSourceKind.sftp
    let capabilities: FileSourceCapabilities = [.chmod, .search, .posix, .exec, .transfers]

    init(connId: String) { self.connId = connId }

    @MainActor var label: String { FilesBridge.connection(connId)?.label ?? connId }
    @MainActor private var svc: FilesService { FilesService.shared }

    func home() async throws -> String { try await svc.home(connId) }
    func list(_ dir: String?) async throws -> FileListing { try await svc.list(connId, dir) }
    func stat(_ path: String) async throws -> FileEntry {
        let a = try await svc.stat(connId, path)
        let name = fsLastSegment(path)
        return SFTPClient.toEntry(SFTPClient.Name(filename: name.isEmpty ? path : name, longname: "", attrs: a),
                                  dir: Posix.parent(path))
    }
    func mkdir(_ path: String) async throws { try await svc.mkdir(connId, path) }
    func rename(_ from: String, to: String) async throws { try await svc.rename(connId, from, to) }
    func remove(_ entries: [FileEntry]) async throws { try await svc.remove(connId, entries) }
    func readText(_ path: String, maxBytes: Int) async throws -> String { try await svc.readFile(connId, path, maxBytes: maxBytes) }
    func writeText(_ path: String, _ text: String) async throws { try await svc.writeFile(connId, path, text) }
    func chmod(_ path: String, mode: UInt32) async throws { try await svc.chmod(connId, path, mode: mode) }
    func search(_ options: FindFiles.Options) async throws -> FindFiles.Outcome { try await svc.search(connId, options) }
}
