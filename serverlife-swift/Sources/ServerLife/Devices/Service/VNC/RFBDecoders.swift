import Foundation
import CoreGraphics
import ImageIO

/// RFB encoding numbers (RFC 6143 and the community registry).
enum RFBEncoding {
    static let raw: Int32 = 0
    static let copyRect: Int32 = 1
    static let rre: Int32 = 2
    static let hextile: Int32 = 5
    static let tight: Int32 = 7
    static let zrle: Int32 = 16
    // pseudo-encodings
    static let cursor: Int32 = -239
    static let desktopSize: Int32 = -223
    static let lastRect: Int32 = -224
    static let extendedDesktopSize: Int32 = -308
    /// -32 + level (0…9): JPEG quality for Tight.
    static func quality(_ level: Int) -> Int32 { -32 + Int32(max(0, min(9, level))) }
    /// -256 + level (0…9): zlib effort.
    static func compression(_ level: Int) -> Int32 { -256 + Int32(max(0, min(9, level))) }
}

/// A cursor shape from the Cursor pseudo-encoding, as RGBA (straight alpha).
struct RFBCursor: Equatable {
    var width: Int
    var height: Int
    var hotX: Int
    var hotY: Int
    var rgba: [UInt8]
    /// No visible pixel at all: the server hides its cursor.
    var isEmpty: Bool {
        if width == 0 || height == 0 { return true }
        var i = 3
        while i < rgba.count { if rgba[i] != 0 { return false }; i += 4 }
        return true
    }
}

/// One screen from ExtendedDesktopSize.
struct RFBScreen: Equatable {
    var id: UInt32
    var x: Int, y: Int, width: Int, height: Int
    var flags: UInt32
}

/// What a rectangle turned out to be, when it was not just pixels.
enum RFBRectResult: Equatable {
    case pixels
    case lastRect
    case cursor(RFBCursor)
    case desktopSize(width: Int, height: Int)
    /// reason: 0 server-side change, 1 our request, 2 another client;
    /// status: 0 ok, 1 prohibited, 2 out of resources, 3 invalid layout.
    case extendedDesktopSize(width: Int, height: Int, reason: Int, status: Int, screens: [RFBScreen])
}

struct RFBDecodeError: Error, CustomStringConvertible { var description: String }

/// The decoders. Holds the state that persists across rectangles — the ZRLE
/// zlib stream and Tight's four — so one per connection.
final class RFBDecoders {
    private let zrleStream = RFBInflater()
    private let tightStreams = [RFBInflater(), RFBInflater(), RFBInflater(), RFBInflater()]

    func decode(_ r: RFBReader, x: Int, y: Int, w: Int, h: Int, encoding: Int32, fb: RFBFramebuffer) throws -> RFBRectResult {
        switch encoding {
        case RFBEncoding.raw:
            fb.putRaw(x, y, w, h, try r.bytes(w * h * 4))
        case RFBEncoding.copyRect:
            let sx = try r.u16(), sy = try r.u16()
            fb.copy(srcX: sx, srcY: sy, x, y, w, h)
        case RFBEncoding.rre:
            try rre(r, x, y, w, h, fb)
        case RFBEncoding.hextile:
            try hextile(r, x, y, w, h, fb)
        case RFBEncoding.zrle:
            try zrle(r, x, y, w, h, fb)
        case RFBEncoding.tight:
            try tight(r, x, y, w, h, fb)
        case RFBEncoding.lastRect:
            return .lastRect
        case RFBEncoding.cursor:
            return .cursor(try cursor(r, hotX: x, hotY: y, w: w, h: h))
        case RFBEncoding.desktopSize:
            return .desktopSize(width: w, height: h)
        case RFBEncoding.extendedDesktopSize:
            let n = Int(try r.u8())
            try r.skip(3)
            var screens: [RFBScreen] = []
            for _ in 0..<n {
                let id = try r.u32()
                let sx = try r.u16(), sy = try r.u16(), sw = try r.u16(), sh = try r.u16()
                let flags = try r.u32()
                screens.append(RFBScreen(id: id, x: sx, y: sy, width: sw, height: sh, flags: flags))
            }
            return .extendedDesktopSize(width: w, height: h, reason: x, status: y, screens: screens)
        default:
            throw RFBDecodeError(description: "the server sent an encoding this viewer did not ask for (\(encoding))")
        }
        return .pixels
    }

    // MARK: RRE

    private func rre(_ r: RFBReader, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: RFBFramebuffer) throws {
        let n = Int(try r.u32())
        fb.fill(x, y, w, h, try r.pixel())
        for _ in 0..<n {
            let c = try r.pixel()
            let sx = try r.u16(), sy = try r.u16(), sw = try r.u16(), sh = try r.u16()
            fb.fill(x + sx, y + sy, sw, sh, c)
        }
    }

    // MARK: Hextile

