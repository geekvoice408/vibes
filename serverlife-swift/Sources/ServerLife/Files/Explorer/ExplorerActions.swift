import AppKit
import SwiftUI

// Everything an explorer does to files: new folder, move, rename, delete,
// edit, download, compare, synchronise, watch, and the transfer helpers
// shared by every explorer (uploadTo, downloadTo, crossCopy).

extension ExplorerModel {
    // MARK: - Mutations

    func makeDir(_ targetDir: String? = nil) async {
        guard let dir = targetDir ?? view.path, !dir.isEmpty || isS3 else { return }
        guard let name = await MiscUI.prompt(window, title: "New folder", label: "Folder name in \(dir)",
                                             confirmLabel: "Create"), !name.isEmpty else { return }
        do {
            var base = dir
            if base.hasSuffix("/") { base.removeLast() }
            let target = base + "/" + name
            guard let src = fileSource else { return }
            try await src.mkdir(target)
            await refresh()
        } catch { xpToast(errorText(error), "error") }
    }

    /// Move entries into another folder of the same pane — a rename
    /// underneath. A folder cannot go inside itself, and an existing name at
    /// the destination stops the move rather than overwriting it.
    func moveInto(_ entries: [FileEntry], _ destDir: String?) async {
        let local = isLocal
        if isS3 {
            xpToast("A bucket has no rename: copy the objects and delete the originals", "error", 7000)
            return
        }
        var dest = destDir ?? ""
        while dest.hasSuffix("/") { dest.removeLast() }
        if dest.isEmpty { dest = local ? (destDir ?? "") : "/" }

        let moving = entries.filter { !$0.path.isEmpty && parentOf($0.path) != dest }
        if moving.isEmpty { return }

        // A folder cannot contain itself. `path + '/'` so a sibling whose name
        // merely starts the same way — /srv/app and /srv/apple — is not caught.
        if let inside = moving.first(where: { x in
            var p = x.path
            while p.hasSuffix("/") { p.removeLast() }
            return dest == x.path || dest.hasPrefix(p + "/")
        }) {
            xpToast("\(inside.name) cannot be moved inside itself", "error")
            return
        }

        // Names already taken at the destination, asked about before anything moves.
        var here = Set<String>()
        if let l = try? await fileSource?.list(dest) { here = Set(l.entries.map(\.name)) }
        let clash = moving.filter { here.contains($0.name) }
        if !clash.isEmpty {
            xpToast(clash.count == 1 ? "\(clash[0].name) is already in that folder"
                                     : "\(clash.count) of those names are already in that folder", "error", 7000)
            return
        }

        var done = 0
        for x in moving {
            do {
                try await fileSource?.rename(x.path, to: joinPath(dest, x.name))
                done += 1
            } catch {
                xpToast("\(x.name): \(errorText(error))", "error", 8000)
                break
            }
        }
        if done > 0 {
            xpStatus(done == 1 ? "Moved \(moving[0].name) to \(dest)" : "Moved \(done) items to \(dest)")
            // The paths just moved; a selection still pointing at them is stale.
            view.selection = []
            await refresh()
        }
    }

    func rename(_ entry: FileEntry) async {
        guard let name = await MiscUI.prompt(window, title: "Rename", label: "New name", value: entry.name,
                                             confirmLabel: "Rename"), !name.isEmpty, name != entry.name else { return }
        do {
            let to = isLocal ? XP.parentLocal(entry.path) + "/" + name : Posix.join(Posix.parent(entry.path), name)
            try await fileSource?.rename(entry.path, to: to)
            await refresh()
        } catch { xpToast(errorText(error), "error") }
    }

    func remove(_ entries: [FileEntry]) async {
        guard !entries.isEmpty else { return }
        let ok = await MiscUI.confirm(
            window,
            title: isLocal ? "Delete local items" : "Delete remote items",
            message: entries.count == 1 ? "Delete “\(entries[0].name)”?" : "Delete \(entries.count) items?",
            detail: entries.prefix(12).map(\.path).joined(separator: "\n")
                + (entries.count > 12 ? "\n… and \(entries.count - 12) more" : "")
                + "\n\nDirectories are removed recursively. This cannot be undone.",
            confirmLabel: "Delete", danger: true)
        guard ok else { return }
        do {
            try await fileSource?.remove(entries)
            await refresh()
            xpStatus("Deleted \(entries.count) item(s)")
        } catch { xpToast(errorText(error), "error") }
    }

