import Foundation

// The folder model: the non-dialog half of src/renderer/js/folders.js.
//
// Folders inside a cluster, and inside an ssh_config. Two ways in, and a
// folder can use both at once:
//
//   by hand    drag a node onto the folder. Kept by the node's UUID (its
//              `prefKey`), never its hostname.
//   by rule    a tag query (`Tags.compileQuery`, the boolean one) the folder
//              re-asks every time the inventory changes.
//
// A node that has been filed stops appearing loose in its group's list; the
// group's menu can put them back (`showFiledHosts`).
//
// Stored exactly as the original: `settings.hostFolders` (array of
// `{id, name, group, parent, rule, icon, color}`) and `settings.folderMembers`
// (`{folderId: {in: [hostKey], out: [hostKey]}}`). The dialogs and the folder
// browser are the hosts owner's; they build on this.

/// One folder (`settings.hostFolders[i]`).
struct HostFolder: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// The group key it belongs to (`FolderModel.groupKey(for:)`, "ssh", a config path …).
    var group: String
    var parent: String?
    var rule: String
    var icon: String
    var color: String
    /// Anything else a stored folder carried.
    var extra: [String: JSON] = [:]

    init(id: String, name: String, group: String, parent: String? = nil, rule: String = "", icon: String = "", color: String = "") {
        self.id = id; self.name = name; self.group = group; self.parent = parent
        self.rule = rule; self.icon = icon; self.color = color
    }

    init(json j: JSON) {
        id = j["id"].stringish ?? ""
        name = j["name"].stringish ?? ""
        group = j["group"].stringish ?? ""
        parent = j["parent"].stringish?.nilIfEmpty
        rule = j["rule"].string ?? ""
        icon = j["icon"].string ?? ""
        color = j["color"].string ?? ""
        for (k, v) in j.entries where !["id", "name", "group", "parent", "rule", "icon", "color"].contains(k) { extra[k] = v }
    }

    var json: JSON {
        var o = extra
        o["id"] = .string(id); o["name"] = .string(name); o["group"] = .string(group)
        o["parent"] = parent.map { .string($0) } ?? .null
        o["rule"] = .string(rule); o["icon"] = .string(icon); o["color"] = .string(color)
        return .object(o)
    }
}

/// `folderMembers[id]`: hand-filed host keys, and keys a rule must not claim.
struct FolderMembers: Hashable, Sendable {
    var `in`: [String] = []
    var out: [String] = []
    init(in i: [String] = [], out: [String] = []) { self.in = i; self.out = out }
    init(json j: JSON) { self.in = j["in"].items.compactMap(\.stringish); out = j["out"].items.compactMap(\.stringish) }
    var json: JSON { ["in": JSON(self.in), "out": JSON(out)] }
}

@MainActor
enum FolderModel {
    // MARK: Identity

    /// The key a host is filed under — the same key every per-host preference
    /// uses (`hostKey` / `hostPrefKey`): uuid, else `tsh:<cluster>:<name>`,
    /// else its id, else `ssh:<alias>`.
    nonisolated static func hostKey(_ host: Host?) -> String { host?.prefKey ?? "" }

    /// The key a group of hosts is known by (`groupKeyFor`): `tp:<proxy>`,
    /// plus `@<home>` for a profile from a non-default tsh home.
    nonisolated static func groupKey(for p: TeleportProfile?) -> String {
        guard let p else { return "" }
        return "tp:" + p.proxy + ((p.home?.isEmpty == false) ? "@" + p.home! : "")
    }

    /// The same, from a host (proxy + home), for a node not yet matched to a profile.
    nonisolated static func groupKey(proxy: String, home: String?) -> String {
        "tp:" + proxy + ((home?.isEmpty == false) ? "@" + home! : "")
    }

    // MARK: Reading


    static func allFolders() -> [HostFolder] {
        SB.store.settingJSON("hostFolders").items.map(HostFolder.init(json:))
    }

    static func folder(id: String?) -> HostFolder? {
        guard let id else { return nil }
        return allFolders().first { $0.id == id }
    }

    /// The folders directly under `parent` in one group, by name
    /// (case-insensitive, numeric).
    static func folders(in groupKey: String, parent: String? = nil) -> [HostFolder] {
        allFolders()
            .filter { $0.group == groupKey && $0.parent == parent?.nilIfEmpty }
            .sorted { namesAscending($0.name, $1.name) }
    }

    /// Does this group have any folders at all?
    static func groupHasFolders(_ groupKey: String) -> Bool {
        allFolders().contains { $0.group == groupKey }
    }

    static func childFolders(_ id: String) -> [HostFolder] {
        allFolders().filter { $0.parent == id }
    }

