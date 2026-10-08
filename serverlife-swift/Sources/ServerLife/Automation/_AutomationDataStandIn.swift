import Foundation

// The store.js methods automation uses, under the `auto` names its callers
// already use, forwarded to Data/ (Data/StoreRecords.swift) so there is one
// implementation.

@MainActor
extension Store {
    func autoListS3Targets() -> [JSON] { listS3Targets() }
    func autoGetS3Target(_ id: String) -> JSON? { getS3Target(id) }
    @discardableResult func autoUpsertS3Target(_ t: JSON) -> JSON { upsertS3Target(t) }
    func autoDeleteS3Target(_ id: String) { deleteS3Target(id) }

    func autoListLayouts() -> [JSON] { listLayouts() }
    @discardableResult
    func autoSaveLayout(id: String? = nil, name: String, workspace: JSON) -> JSON {
        saveLayout(id: id, name: name, workspace: workspace)
    }

    func autoListForwardFavorites() -> [JSON] { listForwardFavorites() }
    func autoMarkForwardFavoriteUsed(_ id: String) { markForwardFavoriteUsed(id) }

    func autoListNetRequests() -> [JSON] { listNetRequests() }
    /// main.js run_request: `store.saveNetRequest({ ...req, lastRunAt: Date.now() })`.
    func autoMarkNetRequestRun(_ rec: JSON) {
        var r = rec
        r["lastRunAt"] = .number(nowMs())
        saveNetRequest(r)
    }

    func autoListTshLogins() -> [JSON] { listTshLogins() }
    func autoListProfiles() -> [JSON] { listProfiles() }
}
