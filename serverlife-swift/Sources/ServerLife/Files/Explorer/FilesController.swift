import AppKit
import SwiftUI

/// A pane's explorers: its own, and the local list stacked under it.
@MainActor
@Observable
final class XPPaneEntry {
    let paneId: String
    let main: ExplorerModel
    var local: ExplorerModel?
    /// Height of the top list when the local one is stacked under it.
    var splitTop: CGFloat?
    init(paneId: String, main: ExplorerModel) { self.paneId = paneId; self.main = main }
}

/// Every pane's explorers, by pane id.
@MainActor
final class XPPaneExplorers {
    static let shared = XPPaneExplorers()
    private var entries: [String: XPPaneEntry] = [:]

    /// The pane's entry, made the first time it is asked for. A remote (or
    /// tmux) pane's explorer follows its own session; any other shows this
    /// machine.
    func entry(_ paneId: String) -> XPPaneEntry {
        if let e = entries[paneId] { return e }
        let info = XPPanes.info(paneId)
        // A tmux pane on this machine has no connection: its files are this
        // machine's (the original switched such a pane's source to local).
        let remote = info?.kind == "remote" || (info?.kind == "tmux" && info?.connId != nil)
        let main = ExplorerModel(source: remote ? .remote(nil) : .local, paneId: paneId, window: info?.window)
        main.onChange = { [weak self] what in
            if what == "hide" { XPPanes.setVisible(paneId, false) }
            if what == "toggle-local" { self?.toggleLocal(paneId) }
        }
        // A tmux pane is drawn before its connection is known; it shows this
        // machine only until then (`resolve`).
        main.localUntilConnected = info?.kind == "tmux" && info?.connId == nil
        let e = XPPaneEntry(paneId: paneId, main: main)
        entries[paneId] = e
        return e
    }

    /// A tmux pane that now has its connection: its files are the server's.
    func resolve(_ paneId: String) {
        guard let e = entries[paneId], e.main.localUntilConnected,
              let info = XPPanes.info(paneId), info.connId != nil else { return }
        e.main.localUntilConnected = false
        e.main.followedCwd = nil
        Task { await e.main.pickSource("pane") }
    }

    func resolveAll() { for id in Array(entries.keys) { resolve(id) } }

    func existing(_ paneId: String) -> XPPaneEntry? { entries[paneId] }
    func main(_ paneId: String) -> ExplorerModel? { entries[paneId]?.main }
    func companion(of paneId: String) -> ExplorerModel? { entries[paneId]?.local }

    /// Show the local filesystem *underneath* this pane's session files, in
    /// the same column (`togglePaneLocalExplorer`).
    @discardableResult
    func toggleLocal(_ paneId: String, force: Bool? = nil) -> ExplorerModel? {
        let e = entry(paneId)
        let wanted = force ?? (e.local == nil)
        if !wanted {
            e.local?.destroy()
            e.local = nil
            e.main.render()
            return nil
        }
        if let l = e.local { return l }
        XPPanes.setVisible(paneId, true)
        let l = ExplorerModel(source: .local, paneId: paneId, companion: true, window: XPPanes.info(paneId)?.window)
        l.onChange = { [weak self] what in
            if what == "hide" || what == "toggle-local" { self?.toggleLocal(paneId, force: false) }
        }
        e.local = l
        Task { await l.ensureLoaded() }
        e.main.render()
        return l
    }

    /// Point a pane's own explorer at a source value ("s3:<id>", "local", …),
    /// showing its file side first (sidebar.js `openS3InExplorer`).
    func show(_ paneId: String, source: String) {
        XPPanes.setVisible(paneId, true)
        let ex = entry(paneId).main
        Task { await ex.pickSource(source) }
    }

    /// The pane is closing for good.
    func close(_ paneId: String) {
        guard let e = entries.removeValue(forKey: paneId) else { return }
        e.local?.destroy()
        e.main.destroy()
    }
}

/// What `PaneAccessories` draws beside (or above) a pane's terminal.
struct ExplorerPaneView: View {
    let entry: XPPaneEntry
    @StateObject private var dragBase = Local<CGFloat?>(nil)

    var body: some View {
        let p = Theme.shared.p
        let connId = XPPanes.info(entry.paneId)?.connId
        GeometryReader { g in
            VStack(spacing: 0) {
                if let local = entry.local {
                    let top = min(max(90, entry.splitTop ?? g.size.height / 2), max(90, g.size.height - 90))
                    ExplorerView(ex: entry.main).frame(height: top)
                    // Drag the divider between a pane's two explorers.
                    ZStack { Color.clear; p.border.frame(height: 1) }
                        .frame(height: 5)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            let base = dragBase.value ?? top
                            if dragBase.value == nil { dragBase.value = top }
                            entry.splitTop = max(90, base + v.translation.height)
                        }.onEnded { _ in dragBase.value = nil })
                    ExplorerView(ex: local)
                } else {
                    ExplorerView(ex: entry.main)
                }
            }
        }
        .onAppear { XPPaneExplorers.shared.resolve(entry.paneId) }
        .onChange(of: connId) { _, _ in XPPaneExplorers.shared.resolve(entry.paneId) }
    }
}

