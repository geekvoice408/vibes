import Foundation

// A YAML emitter and reader for the multi-exec files (multiexecfile.js) and
// nothing grander. The original used js-yaml 5: `dump` with the DUMP schema
// (YAML 1.1 + core, so "yes", "on", "123" and "~" come out quoted), two-space
// indent, `noRefs`, `lineWidth` 100 or 120, and the default single-quote
// preference; `load` with the core schema. The emitter below is a port of
// js-yaml 5's presenter for the shapes those files have (block mappings,
// block sequences, scalars) — scalar styling rules, block headers, folding
// and escaping included — so a file written here is byte-for-byte the file
// the Electron app wrote. The reader is a block-YAML subset: mappings,
// sequences, plain / quoted / block scalars, flow collections, comments.
//
// Fleet-owned (the data owner was to port js-yaml's subset; it stopped, so
// this lives here — see Fleet/README.md).

/// An ordered YAML value. Mappings keep their key order, which is what makes
/// a dumped file read in the order it was written.
indirect enum YAMLValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case seq([YAMLValue])
    case map([(String, YAMLValue)])

    static func == (a: YAMLValue, b: YAMLValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y || (x.isNaN && y.isNaN)
        case let (.string(x), .string(y)): return x == y
        case let (.seq(x), .seq(y)): return x == y
        case let (.map(x), .map(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    subscript(key: String) -> YAMLValue {
        if case .map(let m) = self { return m.last { $0.0 == key }?.1 ?? .null }
        return .null
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    var isMap: Bool { if case .map = self { return true }; return false }
    var items: [YAMLValue]? { if case .seq(let a) = self { return a }; return nil }

    /// JavaScript truthiness of the loaded value (`!!x`).
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .seq, .map: return true
        }
    }

    /// `String(x)` in JavaScript.
    var jsString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return YAMLValue.jsNumber(d)
        case .string(let s): return s
        case .seq(let a): return a.map { $0.isNull ? "" : $0.jsString }.joined(separator: ",")
        case .map: return "[object Object]"
        }
    }

    /// `Number(x)` in JavaScript (NaN when it is not a number).
    var jsNumber: Double {
        switch self {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }
            if t.hasPrefix("0x") || t.hasPrefix("0X") { return Double(Int(t.dropFirst(2), radix: 16) ?? 0) }
            return Double(t) ?? .nan
        case .seq(let a): return a.isEmpty ? 0 : (a.count == 1 ? a[0].jsNumber : .nan)
        case .map: return .nan
        }
    }

    static func jsNumber(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e21 { return String(Int64(d)) }
        return String(d)
    }

    /// The same value as JSON (key order is lost).
    var json: JSON {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .seq(let a): return .array(a.map(\.json))
        case .map(let m):
            var o: [String: JSON] = [:]
            for (k, v) in m { o[k] = v.json }
            return .object(o)
        }
    }
}

// MARK: - Emitter (js-yaml 5 presenter)

enum YAMLEmitter {
    struct Options {
        var indent = 2
        var lineWidth = 80
        /// js-yaml 5's `quoteStyle`; the original passed v4's `quotingType`,
        /// which v5 ignores, so its files use the default single quotes.
        var preferDouble = false
    }

    private enum Style { case plain, single, double, literal, folded }

    private final class State {
        let o: Options
        var openEnded = false
        init(_ o: Options) { self.o = o }
    }

    /// `yaml.dump(value, options)`.
    static func dump(_ value: YAMLValue, _ options: Options = Options()) -> String {
        let st = State(options)
        st.openEnded = false
        let body = writeNode(st, 0, value, block: true, compact: true, isKey: false)
        var out = body + "\n"
        if st.openEnded { out += "...\n" }
        return out
    }

    private static func nextLine(_ st: State, _ level: Int) -> String {
        "\n" + String(repeating: " ", count: st.o.indent * level)
    }

    private static func writeNode(_ st: State, _ level: Int, _ node: YAMLValue, block: Bool, compact: Bool,
                                  isKey: Bool) -> String {
        switch node {
        case .map(let items):
            if block && !items.isEmpty { return writeBlockMapping(st, level, items, compact: compact) }
            st.openEnded = false
            return writeFlowMapping(st, level, items)
        case .seq(let items):
            if block && !items.isEmpty { return writeBlockSequence(st, level, items, compact: compact) }
            st.openEnded = false
            return writeFlowSequence(st, level, items)
        case .null:
            return writeScalar(st, level, "null", isString: false, isKey: isKey, flowOnly: !block)
        case .bool(let b):
            return writeScalar(st, level, b ? "true" : "false", isString: false, isKey: isKey, flowOnly: !block)
        case .int(let i):
            return writeScalar(st, level, String(i), isString: false, isKey: isKey, flowOnly: !block)
        case .double(let d):
            return writeScalar(st, level, representFloat(d), isString: false, isKey: isKey, flowOnly: !block)
        case .string(let s):
            return writeScalar(st, level, s, isString: true, isKey: isKey, flowOnly: !block)
        }
    }

    private static func representFloat(_ d: Double) -> String {
        if d.isNaN { return ".nan" }
        if d == .infinity { return ".inf" }
        if d == -.infinity { return "-.inf" }
        if d == 0 && d.sign == .minus { return "-0.0" }
        let r = YAMLValue.jsNumber(d)
        if let re = try? NSRegularExpression(pattern: "^[-+]?[0-9]+e"), re.matches(r) {
            return r.replacingOccurrences(of: "e", with: ".e")
        }
        return r
    }

    private static func writeFlowSequence(_ st: State, _ level: Int, _ items: [YAMLValue]) -> String {
        "[" + items.map { writeNode(st, level, $0, block: false, compact: false, isKey: false) }.joined(separator: ", ") + "]"
    }

    private static func writeFlowMapping(_ st: State, _ level: Int, _ items: [(String, YAMLValue)]) -> String {
        var result = ""
        for (k, v) in items {
            if !result.isEmpty { result += ", " }
            let kt = writeNode(st, level, .string(k), block: false, compact: false, isKey: true)
            let vt = writeNode(st, level, v, block: false, compact: false, isKey: false)
            result += kt + ":" + (vt.isEmpty ? "" : " ") + vt
        }
        return "{" + result + "}"
    }

