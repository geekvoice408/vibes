import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ServerLife

// The VNC client: DES for VNC Authentication against known vectors, every
// decoder against synthetic rectangles, and a handshake against a fake
// server on the loopback interface.

private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
private func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
/// A pixel in the format the client asks for: 32bpp little-endian, red at 16.
private func px(_ rgb: UInt32) -> [UInt8] { [UInt8(rgb & 0xff), UInt8((rgb >> 8) & 0xff), UInt8((rgb >> 16) & 0xff), 0] }
/// ZRLE's CPIXEL.
private func cpx(_ rgb: UInt32) -> [UInt8] { Array(px(rgb).prefix(3)) }
/// Tight's TPIXEL: R, G, B.
private func tpx(_ rgb: UInt32) -> [UInt8] { [UInt8((rgb >> 16) & 0xff), UInt8((rgb >> 8) & 0xff), UInt8(rgb & 0xff)] }
private func fbv(_ rgb: UInt32) -> UInt32 { 0xFF00_0000 | rgb }

private func compact(_ n: Int) -> [UInt8] {
    if n < 128 { return [UInt8(n)] }
    if n < 16384 { return [UInt8(n & 0x7f | 0x80), UInt8(n >> 7)] }
    return [UInt8(n & 0x7f | 0x80), UInt8((n >> 7) & 0x7f | 0x80), UInt8(n >> 14)]
}

private func decode(_ bytes: [UInt8], _ fb: RFBFramebuffer, _ d: RFBDecoders = RFBDecoders(),
                    x: Int = 0, y: Int = 0, w: Int, h: Int, enc: Int32) throws -> RFBRectResult {
    let r = RFBReader(bytes)
    let res = try d.decode(r, x: x, y: y, w: w, h: h, encoding: enc, fb: fb)
    #expect(r.buffered == 0, "the decoder read exactly its rectangle")
    return res
}

@Suite struct VNCAuthTests {
    @Test func desKnownVector() throws {
        // The classic worked example: K = 133457799BBCDFF1, M = 0123456789ABCDEF.
        let key: [UInt8] = [0x13, 0x34, 0x57, 0x79, 0x9B, 0xBC, 0xDF, 0xF1]
        let m: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        #expect(try VNCAuth.desECB(key: key, data: m) == [0x85, 0xE8, 0x13, 0x54, 0x0F, 0x0A, 0xB4, 0x05])
        // All-zero key and block (FIPS 81 style check value).
        #expect(try VNCAuth.desECB(key: [UInt8](repeating: 0, count: 8), data: [UInt8](repeating: 0, count: 8))
            == [0x8C, 0xA6, 0x4D, 0xE9, 0xC1, 0xB1, 0x23, 0xA7])
    }

    @Test func passwordBitsAreReversed() {
        #expect(VNCAuth.reverseBits(0x01) == 0x80)
        #expect(VNCAuth.reverseBits(0x13) == 0xC8)
        #expect(VNCAuth.key(from: "") == [UInt8](repeating: 0, count: 8))
        #expect(VNCAuth.key(from: "a") == [0x86, 0, 0, 0, 0, 0, 0, 0])
        #expect(VNCAuth.key(from: "12345678abc") == VNCAuth.key(from: "12345678"), "only eight characters count")
    }

    @Test func challengeResponse() throws {
        // A password whose bit-reversed bytes are the known DES key gives the
        // known ciphertext for each half of the challenge.
        let pw = String(String.UnicodeScalarView([0xC8, 0x2C, 0xEA, 0x9E, 0xD9, 0x3D, 0xFB, 0x8F].map { Unicode.Scalar($0) }))
        let m: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        let c: [UInt8] = [0x85, 0xE8, 0x13, 0x54, 0x0F, 0x0A, 0xB4, 0x05]
        #expect(try VNCAuth.response(challenge: m + m, password: pw) == c + c)
    }
}

