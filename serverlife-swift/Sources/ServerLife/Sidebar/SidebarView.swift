import AppKit
import SwiftUI

/// `Slots.sidebar`: the tabs, the filter and its buttons, the panel, the footer.
struct SidebarRoot: View {
    let window: WindowModel

    var body: some View {
        let sw = window.feature(SidebarWindow.self)
        let p = Theme.shared.p
        VStack(spacing: 0) {
            SBTabStrip(window: window, sw: sw)
            if sw.tab == "saved" { SBSubTabs(sw: sw) }
            SBSearchBlock(window: window, sw: sw)
            Group {
                switch sw.tab {
                case "saved": SBSavedPanel(window: window, sw: sw)
                case "teleport":
                    if let make = SidebarHooks.teleportTab { make(window) }
                    else { SBEmptyText(lines: ["The Teleport tab is not available in this build."]) }
                default: SBHostsPanel(window: window, sw: sw)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            SBFooter(window: window)
        }
        .background(p.panel)
    }
}

// MARK: - Tabs

private struct SBTabStrip: View {
    let window: WindowModel
    let sw: SidebarWindow
    var body: some View {
        let p = Theme.shared.p
        let inv = Inventory.shared
        let s = inv.requestSummary()
        HStack(spacing: 0) {
            tab("hosts", "Hosts")
            tab("saved", "Saved")
            tab("teleport", "Teleport", badge: true)
                .help(RequestWatchUI.tabTooltip)
                .tourAnchor("teleport-tab")
        }
        .overlay(alignment: .bottom) { p.borderSoft.frame(height: 1) }
        .sbContextMenu { RequestWatchUI.requestsMenuItems(window: window) }
    }

    private func tab(_ id: String, _ title: String, badge: Bool = false) -> some View {
        let p = Theme.shared.p
        let on = sw.tab == id
        return Button { sw.tab = id } label: {
            HStack(spacing: 4) {
                Text(title).font(SBZoom.font(11.5, .medium))
                if badge { TeleportRequestBadge() }
            }
            .foregroundStyle(on ? p.text : p.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, SBZoom.px(8))
            .overlay(alignment: .bottom) { (on ? p.accent : .clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SBSubTabs: View {
    let sw: SidebarWindow
    var body: some View {
        HStack(spacing: 4) {
            sub("profiles", "Profiles"); sub("macros", "Macros"); sub("s3", "S3")
        }
        .padding(.horizontal, 8).padding(.top, 7)
    }
    private func sub(_ id: String, _ title: String) -> some View {
        let p = Theme.shared.p
        let on = sw.savedView == id
        return Button { sw.savedView = id } label: {
            Text(title).font(SBZoom.font(11))
                .frame(maxWidth: .infinity).padding(.vertical, 3)
                .foregroundStyle(on ? Color.white : p.muted)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? p.accentDim : p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? p.accentDim : p.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter

private struct SBSearchBlock: View {
    let window: WindowModel
    let sw: SidebarWindow
    @FocusState private var focused: Bool
    @StateObject private var dismissed = Local("")

    private static let help = "Text matches anywhere.\nTags: key=value · key:partial · key=a,b for either · key: for any value · key=pre* glob · -key=value to exclude.\nTerms are combined with AND."

    /// The pairs the box has seen (the original's datalist), matched against
    /// the word being typed.
    private func suggestions() -> [String] {
        let text = sw.filterField
        guard focused, !text.isEmpty, dismissed.value != text else { return [] }
        let last = (Tags.tokenize(text).last ?? "").lowercased()
        guard !last.isEmpty, !text.hasSuffix(" ") else { return [] }
        var out: [String] = []
        for t in Tags.collectTags(Inventory.shared.allNodes) {
            for v in t.values {
                let term = Tags.termFor(t.key, v.value)
                if term.lowercased().contains(last) && term.lowercased() != last { out.append(term) }
                if out.count >= 8 { return out }
            }
        }
        return out
    }

    private func accept(_ term: String) {
        var toks = Tags.tokenize(sw.filterField)
        if !toks.isEmpty { toks.removeLast() }
        let joined = (toks.map(Tags.quoteIfNeeded) + [term]).joined(separator: " ")
        dismissed.value = joined
        sw.setFilter(joined)
    }

    var body: some View {
        let p = Theme.shared.p
        let sugg = suggestions()
        VStack(alignment: .leading, spacing: 5) {
            TextField("Filter hosts or tags — env=prod", text: Binding(get: { sw.filterField }, set: { v in
                sw.filterField = v
                sw.fieldChanged(v)
            }))
            .textFieldStyle(.plain)
            .font(SBZoom.font(12))
            .focused($focused)
            .onSubmit { sw.setFilter(sw.filterField, fromInput: true) }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? p.accentDim : p.border))
            .help(Self.help)
            .tourAnchor("host-filter")
            .overlay(alignment: .topLeading) {
                if !sugg.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sugg, id: \.self) { s in
                            Button { accept(s) } label: {
                                Text(s).font(SBZoom.font(11.5, mono: true)).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel3).shadow(radius: 4, y: 2))
                    .offset(y: SBZoom.px(28))
                    .zIndex(10)
                }
            }
            .zIndex(10)
            SBFilterButtons(window: window, sw: sw)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .zIndex(10)
    }
}

private struct SBFilterButtons: View {
    let window: WindowModel
    let sw: SidebarWindow
    var body: some View {
        let inv = Inventory.shared
        let mode = Heartbeat.quietFilter
        let n = SB2.quietCount(sw)
        let gone = SB2.goneCount(sw)
        let all = inv.allNodes + inv.sshHosts
        let shown = sw.filterText.isEmpty ? 0 : all.filter { sw.hostMatches($0) }.count
        let breakdown = gone > 0 ? "\(n - gone) quiet, \(gone) no longer in the inventory"
            : "\(n) node\(n == 1 ? " has" : "s have") gone quiet"
        SBFlow(spacing: 5) {
            SBToolButton(title: "Tags…", help: "Browse every tag in the inventory") { SBTagBrowser.open(window: window) }
            SBToolButton(title: "Show tags", active: HostPrefs.showTags,
                         help: HostPrefs.showTags ? "Hide tags on host rows" : "Show every tag on each host row") { HostPrefs.toggleShowTags() }
            SBToolButton(title: "Heartbeats", active: Heartbeat.showHeartbeats,
                         help: Heartbeat.showHeartbeats ? "Stop showing when each node last checked in"
                            : "Show how long ago each Teleport node last checked in") { HostPrefs.toggleShowHeartbeats() }
                .tourAnchor("btn-heartbeats")
            if n > 0 || mode != "all" {
                SBToolButton(title: ["all": "Quiet: \(n)", "hide": "Quiet hidden (\(n))", "only": "Only quiet (\(n))"][mode]!,
                             active: mode != "all",
                             help: ["all": "\(breakdown) — click to hide them", "hide": "\(breakdown), hidden — click to see only them",
                                    "only": "Showing only these — click for the whole list"][mode]!) { HostPrefs.setQuietFilter() }
            }
            SBToolButton(title: "Folders", help: "Organise hosts into folders — the big view") {
                Actions.shared.perform("folders-browser", window: window)
            }
            .tourAnchor("btn-folders")
            if !sw.filterText.isEmpty {
                SBBadge(text: "\(shown) of \(all.count)", kind: shown == 0 ? "warn" : "")
            }
        }
    }
}

// MARK: - Footer

private struct SBFooter: View {
    let window: WindowModel
    var body: some View {
        let p = Theme.shared.p
        let inv = Inventory.shared
        let b = inv.loading ? (text: "Loading…", kind: "") : inv.badge
        HStack(spacing: 8) {
            Button("+\u{00A0}Add") { Actions.shared.perform("add-server", window: window) }
                .buttonStyle(.ghost).help("Define a new server (⌘⇧N)").fixedSize()
            Button("Refresh") { Actions.shared.perform("refresh", window: window) }
                .buttonStyle(.ghost).help("Refresh inventory (⌘R)").fixedSize()
            SBBadge(text: b.text, kind: b.kind)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .overlay(alignment: .top) { p.borderSoft.frame(height: 1) }
    }
}

/// `.sb-empty`.
struct SBEmptyText: View {
    let lines: [String]
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).opacity(i == 0 ? 1 : 0.75)
            }
        }
        .font(SBZoom.font(12))
        .foregroundStyle(p.muted)
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hosts tab

struct SBHostsPanel: View {
    let window: WindowModel
    let sw: SidebarWindow
    var body: some View {
        _ = sw.tick
        _ = Inventory.shared.generation
        _ = Inventory.shared.beamsGeneration
        _ = Inventory.shared.requestsGeneration
        _ = SBRequestableCache.shared.revision
        _ = ConnectionManager.shared.connections.map(\.state)
        let entries = SB2.hostsTab(sw)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { e in
                    switch e {
                    case .group(let g): SBGroupView(window: window, sw: sw, group: g)
                    case .note(_, let lines, let kind): SBEmptyBlock(window: window, sw: sw, lines: lines, kind: kind)
                    }
                }
            }
            .padding(.top, 2).padding(.bottom, 8)
        }
    }
}

struct SBGroupView: View {
    let window: WindowModel
    let sw: SidebarWindow
    let group: SBGroup
    @StateObject private var hover = LocalFlag()
    @StateObject private var dropMark = Local<Bool?>(nil)
    @StateObject private var height = Local<CGFloat>(24)

    var body: some View {
        let p = Theme.shared.p
        let g = group
        let collapsed = sw.collapsed.contains(g.key)
        let colorHex = g.profile.map { ClusterMarks.colorHex(FolderModel.groupKey(for: $0)) } ?? ""
        let color = HostColor.swiftColor(colorHex)
        let icon = g.profile.map { ClusterMarks.icon($0) } ?? ""
        let ids = g.items.compactMap { i -> String? in if case .host(let h) = i { return h.host.id }; return nil }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("\u{25BC}").font(SBZoom.font(9)).rotationEffect(.degrees(collapsed ? -90 : 0))
                    .foregroundStyle(color?.opacity(0.8) ?? p.muted)
                if !icon.isEmpty { Text(icon).font(SBZoom.font(12)) }
                Text(g.title.uppercased()).kerning(0.6).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(color ?? (hover.on ? p.textDim : p.muted))
                ForEach(Array(g.tags.enumerated()), id: \.offset) { _, t in SBGroupTagView(window: window, tag: t, headHover: hover.on) }
                Spacer(minLength: 4)
                Text(String(g.count)).fontWeight(.regular).opacity(0.65).foregroundStyle(p.muted)
            }
            .font(SBZoom.font(10.5, .semibold))
            .padding(.horizontal, 10).padding(.vertical, SBZoom.px(5))
            .contentShape(Rectangle())
            .background(SBHeightReader(height: $height.value))
            .overlay(alignment: .top) { if dropMark.value == false { p.accent.frame(height: 2) } }
            .overlay(alignment: .bottom) { if dropMark.value == true { p.accent.frame(height: 2) } }
            .onHover { hover.on = $0 }
            .onTapGesture { if collapsed { sw.collapsed.remove(g.key) } else { sw.collapsed.insert(g.key) } }
            .sbContextMenu { SBMenus.groupMenu(g, sw: sw, window: window) }
            .onDrag {
                SBDrag.begin(.group(g.key))
            }
            .onDrop(of: [.text], delegate: SBDropDelegate(height: height.value, canTake: {
                if case .group(let k) = SBDrag.current { return k != g.key }
                return false
            }, onTarget: { dropMark.value = $0 }, perform: { after in
                guard case .group(let moved) = SBDrag.current else { return }
                if !after { SBMenus.placeGroup(moved, before: g.key, sw) }
                else {
                    let keys = SB2.groupKeysOnScreen(sw).filter { $0 != moved }
                    let idx = keys.firstIndex(of: g.key).map { $0 + 1 } ?? keys.count
                    SBMenus.placeGroup(moved, before: idx < keys.count ? keys[idx] : nil, sw)
                }
            }))
            if !collapsed {
                ForEach(g.items) { item in
                    SBItemView(window: window, sw: sw, item: item, groupIds: ids)
                }
            }
        }
        .padding(.bottom, 2)
        .overlay(alignment: .leading) { if let color { color.opacity(0.55).frame(width: 2) } }
    }
}

/// A badge on a group heading.
private struct SBGroupTagView: View {
    let window: WindowModel
    let tag: SBGroupTag
    let headHover: Bool
    var body: some View {
        let p = Theme.shared.p
        switch tag {
        case .home(let pr):
            if !pr.homeName.isEmpty {
                SBTag(text: pr.homeName, help: "From TELEPORT_HOME=\(pr.homeDir)\(pr.username.isEmpty ? "" : " · as " + pr.username)")
            }
        case .leaf(let pr):
            if let v = SidebarHooks.leafClusterTag?(pr, window) { v }
        case .requests(let pr):
            ClusterRequestTag(p: pr, window: window)
        case .expired:
            SBTag(text: "expired", kind: .expired, help: "The certificate has lapsed — log in again")
        case .refresh(let key, let title, let profile):
            let busy = Inventory.shared.refreshingGroups.contains(profile?.key ?? key)
            Text("\u{27F3}")
                .font(SBZoom.font(11))
                .foregroundStyle(busy ? p.accent : p.muted)
                .opacity(busy ? 1 : (headHover ? 0.75 : 0))
                .rotationEffect(.degrees(busy ? 180 : 0))
                .animation(busy ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: busy)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
                .help(busy ? "Refreshing…" : title)
                .onTapGesture {
                    if busy { return }
                    if let profile { SBActions.refreshProfile(profile) } else { SBActions.refreshSshConfigs(key) }
                }
        case .beams(let n):
            SBTag(text: "\(n) beams", kind: .beams, help: "\(n) beam(s) running on this cluster")
        case .active:
            SBTag(text: "active", kind: .live, help: "Plain tsh commands use this cluster")
        case .gathered:
            SBTag(text: "gathered", help: "Starred hosts are gathered here. Their menu can put them back at the top of their own group instead.")
        case .missingFile(let f):
            SBTag(text: "missing", help: f)
        case .extraFile(let f):
            SBTag(text: "-F", help: f)
        case .gone(let n):
            SBTag(text: "\(n) gone", kind: .gone,
                  help: "Watched hosts that left the inventory, and whose cluster is no longer listed.\nThe record is kept until you stop watching them.")
        case .unchecked(let n):
            SBTag(text: "\(n) unchecked", kind: .stale,
                  help: "Watched hosts whose cluster cannot be read — logged out, expired or removed.\nNothing is known about them either way until it can be.")
        }
    }
}

// MARK: - Items

struct SBItemView: View {
    let window: WindowModel
    let sw: SidebarWindow
    let item: SBItem
    let groupIds: [String]

    var body: some View {
        switch item {
        case .host(let h): SBHostRow(window: window, sw: sw, item: h, groupIds: groupIds)
        case .folder(let f, let count, let depth, let gk): SBFolderRow(window: window, sw: sw, folder: f, count: count, depth: depth, groupKey: gk)
        case .more(let gk, let hidden): SBMoreRow(window: window, groupKey: gk, hidden: hidden)
        case .empty(_, let lines, let kind): SBEmptyBlock(window: window, sw: sw, lines: lines, kind: kind)
        case .narrowed(let p, let granted): SBNarrowedNote(profile: p, granted: granted)
        case .expired(let p): SBExpiredBlock(window: window, profile: p)
        case .beamHead(_, let count): SBBeamHead(count: count)
        case .beam(let b): SBBeamRow(window: window, beam: b)
        case .beamAdd(let p, let first): SBBeamAddRow(window: window, profile: p, first: first)
        case .local(let which): SBLocalRow(window: window, which: which)
        }
    }
}

/// The `.sb-empty` blocks with their buttons.
struct SBEmptyBlock: View {
    let window: WindowModel
    let sw: SidebarWindow
    let lines: [String]
    let kind: SBEmptyKind
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l)
                    .foregroundStyle(i == 0 && isNoSsh ? p.amber : p.muted)
                    .opacity(i == 0 ? 1 : 0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons.padding(.top, 3)
        }
        .font(SBZoom.font(12))
        .foregroundStyle(p.muted)
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isNoSsh: Bool { if case .noSsh = kind { return true }; return false }

    @ViewBuilder private var buttons: some View {
        switch kind {
        case .filterMiss:
            HStack(spacing: 6) {
                Button("Browse tags…") { SBTagBrowser.open(window: window) }.buttonStyle(.ghostSmall)
                Button("Clear filter") { sw.setFilter("") }.buttonStyle(.ghostSmall)
            }
        case .tpError(let missing):
            if missing { Button("Locate tsh…") { Actions.shared.perform("locate-tools", window: window) }.buttonStyle(.ghostSmall) }
        case .noSsh:
            Button("Locate ssh…") { Actions.shared.perform("locate-tools", window: window) }.buttonStyle(.ghostSmall)
        case .sshEmpty(let primary, let show):
            if show {
                Button(primary ? "Add a server…" : "Manage config files…") {
                    if primary { Actions.shared.perform("add-server", window: window) } else { SBDialogs.sshConfigFiles(window: window) }
                }.buttonStyle(.ghost)
            }
        default: EmptyView()
        }
    }
}

struct SBHostRow: View {
    let window: WindowModel
    let sw: SidebarWindow
    let item: SBHostItem
    let groupIds: [String]
    @StateObject private var hover = LocalFlag()
    @StateObject private var dropMark = Local<Bool?>(nil)
    @StateObject private var height = Local<CGFloat>(24)

