import AppKit
import SwiftUI

/// reqmonitor.js: requestable resources, watched.
///
/// Pick the resources you care about, and every few minutes the search is run
/// again and each one is confirmed still there. A resource is only ever
/// called missing off the back of a **successful** search: an expired
/// certificate, a proxy that will not answer, a role that cannot search that
/// kind — each produces an empty list that means nothing.
///
/// Records live in `settings.requestMonitor` (JSON objects, the original's
/// shape); per-cluster search outcomes in `settings.requestMonitorStatus`.
/// The pure half is `ReqMonitorLogic` (tested); this is the loop, the list
/// edits and the pane.
@MainActor
enum ReqMonitor {
    // MARK: The list

    static func monitored() -> [JSON] { Store.shared.settingJSON("requestMonitor").items }
    static func monitorCount() -> Int { monitored().count }
    /// How many are missing right now — the number worth putting on a button.
    static func missingCount() -> Int { monitored().filter { $0["missingSince"].truthy }.count }

    static func monitorStatus() -> JSON { Store.shared.settingJSON("requestMonitorStatus") }
    static func monitorMinutes() -> Int { ReqMonitorLogic.monitorMinutes(Store.shared.settingJSON("requestMonitorMinutes")) }

    /// sidebar.js `monitorSummary`: for a cluster heading's menu.
    static func summary(_ p: TeleportProfile) -> (total: Int, missing: Int) {
        let mine = monitored().filter { ReqMonitorLogic.belongs($0, proxy: p.proxy, home: p.homeDir) }
        return (mine.count, mine.filter { $0["missingSince"].truthy }.count)
    }

    static func isMonitored(_ id: String, _ p: TeleportProfile) -> Bool {
        let key = ReqMonitorLogic.monitorKey(proxy: p.proxy, home: p.homeDir, id: id)
        return monitored().contains { ReqMonitorLogic.monitorKey($0) == key }
    }

    static func save(_ list: [JSON]) {
        Store.shared.setSettingJSON("requestMonitor", .array(list))
    }

    @discardableResult
    static func addToMonitor(_ resources: [ReqResource], _ p: TeleportProfile) -> Int {
        var list = monitored()
        var have = Set(list.map(ReqMonitorLogic.monitorKey))
        var added = 0
        for r in resources {
            let rec = ReqMonitorLogic.record(r, profile: p)
            let k = ReqMonitorLogic.monitorKey(rec)
            if have.contains(k) { continue }
            list.append(rec); have.insert(k); added += 1
        }
        if added == 0 { return 0 }
        save(list)
        TUIStatus.show("Monitoring \(added) more requestable resource\(added == 1 ? "" : "s")")
        return added
    }

    static func removeFromMonitor(_ key: String) { save(monitored().filter { ReqMonitorLogic.monitorKey($0) != key }) }
    static func clearMonitor() { save([]) }

    // MARK: Checking

    struct SearchError: Identifiable {
        let id = UUID()
        var proxy: String
        var kind: String
        var error: String
        var empty = false
    }