@Suite struct RFBDecoderTests {
    @Test func raw() throws {
        let fb = RFBFramebuffer(width: 4, height: 4)
        let bytes = px(0xff0000) + px(0x00ff00) + px(0x0000ff) + px(0x123456)
        #expect(try decode(bytes, fb, x: 1, y: 1, w: 2, h: 2, enc: RFBEncoding.raw) == .pixels)
        #expect(fb.pixel(1, 1) == fbv(0xff0000))
        #expect(fb.pixel(2, 1) == fbv(0x00ff00))
        #expect(fb.pixel(1, 2) == fbv(0x0000ff))
        #expect(fb.pixel(2, 2) == fbv(0x123456))
        #expect(fb.pixel(0, 0) == 0xFF00_0000)
    }

    @Test func copyRect() throws {
        let fb = RFBFramebuffer(width: 4, height: 4)
        fb.fill(0, 0, 2, 2, fbv(0xabcdef))
        _ = try decode(be16(0) + be16(0), fb, x: 2, y: 1, w: 2, h: 2, enc: RFBEncoding.copyRect)
        #expect(fb.pixel(2, 1) == fbv(0xabcdef) && fb.pixel(3, 2) == fbv(0xabcdef))
        // Overlapping, shifted right by one.
        let o = RFBFramebuffer(width: 4, height: 1)
        o.put(0, 0, 3, 1, [1, 2, 3].map { fbv($0) })
        _ = try decode(be16(0) + be16(0), o, x: 1, y: 0, w: 3, h: 1, enc: RFBEncoding.copyRect)
        #expect((0..<4).map { o.pixel($0, 0) } == [1, 1, 2, 3].map { fbv($0) })
        // Overlapping vertically, shifted down.
        let v = RFBFramebuffer(width: 1, height: 3)
        v.put(0, 0, 1, 2, [7, 8].map { fbv($0) })
        _ = try decode(be16(0) + be16(0), v, x: 0, y: 1, w: 1, h: 2, enc: RFBEncoding.copyRect)
        #expect((0..<3).map { v.pixel(0, $0) } == [7, 7, 8].map { fbv($0) })
    }

    @Test func rre() throws {
        let fb = RFBFramebuffer(width: 6, height: 6)
        let bytes = be32(2) + px(0x111111) + px(0xff0000) + be16(1) + be16(1) + be16(2) + be16(1)
            + px(0x00ff00) + be16(0) + be16(3) + be16(1) + be16(1)
        _ = try decode(bytes, fb, x: 1, y: 1, w: 4, h: 4, enc: RFBEncoding.rre)
        #expect(fb.pixel(1, 1) == fbv(0x111111))
        #expect(fb.pixel(2, 2) == fbv(0xff0000) && fb.pixel(3, 2) == fbv(0xff0000))
        #expect(fb.pixel(1, 4) == fbv(0x00ff00))
        #expect(fb.pixel(0, 0) == 0xFF00_0000, "outside the rectangle is untouched")
    }

    @Test func hextile() throws {
        // 20×18: four tiles (16×16, 4×16, 16×2, 4×2).
        let fb = RFBFramebuffer(width: 20, height: 18)
        var b: [UInt8] = []
        // Tile 1: background + foreground + one plain subrect at (2,3) 4×5.
        b += [2 | 4 | 8] + px(0x000080) + px(0xffff00) + [1, 0x23, 0x34]
        // Tile 2: raw 4×16.
        b += [1] + (0..<(4 * 16)).flatMap { _ in px(0x00ff00) }
        // Tile 3: background carried over, coloured subrects.
        b += [8 | 16] + [2] + px(0xff0000) + [0x00, 0x00] + px(0x0000ff) + [0x11, 0x00]
        // Tile 4: new background only.
        b += [2] + px(0x808080)
        _ = try decode(b, fb, w: 20, h: 18, enc: RFBEncoding.hextile)
        #expect(fb.pixel(0, 0) == fbv(0x000080))
        #expect(fb.pixel(2, 3) == fbv(0xffff00) && fb.pixel(5, 7) == fbv(0xffff00))
        #expect(fb.pixel(6, 3) == fbv(0x000080))
        #expect(fb.pixel(17, 5) == fbv(0x00ff00))
        #expect(fb.pixel(0, 16) == fbv(0xff0000))
        #expect(fb.pixel(1, 17) == fbv(0x0000ff))
        #expect(fb.pixel(2, 16) == fbv(0x000080), "background persists from the previous tile")
        #expect(fb.pixel(19, 17) == fbv(0x808080))
    }