    private func hextile(_ r: RFBReader, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: RFBFramebuffer) throws {
        var bg: UInt32 = 0xFF00_0000, fg: UInt32 = 0xFFFF_FFFF
        var ty = y
        while ty < y + h {
            let th = min(16, y + h - ty)
            var tx = x
            while tx < x + w {
                let tw = min(16, x + w - tx)
                let sub = try r.u8()
                if sub & 1 != 0 {
                    fb.putRaw(tx, ty, tw, th, try r.bytes(tw * th * 4))
                } else {
                    if sub & 2 != 0 { bg = try r.pixel() }
                    if sub & 4 != 0 { fg = try r.pixel() }
                    var tile = [UInt32](repeating: bg, count: tw * th)
                    if sub & 8 != 0 {
                        let n = Int(try r.u8())
                        let coloured = sub & 16 != 0
                        for _ in 0..<n {
                            let c = coloured ? try r.pixel() : fg
                            let xy = try r.u8(), wh = try r.u8()
                            let sx = Int(xy >> 4), sy = Int(xy & 15)
                            let sw = Int(wh >> 4) + 1, sh = Int(wh & 15) + 1
                            for yy in sy..<min(th, sy + sh) {
                                for xx in sx..<min(tw, sx + sw) { tile[yy * tw + xx] = c }
                            }
                        }
                    }
                    fb.put(tx, ty, tw, th, tile)
                }
                tx += 16
            }
            ty += 16
        }
    }

    // MARK: ZRLE

    private func zrle(_ r: RFBReader, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: RFBFramebuffer) throws {
        let len = Int(try r.u32())
        let compressed = try r.bytes(len)
        let raw = try zrleStream.inflateData(compressed)
        let z = RFBReader(raw)
        var ty = y
        while ty < y + h {
            let th = min(64, y + h - ty)
            var tx = x
            while tx < x + w {
                let tw = min(64, x + w - tx)
                try zrleTile(z, tx, ty, tw, th, fb)
                tx += 64
            }
            ty += 64
        }
    }

    private func zrleTile(_ z: RFBReader, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: RFBFramebuffer) throws {
        let sub = Int(try z.u8())
        let n = w * h
        if sub == 0 {
            var px = [UInt32](repeating: 0, count: n)
            for i in 0..<n { px[i] = try z.cpixel() }
            fb.put(x, y, w, h, px)
            return
        }
        if sub == 1 {
            fb.fill(x, y, w, h, try z.cpixel())
            return
        }
        if sub >= 2 && sub <= 16 {
            var palette: [UInt32] = []
            for _ in 0..<sub { palette.append(try z.cpixel()) }
            let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
            var px = [UInt32](repeating: 0, count: n)
            for row in 0..<h {
                var byte: UInt8 = 0, left = 0
                for col in 0..<w {
                    if left == 0 { byte = try z.u8(); left = 8 }
                    left -= bits
                    let idx = Int((byte >> UInt8(left)) & UInt8((1 << bits) - 1))
                    px[row * w + col] = idx < palette.count ? palette[idx] : 0xFF00_0000
                }
            }
            fb.put(x, y, w, h, px)
            return
        }
        if sub == 128 {
            var px = [UInt32](repeating: 0, count: n)
            var i = 0
            while i < n {
                let c = try z.cpixel()
                let run = try runLength(z)
                for _ in 0..<min(run, n - i) { px[i] = c; i += 1 }
            }
            fb.put(x, y, w, h, px)
            return
        }
        if sub >= 130 {
            var palette: [UInt32] = []
            for _ in 0..<(sub - 128) { palette.append(try z.cpixel()) }
            var px = [UInt32](repeating: 0, count: n)
            var i = 0
            while i < n {
                let b = Int(try z.u8())
                let idx = b & 127
                let c = idx < palette.count ? palette[idx] : 0xFF00_0000
                let run = b & 128 != 0 ? try runLength(z) : 1
                for _ in 0..<min(run, n - i) { px[i] = c; i += 1 }
            }
            fb.put(x, y, w, h, px)
            return
        }
        throw RFBDecodeError(description: "bad ZRLE tile (subencoding \(sub))")
    }

    private func runLength(_ z: RFBReader) throws -> Int {
        var len = 1
        while true {
            let b = Int(try z.u8())
            len += b
            if b != 255 { return len }
        }
    }

    // MARK: Tight

