import SceneKit
import simd

/*
 * What the buildings of the 3D city look like (cityarch.js).
 *
 * The facts a building carries — its height, its footprint and the coloured
 * bands of what its bytes are — are the same in every style; a style only
 * decides the shape they are poured into and what sits on the roof. So a
 * pagoda and a glass tower over the same folder are equally tall and equally
 * striped, and switching styles never changes what the city says.
 *
 * Each style has several kinds of building and picks between them by the
 * folder's name, with the details (how far a tower steps in, how big the
 * dome is, which colour the roof tiles are) jittered by the same seed. A
 * street is then a mix, and the same folder looks the same every visit.
 */

struct CityStyle: Equatable {
    let id: String
    let label: String
    let group: String

    static let all: [CityStyle] = [
        CityStyle(id: "today", label: "Today — the modern mix", group: "Now"),
        CityStyle(id: "eastasia", label: "East Asia — pagodas & eaves", group: "Around the world"),
        CityStyle(id: "mideast", label: "Middle East — domes & minarets", group: "Around the world"),
        CityStyle(id: "mediterranean", label: "Mediterranean — terracotta & blue domes", group: "Around the world"),
        CityStyle(id: "canal", label: "Northern Europe — canal-house gables", group: "Around the world"),
        CityStyle(id: "ancient", label: "Ancient Greece & Rome", group: "Through time"),
        CityStyle(id: "medieval", label: "Medieval — castles & turrets", group: "Through time"),
        CityStyle(id: "victorian", label: "Victorian — mansards & chimneys", group: "Through time"),
        CityStyle(id: "deco", label: "Art Deco — 1930s skyline", group: "Through time"),
        CityStyle(id: "future", label: "Futuristic — the year 2200", group: "Through time"),
    ]

    static let defaultId = "today"

    static func byId(_ id: String?) -> CityStyle { all.first { $0.id == id } ?? all[0] }

    /// The groups in order of first appearance.
    static var groups: [String] {
        var out: [String] = []
        for s in all where !out.contains(s.group) { out.append(s.group) }
        return out
    }
}

// MARK: - Seeds

/// FNV-1a over UTF-16 code units, as `hash` in cityarch.js.
func cityHash(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for c in s.utf16 { h ^= UInt32(c); h = h &* 16777619 }
    return h
}

/// A small deterministic generator (mulberry32), so a folder keeps its building.
/// Bit-for-bit the JavaScript one: the same folder gets the same building.
final class CitySeeded {
    private var a: UInt32
    init(_ key: String) {
        let h = cityHash(key)
        a = h == 0 ? 1 : h
    }
    func next() -> Double {
        a = a &+ 0x6d2b79f5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296
    }
    func callAsFunction() -> Float { Float(next()) }
    func pick<T>(_ arr: [T]) -> T { arr[Int(next() * Double(arr.count)) % arr.count] }
    func range(_ a0: Float, _ a1: Float) -> Float { a0 + Float(next()) * (a1 - a0) }
}

// MARK: - Geometry

private let S: Float = 8   // world units per window tile, as scaledBox in city3d

/// A box whose UVs are in world units / 8, so the window tile keeps its size
/// however tall the band is. Tops and bottoms map to a single wall pixel.
func cityScaledBox(_ w: Float, _ h: Float, _ d: Float, _ v0: Float = 0) -> CityMesh {
    var g = CityMesh.box(w, h, d)
    // Face order: +x, -x, +y, -y, +z, -z — four vertices each.
    let dims: [(Float, Float)] = [(d, h), (d, h), (0, 0), (0, 0), (w, h), (w, h)]
    for f in 0..<6 {
        let (su, sv) = dims[f]
        for k in 0..<4 {
            let i = f * 4 + k
            if su == 0 { g.uv[i] = SIMD2(0.01, 0.01); continue }
            g.uv[i] = SIMD2(g.uv[i].x * su / S, g.uv[i].y * sv / S + v0 / S)
        }
    }
    return g
}

/// A cylinder (or a 4- or 8-sided prism) whose walls carry the window tile
/// at its true size. The caps map to a single wall pixel, as the boxes' do.
func cityScaledCylinder(_ rTop: Float, _ rBot: Float, _ h: Float, _ segs: Int, _ v0: Float = 0) -> CityMesh {
    var g = CityMesh.cylinder(rTop, rBot, h, segs)
    let torso = (segs + 1) * 2
    let perim = Float.pi * (rTop + rBot) * (segs <= 8 ? sin(Float.pi / Float(segs)) * Float(segs) / Float.pi : 1)
    for i in 0..<g.uv.count {
        if i >= torso { g.uv[i] = SIMD2(0.01, 0.01); continue }
        g.uv[i] = SIMD2(g.uv[i].x * perim / S, g.uv[i].y * h / S + v0 / S)
    }
    return g
}

/// A gable: a triangle `w` wide and `h` high, `len` long, ridge along z.
private func prismGeo(_ w: Float, _ h: Float, _ len: Float) -> CityMesh { CityMesh.prism(w, h, len) }

/// A square pyramid or hip roof over a square of side `w`.
private func pyramidGeo(_ w: Float, _ h: Float, _ top: Float = 0) -> CityMesh {
    var g = CityMesh.cylinder(top * 0.70710678, w * 0.70710678, h, 4)
    g.rotateY(.pi / 4)
    return g
}

// MARK: - The builder

/// What a building asks for and returns.
struct CityTowerSpec {
    var styleId: String
    var seed: String
    var w: Float
    var h: Float
    /// [(colour, share)], bottom up.
    var bands: [(Int, Double)]
    /// The windowed wall material for one band.
    var bandMat: (Int) -> SCNMaterial
    /// A plain one: (colour, metal, glow).
    var accent: (Int, Float, Float) -> SCNMaterial
    var night: Bool
}