    @Test func zrleAllSubencodingsAndAPersistentStream() throws {
        let fb = RFBFramebuffer(width: 128, height: 70)
        let d = RFBDecoders()
        let z = RFBDeflater()
        // Rect 1: 128×64 → two tiles: solid, then a packed palette.
        var t: [UInt8] = []
        t += [1] + cpx(0x102030)                                    // tile 1: solid
        // tile 2: packed palette of 2 (1 bit per pixel), 64 wide → 8 bytes a row.
        t += [2] + cpx(0x000000) + cpx(0xffffff)
        for row in 0..<64 { t += (0..<8).map { _ in row % 2 == 0 ? 0xAA : 0x00 } }
        let c1 = z.deflateData(t)
        _ = try decode(be32(c1.count) + c1, fb, d, w: 128, h: 64, enc: RFBEncoding.zrle)
        #expect(fb.pixel(10, 10) == fbv(0x102030))
        #expect(fb.pixel(64, 0) == fbv(0xffffff) && fb.pixel(65, 0) == fbv(0x000000))
        #expect(fb.pixel(64, 1) == fbv(0x000000))

        // Rect 2 continues the same deflate stream: a raw 4×2 tile.
        let u: [UInt8] = [0] + (0..<8).flatMap { i in cpx(UInt32(i)) }
        let c2 = z.deflateData(u)
        _ = try decode(be32(c2.count) + c2, fb, d, y: 64, w: 4, h: 2, enc: RFBEncoding.zrle)
        #expect(fb.pixel(1, 64) == fbv(0x000001) && fb.pixel(3, 65) == fbv(0x000007))
    }

    @Test func zrleRunsAndPalettes() throws {
        let fb = RFBFramebuffer(width: 4, height: 2)
        let d = RFBDecoders()
        let z = RFBDeflater()
        let rle: [UInt8] = [128] + cpx(0xaa0000) + [2] + cpx(0x00bb00) + [4]
        var c = z.deflateData(rle)
        _ = try decode(be32(c.count) + c, fb, d, w: 4, h: 2, enc: RFBEncoding.zrle)
        #expect((0..<4).map { fb.pixel($0, 0) } == [0xaa0000, 0xaa0000, 0xaa0000, 0x00bb00].map(fbv))
        #expect(fb.pixel(3, 1) == fbv(0x00bb00))
        let prle: [UInt8] = [130] + cpx(0x111111) + cpx(0x222222) + [0x80, 5, 1, 0]
        c = z.deflateData(prle)
        _ = try decode(be32(c.count) + c, fb, d, w: 4, h: 2, enc: RFBEncoding.zrle)
        #expect(fb.pixel(1, 1) == fbv(0x111111) && fb.pixel(2, 1) == fbv(0x222222) && fb.pixel(3, 1) == fbv(0x111111))
        // Packed palette with 2 bits an index (3 colours).
        let pp: [UInt8] = [3] + cpx(0x0000ff) + cpx(0x00ff00) + cpx(0xff0000) + [0b00_01_10_00, 0b10_10_01_00]
        c = z.deflateData(pp)
        _ = try decode(be32(c.count) + c, fb, d, w: 4, h: 2, enc: RFBEncoding.zrle)
        #expect((0..<4).map { fb.pixel($0, 0) } == [0x0000ff, 0x00ff00, 0xff0000, 0x0000ff].map(fbv))
        #expect((0..<4).map { fb.pixel($0, 1) } == [0xff0000, 0xff0000, 0x00ff00, 0x0000ff].map(fbv))
        // Raw tile, with a long run length elsewhere checked by count.
        let raw: [UInt8] = [0] + (0..<8).flatMap { cpx(UInt32($0 * 16)) }
        c = z.deflateData(raw)
        _ = try decode(be32(c.count) + c, fb, d, w: 4, h: 2, enc: RFBEncoding.zrle)
        #expect(fb.pixel(3, 1) == fbv(0x70))
    }