    static let stripLimit = 6
    static let stripMaxValue = 22

    private var host: Host { item.host }

    private func heldLine() -> String {
        let n = host.heldBy.count
        return "\(host.name) is out of reach while \(n == 1 ? "an access request is" : "\(n) access requests are") assumed.\n"
            + "Assuming a request for particular resources limits this login to just those; "
            + "this node is still on the cluster.\nDrop the request to use it again."
    }

    private func tooltip(_ tags: [(key: String, value: String)]) -> String {
        if host.watchMissing { return HostWatch.missingLine(host) }
        if host.isHeldBack { return heldLine() }
        if host.watchUnconfirmed { return HostWatch.unconfirmedLine(host) }
        if host.type != Host.teleport {
            return "\(host.alias ?? host.name)\n\(host.user ?? "")@\(host.hostname ?? ""):\(host.port.map(String.init) ?? "")"
        }
        var lines = [host.name, "cluster: \(host.cluster ?? "")",
                     "connects as: \(HostPrefs.preferredLogin(host) ?? "(cluster default)")",
                     host.addr?.nilIfEmpty ?? (host.tunnel == true ? "tunnel" : ""),
                     Heartbeat.heartbeatLine(host),
                     host.ambiguous == true && host.uuid != nil
                        ? "node id: \(host.uuid!)\n(another node here has the same hostname, so this one is dialled by id)" : ""]
            .filter { !$0.isEmpty }
        if !tags.isEmpty {
            lines += ["", "tags (\(tags.count)):"] + tags.prefix(20).map { "  \($0.key) = \($0.value)" }
            if tags.count > 20 { lines.append("  … and \(tags.count - 20) more") }
        }
        return lines.joined(separator: "\n")
    }

