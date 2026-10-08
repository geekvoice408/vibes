import Foundation

/// Transfer engine: pipelined SFTP uploads/downloads with progress — the
/// first half of src/main/transfers.js. The queue is in TransferQueue.swift.
///
/// SFTP reads/writes are capped at ~32KB per packet, so throughput depends
/// entirely on keeping several requests in flight. Workers pull chunk indices
/// off a shared counter and each fully completes its own chunk, which keeps
/// short reads correct without leaving holes.
enum Transfers {
    static let pipelineDepth = 16

    /// One file to move: where it is and where it goes.
    struct Item: Codable, Hashable, Sendable {
        var local: String
        var remote: String
        var size: Int64
    }

    /// A selection flattened into files, plus the directories to create first.
    struct Plan: Sendable {
        var files: [Item]
        var dirs: [String]
    }

    /// The hooks one file transfer takes (all optional).
    struct Options: Sendable {
        /// (bytes done, total) — called from the transfer's own tasks.
        var onProgress: (@Sendable (Int64, Int64) -> Void)?
        /// Called for the work that happens after the last byte has been
        /// counted — closing the local file, closing the remote handle,
        /// restoring the timestamp. On a large file that tail is long enough
        /// to see, and without something to say so the progress bar sits at
        /// 100% looking stuck. nil when it is over.
        var onPhase: (@Sendable (String?) -> Void)?
        var isCancelled: (@Sendable () -> Bool)?
        /// Held here, between chunks, while paused.
        var gate: (@Sendable () async -> Void)?
        /// Spend this many bytes of the speed limit's allowance.
        var throttle: (@Sendable (Int) async -> Void)?
        /// Pick up from what is already there (an explicit retry only).
        var resume = false

        init(onProgress: (@Sendable (Int64, Int64) -> Void)? = nil, onPhase: (@Sendable (String?) -> Void)? = nil,
             isCancelled: (@Sendable () -> Bool)? = nil, gate: (@Sendable () async -> Void)? = nil,
             throttle: (@Sendable (Int) async -> Void)? = nil, resume: Bool = false) {
            self.onProgress = onProgress; self.onPhase = onPhase; self.isCancelled = isCancelled
            self.gate = gate; self.throttle = throttle; self.resume = resume
        }

        func checkCancelled() throws {
            if isCancelled?() == true { throw AppError("cancelled") }
        }
    }

