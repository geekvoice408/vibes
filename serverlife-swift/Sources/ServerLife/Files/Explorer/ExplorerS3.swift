import AppKit
import SwiftUI

/// The explorer's S3 branches (explorer.js `s3Transfer`, `_s3ContextMenu`,
/// `_s3Info`, Finder files dropped on a bucket). The bucket work and its
/// dialogs are the automation owner's `S3UI` / `S3Service`; this supplies
/// what only the explorer knows — which panes, which prefix, what to refresh.
@MainActor
enum XPS3 {
    /// Buckets as explorer sources ("s3:<id>", "S3: <name>").
    final class Provider: XPSourceProvider {
        let prefix = "s3"
        func options() -> [XPSourceOption] {
            S3Service.shared.targets.compactMap { t in
                t["id"].string.map { XPSourceOption(value: "s3:" + $0, label: "S3: " + (t["name"].string ?? $0)) }
            }
        }
        func fileSource(_ value: String) -> FileSource? {
            let id = String(value.dropFirst(3))
            return S3Service.shared.sources.first { $0.targetId == id }
        }
    }

    static func install() {
        ExplorerSources.register(Provider())
        // Registering or removing a bucket changes what every explorer can point at.
        S3Service.shared.onChange.append { ExplorerSources.changed() }
        // Saved → S3 → "Browse in the file explorer": the focused pane's explorer.
        Actions.shared.register("explorer-show-source") { ctx in
            guard let source = ctx.arg("source", as: String.self) else { return }
            if let pid = XPPanes.activePaneId(ctx.window) {
                XPPaneExplorers.shared.show(pid, source: source)
                return
            }
            // No pane yet: open a local shell first, then use its explorer.
            Actions.shared.perform("new-local", window: ctx.window)
            after(0.4) {
                guard let pid = XPPanes.activePaneId(ctx.window) else { xpToast("Open a session first", "error"); return }
                XPPaneExplorers.shared.show(pid, source: source)
            }
        }
    }

    static func side(_ e: ExplorerModel) -> S3UI.Side? {
        if e.isLocal { return .local }
        if let id = e.s3Id { return .s3(id: id) }
        if e.isRemote, let c = e.connId { return .remote(connId: c) }
        return nil
    }

    /// Move files with a bucket on one side.
    static func transfer(_ src: ExplorerModel, _ dest: ExplorerModel, _ entries: [FileEntry], _ destDir: String) async {
        guard let a = side(src), let b = side(dest) else { xpToast("That combination is not supported", "error"); return }
        if await S3UI.transfer(dest.window, from: a, to: b, entries: entries, destDir: destDir) { await dest.refresh() }
    }

    /// Finder files dropped onto a bucket pane.
    static func dropFiles(_ ex: ExplorerModel, _ paths: [String], _ destDir: String) async {
        guard let id = ex.s3Id else { return }
        let entries = paths.map { FileEntry(name: Posix.basename($0), path: $0, type: .file, modeString: "") }
        if await S3UI.transfer(ex.window, from: .local, to: .s3(id: id), entries: entries, destDir: destDir) { await ex.refresh() }
    }

    static func contextMenu(_ ex: ExplorerModel, _ entry: FileEntry?, _ sel: [FileEntry]) -> [CtxItem] {
        guard let id = ex.s3Id else { return [] }
        return S3UI.contextMenu(ex.window, targetId: id, entry: entry, selection: sel, prefix: ex.view.path ?? "",
                                open: { e in Task { try? await ex.navigate(e.path) } },
                                copyToPane: { files in Task { await copyToPane(ex, files) } },
                                info: { e in Task { await XPDialogs.info(ex, e) } },
                                refresh: { Task { await ex.refresh() } })
    }

    /// The same transfers the drag does, from a menu.
    static func copyToPane(_ ex: ExplorerModel, _ files: [FileEntry]) async {
        let others = Explorers.shared.inWindow(ex.window).filter { $0 !== ex }
        if others.isEmpty { xpToast("Open another file pane first", "error"); return }
        guard let chosen = await XPDialogs.pickList(ex.window, title: "Copy to",
                                                    subtitle: "\(files.count) object\(files.count == 1 ? "" : "s")",
                                                    candidates: others, s3Labels: true) else { return }
        await transfer(ex, chosen, files, chosen.view.path ?? "")
    }

    /// Get info for an object, or a prefix (whose contents have to be counted).
    static func info(_ ex: ExplorerModel, _ entry: FileEntry, _ st: XPInfoState) async throws -> (() async -> Void)? {
        guard let id = ex.s3Id else { return nil }
        if XP.isDir(entry) { st.total = "Counting objects under this prefix…" }
        for (k, v) in try await S3UI.info(targetId: id, entry: entry) { st.put(k, v) }
        st.total = ""
        return nil
    }

    static func bucketName(_ id: String) -> String? { S3Service.shared.target(id)?["name"].string }
}

extension ExplorerModel {
    /// An object opened from the list: download it.
    func s3Download(_ files: [FileEntry]) async {
        guard let id = s3Id else { return }
        await S3UI.download(window, targetId: id, files: files)
    }
}
