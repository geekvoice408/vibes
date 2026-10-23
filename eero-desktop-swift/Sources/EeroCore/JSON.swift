import Foundation

/// Dynamic JSON value, the Swift counterpart of the `J` helper in the Windows client.
/// Lookups never throw: a missing key yields `.null`, and the string accessors yield "".
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Construction

    /// Builds an object from alternating keys and values, like `J.Obj`.
    public static func obj(_ pairs: (String, JSONConvertible?)...) -> JSON {
        var d: [String: JSON] = [:]
        for (k, v) in pairs { d[k] = v?.json ?? .null }
        return .object(d)
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSON {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON(any: any)
    }

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
            #else
            if String(cString: n.objCType) == "c" { self = .bool(n.boolValue); return }
            #endif
            self = .number(n.doubleValue)
        case let b as Bool: self = .bool(b)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSON(any: $0) })
        default: self = .string(String(describing: any!))
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    public func serialized(sorted: Bool = true) -> String { render(sorted: sorted) }

    public var data: Data { Data(serialized().utf8) }

    private func render(sorted: Bool) -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JSON.format(n)
        case .string(let s): return JSON.quote(s)
        case .array(let a): return "[" + a.map { $0.render(sorted: sorted) }.joined(separator: ",") + "]"
        case .object(let o):
            let keys = sorted ? o.keys.sorted() : Array(o.keys)
            return "{" + keys.map { JSON.quote($0) + ":" + o[$0]!.render(sorted: sorted) }.joined(separator: ",") + "}"
        }
    }

    static func format(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<", ">", "&", "'": out += String(format: "\\u%04x", u.value)
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: Access

    public subscript(key: String) -> JSON {
        get { if case .object(let o) = self { return o[key] ?? .null }; return .null }
        set {
            var o: [String: JSON]
            if case .object(let existing) = self { o = existing } else { o = [:] }
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    /// Nested lookup, like `J.Get(o, "meta", "code")`.
    public func get(_ keys: String...) -> JSON { get(keys) }
    public func get(_ keys: [String]) -> JSON { keys.reduce(self) { $0[$1] } }

    public var isNull: Bool { self == .null }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }

    /// Invariant string form, like `J.S`. Null becomes "".
    public var string: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "True" : "False"
        case .number(let n): return JSON.format(n)
        case .string(let s): return s
        case .array, .object: return render(sorted: true)
        }
    }
    public func s(_ keys: String...) -> String { get(keys).string }

    /// `J.B`: true only for boolean true or the string "true" (case-insensitive).
    public var bool: Bool {
        switch self {
        case .bool(let b): return b
        default: return string.lowercased() == "true"
        }
    }
    public func b(_ keys: String...) -> Bool { get(keys).bool }

    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    public var int: Int? { double.flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil } }

    /// `J.List`: arrays as-is, objects unwrap a `data` member, anything else is empty.
    public var list: [JSON] {
        switch self {
        case .array(let a): return a
        case .object(let o): return o["data"]?.list ?? []
        default: return []
        }
    }

    /// `J.First`: the first non-empty string among the keys.
    public func first(_ keys: String...) -> String {
        for k in keys { let v = self[k].string; if !v.isEmpty { return v } }
        return ""
    }
}

public protocol JSONConvertible { var json: JSON { get } }
extension JSON: JSONConvertible { public var json: JSON { self } }
extension String: JSONConvertible { public var json: JSON { .string(self) } }
extension Bool: JSONConvertible { public var json: JSON { .bool(self) } }
extension Int: JSONConvertible { public var json: JSON { .number(Double(self)) } }
extension Double: JSONConvertible { public var json: JSON { .number(self) } }
extension Array: JSONConvertible where Element: JSONConvertible { public var json: JSON { .array(map(\.json)) } }
extension Dictionary: JSONConvertible where Key == String, Value: JSONConvertible { public var json: JSON { .object(mapValues(\.json)) } }
extension Optional: JSONConvertible where Wrapped: JSONConvertible { public var json: JSON { self?.json ?? .null } }

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}

extension String {
    /// `NullIfEmpty` from the Windows client.
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}
