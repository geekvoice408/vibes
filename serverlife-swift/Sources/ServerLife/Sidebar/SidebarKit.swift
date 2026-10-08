import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Small pieces the sidebar's views share: the right-click menu catcher, the
// drag state, the host-list text size, and the badge/chip looks of
// styles.css (`.tag`, `.chip`, `.badge`).

/// The host list's text size (settings.sidebarFontSize, 10–22, base 13):
/// everything in the sidebar grows together, as CSS `zoom` did.
@MainActor
enum SBZoom {
    static var factor: CGFloat {
        let px = SB.store.settingJSON("sidebarFontSize").double ?? 13
        return CGFloat(max(10, min(22, px.rounded())) / 13)
    }
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: size * factor, weight: weight, design: mono ? .monospaced : .default)
    }
    static func px(_ v: CGFloat) -> CGFloat { v * factor }
}

/// What is being dragged inside the host list.
@MainActor
enum SBDrag {
    enum Item { case host(id: String, groupKey: String, host: Host), folder(HostFolder), group(String) }
    static var current: Item?
    /// The payload the current drag carries. SwiftUI has no "drag ended", so a
    /// drag cancelled outside a target leaves `current` set; a drop only acts
    /// when what arrives is this drag's own token, so a later drag of text
    /// from elsewhere can never replay a stale one.
    static var token: String?

    static func begin(_ item: Item) -> NSItemProvider {
        current = item
        let t = "serverlife-sidebar-drag:" + UUID().uuidString
        token = t
        return NSItemProvider(object: t as NSString)
    }

    static func end() { current = nil; token = nil }
}

// MARK: - Right-click

/// A transparent catcher for right-clicks (and control-clicks) that shows an
/// NSMenu built at the moment of the click; every other mouse event passes
/// through to the SwiftUI content underneath.
struct SBRightClick: NSViewRepresentable {
    let items: () -> [CtxItem]

    func makeNSView(context: Context) -> CatcherView { CatcherView(items: items) }
    func updateNSView(_ v: CatcherView, context: Context) { v.items = items }

    final class CatcherView: NSView {
        var items: () -> [CtxItem]
        init(items: @escaping () -> [CtxItem]) { self.items = items; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || e.type == .rightMouseUp
                || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return right ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            let list = MainActor.assumeIsolated { items() }
            guard !list.isEmpty else { return }
            let menu = MainActor.assumeIsolated { CtxMenu.build(list) }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

extension View {
    /// Attach a right-click menu built from `CtxItem`s when it is opened.
    func sbContextMenu(_ items: @escaping () -> [CtxItem]) -> some View {
        overlay(SBRightClick(items: items))
    }
}

// MARK: - Looks

/// `.tag`: a small rounded label on a row or heading.
struct SBTag: View {
    enum Kind { case plain, tunnel, mfa, stale, hb, req, gone, held, beams, live, expired, rule, pinned, ok }
    let text: String
    var kind: Kind = .plain
    var help: String? = nil
    var body: some View {
        let p = Theme.shared.p
        let (fg, bg, border): (Color, Color, Color?) = {
            switch kind {
            case .plain: return (p.muted, p.panel3, nil)
            case .tunnel, .beams: return (p.purple, p.purple.opacity(0.18), nil)
            case .mfa: return (p.amber, p.amber.opacity(0.18), nil)
            case .stale: return (p.amber, p.amber.opacity(0.18), p.amber.opacity(0.4))
            case .hb: return (p.muted, .clear, nil)
            case .req: return (p.accent, p.accent.opacity(0.16), p.accent.opacity(0.45))
            case .gone: return (p.amber, p.amber.opacity(0.16), p.amber.opacity(0.45))
            case .held: return (p.textDim, .clear, p.border)
            case .live, .ok: return (p.green, p.green.opacity(0.16), nil)
            case .expired: return (p.red.opacity(0.75), p.panel3, nil)
            case .rule: return (p.text, p.accentDim, nil)
            case .pinned: return (p.text, .clear, nil)
            }
        }()
        Text(text)
            .font(SBZoom.font(kind == .pinned ? 12 : 9.5, kind == .mfa || kind == .live || kind == .req ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, SBZoom.px(kind == .hb ? 2 : 5)).padding(.vertical, SBZoom.px(1))
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 3).fill(bg))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: kind == .held ? [2, 2] : []))
                }
            }
            .help(help ?? "")
    }
}

