import CryptoKit
import Darwin
import Foundation
import Security

/// A local control socket, so another program can drive the app (control.js).
///
/// The point of it is setup work: "open these six servers", "load the layout I
/// use for an upgrade", "which clusters am I logged into". An agent — Claude
/// Code, a script, a hotkey — can do it if there is something to talk to.
/// `ServerLife --mcp` is one such client; the protocol here is deliberately
/// plainer than MCP so anything can use it.
///
/// What it is not: a way for anything on the machine to open SSH sessions
/// unnoticed. So:
///
///   - it is off unless the user turns it on;
///   - the socket lives in the user's own temporary directory, mode 0600;
///   - every connection must present a token that is only readable by them;
///   - what it can do is a fixed list of verbs, none of which runs arbitrary
///     commands — running a *saved macro* is as far as it goes, because a
///     macro is something the user wrote and can read;
///   - every accepted call is shown where the user can see it.
///
/// The transport is newline-delimited JSON: one request object per line, one
/// response object per line. No framing, no versions to negotiate.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ verb: String, _ params: JSON, _ client: String) async throws -> JSON
    typealias Logger = @Sendable (_ kind: String, _ text: String) -> Void

    /// A request bigger than 1 MB is a mistake.
    static let maxLine = 1 << 20

    let dir: String
    private let handle: Handler
    private let onLog: Logger
    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var clients: [ObjectIdentifier: Client] = [:]

    /// One connection. Its descriptor is closed only by the thread serving it,
    /// so a number the system hands out again is never written to; anyone
    /// else may only shut it down, and only while it is still open.
    private final class Client: @unchecked Sendable {
        let fd: Int32
        let lock = NSLock()
        var closed = false
        init(fd: Int32) { self.fd = fd }
        func shutdownIfOpen() { lock.withLock { if !closed { Darwin.shutdown(fd, SHUT_RDWR) } } }
        func close() { lock.withLock { if !closed { closed = true; Darwin.close(fd) } } }
    }
    private(set) var token: String?
    private var boundPath: String?

    init(dir: String, handle: @escaping Handler, onLog: @escaping Logger) {
        self.dir = dir
        self.handle = handle
        self.onLog = onLog
    }

    var running: Bool { lock.lock(); defer { lock.unlock() }; return listenFd >= 0 }

    // MARK: paths

    /// This user's own temporary directory (what `os.tmpdir()` gives on macOS),
    /// asked of the system rather than of TMPDIR so a shell that changed TMPDIR
    /// still finds the app.
    static var tmpRoot: String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        var t = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 ? String(cString: buf) : NSTemporaryDirectory()
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static func shortHash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// Where the socket lives. Not in the settings directory: a socket under a
    /// synced or backed-up directory is a recipe for confusion.
    static func socketPath(for dir: String) -> String {
        tmpRoot + "/serverlife-\(shortHash(dir + String(getuid()))).sock"
    }

    static func tokenFile(for dir: String) -> String { (dir as NSString).appendingPathComponent("control-token") }

    var socketPath: String { lock.lock(); defer { lock.unlock() }; return boundPath ?? ControlServer.socketPath(for: dir) }
    var tokenFile: String { ControlServer.tokenFile(for: dir) }

    // MARK: token

    /// Read the token, creating one on first use.
    @discardableResult
    func ensureToken() throws -> String {
        let file = tokenFile
        if let existing = try? String(contentsOfFile: file, encoding: .utf8).trimmed, existing.count >= 32 {
            lock.lock(); token = existing; lock.unlock()
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppError("Could not make a control token.")
        }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with 0600 from the start, so there is no moment it is readable by others.
        let fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw AppError("Could not write \(file): \(String(cString: strerror(errno)))") }
        let line = Array((t + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        fchmod(fd, 0o600)
        close(fd)
        lock.lock(); token = t; lock.unlock()
        return t
    }

    /// Forget the token, so anything holding it loses access.
    @discardableResult
    func rotateToken() throws -> String {
        try? FileManager.default.removeItem(atPath: tokenFile)
        lock.lock(); token = nil; lock.unlock()
        return try ensureToken()
    }

    // MARK: start / stop

    func start() throws {
        if running { return }
        try ensureToken()
        let path = ControlServer.socketPath(for: dir)
        // A socket left behind by a crash would block binding; nothing else
        // owns this name, so removing it is safe.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError("Could not open the control socket: \(String(cString: strerror(errno)))") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw AppError("The control socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        // Nobody can connect before listen(), and the mode is set between bind
        // and listen — so no umask dance, which is process-wide and would
        // give folders created on other threads meanwhile a mode of 0600.
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard rc == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            throw AppError("Could not listen on \(path): \(e)")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let e = String(cString: strerror(errno))
            close(fd); unlink(path)
            throw AppError("Could not listen on \(path): \(e)")
        }
        lock.lock(); listenFd = fd; boundPath = path; lock.unlock()

        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "ControlServer.accept"
        t.start()
        onLog("start", "Control socket listening on \(path)")
    }

    /// Stop listening. The accept thread closes the listening socket itself;
    /// each connection is shut down and closed by its own thread.
    func stop() {
        lock.lock()
        listenFd = -1
        let conns = Array(clients.values)
        clients.removeAll()
        let path = boundPath ?? ControlServer.socketPath(for: dir)
        boundPath = nil
        lock.unlock()
        for c in conns { c.shutdownIfOpen() }
        // Also clears a socket file left behind by an earlier run.
        unlink(path)
        onLog("stop", "Control socket stopped")
    }

    /// `info()`.
    var info: JSON {
        lock.lock(); defer { lock.unlock() }
        return ["running": .bool(listenFd >= 0), "socketPath": .string(boundPath ?? ControlServer.socketPath(for: dir)),
                "tokenFile": .string(tokenFile), "token": JSON(token), "clients": .number(Double(clients.count))]
    }

    // MARK: connections

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while true {
            if lock.withLock({ listenFd != fd }) { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 250)
            if r < 0 && errno != EINTR { return }
            if r <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(fd: c)
            let keep: Bool = lock.withLock {
                guard listenFd == fd else { return false }
                clients[ObjectIdentifier(client)] = client
                return true
            }
            guard keep else { client.close(); return }
            let t = Thread { [weak self] in
                if let self { self.serve(client) } else { client.close() }
            }
            t.name = "ControlServer.client"
            t.start()
        }
    }

    private func reply(_ c: Client, _ obj: JSON) {
        var data = Data(obj.jsText().utf8)
        data.append(0x0a)
        let fd = c.fd   // still open: only this connection's own thread closes it
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
                off += n
            }
        }
    }

    private func serve(_ client: Client) {
        let fd = client.fd
        defer {
            lock.withLock { _ = clients.removeValue(forKey: ObjectIdentifier(client)) }
            client.close()
        }
        var buf = Data()
        var authed = false
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            buf.append(contentsOf: chunk[0..<n])
            if buf.count > ControlServer.maxLine {
                reply(client, ["ok": false, "error": "request too large"])
                return
            }
            while let i = buf.firstIndex(of: 0x0a) {
                let lineData = buf[buf.startIndex..<i]
                buf = Data(buf[buf.index(after: i)...])
                let line = String(decoding: lineData, as: UTF8.self).trimmed
                if line.isEmpty { continue }

                guard let req = try? JSON.parse(line), req.object != nil else {
                    reply(client, ["ok": false, "error": "malformed JSON"])
                    continue
                }

                // The first line has to authenticate; a wrong token ends the
                // conversation rather than inviting another guess.
                if !authed {
                    let given = req["token"].stringish ?? ""
                    lock.lock(); let want = token; lock.unlock()
                    guard let want, ControlServer.safeEqual(given, want) else {
                        onLog("deny", "Control connection rejected: bad token")
                        reply(client, ["ok": false, "error": "unauthorized"])
                        return
                    }
                    authed = true
                    if !req["verb"].truthy {
                        reply(client, ["ok": true, "id": req["id"], "data": ["hello": true]])
                        continue
                    }
                }

                let verb = req["verb"].stringish ?? ""
                let params = req["params"].object != nil ? req["params"] : .object([:])
                let who = req["client"].stringish?.nilIfEmpty ?? "unknown"
                let result = ControlServer.wait { [handle] in
                    do { return .success(try await handle(verb, params, who)) } catch { return .failure(error) }
                }
                switch result {
                case .success(let data): reply(client, ["ok": true, "id": req["id"], "data": data])
                case .failure(let e):
                    reply(client, ["ok": false, "id": req["id"], "error": .string((e as? AppError)?.message ?? e.localizedDescription)])
                }
            }
        }
    }

    /// Run async work from this connection's own thread and wait for it.
    private static func wait(_ work: @escaping @Sendable () async -> Result<JSON, Error>) -> Result<JSON, Error> {
        final class Box: @unchecked Sendable { var value: Result<JSON, Error> = .failure(AppError("no answer")) }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            sem.signal()
        }
        sem.wait()
        return box.value
    }

    /// Constant-time comparison of the token.
    static func safeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
