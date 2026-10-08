import Darwin
import Foundation

/// S3 as another place files live: the operations of s3.js.
///
/// Every call takes an `S3Usable` (a target with its credentials resolved —
/// see `S3Service.usable`). Errors are `AppError`s with the original's wording.
enum S3Client {
    struct Listing: Sendable { var prefix: String; var entries: [S3Object] }

    struct PrefixInfo: Sendable {
        var prefix: String
        var objects: Int
        var bytes: Int64
        var newest: Double
        var oldest: Double
        var truncated: Bool
        /// (class, count), most common first.
        var classes: [(String, Int)]
    }

    struct Head: Sendable {
        var size: Int64
        var mtime: Double
        var storageClass: String
        var contentType: String?
        var etag: String?
    }

    struct Uploaded: Sendable { var key: String; var bytes: Int64; var storageClass: String }

    struct Bucket: Sendable, Identifiable { var name: String; var createdAt: Double; var id: String { name } }

    struct TestResult: Sendable { var bucket: String; var region: String; var endpoint: String; var keys: Int }

    // MARK: requests

    struct Req {
        var method = "GET"
        var key = ""
        var query: [String: String?] = [:]
        var headers: [String: String] = [:]
        var payloadHash: String?
        var uploadFrom: String?
        var sinkPath: String?
        var bucketless = false
        var onSent: ((Int64) -> Void)?
        var onReceived: ((Int64, Int64) -> Void)?
    }

    /// `request`: one exchange, retried once in the right region when S3 says
    /// the bucket lives elsewhere. Signing is region-specific, so the first
    /// call cannot succeed — but the answer is right there in a header, and
    /// retrying is cheaper than making the user find out which region it is.
    static func request(_ t: S3Usable, _ r: Req) async throws -> S3HTTP.Response {
        let res = try await requestOnce(t, r)
        if res.status == 301, let moved = res.header("x-amz-bucket-region"), !moved.isEmpty,
           moved != t.region, r.uploadFrom == nil {
            var again = t
            again.target["region"] = .string(moved)
            return try await requestOnce(again, r)
        }
        return res
    }

