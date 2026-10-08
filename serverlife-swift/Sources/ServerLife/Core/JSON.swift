import Foundation

/// A JSON value, used wherever the Electron app passed loosely-typed objects
/// around: the settings document, host descriptors' extra fields, tsh's
/// `--format=json` output, and the control-socket protocol.
///
/// Subscripts never trap: reading a missing key or index gives `.null`, and
/// writing a key into a non-object turns it into an object. That mirrors how
/// the JavaScript code treated these values (`settings.foo?.bar`).
enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: - Accessors

    var isNull: Bool { if case .null = self { return true }; return false }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The string, or a number/bool rendered as one (tsh sometimes quotes and
    /// sometimes does not).
    var stringish: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 9e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    /// nil when not a number or outside Int's range (never traps on 1e20).
    var int: Int? {
        guard let d = double, d.isFinite, d >= -9.2e18, d <= 9.2e18 else { return nil }
        return Int(d)
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// JavaScript truthiness, for porting `if (x)` faithfully.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Array elements, or empty when this is not an array.
    var items: [JSON] { array ?? [] }

    /// Object entries, or empty when this is not an object.
    var entries: [String: JSON] { object ?? [:] }

    var stringArray: [String] { items.compactMap { $0.string } }

    subscript(key: String) -> JSON {
        get {
            if case .object(let o) = self { return o[key] ?? .null }
            return .null
        }
        set {
            var o = object ?? [:]
            if newValue.isNull, case .object = self {
                // Keep explicit nulls: JSON.stringify keeps them too.
                o[key] = .null
            } else {
                o[key] = newValue
            }
            self = .object(o)
        }
    }

    subscript(index: Int) -> JSON {
        get {
            if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
            return .null
        }
        set {
            guard case .array(var a) = self, index >= 0 else { return }
            while a.count <= index { a.append(.null) }
            a[index] = newValue
            self = .array(a)
        }
    }

    /// Remove a key from an object (JS `delete o.key`).
    mutating func removeKey(_ key: String) {
        guard case .object(var o) = self else { return }
        o.removeValue(forKey: key)
        self = .object(o)
    }

    /// Shallow merge of an object patch (JS `Object.assign`).
    mutating func merge(_ patch: JSON) {
        guard let p = patch.object else { return }
        var o = object ?? [:]
        for (k, v) in p { o[k] = v }
        self = .object(o)
    }

    // MARK: - Parsing and printing

    static func parse(_ data: Data) throws -> JSON {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON(any: any)
    }

    static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    /// Parse, or `.null` when the text is not JSON.
    static func tryParse(_ text: String) -> JSON {
        (try? parse(text)) ?? .null
    }

    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSON(any: $0) })
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        default: self = .string(String(describing: any!))
        }
    }

    /// Foundation objects for JSONSerialization.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if n == n.rounded(), abs(n) < 9.0e15 { return Int64(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    func data(pretty: Bool = false) -> Data {
        var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: any, options: opts)) ?? Data("null".utf8)
    }

    func text(pretty: Bool = false) -> String {
        String(decoding: data(pretty: pretty), as: UTF8.self)
    }

    /// `JSON.stringify(value, null, indent)` spacing: `"key": value`, empty
    /// containers as `[]`/`{}`, no escaped slashes. Keys are sorted (the enum
    /// does not keep insertion order). indent 0 = compact.
    func jsText(indent: Int = 0) -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, indent: Int, level: Int) {
        let nl = indent > 0 ? "\n" : ""
        let pad = String(repeating: " ", count: indent * (level + 1))
        let closePad = String(repeating: " ", count: indent * level)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n):
            if !n.isFinite { out += "null" }
            else if n == n.rounded(), abs(n) < 9.0e15 { out += String(Int64(n)) }
            else { out += "\(n)" }
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, v) in a.enumerated() {
                out += pad
                v.write(into: &out, indent: indent, level: level + 1)
                if i < a.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{" + nl
            let keys = o.keys.sorted()
            for (i, k) in keys.enumerated() {
                out += pad
                JSON.quote(k, into: &out)
                out += indent > 0 ? ": " : ":"
                o[k]!.write(into: &out, indent: indent, level: level + 1)
                if i < keys.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "}"
        }
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }

    // MARK: - Codable bridging

    /// Decode into a Codable type, or nil when the shape does not fit.
    func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        try? JSONDecoder().decode(T.self, from: data())
    }

    /// Encode any Encodable as a JSON value.
    static func encode<T: Encodable>(_ value: T) -> JSON {
        guard let d = try? JSONEncoder().encode(value) else { return .null }
        return (try? parse(d)) ?? .null
    }
}

extension JSON: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
    init(nilLiteral: ()) { self = .null }
}

extension JSON {
    init(_ s: String?) { self = s.map { .string($0) } ?? .null }
    init(_ n: Int?) { self = n.map { .number(Double($0)) } ?? .null }
    init(_ n: Double?) { self = n.map { .number($0) } ?? .null }
    init(_ b: Bool?) { self = b.map { .bool($0) } ?? .null }
    init(_ a: [String]) { self = .array(a.map { .string($0) }) }
}