/// Something the city animates: halos turn, flags wave, smoke rises.
final class CitySpinner {
    enum Kind { case halo, flag, smoke }
    let kind: Kind
    var obj: SCNNode?
    var speed: Float = 0
    var at: V3 = .zero
    var group: SCNNode?
    var puffs: [SCNNode]? = nil
    var puffT: [Float] = []
    init(kind: Kind, obj: SCNNode? = nil, speed: Float = 0, at: V3 = .zero) {
        self.kind = kind; self.obj = obj; self.speed = speed; self.at = at
    }
}

private final class TowerCtx {
    let g: SCNNode
    let rnd: CitySeeded
    let w: Float, h: Float
    let bands: [(Int, Double)]
    let bandMatFn: (Int) -> SCNMaterial
    let accentFn: (Int, Float, Float) -> SCNMaterial
    let night: Bool
    var spin: [CitySpinner] = []
    var top: Float = 0
    var H: Float = 0
    var topW: Float = 0

    init(_ g: SCNNode, _ s: CityTowerSpec) {
        self.g = g
        rnd = CitySeeded(s.styleId + "|" + s.seed)
        w = s.w; h = s.h; bands = s.bands
        bandMatFn = s.bandMat; accentFn = s.accent; night = s.night
    }

    func bandMat(_ c: Int) -> SCNMaterial { bandMatFn(c) }
    func accent(_ c: Int, metal: Float = 0.1, glow: Float = 0) -> SCNMaterial { accentFn(c, metal, glow) }
}

/// One building, into `g`, standing on y = 0.
///
/// Returns the height of the walls (what the building is "as tall as") and
/// of the very top (where its sign goes), and anything that wants to turn.
@MainActor
func cityBuildTower(_ g: SCNNode, _ spec: CityTowerSpec) -> (H: Float, top: Float, spin: [CitySpinner]) {
    let ctx = TowerCtx(g, spec)
    switch spec.styleId {
    case "eastasia": Recipes.eastasia(ctx)
    case "mideast": Recipes.mideast(ctx)
    case "mediterranean": Recipes.mediterranean(ctx)
    case "canal": Recipes.canal(ctx)
    case "ancient": Recipes.ancient(ctx)
    case "medieval": Recipes.medieval(ctx)
    case "victorian": Recipes.victorian(ctx)
    case "deco": Recipes.deco(ctx)
    case "future": Recipes.future(ctx)
    default: Recipes.today(ctx)
    }
    return (ctx.H, max(ctx.top, ctx.H), ctx.spin)
}

@discardableResult
private func add(_ ctx: TowerCtx, _ geo: CityMesh, _ mat: SCNMaterial, _ x: Float, _ y: Float, _ z: Float,
                 shadow: Bool = true) -> SCNNode {
    let m = SCNNode.mesh(geo, mat, shadow: shadow).at(x, y, z)
    ctx.g.addChildNode(m)
    return m
}

private func raise(_ ctx: TowerCtx, _ y: Float) { ctx.top = max(ctx.top, y) }

private enum WallShape { case box, round, oct, taper }

/// The walls, band by band.
///
///   shape  box | round | oct | taper
///   shrink how much narrower each band is than the one under it (setbacks)
///   taper  for taper: the top's width as a share of the bottom's
///   between(ctx, y, width) is called at each join, for eaves and cornices
@discardableResult
private func walls(_ ctx: TowerCtx, shape: WallShape = .box, shrink: Float = 0, minScale: Float = 0.5, taper: Float = 0.6,
                   between: ((TowerCtx, Float, Float) -> Void)? = nil) -> Float {
    let w = ctx.w, h = ctx.h, bands = ctx.bands
    let total = Float(bands.reduce(0) { $0 + $1.1 })
    var y: Float = 0
    var width = w
    let n = bands.count
    for (i, band) in bands.enumerated() {
        let (color, b) = band
        let bh = max(0.7, h * Float(b) / total)
        let mat = ctx.bandMat(color)
        var geo: CityMesh
        switch shape {
        case .taper:
            let f0 = 1 - (1 - taper) * (y / h), f1 = 1 - (1 - taper) * min(1, (y + bh) / h)
            geo = cityScaledCylinder(w * f1 * 0.70710678, w * f0 * 0.70710678, bh, 4, y)
            geo.rotateY(.pi / 4)
            width = w * f1
        case .round:
            geo = cityScaledCylinder(width / 2, width / 2, bh, 24, y)
        case .oct:
            let r = width / 2 / cos(Float.pi / 8)
            geo = cityScaledCylinder(r, r, bh, 8, y)
            geo.rotateY(.pi / 8)
        case .box:
            geo = cityScaledBox(width, bh, width, y)
        }
        add(ctx, geo, mat, 0, y + bh / 2, 0)
        y += bh
        if i < n - 1 {
            between?(ctx, y, width)
            if shrink != 0 { width = max(w * minScale, width * (1 - shrink)) }
        }
    }
    ctx.H = y
    ctx.topW = width
    raise(ctx, y)
    return y
}

// MARK: roofs and crowns

private func flatUnit(_ ctx: TowerCtx, _ mat: SCNMaterial) {
    let H = ctx.H, topW = ctx.topW, rnd = ctx.rnd
    let n = 1 + Int(rnd() * 3)
    for _ in 0..<n {
        let s = topW * rnd.range(0.18, 0.4), hh = rnd.range(0.8, 2)
        let x = (rnd() - 0.5) * (topW - s) * 0.8
        let z = (rnd() - 0.5) * (topW - s) * 0.8
        add(ctx, .box(s, hh, s), mat, x, H + hh / 2, z)
        raise(ctx, H + hh)
    }
}

private func antenna(_ ctx: TowerCtx, height: Float? = nil, color: Int = 0x9aa3b2, tip: Int = 0xff3b3b, x: Float = 0, z: Float = 0) {
    let base = ctx.top
    let hh = height ?? ctx.rnd.range(3, 8)
    add(ctx, .cylinder(0.08, 0.16, hh, 6), ctx.accent(color, metal: 0.6), x, base + hh / 2, z, shadow: false)
    add(ctx, .sphere(0.28, 8, 6), CityMat.basic(tip), x, base + hh, z, shadow: false)
    raise(ctx, base + hh)
}

