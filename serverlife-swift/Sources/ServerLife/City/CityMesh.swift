import AppKit
import SceneKit
import simd

/*
 * The handful of three.js primitives the city is built from, as SceneKit
 * geometry: same parameters, same vertex layout and the same UVs, so the
 * architecture code ports line for line and the window tile keeps its size.
 *
 * UVs are kept in three.js's convention (v up) while building and flipped
 * once when the geometry is made, because SceneKit's textures have v down.
 */

typealias V3 = SIMD3<Float>

struct CityMesh {
    var pos: [V3] = []
    var nrm: [V3] = []
    var uv: [SIMD2<Float>] = []
    var idx: [UInt32] = []

    // MARK: transforms

    mutating func apply(_ m: simd_float3x3) {
        pos = pos.map { m * $0 }
        nrm = nrm.map { simd_normalize(m * $0) }
    }
    mutating func rotateX(_ a: Float) { apply(simd_float3x3(simd_quatf(angle: a, axis: [1, 0, 0]))) }
    mutating func rotateY(_ a: Float) { apply(simd_float3x3(simd_quatf(angle: a, axis: [0, 1, 0]))) }
    mutating func rotateZ(_ a: Float) { apply(simd_float3x3(simd_quatf(angle: a, axis: [0, 0, 1]))) }
    mutating func translate(_ x: Float, _ y: Float, _ z: Float) { pos = pos.map { $0 + V3(x, y, z) } }

    mutating func append(_ o: CityMesh) {
        let base = UInt32(pos.count)
        pos += o.pos; nrm += o.nrm; uv += o.uv
        idx += o.idx.map { $0 + base }
    }

