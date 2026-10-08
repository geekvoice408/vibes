import Testing
import Foundation
@testable import ServerLife

// Port of tests/devices.test.mjs (telnet, Enter, telnet's voice, serial
// errors), plus the serial option mapping.

private let IAC: UInt8 = 255, DO: UInt8 = 253, DONT: UInt8 = 254, WILL: UInt8 = 251, WONT: UInt8 = 252
private let SB: UInt8 = 250, SE: UInt8 = 240
private let TTYPE: UInt8 = 24, NAWS: UInt8 = 31, ECHO: UInt8 = 1, SGA: UInt8 = 3

private func parse(_ chunks: [[UInt8]]) -> (data: [UInt8], replies: [UInt8], naws: Bool, state: Telnet.State?) {
    var st: Telnet.State?
    var data: [UInt8] = [], replies: [UInt8] = [], naws = false
    for c in chunks {
        let r = Telnet.parse(st, c)
        st = r.state
        data += r.data
        replies += r.replies
        naws = naws || r.sawNaws
    }
    return (data, replies, naws, st)
}

private func latin1(_ b: [UInt8]) -> String { String(b.map { Character(Unicode.Scalar($0)) }) }

@Suite struct TelnetTests {
    @Test func ordinaryOutputPassesThrough() {
        let r = parse([Array("Switch> show version\r\n".utf8)])
        #expect(latin1(r.data) == "Switch> show version\r\n")
        #expect(r.replies.isEmpty)
    }

    @Test func optionsWeHonourAreAcceptedRestRefused() {
        let r = parse([[IAC, DO, TTYPE, IAC, DO, NAWS, IAC, DO, 99]])
        #expect(r.replies == [IAC, WILL, TTYPE, IAC, WILL, NAWS, IAC, WONT, 99])
        #expect(r.naws, "the window size is offered once they ask for it")
        #expect(r.state?.agreed.contains(NAWS) == true)
    }

    @Test func serverOfferingToEchoIsTakenUp() {
        let r = parse([[IAC, WILL, ECHO, IAC, WILL, SGA, IAC, WILL, 77]])
        #expect(r.replies == [IAC, DO, ECHO, IAC, DO, SGA, IAC, DONT, 77])
    }

    @Test func binaryBothWays() {
        let r = parse([[IAC, DO, 0, IAC, WILL, 0]])
        #expect(r.replies == [IAC, WILL, 0, IAC, DO, 0])
    }

    @Test func dontAndWontAreAcknowledged() {
        let r = parse([[IAC, DO, NAWS, IAC, DONT, NAWS, IAC, WONT, ECHO]])
        #expect(r.replies == [IAC, WILL, NAWS, IAC, WONT, NAWS, IAC, DONT, ECHO])
        #expect(r.state?.agreed.contains(NAWS) == false)
    }

    @Test func terminalTypeIsAnswered() {
        let r = parse([[IAC, SB, TTYPE, 1, IAC, SE]])
        #expect(latin1(r.replies) == "\u{ff}\u{fa}\u{18}\u{00}xterm-256color\u{ff}\u{f0}")
    }

    @Test func commandSplitAcrossPackets() {
        let r = parse([[0x68, IAC], [DO], [TTYPE, 0x69]])
        #expect(latin1(r.data) == "hi", "no byte of the command leaks into the output")
        #expect(r.replies == [IAC, WILL, TTYPE])
    }

    @Test func subnegotiationSplitAcrossPackets() {
        let r = parse([[IAC, SB, TTYPE], [1], [IAC, SE]])
        #expect(latin1(r.replies).contains("xterm-256color"))
    }

    @Test func escapedFFIsOneByte() {
        let r = parse([[0x41, IAC, IAC, 0x42]])
        #expect(r.data == [0x41, 0xff, 0x42])
        #expect(r.replies.isEmpty)
    }

    @Test func twoByteCommandsAreDropped() {
        let r = parse([[IAC, 241, IAC, 246, 0x6f, 0x6b]])
        #expect(latin1(r.data) == "ok")
        #expect(r.replies.isEmpty)
    }

    @Test func nawsFrame() {
        #expect(Telnet.nawsFrame(cols: 132, rows: 43) == [IAC, SB, NAWS, 0, 132, 0, 43, IAC, SE])
        #expect(Telnet.nawsFrame(cols: 255, rows: 24) == [IAC, SB, NAWS, 0, IAC, IAC, 0, 24, IAC, SE])
        #expect(Telnet.nawsFrame(cols: 0, rows: 70000) == [IAC, SB, NAWS, 0, 1, IAC, IAC, IAC, IAC, IAC, SE])
    }

