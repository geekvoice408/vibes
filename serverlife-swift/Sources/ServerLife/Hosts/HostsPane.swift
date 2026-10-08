import AppKit
import SwiftUI

/// hostspane.js: a cluster's hosts, given the whole pane — the same
/// inventory as the sidebar with the room it needs, in a real pane that
/// splits, sits beside a terminal and closes like anything else.
///
/// Three things it can be told, all remembered (settings): folders on or
/// off (`hostsPaneFolders`), rows or tiles (`hostsPaneView` "list"/"box"),
/// and whether to list what the cluster would let you ask for
/// (`hostsPaneRequestable`). Plus a filter in the usual query language.
@MainActor
enum HostsPane {
    /// Leaf clusters read on demand: pane key → (when, nodes, error).
    static var leafNodes: [String: (at: Double, nodes: [Host], error: String?)] = [:]
    static let leafTTL: Double = 30000

    static var boxView: Bool { Store.shared.setting("hostsPaneView", "list") == "box" }
    static var foldersOn: Bool { Store.shared.settingJSON("hostsPaneFolders") != .bool(false) }
    /// Off by default: a cluster can offer far more than you hold.
    static var requestableOn: Bool { Store.shared.settingJSON("hostsPaneRequestable") == .bool(true) }

    static func setPref(_ key: String, _ value: JSON) { Store.shared.updateSettings([key: value]) }

    /// `openHostsPane({ groupKey, dir })`: a new tab, or beside the focused pane.
    static func open(_ window: WindowModel?, groupKey: String? = nil, split: String? = nil) {
        let groups = paneGroups()
        guard !groups.isEmpty else { return HToast.error("No clusters or ssh hosts to show yet") }
        let key = groupKey.flatMap { k in groups.contains { $0.key == k } ? k : nil } ?? groups[0].key
        let label = groups.first { $0.key == key }?.label ?? "Hosts"
        let w = window ?? WindowManager.shared.current()
        let model = HostsPaneModel(window: w, groupKey: key)
        var args: [String: Any] = [
            "title": "Hosts · \(label)", "isHosts": true, "hostsGroup": key,
            "view": { AnyView(HostsPaneView(model: model)) } as () -> AnyView,
            "onClose": { model.closed = true } as () -> Void,
        ]
        if let split { args["split"] = split }
        Actions.shared.perform("open-view-pane", window: w, args: args)
        // The pane just made is the focused one: keep it, so its title can follow the cluster.
        if let pane = w.feature(SessionsWindow.self).activePane, pane.isHosts { model.pane = pane }
    }

    /// Everything the pane can be pointed at: the folder groups, plus every
    /// leaf cluster behind each Teleport one, as `root › leaf`.
    static func paneGroups() -> [FolderGroup] {
        var out: [FolderGroup] = []
        for g in HostsHooks.folderGroups() {
            out.append(g)
            if g.kind != "teleport" { continue }
            guard let p = Inventory.shared.profiles.first(where: { FolderModel.groupKey(for: $0) == g.key }) else { continue }
            for leaf in HostsHooks.leavesFor(p) where leaf.name != p.cluster {
                out.append(FolderGroup(key: "\(g.key)::\(leaf.name)", label: "\(g.label) \u{203A} \(leaf.name)", kind: "leaf",
                                       proxy: p.proxy, home: p.homeDir, cluster: leaf.name))
            }
        }
        return out
    }

    /// A selection key naming a leaf, or nil for an ordinary group.
    static func leafOf(_ key: String) -> (group: String, cluster: String)? {
        guard let r = key.range(of: "::") else { return nil }
        return (String(key[..<r.lowerBound]), String(key[r.upperBound...]))
    }

    /// The cluster a pane is pointed at, as proxy, home and cluster name.
    static func clusterOf(_ groupKey: String, _ groups: [FolderGroup]) -> FolderGroup? {
        if let g = groups.first(where: { $0.key == groupKey }), g.proxy != nil { return g }
        guard let p = Inventory.shared.profiles.first(where: { FolderModel.groupKey(for: $0) == groupKey }) else { return nil }
        return FolderGroup(key: groupKey, label: p.cluster, kind: "teleport", proxy: p.proxy, home: p.homeDir, cluster: p.cluster)
    }
}

