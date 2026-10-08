import SceneKit
import simd

/*
 * The town's occasional visitors: a superhero who flies over now and then,
 * and a police car chasing somebody through the streets (cityactors.js).
 *
 * Neither means anything — the buildings are the information, and these are
 * the reason to leave the view open. Both are built from a handful of
 * primitives, like everything else here, and each is a node that owns its
 * geometry, so a visit is thrown away whole when it ends.
 */

private func std(_ color: Int, roughness: CGFloat = 0.6, metalness: CGFloat = 0, emissive: Int = 0, doubleSided: Bool = false) -> SCNMaterial {
    CityMat.std(color, roughness: roughness, metalness: metalness, emissive: emissive, doubleSided: doubleSided)
}

// MARK: - The superhero

/// The hero, and the cape that ripples every frame.
@MainActor
final class CityHero {
    let node: CityNode
    private let cape: SCNNode
    private let capeRest: CityMesh
    private let capeMat: SCNMaterial

    /// Flying the classic way: flat out, nose (well, fist) first along -z, one
    /// arm forward, the cape streaming behind. About twice life size, or from
    /// a flying camera they are a speck.
    init() {
        let g = CityNode()
        let suit = std(0x2457c5)
        capeMat = CityMat.std(0xc62828, roughness: 0.8, doubleSided: true)
        let skin = std(0xf1c27d)
        let boots = std(0xb71c1c)
        let belt = std(0xffd33d, metalness: 0.4)

        func limb(_ r: CGFloat, _ len: CGFloat, _ mat: SCNMaterial) -> SCNNode {
            let c = SCNCapsule(capRadius: r, height: len + 2 * r)
            c.radialSegmentCount = 8
            c.capSegmentCount = 4
            c.materials = [mat]
            let m = SCNNode(geometry: c)
            m.simdEulerAngles.x = .pi / 2
            return m
        }
        let torso = limb(0.42, 1.2, suit)
        let head = SCNNode.mesh(.sphere(0.34, 14, 10), skin).at(0, 0.18, -1.2)
        let hair = SCNNode.mesh(.sphere(0.35, 14, 10, thetaLength: .pi / 2), std(0x1b1b1b)).at(0, 0.18, -1.2)
        hair.simdEulerAngles.x = -0.5
        let armF = limb(0.14, 1.1, suit).at(0.32, 0.05, -1.9)
        let fist = SCNNode.mesh(.sphere(0.17, 8, 6), skin).at(0.32, 0.05, -2.55)
        let armB = limb(0.14, 1.0, suit).at(-0.55, -0.05, -0.1)
        let legL = limb(0.17, 1.3, suit).at(0.2, -0.05, 1.35)
        let legR = limb(0.17, 1.3, suit).at(-0.2, -0.05, 1.35)
        let bootL = limb(0.19, 0.4, boots).at(0.2, -0.05, 2.15)
        let bootR = limb(0.19, 0.4, boots).at(-0.2, -0.05, 2.15)
        let sash = SCNNode.mesh(.cylinder(0.44, 0.44, 0.16, 14), belt).at(0, 0, 0.45)
        sash.simdEulerAngles.x = .pi / 2
        let emblem = SCNNode.mesh(.circle(0.22, 5), std(0xffd33d, emissive: 0x332200)).at(0, -0.43, -0.4)
        emblem.simdEulerAngles.x = .pi / 2

        // The cape: a strip of cloth whose vertices ripple every frame.
        var capeGeo = CityMesh.plane(1.3, 3.2, 4, 12)
        capeGeo.rotateX(-.pi / 2)
        capeGeo.translate(0, 0.45, 0.9)
        capeRest = capeGeo
        cape = SCNNode.mesh(capeGeo, capeMat)

        for n in [torso, head, hair, armF, fist, armB, legL, legR, bootL, bootR, sash, emblem, cape] { g.addChildNode(n) }
        g.scale = SCNVector3(2, 2, 2)
        g.item = CityItem(kind: .hero)
        node = g
    }

    /// Ripple the cape; `t` is time, `speed` how hard the wind is.
    func flapCape(_ t: Float, speed: Float = 1) {
        var m = capeRest
        for i in 0..<m.pos.count {
            let r = capeRest.pos[i]
            let back = max(0, r.z - 0.9)              // fixed at the shoulders
            m.pos[i].y = r.y + sin(t * 14 * speed - r.z * 2.4) * 0.16 * back
            m.pos[i].x = r.x * (1 + back * 0.12)
        }
        m.computeNormals()
        let g = m.geometry()
        g.materials = [capeMat]
        cape.geometry = g
    }
}

