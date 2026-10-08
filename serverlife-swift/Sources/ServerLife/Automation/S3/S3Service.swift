import Foundation
import Observation

/// Registered buckets and everything done with them: main.js's `s3:*` and
/// `aws:*` handlers plus the renderer's `state.s3Targets` (s3.js
/// `loadS3Targets`). Views read `targets` and `generation`; the explorer reads
/// `sources` (one `S3FileSource` per bucket).
@MainActor
@Observable
final class S3Service {
    static let shared = S3Service()

    /// The registered buckets as the interface sees them: never a secret,
    /// only whether one is stored (`s3:list`).
    private(set) var targets: [JSON] = []
    /// Bumped whenever the list changes (the renderer's `state.emit('s3')`).
    private(set) var generation = 0
    /// One file source per bucket, in the same order as `targets`.
    private(set) var sources: [S3FileSource] = []
    /// Called after the list changes (explorers refresh their source menus).
    @ObservationIgnored var onChange: [() -> Void] = []

    // MARK: the list (s3:list / s3:save / s3:delete)

    /// `loadS3Targets`.
    @discardableResult
    func reload() -> [JSON] {
        targets = Store.shared.autoListS3Targets().map(S3Service.safe)
        let old = Dictionary(uniqueKeysWithValues: sources.map { ($0.targetId, $0) })
        sources = targets.compactMap { t in
            guard let id = t["id"].string else { return nil }
            let s = old[id] ?? S3FileSource(targetId: id)
            s.update(t)
            return s
        }
        generation += 1
        onChange.forEach { $0() }
        return targets
    }

    /// The renderer never needs the ciphertext, only whether one is set.
    ///
    /// (The original also dropped the profile, app and role here, which made
    /// editing such a bucket forget them; those are not secrets, so they stay.)
    nonisolated static func safe(_ t: JSON) -> JSON {
        var o = t
        var c = t["credentials"]
        let hasSecret = c["secretAccessKey"].truthy
        c.removeKey("secretAccessKey")
        c.removeKey("sessionToken")
        c["mode"] = .string(c["mode"].string?.nilIfEmpty ?? "env")
        c["envPrefix"] = .string(c["envPrefix"].string ?? "")
        c["accessKeyId"] = .string(c["accessKeyId"].string ?? "")
        c["hasSecret"] = .bool(hasSecret)
        o["credentials"] = c
        return o
    }

    func target(_ id: String) -> JSON? { targets.first { $0["id"].string == id } }

    /// `s3:save`: a stored key is sealed with the Keychain; a blank secret
    /// keeps the one already stored.
    @discardableResult
    func save(_ t: JSON) throws -> JSON {
        var next = t
        var c = t["credentials"].truthy ? t["credentials"] : ["mode": "env"]
        if c["mode"].string == "explicit" {
            let existing = t["id"].string.flatMap { Store.shared.autoGetS3Target($0) }
            c["secretAccessKey"] = try S3Secrets.seal(c["secretAccessKey"].string).map(JSON.string)
                ?? existing?["credentials"]["secretAccessKey"] ?? .null
            c["sessionToken"] = try S3Secrets.seal(c["sessionToken"].string).map(JSON.string)
                ?? existing?["credentials"]["sessionToken"] ?? .null
        }
        next["credentials"] = c
        let rec = Store.shared.autoUpsertS3Target(next)
        reload()
        return S3Service.safe(rec)
    }

    func delete(_ id: String) {
        Store.shared.autoDeleteS3Target(id)
        reload()
    }

    // MARK: usable targets

