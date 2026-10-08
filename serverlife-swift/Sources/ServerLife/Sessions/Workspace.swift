import AppKit
import SwiftUI

/// The saved layouts in the store (store.js `saveWorkspace` … `getDefaultLayout`),
/// kept to the original's shapes so sessions.json stays interchangeable.
@MainActor
enum WorkspaceStore {
    static func save(_ ws: JSON?, slot: String) {
        Store.shared.saveWorkspace(ws, slot: slot)
    }

    /// What was saved before this launch, captured at store load: the only
    /// thing ever offered back, so a session opened a moment ago in this run
    /// is never mistaken for last time's.
    private(set) static var atLaunch: JSON = .object([:])
    static func captureAtLaunch() { atLaunch = Store.shared["workspaces"] }

    /// After the first window has made its offer, later windows (a Dock
    /// reopen) read what is saved now: a window closed on purpose has
    /// cleared its slot, and that is the answer.
    static var launchConsumed = false

    static func launchGet(_ slot: String) -> JSON? {
        if launchConsumed { let w = get(slot); return (w?["tabs"].items.isEmpty ?? true) ? nil : w }
        let w = atLaunch[slot]
        return w.isNull || w["tabs"].items.isEmpty ? nil : w
    }

    static func launchList() -> [JSON] {
        if launchConsumed { return list() }
        return Store.workspaceList(atLaunch)
    }

    static func get(_ slot: String) -> JSON? { Store.shared.getWorkspace(slot) }

    /// Every saved window with something in it, in slot order.
    static func list() -> [JSON] { Store.shared.listWorkspaces() }

    static func clear(_ slot: String?) {
        if let slot { atLaunch.removeKey(slot) } else { atLaunch = .object([:]) }
        Store.shared.clearWorkspace(slot)
    }

    struct Layout { var id: String; var name: String; var workspace: JSON; var updatedAt: Double; var isDefault: Bool }

    private static func layout(_ j: JSON) -> Layout {
        Layout(id: j["id"].string ?? "", name: j["name"].stringish ?? "Layout", workspace: j["workspace"],
               updatedAt: j["updatedAt"].double ?? 0, isDefault: j["isDefault"].bool ?? false)
    }

    static func listLayouts() -> [Layout] { Store.shared.listLayouts().map(layout) }

    /// Save (or overwrite by id, else by name) a named layout.
    @discardableResult
    static func saveLayout(id: String?, name: String, workspace: JSON) -> Layout {
        layout(Store.shared.saveLayout(id: id, name: name, workspace: workspace))
    }

    static func deleteLayout(_ id: String) { Store.shared.deleteLayout(id) }

    static func setDefaultLayout(_ id: String?) { Store.shared.setDefaultLayout(id) }

    static func defaultLayout() -> Layout? { listLayouts().first { $0.isDefault } }

    static func countPanes(_ node: JSON) -> Int {
        if node["type"].string == "pane" { return 1 }
        return node["children"].items.reduce(0) { $0 + countPanes($1) }
    }

    static func paneCount(_ ws: JSON) -> Int { ws["tabs"].items.reduce(0) { $0 + countPanes($1["root"]) } }
}

extension SessionsWindow {
    // MARK: Capture and restore

    /// The current tabs and their pane trees.
    func captureWorkspace() -> JSON {
        func describe(_ id: String) -> JSON? {
            guard let p = pane(id) else { return nil }
            if p.isHosts { return ["kind": "hosts", "group": JSON(p.hostsGroup), "title": .string(p.title ?? "Hosts")] }
            switch p.kind {
            case .local:
                return ["kind": "local", "cwd": JSON(p.cwd), "shell": JSON(p.shellName), "blank": .bool(p.blankShell)]
            case .device:
                return ["kind": "device", "spec": p.host?.json ?? .null, "title": JSON(p.title)]
            case .view:
                return ["kind": "vnc", "spec": p.host?.json ?? .null, "title": JSON(p.title)]
            case .tmux:
                return nil
            case .remote:
                guard let connId = p.connId, let rec = SessConnRecords.shared.get(connId) else { return nil }
                return ["kind": "remote", "hostId": .string(rec.hostId), "label": JSON(SessConnRecords.shared.label(connId)),
                        "target": JSON(SessConn.target(connId)), "type": JSON(SessConn.type(connId)),
                        "login": JSON(rec.login), "cwd": JSON(p.cwd)]
            }
        }
        func walk(_ n: PaneNode?) -> JSON? {
            guard let n else { return nil }
            switch n {
            case .pane(let id): return describe(id).map { ["type": "pane", "pane": $0] }
            case .split(let s):
                let kids = s.children.compactMap(walk)
                if kids.isEmpty { return nil }
                if kids.count == 1 { return kids[0] }
                return ["type": "split", "dir": .string(s.dir.rawValue), "children": .array(kids)]
            }
        }
        let list: [JSON] = tabs.compactMap { t in
            guard let root = walk(t.root) else { return nil }
            return ["title": .string(SessConnRecords.shared.label(t.connId) ?? t.title), "kind": .string(t.kind), "root": root]
        }
        let active = max(0, tabs.firstIndex { $0.id == activeTabId } ?? 0)
        return ["tabs": .array(list), "activeIndex": .number(Double(active))]
    }