    @Test func tightFillCopyPaletteGradient() throws {
        let d = RFBDecoders()
        let fb = RFBFramebuffer(width: 8, height: 8)
        // Fill.
        _ = try decode([0x80] + tpx(0x336699), fb, d, w: 8, h: 8, enc: RFBEncoding.tight)
        #expect(fb.pixel(7, 7) == fbv(0x336699))

        // Basic copy, under 12 bytes: sent as is (2×1 → 6 bytes), stream 0, no filter byte.
        _ = try decode([0x00] + tpx(0xff0000) + tpx(0x0000ff), fb, d, w: 2, h: 1, enc: RFBEncoding.tight)
        #expect(fb.pixel(0, 0) == fbv(0xff0000) && fb.pixel(1, 0) == fbv(0x0000ff))

        // Basic copy, compressed on stream 1, with an explicit copy filter.
        let z1 = RFBDeflater()
        let data = (0..<16).flatMap { tpx(UInt32($0) * 0x010101) }
        let c = z1.deflateData(data)
        _ = try decode([0x50, 0] + compact(c.count) + c, fb, d, x: 4, y: 4, w: 4, h: 4, enc: RFBEncoding.tight)
        #expect(fb.pixel(4, 4) == fbv(0) && fb.pixel(7, 7) == fbv(0x0f0f0f))

        // Palette, two colours → 1 bit a pixel (rows padded to a byte); 8×2 = 2 bytes: raw.
        _ = try decode([0x40, 1, 1] + tpx(0x000000) + tpx(0xffffff) + [0b1010_0000, 0b0000_0001],
                       fb, d, w: 8, h: 2, enc: RFBEncoding.tight)
        #expect(fb.pixel(0, 0) == fbv(0xffffff) && fb.pixel(1, 0) == fbv(0) && fb.pixel(2, 0) == fbv(0xffffff))
        #expect(fb.pixel(7, 1) == fbv(0xffffff) && fb.pixel(6, 1) == fbv(0))

        // Palette, three colours → a byte a pixel; 4×4 = 16 bytes: compressed on stream 2.
        let z2 = RFBDeflater()
        let idx: [UInt8] = (0..<16).map { UInt8($0 % 3) }
        let c2 = z2.deflateData(idx)
        _ = try decode([0x60, 1, 2] + tpx(0x110000) + tpx(0x002200) + tpx(0x000033) + compact(c2.count) + c2,
                       fb, d, w: 4, h: 4, enc: RFBEncoding.tight)
        #expect(fb.pixel(0, 0) == fbv(0x110000) && fb.pixel(1, 0) == fbv(0x002200) && fb.pixel(2, 0) == fbv(0x000033))
        #expect(fb.pixel(3, 3) == fbv(0x110000))  // index 15 % 3 = 0

        // Gradient: a flat colour encodes as the colour in the first pixel and zero differences
        // except along the first row/column.
        let w = 3, h = 2
        let target: [[UInt8]] = Array(repeating: [10, 20, 30], count: w * h)
        var diffs: [UInt8] = []
        for row in 0..<h {
            for col in 0..<w {
                for ch in 0..<3 {
                    let left = col > 0 ? Int(target[row * w + col - 1][ch]) : 0
                    let up = row > 0 ? Int(target[(row - 1) * w + col][ch]) : 0
                    let ul = row > 0 && col > 0 ? Int(target[(row - 1) * w + col - 1][ch]) : 0
                    let pred = max(0, min(255, left + up - ul))
                    diffs.append(UInt8((Int(target[row * w + col][ch]) - pred) & 0xff))
                }
            }
        }
        let z3 = RFBDeflater()
        let c3 = z3.deflateData(diffs)
        _ = try decode([0x70, 2] + compact(c3.count) + c3, fb, d, w: w, h: h, enc: RFBEncoding.tight)
        #expect(fb.pixel(0, 0) == fbv(0x0a141e) && fb.pixel(2, 1) == fbv(0x0a141e))
    }