// MARK: - Cars

/// A car, nose along -z, sitting on y = 0. The police one has a light bar
/// whose two halves `flashLights` takes turns with; in the future, cars have
/// no wheels and float, as was always promised.
@MainActor
final class CityCar {
    let node: CityNode
    let lift: Float
    private(set) var wheels: [SCNNode] = []
    private var red: SCNMaterial?
    private var blue: SCNMaterial?
    /// The heading, as three.js's `rotation.y`.
    var heading: Float = 0 { didSet { node.simdOrientation = simd_quatf(angle: heading, axis: [0, 1, 0]) } }

    init(police: Bool = false, color: Int = 0xd6452f, hover: Bool = false) {
        let g = CityNode()
        lift = hover ? 1.4 : 0
        let paint = std(police ? 0x14171c : color, roughness: 0.35, metalness: 0.5)
        let glass = std(0x1d2733, roughness: 0.15, metalness: 0.8)
        g.addChildNode(SCNNode.mesh(.box(2.1, 0.75, 4.5), paint).at(0, 0.7 + lift, 0))
        g.addChildNode(SCNNode.mesh(.box(1.8, 0.7, 2.3), glass).at(0, 1.4 + lift, 0.25))

        if police {
            // White doors, the way every police car in every film has them.
            let white = std(0xf4f6fa)
            for s in [Float(1), -1] {
                g.addChildNode(SCNNode.mesh(.box(0.04, 0.6, 2), white, shadow: false).at(s * 1.07, 0.72 + lift, 0.1))
            }
            g.addChildNode(SCNNode.mesh(.box(1.7, 0.08, 2.0), white, shadow: false).at(0, 1.79 + lift, 0.25))
        }

        if hover {
            let under = SCNNode.mesh(.cylinder(1.2, 1.2, 0.08, 20), CityMat.basic(0x4cf2ff, opacity: 0.7), shadow: false)
            g.addChildNode(under.at(0, lift - 0.05, 0))
        } else {
            let tyre = std(0x111111, roughness: 0.9)
            var wheelGeo = CityMesh.cylinder(0.42, 0.42, 0.32, 14)
            wheelGeo.rotateZ(.pi / 2)
            for (x, z) in [(Float(1), Float(-1.45)), (-1, -1.45), (1, 1.45), (-1, 1.45)] {
                let w = SCNNode.mesh(wheelGeo, tyre, shadow: false).at(x * 1.0, 0.42, z)
                g.addChildNode(w)
                wheels.append(w)
            }
        }

        let head = CityMat.basic(0xfff6d8)
        let tail = CityMat.basic(0xff2a2a)
        for s in [Float(1), -1] {
            g.addChildNode(SCNNode.mesh(.box(0.45, 0.2, 0.05), head, shadow: false).at(s * 0.7, 0.8 + lift, -2.26))
            g.addChildNode(SCNNode.mesh(.box(0.45, 0.18, 0.05), tail, shadow: false).at(s * 0.7, 0.8 + lift, 2.26))
        }

        if police {
            let r = CityMat.basic(0xff2020), b = CityMat.basic(0x2060ff)
            g.addChildNode(SCNNode.mesh(.box(1.3, 0.12, 0.35), std(0x222222), shadow: false).at(0, 1.88 + lift, 0.1))
            g.addChildNode(SCNNode.mesh(.box(0.6, 0.22, 0.38), r, shadow: false).at(0.33, 2.0 + lift, 0.1))
            g.addChildNode(SCNNode.mesh(.box(0.6, 0.22, 0.38), b, shadow: false).at(-0.33, 2.0 + lift, 0.1))
            red = r; blue = b
        }
        g.item = CityItem(kind: police ? .police : .suspect)
        node = g
    }

    /// Red, blue, red, blue: the lights take turns, and dim when it is not theirs.
    func flashLights(_ t: Float) {
        guard let red, let blue else { return }
        let on = Int(floor(t * 7)) % 2 == 0
        red.diffuse.contents = cityColor(on ? 0xff2020 : 0x3a0808)
        blue.diffuse.contents = cityColor(on ? 0x0c1640 : 0x2060ff)
    }

    func spinWheels(_ dist: Float) {
        for w in wheels { w.simdEulerAngles.x = -dist / 0.42 }
    }
}

