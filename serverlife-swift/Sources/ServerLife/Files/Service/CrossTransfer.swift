import Foundation

/// Server-to-server file transfer (src/main/crosstransfer.js).
///
/// Two routes:
///   direct — both endpoints are Teleport nodes on the same proxy and
///            cluster, so `tsh scp` moves the bytes server-to-server and they
///            never touch this machine.
///   relay  — anything else (different clusters, plain SSH, or a mix). The
///            data is pulled down to a temp directory and pushed back up, so
///            the caller must confirm: it costs bandwidth and briefly writes
///            the file to local disk.
enum CrossTransfer {
    struct Route: Codable, Sendable, Equatable {
        /// "direct" | "relay"
        var mode: String
        var reason: String
    }

    /// Can these two connections hand off directly?
    static func planRoute(_ src: FilesConn, _ dest: FilesConn) -> Route {
        let s = src.host, d = dest.host
        let bothTeleport = src.type == "teleport" && dest.type == "teleport"
        if bothTeleport && s.proxy == d.proxy && s.cluster == d.cluster {
            return Route(mode: "direct", reason: "Both nodes are on \(s.cluster ?? ""); tsh will copy them server-to-server.")
        }
        let why = !bothTeleport ? "At least one endpoint is a plain SSH host." : "The nodes are on different Teleport clusters."
        return Route(mode: "relay", reason: "\(why) Files will be downloaded to this machine and uploaded to the destination.")
    }

    static func scpTarget(_ conn: FilesConn, _ remotePath: String) -> String {
        let login = conn.login.map { $0 + "@" } ?? ""
        let h = conn.host.hostname?.nilIfEmpty ?? conn.host.name
        return "\(login)\(h):\(remotePath)"
    }

    /// One file of the selection, relative to the destination directory.
    struct CrossFile: Sendable, Equatable {
        var path: String
        var rel: String
        var size: Int64
    }

    /// Flatten the selection into files with destination-relative paths.
    static func planCross(_ sftp: SFTPClient, _ entries: [FileEntry]) async throws -> [CrossFile] {
        var files: [CrossFile] = []
        for e in entries {
            if !e.isDirectoryLike {
                let size = (try? await sftp.stat(e.path)).flatMap { $0.size }.map(Int64.init) ?? 0
                files.append(CrossFile(path: e.path, rel: e.name, size: size))
                continue
            }
            func walk(_ dir: String, _ prefix: String) async throws {
                for k in try await sftp.list(dir) {
                    let rel = prefix + "/" + k.name
                    if k.type == .directory { try await walk(k.path, rel) }
                    else if k.type == .file { files.append(CrossFile(path: k.path, rel: rel, size: k.size)) }
                }
            }
            try await walk(e.path, e.name)
        }
        return files
    }

