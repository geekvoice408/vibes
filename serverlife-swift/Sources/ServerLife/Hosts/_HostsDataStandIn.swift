import Foundation

// The store.js record methods the hosts feature uses — profiles, profile
// folders and session history — forwarded to Data/ (Data/StoreRecords.swift),
// so there is one implementation.

/// JavaScript `a || b` for JSON values.
func hostsOr(_ a: JSON, _ b: JSON) -> JSON { dOr(a, b) }

@MainActor
enum HostsData {
    static var profiles: [JSON] { Store.shared.listProfiles() }

    static func profile(_ id: String?) -> JSON? {
        guard let id, !id.isEmpty else { return nil }
        return Store.shared.getProfile(id)
    }

    @discardableResult
    static func upsertProfile(_ profile: JSON) -> JSON { Store.shared.upsertProfile(profile) }

    static func deleteProfile(_ id: String) { Store.shared.deleteProfile(id) }

    static func markUsed(_ id: String?) { Store.shared.markProfileUsed(id) }

    static var profileFolders: [JSON] { Store.shared.listFolders() }

    @discardableResult
    static func upsertProfileFolder(_ folder: JSON) -> JSON { Store.shared.upsertFolder(folder) }

    static func deleteProfileFolder(_ id: String) { Store.shared.deleteFolder(id) }

    static func listHistory(limit: Int = 200) -> [JSON] { Store.shared.listHistory(limit: limit) }

    static func listRecent(limit: Int = 20) -> [JSON] { Store.shared.listRecent(limit: limit) }

    nonisolated static func listRecent(_ history: [JSON], limit: Int) -> [JSON] {
        Store.listRecent(history, limit: limit)
    }

    static func clearHistory() { Store.shared.clearHistory() }
}
