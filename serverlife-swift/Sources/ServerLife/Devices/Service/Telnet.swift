import Foundation

// Telnet, from devices.js. Pure, so the awkward cases can be tested without a
// server: the parser takes the carried state and a chunk, and returns the
// data to show, the bytes to send back, and the state to carry on with.

enum Telnet {
    static let IAC: UInt8 = 255
    static let DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
    static let SB: UInt8 = 250, SE: UInt8 = 240

    static let OPT_BINARY: UInt8 = 0, OPT_ECHO: UInt8 = 1, OPT_SGA: UInt8 = 3, OPT_TTYPE: UInt8 = 24, OPT_NAWS: UInt8 = 31

    /// What we are prepared to do ourselves, and what we are happy for them to do.
    static let weWill: Set<UInt8> = [OPT_TTYPE, OPT_NAWS, OPT_SGA, OPT_BINARY]
    static let theyMay: Set<UInt8> = [OPT_ECHO, OPT_SGA, OPT_BINARY]

    /// The parser's state between chunks: a command can be split across two
    /// packets, and a subnegotiation across several.
    struct State {
        enum Mode { case data, iac, opt, sbopt, sb, sbiac }
        var mode: Mode = .data
        var cmd: UInt8 = 0
        var opt: UInt8 = 0
        var sb: [UInt8] = []
        /// Options we have agreed to perform (NAWS is only re-sent once agreed).
        var agreed: Set<UInt8> = []
    }

    struct Result {
        var data: [UInt8]
        var replies: [UInt8]
        var state: State
        /// They asked for the window size: send it now (and on every resize).
        var sawNaws: Bool
    }

    /// Pull the telnet protocol out of a stream of bytes (`telnetParse`).
    ///
    /// Telnet interleaves its negotiation with the data rather than framing
    /// it, so every byte of output has to be walked: an unlucky 0xFF in the
    /// middle of a `tcpdump` is the same byte that introduces a command.
    static func parse(_ state: State?, _ chunk: [UInt8]) -> Result {
        var st = state ?? State()
        var out: [UInt8] = []
        out.reserveCapacity(chunk.count)
        var replies: [UInt8] = []
        var sawNaws = false

        for b in chunk {
            switch st.mode {
            case .data:
                if b == IAC { st.mode = .iac } else { out.append(b) }
            case .iac:
                if b == IAC { out.append(IAC); st.mode = .data }          // escaped 0xFF
                else if b == DO || b == DONT || b == WILL || b == WONT { st.cmd = b; st.mode = .opt }
                else if b == SB { st.mode = .sbopt }
                // Everything else is a two-byte command with nothing to answer:
                // NOP, Are You There, Interrupt Process and friends.
                else { st.mode = .data }
            case .opt:
                let opt = b
                if st.cmd == DO {
                    let yes = weWill.contains(opt)
                    replies += [IAC, yes ? WILL : WONT, opt]
                    if yes { st.agreed.insert(opt) }
                    // The window size is sent once the other end has asked for
                    // it, and then again on every resize.
                    if yes && opt == OPT_NAWS { sawNaws = true }
                } else if st.cmd == DONT {
                    replies += [IAC, WONT, opt]
                    st.agreed.remove(opt)
                } else if st.cmd == WILL {
                    replies += [IAC, theyMay.contains(opt) ? DO : DONT, opt]
                } else if st.cmd == WONT {
                    replies += [IAC, DONT, opt]
                }
                st.mode = .data
            case .sbopt:
                st.opt = b
                st.sb = []
                st.mode = .sb
            case .sb:
                if b == IAC { st.mode = .sbiac } else { st.sb.append(b) }
            case .sbiac:
                if b == IAC { st.sb.append(IAC); st.mode = .sb }
                else if b == SE {
                    // The only subnegotiation worth answering: "what terminal are you?"
                    if st.opt == OPT_TTYPE && st.sb.first == 1 {
                        replies += [IAC, SB, OPT_TTYPE, 0]
                        replies += Array("xterm-256color".utf8)
                        replies += [IAC, SE]
                    }
                    st.mode = .data
                } else {
                    st.mode = .data
                }
            }
        }
        return Result(data: out, replies: replies, state: st, sawNaws: sawNaws)
    }

    /// The window size, in the shape telnet wants it (`nawsFrame`).
    static func nawsFrame(cols: Int, rows: Int) -> [UInt8] {
        let c = max(1, min(65535, cols))
        let r = max(1, min(65535, rows))
        let body: [UInt8] = [UInt8(c >> 8), UInt8(c & 255), UInt8(r >> 8), UInt8(r & 255)]
        // A dimension that happens to be 0xFF has to be escaped like any other byte.
        var esc: [UInt8] = []
        for b in body { esc.append(b); if b == IAC { esc.append(IAC) } }
        return [IAC, SB, OPT_NAWS] + esc + [IAC, SE]
    }

