import AppKit
import SwiftUI

/// A minimal explorer that hosts a city in a panel of its own: a path, the
/// parent button, refresh, the name filter, hidden files — the explorer's
/// toolbar in miniature.
///
/// This is a stand-in, for the `city-panel` action and for looking at the
/// view (`--snapshot … --actions city-panel`), until the explorer hosts the
/// city in its own pane through `city-open`. It follows the original's rules
/// for what the explorer does: `_notHidden`, `sortEntries`, `_matcher`.
@MainActor
@Observable
final class CityPanelExplorer: CityExplorerHost {
    let source: FileSource
    private(set) var path: String?
    private(set) var entries: [FileEntry] = []
    var filter = ""
    var showHidden: Bool = Store.shared.setting("showHiddenFiles", false)
    var selection: Set<String> = []
    var error: String?
    var maximized = false
    var city: CityController?
    @ObservationIgnored weak var handle: ModalHandle?
    @ObservationIgnored private var lastClicked: String?

    init(source: FileSource) { self.source = source }

    func navigate(_ dir: String?) async throws {
        do {
            let l = try await source.list(dir)
            path = l.path
            entries = l.entries
            selection = []
            error = nil
            handle?.setTitle("3D — " + (l.path as NSString).abbreviatingWithTildeInPath)
        } catch {
            self.error = errorText(error)
            throw error
        }
    }

    func refresh() {
        city?.invalidate()
        Task { try? await navigate(path) }
    }

    // MARK: CityExplorerHost

    var cityPath: String? { path }
    var cityEntries: [FileEntry] { entries }
    var cityShowHidden: Bool { showHidden }
    var citySourceKey: String { source.id }
    var citySourceKind: FileSourceKind { source.kind }
    var cityConnId: String? { (source as? SFTPFileSource)?.connId }
    var cityFilterActive: Bool { !filter.trimmed.isEmpty }
    var citySelection: Set<String> {
        get { selection }
        set { selection = newValue }
    }
    var cityMaximized: Bool {
        get { maximized }
        set {
            maximized = newValue
            if let w = handle?.window, w.isZoomed != newValue { w.zoom(nil) }
        }
    }

    func cityShownEntries() -> [FileEntry] {
        let shown = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        let foldersFirst: Bool = Store.shared.setting("foldersFirst", true)
        return shown.sorted { a, b in
            if foldersFirst && a.isDirectoryLike != b.isDirectoryLike { return a.isDirectoryLike }
            return compareNames(a.name, b.name) == .orderedAscending
        }
    }

    /// `_matcher()`: a glob when there is a * or ?, otherwise a substring, case-insensitive.
    func cityMatcher() -> ((String) -> Bool)? {
        let q = filter.trimmed.lowercased()
        if q.isEmpty { return nil }
        if q.contains("*") || q.contains("?") {
            var body = ""
            for ch in q {
                if ch == "*" { body += ".*" } else if ch == "?" { body += "." } else { body += NSRegularExpression.escapedPattern(for: String(ch)) }
            }
            guard let re = try? NSRegularExpression(pattern: "^" + body + "$") else { return { $0.lowercased().contains(q) } }
            return { re.matches($0.lowercased()) }
        }
        return { $0.lowercased().contains(q) }
    }

    func citySelectionChanged(lastClicked: String?) {
        if let lastClicked { self.lastClicked = lastClicked }
    }

    func cityNavigate(_ p: String) async throws { try await navigate(p) }

    func cityGoParent() async throws {
        guard let path else { return }
        let up = source.parent(of: path)
        if up == path { throw AppError("Already at the top") }
        try await navigate(up)
    }

    func cityOpen(_ entry: FileEntry) {
        if source.kind == .local {
            do { try LocalFS.open(entry.path) } catch { StatusBus.shared.show(errorText(error), kind: .error) }
        } else {
            StatusBus.shared.show("Open \(entry.name) from the explorer's list", kind: .info)
        }
    }

    func cityContextMenu(_ entry: FileEntry?, event: NSEvent, in view: NSView) {
        var items: [CtxItem] = []
        if let e = entry {
            if !selection.contains(e.path) { selection = [e.path]; city?.applyState() }
            items.append(.heading(e.name))
            if e.isDirectoryLike {
                items.append(CtxItem("Open folder") { Task { try? await self.navigate(e.path) } })
            } else {
                items.append(CtxItem("Open") { self.cityOpen(e) })
            }
            if source.kind == .local { items.append(CtxItem("Reveal in Finder") { LocalFS.reveal(e.path) }) }
            items.append(CtxItem("Copy path") { Clipboard.write(e.path) })
        } else {
            items.append(.heading(path ?? "this folder"))
            items.append(CtxItem("Refresh") { self.refresh() })
            if let path { items.append(CtxItem("Copy path") { Clipboard.write(path) }) }
        }
        NSMenu.popUpContextMenu(CtxMenu.build(items), with: event, for: view)
    }

    func cityFocusFilter() { NotificationCenter.default.post(name: .cityPanelFocusFilter, object: self) }
    func cityClearFilter() { filter = "" }

    // MARK: Opening

    /// Open a panel on `path` (nil = home) of a source.
    static func open(source: FileSource, path: String?) {
        let ex = CityPanelExplorer(source: source)
        let h = Modal.panel(title: "3D", width: 1100, height: 720, autosave: "city3d") { handle in
            CityPanelView(ex: ex, handle: handle)
        }
        ex.handle = h
        h.onClose.append { [weak ex] in
            if let ex, ex.city != nil { City.toggle(ex, on: false) }
        }
        Task { @MainActor in
            try? await ex.navigate(path)
            City.toggle(ex, on: true)
        }
    }
}

extension Notification.Name {
    static let cityPanelFocusFilter = Notification.Name("CityPanelFocusFilter")
}

private struct CityPanelView: View {
    let ex: CityPanelExplorer
    let handle: ModalHandle
    @FocusState private var filterFocused: Bool

    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("↑") { Task { try? await ex.cityGoParent() } }.buttonStyle(.icon).help("Parent")
                Button("⟳") { ex.refresh() }.buttonStyle(.icon).help("Refresh")
                Text(ex.path ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(p.textDim)
                Spacer()
                TextField("Filter", text: Binding(get: { ex.filter }, set: { ex.filter = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 180).focused($filterFocused)
                    .onSubmit { ex.city?.focus() }
                Toggle("Hidden", isOn: Binding(get: { ex.showHidden }, set: { ex.showHidden = $0 }))
                    .toggleStyle(.checkbox).font(.system(size: 11)).help("Show hidden files")
                Button(ex.city == nil ? "3D" : "☰ List") {
                    City.toggle(ex)
                }.buttonStyle(.ghostSmall).help("See this folder in 3D — fly over it, walk into folders")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(p.panel)
            p.border.frame(height: 1)
            if let c = ex.city {
                c.view
            } else if let e = ex.error {
                SlotPlaceholder(text: e)
            } else {
                List(ex.cityShownEntries()) { e in
                    Text((e.isDirectoryLike ? "📁 " : "") + e.name).font(.system(size: 12))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cityPanelFocusFilter)) { n in
            if (n.object as AnyObject?) === ex { filterFocused = true }
        }
    }
}