    /// Ancestors first, this folder last — a breadcrumb.
    static func folderPath(_ folder: HostFolder) -> [HostFolder] {
        var out: [HostFolder] = []
        var f: HostFolder? = folder
        var seen = Set<String>()
        let all = allFolders()
        while let cur = f, !seen.contains(cur.id) {
            seen.insert(cur.id)
            out.insert(cur, at: 0)
            f = cur.parent.flatMap { p in all.first { $0.id == p } }
        }
        return out
    }

    /// "Top / Mid / Leaf".
    static func pathLabel(_ folder: HostFolder) -> String {
        folderPath(folder).map(\.name).joined(separator: " / ")
    }

    /// The top-level folder this one sits under — itself, if it is one.
    static func rootOf(_ folder: HostFolder) -> HostFolder {
        folderPath(folder).first ?? folder
    }

    static func members(_ id: String) -> FolderMembers {
        FolderMembers(json: SB.store.settingJSON("folderMembers")[id])
    }

    /// Compiled rules (`Tags.compileQuery` caches by text). nil for no rule
    /// or one with nothing in it.
    static func rule(for folder: HostFolder?) -> CompiledQuery? {
        guard let r = folder?.rule, !r.isEmpty else { return nil }
        let c = Tags.compileQuery(r)
        return c.empty ? nil : c
    }

    /// The hosts in this folder itself: filed by hand, plus what its rule
    /// claims, less anything explicitly taken out.
    static func hostsInFolder(_ folder: HostFolder?, _ hosts: [Host]) -> [Host] {
        guard let folder else { return [] }
        let m = members(folder.id)
        let manual = Set(m.in), excluded = Set(m.out)
        let r = rule(for: folder)
        return hosts.filter { h in
            let k = hostKey(h)
            if excluded.contains(k) { return false }
            return manual.contains(k) || (r?.match(h) ?? false)
        }
    }

    /// The same, including every subfolder, each host counted once.
    static func hostsInTree(_ folder: HostFolder, _ hosts: [Host]) -> [Host] {
        var seen = Set<String>()
        var out: [Host] = []
        func walk(_ f: HostFolder) {
            for h in hostsInFolder(f, hosts) {
                let k = hostKey(h)
                if seen.contains(k) { continue }
                seen.insert(k)
                out.append(h)
            }
            for c in childFolders(f.id) { walk(c) }
        }
        walk(folder)
        return out
    }

    /// Every folder in this group that holds this host, by hand or by rule.
    static func foldersForHost(_ host: Host, _ groupKey: String) -> [HostFolder] {
        let k = hostKey(host)
        return allFolders().filter { f in
            if f.group != groupKey { return false }
            let m = members(f.id)
            if m.out.contains(k) { return false }
            if m.in.contains(k) { return true }
            return rule(for: f)?.match(host) ?? false
        }
    }

    /// Is this host filed anywhere in its group — and so not loose any more?
    static func isFiled(_ host: Host, _ groupKey: String) -> Bool {
        !foldersForHost(host, groupKey).isEmpty
    }

    /// An icon of its own, else the open or shut folder glyph.
    nonisolated static func folderIcon(_ folder: HostFolder?, open: Bool = false) -> String {
        if let i = folder?.icon, !i.isEmpty { return i }
        return open ? "\u{1F4C2}" : "\u{1F4C1}"
    }

    /// Its colour as a hex string ("" for none), from the host colours.
    nonisolated static func folderColorHex(_ folder: HostFolder?) -> String {
        guard let c = folder?.color, !c.isEmpty else { return "" }
        return HostColor.all.first { $0.value == c }?.hex ?? ""
    }

    /// Whether a filed host is also still listed at the top of its group.
    static var showFiledHosts: Bool { SB.store.setting("showFiledHosts", false) }

    // MARK: Writing

    private static func save(_ patch: [String: JSON]) {
        SB.store.updateSettings(patch)
    }

    private static func saveFolders(_ folders: [HostFolder], members: [String: JSON]? = nil) {
        var patch: [String: JSON] = ["hostFolders": .array(folders.map(\.json))]
        if let members { patch["folderMembers"] = .object(members) }
        save(patch)
    }

    private static var membersMap: [String: JSON] { SB.store.settingJSON("folderMembers").entries }

    @discardableResult
    static func createFolder(name: String, group: String, parent: String? = nil, rule: String = "",
                             icon: String = "", color: String = "") -> HostFolder {
        let n = name.trimmed
        let folder = HostFolder(id: uid("fld"), name: n.isEmpty ? "New folder" : n, group: group,
                                parent: parent?.nilIfEmpty, rule: rule, icon: icon, color: color)
        saveFolders(allFolders() + [folder])
        return folder
    }

