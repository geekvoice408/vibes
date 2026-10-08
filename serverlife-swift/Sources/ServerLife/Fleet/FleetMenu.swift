import AppKit
import SwiftUI

/// One entry of a Fleet drop-down menu.
struct FleetMenuItem: Identifiable {
    enum Kind { case item, heading, separator }
    var id = UUID()
    var kind: Kind = .item
    var label = ""
    /// Right-aligned hint ("careful · every 30s", a shortcut).
    var key: String?
    var icon: String?
    /// Hover text on the row.
    var title: String?
    /// The `?` card: what it answers, the command, notes — on its own hover target.
    var help: CtxHelp?
    var disabled = false
    var submenu: [FleetMenuItem]?
    var onClick: (() -> Void)?

    static let separator = FleetMenuItem(kind: .separator)
    static func heading(_ s: String) -> FleetMenuItem { FleetMenuItem(kind: .heading, label: s) }
}

/**
 * A drop-down menu drawn by Fleet rather than NSMenu, because the macro menu
 * needs two things NSMenu cannot do: a row that both runs something *and*
 * carries a submenu — opened from its arrow, not from the row, so a second
 * panel is not thrown under the pointer at each step down the list — and a
 * `?` on every row with a tooltip of its own, so "what does this do" does not
 * mean hovering the thing you have not decided to run.
 */
@MainActor
final class FleetMenu {
    private static var current: FleetMenu?
    private var panels: [FleetMenuPanel] = []
    private var monitor: Any?
    /// The row whose submenu is open at level+1, per level.
    private var subOwner: [Int: UUID] = [:]
    private var closeWork: [Int: DispatchWorkItem] = [:]
    private var helpPanel: NSPanel?

