import AppKit
import SwiftUI

/// `modal({ … })` that resolves with whatever `close(value)` is called with,
/// or nil when cancelled / closed.
@MainActor
enum XPDialog {
    static func present<T>(_ owner: WindowModel?, title: String = "", width: CGFloat = 520, height: CGFloat? = nil,
                           resizable: Bool = false, autosave: String? = nil,
                           _ make: @escaping (_ done: @escaping (T?) -> Void) -> AnyView) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            var answered = false
            var handleRef: ModalHandle?
            let finish: (T?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
                handleRef?.close()
            }
            let h = Modal.sheet(owner, title: title, width: width, height: height, resizable: resizable,
                                autosave: autosave) { _ in make(finish) }
            handleRef = h
            h.onClose.append { finish(nil) }
        }
    }
}

/// Wraps children onto as many lines as they need (`display:flex;flex-wrap:wrap`).
struct XPFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 10_000
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

/// Right-click (and control-click) on a SwiftUI view, delivered with the
/// pointer where it happened — for menus built at the moment they open.
struct XPRightClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
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

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.action = action
        return v
    }

    func updateNSView(_ v: Catcher, context: Context) { v.action = action }
}

extension View {
    func xpOnRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(XPRightClick(action: action))
    }
}

/// A single-line text field that reports Enter, Escape and the arrow keys
/// (`keydown` in the original), and can be focused from the model.
struct XPTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var mono = true
    var size: CGFloat = 11.5
    var tooltip: String? = nil
    var focusToken = 0
    var onChange: ((String) -> Void)? = nil
    var onEnter: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var onArrow: ((Int) -> Void)? = nil
    var onFocus: ((Bool) -> Void)? = nil

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: XPTextField
        var lastToken = 0
        init(_ p: XPTextField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
            parent.onChange?(f.stringValue)
        }
        func controlTextDidBeginEditing(_ obj: Notification) { parent.onFocus?(true) }
        func controlTextDidEndEditing(_ obj: Notification) { parent.onFocus?(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                if let f = parent.onEnter { f(); return true }
            case #selector(NSResponder.cancelOperation(_:)):
                if let f = parent.onEscape { f(); return true }
            case #selector(NSResponder.moveDown(_:)):
                if let f = parent.onArrow { f(1); return true }
            case #selector(NSResponder.moveUp(_:)):
                if let f = parent.onArrow { f(-1); return true }
            default: break
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.delegate = context.coordinator
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byTruncatingHead
        f.font = mono ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        f.placeholderString = placeholder
        f.toolTip = tooltip
        f.stringValue = text
        context.coordinator.lastToken = focusToken
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
        else if f.currentEditor() != nil, f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
        f.toolTip = tooltip
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0)
            }
        }
    }
}

/// `.picker-item` rows: a name, a dim second line, clickable.
struct XPPickerRow: View {
    let name: String
    var meta: String = ""
    var active = false
    let action: () -> Void
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 6)
                if !meta.isEmpty {
                    Text(meta).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? p.accent.opacity(0.18) : hover.on ? p.panel3 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// `.picker-list`: a bordered, scrolling list.
struct XPPickerList<Content: View>: View {
    var maxHeight: CGFloat = 320
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        ScrollView {
            VStack(spacing: 0) { content() }
        }
        .frame(maxHeight: maxHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }
}

/// A small label above a group of buttons in a dialog.
struct XPGroupLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.shared.p.muted).padding(.bottom, 5)
    }
}
