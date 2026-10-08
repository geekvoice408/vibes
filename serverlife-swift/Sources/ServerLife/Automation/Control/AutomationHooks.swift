import Foundation

/// What the control socket needs from features it does not own and cannot
/// reach through a published API yet: macros (fleet). The owner sets these in
/// its `install()`. Unset, `list_macros` and `run_macro` answer with a clear
/// error saying so rather than doing something approximate.
///
/// (Tabs, panes and layouts come straight from Sessions' `SessionsWindow`.)
@MainActor
enum AutomationHooks {
    /// `list_macros`: every macro the window offers, built-ins included, as
    /// `state.macros` held them (`name, category, description, command,
    /// builtin, confirm, interactive, repeatSeconds` …). The same set
    /// `runMacro` runs from, so a caller that lists and then runs is looking
    /// at one list.
    static var listMacros: ((WindowModel) -> [JSON])?

    /// `run_macro`: run one of those macros (macros.js `sendMacro(macro,
    /// {all})`) in the window's focused pane, or every pane of its tab with
    /// `all`. Called only once the focused pane has a terminal.
    static var runMacro: ((WindowModel, JSON, _ all: Bool) async throws -> Void)?
}