    private static func writeBlockSequence(_ st: State, _ level: Int, _ items: [YAMLValue], compact: Bool) -> String {
        var result = ""
        for v in items {
            let item = writeNode(st, level + 1, v, block: true, compact: true, isKey: false)
            if !compact || !result.isEmpty { result += nextLine(st, level) }
            result += (item.isEmpty || item.hasPrefix("\n")) ? "-" : "- "
            result += item
        }
        return result
    }

    private static func writeBlockMapping(_ st: State, _ level: Int, _ items: [(String, YAMLValue)], compact: Bool) -> String {
        var result = ""
        for (k, v) in items {
            var pair = ""
            if !compact || !result.isEmpty { pair += nextLine(st, level) }
            let keyText = writeNode(st, level + 1, .string(k), block: true, compact: true, isKey: true)
            let explicitPair = k.contains("\n") || keyText.utf16.count > 1024
            if explicitPair { pair += keyText.hasPrefix("\n") ? "?" : "? " }
            pair += keyText
            if explicitPair { pair += nextLine(st, level) }
            let valueText = writeNode(st, level + 1, v, block: true, compact: explicitPair, isKey: false)
            pair += (valueText.isEmpty || valueText.hasPrefix("\n")) ? ":" : ": "
            pair += valueText
            result += pair
        }
        return result
    }

    // MARK: Scalars

    private static func writeScalar(_ st: State, _ level: Int, _ value: String, isString: Bool, isKey: Bool,
                                    flowOnly: Bool) -> String {
        let ind = st.o.indent
        let shiftOfParent = level == 0 ? -1 : ind * (level - 1)
        let shiftOfContent = ind * max(1, level)
        let shiftOfFirstLine = level == 0 ? 0 : ind * level

        // Which styles the value could be written in at all.
        let canPlain = canUsePlain(value, isString: isString, isKey: isKey, flowOnly: flowOnly,
                                   shiftOfFirstLine: shiftOfFirstLine)
        let canSingle = canUseSingle(value, isKey: isKey)
        let canBlock = canUseBlock(value, flowOnly: flowOnly, shiftOfParent: shiftOfParent, shiftOfContent: shiftOfContent)
        func allowed(_ s: Style) -> Bool {
            switch s {
            case .double: return true
            case .plain: return canPlain
            case .single: return canSingle
            case .literal, .folded: return canBlock
            }
        }

        var style = Style.plain
        // doubleQuoteForInvisibles
        if style == .plain && value.unicodeScalars.contains(where: isInvisible) { style = .double }
        // doubleQuoteWhitespaceOnly
        if style == .plain && !value.isEmpty && value.unicodeScalars.allSatisfy(isJSWhitespace) { style = .double }
        // tryLongOrMultilineAsBlock
        if style == .plain && !isKey {
            let multiline = value.contains("\n")
            if !canBlock {
                if multiline { style = .double }
            } else {
                let w = st.o.lineWidth
                let available = max(min(w, 40), w - shiftOfContent)
                var shouldFold = false
                for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
                    let u = Array(line.utf16)
                    if u.count > available && u.first != 0x20 && hasFoldPoint(u) { shouldFold = true }
                }
                if shouldFold { style = .folded } else if multiline { style = .literal }
            }
        }
        // quoteInvalidPlain
        if style == .plain && !canPlain { style = (!st.o.preferDouble && canSingle) ? .single : .double }
        // fallbackToDoubleQuoted
        if !allowed(style) { style = .double }