    @Test func userInputIsEscaped() {
        #expect(Telnet.escapeIAC([1, IAC, 2]) == [1, IAC, IAC, 2])
    }

    @Test func returnIsTranslated() {
        #expect(translateNewline("ls\r", "cr") == "ls\r")
        #expect(translateNewline("ls\r", "lf") == "ls\n")
        #expect(translateNewline("ls\r", "crlf") == "ls\r\n")
        #expect(translateNewline("ls\r\n", "crlf") == "ls\r\n")
        #expect(translateNewline("ls\r\n", "lf") == "ls\n")
        #expect(translateNewline("a\nb", "crlf") == "a\r\nb")
        #expect(translateNewline("ls\r", nil) == "ls\r")
    }

    @Test func greeting() {
        #expect(Telnet.greeting(remoteAddress: "3.238.220.225", host: "enterprise.example.com")
            == "Trying 3.238.220.225...\r\nConnected to enterprise.example.com.\r\nEscape character is '^]'.\r\n")
        #expect(Telnet.greeting(remoteAddress: "::ffff:10.0.0.5", host: "h").hasPrefix("Trying 10.0.0.5..."))
        #expect(Telnet.greeting(remoteAddress: nil, host: "host-only").hasPrefix("Trying host-only..."))
    }

    @Test func errorsInTelnetsWords() {
        #expect(Telnet.errorText(code: "ECONNREFUSED", message: nil, host: "switch-1", port: 23)
            == "telnet: Unable to connect to remote host: Connection refused (switch-1:23)")
        #expect(Telnet.errorText(code: "ENOTFOUND", message: nil, host: "no-such.invalid")
            == "telnet: could not resolve no-such.invalid: Name or service not known")
        #expect(Telnet.errorText(code: "ETIMEDOUT", message: nil, host: "h", port: 23).contains("Operation timed out"))
        #expect(Telnet.errorText(code: "EHOSTUNREACH", message: nil, host: "h", port: 23).contains("No route to host"))
        #expect(Telnet.errorText(code: "ECONNRESET", message: nil, host: "h").contains("reset by peer"))
        #expect(Telnet.errorText(code: nil, message: "something else", host: "h") == "telnet: something else")
    }

    @Test func utf8SplitAcrossReadsIsKept() {
        var c = UTF8Carry()
        let bytes = Array("é─x".utf8)  // 2-byte, 3-byte, ASCII
        var out: [UInt8] = []
        for b in bytes { out += c.push([b]) }
        #expect(out == bytes)
        var d = UTF8Carry()
        #expect(d.push([0x61, 0xe2, 0x94]) == [0x61])
        #expect(d.push([0x80]) == [0xe2, 0x94, 0x80])
    }

    /// A real socket: the greeting, negotiation answers and ^] quitting.
    /// The server's end is held open until the test is done, so the session
    /// can only end the way the test ends it.
    @MainActor @Test func telnetAgainstLocalServer() async throws {
        let server = try LoopbackServer()   // port 0: the system picks a free one
        let serverTask = Task.detached { () -> (LoopbackServer.Conn, [UInt8]) in
            let c = try server.accept()
            try c.send([IAC, DO, NAWS, IAC, WILL, ECHO] + Array("login: ".utf8))
            // Our replies (6 bytes) and the NAWS frame (9).
            let got = try c.recv(exactly: 15)
            return (c, got)
        }
        var o = TelnetOptions(host: "127.0.0.1", port: server.port)
        o.cols = 80; o.rows = 24
        let b = try await DeviceBackend.openTelnet(o)
        var text = Data()
        var ended: String?
        b.onData = { text.append($0) }
        b.onExit = { _, why in ended = why }
        let (conn, got) = try await serverTask.value
        #expect(Array(got.prefix(6)) == [IAC, WILL, NAWS, IAC, DO, ECHO])
        #expect(Array(got.dropFirst(6)) == Telnet.nawsFrame(cols: 80, rows: 24))
        let deadline = Date().addingTimeInterval(10)
        while !String(decoding: text, as: UTF8.self).contains("login: ") && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let s = String(decoding: text, as: UTF8.self)
        #expect(s.hasPrefix("Trying 127.0.0.1...\r\nConnected to 127.0.0.1.\r\n"))
        #expect(s.contains("login: "))
        #expect(ended == nil, "still open: the server has not hung up")
        b.write(Data([0x1d]))
        #expect(ended == "closed from this end")
        #expect(String(decoding: text, as: UTF8.self).contains("telnet> quit\r\nConnection closed.\r\n"))
        withExtendedLifetime(conn) {}
    }

    /// Many writes in quick succession reach the far end in order, unmixed.
    @MainActor @Test func telnetWritesStayInOrder() async throws {
        let server = try LoopbackServer()
        let chunks = (0..<400).map { String(format: "%04d,", $0) }
        let expected = Array(chunks.joined().utf8)
        let serverTask = Task.detached { () -> [UInt8] in
            let c = try server.accept()
            let got = try c.recv(exactly: expected.count)
            return got
        }
        var o = TelnetOptions(host: "127.0.0.1", port: server.port)
        o.newline = "cr"
        let b = try await DeviceBackend.openTelnet(o)
        for ch in chunks { b.write(Data(ch.utf8)) }
        let got = try await serverTask.value
        #expect(got == expected)
        b.close()
    }

    @MainActor @Test func telnetRefusedSaysSo() async {
        // A port nothing listens on: bind one, close it, connect.
        let port = (try? LoopbackServer().port) ?? 1
        do {
            _ = try await DeviceBackend.openTelnet(TelnetOptions(host: "127.0.0.1", port: port))
            Issue.record("expected a refusal")
        } catch {
            #expect("\(error)" == "telnet: Unable to connect to remote host: Connection refused (127.0.0.1:\(port))")
        }
    }
}