    @Test func tightStreamsPersistAndReset() throws {
        let d = RFBDecoders()
        let fb = RFBFramebuffer(width: 4, height: 4)
        let z = RFBDeflater()
        let a = z.deflateData((0..<16).flatMap { _ in tpx(0x010203) })
        _ = try decode([0x00] + compact(a.count) + a, fb, d, w: 4, h: 4, enc: RFBEncoding.tight)
        // The same deflate stream continues: only works if the inflater kept its state.
        let b = z.deflateData((0..<16).flatMap { _ in tpx(0x040506) })
        _ = try decode([0x00] + compact(b.count) + b, fb, d, w: 4, h: 4, enc: RFBEncoding.tight)
        #expect(fb.pixel(3, 3) == fbv(0x040506))
        // A fresh server stream with the reset bit for stream 0.
        let z2 = RFBDeflater()
        let c = z2.deflateData((0..<16).flatMap { _ in tpx(0x070809) })
        _ = try decode([0x01] + compact(c.count) + c, fb, d, w: 4, h: 4, enc: RFBEncoding.tight)
        #expect(fb.pixel(0, 0) == fbv(0x070809))
    }

    @Test func tightJPEG() throws {
        // A solid 8×8 JPEG, made here with ImageIO.
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let jpeg = [UInt8](out as Data)
        let fb = RFBFramebuffer(width: 16, height: 16)
        _ = try decode([0x90] + compact(jpeg.count) + jpeg, fb, x: 8, y: 0, w: 8, h: 8, enc: RFBEncoding.tight)
        let p = fb.pixel(12, 4)
        let r = Int((p >> 16) & 0xff), g = Int((p >> 8) & 0xff), b = Int(p & 0xff)
        #expect(r < 20 && abs(g - 128) < 20 && b > 235, "drawn in the right place, right way up")
        #expect(fb.pixel(4, 4) == 0xFF00_0000, "nothing outside the rectangle")
    }

    @Test func tightRejectsWhatWasNotAskedFor() {
        let fb = RFBFramebuffer(width: 2, height: 2)
        #expect(throws: RFBDecodeError.self) { _ = try decode([0xA0, 0], fb, w: 2, h: 2, enc: RFBEncoding.tight) }
        #expect(throws: RFBDecodeError.self) { _ = try decode([0xF0], fb, w: 2, h: 2, enc: RFBEncoding.tight) }
    }

