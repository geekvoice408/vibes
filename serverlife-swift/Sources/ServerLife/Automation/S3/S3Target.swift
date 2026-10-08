import Foundation

// The pure half of s3.js: storage classes, credentials from a target,
// endpoints and URIs, prefixes, and reading S3's XML. Everything here is
// testable without a network.

/// One storage class S3 accepts on a PUT (`STORAGE_CLASSES`).
struct S3StorageClass: Hashable, Sendable, Identifiable {
    var value: String
    var label: String
    var hint: String
    var id: String { value }

    /// Cheapest-to-restore first.
    static let all: [S3StorageClass] = [
        .init(value: "STANDARD", label: "Standard", hint: "Default. Instant access."),
        .init(value: "INTELLIGENT_TIERING", label: "Intelligent-Tiering", hint: "Moves between tiers automatically."),
        .init(value: "STANDARD_IA", label: "Standard-IA", hint: "Cheaper storage, charged per retrieval."),
        .init(value: "ONEZONE_IA", label: "One Zone-IA", hint: "As Standard-IA, single availability zone."),
        .init(value: "GLACIER_IR", label: "Glacier Instant Retrieval", hint: "Archive, still instant to read."),
        .init(value: "GLACIER", label: "Glacier Flexible Retrieval", hint: "Restore takes minutes to hours."),
        .init(value: "DEEP_ARCHIVE", label: "Glacier Deep Archive", hint: "Cheapest. Restore takes hours."),
        .init(value: "REDUCED_REDUNDANCY", label: "Reduced Redundancy", hint: "Legacy. Not recommended."),
    ]
}

/// Where a request goes: scheme, host (with port), the signing region,
/// addressing style and any base path of a custom endpoint.
struct S3Endpoint: Equatable, Sendable {
    var scheme: String
    var host: String
    var region: String
    var pathStyle: Bool
    var basePath: String
}

/// A local tunnel `tsh proxy aws` runs (awsproxy.js `tunnelAgent`): every
/// byte goes through it, and its certificate is verified against its own CA.
struct S3Tunnel: Sendable, Equatable {
    var proxyHost: String
    var proxyPort: Int
    var caBundle: String?
}

/// A target ready to use: the stored record (credentials resolved into it the
/// way main.js `usableTarget` did) plus the tunnel for Teleport credentials.
struct S3Usable: Sendable {
    var target: JSON
    var tunnel: S3Tunnel?
    var name: String { target["name"].string ?? "" }
    var bucket: String { target["bucket"].string ?? "" }
    var region: String { target["region"].string ?? "" }
    var prefix: String { target["prefix"].string ?? "" }
}

enum S3Pure {
    /// `resolveCredentials`: where a target's keys come from. 'env' reads the
    /// environment at the moment of use, so rotating credentials outside the
    /// app is picked up without re-registering anything.
    static func resolveCredentials(_ target: JSON, env: [String: String] = ProcessInfo.processInfo.environment) throws -> SigV4.Credentials {
        let c = target["credentials"]
        let mode = c["mode"].string?.nilIfEmpty ?? "env"
        let name = target["name"].string ?? ""
        // Teleport credentials are minted per session by `tsh proxy aws`; they
        // are resolved before calling in, because starting a proxy is async.
        if mode == "teleport" || mode == "profile" {
            guard let id = c["accessKeyId"].string?.nilIfEmpty, let secret = c["secretAccessKey"].string?.nilIfEmpty else {
                throw AppError(mode == "teleport"
                    ? "\(name): the Teleport AWS proxy has not been started for this bucket."
                    : "\(name): the AWS profile has not been resolved for this bucket.")
            }
            return .init(accessKeyId: id, secretAccessKey: secret, sessionToken: c["sessionToken"].string?.nilIfEmpty)
        }
        if mode == "explicit" {
            guard let id = c["accessKeyId"].string?.nilIfEmpty, let secret = c["secretAccessKey"].string?.nilIfEmpty else {
                throw AppError("\(name): no access key stored. Edit the bucket and enter one, or switch it to environment credentials.")
            }
            return .init(accessKeyId: id, secretAccessKey: secret, sessionToken: c["sessionToken"].string?.nilIfEmpty)
        }
        let prefix = c["envPrefix"].string ?? ""
        func pick(_ n: String) -> String? { env[prefix + n]?.nilIfEmpty ?? env[n]?.nilIfEmpty }
        guard let id = pick("AWS_ACCESS_KEY_ID"), let secret = pick("AWS_SECRET_ACCESS_KEY") else {
            let p = prefix.isEmpty ? "AWS" : prefix
            throw AppError("\(name): \(p)_ACCESS_KEY_ID and \(p)_SECRET_ACCESS_KEY are not set in this app's environment. "
                + "Launch ServerLife from a shell that has them, or store keys on the bucket instead.")
        }
        return .init(accessKeyId: id, secretAccessKey: secret, sessionToken: pick("AWS_SESSION_TOKEN"))
    }