@MainActor
final class HostsPaneModel: ObservableObject {
    weak var window: WindowModel?
    weak var pane: SessionPane?
    var closed = false
    @Published var groupKey: String
    @Published var filter = ""
    @Published var picked = Set<String>()
    var lastKey: String?
    @Published var shut = Set<String>()
    @Published var dropTarget: String?
    @Published var fetching = false
    /// Bumped when a background read lands.
    @Published var landed = 0
    // Requestable: fetched once per (proxy, home) until the toggle or cluster changes.
    var reqKey: String?
    var reqAt: Double?
    var reqFetching = false
    var reqHosts: [Host] = []
    var reqError: String?
    var dragging: [String]?

    init(window: WindowModel?, groupKey: String) {
        self.window = window
        self.groupKey = groupKey
    }

    func setGroup(_ key: String, groups: [FolderGroup]) {
        groupKey = key
        picked = []
        let label = groups.first { $0.key == key }?.label ?? "Hosts"
        pane?.title = "Hosts · \(label)"
        pane?.hostsGroup = key
    }

    /// Start whatever background reads the current selection needs.
    func ensureFetched(_ groups: [FolderGroup]) {
        if HostsPane.requestableOn, let g = HostsPane.clusterOf(groupKey, groups), let proxy = g.proxy {
            let key = "\(proxy)\u{0}\(g.home ?? "")"
            if (reqKey != key || reqAt == nil) && !reqFetching {
                reqFetching = true
                Task { @MainActor in
                    let r = await HostsHooks.requestableHosts(proxy, g.home, g.cluster)
                    reqHosts = r.hosts
                    reqError = r.error
                    reqFetching = false
                    reqKey = key
                    reqAt = nowMs()
                    landed += 1
                }
            }
        }
        guard HostsPane.leafOf(groupKey) != nil else { return }
        let key = groupKey
        let cached = HostsPane.leafNodes[key]
        let fresh = cached.map { nowMs() - $0.at < HostsPane.leafTTL } ?? false
        if !fresh && !fetching, let g = groups.first(where: { $0.key == key }) {
            fetching = true
            Task { @MainActor in
                let r = await Teleport.listNodes(proxy: g.proxy, cluster: g.cluster, home: g.home)
                HostsPane.leafNodes[key] = (nowMs(), r.ok ? r.items : [], r.ok ? nil : (r.error ?? "that cluster would not answer"))
                fetching = false
                landed += 1
            }
        }
    }

    /// The hosts for the selection: the sidebar's own list for a cluster it
    /// draws, the cached `tsh ls` for a leaf, plus anything askable.
    func hostsFor() -> (hosts: [Host], loading: Bool, error: String?) {
        _ = landed
        let askable = HostsPane.requestableOn ? reqHosts : []
        func withAskable(_ list: [Host]) -> [Host] {
            if askable.isEmpty { return list }
            // Anything already reachable wins.
            let have = Set(list.compactMap(\.uuid))
            return list + askable.filter { !have.contains($0.uuid ?? "") }
        }
        guard HostsPane.leafOf(groupKey) != nil else {
            return (withAskable(HostsHooks.hostsInGroup(groupKey)), false, nil)
        }
        let cached = HostsPane.leafNodes[groupKey]
        return (withAskable(cached?.nodes ?? []), cached == nil, cached?.error)
    }

    /// Everything the pane draws — so a dragged requestable or missing row
    /// is found again on the drop.
    func shownHosts() -> [Host] {
        let held = hostsFor().hosts
        return held + HostsHooks.missingIn(groupKey, held)
    }

    func pick(_ k: String, order: [String]) {
        FolderBits.pick(k, picked: &picked, last: &lastKey, order: order)
    }

    func startDrag(_ k: String) {
        if !picked.contains(k) { picked = [k] }
        dragging = Array(picked)
    }

    func drop(on folder: HostFolder) {
        guard let keys = dragging, HostsDrag.isFrom(self) else { return }
        dragging = nil
        let list = shownHosts().filter { keys.contains(FolderModel.hostKey($0)) }
        let g = groupKey
        Task { @MainActor in
            guard let r = await FolderModel.fileHostsInto(list, folder, g) else { return }
            StatusBus.shared.show("\(r.count) host\(r.count == 1 ? "" : "s") \(r.mode == "move" ? "moved to" : "added to") \(folder.name)")
        }
    }