/// files.js: what spans every explorer — show/hide, layout orientation, the
/// background refresh tick and following the terminal's directory.
@MainActor
enum XPFiles {
    private static let tick = Repeater()
    private static var connSub: UUID?

    static func start() {
        // Redraw every explorer when connections change, and load the visible
        // ones that have just become usable — nothing else triggers that first
        // load. A hidden explorer waits: it is loaded when it is shown.
        connSub = ConnectionManager.shared.subscribe { ev in
            switch ev {
            case .state, .changed, .info:
                MainActor.assumeIsolated {
                    XPPaneExplorers.shared.resolveAll()
                    for e in Explorers.shared.list {
                        e.syncSources()
                        e.render()
                        if onScreen(e) { Task { await e.ensureLoaded() } }
                    }
                }
            default: break
            }
        }
        startFollowLoop()
    }

    /// One timer drives two optional behaviours: following the terminal's
    /// working directory, and re-listing visible directories. 0 = Off.
    static func startFollowLoop() {
        let secs = Store.shared.xpRefreshSeconds
        tick.stop()
        guard secs > 0 else { return }
        tick.start(every: secs) { Task { await runTick() } }
    }

    static func runTick() async {
        // A dialog is open.
        if WindowManager.shared.windows.contains(where: { $0.nsWindow?.attachedSheet != nil }) { return }
        var live: [ExplorerModel] = []
        for e in Explorers.shared.list {
            if onScreen(e) { live.append(e) } else { e.pollPaused = true }   // re-listed when shown again
        }
        // Every explorer hidden: ask the servers nothing at all.
        if live.isEmpty { return }
        await followTerminals(live)
        for e in live {
            if isMfaSession(e) { continue }                                   // polling would re-prompt
            e.pollPaused = false
            await e.autoRefresh()
        }
    }

    /// Is this explorer actually being looked at? Its pane's file side is
    /// showing and the pane is in the tab you are on.
    static func onScreen(_ e: ExplorerModel) -> Bool {
        guard !e.destroyed else { return false }
        guard let pid = e.paneId else { return true }
        guard let p = XPPanes.info(pid) else { return false }
        return p.onScreen
    }

    /// Bring the explorers that have just come back on screen up to date.
    static func catchUpVisible(_ paneId: String? = nil) {
        for e in Explorers.shared.list {
            if let paneId, e.paneId != paneId { continue }
            if !onScreen(e) { continue }
            let paused = e.pollPaused
            let loaded = e.view.path != nil
            e.pollPaused = false
            if !paused && loaded { continue }
            if isMfaSession(e) { continue }
            Task {
                await e.ensureLoaded()
                if loaded { await e.autoRefresh() }
            }
        }
    }

    /// A `tsh` session opens a channel per operation — an approval on a
    /// per-session-MFA host, an audit entry everywhere. Never polled.
    static func isMfaSession(_ e: ExplorerModel) -> Bool {
        e.isRemote && e.conn?.transport == "tsh"
    }

    /// The terminal says a directory has probably just changed (or the cwd
    /// probe has a new answer): follow it now rather than at the next tick.
    static func followPaneNow(_ paneId: String) {
        guard Store.shared.xpFollowTerminal else { return }
        let list = Explorers.shared.list.filter { $0.paneId == paneId && !$0.isCompanion && onScreen($0) && !isMfaSession($0) }
        guard !list.isEmpty else { return }
        Task { await followTerminals(list) }
    }

    /// An explorer bound to its own pane's session follows that shell's
    /// directory — the shell *moving*, not the shell's position, so a folder
    /// opened here stays open until the shell goes somewhere new.
    static func followTerminals(_ live: [ExplorerModel]) async {
        guard Store.shared.xpFollowTerminal else { return }
        for e in live {
            guard let pid = e.paneId, let pane = XPPanes.info(pid), pane.hasTerm else { continue }
            let followsOwnSession = e.isRemote && e.source.pinnedConnId == nil && (pane.kind == "remote" || pane.kind == "tmux")
            let followsThisShell = e.isLocal && pane.kind == "local"
            if !followsOwnSession && !followsThisShell { continue }
            if e.pathEditing { continue }
            guard let cwd = pane.cwd, !cwd.isEmpty else { continue }
            // First reading on a fresh session: adopt it without counting as a move.
            if e.followedCwd == nil { e.followedCwd = cwd; continue }
            if cwd == e.followedCwd { continue }
            e.followedCwd = cwd
            if cwd != e.view.path { try? await e.navigate(cwd) }
        }
    }