    private func tight(_ r: RFBReader, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: RFBFramebuffer) throws {
        var ctl = Int(try r.u8())
        for i in 0..<4 where (ctl >> i) & 1 != 0 { tightStreams[i].reset() }
        ctl >>= 4
        if ctl == 0x08 {
            // Fill: one TPIXEL (R, G, B).
            let c = try r.bytes(3)
            fb.fill(x, y, w, h, 0xFF00_0000 | UInt32(c[0]) << 16 | UInt32(c[1]) << 8 | UInt32(c[2]))
            return
        }
        if ctl == 0x09 {
            let len = try r.compactLength()
            let jpeg = try r.bytes(len)
            guard let src = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw RFBDecodeError(description: "the server sent a JPEG that could not be decoded")
            }
            fb.draw(img, x, y, w, h)
            return
        }
        if ctl == 0x0A {
            throw RFBDecodeError(description: "the server sent TightPNG, which this viewer did not ask for")
        }
        if ctl & 0x08 != 0 {
            throw RFBDecodeError(description: "illegal Tight compression received (\(ctl))")
        }
        let streamId = ctl & 0x3
        var filter = 0
        if ctl & 0x4 != 0 { filter = Int(try r.u8()) }
        switch filter {
        case 0: // copy
            let data = try tightData(r, size: w * h * 3, stream: streamId)
            var px = [UInt32](repeating: 0, count: w * h)
            for i in 0..<(w * h) {
                px[i] = 0xFF00_0000 | UInt32(data[i * 3]) << 16 | UInt32(data[i * 3 + 1]) << 8 | UInt32(data[i * 3 + 2])
            }
            fb.put(x, y, w, h, px)
        case 1: // palette
            let count = Int(try r.u8()) + 1
            let pal = try r.bytes(count * 3)
            var palette: [UInt32] = []
            for i in 0..<count {
                palette.append(0xFF00_0000 | UInt32(pal[i * 3]) << 16 | UInt32(pal[i * 3 + 1]) << 8 | UInt32(pal[i * 3 + 2]))
            }
            let bpp = count <= 2 ? 1 : 8
            let rowBytes = (w * bpp + 7) / 8
            let data = try tightData(r, size: rowBytes * h, stream: streamId)
            var px = [UInt32](repeating: 0, count: w * h)
            for row in 0..<h {
                for col in 0..<w {
                    let idx: Int
                    if bpp == 1 {
                        let byte = data[row * rowBytes + col / 8]
                        idx = Int((byte >> UInt8(7 - col % 8)) & 1)
                    } else {
                        idx = Int(data[row * rowBytes + col])
                    }
                    px[row * w + col] = idx < count ? palette[idx] : 0xFF00_0000
                }
            }
            fb.put(x, y, w, h, px)
        case 2: // gradient
            let data = try tightData(r, size: w * h * 3, stream: streamId)
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for row in 0..<h {
                for col in 0..<w {
                    for c in 0..<3 {
                        let i = (row * w + col) * 3 + c
                        let left = col > 0 ? Int(rgb[i - 3]) : 0
                        let up = row > 0 ? Int(rgb[i - w * 3]) : 0
                        let upLeft = row > 0 && col > 0 ? Int(rgb[i - w * 3 - 3]) : 0
                        let predicted = max(0, min(255, left + up - upLeft))
                        rgb[i] = UInt8((predicted + Int(data[i])) & 0xff)
                    }
                }
            }
            var px = [UInt32](repeating: 0, count: w * h)
            for i in 0..<(w * h) {
                px[i] = 0xFF00_0000 | UInt32(rgb[i * 3]) << 16 | UInt32(rgb[i * 3 + 1]) << 8 | UInt32(rgb[i * 3 + 2])
            }
            fb.put(x, y, w, h, px)
        default:
            throw RFBDecodeError(description: "illegal Tight filter received (\(filter))")
        }
    }

    /// Under 12 bytes Tight sends data as is; otherwise a compact length and
    /// zlib data on the given stream.
    private func tightData(_ r: RFBReader, size: Int, stream: Int) throws -> [UInt8] {
        if size == 0 { return [] }
        if size < 12 { return try r.bytes(size) }
        let len = try r.compactLength()
        let compressed = try r.bytes(len)
        return try tightStreams[stream].inflateData(compressed, expected: size)
    }

    // MARK: Cursor

    private func cursor(_ r: RFBReader, hotX: Int, hotY: Int, w: Int, h: Int) throws -> RFBCursor {
        if w == 0 || h == 0 { return RFBCursor(width: 0, height: 0, hotX: hotX, hotY: hotY, rgba: []) }
        let pixels = try r.bytes(w * h * 4)
        let maskRow = (w + 7) / 8
        let mask = try r.bytes(maskRow * h)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let i = row * w + col
                let on = (mask[row * maskRow + col / 8] >> UInt8(7 - col % 8)) & 1 != 0
                // Our pixel format: B G R x in memory.
                rgba[i * 4] = pixels[i * 4 + 2]
                rgba[i * 4 + 1] = pixels[i * 4 + 1]
                rgba[i * 4 + 2] = pixels[i * 4]
                rgba[i * 4 + 3] = on ? 255 : 0
            }
        }
        return RFBCursor(width: w, height: h, hotX: hotX, hotY: hotY, rgba: rgba)
    }
}
