import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `Slots.workspace`: the active tab's panes, or the start page.
struct SessionsWorkspaceView: View {
    let window: WindowModel

    var body: some View {
        let s = window.feature(SessionsWindow.self)
        let p = Theme.shared.p
        ZStack {
            p.bg
            if let t = s.activeTab, let root = t.root {
                PaneNodeView(s: s, node: root)
                    .id(t.id)
            } else {
                EmptyStartView(window: window)
            }
        }
        .coordinateSpace(name: "sessions.workspace")
    }
}

/// One node of the layout tree.
struct PaneNodeView: View {
    let s: SessionsWindow
    let node: PaneNode

    var body: some View {
        switch node {
        case .pane(let id):
            if let p = s.panes[id] { PaneView(s: s, pane: p) } else { Color.clear }
        case .split(let split):
            SplitNodeView(s: s, split: split)
        }
    }
}

/// A split: its children with draggable dividers between them.
struct SplitNodeView: View {
    let s: SessionsWindow
    let split: PaneSplit
    @StateObject private var dragStart = Local<[CGFloat]?>(nil)

    var body: some View {
        GeometryReader { g in
            let horizontal = split.dir == .row
            let total = (horizontal ? g.size.width : g.size.height) - CGFloat(split.children.count - 1) * 4
            let weights = normalised()
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.children.enumerated()), id: \.offset) { i, child in
                    if i > 0 {
                        SplitDivider(horizontal: horizontal) { delta in
                            drag(i, delta, total: total)
                        } onEnd: {
                            dragStart.value = nil
                        }
                    }
                    PaneNodeView(s: s, node: child)
                        .frame(width: horizontal ? max(0, total * weights[i]) : nil,
                               height: horizontal ? nil : max(0, total * weights[i]))
                }
            }
        }
    }

    private func normalised() -> [CGFloat] {
        let n = split.children.count
        guard let w = split.weights, w.count == n else { return Array(repeating: 1 / CGFloat(n), count: n) }
        let sum = w.reduce(0, +)
        return sum > 0 ? w.map { $0 / sum } : Array(repeating: 1 / CGFloat(n), count: n)
    }

    /// Dragging a divider trades size between the two children beside it,
    /// neither going below 80 points.
    private func drag(_ i: Int, _ delta: CGFloat, total: CGFloat) {
        guard total > 0 else { return }
        if dragStart.value == nil { dragStart.value = normalised() }
        var w = dragStart.value!
        let minFrac = 80 / total
        let a = w[i - 1] + delta / total, b = w[i] - delta / total
        guard a >= minFrac, b >= minFrac else { return }
        w[i - 1] = a; w[i] = b
        guard let t = s.tab(s.pane(split.children.first?.firstPane)?.tabId) else { return }
        t.root = PaneTree.settingWeights(t.root, splitId: split.id, w)
    }
}

/// The 4-point divider between panes (`.v-resizer` / `.h-resizer`).
struct SplitDivider: View {
    let horizontal: Bool
    let onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    @StateObject private var hover = LocalFlag()
    @StateObject private var origin = Local<CGFloat?>(nil)

    var body: some View {
        let p = Theme.shared.p
        Rectangle()
            .fill(hover.on || origin.value != nil ? p.accentDim : Color.clear)
            .frame(width: horizontal ? 4 : nil, height: horizontal ? nil : 4)
            .contentShape(Rectangle())
            .onHover { inside in
                hover.on = inside
                if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let v = horizontal ? g.translation.width : g.translation.height
                    origin.value = 0
                    onDrag(v)
                }
                .onEnded { _ in origin.value = nil; onEnd() })
    }
}

/// One pane: header, terminal (with its file browser beside or above it),
/// and the connect overlay on top.
struct PaneView: View {
    let s: SessionsWindow
    let pane: SessionPane
    @StateObject private var dropping = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let focused = s.activePaneId == pane.id
        VStack(spacing: 0) {
            PaneHeaderView(s: s, pane: pane, focused: focused)
            PaneBodyView(s: s, pane: pane)
        }
        .overlay {
            if let o = pane.overlay { PaneOverlayView(s: s, pane: pane, overlay: o) }
        }
        .overlay(RoundedRectangle(cornerRadius: 0).stroke(focused ? p.accentDim : Color.clear, lineWidth: 1))
        .overlay(dropping.on ? RoundedRectangle(cornerRadius: 0).stroke(p.accent, lineWidth: 2) : nil)
        .opacity(PaneDrag.shared.current == pane.id ? 0.55 : 1)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { pane.frame = g.frame(in: .named("sessions.workspace")) }
                .onChange(of: g.frame(in: .named("sessions.workspace"))) { _, f in pane.frame = f }
        })
        .onDrop(of: [UTType.text], delegate: PaneDropDelegate(s: s, target: pane, active: $dropping.on))
    }
}

