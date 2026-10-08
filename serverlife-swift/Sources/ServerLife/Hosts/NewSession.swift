import AppKit
import SwiftUI

/// profiles.js `openNewSessionDialog` (the + / ⌘N launcher spanning recent
/// sessions, this machine's shells and serial ports, saved profiles,
/// Teleport nodes, ssh_config hosts and a typed address) and `pickHost`
/// (the same list for "split with another host").

/// A launcher row.
struct LaunchItem: Identifiable {
    enum Payload {
        case recent(JSON)
        case local(ShellInfo?)
        case serialPort(SerialPortInfo)
        case profile(JSON)
        case host(Host, login: String?)
        case quick(QuickTarget)
        case beam(Host)
    }
    var id: Int
    var kind: String
    var label: String
    var meta: String
    var badge: String
    var group: String?
    var payload: Payload
    /// A recent that failed last time: its error.
    var failed: String?
}

/// What `pickHost` answers (`{kind, host, login}`); `host` is nil for the local shell.
struct HostPick {
    var kind: String
    var host: Host?
    var login: String?
}

@MainActor
enum NewSession {
    // MARK: Descriptions

    /// "4m ago", "yesterday", "3d ago" (profiles.js `fmtAgo`).
    static func ago(_ ms: Double, now: Double = nowMs()) -> String {
        let s = max(0, (now - ms) / 1000)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int((s / 60).rounded()))m ago" }
        if s < 86400 { return "\(Int((s / 3600).rounded()))h ago" }
        if s < 172800 { return "yesterday" }
        return "\(Int((s / 86400).rounded()))d ago"
    }

    /// A recent connection described the way you would say it out loud.
    static func recentMeta(_ r: JSON, now: Double = nowMs()) -> String {
        let when = r["at"].double.flatMap { $0 != 0 ? ago($0, now: now) : nil } ?? ""
        func s(_ k: String) -> String { r[k].truthy ? (r[k].stringish ?? "") : "" }
        let sep = "  \u{00b7}  "
        if r["type"].string == "local" {
            return [s("target").isEmpty ? "local shell" : s("target"), when].filter { !$0.isEmpty }.joined(separator: sep)
        }
        let isTp = r["type"].string == "teleport"
        let host: String = isTp ? (s("node").isEmpty ? s("target") : s("node"))
            : QuickConnect.replace(QuickConnect.re("^[^@]+@"), s("target").isEmpty ? s("node") : s("target"))
        let login = !s("login").isEmpty ? s("login") : (s("target").contains("@") ? s("target").components(separatedBy: "@")[0] : "")
        let who = !login.isEmpty && !host.isEmpty ? "\(login)@\(host)" : (host.isEmpty ? login : host)
        return [who, isTp ? s("cluster") : "", when].filter { !$0.isEmpty }.joined(separator: sep)
    }

    /// The key a recent shares with the inventory row for the same machine.
    static func hostKeyOfRecent(_ r: JSON) -> String {
        func s(_ k: String) -> String { r[k].truthy ? (r[k].stringish ?? "") : "" }
        return "\(s("type"))\u{0}\(s("cluster"))\u{0}\(s("node").isEmpty ? s("label") : s("node"))"
    }

    static func nodeMeta(_ n: Host) -> String {
        [n.cluster ?? "", n.extra["homeName"]?.string ?? "", n.addr ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func sshMeta(_ h: Host) -> String {
        "\(h.user ?? "undefined")@\(h.hostname ?? "undefined"):\(h.port.map(String.init) ?? "undefined")"
    }

    /// Whether the typed text reads like an address worth offering as a quick connect.
    static func typedTarget(_ typed: String) -> QuickTarget? {
        let t = typed.trimmed
        guard !t.isEmpty else { return nil }
        let rest = QuickConnect.replace(QuickConnect.re(#"^(?:ssh|telnet|vnc|rdp)\s+"#, ci: true), t)
        if QuickConnect.test(QuickConnect.re(#"\s"#), rest) { return nil }
        guard let target = QuickConnect.parseTarget(t) else { return nil }
        if target.kind != "ssh" || QuickConnect.test(QuickConnect.re("[@.:]"), t) { return target }
        return nil
    }

    // MARK: The launcher

    static func open(_ window: WindowModel?) {
        let model = NewSessionModel(window: window)
        Modal.sheet(window, title: "New session", width: 620) { handle in
            NewSessionView(model: model, close: { handle.close() })
        }
        model.load()
    }

    /// Act on a chosen row (the dialog is already closed).
    static func choose(_ it: LaunchItem, window: WindowModel?) async {
        switch it.payload {
        case .recent(let r): Profiles.openRecent(r, window: window)
        case .local(let sh):
            // Named shells carry their own title; the default row opens what ⌘T does.
            if let sh { HostsOpen.openLocalShell(window: window, shell: sh.path, title: sh.name) }
            else { HostsOpen.openLocalShell(window: window) }
        case .quick(let t): await QuickConnect.connect(t, window: window)
        case .serialPort(let port):
            do { try await HostsOpen.openDevice(Host.serial, ["kind": "serial", "path": .string(port.path), "name": .string(port.path)], window: window) }
            catch { HToast.error(hostsErrorText(error)) }
        case .profile(let p): await Profiles.launch(p, window: window)
        case .host(let h, let login): HostsOpen.openHost(h, window: window, login: login)
        case .beam(let h): HostsOpen.openHost(h, window: window)
        }
    }

    // MARK: pickHost

    /// Pick a host without opening it. nil when cancelled.
    static func pickHost(_ window: WindowModel?, title: String = "Choose a host", includeLocal: Bool = true,
                         reply: @escaping (HostPick?) -> Void) {
        let model = PickHostModel(includeLocal: includeLocal)
        var answered = false
        let finish: (HostPick?) -> Void = { v in if !answered { answered = true; reply(v) } }
        let h = Modal.sheet(window, title: title, width: 620) { handle in
            PickHostView(model: model, title: title) { pick in finish(pick); handle.close() }
        }
        h.onClose.append { finish(nil) }
    }

    static func beamHost(_ b: Beam) -> Host {
        var h = Host(type: Host.beam, id: "beam:\(b.proxy):\(b.id)", name: b.id)
        h.proxy = b.proxy
        h.home = b.home
        return h
    }
}

@MainActor
final class NewSessionModel: ObservableObject {
    weak var window: WindowModel?
    @Published var search = "" { didSet { active = 0 } }
    @Published var active = 0
    @Published var recent: [JSON] = []
    @Published var shells: [ShellInfo] = []
    @Published var ports: [SerialPortInfo] = []

    init(window: WindowModel?) { self.window = window }

    func load() {
        let limit = Store.shared.setting("recentLimit", 20)
        if limit > 0 { recent = HostsData.listRecent(limit: limit) }
        shells = LocalShells.shared.shells()
        Task { @MainActor in ports = await DeviceSessions.shared.listPorts() }
    }

    var items: [LaunchItem] {
        let q = search.trimmed.lowercased()
        var out: [LaunchItem] = []
        func add(_ kind: String, _ label: String, _ meta: String, _ badge: String, _ group: String, _ p: LaunchItem.Payload,
                 failed: String? = nil) {
            out.append(LaunchItem(id: out.count, kind: kind, label: label, meta: meta, badge: badge, group: group, payload: p, failed: failed))
        }
        for r in recent {
            let label = [r["label"], r["node"], r["target"]].first { $0.truthy }?.stringish ?? "session"
            add("recent", label, NewSession.recentMeta(r), r["type"].string == "local" ? "local" : "recent", "Recent", .recent(r),
                failed: r["error"].truthy ? r["error"].stringish : nil)
        }
        let def = shells.first { $0.isDefault }?.name ?? "your shell"
        add("local", "Local shell", "\(def) on this machine", "local", "This machine", .local(nil))
        for sh in shells where !sh.isDefault { add("local", sh.name, sh.path, "local", "This machine", .local(sh)) }
        for port in ports {
            add("serialport", port.path, [port.label, "115200 8N1"].filter { !$0.isEmpty }.joined(separator: " · "),
                "serial", "This machine", .serialPort(port))
        }
        // A host already offered as recent is not offered again below.
        let recentKeys = Set(recent.map(NewSession.hostKeyOfRecent))
        for p in HostsData.profiles {
            add("profile", p["name"].stringish ?? "", Profiles.meta(p), "saved", "All hosts", .profile(p))
        }
        let profiles = Inventory.shared.profiles
        for nodes in Inventory.shared.nodesByKey.values {
            for n in nodes {
                if recentKeys.contains("teleport\u{0}\(n.cluster ?? "")\u{0}\(n.name)") { continue }
                let login = profiles.first { $0.cluster == (n.cluster ?? "") }?.logins.first
                add("teleport", n.name, NewSession.nodeMeta(n), "tsh", "All hosts", .host(n, login: login))
            }
        }
        for h in Inventory.shared.sshHosts {
            if recentKeys.contains("ssh\u{0}\u{0}\(h.alias ?? "")") { continue }
            add("ssh", h.alias ?? h.name, NewSession.sshMeta(h), h.extra["viaTsh"]?.truthy == true ? "tsh" : "ssh",
                "All hosts", .host(h, login: nil))
        }
        if !q.isEmpty { out = out.filter { ($0.label + " " + $0.meta).lowercased().contains(q) } }
        out = Array(out.prefix(200))
        // Typing an address that is in no inventory: offered last.
        if let t = NewSession.typedTarget(search) {
            out.append(LaunchItem(id: out.count, kind: "quick", label: QuickConnect.targetLabel(t),
                                  meta: t.kind == "ssh" ? "connect without saving it" : "open it over \(t.kind), without saving it",
                                  badge: t.kind == "ssh" ? "quick" : t.kind, group: "Quick connect", payload: .quick(t)))
        }
        return out.enumerated().map { i, x in var y = x; y.id = i; return y }
    }
}

private struct NewSessionView: View {
    @ObservedObject var model: NewSessionModel
    let close: () -> Void
    @FocusState private var focused: Bool

    private func choose(_ it: LaunchItem) {
        close()
        let w = model.window
        Task { @MainActor in await NewSession.choose(it, window: w) }
    }

    var body: some View {
        let items = model.items
        DialogScaffold(title: "New session", subtitle: "Enter to connect", width: 620, scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search hosts, clusters, labels…", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .hostsPickerKeys(up: { model.active = max(model.active - 1, 0) },
                                     down: { model.active = max(0, min(model.active + 1, items.count - 1)) },
                                     enter: { if items.indices.contains(model.active) { choose(items[model.active]) } })
                LaunchList(items: items, active: $model.active, onChoose: choose)
            }
        } footer: {
            Button("Quick connect…") {
                // Whatever is in the search box is usually the address already.
                let typed = model.search.trimmed
                close()
                QuickConnect.openDialog(model.window, initial: QuickConnect.parseTarget(typed) != nil ? ["target": typed] : [:])
            }.buttonStyle(.ghost)
            Button("Local shell") { close(); HostsOpen.openLocalShell(window: model.window) }.buttonStyle(.ghost)
            Button("New profile…") { close(); Profiles.openEditor(model.window) }.buttonStyle(.ghost)
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .frame(height: 520)
        .onAppear { after(0.05) { focused = true } }
    }
}

/// The grouped picker list with an active row that follows the keyboard.
struct LaunchList: View {
    let items: [LaunchItem]
    @Binding var active: Int
    var grouped = true
    let onChoose: (LaunchItem) -> Void

    var body: some View {
        HListBox(maxHeight: .infinity) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if items.isEmpty { HEmpty(text: "No matches.") }
                        ForEach(items) { it in
                            if grouped, let g = it.group, it.id == 0 || items[it.id - 1].group != g { HPickerHead(text: g) }
                            HPickerRow(name: it.label, meta: it.meta, active: it.id == active,
                                       onHover: { active = it.id }, onClick: { onChoose(it) }) {
                                if let f = it.failed { HTag(text: "failed", warn: true, help: f) }
                                HTag(text: it.badge)
                            }
                            .id(it.id)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: active) { _, v in proxy.scrollTo(v) }
            }
        }
    }
}

@MainActor
final class PickHostModel: ObservableObject {
    let includeLocal: Bool
    @Published var search = "" { didSet { active = 0 } }
    @Published var active = 0
    init(includeLocal: Bool) { self.includeLocal = includeLocal }

    var items: [(item: LaunchItem, pick: HostPick)] {
        let q = search.trimmed.lowercased()
        var out: [(LaunchItem, HostPick)] = []
        func add(_ kind: String, _ label: String, _ meta: String, _ badge: String, _ pick: HostPick) {
            out.append((LaunchItem(id: out.count, kind: kind, label: label, meta: meta, badge: badge, group: nil,
                                   payload: .local(nil)), pick))
        }
        // A running beam is also a node called beam-<uuid>; it is listed once, below.
        let beamNodes = Inventory.shared.beamNodeNames()
        for nodes in Inventory.shared.nodesByKey.values {
            for n in nodes where !beamNodes.contains(n.name) {
                add("teleport", n.name, NewSession.nodeMeta(n), "tsh",
                    HostPick(kind: "teleport", host: n, login: Profiles.profileForNode(n)?.logins.first))
            }
        }
        for h in Inventory.shared.sshHosts {
            add("ssh", h.alias ?? h.name, NewSession.sshMeta(h), h.extra["viaTsh"]?.truthy == true ? "tsh" : "ssh",
                HostPick(kind: "ssh", host: h, login: nil))
        }
        for list in Inventory.shared.beamsByProxy.values {
            for b in list {
                add("beam", b.id, [b.proxy, Beams.expiresIn(b)].filter { !$0.isEmpty }.joined(separator: " · "), "beam",
                    HostPick(kind: "beam", host: NewSession.beamHost(b), login: nil))
            }
        }
        if includeLocal { add("local", "Local shell", "this machine", "local", HostPick(kind: "local", host: nil, login: nil)) }
        if !q.isEmpty { out = out.filter { ($0.0.label + " " + $0.0.meta).lowercased().contains(q) } }
        return out.prefix(200).enumerated().map { i, x in var y = x.0; y.id = i; return (y, x.1) }
    }
}

private struct PickHostView: View {
    @ObservedObject var model: PickHostModel
    let title: String
    let done: (HostPick?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.items
        DialogScaffold(title: title, subtitle: "Enter to choose", width: 620, scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search hosts, clusters, labels…", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .hostsPickerKeys(up: { model.active = max(model.active - 1, 0) },
                                     down: { model.active = max(0, min(model.active + 1, items.count - 1)) },
                                     enter: { if items.indices.contains(model.active) { done(items[model.active].pick) } })
                LaunchList(items: items.map(\.item), active: $model.active, grouped: false) { it in done(items[it.id].pick) }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .frame(height: 480)
        .onAppear { after(0.05) { focused = true } }
    }
}
