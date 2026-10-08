import Foundation

/// Options for a telnet session (`_openTelnet`).
struct TelnetOptions: Hashable {
    var host: String
    var port: Int = 23
    var cols: Int = 100
    var rows: Int = 30
    /// Telnet's own NVT says CR LF, so that is the default here.
    var newline: String = "crlf"
    var localEcho: Bool = false

    init(host: String, port: Int = 23) { self.host = host; self.port = port }

    init(json j: JSON) {
        host = j["host"].string ?? j["hostname"].string ?? ""
        port = j["port"].int.flatMap { $0 > 0 ? $0 : nil } ?? j["devicePort"].int.flatMap { $0 > 0 ? $0 : nil } ?? 23
        cols = j["cols"].int ?? 100
        rows = j["rows"].int ?? 30
        newline = j["newline"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "crlf"
        localEcho = j["localEcho"].truthy
    }
}

/// A serial console or a telnet session as a `TerminalBackend` (kind
/// "serial" / "telnet") — the port of `DeviceSessions` in devices.js.
///
/// Deliberately not a connection: there is no ControlMaster, no SFTP, no port
/// forwarding and no second channel. Open, write, resize, close, and two
/// callbacks.
///
/// Output that arrives before the pane sets `onData` is held and handed over
/// when it does (the original's `ready()`): a switch's banner and telnet's own
/// greeting live in exactly that gap. An end that arrives before `onExit` is
/// set is delivered when it is.
@MainActor
final class DeviceBackend: TerminalBackend {
    let kind: String
    /// `/dev/cu.usbserial · 115200 8N1` or `host:port`.
    let label: String
    /// Telnet has already printed its own three lines (Trying / Connected to /
    /// Escape character), so the pane should not add a banner of its own.
    let greeted: Bool
    /// What Return sends ("cr", "lf", "crlf").
    var newline: String
    /// Write what is typed back into the pane, for consoles that echo nothing.
    var localEcho: Bool

    var onData: ((Data) -> Void)? { didSet { flushPending() } }
    var onExit: ((Int32?, String?) -> Void)? { didSet { deliverExitIfEnded() } }

    private var pending = Data()
    private var ended: String??
    private var exitDelivered = false
    private var decoder = UTF8Carry()

    /// Every write to the line goes through this one serial queue, so
    /// keystrokes, negotiation replies and window sizes leave in the order
    /// they were made and never interleave — and never block the main thread.
    private let writeQueue = DispatchQueue(label: "device.write", qos: .userInitiated)
    // serial
    private var serial: SerialPortHandle?
    // telnet
    private var socket: DevSocket?
    private var telnet: Telnet.State?
    private var cols: Int
    private var rows: Int

    private init(kind: String, label: String, greeted: Bool, newline: String, localEcho: Bool, cols: Int, rows: Int) {
        self.kind = kind
        self.label = label
        self.greeted = greeted
        self.newline = newline
        self.localEcho = localEcho
        self.cols = cols
        self.rows = rows
    }

    deinit {
        // A pane that let go without closing must not leave the line open.
        socket?.close()
        serial?.close()
    }

    // MARK: - Opening