private func spire(_ ctx: TowerCtx, _ mat: SCNMaterial, k: Float = 0.6, needle: Bool = true) {
    let topW = ctx.topW
    let base = ctx.top
    let hh = topW * k
    add(ctx, pyramidGeo(topW * 0.98, hh), mat, 0, base + hh / 2, 0)
    raise(ctx, base + hh)
    if needle { antenna(ctx, height: ctx.rnd.range(2, 5), color: 0xc9ccd4, tip: 0xffe08a) }
}

private func dome(_ ctx: TowerCtx, _ mat: SCNMaterial, k: Float = 0.45, drum: Float = 1.2, onion: Bool = false, finial: Int = 0xd9a441) {
    let topW = ctx.topW
    var base = ctx.top
    let r = topW * k
    if drum != 0 {
        add(ctx, .cylinder(r * 1.02, r * 1.05, drum, 24), ctx.accent(0xd8d2c4), 0, base + drum / 2, 0)
        base += drum
    }
    let geo = CityMesh.sphere(r, 24, 14, thetaStart: 0, thetaLength: onion ? .pi * 0.62 : .pi / 2)
    let m = add(ctx, geo, mat, 0, base, 0)
    if onion {
        m.scale = SCNVector3(1, 1.35, 1)
        let tip = r * 0.9
        add(ctx, .cone(r * 0.32, tip, 16), mat, 0, base + r * 1.35 * 0.9 + tip / 2 - r * 0.15, 0)
        base += r * 1.35 + tip * 0.75
    } else {
        base += r
    }
    add(ctx, .sphere(max(0.2, r * 0.07), 8, 6), ctx.accent(finial, metal: 0.7), 0, base + 0.2, 0, shadow: false)
    raise(ctx, base + 0.4)
}

private func gable(_ ctx: TowerCtx, _ mat: SCNMaterial, alongX: Bool = true, k: Float = 0.55, overhang: Float = 0.6,
                   chimneys: Int = 0, chimneyMat: SCNMaterial? = nil) {
    let H = ctx.H, topW = ctx.topW, rnd = ctx.rnd
    let hh = topW * k
    var geo = prismGeo(topW + overhang * 2, hh, topW + overhang * 2)
    if alongX { geo.rotateY(.pi / 2) }
    add(ctx, geo, mat, 0, H, 0)
    raise(ctx, H + hh)
    for _ in 0..<chimneys {
        let cx = (rnd() - 0.5) * topW * 0.6, cz = (rnd() - 0.5) * topW * 0.6
        let ch = hh * rnd.range(0.7, 1.1) + 1.2
        add(ctx, .box(0.9, ch, 0.9), chimneyMat ?? mat, cx, H + ch / 2, cz)
        raise(ctx, H + ch)
    }
}

/// A stepped gable on the street front, as Amsterdam does it.
private func steppedGable(_ ctx: TowerCtx, _ mat: SCNMaterial, _ trim: SCNMaterial) {
    let H = ctx.H, topW = ctx.topW
    let steps = 3 + Int(ctx.rnd() * 2)
    let stepH = topW * 0.16
    for i in 0..<steps {
        let sw = topW * (1 - Float(i) / Float(steps))
        add(ctx, .box(sw, stepH, 0.7), trim, 0, H + stepH * (Float(i) + 0.5), topW / 2 - 0.35)
    }
    // The roof behind it.
    add(ctx, prismGeo(topW, stepH * Float(steps), topW - 0.7), mat, 0, H, -0.35)
    raise(ctx, H + stepH * Float(steps))
    // The hoist beam every one of them has, for the furniture.
    add(ctx, .box(0.25, 0.25, 1.4), ctx.accent(0x3a2a1c), 0, H + stepH * (Float(steps) - 0.5), topW / 2 + 0.4, shadow: false)
}

private func mansard(_ ctx: TowerCtx, _ mat: SCNMaterial, _ chimneyMat: SCNMaterial) {
    let H = ctx.H, topW = ctx.topW, rnd = ctx.rnd
    let hh = rnd.range(2.2, 3.4)
    add(ctx, pyramidGeo(topW * 1.02, hh, topW * 0.62), mat, 0, H + hh / 2, 0)
    // Dormers on the street side.
    let n = max(1, Int(floor(topW / 5)))
    for i in 0..<n {
        let x = -topW * 0.3 + (n == 1 ? topW * 0.3 : (Float(i) * topW * 0.6) / Float(n - 1))
        add(ctx, .box(1.1, 1.3, 0.9), ctx.accent(0xe8e2d4), x, H + hh * 0.45, topW * 0.42)
    }
    // The bound is re-drawn on every pass, as the original's loop condition was.
    var i = 0
    while i < 2 + Int(rnd() * 2) {
        defer { i += 1 }
        let cx = (i % 2 == 1 ? 1 : -1) * topW * 0.38, cz = (rnd() - 0.5) * topW * 0.5
        let ch = hh + rnd.range(1, 2.4)
        add(ctx, .box(1, ch, 1.4), chimneyMat, cx, H + ch / 2, cz)
        add(ctx, .cylinder(0.18, 0.18, 0.6, 6), ctx.accent(0xb5653a), cx, H + ch + 0.3, cz, shadow: false)
        raise(ctx, H + ch + 0.6)
    }
    raise(ctx, H + hh)
}

