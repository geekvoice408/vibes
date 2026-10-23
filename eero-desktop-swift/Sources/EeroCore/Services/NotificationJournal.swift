import Foundation

/// Remembers which eero notifications were already announced, per account and network (port of
/// `NotificationJournal`). The first check for a scope seeds silently so old history is never announced.
/// Scopes and notification identifiers are stored only as SHA-256 digests, so the file contains no account,
/// network or event identifiers in plaintext (the Windows version encrypted them with DPAPI instead).
public final class NotificationJournal {
    public let fileURL: URL
    private var seen: [String: [String]] = [:]
    private var order: [String] = []

    public static let maxScopes = 64
    public static let maxIds = 256

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: fileURL),
              let parsed = try? JSON.parse(data), let object = parsed.object else { return }
        for key in object.keys.sorted().prefix(NotificationJournal.maxScopes) where NotificationJournal.isDigest(key) {
            var ids: [String] = []
            for x in object[key]!.list {
                let id = x.string
                if NotificationJournal.isDigest(id) && !ids.contains(id) { ids.append(id) }
                if ids.count == NotificationJournal.maxIds { break }
            }
            seen[key] = ids; order.append(key)
        }
    }

    /// Convenience for a journal stored at a file-system path.
    public convenience init(_ path: String) { self.init(fileURL: URL(fileURLWithPath: path)) }

    static func isDigest(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) } }
    static func validId(_ id: String) -> Bool {
        !id.isEmpty && id.utf16.count <= 256 && !id.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
    static func digest(_ s: String) -> String { EeroSHA256.hex(Data(s.utf8)).uppercased() }

    private static func scope(_ account: String, _ network: String) throws -> String {
        digest(account + "\n" + (try EeroAPI.resource(network)).absoluteString)
    }

    /// Returns the notifications (from a newest-first page) that have not been seen for this account and network.
    public func observe(_ account: String, _ network: String, _ newestFirst: [JSON]) throws -> [JSON] {
        let scope = try NotificationJournal.scope(account, network)
        let seeded = seen[scope] != nil
        var ids = seen[scope] ?? []
        if !seeded { order.append(scope) }
        var result: [JSON] = []
        for item in newestFirst.prefix(50).reversed() {
            let id = item.first("uuid", "id")
            if !NotificationJournal.validId(id) { continue }
            let key = NotificationJournal.digest(id)
            if ids.contains(key) { continue }
            ids.append(key)
            if seeded { result.append(item) }
        }
        if ids.count > NotificationJournal.maxIds { ids.removeFirst(ids.count - NotificationJournal.maxIds) }
        seen[scope] = ids
        while seen.count > NotificationJournal.maxScopes, let victim = order.first(where: { $0 != scope }) {
            seen[victim] = nil; order.removeAll { $0 == victim }
        }
        return result
    }

    /// Atomically writes the journal, readable only by the current user.
    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSON.object(seen.mapValues { .array($0.map(JSON.string)) }).data.write(to: fileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
