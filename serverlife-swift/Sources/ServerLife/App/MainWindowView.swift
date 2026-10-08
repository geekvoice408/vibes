import SwiftUI

/// Where features draw into a window. Each slot is filled by one feature's
/// `install()`; until then it shows a quiet placeholder. This is what lets
/// the shell be written before the things it holds.
@MainActor
enum Slots {
    /// The tabs across the top of the window (sessions/Tabs).
    static var tabStrip: (WindowModel) -> AnyView = { _ in AnyView(Spacer()) }
    /// Buttons at the right end of the title bar.
    static var titlebarActions: (WindowModel) -> AnyView = { w in AnyView(TitlebarActionsView(window: w)) }
    /// The host list and its tabs (sidebar).
    static var sidebar: (WindowModel) -> AnyView = { _ in AnyView(SlotPlaceholder(text: "Hosts")) }
    /// The panes, or the start page when nothing is open (sessions).
    static var workspace: (WindowModel) -> AnyView = { _ in AnyView(SlotPlaceholder(text: "No sessions")) }
    /// The dock along the bottom (transfers, multi-exec, tunnels, log, downloads, watch).
    static var dock: (WindowModel) -> AnyView = { _ in AnyView(SlotPlaceholder(text: "Dock")) }
    /// Things drawn over the whole window: the tour, floating monitor pane …
    static var overlays: [(WindowModel) -> AnyView] = []
}

struct SlotPlaceholder: View {
    let text: String
    var body: some View {
        ZStack {
            Theme.shared.p.bg
            Text(text).foregroundStyle(Theme.shared.p.muted)
        }
    }
}

struct MainWindowView: View {
    let window: WindowModel

    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 0) {
            TitleBar(window: window)
            HStack(spacing: 0) {
                if window.sidebarVisible {
                    Slots.sidebar(window)
                        .frame(width: window.sidebarWidth)
                        .background(p.panel)
                    Resizer(axis: .vertical) { delta in
                        window.sidebarWidth = min(460, max(170, window.sidebarWidth + delta))
                    } onEnd: {
                        window.rememberPanelSize("#sidebar-resizer", window.sidebarWidth)
                    }
                }
                VStack(spacing: 0) {
                    Slots.workspace(window)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if window.dockVisible {
                        Resizer(axis: .horizontal) { delta in
                            // 108pt up to half the window, wherever it is opened (index.js).
                            let cap = max(108, (window.nsWindow?.contentView?.bounds.height ?? 1400) * 0.5)
                            window.dockHeight = min(cap, max(108, window.dockHeight - delta))
                        } onEnd: {
                            window.rememberPanelSize("#bottom-resizer", window.dockHeight)
                        }
                        Slots.dock(window)
                            .frame(height: window.dockHeight)
                            .background(p.panel)
                    }
                }
            }
            StatusBarView(window: window)
        }
        .background(p.bg)
        .overlay(alignment: .bottomTrailing) { ToastsView().padding(.bottom, 30).padding(.trailing, 12) }
        .overlay {
            ForEach(Array(Slots.overlays.enumerated()), id: \.offset) { _, make in make(window) }
        }
        .themed()
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The title bar: room for the traffic lights, the tab strip, the actions.
private struct TitleBar: View {
    let window: WindowModel
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 0) {
            // Tabs start where the panes do: over the sidebar is the sidebar's
            // (with room for the window buttons), not the first tab's.
            let buttons: CGFloat = window.nsWindow?.styleMask.contains(.fullScreen) == true ? 8 : 78
            Color.clear.frame(width: window.sidebarVisible ? max(buttons, window.sidebarWidth + 5) : buttons)
            Slots.tabStrip(window)
            Slots.titlebarActions(window)
                .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(p.panel)
        .overlay(alignment: .bottom) { p.border.frame(height: 1) }
    }
}

/// A draggable divider between two panels.
struct Resizer: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    var thickness: CGFloat = 5
    let onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    @StateObject private var last = Local<CGFloat?>(nil)

    var body: some View {
        let p = Theme.shared.p
        ZStack {
            Color.clear
            (axis == .vertical ? AnyView(p.border.frame(width: 1)) : AnyView(p.border.frame(height: 1)))
        }
        .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let v = axis == .vertical ? g.location.x : g.location.y
                    if let l = last.value { onDrag(v - l) }
                    last.value = v
                }
                .onEnded { _ in last.value = nil; onEnd() }
        )
    }
}

/// The status bar: feature items on the left, the transient message after.
struct StatusBarView: View {
    let window: WindowModel
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 14) {
            ForEach(StatusItems.shared.items, id: \.id) { item in item.view(window) }
            if let m = StatusBus.shared.message {
                Text(m.text)
                    .foregroundStyle(color(m.kind, p))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(p.textDim)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(p.panel)
        .overlay(alignment: .top) { p.border.frame(height: 1) }
    }

    private func color(_ k: StatusBus.Kind, _ p: Palette) -> Color {
        switch k {
        case .info: return p.textDim
        case .ok: return p.green
        case .warn: return p.amber
        case .error: return p.red
        }
    }
}

private struct ToastsView: View {
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(StatusBus.shared.toasts) { t in
                HStack(spacing: 8) {
                    Text(t.text).font(.system(size: 12)).textSelection(.enabled)
                    Button { StatusBus.shared.dismissToast(t.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(p.muted)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel3))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.kind == .error ? p.red : t.kind == .warn ? p.amber : p.border))
                .shadow(radius: 6, y: 2)
                .frame(maxWidth: 420, alignment: .trailing)
            }
        }
    }
}
