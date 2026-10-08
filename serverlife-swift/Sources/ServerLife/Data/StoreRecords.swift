import Foundation

// The record methods of store.js (`class Store`), ported as `extension Store`.
//
// Every collection has exactly one implementation, here; the features' old
// stand-ins forward to these. Records stay `JSON` objects so they round-trip
// with every field they had — store.js merges with object spread
// (`{ ...existing, ...patch }`), and a field this build does not know about
// must survive an edit just as it does there.
//
// JavaScript idioms are ported literally: `a || b` is `dOr`, `String(x || '')`
// is `dStr`, `Number(x) || 0` is `dNum`, `.slice(0, n)` counts UTF-16 units,
// and every sort is stable (Array.prototype.sort is).

// MARK: - JS helpers

/// `a || b` for JSON values.
func dOr(_ a: JSON, _ b: JSON) -> JSON { a.truthy ? a : b }
/// `String(x || '')`.
func dStr(_ v: JSON) -> String { v.truthy ? (v.stringish ?? "") : "" }
/// `Number(x) || 0` (and `|| fallback`).
func dNum(_ v: JSON, _ fallback: Double = 0) -> Double {
    let d: Double
    switch v {
    case .bool(let b): d = b ? 1 : 0
    case .number(let n): d = n
    case .string(let s): let t = s.trimmed; d = t.isEmpty ? 0 : (Double(t) ?? .nan)
    case .null: d = 0
    case .array, .object: d = .nan
    }
    return d.isNaN || d == 0 ? fallback : d
}
/// `s.slice(0, n)` (UTF-16 code units).
func dSlice(_ s: String, _ n: Int) -> String {
    let u = Array(s.utf16)
    return u.count > n ? String(decoding: u[0..<n], as: UTF16.self) : s
}
/// `(a.x || a.y || 0)` as a sort key.
func dTime(_ a: JSON, _ b: JSON) -> Double {
    if a.truthy, let v = a.double { return v }
    if b.truthy, let v = b.double { return v }
    return 0
}
/// A stable descending sort on a numeric key (`.sort((a, b) => key(b) - key(a))`).
func dSortedDesc(_ list: [JSON], _ key: (JSON) -> Double) -> [JSON] {
    list.enumerated()
        .sorted { let ka = key($0.element), kb = key($1.element); return ka != kb ? ka > kb : $0.offset < $1.offset }
        .map(\.element)
}

private let historyLimit = 500

@MainActor
extension Store {
    // MARK: - Shared plumbing

    fileprivate func recs(_ key: String) -> [JSON] { self[key].items }
    fileprivate func setRecs(_ key: String, _ list: [JSON]) { self[key] = .array(list) }
    fileprivate func index(_ key: String, id: String?) -> Int? {
        guard let id, !id.isEmpty else { return nil }
        return recs(key).firstIndex { $0["id"].string == id }
    }
    /// `{ ...list[i], ...patch, updatedAt: now }` (no `updatedAt` when `stamp` is nil).
    fileprivate func mergeAt(_ key: String, _ i: Int, _ patch: JSON, stamp: Double?) -> JSON {
        var list = recs(key)
        var rec = list[i]
        rec.merge(patch)
        if let stamp { rec["updatedAt"] = .number(stamp) }
        list[i] = rec
        setRecs(key, list)
        return rec
    }
    fileprivate func append(_ key: String, _ rec: JSON) { setRecs(key, recs(key) + [rec]) }
    fileprivate func remove(_ key: String, where field: String = "id", _ value: String) {
        setRecs(key, recs(key).filter { $0[field].stringish != value })
    }
    /// `x.useCount = (x.useCount || 0) + 1; x.lastUsed = Date.now()`.
    fileprivate func bumpUse(_ key: String, _ id: String) -> JSON? {
        guard let i = index(key, id: id) else { return nil }
        var list = recs(key)
        list[i]["useCount"] = .number(dNum(list[i]["useCount"]) + 1)
        list[i]["lastUsed"] = .number(nowMs())
        setRecs(key, list)
        return list[i]
    }

    // MARK: - Profiles

    func listProfiles() -> [JSON] { recs("profiles") }

    func getProfile(_ id: String?) -> JSON? {
        guard let id else { return nil }
        return recs("profiles").first { $0["id"].string == id }
    }