    /// Per-vertex normals from the faces (after the vertices moved).
    mutating func computeNormals() {
        var n = [V3](repeating: .zero, count: pos.count)
        var i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            let fn = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
            n[a] += fn; n[b] += fn; n[c] += fn
            i += 3
        }
        nrm = n.map { simd_length($0) > 1e-9 ? simd_normalize($0) : V3(0, 1, 0) }
    }

    func geometry() -> SCNGeometry {
        let vs = SCNGeometrySource(vertices: pos.map { SCNVector3($0) })
        let ns = SCNGeometrySource(normals: nrm.map { SCNVector3($0) })
        let ts = SCNGeometrySource(textureCoordinates: uv.map { CGPoint(x: CGFloat($0.x), y: CGFloat(1 - $0.y)) })
        let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        return SCNGeometry(sources: [vs, ns, ts], elements: [el])
    }

    // MARK: primitives (three.js parameters)

    /// BoxGeometry, faces +x, -x, +y, -y, +z, -z, four vertices each.
    static func box(_ width: Float, _ height: Float, _ depth: Float) -> CityMesh {
        var m = CityMesh()
        func plane(_ u: Int, _ v: Int, _ w: Int, _ udir: Float, _ vdir: Float, _ pw: Float, _ ph: Float, _ pd: Float) {
            let base = UInt32(m.pos.count)
            for iy in 0...1 {
                let y = Float(iy) * ph - ph / 2
                for ix in 0...1 {
                    let x = Float(ix) * pw - pw / 2
                    var p = V3.zero
                    p[u] = x * udir; p[v] = y * vdir; p[w] = pd / 2
                    var n = V3.zero
                    n[w] = pd > 0 ? 1 : -1
                    m.pos.append(p); m.nrm.append(n)
                    m.uv.append(SIMD2(Float(ix), 1 - Float(iy)))
                }
            }
            let a = base, b = base + 2, c = base + 3, d = base + 1
            m.idx += [a, b, d, b, c, d]
        }
        plane(2, 1, 0, -1, -1, depth, height, width)
        plane(2, 1, 0, 1, -1, depth, height, -width)
        plane(0, 2, 1, 1, 1, width, depth, height)
        plane(0, 2, 1, 1, -1, width, depth, -height)
        plane(0, 1, 2, 1, -1, width, height, depth)
        plane(0, 1, 2, -1, -1, width, height, -depth)
        return m
    }

    /// CylinderGeometry (a cone when `rTop` is 0); torso vertices come first.
    static func cylinder(_ rTop: Float, _ rBot: Float, _ height: Float, _ radial: Int, heightSegs: Int = 1,
                         open: Bool = false, thetaStart: Float = 0, thetaLength: Float = .pi * 2) -> CityMesh {
        var m = CityMesh()
        let half = height / 2
        let slope = height != 0 ? (rBot - rTop) / height : 0
        var grid: [[UInt32]] = []
        for y in 0...heightSegs {
            var row: [UInt32] = []
            let v = Float(y) / Float(heightSegs)
            let r = v * (rBot - rTop) + rTop
            for x in 0...radial {
                let u = Float(x) / Float(radial)
                let th = u * thetaLength + thetaStart
                let s = sin(th), c = cos(th)
                m.pos.append(V3(r * s, -v * height + half, r * c))
                m.nrm.append(simd_normalize(V3(s, slope, c)))
                m.uv.append(SIMD2(u, 1 - v))
                row.append(UInt32(m.pos.count - 1))
            }
            grid.append(row)
        }
        for x in 0..<radial {
            for y in 0..<heightSegs {
                let a = grid[y][x], b = grid[y + 1][x], c = grid[y + 1][x + 1], d = grid[y][x + 1]
                if rTop > 0 || y != 0 { m.idx += [a, b, d] }
                if rBot > 0 || y != heightSegs - 1 { m.idx += [b, c, d] }
            }
        }
        if !open {
            for top in [true, false] {
                let r = top ? rTop : rBot
                if r <= 0 { continue }
                let sign: Float = top ? 1 : -1
                let centerStart = UInt32(m.pos.count)
                for x in 1...radial {
                    m.pos.append(V3(0, half * sign, 0)); m.nrm.append(V3(0, sign, 0)); m.uv.append(SIMD2(0.5, 0.5))
                    _ = x
                }
                let ringStart = UInt32(m.pos.count)
                for x in 0...radial {
                    let u = Float(x) / Float(radial)
                    let th = u * thetaLength + thetaStart
                    let c = cos(th), s = sin(th)
                    m.pos.append(V3(r * s, half * sign, r * c)); m.nrm.append(V3(0, sign, 0))
                    m.uv.append(SIMD2(c * 0.5 + 0.5, s * 0.5 * sign + 0.5))
                }
                for x in 0..<radial {
                    let c = centerStart + UInt32(x), i = ringStart + UInt32(x)
                    if top { m.idx += [i, i + 1, c] } else { m.idx += [i + 1, i, c] }
                }
            }
        }
        return m
    }

    static func cone(_ r: Float, _ height: Float, _ radial: Int, open: Bool = false) -> CityMesh {
        cylinder(0, r, height, radial, open: open)
    }

    /// SphereGeometry with three.js's phi (around y) and theta (from the top) ranges.
    static func sphere(_ r: Float, _ wSeg: Int, _ hSeg: Int, phiStart: Float = 0, phiLength: Float = .pi * 2,
                       thetaStart: Float = 0, thetaLength: Float = .pi) -> CityMesh {
        var m = CityMesh()
        let thetaEnd = min(thetaStart + thetaLength, .pi)
        var grid: [[UInt32]] = []
        for iy in 0...hSeg {
            var row: [UInt32] = []
            let v = Float(iy) / Float(hSeg)
            for ix in 0...wSeg {
                let u = Float(ix) / Float(wSeg)
                let p = V3(-r * cos(phiStart + u * phiLength) * sin(thetaStart + v * thetaLength),
                           r * cos(thetaStart + v * thetaLength),
                           r * sin(phiStart + u * phiLength) * sin(thetaStart + v * thetaLength))
                m.pos.append(p)
                m.nrm.append(simd_length(p) > 0 ? simd_normalize(p) : V3(0, 1, 0))
                m.uv.append(SIMD2(u, 1 - v))
                row.append(UInt32(m.pos.count - 1))
            }
            grid.append(row)
        }
        for iy in 0..<hSeg {
            for ix in 0..<wSeg {
                let a = grid[iy][ix + 1], b = grid[iy][ix], c = grid[iy + 1][ix], d = grid[iy + 1][ix + 1]
                if iy != 0 || thetaStart > 0 { m.idx += [a, b, d] }
                if iy != hSeg - 1 || thetaEnd < .pi { m.idx += [b, c, d] }
            }
        }
        return m
    }

    /// TorusGeometry in the xy plane (as three.js), with an optional arc.
    static func torus(_ radius: Float, _ tube: Float, _ radialSeg: Int, _ tubularSeg: Int, arc: Float = .pi * 2) -> CityMesh {
        var m = CityMesh()
        for j in 0...radialSeg {
            for i in 0...tubularSeg {
                let u = Float(i) / Float(tubularSeg) * arc
                let v = Float(j) / Float(radialSeg) * .pi * 2
                let p = V3((radius + tube * cos(v)) * cos(u), (radius + tube * cos(v)) * sin(u), tube * sin(v))
                let center = V3(radius * cos(u), radius * sin(u), 0)
                m.pos.append(p)
                m.nrm.append(simd_normalize(p - center))
                m.uv.append(SIMD2(Float(i) / Float(tubularSeg), Float(j) / Float(radialSeg)))
            }
        }
        let row = UInt32(tubularSeg + 1)
        for j in 1...radialSeg {
            for i in 1...tubularSeg {
                let a = row * UInt32(j) + UInt32(i) - 1
                let b = row * UInt32(j - 1) + UInt32(i) - 1
                let c = row * UInt32(j - 1) + UInt32(i)
                let d = row * UInt32(j) + UInt32(i)
                m.idx += [a, b, d, b, c, d]
            }
        }
        return m
    }

    /// PlaneGeometry in the xy plane facing +z.
    static func plane(_ w: Float, _ h: Float, _ ws: Int = 1, _ hs: Int = 1) -> CityMesh {
        var m = CityMesh()
        for iy in 0...hs {
            let y = Float(iy) * h / Float(hs) - h / 2
            for ix in 0...ws {
                let x = Float(ix) * w / Float(ws) - w / 2
                m.pos.append(V3(x, -y, 0)); m.nrm.append(V3(0, 0, 1))
                m.uv.append(SIMD2(Float(ix) / Float(ws), 1 - Float(iy) / Float(hs)))
            }
        }
        let gx = UInt32(ws + 1)
        for iy in 0..<UInt32(hs) {
            for ix in 0..<UInt32(ws) {
                let a = ix + gx * iy, b = ix + gx * (iy + 1), c = ix + 1 + gx * (iy + 1), d = ix + 1 + gx * iy
                m.idx += [a, b, d, b, c, d]
            }
        }
        return m
    }

    /// CircleGeometry: a disc in the xy plane facing +z.
    static func circle(_ r: Float, _ segs: Int) -> CityMesh {
        var m = CityMesh()
        m.pos.append(.zero); m.nrm.append(V3(0, 0, 1)); m.uv.append(SIMD2(0.5, 0.5))
        for s in 0...segs {
            let a = Float(s) / Float(segs) * .pi * 2
            m.pos.append(V3(r * cos(a), r * sin(a), 0)); m.nrm.append(V3(0, 0, 1))
            m.uv.append(SIMD2(cos(a) * 0.5 + 0.5, sin(a) * 0.5 + 0.5))
        }
        for i in 1...UInt32(segs) { m.idx += [i, i + 1, 0] }
        return m
    }

    /// An extruded triangle `w` wide and `h` high, `len` long (z from -len/2): a gable.
    static func prism(_ w: Float, _ h: Float, _ len: Float) -> CityMesh {
        var m = CityMesh()
        let z0 = -len / 2, z1 = len / 2
        let a = V3(-w / 2, 0, 0), b = V3(w / 2, 0, 0), c = V3(0, h, 0)
        func tri(_ p: [V3], _ n: V3) {
            let base = UInt32(m.pos.count)
            for q in p { m.pos.append(q); m.nrm.append(n); m.uv.append(SIMD2(0.01, 0.01)) }
            m.idx += [base, base + 1, base + 2]
        }
        func quad(_ p: [V3]) {
            let n = simd_normalize(simd_cross(p[1] - p[0], p[2] - p[0]))
            let base = UInt32(m.pos.count)
            for q in p { m.pos.append(q); m.nrm.append(n); m.uv.append(SIMD2(0.01, 0.01)) }
            m.idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let zf = V3(0, 0, z1), zb = V3(0, 0, z0)
        tri([a + zf, b + zf, c + zf], V3(0, 0, 1))
        tri([b + zb, a + zb, c + zb], V3(0, 0, -1))
        quad([a + zb, b + zb, b + zf, a + zf])          // floor
        quad([b + zb, c + zb, c + zf, b + zf])          // right slope
        quad([c + zb, a + zb, a + zf, c + zf])          // left slope
        return m
    }
}