    // MARK: - Actions

    /// ⌘F with a file list focused: that list's name filter. Returns whether
    /// it took the key (sessions' `find` asks first).
    static func focusFilterIfListFocused(window: WindowModel?) -> Bool {
        let w = window ?? WindowManager.shared.focused
        guard let ex = Explorers.shared.inWindow(w).first(where: { $0.listFocused }) else { return false }
        ex.focusFilter()
        return true
    }

    /// Is any file browser in the window on screen (the title-bar button's lit state)?
    static func anyVisible(window: WindowModel?) -> Bool {
        let w = window ?? WindowManager.shared.focused
        return XPPanes.allPaneIds(w).contains { XPPanes.info($0)?.explorerVisible == true }
    }

    /// The title-bar button's right-click menu: the same scopes as a pane's
    /// ☰ (`openExplorerScopeMenu` for the focused pane).
    static func buttonMenuItems(window: WindowModel?) -> [CtxItem] {
        guard let pid = XPPanes.activePaneId(window), let pane = XPPanes.info(pid) else { return [] }
        let tabPanes = XPPanes.allPaneIds(window).filter { XPPanes.info($0)?.tabId == pane.tabId }
        return [
            CtxItem(pane.explorerVisible ? "Hide this explorer" : "Show this explorer") {
                XPPanes.setVisible(pid, !pane.explorerVisible)
            },
            .sep,
            CtxItem("Show in all \(tabPanes.count) pane(s) in this tab") { for id in tabPanes { XPPanes.setVisible(id, true) } },
            CtxItem("Hide in all \(tabPanes.count) pane(s) in this tab") { for id in tabPanes { XPPanes.setVisible(id, false) } },
            .sep,
            CtxItem("Hide in every pane, everywhere") { toggleAllExplorers(false, window: window) },
        ]
    }

    /// ⌘E: the focused pane's explorer.
    static func toggleFocusedExplorer(_ window: WindowModel?) {
        guard let pid = XPPanes.activePaneId(window), let p = XPPanes.info(pid) else {
            xpToast("No pane focused", "error"); return
        }
        XPPanes.setVisible(pid, !p.explorerVisible)
    }

    /// Show or hide every pane's explorer in a window at once.
    static func toggleAllExplorers(_ force: Bool? = nil, window: WindowModel? = nil) {
        let panes = XPPanes.allPaneIds(window)
        let anyVisible = panes.contains { XPPanes.info($0)?.explorerVisible == true }
        let next = force ?? !anyVisible
        for id in panes { XPPanes.setVisible(id, next) }
        Store.shared.xpExplorersVisible = next
        xpStatus(next ? "File explorers shown" : "File explorers hidden")
    }

    /// Explorer beside the terminal ('left'), or above it ('top').
    static func setExplorerPosition(_ position: String? = nil) {
        let pos = position ?? (Store.shared.xpExplorerPosition == "top" ? "left" : "top")
        Store.shared.xpExplorerPosition = pos
        xpStatus(pos == "top" ? "Explorers stacked above terminals" : "Explorers beside terminals")
    }

    /// Point a local explorer at a path (saved profiles' local start path).
    static func setLocalPath(_ p: String, window: WindowModel?) async {
        guard !p.isEmpty else { return }
        var target = Explorers.shared.inWindow(window ?? WindowManager.shared.focused).first { $0.isLocal }
        if target == nil {
            guard let pid = XPPanes.activePaneId(window) else { return }
            target = XPPaneExplorers.shared.entry(pid).main
            await target?.pickSource("local")
        }
        try? await target?.navigate(p)
    }

    /// Put the local filesystem on screen next to the current session, ready
    /// to drag files either way (`openLocalFiles`).
    static func openLocalFiles(_ window: WindowModel?, path: String? = nil, show: Bool = false) {
        guard let pid = XPPanes.activePaneId(window) else {
            Actions.shared.perform("new-local", window: window)
            return
        }
        // With a path to show, this is "take me there" rather than a toggle.
        let added = XPPaneExplorers.shared.toggleLocal(pid, force: path != nil || show ? true : nil)
        if let path, let added {
            Task { try? await added.navigate(path) }
            xpStatus("Local files — \(path)")
            return
        }
        xpStatus(added != nil
            ? "Local files shown below the session files — drag between them to upload or download"
            : "Local file list hidden")
    }

    /// Settings were saved: the starred defaults, the 3D button, the sort,
    /// the interval.
    static func settingsChanged() {
        startFollowLoop()
        xpRefreshFavorites()
        if !Store.shared.xpShow3d { Explorers.shared.forEach { if $0.city != nil { $0.toggle3d(false) } } }
        Explorers.shared.forEach { $0.render() }
    }
}