    @Test func pseudoEncodings() throws {
        let fb = RFBFramebuffer(width: 2, height: 2)
        // Cursor 2×2: top-left visible red, the rest masked out.
        let cur = px(0xff0000) + px(0x00ff00) + px(0x0000ff) + px(0xffffff) + [0b1000_0000, 0b0100_0000]
        let res = try decode(cur, fb, x: 1, y: 0, w: 2, h: 2, enc: RFBEncoding.cursor)
        guard case .cursor(let c) = res else { Issue.record("not a cursor"); return }
        #expect(c.hotX == 1 && c.hotY == 0)
        #expect(Array(c.rgba[0..<4]) == [255, 0, 0, 255])
        #expect(c.rgba[7] == 0 && c.rgba[15] == 255)
        #expect(!c.isEmpty)
        #expect(try decode([], fb, w: 0, h: 0, enc: RFBEncoding.cursor) == .cursor(RFBCursor(width: 0, height: 0, hotX: 0, hotY: 0, rgba: [])))

        #expect(try decode([], fb, w: 800, h: 600, enc: RFBEncoding.desktopSize) == .desktopSize(width: 800, height: 600))
        #expect(try decode([], fb, w: 0, h: 0, enc: RFBEncoding.lastRect) == .lastRect)
        let ext = [1, 0, 0, 0] + be32(7) + be16(0) + be16(0) + be16(1024) + be16(768) + be32(0)
        #expect(try decode(ext, fb, x: 1, y: 0, w: 1024, h: 768, enc: RFBEncoding.extendedDesktopSize)
            == .extendedDesktopSize(width: 1024, height: 768, reason: 1, status: 0,
                                    screens: [RFBScreen(id: 7, x: 0, y: 0, width: 1024, height: 768, flags: 0)]))
    }

    @Test func framebufferResizeKeepsWhatFits() {
        let fb = RFBFramebuffer(width: 2, height: 2)
        fb.fill(0, 0, 2, 2, fbv(0x123456))
        fb.resize(width: 3, height: 1)
        #expect(fb.width == 3 && fb.height == 1)
        #expect(fb.pixel(1, 0) == fbv(0x123456) && fb.pixel(2, 0) == 0xFF00_0000)
        #expect(fb.makeImage()?.width == 3)
        // Out-of-range rectangles are clipped, not written past the end.
        fb.fill(-5, -5, 100, 100, fbv(1))
        fb.put(2, 0, 4, 4, [UInt32](repeating: fbv(2), count: 16))
        #expect(fb.pixel(2, 0) == fbv(2) && fb.pixel(0, 0) == fbv(1))
    }

    @Test func clientMessages() {
        #expect(RFBMessages.setPixelFormat32() == [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        #expect(RFBMessages.key(0xffe3, down: true) == [4, 1, 0, 0, 0, 0, 0xff, 0xe3])
        #expect(RFBMessages.pointer(x: 300, y: 2, mask: 9) == [5, 9, 1, 44, 0, 2])
        #expect(RFBMessages.cutText("hé") == [6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0xe9])
        #expect(RFBMessages.updateRequest(incremental: true, x: 0, y: 0, w: 640, h: 480) == [3, 1, 0, 0, 0, 0, 2, 128, 1, 224])
        let enc = RFBMessages.setEncodings([RFBEncoding.tight, RFBEncoding.quality(6), RFBEncoding.compression(2)])
        #expect(enc == [2, 0, 0, 3, 0, 0, 0, 7, 0xff, 0xff, 0xff, 0xe6, 0xff, 0xff, 0xff, 0x02])
        let sds = RFBMessages.setDesktopSize(width: 1280, height: 800, screenId: 1, flags: 0)
        #expect(sds.count == 24 && sds[0] == 251 && Array(sds[2..<6]) == [5, 0, 3, 32] && sds[6] == 1)
        #expect(RFBClient.encodings(.init()).contains(RFBEncoding.quality(6)))
        #expect(RFBClient.encodings(.init()).first == RFBEncoding.copyRect)
    }

    @Test func versionNegotiation() {
        #expect(RFBClient.negotiatedVersion("RFB 003.003\n") == "003.003")
        #expect(RFBClient.negotiatedVersion("RFB 003.006\n") == "003.003")
        #expect(RFBClient.negotiatedVersion("RFB 003.007\n") == "003.007")
        #expect(RFBClient.negotiatedVersion("RFB 003.008\n") == "003.008")
        #expect(RFBClient.negotiatedVersion("RFB 003.889\n") == "003.008")
        #expect(RFBClient.negotiatedVersion("RFB 004.001\n") == "003.008")
        #expect(RFBClient.negotiatedVersion("HTTP/1.1 400") == nil)
    }

    @Test func keysyms() {
        #expect(VNCKeys.keysym(for: "a") == 0x61)
        #expect(VNCKeys.keysym(for: "é") == 0xe9)
        #expect(VNCKeys.keysym(for: "€") == 0x0100_20ac)
        #expect(VNCKeys.keysym(for: "\r") == VNCKeys.returnKey)
        #expect(VNCKeys.byKeyCode[0x7E] == VNCKeys.up)
        #expect(VNCKeys.byKeyCode[0x7A] == 0xffbe)
        #expect(VNCKeys.modifiers[0x37]?.keysym == VNCKeys.superL)
    }
}