    /// Run the searches now. A group whose search fails (or comes back
    /// empty, until corroborated) leaves its resources exactly as they were.
    static func checkNow(quiet: Bool = false) async {
        let st = ReqMonitorState.shared
        if st.checking { return }
        let groups = ReqMonitorLogic.groupsOf(monitored())
        if groups.isEmpty { st.lastRun = nowMs(); return }
        st.checking = true
        st.lastErrors = []
        var status = monitorStatus()
        if status.object == nil { status = .object([:]) }
        var gone: [JSON] = [], back: [JSON] = []
        for g in groups {
            let res = await Teleport.searchRequestable(proxy: g.proxy, kind: g.kind, home: g.home)
            let key = ReqMonitorLogic.groupStatusKey(proxy: g.proxy, home: g.home, kind: g.kind)
            if !res.ok {
                let error = res.error?.nilIfEmpty ?? "search failed"
                st.lastErrors.append(SearchError(proxy: g.proxy, kind: g.kind, error: error))
                var s = status[key]; s["failAt"] = .number(nowMs()); s["error"] = .string(error)
                status[key] = s
                continue
            }
            // An answer that worked but returned nothing concludes nothing either.
            if res.items.isEmpty && !g.items.isEmpty {
                var s = status[key]
                let first = s["emptyAt"].double.flatMap { $0 > 0 ? $0 : nil } ?? nowMs()
                s["emptyAt"] = .number(first)
                s["failAt"] = .number(nowMs())
                s["error"] = "the search returned nothing — roles, or a cluster that cannot answer for this kind"
                status[key] = s
                if nowMs() - first < ReqMonitorLogic.emptyCorroborationMs {
                    st.lastErrors.append(SearchError(proxy: g.proxy, kind: g.kind, error: "the search returned nothing", empty: true))
                    continue
                }
            }
            status[key] = ["okAt": .number(nowMs()), "failAt": 0, "error": "", "emptyAt": 0]
            let found = res.items.map { ReqMonitorLogic.Found(id: $0.id, name: $0.name, labels: $0.labels) }
            // Re-read: the list may have been edited while the search ran.
            let out = ReqMonitorLogic.applySearch(monitored(), group: g, resources: found, now: nowMs())
            save(out.items)
            gone += out.gone; back += out.back
        }
        st.checking = false
        st.lastRun = nowMs()
        Store.shared.setSettingJSON("requestMonitorStatus", status)
        if !quiet {
            for r in gone {
                TUIStatus.toast("\(r["name"].stringish ?? "") is no longer requestable on \(r["cluster"].stringish?.nilIfEmpty ?? r["proxy"].stringish ?? "") — you were monitoring it",
                                "error", ms: 12000)
            }
            for r in back {
                TUIStatus.toast("\(r["name"].stringish ?? "") can be requested again on \(r["cluster"].stringish?.nilIfEmpty ?? r["proxy"].stringish ?? "")",
                                "success", ms: 8000)
            }
        }
    }

    private static let timer = Repeater()

    /// The loop: runs whether or not the pane is open — the pane is a window
    /// onto it, not the thing itself.
    static func startMonitorLoop() {
        timer.stop()
        if monitorCount() == 0 { return }
        timer.start(every: Double(monitorMinutes()) * 60) { Task { await checkNow(quiet: false) } }
    }

    static func setMonitorMinutes(_ minutes: Int) {
        Store.shared.setSetting("requestMonitorMinutes", minutes)
        startMonitorLoop()
    }

    // MARK: The pane

    /// `autoOpenPane`: only when asked for (`settings.requestMonitorAutoOpen`);
    /// "it was open when you quit" does not count.
    static func autoOpenPane() -> Bool { TUIData.store.settingJSON("requestMonitorAutoOpen").bool == true }

    static func isPaneOpen(_ w: WindowModel) -> Bool { w.feature(ReqMonitorPane.self).open }

    static func toggle(_ w: WindowModel?) {
        guard let w = w ?? WindowManager.shared.focused else { return }
        if isPaneOpen(w) { closePane(w) } else { openPane(w) }
    }

    static func openPane(_ w: WindowModel?) {
        guard let w = w ?? WindowManager.shared.focused else { return }
        let pane = w.feature(ReqMonitorPane.self)
        if pane.open {
            // A 400 ms blink: it is already here.
            pane.flash = true
            after(0.4) { pane.flash = false }
            return
        }
        pane.open = true
        Store.shared.setSetting("requestMonitorOpen", true)
        // Opening it is a reason to look.
        if monitorCount() > 0 && nowMs() - ReqMonitorState.shared.lastRun > Double(monitorMinutes()) * 60000 {
            Task { await checkNow(quiet: true) }
        }
    }

    static func closePane(_ w: WindowModel) {
        w.feature(ReqMonitorPane.self).open = false
        Store.shared.setSetting("requestMonitorOpen", false)
    }