    func saveWorkspaceNow() {
        guard let slot = window?.id else { return }
        let ws = captureWorkspace()
        WorkspaceStore.save(ws["tabs"].items.isEmpty ? nil : ws, slot: slot)
    }

    /// A saved descriptor found in the live inventory.
    private func resolveHost(_ pane: JSON) -> Host? {
        guard let id = pane["hostId"].string else { return nil }
        return SessionsCore.host(forId: id)
    }

    /// Reopen a saved workspace: the first pane of each tab as the tab, then
    /// a split for each of the rest, in order.
    func restoreWorkspace(_ ws: JSON) async {
        let tabsJ = ws["tabs"].items
        guard !tabsJ.isEmpty else { return }
        var opened = 0, skipped = 0
        restoring = true
        defer { restoring = false; changed() }
        for t in tabsJ {
            var list: [(JSON, PaneSplit.Dir)] = []
            func flatten(_ n: JSON, _ dir: PaneSplit.Dir) {
                if n["type"].string == "pane" { list.append((n["pane"], dir)); return }
                for (i, c) in n["children"].items.enumerated() {
                    flatten(c, i == 0 ? dir : (n["dir"].string == "col" ? .col : .row))
                }
            }
            flatten(t["root"], .row)
            var first = true
            for (pj, dir) in list {
                let kind = pj["kind"].string ?? "remote"
                switch kind {
                case "hosts":
                    var args: [String: Any] = [:]
                    if let g = pj["group"].string { args["groupKey"] = g }
                    if !first { args["split"] = dir.rawValue == "row" ? "right" : "down" }
                    Actions.shared.perform("hosts-pane", window: window, args: args)
                case "device", "vnc":
                    let spec = pj["spec"]
                    if spec.isNull { skipped += 1; continue }
                    var h = Host(json: spec)
                    if spec["type"].isNull, let k = spec["kind"].string { h.type = k }
                    if spec["type"].isNull && spec["kind"].isNull { h.type = kind == "vnc" ? Host.vnc : Host.serial }
                    Actions.shared.perform("\(h.type)-open", window: window, host: h)
                case "local":
                    if first {
                        openLocalShell(cwd: pj["cwd"].string, shell: pj["shell"].string, blank: pj["blank"].truthy)
                    } else {
                        await splitActivePane(dir, SplitOptions(local: true, cwd: pj["cwd"].string, shell: pj["shell"].string,
                                                                blank: pj["blank"].truthy))
                    }
                default:
                    guard let host = resolveHost(pj) else { skipped += 1; continue }
                    // The remote directory is sent as a `cd` once the shell is up.
                    if first {
                        var o = OpenHostOptions(); o.login = pj["login"].string; o.remoteStartPath = pj["cwd"].string
                        await openHost(host, o)
                    } else {
                        await splitActivePane(dir, SplitOptions(host: host, login: pj["login"].string, remoteStartPath: pj["cwd"].string))
                    }
                }
                opened += 1
                first = false
            }
        }
        StatusBus.shared.show(skipped > 0 ? "Restored \(opened) pane(s); \(skipped) could not be reopened" : "Restored \(opened) pane(s)")
    }

