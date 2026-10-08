import Foundation
import CShim

/// Why a socket failed, with the node error code the original's wording keys
/// on (`ECONNREFUSED`, `ENOTFOUND` …) and the system's own message.
struct DevSocketError: Error, CustomStringConvertible {
    var code: String
    var message: String
    var description: String { message }

    static func errno(_ e: Int32) -> DevSocketError {
        let names: [Int32: String] = [
            ECONNREFUSED: "ECONNREFUSED", ETIMEDOUT: "ETIMEDOUT", EHOSTUNREACH: "EHOSTUNREACH",
            ENETUNREACH: "ENETUNREACH", ECONNRESET: "ECONNRESET", EPIPE: "EPIPE", EHOSTDOWN: "EHOSTDOWN",
            ENETDOWN: "ENETDOWN", EADDRNOTAVAIL: "EADDRNOTAVAIL",
        ]
        return DevSocketError(code: names[e] ?? "E\(e)", message: String(cString: strerror(e)))
    }
}

/// A plain blocking TCP socket, for telnet and VNC (`net.Socket` in the
/// original). Connecting and reading happen on background threads; writes
/// may come from any thread and are serialised.
final class DevSocket: @unchecked Sendable {
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32
    private var shut = false
    /// The numeric address actually connected to (`socket.remoteAddress`).
    let remoteAddress: String?

    private init(fd: Int32, remoteAddress: String?) {
        self.fd = fd
        self.remoteAddress = remoteAddress
    }

    /// Resolve and connect, trying each address in turn. Blocking: call from a
    /// background thread. `timeout` nil leaves it to the operating system,
    /// which is what node did.
    static func connect(host: String, port: Int, timeout: TimeInterval? = nil,
                        cancelled: (() -> Bool)? = nil) throws -> DevSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        if rc != 0 {
            let code = rc == EAI_AGAIN ? "EAI_AGAIN" : "ENOTFOUND"
            throw DevSocketError(code: code, message: String(cString: gai_strerror(rc)))
        }
        defer { freeaddrinfo(res) }
        var lastError = DevSocketError(code: "ECONNREFUSED", message: "Connection refused")
        var ai = res
        while let a = ai {
            if cancelled?() == true { throw DevSocketError(code: "ECANCELED", message: "cancelled") }
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s < 0 { lastError = .errno(Darwin.errno); ai = a.pointee.ai_next; continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            if let err = connectOne(s, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout: timeout, cancelled: cancelled) {
                Darwin.close(s)
                lastError = err
                if err.code == "ECANCELED" { throw err }
                ai = a.pointee.ai_next
                continue
            }
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            return DevSocket(fd: s, remoteAddress: numericAddress(a.pointee.ai_addr, a.pointee.ai_addrlen))
        }
        throw lastError
    }

    /// Non-blocking connect polled in short slices, so a cancel (the pane
    /// closed while still dialling) is noticed.
    private static func connectOne(_ s: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: socklen_t,
                                   timeout: TimeInterval?, cancelled: (() -> Bool)?) -> DevSocketError? {
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }
        if Darwin.connect(s, addr, len) == 0 { return nil }
        if Darwin.errno != EINPROGRESS { return .errno(Darwin.errno) }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if cancelled?() == true { return DevSocketError(code: "ECANCELED", message: "cancelled") }
            if let deadline, Date() >= deadline { return .errno(ETIMEDOUT) }
            var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let r = poll(&p, 1, 250)
            if r < 0 { if Darwin.errno == EINTR { continue }; return .errno(Darwin.errno) }
            if r == 0 { continue }
            var err: Int32 = 0
            var l = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &l)
            return err == 0 ? nil : .errno(err)
        }
    }

    private static func numericAddress(_ addr: UnsafeMutablePointer<sockaddr>, _ len: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    /// Blocking read of up to `max` bytes. Empty data means the far end closed
    /// (or `close()` was called); a thrown error is a reset or similar.
    func read(max: Int = 65536) throws -> Data {
        lock.lock(); let f = fd; let isShut = shut; lock.unlock()
        if f < 0 || isShut { return Data() }
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = recv(f, &buf, max, 0)
            if n > 0 { return Data(buf[0..<n]) }
            if n == 0 { return Data() }
            if Darwin.errno == EINTR { continue }
            lock.lock(); let wasShut = shut; lock.unlock()
            if wasShut { return Data() }
            throw DevSocketError.errno(Darwin.errno)
        }
    }

    /// Write everything, or throw.
    func write(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        lock.lock(); let f = fd; lock.unlock()
        if f < 0 { throw DevSocketError(code: "EPIPE", message: "the connection is closed") }
        try data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = send(f, p, left, 0)
                if n > 0 { left -= n; p = p.advanced(by: n) }
                else if n < 0 && Darwin.errno == EINTR { continue }
                else { throw DevSocketError.errno(Darwin.errno) }
            }
        }
    }

    func write(_ bytes: [UInt8]) throws { try write(Data(bytes)) }

    /// Hang up. Wakes a reader blocked in `read`. Safe to call more than once.
    func close() {
        lock.lock()
        let f = fd
        if f >= 0 && !shut {
            shut = true
            Darwin.shutdown(f, SHUT_RDWR)
        }
        lock.unlock()
    }

    /// Release the descriptor (the reader thread does this once it is done).
    func release() {
        close()
        lock.lock()
        let f = fd
        fd = -1
        lock.unlock()
        if f >= 0 { Darwin.close(f) }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}