    /// Create or update a saved profile. A profile captures everything needed
    /// to re-open a session: target, login, start directories and startup command.
    @discardableResult
    func upsertProfile(_ profile: JSON) -> JSON {
        let now = nowMs()
        if let i = index("profiles", id: dStr(profile["id"])) {
            return mergeAt("profiles", i, profile, stamp: now)
        }
        let p = profile
        func orNull(_ k: String) -> JSON { dOr(p[k], .null) }
        var rec: JSON = [:]
        rec["id"] = .string(newId())
        rec["name"] = dOr(p["name"], dOr(p["alias"], dOr(p["node"], "Untitled")))
        rec["folderId"] = orNull("folderId")
        rec["type"] = dOr(p["type"], "ssh")
        for k in ["alias", "hostname", "user", "port", "identityFile", "proxyJump", "direct",
                  "proxy", "cluster", "home", "node", "login",
                  "path", "baudRate", "dataBits", "parity", "stopBits"] { rec[k] = orNull(k) }
        rec["rtscts"] = .bool(p["rtscts"].truthy)
        rec["xon"] = .bool(p["xon"].truthy)
        rec["xoff"] = .bool(p["xoff"].truthy)
        rec["host"] = orNull("host")
        rec["devicePort"] = orNull("devicePort")
        rec["newline"] = orNull("newline")
        rec["localEcho"] = .bool(p["localEcho"].truthy)
        rec["viewOnly"] = .bool(p["viewOnly"].truthy)
        rec["scaling"] = orNull("scaling")
        rec["quality"] = p["quality"]            // `?? null`: 0 is kept
        rec["username"] = orNull("username")
        rec["domain"] = orNull("domain")
        rec["fullscreen"] = .bool(p["fullscreen"].truthy)
        rec["width"] = orNull("width")
        rec["height"] = orNull("height")
        rec["clipboard"] = .bool(p["clipboard"] != .bool(false))
        rec["drives"] = .bool(p["drives"].truthy)
        rec["gateway"] = orNull("gateway")
        rec["color"] = orNull("color")
        rec["tags"] = dOr(p["tags"], .array([]))
        rec["startupCommand"] = dOr(p["startupCommand"], "")
        rec["remoteStartPath"] = dOr(p["remoteStartPath"], "")
        rec["localStartPath"] = dOr(p["localStartPath"], "")
        rec["notes"] = dOr(p["notes"], "")
        rec["createdAt"] = .number(now)
        rec["updatedAt"] = .number(now)
        rec["lastUsed"] = .null
        rec["useCount"] = 0
        append("profiles", rec)
        return rec
    }

    func deleteProfile(_ id: String) {
        let before = recs("profiles")
        let after = before.filter { $0["id"].string != id }
        if after.count != before.count { setRecs("profiles", after) }
    }

    /// store.js `markUsed`.
    func markProfileUsed(_ id: String?) {
        guard let id, let i = index("profiles", id: id) else { return }
        var list = recs("profiles")
        list[i]["lastUsed"] = .number(nowMs())
        list[i]["useCount"] = .number(dNum(list[i]["useCount"]) + 1)
        setRecs("profiles", list)
    }

    // MARK: - Profile folders

    func listFolders() -> [JSON] { recs("folders") }

    @discardableResult
    func upsertFolder(_ folder: JSON) -> JSON {
        if let i = index("folders", id: dStr(folder["id"])) {
            return mergeAt("folders", i, folder, stamp: nil)
        }
        let rec: JSON = ["id": .string(newId("f")), "name": dOr(folder["name"], "New folder"),
                         "parentId": dOr(folder["parentId"], .null)]
        append("folders", rec)
        return rec
    }

    func deleteFolder(_ id: String) {
        setRecs("folders", recs("folders").filter { $0["id"].string != id })
        var list = recs("profiles")
        for i in list.indices where list[i]["folderId"].string == id { list[i]["folderId"] = .null }
        setRecs("profiles", list)
    }

    // MARK: - Session history

    /// Record that a session opened. Kept locally so the timeline covers plain
    /// SSH hosts too, which Teleport's audit log never sees. Newest first, at
    /// most 500.
    @discardableResult
    func startHistory(_ entry: JSON) -> JSON {
        var rec: JSON = ["id": .string(newId("h")), "type": entry["type"], "label": entry["label"]]
        for k in ["target", "cluster", "proxy", "node", "home", "login", "user", "hostname", "direct"] {
            rec[k] = dOr(entry[k], .null)
        }
        rec["startedAt"] = .number(nowMs())
        rec["endedAt"] = .null
        rec["error"] = .null
        var list = recs("history")
        list.insert(rec, at: 0)
        if list.count > historyLimit { list = Array(list.prefix(historyLimit)) }
        setRecs("history", list)
        return rec
    }

    @discardableResult
    func endHistory(_ id: String, error: String? = nil) -> JSON? {
        var list = recs("history")
        guard let i = list.firstIndex(where: { $0["id"].string == id }), !list[i]["endedAt"].truthy else { return nil }
        list[i]["endedAt"] = .number(nowMs())
        if let error, !error.isEmpty { list[i]["error"] = .string(error) }
        setRecs("history", list)
        return list[i]
    }