    /// Every pane in a saved tab, as `login@host: dir`.
    static func describeTabTargets(_ tab: JSON) -> [String] {
        var out: [String] = []
        func walk(_ n: JSON) {
            if n["type"].string == "pane" {
                let p = n["pane"]
                if p["kind"].string == "local" {
                    let where_ = p["cwd"].string.map { SessionsCore.shortCwd($0) } ?? ""
                    out.append(where_.isEmpty ? "local shell" : "local shell: \(where_)")
                    return
                }
                let target = p["target"].string ?? ""
                let label = p["label"].string ?? ""
                let host = target.contains("@") ? target.split(separator: "@", maxSplits: 1).last.map(String.init) ?? "" : (target.isEmpty ? label : target)
                let login = p["login"].string ?? (target.contains("@") ? String(target.split(separator: "@").first ?? "") : "")
                let who = !login.isEmpty ? "\(login)@\(host)" : (!host.isEmpty ? host : (!label.isEmpty ? label : "unknown host"))
                if let cwd = p["cwd"].string, !cwd.isEmpty { out.append("\(who): \(SessionsCore.shortCwd(cwd))") } else { out.append(who) }
                return
            }
            n["children"].items.forEach(walk)
        }
        walk(tab["root"])
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func describeWindows(_ others: [JSON]) -> String {
        others.map { o in let n = o["tabs"].items.count; return "\(n) tab\(n == 1 ? "" : "s")" }.joined(separator: ", ")
    }

    /// On startup, offer the saved layout back. Declining leaves it saved.
    func offerRestore(options: [String: Any]) async {
        guard let window else { return }
        let slot = window.id
        if options["autoRestore"] as? Bool == true {
            if let mine = WorkspaceStore.launchGet(slot), tabs.isEmpty { await restoreWorkspace(mine) }
            return
        }
        if WindowManager.shared.windows.count > 1 { return }
        defer { WorkspaceStore.launchConsumed = true }
        await SessionHooks.waitForInventory?()
        if !tabs.isEmpty { return }
        let auto = Store.shared.settingJSON("autoRestoreWorkspace").bool == true

        if let def = WorkspaceStore.defaultLayout(), !def.workspace["tabs"].items.isEmpty {
            if auto { await restoreWorkspace(def.workspace); return }
            let open = await Modal.confirm(window, title: "Open your default layout?",
                                           message: "“\(def.name)” — \(def.workspace["tabs"].items.count) tab(s).\n\nEach session is dialled again. Set or clear the default in Session → Layouts → Manage Layouts.",
                                           ok: "Open")
            if open { await restoreWorkspace(def.workspace); return }
        }

        // Something was opened before the offer could be made: that window
        // has started fresh, and the saved layout stays for next launch.
        if !tabs.isEmpty { return }
        let ws = WorkspaceStore.launchGet(slot)
        let openSlots = Set(WindowManager.shared.windows.map(\.id))
        let others = WorkspaceStore.launchList().filter { ($0["slot"].string ?? "") != slot && !openSlots.contains($0["slot"].string ?? "") }
        let mineTabs = ws?["tabs"].items ?? []
        if mineTabs.isEmpty && others.isEmpty { return }

        if auto {
            if let ws, !mineTabs.isEmpty { await restoreWorkspace(ws) }
            reopenOtherWindows(others)
            return
        }
        if mineTabs.isEmpty {
            let n = others.count
            let open = await Modal.confirm(window, title: "Reopen \(n) more window\(n == 1 ? "" : "s")?",
                                           message: SessionsWindow.describeWindows(others) + "\n\nReopening dials each server again, which creates new sessions in the audit log.",
                                           ok: "Reopen")
            if open { reopenOtherWindows(others) }
            return
        }
        guard let ws, tabs.isEmpty else { return }
        let answer: (String, Bool) = await withCheckedContinuation { cont in
            var done = false
            let finish: (String, Bool) -> Void = { a, b in if !done { done = true; cont.resume(returning: (a, b)) } }
            let h = Modal.sheet(window, title: "Reopen your last session?", width: 560) { handle in
                RestoreOfferView(ws: ws, others: others) { answer, always in
                    finish(answer, always)
                    handle.close()
                }
            }
            h.onClose.append { finish("", false) }
        }
        switch answer.0 {
        case "yes":
            if answer.1 { Store.shared.setSetting("autoRestoreWorkspace", true) }
            await restoreWorkspace(ws)
            reopenOtherWindows(others)
        case "no":
            StatusBus.shared.show("Started fresh — your last layout is still saved")
        case let a where a.hasPrefix("one:"):
            let i = Int(a.dropFirst(4)) ?? 0
            StatusBus.shared.show("Reopening that one — the rest of the layout is still saved", seconds: 7)
            let t = ws["tabs"][i]
            await restoreWorkspace(["tabs": [t]])
        default: break
        }
    }

    /// Open the windows saved alongside this one, each on its own slot.
    func reopenOtherWindows(_ others: [JSON]) {
        for o in others {
            guard let slot = o["slot"].string else { continue }
            WindowManager.shared.open(slot: slot, options: ["autoRestore": true])
        }
        if !others.isEmpty {
            StatusBus.shared.show("Reopened \(others.count) more window\(others.count == 1 ? "" : "s")")
        }
    }

    // MARK: Named layouts

    func saveLayoutAs() async {
        let ws = captureWorkspace()
        let tabsJ = ws["tabs"].items
        if tabsJ.isEmpty { StatusBus.shared.toast("Nothing open to save", kind: .error); return }
        let existing = WorkspaceStore.listLayouts()
        let base = tabsJ.count == 1 ? (tabsJ[0]["title"].string ?? "") : "\(tabsJ.count) sessions"
        var suggestion = base
        if existing.contains(where: { $0.name == base }) {
            var n = 2
            while existing.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
            suggestion = "\(base) \(n)"
        }
        guard let name = await MiscUI.prompt(window, title: "Save layout as",
                                             label: "\(tabsJ.count) tab(s), \(WorkspaceStore.paneCount(ws)) pane(s)",
                                             value: suggestion, confirmLabel: "Save",
                                             validate: { $0.trimmed.isEmpty ? "Give the layout a name" : nil }) else { return }
        let n = name.trimmed
        if n.isEmpty { return }
        if let clash = existing.first(where: { $0.name.lowercased() == n.lowercased() }) {
            let ok = await Modal.confirm(window, title: "Replace layout",
                                         message: "A layout called “\(clash.name)” already exists.\n\nSaving will overwrite it.", ok: "Replace")
            if !ok { return }
        }
        let saved = WorkspaceStore.saveLayout(id: nil, name: n, workspace: ws)
        StatusBus.shared.show("Saved layout “\(saved.name)”")
        StatusBus.shared.toast("Layout “\(saved.name)” saved", kind: .ok)
    }

    func loadLayoutDialog() async {
        let layouts = WorkspaceStore.listLayouts()
        if layouts.isEmpty { StatusBus.shared.toast("No saved layouts yet — use Save Layout As…"); return }
        let chosen: WorkspaceStore.Layout? = await withCheckedContinuation { cont in
            var done = false
            let finish: (WorkspaceStore.Layout?) -> Void = { l in if !done { done = true; cont.resume(returning: l) } }
            let h = Modal.sheet(window, title: "Load layout", width: 520) { handle in
                LoadLayoutView(layouts: layouts) { l in finish(l); handle.close() }
            }
            h.onClose.append { finish(nil) }
        }
        guard let chosen else { return }
        await loadLayout(chosen, detail: true)
    }

    func loadLayout(_ l: WorkspaceStore.Layout, detail: Bool) async {
        if !tabs.isEmpty {
            let ok = await Modal.confirm(window, title: "Replace current sessions?",
                                         message: "Close \(tabs.count) open tab(s) and open “\(l.name)”?"
                                            + (detail ? "\n\nCurrent sessions are disconnected." : ""), ok: "Replace")
            if !ok { return }
            for t in tabs { closeTab(t.id) }
        }
        if detail { StatusBus.shared.show("Opening layout “\(l.name)”…", seconds: 0) }
        await restoreWorkspace(l.workspace)
    }

    func manageLayouts() {
        Modal.sheet(window, title: "Layouts", width: 720, height: 460, resizable: true, autosave: "layouts") { handle in
            ManageLayoutsView(window: self, close: { handle.close() })
        }
    }
}

// MARK: - Dialogs

private struct RestoreOfferView: View {
    let ws: JSON
    let others: [JSON]
    let answer: (String, Bool) -> Void
    @StateObject private var always = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let tabs = ws["tabs"].items
        let paneCount = WorkspaceStore.paneCount(ws)
        let saved = ws["savedAt"].double.map { "Saved \(Fmt.date(ms: $0))" }
        DialogScaffold(title: "Reopen your last session?", subtitle: saved, width: 560) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(tabs.count) tab\(tabs.count == 1 ? "" : "s"), \(paneCount) pane\(paneCount == 1 ? "" : "s"):")
                    .font(.system(size: 13))
                VStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                        RestoreRow(tab: t) { answer("one:\(i)", false) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
                Toggle("Always restore without asking", isOn: $always.on).toggleStyle(.checkbox).font(.system(size: 12))
                if !others.isEmpty {
                    Text("Plus \(others.count) more window\(others.count == 1 ? "" : "s"): \(SessionsWindow.describeWindows(others))")
                        .font(.system(size: 12)).foregroundStyle(p.accent)
                }
                Text("Reopening dials each server again, which creates new sessions in the audit log.")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
            }
        } footer: {
            Button("Start fresh") { answer("no", false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Reopen") { answer("yes", always.on) }.buttonStyle(.primary)
        }
    }
}

/// A row reopens itself: usually one of the six is the one you want back.
private struct RestoreRow: View {
    let tab: JSON
    let open: () -> Void
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        let who = SessionsWindow.describeTabTargets(tab)
        let title = tab["title"].string ?? ""
        let n = WorkspaceStore.countPanes(tab["root"])
        let sub = who.joined(separator: ", ")
        Button(action: open) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5))
                    if !who.isEmpty && sub.lowercased() != title.lowercased() {
                        Text(sub).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted)
                    }
                }
                Spacer()
                Text("\(n) pane\(n == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(hover.on ? p.panel3 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help((who + ["", "Click to reopen just this one"]).joined(separator: "\n"))
    }
}

