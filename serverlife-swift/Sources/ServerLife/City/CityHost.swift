import AppKit
import Metal
import SceneKit

/// What the 3D view needs from the explorer it is a view of.
///
/// The city is not a second file manager: where it is, what is selected, the
/// name filter, hidden files, search and the right-click menu are all the
/// explorer's own, so everything its toolbar does works here and switching
/// back to the list loses nothing. The explorer adopts this protocol (an
/// extension on its model is enough) and keeps the controller in `city`.
///
/// While `city` is set and the listing is ready, the explorer draws
/// `city.view` in place of its list (and hides the column header), and calls
/// `city.sync()` whenever it redraws — or, if the explorer model is
/// `@Observable`, the controller notices the properties below change by
/// itself. When the listing is not ready ("not connected", "approve MFA"),
/// the explorer shows its list as usual: that is where those messages are.
@MainActor
protocol CityExplorerHost: AnyObject {
    /// The folder on screen (`view.path`); nil while nothing has been listed.
    var cityPath: String? { get }
    /// Its entries as listed, hidden ones included (`view.entries`).
    var cityEntries: [FileEntry] { get }
    /// The entries the list would show, in its order: hidden files dropped
    /// unless they are shown (`_notHidden`), sorted as the list is
    /// (`sortEntries(…, _sortOpts())`).
    func cityShownEntries() -> [FileEntry]
    /// Whether hidden files are shown (part of the redraw signature).
    var cityShowHidden: Bool { get }
    /// Changes when the explorer switches to another machine (`sourceKey`).
    var citySourceKey: String { get }
    var citySourceKind: FileSourceKind { get }
    /// The connection behind a remote source.
    var cityConnId: String? { get }
    /// The name filter as a test (`_matcher()`); nil when there is no filter.
    func cityMatcher() -> ((String) -> Bool)?
    /// A filter is typed in (`ex.filter`).
    var cityFilterActive: Bool { get }
    /// Paths of the selected entries (`view.selection`).
    var citySelection: Set<String> { get set }
    /// After the city changed the selection: `_lastClicked = path; render()`.
    func citySelectionChanged(lastClicked: String?)
    /// Go to a folder (`navigate`).
    func cityNavigate(_ path: String) async throws
    /// The folder above (`goParent`).
    func cityGoParent() async throws
    /// Open a file the way a double-click in the list does (`open`).
    func cityOpen(_ entry: FileEntry)
    /// The explorer's own right-click menu (`_onContextMenu`), for an entry
    /// or — nil — for the folder itself.
    func cityContextMenu(_ entry: FileEntry?, event: NSEvent, in view: NSView)
    /// Put the cursor in the name filter (`focusFilter`).
    func cityFocusFilter()
    /// Empty the name filter (`clearFilter`).
    func cityClearFilter()
    /// The whole explorer pane filling the window, toolbar and all (`.c3-max`).
    var cityMaximized: Bool { get set }
    /// Where the explorer keeps its city; nil when it shows its list.
    var city: CityController? { get set }
}

/// One thing in the city that can be pointed at.
@MainActor
final class CityItem {
    enum Kind: String { case building, crate, door, exit, bird, plane, hero, police, suspect, proc }
    let kind: Kind
    var entry: FileEntry?
    var rec: CityRec?
    /// Weak: the node carries the item (`CityNode.item`), the scene carries the node.
    weak var group: SCNNode?
    var mats: [SCNMaterial] = []
    var h: Float = 0, w: Float = 0, x: Float = 0, z: Float = 0
    var grow: Float = 1
    weak var label: SCNNode?
    var labelY: Float = 0
    /// Only drawn within this distance (unless selected).
    var labelNear: Float?
    /// Shrinks as you come up to it (building signs).
    var labelScales = false
    var dim = false
    var selected = false
    var beacon: SCNNode?
    var proc: CityProc?
    var vehicle: CityProcKind?

    init(kind: Kind, entry: FileEntry? = nil) {
        self.kind = kind
        self.entry = entry
    }
}

/// The "city of here" in the explorer: open, close, and the setting.
@MainActor
enum City {
    /// Every city open now, for the setting that turns them all off.
    private static var open: [ObjectIdentifier: () -> CityExplorerHost?] = [:]

    /// `toggle3d(force)`: open or close the city of an explorer.
    static func toggle(_ host: CityExplorerHost, on force: Bool? = nil) {
        let on = force ?? (host.city == nil)
        if on == (host.city != nil) { return }
        if on && !Store.shared.setting("show3dView", true) { return }
        if on && host.citySourceKind == .s3 {
            StatusBus.shared.toast("The 3D view does not reach into buckets yet", kind: .error)
            return
        }
        if on {
            guard MTLCreateSystemDefaultDevice() != nil else {
                StatusBus.shared.toast("3D needs Metal, which is not available here", kind: .error)
                return
            }
            let c = CityController(host: host)
            host.city = c
            weak var weakHost = host
            open[ObjectIdentifier(c)] = { weakHost }
            c.sync()
            c.focus()
        } else if let c = host.city {
            open.removeValue(forKey: ObjectIdentifier(c))
            c.destroy()
            host.city = nil
        }
    }

    /// `apply3dSetting`: closing any city the setting turned off.
    static func applySetting() {
        guard !Store.shared.setting("show3dView", true) else { return }
        for (_, h) in open { if let host = h() { toggle(host, on: false) } }
        open.removeAll()
    }

    static func forget(_ c: CityController) { open.removeValue(forKey: ObjectIdentifier(c)) }
}

extension Store {
    /// What the town is built in. Remembered across folders and launches,
    /// since it is a taste rather than a fact about any one folder.
    var city3dStyle: String {
        get { setting("city3dStyle", CityStyle.defaultId) }
        set { setSetting("city3dStyle", newValue) }
    }

    /// Processes shown as traffic.
    var city3dTraffic: Bool {
        get { settingJSON("city3dTraffic").bool == true }
        set { setSetting("city3dTraffic", newValue) }
    }
}