        let body: String
        switch style {
        case .plain: body = encodeFlowBreaks(value, shiftOfContent)
        case .single: body = "'" + encodeFlowBreaks(value, shiftOfContent).replacingOccurrences(of: "'", with: "''") + "'"
        case .literal:
            body = "|" + blockHeader(value, shiftOfParent, shiftOfContent) + dropEndingNewline(indentString(value, shiftOfContent))
        case .folded:
            let w = st.o.lineWidth
            let available = max(min(w, 40), w - shiftOfContent)
            body = ">" + blockHeader(value, shiftOfParent, shiftOfContent)
                + dropEndingNewline(indentString(foldBlockScalar(value, available), shiftOfContent))
        case .double: body = "\"" + escapeString(value) + "\""
        }
        st.openEnded = (style == .literal || style == .folded) && (value == "\n" || value.hasSuffix("\n\n"))
        return body
    }

    /// ` [^ \t]` somewhere in the line: a place it could be folded.
    private static func hasFoldPoint(_ u: [UInt16]) -> Bool {
        guard u.count >= 2 else { return false }
        for i in 0..<(u.count - 1) where u[i] == 0x20 && u[i + 1] != 0x20 && u[i + 1] != 0x09 { return true }
        return false
    }

    private static func isInvisible(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return v == 0x09 || (v >= 0x7F && v <= 0xA0) || v == 0x2028 || v == 0x2029 || v == 0xFEFF || v == 0xFFFE || v == 0xFFFF
    }

    /// JavaScript's `\s`.
    static func isJSWhitespace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        case 0x2000...0x200A: return true
        default: return false
        }
    }

    // c-printable minus b-char and BOM.
    private static func isNbChar(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if v == 0x0A || v == 0x0D || v == 0xFEFF { return false }
        return v == 0x09 || (v >= 0x20 && v <= 0x7E) || v == 0x85 || (v >= 0xA0 && v <= 0xD7FF)
            || (v >= 0xE000 && v <= 0xFFFD) || (v >= 0x10000 && v <= 0x10FFFF)
    }

    private static func isNbJson(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return v == 0x09 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0x10FFFF)
    }

    // The ns-plain productions, as js-yaml 5 builds them (ICU syntax).
    private static let rx: (flowOut: NSRegularExpression, flowIn: NSRegularExpression, blockKey: NSRegularExpression,
                            flowKey: NSRegularExpression, forbiddenFirst: NSRegularExpression,
                            forbiddenContent: NSRegularExpression) = {
        let printable = "[\\x{09}\\x{0A}\\x{0D}\\x{20}-\\x{7E}\\x{85}\\x{A0}-\\x{D7FF}\\x{E000}-\\x{FFFD}\\x{10000}-\\x{10FFFF}]"
        let bChar = "[\\n\\r]"
        let bom = "\\x{FEFF}"
        let sWhite = "[ \\t]"
        let nbChar = "(?:(?!(?:\(bChar)|\(bom)))\(printable))"
        let nsChar = "(?:(?!\(sWhite))\(nbChar))"
        let indicator = "[-?:,\\[\\]{}#&*!|>'\"%@`]"
        let flowIndicator = "[,\\[\\]{}]"
        let safeOut = nsChar
        let safeIn = "(?:(?!\(flowIndicator))\(nsChar))"
        let firstOut = "(?:(?:(?!\(indicator))\(nsChar))|[?:-](?=\(safeOut)))"
        let firstIn = "(?:(?:(?!\(indicator))\(nsChar))|[?:-](?=\(safeIn)))"
        let charOut = "(?:(?:(?![:#])\(safeOut))|:(?=\(safeOut)))#*"
        let charIn = "(?:(?:(?![:#])\(safeIn))|:(?=\(safeIn)))#*"
        let inLineOut = "(?:\(sWhite)*\(charOut))*"
        let inLineIn = "(?:\(sWhite)*\(charIn))*"
        let oneLineOut = "\(firstOut)#*\(inLineOut)"
        let oneLineIn = "\(firstIn)#*\(inLineIn)"
        let nextLineOut = "\\n+\(charOut)\(inLineOut)"
        let nextLineIn = "\\n+\(charIn)\(inLineIn)"
        let multiOut = "\(oneLineOut)(?:\(nextLineOut))*"
        let multiIn = "\(oneLineIn)(?:\(nextLineIn))*"
        func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
            (try? NSRegularExpression(pattern: p, options: o)) ?? NSRegularExpression()
        }
        return (re("^(?:\(multiOut))\\z"), re("^(?:\(multiIn))\\z"), re("^(?:\(oneLineOut))\\z"),
                re("^(?:\(oneLineIn))\\z"), re("^(?:---|\\.\\.\\.)(?=\\z|[ \\t\\n\\r])"),
                re("^(?:---|\\.\\.\\.)(?=$|[ \\t\\n\\r])", [.anchorsMatchLines]))
    }()

    private static func canUsePlain(_ str: String, isString: Bool, isKey: Bool, flowOnly: Bool, shiftOfFirstLine: Int) -> Bool {
        if !str.isEmpty {
            // A multi-line value in block context is written as a block (or
            // double-quoted) whatever this says, so skip the expensive test.
            if str.contains("\n") && !isKey && !flowOnly { return false }
            let r = isKey ? (flowOnly ? rx.flowKey : rx.blockKey) : (flowOnly ? rx.flowIn : rx.flowOut)
            if !r.matches(str) { return false }
            if shiftOfFirstLine == 0 && rx.forbiddenFirst.matches(str) { return false }
        }
        guard isString else { return true }
        if YAMLTypes.dumpResolvesNonString(str) { return false }
        if str == "=" { return false }
        return true
    }

    private static func canUseSingle(_ str: String, isKey: Bool) -> Bool {
        for c in str.unicodeScalars where !(isNbJson(c) || (!isKey && c == "\n")) { return false }
        let u = Array(str.utf16)
        if u.count >= 2 {
            for i in 0..<(u.count - 1) {
                if (u[i] == 0x20 || u[i] == 0x09) && u[i + 1] == 0x0A { return false }
                if u[i] == 0x0A && (u[i + 1] == 0x20 || u[i + 1] == 0x09) { return false }
            }
        }
        return true
    }

    private static func canUseBlock(_ str: String, flowOnly: Bool, shiftOfParent: Int, shiftOfContent: Int) -> Bool {
        if flowOnly { return false }
        for c in str.unicodeScalars where !(c == "\n" || isNbChar(c)) { return false }
        let contentIndent = shiftOfContent - shiftOfParent
        if contentIndent < 1 { return false }
        if contentIndent > 9 && startsWithNewlinesThenSpace(str) { return false }
        if shiftOfContent == 0 && rx.forbiddenContent.matches(str) { return false }
        return true
    }

    private static func startsWithNewlinesThenSpace(_ s: String) -> Bool {
        for c in s.unicodeScalars {
            if c == "\n" { continue }
            return c == " "
        }
        return false
    }

    private static func encodeFlowBreaks(_ s: String, _ shift: Int) -> String {
        guard s.contains("\n") else { return s }
        let pad = String(repeating: " ", count: shift)
        let parts = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result = parts[0]
        var i = 1
        while i < parts.count {
            var breaks = 1
            while i < parts.count - 1 && parts[i].isEmpty { breaks += 1; i += 1 }
            result += String(repeating: "\n", count: breaks + 1) + pad + parts[i]
            i += 1
        }
        return result
    }

    private static func indentString(_ s: String, _ spaces: Int) -> String {
        let ind = String(repeating: " ", count: spaces)
        var result = ""
        var lines = s.components(separatedBy: "\n")
        let endsWithNL = s.hasSuffix("\n")
        if endsWithNL { lines.removeLast() }
        for (i, line) in lines.enumerated() {
            let isLast = i == lines.count - 1
            let withNL = !isLast || endsWithNL
            if !line.isEmpty { result += ind }
            result += line + (withNL ? "\n" : "")
        }
        return result
    }

    private static func blockHeader(_ s: String, _ shiftOfParent: Int, _ shiftOfContent: Int) -> String {
        let indicator = startsWithNewlinesThenSpace(s) ? String(shiftOfContent - shiftOfParent) : ""
        let clip = s.hasSuffix("\n")
        let keep = clip && (s.hasSuffix("\n\n") || s == "\n")
        return indicator + (keep ? "+" : clip ? "" : "-") + "\n"
    }

    private static func dropEndingNewline(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }

    private static func str(_ u: ArraySlice<UInt16>) -> String { String(decoding: Array(u), as: UTF16.self) }

    private static func foldLine(_ lineS: String, _ width: Int) -> String {
        let line = Array(lineS.utf16)
        if line.isEmpty || line[0] == 0x20 || line[0] == 0x09 { return lineS }
        var start = 0, curr = 0, next = 0
        var result = ""
        var i = 0
        while i < line.count - 1 {
            if line[i] == 0x20 && line[i + 1] != 0x20 && line[i + 1] != 0x09 {
                next = i
                if next - start > width {
                    let end = curr > start ? curr : next
                    result += "\n" + str(line[start..<end])
                    start = end + 1
                }
                curr = next
            }
            i += 1
        }
        result += "\n"
        if line.count - start > width && curr > start {
            result += str(line[start..<curr]) + "\n" + str(line[(curr + 1)...])
        } else {
            result += str(line[start...])
        }
        return String(result.dropFirst())
    }

    private static func foldBlockScalar(_ s: String, _ width: Int) -> String {
        let isMoreIndented: (String) -> Bool = { $0.hasPrefix(" ") || $0.hasPrefix("\t") }
        let parts = s.components(separatedBy: "\n")
        var result = foldLine(parts[0], width)
        var prevMoreIndented = s.hasPrefix("\n") || isMoreIndented(s)
        var i = 1
        while i < parts.count {
            // One match of /(\n+)([^\n]*)/: a run of newlines, then a line.
            var breaks = 1
            while i < parts.count - 1 && parts[i].isEmpty { breaks += 1; i += 1 }
            let line = parts[i]
            let more = !line.isEmpty && isMoreIndented(line)
            result += String(repeating: "\n", count: breaks)
                + (!prevMoreIndented && !more && !line.isEmpty ? "\n" : "") + foldLine(line, width)
            prevMoreIndented = more
            i += 1
        }
        return result
    }

    static func escapeString(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            let v = c.value
            let needs = c == "\"" || c == "\\" || v <= 0x1F || (v >= 0x7F && v <= 0xA0) || v == 0x2028 || v == 0x2029
                || v == 0xFEFF || v == 0xFFFE || v == 0xFFFF
            guard needs else { out.unicodeScalars.append(c); continue }
            switch v {
            case 0x00: out += "\\0"
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0B: out += "\\v"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x1B: out += "\\e"
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x85: out += "\\N"
            case 0xA0: out += "\\_"
            case 0x2028: out += "\\L"
            case 0x2029: out += "\\P"
            default:
                let hex = String(v, radix: 16).uppercased()
                if v <= 0xFF { out += "\\x" + String(repeating: "0", count: 2 - hex.count) + hex }
                else { out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex }
            }
        }
        return out
    }
}