    static func requestOnce(_ t: S3Usable, _ r: Req) async throws -> S3HTTP.Response {
        let (ep, uri) = try r.bucketless ? S3Pure.serviceUri(t.target) : S3Pure.uri(t.target, key: r.key)
        let creds = try S3Pure.resolveCredentials(t.target)
        let hash = r.payloadHash ?? (r.uploadFrom != nil ? SigV4.unsignedPayload : SigV4.emptyHash)
        let signed = SigV4.sign(method: r.method, host: ep.host, canonicalUri: uri, query: r.query, headers: r.headers,
                                payloadHash: hash, region: ep.region, credentials: creds)
        let qs = SigV4.canonicalQuery(r.query)
        guard let url = URL(string: "\(ep.scheme)://\(ep.host)\(uri)\(qs.isEmpty ? "" : "?" + qs)") else {
            throw AppError("Not a usable S3 address: \(ep.host)\(uri)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = r.method
        for (k, v) in signed.headers where k.lowercased() != "host" { req.setValue(v, forHTTPHeaderField: k) }
        // The object's bytes exactly as stored: naming an encoding ourselves
        // stops URLSession from un-gzipping an object stored with Content-Encoding.
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await S3HTTP.send(req, tunnel: t.tunnel, uploadFrom: r.uploadFrom, sinkPath: r.sinkPath,
                                     onSent: r.onSent, onReceived: r.onReceived)
    }

    // MARK: operations

    /// One "directory" of a bucket. S3 has no directories, so the delimiter
    /// turns shared key prefixes into the folders the file browser expects.
    static func list(_ t: S3Usable, prefix: String = "") async throws -> Listing {
        let base = S3Pure.listingBase(t.target, prefix)
        var entries: [S3Object] = []
        var token: String?
        repeat {
            var q: [String: String?] = ["list-type": "2", "delimiter": "/", "prefix": base, "max-keys": "1000"]
            if let token { q["continuation-token"] = token }
            let res = try await request(t, Req(query: q))
            if res.status != 200 { throw S3Pure.failure(status: res.status, body: res.text, what: "Listing \(t.bucket)") }
            let page = S3Pure.parseListPage(res.text, base: base)
            entries += page.entries
            token = page.next
        } while token != nil
        return Listing(prefix: base, entries: entries)
    }

    /// What sits under a prefix, counted rather than listed. Listing without a
    /// delimiter walks the whole subtree, so it is capped — the caller is told
    /// when the answer is a floor rather than a total.
    static func prefixInfo(_ t: S3Usable, prefix: String = "", maxKeys: Int = 200_000) async throws -> PrefixInfo {
        let base = S3Pure.listingBase(t.target, prefix)
        var token: String?
        var objects = 0, bytes: Int64 = 0, newest = 0.0, oldest = 0.0, truncated = false
        var classes: [String: Int] = [:]
        repeat {
            var q: [String: String?] = ["list-type": "2", "prefix": base, "max-keys": "1000"]
            if let token { q["continuation-token"] = token }
            let res = try await request(t, Req(query: q))
            if res.status != 200 { throw S3Pure.failure(status: res.status, body: res.text, what: "Listing \(t.bucket)") }
            let text = res.text
            for c in S3Pure.xmlAll(text, "Contents") {
                let key = S3Pure.unescapeXml(S3Pure.xmlOne(c, "Key"))
                if key == base { continue }          // the folder marker itself
                objects += 1
                bytes += Int64(S3Pure.xmlOne(c, "Size") ?? "") ?? 0
                let when = S3Pure.parseIsoMs(S3Pure.xmlOne(c, "LastModified"))
                if when > 0 {
                    if when > newest { newest = when }
                    if oldest == 0 || when < oldest { oldest = when }
                }
                classes[S3Pure.xmlOne(c, "StorageClass") ?? "STANDARD", default: 0] += 1
            }
            token = S3Pure.xmlOne(text, "IsTruncated") == "true"
                ? S3Pure.unescapeXml(S3Pure.xmlOne(text, "NextContinuationToken")).nilIfEmpty : nil
            if objects >= maxKeys { truncated = token != nil; token = nil }
        } while token != nil
        return PrefixInfo(prefix: base, objects: objects, bytes: bytes, newest: newest, oldest: oldest, truncated: truncated,
                          classes: classes.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
    }

    @discardableResult
    static func download(_ t: S3Usable, key: String, to destPath: String,
                         onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> Int64 {
        let res = try await request(t, Req(key: key, sinkPath: destPath, onReceived: onProgress))
        if res.status != 200 { throw S3Pure.failure(status: res.status, body: res.text, what: "Downloading \(key)") }
        return res.written
    }

    static func upload(_ t: S3Usable, localPath: String, key: String, storageClass: String?, contentType: String? = nil,
                       onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> Uploaded {
        // stat, not lstat: a link to a file uploads the file, as fsp.stat did.
        let real = URL(fileURLWithPath: localPath).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real) else {
            throw AppError("ENOENT: no such file or directory, stat '\(localPath)'")
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw AppError("\(localPath) is not a file.") }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        // A single PUT tops out at 5 GiB; beyond that S3 requires multipart.
        if size > 5 * 1024 * 1024 * 1024 {
            throw AppError("\((localPath as NSString).lastPathComponent) is larger than 5 GiB, which needs a multipart upload — not supported yet.")
        }
        var headers = ["content-length": String(size)]
        if let contentType { headers["content-type"] = contentType }
        if let sc = storageClass, !sc.isEmpty, sc != "STANDARD" { headers["x-amz-storage-class"] = sc }
        // Streaming means the body is not in hand to hash; over TLS this is
        // what AWS expects instead.
        let res = try await request(t, Req(method: "PUT", key: key, headers: headers, payloadHash: SigV4.unsignedPayload,
                                           uploadFrom: localPath, onSent: { onProgress?($0, size) }))
        if res.status != 200 {
            throw S3Pure.failure(status: res.status, body: res.text, what: "Uploading \((localPath as NSString).lastPathComponent)")
        }
        return Uploaded(key: key, bytes: size, storageClass: storageClass?.nilIfEmpty ?? "STANDARD")
    }

    static func remove(_ t: S3Usable, keys: [String]) async throws {
        for key in keys {
            let res = try await request(t, Req(method: "DELETE", key: key))
            // 204 is the success here; 404 means it is already gone, which is fine.
            if ![204, 200, 404].contains(res.status) {
                throw S3Pure.failure(status: res.status, body: res.text, what: "Deleting \(key)")
            }
        }
    }

    /// Copy within a bucket, which is how S3 does both rename and re-tiering.
    static func copy(_ t: S3Usable, from fromKey: String, to toKey: String, storageClass: String?) async throws {
        var headers = ["x-amz-copy-source": "/\(t.bucket)/\(SigV4.encodeKey(fromKey))"]
        if let sc = storageClass?.nilIfEmpty { headers["x-amz-storage-class"] = sc }
        let res = try await request(t, Req(method: "PUT", key: toKey, headers: headers))
        if res.status != 200 { throw S3Pure.failure(status: res.status, body: res.text, what: "Copying \(fromKey)") }
    }

    static func head(_ t: S3Usable, key: String) async throws -> Head {
        let res = try await request(t, Req(method: "HEAD", key: key))
        if res.status != 200 { throw AppError("\(key): HTTP \(res.status)") }
        return Head(size: Int64(res.header("content-length") ?? "") ?? 0,
                    mtime: S3Pure.parseHttpDateMs(res.header("last-modified")),
                    storageClass: res.header("x-amz-storage-class") ?? "STANDARD",
                    contentType: res.header("content-type"),
                    etag: res.header("etag"))
    }

    /// Every bucket the credentials can see. Needs s3:ListAllMyBuckets, which
    /// some roles withhold — the caller falls back to typing a name.
    static func listBuckets(_ t: S3Usable) async throws -> (owner: String, buckets: [Bucket]) {
        let res = try await request(t, Req(bucketless: true))
        if res.status != 200 { throw S3Pure.failure(status: res.status, body: res.text, what: "Listing buckets") }
        let text = res.text
        let owner = S3Pure.unescapeXml(S3Pure.xmlOne(S3Pure.xmlOne(text, "Owner") ?? "", "DisplayName"))
        let buckets = S3Pure.xmlAll(text, "Bucket").map {
            Bucket(name: S3Pure.unescapeXml(S3Pure.xmlOne($0, "Name")), createdAt: S3Pure.parseIsoMs(S3Pure.xmlOne($0, "CreationDate")))
        }.filter { !$0.name.isEmpty }
        return (owner, buckets)
    }

    /// Which region a bucket lives in — signing fails against the wrong one.
    static func bucketRegion(_ t: S3Usable) async throws -> String {
        let res = try await request(t, Req(method: "HEAD"))
        let region = res.header("x-amz-bucket-region")
        if (region ?? "").isEmpty && res.status >= 400 { throw AppError("Could not determine the region for \(t.bucket).") }
        return region?.nilIfEmpty ?? t.region.nilIfEmpty ?? "us-east-1"
    }

    /// A cheap credentials-and-bucket check, so registering one can be verified.
    static func test(_ t: S3Usable) async throws -> TestResult {
        let res = try await request(t, Req(query: ["list-type": "2", "max-keys": "1", "prefix": S3Pure.joinPrefix(t.prefix)]))
        if res.status != 200 { throw S3Pure.failure(status: res.status, body: res.text, what: "Reaching \(t.bucket)") }
        let ep = try S3Pure.endpoint(t.target)
        return TestResult(bucket: t.bucket, region: ep.region, endpoint: ep.host, keys: S3Pure.xmlAll(res.text, "Contents").count)
    }
}