private func crenellate(_ ctx: TowerCtx, _ mat: SCNMaterial, round: Bool = false) {
    let H = ctx.H, topW = ctx.topW
    let merlon: Float = 1.1
    add(ctx, round ? .cylinder(topW / 2 + 0.4, topW / 2 + 0.4, 0.7, 24) : .box(topW + 0.8, 0.7, topW + 0.8), mat, 0, H + 0.35, 0)
    var pts: [(Float, Float)] = []
    if round {
        let n = max(8, Int((Float.pi * topW / 2.2).rounded()))
        for i in 0..<n {
            let a = Float(i) / Float(n) * .pi * 2
            pts.append((cos(a) * (topW / 2 + 0.1), sin(a) * (topW / 2 + 0.1)))
        }
    } else {
        let n = max(3, Int((topW / 2.4).rounded()))
        let e = topW / 2 + 0.1
        for i in 0...n {
            let t = -e + (2 * e * Float(i)) / Float(n)
            pts.append((t, e)); pts.append((t, -e))
            if i > 0 && i < n { pts.append((e, t)); pts.append((-e, t)) }
        }
    }
    for (x, z) in pts { add(ctx, .box(0.9, merlon, 0.9), mat, x, H + 0.7 + merlon / 2, z) }
    raise(ctx, H + 0.7 + merlon)
    ctx.top = H + 0.7
}

private func turretCone(_ ctx: TowerCtx, _ mat: SCNMaterial) {
    let topW = ctx.topW
    let r = topW / 2 + 0.6
    let hh = r * ctx.rnd.range(1.6, 2.4)
    let base = ctx.H
    add(ctx, .cone(r, hh, 24), mat, 0, base + hh / 2, 0)
    raise(ctx, base + hh)
    // A pennant.
    add(ctx, .cylinder(0.06, 0.06, 2.4, 4), ctx.accent(0x3a3a3a), 0, base + hh + 1.2, 0, shadow: false)
    let flag = add(ctx, .plane(1.4, 0.7), CityMat.lambert(ctx.rnd.pick([0xc62828, 0x1e5bb8, 0xe0b000]), doubleSided: true),
                   0.7, base + hh + 2.0, 0, shadow: false)
    ctx.spin.append(CitySpinner(kind: .flag, obj: flag))
    raise(ctx, base + hh + 2.4)
}

/// Flared eaves at a join, pagoda fashion.
private func eave(_ ctx: TowerCtx, _ y: Float, _ width: Float, _ mat: SCNMaterial, flare: Float = 2.2, round: Bool = false) {
    let geo = round ? CityMesh.cylinder(width / 2, width / 2 + flare, 0.9, 8) : pyramidGeo(width + flare * 2, 0.9, width)
    add(ctx, geo, mat, 0, y + 0.1, 0)
    // Upturned corners.
    if !round {
        let e = width / 2 + flare
        for (sx, sz) in [(Float(1), Float(1)), (1, -1), (-1, 1), (-1, -1)] {
            add(ctx, .cone(0.22, 0.9, 5), mat, sx * e * 0.98, y + 0.45, sz * e * 0.98, shadow: false)
        }
    }
}

private func pagodaTop(_ ctx: TowerCtx, _ roofMat: SCNMaterial, _ finialMat: SCNMaterial) {
    let topW = ctx.topW
    let base = ctx.H
    eave(ctx, base, topW, roofMat, flare: 2.4)
    let hh = topW * 0.45
    add(ctx, pyramidGeo(topW + 1.2, hh), roofMat, 0, base + 0.5 + hh / 2, 0)
    let y = base + 0.5 + hh
    // The finial: rings on a mast.
    add(ctx, .cylinder(0.12, 0.12, 4.5, 6), finialMat, 0, y + 2.25, 0, shadow: false)
    for i in 0..<5 {
        add(ctx, .torus(0.5 - Float(i) * 0.06, 0.09, 6, 14), finialMat, 0, y + 0.8 + Float(i) * 0.6, 0, shadow: false)
            .simdEulerAngles.x = .pi / 2
    }
    raise(ctx, y + 4.5)
}

@discardableResult
private func columns(_ ctx: TowerCtx, colMat: SCNMaterial, baseMat: SCNMaterial, pediment: SCNMaterial? = nil,
                     height: Float? = nil) -> Bool {
    let w = ctx.w
    let ch = min(height ?? ctx.H, 9)
    let e = w / 2 + 1.1
    // The stylobate: three steps up.
    for i in 0..<2 {
        let s = e * 2 + 2 - Float(i) * 0.8
        add(ctx, .box(s, 0.3, s), baseMat, 0, 0.15 + Float(i) * 0.3, 0)
    }
    let n = max(3, Int((e * 2 / 2.6).rounded()))
    var pts: [(Float, Float)] = []
    for i in 0...n {
        let t = -e + (2 * e * Float(i)) / Float(n)
        pts.append((t, e)); pts.append((t, -e))
        if i > 0 && i < n { pts.append((e, t)); pts.append((-e, t)) }
    }
    let geo = CityMesh.cylinder(0.32, 0.4, ch, 10)
    for (x, z) in pts {
        // Leave the door clear.
        if z > 0 && abs(x) < 1.8 && abs(z - e) < 0.01 { continue }
        add(ctx, geo, colMat, x, 0.6 + ch / 2, z)
    }
    add(ctx, .box(e * 2 + 1, 0.8, e * 2 + 1), baseMat, 0, 0.6 + ch + 0.4, 0)
    raise(ctx, 0.6 + ch + 0.8)
    if let pediment, ch >= ctx.H - 0.5 {
        let hh = e * 0.45
        add(ctx, prismGeo(e * 2 + 1, hh, e * 2 + 1), pediment, 0, 0.6 + ch + 0.8, 0)
        raise(ctx, 0.6 + ch + 0.8 + hh)
        return true
    }
    return false
}

