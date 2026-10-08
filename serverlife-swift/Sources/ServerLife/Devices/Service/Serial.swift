import Foundation
import IOKit
import CShim

/// One serial port this machine can see (`listPorts` in devices.js).
struct SerialPortInfo: Hashable, Codable {
    var path: String
    var manufacturer: String = ""
    var serialNumber: String = ""
    var vendorId: String = ""
    var productId: String = ""
    /// The name people actually recognise — "USB Serial", "KeySerial1" — is
    /// not in a single field: the vendor and the product, joined with " · ".
    var label: String = ""

    var json: JSON {
        ["path": .string(path), "manufacturer": .string(manufacturer), "serialNumber": .string(serialNumber),
         "vendorId": .string(vendorId), "productId": .string(productId), "label": .string(label)]
    }
}

/// The line settings for a serial console. Defaults are 115200 8N1 with no
/// flow control — what almost everything made this century uses; hardware
/// flow control on a cable with no CTS wire looks exactly like a dead port.
struct SerialOptions: Hashable {
    var path: String
    var baudRate: Int = 115200
    var dataBits: Int = 8
    var stopBits: Int = 1
    /// "none", "even", "odd" (the form's choices); "mark" and "space" are
    /// accepted too, as serialport did.
    var parity: String = "none"
    var rtscts: Bool = false
    var xon: Bool = false
    var xoff: Bool = false
    /// What Return sends: "cr" (default for serial), "lf", "crlf".
    var newline: String = "cr"
    var localEcho: Bool = false

    init(path: String) { self.path = path }

    /// From a saved profile or an open request, the way `_openSerial` read its
    /// options (`Number(x) || default`).
    init(json j: JSON) {
        path = j["path"].string ?? ""
        baudRate = j["baudRate"].int.flatMap { $0 > 0 ? $0 : nil } ?? 115200
        dataBits = j["dataBits"].int.flatMap { $0 > 0 ? $0 : nil } ?? 8
        stopBits = j["stopBits"].int.flatMap { $0 > 0 ? $0 : nil } ?? 1
        parity = j["parity"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        rtscts = j["rtscts"].truthy
        xon = j["xon"].truthy
        xoff = j["xoff"].truthy
        newline = j["newline"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "cr"
        localEcho = j["localEcho"].truthy
    }

    /// `/dev/cu.usbserial-1410 · 115200 8N1`
    var label: String {
        let p = (parity.isEmpty ? "none" : parity).prefix(1).uppercased()
        return "\(path) · \(baudRate) \(dataBits)\(p)\(stopBits)"
    }

    /// The termios flags these settings come to, applied over `cfmakeraw`.
    struct Flags: Equatable {
        var cflagSet: tcflag_t
        var cflagClear: tcflag_t
        var iflagSet: tcflag_t
        var iflagClear: tcflag_t
        /// The speed for cfsetspeed, or nil when it needs IOSSIOSPEED.
        var standardSpeed: speed_t?
    }

    static let standardSpeeds: [Int: speed_t] = [
        50: speed_t(B50), 75: speed_t(B75), 110: speed_t(B110), 134: speed_t(B134), 150: speed_t(B150),
        200: speed_t(B200), 300: speed_t(B300), 600: speed_t(B600), 1200: speed_t(B1200), 1800: speed_t(B1800),
        2400: speed_t(B2400), 4800: speed_t(B4800), 9600: speed_t(B9600), 19200: speed_t(B19200),
        38400: speed_t(B38400), 57600: speed_t(B57600), 115200: speed_t(B115200), 230400: speed_t(B230400),
    ]

    var flags: Flags {
        var cset: tcflag_t = tcflag_t(CREAD | CLOCAL)
        var cclear: tcflag_t = tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
        switch dataBits {
        case 5: cset |= tcflag_t(CS5)
        case 6: cset |= tcflag_t(CS6)
        case 7: cset |= tcflag_t(CS7)
        default: cset |= tcflag_t(CS8)
        }
        switch parity.lowercased() {
        case "even": cset |= tcflag_t(PARENB)
        case "odd": cset |= tcflag_t(PARENB | PARODD)
        // macOS has no CMSPAR; mark and space are sent as odd/even with the
        // parity bit fixed by the driver where it can.
        case "mark": cset |= tcflag_t(PARENB | PARODD)
        case "space": cset |= tcflag_t(PARENB)
        default: break
        }
        if stopBits >= 2 { cset |= tcflag_t(CSTOPB) }
        if rtscts { cset |= tcflag_t(CRTSCTS) }
        var iset: tcflag_t = 0
        var iclear: tcflag_t = tcflag_t(IXON | IXOFF | IXANY)
        if xon { iset |= tcflag_t(IXON) }
        if xoff { iset |= tcflag_t(IXOFF) }
        if parity.lowercased() != "none" { iset |= tcflag_t(INPCK) } else { iclear |= tcflag_t(INPCK) }
        cclear &= ~cset
        iclear &= ~iset
        return Flags(cflagSet: cset, cflagClear: cclear, iflagSet: iset, iflagClear: iclear,
                     standardSpeed: SerialOptions.standardSpeeds[baudRate])
    }
}

/// Modem control lines (`port.set({ dtr, rts, brk })`).
struct SerialSignals: Equatable {
    var dtr: Bool?
    var rts: Bool?
    var brk: Bool?
}

/// The input lines, as `port.get()` reported them.
struct SerialInputSignals: Equatable {
    var cts: Bool
    var dsr: Bool
    var dcd: Bool
    var ri: Bool
}

enum SerialPorts {
    /// The serial ports this machine can see: IOKit's IOSerialBSDClient
    /// services, by their callout device (/dev/cu.*), with the USB vendor and
    /// product read from the parent device.
    static func list() -> [SerialPortInfo] {
        var out: [SerialPortInfo] = []
        guard let matching = IOServiceMatching("IOSerialBSDClient") else { return fallbackList() }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return fallbackList() }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let path = prop(svc, "IOCalloutDevice", search: false) as? String else { continue }
            var info = SerialPortInfo(path: path)
            info.manufacturer = (prop(svc, "USB Vendor Name") as? String) ?? (prop(svc, "kUSBVendorString") as? String) ?? ""
            let product = (prop(svc, "USB Product Name") as? String) ?? (prop(svc, "kUSBProductString") as? String) ?? ""
            info.serialNumber = (prop(svc, "USB Serial Number") as? String) ?? (prop(svc, "kUSBSerialNumberString") as? String) ?? ""
            if let v = prop(svc, "idVendor") as? Int { info.vendorId = String(format: "%04x", v) }
            if let p = prop(svc, "idProduct") as? Int { info.productId = String(format: "%04x", p) }
            info.label = [info.manufacturer, product].filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(info)
        }
        return out
    }