    /// A thread-safe running total.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int64
        init(_ v: Int64 = 0) { self.v = v }
        @discardableResult func add(_ n: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; v += n; return v }
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return v }
    }

    private final class Indexer: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var failed = false
        let total: Int
        init(_ total: Int) { self.total = total }
        func take() -> Int? {
            lock.lock(); defer { lock.unlock() }
            if failed || next >= total { return nil }
            defer { next += 1 }
            return next
        }
        func fail() { lock.lock(); failed = true; lock.unlock() }
    }

    /// Run `count` workers that each pull indices off a shared counter.
    /// An error stops every worker taking more and is rethrown.
    static func parallelChunks(_ count: Int, _ total: Int, _ fn: @escaping @Sendable (Int) async throws -> Void) async throws {
        let idx = Indexer(total)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<max(1, count) {
                g.addTask {
                    while let i = idx.take() {
                        do { try await fn(i) } catch { idx.fail(); throw error }
                    }
                }
            }
            var first: Error?
            while true {
                do { guard try await g.next() != nil else { break } } catch { if first == nil { first = error } }
            }
            if let first { throw first }
        }
    }

    // MARK: - Download

    /// Download one remote file to a local path. Returns the bytes moved.
    @discardableResult
    static func downloadFile(_ sftp: SFTPClient, remote: String, local: String, _ opts: Options = Options()) async throws -> Int64 {
        let attrs = try await sftp.stat(remote)
        let size = Int64(attrs.size ?? 0)
        let chunk = sftp.maxRead

        try LocalFS.ensureParentDir(local)
        /*
         * Resuming picks up where the local copy stops.
         *
         * Only on an explicit retry: a fresh transfer to an existing path means
         * "replace it", and appending to whatever was there would quietly
         * produce a corrupt file. Writes are positional, so the bytes already
         * fetched are kept and the chunks below the mark are simply skipped.
         */
        var resumeAt: Int64 = 0
        if opts.resume, let st = LocalFS.stat(local), st.isFile, st.size > 0, st.size < size { resumeAt = st.size }
        let from = resumeAt
        let handle = try await sftp.open(remote, .read)
        let fd = Darwin.open(local, from > 0 ? O_RDWR : (O_WRONLY | O_CREAT | O_TRUNC), 0o666)
        if fd < 0 {
            let e = LocalFS.nodeError("open", local)
            try? await sftp.close(handle)
            throw e
        }
        let done = Counter(from)
        if from > 0 { opts.onProgress?(from, size) }

        var failure: Error?
        do {
            if size == 0 {
                // Unknown or empty size: fall back to a simple sequential drain.
                var offset = from
                while true {
                    try opts.checkCancelled()
                    await opts.gate?()
                    guard let data = try await sftp.readChunk(handle, offset: UInt64(offset), length: chunk), !data.isEmpty else { break }
                    try pwriteAll(fd, data, at: offset, path: local)
                    offset += Int64(data.count)
                    let d = done.add(Int64(data.count))
                    opts.onProgress?(d, max(d, size))
                    await opts.throttle?(data.count)
                }
            } else {
                let chunks = Int((size + Int64(chunk) - 1) / Int64(chunk))
                try await parallelChunks(pipelineDepth, chunks) { idx in
                    var offset = Int64(idx) * Int64(chunk)
                    let end = min(offset + Int64(chunk), size)
                    // Already on disk from an interrupted run.
                    if end <= from { return }
                    if offset < from { offset = from }
                    while offset < end {
                        try opts.checkCancelled()
                        await opts.gate?()
                        guard let data = try await sftp.readChunk(handle, offset: UInt64(offset), length: Int(end - offset)),
                              !data.isEmpty else { return }   // early EOF (file shrank)
                        try pwriteAll(fd, data, at: offset, path: local)
                        offset += Int64(data.count)
                        let d = done.add(Int64(data.count))
                        opts.onProgress?(d, size)
                        await opts.throttle?(data.count)
                    }
                }
            }
        } catch {
            failure = error
        }
        opts.onPhase?("writing out the file")
        Darwin.close(fd)
        try? await sftp.close(handle)
        if let failure { throw failure }

        if let m = attrs.mtime, m != 0 {
            setLocalTimes(local, atime: Double(attrs.atime.flatMap { $0 == 0 ? nil : $0 } ?? m), mtime: Double(m))
        }
        opts.onPhase?(nil)
        return done.value
    }

    private static func pwriteAll(_ fd: Int32, _ data: Data, at offset: Int64, path: String) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var written = 0
            while written < raw.count {
                let n = pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LocalFS.nodeError("write")
                }
                written += n
            }
        }
    }

    /// Seconds since the epoch.
    static func setLocalTimes(_ path: String, atime: Double, mtime: Double) {
        var tv = [timeval(tv_sec: Int(atime), tv_usec: 0), timeval(tv_sec: Int(mtime), tv_usec: 0)]
        _ = utimes(path, &tv)
    }

    // MARK: - Upload

    /// Upload one local file to a remote path. See downloadFile for `onPhase`.
    @discardableResult
    static func uploadFile(_ sftp: SFTPClient, local: String, remote: String, _ opts: Options = Options()) async throws -> Int64 {
        let st = try LocalFS.statOrThrow(local)
        let size = st.size
        let chunk = sftp.maxWrite
        let mode = st.mode & 0o777
        // The same resume rule as a download, from the other end: what the
        // server already has, and only when a retry asked for it. Without
        // TRUNC, so the bytes already there survive.
        var resumeAt: Int64 = 0
        if opts.resume, let rst = try? await sftp.stat(remote) {
            let rs = Int64(rst.size ?? 0)
            if rs > 0 && rs < size { resumeAt = rs }
        }
        let from = resumeAt
        let handle = from > 0
            ? try await sftp.open(remote, [.write, .creat], attrs: SFTPClient.Attrs(mode: mode))
            : try await sftp.open(remote, [.write, .creat, .trunc], attrs: SFTPClient.Attrs(mode: mode))
        let fd = Darwin.open(local, O_RDONLY)
        if fd < 0 {
            let e = LocalFS.nodeError("open", local)
            try? await sftp.close(handle)
            throw e
        }
        let done = Counter(from)
        if from > 0 { opts.onProgress?(from, size) }

        var failure: Error?
        do {
            let chunks = max(1, Int((size + Int64(chunk) - 1) / Int64(chunk)))
            try await parallelChunks(pipelineDepth, chunks) { idx in
                var offset = Int64(idx) * Int64(chunk)
                let end = min(offset + Int64(chunk), size)
                if end <= from { return }
                if offset < from { offset = from }
                if offset >= end && size > 0 { return }
                let len = Int(end - offset)
                if len <= 0 { return }
                var buf = Data(count: len)
                let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, len, off_t(offset)) }
                if n <= 0 { return }
                if n < len { buf = buf.prefix(n) }
                try opts.checkCancelled()
                await opts.gate?()
                try await sftp.writeChunk(handle, offset: UInt64(offset), buf)
                let d = done.add(Int64(n))
                opts.onProgress?(d, size)
                await opts.throttle?(n)
            }
        } catch {
            failure = error
        }
        // The last write returning is not the file being on the disk: the
        // server flushes on CLOSE, and for a large file that is where the
        // seconds go.
        opts.onPhase?("the server is closing the file")
        Darwin.close(fd)
        try? await sftp.close(handle)
        if let failure { throw failure }

        // An overwrite keeps the existing file's mode through TRUNC, so this is
        // what makes the uploaded copy match the local one — and the timestamp
        // is what lets a later sync see the two as the same file rather than
        // sending it again every run.
        opts.onPhase?("setting permissions")
        try? await sftp.chmod(remote, mode)
        if st.mtimeMs > 0 {
            let secs = (st.mtimeMs / 1000).rounded(.down)
            try? await sftp.utimes(remote, atime: ((st.atimeMs > 0 ? st.atimeMs : st.mtimeMs) / 1000).rounded(.down), mtime: secs)
        }
        opts.onPhase?(nil)
        return done.value
    }

    // MARK: - Planning

    /// Walk a local file or directory into a flat file list with remote destinations.
    static func planUpload(_ localPath: String, remoteDir: String) async throws -> Plan {
        let st = try LocalFS.statOrThrow(localPath)
        let base = (localPath as NSString).lastPathComponent
        if !st.isDir {
            return Plan(files: [Item(local: localPath, remote: Posix.join(remoteDir, base), size: st.size)], dirs: [])
        }
        var files: [Item] = []
        var dirs: [String] = []
        func walk(_ lp: String, _ rp: String) throws {
            dirs.append(rp)
            for name in try LocalFS.readdir(lp) {
                let l = (lp as NSString).appendingPathComponent(name)
                let r = Posix.join(rp, name)
                guard let e = LocalFS.lstat(l) else { continue }
                if e.isDir { try walk(l, r) }
                else if e.isFile { files.append(Item(local: l, remote: r, size: e.size)) }
            }
        }
        try walk(localPath, Posix.join(remoteDir, base))
        return Plan(files: files, dirs: dirs)
    }

    /// Walk a remote file or directory into a flat file list with local destinations.
    static func planDownload(_ sftp: SFTPClient, remotePath: String, localDir: String, known: FileEntry? = nil) async throws -> Plan {
        let base = remotePath.split(separator: "/").last.map(String.init) ?? "download"
        var type = known?.type
        if type == nil || type == .symlink {
            let a = try await sftp.stat(remotePath)
            type = a.isDirectory ? .directory : .file
        }
        if type != .directory {
            let a = try await sftp.stat(remotePath)
            return Plan(files: [Item(local: (localDir as NSString).appendingPathComponent(base), remote: remotePath,
                                     size: Int64(a.size ?? 0))], dirs: [])
        }
        var files: [Item] = []
        var dirs: [String] = []
        func walk(_ rp: String, _ lp: String) async throws {
            dirs.append(lp)
            for e in try await sftp.list(rp) {
                let l = (lp as NSString).appendingPathComponent(e.name)
                if e.type == .directory { try await walk(e.path, l) }
                else if e.type == .file { files.append(Item(local: l, remote: e.path, size: e.size)) }
            }
        }
        try await walk(remotePath, (localDir as NSString).appendingPathComponent(base))
        return Plan(files: files, dirs: dirs)
    }
}

/// The text of an error, the way the original's `e.message` read.
func errorText(_ e: Error) -> String {
    if let a = e as? AppError { return a.message }
    if let s = e as? SFTPError { return s.description }
    if let l = e as? LocalizedError, let d = l.errorDescription { return d }
    return "\(e)"
}