    /// Patch a folder: any of name, group, parent (pass "" for top level), rule, icon, color.
    static func updateFolder(_ id: String, name: String? = nil, group: String? = nil, parent: String?? = nil,
                             rule: String? = nil, icon: String? = nil, color: String? = nil) {
        saveFolders(allFolders().map { f in
            guard f.id == id else { return f }
            var g = f
            if let name { g.name = name }
            if let group { g.group = group }
            if let parent { g.parent = parent?.nilIfEmpty }
            if let rule { g.rule = rule }
            if let icon { g.icon = icon }
            if let color { g.color = color }
            return g
        })
    }

    /// Move a folder under a new parent, refusing loops. Returns false when refused.
    @discardableResult
    static func reparentFolder(_ id: String, _ parent: String?) -> Bool {
        if id == parent { return false }
        let target = parent.flatMap { folder(id: $0) }
        if parent != nil && target == nil { return false }
        if let target, folderPath(target).contains(where: { $0.id == id }) { return false }
        updateFolder(id, group: target?.group ?? folder(id: id)?.group, parent: .some(parent))
        return true
    }

    /// Ids of a folder and everything under it.
    static func subtreeIds(_ id: String) -> [String] {
        var out = [id]
        for c in childFolders(id) { out.append(contentsOf: subtreeIds(c.id)) }
        return out
    }

    /// Delete a folder and everything under it. Only the folders go.
    static func deleteFolder(_ id: String) {
        let ids = Set(subtreeIds(id))
        var map = membersMap
        for k in ids { map.removeValue(forKey: k) }
        saveFolders(allFolders().filter { !ids.contains($0.id) }, members: map)
    }

    /// Put a host in a folder by hand, clearing any exclusion that contradicts
    /// it. `removeFrom` folders lose it (a rule-held one gets an exclusion).
    static func fileHost(_ host: Host, _ folderId: String, removeFrom: [String] = []) {
        let k = hostKey(host)
        var map = membersMap
        let cur = members(folderId)
        map[folderId] = FolderMembers(in: cur.in.contains(k) ? cur.in : cur.in + [k], out: cur.out.filter { $0 != k }).json
        for other in removeFrom where other != folderId {
            let m = members(other)
            let byRule = !m.in.contains(k)
            map[other] = FolderMembers(in: m.in.filter { $0 != k },
                                       out: byRule ? (m.out.contains(k) ? m.out : m.out + [k]) : m.out).json
        }
        save(["folderMembers": .object(map)])
    }

    /// Take a host out of one folder; a rule match is excluded rather than removed.
    static func unfileHost(_ host: Host, _ folderId: String) {
        let k = hostKey(host)
        var map = membersMap
        let m = members(folderId)
        let byRule = !m.in.contains(k)
        map[folderId] = FolderMembers(in: m.in.filter { $0 != k },
                                      out: byRule ? (m.out.contains(k) ? m.out : m.out + [k]) : m.out).json
        save(["folderMembers": .object(map)])
    }

    /// Undo an exclusion, putting a rule's own match back.
    static func clearExclusion(_ host: Host, _ folderId: String) {
        let k = hostKey(host)
        var map = membersMap
        let m = members(folderId)
        map[folderId] = FolderMembers(in: m.in, out: m.out.filter { $0 != k }).json
        save(["folderMembers": .object(map)])
    }

    static func isExcluded(_ host: Host, _ folderId: String) -> Bool { members(folderId).out.contains(hostKey(host)) }

    /// In the folder because somebody put it there (vs by rule)?
    static func isManualMember(_ host: Host, _ folderId: String) -> Bool { members(folderId).in.contains(hostKey(host)) }

    static func setShowFiledHosts(_ on: Bool) { save(["showFiledHosts": .bool(on)]) }

    /// Put folders filed under a bare proxy address (0.6.0/0.6.1) back under
    /// the group key that draws them. Returns how many moved.
    @discardableResult
    static func repairFolderGroups(_ groupKeys: [String]) -> Int {
        let known = Set(groupKeys)
        if known.isEmpty { return 0 }
        var fixed = 0
        let out = allFolders().map { f -> HostFolder in
            if known.contains(f.group) { return f }
            let guess = "tp:" + f.group
            if !known.contains(guess) { return f }
            fixed += 1
            var g = f; g.group = guess
            return g
        }
        if fixed > 0 { saveFolders(out) }
        return fixed
    }

    // MARK: Dropping

    /// Asked when hosts dropped into a folder are already filed under a
    /// different root: "both", "move", or nil (cancel). The hosts owner may
    /// replace this with its own dialog (folders.js `askBothOrOne`).
    static var askBothOrOne: @MainActor (_ subject: String, _ folder: HostFolder, _ current: [HostFolder]) async -> String? = { subject, folder, current in
        let where_ = current.map(pathLabel)
        let r = await Modal.choose(title: "\(subject) is already filed",
                                   message: where_.joined(separator: " · ") + "\n\n"
                                       + "It is in \(where_.count == 1 ? "that folder" : "those folders") already. "
                                       + "Put it in “\(folder.name)” as well, or move it there?",
                                   buttons: ["Move it here", "List in both", "Cancel"])
        return r == 0 ? "move" : r == 1 ? "both" : nil
    }