    /// `usableTarget`: the target as S3Client needs it — secrets opened, and
    /// for Teleport targets a running local proxy with the tunnel to reach it.
    /// Takes a stored id, or a target being edited (not yet saved).
    func usable(_ idOrTarget: JSON) async throws -> S3Usable {
        let t: JSON
        if let id = idOrTarget.string {
            guard let found = Store.shared.autoGetS3Target(id) else { throw AppError("No such S3 bucket.") }
            t = found
        } else {
            t = idOrTarget
        }
        let mode = t["credentials"]["mode"].string?.nilIfEmpty ?? "env"
        switch mode {
        case "teleport":
            let env = try await AWSProxy.ensure(app: t["credentials"]["app"].string, proxy: t["credentials"]["proxy"].string)
            var o = t
            o["credentials"] = ["mode": "teleport", "accessKeyId": .string(env.accessKeyId),
                                "secretAccessKey": .string(env.secretAccessKey)]
            return S3Usable(target: o, tunnel: env.tunnel)
        case "profile":
            let profile = t["credentials"]["profile"].string?.nilIfEmpty ?? "default"
            let creds = try await AWSCreds.resolveProfile(profile)
            var o = t
            if (o["region"].string ?? "").isEmpty { o["region"] = .string(AWSCreds.profileRegion(profile)) }
            o["credentials"] = ["mode": "profile", "accessKeyId": .string(creds.accessKeyId),
                                "secretAccessKey": .string(creds.secretAccessKey), "sessionToken": JSON(creds.sessionToken),
                                "source": .string(creds.source), "expiration": JSON(creds.expiration)]
            return S3Usable(target: o, tunnel: nil)
        case "explicit":
            var o = t
            var c = t["credentials"]
            c["accessKeyId"] = .string(c["accessKeyId"].string ?? "")
            // An edited, unsaved target carries the plain secret; a stored one the sealed value.
            c["secretAccessKey"] = JSON(try S3Secrets.open(c["secretAccessKey"].string))
            c["sessionToken"] = JSON(try S3Secrets.open(c["sessionToken"].string))
            if c["secretAccessKey"].isNull, let id = t["id"].string, let stored = Store.shared.autoGetS3Target(id) {
                c["secretAccessKey"] = JSON(try S3Secrets.open(stored["credentials"]["secretAccessKey"].string))
                if c["sessionToken"].isNull { c["sessionToken"] = JSON(try S3Secrets.open(stored["credentials"]["sessionToken"].string)) }
            }
            o["credentials"] = c
            return S3Usable(target: o, tunnel: nil)
        default:
            return S3Usable(target: t, tunnel: nil)
        }
    }

    func usable(id: String) async throws -> S3Usable { try await usable(.string(id)) }

    // MARK: s3:* that act on a bucket

    func test(_ idOrTarget: JSON) async throws -> S3Client.TestResult { try await S3Client.test(try await usable(idOrTarget)) }
    func browse(_ id: String, prefix: String) async throws -> S3Client.Listing { try await S3Client.list(try await usable(id: id), prefix: prefix) }
    func head(_ id: String, key: String) async throws -> S3Client.Head { try await S3Client.head(try await usable(id: id), key: key) }
    func prefixInfo(_ id: String, prefix: String) async throws -> S3Client.PrefixInfo {
        try await S3Client.prefixInfo(try await usable(id: id), prefix: prefix)
    }
    func deleteKeys(_ id: String, keys: [String]) async throws { try await S3Client.remove(try await usable(id: id), keys: keys) }
    func copy(_ id: String, from: String, to: String, storageClass: String?) async throws {
        try await S3Client.copy(try await usable(id: id), from: from, to: to, storageClass: storageClass)
    }
    func buckets(_ t: JSON) async throws -> (owner: String, buckets: [S3Client.Bucket]) {
        try await S3Client.listBuckets(try await usable(t))
    }
    func bucketRegion(_ t: JSON) async throws -> String { try await S3Client.bucketRegion(try await usable(t)) }

    // MARK: transfers (s3:upload / download / fromServer / toServer / bucketToBucket)

    struct Moved: Sendable { var count: Int; var storageClass: String }