    func listHistory(limit: Int = 200) -> [JSON] { Array(recs("history").prefix(max(0, limit))) }

    /// The last few distinct places you connected, newest first.
    func listRecent(limit: Int = 20) -> [JSON] { Store.listRecent(recs("history"), limit: limit) }

    /// `listRecent` over a given history (pure): one entry per destination —
    /// the port is part of a direct host's identity — keeping the newest
    /// record but remembering whether it has ever worked.
    nonisolated static func listRecent(_ history: [JSON], limit: Int) -> [JSON] {
        if limit <= 0 { return [] }
        var order: [String] = []
        var seen: [String: JSON] = [:]
        for h in history {
            let key = [dStr(h["type"]), dStr(h["cluster"]), dStr(dOr(h["node"], dOr(h["target"], h["label"]))),
                       dStr(h["login"]), dStr(h["home"]), dStr(h["direct"]["port"])].joined(separator: "\u{0}")
            if var rec = seen[key] {
                if rec["error"].truthy && !h["error"].truthy { rec["error"] = .null; rec["lastOkAt"] = h["startedAt"] }
                rec["count"] = .number(dNum(rec["count"]) + 1)
                seen[key] = rec
                continue
            }
            var rec: JSON = ["key": .string(key), "type": h["type"], "label": h["label"]]
            for k in ["target", "cluster", "proxy", "node", "home", "login", "user", "hostname", "direct"] {
                rec[k] = dOr(h[k], .null)
            }
            rec["at"] = h["startedAt"]
            rec["lastOkAt"] = h["error"].truthy ? .null : h["startedAt"]
            rec["error"] = dOr(h["error"], .null)
            rec["count"] = 1
            seen[key] = rec
            order.append(key)
            if seen.count >= limit { break }
        }
        return order.compactMap { seen[$0] }
    }

    func clearHistory() { setRecs("history", []) }

    // MARK: - Window snapshots (workspace / workspaces)

    /// Store (or, with nil, drop) one window's layout by slot. `workspace` is
    /// kept in step with slot w1 for older builds.
    @discardableResult
    func saveWorkspace(_ ws: JSON?, slot: String = "w1") -> JSON? {
        var all = self["workspaces"]
        if all.object == nil { all = .object([:]) }
        if let ws, ws.truthy {
            var w = ws
            w["slot"] = .string(slot)
            w["savedAt"] = .number(nowMs())
            all[slot] = w
        } else {
            all.removeKey(slot)
        }
        self["workspaces"] = all
        if slot == "w1" { self["workspace"] = dOr(all["w1"], .null) }
        let w = all[slot]
        return w.truthy ? w : JSON?.none
    }

    func getWorkspace(_ slot: String = "w1") -> JSON? {
        let w = self["workspaces"][slot]
        return w.truthy ? w : JSON?.none
    }

    /// Every saved window with something in it, in slot order.
    func listWorkspaces() -> [JSON] { Store.workspaceList(self["workspaces"]) }

    nonisolated static func workspaceList(_ all: JSON) -> [JSON] {
        let o = all.entries
        return o.keys.filter { o[$0]!.truthy && !o[$0]!["tabs"].items.isEmpty }
            .sorted { (Double($0.dropFirst()) ?? 0) < (Double($1.dropFirst()) ?? 0) }
            .compactMap { o[$0] }
    }

    /// One slot, or (nil) every slot.
    func clearWorkspace(_ slot: String? = nil) {
        var all = self["workspaces"]
        if all.object == nil { all = .object([:]) }
        if let slot, !slot.isEmpty { all.removeKey(slot) } else { all = .object([:]) }
        self["workspaces"] = all
        if slot == nil || slot == "" || slot == "w1" { self["workspace"] = .null }
    }

    // MARK: - Named layouts

    func listLayouts() -> [JSON] {
        let def = self["defaultLayoutId"]
        return recs("layouts").map { l in
            var o = l
            o["isDefault"] = .bool(!def.isNull && l["id"] == def)
            return o
        }
    }

    func getLayout(_ id: String?) -> JSON? {
        guard let id else { return nil }
        return recs("layouts").first { $0["id"].string == id }
    }