    /// Open a serial port. Throws with the wording people can act on ("is in
    /// use by something else — screen, minicom or another window").
    static func openSerial(_ o: SerialOptions) async throws -> DeviceBackend {
        if o.path.isEmpty { throw AppError("No serial port given") }
        let handle: SerialPortHandle = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try SerialPortHandle(o)) } catch { cont.resume(throwing: error) }
            }
        }
        let b = DeviceBackend(kind: "serial", label: o.label, greeted: false, newline: o.newline,
                              localEcho: o.localEcho, cols: 100, rows: 30)
        b.serial = handle
        handle.onData = { [weak b] d in
            DispatchQueue.main.async { MainActor.assumeIsolated { b?.received(Array(d)) } }
        }
        handle.onEnd = { [weak b] err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let b else { return }
                    if let err {
                        // A cable pulled out is an error on the port, not a
                        // clean close: say so in the pane and end the session.
                        b.say("\r\n\u{1b}[31m[serial: \(err)]\u{1b}[0m\r\n")
                        b.end(err)
                    } else {
                        b.end("port closed")
                    }
                }
            }
        }
        handle.start()
        return b
    }

    /// Open a telnet session. A failure to connect throws in telnet's own
    /// words (`telnet: Unable to connect to remote host: Connection refused
    /// (switch-1:23)`) and is not also written into the pane.
    static func openTelnet(_ o: TelnetOptions) async throws -> DeviceBackend {
        if o.host.isEmpty { throw AppError("No host given") }
        let port = o.port > 0 ? o.port : 23
        let sock: DevSocket
        do {
            sock = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try DevSocket.connect(host: o.host, port: port)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } catch {
            throw AppError(Telnet.errorText(error, host: o.host, port: port))
        }
        let b = DeviceBackend(kind: "telnet", label: "\(o.host):\(port)", greeted: true, newline: o.newline,
                              localEcho: o.localEcho, cols: o.cols, rows: o.rows)
        b.socket = sock
        b.say(Telnet.greeting(remoteAddress: sock.remoteAddress, host: o.host))
        let host = o.host
        let t = Thread { [weak b] in
            while true {
                do {
                    let d = try sock.read()
                    if d.isEmpty { break }
                    DispatchQueue.main.async { MainActor.assumeIsolated { b?.telnetReceived(Array(d)) } }
                } catch {
                    let text = Telnet.errorText(error, host: host)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { b?.say("\r\n\u{1b}[31m\(text)\u{1b}[0m\r\n") }
                    }
                    break
                }
            }
            sock.release()
            // What telnet says when the far end goes away, because that is what it is.
            DispatchQueue.main.async { MainActor.assumeIsolated { b?.end("connection closed by foreign host") } }
        }
        t.name = "telnet.read"
        t.start()
        return b
    }

    /// Open from a request shaped like the original's `device:open` options
    /// (`kind` "serial" or "telnet").
    static func open(_ j: JSON) async throws -> DeviceBackend {
        switch j["kind"].string {
        case "serial": return try await openSerial(SerialOptions(json: j))
        case "telnet": return try await openTelnet(TelnetOptions(json: j))
        default: throw AppError("unknown device kind: \(j["kind"].stringish ?? "undefined")")
        }
    }

    // MARK: - Incoming

    private func received(_ bytes: [UInt8]) {
        let text = decoder.push(bytes)
        if !text.isEmpty { say(Data(text)) }
    }

    private func telnetReceived(_ chunk: [UInt8]) {
        let r = Telnet.parse(telnet, chunk)
        telnet = r.state
        if !r.replies.isEmpty { send(r.replies) }
        // The size is only worth sending once they have agreed to hear it.
        if r.sawNaws { send(Telnet.nawsFrame(cols: cols, rows: rows)) }
        if !r.data.isEmpty { received(r.data) }
    }

    private func say(_ text: String) { say(Data(text.utf8)) }

    private func say(_ data: Data) {
        if let h = onData { h(data) } else { pending.append(data) }
    }

    private func flushPending() {
        guard !pending.isEmpty, let h = onData else { return }
        let d = pending; pending = Data()
        h(d)
    }

    private func end(_ why: String) {
        guard ended == nil else { return }
        let rest = decoder.flush()
        if !rest.isEmpty { say(Data(rest)) }
        ended = .some(why)
        serial = nil
        socket = nil
        deliverExitIfEnded()
    }

    private func deliverExitIfEnded() {
        guard let e = ended, !exitDelivered, let h = onExit else { return }
        // Anything said before the pane was bound still belongs to it.
        flushPending()
        exitDelivered = true
        h(0, e)
    }

    var isOpen: Bool { ended == nil }

    // MARK: - TerminalBackend

    func write(_ data: Data) {
        guard ended == nil else { return }
        let bytes = Array(data)
        /*
         * `^]` ends a telnet session, as it has always done. A hand that has
         * typed this since the nineties should not have to learn where the
         * menu is — and the greeting promises it works.
         */
        if kind == "telnet" && bytes.contains(0x1d) {
            say("\r\ntelnet> quit\r\nConnection closed.\r\n")
            socket?.close()
            end("closed from this end")
            return
        }
        let text = translateNewline(bytes, newline)
        // Local echo, for the consoles that do none (off unless asked for: a
        // far end that echoes too shows everything twice).
        if localEcho { say(Data(text)) }
        if serial != nil {
            send(text)
        } else if socket != nil {
            // 0xFF in user input has to be doubled.
            send(text.contains(Telnet.IAC) ? Telnet.escapeIAC(text) : text)
        }
    }

    /// Queue bytes for the line, in order.
    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let d = Data(bytes)
        if let serial {
            writeQueue.async { serial.write(d) }
        } else if let socket {
            writeQueue.async { try? socket.write(d) }
        }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        // A serial line has no idea how big your window is and no way to be
        // told; `stty rows/cols` on the far side is the user's to give.
        if kind == "telnet", socket != nil, telnet?.agreed.contains(Telnet.OPT_NAWS) == true {
            send(Telnet.nawsFrame(cols: cols, rows: rows))
        }
    }

    func close() {
        guard ended == nil else { return }
        if let serial { writeQueue.async { serial.close() } }
        socket?.close()
        end("closed from this end")
    }

    func cwd() async -> String? { nil }

    // MARK: - Serial only

    /// A long break on the line (`device:break`; the pane menu sends 300 ms).
    func sendBreak(ms: Int = 250) async throws {
        guard kind == "serial", let serial else { throw AppError("Not a serial session") }
        try await serial.sendBreak(ms: ms)
    }

    /// Raise or drop DTR/RTS (and break) by hand (`device:signals`).
    func setSignals(_ s: SerialSignals) throws {
        guard kind == "serial", let serial else { throw AppError("Not a serial session") }
        try serial.setSignals(s)
    }

    /// CTS/DSR/DCD/RI now.
    func getSignals() throws -> SerialInputSignals {
        guard kind == "serial", let serial else { throw AppError("Not a serial session") }
        return try serial.getSignals()
    }
}

/// Every device backend opened, so they can be closed on the way out
/// (`devices.closeAll()`).
@MainActor
final class DeviceSessions {
    static let shared = DeviceSessions()
    private var open: [ObjectIdentifier: WeakDevice] = [:]

    private struct WeakDevice { weak var backend: DeviceBackend? }

    /// The serial ports this machine can see (`device:ports`).
    func listPorts() async -> [SerialPortInfo] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: SerialPorts.list()) }
        }
    }

    /// `device:open`: serial or telnet, tracked for `closeAll`.
    func open(_ j: JSON) async throws -> DeviceBackend {
        let b = try await DeviceBackend.open(j)
        track(b)
        return b
    }

    func openSerial(_ o: SerialOptions) async throws -> DeviceBackend {
        let b = try await DeviceBackend.openSerial(o); track(b); return b
    }

    func openTelnet(_ o: TelnetOptions) async throws -> DeviceBackend {
        let b = try await DeviceBackend.openTelnet(o); track(b); return b
    }

    private func track(_ b: DeviceBackend) {
        open = open.filter { $0.value.backend != nil }
        open[ObjectIdentifier(b)] = WeakDevice(backend: b)
    }

    func closeAll() {
        for (_, w) in open { w.backend?.close() }
        open = [:]
    }
}
