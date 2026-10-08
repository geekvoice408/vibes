import Foundation
import CShim

/// A zlib inflate stream that persists across rectangles, as ZRLE and Tight
/// require (the server keeps one deflate stream per connection, or four for
/// Tight, and never resets it unless told to).
final class RFBInflater {
    private var stream = z_stream()
    private var ready = false

    init() { reset() }

    deinit { if ready { inflateEnd(&stream) } }

    func reset() {
        if ready { inflateEnd(&stream) }
        stream = z_stream()
        let rc = inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        ready = rc == Z_OK
    }

    struct InflateError: Error, CustomStringConvertible { var description: String }

    /// Inflate all of `input`. With `expected`, exactly that many bytes are
    /// produced (Tight); without, everything the input yields (ZRLE).
    func inflateData(_ input: [UInt8], expected: Int? = nil) throws -> [UInt8] {
        guard ready else { throw InflateError(description: "zlib is not available") }
        var out = [UInt8](repeating: 0, count: max(expected ?? max(input.count * 4, 4096), 1))
        var produced = 0
        var inCopy = input
        try inCopy.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            while true {
                if produced == out.count {
                    if let expected, produced >= expected { break }
                    out += [UInt8](repeating: 0, count: max(out.count, 4096))
                }
                let room = out.count - produced
                let rc: Int32 = out.withUnsafeMutableBufferPointer { ob in
                    stream.next_out = ob.baseAddress!.advanced(by: produced)
                    stream.avail_out = uInt(room)
                    let r = inflate(&stream, Z_SYNC_FLUSH)
                    produced += room - Int(stream.avail_out)
                    return r
                }
                if rc == Z_STREAM_END { break }
                if rc == Z_BUF_ERROR {
                    // No progress possible: either input is exhausted or output is full.
                    if stream.avail_in == 0 { break }
                    continue
                }
                if rc != Z_OK { throw InflateError(description: "zlib inflate failed (\(rc))") }
                if stream.avail_in == 0 && stream.avail_out > 0 { break }
                if let expected, produced >= expected { break }
            }
            stream.next_in = nil
        }
        if let expected {
            if produced < expected { throw InflateError(description: "zlib data ended early (\(produced) of \(expected) bytes)") }
            return Array(out[0..<expected])
        }
        return Array(out[0..<produced])
    }
}

/// The other direction, for tests that need what a server would send (a
/// persistent stream flushed after each rectangle, as servers do).
final class RFBDeflater {
    private var stream = z_stream()

    init(level: Int32 = 6) {
        _ = deflateInit_(&stream, level, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    }

    deinit { deflateEnd(&stream) }

    func deflateData(_ input: [UInt8]) -> [UInt8] {
        var inCopy = input
        var out = [UInt8](repeating: 0, count: input.count + input.count / 2 + 128)
        var produced = 0
        inCopy.withUnsafeMutableBufferPointer { ib in
            stream.next_in = ib.baseAddress
            stream.avail_in = uInt(ib.count)
            repeat {
                if produced == out.count { out += [UInt8](repeating: 0, count: 4096) }
                let room = out.count - produced
                out.withUnsafeMutableBufferPointer { ob in
                    stream.next_out = ob.baseAddress!.advanced(by: produced)
                    stream.avail_out = uInt(room)
                    _ = deflate(&stream, Z_SYNC_FLUSH)
                    produced += room - Int(stream.avail_out)
                }
            } while stream.avail_out == 0
        }
        return Array(out[0..<produced])
    }
}