    /// `addDialog`: a cluster, then its requestable resources.
    static func addDialog(_ w: WindowModel?) {
        let profiles = Inventory.shared.liveProfiles
        if profiles.isEmpty { TUIStatus.toast("Log in to a cluster first", "error"); return }
        let go: (TeleportProfile) -> Void = { p in
            Task { @MainActor in
                guard let picked = await RequestPicker.pickResources(p, opts: .init(title: "Monitor requestable resources",
                                                                                    subtitle: TUI.name(p), confirmLabel: "Monitor selected"),
                                                                     window: w), !picked.isEmpty else { return }
                addToMonitor(picked, p)
                startMonitorLoop()
            }
        }
        if profiles.count == 1 { go(profiles[0]); return }
        CtxMenu.show(profiles.map { p in CtxItem(TUI.name(p)) { go(p) } } + [.sep, CtxItem("Cancel") {}])
    }

    /// `addForProfile`: from a cluster already chosen; unticking stops
    /// monitoring, except for what has gone (it cannot be offered to tick).
    static func addForProfile(_ p: TeleportProfile, window: WindowModel? = nil) async {
        let already = monitored().filter { ReqMonitorLogic.belongs($0, proxy: p.proxy, home: p.homeDir) }
            .compactMap { ReqResource(json: $0) }
        guard let picked = await RequestPicker.pickResources(p, preselected: already,
                                                             opts: .init(title: "Monitor requestable resources",
                                                                         subtitle: TUI.name(p), confirmLabel: "Monitor selected"),
                                                             window: window) else { return }
        let rest = ReqMonitorLogic.reconcileForProfile(monitored(), proxy: p.proxy, home: p.homeDir, pickedIds: picked.map(\.id))
        if rest.count != monitored().count { save(rest) }
        addToMonitor(picked, p)
        startMonitorLoop()
    }

    /// Called once at launch (`initReqMonitor`).
    static func install() {
        startMonitorLoop()
        Slots.overlays.append { w in AnyView(ReqMonitorOverlay(window: w)) }
        if autoOpenPane() {
            var done = false
            WindowManager.shared.didOpen.append { w, _ in
                if done { return }
                done = true
                after(0.3) { openPane(w) }
            }
        }
        // A first pass shortly after launch, so an overnight disappearance is
        // on screen when you sit down.
        if monitorCount() > 0 { after(8) { Task { await checkNow(quiet: false) } } }
    }
}

/// What the pane shows about the last check.
@MainActor
@Observable
final class ReqMonitorState {
    static let shared = ReqMonitorState()
    var checking = false
    var lastRun: Double = 0
    var lastErrors: [ReqMonitor.SearchError] = []
}

/// Per-window: whether this window's pane is open.
@MainActor
@Observable
final class ReqMonitorPane: WindowFeature {
    var open = false
    var flash = false
    init(window: WindowModel) {}
}

// MARK: - Pure logic (tested)

/// The decisions worth being sure about, apart from any UI (the exported
/// pure functions of reqmonitor.js).
enum ReqMonitorLogic {
    /// One empty answer marks nothing; a second ten minutes later is believed.
    static let emptyCorroborationMs: Double = 10 * 60000
    static let defaultMinutes = 5

    /// `r.home || null`.
    static func home(_ r: JSON) -> String? { r["home"].stringish?.nilIfEmpty }

    /// `monitorMinutes`: 1…60, default 5.
    static func monitorMinutes(_ v: JSON) -> Int {
        let n: Double? = {
            switch v {
            case .number(let d): return d
            case .string(let s): return Double(s.trimmed.isEmpty ? "0" : s)
            case .bool(let b): return b ? 1 : 0
            default: return nil
            }
        }()
        guard let n, n.isFinite, n > 0 else { return defaultMinutes }
        return min(60, max(1, Int(n.rounded(.toNearestOrAwayFromZero))))
    }

    /// `monitorKey`: id + the profile it was found through.
    static func monitorKey(_ r: JSON) -> String {
        monitorKey(proxy: r["proxy"].stringish, home: home(r), id: r["id"].stringish)
    }

    static func monitorKey(proxy: String?, home: String?, id: String?) -> String {
        "\(proxy ?? "")\u{0}\(home ?? "")\u{0}\(id ?? "")"
    }

