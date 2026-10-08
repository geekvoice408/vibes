import AppKit
import SwiftUI

/// The explorer (Files/Explorer) as a city host: `city-open` hands over an
/// `ExplorerModel`, and the controller goes back through `attachCity` as the
/// explorer's `XPCityAttachment` (view, sync, invalidate, destroy).
extension CityController: XPCityAttachment {}

@MainActor
final class CityExplorerAdapter: CityExplorerHost {
    private weak var ex: ExplorerModel?

    init(_ ex: ExplorerModel) { self.ex = ex }

    var cityPath: String? { ex?.view.path }
    var cityEntries: [FileEntry] { ex?.view.entries ?? [] }
    func cityShownEntries() -> [FileEntry] {
        guard let ex else { return [] }
        return ex.sorted(ex.notHidden(ex.view.entries))
    }
    var cityShowHidden: Bool { Store.shared.xpShowHidden }
    var citySourceKey: String { ex?.sourceKey ?? "" }
    var citySourceKind: FileSourceKind {
        guard let ex else { return .local }
        return ex.isLocal ? .local : ex.isS3 ? .s3 : .sftp
    }
    var cityConnId: String? { ex?.connId }
    func cityMatcher() -> ((String) -> Bool)? { ex?.matcher }
    var cityFilterActive: Bool { !(ex?.filter.isEmpty ?? true) }
    var citySelection: Set<String> {
        get { ex?.view.selection ?? [] }
        set { ex?.view.selection = newValue }
    }
    func citySelectionChanged(lastClicked: String?) {
        if let lastClicked { ex?.lastClicked = lastClicked }
        ex?.render()
    }
    func cityNavigate(_ path: String) async throws { try await ex?.navigate(path) }
    func cityGoParent() async throws { await ex?.goParent() }
    func cityOpen(_ entry: FileEntry) {
        guard let ex else { return }
        Task { await ex.open(entry) }
    }
    func cityContextMenu(_ entry: FileEntry?, event: NSEvent, in view: NSView) { ex?.showContextMenu(for: entry) }
    func cityFocusFilter() { ex?.focusFilter() }
    func cityClearFilter() { ex?.clearFilter() }

    /// `.c3-max`: the whole explorer pane, toolbar and all, over its window.
    var cityMaximized: Bool {
        get { ex?.maximized ?? false }
        set { ex?.maximized = newValue }
    }

    var city: CityController? {
        get { ex?.city as? CityController }
        set {
            guard let ex else { return }
            if let c = newValue {
                ex.attachCity(c)
            } else if ex.city != nil {
                ex.toggle3d(false)
            }
        }
    }
}