    /// Labels people sort by first, long values last.
    private func orderForStrip(_ tags: [(key: String, value: String)]) -> [(key: String, value: String)] {
        let pr = SB2.labelPriority
        func rank(_ t: (key: String, value: String)) -> Int {
            if t.value.count > Self.stripMaxValue { return pr.count + 1 }
            return pr.firstIndex(of: SB2.lastSegment(t.key)) ?? pr.count
        }
        return tags.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            return Tags.localeLess(a.element.key, b.element.key)
        }.map(\.element)
    }

    private func doubleClick() {
        if host.isHeldBack {
            SBActions.toast("\(host.name) is out of reach while the request is assumed — drop it to use this node", .error)
        } else if host.isRequestableRow {
            SBActions.requestAccessFor(host, window: window)
        } else if host.watchMissing {
            SBActions.toast("\(host.name) is not in the inventory any more — last seen \(HostWatch.goneFor(host.watchMissingSince ?? 0)) ago", .error)
        } else {
            SBActions.open(host, window: window)
        }
    }

    var body: some View {
        let p = Theme.shared.p
        let tags = Tags.labelEntries(host)
        let expanded = HostPrefs.showTags && !tags.isEmpty
        let colorHex = HostPrefs.hostColorHex(host)
        let hostColor = HostColor.swiftColor(colorHex)
        let conn = SB2.connectionState(host.id)
        let hidden = HostPrefs.isHidden(host)
        let inFolder = item.folder != nil
        let leftPad: CGFloat = inFolder ? 26 + CGFloat(item.depth) * 16 : 20
        VStack(alignment: .leading, spacing: 3) {
            line(tags: tags, expanded: expanded, hostColor: hostColor, conn: conn, hidden: hidden)
            if expanded { tagStrip(tags) }
        }
        .padding(.leading, SBZoom.px(leftPad)).padding(.trailing, 10)
        .padding(.top, SBZoom.px(5)).padding(.bottom, SBZoom.px(expanded ? 6 : 5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(host.watchMissing ? 0.72 : host.isHeldBack ? 0.55 : hidden ? 0.45 : 1)
        .background(conn == .connected ? p.panel3 : (hover.on ? p.panel2 : .clear))
        .overlay(alignment: .leading) {
            if let hostColor { hostColor.frame(width: 2) } else if conn == .connected { p.accent.frame(width: 2) }
        }
        .overlay(alignment: .leading) {
            if inFolder { p.borderSoft.frame(width: 1).padding(.leading, SBZoom.px(16 + CGFloat(max(0, item.depth - 1)) * 16)) }
        }
        .overlay(alignment: .top) { if dropMark.value == false { p.accent.frame(height: 2) } }
        .overlay(alignment: .bottom) { if dropMark.value == true { p.accent.frame(height: 2) } }
        .background(SBHeightReader(height: $height.value))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help(tooltip(tags))
        .onTapGesture(count: 2) { doubleClick() }
        .sbContextMenu { SBMenus.hostMenu(host, groupKey: item.groupKey, folder: item.folder, window: window) }
        .modifier(SBHostDrag(item: item, groupIds: groupIds, height: height.value, dropMark: dropMark))
    }

    @ViewBuilder
    private func line(tags: [(key: String, value: String)], expanded: Bool, hostColor: Color?, conn: ConnState?, hidden: Bool) -> some View {
        let p = Theme.shared.p
        let starred = HostPrefs.isStarred(host)
        let icon = HostPrefs.hostIcon(host)
        let checkable = !host.watchMissing && !host.watchUnconfirmed && !host.isHeldBack
        HStack(spacing: SBZoom.px(7)) {
            Toggle("", isOn: Binding(get: { sw.checkedHosts.contains(host.id) }, set: { on in
                if on { sw.checkedHosts.insert(host.id) } else { sw.checkedHosts.remove(host.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().controlSize(.small)
            .disabled(!checkable)
            .help(host.watchMissing ? "This host is no longer in the inventory"
                  : host.watchUnconfirmed ? "Nobody has been able to check this host"
                  : host.isHeldBack ? "Out of reach while a request is assumed" : "Select for multi-exec")
            SBDot(color: host.watchMissing ? p.amber : conn == .connected ? p.green : conn == .error ? p.red : p.muted)
            Text(starred ? "\u{2605}" : "\u{2606}")
                .font(SBZoom.font(10))
                .foregroundStyle(starred ? p.amber : p.muted)
                .opacity(starred ? 1 : (hover.on ? 0.55 : 0))
                .frame(width: SBZoom.px(11))
                .contentShape(Rectangle())
                .onTapGesture { HostPrefs.setStarred(host, !starred) }
                .help(starred ? "Starred — click to unstar" : "Star this host to keep it at the top")
            if HostWatch.showWatchMark && HostWatch.isWatched(host) && !host.watchMissing && !host.watchUnconfirmed {
                Text("\u{1F514}").font(SBZoom.font(10.5)).help("Watched — you will be told if this host leaves the inventory")
            }
            HStack(spacing: 5) {
                Text(host.name.nilIfEmpty ?? host.alias ?? "")
                    .font(SBZoom.font(12.5))
                    .foregroundStyle(hostColor ?? (hover.on ? p.text : p.textDim))
                    .strikethrough(host.watchMissing || hidden)
                    .lineLimit(1).truncationMode(.tail)
                if HostPrefs.isCareful(host) { Text("!").font(SBZoom.font(12.5, .bold)).foregroundStyle(p.amber) }
                if !icon.isEmpty { Text(icon).font(SBZoom.font(11)).help("Right-click → Icon… to change it") }
                if host.ambiguous == true, let uuid = host.uuid {
                    Text("\u{1F4CB}").font(SBZoom.font(10.5)).opacity(0.85)
                        .help("Duplicate named node — another node in \(host.cluster ?? "this cluster") answers to “\(host.name)”.\nThis one is dialled by its id, \(uuid).")
                }
            }
            .frame(minWidth: SBZoom.px(110), alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 0)
            stateTag().fixedSize()
            if HostPrefs.isMfaHost(host.id) { SBTag(text: "mfa", kind: .mfa, help: "Requires per-session MFA").fixedSize() }
            if !expanded && !item.label.isEmpty { SBTag(text: item.label) }
            else if host.tunnel == true { SBTag(text: "tunnel", kind: .tunnel, help: "Reached over a reverse tunnel").fixedSize() }
        }
    }

    @ViewBuilder private func stateTag() -> some View {
        if host.isHeldBack {
            SBTag(text: "held", kind: .held, help: heldLine())
        } else if host.watchMissing {
            SBTag(text: "\u{2298} gone " + HostWatch.goneFor(host.watchMissingSince ?? 0), kind: .gone, help: HostWatch.missingLine(host))
        } else if host.isRequestableRow {
            SBTag(text: "req", kind: .req,
                  help: "You no longer have standing access to \(host.name), but the cluster will let you ask for it.\n"
                    + "Double-click the row to start a request." + (host.requestableSince.map { "\nRequestable since \(HostWatch.localeString($0))." } ?? ""))
        } else if host.watchUnconfirmed {
            SBTag(text: "? unchecked " + HostWatch.goneFor(host.watchLastSeen ?? 0), kind: .stale, help: HostWatch.unconfirmedLine(host))
        } else if Heartbeat.isStale(host) {
            SBTag(text: "\u{26A0} " + Heartbeat.staleLabel(host), kind: .stale, help: Heartbeat.heartbeatLine(host))
        } else if Heartbeat.showHeartbeats && Heartbeat.heartbeatAge(host) != nil {
            SBTag(text: "\u{2665} " + Heartbeat.ageLabel(host), kind: .hb, help: Heartbeat.heartbeatLine(host))
        }
    }

    private func tagStrip(_ tags: [(key: String, value: String)]) -> some View {
        let ordered = orderForStrip(tags)
        var shown = Array(ordered.prefix(Self.stripLimit))
        for t in ordered.dropFirst(Self.stripLimit) where Tags.hasTerm(sw.filterText, Tags.termFor(t.key, t.value)) { shown.append(t) }
        let hidden = tags.count - shown.count
        return SBFlow(spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, t in
                let on = Tags.hasTerm(sw.filterText, Tags.termFor(t.key, t.value))
                SBChip(key: t.key, value: t.value.isEmpty ? "—" : t.value, on: on,
                       help: on ? "\(t.key) = \(t.value)\nClick to remove from the filter" : "\(t.key) = \(t.value)\nClick to filter by it") {
                    sw.filterByTag(t.key, t.value)
                }
            }
            if hidden > 0 {
                SBChip(value: "+\(hidden) more", italic: true, help: "Show every tag on this node") {
                    SBTagBrowser.openHostTags(host, window: window)
                }
            }
        }
        .padding(.leading, SBZoom.px(26 - 20))
    }
}

/// Drag a host to reorder it within its group, or onto a folder.
private struct SBHostDrag: ViewModifier {
    let item: SBHostItem
    let groupIds: [String]
    let height: CGFloat
    @ObservedObject var dropMark: Local<Bool?>

    func body(content: Content) -> some View {
        guard let gk = item.groupKey else { return AnyView(content) }
        let host = item.host
        return AnyView(content
            .onDrag {
                SBDrag.begin(.host(id: host.id, groupKey: gk, host: host))
            }
            .onDrop(of: [.text], delegate: SBDropDelegate(height: height, canTake: {
                if case .host(let id, let g, _) = SBDrag.current { return g == gk && id != host.id }
                return false
            }, onTarget: { dropMark.value = $0 }, perform: { after in
                guard case .host(let id, _, _) = SBDrag.current else { return }
                var ids = groupIds
                if let from = ids.firstIndex(of: id) { ids.remove(at: from) }
                var at = ids.firstIndex(of: host.id) ?? ids.count
                if at < ids.count && after { at += 1 }
                ids.insert(id, at: at)
                HostPrefs.saveHostOrder(gk, ids)
                SBActions.status("Order saved for this group")
            })))
    }
}

struct SBFolderRow: View {
    let window: WindowModel
    let sw: SidebarWindow
    let folder: HostFolder
    let count: Int
    let depth: Int
    let groupKey: String
    @StateObject private var hover = LocalFlag()
    @StateObject private var dropIn = LocalFlag()

    private func canTake() -> Bool {
        switch SBDrag.current {
        case .host(_, let g, _): return g == groupKey
        case .folder(let f):
            if f.id == folder.id || f.group != groupKey { return false }
            return !FolderModel.folderPath(folder).contains { $0.id == f.id }
        default: return false
        }
    }

    var body: some View {
        let p = Theme.shared.p
        let shut = sw.foldersShut.contains(folder.id)
        let hex = FolderModel.folderColorHex(folder)
        let color = HostColor.swiftColor(hex)
        HStack(spacing: 6) {
            Text(shut ? "\u{25B6}" : "\u{25BC}").font(SBZoom.font(8)).foregroundStyle(p.muted).frame(width: SBZoom.px(9))
            Text(FolderModel.folderIcon(folder, open: !shut)).font(SBZoom.font(11)).saturation(0.65)
            Text(folder.name).font(SBZoom.font(12.5)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(dropIn.on ? .white : color ?? (hover.on ? p.text : p.textDim))
                .frame(maxWidth: .infinity, alignment: .leading)
            if !folder.rule.isEmpty { SBTag(text: "rule", kind: .rule, help: folder.rule) }
            Text(String(count)).font(SBZoom.font(10)).foregroundStyle(p.muted).monospacedDigit()
        }
        .padding(.leading, SBZoom.px(10 + CGFloat(depth) * 16)).padding(.trailing, 8).padding(.vertical, SBZoom.px(4))
        .background(dropIn.on ? p.accentDim : (hover.on ? p.panel2 : .clear))
        .overlay(alignment: .leading) {
            if dropIn.on { p.accent.frame(width: 2) } else if let color { color.frame(width: 2) }
        }
        .overlay(alignment: .leading) {
            if depth > 0 && depth <= 3 { p.borderSoft.frame(width: 1).padding(.leading, SBZoom.px(16 + CGFloat(depth - 1) * 16)) }
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help([FolderModel.pathLabel(folder),
               folder.rule.isEmpty ? "holds what you drag into it" : "fills itself with: \(folder.rule)",
               "\(count) host\(count == 1 ? "" : "s")", "Drag a host onto it, or right-click for more"].joined(separator: "\n"))
        .onTapGesture { if shut { sw.foldersShut.remove(folder.id) } else { sw.foldersShut.insert(folder.id) } }
        .sbContextMenu { SBMenus.folderRowMenu(folder, groupKey: groupKey, window: window) }
        .onDrag {
            SBDrag.begin(.folder(folder))
        }
        .onDrop(of: [.text], delegate: SBDropDelegate(height: 20, canTake: canTake, onTarget: { dropIn.on = $0 != nil }, perform: { _ in
            switch SBDrag.current {
            case .folder(let moving):
                if FolderModel.reparentFolder(moving.id, folder.id) { SBActions.status("\(moving.name) is now inside \(folder.name)") }
            case .host(let id, _, let h):
                let host = SB2.hostById(id) ?? h
                Task { await SBMenus.dropHostIntoFolder(host, folder, groupKey) }
            default: break
            }
        }))
    }
}

private struct SBMoreRow: View {
    let window: WindowModel
    let groupKey: String
    let hidden: Int
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 7) {
            Text("…").font(SBZoom.font(13)).kerning(1)
            Text("\(hidden) more").font(SBZoom.font(11.5)).monospacedDigit()
            Spacer()
            Text("open in a pane").font(SBZoom.font(10.5)).foregroundStyle(p.accent)
        }
        .foregroundStyle(hover.on ? p.text : p.muted)
        .padding(.leading, SBZoom.px(20)).padding(.trailing, 10).padding(.vertical, SBZoom.px(4))
        .background(hover.on ? p.panel2 : .clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help("This list stops at \(HostPrefs.hostLimit) hosts.\nOpen the pane to see all of them, or raise the limit in Settings.")
        .onTapGesture { Actions.shared.perform("hosts-pane", window: window, args: ["groupKey": groupKey]) }
    }
}

private struct SBNarrowedNote: View {
    let profile: TeleportProfile
    let granted: Int
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 8) {
            Text("Request assumed — this login reaches only \(granted) of the cluster's resources.")
                .fixedSize(horizontal: false, vertical: true)
            if !profile.activeRequests.isEmpty {
                Button("Drop request") { Task { await SBActions.dropRequest(profile) } }
                    .buttonStyle(.ghostSmall)
                    .help("Go back to your standing access, and the whole cluster")
            }
        }
        .font(SBZoom.font(11))
        .foregroundStyle(p.textDim)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(p.accent.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.accent.opacity(0.28)))
        .padding(.leading, 22).padding(.trailing, 8).padding(.top, 2).padding(.bottom, 4)
        .help(profile.allowedResources.joined(separator: "\n"))
    }
}

private struct SBExpiredBlock: View {
    let window: WindowModel
    let profile: TeleportProfile
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            Text("Session expired.").foregroundStyle(p.textDim)
            HStack(spacing: 6) {
                Button("tsh login") { Task { await SBActions.loginExpired(profile, window: window) } }.buttonStyle(.ghostSmall)
                Button("Copy login cmd") { SBActions.copyLoginCommand(profile) }.buttonStyle(.ghostSmall)
                    .help("Copy the tsh login command, ready to paste into a terminal")
                Button("Remove") { Task { await SBActions.removeExpiredProfile(profile, window: window) } }.buttonStyle(.ghostSmall)
                    .help("Delete this profile from the tsh home, so it stops being listed")
            }
            .padding(.top, 7)
        }
        .font(SBZoom.font(12))
        .padding(.leading, SBZoom.px(26)).padding(.trailing, 12).padding(.top, 10).padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { p.borderSoft.frame(width: 1).padding(.leading, SBZoom.px(16)) }
        .padding(.top, 2).padding(.bottom, 4)
    }
}

private struct SBBeamHead: View {
    let count: Int
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 6) {
            Text("BEAMS").kerning(0.8)
            if count > 0 { Text(String(count)).fontWeight(.regular).opacity(0.65) }
        }
        .font(SBZoom.font(9.5, .semibold))
        .foregroundStyle(p.muted)
        .padding(.leading, SBZoom.px(20)).padding(.trailing, 10).padding(.top, 6).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { p.borderSoft.frame(height: 1) }
        .padding(.top, 2)
    }
}