    func download(_ entries: [FileEntry], to localDir: String? = nil) async {
        await XPTransfer.downloadTo(connId, entries, localDir, window: window)
    }

    // MARK: - Compare, sync, watch

    /// The other explorer to work against: the local list stacked under this
    /// pane, or the only other one on screen. Asked only when ambiguous.
    func otherPane(needLocal: Bool = false) async -> ExplorerModel? {
        let companion = paneId.flatMap { XPPaneExplorers.shared.companion(of: $0) }.flatMap { $0 === self ? nil : $0 }
        let candidates = Explorers.shared.inWindow(window).filter { e in
            e !== self && (!needLocal || e.isLocal) && !e.isS3
        }
        if let companion, !needLocal || companion.isLocal { return companion }
        if candidates.count == 1 { return candidates[0] }
        if candidates.isEmpty {
            xpToast(needLocal ? "Open the local file list first (the 💻 button)"
                              : "Open a second file list to compare against", "error")
            return nil
        }
        return await XPDialogs.pickList(window, title: "Which list?",
                                        subtitle: "Compare and sync work between two file lists",
                                        candidates: candidates, s3Labels: false)
    }

    /// Mark what differs between this list and another, in place.
    func compareWith() async {
        guard let other = await otherPane() else { return }
        let mine = view.entries, theirs = other.view.entries
        func mark(_ exp: ExplorerModel, _ from: [FileEntry], _ against: [FileEntry], _ otherSide: ExplorerModel) {
            exp.compare = XP.compareMap(from, against)
            exp.compareAgainst = otherSide
            exp.render()
        }
        mark(self, mine, theirs, other)
        mark(other, theirs, mine, self)
        var c: [String: Int] = [:]
        for v in (compare ?? [:]).values { c[v, default: 0] += 1 }
        setStatus("Compared: \(c["same"] ?? 0) identical · \(c["newer"] ?? 0) newer here · "
                  + "\(c["older"] ?? 0) newer there · \(c["only"] ?? 0) only here")
        xpStatus("Comparing — the ✕ on the pane header clears it", 7000)
    }

    func clearCompare(both: Bool = true) {
        let other = compareAgainst
        compare = nil
        compareAgainst = nil
        render()
        if both, let other, other.compare != nil { other.clearCompare(both: false) }
    }

    /// Synchronise this directory with the other pane's, after showing the work.
    func syncWith() async {
        if isS3 { xpToast("Sync works between a server and this machine", "error"); return }
        guard let other = await otherPane() else { return }
        let localSide = isLocal ? self : (other.isLocal ? other : nil)
        let remoteSide = isRemote ? self : (other.isRemote ? other : nil)
        guard let localSide, let remoteSide, let connId = remoteSide.connId else {
            xpToast("Sync needs one local list and one server list", "error"); return
        }
        guard let l = localSide.view.path, let r = remoteSide.view.path else {
            xpToast("Both lists need a folder open", "error"); return
        }
        await XPSyncDialog.open(window, connId: connId, localDir: l, remoteDir: r) {
            Task { await localSide.refresh(); await remoteSide.refresh() }
        }
    }

    /// Mirror a local folder onto the server as it changes.
    func keepUpToDate() async {
        guard isRemote, let connId else {
            xpToast("Open this on the server side — it watches a local folder and uploads to here", "error"); return
        }
        guard let other = await otherPane(needLocal: true) else { return }
        guard let localDir = other.view.path, let remoteDir = view.path else {
            xpToast("Both lists need a folder open", "error"); return
        }
        let ok = await MiscUI.confirm(
            window, title: "Keep the server up to date",
            message: "Upload changes in \(localDir) to \(remoteDir) as they are saved?",
            detail: "Files are uploaded when they change, including new ones. Nothing is ever deleted "
                + "on the server, and nothing is downloaded. Version control directories, node_modules "
                + "and editor scratch files are ignored.\n\nIt keeps running until you stop it in the Watch panel.",
            confirmLabel: "Start watching")
        guard ok else { return }
        do {
            try Watches.shared.watchDir(connId: connId, localDir: localDir, remoteDir: remoteDir)
            window?.showDock("watch")
            xpStatus("Watching \(localDir) → \(remoteDir)")
        } catch { xpToast(errorText(error), "error") }
    }

