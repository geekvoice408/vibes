import AppKit
import SceneKit
import simd

/// Physical keys (`e.code` in the original), so WASD stays WASD on any layout.
enum CityKey {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, h: UInt16 = 4, g: UInt16 = 5, x: UInt16 = 7, c: UInt16 = 8
    static let w: UInt16 = 13, space: UInt16 = 49, shiftL: UInt16 = 56, shiftR: UInt16 = 60
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let enter: UInt16 = 36, keypadEnter: UInt16 = 76, backspace: UInt16 = 51, escape: UInt16 = 53
    static let movement: Set<UInt16> = [w, a, s, d, x, c, space, shiftL, shiftR, up, down, left, right]
}

extension CityController {
    // MARK: - Selection, filter, highlight

    func applyState() {
        guard let host else { return }
        let match = host.cityMatcher()
        let selection = host.citySelection
        for it in items.values {
            guard let e = it.entry else { continue }
            let matched = match.map { $0(e.name) } ?? true
            let sel = selection.contains(e.path)
            it.dim = !matched
            for m in it.mats {
                m.transparency = matched ? 1 : 0.12
                m.writesToDepthBuffer = matched
            }
            it.label?.isHidden = !matched
            if sel != it.selected {
                it.selected = sel
                if sel { addBeacon(it) } else { it.beacon?.removeFromParentNode(); it.beacon = nil }
            }
        }
        syncHud()
    }

    private func addBeacon(_ it: CityItem) {
        let r: Float = it.kind == .building ? it.w * 0.8 : it.kind == .door ? 1.8 : max(0.7, it.w)
        let ring = SCNNode.mesh(.torus(r, it.kind == .building ? 0.25 : 0.08, 8, 40),
                                CityMat.basic(0x4c8dff, opacity: 0.5, doubleSided: true), shadow: false)
        if it.kind == .door {
            ring.simdPosition = V3(0, 1.7, 0.3)
        } else {
            ring.simdEulerAngles.x = .pi / 2
            ring.simdPosition = V3(0, 0.15, 0)
        }
        it.beacon = ring
        it.group?.addChildNode(ring)
    }

    /// A click: select it (⌘ adds), or say something about whatever is not a file.
    func select(_ it: CityItem?, additive: Bool) {
        guard let host else { return }
        guard let it, let e = it.entry else {
            if !additive { host.citySelection = [] }
            switch it?.kind {
            case .bird: StatusBus.shared.show("🐦 tweet")
            case .plane: StatusBus.shared.show("✈︎ nobody’s flying it — it’s a folder view")
            case .hero: StatusBus.shared.show("🦸 Up, up and away!")
            case .proc:
                if let p = it?.proc {
                    StatusBus.shared.show("\(p.name) · pid \(p.pid) · \(p.user) · \(String(format: "%.1f", p.cpu))% CPU · \(Fmt.bytes(p.mem))")
                }
            case .police: StatusBus.shared.show("🚓 Stand back — pursuit in progress")
            case .suspect: StatusBus.shared.show("🚗 They went that way!")
            default: break
            }
            host.citySelectionChanged(lastClicked: nil)
            applyState()
            return
        }
        let p = e.path
        var sel = host.citySelection
        if additive {
            if sel.contains(p) { sel.remove(p) } else { sel.insert(p) }
        } else {
            sel = [p]
        }
        host.citySelection = sel
        host.citySelectionChanged(lastClicked: p)
        applyState()
    }

    /// Go into a building or a door; open a file.
    func activate(_ it: CityItem?) {
        guard let it else { return }
        if it.kind == .exit { out(); return }
        guard let e = it.entry, let host else { return }
        if it.kind == .building || it.kind == .door {
            nextMode = "room"
            Task { @MainActor [weak self] in
                try? await host.cityNavigate(e.path)
                // The original's navigate redrew (and so synced) before its finally.
                self?.sync()
                self?.nextMode = nil
            }
            return
        }
        host.cityOpen(e)
    }

    /// Out of a room to the street it is on; out of a city to the one above.
    func out() {
        if leaving { return }
        leaving = true
        after(0.4) { [weak self] in self?.leaving = false }
        returnFrom = dir
        nextMode = "city"
        if mode == "room" { setFlying(false) }
        guard let host else { return }
        Task { @MainActor [weak self] in
            try? await host.cityGoParent()
            guard let self else { return }
            self.sync()
            // Nowhere above (the root): leaving a room still means the street.
            if self.nextMode != nil && self.mode == "room" {
                self.mode = "city"
                self.rebuild(spawn: true)
                self.applyState()
            }
            self.nextMode = nil
        }
    }

    // MARK: - Picking

    func pick(at point: CGPoint) -> CityItem? {
        let hits = scnView.hitTest(point, options: [
            .categoryBitMask: cityPickMask,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .sortResults: true,
            .ignoreHiddenNodes: true,
        ])
        for h in hits {
            var n: SCNNode? = h.node
            while let cur = n {
                if let c = cur as? CityNode, let it = c.item {
                    if it.dim { break }
                    return it
                }
                n = cur.parent
            }
        }
        return nil
    }

    // MARK: - Pointer

    func mouseDown(_ e: NSEvent, at p: CGPoint) {
        focus()
        drag = (p.x, p.y, false)
    }

    func mouseDragged(_ e: NSEvent, at p: CGPoint) {
        guard var d = drag else { return }
        let dx = p.x - d.x, dy = -(p.y - d.y)   // y down, as the original's clientY
        if !d.moved && hypot(dx, dy) < 4 { return }
        d.moved = true
        d.x = p.x
        d.y = p.y
        drag = d
        yaw -= Float(dx) * 0.005
        pitch -= Float(dy) * 0.005
        tip = nil
    }