private func minaret(_ ctx: TowerCtx, _ mat: SCNMaterial, _ domeMat: SCNMaterial) {
    let w = ctx.w, H = ctx.H, rnd = ctx.rnd
    let side: Float = rnd() < 0.5 ? 1 : -1
    let x = side * (w / 2 + 1.6), z = -w / 2 + 1.6
    let mh = max(H * rnd.range(1.15, 1.4), 14)
    add(ctx, .cylinder(0.75, 0.95, mh, 12), mat, x, mh / 2, z)
    // The balcony the call to prayer is made from.
    add(ctx, .cylinder(1.35, 1.1, 0.4, 14), mat, x, mh * 0.78, z)
    add(ctx, .sphere(0.85, 12, 8, thetaLength: .pi * 0.62), domeMat, x, mh, z).scale = SCNVector3(1, 1.4, 1)
    add(ctx, .cone(0.2, 1.4, 8), domeMat, x, mh + 1.6, z, shadow: false)
    raise(ctx, mh + 2.3)
}

private func halo(_ ctx: TowerCtx, _ color: Int) {
    let topW = ctx.topW
    let y = ctx.top + ctx.rnd.range(1.5, 4)
    let ring = add(ctx, .torus(topW * ctx.rnd.range(0.45, 0.75), 0.18, 8, 40), ctx.accent(color, glow: 1.6), 0, y, 0, shadow: false)
    ring.simdEulerAngles.x = .pi / 2 + ctx.rnd.range(-0.25, 0.25)
    ctx.spin.append(CitySpinner(kind: .halo, obj: ring, speed: ctx.rnd.range(0.4, 1.2) * (ctx.rnd() < 0.5 ? -1 : 1)))
    raise(ctx, y + 0.5)
}

private func sky(_ ctx: TowerCtx, _ mat: SCNMaterial) {
    // A skybridge stub and garden deck partway up — futures always have those.
    let w = ctx.w, H = ctx.H, rnd = ctx.rnd
    let y = H * rnd.range(0.45, 0.75)
    add(ctx, .cylinder(w * 0.6, w * 0.56, 0.6, 32), mat, 0, y, 0)
    add(ctx, .cylinder(w * 0.58, w * 0.58, 0.3, 32), ctx.accent(0x5aa04f), 0, y + 0.45, 0, shadow: false)
}

private func decoCrown(_ ctx: TowerCtx, _ trim: SCNMaterial) {
    let topW = ctx.topW, rnd = ctx.rnd
    var base = ctx.H
    var s = topW * 0.85
    let steps = 2 + Int(rnd() * 3)
    for _ in 0..<steps {
        let hh = rnd.range(1.2, 2.4)
        add(ctx, .box(s, hh, s), trim, 0, base + hh / 2, 0)
        base += hh
        s *= 0.72
    }
    ctx.top = base
    if rnd() < 0.5 {
        // The Chrysler move: a scalloped spire of nested arches, simplified to rings.
        for i in 0..<4 {
            add(ctx, .torus(s * (0.9 - Float(i) * 0.18), 0.12, 6, 24, arc: .pi), trim, 0, base + Float(i) * 0.9, 0, shadow: false)
        }
        ctx.top = base + 3.6
    }
    antenna(ctx, height: rnd.range(4, 9), color: 0xd9d4c4, tip: 0xffd27a)
}

// MARK: - The styles

private enum Recipes {
    static func today(_ ctx: TowerCtx) {
        let rnd = ctx.rnd, h = ctx.h
        let roof = ctx.accent(rnd.pick([0x2b303a, 0x3a3f4a, 0x4a3f36]))
        let kind = h < 7 && rnd() < 0.5 ? "house" : rnd.pick(["slab", "setback", "round", "spire", "glass"])
        if kind == "house" {
            walls(ctx)
            gable(ctx, ctx.accent(rnd.pick([0x8c3b2e, 0x4a4f5c, 0x6b4a2f])), alongX: rnd() < 0.5, chimneys: rnd() < 0.6 ? 1 : 0)
        } else if kind == "setback" {
            walls(ctx, shrink: rnd.range(0.08, 0.2))
            flatUnit(ctx, roof)
            antenna(ctx)
        } else if kind == "round" {
            walls(ctx, shape: .round)
            add(ctx, .cylinder(ctx.topW * 0.52, ctx.topW * 0.52, 0.5, 24), roof, 0, ctx.H + 0.25, 0)
            raise(ctx, ctx.H + 0.5)
            if rnd() < 0.5 { antenna(ctx) }
        } else if kind == "spire" {
            walls(ctx, shrink: rnd() < 0.5 ? 0.1 : 0)
            spire(ctx, roof, k: rnd.range(0.3, 0.7))
        } else if kind == "glass" {
            walls(ctx, shape: .oct, shrink: rnd.range(0, 0.08))
            flatUnit(ctx, roof)
        } else {
            walls(ctx)
            flatUnit(ctx, roof)
        }
    }

    static func eastasia(_ ctx: TowerCtx) {
        let rnd = ctx.rnd
        let roofMat = ctx.accent(rnd.pick([0x2e3a33, 0x23303a, 0x6b1f1a, 0x3b4a3a]))
        let gold = ctx.accent(0xd9a441, metal: 0.6)
        let kind = rnd.pick(["pagoda", "pagoda", "hall", "octpagoda", "modern"])
        if kind == "pagoda" || kind == "octpagoda" {
            let oct = kind == "octpagoda"
            walls(ctx, shape: oct ? .oct : .box, shrink: rnd.range(0.06, 0.14),
                  between: { c, y, width in eave(c, y, width, roofMat, flare: rnd.range(1.4, 2.4), round: oct) })
            pagodaTop(ctx, roofMat, gold)
        } else if kind == "hall" {
            walls(ctx)
            // A hip-and-gable roof, wider than the hall, with a ridge.
            eave(ctx, ctx.H, ctx.topW, roofMat, flare: 2.8)
            let hh = ctx.topW * 0.35
            add(ctx, pyramidGeo(ctx.topW + 1.5, hh, ctx.topW * 0.3), roofMat, 0, ctx.H + 0.5 + hh / 2, 0)
            add(ctx, .box(ctx.topW * 0.5, 0.6, 0.6), gold, 0, ctx.H + 0.5 + hh + 0.3, 0)
            raise(ctx, ctx.H + hh + 1.2)
        } else {
            // Today's Shanghai and Tokyo: towers with a crown.
            walls(ctx, shape: rnd() < 0.5 ? .taper : .box, taper: rnd.range(0.55, 0.8))
            if rnd() < 0.5 { spire(ctx, roofMat, k: 0.5) } else { flatUnit(ctx, roofMat); antenna(ctx) }
        }
    }

