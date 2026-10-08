import Foundation

/// What happened on the protocol thread, delivered to the main queue.
enum RFBEvent {
    case authenticating
    case connected(width: Int, height: Int, name: String)
    case resized(width: Int, height: Int)
    /// Pixels changed (one whole FramebufferUpdate's worth).
    case damage
    case cursor(RFBCursor)
    case clipboard(String)
    case bell
    /// The server answered (or refused) a SetDesktopSize of ours.
    case resizeRefused(String)
    /// The handshake or the connection failed; the message is meant for people.
    case failed(String)
    /// The server ended a session that was running.
    case ended(String)
    /// We hung up (or the password prompt was cancelled).
    case closed
}

/// An RFB 3.3 / 3.7 / 3.8 client on its own thread: blocking reads, the
/// decoders writing straight into the framebuffer, events posted to the main
/// queue. Client messages can be sent from any thread.
final class RFBClient: @unchecked Sendable {
    struct Options {
        /// Let other viewers stay connected (ClientInit shared flag).
        var shared = true
        /// JPEG quality 0…9 (Tight). The original's default is 6.
        var quality = 6
        /// zlib effort 0…9. The original's default is 2.
        var compression = 2
    }

    let host: String
    let port: Int
    let options: Options
    let framebuffer = RFBFramebuffer(width: 1, height: 1)

    /// Events, on the main queue.
    var onEvent: ((RFBEvent) -> Void)?
    /// Asked (on the protocol thread, blocking) when the server wants a
    /// password and none was given. nil cancels.
    var passwordProvider: (() -> String?)?

    private var password: String?
    private let lock = NSLock()
    private var socket: DevSocket?
    private var stopped = false
    private var connected = false
    private var thread: Thread?
    /// The server's screens, once it has spoken ExtendedDesktopSize — which
    /// is also what says it will accept SetDesktopSize.
    private var screens: [RFBScreen] = []
    private(set) var serverVersion = ""
    private(set) var protocolVersion = ""

    init(host: String, port: Int, password: String?, options: Options = Options()) {
        self.host = host
        self.port = port
        self.password = password
        self.options = options
    }