/// The terminal and its accessory (the file browser), or a view pane's view.
struct PaneBodyView: View {
    let s: SessionsWindow
    let pane: SessionPane

    var body: some View {
        let p = Theme.shared.p
        if pane.kind == .view {
            Group {
                if let c = pane.content { c() } else { Color.black }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { s.setActivePane(pane.id) })
        } else {
            let stacked = Store.shared.settingJSON("explorerPosition").string == "top"
            let showAcc = PaneAccessories.shared.hasProvider && (pane.explorerVisible || pane.filesOnly)
            GeometryReader { g in
                let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                layout {
                    if showAcc, let make = PaneAccessories.shared.provider {
                        let size = accessorySize(g.size, stacked: stacked)
                        make(pane)
                            .frame(width: pane.filesOnly ? nil : (stacked ? nil : size),
                                   height: pane.filesOnly ? nil : (stacked ? size : nil))
                            .frame(maxWidth: pane.filesOnly ? .infinity : nil, maxHeight: pane.filesOnly ? .infinity : nil)
                            .background(p.panel)
                        if !pane.filesOnly {
                            SplitDivider(horizontal: !stacked) { delta in
                                let base = accessorySize(g.size, stacked: stacked)
                                pane.attachments["accDragBase"] = pane.attachments["accDragBase"] ?? base
                                let start = pane.attachments["accDragBase"] as? CGFloat ?? base
                                pane.accessorySize = max(140, start + delta)
                            } onEnd: {
                                pane.attachments["accDragBase"] = nil
                            }
                        }
                    }
                    if !pane.filesOnly {
                        TermHostView(pane: pane, covered: pane.overlay != nil, ended: pane.tmuxEnded != nil)
                            .padding(.top, 3).padding(.leading, 5)
                            .background(Color(nsColor: pane.term?.nativeBackgroundColor ?? .black))
                    }
                }
            }
        }
    }

    private func accessorySize(_ size: CGSize, stacked: Bool) -> CGFloat {
        if let s = pane.accessorySize { return min(s, (stacked ? size.height : size.width) - 80) }
        return stacked ? 240 : min(270, size.width * 0.42)
    }
}

/// Hosts a pane's terminal NSView. The view belongs to the pane, not to
/// SwiftUI, so moving a pane — to another split, tab or window — re-parents
/// the same terminal with its scrollback and everything running in it.
///
/// SwiftUI can briefly hold two containers for one pane (the old layout and
/// the new) and does not say in which order it builds and drops them. So a
/// container that is in a window always wins over one that is not, and a
/// container leaving the window hands the terminal to another live one.
struct TermHostView: NSViewRepresentable {
    let pane: SessionPane
    /// An overlay is up: the terminal is hidden under it, so the overlay is
    /// on top in real rendering and takes the clicks.
    var covered: Bool
    /// The tmux session behind it has ended: dimmed, as `.tmux-ended`.
    var ended: Bool

    func makeNSView(context: Context) -> NSView {
        let v = TermContainer()
        v.pane = pane
        v.adopt(force: false)
        v.apply(covered: covered, ended: ended)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let c = v as? TermContainer else { return }
        if c.pane !== pane { c.pane = pane }
        c.adopt(force: false)
        c.apply(covered: covered, ended: ended)
    }
}

final class TermContainer: NSView {
    nonisolated(unsafe) static let all = NSHashTable<TermContainer>.weakObjects()
    weak var pane: SessionPane?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        TermContainer.all.add(self)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Take the pane's terminal unless a container that is on screen holds it
    /// and this one is not (`force` takes it regardless).
    @MainActor func adopt(force: Bool) {
        guard let term = pane?.term else { return }
        if term.superview === self { layoutTerm(); return }
        if !force, window == nil, let holder = term.superview, holder.window != nil { return }
        term.removeFromSuperview()
        addSubview(term)
        layoutTerm()
        // A re-parented terminal has lost its drawing; repaint all of it,
        // not only the rows that change next.
        term.needsDisplay = true
        DispatchQueue.main.async { [weak term] in term?.setNeedsDisplay(term?.bounds ?? .zero) }
    }