    static func mideast(_ ctx: TowerCtx) {
        let rnd = ctx.rnd
        let domeMat = ctx.accent(rnd.pick([0xd9a441, 0x2aa198, 0x1e6fb5, 0xe9e2cf]), metal: 0.3)
        let stone = ctx.accent(rnd.pick([0xe2d3b3, 0xd8c39a, 0xefe6d2]))
        let kind = rnd.pick(["mosque", "mosque", "domed", "tower", "flat"])
        if kind == "mosque" {
            walls(ctx)
            add(ctx, .box(ctx.topW + 0.6, 0.5, ctx.topW + 0.6), stone, 0, ctx.H + 0.25, 0)
            ctx.top = ctx.H + 0.5
            dome(ctx, domeMat, k: rnd.range(0.32, 0.45), drum: 1.4, onion: rnd() < 0.6)
            minaret(ctx, stone, domeMat)
        } else if kind == "domed" {
            walls(ctx, shape: rnd() < 0.5 ? .oct : .round)
            ctx.top = ctx.H
            dome(ctx, domeMat, k: 0.48, drum: 0.8, onion: true)
        } else if kind == "tower" {
            // Dubai: a tapering needle.
            walls(ctx, shape: .taper, taper: rnd.range(0.3, 0.55))
            antenna(ctx, height: rnd.range(6, 14), color: 0xd9d4c4, tip: 0xffffff)
        } else {
            walls(ctx)
            // Flat roofs with a parapet and a couple of little domes.
            add(ctx, .box(ctx.topW + 0.4, 0.8, ctx.topW + 0.4), stone, 0, ctx.H + 0.4, 0)
            var i = 0
            while i < 1 + Int(rnd() * 2) {
                i += 1
                let r = ctx.topW * rnd.range(0.1, 0.18)
                let x = (rnd() - 0.5) * ctx.topW * 0.5
                let z = (rnd() - 0.5) * ctx.topW * 0.5
                add(ctx, .sphere(r, 14, 8, thetaLength: .pi / 2), domeMat, x, ctx.H + 0.8, z)
                raise(ctx, ctx.H + 0.8 + r)
            }
        }
    }

    static func mediterranean(_ ctx: TowerCtx) {
        let rnd = ctx.rnd
        let tile = ctx.accent(rnd.pick([0xb5653a, 0xc4703f, 0xa0522d]))
        let blue = ctx.accent(rnd.pick([0x1f5fbf, 0x2a74d4]))
        let kind = rnd.pick(["hip", "hip", "bluedome", "bell", "terrace"])
        if kind == "hip" {
            walls(ctx, shrink: rnd() < 0.3 ? 0.1 : 0)
            let hh = ctx.topW * rnd.range(0.2, 0.32)
            add(ctx, pyramidGeo(ctx.topW + 1.4, hh, rnd() < 0.5 ? 0 : ctx.topW * 0.4), tile, 0, ctx.H + hh / 2, 0)
            raise(ctx, ctx.H + hh)
        } else if kind == "bluedome" {
            walls(ctx, shape: rnd() < 0.5 ? .round : .box)
            ctx.top = ctx.H
            dome(ctx, blue, k: rnd.range(0.35, 0.48), drum: 0.6, finial: 0xffffff)
        } else if kind == "bell" {
            walls(ctx)
            // A campanile at the corner.
            let bw = max(3, ctx.w * 0.28), bh = ctx.H + rnd.range(5, 10)
            let x = ctx.w / 2 - bw / 2, z = -ctx.w / 2 + bw / 2
            add(ctx, .box(bw, bh, bw), ctx.accent(0xefe6d2), x, bh / 2, z)
            add(ctx, pyramidGeo(bw + 0.4, bw * 0.8), tile, x, bh + bw * 0.4, z)
            raise(ctx, bh + bw * 0.8)
            let hh = ctx.topW * 0.22
            add(ctx, pyramidGeo(ctx.topW + 1, hh), tile, 0, ctx.H + hh / 2, 0)
        } else {
            // Terraces stepping up a hillside.
            walls(ctx, shrink: rnd.range(0.15, 0.25), minScale: 0.4, between: { c, y, width in
                add(c, .box(width + 0.3, 0.35, width + 0.3), tile, 0, y + 0.17, 0, shadow: false)
            })
            add(ctx, .box(ctx.topW + 0.3, 0.6, ctx.topW + 0.3), ctx.accent(0xefe6d2), 0, ctx.H + 0.3, 0)
            raise(ctx, ctx.H + 0.6)
        }
    }

    static func canal(_ ctx: TowerCtx) {
        let rnd = ctx.rnd
        let slate = ctx.accent(rnd.pick([0x3d4552, 0x4a4d55, 0x5b3a2e]))
        let trim = ctx.accent(rnd.pick([0xf2ede2, 0x8c3b2e, 0x2b2f38]))
        let kind = rnd.pick(["stepped", "stepped", "bell", "neck", "church"])
        walls(ctx)
        if kind == "stepped" { steppedGable(ctx, slate, trim) }
        else if kind == "bell" || kind == "neck" {
            gable(ctx, slate, alongX: false, k: kind == "neck" ? 0.9 : 0.7, overhang: 0.2)
            // The ornamented front gable.
            add(ctx, prismGeo(ctx.topW * 0.98, ctx.topW * (kind == "neck" ? 0.9 : 0.7), 0.6), trim, 0, ctx.H, ctx.topW / 2 - 0.1)
        } else {
            gable(ctx, slate, alongX: false, k: 0.8)
            // A slim church spire at the back.
            let x: Float = 0, z = -ctx.topW / 2 + 1.6
            let bh = ctx.H + ctx.topW * 0.8 + rnd.range(4, 9)
            add(ctx, .box(3, bh, 3), trim, x, bh / 2, z)
            add(ctx, .cone(1.9, 7, 8), slate, x, bh + 3.5, z)
            raise(ctx, bh + 7)
        }
    }