    /// Open a remote file in the editor this machine (or the user) prefers.
    func editExternally(_ entry: FileEntry) async {
        guard isRemote, let connId else { return }
        xpStatus("Fetching \(entry.name)…", 0)
        do {
            let w = try await Watches.shared.editRemote(connId: connId, remotePath: entry.path)
            window?.showDock("watch")
            if let e = w.openError {
                xpStatus("")
                xpToast("Saved to \(w.localPath ?? "") — could not open an editor: \(e)", "error", 9000)
            } else {
                xpStatus("\(entry.name) is open — every save goes back to the server", 9000)
                return
            }
        } catch {
            xpToast(errorText(error), "error")
        }
        xpStatus("")
    }

    // MARK: - The terminal beside it

    /// Would `cd` in this pane's terminal land where this list is looking?
    /// Only when the two are the same machine.
    func canCd() -> Bool {
        if isS3 || !(isLocal || isRemote) { return false }
        let pid = paneId ?? XPPanes.activePaneId(window)
        guard let pid, let p = XPPanes.info(pid) else { return false }
        if isLocal { return p.kind == "local" }
        return p.kind != "local" && connId != nil && connId == p.connId
    }

    /// The `cd here` item for a folder, or nil where it would not mean this pane.
    func cdItem(_ path: String?, label: String = "cd here in terminal") -> CtxItem? {
        guard let path, !path.isEmpty, canCd() else { return nil }
        return CtxItem(label, icon: "\u{232B}", title: "cd \(path)") { [weak self] in self?.cdInTerminal(path) }
    }

    func cdInTerminal(_ path: String) {
        guard let pid = paneId ?? XPPanes.activePaneId(window) else { return }
        XPPanes.send(pid, "cd \(XPTransfer.jsonQuote(path))\n")
    }

    // MARK: - Drops

    /// Files dragged in from Finder, onto `destDir`.
    func dropFinder(_ paths: [String], destDir: String) async {
        guard !paths.isEmpty else { return }
        if isRemote { await XPTransfer.uploadTo(connId, paths, destDir, window: window) }
        else if isS3 { await XPS3.dropFiles(self, paths, destDir) }
        else { xpToast("Those files are already on this machine", "info") }
    }

    /// Entries dragged from an explorer (this one: a move; another: a copy).
    func dropEntries(_ entries: [FileEntry], from srcId: String, destDir: String) async {
        if srcId == id { await moveInto(entries, destDir); return }
        guard let src = Explorers.shared.get(srcId) else { return }
        // A bucket at either end is routed separately: S3 is not a filesystem.
        if src.isS3 || isS3 { await XPS3.transfer(src, self, entries, destDir); return }
        if src.isLocal && isRemote {
            await XPTransfer.uploadTo(connId, entries.map(\.path), destDir, window: window)
        } else if src.isRemote && isLocal {
            await XPTransfer.downloadTo(src.connId, entries, destDir, window: window)
        } else if src.isRemote && isRemote {
            if src.connId == connId { xpToast("Both panes are the same server", "info"); return }
            guard let a = src.connId, let b = connId else { return }
            await XPTransfer.crossCopy(a, entries, b, destDir, window: window)
        }
    }

    /// Where a drop lands: the folder row under the pointer, the folder a
    /// file row is in, or the directory the pane is showing.
    func dropDestination(row: FileEntry?) -> String? {
        let d: String?
        if let row { d = XP.isDir(row) ? row.path : parentOf(row.path) } else { d = view.path }
        // A bucket's root prefix is the empty string, which is a perfectly
        // good destination — only a genuinely absent path is a reason to stop.
        guard let d else { return nil }
        if !isS3 && d.isEmpty { return nil }
        return d
    }
}