    func mouseUp(_ e: NSEvent, at p: CGPoint) {
        let d = drag
        drag = nil
        guard let d, !d.moved else { return }
        let it = pick(at: p)
        let mods = e.modifierFlags
        select(it, additive: mods.contains(.command) || mods.contains(.control) || mods.contains(.shift))
        if e.clickCount == 2 { activate(pick(at: p)) }
    }

    func mouseMoved(_ e: NSEvent, at p: CGPoint) {
        if drag != nil { return }
        let it = pick(at: p)
        hover = it
        pointer = it != nil
        showTip(it, at: CGPoint(x: p.x, y: scnView.bounds.height - p.y))
    }

    func mouseExited() {
        tip = nil
        hover = nil
        pointer = false
    }

    func rightMouseDown(_ e: NSEvent, at p: CGPoint) {
        focus()
        let it = pick(at: p)
        host?.cityContextMenu(it?.entry, event: e, in: scnView)
    }

    func scrollWheel(_ e: NSEvent) {
        // The original's deltaY: pixels, positive scrolling down.
        let deltaY = -e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 40)
        let f = forward(flying)
        let step = -Float(deltaY) * 0.02 * (flying ? flySpeed() / 18 : 1)
        moveBy(f.x * step, flying ? f.y * step : 0, f.z * step)
    }

    private func showTip(_ it: CityItem?, at p: CGPoint) {
        guard let it else { tip = nil; return }
        var lines: [CityTip.Line] = []
        func add(_ cls: String, _ text: String) { if !text.isEmpty { lines.append(.init(cls: cls, text: text)) } }
        if it.kind == .proc, let p = it.proc {
            let glyph = ["car": "🚗", "boat": "🚢", "rocket": "🚀"][it.vehicle?.rawValue ?? ""] ?? ""
            add("n", "\(glyph) \(p.name)")
            add("m", "pid \(p.pid) · \(p.user)")
            add("k", "\(String(format: "%.1f", p.cpu))% CPU · \(Fmt.bytes(p.mem)) memory")
            add("h", it.vehicle == .rocket ? "One of the biggest on this machine"
                : it.vehicle == .boat ? "Mostly memory — the bigger, the more" : "Mostly CPU — the faster, the more")
        } else if it.entry == nil {
            let names: [CityItem.Kind: String] = [.exit: "Out to the street", .bird: "🐦", .hero: "🦸 Is it a bird? Is it a plane?",
                                                  .police: "🚓 In pursuit", .suspect: "🚗 Getaway car"]
            add("n", names[it.kind] ?? "✈︎")
            add("m", it.kind == .exit ? "Double-click, or walk through" : "")
        } else if it.kind == .crate, let e = it.entry {
            add("n", e.name)
            add("m", "\(Fmt.bytes(Double(e.size))) · \(CityKinds.labels[FileKinds.kindOf(e.name)] ?? "Other")")
            add("h", "Double-click to open")
        } else if let e = it.entry {
            add("n", "📁 " + e.name)
            if let r = it.rec {
                let nf = NumberFormatter()
                nf.numberStyle = .decimal
                add("m", "\(Fmt.bytes(r.bytes)) · \(nf.string(from: NSNumber(value: r.files)) ?? "\(r.files)") files · \(nf.string(from: NSNumber(value: r.dirs)) ?? "\(r.dirs)") folders")
                add("k", CityKinds.summary(r))
            } else {
                add("m", "not measured yet")
            }
            add("h", "Double-click to go in")
        }
        let size = scnView.bounds.size
        tip = CityTip(lines: lines, at: CGPoint(x: min(p.x + 14, size.width - 230), y: min(p.y + 14, size.height - 90)))
    }

    // MARK: - Keys

    /// true when the key was the city's.
    func keyDown(_ e: NSEvent) -> Bool {
        guard let host else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let meta = mods.contains(.command) || mods.contains(.control)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if meta && ch == "f" { host.cityFocusFilter(); return true }
        if meta && ch == "a" {
            host.citySelection = Set(items.values.filter { !$0.dim }.compactMap { $0.entry?.path })
            host.citySelectionChanged(lastClicked: nil)
            applyState()
            return true
        }
        if meta || mods.contains(.option) { return false }
        if e.characters == "/" { host.cityFocusFilter(); return true }
        if e.keyCode == CityKey.escape {
            if helpShown { helpShown = false }
            else if host.cityMaximized { toggleMax(false) }
            else if host.cityFilterActive { host.cityClearFilter() }
            else { host.citySelection = []; host.citySelectionChanged(lastClicked: nil); applyState() }
            return true
        }
        if e.keyCode == CityKey.enter || e.keyCode == CityKey.keypadEnter {
            let sel = host.cityEntries.filter { host.citySelection.contains($0.path) }
            if sel.count == 1 { activate(items[sel[0].path]); return true }
            activate(pick(at: CGPoint(x: scnView.bounds.midX, y: scnView.bounds.midY)))
            return true
        }
        if e.keyCode == CityKey.backspace { out(); return true }
        if e.keyCode == CityKey.g { setFlying(!flying); return true }
        if e.keyCode == CityKey.h || e.characters == "?" { helpShown.toggle(); return true }
        if CityKey.movement.contains(e.keyCode) {
            keys.insert(e.keyCode)
            return true
        }
        return false
    }

    func keyUp(_ e: NSEvent) { keys.remove(e.keyCode) }

    func flagsChanged(_ e: NSEvent) {
        if e.modifierFlags.contains(.shift) { keys.insert(e.keyCode == CityKey.shiftR ? CityKey.shiftR : CityKey.shiftL) }
        else { keys.remove(CityKey.shiftL); keys.remove(CityKey.shiftR) }
    }

    func blur() { keys.removeAll() }
}