private struct LoadLayoutView: View {
    let layouts: [WorkspaceStore.Layout]
    let choose: (WorkspaceStore.Layout?) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Load layout", subtitle: "\(layouts.count) saved", width: 520) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    ForEach(layouts, id: \.id) { l in
                        Button { choose(l) } label: {
                            HStack {
                                Text(l.name).font(.system(size: 12.5))
                                if l.isDefault { Badge(text: "default") }
                                Spacer()
                                Text("\(l.workspace["tabs"].items.count) tabs · \(WorkspaceStore.paneCount(l.workspace)) panes · \(Fmt.date(ms: l.updatedAt))")
                                    .font(.system(size: 11)).foregroundStyle(p.muted)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                Text("Loading replaces what is open now. Each session is dialled again.")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
            }
        } footer: {
            Button("Cancel") { choose(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }
}

private struct ManageLayoutsView: View {
    let window: SessionsWindow
    let close: () -> Void
    @StateObject private var tick = Local(0)

    var body: some View {
        let p = Theme.shared.p
        let _ = tick.value
        let layouts = WorkspaceStore.listLayouts()
        DialogScaffold(title: "Layouts", subtitle: "Saved arrangements of sessions") {
            VStack(alignment: .leading, spacing: 6) {
                if layouts.isEmpty {
                    Text("No saved layouts yet.").font(.system(size: 12)).foregroundStyle(p.muted)
                }
                ForEach(layouts, id: \.id) { l in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(l.name).font(.system(size: 12.5, weight: .medium))
                                if l.isDefault { Badge(text: "opens by default", color: p.accent) }
                            }
                            Text("\(l.workspace["tabs"].items.count) tabs · \(WorkspaceStore.paneCount(l.workspace)) panes · saved \(Fmt.date(ms: l.updatedAt))")
                                .font(.system(size: 11)).foregroundStyle(p.muted)
                        }
                        Spacer()
                        Button("Load") { Task { await window.loadLayout(l, detail: false) } }.buttonStyle(.ghostSmall)
                        Button(l.isDefault ? "Unset default" : "Set default") {
                            WorkspaceStore.setDefaultLayout(l.isDefault ? nil : l.id)
                            StatusBus.shared.show(l.isDefault ? "Default layout cleared" : "“\(l.name)” opens by default")
                            tick.value += 1
                        }.buttonStyle(.ghostSmall)
                        Button("Rename") {
                            Task {
                                guard let name = await Modal.prompt(window.window, title: "Rename layout", value: l.name, ok: "Rename"),
                                      !name.trimmed.isEmpty else { return }
                                WorkspaceStore.saveLayout(id: l.id, name: name.trimmed, workspace: l.workspace)
                                tick.value += 1
                            }
                        }.buttonStyle(.ghostSmall)
                        Button("Delete") {
                            Task {
                                let ok = await Modal.confirm(window.window, title: "Delete layout", message: "Delete “\(l.name)”?",
                                                             ok: "Delete", destructive: true)
                                if ok { WorkspaceStore.deleteLayout(l.id); tick.value += 1 }
                            }
                        }.buttonStyle(GhostButtonStyle(small: true, destructive: true))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(l.isDefault ? p.accent.opacity(0.08) : p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(l.isDefault ? p.accentDim : p.borderSoft))
                }
            }
        } footer: {
            Button("Save current as…") { close(); Task { await window.saveLayoutAs() } }.buttonStyle(.ghost)
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }
}