// MARK: - Nodes and materials

/// A node that can carry what it stands for, so a hit anywhere inside a
/// building, a crate or a bird finds the thing it belongs to.
final class CityNode: SCNNode {
    var item: CityItem?
}

/// What hit tests look for (`pickables` in city3d.js).
let cityPickMask = 2

extension SCNNode {
    static func mesh(_ m: CityMesh, _ mat: SCNMaterial, shadow: Bool = true) -> SCNNode {
        let g = m.geometry()
        g.materials = [mat]
        let n = SCNNode(geometry: g)
        n.castsShadow = shadow
        return n
    }

    func at(_ x: Float, _ y: Float, _ z: Float) -> Self {
        simdPosition = V3(x, y, z)
        return self
    }

    /// Mark every geometry node under (and including) this one as pickable.
    func markPickable() {
        enumerateHierarchy { n, _ in if n.geometry != nil { n.categoryBitMask |= cityPickMask } }
        if geometry != nil { categoryBitMask |= cityPickMask }
    }

    /// Rotation about y only (three.js `rotation.y`).
    var yaw: Float {
        get { eulerAngles.y.f }
        set { simdOrientation = simd_quatf(angle: newValue, axis: [0, 1, 0]) }
    }
}

extension CGFloat { var f: Float { Float(self) } }
extension Double { var f: Float { Float(self) } }