    /// File hosts into a folder, asking the question when it needs asking
    /// (`fileHostsInto`): nothing filed elsewhere → straight in; filed in the
    /// same tree → moved; filed under another root → asked once per drop.
    @discardableResult
    static func fileHostsInto(_ hosts: [Host], _ folder: HostFolder?, _ groupKey: String) async -> (count: Int, mode: String)? {
        guard let folder, !hosts.isEmpty else { return nil }
        let targetRoot = rootOf(folder).id
        var others: [String: [HostFolder]] = [:]
        var crossRoot = 0
        for h in hosts {
            let cur = foldersForHost(h, groupKey).filter { $0.id != folder.id }
            others[hostKey(h)] = cur
            if cur.contains(where: { rootOf($0).id != targetRoot }) { crossRoot += 1 }
        }
        var mode = "move"
        if crossRoot > 0 {
            let subject = hosts.count == 1 ? (hosts[0].name.nilIfEmpty ?? hosts[0].alias ?? "") : "\(crossRoot) of \(hosts.count) hosts"
            var seen: [HostFolder] = []
            for list in others.values { for f in list where !seen.contains(where: { $0.id == f.id }) { seen.append(f) } }
            guard let answer = await askBothOrOne(subject, folder, seen) else { return nil }
            mode = answer
        }
        for h in hosts {
            let from = mode == "move" ? (others[hostKey(h)] ?? []).map(\.id) : []
            fileHost(h, folder.id, removeFrom: from)
        }
        return (hosts.count, mode)
    }

    // MARK: Export / import

    static let fileKind = "serverlife-folders"

    /// The arrangement as a file: folders, rules, membership — nothing else.
    static func exportData(_ groupKey: String? = nil) -> JSON {
        let folders = allFolders().filter { groupKey == nil || $0.group == groupKey }
        let all = membersMap
        var membersOut: [String: JSON] = [:]
        for f in folders { if let m = all[f.id] { membersOut[f.id] = m } }
        var groups: [String] = []
        for f in folders where !groups.contains(f.group) { groups.append(f.group) }
        return [
            "kind": .string(fileKind), "version": 1,
            "exportedAt": .string(TPText.isoString(ms: nowMs())),
            "app": .string(AppResources.version),
            "groups": JSON(groups),
            "folders": .array(folders.map(\.json)),
            "members": .object(membersOut),
        ]
    }

    static func parseImport(_ text: String) throws -> JSON {
        guard let data = try? JSON.parse(text) else { throw AppError("That file is not JSON.") }
        guard data["kind"].string == fileKind else { throw AppError("That is not a ServerLife folder export.") }
        guard data["folders"].array != nil else { throw AppError("The file has no folders in it.") }
        return data
    }

    /// Bring an exported arrangement in. `mode` "merge" or "replace" (clears
    /// the groups the file covers first). Ids are rewritten either way;
    /// `remap` lands every folder in another group.
    @discardableResult
    static func importData(_ data: JSON, mode: String = "merge", remap: String? = nil) -> (folders: Int, groups: [String]) {
        var idMap: [String: String] = [:]
        for f in data["folders"].items { idMap[f["id"].stringish ?? ""] = uid("fld") }
        let incoming = data["folders"].items.map { f -> HostFolder in
            HostFolder(id: idMap[f["id"].stringish ?? ""]!, name: f["name"].stringish?.nilIfEmpty ?? "Folder",
                       group: remap?.nilIfEmpty ?? f["group"].stringish ?? "",
                       parent: f["parent"].stringish.flatMap { idMap[$0] }, rule: f["rule"].string ?? "")
        }
        var incomingMembers: [String: JSON] = [:]
        for (oldId, m) in data["members"].entries {
            guard let id = idMap[oldId] else { continue }
            incomingMembers[id] = FolderMembers(in: m["in"].items.compactMap(\.stringish), out: m["out"].items.compactMap(\.stringish)).json
        }
        var touched: [String] = []
        for f in incoming where !touched.contains(f.group) { touched.append(f.group) }
        let keep = mode == "replace" ? allFolders().filter { !touched.contains($0.group) } : allFolders()
        let keptIds = Set(keep.map(\.id))
        var map: [String: JSON] = [:]
        for (id, m) in membersMap where keptIds.contains(id) { map[id] = m }
        for (k, v) in incomingMembers { map[k] = v }
        saveFolders(keep + incoming, members: map)
        return (incoming.count, touched)
    }
}
