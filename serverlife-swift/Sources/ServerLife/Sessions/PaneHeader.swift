import AppKit
import SwiftUI

/// A pane's title bar: who and where, the scrollback search, highlighting,
/// network tools, tmux's controls, pinned macros, the macro menu, the file
/// browser toggle and close.
struct PaneHeaderView: View {
    let s: SessionsWindow
    let pane: SessionPane
    let focused: Bool

    var body: some View {
        let p = Theme.shared.p
        let colour = SessionsCore.hostColor(connId: pane.connId)
        let title = SessionsCore.paneTitle(pane)
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(colour ?? (focused ? p.textDim : p.muted))
                .lineLimit(1).truncationMode(.tail)
                .help(SessionsCore.paneTitle(pane, long: true))
                .allowsHitTesting(false)
            if let ended = pane.tmuxEnded {
                Text(ended).font(.system(size: 10.5)).foregroundStyle(p.amber).allowsHitTesting(false)
            }
            Spacer(minLength: 4)
            if pane.kind != .view {
                PaneSearchBox(s: s, pane: pane)
                highlightButton(p)
            }
            if pane.kind == .remote && Store.shared.settingJSON("showPaneNetIcon").bool != false {
                Button("\u{2317}") {
                    s.setActivePane(pane.id)
                    Actions.shared.perform("nettools", window: s.window, paneId: pane.id, connId: pane.connId,
                                           args: ["connId": pane.connId ?? "", "tool": "ports"])
                }
                .buttonStyle(HeaderButtonStyle())
                .help("Network tools from this host — reachability, HTTP and its own addresses")
            }
            let tmuxCtl = PaneHeaderItems.shared.views(.tmuxControls, pane)
            if !tmuxCtl.isEmpty {
                HStack(spacing: 1) { ForEach(Array(tmuxCtl.enumerated()), id: \.offset) { $0.element } }
                    .padding(.horizontal, 4)
                    .overlay(alignment: .leading) { p.borderSoft.frame(width: 1) }
                    .overlay(alignment: .trailing) { p.borderSoft.frame(width: 1) }
            }
            let pins = PaneHeaderItems.shared.views(.macroPins, pane)
            if !pins.isEmpty {
                HStack(spacing: 1) { ForEach(Array(pins.enumerated()), id: \.offset) { $0.element } }
            }
            if !pane.filesOnly && pane.kind != .view {
                Button("\u{25B6}") {
                    s.setActivePane(pane.id)
                    Actions.shared.perform("run-macro", window: s.window, paneId: pane.id, connId: pane.connId)
                }
                .buttonStyle(HeaderButtonStyle(color: p.green, size: 9, pulsing: pane.macroRepeating))
                .help(pane.macroButtonTitle ?? (pane.kind == .local ? "Run a macro in this shell (⌘⇧R)" : "Run a macro on this host (⌘⇧R)"))
            }
            if PaneAccessories.shared.hasProvider && pane.kind != .view {
                Button("\u{2630}") { s.setExplorerVisible(pane, !pane.explorerVisible) }
                    .buttonStyle(HeaderButtonStyle(active: pane.explorerVisible))
                    .help("Show/hide this file explorer (⌘E)\nRight-click for every pane in this tab")
                    .contextMenu { explorerScopeMenu() }
            }
            Button("×") { s.closePane(pane.id) }
                .buttonStyle(HeaderButtonStyle(size: 13))
                .help("Close pane")
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(PaneDragSource(s: s, paneId: pane.id))
        .background(focused ? p.panel2 : p.panel)
        .overlay(alignment: .leading) { if let colour { colour.frame(width: 2) } }
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
    }