private struct SBBeamRow: View {
    let window: WindowModel
    let beam: Beam
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        let conn = ConnectionManager.shared.connections.first { $0.hostId == "beam:\(beam.proxy):\(beam.id)" }
        let live = conn.map { [.connected, .connecting, .prompting].contains($0.state) } ?? false
        let left = beam.expires.map { $0 - nowMs() } ?? 0
        let soon = left > 0 && left < 3_600_000
        let exp = Beams.expiresIn(beam)
        HStack(spacing: SBZoom.px(7)) {
            SBDot(color: left <= 0 ? p.red : p.green)
            Text(beam.id).font(SBZoom.font(12.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            SBTag(text: "beam", kind: .beams)
            if !beam.region.isEmpty { SBTag(text: beam.region) }
            Group {
                if beam.expires == nil { Text("no expiry").font(SBZoom.font(9.5)).foregroundStyle(p.muted) }
                else { BeamExpiryLabel(beam: beam) }
            }
            .padding(.horizontal, SBZoom.px(5)).padding(.vertical, SBZoom.px(1))
            .background(RoundedRectangle(cornerRadius: 3).fill(soon ? p.amber.opacity(0.18) : p.panel3))
            .fixedSize()
            .help(beam.expires.map { HostWatch.localeString($0) } ?? "")
        }
        .foregroundStyle(hover.on || live ? p.text : p.textDim)
        .padding(.leading, SBZoom.px(20)).padding(.trailing, 10).padding(.vertical, SBZoom.px(5))
        .background(live ? p.panel3 : (hover.on ? p.panel2 : .clear))
        .overlay(alignment: .leading) { if live { p.accent.frame(width: 2) } }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help([beam.id, beam.region.isEmpty ? "" : "region: " + beam.region,
               beam.requestedRegion.isEmpty ? "" : "(asked for \(beam.requestedRegion))",
               beam.owner.isEmpty ? "" : "owner: " + beam.owner, beam.uuid, exp].filter { !$0.isEmpty }.joined(separator: "\n"))
        .onTapGesture(count: 2) { Actions.shared.perform("beam-open", window: window, args: ["beam": beam]) }
        .sbContextMenu {
            if let make = SidebarHooks.beamMenu { return make(beam, window) }
            Actions.shared.perform("beam-menu", window: window, args: ["beam": beam])
            return []
        }
    }
}

private struct SBBeamAddRow: View {
    let window: WindowModel
    let profile: TeleportProfile
    let first: Bool
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: SBZoom.px(7)) {
            SBDot(color: p.accent)
            Text(first ? "+  Start the first beam…" : "+  Start a beam…").font(SBZoom.font(12.5, .medium))
        }
        .foregroundStyle(p.accent)
        .padding(.leading, SBZoom.px(20)).padding(.trailing, 10).padding(.vertical, SBZoom.px(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover.on ? p.panel2 : .clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help("Start a new sandbox VM on this cluster")
        .onTapGesture { Actions.shared.perform("beam-start", window: window, args: ["profileKey": profile.key]) }
    }
}

private struct SBLocalRow: View {
    let window: WindowModel
    let which: String
    @StateObject private var hover = LocalFlag()
    var body: some View {
        let p = Theme.shared.p
        let (name, color, help): (String, Color, String) = {
            switch which {
            case "keys": return ("SSH keys", p.amber, "Keypairs in ~/.ssh, their fingerprints and what the agent holds (⌘⇧K)")
            case "nettools": return ("Network tools", p.accent, "Ping, traceroute, DNS, ports, TLS, HTTP and cluster info (⌘⇧T)")
            default: return ("Local shell", p.purple, "Open a shell on this machine")
            }
        }()
        let row = HStack(spacing: SBZoom.px(7)) {
            SBDot(color: color)
            Text(name).font(SBZoom.font(12.5))
        }
        .foregroundStyle(hover.on ? p.text : p.textDim)
        .padding(.leading, SBZoom.px(20)).padding(.trailing, 10).padding(.vertical, SBZoom.px(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover.on ? p.panel2 : .clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help(help)
        .onTapGesture(count: 2) { open() }
        .sbContextMenu { menu() }
        switch which {
        case "keys": row.tourAnchor("keys")
        case "nettools": row.tourAnchor("nettools")
        default: row
        }
    }

    private func open() {
        switch which {
        case "keys": Actions.shared.perform("keys", window: window)
        case "nettools": Actions.shared.perform("nettools", window: window)
        default: Actions.shared.perform("open-local", window: window)
        }
    }

    private func menu() -> [CtxItem] {
        switch which {
        case "keys":
            return [CtxItem("Show keys…", key: "⌘⇧K") { open() }, .sep,
                    CtxItem("Browse ~/.ssh in the file browser") {
                        Actions.shared.perform("local-files", window: window, args: ["path": NSHomeDirectory() + "/.ssh"])
                    }]
        case "nettools":
            return [CtxItem("Open network tools…") { open() }]
        default:
            return SBMenus.localShellMenu(window: window)
        }
    }
}