    /// Show `items` with the menu's top-right corner (or top-left) at
    /// `point` in screen coordinates.
    static func show(_ items: [FleetMenuItem], at point: NSPoint, alignRight: Bool = true) {
        current?.close()
        let m = FleetMenu()
        current = m
        m.open(items, level: 0) { size, vis in
            var x = alignRight ? point.x - size.width : point.x
            x = max(vis.minX + 8, min(x, vis.maxX - size.width - 8))
            return NSPoint(x: x, y: point.y)
        }
        m.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak m] e in
            MainActor.assumeIsolated {
                guard let m else { return e }
                if e.type == .keyDown {
                    if e.keyCode == 53 { m.close(); return nil }   // Escape
                    return e
                }
                if let w = e.window, m.panels.contains(where: { $0 === w }) { return e }
                m.close()
                return e
            }
        }
    }

    static func closeAll() { current?.close() }

    private func screenFrame(near p: NSPoint) -> NSRect {
        (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    }

    /// `place` gets the panel's size and the screen's visible frame and
    /// answers the top-left corner.
    private func open(_ items: [FleetMenuItem], level: Int, place: (NSSize, NSRect) -> NSPoint) {
        // Close deeper submenus first.
        closeBeyond(level - 1)
        let panel = FleetMenuPanel()
        // Measured without the scroll view, whose own height is not its content's.
        let measure = NSHostingView(rootView: AnyView(FleetMenuView(items: items, menu: self, level: level, scroll: false).themed()))
        let size = measure.fittingSize
        let host = FirstMouseHostingView(rootView: AnyView(
            FleetMenuView(items: items, menu: self, level: level, scroll: true).themed()))
        let probe = place(NSSize(width: max(size.width, 220), height: size.height), screenFrame(near: NSEvent.mouseLocation))
        let vis = screenFrame(near: probe)
        let height = min(size.height, vis.height - 16)
        let width = max(size.width, 220)
        let tl = place(NSSize(width: width, height: height), vis)
        var top = min(tl.y, vis.maxY)
        if top - height < vis.minY + 8 { top = vis.minY + 8 + height }
        panel.setFrame(NSRect(x: tl.x, y: top - height, width: width, height: height), display: false)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        panel.contentView = host
        panels.append(panel)
        panel.orderFrontRegardless()
        if level == 0 { panel.makeKey() }
    }

    /// Open (or keep open) the submenu of the row `owner` at `level`, beside
    /// the parent panel — flipped to its left when there is no room on the right.
    fileprivate func openSubmenu(_ items: [FleetMenuItem], owner: UUID, rowTop: CGFloat, level: Int) {
        cancelClose(level)
        if subOwner[level] == owner, panels.count > level + 1 { return }
        guard level < panels.count else { return }
        let parent = panels[level].frame
        subOwner[level] = owner
        open(items, level: level + 1) { size, vis in
            // No gap: dead space between the panels closes the submenu on the way to it.
            let right = parent.maxX + size.width + 4 <= vis.maxX
            return NSPoint(x: right ? parent.maxX : parent.minX - size.width, y: rowTop + 4)
        }
    }

    /// Closing is deliberately slow, so the diagonal move to a submenu works.
    fileprivate func scheduleClose(_ level: Int) {
        guard panels.count > level + 1 else { return }
        cancelClose(level)
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeBeyond(level) } }
        closeWork[level] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: w)
    }

    fileprivate func cancelClose(_ level: Int) {
        closeWork.removeValue(forKey: level)?.cancel()
    }

    /// The pointer is over a row at `level`: an open submenu that is not this
    /// row's gets the same grace period rather than shutting at once.
    fileprivate func hovered(_ owner: UUID, level: Int) {
        guard panels.count > level + 1 else { return }
        if subOwner[level] == owner { cancelClose(level) } else { scheduleClose(level) }
    }

    fileprivate func isOwner(_ owner: UUID, level: Int) -> Bool { subOwner[level] == owner && panels.count > level + 1 }

    private func closeBeyond(_ level: Int) {
        while panels.count > level + 1 { panels.removeLast().orderOut(nil) }
        for l in Array(subOwner.keys) where panels.count <= l + 1 { subOwner[l] = nil }
        hideHelp()
    }

    fileprivate func panel(_ level: Int) -> NSWindow? { level < panels.count ? panels[level] : nil }

    // MARK: The `?` card

    /// A card beside the *menu* (not the mark, where the panel would clip
    /// it): what it answers, the command it runs, notes. Not interactive, so
    /// nothing can be clicked by accident while reading it.
    fileprivate func showHelp(_ help: CtxHelp, rowTop: CGFloat, level: Int) {
        hideHelp()
        guard level < panels.count else { return }
        let menuFrame = panels[level].frame
        let host = NSHostingView(rootView: AnyView(FleetHelpCard(help: help).themed()))
        let size = host.fittingSize
        let vis = screenFrame(near: NSPoint(x: menuFrame.midX, y: menuFrame.midY))
        let right = menuFrame.maxX + 10 + size.width <= vis.maxX
        let x = right ? menuFrame.maxX + 10 : max(vis.minX + 8, menuFrame.minX - size.width - 10)
        let top = max(vis.minY + 8 + size.height, min(rowTop + 6, vis.maxY - 8))
        let p = NSPanel(contentRect: NSRect(x: x, y: top - size.height, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.orderFrontRegardless()
        helpPanel = p
    }

    fileprivate func hideHelp() {
        helpPanel?.orderOut(nil)
        helpPanel = nil
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        closeWork.values.forEach { $0.cancel() }
        closeWork = [:]
        hideHelp()
        for p in panels { p.orderOut(nil) }
        panels = []
        if FleetMenu.current === self { FleetMenu.current = nil }
    }

    fileprivate func fire(_ item: FleetMenuItem) {
        close()
        item.onClick?()
    }
}

private final class FleetMenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
    }
    override var canBecomeKey: Bool { true }
}

/// A submenu panel is not key; its first click must still choose.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// ui.js `.ctx-helpcard`.
private struct FleetHelpCard: View {
    let help: CtxHelp
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 5) {
            if let a = help.answers, !a.isEmpty {
                Text(a).font(.system(size: 12)).foregroundStyle(p.text).fixedSize(horizontal: false, vertical: true)
            }
            if let c = help.command, !c.isEmpty {
                Text("RUNS").font(.system(size: 9, weight: .semibold)).kerning(0.6).foregroundStyle(p.muted)
                Text(c).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(p.bg))
            }
            ForEach(help.notes, id: \.self) { n in
                Text(n).font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(p.panel3))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.border))
    }
}