    static func belongs(_ r: JSON, proxy: String?, home h: String?) -> Bool {
        (r["proxy"].stringish ?? "") == (proxy ?? "") && home(r) == h?.nilIfEmpty
    }

    /// `record`: everything worth keeping about a resource that may vanish.
    static func record(_ r: ReqResource, profile p: TeleportProfile, now: Double = nowMs()) -> JSON {
        [
            "id": .string(r.id), "kind": .string(r.kind.nilIfEmpty ?? "node"),
            "name": .string(r.name.nilIfEmpty ?? r.uuid.nilIfEmpty ?? r.id), "uuid": .string(r.uuid),
            "cluster": .string(r.cluster.nilIfEmpty ?? p.cluster), "proxy": .string(p.proxy),
            "home": JSON(p.homeDir.nilIfEmpty), "labels": .object(r.labels.mapValues { .string($0) }),
            "addedAt": .number(now), "lastSeen": .number(now), "lastCheck": .number(now), "missingSince": .null,
        ]
    }

    struct Group: Equatable {
        var proxy: String
        var home: String?
        var kind: String
        var items: [JSON]
    }

    /// `groupsOf`: one search per proxy + home + kind.
    static func groupsOf(_ items: [JSON]) -> [Group] {
        var order: [String] = []
        var groups: [String: Group] = [:]
        for r in items {
            let kind = r["kind"].stringish?.nilIfEmpty ?? "node"
            let key = groupStatusKey(proxy: r["proxy"].stringish, home: home(r), kind: kind)
            if groups[key] == nil {
                order.append(key)
                groups[key] = Group(proxy: r["proxy"].stringish ?? "", home: home(r), kind: kind, items: [])
            }
            groups[key]!.items.append(r)
        }
        return order.map { groups[$0]! }
    }

    static func groupStatusKey(proxy: String?, home: String?, kind: String?) -> String {
        "\(proxy ?? "")\u{0}\(home ?? "")\u{0}\(kind?.nilIfEmpty ?? "node")"
    }

    static func groupStatusKey(_ r: JSON) -> String {
        groupStatusKey(proxy: r["proxy"].stringish, home: home(r), kind: r["kind"].stringish)
    }

    /// `rowState`: "ok", "gone" or "unchecked" — the third being "nobody
    /// could look", which is neither good news nor bad.
    static func rowState(_ r: JSON, status: JSON, minutes: Int, now: Double) -> String {
        let st = status[groupStatusKey(r)]
        if (st["failAt"].double ?? 0) > (st["okAt"].double ?? 0) { return "unchecked" }
        if r["missingSince"].truthy { return "gone" }
        let due = max(3 * Double(minutes) * 60000, 15 * 60000)
        let last = r["lastCheck"].double.flatMap { $0 > 0 ? $0 : nil } ?? r["lastSeen"].double ?? 0
        if now - last > due { return "unchecked" }
        return "ok"
    }

    /// `groupError`: why the last search failed, or "".
    static func groupError(_ r: JSON, status: JSON) -> String {
        let st = status[groupStatusKey(r)]
        return (st["failAt"].double ?? 0) > (st["okAt"].double ?? 0)
            ? (st["error"].stringish?.nilIfEmpty ?? "the cluster could not be searched") : ""
    }

    struct Found { var id: String; var name: String; var labels: [String: String] }

    /// `applySearch`: fold one successful search back into the list. Only
    /// the group searched is touched; `missingSince` is set once and kept.
    static func applySearch(_ items: [JSON], group: Group, resources: [Found], now: Double)
        -> (items: [JSON], gone: [JSON], back: [JSON]) {
        var byId: [String: Found] = [:]
        for f in resources where byId[f.id] == nil { byId[f.id] = f }
        func inGroup(_ r: JSON) -> Bool {
            (r["proxy"].stringish ?? "") == group.proxy && home(r) == group.home?.nilIfEmpty
                && (r["kind"].stringish?.nilIfEmpty ?? "node") == (group.kind.nilIfEmpty ?? "node")
        }
        var gone: [JSON] = [], back: [JSON] = []
        let next = items.map { r -> JSON in
            guard inGroup(r) else { return r }
            if let found = byId[r["id"].stringish ?? ""] {
                var u = r
                u["name"] = .string(found.name.nilIfEmpty ?? r["name"].stringish ?? "")
                u["labels"] = .object(found.labels.mapValues { .string($0) })
                u["lastSeen"] = .number(now)
                u["lastCheck"] = .number(now)
                u["missingSince"] = .null
                if r["missingSince"].truthy { back.append(u) }
                return u
            }
            var u = r
            u["lastCheck"] = .number(now)
            if !r["missingSince"].truthy {
                u["missingSince"] = .number(now)
                gone.append(u)
            }
            return u
        }
        return (next, gone, back)
    }