/// Colours as the original wrote them: 0xrrggbb.
func cityColor(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func cityCSS(_ hex: Int) -> String { String(format: "#%06x", hex) }

enum CityMat {
    /// MeshStandardMaterial.
    static func std(_ color: Int, roughness: CGFloat = 0.6, metalness: CGFloat = 0, emissive: Int = 0,
                    emissiveIntensity: CGFloat = 1, doubleSided: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = cityColor(color)
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        if emissive != 0 && emissiveIntensity > 0 {
            m.emission.contents = cityColor(emissive)
            m.emission.intensity = emissiveIntensity
        }
        m.isDoubleSided = doubleSided
        return m
    }

    /// MeshLambertMaterial.
    static func lambert(_ color: Int, doubleSided: Bool = false, transparent: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = cityColor(color)
        m.isDoubleSided = doubleSided
        if transparent { m.writesToDepthBuffer = false }
        return m
    }

    /// MeshBasicMaterial: unlit.
    static func basic(_ color: Int, opacity: CGFloat = 1, additive: Bool = false, doubleSided: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = cityColor(color)
        m.isDoubleSided = doubleSided
        if opacity < 1 || additive {
            m.transparency = opacity
            m.writesToDepthBuffer = false
        }
        if additive { m.blendMode = .add }
        return m
    }
}

// MARK: - Textures

enum CityTextures {
    /// Draw into a fresh RGBA image, y down (canvas coordinates).
    static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()
    }

    static func rgb(_ hex: Int) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255)
    }
}