    /// 0xFF in user input has to be doubled, or the far end reads it as the
    /// start of a command (`escapeIac`).
    static func escapeIAC(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        for b in bytes { out.append(b); if b == IAC { out.append(IAC) } }
        return out
    }

    /// What the telnet client everyone knows prints before anything else
    /// (`_telnetGreeting`). The resolved address is in there because it is
    /// frequently the question — `telnet host 443` is how people find out
    /// which way DNS is pointing today.
    static func greeting(remoteAddress: String?, host: String) -> String {
        var addr = host
        if let r = remoteAddress, !r.isEmpty {
            addr = r.hasPrefix("::ffff:") ? String(r.dropFirst("::ffff:".count)) : r
        }
        return "Trying \(addr)...\r\nConnected to \(host).\r\n" + "Escape character is '^]'.\r\n"
    }

    /// A failure in telnet's words rather than the system's (`telnetError`).
    static func errorText(code: String?, message: String?, host: String, port: Int? = nil) -> String {
        let code = code ?? ""
        let whereStr = port.map { "\(host):\($0)" } ?? host
        switch code {
        case "ECONNREFUSED": return "telnet: Unable to connect to remote host: Connection refused (\(whereStr))"
        case "ETIMEDOUT": return "telnet: Unable to connect to remote host: Operation timed out (\(whereStr))"
        case "EHOSTUNREACH": return "telnet: Unable to connect to remote host: No route to host (\(whereStr))"
        case "ENETUNREACH": return "telnet: Unable to connect to remote host: Network is unreachable (\(whereStr))"
        case "ENOTFOUND", "EAI_AGAIN": return "telnet: could not resolve \(host): Name or service not known"
        case "ECONNRESET": return "telnet: Connection reset by peer"
        default: return "telnet: \((message?.isEmpty == false) ? message! : "connection failed")"
        }
    }

    static func errorText(_ err: Error, host: String, port: Int? = nil) -> String {
        if let e = err as? DevSocketError { return errorText(code: e.code, message: e.message, host: host, port: port) }
        return errorText(code: nil, message: "\(err)", host: host, port: port)
    }
}

/// Translate Return on the way out (`translateNewline`).
///
/// Nothing in a terminal agrees about what Enter means. xterm sends CR; a
/// Cisco console wants CR, a Linux getty over serial usually wants LF, and
/// some appliances insist on CRLF and show you a staircase if they do not get
/// it. Telnet's own answer, in its NVT, is CR LF.
func translateNewline(_ data: [UInt8], _ mode: String?) -> [UInt8] {
    guard let mode, mode != "cr", mode == "lf" || mode == "crlf" else { return data }
    var out: [UInt8] = []
    out.reserveCapacity(data.count + 4)
    var i = 0
    while i < data.count {
        let b = data[i]
        if b == 13 {
            // \r\n? → one newline
            if i + 1 < data.count && data[i + 1] == 10 { i += 1 }
            if mode == "lf" { out.append(10) } else { out += [13, 10] }
        } else if b == 10 && mode == "crlf" {
            out += [13, 10]
        } else {
            out.append(b)
        }
        i += 1
    }
    return out
}

func translateNewline(_ text: String, _ mode: String?) -> String {
    String(decoding: translateNewline(Array(text.utf8), mode), as: UTF8.self)
}

/// Holds back an incomplete UTF-8 sequence at the end of a chunk until the
/// rest arrives — the `StringDecoder` the original kept per session, because a
/// multi-byte character split across two reads becomes two replacement
/// characters if each chunk is decoded alone.
struct UTF8Carry {
    private var carry: [UInt8] = []

    mutating func push(_ chunk: [UInt8]) -> [UInt8] {
        var bytes = carry + chunk
        carry = []
        // Look back at most 3 bytes for the start of an unfinished sequence.
        var i = bytes.count - 1
        var back = 0
        while i >= 0 && back < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }   // continuation byte
            if b & 0x80 == 0 { break }                            // ASCII: complete
            let need = b & 0xE0 == 0xC0 ? 2 : b & 0xF0 == 0xE0 ? 3 : b & 0xF8 == 0xF0 ? 4 : 1
            let have = bytes.count - i
            if have < need {
                carry = Array(bytes[i...])
                bytes.removeSubrange(i...)
            }
            break
        }
        return bytes
    }

    /// Whatever is left over (at the end of the stream).
    mutating func flush() -> [UInt8] { defer { carry = [] }; return carry }
}
