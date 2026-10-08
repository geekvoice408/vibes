import AppKit
import SceneKit
import SwiftUI
import simd

/*
 * The file explorer as a city (city3d.js).
 *
 * Every folder in the directory is a building: as tall as the data under it,
 * as wide as the number of files, and painted in bands by what those bytes
 * are — code, logs, images, archives. The loose files sit in the plaza in
 * front. Double-click a building to walk into it: inside, the files are crates
 * on the floor (sized and coloured the same way) and the folders are doors in
 * the walls.
 *
 * It is a view of an Explorer, not a second file manager. Where it is, what is
 * selected, the name filter, hidden files, search and the right-click menu are
 * all the explorer's own — so everything the toolbar does works here, and
 * switching back to the list loses nothing.
 */

enum CityKinds {
    static let order = ["code", "config", "docs", "images", "media", "archives", "logs", "data", "binaries", "secrets", "other"]
    static let colors: [String: Int] = [
        "code": 0x4c8dff, "config": 0xa371f7, "docs": 0xe3b341, "images": 0x3fb950, "media": 0xf778ba,
        "archives": 0xd18616, "logs": 0x56d4dd, "data": 0x2ea4a0, "binaries": 0xda3633, "secrets": 0xffd33d,
        "other": 0x8b95a5,
    ]
    static let labels: [String: String] = [
        "code": "Code", "config": "Config", "docs": "Documents", "images": "Images", "media": "Audio & video",
        "archives": "Archives", "logs": "Logs", "data": "Data & disks", "binaries": "Binaries",
        "secrets": "Keys & certs", "other": "Other",
    ]
    static let measuring = 0x5b6475
    static let empty = 0x3a404c

    /// Height of a building for this many bytes — logarithmic, or one tall folder hides the rest.
    static func heightFor(_ bytes: Double) -> Float { Float(3 + 5.2 * log2(1 + bytes / 32768)) }
    static func footFor(_ files: Int) -> Float { Float(cityClamp(10 + 2 * log2(1 + Double(files)), 10, 26)) }
    static func crateFor(_ bytes: Double) -> Float { Float(cityClamp(0.45 + 0.3 * log2(1 + bytes / 4096), 0.45, 2.8)) }

    /// Bytes per kind, biggest first, small slivers folded into "other".
    static func bands(_ rec: CityRec) -> [(String, Double)] {
        let total = rec.bytes
        if total <= 0 { return [] }
        var out: [(String, Double)] = []
        var other: Double = 0
        for k in order {
            guard let b = rec.kinds[k], b > 0 else { continue }
            if k == "other" || b / total < 0.03 { other += b } else { out.append((k, b)) }
        }
        // Kinds the table does not know (none today) count as other.
        for (k, b) in rec.kinds where colors[k] == nil && b > 0 { other += b }
        if other > 0 { out.append(("other", other)) }
        return out.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }.map(\.element)
    }

    static func summary(_ rec: CityRec) -> String {
        let bs = bands(rec)
        if bs.isEmpty { return "" }
        return bs.prefix(4).map { "\(labels[$0.0] ?? $0.0) \(Int((100 * $0.1 / rec.bytes).rounded()))%" }.joined(separator: " · ")
    }
}

let cityEye: Float = 1.7         // eye height when walking
let cityCell: Float = 36         // city block pitch
private let MIN_GRID = 4         // a town is at least this many blocks across, parks filling the gaps
private let MAX_BUILDINGS = 600
private let MAX_CRATES = 400

/// A box you cannot walk through, and can stand on.
struct CitySolid { var x0, x1, z0, z1, top: Float }

/// The hover card.
struct CityTip: Equatable {
    struct Line: Equatable { var cls: String; var text: String }
    var lines: [Line]
    var at: CGPoint
}

@MainActor
@Observable
final class CityController {
    // MARK: what the HUD shows

    var whereText = ""
    var whereTitle = ""
    var measureNote = ""
    var trafficNote = ""
    var approveShown = false
    var flying = true
    var mode = "city"            // "city" | "room"
    var trafficOn: Bool
    var style: String
    var legend: [String] = []
    var tip: CityTip?
    var helpShown = false
    var outText = ""
    var outTitle = ""
    var outHidden = false
    var hereHidden = true
    var maximized = false
    var pointer = false

    // MARK: the explorer

    @ObservationIgnored weak var host: CityExplorerHost?
    @ObservationIgnored private(set) var dir: String?
    @ObservationIgnored private var src: String?
    @ObservationIgnored private var sig: String?
    @ObservationIgnored var nextMode: String?
    @ObservationIgnored var returnFrom: String?
    @ObservationIgnored var mfaOk = false
    @ObservationIgnored private(set) var destroyed = false

    // MARK: the scene

