import Foundation

/// Which of Desktop/Documents/Downloads each connection actually has, so the
/// home directory is only listed once per session for this.
@MainActor
enum XPHomeFolders {
    static var cache: [String: Task<[String], Never>] = [:]
    static func clear() { cache = [:] }
}

/// Re-read the starred lists in every open explorer (`refreshFavorites`).
@MainActor
func xpRefreshFavorites() {
    XPHomeFolders.clear()
    Explorers.shared.forEach { $0.forgetAutoLocal(); $0.syncFavButton() }
}

extension ExplorerModel {
    func forgetAutoLocal() { autoLocalKeyReset() }

    /// Which favourites apply to this pane, and what a new one here would be
    /// scoped to. A local pane is its own scope; a remote pane gets the
    /// host's key — the same one the sidebar uses, so a starred folder
    /// survives a Teleport node being renamed — and also sees anything
    /// starred for every host.
    func favScope() -> XPFavScope? {
        if isLocal { return XPFavScope(kind: "local", key: "local", label: "this machine") }
        if !isRemote { return nil }
        guard let conn else { return nil }
        let key = conn.host.prefKey
        return XPFavScope(kind: "host", key: key, label: conn.label.nilIfEmpty ?? "this host")
    }

    /// Folders that start out flagged: they live in code (settings.autoFlag*),
    /// unstarring one hides it, and nothing that is not there is offered.
    func defaultFavorites(_ scope: XPFavScope) async -> [XPFavorite] {
        let hidden = Set(Store.shared.xpHiddenFolderFavorites)
        let list = scope.kind == "local" ? Store.shared.xpAutoFlagLocal : Store.shared.xpAutoFlagHost
        if list.isEmpty { return [] }
        let id = { (p: String) in XP.builtinFavoriteId(kind: scope.kind, path: p) }

        if scope.kind == "local" {
            let dirs = autoLocalDirs(list)
            return dirs.map { XPFavorite(id: id($0.given), path: $0.path, label: XP.builtinLabel($0.given),
                                         scope: "local", kind: "dir", builtin: true) }
                .filter { !hidden.contains($0.id) }
        }

        let homeDir = conn?.homeDir
        let homeNames = await homeFolders(homeDir)
        var out: [XPFavorite] = []
        for raw in list {
            let p = raw.trimmed
            if p.isEmpty { continue }
            if p == "~" {
                if let homeDir { out.append(XPFavorite(id: id(p), path: homeDir, label: "Home", scope: "hosts", kind: "dir", builtin: true)) }
                continue
            }
            if p.hasPrefix("~/") {
                // Only the home subfolders this host actually has, from one listing.
                let name = String(p.dropFirst(2))
                guard let homeDir, homeNames.contains(name) else { continue }
                out.append(XPFavorite(id: id(p), path: Posix.join(homeDir, name), label: name, scope: "hosts", kind: "dir", builtin: true))
                continue
            }
            out.append(XPFavorite(id: id(p), path: p, label: XP.builtinLabel(p), scope: "hosts", kind: "dir", builtin: true))
        }
        return out.filter { !hidden.contains($0.id) }
    }

    /// Which of the usual home subfolders this server actually has: the home
    /// directory is listed once per connection and the answer cached.
    func homeFolders(_ homeDir: String?) async -> [String] {
        guard let homeDir, let connId else { return [] }
        if let t = XPHomeFolders.cache[connId] { return await t.value }
        let t = Task { @MainActor () -> [String] in
            do {
                let r = try await FilesService.shared.list(connId, homeDir)
                let names = Set(r.entries.filter(XP.isDir).map(\.name))
                let wanted = Store.shared.xpAutoFlagHost.filter { $0.hasPrefix("~/") }.map { String($0.dropFirst(2)) }
                    .filter { !$0.isEmpty && !$0.contains("/") }
                return wanted.filter { names.contains($0) }
            } catch {
                // Not connected yet, or no permission to read home: offer
                // nothing rather than guessing.
                return []
            }
        }
        XPHomeFolders.cache[connId] = t
        return await t.value
    }

    /// The favourites to show here: the built-in ones, then this scope's own,
    /// then anything starred for every host. A path starred by hand replaces
    /// the built-in entry for the same path rather than doubling it.
    func favorites() async -> [XPFavorite] {
        guard let scope = favScope() else { return [] }
        let mine = Store.shared.xpFolderFavorites.compactMap(XPFavoriteStore.decode)
            .filter { $0.scope == scope.key || (scope.kind == "host" && $0.scope == "hosts") }
        let defaults = await defaultFavorites(scope)
        let byPath = Set(mine.map(\.path))
        return defaults.filter { !byPath.contains($0.path) } + mine
    }

    /// The starred folders (not files) for wherever this pane is pointed —
    /// what the rsync dialog offers.
    func favoriteFolders() async -> [XPFavorite] {
        await favorites().filter { $0.kind == "dir" }
    }

    func isFavorite(_ path: String?) async -> Bool {
        guard let path else { return false }
        return await favorites().contains { $0.path == path }
    }

