import SceneKit
import simd

/*
 * The machine's processes as traffic (cityprocs.js).
 *
 * A periodic `ps`, the busiest forty, and each one becomes something moving
 * around town — sized by what it is using:
 *
 *   cars    processes that are mostly CPU, driving the streets; the more CPU,
 *           the faster they go
 *   boats   processes that are mostly memory, on the river behind the town,
 *           sitting lower and longer the more they hold
 *   rockets the few that are big either way, on launch pads at the edge of
 *           town, going up again and again with a flame as big as their CPU
 *
 * Each vehicle is kept by pid between looks, so it grows and shrinks as its
 * process does rather than being replaced every few seconds, and one that
 * has exited sinks or drives off rather than blinking out.
 */

private let MB: Double = 1024 * 1024
private let ROCKET_MEM = 1.5 * 1024 * MB
private let ROCKET_CPU: Double = 60
private let MAX_ROCKETS = 3

enum CityProcKind: String { case car, boat, rocket }

enum CityProcRules {
    static func sizeFor(_ p: CityProc) -> Float {
        Float(cityClamp(0.7 + 0.42 * log2(1 + p.mem / (64 * MB)) + p.cpu / 60, 0.6, 3.6))
    }

    static func hashHue(_ s: String) -> Double {
        var h: UInt32 = 0
        for c in s.utf16 { h = h &* 31 &+ UInt32(c) }
        return Double(h % 360) / 360
    }

    /// A colour per user; root is red.
    static func colorFor(_ user: String) -> Int {
        hsl(user == "root" ? 0 : hashHue(user.isEmpty ? "?" : user), 0.62, 0.5)
    }

    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Int {
        func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * 6 * (2 / 3 - t) }
            return p
        }
        let q = l <= 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        // three (r152+, colour management on) makes HSL in linear space and
        // getHex() encodes to sRGB, so the colour is lighter than plain HSL.
        func enc(_ c: Double) -> Int {
            let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            return Int((max(0, min(1, s)) * 255).rounded())
        }
        let r = hue2rgb(p, q, h + 1 / 3), g = hue2rgb(p, q, h), b = hue2rgb(p, q, h - 1 / 3)
        return (enc(r) << 16) | (enc(g) << 8) | enc(b)
    }

    static func kindFor(_ p: CityProc, rocketSlots: Int) -> CityProcKind {
        if rocketSlots > 0 && (p.mem >= ROCKET_MEM || p.cpu >= ROCKET_CPU) { return .rocket }
        return p.mem / (100 * MB) > p.cpu ? .boat : .car
    }
}

/// Where the traffic goes: the street grid, the river behind the town, and
/// the launch pads off to its east.
struct CityTrafficLayout {
    struct River { var z: Float; var width: Float; var x0: Float; var x1: Float }
    var river: River
    var pads: [(x: Float, z: Float)]
    var night: Bool
    var hover: Bool
    var streets: (xs: [Float], zs: [Float])?
}

// MARK: - Models

@MainActor
private func makeBoat(_ color: Int) -> (CityNode, SCNNode) {
    let g = CityNode()
    let hullMat = CityMat.std(0x2b303a, roughness: 0.7)
    g.addChildNode(SCNNode.mesh(.box(2.6, 1.1, 5.4), hullMat).at(0, 0.35, 0))
    let bow = SCNNode.mesh(.cone(1.84, 2.4, 4), hullMat).at(0, 0.35, -3.9)
    bow.simdEulerAngles = V3(-.pi / 2, .pi / 4, 0)
    bow.scale = SCNVector3(1, 1, 0.6)
    g.addChildNode(bow)
    g.addChildNode(SCNNode.mesh(.box(2.64, 0.22, 5.44), CityMat.std(color)).at(0, 0.75, 0))
    g.addChildNode(SCNNode.mesh(.box(1.9, 1.1, 2), CityMat.std(0xf2f4f8, roughness: 0.5)).at(0, 1.45, 0.9))
    g.addChildNode(SCNNode.mesh(.cylinder(0.35, 0.42, 1.2, 10), CityMat.std(color)).at(0, 2.5, 1.2))
    let wake = SCNNode.mesh(.plane(2.4, 6), CityMat.basic(0xffffff, opacity: 0.35), shadow: false).at(0, -0.12, 5.6)
    wake.simdEulerAngles.x = -.pi / 2
    g.addChildNode(wake)
    return (g, wake)
}

