import AppKit
import SwiftUI

// The explorer's seams: the settings it reads, what it needs to know about the
// pane it sits in (filled from Sessions by ExplorerSessionsGlue.swift), the
// connections it browses, the source registry other owners add to (S3), and
// the 3D view's attachment.

// MARK: - Settings (same keys and defaults as store.js)

extension Store {
    /// settings.showHiddenFiles (`state.showHidden`).
    var xpShowHidden: Bool {
        get { settingJSON("showHiddenFiles").bool == true }
        set { setSetting("showHiddenFiles", newValue) }
    }
    /// settings.showFileDetails — the ≣ details columns.
    var xpShowDetails: Bool {
        get { settingJSON("showFileDetails").bool == true }
        set { setSetting("showFileDetails", newValue) }
    }
    /// settings.followTerminalFolder (`state.followTerminal`).
    var xpFollowTerminal: Bool {
        get { settingJSON("followTerminalFolder").bool != false }
        set { setSetting("followTerminalFolder", newValue) }
    }
    /// `state.settings.foldersFirst !== false`.
    var xpFoldersFirst: Bool {
        get { settingJSON("foldersFirst").bool != false }
        set { setSetting("foldersFirst", newValue) }
    }
    /// `state.settings.show3dView !== false`.
    var xpShow3d: Bool { settingJSON("show3dView").bool != false }
    /// `refreshSeconds`: undefined → 5, otherwise max(0, Number(v) || 0).
    var xpRefreshSeconds: Double {
        let v = settingJSON("refreshSeconds")
        if v.isNull { return 5 }
        return max(0, v.double ?? 0)
    }
    var xpExplorersVisible: Bool {
        get { settingJSON("explorersVisible").bool != false }
        set { setSetting("explorersVisible", newValue) }
    }
    /// 'left' (beside the terminal) or 'top' (above it).
    var xpExplorerPosition: String {
        get { settingJSON("explorerPosition").string?.nilIfEmpty ?? "left" }
        set { setSetting("explorerPosition", newValue) }
    }
    var xpFavListCollapsed: Bool {
        get { settingJSON("favListCollapsed").bool == true }
        set { setSetting("favListCollapsed", newValue) }
    }
    var xpFolderFavorites: [JSON] { settingJSON("folderFavorites").items }
    var xpHiddenFolderFavorites: [String] { settingJSON("hiddenFolderFavorites").stringArray }
    var xpAutoFlagLocal: [String] { settingJSON("autoFlagLocal").items.compactMap { $0.stringish } }
    var xpAutoFlagHost: [String] { settingJSON("autoFlagHost").items.compactMap { $0.stringish } }
    var xpOpenWithApps: [String] { settingJSON("openWithApps").stringArray }
}

// MARK: - The pane an explorer sits in

/// What the explorer needs to know about a pane. Filled from Sessions'
/// `SessionPane` by the glue; nil when there is no such pane.
struct XPPaneInfo {
    /// "remote" | "local" | "tmux" | "device" | "view"
    var kind: String
    var connId: String?
    var tabId: String?
    var explorerVisible: Bool
    /// The pane's file side is showing and its tab is the one on screen.
    var onScreen: Bool
    var cwd: String?
    var hasTerm: Bool
    /// A tmux pane whose control stream is still attached.
    var tmuxAttached: Bool
    var window: WindowModel?
}

/// The pane-side operations, set by the glue to Sessions. Each falls back to
/// something sensible (nothing) while Sessions is not there.
@MainActor
enum XPPanes {
    static var info: (String) -> XPPaneInfo? = { _ in nil }
    /// The focused pane of a window.
    static var activePaneId: (WindowModel?) -> String? = { _ in nil }
    /// Show or hide a pane's file side (sessions' setPaneExplorerVisible).
    static var setVisible: (String, Bool) -> Void = { _, _ in }
    /// Type into a pane's terminal (`sendToPane`).
    static var send: (String, String) -> Void = { paneId, text in
        Actions.shared.perform("send-text", paneId: paneId, args: ["text": text, "enter": false])
    }
    /// Every pane id in a window (nil: the focused one).
    static var allPaneIds: (WindowModel?) -> [String] = { _ in [] }
}

// MARK: - Connections

/// What the explorer reads about a connection (state.getConnection in the original).
@MainActor
struct XPConn {
    let id: String
    let state: String
    let transport: String
    let transportForced: String?
    let homeDir: String?
    let label: String
    let error: String?
    let type: String
    let target: String
    let host: Host

    static func get(_ id: String?) -> XPConn? {
        guard let id, let c = ConnectionManager.shared.connection(id) else { return nil }
        return XPConn(id: c.id, state: c.state.rawValue, transport: c.transportKind, transportForced: c.transportForced,
                      homeDir: c.homeDir, label: c.label, error: c.error, type: c.type, target: c.target, host: c.host)
    }

    static var all: [XPConn] { ConnectionManager.shared.connections.compactMap { get($0.id) } }

    var connected: Bool { state == "connected" }
    /// `needsMfaApproval(conn)`.
    var needsMfaApproval: Bool { transport == "tsh" }
}

// MARK: - Sources other owners add (S3)

/// One entry in an explorer's source picker, from a registered provider.
struct XPSourceOption: Hashable {
    /// The picker value, e.g. "s3:<targetId>". Must start with the provider's prefix.
    var value: String
    var label: String
}

/// A kind of place an explorer can point at beyond this machine and the open
/// sessions — the automation owner registers S3 buckets here.
@MainActor
protocol XPSourceProvider: AnyObject {
    /// "s3" → values look like "s3:<id>".
    var prefix: String { get }
    func options() -> [XPSourceOption]
    func fileSource(_ value: String) -> FileSource?
}

@MainActor
enum ExplorerSources {
    private(set) static var providers: [XPSourceProvider] = []

    /// Add a provider; its options appear in every explorer's picker.
    static func register(_ p: XPSourceProvider) {
        providers.removeAll { $0.prefix == p.prefix }
        providers.append(p)
        Explorers.shared.forEach { $0.syncSources() }
    }

    /// Call after a provider's options change (a bucket registered or removed).
    static func changed() { Explorers.shared.forEach { $0.syncSources(); $0.render() } }

    static func provider(for value: String) -> XPSourceProvider? {
        providers.first { value.hasPrefix($0.prefix + ":") }
    }
}

// MARK: - The 3D view

/// What the city owner attaches to an explorer after `city-open`: the view
/// drawn in place of the list while a folder is on screen, and the calls the
/// explorer makes as it changes (city3d.js `sync`, `invalidate`, `destroy`).
@MainActor
protocol XPCityAttachment: AnyObject {
    var view: AnyView { get }
    /// The explorer redrew (path, entries, selection, filter changed).
    func sync()
    /// A refresh was asked for: rescan.
    func invalidate()
    /// The explorer is closing it (the 3D button, a bucket, the setting).
    func destroy()
}
