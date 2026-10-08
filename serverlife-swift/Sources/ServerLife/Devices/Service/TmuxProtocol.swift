import Foundation

// tmux control mode: the pure half of tmuxctl.js — output unescaping, the
// layout parser and the line protocol. Every edge in it is a silent
// corruption: an octal escape read wrongly puts a stray backslash in
// somebody's config file, and a layout misread puts output in the wrong pane.

enum Tmux {
    /// The DCS tmux sends on entering control mode (`-CC`). Everything before
    /// it is the login banner and the terminal handshake.
    static let DCS = "\u{1b}P1000p"
    static let dcsBytes: [UInt8] = Array(DCS.utf8)

    /// Undo tmux's escaping of forwarded output (`unescapeOutput`): every byte
    /// below 32 and the backslash itself arrive as three octal digits. One
    /// pass, left to right — decoding `\134` first and rescanning would turn
    /// `\134033` (a backslash and the text 033) into ESC.
    static func unescapeOutput(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        let end = bytes.endIndex
        func octal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }
        while i < end {
            let b = bytes[i]
            if b == 0x5c && end - i >= 4 && octal(bytes[i + 1]) && octal(bytes[i + 2]) && octal(bytes[i + 3]) {
                let v = Int(bytes[i + 1] - 0x30) * 64 + Int(bytes[i + 2] - 0x30) * 8 + Int(bytes[i + 3] - 0x30)
                out.append(UInt8(truncatingIfNeeded: v))
                i += 4
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    static func unescapeOutput(_ s: String) -> String {
        String(decoding: unescapeOutput(ArraySlice(Array(s.utf8))), as: UTF8.self)
    }

    /// Arbitrary bytes, in the one form `send-keys` cannot misread (`hexKeys`).
    static func hexKeys(_ data: [UInt8]) -> String {
        data.map { String(format: "0x%02x", $0) }.joined(separator: " ")
    }

    static func hexKeys(_ s: String) -> String { hexKeys(Array(s.utf8)) }

    /// What a terminal would answer to tmux's opening questions
    /// (`probeAnswers`): cursor position, background colour, device
    /// attributes. Deliberately boring answers.
    static func probeAnswers(_ text: String) -> [String] {
        var out: [String] = []
        if text.contains("\u{1b}[6n") { out.append("\u{1b}[1;1R") }
        if text.contains("\u{1b}]11;?") { out.append("\u{1b}]11;rgb:1212/1414/1a1a\u{1b}\\") }
        if text.contains("\u{1b}[c") || text.contains("\u{1b}[>c") { out.append("\u{1b}[?1;2c") }
        return out
    }
}

/// A tmux layout, as a tree (`parseLayout`). `[` is a column of panes
/// stacked top to bottom (`dir` "col"), `{` a row side by side ("row").
indirect enum TmuxLayout: Equatable {
    case pane(w: Int, h: Int, x: Int, y: Int, pane: String?)
    case split(w: Int, h: Int, x: Int, y: Int, dir: String, children: [TmuxLayout])

    var w: Int { switch self { case .pane(let w, _, _, _, _), .split(let w, _, _, _, _, _): return w } }
    var h: Int { switch self { case .pane(_, let h, _, _, _), .split(_, let h, _, _, _, _): return h } }
    var x: Int { switch self { case .pane(_, _, let x, _, _), .split(_, _, let x, _, _, _): return x } }
    var y: Int { switch self { case .pane(_, _, _, let y, _), .split(_, _, _, let y, _, _): return y } }
    /// "%3" for a leaf.
    var pane: String? { if case .pane(_, _, _, _, let p) = self { return p }; return nil }
    /// "col" or "row" for a split.
    var dir: String? { if case .split(_, _, _, _, let d, _) = self { return d }; return nil }
    var children: [TmuxLayout] { if case .split(_, _, _, _, _, let c) = self { return c }; return [] }

    /// Every pane, in the order tmux lists them (`panesInLayout`).
    var panes: [String] {
        switch self {
        case .pane(_, _, _, _, let p): return p.map { [$0] } ?? []
        case .split(_, _, _, _, _, let c): return c.flatMap { $0.panes }
        }
    }

    /// `{ w, h, x, y, pane }` / `{ w, h, x, y, dir, children }`, as the JS had it.
    var json: JSON {
        switch self {
        case .pane(let w, let h, let x, let y, let p):
            return ["w": JSON(w), "h": JSON(h), "x": JSON(x), "y": JSON(y), "pane": JSON(p)]
        case .split(let w, let h, let x, let y, let d, let c):
            return ["w": JSON(w), "h": JSON(h), "x": JSON(x), "y": JSON(y), "dir": .string(d), "children": .array(c.map { $0.json })]
        }
    }

    struct ParseError: Error, CustomStringConvertible { var description: String }

    /// Parse `bb62,279x82,0,0[279x41,0,0,1,279x40,0,42{…}]`. Throws "bad layout
    /// at N: …" for anything that makes no sense rather than half-reading it.
    static func parse(_ layout: String) throws -> TmuxLayout {
        let s = layout
        // Drop the leading checksum.
        let body: [UInt8] = s.contains(",") ? Array(s[s.index(after: s.firstIndex(of: ",")!)...].utf8) : Array(s.utf8)
        var i = 0
        func fail() -> ParseError { ParseError(description: "bad layout at \(i): \(s)") }
        func at() -> UInt8? { i < body.count ? body[i] : nil }
        func number() throws -> Int {
            let start = i
            while let c = at(), c >= 0x30 && c <= 0x39 { i += 1 }
            if i == start { throw fail() }
            return Int(String(decoding: body[start..<i], as: UTF8.self)) ?? 0
        }
        func node() throws -> TmuxLayout {
            let w = try number()
            guard at() == UInt8(ascii: "x") else { throw fail() }
            i += 1
            let h = try number()
            guard at() == UInt8(ascii: ",") else { throw fail() }
            i += 1
            let x = try number()
            guard at() == UInt8(ascii: ",") else { throw fail() }
            i += 1
            let y = try number()
            if at() == UInt8(ascii: ",") {
                i += 1
                let p = try number()
                return .pane(w: w, h: h, x: x, y: y, pane: "%\(p)")
            }
            if at() == UInt8(ascii: "[") || at() == UInt8(ascii: "{") {
                let close = at() == UInt8(ascii: "[") ? UInt8(ascii: "]") : UInt8(ascii: "}")
                let dir = at() == UInt8(ascii: "[") ? "col" : "row"
                i += 1
                var children: [TmuxLayout] = []
                while true {
                    children.append(try node())
                    if at() == UInt8(ascii: ",") { i += 1; continue }
                    if at() == close { i += 1; break }
                    throw fail()
                }
                return .split(w: w, h: h, x: x, y: y, dir: dir, children: children)
            }
            return .pane(w: w, h: h, x: x, y: y, pane: nil)
        }
        return try node()
    }

    /// `safeLayout`: nil instead of throwing.
    static func safe(_ layout: String) -> TmuxLayout? { try? parse(layout) }
}

/// One thing the control-mode stream said.
enum TmuxEvent: Equatable {
    /// Bytes to write back (a terminal probe), only ever before control mode.
    case probe(String)
    /// Text before the DCS: the login banner.
    case preamble(String)
    case ready
    /// A `%begin … %end/%error` block. `flags` is the guard line's third
    /// field: "0" for tmux's own opening block, "1" for replies to us.
    case result(num: String, flags: String, error: Bool, lines: [String])
    /// Pane output, unescaped. `age` is how far behind this client is (ms),
    /// from `%extended-output`.
    case output(pane: String, data: [UInt8], age: Int?)
    case layout(window: String, layout: String, tree: TmuxLayout?)
    case windowAdd(String)
    case windowClose(String)
    case windowRenamed(window: String, name: String)
    case activePane(window: String, pane: String)
    case activeWindow(session: String, window: String)
    case session(id: String, name: String)
    case sessionRenamed(String)
    case sessionsChanged
    case pause(String)
    case `continue`(String)
    case exit(String?)
    case subscription(name: String, value: String)
    /// A line outside any block that is not a notification.
    case noise(String)
    case other(kind: String, rest: String)
}

/// A parser that can be fed arbitrary chunks (`Parser` in tmuxctl.js).
///
/// Output arrives split at any byte, so nothing is interpreted until a line
/// is complete. The protocol does not begin at byte zero — a login banner and
/// tmux's own terminal probes come first, and the probes have to be answered
/// or tmux waits for ever. Once the DCS has gone past, this side's input is
/// the command channel, so nothing is answered as a probe any more.
final class TmuxParser {
    /// `tmux -C` with no terminal in between (a beam): no DCS, no probes,
    /// the protocol starts with the first line.
    let plain: Bool
    private(set) var inControl: Bool
    private var announced = false
    private var buf: [UInt8] = []
    private var pre: [UInt8] = []
    private var block: (num: String, lines: [String])?

    init(plain: Bool = false) {
        self.plain = plain
        self.inControl = plain
    }

    func feed(_ s: String) -> [TmuxEvent] { feed(Array(s.utf8)) }
    func feed(_ d: Data) -> [TmuxEvent] { feed(Array(d)) }

    func feed(_ chunk: [UInt8]) -> [TmuxEvent] {
        var events: [TmuxEvent] = []
        var bytes = chunk
        if !inControl {
            // The DCS can itself be split across reads: search the tail of what
            // came before plus this chunk.
            let carry = pre
            let joined = carry + bytes
            if let at = Self.find(Tmux.dcsBytes, in: joined) {
                let before = Array(joined[..<at])
                let newPre = Array(before.dropFirst(min(carry.count, before.count)))
                emitPreamble(newPre, into: &events)
                inControl = true
                pre = []
                events.append(.ready)
                bytes = Array(joined[(at + Tmux.dcsBytes.count)...])
            } else {
                // Keep a few bytes in case the DCS straddles this read and the next.
                let keep = min(joined.count, Tmux.dcsBytes.count - 1)
                let fresh = Array(joined.dropFirst(carry.count))
                emitPreamble(fresh, into: &events)
                pre = Array(joined.suffix(keep))
                return events
            }
        }
        buf += bytes
        var start = 0
        while let nl = buf[start...].firstIndex(of: 10) {
            var lineEnd = nl
            if lineEnd > start && buf[lineEnd - 1] == 13 { lineEnd -= 1 }
            line(buf[start..<lineEnd], &events)
            start = nl + 1
        }
        if start > 0 { buf.removeFirst(start) }
        return events
    }

    private func emitPreamble(_ fresh: [UInt8], into events: inout [TmuxEvent]) {
        let text = String(decoding: fresh, as: UTF8.self)
        for answer in Tmux.probeAnswers(text) { events.append(.probe(answer)) }
        if !fresh.isEmpty { events.append(.preamble(text)) }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = 0
        while i + needle.count <= hay.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    private func line(_ raw: ArraySlice<UInt8>, _ events: inout [TmuxEvent]) {
        let isPercent = raw.first == UInt8(ascii: "%")
        // Without a DCS to say so, control mode has begun when tmux first speaks.
        if plain && !announced && isPercent {
            announced = true
            events.append(.ready)
        }
        // A notification never appears inside a block, so a block only ever
        // ends at its own guard line.
        if var b = block {
            let line = String(decoding: raw, as: UTF8.self)
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: false)
                let flags = parts.count > 3 ? String(parts[3]).trimmed : ""
                events.append(.result(num: b.num, flags: flags, error: line.hasPrefix("%error"), lines: b.lines))
                block = nil
                return
            }
            b.lines.append(line)
            block = b
            return
        }
        // Output is the hot path: take it as bytes, never via String.
        if Self.hasPrefix(raw, "%output ") {
            let rest = raw.dropFirst(8)
            if let sp = rest.firstIndex(of: 32) {
                let pane = String(decoding: rest[..<sp], as: UTF8.self)
                events.append(.output(pane: pane, data: Tmux.unescapeOutput(rest[(sp + 1)...]), age: nil))
            } else {
                events.append(.output(pane: String(decoding: rest, as: UTF8.self), data: [], age: nil))
            }
            return
        }
        if Self.hasPrefix(raw, "%extended-output ") {
            // `%extended-output %0 <ms-behind> : <data>`
            var rest = raw.dropFirst(17)
            guard let sp1 = rest.firstIndex(of: 32) else { return }
            let pane = String(decoding: rest[..<sp1], as: UTF8.self)
            guard pane.count > 1, pane.first == "%", pane.dropFirst().allSatisfy(\.isNumber) else { return }
            rest = rest[(sp1 + 1)...]
            var j = rest.startIndex
            while j < rest.endIndex, rest[j] >= 0x30 && rest[j] <= 0x39 { j += 1 }
            guard j > rest.startIndex, j < rest.endIndex, rest[j] == 32 else { return }
            let age = Int(String(decoding: rest[rest.startIndex..<j], as: UTF8.self)) ?? 0
            var k = j + 1
            if k < rest.endIndex && rest[k] == UInt8(ascii: ":") { k += 1 }
            if k < rest.endIndex && rest[k] == 32 { k += 1 }
            events.append(.output(pane: pane, data: Tmux.unescapeOutput(rest[k...]), age: age))
            return
        }

        let line = String(decoding: raw, as: UTF8.self)
        if line.hasPrefix("%begin ") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            block = (num: parts.count > 2 ? String(parts[2]) : "", lines: [])
            return
        }
        if !isPercent {
            // Noise from the far side — a shell that printed something after tmux started.
            if !line.trimmed.isEmpty { events.append(.noise(line)) }
            return
        }
        let kind: String
        let rest: String
        if let sp = line.firstIndex(of: " ") {
            kind = String(line[line.index(after: line.startIndex)..<sp])
            rest = String(line[line.index(after: sp)...])
        } else {
            kind = String(line.dropFirst())
            rest = ""
        }
        func split(_ s: String) -> [String] { s.split(separator: " ", omittingEmptySubsequences: false).map(String.init) }
        func headTail(_ s: String) -> (String, String) {
            guard let i = s.firstIndex(of: " ") else { return (s, "") }
            return (String(s[..<i]), String(s[s.index(after: i)...]))
        }
        switch kind {
        case "layout-change":
            let p = split(rest)
            let win = p.first ?? ""
            let layout = p.count > 1 ? p[1] : ""
            events.append(.layout(window: win, layout: layout, tree: TmuxLayout.safe(layout)))
        case "window-add", "unlinked-window-add":
            events.append(.windowAdd(rest.trimmed))
        case "window-close", "unlinked-window-close":
            events.append(.windowClose(rest.trimmed))
        case "window-renamed", "unlinked-window-renamed":
            let (w, n) = headTail(rest)
            events.append(.windowRenamed(window: w, name: n))
        case "window-pane-changed":
            let p = split(rest)
            events.append(.activePane(window: p.first ?? "", pane: p.count > 1 ? p[1] : ""))
        case "session-window-changed":
            let p = split(rest)
            events.append(.activeWindow(session: p.first ?? "", window: p.count > 1 ? p[1] : ""))
        case "session-changed":
            let (id, n) = headTail(rest)
            events.append(.session(id: id, name: n))
        case "session-renamed":
            // `%session-renamed $0 newname` (current tmux); older ones sent the name alone.
            let r = rest.trimmed
            if r.hasPrefix("$"), let sp = r.firstIndex(of: " ") {
                events.append(.sessionRenamed(String(r[r.index(after: sp)...])))
            } else {
                events.append(.sessionRenamed(r))
            }
        case "sessions-changed":
            events.append(.sessionsChanged)
        case "pause":
            events.append(.pause(rest.trimmed))
        case "continue":
            events.append(.continue(rest.trimmed))
        case "exit":
            events.append(.exit(rest.trimmed.isEmpty ? nil : rest.trimmed))
        case "subscription-changed":
            let p = split(rest)
            events.append(.subscription(name: p.first ?? "", value: p.count > 5 ? p[5...].joined(separator: " ") : ""))
        default:
            events.append(.other(kind: kind, rest: rest))
        }
    }

    private static func hasPrefix(_ raw: ArraySlice<UInt8>, _ p: String) -> Bool {
        let pb = Array(p.utf8)
        guard raw.count >= pb.count else { return false }
        return raw.prefix(pb.count).elementsEqual(pb)
    }
}
