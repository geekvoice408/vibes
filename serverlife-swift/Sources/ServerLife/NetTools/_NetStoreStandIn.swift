import Foundation

// store.js's netRequests / netRuns methods, forwarded to Data/
// (Data/StoreRecords.swift), so there is one implementation.

@MainActor
enum NetSaved {
    /// Saved requests, most recently run (or saved) first.
    static func requests() -> [JSON] { Store.shared.listNetRequests() }

    /// Save (or update) a named request.
    @discardableResult
    static func saveRequest(_ rec: JSON) -> JSON { Store.shared.saveNetRequest(rec) }

    static func deleteRequest(_ id: String) { Store.shared.deleteNetRequest(id) }

    /// Remember a run (store.js `addNetRun`; see the note there on replacement).
    @discardableResult
    static func addRun(_ rec: JSON) -> JSON { Store.shared.addNetRun(rec) }

    static func runs() -> [JSON] { Store.shared.listNetRuns() }

    static func clearRuns() { Store.shared.clearNetRuns() }
}