    /// Star or unstar a folder (or file). Starring asks nothing — a star is
    /// instantly reversible.
    func toggleFavorite(_ path: String?, scope forceScope: String? = nil, kind: String = "dir") async {
        guard let scope = favScope() else { xpToast("Buckets cannot be starred yet", "error"); return }
        guard let path else { return }
        let target = forceScope ?? scope.key

        // A built-in for this path is hidden rather than deleted.
        let all = Store.shared.xpFolderFavorites
        if let builtin = await defaultFavorites(scope).first(where: { $0.path == path }),
           !all.contains(where: { $0["path"].string == path }) {
            var hidden = Store.shared.xpHiddenFolderFavorites
            if !hidden.contains(builtin.id) { hidden.append(builtin.id) }
            Store.shared.setSettingJSON("hiddenFolderFavorites", JSON(hidden))
            xpStatus("Unstarred \(path)")
            syncFavButton()
            return
        }

        var list = all
        if let at = list.firstIndex(where: { $0["path"].string == path
            && ($0["scope"].string == target || (scope.kind == "host" && $0["scope"].string == "hosts")) }) {
            let gone = list.remove(at: at)
            Store.shared.setSettingJSON("folderFavorites", .array(list))
            xpStatus("Unstarred \(gone["path"].string ?? path)")
        } else {
            let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            let fid = "fav_" + String((0..<7).map { _ in chars.randomElement()! })
            list.append([
                "id": .string(fid),
                "path": .string(path),
                "label": .string(Posix.basename(path).nilIfEmpty ?? path),
                "scope": .string(target),
                "scopeLabel": .string(target == "local" ? "this machine" : target == "hosts" ? "every host" : scope.label),
                // A starred file opens; a starred folder is navigated to.
                "kind": .string(kind == "file" ? "file" : "dir"),
            ])
            Store.shared.setSettingJSON("folderFavorites", .array(list))
            xpStatus("Starred \(path)")
        }
        syncFavButton()
    }

    /// Bring the star button and the starred list up to date.
    func syncFavButton() {
        let scope = favScope()
        let here = view.path
        Task { @MainActor [weak self] in
            guard let self else { return }
            let favs = scope == nil ? [] : await self.favorites()
            if self.favScopeNow != scope { self.favScopeNow = scope }
            if self.favList != favs { self.favList = favs }
            let on = here != nil && favs.contains { $0.path == here }
            if self.favOn != on { self.favOn = on }
        }
    }

    /// Rename a starred folder's label.
    func renameFavorite(_ f: XPFavorite) async {
        guard let name = await MiscUI.prompt(window, title: "Rename favourite", label: "Name", value: f.label,
                                             confirmLabel: "Save"), !name.isEmpty else { return }
        let all = Store.shared.xpFolderFavorites.map { x -> JSON in
            guard x["id"].string == f.id else { return x }
            var y = x; y["label"] = .string(name); return y
        }
        Store.shared.setSettingJSON("folderFavorites", .array(all))
        syncFavButton()
    }

    func unstarFavorite(id: String, path: String) {
        let all = Store.shared.xpFolderFavorites.filter { $0["id"].string != id }
        Store.shared.setSettingJSON("folderFavorites", .array(all))
        xpStatus("Unstarred \(path)")
        syncFavButton()
    }

    func restoreBuiltinFavorites() {
        Store.shared.setSettingJSON("hiddenFolderFavorites", .array([]))
        syncFavButton()
    }

    func setFavListCollapsed(_ v: Bool) {
        Store.shared.xpFavListCollapsed = v
        // Both panes carry the same list, so both follow the same choice.
        Explorers.shared.forEach { $0.syncFavButton() }
    }

    /// Open a starred file: locally the OS, on a server the built-in editor.
    func openFavFile(_ path: String) async {
        if isLocal {
            do { try LocalFS.open(path) } catch { xpToast(errorText(error), "error") }
            return
        }
        await edit(FileEntry(name: Posix.basename(path), path: path, type: .file, modeString: ""))
    }
}

/// Reading the stored favourites (settings.folderFavorites).
enum XPFavoriteStore {
    static func decode(_ j: JSON) -> XPFavorite? {
        guard let path = j["path"].string else { return nil }
        return XPFavorite(id: j["id"].string ?? "", path: path, label: j["label"].string?.nilIfEmpty ?? path,
                          scope: j["scope"].string ?? "", kind: j["kind"].string ?? "dir", builtin: false)
    }

    /// `starredFolders(side)` from rsyncsync.js: the saved stars for one side
    /// of an rsync, folders only.
    static func starredFolders(local: Bool, favorites: [JSON]) -> [(path: String, label: String)] {
        favorites.filter { ($0["kind"].string ?? "dir") == "dir" }
            .filter { local ? $0["scope"].string == "local" : $0["scope"].string != "local" }
            .compactMap { j in j["path"].string.map { ($0, j["label"].string?.nilIfEmpty ?? $0) } }
    }
}

extension ExplorerModel {
    /// The local defaults, from what actually exists (cached per list).
    fileprivate func autoLocalDirs(_ list: [String]) -> [LocalFS.ExistingDir] {
        let key = list.joined(separator: "\n")
        if XPAutoLocal.key[id] != key {
            XPAutoLocal.key[id] = key
            XPAutoLocal.dirs[id] = LocalFS.existingDirs(list)
        }
        return XPAutoLocal.dirs[id] ?? []
    }

    fileprivate func autoLocalKeyReset() { XPAutoLocal.key[id] = nil }
}

@MainActor
private enum XPAutoLocal {
    static var key: [String: String] = [:]
    static var dirs: [String: [LocalFS.ExistingDir]] = [:]
}