    static func defaultRegion(_ target: JSON, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        target["region"].string?.nilIfEmpty ?? env["AWS_REGION"]?.nilIfEmpty ?? env["AWS_DEFAULT_REGION"]?.nilIfEmpty ?? "us-east-1"
    }

    /// `endpointFor`: virtual-hosted addressing by default; path style for
    /// MinIO and friends.
    static func endpoint(_ target: JSON, env: [String: String] = ProcessInfo.processInfo.environment) throws -> S3Endpoint {
        let region = defaultRegion(target, env: env)
        if let ep = target["endpoint"].string?.nilIfEmpty {
            let full = ep.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil ? ep : "https://" + ep
            guard let u = URLComponents(string: full), let rawHost = u.host, !rawHost.isEmpty else { throw AppError("Invalid URL") }
            let scheme = (u.scheme ?? "https").lowercased()
            // As JS `URL.host`: lowercased, and the scheme's default port left out
            // — the signed host has to be exactly what goes on the wire.
            var host = rawHost.lowercased()
            if let port = u.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) { host += ":\(port)" }
            var base = u.percentEncodedPath
            while base.hasSuffix("/") { base.removeLast() }
            return S3Endpoint(scheme: scheme, host: host, region: region,
                              pathStyle: target["pathStyle"].bool != false, basePath: base)
        }
        return S3Endpoint(scheme: "https", host: "\(target["bucket"].string ?? "").s3.\(region).amazonaws.com",
                          region: region, pathStyle: false, basePath: "")
    }

    /// `serviceUri`: the service endpoint rather than a bucket's — what
    /// ListBuckets talks to.
    static func serviceUri(_ target: JSON, env: [String: String] = ProcessInfo.processInfo.environment) throws -> (S3Endpoint, String) {
        if target["endpoint"].string?.nilIfEmpty != nil {
            let ep = try endpoint(target, env: env)
            return (ep, ep.basePath + "/")
        }
        let region = defaultRegion(target, env: env)
        return (S3Endpoint(scheme: "https", host: "s3.\(region).amazonaws.com", region: region, pathStyle: true, basePath: ""), "/")
    }

    /// `uriFor`: the canonical (already encoded) URI of a key.
    static func uri(_ target: JSON, key: String, env: [String: String] = ProcessInfo.processInfo.environment) throws -> (S3Endpoint, String) {
        let ep = try endpoint(target, env: env)
        let encoded = key.isEmpty ? "" : SigV4.encodeKey(key)
        let uri = ep.pathStyle
            ? "\(ep.basePath)/\(SigV4.encodeRfc3986(target["bucket"].string ?? ""))\(encoded.isEmpty ? "" : "/" + encoded)"
            : "\(ep.basePath)/\(encoded)"
        return (ep, uri.isEmpty ? "/" : uri)
    }

    /// `joinPrefix`: non-empty parts, slashes trimmed, joined, with one
    /// trailing slash — or "" for nothing.
    static func joinPrefix(_ parts: String?...) -> String {
        let joined = parts.compactMap { $0 }.filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return joined.isEmpty ? "" : joined + "/"
    }

    /// The prefix a listing reads. The original joined the target's prefix
    /// onto whatever it was asked for — but the paths it hands back are full
    /// keys, so opening a folder in a bucket registered with a prefix asked
    /// for the prefix twice. A request that already starts with the target's
    /// prefix is taken as the full prefix it is.
    static func listingBase(_ target: JSON, _ prefix: String) -> String {
        let own = joinPrefix(target["prefix"].string)
        let asked = joinPrefix(prefix)
        if !own.isEmpty && asked.hasPrefix(own) { return asked }
        return joinPrefix(target["prefix"].string, prefix)
    }

    // MARK: XML

    static func xmlAll(_ text: String, _ tag: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)>([\\s\\S]*?)</\(tag)>") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func xmlOne(_ text: String, _ tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)>([\\s\\S]*?)</\(tag)>") else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func unescapeXml(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// S3's ISO dates (`2009-10-12T17:50:30.000Z`) → ms, 0 when unreadable.
    static func parseIsoMs(_ s: String?) -> Double {
        guard let s, !s.isEmpty else { return 0 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return (d.timeIntervalSince1970 * 1000).rounded() }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return (d.timeIntervalSince1970 * 1000).rounded() }
        return 0
    }

    /// HTTP dates (`Wed, 12 Oct 2009 17:50:00 GMT`) → ms, 0 when unreadable.
    static func parseHttpDateMs(_ s: String?) -> Double {
        guard let s, !s.isEmpty else { return 0 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: s) { return (d.timeIntervalSince1970 * 1000).rounded() }
        return parseIsoMs(s)
    }

    /// `failure`: S3 reports failures as XML; the message inside is the useful part.
    static func failure(status: Int, body: String, what: String) -> AppError {
        let msg = xmlOne(body, "Message")
        let code = xmlOne(body, "Code")
        if status == 403 {
            return AppError("\(what): access denied\(code.map { " (\($0))" } ?? ""). Check the credentials and the bucket policy.")
        }
        if status == 404 { return AppError("\(what): not found\(code.map { " (\($0))" } ?? "").") }
        return AppError("\(what): \(msg ?? code ?? "HTTP \(status)")")
    }

    /// One "directory" of a bucket from a ListObjectsV2 page (delimiter "/").
    static func parseListPage(_ text: String, base: String) -> (entries: [S3Object], next: String?) {
        var out: [S3Object] = []
        for cp in xmlAll(text, "CommonPrefixes") {
            let p = unescapeXml(xmlOne(cp, "Prefix"))
            var name = p.count >= base.count ? String(p.dropFirst(base.count)) : ""
            if name.hasSuffix("/") { name.removeLast() }
            if !name.isEmpty { out.append(S3Object(name: name, path: p, isDirectory: true, size: 0, mtime: 0, storageClass: nil)) }
        }
        for c in xmlAll(text, "Contents") {
            let k = unescapeXml(xmlOne(c, "Key"))
            let name = k.count >= base.count ? String(k.dropFirst(base.count)) : ""
            // The prefix itself comes back as a zero-length key; it is not a file.
            if name.isEmpty { continue }
            out.append(S3Object(name: name, path: k, isDirectory: false, size: Int64(xmlOne(c, "Size") ?? "") ?? 0,
                                mtime: parseIsoMs(xmlOne(c, "LastModified")),
                                storageClass: xmlOne(c, "StorageClass") ?? "STANDARD"))
        }
        // An empty token ends it too, as the original's falsy check did.
        let next = xmlOne(text, "IsTruncated") == "true" ? unescapeXml(xmlOne(text, "NextContinuationToken")).nilIfEmpty : nil
        return (out, next)
    }
}

/// One row of a bucket listing (`{name, path, type, size, mtime, storageClass}`).
struct S3Object: Equatable, Sendable {
    var name: String
    /// The full key (or common prefix, ending in "/").
    var path: String
    var isDirectory: Bool
    var size: Int64
    var mtime: Double
    var storageClass: String?

    var json: JSON {
        var o: JSON = ["name": .string(name), "path": .string(path), "type": .string(isDirectory ? "directory" : "file"),
                       "size": .number(Double(size)), "mtime": .number(mtime)]
        if let storageClass { o["storageClass"] = .string(storageClass) }
        return o
    }

    var fileEntry: FileEntry {
        var e = FileEntry(name: name, path: path, type: isDirectory ? .directory : .file, size: size, mode: nil,
                          modeString: isDirectory ? "d---------" : "----------", mtime: mtime > 0 ? mtime : nil)
        if let storageClass { e.extra = ["storageClass": .string(storageClass)] }
        return e
    }
}