    /// `s3:upload`: local files into a prefix.
    func upload(_ id: String, localPaths: [String], prefix: String, storageClass: String?) async throws -> Moved {
        let t = try await usable(id: id)
        let cls = storageClass?.nilIfEmpty ?? t.target["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD"
        var n = 0
        for p in localPaths {
            let key = S3Pure.joinPrefix(prefix) + (p as NSString).lastPathComponent
            _ = try await S3Client.upload(t, localPath: p, key: key, storageClass: cls)
            n += 1
        }
        return Moved(count: n, storageClass: cls)
    }

    /// `s3:download`: objects into a local folder; each lands in Downloads.
    func download(_ id: String, keys: [String], destDir: String) async throws -> Int {
        let t = try await usable(id: id)
        var n = 0
        for key in keys {
            let dest = (destDir as NSString).appendingPathComponent(Posix.basename(key))
            let bytes = try await S3Client.download(t, key: key, to: dest)
            n += 1
            // An object pulled out of a bucket is as much a download as a file
            // off a server, and lands in the same list.
            DownloadHistory.add(localPath: dest, name: (dest as NSString).lastPathComponent,
                                source: "s3://\(t.bucket)/\(key)", from: t.name.nilIfEmpty ?? t.bucket.nilIfEmpty ?? "S3",
                                kind: "file", bytes: bytes, files: 1)
        }
        return n
    }

    /// Server → bucket, relayed through this machine: a server and a bucket
    /// cannot reach each other. The SFTP transfer is awaited before S3 sees anything.
    func fromServer(connId: String, entries: [FileEntry], to id: String, prefix: String, storageClass: String?) async throws -> Moved {
        let t = try await usable(id: id)
        let cls = storageClass?.nilIfEmpty ?? t.target["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD"
        let sftp = try await FilesService.shared.sftp(connId)
        let tmp = try S3Service.scratchDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var n = 0
        for e in entries where e.type != .directory {
            let local = (tmp as NSString).appendingPathComponent(Posix.basename(e.path))
            _ = try await Transfers.downloadFile(sftp, remote: e.path, local: local)
            _ = try await S3Client.upload(t, localPath: local, key: S3Pure.joinPrefix(prefix) + Posix.basename(e.path), storageClass: cls)
            n += 1
        }
        return Moved(count: n, storageClass: cls)
    }

    /// Bucket → server, relayed through this machine.
    func toServer(_ id: String, keys: [String], connId: String, destDir: String) async throws -> Int {
        let t = try await usable(id: id)
        let sftp = try await FilesService.shared.sftp(connId)
        let tmp = try S3Service.scratchDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var n = 0
        for key in keys {
            let base = Posix.basename(key)
            let local = (tmp as NSString).appendingPathComponent(base)
            try await S3Client.download(t, key: key, to: local)
            _ = try await Transfers.uploadFile(sftp, local: local, remote: Posix.join(destDir, base))
            n += 1
        }
        return n
    }

    /// Bucket → bucket, also relayed through this machine.
    func bucketToBucket(from fromId: String, keys: [String], to toId: String, prefix: String, storageClass: String?) async throws -> Moved {
        let from = try await usable(id: fromId)
        let to = try await usable(id: toId)
        let cls = storageClass?.nilIfEmpty ?? to.target["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD"
        let tmp = try S3Service.scratchDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var n = 0
        for key in keys {
            let base = Posix.basename(key)
            let local = (tmp as NSString).appendingPathComponent(base)
            try await S3Client.download(from, key: key, to: local)
            _ = try await S3Client.upload(to, localPath: local, key: S3Pure.joinPrefix(prefix) + base, storageClass: cls)
            n += 1
        }
        return Moved(count: n, storageClass: cls)
    }

    // MARK: scratch space (s3:relayDir / s3:cleanRelay)

    nonisolated static var tmpRoot: String {
        var t = NSTemporaryDirectory()
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// A private `serverlife-s3-…` directory for bytes on their way through.
    nonisolated static func scratchDir() throws -> String {
        var template = Array((tmpRoot + "/serverlife-s3-XXXXXX").utf8CString)
        guard let p = mkdtemp(&template) else { throw AppError("Could not make a scratch directory for the transfer.") }
        return String(cString: p)
    }

    /// `s3:relayDir`.
    nonisolated static func relayDir() throws -> String {
        let dir = tmpRoot + "/serverlife-s3-\(Int(nowMs()))-" + String(UUID().uuidString.lowercased().prefix(6))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// `s3:cleanRelay`: only ever removes a directory this process made,
    /// whatever is passed in.
    nonisolated static func cleanRelay(_ dir: String) throws {
        guard !dir.isEmpty, (dir as NSString).lastPathComponent.hasPrefix("serverlife-s3-"),
              (dir as NSString).deletingLastPathComponent == tmpRoot else {
            throw AppError("Refusing to remove a directory that is not a transfer scratch area.")
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: aws:*

    struct ProfileCheck: Sendable {
        var profile: String
        var source: String
        /// The first six characters and an ellipsis.
        var accessKeyId: String
        var temporary: Bool
        var expiration: String?
        var region: String
    }

    /// `aws:profileCheck`.
    func profileCheck(_ profile: String?) async throws -> ProfileCheck {
        let c = try await AWSCreds.resolveProfile(profile, refresh: true)
        return ProfileCheck(profile: profile?.nilIfEmpty ?? "default", source: c.source,
                            accessKeyId: String(c.accessKeyId.prefix(6)) + "…", temporary: c.sessionToken != nil,
                            expiration: c.expiration, region: AWSCreds.profileRegion(profile))
    }

    /// `credentialLabel`: how the manager names a bucket's credentials.
    nonisolated static func credentialLabel(_ t: JSON) -> String {
        let c = t["credentials"]
        switch c["mode"].string?.nilIfEmpty ?? "env" {
        case "teleport": return "teleport" + (c["app"].string?.nilIfEmpty.map { ": " + $0 } ?? "")
        case "profile": return "profile: " + (c["profile"].string?.nilIfEmpty ?? "default")
        case "explicit": return "stored key"
        default: return "environment"
        }
    }

    /// The sidebar row's short tag.
    nonisolated static func modeTag(_ t: JSON) -> String {
        switch t["credentials"]["mode"].string?.nilIfEmpty ?? "env" {
        case "teleport": return "tsh"
        case "profile": return "aws"
        case "explicit": return "key"
        default: return "env"
        }
    }
}