@Suite struct SerialTests {
    @Test func threeWaysAPortRefuses() {
        let perm = SerialPorts.hint("Permission denied, cannot open /dev/ttyUSB0", path: "/dev/ttyUSB0")
        #expect(perm.lowercased().contains("permission denied"))
        #expect(SerialPorts.hint("Resource temporarily unavailable", path: "/dev/x").contains("in use by something else — screen, minicom or another window"))
        #expect(SerialPorts.hint("Resource busy (EBUSY)", path: "/dev/x") == "/dev/x is in use by something else — screen, minicom or another window")
        #expect(SerialPorts.hint("No such file or directory", path: "/dev/x") == "/dev/x is not there — the adapter may have been unplugged")
        #expect(SerialPorts.hint("weird", path: "/dev/x") == "/dev/x: weird")
    }

    @Test func defaultsAre115200_8N1() {
        let o = SerialOptions(json: ["path": "/dev/cu.usbserial"])
        #expect(o.baudRate == 115200 && o.dataBits == 8 && o.stopBits == 1 && o.parity == "none")
        #expect(!o.rtscts && !o.xon && !o.xoff)
        #expect(o.newline == "cr" && !o.localEcho)
        #expect(o.label == "/dev/cu.usbserial · 115200 8N1")
        let f = o.flags
        #expect(f.cflagSet & tcflag_t(CSIZE) == tcflag_t(CS8))
        #expect(f.cflagSet & tcflag_t(PARENB) == 0)
        #expect(f.cflagClear & tcflag_t(PARENB) != 0)
        #expect(f.cflagSet & tcflag_t(CSTOPB) == 0)
        #expect(f.cflagSet & tcflag_t(CRTSCTS) == 0, "no hardware flow control unless asked")
        #expect(f.cflagSet & tcflag_t(CLOCAL | CREAD) == tcflag_t(CLOCAL | CREAD))
        #expect(f.iflagSet == 0)
        #expect(f.standardSpeed == speed_t(B115200))
    }

    @Test func optionsMapToTermios() {
        var o = SerialOptions(path: "/dev/x")
        o.baudRate = 9600; o.dataBits = 7; o.parity = "even"; o.stopBits = 2; o.rtscts = true
        var f = o.flags
        #expect(f.cflagSet & tcflag_t(CSIZE) == tcflag_t(CS7))
        #expect(f.cflagSet & tcflag_t(PARENB) != 0 && f.cflagSet & tcflag_t(PARODD) == 0)
        #expect(f.cflagSet & tcflag_t(CSTOPB) != 0)
        #expect(f.cflagSet & tcflag_t(CRTSCTS) != 0)
        #expect(f.iflagSet & tcflag_t(INPCK) != 0)
        #expect(f.standardSpeed == speed_t(B9600))
        #expect(o.label == "/dev/x · 9600 7E2")

        o = SerialOptions(path: "/dev/x")
        o.parity = "odd"; o.dataBits = 5; o.xon = true; o.xoff = true; o.baudRate = 921600
        f = o.flags
        #expect(f.cflagSet & tcflag_t(PARENB | PARODD) == tcflag_t(PARENB | PARODD))
        #expect(f.cflagSet & tcflag_t(CSIZE) == tcflag_t(CS5))
        #expect(f.iflagSet & tcflag_t(IXON | IXOFF) == tcflag_t(IXON | IXOFF))
        #expect(f.standardSpeed == nil, "921600 needs IOSSIOSPEED")
        #expect(o.label == "/dev/x · 921600 5O1")
    }

