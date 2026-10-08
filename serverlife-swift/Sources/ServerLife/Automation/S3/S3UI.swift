import AppKit
import SwiftUI

/// The S3 dialogs (renderer s3.js) and the bucket helpers the explorer and
/// the sidebar's *Saved → S3* tab use (explorer.js `s3Transfer`,
/// `pickStorageClass`, `_s3*`; sidebar.js `renderS3Tab`, `s3Row`).
@MainActor
enum S3UI {
    // MARK: register / edit

    /// `openS3Editor`: returns the saved record (no secrets), or nil.
    @discardableResult
    static func openEditor(_ owner: WindowModel?, initial: JSON = [:]) async -> JSON? {
        let model = S3EditorModel(initial)
        let res: JSON? = await S3Dialog.ask(owner, title: model.isEdit ? "Edit S3 bucket" : "Register an S3 bucket", width: 660) { done in
            S3EditorView(m: model, owner: owner, done: done)
        }
        guard let res else { return nil }
        do {
            return try S3Service.shared.save(res)
        } catch {
            StatusBus.shared.s3Error(s3Message(error))
            return nil
        }
    }

    // MARK: browse buckets

    struct Picked { var name: String; var region: String }

    /// `browseBuckets`: every bucket the credentials can see. Needs
    /// s3:ListAllMyBuckets, which plenty of roles withhold — hence the
    /// fallback message rather than an empty list.
    static func browseBuckets(_ owner: WindowModel?, target: JSON) async -> Picked? {
        let model = BucketBrowser(target: target)
        return await S3Dialog.ask(owner, title: "Buckets", width: 620) { done in
            BucketBrowserView(m: model, done: done)
        }
    }

    // MARK: manage

    /// `openS3Manager` (the `s3` menu item).
    static func openManager(_ owner: WindowModel?) {
        S3Service.shared.reload()
        Modal.sheet(owner, title: "S3 buckets", width: 700) { handle in
            S3ManagerView(owner: owner, close: { handle.close() })
        }
    }

    static func test(_ id: String, bucket: String) {
        StatusBus.shared.show("Testing \(bucket)…", seconds: 0)
        Task {
            do {
                let r = try await S3Service.shared.test(.string(id))
                StatusBus.shared.clear()
                StatusBus.shared.s3Ok("Reached \(r.bucket) in \(r.region)")
            } catch {
                StatusBus.shared.clear()
                StatusBus.shared.s3Error(s3Message(error))
            }
        }
    }

    /// Remove a registration after asking. `detail` differs between the
    /// manager and the sidebar in the original, and is kept that way.
    static func remove(_ owner: WindowModel?, _ t: JSON, detail: String) async -> Bool {
        let name = t["name"].string ?? ""
        guard await MiscUI.confirm(owner, title: "Remove bucket", message: "Remove “\(name)”?", detail: detail,
                                   confirmLabel: "Remove", danger: true) else { return false }
        if let id = t["id"].string { S3Service.shared.delete(id) }
        return true
    }

    // MARK: storage class

