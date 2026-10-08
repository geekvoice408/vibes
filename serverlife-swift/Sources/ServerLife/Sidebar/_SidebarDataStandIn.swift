import Foundation

// The store.js record methods the sidebar uses, forwarded to Data/
// (Data/StoreRecords.swift) on `SB.store`, so there is one implementation.

@MainActor
enum SBData {
    static func forwardFavorites() -> [JSON] { SB.store.listForwardFavorites() }

    /// `addForwardFavorite`: one per host + listen port + kind (updated, not duplicated).
    @discardableResult
    static func addForwardFavorite(_ rec: JSON) throws -> JSON { try SB.store.addForwardFavorite(rec) }

    static func markForwardFavoriteUsed(_ id: String) { SB.store.markForwardFavoriteUsed(id) }
}
