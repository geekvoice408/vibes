import Foundation
import CoreGraphics

/// Reads RFB's big-endian fields from a byte source that may hand them over
/// in pieces (a socket), or from a fixed buffer (tests). Blocking.
final class RFBReader {
    struct EndOfStream: Error, CustomStringConvertible { var description: String { "the connection closed" } }

    private var buf: [UInt8] = []
    private var pos = 0
    private let source: () throws -> [UInt8]

    /// `source` returns more bytes, or empty at the end of the stream.
    init(source: @escaping () throws -> [UInt8]) { self.source = source }

    /// A reader over fixed data.
    convenience init(_ data: [UInt8]) {
        var given = false
        self.init(source: { if given { return [] }; given = true; return data })
    }

    var buffered: Int { buf.count - pos }

    func need(_ n: Int) throws {
        while buf.count - pos < n {
            if pos > 0 && (pos > 1 << 20 || pos == buf.count) {
                buf.removeFirst(pos)
                pos = 0
            }
            let more = try source()
            if more.isEmpty { throw EndOfStream() }
            buf += more
        }
    }

    func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return buf[pos] }

    func u16() throws -> Int {
        try need(2); defer { pos += 2 }
        return Int(buf[pos]) << 8 | Int(buf[pos + 1])
    }

    func u32() throws -> UInt32 {
        try need(4); defer { pos += 4 }
        return UInt32(buf[pos]) << 24 | UInt32(buf[pos + 1]) << 16 | UInt32(buf[pos + 2]) << 8 | UInt32(buf[pos + 3])
    }

    func s32() throws -> Int32 { Int32(bitPattern: try u32()) }

    func bytes(_ n: Int) throws -> [UInt8] {
        if n <= 0 { return [] }
        try need(n); defer { pos += n }
        return Array(buf[pos..<(pos + n)])
    }

    func skip(_ n: Int) throws { if n > 0 { try need(n); pos += n } }

    /// A 32bpp little-endian pixel in the format this client asks for
    /// (0x00RRGGBB), as an opaque framebuffer value.
    func pixel() throws -> UInt32 {
        try need(4); defer { pos += 4 }
        return UInt32(buf[pos]) | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2]) << 16 | 0xFF00_0000
    }

    /// ZRLE's CPIXEL: the three low bytes of the pixel (B, G, R).
    func cpixel() throws -> UInt32 {
        try need(3); defer { pos += 3 }
        return UInt32(buf[pos]) | UInt32(buf[pos + 1]) << 8 | UInt32(buf[pos + 2]) << 16 | 0xFF00_0000
    }

    /// Tight's compact length: 1–3 bytes, 7 bits each.
    func compactLength() throws -> Int {
        let b0 = Int(try u8())
        var len = b0 & 0x7f
        if b0 & 0x80 != 0 {
            let b1 = Int(try u8())
            len |= (b1 & 0x7f) << 7
            if b1 & 0x80 != 0 { len |= Int(try u8()) << 14 }
        }
        return len
    }
}

/// The remote screen: 32-bit pixels (0xFFRRGGBB, little-endian in memory, so
/// B G R A — what a CGBitmapContext with `byteOrder32Little |
/// noneSkipFirst` reads). Written by the protocol thread, read by the view;
/// every operation takes the lock.
final class RFBFramebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var width: Int
    private(set) var height: Int
    private var data: UnsafeMutablePointer<UInt32>
    private var ctx: CGContext?

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        data = .allocate(capacity: self.width * self.height)
        data.initialize(repeating: 0xFF00_0000, count: self.width * self.height)
        ctx = RFBFramebuffer.makeContext(data, self.width, self.height)
    }

    deinit { data.deallocate() }

    private static func makeContext(_ p: UnsafeMutablePointer<UInt32>, _ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// A new size; what fits of the old picture is kept.
    func resize(width w: Int, height h: Int) {
        lock.lock(); defer { lock.unlock() }
        let nw = max(1, w), nh = max(1, h)
        if nw == width && nh == height { return }
        let n = UnsafeMutablePointer<UInt32>.allocate(capacity: nw * nh)
        n.initialize(repeating: 0xFF00_0000, count: nw * nh)
        let cw = min(nw, width)
        for row in 0..<min(nh, height) {
            (n + row * nw).update(from: data + row * width, count: cw)
        }
        data.deallocate()
        data = n
        width = nw
        height = nh
        ctx = RFBFramebuffer.makeContext(n, nw, nh)
    }

    /// Clip a rectangle to the screen; nil when nothing is left.
    private func clip(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Int, Int, Int, Int)? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        return x1 > x0 && y1 > y0 ? (x0, y0, x1 - x0, y1 - y0) : nil
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard let (cx, cy, cw, ch) = clip(x, y, w, h) else { return }
        for row in cy..<(cy + ch) { (data + row * width + cx).update(repeating: color, count: cw) }
    }

    /// `pixels` is w×h, row-major.
    func put(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ pixels: [UInt32]) {
        lock.lock(); defer { lock.unlock() }
        guard pixels.count >= w * h, let (cx, cy, cw, ch) = clip(x, y, w, h) else { return }
        pixels.withUnsafeBufferPointer { src in
            for row in cy..<(cy + ch) {
                let srcRow = (row - y) * w + (cx - x)
                (data + row * width + cx).update(from: src.baseAddress! + srcRow, count: cw)
            }
        }
    }

    /// Raw 32bpp little-endian pixels straight off the wire.
    func putRaw(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ bytes: [UInt8]) {
        var px = [UInt32](repeating: 0, count: w * h)
        bytes.withUnsafeBufferPointer { b in
            for i in 0..<min(w * h, b.count / 4) {
                let o = i * 4
                px[i] = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | 0xFF00_0000
            }
        }
        put(x, y, w, h, px)
    }

    /// CopyRect: overlapping source and destination are handled.
    func copy(srcX: Int, srcY: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let (cx, cy, cw, ch) = clip(x, y, w, h) else { return }
        let sx = srcX + (cx - x), sy = srcY + (cy - y)
        guard sx >= 0, sy >= 0, sx + cw <= width, sy + ch <= height else { return }
        let rows: [Int] = sy < cy ? Array((0..<ch).reversed()) : Array(0..<ch)
        for r in rows {
            let src = data + (sy + r) * width + sx
            let dst = data + (cy + r) * width + cx
            if sy + r == cy + r { memmove(dst, src, cw * 4) } else { dst.update(from: src, count: cw) }
        }
    }

    func pixel(_ x: Int, _ y: Int) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return data[y * width + x]
    }

    /// Draw a decoded image (Tight JPEG) into a rectangle.
    func draw(_ image: CGImage, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let ctx else { return }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: x, y: height - y - h, width: w, height: h))
        ctx.restoreGState()
    }

    /// A snapshot for drawing. A real copy: the pixels are written behind
    /// CoreGraphics' back, so its copy-on-write snapshot would not notice.
    func makeImage() -> CGImage? {
        lock.lock()
        let w = width, h = height
        let bytes = Data(bytes: data, count: w * h * 4)
        lock.unlock()
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
