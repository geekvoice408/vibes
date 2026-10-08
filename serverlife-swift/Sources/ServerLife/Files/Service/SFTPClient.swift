import Foundation

/// A minimal SFTP v3 client that speaks the protocol directly over a
/// `ByteChannel` — the port of src/main/sftp.js.
///
/// The channel is whatever the connection layer opened: `ssh -S <controlpath>
/// <host> -s sftp` (so the connection rides the existing ControlMaster: no
/// second authentication, no extra Teleport session), `tsh ssh … sftp-server`
/// for per-session-MFA nodes, `tsh beams exec … sftp-server` for a beam, or a
/// local `/usr/libexec/sftp-server` in tests. This type depends on nothing but
/// the channel.
///
/// Thread-safe: requests may be issued from any task, concurrently — which is
/// the point, since throughput comes from keeping many requests in flight.
final class SFTPClient: @unchecked Sendable {
    // Packet types.
    enum T {
        static let INIT: UInt8 = 1, VERSION: UInt8 = 2, OPEN: UInt8 = 3, CLOSE: UInt8 = 4, READ: UInt8 = 5,
                   WRITE: UInt8 = 6, LSTAT: UInt8 = 7, FSTAT: UInt8 = 8, SETSTAT: UInt8 = 9, FSETSTAT: UInt8 = 10,
                   OPENDIR: UInt8 = 11, READDIR: UInt8 = 12, REMOVE: UInt8 = 13, MKDIR: UInt8 = 14, RMDIR: UInt8 = 15,
                   REALPATH: UInt8 = 16, STAT: UInt8 = 17, RENAME: UInt8 = 18, READLINK: UInt8 = 19, SYMLINK: UInt8 = 20,
                   STATUS: UInt8 = 101, HANDLE: UInt8 = 102, DATA: UInt8 = 103, NAME: UInt8 = 104, ATTRS: UInt8 = 105,
                   EXTENDED: UInt8 = 200
    }

    /// Open flags (`F` in sftp.js).
    struct OpenFlags: OptionSet, Sendable {
        let rawValue: UInt32
        static let read = OpenFlags(rawValue: 0x1)
        static let write = OpenFlags(rawValue: 0x2)
        static let append = OpenFlags(rawValue: 0x4)
        static let creat = OpenFlags(rawValue: 0x8)
        static let trunc = OpenFlags(rawValue: 0x10)
        static let excl = OpenFlags(rawValue: 0x20)
    }

    /// Attribute flags (`A` in sftp.js).
    enum A {
        static let SIZE: UInt32 = 0x1, UIDGID: UInt32 = 0x2, PERMISSIONS: UInt32 = 0x4, ACMODTIME: UInt32 = 0x8,
                   EXTENDED: UInt32 = 0x8000_0000
    }

    static let statusText: [UInt32: String] = [
        0: "OK", 1: "End of file", 2: "No such file", 3: "Permission denied",
        4: "Failure", 5: "Bad message", 6: "No connection", 7: "Connection lost",
        8: "Operation unsupported",
    ]

    struct Attrs: Sendable, Equatable {
        var flags: UInt32 = 0
        var size: UInt64?
        var uid: UInt32?
        var gid: UInt32?
        var mode: UInt32?
        var atime: UInt32?
        var mtime: UInt32?

        var type: FileType { FileMode.type(mode) }
        var isDirectory: Bool { type == .directory }
    }

    struct Name: Sendable {
        var filename: String
        var longname: String
        var attrs: Attrs
    }

    enum Reply: Sendable {
        case ok, eof
        case handle(Data)
        case data(Data)
        case names([Name])
        case attrs(Attrs)
    }

    let channel: ByteChannel
    /// OpenSSH caps a single read/write payload; stay under it.
    let maxRead = 32 * 1024
    let maxWrite = 32 * 1024

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var buf = Data()
    private var reqid: UInt32 = 0
    private var pending: [UInt32: (cont: CheckedContinuation<Reply, Error>, path: String?)] = [:]
    private var _version: UInt32 = 0
    private var _extensions: [String: String] = [:]
    private var _closed = false
    private var _ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var readyError: Error?
    private var closeHandlers: [@Sendable (String?) -> Void] = []
    private var connectStarted = false