    /// `pickStorageClass`: which class to write. Defaults to whatever the
    /// bucket was registered with, so the common case is one Return.
    static func pickStorageClass(_ owner: WindowModel?, target: JSON?, current: String? = nil) async -> String? {
        let initial = current?.nilIfEmpty ?? target?["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD"
        let sel = Local(initial)
        return await S3Dialog.ask(owner, title: current != nil ? "Change storage class" : "Storage class", width: 460) { done in
            StorageClassView(sel: sel, subtitle: target?["name"].string ?? "", changing: current != nil, done: done)
        }
    }

    // MARK: explorer helpers

    /// One side of a transfer: what an explorer pane is showing.
    enum Side: Equatable {
        case local
        case s3(id: String)
        case remote(connId: String)
    }

    /// `s3Transfer`: moving files between a bucket and anything else. Server ↔
    /// bucket goes through this machine, and says so. Returns true when the
    /// destination should refresh.
    @discardableResult
    static func transfer(_ owner: WindowModel?, from src: Side, to dest: Side, entries: [FileEntry], destDir: String) async -> Bool {
        let files = entries.filter { !$0.isDirectoryLike }
        if files.isEmpty {
            StatusBus.shared.s3Error("Folders cannot be moved in one step — open it and take the files.")
            return false
        }
        let svc = S3Service.shared
        switch (src, dest) {
        case (.local, .s3(let id)):
            guard let cls = await pickStorageClass(owner, target: svc.target(id)) else { return false }
            return await run("Uploading \(files.count) file(s)") {
                let r = try await svc.upload(id, localPaths: files.map(\.path), prefix: destDir, storageClass: cls)
                return "Uploaded \(r.count) file(s) as \(r.storageClass)"
            }
        case (.s3(let id), .local):
            return await run("Downloading \(files.count) object(s)") {
                let n = try await svc.download(id, keys: files.map(\.path), destDir: destDir)
                return "Downloaded \(n) object(s)"
            }
        case (.s3(let a), .s3(let b)):
            if a == b { StatusBus.shared.toast("Both panes are the same bucket", kind: .info); return false }
            guard let cls = await pickStorageClass(owner, target: svc.target(b)) else { return false }
            return await run("Copying \(files.count) object(s) via this machine") {
                let r = try await svc.bucketToBucket(from: a, keys: files.map(\.path), to: b, prefix: destDir, storageClass: cls)
                return "Copied \(r.count) object(s) as \(r.storageClass)"
            }
        case (.remote(let connId), .s3(let id)):
            guard let cls = await pickStorageClass(owner, target: svc.target(id)) else { return false }
            StatusBus.shared.show(viaHere, seconds: 6)
            return await run("Uploading \(files.count) file(s) from the server") {
                let r = try await svc.fromServer(connId: connId, entries: files, to: id, prefix: destDir, storageClass: cls)
                return "Uploaded \(r.count) file(s) as \(r.storageClass)"
            }
        case (.s3(let id), .remote(let connId)):
            StatusBus.shared.show(viaHere, seconds: 6)
            return await run("Sending \(files.count) object(s) to the server") {
                let n = try await svc.toServer(id, keys: files.map(\.path), connId: connId, destDir: destDir)
                return "Sent \(n) object(s)"
            }
        default:
            StatusBus.shared.s3Error("That combination is not supported")
            return false
        }
    }

    static let viaHere = "Routed through this machine — a server and a bucket cannot talk to each other directly."

    /// `runS3`: busy status, then a toast either way.
    private static func run(_ busy: String, _ work: () async throws -> String) async -> Bool {
        StatusBus.shared.show(busy + "…", seconds: 0)
        do {
            let msg = try await work()
            StatusBus.shared.clear()
            StatusBus.shared.s3Ok(msg)
            return true
        } catch {
            StatusBus.shared.clear()
            StatusBus.shared.s3Error(s3Message(error))
            return false
        }
    }

    /// `_s3Download`: pick a folder (Downloads first), then fetch.
    static func download(_ owner: WindowModel?, targetId: String, files: [FileEntry]) async {
        guard let dest = await Modal.chooseDirectory(owner, defaultPath: NSHomeDirectory() + "/Downloads") else { return }
        StatusBus.shared.show("Downloading \(files.count) object(s) → \(dest.path)", seconds: 0)
        do {
            let n = try await S3Service.shared.download(targetId, keys: files.map(\.path), destDir: dest.path)
            StatusBus.shared.s3Ok("Downloaded \(n) object(s)")
            StatusBus.shared.clear()
        } catch {
            StatusBus.shared.clear()
            StatusBus.shared.s3Error(s3Message(error))
        }
    }

    /// `_s3Upload`: pick files, pick a class, upload into `prefix`. True when uploaded.
    static func upload(_ owner: WindowModel?, targetId: String, prefix: String) async -> Bool {
        let urls = await Modal.openFiles(owner)
        guard !urls.isEmpty else { return false }
        guard let cls = await pickStorageClass(owner, target: S3Service.shared.target(targetId)) else { return false }
        StatusBus.shared.show("Uploading \(urls.count) file(s) → \(prefix.isEmpty ? "bucket root" : prefix)", seconds: 0)
        do {
            let r = try await S3Service.shared.upload(targetId, localPaths: urls.map(\.path), prefix: prefix, storageClass: cls)
            StatusBus.shared.s3Ok("Uploaded \(r.count) file(s) as \(r.storageClass)")
            StatusBus.shared.clear()
            return true
        } catch {
            StatusBus.shared.clear()
            StatusBus.shared.s3Error(s3Message(error))
            return false
        }
    }

    /// `_s3Retier`: re-tiering is a copy onto itself; S3 has no other way to
    /// change class. True when changed.
    static func retier(_ owner: WindowModel?, targetId: String, file: FileEntry) async -> Bool {
        guard let cls = await pickStorageClass(owner, target: S3Service.shared.target(targetId),
                                               current: file.extra?["storageClass"]?.string ?? "STANDARD") else { return false }
        do {
            try await S3Service.shared.copy(targetId, from: file.path, to: file.path, storageClass: cls)
            StatusBus.shared.s3Ok("\(file.name) is now \(cls)")
            return true
        } catch {
            StatusBus.shared.s3Error(s3Message(error))
            return false
        }
    }

    /// `_s3Delete`. True when something was deleted.
    static func delete(_ owner: WindowModel?, targetId: String, entries: [FileEntry]) async -> Bool {
        let keys = entries.filter { !$0.isDirectoryLike }.map(\.path)
        if keys.isEmpty {
            StatusBus.shared.s3Error("Folders in S3 are only shared prefixes — delete the objects inside.")
            return false
        }
        let detail = keys.prefix(8).joined(separator: "\n") + (keys.count > 8 ? "\n… and \(keys.count - 8) more" : "")
        guard await MiscUI.confirm(owner, title: "Delete from S3", message: "Delete \(keys.count) object\(keys.count == 1 ? "" : "s")?",
                                   detail: detail, confirmLabel: "Delete", danger: true) else { return false }
        do {
            try await S3Service.shared.deleteKeys(targetId, keys: keys)
            StatusBus.shared.s3Ok("Deleted \(keys.count) object(s)")
            return true
        } catch {
            StatusBus.shared.s3Error(s3Message(error))
            return false
        }
    }

    /// `_s3Info`: the Get info rows for an object or a prefix (a prefix is
    /// not a directory — what it holds has to be counted).
    static func info(targetId: String, entry: FileEntry) async throws -> [(String, String)] {
        var rows: [(String, String)] = []
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { rows.append((k, v)) } }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        func n(_ v: Int64) -> String { nf.string(from: NSNumber(value: v)) ?? String(v) }
        if !entry.isDirectoryLike {
            let h = try await S3Service.shared.head(targetId, key: entry.path)
            let size = h.size
            put("Key", entry.path)
            put("Size", Fmt.bytes(size) + " (\(n(size)) bytes)")
            put("Storage class", h.storageClass.nilIfEmpty ?? entry.extra?["storageClass"]?.string ?? "STANDARD")
            put("Modified", Fmt.date(ms: h.mtime > 0 ? h.mtime : entry.mtime))
            put("ETag", h.etag)
            put("Content type", h.contentType)
            return rows
        }
        let d = try await S3Service.shared.prefixInfo(targetId, prefix: entry.path)
        put("Prefix", d.prefix)
        put("Objects", n(Int64(d.objects)) + (d.truncated ? " (stopped early)" : ""))
        put("Size", Fmt.bytes(d.bytes) + " (\(n(d.bytes)) bytes)")
        if !d.classes.isEmpty { put("Storage classes", d.classes.map { "\($0.0) × \($0.1)" }.joined(separator: ", ")) }
        if d.newest > 0 { put("Newest object", Fmt.date(ms: d.newest)) }
        if d.oldest > 0 { put("Oldest object", Fmt.date(ms: d.oldest)) }
        return rows
    }

