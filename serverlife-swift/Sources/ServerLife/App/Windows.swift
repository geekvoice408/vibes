import AppKit
import SwiftUI

/// Per-window state that a feature keeps for itself (its own tabs, its
/// sidebar filter, its dock selection …). Created lazily, once per window,
/// by `WindowModel.feature(_:)` — so a feature can add per-window state
/// without editing this file.
@MainActor
protocol WindowFeature: AnyObject {
    init(window: WindowModel)
}

/// One application window: the port of one Electron renderer. Each window has
/// its own tabs, panes, sidebar and file browsers; connections are shared.
@MainActor
@Observable
final class WindowModel: Identifiable {
    /// The slot ('w1', 'w2' …) its layout and bounds are remembered under.
    let id: String
    @ObservationIgnored weak var nsWindow: NSWindow?

    var title = "ServerLife"
    var sidebarVisible = true
    var dockVisible = false
    /// transfers | multiexec | forwards | log | downloads | watch
    var dockTab = "transfers"
    /// Panel sizes in points (sidebar width, dock height), seeded from settings.panelSizes.
    var sidebarWidth: CGFloat = 300
    var dockHeight: CGFloat = 220

    @ObservationIgnored private var features: [ObjectIdentifier: AnyObject] = [:]

    init(id: String) {
        self.id = id
        let sizes = Store.shared.settingJSON("panelSizes")
        // Keyed by the original's resizer selectors, so the file round-trips.
        if let w = sizes["#sidebar-resizer"].double { sidebarWidth = CGFloat(min(460, max(170, w))) }
        if let h = sizes["#bottom-resizer"].double { dockHeight = CGFloat(max(108, h)) }
    }

    func feature<T: WindowFeature>(_ type: T.Type = T.self) -> T {
        if let f = features[ObjectIdentifier(type)] as? T { return f }
        let f = T(window: self)
        features[ObjectIdentifier(type)] = f
        return f
    }

    /// Whether this window is the key window.
    var isKey: Bool { nsWindow?.isKeyWindow ?? false }

    func showDock(_ tab: String) {
        dockTab = tab
        dockVisible = true
    }

    func rememberPanelSize(_ key: String, _ value: CGFloat) {
        Store.shared.mutateSetting("panelSizes") { $0[key] = .number(Double(value)) }
    }
}

/// Opens, tracks and closes windows (window:new / window:list / window:me).
@MainActor
@Observable
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private(set) var windows: [WindowModel] = []
    /// The window the user was last working in.
    private(set) var focused: WindowModel?

    /// Hooks run when a window is about to close; return false to keep it open
    /// (quit guard, "close tabs with live sessions?").
    @ObservationIgnored var shouldClose: [(WindowModel) -> Bool] = []
    /// Hooks run after a window has closed (tear down its panes).
    @ObservationIgnored var didClose: [(WindowModel) -> Void] = []
    /// Hooks run after a window opens (restore its layout, offer the tour …).
    @ObservationIgnored var didOpen: [(WindowModel, [String: Any]) -> Void] = []

    private func nextSlot() -> String {
        var n = 1
        while windows.contains(where: { $0.id == "w\(n)" }) { n += 1 }
        return "w\(n)"
    }

    /// Open a new window. `options` reach the `didOpen` hooks (e.g. a pane
    /// being adopted from another window, or a layout to restore).
    @discardableResult
    func open(slot: String? = nil, options: [String: Any] = [:]) -> WindowModel {
        let model = WindowModel(id: slot ?? nextSlot())
        let root = MainWindowView(window: model)
        let host = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 760, height: 480)
        w.title = "ServerLife"
        w.delegate = self
        restoreBounds(w, slot: model.id)
        model.nsWindow = w
        windows.append(model)
        focused = model
        w.makeKeyAndOrderFront(nil)
        for hook in didOpen { hook(model, options) }
        return model
    }

    func model(for w: NSWindow?) -> WindowModel? {
        guard let w else { return nil }
        // A sheet or panel belongs to the window it is attached to.
        let base = w.sheetParent ?? w
        return windows.first { $0.nsWindow === base }
    }

    /// The window to act in: the key one, else the last focused, else a new one.
    func current() -> WindowModel {
        if let m = model(for: NSApp.keyWindow) { return m }
        if let f = focused, windows.contains(where: { $0 === f }) { return f }
        return windows.first ?? open()
    }

    // MARK: Bounds

    private func restoreBounds(_ w: NSWindow, slot: String) {
        let b = Store.shared.settingJSON("windowBounds")[slot]
        if let x = b["x"].double, let y = b["y"].double, let width = b["width"].double, let height = b["height"].double {
            var frame = NSRect(x: x, y: y, width: width, height: height)
            // Clamp to a display that exists now: one last used on an unplugged
            // monitor must not open somewhere unreachable.
            let screens = NSScreen.screens.map(\.visibleFrame)
            if !screens.contains(where: { $0.intersects(frame) }), let main = NSScreen.main?.visibleFrame {
                frame.size.width = min(frame.width, main.width)
                frame.size.height = min(frame.height, main.height)
                frame.origin = NSPoint(x: main.midX - frame.width / 2, y: main.midY - frame.height / 2)
            }
            w.setFrame(frame, display: false)
            if b["maximized"].bool == true { w.zoom(nil) }
        } else {
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
            if windows.count > 0, let last = windows.last?.nsWindow {
                w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 28, y: last.frame.maxY - 28))
            }
        }
    }

    private func saveBounds(_ model: WindowModel) {
        guard let w = model.nsWindow else { return }
        let f = w.frame
        Store.shared.mutateSetting("windowBounds") {
            $0[model.id] = ["x": .number(f.minX), "y": .number(f.minY), "width": .number(f.width),
                            "height": .number(f.height), "maximized": .bool(w.isZoomed),
                            "fullScreen": .bool(w.styleMask.contains(.fullScreen))]
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if let m = model(for: notification.object as? NSWindow) { focused = m }
    }

    func windowDidMove(_ notification: Notification) {
        if let m = model(for: notification.object as? NSWindow) { saveBounds(m) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let m = model(for: notification.object as? NSWindow) { saveBounds(m) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let m = model(for: sender) else { return true }
        for check in shouldClose where !check(m) { return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let m = windows.first(where: { $0.nsWindow === w }) else { return }
        saveBounds(m)
        windows.removeAll { $0 === m }
        if focused === m { focused = windows.last }
        for hook in didClose { hook(m) }
    }
}
