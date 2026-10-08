import AppKit
import SwiftUI

/// folderview.js: the whole arrangement at once, in the shape a file manager
/// uses — a tree on the left, what is in the selected thing on the right,
/// breadcrumbs, Unfiled per group, click / ⌘-click / shift-click, drag onto
/// any folder, double-click to go in or open.
///
/// Not a second inventory: everything is the sidebar's own data and every
/// change the same settings write, so the two are never out of step.
@MainActor
enum FolderBrowser {
    /// Folders closed in the tree, kept for the life of the app (module state in the original).
    static var shut = Set<String>()

    /// `openFolderBrowser({ groupKey, folderId })`.
    static func open(_ window: WindowModel?, groupKey: String? = nil, folderId: String? = nil) {
        let groups = HostsHooks.folderGroups()
        guard let first = groups.first else { return HToast.error("No clusters or ssh hosts to organise yet") }
        let model = FolderBrowserModel(window: window, groupKey: groupKey?.nilIfEmpty ?? first.key, folderId: folderId)
        Modal.sheet(window, title: "Folders", width: 1100, height: 660, resizable: true, autosave: "folders") { handle in
            FolderBrowserView(model: model)
                .onAppear { model.close = { handle.close() } }
        }
    }
}

@MainActor
final class FolderBrowserModel: ObservableObject {
    weak var window: WindowModel?
    var close: () -> Void = {}
    @Published var groupKey: String
    @Published var folderId: String?
    @Published var unfiled = false
    @Published var picked = Set<String>()
    var lastPickedKey: String?
    @Published var query = ""
    @Published var shut: Set<String> = FolderBrowser.shut { didSet { FolderBrowser.shut = shut } }
    @Published var dropTarget: String?

    enum Drag { case hosts(keys: [String], groupKey: String, from: String?), folder(String) }
    var dragging: Drag?

    init(window: WindowModel?, groupKey: String, folderId: String?) {
        self.window = window
        self.groupKey = groupKey
        self.folderId = folderId
    }

    var groups: [FolderGroup] { HostsHooks.folderGroups() }
    var hosts: [Host] { HostsHooks.hostsInGroup(groupKey) }
    var current: HostFolder? { folderId.flatMap { FolderModel.folder(id: $0) } }

    func selectGroup(_ key: String) {
        groupKey = key
        folderId = nil
        unfiled = false
        picked = []
    }

    func go(_ id: String?, unfiled u: Bool = false) {
        folderId = id
        unfiled = u
        picked = []
    }

    /// What the listing shows: subfolders, then hosts.
    func listing(_ hosts: [Host]) -> (subfolders: [HostFolder], shown: [Host]) {
        let folder = current
        let q = query.trimmed.isEmpty ? nil : Tags.compileQuery(query)
        let keep = { (h: Host) in q == nil || q!.match(h) }
        let subs = folder != nil ? FolderModel.folders(in: groupKey, parent: folder!.id)
            : (unfiled ? [] : FolderModel.folders(in: groupKey, parent: nil))
        let shown = folder != nil ? FolderModel.hostsInFolder(folder, hosts).filter(keep)
            : unfiled ? hosts.filter { !FolderModel.isFiled($0, groupKey) }.filter(keep)
            : hosts.filter(keep)
        return (subs, shown)
    }

    func pick(_ k: String, order: [String]) {
        FolderBits.pick(k, picked: &picked, last: &lastPickedKey, order: order)
    }

    // MARK: Drag and drop

    func startHostDrag(_ k: String) {
        // Dragging something outside the selection means that is what you meant.
        if !picked.contains(k) { picked = [k] }
        dragging = .hosts(keys: Array(picked), groupKey: groupKey, from: folderId)
    }

    func canDrop(on folder: HostFolder) -> Bool {
        guard HostsDrag.isFrom(self) else { return false }
        switch dragging {
        case .folder(let id):
            if id == folder.id { return false }
            return !FolderModel.folderPath(folder).contains { $0.id == id }
        case .hosts(_, let g, let from):
            return g == groupKey && from != folder.id
        case nil:
            return false
        }
    }

