import Foundation

/// TCP from this machine, on plain sockets: the port check and the telnet
/// probe (`probePort` and `telnetProbe` in nettools.js). Blocking calls, made
/// on a background thread by the callers.
enum NetSocket {
    /// Node's error codes, which the original reported as-is.
    static func code(_ e: Int32) -> String {
        switch e {
        case ECONNREFUSED: return "ECONNREFUSED"
        case ETIMEDOUT: return "ETIMEDOUT"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ENETUNREACH: return "ENETUNREACH"
        case ENETDOWN: return "ENETDOWN"
        case EHOSTDOWN: return "EHOSTDOWN"
        case ECONNRESET: return "ECONNRESET"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case EACCES: return "EACCES"
        case EPERM: return "EPERM"
        case ECONNABORTED: return "ECONNABORTED"
        case EPIPE: return "EPIPE"
        default: return String(cString: strerror(e))
        }
    }

    enum Connect {
        case open(fd: Int32, address: String)
        case failed(code: String, message: String)
        case timedOut
    }

    /// Resolve and connect within `timeoutMs` (resolution included, as the
    /// original's socket timeout included it). Tries each address in turn.
    static func connect(_ host: String, _ port: Int, timeoutMs: Int) -> Connect {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &res)
        if gai != 0 {
            let code = gai == EAI_AGAIN ? "EAI_AGAIN" : "ENOTFOUND"
            return .failed(code: code, message: "getaddrinfo \(code) \(host)")
        }
        defer { freeaddrinfo(res) }
        var last: Connect = .failed(code: "ENOTFOUND", message: "getaddrinfo ENOTFOUND \(host)")
        var ai = res
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let left = Int(deadline.timeIntervalSinceNow * 1000)
            if left <= 0 { return .timedOut }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { last = .failed(code: code(errno), message: String(cString: strerror(errno))); continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let address = NetLocal.sockaddrString(a.pointee.ai_addr)
            var rc = Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
            var err: Int32 = rc == 0 ? 0 : errno
            if rc != 0 && err == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                repeat { rc = poll(&pfd, 1, Int32(max(1, left))) } while rc < 0 && errno == EINTR
                if rc == 0 { close(fd); return .timedOut }
                var so: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &so, &len)
                err = so
            }
            if err == 0 {
                return .open(fd: fd, address: address.replacingOccurrences(of: "::ffff:", with: ""))
            }
            close(fd)
            last = .failed(code: code(err), message: "connect \(code(err)) \(address):\(port)")
        }
        return last
    }

    /// One port: open, refused (closed), no answer (filtered) or an error.
    static func probe(_ host: String, _ port: Int, timeoutMs: Int) async -> PortResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                let r = connect(host, port, timeoutMs: timeoutMs)
                let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
                switch r {
                case .open(let fd, _):
                    close(fd)
                    cont.resume(returning: PortResult(port: port, state: "open", ms: ms, detail: nil))
                case .timedOut:
                    cont.resume(returning: PortResult(port: port, state: "filtered", ms: ms, detail: "no response"))
                case .failed(let code, _):
                    // A refusal is fully described by "closed"; only the
                    // unexpected codes are worth the extra words.
                    cont.resume(returning: code == "ECONNREFUSED"
                                ? PortResult(port: port, state: "closed", ms: ms, detail: nil)
                                : PortResult(port: port, state: "error", ms: ms, detail: code))
                }
            }
        }
    }

    /// The telnet probe, start to finish.
    static func telnet(_ h: String, _ p: Int, listenMs: Int, connectMs connectWithin: Int) -> TelnetResult {
        let started = Date()
        var result = TelnetResult(host: h, port: p, address: nil, state: "error", connectMs: nil, listenedMs: 0,
                                  text: "", telnet: false, closedByPeer: false, guess: nil, command: "telnet \(h) \(p)",
                                  error: nil)
        let fd: Int32
        switch connect(h, p, timeoutMs: connectWithin) {
        case .timedOut:
            result.state = "filtered"
            result.error = Telnet.errorText(code: "ETIMEDOUT", message: nil, host: h, port: p)
            return result
        case .failed(let code, let message):
            result.state = code == "ECONNREFUSED" ? "closed" : (code == "ENOTFOUND" || code == "EAI_AGAIN") ? "dns" : "error"
            result.error = Telnet.errorText(code: code, message: message, host: h, port: p)
            return result
        case .open(let s, let address):
            fd = s
            result.address = address.isEmpty ? nil : address
        }
        defer { close(fd) }
        let connectedAt = Date()
        result.connectMs = Int((connectedAt.timeIntervalSince(started) * 1000).rounded())
        result.state = "open"

        // The same parser the telnet sessions use (Devices/Service/Telnet.swift):
        // answering the negotiation is what makes a switch show its prompt.
        var tstate: Telnet.State? = nil
        var data = Data()
        let listenEnd = connectedAt.addingTimeInterval(Double(listenMs) / 1000)
        var idleEnd: Date? = nil
        var buf = [UInt8](repeating: 0, count: 8192)
        func send(_ bytes: [UInt8]) {
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n > 0 { off += n } else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(2000) } else { return }
            }
        }
        loop: while true {
            // Most services say everything in one breath: a short quiet spell
            // after some output ends the listen early.
            let end = min(listenEnd, idleEnd ?? listenEnd)
            let left = end.timeIntervalSinceNow
            if left <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, Int32(max(1, left * 1000)))
            if rc < 0 { if errno == EINTR { continue }; result.closedByPeer = true; break }
            if rc == 0 { continue }
            let n = read(fd, &buf, buf.count)
            if n == 0 { result.closedByPeer = true; break }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                result.closedByPeer = true; break
            }
            let r = Telnet.parse(tstate, Array(buf[0..<n]))
            tstate = r.state
            if !r.replies.isEmpty { result.telnet = true; send(r.replies) }
            if r.sawNaws { send(Telnet.nawsFrame(cols: 80, rows: 24)) }
            if !r.data.isEmpty { data.append(contentsOf: r.data) }
            if !data.isEmpty { idleEnd = Date().addingTimeInterval(0.7) }
            if data.count > 16384 { break loop }
        }
        result.listenedMs = Int((Date().timeIntervalSince(connectedAt) * 1000).rounded())
        result.text = NetLocal.cleanBanner(String(decoding: data, as: UTF8.self))
        result.guess = NetLocal.guessService(result.text, spokeTelnet: result.telnet)
        return result
    }
}
