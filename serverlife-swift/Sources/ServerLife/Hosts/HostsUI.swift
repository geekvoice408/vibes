import AppKit
import SwiftUI

// Form and list pieces shared by the hosts dialogs: ui.js `textInput`,
// `select`, `.field-row`, `.picker-list` / `.picker-item`, `.tag`.

/// `textInput`: a rounded text field, optionally monospaced.
struct HField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var disabled = false
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: mono ? .monospaced : .default))
            .disabled(disabled)
            .onSubmit(onSubmit)
    }
}

/// A number field (`type: 'number'`) that keeps its text as typed.
struct HNumberField: View {
    @Binding var text: String
    var width: CGFloat? = nil
    var onEdit: () -> Void = {}
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: width)
            .onChange(of: text) { _, _ in onEdit() }
    }
}

/// ui.js `select(options, value)`.
struct HSelect: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var disabled = false
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A multi-line text box (`textarea`).
struct HTextArea: View {
    @Binding var text: String
    var placeholder = ""
    var height: CGFloat = 64
    var mono = true
    var body: some View {
        let p = Theme.shared.p
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(4)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                    .foregroundStyle(p.muted)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
    }
}

/// `.field-row`: fields side by side.
struct HFieldRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) { content() }
    }
}

/// `.tag` (and `.tag.warn`).
struct HTag: View {
    let text: String
    var warn = false
    var color: Color? = nil
    var help: String? = nil
    var body: some View {
        let p = Theme.shared.p
        let c = color ?? (warn ? p.amber : p.textDim)
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(c)
            .background(RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.13)))
            .help(help ?? "")
    }
}

/// `.picker-head`: a group title in a picker list.
struct HPickerHead: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).kerning(0.5)
            .foregroundStyle(Theme.shared.p.muted)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.picker-item`: one row of a picker list.
struct HPickerRow<Trailing: View>: View {
    let name: String
    var meta: String = ""
    var active = false
    var mono = false
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    var onDoubleClick: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: mono ? 11.5 : 12.5, design: mono ? .monospaced : .default))
                .lineLimit(mono ? nil : 1)
                .fixedSize(horizontal: false, vertical: mono)
                .frame(maxWidth: mono ? .infinity : nil, alignment: .leading)
            if !meta.isEmpty {
                Text(meta).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? p.accent.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onHover { if $0 { onHover() } }
        .modifier(HostsClicks(single: onClick, double: onDoubleClick))
    }
}

/// A click, and a double-click only when one is wanted — so a plain click is
/// not held back for the double-click interval.
struct HostsClicks: ViewModifier {
    let single: () -> Void
    let double: (() -> Void)?
    func body(content: Content) -> some View {
        if let double {
            content.gesture(TapGesture(count: 2).onEnded { double() }
                .exclusively(before: TapGesture(count: 1).onEnded { single() }))
        } else {
            content.onTapGesture { single() }
        }
    }
}

extension HPickerRow where Trailing == EmptyView {
    init(name: String, meta: String = "", active: Bool = false, onHover: @escaping () -> Void = {},
         onClick: @escaping () -> Void = {}) {
        self.init(name: name, meta: meta, active: active, onHover: onHover, onClick: onClick, trailing: { EmptyView() })
    }
}

/// `.sb-empty`.
struct HEmpty: View {
    let text: String
    var color: Color? = nil
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color ?? Theme.shared.p.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The `.picker-list` box.
struct HListBox<Content: View>: View {
    var maxHeight: CGFloat? = 360
    var minHeight: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        content()
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }
}

/// Toasts the way ui.js `toast(message, kind)` was used from dialogs.
@MainActor
enum HToast {
    static func error(_ s: String, seconds: Double = 5) { StatusBus.shared.toast(s, kind: .error, seconds: seconds) }
    static func ok(_ s: String, seconds: Double = 5) { StatusBus.shared.toast(s, kind: .ok, seconds: seconds) }
    static func info(_ s: String) { StatusBus.shared.toast(s, kind: .info) }
}

/// `status(text, 0)` / `status('')`.
@MainActor
enum HStatus {
    static func show(_ s: String, sticky: Bool = false) {
        if s.isEmpty { StatusBus.shared.clear(); return }
        StatusBus.shared.show(s, seconds: sticky ? 0 : 6)
    }
}

/// Key handling for the list pickers: ↑ ↓ ⏎ while the picker's window is
/// key. A local key monitor rather than `onKeyPress`, because a focused text
/// field's editor takes the arrows and Return before SwiftUI sees them.
extension View {
    func hostsPickerKeys(up: @escaping () -> Void, down: @escaping () -> Void, enter: @escaping () -> Void) -> some View {
        background(HostsPickerKeyMonitor(up: up, down: down, enter: enter))
    }
}

private struct HostsPickerKeyMonitor: NSViewRepresentable {
    let up: () -> Void, down: () -> Void, enter: () -> Void
    func makeNSView(context: Context) -> HostsKeyMonitorView { update(HostsKeyMonitorView()) }
    func updateNSView(_ v: HostsKeyMonitorView, context: Context) { _ = update(v) }
    private func update(_ v: HostsKeyMonitorView) -> HostsKeyMonitorView { v.up = up; v.down = down; v.enter = enter; return v }
}

final class HostsKeyMonitorView: NSView {
    var up: () -> Void = {}, down: () -> Void = {}, enter: () -> Void = {}
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, e.window === w else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return e }
            switch e.keyCode {
            case 126: self.up(); return nil
            case 125: self.down(); return nil
            case 36, 76: self.enter(); return nil
            default: return e
            }
        }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

/// A wrapping row (`display:flex; flex-wrap:wrap`).
struct HFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, width)
            if x > 0 && x + w > width { y += line + lineSpacing; x = 0; line = 0 }
            x += w + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: s.height))
            x += w + spacing
            line = max(line, s.height)
        }
    }
}
