import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `Slots.tabStrip`: one tab per session, and the + after them.
struct SessionsTabStrip: View {
    let window: WindowModel
    @StateObject private var dropNew = LocalFlag()

    var body: some View {
        let s = window.feature(SessionsWindow.self)
        let p = Theme.shared.p
        GeometryReader { g in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(s.tabs) { t in TabItemView(s: s, tab: t) }
                    AddTabButton(window: window)
                    // Past the end of the tabs: a tab of its own for a dragged pane.
                    Rectangle().fill(Color.clear)
                        .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .overlay(alignment: .leading) { if dropNew.on { p.accent.frame(width: 3) } }
                        .onDrop(of: [UTType.text], delegate: NewTabDropDelegate(s: s, active: $dropNew.on))
                }
                .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// The + button: a new session; right-click for the other ways in.
private struct AddTabButton: View {
    let window: WindowModel
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        Button { Actions.shared.perform("new-session", window: window) } label: {
            Text("+").font(.system(size: 17))
                .frame(width: 34, height: 38)
                .foregroundStyle(hover.on ? p.text : p.muted)
                .background(hover.on ? p.panel2 : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help("New session or local shell (⌘N)")
        .tourAnchor("tab-add")
        .contextMenu {
            Button("New session…  ⌘N") { Actions.shared.perform("new-session", window: window) }
            Button("Quick connect…  ⌘⌥C") { Actions.shared.perform("quick-connect", window: window) }
            Button("New local shell  ⌘T") { Actions.shared.perform("new-local", window: window) }
        }
    }
}

/// One tab: connection dot, who and where, what it is doing, close.
struct TabItemView: View {
    let s: SessionsWindow
    let tab: SessionTab
    @StateObject private var hover = LocalFlag()
    @StateObject private var dropInto = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let paneIds = tab.paneIds
        let first = s.pane(paneIds.first)
        let active = tab.id == s.activeTabId
        let label = SessConnRecords.shared.label(tab.connId)
        let title = (first.map { SessionsCore.paneTitle($0) }?.nilIfEmpty)
            ?? (tab.kind == "local" ? "Local shell" : (label ?? tab.title))
        let suffix = (paneIds.count > 1 ? " (\(paneIds.count))" : "") + (tab.tmuxEnded.map { " \u{2014} \($0)" } ?? "")
        let tint = SessionsCore.hostColor(connId: tab.connId)
        let tooltip: String = {
            guard let first else { return title }
            var lines = [SessionsCore.paneTitle(first, long: true)]
            if let c = tab.connId { lines.append("\(SessConn.target(c) ?? "") — \(SessConn.state(c))") }
            return lines.filter { !$0.isEmpty }.joined(separator: "\n")
        }()

        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let act: PaneActivity.State = (PaneActivity.showTabActivity && !active) ? PaneActivity.shared.tabActivity(paneIds) : .idle
            HStack(spacing: 7) {
                Circle().fill(dotColor(p)).frame(width: 7, height: 7)
                    .opacity(dotPulse ? 0.6 : 1)
                Text(title + suffix)
                    .font(.system(size: 12))
                    .italic(tab.tmuxEnded != nil)
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(act == .waiting ? p.amber : (tint ?? (active || hover.on ? p.text : p.textDim)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActivityMark(state: act)
                    .help(act == .waiting ? "Waiting for an answer in this tab" : act == .moving ? "Output is arriving in this tab" : "")
                Button { Task { await s.requestCloseTab(tab.id) } } label: {
                    Text("×").font(.system(size: 14)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.muted)
                .opacity(hover.on || active ? 1 : 0)
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(minWidth: 110, maxWidth: 230, maxHeight: .infinity)
            .background(background(p, active: active, act: act))
            .overlay(alignment: .bottom) {
                if dropInto.on { p.accent.frame(height: 2) }
                else if active { p.accent.frame(height: 2) }
                else if let tint { tint.frame(height: 2) }
            }
            .overlay(alignment: .trailing) { p.borderSoft.frame(width: 1) }
            .opacity(tab.tmuxEnded != nil ? 0.6 : 1)
        }
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear
                .onAppear { s.tabFrames[tab.id] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in s.tabFrames[tab.id] = f }
        })
        .onHover { hover.on = $0 }
        .onTapGesture {
            s.setActiveTab(tab.id)
            s.focusActivePane()
        }
        .help(tooltip)
        .contextMenu { menu(title) }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(s: s, tab: tab, active: $dropInto.on))
    }

    private var dotPulse: Bool {
        let st = SessConn.state(tab.connId)
        return tab.kind == "remote" && (st == "connecting" || st == "prompting")
    }

    private func dotColor(_ p: Palette) -> Color {
        guard tab.kind == "remote" else { return p.purple }
        switch SessConn.state(tab.connId) {
        case "connected": return p.green
        case "connecting", "prompting": return p.amber
        case "error": return p.red
        default: return p.muted
        }
    }

    private func background(_ p: Palette, active: Bool, act: PaneActivity.State) -> Color {
        if dropInto.on { return p.accent.opacity(0.14) }
        if act == .waiting { return p.amber.opacity(hover.on ? 0.20 : 0.13) }
        if active { return p.bg }
        return hover.on ? p.panel2 : .clear
    }

    @ViewBuilder
    private func menu(_ title: String) -> some View {
        Button("Duplicate tab  ⌘D") { s.setActiveTab(tab.id); Task { await s.duplicateActiveTab() } }
        Button("Split right  ⌘⇧D") { s.setActiveTab(tab.id); Task { await s.splitActivePane(.row) } }
        Button("Split down  ⌘⇧E") { s.setActiveTab(tab.id); Task { await s.splitActivePane(.col) } }
        Divider()
        Button("Rename…") {
            Task {
                guard let v = await Modal.prompt(s.window, title: "Rename tab", value: title, ok: "Rename"), !v.isEmpty else { return }
                tab.title = v
                SessConnRecords.shared.get(tab.connId)?.labelOverride = v
                s.changed()
            }
        }
        Divider()
        Button("Close other tabs") { Task { await s.requestCloseTabs(s.tabs.filter { $0.id != tab.id }.map(\.id)) } }
        Button("Close tab  ⌘W") { Task { await s.requestCloseTab(tab.id) } }
    }
}

/// Bars that ripple while output arrives; an amber "?" while it waits. One
/// reserved slot, so nothing in the strip moves.
struct ActivityMark: View {
    let state: PaneActivity.State

    var body: some View {
        let p = Theme.shared.p
        ZStack {
            if state == .moving {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .bottom, spacing: 1.5) {
                        ForEach(0..<3) { i in
                            let ph = (t - Double(i) * 0.15) / 0.9 * 2 * .pi
                            RoundedRectangle(cornerRadius: 1).fill(p.accent)
                                .frame(width: 2, height: 3 + 6 * (0.5 - 0.5 * cos(ph)))
                        }
                    }
                    .frame(width: 10, height: 10, alignment: .bottom)
                }
            } else if state == .waiting {
                Text("?").font(.system(size: 11, weight: .bold)).foregroundStyle(p.amber)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

/// A pane dragged onto a tab moves into it.
struct TabDropDelegate: DropDelegate {
    let s: SessionsWindow
    let tab: SessionTab
    @Binding var active: Bool

    @MainActor private func ok() -> Bool {
        guard let id = PaneDrag.shared.current, let p = s.pane(id) else { return false }
        return p.tabId != tab.id
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
            s.movePaneToTab(id, tab.id)
            return true
        }
    }
}

/// Past the last tab: a tab of its own (when it is not alone already).
struct NewTabDropDelegate: DropDelegate {
    let s: SessionsWindow
    @Binding var active: Bool

    @MainActor private func ok() -> Bool {
        guard let id = PaneDrag.shared.current, let p = s.pane(id) else { return false }
        return s.panesOf(p.tabId).count >= 2
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
            s.movePaneToNewTab(id)
            return true
        }
    }
}
