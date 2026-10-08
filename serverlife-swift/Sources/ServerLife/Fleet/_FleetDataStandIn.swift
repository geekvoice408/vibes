import Foundation

// store.js's record methods for snippets, macros (pins, hidden built-ins,
// category order), multi-exec history and favourite tunnels, forwarded to
// Data/ (Data/StoreRecords.swift), so there is one implementation.

@MainActor
enum FleetStore {
    /// Tests point this at a throwaway store so they never write the real one.
    static var storeOverride: Store?
    static var store: Store { storeOverride ?? Store.shared }

    /// First line of a command, 40 characters (UTF-16, as `.slice(0, 40)`).
    static func firstLine(_ command: String, max: Int = 40) -> String {
        dSlice(command.components(separatedBy: "\n").first ?? "", max)
    }

    // MARK: Command snippets

    static func snippets() -> [JSON] { store.listSnippets() }
    @discardableResult static func upsertSnippet(_ sn: JSON) -> JSON { store.upsertSnippet(sn) }
    static func deleteSnippet(_ id: String) { store.deleteSnippet(id) }
    static func markSnippetUsed(_ id: String) { store.markSnippetUsed(id) }

    // MARK: Macros

    static func savedMacros() -> [JSON] { store.listMacros()["macros"].items }
    static func hiddenMacros() -> [String] { store.listMacros()["hidden"].items.compactMap(\.string) }
    static func macroCategoryOrder() -> [String] { store.listMacros()["categoryOrder"].items.compactMap(\.string) }
    static func macroPins() -> [JSON] { store.listMacros()["pins"].items }

    @discardableResult
    static func setMacroPin(_ id: String, pinned: Bool = true, icon: String = "", where scope: String? = nil) -> [JSON] {
        store.setMacroPin(id, pinned: pinned, icon: icon, where: scope)
    }
    @discardableResult static func setMacroCategoryOrder(_ order: [String]) -> [String] { store.setMacroCategoryOrder(order) }
    @discardableResult static func upsertMacro(_ m: JSON) -> JSON { store.upsertMacro(m) }
    static func deleteMacro(_ id: String) { store.deleteMacro(id) }
    @discardableResult static func setMacroHidden(_ id: String, _ hidden: Bool) -> [String] { store.setMacroHidden(id, hidden) }
    static func markMacroUsed(_ id: String) { store.markMacroUsed(id) }

    // MARK: Multi-exec history

    @discardableResult static func addExecRun(_ rec: JSON) -> JSON? { store.addExecRun(rec) }
    static func execRuns() -> [JSON] { store.listExecRuns() }
    static func deleteExecRun(_ id: String) { store.deleteExecRun(id) }
    static func clearExecRuns() { store.clearExecRuns() }

    // MARK: Favourite tunnels

    static func forwardFavorites() -> [JSON] { store.listForwardFavorites() }
    @discardableResult static func addForwardFavorite(_ rec: JSON) throws -> JSON { try store.addForwardFavorite(rec) }
    @discardableResult static func updateForwardFavorite(_ id: String, _ patch: JSON) -> JSON? { store.updateForwardFavorite(id, patch) }
    static func markForwardFavoriteUsed(_ id: String) { store.markForwardFavoriteUsed(id) }
    static func deleteForwardFavorite(_ id: String) { store.deleteForwardFavorite(id) }
}
