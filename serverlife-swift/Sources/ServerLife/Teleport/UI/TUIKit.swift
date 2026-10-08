import AppKit
import SwiftUI

// Small building blocks the Teleport UI shares: the `.tag` pills, a wrapping
// row for button strips, right-click on a SwiftUI view, a mono `pre`, the
// `nt-kv` rows, and `modal()` with a result (ui.js `modal({ buttons })`).

/// `.tag` (with `.live`, `.expired`, `.warn`, `.ok`, `.req` …).
struct TUITag: View {
    enum Kind { case plain, live, expired, warn, ok, accent, gone, stale }
    let text: String
    var kind: Kind = .plain
    var help: String? = nil
    var body: some View {
        let p = Theme.shared.p
        let c: Color = {
            switch kind {
            case .plain: return p.textDim
            case .live, .ok: return p.green
            case .expired, .gone: return p.red
            case .warn, .stale: return p.amber
            case .accent: return p.accent
            }
        }()
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(c)
            .background(RoundedRectangle(cornerRadius: 3).fill(kind == .plain ? p.panel3 : c.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(kind == .plain ? p.border : c.opacity(0.35), lineWidth: 0.5))
            .help(help ?? "")
    }
}

/// The coloured status dot (`.st`, `.st.connected`, `.st.error`).
struct TUIDot: View {
    var color: Color?
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color ?? Theme.shared.p.muted.opacity(0.6)).frame(width: size, height: size)
    }
}

/// A row that wraps its children onto more lines (`flex-wrap: wrap`).
struct TUIFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}

/// `<pre>`: monospaced, selectable, wrapping.
struct TUIPre: View {
    let text: String
    var maxHeight: CGFloat? = nil
    var size: CGFloat = 11
    var body: some View {
        let p = Theme.shared.p
        ScrollView(.vertical) {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: size, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9)
        }
        .frame(maxHeight: maxHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}

/// `.nt-kv`: a key on the left, a value on the right.
struct TUIKeyValue: View {
    let key: String
    let value: String
    var body: some View {
        let p = Theme.shared.p
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(.system(size: 11.5)).foregroundStyle(p.muted).frame(width: 110, alignment: .leading)
            Text(value).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }
}

/// `.sb-empty`: a quiet centred message in a list.
struct TUIEmpty: View {
    let lines: [String]
    var error = false
    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).font(.system(size: 12)).multilineTextAlignment(.center)
                    .foregroundStyle(error ? p.red : p.textDim)
                    .opacity(i == 0 ? 1 : 0.75)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16).padding(.horizontal, 10)
    }
}

/// A card (`.req-card`, `.mx-result`).
struct TUICard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }
}

/// A labelled field (ui.js `field(label, input, hint)`), label above.
struct TUIField<Content: View>: View {
    let label: String?
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        MiscField(label: label, hint: hint, content: content)
    }
}

// MARK: - Right-click on a SwiftUI view

extension View {
    /// Run `action` on a right-click (or control-click) over this view, leaving
    /// left clicks alone. Used for the context menus the original attached with
    /// `addEventListener('contextmenu', …)`.
    func onRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(TUIRightClickCatcher(action: action))
    }
}

private struct TUIRightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.action = action
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return right ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { action?() } else { super.mouseDown(with: event) }
        }
    }
}

// MARK: - Dialogs with a result

@MainActor
enum TUIModal {
    /// A sheet that resolves to a value (ui.js `modal()` → `close(value)`).
    /// Closing it any other way (Escape) resolves to nil.
    static func ask<T, V: View>(_ owner: WindowModel?, title: String, width: CGFloat = 560, height: CGFloat? = nil,
                                resizable: Bool = false, autosave: String? = nil,
                                @ViewBuilder content: @escaping (_ finish: @escaping (T?) -> Void, _ handle: ModalHandle) -> V) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            var answered = false
            var handleRef: ModalHandle?
            let finish: (T?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
                handleRef?.close()
            }
            let h = Modal.sheet(owner, title: title, width: width, height: height, resizable: resizable || height != nil,
                                autosave: autosave) { handle in
                content(finish, handle)
            }
            handleRef = h
            h.onClose.append { finish(nil) }
        }
    }

    /// A sheet that is only shown (no result).
    @discardableResult
    static func show<V: View>(_ owner: WindowModel?, title: String, width: CGFloat = 560, height: CGFloat? = nil,
                              autosave: String? = nil, @ViewBuilder content: (ModalHandle) -> V) -> ModalHandle {
        Modal.sheet(owner, title: title, width: width, height: height, resizable: height != nil, autosave: autosave,
                    content: content)
    }
}

// MARK: - Messages (ui.js `status` / `toast`)

@MainActor
enum TUIStatus {
    /// `status(text, ms)`; 0 = stays until replaced.
    static func show(_ text: String, ms: Double? = nil) {
        if text.isEmpty { StatusBus.shared.clear(); return }
        if let ms { StatusBus.shared.show(text, kind: .info, seconds: ms / 1000) } else { StatusBus.shared.show(text, kind: .info) }
    }
    static func clear() { StatusBus.shared.clear() }

    /// `toast(text, kind, ms)` with the original's kind names.
    static func toast(_ text: String, _ kind: String = "info", ms: Double? = nil) {
        let k: StatusBus.Kind = kind == "error" ? .error : kind == "success" ? .ok : kind == "warn" ? .warn : .info
        if let ms { StatusBus.shared.toast(text, kind: k, seconds: ms / 1000) } else { StatusBus.shared.toast(text, kind: k) }
    }
}