// MARK: - Implicit types

enum YAMLTypes {
    private static func re(_ p: String) -> NSRegularExpression { (try? NSRegularExpression(pattern: p)) ?? NSRegularExpression() }

    static let int11 = re("^(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?0x[0-9a-fA-F_]+|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+|[-+]?(?:0|[1-9][0-9_]*))\\z")
    static let intCore = re("^(?:0o[0-7]+|0x[0-9a-fA-F]+|[-+]?[0-9]+)\\z")
    static let float11 = re("^(?:[-+]?(?:(?:[0-9][0-9_]*)?\\.[0-9_]*)(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\\.[0-9_]*|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))\\z")
    static let floatCore = re("^(?:[-+]?[0-9]+(?:\\.[0-9]*)?(?:[eE][-+]?[0-9]+)?|[-+]?\\.[0-9]+(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))\\z")
    static let floatSpecial = re("^(?:[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))\\z")
    static let date = re("^([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9])\\z")
    static let timestamp = re("^([0-9][0-9][0-9][0-9])-([0-9][0-9]?)-([0-9][0-9]?)(?:[Tt]|[ \\t]+)([0-9][0-9]?):([0-9][0-9]):([0-9][0-9])(?:\\.([0-9]*))?(?:[ \\t]*(Z|([-+])([0-9][0-9]?)(?::([0-9][0-9]))?))?\\z")

    static let null11: Set<String> = ["", "~", "null", "Null", "NULL"]
    static let bool11: Set<String> = ["true", "True", "TRUE", "y", "Y", "yes", "Yes", "YES", "on", "On", "ON",
                                      "false", "False", "FALSE", "n", "N", "no", "No", "NO", "off", "Off", "OFF"]

    /// Would js-yaml's DUMP schema read this plain scalar as anything but a
    /// string? (Then it has to be quoted.)
    static func dumpResolvesNonString(_ s: String) -> Bool {
        if null11.contains(s) || bool11.contains(s) || s == "<<" { return true }
        if int11.matches(s) || intCore.matches(s) { return true }
        if float11.matches(s) {
            if floatSpecial.matches(s) { return true }
            if let d = Double(s.lowercased().replacingOccurrences(of: "_", with: "")), d.isFinite { return true }
            if s.contains(":") { return true }
            // "1." / ".5" style: parseFloat reads them
            let t = s.replacingOccurrences(of: "_", with: "")
            if t.contains(where: \.isNumber) { return true }
        }
        if floatCore.matches(s) {
            if floatSpecial.matches(s) { return true }
            if let d = Double(s), d.isFinite { return true }
        }
        if isTimestamp(s) { return true }
        return false
    }

    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
    }

    static func isTimestamp(_ s: String) -> Bool {
        let g = groups(date, s) ?? groups(timestamp, s)
        guard let g, let y = Int(g[1] ?? ""), let mo = Int(g[2] ?? ""), let d = Int(g[3] ?? "") else { return false }
        var comps = DateComponents(); comps.year = y; comps.month = mo; comps.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard (1...12).contains(mo), let date = cal.date(from: comps),
              cal.component(.day, from: date) == d, cal.component(.month, from: date) == mo else { return false }
        if g.count > 4, let h = g[4] {
            guard let hh = Int(h), let mm = Int(g[5] ?? ""), let ss = Int(g[6] ?? ""), hh <= 23, mm <= 59, ss <= 59 else { return false }
            if g.count > 9, g[9] != nil {
                guard let oh = Int(g[10] ?? ""), oh <= 23, Int(g[11] ?? "0") ?? 0 <= 59 else { return false }
            }
        }
        return true
    }

    /// The core schema, as `yaml.load` resolves a plain scalar.
    static func resolveCore(_ s: String) -> YAMLValue {
        if ["", "~", "null", "Null", "NULL"].contains(s) { return .null }
        if ["true", "True", "TRUE"].contains(s) { return .bool(true) }
        if ["false", "False", "FALSE"].contains(s) { return .bool(false) }
        if intCore.matches(s) {
            var v = Substring(s)
            var sign = 1
            if v.first == "-" || v.first == "+" { if v.first == "-" { sign = -1 }; v = v.dropFirst() }
            if v.hasPrefix("0o"), let n = Int(v.dropFirst(2), radix: 8) { return .int(sign * n) }
            if v.hasPrefix("0x"), let n = Int(v.dropFirst(2), radix: 16) { return .int(sign * n) }
            if let n = Int(v) { return .int(sign * n) }
            if let d = Double(s) { return .double(d) }
        }
        if floatCore.matches(s) {
            let l = s.lowercased()
            var t = Substring(l)
            let sign: Double = t.first == "-" ? -1 : 1
            if t.first == "-" || t.first == "+" { t = t.dropFirst() }
            if t == ".inf" { return .double(sign * .infinity) }
            if t == ".nan" { return .double(.nan) }
            if let d = Double(t), d.isFinite { return .double(sign * d) }
        }
        return .string(s)
    }
}