    @MainActor func apply(covered: Bool, ended: Bool) {
        guard let term = pane?.term, term.superview === self else { return }
        if term.isHidden != covered { term.isHidden = covered }
        let alpha: CGFloat = ended ? 0.45 : 1
        if alphaValue != alpha { alphaValue = alpha }
        wantsLayer = true
        if ended, contentFilters.isEmpty, let f = CIFilter(name: "CIColorControls") {
            f.setDefaults()
            f.setValue(0.4, forKey: kCIInputSaturationKey)
            layerUsesCoreImageFilters = true
            contentFilters = [f]
        } else if !ended, !contentFilters.isEmpty {
            contentFilters = []
        }
    }

    /// The terminal takes the container's size — but never a collapsed one.
    /// A container squeezed to nothing for a moment (a tab switch, a layout
    /// rebuild) would otherwise resize the grid to a couple of columns, and
    /// the lines cut to fit do not come back when it grows again.
    private func layoutTerm() {
        guard bounds.width > 40, bounds.height > 20 else { return }
        for v in subviews {
            v.autoresizingMask = []
            if v.frame != bounds { v.frame = bounds }
        }
    }

    override func layout() {
        super.layout()
        let before = subviews.first?.frame
        layoutTerm()
        if let t = subviews.first, t.frame != before { t.needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            if window != nil {
                adopt(force: true)
            } else if let p = pane, p.term?.superview === self {
                // Leaving the window with the terminal: hand it to a live one.
                DispatchQueue.main.async { [weak p] in
                    MainActor.assumeIsolated {
                        guard let p, let term = p.term, term.window == nil else { return }
                        for c in TermContainer.all.allObjects where c.pane === p && c.window != nil {
                            c.adopt(force: true)
                            break
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dragging panes

/// Which pane is being dragged, for the drop targets to read — a drag over
/// a target is not allowed to see the payload until the drop.
@MainActor
@Observable
final class PaneDrag {
    static let shared = PaneDrag()
    var current: String?
    static let prefix = "serverlife-pane:"
}

/// Dropping a pane on another pane in the same tab swaps the two.
struct PaneDropDelegate: DropDelegate {
    let s: SessionsWindow
    let target: SessionPane
    @Binding var active: Bool

    @MainActor private func ok() -> Bool {
        guard let id = PaneDrag.shared.current, id != target.id, let other = s.pane(id) else { return false }
        return other.tabId == target.tabId
    }

    func validateDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { ok() } }
    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { active = ok() } }
    func dropExited(info: DropInfo) { active = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { ok() ? DropProposal(operation: .move) : DropProposal(operation: .forbidden) }
    }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            active = false
            guard ok(), let id = PaneDrag.shared.current else { return false }
            PaneDrag.shared.current = nil
            s.swapPanes(id, target.id)
            return true
        }
    }
}

/// The header's drag handle: picks the pane up, and notices a drop outside
/// the window (the gesture for "give this its own window").
struct PaneDragSource: NSViewRepresentable {
    let s: SessionsWindow
    let paneId: String

    func makeNSView(context: Context) -> NSView {
        let v = PaneDragSourceView()
        v.s = s; v.paneId = paneId
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        (v as? PaneDragSourceView)?.s = s
        (v as? PaneDragSourceView)?.paneId = paneId
    }
}

final class PaneDragSourceView: NSView, NSDraggingSource {
    weak var s: SessionsWindow?
    var paneId = ""
    private var downAt: NSPoint?

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        MainActor.assumeIsolated {
            s?.setActivePane(paneId)
            s?.focusActivePane()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt else { return }
        let dx = event.locationInWindow.x - d.x, dy = event.locationInWindow.y - d.y
        guard dx * dx + dy * dy > 16 else { return }
        downAt = nil
        let item = NSPasteboardItem()
        item.setString(PaneDrag.prefix + paneId, forType: .string)
        let di = NSDraggingItem(pasteboardWriter: item)
        let img = MainActor.assumeIsolated { dragImage() }
        di.setDraggingFrame(NSRect(x: convert(event.locationInWindow, from: nil).x - 40, y: 0,
                                   width: img.size.width, height: img.size.height), contents: img)
        MainActor.assumeIsolated { PaneDrag.shared.current = paneId }
        beginDraggingSession(with: [di], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { downAt = nil }

    /// The header's right-click is the pane's menu, for every kind of pane —
    /// the only way to it for a screen, a hosts list or a files-only pane.
    override func menu(for event: NSEvent) -> NSMenu? {
        MainActor.assumeIsolated { s?.paneMenu(paneId, at: NSPoint(x: -1, y: -1)) }
    }

    @MainActor private func dragImage() -> NSImage {
        let title = SessionsCore.paneTitle(s?.pane(paneId))
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attr)
        let img = NSImage(size: NSSize(width: size.width + 16, height: 22))
        img.lockFocus()
        NSColor(white: 0.2, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: img.size), xRadius: 4, yRadius: 4).fill()
        (title as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: attr)
        img.unlockFocus()
        return img
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            let was = PaneDrag.shared.current
            PaneDrag.shared.current = nil
            // Dropped clean outside the window: a window of its own.
            guard let was, operation == [], let w = window else { return }
            if !w.frame.contains(screenPoint) { s?.popPaneToWindow(was) }
        }
    }
}

// MARK: - Overlay

/// Connect progress, prompts answered in the pane, and failures.
struct PaneOverlayView: View {
    let s: SessionsWindow
    let pane: SessionPane
    let overlay: PaneOverlay
    @StateObject private var response = Local("")
    @FocusState private var inputFocused: Bool

    var body: some View {
        let p = Theme.shared.p
        let connState = SessConn.state(pane.connId)
        let showInput = overlay.promptInput || pane.overlaySawPrompt || connState == "prompting"
        let log = overlay.showLog ? (SessConn.logText(pane.connId) + overlay.notes) : ""
        ZStack {
            p.bg.opacity(0.97)
            VStack(alignment: .leading, spacing: 0) {
                if let scene = overlay.scene, overlay.error == nil { ConnectSceneView(anim: scene) }
                Text(overlay.title).font(.system(size: 14, weight: .semibold)).padding(.bottom, 6)
                if !overlay.sub.isEmpty {
                    Text(overlay.sub).font(.system(size: 12)).foregroundStyle(p.muted).padding(.bottom, 12)
                }
                if let e = overlay.error {
                    Text(e).font(.system(size: 12)).foregroundStyle(p.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                }
                if overlay.showLog {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(log.isEmpty ? " " : log)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(p.textDim)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11).padding(.vertical, 9)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxHeight: 210)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                        .onChange(of: log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .padding(.bottom, 12)
                }
                if showInput, let connId = pane.connId {
                    SecureField(overlay.promptInput ? "Response…" : "Type response and press Enter…", text: $response.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(inputFocused ? p.accent : p.border))
                        .focused($inputFocused)
                        .onSubmit {
                            SessConn.writeMaster(connId, response.value + "\n")
                            response.value = ""
                        }
                        .onAppear { after(0.05) { inputFocused = true } }
                        .padding(.bottom, 10)
                }
                if let mfa = overlay.mfa {
                    Text("Try again, or use a method that does not need an OS prompt — an OTP code is typed straight into the terminal.")
                        .font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 8)
                    HStack(spacing: 8) {
                        ForEach([("platform", "Touch ID"), ("cross-platform", "Security key"), ("otp", "OTP code"), ("browser", "Browser")],
                                id: \.0) { m in
                            Button(m.0 == mfa.current ? "Retry with \(m.1)" : m.1) { mfa.retry(m.0) }
                                .buttonStyle(m.0 == mfa.current ? .primary : .ghost)
                        }
                    }
                    .padding(.bottom, 10)
                    Button("Copy tsh command") { mfa.copyCommand() }
                        .buttonStyle(.ghost)
                        .help("Run it in Terminal if the OS prompt will not appear here")
                        .padding(.bottom, 10)
                }
                if let logins = overlay.logins, !logins.options.isEmpty {
                    Text("Authentication failed as “\(logins.current ?? "default")”. That is either a login this node does not allow, or a node that wants MFA per session — try another login, or the MFA transport.")
                        .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    HStack(spacing: 8) {
                        ForEach(logins.options.prefix(6), id: \.self) { l in
                            Button("Try as " + l) { logins.retry(l) }.buttonStyle(.ghost)
                        }
                    }
                    .padding(.bottom, 10)
                }
                HStack(spacing: 8) {
                    if let alt = overlay.alt { Button(alt.label) { alt.run() }.buttonStyle(.primary) }
                    if overlay.error != nil, let retry = overlay.retry {
                        Button("Retry") { retry() }.buttonStyle(overlay.alt != nil ? .ghost : .primary)
                    }
                    Button(overlay.error != nil ? "Close pane" : "Cancel") { s.closePane(pane.id) }.buttonStyle(.ghost)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
        }
        .onChange(of: connState) { _, st in if st == "prompting" { pane.overlaySawPrompt = true } }
    }
}
