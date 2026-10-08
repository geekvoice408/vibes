import AppKit
import SwiftUI

// The explorer's menus: the list's context menu (also what the 3D view shows
// for the building it picked), the ⇅ sort menu, the ☆ star's scope menu, a
// starred row's menu, and "Open with…".

extension ExplorerModel {
    /// Right-click in the list (or on a picked building in 3D): select the
    /// entry under the pointer if it is not already, then show the menu.
    func showContextMenu(for entry: FileEntry?) {
        let view = self.view
        if let entry, !view.selection.contains(entry.path) {
            view.selection = [entry.path]
            render()
        }
        CtxMenu.show(contextMenuItems(for: entry))
    }

    /// The context menu for an entry (nil: the blank space below the rows,
    /// which means "this folder").
    func contextMenuItems(for entry: FileEntry?) -> [CtxItem] {
        let view = self.view
        let sel = selected()
        let local = isLocal
        if isS3 { return XPS3.contextMenu(self, entry, sel) }
        let targetDir = entry.map { XP.isDir($0) ? $0.path : parentOf($0.path) } ?? view.path

        // Where a `cd` would go: the folder under the pointer, or — on blank
        // space — the folder the list is showing, which then leads the menu.
        let cd: CtxItem? = (entry.map(XP.isDir) ?? false) ? cdItem(entry?.path)
            : cdItem(view.path, label: "cd to this folder in terminal")
        let entryCd = cd

        var items: [CtxItem?] = []
        if let entry {
            let dir = XP.isDir(entry)
            if dir {
                let open = view.expanded.contains(entry.path)
                items.append(CtxItem(open ? "Collapse" : "Expand", icon: open ? "\u{25BE}" : "\u{25B8}") { [weak self] in
                    Task { await self?.toggleExpand(entry) }
                })
                items.append(CtxItem("Open folder", icon: "\u{2192}") { [weak self] in Task { try? await self?.navigate(entry.path) } })
            }
            if !dir && local {
                items.append(CtxItem("Open", icon: "\u{2197}", title: "Whatever this Mac opens it with by default") {
                    do { try LocalFS.open(entry.path) } catch { xpToast(errorText(error), "error") }
                })
                // The two things the default handler cannot do: read it here,
                // and name an application.
                items.append(CtxItem("Open as text", icon: "\u{270e}", title: "In this window, with the same editor a remote file gets") {
                    [weak self] in guard let self else { return }
                    Task { await XPDialogs.editor(self, entry, local: true) }
                })
                items.append(CtxItem("Open with\u{2026}", icon: "\u{2197}", submenu: openWithMenu(entry)))
            }
            if !dir && !local {
                items.append(CtxItem("Edit / preview", icon: "\u{270E}") { [weak self] in Task { await self?.edit(entry) } })
                items.append(CtxItem("Edit in my editor…", icon: "\u{270E}",
                                     title: "Downloads it, opens your editor, and uploads every save until you stop") { [weak self] in
                    Task { await self?.editExternally(entry) }
                })
            }
        } else {
            items.append(cd)
        }
        items.append(.sep)

        if !local {
            if !sel.isEmpty {
                items.append(CtxItem("Download\(sel.count > 1 ? " \(sel.count) items" : "")", icon: "\u{2193}") { [weak self] in
                    Task { await self?.download(sel) }
                })
                if let c = connId {
                    items.append(CtxItem("Copy to another server…", icon: "\u{21C6}") { [weak self] in
                        guard let self else { return }
                        Task { await XPDialogs.copyToServer(self, srcConn: c, entries: sel) }
                    })
                }
            }
            items.append(CtxItem("Upload files here…", icon: "\u{2191}") { [weak self] in
                guard let self else { return }
                Task {
                    let urls = await Modal.openFiles(self.window)
                    if !urls.isEmpty { await XPTransfer.uploadTo(self.connId, urls.map(\.path), targetDir, window: self.window) }
                }
            })
            items.append(CtxItem("Upload folder here…", icon: "\u{2191}") { [weak self] in
                guard let self else { return }
                Task {
                    let urls = await Modal.openFiles(self.window, directories: true, files: false)
                    if !urls.isEmpty { await XPTransfer.uploadTo(self.connId, urls.map(\.path), targetDir, window: self.window) }
                }
            })
        } else {
            let remotes = Explorers.shared.inWindow(window).filter { $0.isRemote && $0.connId != nil }
            if !sel.isEmpty, let r = remotes.first {
                items.append(CtxItem("Upload to " + (r.view.path ?? "the other pane"), icon: "\u{2191}") {
                    Task { await XPTransfer.uploadTo(r.connId, sel.map(\.path), r.view.path, window: r.window) }
                })
            }
            if let entry {
                items.append(CtxItem("Reveal in Finder", icon: "\u{2197}") { LocalFS.reveal(entry.path) })
            }
        }

        items.append(.sep)
        items.append(CtxItem("New folder…", icon: "\u{002B}") { [weak self] in Task { await self?.makeDir(targetDir) } })
        if let entry {
            items.append(CtxItem("Rename…", icon: "\u{270E}") { [weak self] in Task { await self?.rename(entry) } })
            if !local {
                items.append(CtxItem(sel.count > 1 ? "Permissions and owner (\(sel.count) items)…" : "Permissions and owner…",
                                     icon: "\u{26BF}") { [weak self] in
                    guard let self else { return }
                    Task { await XPDialogs.permissions(self, sel.count > 1 ? sel : [entry]) }
                })
            }
        }
        if !sel.isEmpty {
            items.append(CtxItem("Delete", icon: "\u{2715}") { [weak self] in Task { await self?.remove(sel) } })
        }
        items.append(.sep)
        if let entry {
            items.append(CtxItem("Copy path", icon: "\u{29C9}") {
                Clipboard.write(entry.path)
                xpStatus("Copied " + entry.path)
            })
            // On blank space this already led the menu, above.
            items.append(entryCd)
            items.append(CtxItem(XP.isDir(entry) ? "Get folder info…" : "Get info…", icon: "\u{2139}") { [weak self] in
                guard let self else { return }
                Task { await XPDialogs.info(self, entry) }
            })
            // A starred folder is somewhere to go, a starred file is something to open.
            items.append(CtxItem(XP.isDir(entry) ? "Star this folder" : "Star this file", icon: "\u{2606}",
                                 title: "Keep it in the starred list above the files") { [weak self] in
                Task { await self?.toggleFavorite(entry.path, kind: XP.isDir(entry) ? "dir" : "file") }
            })
        }
        items.append(.sep)
        // The two-pane operations act on the directory, not the selection.
        if compare != nil {
            items.append(CtxItem("Clear the comparison", icon: "\u{2715}") { [weak self] in self?.clearCompare() })
        } else {
            items.append(CtxItem("Compare with the other list", icon: "\u{2260}") { [weak self] in Task { await self?.compareWith() } })
        }
        items.append(CtxItem("Synchronize with the other list…", icon: "\u{21C6}",
                             title: "Walks both folders and shows what it would move before moving anything") { [weak self] in
            Task { await self?.syncWith() }
        })
        items.append(CtxItem("Synchronize with rsync…", icon: "\u{21C6}",
                             title: "Runs rsync between this folder and the other pane, over the connection already open") { [weak self] in
            guard let self else { return }
            Task { await XPRsyncDialog.open(self) }
        })
        if !local {
            items.append(CtxItem("Keep this folder up to date from here…", icon: "\u{21BB}",
                                 title: "Watches a local folder and uploads changes as they are saved") { [weak self] in
                Task { await self?.keepUpToDate() }
            })
        }
        items.append(.sep)
        items.append(CtxItem("Collapse all", icon: "\u{25BE}") { [weak self] in self?.collapseAll() })
        items.append(CtxItem("Refresh", icon: "\u{21BB}") { [weak self] in Task { await self?.refresh() } })
        return tidy(items.compactMap { $0 })
    }

