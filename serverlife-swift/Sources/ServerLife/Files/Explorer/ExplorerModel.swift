import AppKit
import SwiftUI

/// `status(message, ms)` from ui.js: 4 s by default, 0 = stays, "" clears.
@MainActor
func xpStatus(_ text: String, _ ms: Double = 4000) {
    if text.isEmpty { StatusBus.shared.clear(); return }
    StatusBus.shared.show(text, kind: .info, seconds: ms / 1000)
}

/// `toast(message, kind, ms)` from ui.js ("info" | "error" | "success").
@MainActor
func xpToast(_ text: String, _ kind: String = "info", _ ms: Double = 3800) {
    let k: StatusBus.Kind = kind == "error" ? .error : kind == "success" ? .ok : .info
    StatusBus.shared.toast(text, kind: k, seconds: ms / 1000)
}

/// What one explorer is pointed at.
enum XPSource: Equatable {
    case local
    /// A session's files; nil means "follow whichever session this pane belongs to".
    case remote(String?)
    /// A registered provider's place, by picker value ("s3:<id>").
    case other(String)

    /// "local" | "remote" | the provider's prefix ("s3").
    var kind: String {
        switch self {
        case .local: return "local"
        case .remote: return "remote"
        case .other(let v): return String(v.split(separator: ":").first ?? "other")
        }
    }

    var pinnedConnId: String? { if case .remote(let c) = self { return c }; return nil }
}

/// What a tree branch holds: not there yet (absent), its entries, or a failure.
enum XPChildren: Equatable {
    case loaded([FileEntry])
    case failed
}

/// One source's view state, kept per source so switching back keeps its place.
@MainActor
@Observable
final class XPViewState {
    var path: String?
    var entries: [FileEntry] = []
    var selection: Set<String> = []
    var history: [String] = []
    var hIndex = -1
    var expanded: Set<String> = []
    var children: [String: XPChildren] = [:]
    var loadingPaths: Set<String> = []
    var error: String?
    var loading = false
    /// `_loading`: a first load in flight.
    var firstLoading = false
    /// `_mfaFailed`: the file channel was refused; wait for a click.
    var mfaFailed = false
    var refreshing = false
}

/// A starred folder or file, as the pane shows it.
struct XPFavorite: Identifiable, Equatable {
    var id: String
    var path: String
    var label: String
    /// "local", "hosts" (every host), or a host's preference key.
    var scope: String
    /// "dir" | "file"
    var kind: String
    var builtin: Bool
}

/// Where a new star here would be kept.
struct XPFavScope: Equatable {
    /// "local" | "host"
    var kind: String
    var key: String
    var label: String
}

/// One drawn line of the list: an entry, or a note under an expanded folder.
struct XPRow: Identifiable {
    enum Kind { case entry(FileEntry), note(String, error: Bool) }
    var id: String
    var depth: Int
    var kind: Kind
}

/// Every live explorer, for the background tick and drag routing (`explorers`).
@MainActor
final class Explorers {
    static let shared = Explorers()
    private(set) var list: [ExplorerModel] = []
    func add(_ e: ExplorerModel) { list.append(e) }
    func remove(_ e: ExplorerModel) { list.removeAll { $0 === e } }
    func get(_ id: String) -> ExplorerModel? { list.first { $0.id == id } }
    func forEach(_ body: (ExplorerModel) -> Void) { list.forEach(body) }
    /// The live explorers of one window — each window had its own `explorers`
    /// map in the original, so "the other list" is always in the same window.
    func inWindow(_ w: WindowModel?) -> [ExplorerModel] {
        list.filter { !$0.destroyed && $0.window === w }
    }
}

/// A self-contained file explorer: the port of explorer.js's `Explorer`.
///
/// One instance is attached to each terminal pane, so every open session shows
/// its own filesystem beside (or above) its terminal. An instance can also
/// point at the local machine or at any other open session, which is what
/// makes dragging files directly between two servers possible.
///
/// The city owner drives it through the public members: `view` (path,
/// entries, selection), `source`, `sourceKey`, `connId`, `navigate`, `open`,
/// `goParent`, `filter`/`focusFilter`/`clearFilter`, `notHidden`, `matcher`,
/// `sortOptions`, `selected`, `render`, `contextMenuItems(for:)`.
@MainActor
@Observable
final class ExplorerModel: Identifiable {
    let id = uid("exp")
    var source: XPSource
    let paneId: String?
    /// The local list stacked under a pane's own explorer.
    let isCompanion: Bool
    /// "hide" | "toggle-local" — handled by whoever made this explorer.
    @ObservationIgnored var onChange: ((String) -> Void)?
    @ObservationIgnored weak var windowRef: WindowModel?

