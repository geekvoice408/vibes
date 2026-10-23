import Foundation

/// Incremental splitter for the chat service's stream of concatenated JSON objects (not Server-Sent Events).
/// Works on UTF-8 bytes: structural characters are ASCII and never occur inside multi-byte sequences, so
/// chunks may split anywhere, including inside a character.
public final class JsonObjectStream {
    public static let objectLimit = 1024 * 1024
    private var buffer: [UInt8] = []
    private var depth = 0
    private var quoted = false
    private var escaped = false

    public init() {}

    public func feed(_ data: Data, _ receive: (JSON) throws -> Void) throws {
        for c in data {
            if buffer.isEmpty && (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C) { continue }
            if buffer.isEmpty && c != UInt8(ascii: "{") { throw EeroError.data("The chat service returned an unsupported stream.") }
            buffer.append(c)
            if buffer.count > JsonObjectStream.objectLimit { throw EeroError.data("A chat response exceeded the size limit.") }
            if quoted {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { quoted = false }
            } else if c == UInt8(ascii: "\"") { quoted = true }
            else if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
            else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") { depth -= 1 }
            if depth == 0 {
                let value: JSON
                do { value = try JSON.parse(Data(buffer)) } catch { throw EeroError.data("The chat service returned an unsupported stream.") }
                buffer.removeAll(keepingCapacity: true)
                try receive(value)
            }
        }
    }

    public func feed(_ text: String, _ receive: (JSON) throws -> Void) throws { try feed(Data(text.utf8), receive) }

    /// Fails if the stream ended inside an object.
    public func finish() throws {
        if !buffer.isEmpty { throw JsonObjectStream.interrupted }
    }

    public static let interrupted = EeroError.data("The chat response was interrupted. Reload history before sending again.")
}
