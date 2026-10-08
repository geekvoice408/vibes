import AppKit
import SwiftUI

/// Draws a `VNCSession`'s screen and forwards keyboard, mouse and wheel to
/// it. Three scaling modes (`session.scaling`):
///
/// - `.scale` — the screen scaled to fit the pane, centred (up or down);
/// - `.resize` — the server is asked to match the pane (SetDesktopSize,
///   debounced), and whatever it does not match is scaled as above;
/// - `.none` — 1:1, in a scroll view. The wheel scrolls the view when the
///   screen is bigger than the pane; hold Option to send it to the remote.
///
/// In view-only mode nothing is sent. Scaling can be changed at any time
/// (`applyScaling()` after setting `session.scaling`).
@MainActor
final class VNCFramebufferView: NSView {
    let session: VNCSession
    private let scroll = NSScrollView()
    private let canvas: VNCCanvasView
    private var resizeWork: DispatchWorkItem?
    private var lastRequested: (Int, Int)?
    private var sawRemoteResize = false

    init(session: VNCSession) {
        self.session = session
        canvas = VNCCanvasView(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.borderType = .noBorder
        scroll.documentView = canvas
        scroll.autohidesScrollers = true
        addSubview(scroll)
        session.view = self
        applyScaling()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(canvas) ?? false }

    /// Give the keyboard to the remote screen.
    func focus() { window?.makeFirstResponder(canvas) }

    private var appliedScaling: VNCSession.Scaling?

    /// `applyScaling()` only when `session.scaling` differs from what is shown.
    func applyScalingIfChanged() {
        if appliedScaling != session.scaling { applyScaling() }
    }

    /// Call after changing `session.scaling`.
    func applyScaling() {
        appliedScaling = session.scaling
        let one = session.scaling == .none
        scroll.hasVerticalScroller = one
        scroll.hasHorizontalScroller = one
        lastRequested = nil
        needsLayout = true
        layoutCanvas()
        canvas.needsDisplay = true
        window?.invalidateCursorRects(for: canvas)
        if session.scaling == .resize { scheduleRemoteResize() }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutCanvas()
        if session.scaling == .resize { scheduleRemoteResize() }
    }

    private func layoutCanvas() {
        let content = scroll.contentSize
        if session.scaling == .none {
            let w = CGFloat(max(session.width, 1)), h = CGFloat(max(session.height, 1))
            canvas.frame = NSRect(x: 0, y: 0, width: max(w, content.width), height: max(h, content.height))
        } else {
            canvas.frame = NSRect(origin: .zero, size: content)
        }
        canvas.needsDisplay = true
    }

    /// Ask the server to match the pane, once the pane has stopped changing.
    private func scheduleRemoteResize() {
        resizeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session.scaling == .resize else { return }
                let size = self.scroll.contentSize
                let want = (Int(size.width.rounded(.down)), Int(size.height.rounded(.down)))
                guard want.0 > 16, want.1 > 16 else { return }
                if let l = self.lastRequested, l == want { return }
                guard self.session.supportsRemoteResize, self.session.state == .connected else { return }
                self.lastRequested = want
                self.session.requestRemoteSize(width: want.0, height: want.1)
            }
        }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // MARK: Called by the session

    func framebufferChanged() {
        canvas.needsDisplay = true
        if session.supportsRemoteResize && !sawRemoteResize {
            sawRemoteResize = true
            if session.scaling == .resize { scheduleRemoteResize() }
        }
    }

    func sessionResized() {
        layoutCanvas()
        window?.invalidateCursorRects(for: canvas)
    }

    func cursorChanged() { window?.invalidateCursorRects(for: canvas) }

    func connectedNow() {
        sawRemoteResize = false
        lastRequested = nil
        focus()
    }
}

/// The drawing surface and the input forwarding.
@MainActor
final class VNCCanvasView: NSView {
    let session: VNCSession
    private var buttons: UInt8 = 0
    private var pressed: [UInt16: UInt32] = [:]
    private var modifiersDown: Set<UInt32> = []
    private var wheelX: CGFloat = 0
    private var wheelY: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var lastPointer: (Int, Int) = (0, 0)

    init(session: VNCSession) {
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Where the screen is drawn in this view, and at what scale.
    var placement: (rect: NSRect, scale: CGFloat) {
        let fw = CGFloat(max(session.width, 1)), fh = CGFloat(max(session.height, 1))
        if session.scaling == .none { return (NSRect(x: 0, y: 0, width: fw, height: fh), 1) }
        let b = bounds
        let s = max(0.01, min(b.width / fw, b.height / fh))
        let w = fw * s, h = fh * s
        return (NSRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h), s)
    }

