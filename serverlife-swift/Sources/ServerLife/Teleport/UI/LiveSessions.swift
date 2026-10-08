import AppKit
import SwiftUI

/// livesessions.js: sessions going on right now in a cluster, and a way into
/// the ones with a terminal (watch, join, moderate) in a local tab running
/// `tsh join` / `tsh kube join`.
@MainActor
enum LiveSessionsUI {
    static let modes: [(mode: String, label: String, title: String)] = [
        ("observer", "Watch", "Observer: see everything, type nothing"),
        ("peer", "Join", "Peer: type alongside whoever is in it"),
        ("moderator", "Moderate", "Moderator: watch, with the power to end it — what a moderated session waits for"),
    ]

    static let kindLabel = ["ssh": "ssh", "k8s": "kube", "db": "database", "app": "app", "desktop": "desktop"]

    /// "3m", "2h 5m" — how long a session has been going.
    static func age(_ created: String?, now: Double = nowMs()) -> String {
        guard let t = TPText.parseDate(created) else { return "" }
        let mins = max(0, Int(((now - t) / 60000).rounded()))
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        return h < 24 ? "\(h)h \(mins % 60)m" : "\(h / 24)d \(h % 24)h"
    }

    /// `joinSession`: tsh does the joining, so its own words land in the tab.
    static func join(_ s: ActiveSession, mode: String, proxy: String?, home: String?, window: WindowModel? = nil) {
        do {
            let cmd = try Teleport.joinCommand(s.id, proxy: proxy, cluster: s.cluster, kind: s.kind, mode: mode, home: home)
            let verb = mode == "observer" ? "watching" : mode == "moderator" ? "moderating" : "joined"
            cmd.open(title: "\u{21C4} \(s.target.nilIfEmpty ?? String(s.id.prefix(8))) · \(verb)", window: window)
            TUIStatus.show("\(verb.prefix(1).uppercased() + verb.dropFirst()) session \(s.id.prefix(8))")
        } catch {
            TUIStatus.toast(error.localizedDescription, "error")
        }
    }

    /// The command a person would type, for the clipboard.
    static func joinCommandLine(_ s: ActiveSession, mode: String, proxy: String?) -> String {
        (["tsh", proxy?.nilIfEmpty.map { "--proxy=\($0)" }] + (s.kind == "k8s" ? ["kube", "join"] : ["join"])
            + ["--mode=\(mode)", s.cluster.nilIfEmpty.map { "--cluster=\($0)" }, s.id]).compactMap { $0 }.joined(separator: " ")
    }

    /// `openActiveSessions({ proxy, home, match, title, subtitle })`. `match`
    /// narrows the list to one machine by any of its names.
    static func open(proxy: String?, home: String? = nil, match: [String]? = nil, title: String = "Active sessions",
                     subtitle: String? = nil, window: WindowModel? = nil) {
        let m = LiveSessionsModel(proxy: proxy, home: home, match: match, window: window)
        m.load()
        TUIModal.show(window, title: title, width: 860, height: 520, autosave: "livesessions") { handle in
            m.handle = handle
            return LiveSessionsView(m: m, title: title, subtitle: subtitle ?? proxy ?? "")
        }
    }

    /// For a host: a beam is tracked as `beam-<uuid>`, a node by its names.
    static func open(for host: Host, window: WindowModel? = nil) {
        if host.isBeam, let b = Inventory.shared.beamsFor(host.proxy ?? "").first(where: { $0.id == host.name }) {
            BeamsUI.activeSessions(b, window: window)
            return
        }
        open(proxy: host.proxy, home: host.home, match: [host.name, host.hostname, host.uuid].compactMap { $0 },
             title: "Active sessions on \(host.name)", subtitle: host.cluster ?? host.proxy, window: window)
    }
}

@MainActor
final class LiveSessionsModel: ObservableObject {
    let proxy: String?
    let home: String?
    let match: [String]?
    let window: WindowModel?
    weak var handle: ModalHandle?
    @Published var loading = true
    @Published var result: TshList<ActiveSession>?

    init(proxy: String?, home: String?, match: [String]?, window: WindowModel?) {
        self.proxy = proxy; self.home = home; self.match = match; self.window = window
    }