    func open(_ host: Host) {
        // A requestable node cannot be opened, so the double-click asks for it.
        if host.extra["requestable"]?.truthy == true { return HostsOpen.requestAccess(host, window: window) }
        if host.extra["missing"]?.truthy == true {
            return HToast.error("\(host.name) is not in the inventory any more — last seen \(HostsHooks.goneFor(host.extra["missingSince"]?.double)) ago")
        }
        // The host list's own open: the pinned or remembered account, and the
        // MFA route where the node needs one.
        HostsOpen.openFromList(host, window: window)
    }
}

struct HostsPaneView: View {
    @ObservedObject var model: HostsPaneModel

    var body: some View {
        let p = Theme.shared.p
        let groups = HostsPane.paneGroups()
        let here = model.hostsFor()
        let all = here.hosts + HostsHooks.missingIn(model.groupKey, here.hosts)
        let q = model.filter.trimmed.isEmpty ? nil : Tags.compileQuery(model.filter)
        let hosts = q.map { q in all.filter { q.match($0) } } ?? all
        VStack(spacing: 0) {
            toolbar(groups, all: all, shown: hosts, loading: here.loading)
            p.borderSoft.frame(height: 1)
            ScrollView {
                Group {
                    if here.loading {
                        empty("Reading that cluster…")
                    } else if let e = here.error {
                        VStack(spacing: 8) {
                            Text(e).foregroundStyle(p.amber)
                            MiscHint(text: "A leaf is read with its own tsh ls; the certificate for the root has to be good.")
                        }
                        .font(.system(size: 12.5)).frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 12)
                    } else {
                        content(hosts)
                    }
                }
                .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 14)
            }
        }
        .background(p.bg)
        // The original re-read a stale leaf (30 s) on any redraw: a filter
        // keystroke, a folder write, an inventory event, a preference.
        .task(id: renderKey) { model.ensureFetched(groups) }
    }

    private var renderKey: String {
        let st = Store.shared
        return [model.groupKey, model.filter, String(Inventory.shared.generation), String(HostsPane.requestableOn),
                String(HostsPane.foldersOn), String(HostsPane.boxView), String(model.landed),
                String(st.settingJSON("hostFolders").hashValue), String(st.settingJSON("folderMembers").hashValue)]
            .joined(separator: "|")
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.shared.p.muted)
            .frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 12)
    }

    // MARK: Toolbar

    private func toolbar(_ groups: [FolderGroup], all: [Host], shown: [Host], loading: Bool) -> some View {
        let p = Theme.shared.p
        let req = HostsPane.requestableOn, folders = HostsPane.foldersOn, box = HostsPane.boxView
        func toggle(_ label: String, _ on: Bool, _ help: String, _ action: @escaping () -> Void) -> some View {
            Button(label, action: action)
                .buttonStyle(GhostButtonStyle(small: true))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? p.accent : Color.clear))
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? p.accentDim : Color.clear))
                .help(help)
        }
        return HFlow(spacing: 7) {
            HSelect(options: groups.map { g in
                let icon = HostsHooks.clusterIcon(g.key)
                return (g.key, (icon.isEmpty ? "" : icon + " ") + g.label)
            }, selection: Binding(get: { model.groupKey }, set: { model.setGroup($0, groups: groups) }))
            .frame(width: 220)
            toggle("Requestable", req, req ? "Also listing what this cluster would let you ask for — click to show only what you hold"
                   : "Also list what this cluster would let you ask for, tagged req") {
                HostsPane.setPref("hostsPaneRequestable", .bool(!req))
            }
            toggle("Folders", folders, folders ? "Showing the folder arrangement — click for the plain list"
                   : "Showing every host in one list — click for the folders") {
                HostsPane.setPref("hostsPaneFolders", .bool(!folders))
            }
            HStack(spacing: 2) {
                toggle("List", !box, "One row per host") { HostsPane.setPref("hostsPaneView", "list") }
                toggle("Boxes", box, "Tiles, for scanning a lot of them") { HostsPane.setPref("hostsPaneView", "box") }
            }
            HField(placeholder: "Filter — env=prod, name~^web, tag:gpu", text: $model.filter).frame(width: 260)
            Text(loading ? "reading…" : FolderBits.countText(shown.count, all.count))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(p.muted)
                .frame(height: 22)
            Button("New folder…") {
                FolderDialogs.openFolderDialog(model.window, group: model.groupKey, hosts: all)
            }.buttonStyle(.ghostSmall)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(p.panel)
    }

    // MARK: Content

    @ViewBuilder private func content(_ hosts: [Host]) -> some View {
        if hosts.isEmpty {
            empty(model.filter.isEmpty ? "No hosts in this group." : "Nothing matches that filter.")
        } else if !HostsPane.foldersOn {
            grid(hosts, depth: 0, folder: nil, order: hosts.map(FolderModel.hostKey))
        } else {
            let sections = arranged(hosts)
            let order = sections.flatMap { $0.hosts.map(FolderModel.hostKey) }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                    if let f = s.folder, s.isHead {
                        folderHead(f, depth: s.depth, count: s.count)
                    } else if s.isHead {
                        unfiledHead(s.count)
                    } else {
                        grid(s.hosts, depth: s.depth, folder: s.folder, order: order)
                    }
                }
            }
        }
    }

    /// Folder heads and their grids, then Unfiled — in the order drawn.
    private struct Section { var isHead: Bool; var folder: HostFolder?; var depth: Int; var count: Int; var hosts: [Host] }

    private func arranged(_ hosts: [Host]) -> [Section] {
        var out: [Section] = []
        func walk(_ parent: String?, _ depth: Int) {
            for f in FolderModel.folders(in: model.groupKey, parent: parent) {
                let deep = FolderModel.hostsInTree(f, hosts)
                if !model.filter.isEmpty && deep.isEmpty { continue }
                out.append(Section(isHead: true, folder: f, depth: depth, count: deep.count, hosts: []))
                if model.shut.contains(f.id) { continue }
                let mine = FolderModel.hostsInFolder(f, hosts)
                if !mine.isEmpty { out.append(Section(isHead: false, folder: f, depth: depth + 1, count: 0, hosts: mine)) }
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        let loose = hosts.filter { !FolderModel.isFiled($0, model.groupKey) }
        if !loose.isEmpty {
            out.append(Section(isHead: true, folder: nil, depth: 0, count: loose.count, hosts: []))
            out.append(Section(isHead: false, folder: nil, depth: 0, count: 0, hosts: loose))
        }
        return out
    }

    private func folderHead(_ folder: HostFolder, depth: Int, count: Int) -> some View {
        let p = Theme.shared.p
        let shut = model.shut.contains(folder.id)
        let colour = FolderBits.color(folder)
        let target = model.dropTarget == folder.id
        return HStack(spacing: 7) {
            Text(shut ? "▶" : "▼").font(.system(size: 8)).foregroundStyle(p.muted)
            Text(FolderModel.folderIcon(folder, open: !shut)).font(.system(size: 12))
            Text(folder.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(target ? Color.white : (colour ?? p.textDim))
            if !folder.rule.isEmpty { SmallTag(kind: .rule, text: "rule") }
            Text(String(count)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(p.muted)
            Spacer()
        }
        .padding(.vertical, 4).padding(.trailing, 8).padding(.leading, 4 + CGFloat(depth) * 18)
        .background(RoundedRectangle(cornerRadius: 6).fill(target ? p.accentDim : Color.clear))
        .overlay(alignment: .leading) { (colour ?? .clear).frame(width: 2) }
        .padding(.top, 10).padding(.bottom, 5)
        .contentShape(Rectangle())
        .onTapGesture { if shut { model.shut.remove(folder.id) } else { model.shut.insert(folder.id) } }
        .help(folder.rule.isEmpty ? "Drop hosts here to file them" : "Fills itself with: \(folder.rule)")
        // A folder heading is a drop target: this pane is a place to do the filing.
        .folderDrop(canDrop: { model.dragging != nil && HostsDrag.isFrom(model) },
                    onTarget: { model.dropTarget = $0 ? folder.id : (model.dropTarget == folder.id ? nil : model.dropTarget) },
                    onDrop: { model.drop(on: folder) })
    }

    private func unfiledHead(_ count: Int) -> some View {
        let p = Theme.shared.p
        return HStack(spacing: 7) {
            Text("—").font(.system(size: 12))
            Text("Unfiled").font(.system(size: 12)).foregroundStyle(p.muted)
            Text(String(count)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(p.muted)
            Spacer()
        }
        .foregroundStyle(p.textDim)
        .padding(.vertical, 4).padding(.horizontal, 6)
        .padding(.top, 10).padding(.bottom, 5)
    }

    @ViewBuilder private func grid(_ hosts: [Host], depth: Int, folder: HostFolder?, order: [String]) -> some View {
        if HostsPane.boxView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 7)], alignment: .leading, spacing: 7) {
                ForEach(hosts, id: \.id) { h in card(h, folder: folder, order: order) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(hosts, id: \.id) { h in card(h, folder: folder, order: order) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
    }

    private func card(_ host: Host, folder: HostFolder?, order: [String]) -> some View {
        HostsPaneCard(model: model, host: host, folder: folder, order: order)
    }
}

/// One host in the pane (`.hp-card`), as a row or a tile.
private struct HostsPaneCard: View {
    @ObservedObject var model: HostsPaneModel
    let host: Host
    let folder: HostFolder?
    let order: [String]
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let box = HostsPane.boxView
        let k = FolderModel.hostKey(host)
        let on = model.picked.contains(k)
        let live = FolderBits.connected(host)
        let missing = host.extra["missing"]?.truthy == true
        let requestable = host.extra["requestable"]?.truthy == true
        let beat = HostsHooks.heartbeat(host)
        let quiet = beat?.stale == true
        let tags = Tags.labelEntries(host).prefix(box ? 3 : 5)
        let icon = Store.shared.settingJSON("hostIcons")[k].string ?? ""
        let name = host.name.nilIfEmpty ?? host.alias ?? ""
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                HostDot(on: live, color: missing ? p.amber : nil)
                if HostsHooks.showWatchMark && HostsHooks.isWatched(host) && !missing {
                    Text("\u{1F514}").font(.system(size: 10)).help("Watched for disappearance")
                }
                Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .strikethrough(missing)
                if !icon.isEmpty { Text(icon).font(.system(size: 12)) }
                if host.ambiguous == true, let uuid = host.uuid {
                    Text("\u{1F4CB}").font(.system(size: 10))
                        .help("Duplicate named node — another node here answers to “\(host.name)”.\nThis one is dialled by its id, \(uuid).")
                }
                if requestable {
                    SmallTag(kind: .req, text: "req",
                             help: "Not yours to open yet \u{2014} \(host.cluster ?? "this cluster") will let you ask for it.\nDouble-click to start a request.")
                } else if missing {
                    SmallTag(kind: .gone, text: "\u{2298} gone " + HostsHooks.goneFor(host.extra["missingSince"]?.double),
                             help: HostsHooks.missingLine(host))
                } else {
                    HeartbeatTag(host: host)
                }
                Spacer(minLength: 4)
                Text(host.addr?.nilIfEmpty ?? (host.tunnel == true ? "tunnel" : (host.user ?? "")))
                    .font(.system(size: 11)).foregroundStyle(on ? Color.white.opacity(0.75) : p.muted).lineLimit(1).fixedSize()
            }
            if !tags.isEmpty {
                HFlow(spacing: 3, lineSpacing: 3) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, t in LabelChip(key: t.key, value: t.value, onAccent: on) }
                }
            }
        }
        .foregroundStyle(on ? Color.white : (hover.on ? p.text : p.textDim))
        .padding(.horizontal, box ? 10 : 9).padding(.vertical, box ? 8 : 5)
        .frame(minHeight: box ? 52 : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? p.accentDim : (box ? (hover.on ? p.panel3 : p.panel2) : (hover.on ? p.panel2 : Color.clear))))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? p.accent : (box ? p.borderSoft : Color.clear)))
        .overlay(alignment: .leading) { if quiet { p.amber.frame(width: 2) } }
        .opacity(missing ? 0.72 : 1)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help([name, host.addr?.nilIfEmpty ?? (host.tunnel == true ? "tunnel" : ""), beat?.line ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
        .gesture(TapGesture(count: 2).onEnded { model.open(host) }
            .exclusively(before: TapGesture(count: 1).onEnded { model.pick(k, order: order) }))
        .hostsRightClick {
            if !model.picked.contains(k) { model.picked = [k]; model.lastKey = k }
            HostsHooks.showHostMenu(host, folder: folder, groupKey: model.groupKey, window: model.window)
        }
        .onDrag {
            model.startDrag(k)
            return HostsDrag.provider(name, from: model)
        }
        // In a folder, the fastest way out of it is the one you already tried.
        .focusable(folder != nil)
        .focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let folder else { return .ignored }
            FolderModel.unfileHost(host, folder.id)
            return .handled
        }
    }
}