/// Windows: a tile of 4×4 with a random few lit. The colour map is white
/// walls and dark glass, so the material colour paints the wall; the
/// emissive map is only the lit panes, so the city lights up at night and not
/// in the day.
///
/// SceneKit has no "colour × map", so the wall colour is baked into a copy of
/// the map per colour (there are a dozen).
@MainActor
final class CityWindowTextures {
    let n = 4, size = 128
    private var lit: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, warm: Bool)] = []
    private var panes: [CGRect] = []
    private var byColor: [Int: CGImage] = [:]
    private(set) var emissive: CGImage?

    init() {
        let cell = CGFloat(size / n)
        for i in 0..<n {
            for j in 0..<n {
                let r = CGRect(x: CGFloat(i) * cell + cell * 0.22, y: CGFloat(j) * cell + cell * 0.18,
                               width: cell * 0.56, height: cell * 0.62)
                panes.append(r)
                if Double.random(in: 0..<1) < 0.55 {
                    lit.append((r.minX, r.minY, r.width, r.height, Double.random(in: 0..<1) < 0.5))
                }
            }
        }
        // Lit panes, already the colour of the night glow (emissive 0xffcf7a × map).
        emissive = CityTextures.draw(size, size) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let glow = CityTextures.rgb(0xffcf7a)
            for l in lit {
                let c = CityTextures.rgb(l.warm ? 0xffd98a : 0xfff1c9)
                ctx.setFillColor(CGColor(srgbRed: c.0 * glow.0, green: c.1 * glow.1, blue: c.2 * glow.2, alpha: 1))
                ctx.fill(CGRect(x: l.x, y: l.y, width: l.w, height: l.h))
            }
        }
    }

    /// The wall map multiplied by `color`.
    func map(_ color: Int) -> CGImage? {
        if let m = byColor[color] { return m }
        let c = CityTextures.rgb(color)
        let glass = CityTextures.rgb(0x4b5463)
        let img = CityTextures.draw(size, size) { ctx in
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.setFillColor(CGColor(srgbRed: c.0 * glass.0, green: c.1 * glass.1, blue: c.2 * glass.2, alpha: 1))
            for p in panes { ctx.fill(p) }
        }
        byColor[color] = img
        return img
    }
}

// MARK: - Labels

/// A text sign. `lines[0]` is bold. As a billboard (always facing you), or
/// as an image for a banner.
@MainActor
enum CityLabel {
    struct Style {
        var height: Float = 1
        var color = NSColor.white
        var bg = NSColor(srgbRed: 12 / 255, green: 16 / 255, blue: 24 / 255, alpha: 0.78)
        var accent: NSColor? = nil
    }

    static func image(_ lines: [String], _ st: Style) -> (CGImage, CGFloat, CGFloat)? {
        let f0 = NSFont.boldSystemFont(ofSize: 40), f1 = NSFont.systemFont(ofSize: 30)
        let pad: CGFloat = 18, lh0: CGFloat = 48, lh1: CGFloat = 38
        func width(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }
        var w = width(lines.first ?? "", f0)
        for l in lines.dropFirst() { w = max(w, width(l, f1)) }
        let cw = ceil(w + pad * 2), ch = ceil(pad * 2 + lh0 + lh1 * CGFloat(max(0, lines.count - 1)))
        guard let img = CityTextures.draw(Int(cw), Int(ch), { ctx in
            ctx.setFillColor(st.bg.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: cw, height: ch), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.fillPath()
            if let a = st.accent {
                ctx.setFillColor(a.cgColor)
                ctx.fill(CGRect(x: 0, y: ch - 6, width: cw, height: 6))
            }
            let g = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            ((lines.first ?? "") as NSString).draw(at: NSPoint(x: pad, y: pad + 2),
                withAttributes: [.font: f0, .foregroundColor: st.color])
            for (i, l) in lines.dropFirst().enumerated() {
                (l as NSString).draw(at: NSPoint(x: pad, y: pad + lh0 + CGFloat(i) * lh1 + 2),
                                     withAttributes: [.font: f1, .foregroundColor: st.color.withAlphaComponent(0.8)])
            }
            NSGraphicsContext.restoreGraphicsState()
        }) else { return nil }
        return (img, cw, ch)
    }

    static func material(_ img: CGImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        return m
    }

    /// The sprite: a plane that turns to face the camera, `height` world units tall per line block.
    static func make(_ lines: [String], _ st: Style = Style()) -> CityNode {
        let node = CityNode()
        guard let (img, cw, ch) = image(lines, st) else { return node }
        let hh = st.height * (lines.count == 1 ? 1 : 1 + 0.75 * Float(lines.count - 1))
        let plane = SCNPlane(width: CGFloat(hh) * cw / ch, height: CGFloat(hh))
        plane.materials = [material(img)]
        node.geometry = plane
        node.castsShadow = false
        node.renderingOrder = 2
        let bb = SCNBillboardConstraint()
        bb.freeAxes = .all
        node.constraints = [bb]
        return node
    }
}


/// `short(s, n)`: an ellipsis past n characters.
func cityShort(_ s: String, _ n: Int = 26) -> String {
    s.count > n ? String(s.prefix(n - 1)) + "…" : s
}

func cityClamp<T: Comparable>(_ v: T, _ a: T, _ b: T) -> T { max(a, min(b, v)) }