    var sort: (key: String, dir: Int) = ("name", 1)
    var destroyed = false

    /// Name filter for this explorer — per explorer, visible in its own box
    /// the whole time it is in force.
    var filter = ""
    var filterShown = false
    /// Bumped to put the keyboard in the filter box / the list.
    var filterFocusToken = 0
    var listFocusToken = 0

    /// The shell directory the follow loop last acted on (nil = not read yet).
    @ObservationIgnored var followedCwd: String?
    /// Skipped by the background tick for being off screen.
    @ObservationIgnored var pollPaused = false

    /// A comparison in force: name → verdict, against which list.
    var compare: [String: String]?
    @ObservationIgnored weak var compareAgainst: ExplorerModel?

    private var views: [String: XPViewState] = [:]

    var reconnecting = false
    @ObservationIgnored private var lastHeal: Double = 0
    /// A transient status line (Loading…, Compared: …); cleared by `render`.
    var statusOverride: (text: String, error: Bool)?
    @ObservationIgnored var lastClicked: String?
    /// Bumped on every `render`.
    var revision = 0
    /// Scroll a row into view (`scrollIntoView`).
    var scrollTarget: (path: String, center: Bool, token: Int)?
    /// The path bar has the keyboard: the background tick leaves it alone.
    @ObservationIgnored var pathEditing = false
    /// A drag is over this pane.
    var dragOver = false
    /// The list has the keyboard (for ⌘F → the name filter).
    @ObservationIgnored var listFocused = false
    /// Showing this machine only because its tmux pane had no connection yet.
    @ObservationIgnored var localUntilConnected = false

    // Starred folders as last worked out for this pane.
    var favScopeNow: XPFavScope?
    var favList: [XPFavorite] = []
    var favOn = false

    /// The 3D view, when the city owner has attached one.
    var city: XPCityAttachment?
    /// True while a folder listing is on screen (the city shows instead).
    var listReady = false

    /// The whole pane covers its window, toolbar included (the original's
    /// `.fpane.c3-max`, used by the 3D view's ⤢). Esc / ⤡ set it back.
    var maximized: Bool {
        get { XPMaxed.shared.byWindow.values.contains { $0 === self } }
        set {
            if newValue { XPMaxed.shared.fill(window, with: self) }
            else { XPMaxed.shared.release(self) }
        }
    }

    @ObservationIgnored private var sftpSources: [String: SFTPFileSource] = [:]
    @ObservationIgnored private var otherSources: [String: FileSource] = [:]

    init(source: XPSource, paneId: String? = nil, companion: Bool = false, window: WindowModel? = nil,
         onChange: ((String) -> Void)? = nil) {
        self.source = source
        self.paneId = paneId
        self.isCompanion = companion
        self.windowRef = window
        self.onChange = onChange
        Explorers.shared.add(self)
    }

    // MARK: - What it is pointed at

    var kind: String { source.kind }
    var isLocal: Bool { kind == "local" }
    var isRemote: Bool { kind == "remote" }
    var isS3: Bool { kind == "s3" }

    var pane: XPPaneInfo? { paneId.flatMap { XPPanes.info($0) } }

    /// The window dialogs open over.
    var window: WindowModel? { pane?.window ?? windowRef ?? WindowManager.shared.focused }

    /// The connection this explorer reads, resolving "follow the pane".
    var connId: String? {
        guard case .remote(let pinned) = source else { return nil }
        if let pinned { return pinned }
        return pane?.connId
    }

    var conn: XPConn? { XPConn.get(connId) }

    /// The registered bucket this explorer reads, when it is pointed at one.
    var s3Id: String? {
        if case .other(let v) = source, isS3 { return String(v.dropFirst(3)) }
        return nil
    }

    var sourceKey: String {
        switch source {
        case .other(let v): return v
        case .local: return "local"
        case .remote: return "conn:" + (connId ?? "null")
        }
    }