// MARK: - Reader

struct YAMLError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// `yaml.load(text)` for block YAML: one document of mappings, sequences and
/// scalars (plain, quoted, literal and folded), flow collections, comments,
/// anchors and aliases.
struct YAMLReader {
    private var lines: [[Character]] = []
    private var li = 0
    private var col = 0
    private var anchors: [String: YAMLValue] = [:]

    static func load(_ text: String) throws -> YAMLValue {
        var r = YAMLReader()
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        r.lines = t.components(separatedBy: "\n").map { Array($0) }
        return try r.document()
    }

    /// js-yaml's wording: the reason, `(line:column)`, then the lines up to
    /// it with a caret under the column.
    private func err(_ msg: String) -> YAMLError {
        let line = min(li, max(0, lines.count - 1))
        let c = li < lines.count ? col : (lines.last?.count ?? 0)
        let first = max(0, line - 3)
        let width = String(line + 1).count
        var snippet = ""
        for i in first...line where i < lines.count {
            let n = String(i + 1)
            snippet += "\n " + String(repeating: " ", count: width - n.count) + n + " | " + String(lines[i])
        }
        snippet += "\n" + String(repeating: "-", count: 1 + width + 3 + c) + "^"
        return YAMLError(message: "\(msg) (\(line + 1):\(c + 1))\n" + snippet)
    }

    private func line(_ i: Int) -> [Character] { i < lines.count ? lines[i] : [] }

    private func indentOf(_ l: [Character]) -> Int {
        var n = 0
        while n < l.count && l[n] == " " { n += 1 }
        return n
    }

    private func isBlank(_ l: [Character], from: Int = 0) -> Bool {
        var i = from
        while i < l.count && (l[i] == " " || l[i] == "\t") { i += 1 }
        return i >= l.count || l[i] == "#"
    }

    private func isDocMarker(_ l: [Character]) -> Bool {
        guard l.count >= 3 else { return false }
        let p = String(l[0..<3])
        return (p == "---" || p == "...") && (l.count == 3 || l[3] == " " || l[3] == "\t")
    }

    /// Move to the next line with content, column at its first character.
    private mutating func skipBlank() {
        while li < lines.count {
            if !isBlank(lines[li], from: col) {
                while col < lines[li].count && (lines[li][col] == " " || lines[li][col] == "\t") { col += 1 }
                return
            }
            li += 1
            col = 0
        }
    }

    private var atEnd: Bool { li >= lines.count }

    private mutating func document() throws -> YAMLValue {
        // Directives and the start marker.
        while li < lines.count {
            let l = lines[li]
            if isBlank(l) || l.first == "%" { li += 1; continue }
            if isDocMarker(l) && String(l[0..<3]) == "---" {
                col = 3
                if isBlank(l, from: 3) { li += 1; col = 0 }
            }
            break
        }
        skipBlank()
        if atEnd { return .null }
        if col == 0 && isDocMarker(lines[li]) && String(lines[li][0..<3]) == "..." { return .null }
        let v = try node(parentIndent: -1)
        skipBlank()
        if !atEnd {
            let l = lines[li]
            if isDocMarker(l) && col == 0 {
                if String(l[0..<3]) == "---" {
                    li += 1; col = 0; skipBlank()
                    if !atEnd { throw err("expected a single document in the stream, but found more") }
                }
            } else {
                throw err("end of the stream or a document separator is expected")
            }
        }
        return v
    }

    private func rest() -> [Character] { li < lines.count && col <= lines[li].count ? Array(lines[li][col...]) : [] }

    /// A node starting at the current position. `parentIndent` is the
    /// indentation of the collection it belongs to (-1 at the root).
    private mutating func node(parentIndent: Int) throws -> YAMLValue {
        skipBlank()
        if atEnd { return .null }
        if col == 0 && isDocMarker(lines[li]) { return .null }
        var r = rest()
        // Properties: an anchor and/or a tag before the content.
        var anchor: String?
        var tag: String?
        while let f = r.first, f == "&" || f == "!" {
            var j = 1
            while j < r.count && r[j] != " " && r[j] != "\t" { j += 1 }
            let word = String(r[1..<j])
            if f == "&" { anchor = word } else { tag = word }
            col += j
            while col < line(li).count && (line(li)[col] == " " || line(li)[col] == "\t") { col += 1 }
            r = rest()
            if r.isEmpty || r.first == "#" {
                // The content is on the following lines.
                li += 1; col = 0
                skipBlank()
                if atEnd || indentOf(line(li)) <= parentIndent {
                    let v = try applyTag(tag, .string(""))
                    if let anchor { anchors[anchor] = v }
                    return v
                }
                r = rest()
                break
            }
        }
        var v = try content(parentIndent: parentIndent)
        v = try applyTag(tag, v)
        if let anchor { anchors[anchor] = v }
        return v
    }