    private static let meter = try! NSRegularExpression(pattern: #"(\S+)\s+\[[^\]]*\]\s+(\d+)%"#)

    /// Direct hand-off with `tsh scp`. Progress is scraped from tsh's own
    /// meter, which reports a percentage per file.
    static func runDirect(src: FilesConn, dest: FilesConn, entries: [FileEntry], destDir: String,
                          ctx: TransferRunContext, totalBytes: Int64) async throws {
        let node = src.host
        var args: [String] = []
        if let p = node.proxy, !p.isEmpty { args.append("--proxy=" + p) }
        args += ["scp", "-r", "-q"]
        if let c = node.cluster, !c.isEmpty { args.append("--cluster=" + c) }
        for e in entries { args.append(scpTarget(src, e.path)) }
        args.append(scpTarget(dest, destDir.hasSuffix("/") ? destDir : destDir + "/"))
        // Both ends are in the same cluster for a direct hand-off, so the
        // source node's tsh home is the one that holds the certificate.
        let env = Tools.tshEnv(home: node.home ?? Tools.home(forProxy: node.proxy))

        final class State: @unchecked Sendable {
            let lock = NSLock()
            var err = ""
            var completed = 0
        }
        let state = State()
        let perFile = totalBytes > 0 && !entries.isEmpty ? Double(totalBytes) / Double(entries.count) : 0
        let onChunk: @Sendable (Data) -> Void = { d in
            let text = String(decoding: d, as: UTF8.self)
            state.lock.lock()
            state.err += text
            if state.err.count > 8000 { state.err = String(state.err.suffix(8000)) }
            let ns = text as NSString
            for m in meter.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let pct = Double(ns.substring(with: m.range(at: 2))) ?? 0
                ctx.setFile(name, nil)
                if perFile > 0 {
                    ctx.onProgress(Int64(min(Double(totalBytes), Double(state.completed) * perFile + pct / 100 * perFile)), totalBytes)
                }
                if pct == 100 { state.completed += 1 }
            }
            state.lock.unlock()
        }
        let p = try RunningProcess(Tools.tsh, args, env: env, onStdout: onChunk, onStderr: onChunk)
        p.closeStdin()
        let watcher = Task {
            while !Task.isCancelled {
                if ctx.isCancelled() { p.signal(SIGKILL); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let code = await p.wait()
        watcher.cancel()
        if ctx.isCancelled() { throw AppError("cancelled") }
        if code != 0 {
            let err = state.lock.withLock { state.err }
            let clean = (meter.stringByReplacingMatches(in: err, range: NSRange(location: 0, length: (err as NSString).length), withTemplate: "") as String)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
            throw AppError(clean.isEmpty ? "tsh scp failed (exit \(code))" : clean)
        }
        ctx.onProgress(totalBytes, totalBytes)
    }

    /// Pull down to a temp dir, push back up, then clean up.
    static func runRelay(srcSftp: SFTPClient, destSftp: SFTPClient, files: [CrossFile], destDir: String,
                         ctx: TransferRunContext) async throws {
        let tmpRoot = try makeTempDir(prefix: "serverlife-relay-")
        defer { try? FileManager.default.removeItem(atPath: tmpRoot) }
        // Each byte is moved twice, so the progress denominator is doubled.
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let grand = total * 2
        var moved: Int64 = 0

        // Recreate the directory structure on the destination first.
        var made = Set<String>()
        for f in files {
            let destPath = Posix.join(destDir, f.rel)
            let parent = String(destPath[..<(destPath.lastIndex(of: "/") ?? destPath.startIndex)])
            if !parent.isEmpty && !made.contains(parent) { await mkdirp(destSftp, parent, &made) }
        }

        for (i, f) in files.enumerated() {
            if ctx.isCancelled() { throw AppError("cancelled") }
            ctx.setFile(f.rel, i + 1)
            let local = (tmpRoot as NSString).appendingPathComponent(f.rel.replacingOccurrences(of: "/", with: "__"))
            let base = moved
            try await Transfers.downloadFile(srcSftp, remote: f.path, local: local, Transfers.Options(
                onProgress: { d, _ in ctx.onProgress(base + d, grand) }, isCancelled: ctx.isCancelled))
            moved = base + f.size
            let base2 = moved
            try await Transfers.uploadFile(destSftp, local: local, remote: Posix.join(destDir, f.rel), Transfers.Options(
                onProgress: { d, _ in ctx.onProgress(base2 + d, grand) }, isCancelled: ctx.isCancelled))
            moved = base2 + f.size
            unlink(local)
        }
        ctx.onProgress(grand, grand)
    }

    static func mkdirp(_ sftp: SFTPClient, _ dir: String, _ made: inout Set<String>) async {
        var cur = ""
        for part in dir.split(separator: "/") {
            cur += "/" + part
            if made.contains(cur) { continue }
            try? await sftp.mkdir(cur)   // already-exists is fine
            made.insert(cur)
        }
    }

    static func makeTempDir(prefix: String) throws -> String {
        var template = Array(((NSTemporaryDirectory() as NSString).appendingPathComponent(prefix + "XXXXXX")).utf8CString)
        guard let p = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw LocalFS.nodeError("mkdtemp", prefix + "XXXXXX")
        }
        return String(cString: p)
    }

    struct Started: Codable, Sendable {
        var jobId: String
        var mode: String
        var route: Route
        var fileCount: Int
        var totalBytes: Int64
    }

    /// Queue a server-to-server transfer on the destination connection.
    @MainActor
    static func transfer(src: FilesConn, dest: FilesConn, entries: [FileEntry], destDir: String,
                         mode: String? = nil) async throws -> Started {
        let route = planRoute(src, dest)
        let chosen = mode ?? route.mode
        let srcSftp = try await FilesService.shared.sftp(src.id)
        let files = try await planCross(srcSftp, entries)
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let label = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        let destId = dest.id
        let jobId = FilesService.shared.queue(dest.id).add(TransferJobSpec(
            kind: "cross",
            label: "\(src.label): \(label) → \(dest.label):\(destDir)",
            items: files.map { Transfers.Item(local: "", remote: $0.path, size: $0.size) },
            dirs: [],
            customRun: { ctx in
                if chosen == "direct" {
                    try await runDirect(src: src, dest: dest, entries: entries, destDir: destDir, ctx: ctx, totalBytes: totalBytes)
                } else {
                    let s = try await FilesService.shared.sftp(src.id)
                    let d = try await FilesService.shared.sftp(destId)
                    try await runRelay(srcSftp: s, destSftp: d, files: files, destDir: destDir, ctx: ctx)
                }
            }))
        return Started(jobId: jobId, mode: chosen, route: route, fileCount: files.count, totalBytes: totalBytes)
    }
}