    /// The FileSource behind the current pick.
    var fileSource: FileSource? {
        switch source {
        case .local: return LocalFileSource.shared
        case .remote:
            guard let c = connId else { return nil }
            if let s = sftpSources[c] { return s }
            let s = SFTPFileSource(connId: c)
            sftpSources[c] = s
            return s
        case .other(let v):
            if let s = otherSources[v] { return s }
            guard let s = ExplorerSources.provider(for: v)?.fileSource(v) else { return nil }
            otherSources[v] = s
            return s
        }
    }

    var view: XPViewState {
        let key = sourceKey
        if let v = views[key] { return v }
        let v = XPViewState()
        views[key] = v
        return v
    }

    func parentOf(_ p: String) -> String { isLocal ? XP.parentLocal(p) : Posix.parent(p) }
    func joinPath(_ dir: String, _ name: String) -> String {
        isLocal ? (dir.hasSuffix("/") ? dir + name : dir + "/" + name) : Posix.join(dir, name)
    }

    // MARK: - Sources

    /// The picker's options: this session, the local machine, every other
    /// connected session, then registered places (buckets).
    func sourceOptions() -> [XPSourceOption] {
        let p = pane
        let paneConn = XPConn.get(p?.connId)
        var opts: [XPSourceOption] = []
        // "This session" is offered by any pane that has a host behind it — a
        // tmux pane included, since its control stream rides the same
        // connection as an ordinary session's shell.
        if let p, p.kind == "remote" || p.kind == "tmux" {
            opts.append(XPSourceOption(value: "pane", label: paneConn.map { "This session: \($0.label)" } ?? "This session"))
        }
        opts.append(XPSourceOption(value: "local", label: "Local machine"))
        for c in XPConn.all where c.connected {
            if let p, c.id == p.connId { continue }   // already offered as "this session"
            opts.append(XPSourceOption(value: "conn:" + c.id, label: c.label))
        }
        for prov in ExplorerSources.providers { opts.append(contentsOf: prov.options()) }
        return opts
    }

    /// The picker value for the current source.
    var sourceValue: String {
        switch source {
        case .other(let v): return v
        case .local: return "local"
        case .remote(let c): return c.map { "conn:" + $0 } ?? "pane"
        }
    }

    /// Refresh against the current connections: the session this explorer
    /// was pinned to may have closed.
    func syncSources() {
        let opts = sourceOptions()
        let want = sourceValue
        if !opts.contains(where: { $0.value == want }) {
            let next = opts.first?.value ?? "local"
            Task { await pickSource(next, silent: true) }
        }
    }

    func pickSource(_ value: String, silent: Bool = false) async {
        if value == "local" { source = .local }
        else if value == "pane" { source = .remote(nil) }
        else if value.hasPrefix("conn:") { source = .remote(String(value.dropFirst(5))) }
        else { source = .other(value) }
        if isS3, city != nil { toggle3d(false) }
        // A different source has a different shell behind it, so what was
        // followed before says nothing about this one.
        followedCwd = nil
        if !silent { await ensureLoaded(force: true) } else { render() }
    }

    // MARK: - Loading

    /// Load the home/root listing the first time this source becomes usable.
    func ensureLoaded(force: Bool = false, user: Bool = false) async {
        let view = self.view
        if isRemote {
            guard let conn, conn.connected else { render(); return }
            /*
             * On a per-session-MFA host every channel costs an approval, and
             * the file channel would otherwise race the terminal's prompt — two
             * OS dialogs at once, which macOS cancels. So the first load waits
             * for an explicit click, and a failure does not retry itself.
             */
            if conn.transport == "tsh" && !conn.needsMfaApproval && view.path == nil && !user {
                // Nothing to approve: fall through and load.
            } else if conn.transport == "tsh" && !user && view.path == nil { render(); return }
            if view.mfaFailed && !user { render(); return }
            if view.path != nil && !force { render(); return }
            if view.firstLoading { return }
            view.firstLoading = true
            defer { view.firstLoading = false }
            do {
                try await navigate(view.path ?? conn.homeDir)
                view.mfaFailed = false
            } catch {
                if conn.transport == "tsh" { view.mfaFailed = true }
            }
            return
        }
        if isS3 || !isLocal {
            if view.path != nil && !force { render(); return }
            try? await navigate(view.path ?? "")
            return
        }
        if view.path != nil && !force { render(); return }
        try? await navigate(view.path ?? LocalFS.home)
    }