    private func applyTag(_ tag: String?, _ v: YAMLValue) throws -> YAMLValue {
        guard let tag else { return v }
        switch tag {
        case "!str", "!!str": if case .string = v { return v }; return .string(v.jsString == "null" ? "" : v.jsString)
        case "!!int": if case .string(let s) = v, let n = Int(s) { return .int(n) }; return v
        case "!!float": if case .string(let s) = v, let d = Double(s) { return .double(d) }; return v
        case "!!bool": if case .string(let s) = v { return .bool(s == "true") }; return v
        case "!!null": return .null
        default: return v
        }
    }

    private mutating func content(parentIndent: Int) throws -> YAMLValue {
        let r = rest()
        guard let f = r.first else { return .null }
        let here = col
        if f == "*" {
            var j = 1
            while j < r.count && r[j] != " " && r[j] != "\t" && r[j] != "," && r[j] != "]" && r[j] != "}" { j += 1 }
            let name = String(r[1..<j])
            guard let v = anchors[name] else { throw err("unidentified alias \"\(name)\"") }
            col += j
            try endOfLine()
            return v
        }
        if f == "-" && (r.count == 1 || r[1] == " " || r[1] == "\t") {
            return try blockSequence(indent: here)
        }
        if f == "|" || f == ">" { return try blockScalar(parentIndent: parentIndent) }
        if f == "[" || f == "{" {
            let v = try flowCollection()
            // A flow mapping or sequence used as a key is not supported here.
            try endOfLine()
            return v
        }
        if f == "?" && (r.count == 1 || r[1] == " ") { throw err("explicit mapping keys are not supported") }
        // A mapping, if this line has a key.
        if keyEnd(r) != nil { return try blockMapping(indent: here, parentIndent: parentIndent) }
        if f == "\"" || f == "'" {
            let s = try quoted()
            try endOfLine()
            return .string(s)
        }
        return try plainScalar(parentIndent: parentIndent, inFlow: false)
    }

    /// Where the key on this line ends: (end of key text, index of the value).
    private func keyEnd(_ r: [Character]) -> (key: String, valueAt: Int)? {
        guard let f = r.first else { return nil }
        if f == "\"" || f == "'" {
            // Find the closing quote, then require `:`.
            var j = 1
            var key = ""
            while j < r.count {
                if f == "'" && r[j] == "'" {
                    if j + 1 < r.count && r[j + 1] == "'" { key.append("'"); j += 2; continue }
                    break
                }
                if f == "\"" && r[j] == "\\" && j + 1 < r.count { j += 2; continue }
                if f == "\"" && r[j] == "\"" { break }
                j += 1
            }
            guard j < r.count else { return nil }
            var k = j + 1
            while k < r.count && (r[k] == " " || r[k] == "\t") { k += 1 }
            guard k < r.count, r[k] == ":", k + 1 == r.count || r[k + 1] == " " || r[k + 1] == "\t" else { return nil }
            return ("", k + 1)
        }
        if "[{]}#,`@|>%".contains(f) { return nil }
        if (f == "-" || f == "?" || f == ":") && (r.count == 1 || r[1] == " " || r[1] == "\t") { return nil }
        var j = 0
        while j < r.count {
            if r[j] == "#" && j > 0 && (r[j - 1] == " " || r[j - 1] == "\t") { return nil }
            if r[j] == ":" && (j + 1 == r.count || r[j + 1] == " " || r[j + 1] == "\t") {
                var end = j
                while end > 0 && (r[end - 1] == " " || r[end - 1] == "\t") { end -= 1 }
                return (String(r[0..<end]), j + 1)
            }
            j += 1
        }
        return nil
    }

    private mutating func endOfLine() throws {
        let l = line(li)
        var i = col
        while i < l.count && (l[i] == " " || l[i] == "\t") { i += 1 }
        if i < l.count && l[i] != "#" { throw err("unexpected content after a value") }
        li += 1
        col = 0
    }

    private mutating func blockMapping(indent: Int, parentIndent: Int) throws -> YAMLValue {
        var items: [(String, YAMLValue)] = []
        var first = true
        while true {
            if !first {
                skipBlank()
                if atEnd { break }
                let ind = indentOf(lines[li])
                if ind < indent || (ind == 0 && isDocMarker(lines[li])) { break }
                if ind > indent { throw err("bad indentation of a mapping entry") }
                col = ind
            }
            first = false
            let r = rest()
            if r.first == "-" && (r.count == 1 || r[1] == " ") { break }
            guard let k = keyEnd(r) else { throw err("can not read a block mapping entry; a multiline key may not be an implicit key") }
            var key = k.key
            if r.first == "\"" || r.first == "'" {
                let save = col
                key = try quoted()
                col = save
            }
            if items.contains(where: { $0.0 == key }) { throw err("duplicated mapping key") }
            col += k.valueAt
            while col < line(li).count && (line(li)[col] == " " || line(li)[col] == "\t") { col += 1 }
            let after = rest()
            let value: YAMLValue
            if after.isEmpty || after.first == "#" {
                li += 1; col = 0
                skipBlank()
                if atEnd { value = .null }
                else {
                    let ind = indentOf(lines[li])
                    let r2 = rest()
                    if ind > indent && !(ind == 0 && isDocMarker(lines[li])) {
                        value = try node(parentIndent: indent)
                    } else if ind == indent && r2.first == "-" && (r2.count == 1 || r2[1] == " ") {
                        value = try blockSequence(indent: indent)
                    } else {
                        value = .null
                    }
                }
            } else {
                value = try node(parentIndent: indent)
            }
            items.append((key, value))
        }
        _ = parentIndent
        return .map(items)
    }

    private mutating func blockSequence(indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []
        var first = true
        while true {
            if !first {
                skipBlank()
                if atEnd { break }
                let ind = indentOf(lines[li])
                if ind != indent || (ind == 0 && isDocMarker(lines[li])) {
                    if ind > indent { throw err("bad indentation of a sequence entry") }
                    break
                }
                col = ind
            }
            first = false
            let r = rest()
            guard r.first == "-", r.count == 1 || r[1] == " " || r[1] == "\t" else { break }
            col += 1
            while col < line(li).count && (line(li)[col] == " " || line(li)[col] == "\t") { col += 1 }
            let after = rest()
            if after.isEmpty || after.first == "#" {
                li += 1; col = 0
                skipBlank()
                if !atEnd && indentOf(lines[li]) > indent { items.append(try node(parentIndent: indent)) }
                else { items.append(.null) }
            } else {
                items.append(try node(parentIndent: indent))
            }
        }
        return .seq(items)
    }

