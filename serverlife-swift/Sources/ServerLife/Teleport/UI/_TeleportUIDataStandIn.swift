import Foundation

/// The store.js record methods the Teleport UI uses — saved cluster logins,
/// saved access requests, flagged/noted sessions, connection history and
/// quick connect's typed addresses — forwarded to Data/
/// (Data/StoreRecords.swift) on `store`, so there is one implementation.
@MainActor
enum TUIData {
    /// The store these records live in (tests swap in a throwaway one).
    static var store: Store = .shared

    static func listTshLogins() -> [JSON] { store.listTshLogins() }
    @discardableResult static func upsertTshLogin(_ t: JSON) -> JSON { store.upsertTshLogin(t) }
    static func deleteTshLogin(_ id: String) { store.deleteTshLogin(id) }
    static func markTshLoginUsed(_ id: String) { store.markTshLoginUsed(id) }

    static func listRequestTemplates(proxy: String? = nil, cluster: String? = nil) -> [JSON] {
        store.listRequestTemplates(proxy: proxy, cluster: cluster)
    }
    static func trimRequestResources(_ resources: JSON) -> JSON { Store.trimRequestResources(resources) }
    @discardableResult static func upsertRequestTemplate(_ t: JSON) -> JSON { store.upsertRequestTemplate(t) }
    static func deleteRequestTemplate(_ id: String) { store.deleteRequestTemplate(id) }
    static func markRequestTemplateUsed(_ id: String) { store.markRequestTemplateUsed(id) }

    static func listSessionNotes() -> [JSON] { store.listSessionNotes() }
    @discardableResult static func upsertSessionNote(_ rec: JSON) -> JSON? { store.upsertSessionNote(rec) }
    static func deleteSessionNote(_ sid: String) { store.deleteSessionNote(sid) }

    static func listHistory(limit: Int = 200) -> [JSON] { store.listHistory(limit: limit) }
    static func clearHistory() { store.clearHistory() }

    /// quickconnect.js `clearQuickConnectHistory`.
    static func clearQuickConnectHistory() { store.setSettingJSON("quickConnects", .array([])) }

    /// `(a.lastUsed || a.updatedAt || 0)`.
    static func jsTime(_ a: JSON, _ b: JSON) -> Double { dTime(a, b) }
}