    /// `_s3ContextMenu`: what a bucket pane offers — a smaller set than a
    /// filesystem (no permissions, no symlinks, no rename in place). The
    /// explorer supplies what only it can do.
    static func contextMenu(_ owner: WindowModel?, targetId: String, entry: FileEntry?, selection: [FileEntry],
                            prefix: String, open: @escaping (FileEntry) -> Void, copyToPane: @escaping ([FileEntry]) -> Void,
                            info: @escaping (FileEntry) -> Void, refresh: @escaping () -> Void) -> [CtxItem] {
        let files = selection.filter { !$0.isDirectoryLike }
        var items: [CtxItem] = []
        if let entry, entry.isDirectoryLike { items.append(CtxItem("Open") { open(entry) }) }
        if !files.isEmpty {
            items.append(CtxItem("Download\(files.count > 1 ? " \(files.count) items" : "")…") {
                Task { await download(owner, targetId: targetId, files: files) }
            })
            items.append(CtxItem("Copy to another pane…") { copyToPane(files) })
        }
        items.append(CtxItem("Upload files here…") {
            Task { if await upload(owner, targetId: targetId, prefix: prefix) { refresh() } }
        })
        items.append(.sep)
        if let entry {
            items.append(CtxItem("Copy key") {
                Clipboard.write(entry.path)
                StatusBus.shared.show("Copied " + entry.path)
            })
        }
        if files.count == 1 {
            items.append(CtxItem("Change storage class…") {
                Task { if await retier(owner, targetId: targetId, file: files[0]) { refresh() } }
            })
        }
        if !selection.isEmpty {
            items.append(CtxItem("Delete\(selection.count > 1 ? " \(selection.count) items" : "")") {
                Task { if await delete(owner, targetId: targetId, entries: selection) { refresh() } }
            })
        }
        items.append(.sep)
        if let entry { items.append(CtxItem("Get info") { info(entry) }) }
        items.append(CtxItem("Refresh") { refresh() })
        return items
    }