/// The transfer helpers shared by every explorer.
@MainActor
enum XPTransfer {
    /// `JSON.stringify(path)` — what `cd` is typed with.
    static func jsonQuote(_ s: String) -> String {
        JSON.string(s).text()
    }

    static func showTransfers(_ window: WindowModel?) { (window ?? WindowManager.shared.focused)?.showDock("transfers") }

    /// A folder going to or from a beam: say that one archive beats a file at a time.
    static func beamFolderAdvice(_ connId: String, dirPath: String?, up: Bool, dest: String) {
        guard XPConn.get(connId)?.transport == "beam", let dirPath, !dirPath.isEmpty else { return }
        var t = dirPath
        while t.hasSuffix("/") || t.hasSuffix("\\") { t.removeLast() }
        var parts = t.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = parts.popLast().flatMap { $0.nilIfEmpty } ?? dirPath
        let parent = parts.joined(separator: "/").nilIfEmpty ?? "/"
        let pack = "tar czf \(name).tar.gz -C \(XP.shq(parent)) \(XP.shq(name))"
        let unpack = "tar xzf \(name).tar.gz -C \(XP.shq(dest))"
        xpToast(up
            ? "Large folder? Faster to a beam as one archive: here, \(pack); upload that; then in the beam, \(unpack)."
            : "Large folder? Faster from a beam as one archive: in the beam, \(pack); download that; then here, \(unpack).",
            "info", 15000)
    }

    static func uploadTo(_ connId: String?, _ paths: [String], _ remoteDir: String?, window: WindowModel?) async {
        guard let connId else { xpToast("No session for that pane", "error"); return }
        guard let remoteDir, !remoteDir.isEmpty else { xpToast("No remote directory", "error"); return }
        do {
            try await FilesService.shared.upload(connId, localPaths: paths, remoteDir: remoteDir)
            xpStatus("Uploading \(paths.count) item(s) → \(remoteDir)")
            showTransfers(window)
            if XPConn.get(connId)?.transport == "beam" {
                let dirs = LocalFS.existingDirs(paths)
                beamFolderAdvice(connId, dirPath: dirs.first?.path, up: true, dest: remoteDir)
            }
        } catch { xpToast(errorText(error), "error") }
    }

    static func downloadTo(_ connId: String?, _ entries: [FileEntry], _ localDir: String?, window: WindowModel?) async {
        guard let connId else { xpToast("No session for that pane", "error"); return }
        var dir = localDir
        if dir == nil {
            guard let u = await Modal.chooseDirectory(window) else { return }
            dir = u.path
        }
        guard let dir else { return }
        do {
            try await FilesService.shared.download(connId, entries: entries, localDir: dir)
            xpStatus("Downloading \(entries.count) item(s) → \(dir)")
            showTransfers(window)
            beamFolderAdvice(connId, dirPath: entries.first(where: XP.isDir)?.path, up: false, dest: dir)
        } catch { xpToast(errorText(error), "error") }
    }

    static func crossCopy(_ fromConn: String, _ entries: [FileEntry], _ toConn: String, _ destDir: String,
                          window: WindowModel?) async {
        do {
            let plan = try FilesService.shared.crossPlan(fromConn, toConn)
            if plan.mode == "relay" {
                let ok = await MiscUI.confirm(
                    window, title: "Relay through this machine?",
                    message: "\(entries.count) item(s) will be downloaded here and re-uploaded.",
                    detail: plan.reason + "\n\nFiles go to a temporary folder and are deleted afterwards.",
                    confirmLabel: "Copy anyway")
                if !ok { return }
            }
            let out = try await FilesService.shared.cross(fromConn, entries: entries, to: toConn, destDir: destDir)
            xpStatus("\(out.mode == "direct" ? "Direct" : "Relayed") copy of \(out.fileCount) file(s) started")
            showTransfers(window)
        } catch { xpToast(errorText(error), "error") }
    }
}