@MainActor
private func makeRocket(_ color: Int) -> (CityNode, flame: SCNNode, core: SCNNode) {
    let g = CityNode()
    let white = CityMat.std(0xf2f4f8, roughness: 0.4, metalness: 0.3)
    let paint = CityMat.std(color, roughness: 0.5)
    g.addChildNode(SCNNode.mesh(.cylinder(1, 1, 9, 20), white).at(0, 5.5, 0))
    g.addChildNode(SCNNode.mesh(.cylinder(1.02, 1.02, 1.2, 20), paint).at(0, 7.5, 0))
    g.addChildNode(SCNNode.mesh(.cone(1, 3, 20), paint).at(0, 11.5, 0))
    for i in 0..<3 {
        let a = Float(i) / 3 * .pi * 2
        let f = SCNNode.mesh(.box(0.15, 2.4, 1.6), paint).at(sin(a) * 1.2, 1.9, cos(a) * 1.2)
        f.simdEulerAngles.y = a
        g.addChildNode(f)
    }
    g.addChildNode(SCNNode.mesh(.cylinder(0.6, 0.85, 0.9, 14), CityMat.std(0x3a3f4a, metalness: 0.6), shadow: false).at(0, 0.65, 0))
    // The flame hangs below the nozzle: a cone turned point-down, in a group
    // so its own scale can stretch it from the nozzle.
    let flame = SCNNode()
    let fl = SCNNode.mesh(.cone(0.75, 4, 14, open: true), CityMat.basic(0xffa23a, opacity: 0.9, additive: true, doubleSided: true), shadow: false)
    fl.simdEulerAngles.x = .pi
    flame.addChildNode(fl)
    flame.simdPosition = V3(0, -1.8, 0)
    let core = SCNNode()
    let co = SCNNode.mesh(.cone(0.4, 2.4, 10, open: true), CityMat.basic(0xfff3c4, opacity: 0.95, additive: true, doubleSided: true), shadow: false)
    co.simdEulerAngles.x = .pi
    core.addChildNode(co)
    core.simdPosition = V3(0, -1, 0)
    g.addChildNode(flame)
    g.addChildNode(core)
    return (g, flame, core)
}

@MainActor
private func makePad() -> SCNNode {
    let g = SCNNode()
    let concrete = CityMat.std(0x8a8f99, roughness: 0.95)
    let steel = CityMat.std(0xc0392b, roughness: 0.6, metalness: 0.4)
    g.addChildNode(SCNNode.mesh(.cylinder(7, 7.5, 0.6, 24), concrete, shadow: false).at(0, 0.3, 0))
    g.addChildNode(SCNNode.mesh(.box(1.2, 18, 1.2), steel).at(4.4, 9, 0))
    g.addChildNode(SCNNode.mesh(.box(3.2, 0.4, 0.5), steel, shadow: false).at(2.8, 14, 0))
    return g
}

// MARK: - Routes