    // MARK: Saved → S3

    /// Point the focused pane's explorer at a bucket (sidebar.js
    /// `openS3InExplorer`). The explorer owns that; it is asked through the
    /// `explorer-show-source` action with `source` "s3:<id>".
    static func openInExplorer(_ owner: WindowModel?, _ t: JSON) {
        guard let id = t["id"].string else { return }
        Actions.shared.perform("explorer-show-source", window: owner, args: ["source": "s3:" + id])
        if Actions.shared.isRegistered("explorer-show-source") { StatusBus.shared.show("Browsing \(t["name"].string ?? "")") }
    }

    /// The sidebar row's right-click menu (`s3Row`).
    static func rowMenu(_ owner: WindowModel?, _ t: JSON) -> [CtxItem] {
        [
            CtxItem("Browse in the file explorer") { openInExplorer(owner, t) },
            CtxItem("Test connection") { test(t["id"].string ?? "", bucket: t["bucket"].string ?? "") },
            .sep,
            CtxItem("Edit…") { Task { await openEditor(owner, initial: t) } },
            CtxItem("Remove") {
                Task { _ = await remove(owner, t, detail: "Only the registration goes. Nothing in S3 is touched.") }
            },
        ]
    }
}

// MARK: - views

private struct S3ManagerView: View {
    let owner: WindowModel?
    let close: () -> Void
    var body: some View {
        let svc = S3Service.shared
        let p = Theme.shared.p
        _ = svc.generation
        return DialogScaffold(title: "S3 buckets", width: 700) {
            VStack(alignment: .leading, spacing: 10) {
                if svc.targets.isEmpty {
                    VStack(spacing: 6) {
                        Text("No buckets registered.").foregroundStyle(p.textDim)
                        Text("Register one and it appears in every file explorer’s source list.").foregroundStyle(p.muted)
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                ForEach(Array(svc.targets.enumerated()), id: \.offset) { _, t in card(t) }
            }
        } footer: {
            Button("Register a bucket…") { Task { await S3UI.openEditor(owner) } }.buttonStyle(.ghost)
            Spacer()
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .frame(minHeight: 260)
    }

    private func card(_ t: JSON) -> some View {
        let p = Theme.shared.p
        let region = t["region"].string ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(t["name"].string ?? "").font(.system(size: 13, weight: .semibold))
                S3Tag(text: S3Service.credentialLabel(t))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("bucket: \(t["bucket"].string ?? "")\(region.isEmpty ? "" : " · " + region)")
                if let pre = t["prefix"].string?.nilIfEmpty { Text("prefix: " + pre) }
                if let ep = t["endpoint"].string?.nilIfEmpty { Text("endpoint: " + ep) }
                Text("uploads as: " + (t["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD"))
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(p.textDim)
            .textSelection(.enabled)
            HStack(spacing: 6) {
                Button("Test") { S3UI.test(t["id"].string ?? "", bucket: t["bucket"].string ?? "") }.buttonStyle(.ghost)
                Button("Edit…") { Task { await S3UI.openEditor(owner, initial: t) } }.buttonStyle(.ghost)
                Button("Remove") {
                    Task { _ = await S3UI.remove(owner, t, detail: "Only the registration is removed. Nothing in S3 is touched.") }
                }
                .buttonStyle(GhostButtonStyle(destructive: true))
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }
}

@MainActor
final class BucketBrowser: ObservableObject {
    let target: JSON
    @Published var listing: [S3Client.Bucket]?
    @Published var error: String?
    @Published var filter = ""
    @Published var resolving = false

    init(target: JSON) {
        self.target = target
        var t = target
        if t["bucket"].isNull { t["bucket"] = "" }
        Task {
            do { listing = try await S3Service.shared.buckets(t).buckets } catch { self.error = s3Message(error) }
        }
    }

    /// The region is needed to sign; ask S3 rather than making the user know.
    func pick(_ b: S3Client.Bucket, _ done: @escaping (S3UI.Picked?) -> Void) {
        resolving = true
        var t = target
        t["bucket"] = .string(b.name)
        Task {
            let region = (try? await S3Service.shared.bucketRegion(t)) ?? ""
            done(S3UI.Picked(name: b.name, region: region))
        }
    }
}

private struct BucketBrowserView: View {
    @ObservedObject var m: BucketBrowser
    let done: (S3UI.Picked?) -> Void
    var body: some View {
        let p = Theme.shared.p
        let sub = (m.target["bucket"].string ?? "").isEmpty ? "Pick one to register" : nil
        DialogScaffold(title: "Buckets", subtitle: sub, width: 620, scroll: false) {
            VStack(alignment: .leading, spacing: 10) {
                SearchField(placeholder: "Filter buckets…", text: $m.filter)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content(p) }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200, maxHeight: 440)
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private func content(_ p: Palette) -> some View {
        if let e = m.error {
            VStack(spacing: 6) {
                Text(e).foregroundStyle(p.red)
                Text("Type the bucket name instead — listing all buckets is a separate permission from using one.")
                    .foregroundStyle(p.red.opacity(0.8))
            }
            .font(.system(size: 12)).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        } else if let list = m.listing {
            let q = m.filter.trimmed.lowercased()
            let shown = q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
            if shown.isEmpty {
                Text("No bucket matches.").foregroundStyle(p.muted).font(.system(size: 12))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ForEach(shown) { b in BucketRow(b: b) { m.pick(b, done) }.disabled(m.resolving) }
            }
        } else {
            Text("Listing buckets…").foregroundStyle(p.muted).font(.system(size: 12))
                .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }
}

private struct BucketRow: View {
    let b: S3Client.Bucket
    let action: () -> Void
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        Button(action: action) {
            HStack {
                Text(b.name).font(.system(size: 12.5))
                Spacer()
                Text(b.createdAt > 0 ? Fmt.date(ms: b.createdAt) : "").font(.system(size: 11)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover.on ? p.panel3 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

private struct StorageClassView: View {
    @ObservedObject var sel: Local<String>
    let subtitle: String
    let changing: Bool
    let done: (String?) -> Void
    var body: some View {
        DialogScaffold(title: changing ? "Change storage class" : "Storage class", subtitle: subtitle.nilIfEmpty, width: 460) {
            S3Field(label: "Store as") {
                S3Select(options: S3StorageClass.all.map { ($0.value, $0.label) }, selection: $sel.value)
            }
            S3Hint(text: S3StorageClass.all.first { $0.value == sel.value }?.hint ?? "")
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(changing ? "Change" : "Upload") { done(sel.value) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

/// *Saved → S3* (sidebar.js `renderS3Tab`): registered buckets sit beside
/// profiles and macros, because that is what they are — a saved place, not a
/// live connection. The sidebar embeds this with its filter text; the group
/// and rows are the sidebar's own (`SBSimpleGroup` under key `s3`, `SBPlainRow`).
struct S3SavedTab: View {
    let window: WindowModel?
    var filter: String = ""

    var body: some View {
        let svc = S3Service.shared
        let p = Theme.shared.p
        let w = window ?? WindowManager.shared.current()
        let sw = w.feature(SidebarWindow.self)
        _ = svc.generation
        let q = filter.trimmed.lowercased()
        let targets = svc.targets.filter { t in
            q.isEmpty || ["name", "bucket", "region", "prefix"].contains { (t[$0].string ?? "").lowercased().contains(q) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            if targets.isEmpty {
                VStack(spacing: 6) {
                    Text(q.isEmpty ? "No S3 buckets registered." : "No matching buckets.").foregroundStyle(p.textDim)
                    Text("Register one and it appears as a source in every file explorer, alongside your sessions.")
                        .foregroundStyle(p.muted).opacity(0.75)
                        .multilineTextAlignment(.center)
                    Button("Register a bucket…") { Task { await S3UI.openEditor(w) } }
                        .buttonStyle(.ghost).padding(.top, 3)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12).padding(.vertical, 18)
            } else {
                SBSimpleGroup(sw: sw, title: "Buckets", count: targets.count, key: "s3") {
                    ForEach(Array(targets.enumerated()), id: \.offset) { _, t in row(w, t) }
                }
                HStack(spacing: 6) {
                    Button("Register…") { Task { await S3UI.openEditor(w) } }.buttonStyle(.ghost)
                    Button("Manage…") { S3UI.openManager(w) }.buttonStyle(.ghost)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
            }
        }
    }

    private func row(_ w: WindowModel, _ t: JSON) -> some View {
        let p = Theme.shared.p
        let region = t["region"].string ?? ""
        let tip = "\(t["bucket"].string ?? "")\(region.isEmpty ? "" : " · " + region)\n"
            + (t["prefix"].string?.nilIfEmpty.map { "prefix: \($0)\n" } ?? "")
            + "uploads as \(t["defaultStorageClass"].string?.nilIfEmpty ?? "STANDARD")"
        return SBPlainRow(dot: p.amber, name: t["name"].string ?? "", help: tip,
                          tags: { SBTag(text: S3Service.modeTag(t)) },
                          onDouble: { S3UI.openInExplorer(w, t) },
                          menu: { S3UI.rowMenu(w, t) })
    }
}