    /// Bring the file browser's connection back, then the listing. A tmux
    /// pane's terminal never exits when the connection is marked down, so the
    /// browser needs a way of its own.
    func reconnect(quiet: Bool = false) async {
        guard let connId, !reconnecting else { return }
        reconnecting = true
        render()
        setStatus("Reconnecting…")
        defer { reconnecting = false }
        do {
            try await ConnectionManager.shared.connect(connId)
            view.error = nil
            view.mfaFailed = false
            reconnecting = false
            await ensureLoaded(force: true, user: !quiet)
        } catch {
            view.error = errorText(error)
            reconnecting = false
            render()
            if !quiet { xpToast(errorText(error), "error") }
        }
    }

    /// A tmux pane whose session is still attached heals itself — at most
    /// once a minute.
    func maybeHealTmux() {
        guard let p = pane, p.kind == "tmux", p.connId == connId else { return }
        if nowMs() - lastHeal < 60000 { return }
        guard p.tmuxAttached else { return }
        lastHeal = nowMs()
        Task { await reconnect(quiet: true) }
    }

    func navigate(_ path: String?, push: Bool = true) async throws {
        // A comparison describes one pair of directories; leaving either of
        // them would make its marks a lie, so they go.
        compare = nil
        let view = self.view
        if isRemote {
            guard let conn, conn.connected else { setStatus("Not connected", true); render(); return }
        }
        view.loading = true
        setStatus("Loading…")
        do {
            guard let src = fileSource else { throw AppError(isRemote ? "No session selected." : "That source is not available.") }
            let target: String? = isS3 ? (path ?? "") : ((path?.isEmpty ?? true) ? nil : path)
            let res = try await src.list(target)
            view.path = res.path
            view.entries = res.entries
            view.selection = []
            view.error = nil
            view.expanded = []
            view.children = [:]
            view.loadingPaths = []
            if push {
                if view.hIndex + 1 < view.history.count { view.history = Array(view.history.prefix(view.hIndex + 1)) }
                if view.history.last != res.path { view.history.append(res.path) }
                view.hIndex = view.history.count - 1
            }
        } catch {
            view.error = errorText(error)
            view.loading = false
            render()
            throw error
        }
        view.loading = false
        render()
    }

    func refresh() async {
        city?.invalidate()
        let view = self.view
        guard let p = view.path, !(p.isEmpty && !isS3) else { await ensureLoaded(force: true); return }
        let open = Array(view.expanded)
        do { try await navigate(p, push: false) } catch { return }
        for dir in open {
            view.expanded.insert(dir)
            if let l = try? await fileSource?.list(dir) { view.children[dir] = .loaded(l.entries) }
            else { view.children[dir] = .failed }
        }
        render()
    }

    func goParent() async {
        guard let p = view.path else { return }
        if isS3 {
            // '' is the bucket root, so there is nowhere above it.
            if p.isEmpty { return }
            var t = p
            while t.hasSuffix("/") { t.removeLast() }
            let up = t.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
            try? await navigate(up.isEmpty ? "" : up + "/")
            return
        }
        if p.isEmpty { return }
        try? await navigate(parentOf(p))
    }

    func historyGo(_ delta: Int) async {
        let view = self.view
        let i = view.hIndex + delta
        if i < 0 || i >= view.history.count { return }
        view.hIndex = i
        try? await navigate(view.history[i], push: false)
    }

    // MARK: - Drawing

    /// Redraw: clears a transient status, re-checks the sources and the star,
    /// and tells the 3D view.
    func render() {
        guard !destroyed else { return }
        statusOverride = nil
        revision += 1
        syncFavButton()
        listReady = computeListReady()
        city?.sync()
    }

    func setStatus(_ text: String, _ isError: Bool = false) {
        statusOverride = (text, isError)
    }

    /// Whether the list would show entries (rather than a notice).
    private func computeListReady() -> Bool {
        if isRemote {
            guard let conn else { return false }
            if !conn.connected { return false }
            if conn.transport == "tsh" && view.path == nil && conn.needsMfaApproval { return false }
        }
        return view.error == nil && view.path != nil
    }