    /// "Open with…": applications previously chosen, then the picker.
    func openWithMenu(_ entry: FileEntry) -> [CtxItem] {
        let recent = Array(Store.shared.xpOpenWithApps.prefix(8))
        func openIn(_ app: String) {
            Task {
                do {
                    try await LocalFS.openWith(entry.path, app: app)
                    // Most recent first, so the list orders itself by use.
                    let next = [app] + Store.shared.xpOpenWithApps.filter { $0 != app }
                    Store.shared.setSettingJSON("openWithApps", JSON(Array(next.prefix(12))))
                } catch { xpToast(errorText(error), "error") }
            }
        }
        var items = recent.map { a in CtxItem(XP.appName(a), icon: "↗", title: a) { openIn(a) } }
        if !recent.isEmpty { items.append(.sep) }
        items.append(CtxItem("Choose an application…", icon: "+") { [weak self] in
            Task {
                if let u = await Modal.chooseApp(self?.window) { openIn(u.path) }
            }
        })
        if !recent.isEmpty {
            items.append(CtxItem("Forget these", title: "Empty the list of applications above") {
                Store.shared.setSettingJSON("openWithApps", .array([]))
            })
        }
        return items
    }

    /// The ⇅ menu: sort keys (ticks show what is in force), reverse, folders first.
    func sortMenuItems() -> [CtxItem] {
        func mark(_ k: String) -> String? { sort.key == k ? (sort.dir == 1 ? "ascending" : "descending") : nil }
        return [
            .heading("Sort by"),
            CtxItem("Name", sub: mark("name")) { [weak self] in self?.sortBy("name") },
            CtxItem("Size", sub: mark("size")) { [weak self] in self?.sortBy("size") },
            CtxItem("Date modified", sub: mark("mtime")) { [weak self] in self?.sortBy("mtime") },
            .sep,
            CtxItem(sort.dir == 1 ? "Reverse order" : "Normal order") { [weak self] in
                guard let self else { return }
                self.sort.dir = -self.sort.dir
                self.render()
            },
            .sep,
            CtxItem("Folders first", sub: Store.shared.xpFoldersFirst ? "✓" : nil,
                    title: "Off mixes files and folders together, in whatever order the column says") {
                Store.shared.xpFoldersFirst = !Store.shared.xpFoldersFirst
                // Every explorer sorts the same way, so every explorer redraws.
                Explorers.shared.forEach { $0.render() }
            },
        ]
    }