private struct FleetMenuView: View {
    let items: [FleetMenuItem]
    let menu: FleetMenu
    let level: Int
    var scroll = true

    var body: some View {
        let p = Theme.shared.p
        Group {
            if scroll { ScrollView { list } } else { list }
        }
        .frame(minWidth: 220, maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 7).fill(p.panel2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.border))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        // A submenu keeps itself open while the pointer is in it.
        .onHover { inside in
            guard level > 0 else { return }
            if inside { menu.cancelClose(level - 1) } else { menu.scheduleClose(level - 1) }
        }
    }

    private var list: some View {
        let p = Theme.shared.p
        // An icon gutter in a panel that has icons, for every row.
        let gutter = items.contains { $0.icon != nil }
        return VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { it in
                    switch it.kind {
                    case .separator:
                        p.border.frame(height: 1).padding(.vertical, 4)
                    case .heading:
                        Text(it.label.uppercased())
                            .font(.system(size: 9.5, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(p.muted)
                            .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 2)
                    case .item:
                        FleetMenuRow(item: it, menu: menu, level: level, gutter: gutter)
                    }
                }
            }
            .padding(.vertical, 4)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct FleetMenuRow: View {
    let item: FleetMenuItem
    let menu: FleetMenu
    let level: Int
    let gutter: Bool
    @StateObject private var hover = LocalFlag()
    @StateObject private var frame = Local<CGRect>(.zero)

    private var hasSub: Bool { !(item.submenu ?? []).isEmpty && !item.disabled }

    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 6) {
            if gutter { Text(item.icon ?? "").font(.system(size: 12)).frame(width: 16) }
            Text(item.label).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 14)
            if let key = item.key, !key.isEmpty {
                Text(key).font(.system(size: 10.5)).foregroundStyle(hover.on ? Color.white.opacity(0.8) : p.muted).lineLimit(1)
            }
            if let help = item.help {
                Text("?")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 15, height: 15)
                    .foregroundStyle(hover.on ? Color.white : p.muted)
                    .overlay(Circle().stroke(hover.on ? Color.white.opacity(0.7) : p.border))
                    .contentShape(Circle())
                    .onHover { inside in if inside { menu.showHelp(help, rowTop: rowTop, level: level) } else { menu.hideHelp() } }
                    // A question about what a macro does is not a request to run it.
                    .onTapGesture { menu.showHelp(help, rowTop: rowTop, level: level) }
            }
            if hasSub, item.onClick != nil, let sub = item.submenu {
                Text("\u{203A}").font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .foregroundStyle(hover.on ? Color.white : p.textDim)
                    // A row that does something opens its submenu from the arrow only.
                    .onHover { inside in
                        if inside { openSub(sub) } else { menu.scheduleClose(level) }
                    }
                    .onTapGesture { openSub(sub) }
            } else if hasSub {
                Text("\u{203A}").font(.system(size: 14, weight: .semibold)).frame(width: 18, height: 18)
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(item.disabled ? p.muted : (hover.on ? Color.white : p.text))
        .background(RoundedRectangle(cornerRadius: 4).fill(hover.on && !item.disabled ? p.accent : Color.clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { inside in
            hover.on = inside
            if inside {
                // A row that is only a submenu parent opens on hover.
                if hasSub, item.onClick == nil, let sub = item.submenu { openSub(sub) } else { menu.hovered(item.id, level: level) }
            } else if menu.isOwner(item.id, level: level) {
                menu.scheduleClose(level)
            }
        }
        .onTapGesture {
            guard !item.disabled else { return }
            if item.onClick != nil { menu.fire(item) } else if let sub = item.submenu { openSub(sub) }
        }
        .help(item.title ?? "")
        .background(GeometryReader { g in
            Color.clear.onAppear { frame.value = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in frame.value = f }
        })
    }

    /// The row's top edge in screen coordinates.
    private var rowTop: CGFloat {
        guard let win = menu.panel(level) else { return NSEvent.mouseLocation.y }
        return win.frame.maxY - frame.value.minY
    }

    private func openSub(_ sub: [FleetMenuItem]) {
        menu.openSubmenu(sub, owner: item.id, rowTop: rowTop, level: level)
    }
}