    /// The hidden-files rule alone, which the status line counts separately.
    func notHidden(_ entries: [FileEntry]) -> [FileEntry] {
        Store.shared.xpShowHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    var matcher: ((String) -> Bool)? { XP.matcher(filter) }

    /// What is on screen of a set of entries: not hidden, and matching the
    /// filter — a directory survives a filter it does not match itself if
    /// something expanded inside it does.
    func visible(_ entries: [FileEntry]) -> [FileEntry] {
        let shown = notHidden(entries)
        guard let match = matcher else { return shown }
        return shown.filter { match($0.name) || hasMatchingDescendant($0, match) }
    }

    private func hasMatchingDescendant(_ entry: FileEntry, _ match: (String) -> Bool, depth: Int = 0) -> Bool {
        let view = self.view
        if depth > 8 || !XP.isDir(entry) || !view.expanded.contains(entry.path) { return false }
        guard case .loaded(let kids) = view.children[entry.path] else { return false }
        return notHidden(kids).contains { match($0.name) || hasMatchingDescendant($0, match, depth: depth + 1) }
    }

    var sortOptions: (key: String, dir: Int, foldersFirst: Bool) { (sort.key, sort.dir, Store.shared.xpFoldersFirst) }

    func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        let o = sortOptions
        return XP.sortEntries(entries, key: o.key, dir: o.dir, foldersFirst: o.foldersFirst)
    }

    /// Sort by a column; clicking the one already in force flips it.
    func sortBy(_ key: String) {
        if sort.key == key { sort.dir = -sort.dir } else { sort = (key, key == "name" ? 1 : -1) }
        render()
    }

    /// The rows to draw, tree included (`_renderTree`).
    func rows() -> [XPRow] {
        var out: [XPRow] = []
        let view = self.view
        func walk(_ entries: [FileEntry], _ depth: Int) {
            for e in entries {
                out.append(XPRow(id: e.path, depth: depth, kind: .entry(e)))
                if !XP.isDir(e) || !view.expanded.contains(e.path) { continue }
                switch view.children[e.path] {
                case nil:
                    out.append(XPRow(id: e.path + "\u{0}note", depth: depth + 1, kind: .note("Loading…", error: false)))
                case .failed:
                    out.append(XPRow(id: e.path + "\u{0}note", depth: depth + 1, kind: .note("Cannot read directory", error: true)))
                case .loaded(let kids):
                    let s = sorted(visible(kids))
                    if s.isEmpty { out.append(XPRow(id: e.path + "\u{0}note", depth: depth + 1, kind: .note("empty", error: false))) }
                    else { walk(s, depth + 1) }
                }
            }
        }
        walk(sorted(visible(view.entries)), 0)
        return out
    }

    /// Counted against their own rule each: "hidden" means dotfiles,
    /// "filtered" means the name filter.
    var counts: (shown: Int, dirs: Int, hidden: Int, filtered: Int) {
        let view = self.view
        let entries = visible(view.entries)
        let nh = notHidden(view.entries)
        return (entries.count, entries.filter(XP.isDir).count, view.entries.count - nh.count, nh.count - entries.count)
    }

    /// The status line as `_renderList` would leave it.
    var statusLine: (text: String, error: Bool) {
        if let o = statusOverride { return o }
        if isRemote {
            guard let conn else { return ("", false) }
            if !conn.connected { return ("", false) }
            if conn.transport == "tsh" && view.path == nil && conn.needsMfaApproval { return ("", false) }
        }
        if let e = view.error { return (e, true) }
        if view.path == nil { return ("", false) }
        let c = counts
        return ("\(c.shown) items · \(c.dirs) folders" + (c.hidden > 0 ? " · \(c.hidden) hidden" : "")
                + (c.filtered > 0 ? " · \(c.filtered) filtered out" : ""), false)
    }

    // MARK: - Name filter

    /// Show or hide the filter row. Showing it focuses it.
    func toggleFilter(_ force: Bool? = nil) {
        let show = force ?? !filterShown
        filterShown = show
        if show { filterFocusToken += 1 } else if !filter.isEmpty { clearFilter() }
    }

    func clearFilter() {
        filter = ""
        render()
    }