    /// Right-click on the ☆: the scopes and the list.
    func starMenuItems() async -> [CtxItem] {
        guard let scope = favScope() else { return [] }
        let favs = await favorites()
        let here = view.path
        var items: [CtxItem] = [.heading(here ?? "this folder")]
        items.append(CtxItem(await isFavorite(here) ? "Unstar this folder" : "Star for \(scope.label)") { [weak self] in
            Task { await self?.toggleFavorite(here) }
        })
        if scope.kind == "host" {
            items.append(CtxItem("Star for every host", title: "A folder like /var/log is the same question on every server") {
                [weak self] in Task { await self?.toggleFavorite(here, scope: "hosts") }
            })
        }
        if !favs.isEmpty {
            items.append(.sep)
            items.append(.heading("Favourites"))
            for f in favs {
                items.append(CtxItem(f.label, sub: f.scope == "hosts" ? "every host" : nil, title: f.path) { [weak self] in
                    Task { try? await self?.navigate(f.path) }
                })
            }
        }
        return items
    }

    /// A starred row's menu.
    func favRowMenuItems(_ f: XPFavorite) -> [CtxItem] {
        var items: [CtxItem?] = [.heading(f.path)]
        if f.kind == "file" {
            items.append(CtxItem("Open it", icon: "\u{2197}") { [weak self] in Task { await self?.openFavFile(f.path) } })
            items.append(nil)
            items.append(CtxItem("Show the folder it is in", icon: "\u{2630}") { [weak self] in
                guard let self else { return }
                Task { try? await self.navigate(self.isLocal ? XP.parentLocal(f.path) : Posix.parent(f.path)) }
            })
        } else {
            items.append(CtxItem("Go here", icon: "\u{2192}") { [weak self] in Task { try? await self?.navigate(f.path) } })
            // And the same place in the terminal.
            items.append(cdItem(f.path))
            items.append(CtxItem("Open in the other list", icon: "\u{216E}",
                                 title: "Useful for comparing or synchronising the same folder") { [weak self] in
                Task {
                    if let other = await self?.otherPane() { try? await other.navigate(f.path) }
                }
            })
        }
        items.append(.sep)
        if !f.builtin {
            items.append(CtxItem("Rename…", icon: "\u{270E}") { [weak self] in Task { await self?.renameFavorite(f) } })
        }
        items.append(CtxItem(f.builtin ? "Hide this one" : "Unstar", icon: "\u{2605}",
                             title: f.builtin ? "A built-in favourite; hidden until you restore them" : nil) { [weak self] in
            Task { await self?.toggleFavorite(f.path) }
        })
        if !Store.shared.xpHiddenFolderFavorites.isEmpty {
            items.append(CtxItem("Restore the built-in ones", icon: "\u{21BA}") { [weak self] in self?.restoreBuiltinFavorites() })
        }
        return items.compactMap { $0 }
    }

    /// No leading, trailing or doubled separators (contextMenu skipped them too).
    private func tidy(_ items: [CtxItem]) -> [CtxItem] {
        var out: [CtxItem] = []
        for it in items {
            let isSep = it.label.isEmpty && it.onClick == nil && it.submenu == nil
            if isSep && (out.isEmpty || out.last.map { $0.label.isEmpty && $0.onClick == nil && $0.submenu == nil } == true) { continue }
            out.append(it)
        }
        while let l = out.last, l.label.isEmpty && l.onClick == nil && l.submenu == nil { out.removeLast() }
        return out
    }

    // MARK: - Editing

    /// The built-in editor for a remote file.
    func edit(_ entry: FileEntry) async { await XPDialogs.editor(self, entry, local: false) }
}