    /// A point in this view → framebuffer pixel, clamped to the screen.
    func framebufferPoint(_ p: NSPoint) -> (Int, Int) {
        let (r, s) = placement
        let x = Int(((p.x - r.minX) / s).rounded(.down))
        let y = Int(((p.y - r.minY) / s).rounded(.down))
        return (max(0, min(session.width - 1, x)), max(0, min(session.height - 1, y)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(dirtyRect)
        guard session.width > 0, let image = session.framebuffer?.makeImage() else { return }
        let (r, s) = placement
        ctx.saveGState()
        ctx.interpolationQuality = s == 1 ? .none : .medium
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        if session.viewOnly || session.state != .connected {
            cursor = .arrow
        } else if let c = session.cursor {
            cursor = c.isEmpty ? VNCCanvasView.dotCursor : (makeCursor(c) ?? .arrow)
        } else {
            cursor = .arrow
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    /// The server's cursor, at the scale the screen is drawn.
    private func makeCursor(_ c: RFBCursor) -> NSCursor? {
        guard c.width > 0, c.height > 0 else { return nil }
        var rgba = c.rgba
        // Premultiply for CoreGraphics.
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] == 0 {
            rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: c.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let s = max(0.25, placement.scale)
        let size = NSSize(width: CGFloat(c.width) * s, height: CGFloat(c.height) * s)
        let ns = NSImage(cgImage: img, size: size)
        return NSCursor(image: ns, hotSpot: NSPoint(x: CGFloat(c.hotX) * s, y: CGFloat(c.hotY) * s))
    }

    /// Shown when the server's cursor is invisible, so you can still see
    /// where you are pointing (noVNC's `showDotCursor`).
    static let dotCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 3, y: 3))
    }()

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func pointer(_ e: NSEvent) {
        let p = framebufferPoint(convert(e.locationInWindow, from: nil))
        lastPointer = p
        session.sendPointer(x: p.0, y: p.1, mask: buttons)
    }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func rightMouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDown(with e: NSEvent) { if e.buttonNumber == 2 { buttons |= 2 }; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { if e.buttonNumber == 2 { buttons &= ~2 }; pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }

    /// The context menu belongs to the remote screen while connected; the
    /// pane's own menu is the consoles owner's to attach elsewhere.
    override func menu(for event: NSEvent) -> NSMenu? {
        session.state == .connected && !session.viewOnly ? nil : super.menu(for: event)
    }

    override func scrollWheel(with e: NSEvent) {
        let oneToOne = session.scaling == .none
        let bigger = bounds.width > (enclosingScrollView?.contentSize.width ?? bounds.width) + 1
            || bounds.height > (enclosingScrollView?.contentSize.height ?? bounds.height) + 1
        if session.viewOnly || (oneToOne && bigger && !e.modifierFlags.contains(.option)) {
            super.scrollWheel(with: e)
            return
        }
        // One wheel step per 50 points of trackpad travel, one per notch for
        // a wheel — what noVNC did.
        let step: CGFloat = e.hasPreciseScrollingDeltas ? 50 : 1
        wheelX += e.scrollingDeltaX
        wheelY += e.scrollingDeltaY
        let p = framebufferPoint(convert(e.locationInWindow, from: nil))
        func click(_ bit: UInt8) {
            session.sendPointer(x: p.0, y: p.1, mask: buttons | bit)
            session.sendPointer(x: p.0, y: p.1, mask: buttons)
        }
        while wheelY >= step { click(8); wheelY -= step }          // up
        while wheelY <= -step { click(16); wheelY += step }        // down
        while wheelX >= step { click(32); wheelX -= step }         // left
        while wheelX <= -step { click(64); wheelX += step }        // right
        if e.phase == .ended || e.momentumPhase == .ended { wheelX = 0; wheelY = 0 }
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        guard let k = pressed[e.keyCode] ?? VNCKeys.keysym(for: e) else { return }
        pressed[e.keyCode] = k
        session.sendKey(k, down: true)
    }

    override func keyUp(with e: NSEvent) {
        guard let k = pressed.removeValue(forKey: e.keyCode) ?? VNCKeys.keysym(for: e) else { return }
        session.sendKey(k, down: false)
    }

    override func flagsChanged(with e: NSEvent) {
        if e.keyCode == VNCKeys.capsLockKeyCode {
            // Caps Lock reports a state, not a press: send a tap each change.
            session.sendKey(VNCKeys.capsLock, down: true)
            session.sendKey(VNCKeys.capsLock, down: false)
            return
        }
        guard let m = VNCKeys.modifiers[e.keyCode] else { return }
        let down = e.modifierFlags.rawValue & m.mask != 0
        if down { modifiersDown.insert(m.keysym) } else { modifiersDown.remove(m.keysym) }
        session.sendKey(m.keysym, down: down)
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    /// Nothing stays held down on the far side when focus goes elsewhere.
    func releaseAll() {
        for (_, k) in pressed { session.sendKey(k, down: false) }
        pressed = [:]
        for k in modifiersDown { session.sendKey(k, down: false) }
        modifiersDown = []
        if buttons != 0 {
            buttons = 0
            session.sendPointer(x: lastPointer.0, y: lastPointer.1, mask: 0)
        }
    }
}

/// `VNCFramebufferView` for SwiftUI.
struct VNCView: NSViewRepresentable {
    let session: VNCSession

    func makeNSView(context: Context) -> VNCFramebufferView { VNCFramebufferView(session: session) }

    func updateNSView(_ v: VNCFramebufferView, context: Context) { v.applyScalingIfChanged() }
}