    /// Focus the filter, seeding it — used by type-ahead from the list.
    func focusFilter(_ seed: String? = nil) {
        toggleFilter(true)
        if let seed {
            filter = seed
            render()
        }
    }

    /// A new filter was typed.
    func filterChanged(_ text: String) {
        filter = text
        // A filter that just excluded the selected file would otherwise leave
        // a selection that is no longer on screen, which Enter would then open.
        pruneSelection()
        render()
    }

    func pruneSelection() {
        let view = self.view
        if view.selection.isEmpty { return }
        let shown = Set(flat().map(\.path))
        view.selection = view.selection.filter { shown.contains($0) }
    }

    // MARK: - Selection and keys

    func flat() -> [FileEntry] {
        let view = self.view
        var out: [FileEntry] = []
        func walk(_ entries: [FileEntry]) {
            for e in sorted(visible(entries)) {
                out.append(e)
                if XP.isDir(e), view.expanded.contains(e.path), case .loaded(let kids) = view.children[e.path] { walk(kids) }
            }
        }
        walk(view.entries)
        return out
    }

    func selected() -> [FileEntry] {
        let sel = view.selection
        return flat().filter { sel.contains($0.path) }
    }

    /// A click on a row: ⌘ toggles, ⇧ extends from the last click.
    func select(_ entry: FileEntry, command: Bool = false, shift: Bool = false) {
        let view = self.view
        let entries = flat()
        if command {
            if view.selection.contains(entry.path) { view.selection.remove(entry.path) } else { view.selection.insert(entry.path) }
        } else if shift, let last = lastClicked {
            if let a = entries.firstIndex(where: { $0.path == last }), let b = entries.firstIndex(where: { $0.path == entry.path }) {
                view.selection = Set(entries[min(a, b)...max(a, b)].map(\.path))
            }
        } else {
            view.selection = [entry.path]
        }
        lastClicked = entry.path
        render()
    }

    func toggleExpand(_ entry: FileEntry) async {
        let view = self.view
        if view.expanded.contains(entry.path) {
            view.expanded.remove(entry.path)
            render()
            return
        }
        view.expanded.insert(entry.path)
        if view.children[entry.path] != nil { render(); return }
        view.loadingPaths.insert(entry.path)
        render()
        if let l = try? await fileSource?.list(entry.path) { view.children[entry.path] = .loaded(l.entries) }
        else { view.children[entry.path] = .failed }
        view.loadingPaths.remove(entry.path)
        render()
    }

    func collapseAll() {
        view.expanded = []
        view.children = [:]
        render()
    }

    /// Double-click / Enter: into a folder, the OS for a local file, a
    /// download for anything over 2 MB on a server, the editor otherwise.
    func open(_ entry: FileEntry) async {
        if XP.isDir(entry) { try? await navigate(entry.path); return }
        if isLocal {
            do { try LocalFS.open(entry.path) } catch { xpToast(errorText(error), "error") }
            return
        }
        if isS3 { await s3Download([entry]); return }
        if entry.size > 2 * 1024 * 1024 { await download([entry]); return }
        await edit(entry)
    }

    /// Move the selection one row over what is actually on screen — from
    /// match to match when a filter is in force.
    func moveSelection(_ delta: Int) {
        let view = self.view
        let flat = self.flat()
        guard !flat.isEmpty else { return }
        let sel = selected()
        let cur = sel.count == 1 ? (flat.firstIndex { $0.path == sel[0].path } ?? -1) : -1
        let next = cur == -1 ? (delta > 0 ? flat[0] : flat[flat.count - 1])
                             : flat[max(0, min(flat.count - 1, cur + delta))]
        view.selection = [next.path]
        lastClicked = next.path
        render()
        scrollTo(next.path, center: false)
    }

    func scrollTo(_ path: String, center: Bool) {
        scrollTarget = (path, center, (scrollTarget?.token ?? 0) + 1)
    }