    var supportsRemoteResize: Bool { lock.lock(); defer { lock.unlock() }; return !screens.isEmpty }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "vnc.rfb"
        thread = t
        t.start()
    }

    /// Hang up. Safe to call more than once.
    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let s = socket
        lock.unlock()
        if !wasStopped { s?.close() }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func post(_ e: RFBEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    // MARK: - The connection

    private func run() {
        let sock: DevSocket
        do {
            sock = try DevSocket.connect(host: host, port: port, timeout: 30, cancelled: { [weak self] in self?.isStopped ?? true })
        } catch {
            if isStopped { post(.closed) } else { post(.failed(RFBClient.connectError(error, host: host, port: port))) }
            return
        }
        lock.lock()
        socket = sock
        let stoppedAlready = stopped
        lock.unlock()
        if stoppedAlready { sock.release(); post(.closed); return }

        let reader = RFBReader(source: { Array(try sock.read()) })
        do {
            try handshake(reader, sock)
            password = nil
            try loop(reader, sock)
        } catch let e as Cancelled {
            _ = e
            sock.release()
            post(.closed)
            return
        } catch let e as Failure {
            sock.release()
            post(isStopped ? .closed : .failed(e.message))
            return
        } catch is RFBReader.EndOfStream {
            sock.release()
            if isStopped { post(.closed) }
            else if connected { post(.ended("the server closed the session")) }
            else { post(.failed("the server closed the connection before the session started")) }
            return
        } catch {
            sock.release()
            if isStopped { post(.closed) }
            else if connected { post(.failed("the connection dropped")) }
            else { post(.failed("\(error)")) }
            return
        }
        sock.release()
        post(.closed)
    }

    private struct Failure: Error { var message: String }
    private struct Cancelled: Error {}

    /// A socket failure, said plainly.
    static func connectError(_ err: Error, host: String, port: Int) -> String {
        let code = (err as? DevSocketError)?.code ?? ""
        switch code {
        case "ECONNREFUSED": return "the connection was refused — nothing is listening on port \(port)"
        case "ETIMEDOUT": return "the connection timed out"
        case "EHOSTUNREACH", "EHOSTDOWN": return "no route to host"
        case "ENETUNREACH", "ENETDOWN": return "the network is unreachable"
        case "ENOTFOUND", "EAI_AGAIN": return "could not resolve \(host)"
        case "ECONNRESET": return "the connection was reset"
        default: return (err as? DevSocketError)?.message ?? "\(err)"
        }
    }

    /// The version this client answers with, for what the server offered
    /// (noVNC's table: 3.3 for anything older, 3.8 for 3.8 and newer —
    /// including Apple's 003.889 and RealVNC's 004.x).
    static func negotiatedVersion(_ serverVersion: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"^RFB (\d{3})\.(\d{3})\n?$"#)
        guard let m = re.firstMatch(in: serverVersion, range: NSRange(serverVersion.startIndex..., in: serverVersion)),
              let r1 = Range(m.range(at: 1), in: serverVersion), let r2 = Range(m.range(at: 2), in: serverVersion),
              let major = Int(serverVersion[r1]), let minor = Int(serverVersion[r2]) else { return nil }
        if major > 3 || (major == 3 && minor >= 8) { return "003.008" }
        if major == 3 && minor == 7 { return "003.007" }
        if major == 3 { return "003.003" }
        return nil
    }

    static let appleSecurityTypes: Set<UInt8> = [30, 33, 35, 36]

    private func handshake(_ r: RFBReader, _ sock: DevSocket) throws {
        // ProtocolVersion
        let v = String(decoding: try r.bytes(12), as: UTF8.self)
        serverVersion = v.trimmingCharacters(in: .newlines)
        guard let ver = RFBClient.negotiatedVersion(v) else {
            let shown = v.filter { $0.isASCII && !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " ") }
            throw Failure(message: "this is not a VNC server (it said “\(shown)”)")
        }
        protocolVersion = ver
        try sock.write(Array("RFB \(ver)\n".utf8))

        // Security
        var type: UInt8
        if ver == "003.003" {
            let t = try r.u32()
            if t == 0 { throw Failure(message: try reason(r) ?? "the server refused the connection") }
            guard t == 1 || t == 2 else {
                throw Failure(message: "the server asks for a kind of authentication this viewer does not support (type \(t))")
            }
            type = UInt8(t)
        } else {
            let n = Int(try r.u8())
            if n == 0 { throw Failure(message: try reason(r) ?? "the server refused the connection") }
            let types = try r.bytes(n)
            // The server's order of preference, among the ones we speak.
            guard let pick = types.first(where: { $0 == 1 || $0 == 2 }) else {
                var msg = "the server asks for a kind of authentication this viewer does not support (types: "
                    + types.map(String.init).joined(separator: ", ") + ")"
                if types.contains(where: { RFBClient.appleSecurityTypes.contains($0) }) {
                    msg += " — on a Mac, turn on “VNC viewers may control screen with password” in Screen Sharing settings"
                }
                throw Failure(message: msg)
            }
            type = pick
            try sock.write([type])
        }

        if type == 2 {
            post(.authenticating)
            let challenge = try r.bytes(16)
            var pw = password
            if pw == nil || pw!.isEmpty {
                pw = passwordProvider?()
                if pw == nil { throw Cancelled() }
            }
            try sock.write(try VNCAuth.response(challenge: challenge, password: pw ?? ""))
        }

        // SecurityResult: always in 3.8; in 3.3 and 3.7 only after VNC auth.
        if ver == "003.008" || type == 2 {
            let result = try r.u32()
            if result != 0 {
                if ver == "003.008" { throw Failure(message: try reason(r) ?? "Authentication failure") }
                throw Failure(message: result == 2 ? "Too many authentication attempts" : "Authentication failure")
            }
        }

        // ClientInit / ServerInit
        try sock.write([options.shared ? 1 : 0])
        let w = try r.u16(), h = try r.u16()
        try r.skip(16)  // the server's pixel format: we set our own below
        let nameLen = Int(try r.u32())
        if nameLen > RFBClient.maxNameLength {
            throw Failure(message: "the server sent a desktop name of \(nameLen) bytes, which is not a VNC server behaving")
        }
        let name = String(decoding: try r.bytes(nameLen), as: UTF8.self)
        framebuffer.resize(width: w, height: h)

        try sock.write(RFBMessages.setPixelFormat32())
        try sock.write(RFBMessages.setEncodings(RFBClient.encodings(options)))
        try sock.write(RFBMessages.updateRequest(incremental: false, x: 0, y: 0, w: w, h: h))
        lock.lock(); connected = true; lock.unlock()
        post(.connected(width: w, height: h, name: name))
    }

    /// What we ask for, best first: CopyRect is cheapest of all; then the
    /// compressing encodings, then the pseudo-encodings.
    static func encodings(_ o: Options) -> [Int32] {
        [RFBEncoding.copyRect, RFBEncoding.tight, RFBEncoding.zrle, RFBEncoding.hextile, RFBEncoding.rre,
         RFBEncoding.raw, RFBEncoding.quality(o.quality), RFBEncoding.compression(o.compression),
         RFBEncoding.desktopSize, RFBEncoding.lastRect, RFBEncoding.extendedDesktopSize, RFBEncoding.cursor]
    }

    private func reason(_ r: RFBReader) throws -> String? {
        let n = Int(try r.u32())
        guard n > 0 && n < 1 << 20 else { return nil }
        let s = String(decoding: try r.bytes(n), as: UTF8.self).trimmed
        return s.isEmpty ? nil : s
    }

    // MARK: - Server messages

    private func loop(_ r: RFBReader, _ sock: DevSocket) throws {
        let decoders = RFBDecoders()
        while !isStopped {
            let type = try r.u8()
            switch type {
            case 0:
                try framebufferUpdate(r, decoders, sock)
            case 1:  // SetColourMapEntries: we asked for true colour; read past it.
                try r.skip(1)
                _ = try r.u16()
                let n = try r.u16()
                try r.skip(n * 6)
            case 2:
                post(.bell)
            case 3:
                try r.skip(3)
                let n = Int(try r.u32())
                if n > RFBClient.maxClipboardLength {
                    throw Failure(message: "the server sent \(n) bytes of clipboard text, more than this viewer accepts (\(RFBClient.maxClipboardLength / (1 << 20)) MB)")
                }
                let bytes = try r.bytes(n)
                // ServerCutText is Latin-1.
                post(.clipboard(String(bytes.map { Character(Unicode.Scalar($0)) })))
            case 150:  // EndOfContinuousUpdates — we never asked, but it is harmless.
                break
            case 248:  // ServerFence
                try r.skip(3)
                _ = try r.u32()
                let n = Int(try r.u8())
                try r.skip(n)
            default:
                throw Failure(message: "the server sent a message this viewer does not understand (type \(type))")
            }
        }
        throw Cancelled()
    }

    private func framebufferUpdate(_ r: RFBReader, _ d: RFBDecoders, _ sock: DevSocket) throws {
        try r.skip(1)
        let count = try r.u16()
        var resized = false
        var i = 0
        while count == 0xFFFF || i < count {
            i += 1
            let x = try r.u16(), y = try r.u16(), w = try r.u16(), h = try r.u16()
            let enc = try r.s32()
            let result: RFBRectResult
            do {
                result = try d.decode(r, x: x, y: y, w: w, h: h, encoding: enc, fb: framebuffer)
            } catch let e as RFBDecodeError {
                throw Failure(message: e.description)
            } catch let e as RFBInflater.InflateError {
                throw Failure(message: e.description)
            }
            switch result {
            case .pixels, .lastRect: break
            case .cursor(let c):
                post(.cursor(c))
            case .desktopSize(let w, let h):
                framebuffer.resize(width: w, height: h)
                resized = true
                post(.resized(width: w, height: h))
            case .extendedDesktopSize(let w, let h, let reason, let status, let screens):
                lock.lock(); self.screens = screens; lock.unlock()
                if status == 0 {
                    if w != framebuffer.width || h != framebuffer.height {
                        framebuffer.resize(width: w, height: h)
                        resized = true
                        post(.resized(width: w, height: h))
                    }
                } else if reason == 1 {
                    let why = ["", "the server does not allow it", "the server is out of resources", "the layout was invalid"]
                    post(.resizeRefused("The server did not resize the session: " + (status < why.count ? why[status] : "status \(status)")))
                }
            }
            if case .lastRect = result { break }
        }
        post(.damage)
        try sock.write(RFBMessages.updateRequest(incremental: !resized, x: 0, y: 0,
                                                 w: framebuffer.width, h: framebuffer.height))
    }

    // MARK: - Client messages

    /// Limits on lengths the server chooses, so a broken one cannot make the
    /// app allocate gigabytes.
    static let maxNameLength = 1 << 20
    static let maxClipboardLength = 16 << 20

    /// Client messages go out on one serial queue, in order, never on the
    /// main thread: a server that stops reading must not freeze the app.
    private let writeQueue = DispatchQueue(label: "vnc.write", qos: .userInitiated)
    private var backlog = 0

    /// Queue a message. `droppable` ones (pointer motion) are skipped while
    /// more than 1 MB is already waiting; keys and clicks never are.
    private func send(_ bytes: [UInt8], droppable: Bool = false) {
        lock.lock()
        let s = socket
        let c = connected && !stopped
        let busy = backlog > 1 << 20
        if c && !(droppable && busy) { backlog += bytes.count }
        lock.unlock()
        guard c, let s, !(droppable && busy) else { return }
        writeQueue.async { [weak self] in
            try? s.write(bytes)
            guard let self else { return }
            self.lock.lock(); self.backlog -= bytes.count; self.lock.unlock()
        }
    }

    /// Bytes queued and not yet written.
    var pendingBytes: Int { lock.lock(); defer { lock.unlock() }; return backlog }

    func sendKey(_ keysym: UInt32, down: Bool) { send(RFBMessages.key(keysym, down: down)) }

    private var lastMask: UInt8 = 0

    func sendPointer(x: Int, y: Int, mask: UInt8) {
        lock.lock(); let changed = mask != lastMask; lastMask = mask; lock.unlock()
        send(RFBMessages.pointer(x: x, y: y, mask: mask), droppable: !changed)
    }

    func sendClipboard(_ text: String) { send(RFBMessages.cutText(text)) }

    /// Ask the server to match a size (needs ExtendedDesktopSize support).
    func requestDesktopSize(width: Int, height: Int) {
        lock.lock(); let s = screens; lock.unlock()
        guard let first = s.first, width > 0, height > 0 else { return }
        send(RFBMessages.setDesktopSize(width: width, height: height, screenId: first.id, flags: first.flags))
    }
}