/// `.chip`: `key = value`, clickable, lit when the filter names it.
struct SBChip: View {
    var key: String?
    var value: String
    var count: Int? = nil
    var on = false
    var italic = false
    var size: CGFloat = 10.5
    var help: String = ""
    var action: () -> Void
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        // Key in the secondary label colour, value in the primary one, each
        // at full strength: dimming an already-dim colour made them unreadable.
        let keyColour: Color = on ? Color.white.opacity(0.85) : p.textDim
        let valueColour: Color = on ? Color.white : p.text
        Button(action: action) {
            HStack(spacing: 3) {
                if let key {
                    Text(key).foregroundStyle(keyColour).lineLimit(1)
                    Text("=").foregroundStyle(p.muted)
                }
                Text(value).foregroundStyle(valueColour).lineLimit(1).italic(italic)
                if let count { Text(String(count)).foregroundStyle(keyColour) }
            }
            .font(SBZoom.font(max(size, 10.5), mono: true))
            .padding(.horizontal, SBZoom.px(6)).padding(.vertical, SBZoom.px(1.5))
            .background(RoundedRectangle(cornerRadius: 3).fill(on ? p.accentDim : p.panel3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? p.accent : (hover.on ? p.accentDim : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

/// `.badge`: muted status text (ok / warn / err).
struct SBBadge: View {
    let text: String
    var kind = ""
    var body: some View {
        let p = Theme.shared.p
        Text(text)
            .font(SBZoom.font(10.5))
            .lineLimit(1).truncationMode(.tail)
            .foregroundStyle(kind == "ok" ? p.green : kind == "warn" ? p.amber : kind == "err" ? p.red : p.muted)
    }
}

/// `.ghost-btn sm` with an "active" state (Show tags, Heartbeats, Quiet).
struct SBToolButton: View {
    let title: String
    var active = false
    var help: String = ""
    let action: () -> Void
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        Button(action: action) {
            Text(title)
                .font(SBZoom.font(11))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, SBZoom.px(7)).padding(.vertical, SBZoom.px(2))
                .foregroundStyle(active ? Color.white : p.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? p.accentDim : (hover.on ? p.panel3 : p.panel2)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? p.accent : p.border))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

/// The 6px connection dot (`.st`).
struct SBDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: SBZoom.px(6), height: SBZoom.px(6)) }
}

/// A row's hover wash.
struct SBHoverRow<Content: View>: View {
    var active = false
    var leftColor: Color? = nil
    var groupColor: Color? = nil
    @ViewBuilder var content: () -> Content
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? p.panel3 : (hover.on ? p.panel2 : Color.clear))
            .overlay(alignment: .leading) {
                if let leftColor { leftColor.frame(width: 2) }
                else if active { p.accent.frame(width: 2) }
            }
            .overlay(alignment: .leading) { if let groupColor { groupColor.opacity(0.55).frame(width: 2) } }
            .contentShape(Rectangle())
            .onHover { hover.on = $0 }
    }
}

/// A drop target that reports the pointer's half (above / below the middle).
struct SBDropDelegate: DropDelegate {
    var height: CGFloat
    var canTake: () -> Bool
    var onTarget: (_ after: Bool?) -> Void
    var perform: (_ after: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { canTake() } }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: MainActor.assumeIsolated { canTake() } ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { MainActor.assumeIsolated { onTarget(nil) } }
    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.y > height / 2
        MainActor.assumeIsolated { onTarget(nil) }
        guard let provider = info.itemProviders(for: [.text]).first else {
            MainActor.assumeIsolated { SBDrag.end() }
            return false
        }
        let perform = self.perform, canTake = self.canTake
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            let got = obj as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let got, got == SBDrag.token, canTake() { perform(after) }
                    SBDrag.end()
                }
            }
        }
        return true
    }
    private func update(_ info: DropInfo) {
        let after = info.location.y > height / 2
        MainActor.assumeIsolated { if canTake() { onTarget(after) } }
    }
}

/// Reads a view's height into a binding.
struct SBHeightReader: View {
    @Binding var height: CGFloat
    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { height = g.size.height }
                .onChange(of: g.size.height) { _, v in height = v }
        }
    }
}

extension HostColor {
    /// The colour for a stored value, or nil.
    static func swiftColor(_ hex: String) -> Color? { hex.isEmpty ? nil : Color(hex: hex) }
}