    /// The list's keys. Returns whether the key was used.
    func handleKey(_ key: String, chars: String, command: Bool, control: Bool, option: Bool) -> Bool {
        let view = self.view
        let sel = selected()
        let meta = command || control
        if (key == "delete" || key == "forwardDelete") && meta { Task { await remove(sel) }; return true }
        if chars.lowercased() == "a" && meta {
            view.selection = Set(flat().map(\.path))
            render(); return true
        }
        if chars.lowercased() == "f" && meta { focusFilter(); return true }
        if key == "escape" && !filter.isEmpty { clearFilter(); return true }
        if key == "delete" { Task { await goParent() }; return true }
        if key == "return" { if sel.count == 1 { Task { await open(sel[0]) } }; return true }
        // Type-ahead: a printable character with the list focused starts filtering.
        if chars.count == 1, !meta, !option, let ch = chars.first, !ch.isWhitespace, !ch.isNewline,
           ch.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) {
            focusFilter(filter + chars)
            return true
        }
        if key == "down" || key == "up" { moveSelection(key == "down" ? 1 : -1); return true }
        if key == "right", sel.count == 1, XP.isDir(sel[0]), !view.expanded.contains(sel[0].path) {
            Task { await toggleExpand(sel[0]) }; return true
        }
        if key == "left", sel.count == 1, XP.isDir(sel[0]), view.expanded.contains(sel[0].path) {
            Task { await toggleExpand(sel[0]) }; return true
        }
        return false
    }

    /// Enter in the filter box: the one selected, or the first match.
    func openFromFilter() {
        let sel = selected()
        let target = sel.count == 1 ? sel[0] : flat().first
        if let target { Task { await open(target) } }
    }

    // MARK: - 3D

    func toggle3d(_ force: Bool? = nil) {
        let on = force ?? (city == nil)
        if on == (city != nil) { return }
        if on && !Store.shared.xpShow3d { return }
        if on && isS3 { xpToast("The 3D view does not reach into buckets yet", "error"); return }
        if on {
            guard Actions.shared.isRegistered("city-open") else {
                xpToast("3D is not available in this build", "error")
                return
            }
            Actions.shared.perform("city-open", window: window, args: ["explorer": self])
        } else {
            maximized = false
            city?.destroy()
            city = nil
        }
        render()
    }

    /// The city owner hands its view over (after `city-open`).
    func attachCity(_ c: XPCityAttachment) {
        city?.destroy()
        city = c
        render()
    }

    // MARK: - Background refresh

    /// Re-list without disturbing selection, expansion or scroll.
    func autoRefresh() async {
        let view = self.view
        guard let path = view.path, !view.loading, !view.firstLoading, !view.refreshing else { return }
        if pathEditing { return }
        if isRemote, !(conn?.connected ?? false) { return }
        view.refreshing = true
        defer { view.refreshing = false }
        guard let res = try? await fileSource?.list(isS3 ? path : path) else { return }
        if res.path != view.path { return }
        if XP.signature(res.entries) == XP.signature(view.entries) { return }
        let names = Set(res.entries.map(\.path))
        view.entries = res.entries
        view.selection = view.selection.filter { names.contains($0) }
        for dir in view.expanded where !names.contains(dir) && dir != view.path { view.expanded.remove(dir) }
        render()
    }

    func destroy() {
        maximized = false
        destroyed = true
        city?.destroy()
        city = nil
        Explorers.shared.remove(self)
    }
}

/// The explorer filling each window, by window id (at most one).
@MainActor
@Observable
final class XPMaxed {
    static let shared = XPMaxed()
    private(set) var byWindow: [String: ExplorerModel] = [:]
    @ObservationIgnored private var hosts: [String: NSView] = [:]

    /// Cover the window with the explorer. A view of its own on top of the
    /// window's content, because the terminals are AppKit views that a
    /// SwiftUI overlay would sit underneath.
    func fill(_ window: WindowModel?, with ex: ExplorerModel) {
        // Above the content view itself: SwiftUI keeps re-ordering the
        // subviews of its own hosting view.
        guard let window, let cv = window.nsWindow?.contentView, let content = cv.superview else { return }
        release(byWindow[window.id] ?? ex)
        byWindow[window.id] = ex
        let host = NSHostingView(rootView: XPMaxOverlay(ex: ex).themed())
        host.frame = cv.frame
        host.autoresizingMask = [.width, .height]
        content.addSubview(host, positioned: .above, relativeTo: cv)
        hosts[window.id] = host
    }

    func release(_ ex: ExplorerModel) {
        for (k, v) in byWindow where v === ex {
            byWindow[k] = nil
            hosts.removeValue(forKey: k)?.removeFromSuperview()
        }
    }
}