    static func ancient(_ ctx: TowerCtx) {
        let rnd = ctx.rnd
        let marble = ctx.accent(rnd.pick([0xeee9dc, 0xe6dfcc, 0xf4f0e6]))
        let tile = ctx.accent(rnd.pick([0xb5653a, 0x9e5a35]))
        let kind = rnd.pick(["temple", "temple", "pantheon", "basilica", "obelisk"])
        if kind == "temple" {
            walls(ctx)
            let roofed = columns(ctx, colMat: marble, baseMat: marble, pediment: tile)
            if !roofed { gable(ctx, tile, alongX: false, k: 0.3, overhang: 1.2) }
        } else if kind == "pantheon" {
            walls(ctx, shape: .round)
            columns(ctx, colMat: marble, baseMat: marble, height: min(ctx.H, 7))
            ctx.top = ctx.H
            dome(ctx, ctx.accent(0x9aa3a8), k: 0.5, drum: 0.6, finial: 0xd9a441)
        } else if kind == "basilica" {
            walls(ctx, shrink: 0.1)
            gable(ctx, tile, alongX: false, k: 0.35, overhang: 0.8)
        } else {
            walls(ctx, shape: .taper, taper: rnd.range(0.4, 0.6))
            // A gilded pyramidion.
            add(ctx, pyramidGeo(ctx.topW, ctx.topW * 0.8), ctx.accent(0xd9a441, metal: 0.8), 0, ctx.H + ctx.topW * 0.4, 0)
            raise(ctx, ctx.H + ctx.topW * 0.8)
        }
    }

    static func medieval(_ ctx: TowerCtx) {
        let rnd = ctx.rnd, h = ctx.h
        let stone = ctx.accent(rnd.pick([0x8f8a80, 0x9a948a, 0x7d786f]))
        let roof = ctx.accent(rnd.pick([0x5a3d6b, 0x8b3a2b, 0x3d4552, 0x6b4a2f]))
        let kind = h < 8 && rnd() < 0.6 ? "timber" : rnd.pick(["keep", "turret", "turret", "gatehouse", "cathedral"])
        if kind == "timber" {
            walls(ctx)
            // Jettied upper floor and a steep roof.
            add(ctx, .box(ctx.topW + 1, 0.4, ctx.topW + 1), ctx.accent(0x4a3020), 0, ctx.H - 0.2, 0)
            gable(ctx, roof, alongX: rnd() < 0.5, k: 0.85, chimneys: 1, chimneyMat: stone)
        } else if kind == "keep" {
            walls(ctx)
            crenellate(ctx, stone)
            // Corner bartizans.
            for (sx, sz) in [(Float(1), Float(1)), (-1, 1), (1, -1), (-1, -1)] {
                let x = sx * ctx.topW / 2, z = sz * ctx.topW / 2
                add(ctx, .cylinder(0.9, 0.7, 2.2, 10), stone, x, ctx.H + 1.1, z)
                add(ctx, .cone(1.1, 2.2, 10), roof, x, ctx.H + 3.3, z)
            }
            raise(ctx, ctx.H + 4.4)
        } else if kind == "turret" {
            walls(ctx, shape: .round)
            if rnd() < 0.6 { turretCone(ctx, roof) } else { crenellate(ctx, stone, round: true) }
        } else if kind == "gatehouse" {
            walls(ctx)
            crenellate(ctx, stone)
            for sx in [Float(1), -1] {
                let x = sx * (ctx.w / 2 + 0.2), z = ctx.w / 2 - 1
                let th = ctx.H + rnd.range(2, 5)
                add(ctx, .cylinder(1.8, 2, th, 14), stone, x, th / 2, z)
                add(ctx, .cone(2.3, 4, 14), roof, x, th + 2, z)
                raise(ctx, th + 4)
            }
        } else {
            walls(ctx, shrink: 0.12)
            gable(ctx, roof, alongX: false, k: 0.9)
            // A slim spire rising from the ridge, not a pyramid sat on it.
            let sh = ctx.topW * rnd.range(1.1, 1.8)
            add(ctx, .cone(max(1.2, ctx.topW * 0.12), sh, 8), roof, 0, ctx.top + sh / 2 - 0.5, 0)
            raise(ctx, ctx.top + sh)
        }
    }

