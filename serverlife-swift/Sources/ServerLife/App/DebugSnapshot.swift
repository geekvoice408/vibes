import AppKit
import SwiftTerm

/// Visual checks without screen-recording permission:
///
///     ServerLife --snapshot out.png [--open-host alias] [--actions a,b,c] [--delay 3] [--size 1400x900]
///         [--data-dir /tmp/sl-test]
///
/// Opens normally, performs the listed action ids in order (one per second),
/// waits `delay` seconds, then renders every window (and any open panel or
/// sheet) into PNGs — out.png for the main window, out-1.png … for the rest —
/// and quits. `--data-dir` points the store somewhere disposable. Used by
/// the porting work to look at what a view actually draws.
@MainActor
enum DebugSnapshot {
    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func runIfRequested() {
        guard let out = arg("--snapshot") else { return }
        let actions = (arg("--actions") ?? "").split(separator: ",").map(String.init)
        let delay = Double(arg("--delay") ?? "3") ?? 3
        if let size = arg("--size"), let w = WindowManager.shared.focused?.nsWindow {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { w.setContentSize(NSSize(width: parts[0], height: parts[1])) }
        }
        // --open-host alias[,alias…]: open real ssh sessions (ssh_config alias
        // or plain hostname) before the listed actions run.
        let hosts = (arg("--open-host") ?? "").split(separator: ",").map(String.init)
        for (i, h) in hosts.enumerated() {
            onCommonModes(0.5 + Double(i) * 0.5) {
                var host = Host(type: Host.ssh, id: "ssh:" + h, name: h)
                host.alias = h
                Actions.shared.perform("open-host", host: host)
            }
        }
        for (i, id) in actions.enumerated() {
            onCommonModes(Double(i + 1)) { Actions.shared.perform(id) }
        }
        onCommonModes(Double(actions.count) + delay) {
            var n = 0
            for w in NSApp.windows where w.isVisible {
                let path = n == 0 ? out : out.replacingOccurrences(of: ".png", with: "-\(n).png")
                if render(w, to: path) { print("snapshot: \(path) — \(w.title)") ; n += 1 }
            }
            // Not NSApp.terminate: an open sheet or modal alert blocks it.
            Store.shared.saveNow()
            exit(0)
        }
    }

    /// Like `after`, but also fires inside modal loops (alerts, runModal),
    /// which the main dispatch queue does not service.
    static func onCommonModes(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .modalPanel)
    }

    static func allSubviews(_ v: NSView) -> [NSView] {
        v.subviews + v.subviews.flatMap { allSubviews($0) }
    }

    static func render(_ w: NSWindow, to path: String) -> Bool {
        guard let view = w.contentView?.superview ?? w.contentView else { return false }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        // Some views (SwiftTerm's terminal) draw nothing through the window-wide
        // cache, but do when asked on their own: draw those again on top.
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for v in allSubviews(view) where v is SwiftTerm.TerminalView && !v.isHiddenOrHasHiddenAncestor {
                let r = v.convert(v.bounds, to: view)
                guard r.width > 1, r.height > 1, let sub = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: sub)
                let flipped = view.isFlipped ? NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) : r
                sub.draw(in: flipped, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
