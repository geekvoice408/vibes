import AppKit
import SceneKit
import simd

/// A flock: a few birds in a loose V, circling over wherever you are.
@MainActor
final class CityFlock {
    let node = SCNNode()
    var birds: [(node: CityNode, l: SCNNode, r: SCNNode, off: V3, ph: Float)] = []
    var r: Float, alt: Float, speed: Float, a: Float, dir: Float, scare: Float = 0, cx: Float, cz: Float
    init(r: Float, alt: Float, speed: Float, a: Float, dir: Float, cx: Float, cz: Float) {
        self.r = r; self.alt = alt; self.speed = speed; self.a = a; self.dir = dir; self.cx = cx; self.cz = cz
    }
}

/// A plane crossing the sky, sometimes trailing a banner.
@MainActor
final class CityPlane {
    let node = CityNode()
    var strobe: SCNNode?
    var banner: SCNNode?
    var from = V3.zero, to = V3.zero
    var t: Float = 0, dur: Float = 1
}

extension CityController {
    // MARK: - The loop

    func startLoop() {
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFrame() }
        }
        RunLoop.main.add(t, forMode: .common)
        loopTimer = t
    }

    private func tickFrame() {
        guard !destroyed else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - last))
        last = now
        // Nothing to draw for a view that is not on screen.
        guard let w = scnView.window, w.occlusionState.contains(.visible), !scnView.isHiddenOrHasHiddenAncestor else { return }
        time += dt
        update(dt)
        animate(dt)
        updateBirds(dt)
        updatePlanes(dt)
        updateHero(dt)
        updateChase(dt)
        traffic?.tick(dt)
        frame += 1
        if frame % 3 == 0 { cullLabels() }
    }

    func forward(_ withPitch: Bool) -> V3 {
        let cp = withPitch ? cos(pitch) : 1
        return V3(-sin(yaw) * cp, withPitch ? sin(pitch) : 0, -cos(yaw) * cp)
    }

    func flySpeed() -> Float { max(18, extent / 3.5) }

    /// Height of whatever you would be standing on at (x, z) from this foot height.
    private func groundAt(_ x: Float, _ z: Float, _ feet: Float) -> Float {
        var g: Float = 0
        for s in solids where x > s.x0 - 0.3 && x < s.x1 + 0.3 && z > s.z0 - 0.3 && z < s.z1 + 0.3 && s.top <= feet + 0.45 {
            g = max(g, s.top)
        }
        return g
    }

    func moveBy(_ dx: Float, _ dy: Float, _ dz: Float) {
        var p = cameraNode.simdPosition
        var nx = p.x + dx, nz = p.z + dz
        if !flying || mode == "room" {
            let feet = p.y - cityEye
            let R: Float = 0.4
            for s in solids {
                if s.top <= feet + 0.45 { continue }              // you are above it, or can step onto it
                if !flying && feet > s.top { continue }
                if flying && p.y > s.top + 1 { continue }
                let inX = nx > s.x0 - R && nx < s.x1 + R
                let inZ = nz > s.z0 - R && nz < s.z1 + R
                if !inX || !inZ { continue }
                // Push out along whichever axis you came in on.
                let wasX = p.x > s.x0 - R && p.x < s.x1 + R
                if !wasX { nx = p.x } else { nz = p.z }
            }
        }
        p.x = nx
        p.z = nz
        p.y = max(0.6, p.y + dy)
        cameraNode.simdPosition = p
        if mode == "room", let b = bounds, p.z > b.D / 2 + 1.2 { out() }
    }

    private func update(_ dt: Float) {
        let K = keys
        let fast = K.contains(CityKey.shiftL) || K.contains(CityKey.shiftR)
        if K.contains(CityKey.left) { yaw += dt * 1.8 }
        if K.contains(CityKey.right) { yaw -= dt * 1.8 }
        var fwd: Float = 0, side: Float = 0
        if K.contains(CityKey.w) || K.contains(CityKey.up) { fwd += 1 }
        if K.contains(CityKey.s) || K.contains(CityKey.down) { fwd -= 1 }
        if K.contains(CityKey.d) { side += 1 }
        if K.contains(CityKey.a) { side -= 1 }

        let r = V3(cos(yaw), 0, -sin(yaw))
        if flying {
            let sp = flySpeed() * (fast ? 3 : 1) * dt
            let f = forward(true)
            var up: Float = 0
            if K.contains(CityKey.space) { up += 1 }
            if K.contains(CityKey.x) || K.contains(CityKey.c) { up -= 1 }
            if fwd != 0 || side != 0 || up != 0 {
                moveBy((f.x * fwd + r.x * side) * sp, (f.y * fwd + up) * sp, (f.z * fwd + r.z * side) * sp)
            }
        } else {
            let sp = (fast ? 13 : 6) * dt
            let f = forward(false)
            if fwd != 0 || side != 0 { moveBy((f.x * fwd + r.x * side) * sp, 0, (f.z * fwd + r.z * side) * sp) }
            var p = cameraNode.simdPosition
            let ground = groundAt(p.x, p.z, p.y - cityEye)
            let feet = p.y - cityEye
            if feet <= ground + 0.001 && vy <= 0 {
                p.y = ground + cityEye
                vy = 0
                if K.contains(CityKey.space) { vy = 7.5 }
            } else {
                vy -= 22 * dt
                p.y = max(ground + cityEye, p.y + vy * dt)
            }
            cameraNode.simdPosition = p
        }
        pitch = cityClamp(pitch, -1.5, 1.5)
        // Rotation order YXZ: turn, then look up or down.
        cameraNode.simdOrientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }

    private func animate(_ dt: Float) {
        let step = dt * 2.2
        for it in items.values where it.grow != 1 {
            it.grow = it.grow < 1 ? min(1, it.grow + step) : max(1, it.grow - step)
            it.group?.simdScale = V3(1, it.grow, 1)
            if let l = it.label, it.kind != .door {
                l.simdPosition.y = it.labelY * it.grow + (it.kind == .building ? 0.3 : 0)
            }
        }
        // Selected things bob a little and wear a ring of light.
        for it in items.values {
            guard let b = it.beacon else { continue }
            b.simdEulerAngles.y += dt * 1.5
            b.geometry?.firstMaterial?.transparency = CGFloat(0.35 + sin(time * 4) * 0.15)
        }
        for k in clouds.indices {
            clouds[k].a += clouds[k].speed * dt
            let c = clouds[k]
            c.node.simdPosition = V3(center.x + cos(c.a) * c.r, c.y, center.z + sin(c.a) * c.r)
        }
        for s in spinners {
            switch s.kind {
            case .halo: s.obj?.simdEulerAngles.z += dt * s.speed
            case .flag:
                if let o = s.obj { o.simdEulerAngles.y = sin(time * 3 + Float(ObjectIdentifier(o).hashValue % 97)) * 0.35 }
            case .smoke: smoke(s, dt)
            }
        }
    }

    /// A mill chimney's smoke: a few puffs that rise, swell and fade, then start again.
    private func smoke(_ s: CitySpinner, _ dt: Float) {
        if s.puffs == nil {
            var puffs: [SCNNode] = []
            let geo = SCNSphere(radius: 0.8)
            geo.isGeodesic = true
            geo.segmentCount = 1
            for i in 0..<5 {
                let mat = CityMat.lambert(0x8a8f99, transparent: true)
                geo.materials = [mat]
                let m = SCNNode(geometry: geo.copy() as? SCNGeometry)
                m.geometry?.materials = [mat]
                m.castsShadow = false
                s.group?.addChildNode(m)
                puffs.append(m)
                s.puffT.append(Float(i) / 5)
            }
            s.puffs = puffs
        }
        for (i, m) in (s.puffs ?? []).enumerated() {
            let t = (s.puffT[i] + dt * 0.22).truncatingRemainder(dividingBy: 1)
            s.puffT[i] = t
            m.simdPosition = V3(s.at.x + t * 3, s.at.y + t * 7, s.at.z - t * 1.5)
            m.simdScale = V3(repeating: 0.6 + t * 2.2)
            m.geometry?.firstMaterial?.transparency = CGFloat(0.55 * (1 - t))
        }
    }

    // MARK: - Birds

    /// Flocks of a few birds each, in a loose V, circling over wherever you
    /// are. Fly into one and it scatters.
    func initBirds() {
        let mat = CityMat.lambert(night ? 0xc9d3e6 : 0x262a33, doubleSided: true)
        var wing = CityMesh()
        wing.pos = [V3(0, 0, -0.35), V3(0, 0, 0.35), V3(1.5, 0, 0.15)]
        wing.nrm = [V3(0, 1, 0), V3(0, 1, 0), V3(0, 1, 0)]
        wing.uv = [.zero, .zero, .zero]
        wing.idx = [0, 1, 2]
        var body = CityMesh.cone(0.18, 1.1, 5)
        body.rotateX(-.pi / 2)
        for _ in 0..<4 {
            let flock = CityFlock(r: Float(40 + Double.random(in: 0..<1) * 120), alt: Float(28 + Double.random(in: 0..<1) * 30),
                                  speed: Float(7 + Double.random(in: 0..<1) * 5), a: Float.random(in: 0..<(2 * .pi)),
                                  dir: Bool.random() ? 1 : -1,
                                  cx: Float.random(in: -0.5..<0.5) * 60, cz: Float.random(in: -0.5..<0.5) * 60)
            let n = 5 + Int.random(in: 0..<6)
            for i in 0..<n {
                let bird = CityNode()
                bird.addChildNode(SCNNode.mesh(body, mat, shadow: false))
                let l = SCNNode.mesh(wing, mat, shadow: false)
                let r = SCNNode.mesh(wing, mat, shadow: false)
                r.simdScale = V3(-1, 1, 1)
                bird.addChildNode(l)
                bird.addChildNode(r)
                let side: Float = i % 2 == 1 ? 1 : -1, rank = Float((i + 1) / 2)
                bird.item = CityItem(kind: .bird)
                bird.markPickable()
                flock.birds.append((bird, l, r, V3(side * rank * 2.2, Float.random(in: -0.5..<0.5) * 0.8, rank * 2.4), Float.random(in: 0..<6)))
                flock.node.addChildNode(bird)
            }
            flocks.append(flock)
            scene.rootNode.addChildNode(flock.node)
        }
    }

    private func updateBirds(_ dt: Float) {
        let cam = cameraNode.simdPosition
        let base = max(topHeight + 12, 24)
        for f in flocks {
            f.a += f.dir * dt * f.speed / f.r
            let cx = center.x + f.cx, cz = center.z + f.cz
            let alt = base + f.alt - 24 + sin(time * 0.4 + f.r) * 3 + f.scare * 14
            f.node.simdPosition = V3(cx + cos(f.a) * f.r, alt, cz + sin(f.a) * f.r)
            // Heading: along the circle.
            f.node.simdEulerAngles = V3(0, -f.a + (f.dir > 0 ? .pi : 0), 0)
            let near = simd_distance(f.node.simdPosition, cam) < 14
            f.scare = near ? min(1, f.scare + dt * 3) : max(0, f.scare - dt * 0.25)
            for b in f.birds {
                let spread = 1 + f.scare * 2.5
                b.node.simdPosition = V3(b.off.x * spread, b.off.y * spread + sin(time * 1.3 + b.ph) * 0.4, b.off.z * spread)
                let flap = sin(time * (8 + f.scare * 10) + b.ph) * 0.7
                b.l.simdEulerAngles.z = flap
                b.r.simdEulerAngles.z = -flap
            }
        }
    }

    // MARK: - Planes

    private func makePlane(_ banner: String?) -> CityPlane {
        let p = CityPlane()
        let g = p.node
        let white = CityMat.std(0xf2f4f8, roughness: 0.5, metalness: 0.2)
        let stripe = CityMat.std(0x4c8dff, roughness: 0.5)
        let body = SCNNode.mesh(.cylinder(0.9, 0.7, 10, 10), white)
        body.simdEulerAngles.x = .pi / 2
        let nose = SCNNode.mesh(.cone(0.9, 2, 10), white, shadow: false).at(0, 0, -6)
        nose.simdEulerAngles.x = -.pi / 2
        let wing = SCNNode.mesh(.box(14, 0.25, 2.2), white).at(0, -0.2, -0.6)
        let tail = SCNNode.mesh(.box(0.25, 2.6, 1.8), stripe).at(0, 1.5, 4.3)
        let stab = SCNNode.mesh(.box(5, 0.2, 1.3), white, shadow: false).at(0, 0.3, 4.4)
        let band = SCNNode.mesh(.cylinder(0.92, 0.82, 1.2, 10), stripe, shadow: false).at(0, 0, 1.5)
        band.simdEulerAngles.x = .pi / 2
        let red = SCNNode.mesh(.sphere(0.22, 6, 6), CityMat.basic(0xff3b3b), shadow: false).at(-7, -0.2, -0.6)
        let green = SCNNode.mesh(.sphere(0.22, 6, 6), CityMat.basic(0x3bff6b), shadow: false).at(7, -0.2, -0.6)
        let strobe = SCNNode.mesh(.sphere(0.25, 6, 6), CityMat.basic(0xffffff), shadow: false).at(0, 2.9, 4.8)
        for n in [body, nose, wing, tail, stab, band, red, green, strobe] { g.addChildNode(n) }
        p.strobe = strobe

        if let banner, let (img, cw, ch) = CityLabel.image([banner], .init(height: 3.2, color: cityColor(0x1c2128),
                                                                          bg: NSColor(srgbRed: 1, green: 250 / 255, blue: 235 / 255, alpha: 0.96),
                                                                          accent: cityColor(0xd29922))) {
            let hh: Float = 3.2
            let sw = hh * Float(cw / ch)
            // A sprite would turn to face you; a banner should not. Two faces,
            // back to back, so it reads the right way round from either side.
            let mat = CityLabel.material(img)
            mat.isDoubleSided = false
            let mesh = SCNNode()
            let front = SCNNode.mesh(.plane(sw, hh), mat, shadow: false)
            let back = SCNNode.mesh(.plane(sw, hh), mat, shadow: false)
            back.simdEulerAngles.y = .pi
            mesh.addChildNode(front)
            mesh.addChildNode(back)
            mesh.simdEulerAngles.y = .pi / 2
            mesh.simdPosition = V3(0, -0.6, 14 + sw / 2)
            let rope = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(0, -0.4, 5), SCNVector3(0, -0.6, 14)])],
                                   elements: [SCNGeometryElement(indices: [UInt16(0), 1], primitiveType: .line)])
            rope.materials = [CityMat.basic(0x555555)]
            g.addChildNode(mesh)
            g.addChildNode(SCNNode(geometry: rope))
            p.banner = mesh
        }
        g.item = CityItem(kind: .plane)
        g.markPickable()
        return p
    }

    /// Something worth trailing behind a plane, about where you are.
    private func bannerText() -> String {
        let recs = items.values.filter { $0.kind == .building && $0.rec != nil }
        var pick: [String] = []
        if let big = recs.max(by: { ($0.rec?.bytes ?? 0) < ($1.rec?.bytes ?? 0) }) {
            pick.append("Biggest here: \(cityShort(big.entry?.name ?? "", 22)) — \(Fmt.bytes(big.rec?.bytes ?? 0))")
            let total = recs.reduce(0) { $0 + ($1.rec?.bytes ?? 0) }
            pick.append("\(recs.count) folders · \(Fmt.bytes(total)) below")
        }
        let d = dir ?? ""
        let base = d.split(separator: "/").last.map(String.init) ?? (d.isEmpty ? "here" : d)
        pick.append("Welcome to \(cityShort(base, 24))")
        pick.append("Visit beautiful " + cityShort(base, 20))
        return pick.randomElement() ?? ""
    }

    private func updatePlanes(_ dt: Float) {
        nextPlane -= dt
        if nextPlane <= 0 && planes.count < 2 {
            nextPlane = Float(14 + Double.random(in: 0..<1) * 20)
            let p = makePlane(Double.random(in: 0..<1) < 0.7 ? bannerText() : nil)
            let L = max(extent * 2, 300)
            let h = Float.random(in: 0..<(2 * .pi))
            var start = V3(center.x + cos(h) * L, 0, center.z + sin(h) * L)
            let lateral = Float.random(in: -0.5..<0.5) * extent
            var end = V3(center.x - cos(h) * L - sin(h) * lateral, 0, center.z - sin(h) * L + cos(h) * lateral)
            let alt = max(topHeight + 35, 70) + Float.random(in: 0..<40)
            start.y = alt; end.y = alt
            p.node.simdPosition = start
            // The model's nose is -z, which is what looking at the target points.
            p.node.simdLook(at: end, up: V3(0, 1, 0), localFront: V3(0, 0, -1))
            p.from = start
            p.to = end
            p.t = 0
            p.dur = simd_distance(start, end) / (32 + Float.random(in: 0..<14))
            planes.append(p)
            scene.rootNode.addChildNode(p.node)
        }
        for p in planes {
            p.t += dt / p.dur
            var pos = simd_mix(p.from, p.to, V3(repeating: p.t))
            pos.y += sin(p.t * 8) * 0.6
            p.node.simdPosition = pos
            p.strobe?.isHidden = !(time.truncatingRemainder(dividingBy: 1.2) < 0.08)
            if let b = p.banner { b.simdEulerAngles = V3(sin(time * 6) * 0.06, .pi / 2, 0) }
            if p.t >= 1 { p.node.removeFromParentNode() }
        }
        planes.removeAll { $0.t >= 1 }
    }

    // MARK: - Visitors

    /// Now and then a superhero crosses town, high enough to clear the tallest
    /// building, with a barrel roll somewhere over the middle for no reason.
    private func updateHero(_ dt: Float) {
        if hero == nil {
            nextHero -= dt
            if nextHero > 0 { return }
            nextHero = Float(35 + Double.random(in: 0..<1) * 45)
            let h = CityHero()
            let L = max(extent * 1.6, 220)
            let a = Float.random(in: 0..<(2 * .pi))
            let lateral = Float.random(in: -0.5..<0.5) * extent * 0.8
            let from = V3(center.x + cos(a) * L, 0, center.z + sin(a) * L)
            let to = V3(center.x - cos(a) * L - sin(a) * lateral, 0, center.z - sin(a) * L + cos(a) * lateral)
            let alt = max(topHeight + 10, 26) + Float.random(in: 0..<12)
            heroPath = (from, to, alt, 0, simd_distance(from, to) / (48 + Float.random(in: 0..<20)), 0.35 + Float.random(in: 0..<0.3))
            h.node.markPickable()
            hero = h
            scene.rootNode.addChildNode(h.node)
        }
        guard let h = hero, var u = heroPath else { return }
        u.t += dt / u.dur
        heroPath = u
        var p = simd_mix(u.from, u.to, V3(repeating: u.t))
        // Swoop in, level off over the town, climb away.
        p.y = u.alt + cos(u.t * .pi * 2) * 6
        h.node.simdPosition = p
        h.node.simdLook(at: V3(u.to.x, p.y, u.to.z), up: V3(0, 1, 0), localFront: V3(0, 0, -1))
        let r = (u.t - u.roll) / 0.08
        let roll = r > 0 && r < 1 ? r * .pi * 2 : sin(time * 1.5) * 0.12
        h.node.simdOrientation = h.node.simdOrientation
            * simd_quatf(angle: roll, axis: [0, 0, 1])
            * simd_quatf(angle: -sin(u.t * .pi * 2) * 0.25, axis: [1, 0, 0])
        h.flapCape(time, speed: 1.2)
        if u.t >= 1 {
            h.node.removeFromParentNode()
            hero = nil
            heroPath = nil
        }
    }

    /// A getaway car through the streets, with the police right behind it,
    /// lights going. Only in a city — a room has no streets — and never more
    /// than one at a time.
    private func updateChase(_ dt: Float) {
        if chase == nil {
            guard mode == "city", let st = streets else { return }
            nextChase -= dt
            if nextChase > 0 { return }
            nextChase = Float(30 + Double.random(in: 0..<1) * 40)
            guard let route = cityChaseRoute(xs: st.xs, zs: st.zs) else { return }
            let hover = style == "future"
            let suspect = CityCar(color: [0xd6452f, 0xe0b000, 0x2e8b57, 0x8e44ad, 0xf2f4f8].randomElement()!, hover: hover)
            let police = CityCar(police: true, hover: hover)
            suspect.node.markPickable()
            police.node.markPickable()
            chase = (route, suspect, police, 0, 24 + Float.random(in: 0..<6), 13 + Float.random(in: 0..<4))
            scene.rootNode.addChildNode(suspect.node)
            scene.rootNode.addChildNode(police.node)
        }
        guard var c = chase else { return }
        c.s += dt * c.speed
        chase = c
        func place(_ car: CityCar, _ s: Float) {
            let p = c.route.at(s)
            let ahead = c.route.at(s + 2.5)
            car.node.simdPosition = V3(p.x, 0.12 + (car.lift != 0 ? sin(time * 3 + s) * 0.15 : 0), p.z)
            if simd_distance_squared(ahead, p) > 1e-4 {
                let want = atan2(-(ahead.x - p.x), -(ahead.z - p.z))
                // Turn into the corner rather than snapping to the new street.
                var d = want - car.heading
                d = atan2(sin(d), cos(d))
                car.heading += d * min(1, dt * 9)
            }
            car.spinWheels(s)
        }
        place(c.suspect, c.s)
        place(c.police, max(0, c.s - c.gap))
        c.police.flashLights(time)
        if c.s - c.gap >= c.route.length { endChase() }
    }

    func endChase() {
        guard let c = chase else { return }
        c.suspect.node.removeFromParentNode()
        c.police.node.removeFromParentNode()
        chase = nil
    }

    /// Small labels only up close: a room of 400 signs is noise. Building
    /// signs shrink as you come up to them, so the one in front of you does
    /// not fill the screen.
    private func cullLabels() {
        let cam = cameraNode.simdPosition
        for it in items.values {
            guard let l = it.label, !it.dim else { continue }
            let d = simd_distance(cam, l.simdPosition)
            let visible = it.labelNear == nil || it.selected || d < it.labelNear!
            l.isHidden = !visible
            if it.labelScales && visible { l.simdScale = V3(repeating: cityClamp(d / 45, 0.3, 1)) }
        }
    }

    // MARK: - Processes as traffic

    func setTraffic(_ on: Bool) {
        trafficOn = on
        if !on { stopTraffic() }
        // The river and the launch pads need room cleared in the woods, and
        // giving it back when they go.
        rebuild()
        applyState()
        if on { startTraffic() }
        Store.shared.city3dTraffic = on
    }

    func startTraffic() {
        guard trafficOn, !destroyed else { return }
        if traffic == nil {
            let t = CityTraffic(scene: scene)
            t.layout(mode == "city" ? trafficLayout : nil)
            traffic = t
        }
        trafficTimer?.cancel()
        trafficSrc = host?.citySourceKey
        pollTraffic()
    }

    func stopTraffic() {
        trafficTimer?.cancel()
        trafficTimer = nil
        traffic?.dispose()
        traffic = nil
        trafficNote = ""
    }

    /// One look at the processes, then the next one booked. Locally every
    /// five seconds; on a server every ten, since each look is a command over
    /// the connection. A machine with no ps to ask — a stripped-down
    /// appliance — gets a note and no traffic, and the view goes on being a
    /// file browser.
    func pollTraffic() {
        guard trafficOn, traffic != nil, !destroyed, let host else { return }
        let local = host.citySourceKind == .local
        let src = host.citySourceKey
        let connId = host.cityConnId
        Task { @MainActor [weak self] in
            guard let self else { return }
            var next: Double = local ? 5 : 10
            do {
                var procs: [CityProc]?
                if local {
                    procs = try await CityService.procsLocal()
                } else if !CityService.isConnected(connId) {
                    self.trafficNote = "Processes: waiting for the connection"
                } else if CityService.needsMfaApproval(connId) && !self.mfaOk {
                    self.trafficNote = "Processes: each look would need an MFA approval — approve measuring to allow it"
                    self.approveShown = true
                } else {
                    procs = try await CityService.procsRemote(connId: connId ?? "")
                }
                if self.destroyed || self.traffic == nil || src != self.host?.citySourceKey { return }
                if let procs {
                    if procs.isEmpty { throw AppError("ps returned nothing") }
                    self.traffic?.update(procs)
                    self.trafficNote = ""
                }
            } catch {
                if self.destroyed || self.traffic == nil { return }
                let first = errorText(error).components(separatedBy: "\n")[0]
                self.trafficNote = "Processes: not available here (\(String(first.prefix(80)))) — the files are all still here"
                next = 60
            }
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.pollTraffic() } }
            self.trafficTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + next, execute: w)
        }
    }
}