    private mutating func blockScalar(parentIndent: Int) throws -> YAMLValue {
        let r = rest()
        let folded = r[0] == ">"
        var chomp = "clip"
        var explicit: Int?
        var j = 1
        while j < r.count && r[j] != " " && r[j] != "\t" && r[j] != "#" {
            if r[j] == "+" { chomp = "keep" } else if r[j] == "-" { chomp = "strip" }
            else if let d = r[j].wholeNumberValue, d > 0 { explicit = d }
            else { throw err("bad block scalar header") }
            j += 1
        }
        li += 1; col = 0
        let base = max(parentIndent, 0)
        var contentIndent: Int?
        if let explicit { contentIndent = (parentIndent < 0 ? 0 : parentIndent) + explicit }
        var raw: [String] = []
        while li < lines.count {
            let l = lines[li]
            let ind = indentOf(l)
            let blank = ind == l.count
            if contentIndent == nil {
                if blank { raw.append(""); li += 1; continue }
                if ind <= parentIndent || (parentIndent < 0 && ind < base) { break }
                contentIndent = ind
            }
            let ci = contentIndent ?? 0
            if blank {
                raw.append(l.count > ci ? String(l[ci...]) : "")
                li += 1
                continue
            }
            if ind < ci { break }
            if ci == 0 && isDocMarker(l) { break }
            raw.append(String(l[ci...]))
            li += 1
        }
        col = 0
        // Trailing blank lines belong to chomping.
        var trailing = 0
        while let last = raw.last, last.allSatisfy({ $0 == " " }) {
            raw.removeLast()
            trailing += 1
        }
        var text = folded ? foldFix(raw) : raw.joined(separator: "\n")
        if raw.isEmpty {
            return .string(chomp == "keep" ? String(repeating: "\n", count: trailing) : "")
        }
        switch chomp {
        case "strip": break
        case "keep": text += "\n" + String(repeating: "\n", count: trailing)
        default: text += "\n"
        }
        return .string(text)
    }

    /// Folding as the spec has it: a single line break between two text lines
    /// becomes a space; each blank line in between is a newline; lines that
    /// are more indented keep their breaks.
    private func foldFix(_ raw: [String]) -> String {
        var out = ""
        var i = 0
        var prevText: Bool? = nil   // was the previous non-blank line a normal text line
        var pendingBlank = 0
        while i < raw.count {
            let ln = raw[i]
            if ln.isEmpty { pendingBlank += 1; i += 1; continue }
            let more = ln.hasPrefix(" ") || ln.hasPrefix("\t")
            if let pt = prevText {
                if pt && !more && pendingBlank == 0 { out += " " }
                else if pt && !more { out += String(repeating: "\n", count: pendingBlank) }
                else { out += String(repeating: "\n", count: pendingBlank + 1) }
            } else {
                out += String(repeating: "\n", count: pendingBlank)
            }
            out += ln
            pendingBlank = 0
            prevText = !more
            i += 1
        }
        return out
    }