    @ObservationIgnored let scnView: CitySCNView
    @ObservationIgnored let scene = SCNScene()
    @ObservationIgnored let cameraNode = SCNNode()
    @ObservationIgnored var world = SCNNode()
    @ObservationIgnored let sunNode = SCNNode()
    @ObservationIgnored let win = CityWindowTextures()
    @ObservationIgnored var night = false
    @ObservationIgnored var yaw: Float = 0
    @ObservationIgnored var pitch: Float = -0.3
    @ObservationIgnored var vy: Float = 0
    @ObservationIgnored var keys = Set<UInt16>()
    @ObservationIgnored var items: [String: CityItem] = [:]
    @ObservationIgnored var solids: [CitySolid] = []
    @ObservationIgnored var extent: Float = 60
    @ObservationIgnored var center = V3.zero
    @ObservationIgnored var bounds: (W: Float, D: Float, GAP: Float)?
    @ObservationIgnored var time: Float = 0
    @ObservationIgnored var hover: CityItem?
    @ObservationIgnored var topHeight: Float = 0
    @ObservationIgnored var plazaFront: Float = 10
    @ObservationIgnored var spinners: [CitySpinner] = []
    @ObservationIgnored var streets: (xs: [Float], zs: [Float])?
    @ObservationIgnored var hero: CityHero?
    @ObservationIgnored var heroPath: (from: V3, to: V3, alt: Float, t: Float, dur: Float, roll: Float)?
    @ObservationIgnored var chase: (route: CityPath, suspect: CityCar, police: CityCar, s: Float, speed: Float, gap: Float)?
    @ObservationIgnored var nextHero = Float(12 + Double.random(in: 0..<1) * 15)
    @ObservationIgnored var nextChase = Float(8 + Double.random(in: 0..<1) * 12)
    @ObservationIgnored var traffic: CityTraffic?
    @ObservationIgnored var trafficLayout: CityTrafficLayout?
    @ObservationIgnored var trafficSrc: String?
    @ObservationIgnored var trafficTimer: DispatchWorkItem?
    @ObservationIgnored var clouds: [(node: SCNNode, r: Float, a: Float, speed: Float, y: Float)] = []
    @ObservationIgnored var flocks: [CityFlock] = []
    @ObservationIgnored var planes: [CityPlane] = []
    @ObservationIgnored var nextPlane: Float = 3
    @ObservationIgnored var loopTimer: Timer?
    @ObservationIgnored var last = CACurrentMediaTime()
    @ObservationIgnored var frame = 0
    @ObservationIgnored var leaving = false
    @ObservationIgnored var drag: (x: CGFloat, y: CGFloat, moved: Bool)?

    /// The view the explorer puts in place of its list.
    /// Made on each request rather than kept: a kept view holding the
    /// controller would be a cycle that outlives `destroy()`.
    var view: AnyView { AnyView(CityView(city: self)) }
    /// A host adapter the controller keeps alive (the explorer holds the controller).
    @ObservationIgnored var keepAlive: AnyObject?

    init(host: CityExplorerHost) {
        self.host = host
        style = CityStyle.byId(Store.shared.city3dStyle).id
        trafficOn = Store.shared.city3dTraffic
        scnView = CitySCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        scnView.city = self
        initGL()
        initSky()
        setFlying(true)
        if trafficOn { startTraffic() }
        startLoop()
        track()
        debugShot()
    }

