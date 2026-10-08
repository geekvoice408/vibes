import SwiftUI

/// Extension points other owners fill in from their `install()`, for the
/// parts of the host list that draw their data. Each is optional: unset, the
/// sidebar says the thing is not available rather than failing.
@MainActor
enum SidebarHooks {
    /// teleport-ui (teleportpanel.js `renderTeleportTab`): the Teleport tab's contents.
    static var teleportTab: ((WindowModel) -> AnyView)?

    /// teleport-ui (`leafClusterTag`): the leaf-cluster badge on a cluster
    /// heading, or nil when the cluster has no leaves.
    static var leafClusterTag: ((TeleportProfile, WindowModel) -> AnyView?)?

    /// teleport-ui (`clusterSwitchMenuItem`): the "switch cluster" entry of a
    /// cluster heading's menu (a submenu for a handful, a dialog past ten).
    static var clusterSwitchMenuItem: ((TeleportProfile, WindowModel) -> CtxItem?)?

    /// teleport-ui (beams.js `beamMenu`): a beam row's right-click menu.
    static var beamMenu: ((Beam, WindowModel) -> [CtxItem])?

    /// fleet (macros.js): the macro list on Saved → Macros.
    static var macros: SidebarMacroSource?
}

/// What the Saved → Macros list needs from macros.js. Macros are JSON in the
/// store's shape (`id, name, command, description, category, confirm,
/// repeatSeconds, interactive, noEnter, builtin, runScope …`).
@MainActor
protocol SidebarMacroSource: AnyObject {
    /// Every macro (built-ins and the user's), as `state.macros`.
    func all() -> [JSON]
    /// `macroCategories(list)`: the list grouped by category, in category order.
    func categories(_ list: [JSON]) -> [(category: String, items: [JSON])]
    func isPinned(_ id: String) -> Bool
    /// The pinned button's icon.
    func pinnedIcon(_ id: String) -> String
    /// `scopeLabel(pinnedScopeFor(id))`, e.g. "Every host".
    func pinnedScopeLabel(_ id: String) -> String
    /// `runScopeOf(m)`: "hosts", "local" or "both".
    func runScope(_ m: JSON) -> String
    /// `runScopeLabel(scope)`.
    func runScopeLabel(_ scope: String) -> String
    /// `sendMacro(m, { all })`: to the focused terminal, or every pane in the tab.
    func send(_ m: JSON, all: Bool, window: WindowModel)
    /// `runMacroOnHost(m, host, login)`: run headless and show the output.
    func runOnHost(_ m: JSON, host: Host, login: String?, window: WindowModel)
    /// `promptRepeat(m)`.
    func promptRepeat(_ m: JSON, window: WindowModel)
    /// `togglePin(m)`.
    func togglePin(_ m: JSON, window: WindowModel) async
    /// `editMacro(m)` (an empty object for a new one).
    func edit(_ m: JSON, window: WindowModel) async
    /// `deleteMacro(m)`: true when it went (or was hidden).
    func delete(_ m: JSON, window: WindowModel) async -> Bool
    /// `restoreBuiltins()`.
    func restoreBuiltins() async
    /// `moveCategory(category, delta)`: true when it moved.
    func moveCategory(_ category: String, _ delta: Int) async -> Bool
}