    var version: UInt32 { lock.lock(); defer { lock.unlock() }; return _version }
    var extensions: [String: String] { lock.lock(); defer { lock.unlock() }; return _extensions }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready }

    init(channel: ByteChannel) {
        self.channel = channel
        channel.onClose = { [weak self] reason in self?.transportClosed(reason) }
        channel.onData = { [weak self] d in self?.onData(d) }
    }

    /// Called once when the channel goes away (with the far side's reason).
    func onClose(_ handler: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        if _closed { lock.unlock(); handler(nil); return }
        closeHandlers.append(handler)
        lock.unlock()
    }

    // MARK: - Handshake

    /// Send INIT v3 and wait for VERSION. `timeout` matches sftp.js: 30 s, or
    /// longer for a tsh transport that may be waiting on an MFA approval.
    func connect(timeout: TimeInterval = 30) async throws {
        let first = lock.withLock { () -> Bool in
            defer { connectStarted = true }
            return !connectStarted
        }
        if first {
            var w = PacketWriter()
            w.u8(T.INIT); w.u32(3)
            writePacket(w.data)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.failReady(AppError("SFTP handshake timed out"))
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if _ready { lock.unlock(); cont.resume(); return }
            if let e = readyError { lock.unlock(); cont.resume(throwing: e); return }
            readyWaiters.append(cont)
            lock.unlock()
        }
    }

    private func failReady(_ e: Error) {
        lock.lock()
        guard !_ready, readyError == nil else { lock.unlock(); return }
        readyError = e
        let w = readyWaiters; readyWaiters = []
        lock.unlock()
        w.forEach { $0.resume(throwing: e) }
    }

    // MARK: - Framing

    private func writePacket(_ body: Data) {
        var pkt = Data(capacity: body.count + 4)
        let n = UInt32(body.count).bigEndian
        withUnsafeBytes(of: n) { pkt.append(contentsOf: $0) }
        pkt.append(body)
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { return }
        channel.write(pkt)
    }

    private func onData(_ chunk: Data) {
        var packets: [Data] = []
        var tooLarge = false
        lock.lock()
        buf.append(chunk)
        var at = buf.startIndex
        while buf.endIndex - at >= 4 {
            let len = Int(buf[at]) << 24 | Int(buf[at + 1]) << 16 | Int(buf[at + 2]) << 8 | Int(buf[at + 3])
            if len > 0x100_0000 { tooLarge = true; break }
            if buf.endIndex - at < 4 + len { break }
            packets.append(Data(buf[(at + 4)..<(at + 4 + len)]))
            at += 4 + len
        }
        if at > buf.startIndex { buf = Data(buf[at...]) }
        lock.unlock()
        for p in packets { handle(p) }
        if tooLarge { destroy(AppError("SFTP packet too large")) }
    }

    private func handle(_ pkt: Data) {
        var r = PacketReader(pkt)
        guard let type = try? r.u8() else { return }
        if type == T.VERSION {
            let v = (try? r.u32()) ?? 0
            var ext: [String: String] = [:]
            while r.left > 8 {
                guard let name = try? r.text(), let data = try? r.text() else { break }
                ext[name] = data
            }
            lock.lock()
            _version = v
            _extensions = ext
            _ready = true
            let w = readyWaiters; readyWaiters = []
            lock.unlock()
            w.forEach { $0.resume() }
            return
        }
        guard let id = try? r.u32() else { return }
        lock.lock()
        let p = pending.removeValue(forKey: id)
        lock.unlock()
        guard let p else { return }
        do {
            switch type {
            case T.STATUS:
                let code = try r.u32()
                let msg = r.left >= 4 ? ((try? r.text()) ?? "") : ""
                if code == 0 { p.cont.resume(returning: .ok) }
                else if code == 1 { p.cont.resume(returning: .eof) }
                else { p.cont.resume(throwing: SFTPError(code: code, message: msg, path: p.path)) }
            case T.HANDLE: p.cont.resume(returning: .handle(try r.str()))
            case T.DATA: p.cont.resume(returning: .data(try r.str()))
            case T.NAME:
                let count = try r.u32()
                var items: [Name] = []
                for _ in 0..<count {
                    let filename = try r.text()
                    let longname = try r.text()
                    let attrs = try Self.readAttrs(&r)
                    items.append(Name(filename: filename, longname: longname, attrs: attrs))
                }
                p.cont.resume(returning: .names(items))
            case T.ATTRS: p.cont.resume(returning: .attrs(try Self.readAttrs(&r)))
            default: p.cont.resume(throwing: AppError("Unexpected SFTP packet type \(type)"))
            }
        } catch {
            p.cont.resume(throwing: AppError("Bad SFTP packet"))
        }
    }

    private func transportClosed(_ reason: String?) {
        failAll(AppError(Self.exitMessage(reason, status: (channel as? SFTPChannelExitStatus)?.exitStatus)), reason: reason)
    }

    /// `sftp transport exited (127): sftp-server not found on this host`, as
    /// sftp.js said it: the code tells "no sftp-server" (127) apart from an
    /// authentication refusal (255). The code comes from the channel when it
    /// can report one, else from ProcessChannel's "exited with code N".
    static func exitMessage(_ reason: String?, status: Int32?) -> String {
        var code = status
        var text = reason?.trimmed ?? ""
        if let re = try? NSRegularExpression(pattern: #"^exited with code (-?\d+)$"#),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            code = code ?? Int32((text as NSString).substring(with: m.range(at: 1)))
            text = ""
        }
        if code == nil && reason == nil { code = 0 }
        let head = "sftp transport exited" + (code.map { " (\($0))" } ?? "")
        return text.isEmpty ? head : head + ": " + text
    }

    private func failAll(_ err: Error, reason: String?) {
        lock.lock()
        let wasClosed = _closed
        _closed = true
        let all = pending; pending = [:]
        let handlers = closeHandlers; closeHandlers = []
        lock.unlock()
        for (_, p) in all { p.cont.resume(throwing: err) }
        failReady(err)
        if !wasClosed { handlers.forEach { $0(reason) } }
    }

    /// Tear the client down: every waiting request fails, the channel closes.
    func destroy(_ err: Error? = nil) {
        failAll(err ?? AppError("SFTP closed"), reason: (err as? AppError)?.message)
        channel.close()
    }

    // MARK: - Requests

    func request(_ type: UInt8, path: String? = nil, _ build: (inout PacketWriter) -> Void) async throws -> Reply {
        let next: UInt32? = lock.withLock {
            if _closed { return nil }
            reqid &+= 1
            return reqid
        }
        guard let id = next else { throw AppError("SFTP connection closed") }
        var w = PacketWriter()
        w.u8(type); w.u32(id)
        build(&w)
        let body = w.data
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if _closed { lock.unlock(); cont.resume(throwing: AppError("SFTP connection closed")); return }
            pending[id] = (cont, path)
            lock.unlock()
            writePacket(body)
        }
    }

    private func names(_ r: Reply) throws -> [Name] {
        if case .names(let n) = r { return n }
        throw AppError("Unexpected SFTP reply")
    }

    private func attrs(_ r: Reply) throws -> Attrs {
        if case .attrs(let a) = r { return a }
        throw AppError("Unexpected SFTP reply")
    }

    func realpath(_ p: String) async throws -> String {
        let n = try names(await request(T.REALPATH, path: p) { $0.str(p) })
        guard let first = n.first else { throw AppError("Unexpected SFTP reply") }
        return first.filename
    }

    func stat(_ p: String) async throws -> Attrs {
        try attrs(await request(T.STAT, path: p) { $0.str(p) })
    }

    func lstat(_ p: String) async throws -> Attrs {
        try attrs(await request(T.LSTAT, path: p) { $0.str(p) })
    }

    func readlink(_ p: String) async throws -> String {
        let n = try names(await request(T.READLINK, path: p) { $0.str(p) })
        guard let first = n.first else { throw AppError("Unexpected SFTP reply") }
        return first.filename
    }

    /// Full directory listing, following READDIR until EOF.
    func list(_ dir: String) async throws -> [FileEntry] {
        guard case .handle(let handle) = try await request(T.OPENDIR, path: dir, { $0.str(dir) }) else {
            throw AppError("Unexpected SFTP reply")
        }
        var out: [FileEntry] = []
        do {
            while true {
                let res = try await request(T.READDIR, path: dir) { $0.str(handle) }
                guard case .names(let batch) = res else { break }
                for n in batch where n.filename != "." && n.filename != ".." {
                    out.append(Self.toEntry(n, dir: dir))
                }
            }
        } catch {
            _ = try? await request(T.CLOSE) { $0.str(handle) }
            throw error
        }
        _ = try? await request(T.CLOSE) { $0.str(handle) }
        return out
    }

    static func toEntry(_ n: Name, dir: String) -> FileEntry {
        let a = n.attrs
        let long = parseLongname(n.longname)
        return FileEntry(
            name: n.filename,
            path: dir.hasSuffix("/") ? dir + n.filename : dir + "/" + n.filename,
            type: FileMode.type(a.mode),
            targetType: nil,
            size: Int64(a.size ?? 0),
            mode: a.mode,
            modeString: FileMode.string(a.mode),
            mtime: (a.mtime ?? 0) != 0 ? Double(a.mtime!) * 1000 : nil,
            atime: (a.atime ?? 0) != 0 ? Double(a.atime!) * 1000 : nil,
            uid: a.uid, gid: a.gid,
            // The names, not just the numbers. SFTP sends uid/gid as integers,
            // and the account they belong to lives on the server, so nothing
            // here could translate them — but the protocol also sends the
            // `ls -l` line the server itself produced, which has already done it.
            owner: (long?.owner).flatMap { $0.isEmpty ? nil : $0 },
            group: (long?.group).flatMap { $0.isEmpty ? nil : $0 },
            links: long?.links,
            longname: n.longname)
    }

    /// Resolve a symlink's target type so the UI can navigate into link-to-dir.
    func resolveEntry(_ entry: FileEntry) async -> FileEntry {
        guard entry.type == .symlink else { return entry }
        var e = entry
        do {
            let a = try await stat(entry.path)
            e.targetType = a.type
            if let s = a.size { e.size = Int64(s) }
        } catch {
            e.targetType = .broken
        }
        return e
    }

    func mkdir(_ p: String) async throws {
        _ = try await request(T.MKDIR, path: p) { $0.str(p); $0.attrs(nil) }
    }

    func rmdir(_ p: String) async throws {
        _ = try await request(T.RMDIR, path: p) { $0.str(p) }
    }

    func remove(_ p: String) async throws {
        _ = try await request(T.REMOVE, path: p) { $0.str(p) }
    }

    /// posix-rename@openssh.com when the server offers it (it replaces an
    /// existing target the way rename(2) does), plain RENAME otherwise.
    func rename(_ from: String, _ to: String) async throws {
        if extensions["posix-rename@openssh.com"] != nil {
            _ = try await request(T.EXTENDED, path: from) {
                $0.str("posix-rename@openssh.com"); $0.str(from); $0.str(to)
            }
            return
        }
        _ = try await request(T.RENAME, path: from) { $0.str(from); $0.str(to) }
    }

    func chmod(_ p: String, _ mode: UInt32) async throws {
        _ = try await request(T.SETSTAT, path: p) { $0.str(p); $0.attrs(Attrs(mode: mode)) }
    }

    /// Set access and modification times, in whole seconds.
    ///
    /// What makes an upload comparable to its source afterwards: without it a
    /// freshly uploaded file has "now" as its mtime, so any sync that compares
    /// timestamps decides it has changed again and sends it a second time, and
    /// a third, forever.
    func utimes(_ p: String, atime: Double, mtime: Double) async throws {
        let a = UInt32(max(0, atime.rounded(.down)))
        let m = UInt32(max(0, mtime.rounded(.down)))
        _ = try await request(T.SETSTAT, path: p) { $0.str(p); $0.attrs(Attrs(atime: a, mtime: m)) }
    }

    func open(_ p: String, _ flags: OpenFlags, attrs: Attrs? = nil) async throws -> Data {
        guard case .handle(let h) = try await request(T.OPEN, path: p, {
            $0.str(p); $0.u32(flags.rawValue); $0.attrs(attrs)
        }) else { throw AppError("Unexpected SFTP reply") }
        return h
    }

    func close(_ handle: Data) async throws {
        _ = try await request(T.CLOSE) { $0.str(handle) }
    }

    /// nil at end of file.
    func readChunk(_ handle: Data, offset: UInt64, length: Int) async throws -> Data? {
        let res = try await request(T.READ) { $0.str(handle); $0.u64(offset); $0.u32(UInt32(length)) }
        switch res {
        case .eof: return nil
        case .data(let d): return d
        default: throw AppError("Unexpected SFTP reply")
        }
    }

    func writeChunk(_ handle: Data, offset: UInt64, _ data: Data) async throws {
        _ = try await request(T.WRITE) { $0.str(handle); $0.u64(offset); $0.str(data) }
    }

    /// Recursively delete a directory tree.
    func removeTree(_ p: String, onProgress: ((String) -> Void)? = nil) async throws {
        for e in try await list(p) {
            if e.type == .directory { try await removeTree(e.path, onProgress: onProgress) }
            else { try await remove(e.path) }
            onProgress?(e.path)
        }
        try await rmdir(p)
    }

    // MARK: - Whole files (the inline editor; main.js sftp:readFile / sftp:writeFile)

    /// A whole file, refusing anything over `maxBytes` with the original's wording.
    func readFile(_ p: String, maxBytes: Int = 2 * 1024 * 1024) async throws -> Data {
        let st = try await stat(p)
        let size = st.size ?? 0
        if size > UInt64(maxBytes) { throw AppError("File is too large to preview (\(size) bytes)") }
        let h = try await open(p, .read)
        var out = Data()
        do {
            while true {
                guard let d = try await readChunk(h, offset: UInt64(out.count), length: maxRead), !d.isEmpty else { break }
                out.append(d)
            }
        } catch {
            try? await close(h)
            throw error
        }
        try? await close(h)
        return out
    }

    func writeFile(_ p: String, _ data: Data) async throws {
        let h = try await open(p, [.write, .creat, .trunc])
        do {
            var off = 0
            while off < data.count {
                let end = min(off + maxWrite, data.count)
                try await writeChunk(h, offset: UInt64(off), data.subdata(in: off..<end))
                off = end
            }
        } catch {
            try? await close(h)
            throw error
        }
        try? await close(h)
    }

    // MARK: - Attributes

    static func readAttrs(_ r: inout PacketReader) throws -> Attrs {
        let flags = try r.u32()
        var a = Attrs(flags: flags)
        if flags & A.SIZE != 0 { a.size = try r.u64() }
        if flags & A.UIDGID != 0 { a.uid = try r.u32(); a.gid = try r.u32() }
        if flags & A.PERMISSIONS != 0 { a.mode = try r.u32() }
        if flags & A.ACMODTIME != 0 { a.atime = try r.u32(); a.mtime = try r.u32() }
        if flags & A.EXTENDED != 0 {
            let n = try r.u32()
            for _ in 0..<n { _ = try r.str(); _ = try r.str() }
        }
        return a
    }
}