    /// Save (or overwrite by id, else by name, case-insensitively) a named layout.
    @discardableResult
    func saveLayout(id: String? = nil, name: String, workspace: JSON) -> JSON {
        let now = nowMs()
        var list = recs("layouts")
        let at: Int? = (id?.isEmpty == false)
            ? list.firstIndex { $0["id"].string == id }
            : list.firstIndex { ($0["name"].stringish ?? "").lowercased() == name.lowercased() }
        let def = self["defaultLayoutId"]
        if let at {
            var e = list[at]
            if !name.isEmpty { e["name"] = .string(name) }
            e["workspace"] = workspace
            e["updatedAt"] = .number(now)
            list[at] = e
            setRecs("layouts", list)
            e["isDefault"] = .bool(!def.isNull && e["id"] == def)
            return e
        }
        var rec: JSON = ["id": .string(newId("l")), "name": .string(name.isEmpty ? "Layout" : name),
                         "workspace": workspace, "createdAt": .number(now), "updatedAt": .number(now)]
        list.append(rec)
        setRecs("layouts", list)
        rec["isDefault"] = false
        return rec
    }

    func deleteLayout(_ id: String) {
        setRecs("layouts", recs("layouts").filter { $0["id"].string != id })
        if self["defaultLayoutId"].string == id { self["defaultLayoutId"] = .null }
    }

    /// nil clears the default, so startup falls back to the snapshot.
    @discardableResult
    func setDefaultLayout(_ id: String?) -> String? {
        let keep = (id?.isEmpty == false) && getLayout(id) != nil
        self["defaultLayoutId"] = keep ? .string(id!) : .null
        return keep ? id : nil
    }

    func getDefaultLayout() -> JSON? { getLayout(self["defaultLayoutId"].string) }

    // MARK: - Command snippets

    func listSnippets() -> [JSON] { recs("snippets") }

    @discardableResult
    func upsertSnippet(_ sn: JSON) -> JSON {
        let now = nowMs()
        if let i = index("snippets", id: dStr(sn["id"])) { return mergeAt("snippets", i, sn, stamp: now) }
        let command = dStr(sn["command"])
        let rec: JSON = [
            "id": .string(newId("s")),
            "name": dOr(sn["name"], dOr(.string(dSlice(command.components(separatedBy: "\n")[0], 40)), "Snippet")),
            "command": .string(command),
            "tags": dOr(sn["tags"], .array([])),
            "runOnOpen": .bool(sn["runOnOpen"].truthy),
            "createdAt": .number(now),
            "updatedAt": .number(now),
            "useCount": 0,
        ]
        append("snippets", rec)
        return rec
    }

    func deleteSnippet(_ id: String) { remove("snippets", id) }

    func markSnippetUsed(_ id: String) { _ = bumpUse("snippets", id) }

    // MARK: - Macros

    /// `{ macros, hidden, categoryOrder, pins }`.
    func listMacros() -> JSON {
        ["macros": .array(recs("macros")), "hidden": .array(recs("hiddenMacros")),
         "categoryOrder": .array(recs("macroCategoryOrder")), "pins": .array(recs("macroPins"))]
    }

    /// Pin a macro as a session-header button, or unpin it. A new pin is
    /// appended; re-pinning keeps its place and changes only icon and scope.
    /// A pin with no scope means hosts only.
    @discardableResult
    func setMacroPin(_ id: String, pinned: Bool = true, icon: String = "", where scopeIn: String? = nil) -> [JSON] {
        var pins = recs("macroPins")
        guard !id.isEmpty else { return pins }
        let scope = ["all", "hosts", "local"].contains(scopeIn ?? "") ? scopeIn : nil
        let at = pins.firstIndex { $0["id"].string == id }
        let iconCut = dSlice(icon, 8)
        if !pinned {
            if let at { pins.remove(at: at) }
        } else if let at {
            pins[at]["icon"] = .string(iconCut)
            pins[at]["where"] = scope.map { .string($0) } ?? dOr(pins[at]["where"], "hosts")
        } else {
            pins.append(["id": .string(id), "icon": .string(iconCut), "where": .string(scope ?? "hosts")])
        }
        setRecs("macroPins", pins)
        return pins
    }

    @discardableResult
    func setMacroCategoryOrder(_ order: [String]) -> [String] {
        var out: [String] = []
        for c in order where !c.isEmpty && !out.contains(c) { out.append(c) }
        setRecs("macroCategoryOrder", out.map { .string($0) })
        return out
    }

    @discardableResult
    func upsertMacro(_ m: JSON) -> JSON {
        let now = nowMs()
        if let i = index("macros", id: dStr(m["id"])) { return mergeAt("macros", i, m, stamp: now) }
        let command = dStr(m["command"])
        let whereV = m["where"].string ?? ""
        let rec: JSON = [
            "id": .string(newId("m")),
            "name": dOr(m["name"], dOr(.string(dSlice(command.components(separatedBy: "\n")[0], 40)), "Macro")),
            "command": .string(command),
            "description": dOr(m["description"], ""),
            "category": dOr(m["category"], "Custom"),
            "confirm": .bool(m["confirm"].truthy),
            "interactive": .bool(m["interactive"].truthy),
            "noEnter": .bool(m["noEnter"].truthy),
            "where": .string(["all", "hosts", "local"].contains(whereV) ? whereV : "all"),
            "variables": m["variables"].array.map { .array($0) } ?? .array([]),
            "variableSpec": dOr(m["variableSpec"], ""),
            "repeatSeconds": .number(max(0, (dNum(m["repeatSeconds"]) + 0.5).rounded(.down))),
            "createdAt": .number(now),
            "updatedAt": .number(now),
            "useCount": 0,
        ]
        append("macros", rec)
        return rec
    }