    /// `reconcileForProfile`: what the monitor holds for one cluster after the
    /// picker comes back — a gone resource survives being "unticked".
    static func reconcileForProfile(_ items: [JSON], proxy: String?, home h: String?, pickedIds: [String]) -> [JSON] {
        let keep = Set(pickedIds)
        return items.filter { r in
            !belongs(r, proxy: proxy, home: h) || keep.contains(r["id"].stringish ?? "") || r["missingSince"].truthy
        }
    }

    /// `ago`: "40s", "4m", "2h", "3d"; "" for nothing.
    static func ago(_ ms: Double?, now: Double = nowMs()) -> String {
        guard let ms, ms > 0 else { return "" }
        let secs = Int(max(0, ((now - ms) / 1000).rounded()))
        if secs < 90 { return "\(secs)s" }
        let mins = Int((Double(secs) / 60).rounded())
        if mins < 90 { return "\(mins)m" }
        let hours = Int((Double(mins) / 60).rounded())
        if hours < 48 { return "\(hours)h" }
        return "\(Int((Double(hours) / 24).rounded()))d"
    }

    /// `missingDetail`: what the cluster will not be able to tell you later.
    static func missingDetail(_ r: JSON, now: Double = nowMs()) -> String {
        let labels = r["labels"].entries.filter { !$0.key.hasPrefix("teleport.internal/") }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.stringish ?? "")" }
        let lastSeen = r["lastSeen"].double ?? 0
        let uuid = r["uuid"].stringish ?? ""
        return [
            r["missingSince"].truthy
                ? "Not in tsh request search. Last confirmed \(localeString(lastSeen)) (\(ago(r["missingSince"].double, now: now)) ago)."
                : "Requestable. Last confirmed \(lastSeen > 0 ? localeString(lastSeen) : "not yet").",
            "id: \(r["id"].stringish ?? "")",
            !uuid.isEmpty && uuid != r["name"].stringish ? "node id: \(uuid)" : "",
            r["cluster"].stringish?.nilIfEmpty.map { "cluster: \($0)" } ?? "",
            r["proxy"].stringish?.nilIfEmpty.map { "proxy: \($0)" } ?? "",
            labels.isEmpty ? "" : "labels: \(labels.joined(separator: ", "))",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `uncheckedDetail`: the tooltip for a resource nobody has been able to ask about.
    static func uncheckedDetail(_ r: JSON, status: JSON) -> String {
        let why = groupError(r, status: status)
        let lastSeen = r["lastSeen"].double ?? 0
        return [
            "Not checked. The cluster could not be searched, so this says nothing",
            "about the resource — only that nobody has been able to look.",
            why.isEmpty ? "" : "reason: \(why)",
            "Last confirmed \(lastSeen > 0 ? localeString(lastSeen) : "never")",
            r["missingSince"].truthy
                ? "It was absent from the last search that worked (\(localeString(r["missingSince"].double ?? 0)))." : "",
            "id: \(r["id"].stringish ?? "")",
            r["cluster"].stringish?.nilIfEmpty.map { "cluster: \($0)" } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `shortReason`: why it could not be confirmed, in three or four words.
    static func shortReason(_ r: JSON, status: JSON) -> String {
        let why = groupError(r, status: status)
        if why.isEmpty { return "not checked recently" }
        return why.contains("returned nothing") ? "the search came back empty" : "cluster unreachable"
    }

    static func localeString(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static let kindLabels: [String: String] = [
        "node": "server", "app": "application", "db": "database", "kube_cluster": "kube cluster",
        "windows_desktop": "windows desktop", "linux_desktop": "linux desktop", "user_group": "user group",
        "saml_idp_service_provider": "SAML app", "git_server": "git server",
        "aws_ic_account": "AWS account", "aws_ic_account_assignment": "AWS assignment",
    ]
}

// MARK: - The floating pane

/// Drawn over the window (Slots.overlays), draggable by its head, kept on
/// screen; where it was left is `settings.requestMonitorPos`.
private struct ReqMonitorOverlay: View {
    let window: WindowModel
    @StateObject private var drag = Local<CGSize>(.zero)

    var body: some View {
        let pane = window.feature(ReqMonitorPane.self)
        if pane.open {
            GeometryReader { geo in
                let w: CGFloat = 340
                let pos = Store.shared.settingJSON("requestMonitorPos")
                let bx = min(max(8, CGFloat(pos["x"].double ?? Double(geo.size.width - w - 24))), max(8, geo.size.width - w - 8))
                let by = min(max(34, CGFloat(pos["y"].double ?? 90)), max(34, geo.size.height - 120))
                let x = min(max(4, bx + drag.value.width), geo.size.width - w - 4)
                let y = min(max(30, by + drag.value.height), geo.size.height - 60)
                ReqMonitorPaneView(window: window, flash: pane.flash, onDrag: { drag.value = $0 }, onDragEnd: {
                    Store.shared.setSettingJSON("requestMonitorPos", ["x": .number(Double(x.rounded())), "y": .number(Double(y.rounded()))])
                    drag.value = .zero
                })
                .frame(width: w)
                .offset(x: x, y: y)
            }
        }
    }
}

private struct ReqMonitorPaneView: View {
    let window: WindowModel
    let flash: Bool
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    var body: some View {
        let pal = Theme.shared.p
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let now = ctx.date.timeIntervalSince1970 * 1000
            let items = ReqMonitor.monitored()
            let status = ReqMonitor.monitorStatus()
            let minutes = ReqMonitor.monitorMinutes()
            let states = items.map { ReqMonitorLogic.rowState($0, status: status, minutes: minutes, now: now) }
            let missing = items.filter { $0["missingSince"].truthy }.count
            let unchecked = states.filter { $0 == "unchecked" }.count
            let st = ReqMonitorState.shared
            VStack(spacing: 0) {
                head(items: items.count, missing: missing, unchecked: unchecked)
                pal.border.frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty { empty(minutes) }
                        ForEach(Array(items.enumerated()), id: \.offset) { i, r in
                            row(r, state: states[i], status: status, now: now)
                        }
                        ForEach(st.lastErrors) { e in
                            let kl = ReqMonitorLogic.kindLabels[e.kind] ?? e.kind
                            Text(e.empty
                                 ? "The search for \(kl)s on \(e.proxy.nilIfEmpty ?? "this cluster") came back empty — nothing was judged missing."
                                 : "Could not search \(kl)s on \(e.proxy.nilIfEmpty ?? "this cluster") — nothing was judged missing.")
                                .font(.system(size: 10.5)).foregroundStyle(pal.amber)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 5).help(e.error)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                pal.border.frame(height: 1)
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { minutes }, set: { ReqMonitor.setMonitorMinutes($0) })) {
                        ForEach([1, 5, 15, 30, 60], id: \.self) { m in Text(m == 60 ? "hourly" : "every \(m)m").tag(m) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 110).help("How often the search is run")
                    Spacer()
                    Text(st.checking ? "checking…" : st.lastRun > 0 ? "checked \(ReqMonitorLogic.ago(st.lastRun, now: now)) ago" : "not checked yet")
                        .font(.system(size: 10.5)).foregroundStyle(pal.muted)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(pal.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(flash ? pal.accent : pal.border, lineWidth: flash ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .animation(.easeOut(duration: 0.15), value: flash)
        }
    }

    private func head(items: Int, missing: Int, unchecked: Int) -> some View {
        let pal = Theme.shared.p
        return HStack(spacing: 6) {
            Text("Requestable resources").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            if missing > 0 { TUITag(text: "\(missing) missing", kind: .gone, help: "\(missing) no longer in the search") }
            if unchecked > 0 {
                TUITag(text: "\(unchecked) unchecked", kind: .stale, help: "The cluster could not be searched — nothing here is being confirmed")
            }
            if missing == 0 && unchecked == 0 { Badge(text: String(items)) }
            Spacer()
            Button("\u{21BB}") { Task { await ReqMonitor.checkNow() } }.buttonStyle(.icon).help("Check now")
            Button("+") { ReqMonitor.addDialog(window) }.buttonStyle(.icon).help("Monitor more requestable resources…")
            Button("\u{00D7}") { ReqMonitor.closePane(window) }.buttonStyle(.icon).help("Close this pane (monitoring carries on)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(pal.panel2)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2).onChanged { onDrag($0.translation) }.onEnded { _ in onDragEnd() })
    }

    private func empty(_ minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing is being monitored yet.").font(.system(size: 12))
            MiscHint(text: "Pick resources you expect to be able to request. Every \(minutes) minutes the search is run again, "
                     + "and anything that stops being offered is listed here rather than discovered when you need it.")
            Button("Choose resources…") { ReqMonitor.addDialog(window) }.buttonStyle(.ghost).padding(.top, 3)
        }
        .padding(12)
    }

    private func row(_ r: JSON, state: String, status: JSON, now: Double) -> some View {
        let pal = Theme.shared.p
        let gone = state == "gone", unsure = state == "unchecked"
        let lastSeen = r["lastSeen"].double ?? 0
        let when: String = gone
            ? " — missing \(ReqMonitorLogic.ago(r["missingSince"].double, now: now)), last confirmed \(ReqMonitorLogic.ago(lastSeen, now: now)) ago"
            : unsure
            ? " — \(ReqMonitorLogic.shortReason(r, status: status)), last confirmed \(lastSeen > 0 ? ReqMonitorLogic.ago(lastSeen, now: now) + " ago" : "never")"
            : lastSeen > 0 ? " — confirmed \(ReqMonitorLogic.ago(lastSeen, now: now)) ago" : " — not checked yet"
        let kind = r["kind"].stringish ?? "node"
        let meta = [ReqMonitorLogic.kindLabels[kind] ?? kind, r["cluster"].stringish ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let dull = #"^(uptime|stats|hostname)$"#
        let tags = tuiLabelEntries(r["labels"].entries.compactMapValues(\.stringish))
            .filter { !TPText.test(dull, String($0.0.split(separator: "/").last ?? "")) }
        let stateColor = gone ? pal.red : unsure ? pal.amber : pal.green
        return HStack(alignment: .top, spacing: 8) {
            TUIDot(color: gone ? pal.red : unsure ? pal.amber : (lastSeen > 0 ? pal.green : nil)).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(r["name"].stringish ?? "").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(meta).font(.system(size: 10.5)).foregroundStyle(pal.muted)
                (Text(gone ? "\u{2298} not requestable" : unsure ? "? not checked" : "\u{2713} requestable").foregroundStyle(stateColor)
                    + Text(when).foregroundStyle(pal.muted))
                    .font(.system(size: 10.5))
                if !tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(tags.prefix(3)), id: \.0) { t in
                            TUILabelChip(k: t.0, v: t.1.count > 14 ? String(t.1.prefix(13)) + "…" : t.1)
                        }
                        if tags.count > 3 { TUITag(text: "+\(tags.count - 3)") }
                    }
                }
            }
            Spacer(minLength: 0)
            Button("\u{00D7}") { ReqMonitor.removeFromMonitor(ReqMonitorLogic.monitorKey(r)) }
                .buttonStyle(.icon).help("Stop monitoring this one")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(gone ? pal.red.opacity(0.07) : Color.clear)
        .help(unsure ? ReqMonitorLogic.uncheckedDetail(r, status: status) : ReqMonitorLogic.missingDetail(r, now: now))
        .overlay(alignment: .bottom) { pal.borderSoft.frame(height: 1) }
    }
}