/// A loop round a random rectangle of blocks, keeping right.
private func blockLoop(xs: [Float], zs: [Float], lane: Float = 1.3) -> CityPath? {
    guard xs.count >= 2, zs.count >= 2 else { return nil }
    func r(_ n: Int) -> Int { Int.random(in: 0..<max(1, n)) }
    let i0 = r(xs.count - 1), i1 = i0 + 1 + r(xs.count - 1 - i0)
    let j0 = r(zs.count - 1), j1 = j0 + 1 + r(zs.count - 1 - j0)
    var corners: [(Float, Float)] = [(xs[i0], zs[j0]), (xs[i1], zs[j0]), (xs[i1], zs[j1]), (xs[i0], zs[j1])]
    if Bool.random() { corners.reverse() }
    let n = corners.count
    func dir(_ a: (Float, Float), _ b: (Float, Float)) -> (Float, Float) { (sign(b.0 - a.0), sign(b.1 - a.1)) }
    func right(_ d: (Float, Float)) -> (Float, Float) { (-d.1, d.0) }
    var pts: [V3] = corners.enumerated().map { k, c in
        let din = dir(corners[(k + n - 1) % n], c), dout = dir(c, corners[(k + 1) % n])
        let ri = right(din), ro = right(dout)
        return V3(c.0 + (ri.0 + ro.0) * lane, 0, c.1 + (ri.1 + ro.1) * lane)
    }
    pts.append(pts[0])
    var lens: [Float] = [0]
    for k in 1..<pts.count { lens.append(lens[k - 1] + simd_distance(pts[k], pts[k - 1])) }
    let length = lens[lens.count - 1]
    return CityPath(length: length) { s0 in
        guard length > 0 else { return pts[0] }
        let s = (s0.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
        var k = 1
        while k < lens.count - 1 && lens[k] < s { k += 1 }
        let seg = lens[k] - lens[k - 1]
        let t = (s - lens[k - 1]) / (seg != 0 ? seg : 1)
        return simd_mix(pts[k - 1], pts[k], V3(repeating: t))
    }
}

// MARK: - The traffic

@MainActor
final class CityTraffic {
    final class Actor {
        let kind: CityProcKind
        let obj: CityNode
        var proc: CityProc
        var size: Float = 0.05
        var target: Float
        var s: Float = Float.random(in: 0..<1000)
        var leaving: Float = 0
        let item: CityItem
        var route: CityPath?
        var dir: Float = 1
        var laneZ: Float = 0
        var x: Float = 0
        var phase = "pad"
        var wait: Float = 0
        var y: Float = 0
        var vy: Float = 0
        var pad: (x: Float, z: Float)?
        var heading: Float = 0
        var flame: SCNNode?
        var core: SCNNode?
        var lift: Float = 0
        var wheels: CityCar?

        init(kind: CityProcKind, obj: CityNode, proc: CityProc, item: CityItem) {
            self.kind = kind; self.obj = obj; self.proc = proc; self.item = item
            target = CityProcRules.sizeFor(proc)
        }
    }

    let root = SCNNode()
    private var actors: [Int: Actor] = [:]
    /// pids in the order they arrived (a JS Map's order), for stable pads.
    private var order: [Int] = []
    private var leavingList: [Actor] = []
    private var layoutInfo: CityTrafficLayout?
    private var fixtures: SCNNode?
    private var padSpots: [(x: Float, z: Float)] = []
    private var time: Float = 0

    init(scene: SCNScene) {
        scene.rootNode.addChildNode(root)
    }

    /// Where things go: called whenever the city is rebuilt.
    func layout(_ info: CityTrafficLayout?) {
        layoutInfo = info
        fixtures?.removeFromParentNode()
        fixtures = nil
        guard let info else { root.isHidden = true; return }
        root.isHidden = false
        let f = SCNNode()
        let river = info.river
        let waterMat = CityMat.std(info.night ? 0x1d3b5c : 0x3f86c6, roughness: 0.25, metalness: 0.2,
                                   emissive: info.night ? 0x0a1a2a : 0)
        let water = SCNNode.mesh(.plane(river.x1 - river.x0, river.width), waterMat, shadow: false)
            .at((river.x0 + river.x1) / 2, 0.08, river.z)
        water.simdEulerAngles.x = -.pi / 2
        let bankMat = CityMat.std(info.night ? 0x5a5240 : 0xc9b98f, roughness: 1)
        for s in [Float(1), -1] {
            f.addChildNode(SCNNode.mesh(.box(river.x1 - river.x0, 0.3, 2.5), bankMat, shadow: false)
                .at((river.x0 + river.x1) / 2, 0.12, river.z + s * (river.width / 2 + 1.2)))
        }
        f.addChildNode(water)
        padSpots = info.pads.map { p in
            f.addChildNode(makePad().at(p.x, 0, p.z))
            return p
        }
        fixtures = f
        root.addChildNode(f)
        // Everything that was driving or sailing finds its place in the new town.
        for a in actors.values { place(a, relayout: true) }
    }

    /// A fresh look at the processes.
    func update(_ procs: [CityProc]) {
        var seen = Set<Int>()
        var rocketSlots = MAX_ROCKETS
        func w(_ p: CityProc) -> Double { p.mem / ROCKET_MEM + p.cpu / ROCKET_CPU }
        let sorted = procs.enumerated().sorted { a, b in
            w(a.element) != w(b.element) ? w(a.element) > w(b.element) : a.offset < b.offset
        }.map(\.element)
        for p in sorted {
            let kind = CityProcRules.kindFor(p, rocketSlots: rocketSlots)
            if kind == .rocket { rocketSlots -= 1 }
            seen.insert(p.pid)
            var a = actors[p.pid]
            if let old = a, old.kind != kind { drop(old, now: true); a = nil }
            let actor = a ?? spawn(p, kind)
            actor.proc = p
            actor.item.proc = p
            actor.target = CityProcRules.sizeFor(p)
        }
        for a in Array(actors.values) where !seen.contains(a.proc.pid) { drop(a) }
        assignPads()
    }

    private func spawn(_ p: CityProc, _ kind: CityProcKind) -> Actor {
        let color = CityProcRules.colorFor(p.user)
        let item = CityItem(kind: .proc)
        item.vehicle = kind
        item.proc = p
        let a: Actor
        switch kind {
        case .car:
            let car = CityCar(color: color, hover: layoutInfo?.hover ?? false)
            a = Actor(kind: kind, obj: car.node, proc: p, item: item)
            a.lift = car.lift
            a.wheels = car
        case .boat:
            let (b, _) = makeBoat(color)
            a = Actor(kind: kind, obj: b, proc: p, item: item)
        case .rocket:
            let (r, flame, core) = makeRocket(color)
            a = Actor(kind: kind, obj: r, proc: p, item: item)
            a.flame = flame; a.core = core
        }
        a.obj.item = item
        a.obj.markPickable()
        root.addChildNode(a.obj)
        actors[p.pid] = a
        order.append(p.pid)
        place(a, relayout: false)
        return a
    }

    private func drop(_ a: Actor, now: Bool = false) {
        actors.removeValue(forKey: a.proc.pid)
        order.removeAll { $0 == a.proc.pid }
        if now { a.obj.removeFromParentNode(); return }
        a.leaving = 1
        leavingList.append(a)
    }

    /// Give a vehicle a route (a car), a lane (a boat) or a pad (a rocket).
    private func place(_ a: Actor, relayout: Bool) {
        guard let info = layoutInfo else { return }
        switch a.kind {
        case .car:
            a.route = info.streets.flatMap { blockLoop(xs: $0.xs, zs: $0.zs) }
            if relayout { a.s = Float.random(in: 0..<1000) }
        case .boat:
            let r = info.river
            a.dir = Bool.random() ? 1 : -1
            a.laneZ = r.z + a.dir * r.width * (0.12 + Float.random(in: 0..<1) * 0.22)
            a.x = r.x0 + Float.random(in: 0..<1) * (r.x1 - r.x0)
        case .rocket:
            a.phase = "pad"
            a.wait = 2 + Float.random(in: 0..<1) * 6
            a.y = 0
            a.vy = 0
        }
    }

    private func assignPads() {
        var k = 0
        for pid in order {
            guard let a = actors[pid], a.kind == .rocket else { continue }
            a.pad = padSpots.isEmpty ? (0, 0) : padSpots[k % padSpots.count]
            k += 1
        }
    }

    func tick(_ dt: Float) {
        time += dt
        guard layoutInfo != nil else { return }
        for a in actors.values {
            a.size += (a.target - a.size) * min(1, dt * 1.5)
            move(a, dt)
        }
        for a in leavingList {
            a.leaving -= dt * 0.6
            a.size = max(0.01, a.size * (1 - dt * 1.2))
            move(a, dt)
            if a.kind == .boat { a.obj.simdPosition.y -= (1 - a.leaving) * 1.5 }
            if a.leaving <= 0 { a.obj.removeFromParentNode() }
        }
        leavingList.removeAll { $0.leaving <= 0 }
    }

    private func move(_ a: Actor, _ dt: Float) {
        let o = a.obj
        o.simdScale = V3(repeating: a.size)
        let p = a.proc
        switch a.kind {
        case .car:
            guard let route = a.route else { o.isHidden = true; return }
            o.isHidden = false
            a.s += dt * Float(cityClamp(6 + p.cpu * 0.5, 6, 42))
            let here = route.at(a.s), ahead = route.at(a.s + 2)
            o.simdPosition = V3(here.x, 0.12 + (a.lift != 0 ? sin(time * 3 + a.s) * 0.12 : 0), here.z)
            let want = atan2(-(ahead.x - here.x), -(ahead.z - here.z))
            var d = want - a.heading
            d = atan2(sin(d), cos(d))
            a.heading += d * min(1, dt * 8)
            o.simdOrientation = simd_quatf(angle: a.heading, axis: [0, 1, 0])
            a.wheels?.spinWheels(a.s / a.size)
        case .boat:
            guard let r = layoutInfo?.river else { return }
            a.x += a.dir * dt * Float(cityClamp(3 + p.cpu * 0.3, 3, 18))
            if a.x > r.x1 - 6 { a.x = r.x0 + 6 }
            if a.x < r.x0 + 6 { a.x = r.x1 - 6 }
            o.simdPosition = V3(a.x, 0.1 - Float(min(0.5, p.mem / (2048 * MB))) * a.size * 0.3 + sin(time * 1.4 + a.x * 0.1) * 0.08, a.laneZ)
            o.simdEulerAngles = V3(0, a.dir > 0 ? -.pi / 2 : .pi / 2, sin(time * 1.1 + a.x) * 0.03)
        case .rocket:
            let pad = a.pad ?? (0, 0)
            // Countdown on the pad, then up and out of sight, then the next one.
            if a.phase == "pad" {
                a.wait -= dt
                a.y = 0
                if a.wait <= 0 { a.phase = "up"; a.vy = 0 }
            } else {
                a.vy += dt * Float(4 + p.cpu * 0.15)
                a.y += a.vy * dt
                if a.y > 600 { a.phase = "pad"; a.wait = 4 + Float.random(in: 0..<1) * 8; a.y = 0; a.vy = 0 }
            }
            o.simdPosition = V3(pad.x, 0.6 + a.y, pad.z)
            let burning = a.phase == "up" || a.wait < 1.5
            let power = Float(cityClamp(0.4 + p.cpu / 50, 0.4, 2.6))
            let flick = 0.85 + sin(time * 40 + pad.x) * 0.15
            a.flame?.isHidden = !burning
            a.core?.isHidden = !burning
            a.flame?.simdScale = V3(1, power * flick * (a.phase == "up" ? 1.6 : 0.6), 1)
            a.core?.simdScale = V3(1, power * flick, 1)
        }
    }

    func dispose() {
        root.removeFromParentNode()
        actors.removeAll()
        order.removeAll()
        leavingList.removeAll()
    }
}