    /// Deleting a macro drops its pin, so no button points at nothing.
    func deleteMacro(_ id: String) {
        remove("macros", id)
        let pins = recs("macroPins")
        if pins.contains(where: { $0["id"].string == id }) { setRecs("macroPins", pins.filter { $0["id"].string != id }) }
    }

    /// Dismiss (or restore) one of the built-ins (`new Set(...)`: insertion
    /// order, no duplicates).
    @discardableResult
    func setMacroHidden(_ id: String, _ hidden: Bool) -> [String] {
        var set: [String] = []
        for x in recs("hiddenMacros").compactMap(\.stringish) where !set.contains(x) { set.append(x) }
        if hidden { if !set.contains(id) { set.append(id) } } else { set.removeAll { $0 == id } }
        setRecs("hiddenMacros", set.map { .string($0) })
        return set
    }

    @discardableResult
    func markMacroUsed(_ id: String) -> JSON? { bumpUse("macros", id) }

    // MARK: - S3 buckets

    func listS3Targets() -> [JSON] { recs("s3Targets") }

    func getS3Target(_ id: String) -> JSON? { recs("s3Targets").first { $0["id"].string == id } }

    /// The whole record is rewritten; only `createdAt` survives an update.
    @discardableResult
    func upsertS3Target(_ t: JSON) -> JSON {
        let now = nowMs()
        var list = recs("s3Targets")
        let i = index("s3Targets", id: dStr(t["id"]))
        let rec: JSON = [
            "id": dOr(t["id"], .string(newId("s3"))),
            "name": dOr(t["name"], dOr(t["bucket"], "S3")),
            "bucket": dOr(t["bucket"], ""),
            "region": dOr(t["region"], ""),
            "prefix": dOr(t["prefix"], ""),
            "endpoint": dOr(t["endpoint"], ""),
            "pathStyle": .bool(t["pathStyle"].truthy),
            "defaultStorageClass": dOr(t["defaultStorageClass"], "STANDARD"),
            "credentials": dOr(t["credentials"], ["mode": "env"]),
            "createdAt": i.map { list[$0]["createdAt"] } ?? .number(now),
            "updatedAt": .number(now),
        ]
        if let i { list[i] = rec } else { list.append(rec) }
        setRecs("s3Targets", list)
        return rec
    }

    func deleteS3Target(_ id: String) { remove("s3Targets", id) }

    // MARK: - Downloads

    /// Remember a completed download. One row per local path (an existing row
    /// is merged and moved to the top), newest first, at most 300.
    @discardableResult
    func addDownload(_ rec: JSON) -> JSON? {
        let now = nowMs()
        let localPath = dStr(rec["localPath"])
        if localPath.isEmpty { return nil }
        var list = recs("downloads")
        if let match = list.firstIndex(where: { $0["localPath"].string == localPath }) {
            var merged = list.remove(at: match)
            merged.merge(rec)
            merged["at"] = .number(now)
            list.insert(merged, at: 0)
            setRecs("downloads", list)
            return merged
        }
        let last = localPath.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let row: JSON = [
            "id": .string(newId("dl")),
            "localPath": .string(localPath),
            "name": dOr(rec["name"], .string(last)),
            "source": dOr(rec["source"], ""),
            "from": dOr(rec["from"], ""),
            "kind": dOr(rec["kind"], "file"),
            "bytes": .number(dNum(rec["bytes"])),
            "files": .number(dNum(rec["files"], 1)),
            "at": .number(now),
        ]
        list.insert(row, at: 0)
        if list.count > 300 { list = Array(list.prefix(300)) }
        setRecs("downloads", list)
        return row
    }

    func listDownloads() -> [JSON] { dSortedDesc(recs("downloads")) { $0["at"].truthy ? ($0["at"].double ?? 0) : 0 } }

    func deleteDownload(_ id: String) { remove("downloads", id) }

    func clearDownloads() { setRecs("downloads", []) }

    // MARK: - Multi-exec history