/// Client-to-server messages.
enum RFBMessages {
    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// 32bpp, depth 24, little-endian, true colour, 8 bits a channel, red at 16.
    static func setPixelFormat32() -> [UInt8] {
        [0, 0, 0, 0, 32, 24, 0, 1] + be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0]
    }

    static func setEncodings(_ encs: [Int32]) -> [UInt8] {
        var m: [UInt8] = [2, 0] + be16(encs.count)
        for e in encs { m += be32(UInt32(bitPattern: e)) }
        return m
    }

    static func updateRequest(incremental: Bool, x: Int, y: Int, w: Int, h: Int) -> [UInt8] {
        [3, incremental ? 1 : 0] + be16(x) + be16(y) + be16(w) + be16(h)
    }

    static func key(_ keysym: UInt32, down: Bool) -> [UInt8] {
        [4, down ? 1 : 0, 0, 0] + be32(keysym)
    }

    static func pointer(x: Int, y: Int, mask: UInt8) -> [UInt8] {
        [5, mask] + be16(max(0, min(65535, x))) + be16(max(0, min(65535, y)))
    }

    /// ClientCutText is Latin-1; anything outside it becomes "?".
    static func cutText(_ text: String) -> [UInt8] {
        let bytes: [UInt8] = text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
        return [6, 0, 0, 0] + be32(UInt32(bytes.count)) + bytes
    }

    static func setDesktopSize(width: Int, height: Int, screenId: UInt32, flags: UInt32) -> [UInt8] {
        [251, 0] + be16(width) + be16(height) + [1, 0] + be32(screenId) + be16(0) + be16(0)
            + be16(width) + be16(height) + be32(flags)
    }
}