    /// `--city-shot out.png [--city-shot-actions keys]`: the rendered scene
    /// (screen capture of a Metal layer is not possible with --snapshot),
    /// for checking the port by eye.
    private func debugShot() {
        guard let out = DebugSnapshot.arg("--city-shot") else { return }
        let delay = Double(DebugSnapshot.arg("--city-shot-delay") ?? "4") ?? 4
        if let st = DebugSnapshot.arg("--city-style") { style = CityStyle.byId(st).id }
        if DebugSnapshot.arg("--city-walk") != nil { after(delay - 1.5) { [weak self] in self?.setFlying(false); self?.spawn() } }
        if let into = DebugSnapshot.arg("--city-enter") {
            after(delay - 2.5) { [weak self] in
                guard let self, let it = self.items.values.first(where: { $0.entry?.name == into }) else { return }
                self.activate(it)
            }
        }
        after(delay) { [weak self] in
            guard let self, let img = Optional(self.scnView.snapshot()),
                  let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: out))
            print("city-shot: \(out)")
        }
    }

    // MARK: - GL

    private func initGL() {
        let cam = SCNCamera()
        cam.fieldOfView = 65
        cam.projectionDirection = .vertical
        cam.zNear = 0.1
        cam.zFar = 5000
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(world)
        scnView.scene = scene
        scnView.pointOfView = cameraNode
        scnView.antialiasingMode = .multisampling4X
        scnView.rendersContinuously = true
        scnView.preferredFramesPerSecond = 60
        scnView.backgroundColor = NSColor(srgbRed: 10 / 255, green: 19 / 255, blue: 36 / 255, alpha: 1)
    }

    /// Sun or moon, sky, ground, clouds, stars, birds and planes — the parts that never rebuild.
    private func initSky() {
        let light = Theme.shared.p.tone == .light
        night = !light
        let sky = light ? 0x9fd3ff : 0x1a2747
        scene.fogColor = cityColor(sky)
        scene.fogStartDistance = 200
        scene.fogEndDistance = 900
        // Stars live in the backdrop, where the fog does not reach them.
        scene.background.contents = night ? CitySky.starryBackdrop(sky) : cityColor(sky)

        // Night is dusk rather than dark: the colours are the information.
        // The hemisphere light: sky colour from above, ground colour from below.
        scene.lightingEnvironment.contents = CitySky.hemisphere(top: light ? 0xdff1ff : 0x8ea6d8, bottom: light ? 0x4f6b3a : 0x2a3140)
        scene.lightingEnvironment.intensity = light ? 1.15 : 1.35
        let sun = SCNLight()
        sun.type = .directional
        sun.color = cityColor(light ? 0xfff2dc : 0xc4d2ff)
        sun.intensity = light ? 1900 : 1100
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowMode = .forward
        sun.shadowSampleCount = 8
        sun.shadowRadius = 2
        sun.shadowColor = NSColor(white: 0, alpha: 0.55)
        sun.automaticallyAdjustsShadowProjection = false
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)

        let ground = SCNNode.mesh(.plane(6000, 6000), CityMat.std(light ? 0x6f9a5a : 0x2f4a35, roughness: 1), shadow: false)
        ground.simdEulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(ground)

        // Clouds: a few lumps of flat-shaded spheres, drifting.
        let cloudMat = CityMat.lambert(light ? 0xffffff : 0x3b465c)
        let puff = SCNSphere(radius: 1)
        puff.isGeodesic = true
        puff.segmentCount = 2
        puff.materials = [cloudMat]
        for _ in 0..<10 {
            let c = SCNNode()
            let n = 4 + Int.random(in: 0..<4)
            for k in 0..<n {
                let m = SCNNode(geometry: puff)
                let s = Float(6 + Double.random(in: 0..<1) * 8)
                m.simdScale = V3(s * 1.4, s * 0.8, s)
                m.simdPosition = V3((Float(k) - Float(n) / 2) * 9 + Float.random(in: 0..<4), Float.random(in: 0..<4), Float.random(in: 0..<8) - 4)
                m.castsShadow = false
                c.addChildNode(m)
            }
            clouds.append((c, Float(120 + Double.random(in: 0..<1) * 380), Float.random(in: 0..<(2 * .pi)),
                           Float(0.004 + Double.random(in: 0..<1) * 0.006), Float(110 + Double.random(in: 0..<1) * 60)))
            scene.rootNode.addChildNode(c)
        }

        initBirds()
    }

    // MARK: - Explorer → view

    /// Called whenever the explorer redraws. Cheap unless the folder changed.
    func sync() {
        guard !destroyed, let host else { return }
        if host.citySourceKind == .s3 { City.toggle(host, on: false); return }
        guard let path = host.cityPath else { return }
        let s = signature()
        if path != dir || host.citySourceKey != src {
            if let m = nextMode { mode = m }
            nextMode = nil
            dir = path
            src = host.citySourceKey
            sig = s
            rebuild(spawn: true)
            measure(path)
            // Another machine is other processes.
            if trafficOn && trafficSrc != src { stopTraffic(); startTraffic() }
        } else if s != sig {
            sig = s
            rebuild()
        }
        applyState()
    }

    /// Follow the explorer's observable state without being told (an
    /// `@Observable` explorer model makes this fire; `sync()` works either way).
    private func track() {
        guard let host, !destroyed else { return }
        withObservationTracking {
            _ = host.cityPath
            _ = host.cityEntries
            _ = host.citySourceKey
            _ = host.cityShowHidden
            _ = host.citySelection
            _ = host.cityFilterActive
            _ = host.cityMatcher()
            _ = host.cityMaximized
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.destroyed else { return }
                self.maximized = self.host?.cityMaximized ?? false
                self.sync()
                self.track()
            }
        }
    }

    private func signature() -> String {
        guard let host else { return "" }
        var parts = [host.cityPath ?? "", String(host.cityShowHidden), mode]
        parts += host.cityEntries.map { "\($0.name):\($0.size):\($0.type.rawValue)" }
        return parts.joined(separator: "|")
    }

    /// Forget the measurements for the folder on screen, and take them again
    /// (the explorer calls this on Refresh).
    func invalidate() {
        guard let dir else { return }
        CityScans.shared.forget(scanKey(dir))
        measure(dir)
    }

    private func scanKey(_ dir: String) -> String { (host?.citySourceKey ?? "") + "|" + dir }

    func measure(_ dir: String?) {
        guard let dir, let host else { return }
        let key = scanKey(dir)
        if let r = CityScans.shared.cached(key) { noteMeasured(r); return }
        let local = host.citySourceKind == .local
        let connId = host.cityConnId
        if !local {
            guard CityService.isConnected(connId) else { return }
            // On a per-session-MFA host a scan is one more approval; ask first.
            if CityService.needsMfaApproval(connId) && !mfaOk {
                measureNote = "Buildings are not measured yet."
                approveShown = true
                return
            }
        }
        approveShown = false
        measureNote = "Measuring the folders…"
        Task { @MainActor [weak self] in
            do {
                let r = try await CityScans.shared.measure(key) {
                    local ? try await CityService.scanLocal(dir) : try await CityService.scanRemote(connId: connId ?? "", dir: dir)
                }
                guard let self, !self.destroyed, self.dir == dir else { return }
                self.noteMeasured(r)
                self.rebuild()
                self.applyState()
            } catch {
                guard let self, self.dir == dir else { return }
                self.measureNote = "Could not measure: " + errorText(error)
            }
        }
    }

    private func noteMeasured(_ r: CityScanResult) {
        measureNote = r.truncated ? "Stopped measuring early — big trees are a floor, not the total." : ""
    }

    func rec(_ entry: FileEntry) -> CityRec? {
        guard let dir, let s = CityScans.shared.cached(scanKey(dir)) else { return nil }
        return s.children[entry.name] ?? CityRec()
    }

    // MARK: - Building the world

    func rebuild(spawn: Bool = false) {
        tip = nil
        hover = nil
        var prev: [String: Float] = [:]
        for (p, it) in items { prev[p] = it.h }
        world.removeFromParentNode()
        world = SCNNode()
        scene.rootNode.addChildNode(world)
        items = [:]
        solids = []
        topHeight = 0
        spinners = []
        streets = nil
        trafficLayout = nil
        // A chase mid-way through streets that just moved would drive through walls.
        endChase()

        // Hidden files go; the name filter only dims, so a filter reads as "these, here".
        let entries = host?.cityShownEntries() ?? []
        let dirs = entries.filter(\.isDirectoryLike)
        let files = entries.filter { !$0.isDirectoryLike }
        if mode == "room" { buildRoom(dirs, files, prev) } else { buildCity(dirs, files, prev) }

        drawLegend()
        syncHud()
        sig = signature()

        // Shadows cover the place you are in, whatever its size.
        let ext = extent
        if let sun = sunNode.light {
            sun.orthographicScale = CGFloat(ext)
            sun.zNear = 1
            sun.zFar = CGFloat(ext * 4 + 300)
        }
        sunNode.simdPosition = V3(center.x + ext * 0.6, ext * 1.4 + 120, center.z + ext * 0.4)
        sunNode.simdLook(at: center, up: V3(0, 1, 0), localFront: V3(0, 0, -1))
        scene.fogStartDistance = CGFloat(max(120, ext * 1.4))
        scene.fogEndDistance = CGFloat(max(700, ext * 5))

        traffic?.layout(mode == "city" ? trafficLayout : nil)
        if spawn { self.spawn() }
    }

    func material(_ color: Int) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = win.map(color)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 4
        if night {
            m.emission.contents = win.emissive
            m.emission.wrapS = .repeat
            m.emission.wrapT = .repeat
            m.emission.intensity = 0.55
        }
        m.roughness.contents = 0.75
        m.metalness.contents = 0.08
        return m
    }

    private func buildCity(_ dirs: [FileEntry], _ files: [FileEntry], _ prev: [String: Float]) {
        let shown = Array(dirs.prefix(MAX_BUILDINGS))
        let n = shown.count
        let cols = max(MIN_GRID, Int(ceil(sqrt(Double(n) * 1.3))))
        let rows = max(MIN_GRID, Int(ceil(Double(n) / Double(cols))))
        let width = Float(cols) * cityCell
        let x0 = -Float(cols - 1) * cityCell / 2
        let z0 = -cityCell / 2 - 8                          // the first row's centre
        let zFront = z0 + cityCell / 2                      // the street you arrive on
        let zBack = z0 - Float(rows - 1) * cityCell - cityCell / 2
        func cellAt(_ i: Int) -> (x: Float, z: Float) { (x0 + Float(i % cols) * cityCell, z0 - Float(i / cols) * cityCell) }

        // Streets: one slab of asphalt under the blocks, pavements on top.
        let road = SCNNode.mesh(.box(width + 12, 0.1, Float(rows) * cityCell + 12),
                                CityMat.std(night ? 0x262b35 : 0x3a3f47, roughness: 0.95), shadow: false)
        world.addChildNode(road.at(0, 0.05, (zFront + zBack) / 2))

        let paveMat = CityMat.std(night ? 0x4a515e : 0xb9bdc4, roughness: 0.9)
        let doorMat = CityMat.std(0x1b1f27, roughness: 0.6, emissive: night ? 0x332200 : 0)

        for (i, entry) in shown.enumerated() {
            let (x, z) = cellAt(i)
            let rec = self.rec(entry)
            let w = rec.map { CityKinds.footFor($0.files) } ?? 12
            let h: Float = rec.map { $0.bytes > 0 ? CityKinds.heightFor($0.bytes) : 1.6 } ?? 4.4
            topHeight = max(topHeight, h)

            world.addChildNode(SCNNode.mesh(.box(w + 5, 0.3, w + 5), paveMat, shadow: false).at(x, 0.2, z))

            let g = CityNode()
            g.simdPosition = V3(x, 0.35, z)
            var mats: [SCNMaterial] = []
            var bs: [(Int, Double)] = rec.map { CityKinds.bands($0).map { (CityKinds.colors[$0.0] ?? CityKinds.colors["other"]!, $0.1) } } ?? []
            if bs.isEmpty { bs.append((rec != nil ? CityKinds.empty : CityKinds.measuring, 1)) }
            // The shape is the style's; the height, footprint and bands are the
            // folder's, whichever style is chosen.
            let night = self.night
            let built = cityBuildTower(g, CityTowerSpec(
                styleId: style, seed: entry.path, w: w, h: h, bands: bs,
                bandMat: { [unowned self] c in let m = self.material(c); mats.append(m); return m },
                accent: { c, metal, glow in
                    let m = CityMat.std(c, roughness: CGFloat(0.7 - metal * 0.4), metalness: CGFloat(metal),
                                        emissive: glow > 0 ? c : 0, emissiveIntensity: CGFloat(glow * (night ? 1 : 0.5)))
                    mats.append(m)
                    return m
                },
                night: night))
            let H = built.H
            for s in built.spin { s.group = g; spinners.append(s) }
            let dh = min(4.2, H)
            g.addChildNode(SCNNode.mesh(.box(3, dh, 0.3), doorMat, shadow: false).at(0, dh / 2, w / 2 + 0.08))

            let item = CityItem(kind: .building, entry: entry)
            item.rec = rec; item.group = g; item.mats = mats; item.h = H; item.w = w; item.x = x; item.z = z
            g.item = item
            g.markPickable()
            let from = prev[entry.path]
            item.grow = from == nil ? 0.02 : cityClamp(from! / H, 0.02, 4)
            g.simdScale = V3(1, item.grow, 1)
            world.addChildNode(g)

            let firstBand = rec.flatMap { CityKinds.bands($0).first?.0 }
            let accent = firstBand.flatMap { CityKinds.colors[$0] } ?? CityKinds.measuring
            let label = CityLabel.make([cityShort(entry.name), rec.map { Fmt.bytes($0.bytes) } ?? "measuring…"],
                                       CityLabel.Style(height: 3.6, accent: cityColor(accent)))
            item.label = label
            item.labelY = built.top + 4
            topHeight = max(topHeight, built.top)
            label.simdPosition = V3(x, item.labelY * item.grow + 0.35, z)
            label.item = item
            item.labelNear = 260
            item.labelScales = true
            world.addChildNode(label)

            items[entry.path] = item
            solids.append(CitySolid(x0: x - w / 2, x1: x + w / 2, z0: z - w / 2, z1: z + w / 2, top: H + 0.35))
        }

        // Blocks with no folder on them are parks, so a small folder is still a town.
        var trees: [(Float, Float, Float)] = []
        let grassMat = CityMat.std(night ? 0x35583c : 0x7fb069, roughness: 1)
        for i in n..<(cols * rows) {
            let p = cellAt(i)
            world.addChildNode(SCNNode.mesh(.box(cityCell - 8, 0.3, cityCell - 8), grassMat, shadow: false).at(p.x, 0.2, p.z))
            let k = 4 + Int.random(in: 0..<5)
            for _ in 0..<k {
                trees.append((p.x + Float.random(in: -0.5..<0.5) * (cityCell - 14), p.z + Float.random(in: -0.5..<0.5) * (cityCell - 14),
                              0.8 + Float.random(in: 0..<0.7)))
            }
        }
        // With the processes shown, a river behind the town and launch pads to
        // the east — and the woods kept off both.
        let riverZ = zBack - 34
        let padX = width / 2 + 36
        let padsZ = [zFront - 14, zFront - 48, zFront - 82]
        let trafficOn = self.trafficOn
        func clearing(_ x: Float, _ z: Float) -> Bool {
            guard trafficOn else { return false }
            return abs(z - riverZ) < 17 || (x > padX - 16 && x < padX + 16 && z < zFront + 4 && z > padsZ[2] - 14)
        }
        if trafficOn {
            trafficLayout = CityTrafficLayout(
                river: .init(z: riverZ, width: 24, x0: -width / 2 - 240, x1: width / 2 + 240),
                pads: padsZ.map { (padX, $0) }, night: night, hover: style == "future", streets: nil)
        }
        // A belt of woods around the edge of town, out to the horizon-ish.
        let rx = width / 2 + 14, rz0 = zBack - 14, rz1 = zFront + 14
        for _ in 0..<420 {
            let a = Float.random(in: 0..<(2 * .pi))
            let d = 10 + pow(Float.random(in: 0..<1), 0.7) * 160
            let x = cos(a) * (rx + d)
            let z = (rz0 + rz1) / 2 + sin(a) * ((rz1 - rz0) / 2 + d)
            // Keep the approach to the plaza open.
            if z > zFront && abs(x) < width / 2 + 10 { continue }
            if clearing(x, z) { continue }
            trees.append((x, z, 0.8 + Float.random(in: 0..<1.1)))
        }
        plantTrees(trees)
        lamps(cols, rows, x0, z0)
        streets = ((0...cols).map { x0 - cityCell / 2 + Float($0) * cityCell },
                   (0...rows).map { z0 + cityCell / 2 - Float($0) * cityCell })
        trafficLayout?.streets = streets

        // The plaza: loose files, in front of the city where you arrive.
        let plazaFiles = Array(files.enumerated().sorted { a, b in
            a.element.size != b.element.size ? a.element.size > b.element.size : a.offset < b.offset
        }.map(\.element).prefix(MAX_CRATES))
        let PX: Float = 4, PZ: Float = 4.2
        let pcols = max(10, Int(floor(max(width * 0.7, 60) / PX)))
        let pStart = zFront + 14
        for (i, entry) in plazaFiles.enumerated() {
            let c = i % pcols, r = i / pcols
            crate(entry, -Float(pcols - 1) * PX / 2 + Float(c) * PX, pStart + Float(r) * PZ, prev, small: true)
        }
        let plazaDepth: Float = plazaFiles.isEmpty ? 0 : Float((plazaFiles.count + pcols - 1) / pcols) * PZ + 8
        if !plazaFiles.isEmpty {
            let plaza = SCNNode.mesh(.box(Float(pcols) * PX + 8, 0.12, plazaDepth + 4),
                                     CityMat.std(night ? 0x5a5240 : 0xd8cfb8, roughness: 0.95), shadow: false)
            world.addChildNode(plaza.at(0, 0.06, pStart - 4 + plazaDepth / 2))
        }
        if files.count > plazaFiles.count {
            let sign = CityLabel.make(["+\(files.count - plazaFiles.count) more files", "the list view has them all"], .init(height: 1.4))
            world.addChildNode(sign.at(0, 4, pStart + plazaDepth))
        }

        if n == 0 && files.isEmpty {
            let sign = CityLabel.make(["Nothing here", "an empty lot"], .init(height: 3))
            world.addChildNode(sign.at(0, 6, z0))
        }

        let depth = (zFront - zBack) + plazaDepth + 30
        extent = max(90, max(width, depth) / 2 + 30)
        center = V3(0, 0, (zBack + zFront + plazaDepth) / 2)
        bounds = nil
        plazaFront = pStart + plazaDepth
    }

    /// Trees, merged into one node per colour: one draw call for a forest.
    private func plantTrees(_ list: [(Float, Float, Float)]) {
        if list.isEmpty { return }
        var trunk = CityMesh.cylinder(0.35, 0.5, 3, 6)
        trunk.translate(0, 1.5, 0)
        var leaf = CityMesh.cone(2.6, 7, 7)
        leaf.translate(0, 6, 0)
        let greens = night ? [0x2e5a3a, 0x3a6b45, 0x284d33] : [0x3f8f4a, 0x2f7a3d, 0x5aa04f, 0x4b8a3c]
        var trunks = CityMesh()
        var leaves = [CityMesh](repeating: CityMesh(), count: greens.count)
        for (i, t) in list.enumerated() {
            let (x, z, sc) = t
            let rot = simd_float3x3(simd_quatf(angle: Float.random(in: 0..<6), axis: [0, 1, 0])) * simd_float3x3(diagonal: V3(repeating: sc))
            var tr = trunk; tr.apply(rot); tr.translate(x, 0, z); trunks.append(tr)
            var lf = leaf; lf.apply(rot); lf.translate(x, 0, z); leaves[i % greens.count].append(lf)
        }
        world.addChildNode(SCNNode.mesh(trunks, CityMat.std(0x6b4a2f, roughness: 1)))
        for (k, m) in leaves.enumerated() where !m.pos.isEmpty {
            world.addChildNode(SCNNode.mesh(m, CityMat.std(greens[k], roughness: 0.9)))
        }
    }

    /// Street lamps at the crossroads — lit at night.
    private func lamps(_ cols: Int, _ rows: Int, _ x0: Float, _ z0: Float) {
        var pole = CityMesh.cylinder(0.15, 0.2, 7, 6)
        pole.translate(0, 3.5, 0)
        var bulb = CityMesh.sphere(0.55, 10, 8)
        bulb.translate(0, 7.2, 0)
        var poles = CityMesh(), bulbs = CityMesh()
        for c in 0...cols {
            for r in 0...rows {
                let x = x0 - cityCell / 2 + Float(c) * cityCell, z = z0 + cityCell / 2 - Float(r) * cityCell
                var p = pole; p.translate(x, 0, z); poles.append(p)
                var b = bulb; b.translate(x, 0, z); bulbs.append(b)
            }
        }
        world.addChildNode(SCNNode.mesh(poles, CityMat.std(0x2b303a, roughness: 0.6, metalness: 0.4), shadow: false))
        world.addChildNode(SCNNode.mesh(bulbs, CityMat.std(0xfff2c8, emissive: 0xffd27a, emissiveIntensity: night ? 1 : 0.2), shadow: false))
    }

    @discardableResult
    private func crate(_ entry: FileEntry, _ x: Float, _ z: Float, _ prev: [String: Float], small: Bool = false) -> CityItem {
        let s = CityKinds.crateFor(Double(entry.size)) * (small ? 1.2 : 1)
        let k = FileKinds.kindOf(entry.name)
        let mat = CityMat.std(CityKinds.colors[k] ?? 0x8b95a5, roughness: 0.55, metalness: 0.1)
        let g = CityNode()
        g.simdPosition = V3(x, 0, z)
        g.addChildNode(SCNNode.mesh(.box(s, s, s), mat).at(0, s / 2, 0))
        // A lid strip so a crate reads as a crate rather than a cube.
        g.addChildNode(SCNNode.mesh(.box(s * 1.04, s * 0.08, s * 1.04), CityMat.std(0x2b303a, roughness: 0.7)).at(0, s * 0.96, 0))
        let item = CityItem(kind: .crate, entry: entry)
        item.group = g; item.mats = [mat]; item.h = s; item.w = s; item.x = x; item.z = z
        g.item = item
        g.markPickable()
        item.grow = prev[entry.path] == nil ? 0.02 : 1
        g.simdScale = V3(1, item.grow, 1)
        world.addChildNode(g)
        let label = CityLabel.make([cityShort(entry.name, 30), Fmt.bytes(Double(entry.size))], .init(height: small ? 0.5 : 0.38))
        item.label = label
        item.labelY = s + 0.6
        label.simdPosition = V3(x, item.labelY, z)
        label.item = item
        item.labelNear = small ? 22 : 14
        world.addChildNode(label)
        items[entry.path] = item
        solids.append(CitySolid(x0: x - s / 2, x1: x + s / 2, z0: z - s / 2, z1: z + s / 2, top: s))
        return item
    }

    private func buildRoom(_ dirs: [FileEntry], _ files: [FileEntry], _ prev: [String: Float]) {
        let crates = Array(files.prefix(MAX_CRATES))
        let SP: Float = 3.4
        let fc = max(1, Int(ceil(sqrt(Double(crates.count)))))
        let doors = Array(dirs.prefix(MAX_BUILDINGS))
        var W = max(16, Float(fc) * SP + 8)
        var D = max(16, Float((crates.count + fc - 1) / fc) * SP + 10)
        // Room enough on the walls for every door, leaving the exit clear.
        let need = Float(doors.count * 4 + 8)
        if 2 * W + 2 * D < need { let k = need / (2 * W + 2 * D); W = ceil(W * k); D = ceil(D * k) }
        let WALL: Float = 6, T: Float = 0.4

        world.addChildNode(SCNNode.mesh(.box(W, 0.2, D), CityMat.std(night ? 0x4a3a2a : 0xa98463, roughness: 0.85), shadow: false).at(0, 0.1, 0))

        let wallMat = CityMat.std(night ? 0x59606e : 0xe9e4da, roughness: 0.9)
        func wall(_ x: Float, _ z: Float, _ w: Float, _ d: Float) {
            world.addChildNode(SCNNode.mesh(.box(w, WALL, d), wallMat).at(x, WALL / 2, z))
            solids.append(CitySolid(x0: x - w / 2, x1: x + w / 2, z0: z - d / 2, z1: z + d / 2, top: WALL))
        }
        let GAP: Float = 3.2
        wall(0, -D / 2, W + T, T)
        wall(-W / 2, 0, T, D)
        wall(W / 2, 0, T, D)
        wall(-(W / 2 + GAP / 2) / 2, D / 2, W / 2 - GAP / 2, T)
        wall((W / 2 + GAP / 2) / 2, D / 2, W / 2 - GAP / 2, T)

        // Exit: the gap in the south wall, with a sign over it.
        let exitSign = CityLabel.make(["⇦ Out to the street"], .init(height: 0.7, bg: NSColor(srgbRed: 26 / 255, green: 127 / 255, blue: 55 / 255, alpha: 0.92)))
        exitSign.simdPosition = V3(0, 3.6, D / 2 - 0.3)
        exitSign.item = CityItem(kind: .exit)
        exitSign.markPickable()
        world.addChildNode(exitSign)

        // Doors around the walls: north, then east, west, then the south either side of the exit.
        var slots: [(x: Float, z: Float, ry: Float)] = []
        func along(_ len: Float, _ f: (Float) -> Void) {
            let k = Int(floor((len - 2) / 4))
            for i in 0..<max(0, k) { f(-len / 2 + 1 + 2 + Float(i) * 4 + ((len - 2) - Float(k) * 4) / 2) }
        }
        along(W) { slots.append(($0, -D / 2 + T / 2 + 0.06, 0)) }
        along(D) { slots.append((W / 2 - T / 2 - 0.06, $0, -.pi / 2)) }
        along(D) { slots.append((-W / 2 + T / 2 + 0.06, $0, .pi / 2)) }
        along(W) { x in if abs(x) > GAP / 2 + 2 { slots.append((x, D / 2 - T / 2 - 0.06, .pi)) } }
        let frameDark = CityMat.std(0x1b1f27, roughness: 0.6)
        let knobMat = CityMat.std(0xd2b048, roughness: 0.3, metalness: 0.8)
        for (i, entry) in doors.enumerated() {
            guard i < slots.count else { break }
            let s = slots[i]
            let rec = self.rec(entry)
            let k = rec.map { CityKinds.bands($0).first?.0 ?? "other" }
            let color = rec.map { $0.bytes > 0 ? (CityKinds.colors[k ?? "other"] ?? 0x8b95a5) : CityKinds.empty } ?? CityKinds.measuring
            let g = CityNode()
            g.simdPosition = V3(s.x, 0, s.z)
            g.simdEulerAngles.y = s.ry
            let frameMat = CityMat.std(color, roughness: 0.6)
            g.addChildNode(SCNNode.mesh(.box(2.6, 3.4, 0.25), frameMat).at(0, 1.7, 0))
            g.addChildNode(SCNNode.mesh(.box(2, 3, 0.3), frameDark).at(0, 1.5, 0.05))
            g.addChildNode(SCNNode.mesh(.sphere(0.1, 8, 8), knobMat, shadow: false).at(0.7, 1.4, 0.25))
            let item = CityItem(kind: .door, entry: entry)
            item.rec = rec; item.group = g; item.mats = [frameMat]; item.h = 3.4; item.w = 2.6; item.x = s.x; item.z = s.z
            g.item = item
            g.markPickable()
            world.addChildNode(g)
            let second = rec.map { Fmt.bytes($0.bytes) + ($0.files > 0 ? " · \($0.files) files" : "") } ?? "…"
            let label = CityLabel.make(["📁 " + cityShort(entry.name, 22), second], .init(height: 0.42))
            let inward = simd_quatf(angle: s.ry, axis: [0, 1, 0]).act(V3(0, 0, 0.6))
            label.simdPosition = V3(s.x + inward.x, 4.1, s.z + inward.z)
            item.label = label
            item.labelY = 4.1
            item.grow = 1
            label.item = item
            world.addChildNode(label)
            items[entry.path] = item
        }
        if doors.count > slots.count {
            world.addChildNode(CityLabel.make(["+\(doors.count - slots.count) more folders"], .init(height: 0.6)).at(0, 5, -D / 2 + 1))
        }

        // Crates in aisles.
        let cx0 = -Float(fc - 1) * SP / 2
        for (i, entry) in crates.enumerated() {
            let c = i % fc, r = i / fc
            crate(entry, cx0 + Float(c) * SP, -D / 2 + 4 + Float(r) * SP, prev)
        }
        if files.count > crates.count {
            world.addChildNode(CityLabel.make(["+\(files.count - crates.count) more files", "the list view has them all"], .init(height: 0.5)).at(0, 2.5, D / 2 - 3))
        }
        if files.isEmpty && doors.isEmpty {
            world.addChildNode(CityLabel.make(["An empty room"], .init(height: 0.8)).at(0, 2.5, 0))
        }

        // A ceiling light, for night.
        if night {
            let lamp = SCNLight()
            lamp.type = .omni
            lamp.color = cityColor(0xffe2b0)
            lamp.intensity = 500
            lamp.attenuationStartDistance = 0
            lamp.attenuationEndDistance = CGFloat(max(W, D) * 1.2)
            lamp.attenuationFalloffExponent = 1.6
            let ln = SCNNode()
            ln.light = lamp
            world.addChildNode(ln.at(0, WALL + 2, 0))
        }

        topHeight = WALL
        extent = max(40, max(W, D) / 2 + 10)
        center = .zero
        bounds = (W, D, GAP)
    }

    // MARK: - Where you stand

    func spawn() {
        if mode == "room", let b = bounds {
            setFlying(false)
            cameraNode.simdPosition = V3(0, cityEye, b.D / 2 - 2)
            yaw = 0
            pitch = -0.08
            return
        }
        let back = returnFrom.flatMap { items[$0] }
        returnFrom = nil
        if let back {
            // Out of the door you went in by, facing the building.
            cameraNode.simdPosition = V3(back.x, flying ? 12 : cityEye, back.z + back.w / 2 + 6)
            yaw = 0
            pitch = flying ? -0.2 : 0.05
            return
        }
        // Far enough back and up to see the whole city, tallest tower included.
        let h = max(24, extent * 0.75, topHeight * 0.9)
        if flying {
            let backZ = plazaFront + extent * 1.05
            cameraNode.simdPosition = V3(0, h, backZ)
            yaw = 0
            pitch = -atan2(h - topHeight * 0.35, backZ - center.z)
        } else {
            cameraNode.simdPosition = V3(0, cityEye, plazaFront + 4)
            yaw = 0
            pitch = 0.05
        }
    }

    // MARK: - HUD

    func setFlying(_ on: Bool) {
        flying = on
        vy = 0
    }

    func syncHud() {
        let d = dir ?? ""
        let name = d.split(separator: "/").last.map(String.init) ?? (d.isEmpty ? "/" : d)
        whereText = mode == "room" ? "🚪 Inside \(name)" : "🏙 \(d.isEmpty ? "/" : d)"
        whereTitle = d
        let atRoot = d == "/"
        outText = mode == "room" ? "⇦ Out" : "⇧ Up a level"
        outTitle = mode == "room" ? "Back out to the street (Backspace)" : "The city one folder up (Backspace)"
        outHidden = mode != "room" && atRoot
        hereHidden = mode != "room"
    }

    private func drawLegend() {
        var seen = Set<String>()
        for it in items.values {
            if it.kind == .crate, let e = it.entry { seen.insert(FileKinds.kindOf(e.name)) }
            else if let r = it.rec { for (k, _) in CityKinds.bands(r) { seen.insert(k) } }
        }
        legend = CityKinds.order.filter { seen.contains($0) }
    }

    // MARK: - Settings-backed choices

    func setStyle(_ id: String) {
        let st = CityStyle.byId(id)
        if st.id == style { return }
        style = st.id
        rebuild()
        applyState()
        focus()
        StatusBus.shared.show("The town is now built in \(st.label.components(separatedBy: " — ")[0])")
        Store.shared.city3dStyle = st.id
    }

    func toggleMax(_ force: Bool? = nil) {
        guard let host else { return }
        let on = force ?? !host.cityMaximized
        host.cityMaximized = on
        maximized = on
    }

    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let v = self?.scnView, let w = v.window else { return }
            w.makeFirstResponder(v)
        }
    }

    /// Back to the list (the "☰ List" button; the same as pressing 3D again).
    func backToList() {
        guard let host else { return }
        City.toggle(host, on: false)
    }

    func approveMeasuring() {
        mfaOk = true
        approveShown = false
        measure(dir)
        if traffic != nil { trafficTimer?.cancel(); pollTraffic() }
    }

    /// "🏙 City of here": this folder's own folders as a city.
    func cityOfHere() {
        mode = "city"
        rebuild(spawn: true)
        measure(dir)
        applyState()
    }

    func destroy() {
        if destroyed { return }
        destroyed = true
        loopTimer?.invalidate()
        loopTimer = nil
        if host?.cityMaximized == true { host?.cityMaximized = false }
        endChase()
        stopTraffic()
        world.removeFromParentNode()
        for p in planes { p.node.removeFromParentNode() }
        hero?.node.removeFromParentNode()
        for p in planes { p.node.removeFromParentNode() }
        planes.removeAll()
        flocks.removeAll()
        clouds.removeAll()
        items.removeAll()
        spinners.removeAll()
        hero = nil
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        scene.background.contents = nil
        scene.lightingEnvironment.contents = nil
        scnView.scene = nil
        scnView.city = nil
        scnView.removeFromSuperview()
        City.forget(self)
        keepAlive = nil
    }
}