    /// Remember a run. The same command on the same hosts (in any order)
    /// replaces its earlier entry. Newest first, at most 40.
    @discardableResult
    func addExecRun(_ rec: JSON) -> JSON? {
        let command = dStr(rec["command"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty { return nil }
        let hostIds = rec["hostIds"].items.filter(\.truthy)
        func key(_ cmd: String, _ ids: [JSON]) -> String {
            cmd + "\u{0}" + ids.map { $0.stringish ?? "" }.sorted().joined(separator: ",")
        }
        let k = key(command, hostIds)
        let sel = rec["selector"]
        let row: JSON = [
            "id": .string(newId("mx")),
            "command": .string(command),
            "label": .string(dStr(rec["label"])),
            "runAs": dOr(rec["runAs"], .null),
            "hosts": .array(Array(rec["hosts"].items.prefix(60))),
            "hostIds": .array(Array(hostIds.prefix(60))),
            "selector": (sel.object != nil || sel.array != nil)
                ? ["proxy": dOr(sel["proxy"], ""), "query": .string(dStr(sel["query"]))] : .null,
            "ok": .number(dNum(rec["ok"])),
            "failed": .number(dNum(rec["failed"])),
            "at": .number(nowMs()),
        ]
        var runs = recs("execRuns").filter { key($0["command"].stringish ?? "", $0["hostIds"].items) != k }
        runs.insert(row, at: 0)
        if runs.count > 40 { runs = Array(runs.prefix(40)) }
        setRecs("execRuns", runs)
        return row
    }

    func listExecRuns() -> [JSON] { recs("execRuns") }

    func deleteExecRun(_ id: String) { remove("execRuns", id) }

    func clearExecRuns() { setRecs("execRuns", []) }

    // MARK: - Network tools

    /// `{ hostId, label, type }` — where a request or run happened, by host.
    fileprivate func netHostRef(_ on: JSON) -> JSON {
        guard on.object != nil else { return .null }
        return ["hostId": dOr(on["hostId"], .null), "label": .string(dStr(on["label"])), "type": dOr(on["type"], "ssh")]
    }

    /// Saved requests, most recently run (or saved) first.
    func listNetRequests() -> [JSON] { dSortedDesc(recs("netRequests")) { dTime($0["lastRunAt"], $0["savedAt"]) } }

    /// Save (or update) a named request; an update keeps the first `savedAt`.
    @discardableResult
    func saveNetRequest(_ rec: JSON) -> JSON {
        let id = dOr(rec["id"], .string(newId("req")))
        let name = dStr(rec["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var row: JSON = [
            "id": id,
            "name": .string(name.isEmpty ? (rec["target"].truthy ? dStr(rec["target"]) : "Request") : name),
            "tool": dOr(rec["tool"], "curl"),
            "target": .string(dStr(rec["target"])),
            "opts": (rec["opts"].object != nil || rec["opts"].array != nil) ? rec["opts"] : .object([:]),
            "on": netHostRef(rec["on"]),
            "savedAt": .number(nowMs()),
            "lastRunAt": dOr(rec["lastRunAt"], .null),
        ]
        var list = recs("netRequests")
        if let at = list.firstIndex(where: { $0["id"] == id }) {
            row["savedAt"] = dOr(list[at]["savedAt"], row["savedAt"])
            list[at] = row
        } else {
            list.append(row)
        }
        setRecs("netRequests", list)
        return row
    }

    func deleteNetRequest(_ id: String) { remove("netRequests", id) }

    /// Remember a run of any tool. Newest first, at most 25.
    ///
    /// store.js builds a three-part key (tool, target, host) but compares it
    /// with a two-part one (tool, target), so in practice nothing is ever
    /// replaced and "Recent" is every run — which is what GUIDE.md says it
    /// is. Ported as written so both apps keep the same list.
    @discardableResult
    func addNetRun(_ rec: JSON) -> JSON {
        let key = "\(dStr(rec["tool"]))\u{0}\(dStr(rec["target"]))\u{0}\(dStr(dOr(rec["on"]["hostId"], rec["on"]["label"])))"
        let row: JSON = [
            "id": .string(newId("run")),
            "tool": dOr(rec["tool"], ""),
            "target": .string(dStr(rec["target"])),
            "opts": (rec["opts"].object != nil || rec["opts"].array != nil) ? rec["opts"] : .object([:]),
            "ok": .bool(rec["ok"] != .bool(false)),
            "summary": .string(dSlice(dStr(rec["summary"]), 160)),
            "on": netHostRef(rec["on"]),
            "at": .number(nowMs()),
        ]
        var runs = recs("netRuns").filter { "\($0["tool"].stringish ?? "undefined")\u{0}\($0["target"].stringish ?? "undefined")" != key }
        runs.insert(row, at: 0)
        if runs.count > 25 { runs = Array(runs.prefix(25)) }
        setRecs("netRuns", runs)
        return row
    }

    func listNetRuns() -> [JSON] { recs("netRuns") }

    func clearNetRuns() { setRecs("netRuns", []) }

    // MARK: - Favourite port forwards

    func listForwardFavorites() -> [JSON] { recs("forwardFavorites") }

    /// Keep a forward. One per host + listen port + kind: a second star of the
    /// same tunnel updates it, keeping its id, createdAt and lastUsedAt.
    @discardableResult
    func addForwardFavorite(_ rec: JSON) throws -> JSON {
        let kind = ["L", "R", "D"].contains(rec["kind"].string ?? "") ? rec["kind"].string! : "L"
        let bindPort = dNum(rec["bindPort"])
        if bindPort == 0 { throw AppError("A favourite needs a listen port") }
        guard rec["host"].object != nil else { throw AppError("A favourite needs the host to open it on") }
        let host = rec["host"]
        var row: JSON = [
            "id": .string(newId("fwd")),
            "name": .string(dStr(rec["name"]).trimmed),
            "kind": .string(kind),
            "bindPort": .number(bindPort),
            "bindAddr": .string(dStr(rec["bindAddr"]).trimmed),
            "destHost": .string(kind == "D" ? "" : dStr(rec["destHost"]).trimmed),
            "destPort": .number(kind == "D" ? 0 : dNum(rec["destPort"])),
            "host": host,
            "login": dOr(rec["login"], .null),
            "createdAt": .number(nowMs()),
            "lastUsedAt": .null,
        ]
        var list = recs("forwardFavorites")
        if let at = list.firstIndex(where: { $0["host"]["id"] == host["id"] && $0["bindPort"] == .number(bindPort)
                                            && $0["kind"].string == kind }) {
            row["id"] = list[at]["id"]
            row["createdAt"] = dOr(list[at]["createdAt"], row["createdAt"])
            row["lastUsedAt"] = dOr(list[at]["lastUsedAt"], .null)
            list[at] = row
        } else {
            list.append(row)
        }
        setRecs("forwardFavorites", list)
        return row
    }

    @discardableResult
    func updateForwardFavorite(_ id: String, _ patch: JSON) -> JSON? {
        guard let at = index("forwardFavorites", id: id) else { return nil }
        var list = recs("forwardFavorites")
        var row = list[at]
        row.merge(patch)
        row["id"] = .string(id)
        list[at] = row
        setRecs("forwardFavorites", list)
        return row
    }

    @discardableResult
    func markForwardFavoriteUsed(_ id: String) -> JSON? {
        updateForwardFavorite(id, ["lastUsedAt": .number(nowMs())])
    }

    func deleteForwardFavorite(_ id: String) { remove("forwardFavorites", id) }

    // MARK: - Flagged sessions and notes

    func listSessionNotes() -> [JSON] { dSortedDesc(recs("sessionNotes")) { dTime($0["updatedAt"], .null) } }

    /// Flag a session, note it, or both. A record with neither a flag nor a
    /// note is deleted rather than kept as an empty row.
    @discardableResult
    func upsertSessionNote(_ rec: JSON) -> JSON? {
        let sid = dStr(rec["sid"])
        if sid.isEmpty { return nil }
        var list = recs("sessionNotes")
        let at = list.firstIndex { $0["sid"].stringish == sid }
        // `rec.note ?? existing.note ?? ''`
        let noteV = !rec["note"].isNull ? rec["note"] : (at.map { list[$0]["note"] } ?? .null)
        let note = noteV.isNull ? "" : (noteV.stringish ?? "")
        // `rec.flagged === undefined` — only a missing key falls back.
        let flagged = rec.entries["flagged"] == nil ? (at.map { list[$0]["flagged"].truthy } ?? false) : rec["flagged"].truthy
        if !flagged && note.trimmed.isEmpty {
            if let at { list.remove(at: at); setRecs("sessionNotes", list) }
            return nil
        }
        let base: JSON = at.map { list[$0] } ?? ["sid": .string(sid), "createdAt": .number(nowMs())]
        var next = base
        next["sid"] = .string(sid)
        next["flagged"] = .bool(flagged)
        next["note"] = .string(note)
        for (k, fallback) in [("cluster", JSON.string("")), ("proxy", ""), ("home", .null), ("node", ""), ("user", ""),
                              ("login", ""), ("startedAt", .null), ("durationMs", .null), ("playable", true)] {
            next[k] = !rec[k].isNull ? rec[k] : (!base[k].isNull ? base[k] : fallback)
        }
        next["updatedAt"] = .number(nowMs())
        if let at { list[at] = next } else { list.append(next) }
        setRecs("sessionNotes", list)
        return next
    }

    @discardableResult
    func deleteSessionNote(_ sid: String) -> [JSON] {
        remove("sessionNotes", where: "sid", sid)
        return listSessionNotes()
    }

    // MARK: - Saved cluster logins

    /// Most recently used (or updated) first.
    func listTshLogins() -> [JSON] { dSortedDesc(recs("tshLogins")) { dTime($0["lastUsed"], $0["updatedAt"]) } }

    /// One record per proxy + user + home (or, with an id, that record).
    @discardableResult
    func upsertTshLogin(_ t: JSON) -> JSON {
        let now = nowMs()
        let list = recs("tshLogins")
        let match: Int? = t["id"].truthy
            ? list.firstIndex { $0["id"] == t["id"] }
            : list.firstIndex { $0["proxy"] == t["proxy"] && dOr($0["user"], "") == dOr(t["user"], "")
                && dOr($0["home"], "") == dOr(t["home"], "") }
        if let match { return mergeAt("tshLogins", match, t, stamp: now) }
        let rec: JSON = [
            "id": .string(newId("tl")),
            "name": dOr(t["name"], dOr(t["cluster"], dOr(t["proxy"], "Cluster"))),
            "proxy": dOr(t["proxy"], ""),
            "cluster": dOr(t["cluster"], ""),
            "user": dOr(t["user"], ""),
            "authConnector": dOr(t["authConnector"], ""),
            "home": dOr(t["home"], ""),
            "ttl": dOr(t["ttl"], ""),
            "mfaMode": dOr(t["mfaMode"], ""),
            "autoLogin": .bool(t["autoLogin"].truthy),
            "createdAt": .number(now),
            "updatedAt": .number(now),
            "lastUsed": 0,
            "useCount": 0,
        ]
        append("tshLogins", rec)
        return rec
    }

    func deleteTshLogin(_ id: String) { remove("tshLogins", id) }

    @discardableResult
    func markTshLoginUsed(_ id: String) -> JSON? { bumpUse("tshLogins", id) }

    // MARK: - Saved access requests

    /// Matched on proxy *or* cluster (a proxy's spelling can change between
    /// logins); most recently used (or updated) first.
    func listRequestTemplates(proxy: String? = nil, cluster: String? = nil) -> [JSON] {
        var out = recs("requestTemplates")
        let px = proxy?.nilIfEmpty, cl = cluster?.nilIfEmpty
        if px != nil || cl != nil {
            out = out.filter { (px != nil && $0["proxy"].string == px) || (cl != nil && $0["cluster"].string == cl) }
        }
        return dSortedDesc(out) { dTime($0["lastUsed"], $0["updatedAt"]) }
    }

    /// Keep only what replaying a request needs: id, kind, name, cluster.
    /// Labels are dropped — they go stale and nothing replays them.
    nonisolated static func trimRequestResources(_ resources: JSON) -> JSON {
        .array(resources.items.compactMap { r -> JSON? in
            guard r["id"].truthy else { return nil }
            var o: JSON = ["id": r["id"]]
            if r.entries["kind"] != nil { o["kind"] = r["kind"] }   // undefined is dropped by JSON.stringify
            o["name"] = dOr(r["name"], "")
            o["cluster"] = dOr(r["cluster"], "")
            return o
        })
    }

    @discardableResult
    func upsertRequestTemplate(_ t0: JSON) -> JSON {
        let now = nowMs()
        var t = t0
        if t["resources"].array != nil { t["resources"] = Store.trimRequestResources(t["resources"]) }
        if let i = index("requestTemplates", id: dStr(t["id"])) { return mergeAt("requestTemplates", i, t, stamp: now) }
        let rec: JSON = [
            "id": .string(newId("rq")),
            "name": dOr(t["name"], "Saved request"),
            "proxy": dOr(t["proxy"], ""),
            "cluster": dOr(t["cluster"], ""),
            "roles": t["roles"].array.map { .array($0) } ?? .array([]),
            "resources": Store.trimRequestResources(t["resources"]),
            "reason": dOr(t["reason"], ""),
            "reviewers": t["reviewers"].array.map { .array($0) } ?? .array([]),
            "requestTtl": dOr(t["requestTtl"], ""),
            "maxDuration": dOr(t["maxDuration"], ""),
            "sessionTtl": dOr(t["sessionTtl"], ""),
            "createdAt": .number(now),
            "updatedAt": .number(now),
            "useCount": 0,
        ]
        append("requestTemplates", rec)
        return rec
    }

    func deleteRequestTemplate(_ id: String) { remove("requestTemplates", id) }

    @discardableResult
    func markRequestTemplateUsed(_ id: String) -> JSON? { bumpUse("requestTemplates", id) }
}