/// Handshakes against a fake server.
@Suite(.serialized) struct RFBHandshakeTests {
    private final class Box: @unchecked Sendable {
        var events: [RFBEvent] = []
    }

    /// Run a client against `script` (the server side) and collect events until a terminal one.
    @MainActor
    private func run(password: String? = nil, provider: (() -> String?)? = nil,
                     script: @escaping @Sendable (LoopbackServer.Conn) throws -> Void) async throws -> ([RFBEvent], RFBClient) {
        let server = try LoopbackServer()
        let t = Task.detached { let c = try server.accept(); try script(c); try await Task.sleep(nanoseconds: 300_000_000); _ = c }
        let client = RFBClient(host: "127.0.0.1", port: server.port, password: password)
        client.passwordProvider = provider
        let box = Box()
        client.onEvent = { box.events.append($0) }
        client.start()
        for _ in 0..<200 {
            if box.events.contains(where: {
                switch $0 { case .failed, .ended, .closed: return true; case .damage: return true; default: return false }
            }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        _ = try? await t.value
        return (box.events, client)
    }

    @MainActor @Test func vncAuthThenAFrame() async throws {
        let challenge: [UInt8] = (0..<16).map { UInt8($0 * 7) }
        let expected = try VNCAuth.response(challenge: challenge, password: "secret")
        let (events, client) = try await run(password: "secret") { c in
            try c.send(Array("RFB 003.008\n".utf8))
            #expect(try c.recv(exactly: 12) == Array("RFB 003.008\n".utf8))
            try c.send([2, 30, 2])                          // Apple DH and VNC auth: we pick 2
            #expect(try c.recv(exactly: 1) == [2])
            try c.send(challenge)
            #expect(try c.recv(exactly: 16) == expected)
            try c.send(be32(0))                             // SecurityResult OK
            #expect(try c.recv(exactly: 1) == [1])          // shared
            try c.send(be16(4) + be16(2) + [UInt8](repeating: 0, count: 16) + be32(4) + Array("desk".utf8))
            let pf = try c.recv(exactly: 20)
            #expect(pf == RFBMessages.setPixelFormat32())
            let head = try c.recv(exactly: 4)
            #expect(head[0] == 2)
            _ = try c.recv(exactly: (Int(head[2]) << 8 | Int(head[3])) * 4)
            #expect(try c.recv(exactly: 10) == RFBMessages.updateRequest(incremental: false, x: 0, y: 0, w: 4, h: 2))
            // ServerCutText, then one Raw rectangle.
            try c.send([3, 0, 0, 0] + be32(5) + Array("hello".utf8))
            try c.send([0, 0] + be16(1) + be16(0) + be16(0) + be16(2) + be16(1) + be32(0) + px(0xff8800) + px(0x0088ff))
            #expect(try c.recv(exactly: 10) == RFBMessages.updateRequest(incremental: true, x: 0, y: 0, w: 4, h: 2))
        }
        #expect(events.contains { if case .authenticating = $0 { return true }; return false })
        #expect(events.contains { if case .connected(4, 2, "desk") = $0 { return true }; return false })
        #expect(events.contains { if case .clipboard("hello") = $0 { return true }; return false })
        #expect(events.contains { if case .damage = $0 { return true }; return false })
        #expect(client.framebuffer.pixel(0, 0) == fbv(0xff8800))
        #expect(client.framebuffer.pixel(1, 0) == fbv(0x0088ff))
        client.stop()
    }

    @MainActor @Test func wrongPasswordSaysWhatTheServerSaid() async throws {
        let (events, _) = try await run(password: "nope") { c in
            try c.send(Array("RFB 003.008\n".utf8)); _ = try c.recv(exactly: 12)
            try c.send([1, 2]); _ = try c.recv(exactly: 1)
            try c.send([UInt8](repeating: 1, count: 16)); _ = try c.recv(exactly: 16)
            try c.send(be32(1) + be32(21) + Array("Authentication failed".utf8))
        }
        #expect(events.contains { if case .failed("Authentication failed") = $0 { return true }; return false })
    }

    @MainActor @Test func version33NoAuthAndOldFailure() async throws {
        let (events, _) = try await run(provider: { "pw" }) { c in
            try c.send(Array("RFB 003.003\n".utf8))
            #expect(try c.recv(exactly: 12) == Array("RFB 003.003\n".utf8))
            try c.send(be32(2))                              // VNC auth, chosen by the server
            try c.send([UInt8](repeating: 0, count: 16)); _ = try c.recv(exactly: 16)
            try c.send(be32(1))                              // failed, no reason in 3.3
        }
        #expect(events.contains { if case .failed("Authentication failure") = $0 { return true }; return false })
    }

    @MainActor @Test func cancellingThePasswordCloses() async throws {
        let (events, _) = try await run(provider: { nil }) { c in
            try c.send(Array("RFB 003.007\n".utf8)); _ = try c.recv(exactly: 12)
            try c.send([1, 2]); _ = try c.recv(exactly: 1)
            try c.send([UInt8](repeating: 0, count: 16))
        }
        #expect(events.contains { if case .closed = $0 { return true }; return false })
    }

    @MainActor @Test func macOnlyAuthenticationIsExplained() async throws {
        let (events, _) = try await run { c in
            try c.send(Array("RFB 003.889\n".utf8)); _ = try c.recv(exactly: 12)
            try c.send([2, 30, 33])
        }
        let msg = events.compactMap { if case .failed(let m) = $0 { return m }; return nil }.first ?? ""
        #expect(msg.contains("types: 30, 33"))
        #expect(msg.contains("VNC viewers may control screen with password"))
    }

    @MainActor @Test func notAVNCServer() async throws {
        let (events, _) = try await run { c in try c.send(Array("HTTP/1.1 400 Bad Request\r\n".utf8)) }
        let msg = events.compactMap { if case .failed(let m) = $0 { return m }; return nil }.first ?? ""
        #expect(msg.hasPrefix("this is not a VNC server"))
    }

    @MainActor @Test func refusedConnection() async throws {
        let port = (try? LoopbackServer().port) ?? 1
        let client = RFBClient(host: "127.0.0.1", port: port, password: nil)
        let box = Box()
        client.onEvent = { box.events.append($0) }
        client.start()
        for _ in 0..<100 where box.events.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let msg = box.events.compactMap { if case .failed(let m) = $0 { return m }; return nil }.first
        #expect(msg == "the connection was refused — nothing is listening on port \(port)")
    }

    @MainActor @Test func serverClosingARunningSessionEndsIt() async throws {
        let (events, _) = try await run { c in
            try c.send(Array("RFB 003.008\n".utf8)); _ = try c.recv(exactly: 12)
            try c.send([1, 1]); _ = try c.recv(exactly: 1)
            try c.send(be32(0)); _ = try c.recv(exactly: 1)
            try c.send(be16(2) + be16(2) + [UInt8](repeating: 0, count: 16) + be32(0))
            // Read what the client sends, so the close is a FIN and not a reset.
            _ = try c.recv(exactly: 20)
            let head = try c.recv(exactly: 4)
            _ = try c.recv(exactly: (Int(head[2]) << 8 | Int(head[3])) * 4 + 10)
        }
        #expect(events.contains { if case .connected = $0 { return true }; return false })
        #expect(events.contains { if case .ended("the server closed the session") = $0 { return true }; return false })
    }
}