/// The backdrop and the hemisphere light.
enum CitySky {
    /// An equirectangular sky of one colour with stars from just above the
    /// horizon up to about 30°, as the original's point cloud on a dome.
    static func starryBackdrop(_ sky: Int) -> CGImage? {
        let W = 4096, H = 2048
        let c = CityTextures.rgb(sky)
        return CityTextures.draw(W, H) { ctx in
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            for _ in 0..<900 {
                let u = Double.random(in: 0..<1), v = Double.random(in: 0..<1) * 0.45 + 0.08
                let x = u * Double(W), y = (0.5 - v / .pi) * Double(H)
                ctx.fillEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
            }
        }
    }

    /// Sky colour above, ground colour below: what a hemisphere light does.
    static func hemisphere(top: Int, bottom: Int) -> CGImage? {
        let t = CityTextures.rgb(top), b = CityTextures.rgb(bottom)
        return CityTextures.draw(64, 32) { ctx in
            for y in 0..<32 {
                let f = CGFloat(y) / 31
                let k = max(0, min(1, (f - 0.35) / 0.3))
                ctx.setFillColor(CGColor(srgbRed: t.0 + (b.0 - t.0) * k, green: t.1 + (b.1 - t.1) * k, blue: t.2 + (b.2 - t.2) * k, alpha: 1))
                ctx.fill(CGRect(x: 0, y: y, width: 64, height: 1))
            }
        }
    }
}