    private static func prop(_ svc: io_object_t, _ key: String, search: Bool = true) -> Any? {
        if !search {
            return IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        return IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                               IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    /// When IOKit says nothing, the device nodes themselves.
    private static func fallbackList() -> [SerialPortInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") }.sorted().map { SerialPortInfo(path: "/dev/" + $0) }
    }

    /// The three things that actually go wrong when opening a port, said
    /// plainly (`serialHint`). "Permission denied, cannot open /dev/ttyUSB0" is
    /// true and useless; saying it is in use by screen is the next thing to do.
    static func hint(_ message: String, path: String) -> String {
        func has(_ pattern: String) -> Bool {
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.matches(message) ?? false
        }
        if has("access denied|permission denied|EACCES") { return "\(path): permission denied" }
        if has("busy|EBUSY|Resource temporarily unavailable") {
            return "\(path) is in use by something else — screen, minicom or another window"
        }
        if has("no such file|ENOENT|cannot open") { return "\(path) is not there — the adapter may have been unplugged" }
        return "\(path): \(message)"
    }
}

/// An open serial port: a non-blocking descriptor with the line configured
/// by termios, read on a dispatch source.
final class SerialPortHandle: @unchecked Sendable {
    let fd: Int32
    let options: SerialOptions
    private let queue = DispatchQueue(label: "serial.read")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    /// Held for a whole write and around closing the descriptor, so two
    /// writes never interleave and nothing is written to a closed (or
    /// reused) descriptor.
    private let ioLock = NSLock()
    private var closed = false
    private var saved = termios()

    /// Called on a background queue.
    var onData: ((Data) -> Void)?
    /// Called once: nil for a clean close, a message for an error on the port
    /// (a cable pulled out of a laptop).
    var onEnd: ((String?) -> Void)?

    /// Open and configure. Throws with the original's wording for the three
    /// common failures.
    init(_ o: SerialOptions) throws {
        options = o
        guard !o.path.isEmpty else { throw AppError("No serial port given") }
        let f = Darwin.open(o.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if f < 0 { throw AppError(SerialPorts.hint(Self.errText(errno), path: o.path)) }
        // serialport locked the port by default: a second opener is "busy".
        if ioctl(f, TIOCEXCL) != 0 || flock(f, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            Darwin.close(f)
            throw AppError(SerialPorts.hint(Self.errText(e == EWOULDBLOCK ? EBUSY : e), path: o.path))
        }
        var t = termios()
        if tcgetattr(f, &t) != 0 {
            let e = errno; Darwin.close(f)
            throw AppError(SerialPorts.hint(Self.errText(e), path: o.path))
        }
        saved = t
        cfmakeraw(&t)
        let fl = o.flags
        t.c_cflag = (t.c_cflag & ~fl.cflagClear) | fl.cflagSet
        t.c_iflag = (t.c_iflag & ~fl.iflagClear) | fl.iflagSet
        // VMIN 1 / VTIME 0: hand over whatever arrives.
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        if let s = fl.standardSpeed { cfsetspeed(&t, s) }
        if tcsetattr(f, TCSANOW, &t) != 0 {
            let e = errno; Darwin.close(f)
            throw AppError(SerialPorts.hint(Self.errText(e), path: o.path))
        }
        if fl.standardSpeed == nil {
            // Rates termios has no constant for (460800, 921600 …).
            var speed = speed_t(o.baudRate)
            let IOSSIOSPEED: UInt = 0x8008_5402
            if ioctl(f, IOSSIOSPEED, &speed) != 0 {
                let e = errno; Darwin.close(f)
                throw AppError("\(o.path): \(o.baudRate) baud is not supported by this adapter (\(Self.errText(e)))")
            }
        }
        // Raise DTR and RTS, as opening a port does everywhere else.
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(f, TIOCMBIS, &bits)
        tcflush(f, TCIOFLUSH)
        fd = f
    }

    static func errText(_ e: Int32) -> String {
        let names: [Int32: String] = [EACCES: "EACCES", EBUSY: "EBUSY", ENOENT: "ENOENT", EAGAIN: "EAGAIN"]
        let s = String(cString: strerror(e))
        return names[e].map { "\(s) (\($0))" } ?? s
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 16384)
            var got = Data()
            while true {
                let n = Darwin.read(self.fd, &buf, buf.count)
                if n > 0 { got.append(contentsOf: buf[0..<n]); continue }
                let e = errno
                if n < 0 && (e == EAGAIN || e == EINTR) { break }
                if !got.isEmpty { self.onData?(got); got = Data() }
                // EOF or an error: the device went away.
                self.finish(n == 0 ? nil : Self.errText(e))
                return
            }
            if !got.isEmpty { self.onData?(got) }
        }
        source = src
        src.resume()
    }

    private func finish(_ error: String?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        source?.cancel()
        ioLock.lock(); Darwin.close(fd); ioLock.unlock()
        onEnd?(error)
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

    func write(_ data: Data) {
        ioLock.lock(); defer { ioLock.unlock() }
        guard isOpen else { return }
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            var spins = 0
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n > 0 { left -= n; p = p.advanced(by: n); spins = 0 }
                else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    // Flow control is holding us back; wait for the line, briefly.
                    spins += 1
                    if spins > 2000 || !isOpen { break }
                    usleep(1000)
                } else { break }
            }
        }
    }

    /// A serial break — how you interrupt a boot loader, and nothing else.
    /// Held for `ms`, clamped to 50…2000 as the original did.
    func sendBreak(ms: Int = 250) async throws {
        guard isOpen else { throw AppError("Not a serial session") }
        if ioctl(fd, TIOCSBRK) != 0 { throw AppError("\(options.path): \(Self.errText(errno))") }
        try? await Task.sleep(nanoseconds: UInt64(max(50, min(2000, ms))) * 1_000_000)
        if isOpen, ioctl(fd, TIOCCBRK) != 0 { throw AppError("\(options.path): \(Self.errText(errno))") }
    }

    /// Raise or drop the modem control lines by hand.
    func setSignals(_ s: SerialSignals) throws {
        guard isOpen else { throw AppError("Not a serial session") }
        func set(_ bit: Int32, _ on: Bool) throws {
            var b = bit
            if ioctl(fd, on ? TIOCMBIS : TIOCMBIC, &b) != 0 { throw AppError("\(options.path): \(Self.errText(errno))") }
        }
        if let d = s.dtr { try set(TIOCM_DTR, d) }
        if let r = s.rts { try set(TIOCM_RTS, r) }
        if let b = s.brk {
            if ioctl(fd, b ? TIOCSBRK : TIOCCBRK) != 0 { throw AppError("\(options.path): \(Self.errText(errno))") }
        }
    }

    /// CTS, DSR, DCD and RI as the port reports them now.
    func getSignals() throws -> SerialInputSignals {
        guard isOpen else { throw AppError("Not a serial session") }
        var bits: Int32 = 0
        if ioctl(fd, TIOCMGET, &bits) != 0 { throw AppError("\(options.path): \(Self.errText(errno))") }
        return SerialInputSignals(cts: bits & TIOCM_CTS != 0, dsr: bits & TIOCM_DSR != 0,
                                  dcd: bits & TIOCM_CD != 0, ri: bits & TIOCM_RI != 0)
    }

    /// Close without reporting an error. Safe to call more than once.
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        source?.cancel()
        ioLock.lock()
        var t = saved
        _ = tcsetattr(fd, TCSANOW, &t)
        Darwin.close(fd)
        ioLock.unlock()
    }
}