    static func victorian(_ ctx: TowerCtx) {
        let rnd = ctx.rnd, h = ctx.h
        let slate = ctx.accent(rnd.pick([0x3d4552, 0x2f353f, 0x4a4f5c]))
        let brick = ctx.accent(rnd.pick([0x8c3b2e, 0x7a3426, 0x9b4a35]))
        let kind = h < 7 && rnd() < 0.5 ? "terrace" : rnd.pick(["mansard", "mansard", "clock", "gothic", "mill"])
        if kind == "terrace" {
            walls(ctx)
            gable(ctx, slate, alongX: true, k: 0.5, chimneys: 2, chimneyMat: brick)
        } else if kind == "mansard" {
            walls(ctx, between: { c, y, width in
                add(c, .box(width + 0.5, 0.3, width + 0.5), c.accent(0xe8e2d4), 0, y, 0, shadow: false)
            })
            mansard(ctx, slate, brick)
        } else if kind == "clock" {
            walls(ctx, shrink: 0.15)
            // A clock face on all four sides of the top band.
            let face = ctx.accent(0xf6f1e3, glow: ctx.night ? 0.8 : 0)
            let r = min(ctx.topW * 0.32, 3)
            for i in 0..<4 {
                let a = Float(i) * .pi / 2
                let d = ctx.topW / 2 + 0.05
                let m = add(ctx, .circle(r, 24), face, sin(a) * d, ctx.H - r - 0.6, cos(a) * d, shadow: false)
                m.simdEulerAngles.y = a
            }
            spire(ctx, slate, k: rnd.range(0.9, 1.4), needle: true)
        } else if kind == "gothic" {
            walls(ctx)
            gable(ctx, slate, alongX: false, k: 0.9)
            for (sx, sz) in [(Float(1), Float(1)), (-1, 1)] {
                let x = sx * ctx.topW / 2, z = sz * ctx.topW / 2
                add(ctx, .cone(0.6, 3.5, 6), slate, x, ctx.H + 1.75, z)
            }
            raise(ctx, ctx.H + 3.5)
        } else {
            // A mill with its chimney stack.
            walls(ctx)
            gable(ctx, slate, alongX: true, k: 0.3)
            let x = ctx.w / 2 - 1.4, z = -ctx.w / 2 + 1.4
            let sh = ctx.H + rnd.range(8, 16)
            add(ctx, .cylinder(0.8, 1.3, sh, 12), brick, x, sh / 2, z)
            raise(ctx, sh)
            ctx.spin.append(CitySpinner(kind: .smoke, at: V3(x, sh + 0.5, z)))
        }
    }

    static func deco(_ ctx: TowerCtx) {
        let rnd = ctx.rnd
        let trim = ctx.accent(rnd.pick([0xd9b45a, 0xc9ccd4, 0xb08d57]), metal: 0.6, glow: ctx.night ? 0.25 : 0)
        let kind = rnd.pick(["ziggurat", "ziggurat", "slab", "round"])
        if kind == "ziggurat" {
            walls(ctx, shrink: rnd.range(0.12, 0.22), minScale: 0.35, between: { c, y, width in
                add(c, .box(width + 0.3, 0.35, width + 0.3), trim, 0, y, 0, shadow: false)
            })
            decoCrown(ctx, trim)
        } else if kind == "slab" {
            walls(ctx)
            // Vertical piers running the height.
            let n = max(2, Int(floor(ctx.w / 4)))
            for i in 0..<n {
                let x = -ctx.w / 2 + (ctx.w * (Float(i) + 0.5)) / Float(n)
                add(ctx, .box(0.35, ctx.H, 0.35), trim, x, ctx.H / 2, ctx.w / 2 + 0.1, shadow: false)
            }
            decoCrown(ctx, trim)
        } else {
            walls(ctx, shape: .round, shrink: rnd.range(0.1, 0.18))
            add(ctx, .cylinder(ctx.topW * 0.45, ctx.topW * 0.55, 1.5, 24), trim, 0, ctx.H + 0.75, 0)
            ctx.top = ctx.H + 1.5
            antenna(ctx, height: rnd.range(5, 10), color: 0xd9d4c4, tip: 0xffd27a)
        }
    }

    static func future(_ ctx: TowerCtx) {
        let rnd = ctx.rnd
        let glow = rnd.pick([0x4cf2ff, 0xff4cd2, 0x7cff6b, 0xffb84c, 0x9d7cff])
        let shell = ctx.accent(rnd.pick([0xdfe6ee, 0x9aa3b2, 0x2b303a]), metal: 0.7)
        let kind = rnd.pick(["spindle", "halo", "pod", "twist", "arcology"])
        if kind == "spindle" {
            // Glowing collars at each join; corner strips would stand off a taper.
            walls(ctx, shape: .taper, taper: rnd.range(0.25, 0.45), between: { c, y, width in
                add(c, .box(width + 0.5, 0.2, width + 0.5), c.accent(glow, glow: 1.4), 0, y, 0, shadow: false)
            })
            antenna(ctx, height: rnd.range(8, 16), color: 0xdfe6ee, tip: glow)
        } else if kind == "halo" {
            walls(ctx, shape: .round, shrink: rnd.range(0, 0.08))
            add(ctx, .sphere(ctx.topW * 0.5, 24, 12, thetaLength: .pi / 2), shell, 0, ctx.H, 0)
            raise(ctx, ctx.H + ctx.topW * 0.5)
            halo(ctx, glow)
            if rnd() < 0.5 { halo(ctx, glow) }
        } else if kind == "pod" {
            walls(ctx, shape: .oct)
            sky(ctx, shell)
            // A saucer on top.
            let r = ctx.topW * rnd.range(0.7, 1)
            add(ctx, .cylinder(r * 0.3, r, 1.2, 32), shell, 0, ctx.H + 1.6, 0)
            add(ctx, .cylinder(r, r * 0.4, 0.8, 32), shell, 0, ctx.H + 2.6, 0)
            add(ctx, .torus(r, 0.12, 6, 40), ctx.accent(glow, glow: 1.6), 0, ctx.H + 2.2, 0, shadow: false).simdEulerAngles.x = .pi / 2
            add(ctx, .cylinder(0.6, 0.6, 1.6, 12), shell, 0, ctx.H + 0.8, 0)
            raise(ctx, ctx.H + 3.2)
        } else if kind == "twist" {
            // Each band turned a little further than the one under it.
            let before = ctx.g.childNodes.count
            walls(ctx, shrink: rnd.range(0, 0.06))
            let turn = rnd.range(0.12, 0.3) * (rnd() < 0.5 ? 1 : -1)
            for (i, m) in ctx.g.childNodes.dropFirst(before).enumerated() { m.simdEulerAngles.y = turn * Float(i) }
            spire(ctx, shell, k: 0.5)
        } else {
            walls(ctx, shape: .taper, taper: rnd.range(0.55, 0.75), between: { c, y, width in
                add(c, .box(width + 0.8, 0.25, width + 0.8), c.accent(glow, glow: 1.2), 0, y, 0, shadow: false)
            })
            sky(ctx, shell)
            halo(ctx, glow)
        }
    }
}