// MARK: - The route

/// A path you can ask "where am I after s units?".
struct CityPath {
    let length: Float
    let at: (Float) -> V3
}

/// A getaway through the grid: in from outside town along one street, a
/// handful of random turns at the crossroads, and out again.
///
/// `xs` are the x of the north–south streets and `zs` the z of the east–west
/// ones. Cars keep to the right of the centre line, which is also what keeps
/// them off the lamp posts standing in the middle of every crossing.
func cityChaseRoute(xs: [Float], zs: [Float], lane: Float = 1.3, outside: Float = 70, turns: Int = 8,
                    random: () -> Double = { Double.random(in: 0..<1) }) -> CityPath? {
    if xs.count < 2 || zs.count < 2 { return nil }
    func pick<T>(_ a: [T]) -> T { a[min(a.count - 1, Int(random() * Double(a.count)))] }
    let dirs: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    func inGrid(_ i: Int, _ j: Int) -> Bool { i >= 0 && j >= 0 && i < xs.count && j < zs.count }

    // Enter at an edge crossing, heading inward.
    let edge = pick(["w", "e", "n", "s"])
    var i: Int, j: Int, d: (Int, Int)
    switch edge {
    case "w": i = 0; j = Int(random() * Double(zs.count)); d = (1, 0)
    case "e": i = xs.count - 1; j = Int(random() * Double(zs.count)); d = (-1, 0)
    case "n": j = zs.count - 1; i = Int(random() * Double(xs.count)); d = (0, -1)
    default: j = 0; i = Int(random() * Double(xs.count)); d = (0, 1)
    }
    i = min(i, xs.count - 1); j = min(j, zs.count - 1)

    func P(_ a: Int, _ b: Int) -> V3 { V3(xs[a], 0, zs[b]) }
    func dv(_ d: (Int, Int)) -> V3 { V3(Float(d.0), 0, Float(d.1)) }
    var nodes: [(p: V3, d: (Int, Int))] = [(P(i, j) - dv(d) * outside, d)]
    nodes.append((P(i, j), d))
    for _ in 0..<(turns * 3) {
        let options = dirs.filter { !($0.0 == -d.0 && $0.1 == -d.1) && inGrid(i + $0.0, j + $0.1) }
        if options.isEmpty { break }
        let straight = options.first { $0.0 == d.0 && $0.1 == d.1 }
        if let straight, random() < 0.45 { d = straight } else { d = pick(options) }
        i += d.0; j += d.1
        nodes.append((P(i, j), d))
        if nodes.count > turns + 2 && random() < 0.25 { break }
    }
    // And away, straight on out of town.
    while inGrid(i + d.0, j + d.1) { i += d.0; j += d.1; nodes.append((P(i, j), d)) }
    nodes.append((P(i, j) + dv(d) * outside, d))

    // Keep right: offset each point by the right-hand side of the way in and
    // the way out, which at a corner puts it on the inside or outside of the
    // turn as it should be.
    func right(_ d: (Int, Int)) -> V3 { V3(Float(-d.1), 0, Float(d.0)) }
    let pts: [V3] = nodes.enumerated().map { k, n in
        let din = n.d
        let dout = k < nodes.count - 1 ? nodes[k + 1].d : n.d
        var off = right(din)
        if din.0 != dout.0 || din.1 != dout.1 { off += right(dout) }
        return n.p + off * lane
    }
    // Drop points that sit in a straight line, so speed is even along them.
    var out = [pts[0]]
    for k in 1..<pts.count where simd_distance(pts[k], out[out.count - 1]) > 0.01 { out.append(pts[k]) }
    return cityPolyline(out)
}

/// A path of straight segments you can ask "where am I after s units?".
func cityPolyline(_ points: [V3]) -> CityPath {
    var lens: [Float] = []
    var acc: Float = 0
    for k in 0..<max(0, points.count - 1) {
        acc += simd_distance(points[k], points[k + 1])
        lens.append(acc)
    }
    let length = lens.last ?? 0
    return CityPath(length: length) { s0 in
        guard !lens.isEmpty else { return points.first ?? .zero }
        let s = max(0, min(length, s0))
        var k = 0
        while k < lens.count - 1 && lens[k] < s { k += 1 }
        let start = k > 0 ? lens[k - 1] : 0
        let seg = lens[k] - start
        let t = seg != 0 ? (s - start) / seg : 0
        return simd_mix(points[k], points[k + 1], V3(repeating: t))
    }
}