    /// A single- or double-quoted scalar from the current position (may span
    /// lines). Leaves the position after the closing quote.
    private mutating func quoted() throws -> String {
        let q = line(li)[col]
        col += 1
        var out = ""
        var pendingSpace = false
        var newlines = 0
        while true {
            let l = line(li)
            if li >= lines.count {
                throw err("unexpected end of the stream within a \(q == "'" ? "single" : "double") quoted scalar")
            }
            if col >= l.count {
                // Line break inside the scalar: folded.
                li += 1
                col = 0
                // Trim trailing whitespace already added.
                while out.hasSuffix(" ") || out.hasSuffix("\t") { out.removeLast() }
                newlines += 1
                while col < line(li).count && (line(li)[col] == " " || line(li)[col] == "\t") { col += 1 }
                if li < lines.count && col >= line(li).count { continue }
                pendingSpace = true
                continue
            }
            if pendingSpace || newlines > 0 {
                if newlines > 1 { out += String(repeating: "\n", count: newlines - 1) } else if newlines == 1 { out += " " }
                pendingSpace = false
                newlines = 0
            }
            let c = l[col]
            if q == "'" {
                if c == "'" {
                    if col + 1 < l.count && l[col + 1] == "'" { out.append("'"); col += 2; continue }
                    col += 1
                    return out
                }
                out.append(c); col += 1
                continue
            }
            if c == "\"" { col += 1; return out }
            if c == "\\" {
                col += 1
                guard col < l.count else {
                    // An escaped line break: joined with nothing.
                    li += 1; col = 0
                    while col < line(li).count && (line(li)[col] == " " || line(li)[col] == "\t") { col += 1 }
                    continue
                }
                let e = l[col]
                col += 1
                switch e {
                case "0": out.append("\u{0}")
                case "a": out.append("\u{07}")
                case "b": out.append("\u{08}")
                case "t", "\t": out.append("\t")
                case "n": out.append("\n")
                case "v": out.append("\u{0B}")
                case "f": out.append("\u{0C}")
                case "r": out.append("\r")
                case "e": out.append("\u{1B}")
                case " ": out.append(" ")
                case "\"": out.append("\"")
                case "/": out.append("/")
                case "\\": out.append("\\")
                case "N": out.append("\u{85}")
                case "_": out.append("\u{A0}")
                case "L": out.append("\u{2028}")
                case "P": out.append("\u{2029}")
                case "x", "u", "U":
                    let n = e == "x" ? 2 : e == "u" ? 4 : 8
                    guard col + n <= l.count, let v = UInt32(String(l[col..<(col + n)]), radix: 16),
                          let s = Unicode.Scalar(v) else { throw err("expected hexadecimal character") }
                    out.unicodeScalars.append(s)
                    col += n
                default: throw err("unknown escape sequence")
                }
                continue
            }
            out.append(c)
            col += 1
        }
    }

    /// A plain scalar, possibly continued on more-indented lines.
    private mutating func plainScalar(parentIndent: Int, inFlow: Bool) throws -> YAMLValue {
        /// The text of a line from `from`, up to a ` #` comment; and whether one was found.
        func text(_ l: [Character], _ from: Int) -> (String, Bool) {
            var t = ""
            var k = from
            while k < l.count {
                if l[k] == "#" && k > from && (l[k - 1] == " " || l[k - 1] == "\t") { return (t.trimmingCharacters(in: .whitespaces), true) }
                t.append(l[k]); k += 1
            }
            return (t.trimmingCharacters(in: .whitespaces), false)
        }
        let (first, commented) = text(line(li), col)
        var s = first
        li += 1
        col = 0
        guard !commented else { return YAMLTypes.resolveCore(s) }
        // Continuation lines: more indented than the parent, until a comment.
        var blank = 0
        while li < lines.count {
            let l = lines[li]
            let ind = indentOf(l)
            if ind == l.count || l[ind...].allSatisfy({ $0 == " " || $0 == "\t" }) { blank += 1; li += 1; continue }
            if l[ind] == "#" || ind <= parentIndent || (ind == 0 && isDocMarker(l)) { break }
            let (t, stop) = text(l, ind)
            s += blank > 0 ? String(repeating: "\n", count: blank) + t : " " + t
            blank = 0
            li += 1
            if stop { break }
        }
        return YAMLTypes.resolveCore(s)
    }

    // MARK: Flow collections

    private mutating func flowCollection() throws -> YAMLValue {
        // Gather the text up to the matching bracket, across lines.
        var text: [Character] = []
        var depth = 0
        var quote: Character?
        var done = false
        while !done {
            guard li < lines.count else { throw err("unexpected end of the stream within a flow collection") }
            let l = lines[li]
            while col < l.count {
                let c = l[col]
                if let q = quote {
                    text.append(c)
                    if q == "\"" && c == "\\" && col + 1 < l.count { text.append(l[col + 1]); col += 2; continue }
                    if c == q {
                        if q == "'" && col + 1 < l.count && l[col + 1] == "'" { text.append("'"); col += 2; continue }
                        quote = nil
                    }
                    col += 1
                    continue
                }
                if c == "#" && (text.last == " " || text.isEmpty) { col = l.count; break }
                if c == "\"" || c == "'" { quote = c }
                if c == "[" || c == "{" { depth += 1 }
                if c == "]" || c == "}" { depth -= 1 }
                text.append(c)
                col += 1
                if depth == 0 { done = true; break }
            }
            if !done { li += 1; col = 0; text.append(" ") }
        }
        var p = FlowParser(chars: text)
        let v = try p.value()
        return v
    }

    private struct FlowParser {
        let chars: [Character]
        var i = 0

        mutating func ws() { while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 } }

        mutating func value() throws -> YAMLValue {
            ws()
            guard i < chars.count else { return .null }
            let c = chars[i]
            if c == "[" {
                i += 1
                var items: [YAMLValue] = []
                while true {
                    ws()
                    if i < chars.count && chars[i] == "]" { i += 1; break }
                    let v = try value()
                    ws()
                    if i < chars.count && chars[i] == ":" {
                        i += 1
                        let v2 = try value()
                        items.append(.map([(v.jsString, v2)]))
                    } else {
                        items.append(v)
                    }
                    ws()
                    if i < chars.count && chars[i] == "," { i += 1; continue }
                    if i < chars.count && chars[i] == "]" { i += 1; break }
                    throw YAMLError(message: "missed comma between flow collection entries")
                }
                return .seq(items)
            }
            if c == "{" {
                i += 1
                var items: [(String, YAMLValue)] = []
                while true {
                    ws()
                    if i < chars.count && chars[i] == "}" { i += 1; break }
                    let k = try value()
                    ws()
                    var v: YAMLValue = .null
                    if i < chars.count && chars[i] == ":" { i += 1; v = try value() }
                    let key = k.isNull ? "null" : k.jsString
                    if items.contains(where: { $0.0 == key }) { throw YAMLError(message: "duplicated mapping key") }
                    items.append((key, v))
                    ws()
                    if i < chars.count && chars[i] == "," { i += 1; continue }
                    if i < chars.count && chars[i] == "}" { i += 1; break }
                    throw YAMLError(message: "missed comma between flow collection entries")
                }
                return .map(items)
            }
            if c == "\"" || c == "'" {
                i += 1
                var out = ""
                while i < chars.count {
                    let d = chars[i]
                    if c == "'" && d == "'" {
                        if i + 1 < chars.count && chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                        i += 1
                        return .string(out)
                    }
                    if c == "\"" && d == "\"" { i += 1; return .string(out) }
                    if c == "\"" && d == "\\" && i + 1 < chars.count {
                        let e = chars[i + 1]
                        i += 2
                        switch e {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "r": out.append("\r")
                        case "0": out.append("\u{0}")
                        case "\"": out.append("\"")
                        case "\\": out.append("\\")
                        case "/": out.append("/")
                        case "x", "u", "U":
                            let n = e == "x" ? 2 : e == "u" ? 4 : 8
                            guard i + n <= chars.count, let v = UInt32(String(chars[i..<(i + n)]), radix: 16),
                                  let s = Unicode.Scalar(v) else { throw YAMLError(message: "expected hexadecimal character") }
                            out.unicodeScalars.append(s); i += n
                        default: out.append(e)
                        }
                        continue
                    }
                    out.append(d)
                    i += 1
                }
                throw YAMLError(message: "unexpected end of a quoted scalar")
            }
            var s = ""
            while i < chars.count {
                let d = chars[i]
                if d == "," || d == "]" || d == "}" { break }
                if d == ":" && (i + 1 >= chars.count || chars[i + 1] == " " || ",]}".contains(chars[i + 1])) { break }
                s.append(d)
                i += 1
            }
            return YAMLTypes.resolveCore(s.trimmingCharacters(in: .whitespaces))
        }
    }
}

extension YAMLValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}