    func drop(on folder: HostFolder) {
        guard let d = dragging, canDrop(on: folder) else { return }
        dragging = nil
        switch d {
        case .folder(let id):
            if let moving = FolderModel.folder(id: id), FolderModel.reparentFolder(moving.id, folder.id) {
                StatusBus.shared.show("\(moving.name) is now inside \(folder.name)")
            }
        case .hosts(let keys, _, _):
            // The both-or-move question is asked once for the whole drag.
            let list = hosts.filter { keys.contains(FolderModel.hostKey($0)) }
            let g = groupKey
            Task { @MainActor in
                guard let r = await FolderModel.fileHostsInto(list, folder, g) else { return }
                StatusBus.shared.show("\(r.count) host\(r.count == 1 ? "" : "s") \(r.mode == "move" ? "moved to" : "added to") \(folder.name)")
            }
        }
    }

    // MARK: Actions

    func newFolder() {
        FolderDialogs.openFolderDialog(window, group: groupKey, parent: folderId, hosts: hosts)
    }

    func edit(_ folder: HostFolder) {
        FolderDialogs.openFolderDialog(window, group: groupKey, folder: folder, hosts: hosts)
    }

    func folderActions(_ folder: HostFolder) {
        CtxMenu.show([
            .heading(folder.name),
            CtxItem("Open it") { [weak self] in self?.go(folder.id) },
            CtxItem(folder.rule.isEmpty ? "Edit folder…" : "Edit folder and its rule…") { [weak self] in self?.edit(folder) },
            CtxItem("New folder inside…") { [weak self] in
                guard let self else { return }
                FolderDialogs.openFolderDialog(self.window, group: self.groupKey, parent: folder.id, hosts: self.hosts)
            },
            .sep,
            CtxItem("Move to the top level") { FolderModel.reparentFolder(folder.id, nil) },
            .sep,
            CtxItem("Delete this folder…") { [weak self] in
                Task { @MainActor in
                    let ok = await MiscUI.confirm(self?.window, title: "Delete “\(folder.name)”?",
                                                  message: "The folder and anything inside it go.",
                                                  detail: "The hosts stay where they were — they live in the cluster, not in here.",
                                                  confirmLabel: "Delete")
                    guard ok, let self else { return }
                    FolderModel.deleteFolder(folder.id)
                    if self.folderId == folder.id { self.go(folder.parent) }
                }
            },
        ])
    }

    func takeSelectedOut() {
        guard let folder = current else { return }
        let list = hosts.filter { picked.contains(FolderModel.hostKey($0)) }
        if list.isEmpty { return HToast.error("Nothing selected") }
        for h in list { FolderModel.unfileHost(h, folder.id) }
        picked = []
        StatusBus.shared.show("\(list.count) taken out of \(folder.name)")
    }

    func openHost(_ host: Host) {
        // Through the host list's own open, so the account and the MFA route
        // are the same ones the sidebar would have used.
        close()
        HostsOpen.openFromList(host, window: window)
    }

    func openAsPane() {
        let w = window, g = groupKey
        close()
        HostsPane.open(w, groupKey: g)
    }
}

private struct FolderBrowserView: View {
    @ObservedObject var model: FolderBrowserModel

