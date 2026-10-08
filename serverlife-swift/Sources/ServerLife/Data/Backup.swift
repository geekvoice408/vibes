import Foundation

/// main/backup.js: export and import as one versioned JSON envelope, so a file
/// can say what it is before anything is applied. Nothing secret travels.
@MainActor
enum Backup {
    static let format = "serverlife.backup"
    static let version = 1

    /// What "everything" means. History is left out: it is a log, not a setting.
    static let fullKeys = ["profiles", "folders", "snippets", "macros", "hiddenMacros", "macroCategoryOrder",
                           "requestTemplates", "layouts", "defaultLayoutId", "settings"]
    /// Keys that are lists of records, and so can be merged rather than replaced.
    static let listKeys = ["profiles", "folders", "snippets", "macros", "requestTemplates", "layouts"]

    static func envelope(_ kind: String, _ data: JSON, _ meta: [String: JSON] = [:]) -> JSON {
        var e: JSON = ["format": .string(format), "version": JSON(version), "kind": .string(kind),
                       "exportedAt": .string(isoNow()), "app": "ServerLife"]
        for (k, v) in meta { e[k] = v }
        e["data"] = data
        return e
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// `exportAll`.
    static func exportAll(_ store: Store) -> JSON {
        var data: JSON = .object([:])
        for k in fullKeys {
            if k == "settings" { data[k] = store.settings; continue }
            if store.data.entries[k] != nil { data[k] = store[k] }
        }
        var counts: JSON = .object([:])
        for k in listKeys { counts[k] = JSON(data[k].items.count) }
        return envelope("settings", data, ["counts": counts])
    }

    /// `exportMacros`: the user's own macros (built-ins exist on the other
    /// machine already), plus hidden built-in ids and the category order
    /// unless only some ids were asked for.
    static func exportMacros(_ store: Store, _ ids: [String]?) -> JSON {
        let all = store["macros"].items
        let some = ids?.isEmpty == false
        let macros = some ? all.filter { ids!.contains($0["id"].string ?? "") } : all
        return envelope("macros", ["macros": .array(macros),
                                   "hiddenMacros": some ? [] : .array(store["hiddenMacros"].items),
                                   "macroCategoryOrder": some ? [] : .array(store["macroCategoryOrder"].items)],
                        ["counts": ["macros": JSON(macros.count)]])
    }

    static func parse(_ text: String) throws -> JSON {
        guard let doc = try? JSON.parse(text) else { throw AppError("That file is not JSON.") }
        guard doc.truthy, doc["format"].string == format else { throw AppError("That is not a ServerLife export.") }
        // `Number(doc.version) > VERSION`
        if dNum(doc["version"], .nan) > Double(version) {
            throw AppError("That file was written by a newer ServerLife (format \(doc["version"].stringish ?? "")).")
        }
        // `!doc.data || typeof doc.data !== 'object'` (an array is an object there)
        guard doc["data"].object != nil || doc["data"].array != nil else { throw AppError("The export has no data in it.") }
        return doc
    }

    /// What an import would do, without doing it — so the user can be asked first.
    static func describe(_ doc: JSON) -> JSON {
        let d = doc["data"]
        var counts: JSON = .object([:])
        for k in listKeys + ["hiddenMacros"] { if let a = d[k].array { counts[k] = JSON(a.count) } }
        return ["kind": doc["kind"], "exportedAt": dOr(doc["exportedAt"], .null),
                "hasSettings": .bool(d["settings"].truthy), "counts": counts]
    }

    /// `applyImport`: merge keeps what is here and adds what is not (matched
    /// on id); replace makes this machine look like the file. Settings always
    /// merge over the top: a file from an older build must not remove
    /// settings this one has gained.
    @discardableResult
    static func applyImport(_ store: Store, _ doc: JSON, mode: String = "merge") -> JSON {
        let d = doc["data"]
        var added: JSON = .object([:])
        for k in listKeys {
            guard let incoming = d[k].array else { continue }
            if mode == "replace" {
                store[k] = .array(incoming)
                added[k] = JSON(incoming.count)
                continue
            }
            let existing = store[k].items
            let seen = Set(existing.filter(\.truthy).map { $0["id"] }.filter(\.truthy))
            let fresh = incoming.filter { $0.truthy && (!$0["id"].truthy || !seen.contains($0["id"])) }
            store[k] = .array(existing + fresh)
            added[k] = JSON(fresh.count)
        }
        for k in ["hiddenMacros", "macroCategoryOrder"] {
            guard let incoming = d[k].array else { continue }
            if mode == "replace" { store[k] = .array(incoming); continue }
            // `[...new Set([...existing, ...incoming])]`
            var out: [JSON] = []
            for x in store[k].items + incoming where !out.contains(x) { out.append(x) }
            store[k] = .array(out)
        }
        if let s = d["settings"].object { store.updateSettings(s) }
        if mode == "replace", d.entries["defaultLayoutId"] != nil {
            store["defaultLayoutId"] = d["defaultLayoutId"]
        }
        store.save()
        return ["mode": .string(mode), "added": added]
    }
}
