import Foundation

/// The envelope behind the backup dialogs (main/backup.js), forwarded to
/// Data/'s port (`Backup`, Data/Backup.swift) over `Store.shared`.
@MainActor
enum BackupOps {
    static var format: String { Backup.format }
    static var version: Int { Backup.version }
    static var fullKeys: [String] { Backup.fullKeys }
    static var listKeys: [String] { Backup.listKeys }

    static func envelope(_ kind: String, _ data: JSON, _ meta: [String: JSON] = [:]) -> JSON {
        Backup.envelope(kind, data, meta)
    }

    /// Everything, or (`macrosOnly`) macros — optionally only `ids`.
    static func export(_ macrosOnly: Bool, _ ids: [String]?) throws -> JSON {
        macrosOnly ? Backup.exportMacros(.shared, ids) : Backup.exportAll(.shared)
    }

    static func parse(_ text: String) throws -> JSON { try Backup.parse(text) }

    static func describe(_ doc: JSON) -> JSON { Backup.describe(doc) }

    static func apply(_ doc: JSON, _ mode: String) throws -> JSON { Backup.applyImport(.shared, doc, mode: mode) }
}
