import Foundation

/// A registered bucket as a file source (Files/Service `FileSource`).
///
/// A bucket has no directories, only keys that share a prefix — so a "path"
/// here is a key prefix ("" is the bucket root, "logs/2024/" a folder), and a
/// listing turns shared prefixes into folders. Entries' paths are full keys.
/// Storage class goes in `FileEntry.extra["storageClass"]`.
///
/// A bucket supports a smaller set of things than a filesystem: no
/// permissions, no symlinks, no rename in place, no search. Those throw with
/// a message to show; uploads, downloads, copies between panes, re-tiering
/// and Get info are `S3Service` / `S3UI` calls (see Automation/README.md).
final class S3FileSource: FileSource, @unchecked Sendable {
    let targetId: String
    var id: String { "s3:" + targetId }
    let kind = FileSourceKind.s3
    let capabilities: FileSourceCapabilities = []
    private let lock = NSLock()
    private var record: JSON = .null

    init(targetId: String) { self.targetId = targetId }

    func update(_ t: JSON) { lock.lock(); record = t; lock.unlock() }

    /// The registration (no secrets).
    var target: JSON { lock.lock(); defer { lock.unlock() }; return record }

    @MainActor var label: String { target["name"].string?.nilIfEmpty ?? target["bucket"].string ?? targetId }

    @MainActor private var svc: S3Service { S3Service.shared }

    /// The bucket root (the registered prefix, when there is one).
    func home() async throws -> String { "" }

    func list(_ dir: String?) async throws -> FileListing {
        let p = (dir == nil || dir == "." || dir == "/" || dir == "~") ? "" : dir!
        let r = try await svc.browse(targetId, prefix: p)
        return FileListing(path: r.prefix, entries: r.entries.map(\.fileEntry))
    }

    func stat(_ path: String) async throws -> FileEntry {
        if path.isEmpty || path.hasSuffix("/") {
            let name = Posix.basename(path)
            return FileEntry(name: name.isEmpty ? (target["bucket"].string ?? "") : name, path: path, type: .directory,
                             size: 0, mode: nil, modeString: "d---------")
        }
        let h = try await svc.head(targetId, key: path)
        var e = FileEntry(name: Posix.basename(path), path: path, type: .file, size: h.size, mode: nil,
                          modeString: "----------", mtime: h.mtime > 0 ? h.mtime : nil)
        var extra: [String: JSON] = ["storageClass": .string(h.storageClass)]
        if let ct = h.contentType { extra["contentType"] = .string(ct) }
        if let et = h.etag { extra["etag"] = .string(et) }
        e.extra = extra
        return e
    }

    func mkdir(_ path: String) async throws {
        throw AppError("A bucket has no folders to make — a folder appears when something is uploaded into it.")
    }

    func rename(_ from: String, to: String) async throws {
        throw AppError("Objects in a bucket cannot be renamed in place.")
    }

    /// Objects only: folders in S3 are only shared prefixes.
    func remove(_ entries: [FileEntry]) async throws {
        let keys = entries.filter { !$0.isDirectoryLike }.map(\.path)
        if keys.isEmpty { throw AppError("Folders in S3 are only shared prefixes — delete the objects inside.") }
        try await svc.deleteKeys(targetId, keys: keys)
    }

    func readText(_ path: String, maxBytes: Int) async throws -> String {
        throw AppError("Objects in a bucket cannot be edited here — download it first.")
    }

    func writeText(_ path: String, _ text: String) async throws {
        throw AppError("Objects in a bucket cannot be edited here — download it first.")
    }

    func chmod(_ path: String, mode: UInt32) async throws {
        throw AppError("Objects in a bucket have no permissions to change.")
    }

    func search(_ options: FindFiles.Options) async throws -> FindFiles.Outcome {
        throw AppError("Search does not reach into buckets yet")
    }

    func parent(of path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let i = p.lastIndex(of: "/") else { return "" }
        return String(p[...i])
    }

    func join(_ dir: String, _ name: String) -> String { S3Pure.joinPrefix(dir) + name }
}