    var body: some View {
        let p = Theme.shared.p
        let hosts = model.hosts
        let groups = model.groups
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Folders").font(.system(size: 14, weight: .semibold))
                Text("Drag hosts in. Double-click to open one.").font(.system(size: 11)).foregroundStyle(p.textDim)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            p.border.frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                toolbar(groups, hosts)
                HStack(spacing: 0) {
                    ScrollView { tree(groups, hosts).padding(.vertical, 6) }
                        .frame(width: 240)
                        .background(p.panel2)
                    p.borderSoft.frame(width: 1)
                    ScrollView { listing(hosts).padding(6) }
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 260, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                footer(hosts)
            }
            .padding(16)
            p.border.frame(height: 1)
            HStack { Spacer(); Button("Close") { model.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction) }
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(p.panel)
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: Toolbar

    private func toolbar(_ groups: [FolderGroup], _ hosts: [Host]) -> some View {
        let current = model.current
        return HStack(spacing: 7) {
            HSelect(options: groups.map { ($0.key, $0.label) },
                    selection: Binding(get: { model.groupKey }, set: { model.selectGroup($0) }))
                .frame(maxWidth: 220)
            crumbs(current)
            Spacer(minLength: 4)
            HField(placeholder: "Filter what is listed", text: $model.query).frame(maxWidth: 210)
            Button(current != nil ? "New inside" : "New folder") { model.newFolder() }.buttonStyle(.ghostSmall)
                .help(current.map { "A folder inside \($0.name)" } ?? "A folder at the top of this group")
            if let current { Button("Edit") { model.edit(current) }.buttonStyle(.ghostSmall) }
            Button("Export…") { Task { @MainActor in await FolderDialogs.exportFolders(model.window, groupKey: model.groupKey) } }
                .buttonStyle(.ghostSmall).help("Write this group’s folders out as a file")
            Button("Import…") { Task { @MainActor in await FolderDialogs.importFolders(model.window, groups: HostsHooks.folderGroups()) } }
                .buttonStyle(.ghostSmall)
            Button("Open as a pane") { model.openAsPane() }.buttonStyle(.ghostSmall)
                .help("The same hosts in a pane of the window, which stays open while you work")
        }
    }

    private func crumbs(_ folder: HostFolder?) -> some View {
        let p = Theme.shared.p
        func crumb(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(text).font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? p.text : p.muted).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 2)
            }.buttonStyle(.plain)
        }
        let sep = Text("›").font(.system(size: 11)).foregroundStyle(p.muted)
        return HStack(spacing: 3) {
            crumb("All", on: folder == nil && !model.unfiled) { model.go(nil) }
            if model.unfiled { sep; crumb("Unfiled", on: true) {} }
            ForEach(folder.map(FolderModel.folderPath) ?? []) { f in
                sep
                crumb(f.name, on: f.id == folder?.id) { model.go(f.id) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Tree

    private func tree(_ groups: [FolderGroup], _ hosts: [Host]) -> some View {
        let p = Theme.shared.p
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { g in
                let on = g.key == model.groupKey
                Text(g.label.uppercased())
                    .font(.system(size: 10.5)).kerning(0.6).lineLimit(1)
                    .foregroundStyle(on ? p.text : p.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? p.panel3 : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectGroup(g.key) }
                    .help(g.key)
                if on {
                    ForEach(treeFolders(g.key), id: \.folder.id) { row in
                        treeRow(row.folder, depth: row.depth, count: FolderModel.hostsInTree(row.folder, hosts).count,
                                kids: !FolderModel.folders(in: g.key, parent: row.folder.id).isEmpty)
                    }
                    let loose = hosts.filter { !FolderModel.isFiled($0, g.key) }
                    VStack(spacing: 0) {
                        p.borderSoft.frame(height: 1).padding(.top, 6)
                        HStack(spacing: 6) {
                            Text("").frame(width: 10)
                            Text("—").font(.system(size: 12))
                            Text("Unfiled").font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(loose.count)).font(.system(size: 10)).foregroundStyle(model.unfiled ? Color.white.opacity(0.8) : p.muted)
                        }
                        .foregroundStyle(model.unfiled ? Color.white : p.textDim)
                        .padding(.horizontal, 8).padding(.leading, 2).padding(.vertical, 4).padding(.top, 1)
                        .background(model.unfiled ? p.accentDim : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { model.go(nil, unfiled: true) }
                        .help("Everything in this group that is not in a folder")
                    }
                }
            }
        }
    }

    private func treeFolders(_ group: String) -> [(folder: HostFolder, depth: Int)] {
        var out: [(HostFolder, Int)] = []
        func walk(_ parent: String?, _ depth: Int) {
            for f in FolderModel.folders(in: group, parent: parent) {
                out.append((f, depth))
                if !model.shut.contains(f.id) { walk(f.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return out
    }

    private func treeRow(_ folder: HostFolder, depth: Int, count: Int, kids: Bool) -> some View {
        let p = Theme.shared.p
        let isShut = model.shut.contains(folder.id)
        let on = model.folderId == folder.id
        let colour = FolderBits.color(folder)
        let target = model.dropTarget == folder.id
        return HStack(spacing: 6) {
            Text(kids ? (isShut ? "▶" : "▼") : "").font(.system(size: 8)).foregroundStyle(p.muted).frame(width: 10)
                .contentShape(Rectangle())
                .onTapGesture { if isShut { model.shut.remove(folder.id) } else { model.shut.insert(folder.id) } }
            Text(FolderModel.folderIcon(folder, open: !isShut)).font(.system(size: 12))
            Text(folder.name).font(.system(size: 12.5)).lineLimit(1)
                .foregroundStyle(on || target ? Color.white : (colour ?? p.textDim))
                .frame(maxWidth: .infinity, alignment: .leading)
            if !folder.rule.isEmpty { SmallTag(kind: .rule, text: "rule") }
            Text(String(count)).font(.system(size: 10)).foregroundStyle(on ? Color.white.opacity(0.8) : p.muted)
        }
        .padding(.vertical, 4).padding(.trailing, 8).padding(.leading, 10 + CGFloat(depth) * 12)
        .background(on || target ? p.accentDim : Color.clear)
        .overlay(alignment: .leading) { if let colour { colour.frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.go(folder.id) }
        .hostsRightClick { model.folderActions(folder) }
        .help(folder.rule.isEmpty ? "Holds what you drag into it" : "Rule: \(folder.rule)")
        .onDrag {
            model.dragging = .folder(folder.id)
            return HostsDrag.provider(folder.name, from: model)
        }
        .folderDrop(canDrop: { model.canDrop(on: folder) },
                    onTarget: { model.dropTarget = $0 ? folder.id : (model.dropTarget == folder.id ? nil : model.dropTarget) },
                    onDrop: { model.drop(on: folder) })
    }

    // MARK: Listing

    @ViewBuilder private func listing(_ hosts: [Host]) -> some View {
        let p = Theme.shared.p
        let folder = model.current
        let (subs, shown) = model.listing(hosts)
        let order = shown.map(FolderModel.hostKey)
        LazyVStack(alignment: .leading, spacing: 1) {
            if let folder, !folder.rule.isEmpty {
                let c = Tags.compileQuery(folder.rule)
                HStack(spacing: 8) {
                    Text("RULE").font(.system(size: 9.5)).kerning(0.6).foregroundStyle(p.muted)
                    Text(folder.rule).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    if let e = c.error { Text(e).font(.system(size: 11.5)).foregroundStyle(p.amber) }
                    Spacer()
                    Button("Edit rule") { model.edit(folder) }.buttonStyle(.ghostSmall)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .padding(.bottom, 6)
            }
            ForEach(subs) { f in tile(f, hosts) }
            ForEach(shown, id: \.id) { h in hostRow(h, folder: folder, order: order) }
            if shown.isEmpty && subs.isEmpty {
                VStack(spacing: 8) {
                    Text(folder != nil
                         ? (model.query.isEmpty ? "This folder is empty." : "Nothing in this folder matches that.")
                         : (model.unfiled ? "Everything in this group is filed." : "Nothing here."))
                    if folder != nil && model.query.isEmpty {
                        MiscHint(text: "Drag hosts onto it from Unfiled, or give it a rule so it fills itself.")
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 26).padding(.horizontal, 12)
            }
        }
    }

    private func tile(_ folder: HostFolder, _ hosts: [Host]) -> some View {
        let p = Theme.shared.p
        let count = FolderModel.hostsInTree(folder, hosts).count
        let target = model.dropTarget == folder.id
        return HStack(spacing: 8) {
            Text(FolderModel.folderIcon(folder)).font(.system(size: 13))
            Text(folder.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(FolderBits.color(folder) ?? p.text)
            if !folder.rule.isEmpty { SmallTag(kind: .rule, text: "rule") }
            Spacer()
            Text("\(count) host\(count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(p.muted)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(target ? p.accentDim : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.go(folder.id) }
        .hostsRightClick { model.folderActions(folder) }
        .help(folder.rule.isEmpty ? "" : "Rule: \(folder.rule)")
        .folderDrop(canDrop: { model.canDrop(on: folder) },
                    onTarget: { model.dropTarget = $0 ? folder.id : (model.dropTarget == folder.id ? nil : model.dropTarget) },
                    onDrop: { model.drop(on: folder) })
    }

    private func hostRow(_ host: Host, folder: HostFolder?, order: [String]) -> some View {
        let p = Theme.shared.p
        let k = FolderModel.hostKey(host)
        let on = model.picked.contains(k)
        let live = FolderBits.connected(host)
        let tags = Tags.labelEntries(host).prefix(4)
        let byRule = folder.map { !FolderModel.isManualMember(host, $0.id) } ?? false
        let icon = HostsHooks.hostIcon(host)
        return HStack(spacing: 8) {
            HostDot(on: live)
            if HostsHooks.showWatchMark && HostsHooks.isWatched(host) {
                Text("\u{1F514}").font(.system(size: 10)).help("Watched for disappearance")
            }
            Text(host.name.nilIfEmpty ?? host.alias ?? "").font(.system(size: 12.5, weight: .medium)).lineLimit(1).fixedSize()
            if !icon.isEmpty { Text(icon).font(.system(size: 12)) }
            if byRule { SmallTag(kind: .rule, text: "by rule", help: "In here because the folder’s rule matches it") }
            HeartbeatTag(host: host)
            HStack(spacing: 3) { ForEach(Array(tags.enumerated()), id: \.offset) { _, t in LabelChip(key: t.key, value: t.value, onAccent: on) } }
                .clipped()
            Spacer(minLength: 4)
            Text(host.addr?.nilIfEmpty ?? (host.tunnel == true ? "tunnel" : (host.hostname ?? "")))
                .font(.system(size: 11)).foregroundStyle(on ? Color.white.opacity(0.75) : p.muted).lineLimit(1).fixedSize()
        }
        .foregroundStyle(on ? Color.white : p.text)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? p.accentDim : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? p.accent : Color.clear))
        .contentShape(Rectangle())
        .help(HostsHooks.heartbeat(host)?.line ?? "")
        .gesture(TapGesture(count: 2).onEnded { model.openHost(host) }
            .exclusively(before: TapGesture(count: 1).onEnded { model.pick(k, order: order) }))
        .hostsRightClick {
            if !model.picked.contains(k) { model.picked = [k]; model.lastPickedKey = k }
            HostsHooks.showHostMenu(host, folder: folder, groupKey: model.groupKey, window: model.window)
        }
        .onDrag {
            model.startHostDrag(k)
            return HostsDrag.provider(host.name.nilIfEmpty ?? host.alias ?? "", from: model)
        }
    }

    // MARK: Footer

    private func footer(_ hosts: [Host]) -> some View {
        let p = Theme.shared.p
        let filed = hosts.filter { FolderModel.isFiled($0, model.groupKey) }.count
        return HStack(spacing: 8) {
            Text(model.picked.isEmpty ? "" : "\(model.picked.count) selected").foregroundStyle(p.text)
            Spacer()
            if model.current != nil {
                Button("Take the selected out of this folder") { model.takeSelectedOut() }.buttonStyle(.ghostSmall)
            }
            Text("\(filed) of \(hosts.count) filed").foregroundStyle(p.muted)
        }
        .font(.system(size: 11.5))
    }
}