    @Test func profileFieldsAreRead() {
        let o = SerialOptions(json: ["path": "/dev/cu.a", "baudRate": 57600, "dataBits": 7, "parity": "odd",
                                     "stopBits": 2, "rtscts": false, "xon": true, "xoff": true, "newline": "lf",
                                     "localEcho": true])
        #expect(o.baudRate == 57600 && o.dataBits == 7 && o.parity == "odd" && o.stopBits == 2)
        #expect(o.xon && o.xoff && !o.rtscts && o.newline == "lf" && o.localEcho)
        let t = TelnetOptions(json: ["host": "switch-1"])
        #expect(t.port == 23 && t.newline == "crlf" && t.cols == 100 && t.rows == 30)
    }

    @MainActor @Test func missingPortSaysSo() async {
        do { _ = try await DeviceBackend.openSerial(SerialOptions(path: "/dev/cu.serverlife-no-such-port")); Issue.record("opened?") }
        catch { #expect("\(error)" == "/dev/cu.serverlife-no-such-port is not there — the adapter may have been unplugged") }
        do { _ = try await DeviceBackend.openSerial(SerialOptions(path: "")); Issue.record("opened?") }
        catch { #expect("\(error)" == "No serial port given") }
    }

    /// A pseudo-terminal stands in for the cable: the port opens with its
    /// termios, output arrives, and fast writes go out whole and in order.
    @MainActor @Test func serialOverAPtyKeepsWritesInOrder() async throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let slave = String(cString: ptsname(master))
        var o = SerialOptions(path: slave)
        o.newline = "lf"
        let b = try await DeviceBackend.openSerial(o)
        #expect(b.label == "\(slave) · 115200 8N1")
        var text = Data()
        b.onData = { text.append($0) }
        _ = "hello é\r\n".withCString { Darwin.write(master, $0, strlen($0)) }
        for _ in 0..<250 where !String(decoding: text, as: UTF8.self).contains("hello é") {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(String(decoding: text, as: UTF8.self).contains("hello é"))

        let chunks = (0..<400).map { String(format: "%04d\r", $0) }
        let expected = Array(chunks.map { $0.replacingOccurrences(of: "\r", with: "\n") }.joined().utf8)
        let reader = Task.detached { () -> [UInt8] in
            var got: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 4096)
            let deadline = Date().addingTimeInterval(15)
            while got.count < expected.count && Date() < deadline {
                var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 200) <= 0 { continue }
                let n = read(master, &buf, buf.count)
                if n > 0 { got += buf[0..<n] } else if n < 0 && errno != EAGAIN && errno != EINTR { break }
            }
            return got
        }
        for ch in chunks { b.write(Data(ch.utf8)) }
        let got = await reader.value
        #expect(got == expected, "every chunk, Enter sent as LF, in the order typed")
        var ended: String?
        b.onExit = { _, why in ended = why }
        b.close()
        #expect(ended == "closed from this end")
    }

    @Test func listingDoesNotCrash() {
        let ports = SerialPorts.list()
        for p in ports { #expect(p.path.hasPrefix("/dev/")) }
    }
}

/// A one-connection TCP server on 127.0.0.1 for tests.
final class LoopbackServer: @unchecked Sendable {
    let fd: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 1) == 0 else { close(fd); throw AppError("bind failed") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = Int(UInt16(bigEndian: addr.sin_port))
    }

    deinit { close(fd) }

    final class Conn: @unchecked Sendable {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { close(fd) }
        func send(_ b: [UInt8]) throws {
            var off = 0
            while off < b.count {
                let n = b[off...].withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { throw AppError("send failed") }
                off += n
            }
        }
        func recv(_ max: Int = 65536) throws -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: max)
            let n = Darwin.recv(fd, &buf, max, 0)
            if n <= 0 { throw AppError("closed") }
            return Array(buf[0..<n])
        }
        /// Exactly n bytes.
        func recv(exactly n: Int) throws -> [UInt8] {
            var out: [UInt8] = []
            while out.count < n { out += try recv(n - out.count) }
            return out
        }
    }

    /// Waits up to `timeout` seconds for the client, then gives up rather
    /// than hanging the suite.
    func accept(timeout: TimeInterval = 15) throws -> Conn {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { throw AppError("no client connected") }
        let c = Darwin.accept(fd, nil, nil)
        if c < 0 { throw AppError("accept failed") }
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return Conn(c)
    }
}