    func load() {
        loading = true
        let px = proxy, h = home
        Task { @MainActor in
            self.result = await Teleport.listActiveSessions(proxy: px, home: h)
            self.loading = false
        }
    }

    var shown: [ActiveSession] {
        let all = result?.items ?? []
        guard let match else { return all }
        let names = Set(match.filter { !$0.isEmpty }.map { $0.lowercased() })
        return all.filter { s in [s.hostname, s.address, s.target].contains { !$0.isEmpty && names.contains($0.lowercased()) } }
    }

    func join(_ s: ActiveSession, _ mode: String) {
        handle?.close()
        LiveSessionsUI.join(s, mode: mode, proxy: proxy, home: home, window: window)
    }

    func rowMenu(_ s: ActiveSession) {
        var items: [CtxItem] = [.heading(s.target.nilIfEmpty ?? s.id)]
        if s.joinable {
            items += LiveSessionsUI.modes.map { m in
                CtxItem("\(m.label) (\(m.mode))", title: m.title) { [weak self] in self?.join(s, m.mode) }
            }
        } else {
            items.append(CtxItem("A \(LiveSessionsUI.kindLabel[s.kind] ?? s.kind) session cannot be joined from a terminal", disabled: true))
        }
        items.append(.sep)
        items.append(CtxItem("Copy session id") { Clipboard.write(s.id); TUIStatus.show("Copied " + s.id) })
        if s.joinable {
            items.append(CtxItem("Copy the join command") { [proxy] in
                Clipboard.write(LiveSessionsUI.joinCommandLine(s, mode: "observer", proxy: proxy))
                TUIStatus.show("Copied")
            })
        }
        CtxMenu.show(items)
    }
}

private struct LiveSessionsView: View {
    @ObservedObject var m: LiveSessionsModel
    let title: String
    let subtitle: String

    var body: some View {
        DialogScaffold(title: title, subtitle: subtitle) {
            content
        } footer: {
            Button("Refresh") { m.load() }.buttonStyle(.ghost)
            Button("Close") { m.handle?.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var content: some View {
        let pal = Theme.shared.p
        if m.loading {
            TUIEmpty(lines: ["Asking the cluster…"])
        } else if let r = m.result, !r.ok {
            TUIEmpty(lines: [r.error ?? ""], error: true)
        } else if m.shown.isEmpty {
            TUIEmpty(lines: [m.match != nil ? "Nothing is going on here right now." : "No sessions are in progress on this cluster."])
        } else {
            VStack(spacing: 2) {
                ForEach(m.shown, id: \.id) { s in
                    let who = s.participants.isEmpty ? s.owner
                        : s.participants.map { !$0.mode.isEmpty && $0.mode != "peer" ? "\($0.user) (\($0.mode))" : $0.user }.joined(separator: ", ")
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(s.target.nilIfEmpty ?? "(no target)").font(.system(size: 12.5))
                                TUITag(text: LiveSessionsUI.kindLabel[s.kind] ?? s.kind)
                                if s.state != "running" {
                                    TUITag(text: s.state, kind: .warn, help: s.state == "pending" ? "Waiting for a moderator before it starts" : nil)
                                }
                            }
                            Text([s.login.isEmpty ? "" : "as \(s.login)", who, s.command, String(s.id.prefix(8))]
                                .filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                .font(.system(size: 11)).foregroundStyle(pal.muted).help(s.reason)
                        }
                        Spacer(minLength: 0)
                        Text(LiveSessionsUI.age(s.created)).font(.system(size: 11)).foregroundStyle(pal.muted)
                            .frame(width: 64, alignment: .trailing)
                        if s.joinable {
                            ForEach(LiveSessionsUI.modes, id: \.mode) { md in
                                Button(md.label) { m.join(s, md.mode) }.buttonStyle(.ghostSmall).help(md.title)
                            }
                        } else {
                            Text("not joinable from here").font(.system(size: 11)).foregroundStyle(pal.muted)
                                .frame(width: 150, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(pal.panel2))
                    .onRightClick { m.rowMenu(s) }
                }
            }
        }
    }
}