    @ViewBuilder
    private func highlightButton(_ p: Palette) -> some View {
        let n = pane.highlightCount
        let key = SessionsCore.hostKey(of: pane)
        Button("\u{25A4}") { s.toggleHighlight(pane) }
            .buttonStyle(HeaderButtonStyle(color: n > 0 ? p.amber : nil, dim: n == 0))
            .help(n > 0 ? "Highlighting \(n) keyword pattern\(n == 1 ? "" : "s") — click to turn off, right-click to edit"
                        : "Highlight keywords in this session — right-click to edit")
            .contextMenu {
                Section("Keyword highlighting") {
                    Button("Highlights…") {
                        HighlightEditor.open(s.window, hostKey: key,
                                             hostLabel: pane.kind == .local ? "the local shell" : (SessConnRecords.shared.label(pane.connId) ?? "this host"))
                    }
                    if let key {
                        let src = Highlight.source(key) == "host" ? (Highlight.isOn(key) ? "always on" : "always off") : "follows the global setting"
                        Menu("This host: \(src)") {
                            Button("Always on") { Highlight.setForHost(key, true); pane.applyHighlightSettings() }
                            Button("Always off") { Highlight.setForHost(key, false); pane.applyHighlightSettings() }
                            Button("Follow the global setting") { Highlight.setForHost(key, nil); pane.applyHighlightSettings() }
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private func explorerScopeMenu() -> some View {
        let n = s.panesOf(pane.tabId).count
        Button(pane.explorerVisible ? "Hide this explorer" : "Show this explorer") { s.setExplorerVisible(pane, !pane.explorerVisible) }
        Divider()
        Button("Show in all \(n) pane(s) in this tab") { s.setTabExplorers(pane.tabId, true) }
        Button("Hide in all \(n) pane(s) in this tab") { s.setTabExplorers(pane.tabId, false) }
        Divider()
        Button("Hide in every pane, everywhere") { SessionsWindow.hideAllExplorers() }
    }
}

/// `.icon-btn.sm` in a pane header.
struct HeaderButtonStyle: ButtonStyle {
    var color: Color? = nil
    var size: CGFloat = 12
    var active = false
    var dim = false
    var pulsing = false

    func makeBody(configuration: Configuration) -> some View {
        HBBody(configuration: configuration, color: color, size: size, active: active, dim: dim, pulsing: pulsing)
    }

    private struct HBBody: View {
        let configuration: ButtonStyle.Configuration
        let color: Color?, size: CGFloat, active: Bool, dim: Bool, pulsing: Bool
        @StateObject private var hover = LocalFlag()
        var body: some View {
            let p = Theme.shared.p
            configuration.label
                .font(.system(size: size))
                .foregroundStyle(active ? Color.white : (color ?? (hover.on ? p.text : p.textDim)))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? p.accentDim : (hover.on ? p.panel3 : .clear)))
                .opacity(dim && !hover.on ? 0.5 : 1)
                .overlay(alignment: .topTrailing) {
                    if pulsing { Circle().fill(p.green).frame(width: 5, height: 5).offset(x: -2, y: 2) }
                }
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
        }
    }
}

/// The scrollback search beside the host name, with a live match count.
struct PaneSearchBox: View {
    let s: SessionsWindow
    let pane: SessionPane
    @FocusState private var focused: Bool

    var body: some View {
        let p = Theme.shared.p
        let active = pane.searchActive || focused || !pane.searchText.isEmpty
        HStack(spacing: 2) {
            Text("\u{2315}").font(.system(size: 11)).foregroundStyle(p.muted).padding(.trailing, 1)
            TextField("Search…", text: Binding(get: { pane.searchText }, set: { v in
                pane.searchText = v
                if v.isEmpty { pane.term?.clearSearchState() } else { pane.term?.findIncremental(v) }
            }))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .frame(width: active ? 190 : 110)
            .background(RoundedRectangle(cornerRadius: 3).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(focused ? p.accent : p.border))
            .focused($focused)
            .onKeyPress(.return, phases: .down) { press in
                step(press.modifiers.contains(.shift) ? -1 : 1)
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                clear()
                return .handled
            }
            .onChange(of: pane.searchFocusRequest) { _, _ in focused = true }
            .onChange(of: focused) { _, f in pane.searchActive = f || !pane.searchText.isEmpty }
            Text(countText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(pane.searchCount == 0 && !pane.searchText.isEmpty ? p.red : p.muted)
                .frame(minWidth: 34, alignment: .trailing)
            if active {
                Button("\u{2039}") { step(-1) }.buttonStyle(HeaderButtonStyle()).help("Previous match (⇧⏎)")
                Button("\u{203A}") { step(1) }.buttonStyle(HeaderButtonStyle()).help("Next match (⏎)")
                Button("×") { clear() }.buttonStyle(HeaderButtonStyle()).help("Clear")
            }
        }
        .padding(.trailing, 6)
        .animation(.easeOut(duration: 0.12), value: active)
    }

    private var countText: String {
        if pane.searchText.isEmpty { return "" }
        if pane.searchCount > 0 { return "\(max(pane.searchIndex, 0) + 1)/\(pane.searchCount)" }
        return pane.searchCount == 0 ? "0" : ""
    }

    private func step(_ dir: Int) {
        let q = pane.searchText
        guard !q.isEmpty, let t = pane.term else { return }
        if dir > 0 { t.findNextMatch(q) } else { t.findPrevMatch(q) }
    }

    private func clear() {
        pane.searchText = ""
        pane.searchCount = -1
        pane.searchActive = false
        pane.term?.clearSearchState()
        focused = false
        s.focusActivePane()
    }
}

extension SessionsWindow {
    /// Toggle what the pane is *doing*: the host's own setting when it has a
    /// host, the pane's override when it does not.
    func toggleHighlight(_ p: SessionPane) {
        let key = SessionsCore.hostKey(of: p)
        let effective = p.highlight != nil
        if let key {
            p.highlightOverride = nil
            Highlight.setForHost(key, !effective)
        } else {
            p.highlightOverride = !effective
        }
        for w in SessionsCore.allWindows() { for o in w.panes.values { o.applyHighlightSettings() } }
        StatusBus.shared.show("Highlighting \(effective ? "off" : "on")\(key != nil ? " for this host" : " in this pane")")
    }

    func setExplorerVisible(_ p: SessionPane, _ visible: Bool) {
        p.explorerVisible = visible
    }

    func setTabExplorers(_ tabId: String?, _ visible: Bool?) {
        let list = panesOf(tabId ?? activeTabId).compactMap { pane($0) }
        guard !list.isEmpty else { return }
        let next = visible ?? !list.contains { $0.explorerVisible }
        for p in list { p.explorerVisible = next }
    }

    /// Every pane, everywhere: the explorer's `explorers-all` (it saves the
    /// preference and says so).
    static func hideAllExplorers() {
        Actions.shared.perform("explorers-all", args: ["visible": false])
    }

    /// ⌘F: focus the focused pane's search, picking up a one-line selection.
    @discardableResult
    func focusPaneSearch() -> Bool {
        guard let p = activePane, p.kind != .view else { return false }
        let sel = p.term?.hasSelection == true ? (p.term?.selectionText ?? "") : ""
        if !sel.isEmpty && !sel.contains("\n") {
            p.searchText = sel.trimmed
            p.term?.findIncremental(p.searchText)
        }
        p.searchActive = true
        p.searchFocusRequest += 1
        return true
    }
}