/// An SFTP STATUS failure. The message reads like sftp.js's: the server's
/// text (or the standard one for the code), then the path.
struct SFTPError: LocalizedError, CustomStringConvertible {
    var code: UInt32
    var message: String
    var path: String?
    var errorDescription: String? { description }
    var description: String {
        let text = message.isEmpty ? (SFTPClient.statusText[code] ?? "SFTP error \(code)") : message
        return text + ((path?.isEmpty == false) ? ": " + path! : "")
    }
    var noSuchFile: Bool { code == 2 }
}

/// Big-endian packet builder.
struct PacketWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func str(_ s: String) { str(Data(s.utf8)) }
    mutating func str(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
    mutating func attrs(_ a: SFTPClient.Attrs?) {
        guard let a else { u32(0); return }
        var flags: UInt32 = 0
        if a.size != nil { flags |= SFTPClient.A.SIZE }
        if a.uid != nil && a.gid != nil { flags |= SFTPClient.A.UIDGID }
        if a.mode != nil { flags |= SFTPClient.A.PERMISSIONS }
        if a.atime != nil && a.mtime != nil { flags |= SFTPClient.A.ACMODTIME }
        u32(flags)
        if let s = a.size { u64(s) }
        if flags & SFTPClient.A.UIDGID != 0 { u32(a.uid!); u32(a.gid!) }
        if let m = a.mode { u32(m) }
        if flags & SFTPClient.A.ACMODTIME != 0 { u32(a.atime!); u32(a.mtime!) }
    }
}

/// Big-endian reader over one packet body.
struct PacketReader {
    struct Short: Error {}
    private let d: Data
    private var o: Int
    init(_ d: Data) { self.d = d; o = d.startIndex }
    var left: Int { d.endIndex - o }
    mutating func u8() throws -> UInt8 {
        guard left >= 1 else { throw Short() }
        defer { o += 1 }
        return d[o]
    }
    mutating func u32() throws -> UInt32 {
        guard left >= 4 else { throw Short() }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(d[o + i]) }
        o += 4
        return v
    }
    mutating func u64() throws -> UInt64 {
        guard left >= 8 else { throw Short() }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(d[o + i]) }
        o += 8
        return v
    }
    mutating func str() throws -> Data {
        let n = Int(try u32())
        guard left >= n else { throw Short() }
        defer { o += n }
        return d.subdata(in: o..<(o + n))
    }
    mutating func text() throws -> String { String(decoding: try str(), as: UTF8.self) }
}

/// A channel that can say how its process ended. Conformed to (in this
/// directory) by whichever channel types expose an exit status.
protocol SFTPChannelExitStatus {
    var exitStatus: Int32? { get }
}
