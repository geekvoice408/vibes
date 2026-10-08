import AppKit
import SwiftUI

/// What would be lost by quitting or closing — the port of quitguard.js.
///
/// Only sessions with something on the other end count: a local shell is
/// this machine talking to itself. Dead things do not count either — a pane
/// that says "[session ended]", a connection that failed — or the question
/// teaches people to click Quit without reading.
enum QuitGuard {
    /// A pane, reduced to what the census needs (testable without the UI).
    struct PaneInfo {
        var id: String
        var kind: String          // remote | local | device | tmux | vnc | view
        var connId: String?
        var hasTerm: Bool
        var status: String
        var filesOnly = false
        var title: String?
        var deviceKind: String?   // serial | telnet
        var deviceLabel: String?
    }
    struct ConnInfo { var state: String; var type: String?; var label: String? }
    struct TabInfo { var id: String; var title: String?; var panes: [PaneInfo] }
    struct Live: Equatable { var kind: String; var name: String }

    struct Census {
        var tabs: [TabInfo]
        var conn: (String) -> ConnInfo?
        var forwards: (String) -> Int = { _ in 0 }

        func tab(_ id: String) -> TabInfo? { tabs.first { $0.id == id } }
        func pane(_ id: String) -> (TabInfo, PaneInfo)? {
            for t in tabs { if let p = t.panes.first(where: { $0.id == id }) { return (t, p) } }
            return nil
        }
    }

    /// The live sessions, one per pane except tmux: a tmux tab is one
    /// session on the server, counted once under its own name.
    static func liveSessions(_ s: Census) -> [Live] {
        var out: [Live] = []
        var tmuxTabs = Set<String>()
        for t in s.tabs {
            for p in t.panes {
                guard let e = entry(s, t, p) else { continue }
                if e.kind == "tmux" {
                    if tmuxTabs.contains(t.id) { continue }
                    tmuxTabs.insert(t.id)
                }
                out.append(e)
            }
        }
        return out
    }

    /// What closing these tabs or panes would end. tmux is left out: closing
    /// a tmux tab detaches and leaves it running.
    static func liveSessionsIn(_ s: Census, tabIds: [String] = [], paneIds: [String] = []) -> [Live] {
        var out: [Live] = []
        var seen = Set<String>()
        func consider(_ t: TabInfo?, _ p: PaneInfo?) {
            guard let p, !seen.contains(p.id) else { return }
            seen.insert(p.id)
            guard let t, let e = entry(s, t, p), e.kind != "tmux" else { return }
            out.append(e)
        }
        for id in tabIds { if let t = s.tab(id) { t.panes.forEach { consider(t, $0) } } }
        for id in paneIds { if let (t, p) = s.pane(id) { consider(t, p) } }
        return out
    }

    private static func entry(_ s: Census, _ t: TabInfo, _ p: PaneInfo) -> Live? {
        switch p.kind {
        case "remote":
            // The connection being up is not enough: something has to be
            // using it — a terminal, a files-only browser, or a port forward.
            guard let c = p.connId, let conn = s.conn(c), conn.state == "connected" else { return nil }
            let inUse = (p.hasTerm && p.status == "connected") || p.filesOnly || s.forwards(c) > 0
            if !inUse { return nil }
            return Live(kind: conn.type == "teleport" ? "teleport" : "ssh", name: conn.label ?? t.title ?? "remote session")
        case "tmux":
            return p.hasTerm ? Live(kind: "tmux", name: t.title ?? "tmux") : nil
        case "device":
            guard p.hasTerm, p.status == "connected" else { return nil }
            return Live(kind: p.deviceKind == "telnet" ? "telnet" : "serial", name: p.title ?? p.deviceLabel ?? "console")
        case "vnc":
            return p.status == "connected" ? Live(kind: "vnc", name: p.title ?? "VNC") : nil
        default:
            return nil
        }
    }
}

extension SessionsWindow {
    /// This window, as the census sees it.
    func census() -> QuitGuard.Census {
        let tabsInfo = tabs.map { t in
            QuitGuard.TabInfo(id: t.id, title: t.title, panes: t.paneIds.compactMap { id in
                guard let p = pane(id) else { return nil }
                var kind = p.kind.rawValue
                if p.kind == .view { kind = p.isHosts ? "view" : "vnc" }
                return QuitGuard.PaneInfo(id: p.id, kind: kind, connId: p.connId, hasTerm: p.hasTerm, status: p.status,
                                          filesOnly: p.filesOnly, title: p.title,
                                          deviceKind: p.host?.type ?? p.backend?.kind, deviceLabel: p.host?.label)
            })
        }
        return QuitGuard.Census(tabs: tabsInfo, conn: { id in
            guard SessConn.exists(id) else { return nil }
            return QuitGuard.ConnInfo(state: SessConn.state(id), type: SessConn.type(id), label: SessConnRecords.shared.label(id))
        }, forwards: { SessionHooks.forwardCount?($0) ?? 0 })
    }

    /// Ask before closing what would end a live session (the tab's ×, its
    /// menu, ⌘W). Asks only when something would actually be lost.
    func confirmClosing(tabIds: [String] = [], paneIds: [String] = []) async -> Bool {
        if Store.shared.settingJSON("confirmCloseWithSessions").bool == false { return true }
        let live = QuitGuard.liveSessionsIn(census(), tabIds: tabIds, paneIds: paneIds)
        if live.isEmpty { return true }
        var names: [String] = []
        for l in live { let n = "\(l.name) (\(l.kind))"; if !names.contains(n) { names.append(n) } }
        let what = !paneIds.isEmpty && tabIds.isEmpty ? "this pane" : tabIds.count > 1 ? "these \(tabIds.count) tabs" : "this tab"
        let result: (Bool, Bool) = await withCheckedContinuation { cont in
            var done = false
            let finish: (Bool, Bool) -> Void = { a, b in if !done { done = true; cont.resume(returning: (a, b)) } }
            let h = Modal.sheet(window, title: "Close \(what)?", width: 460) { handle in
                CloseConfirmView(what: what, count: live.count, names: names) { ok, again in finish(ok, again); handle.close() }
            }
            h.onClose.append { finish(false, false) }
        }
        if result.0 && result.1 {
            Store.shared.setSetting("confirmCloseWithSessions", false)
            StatusBus.shared.show("Closing tabs will not ask again — turn it back on in Settings")
        }
        return result.0
    }

    func requestCloseTab(_ tabId: String) async {
        if await confirmClosing(tabIds: [tabId]) { closeTab(tabId) }
    }

    func requestCloseTabs(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        if await confirmClosing(tabIds: ids) { for id in ids { closeTab(id) } }
    }

    func requestClosePane(_ paneId: String) async {
        if await confirmClosing(paneIds: [paneId]) { closePane(paneId) }
    }
}

/// The quit question (main.js `confirmQuit`), asked across every window.
@MainActor
enum QuitConfirm {
    static func confirm() async -> Bool {
        if Store.shared.settingJSON("confirmQuitWithSessions").bool == false { return true }
        let live = SessionsCore.allWindows().flatMap { QuitGuard.liveSessions($0.census()) }
        if live.isEmpty { return true }
        // The same host open in three panes is one name, said once.
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in live { if counts[s.name] == nil { order.append(s.name) }; counts[s.name, default: 0] += 1 }
        let names = order.map { n in counts[n]! > 1 ? "\(n) (×\(counts[n]!))" : n }
        let shown = names.prefix(6)
        let more = names.count - shown.count
        let n = live.count
        var detail = shown.joined(separator: "\n") + (more > 0 ? "\n…and \(more) more" : "")
        detail += "\n\nQuitting disconnects " + (n == 1 ? "it" : "them") + "."
        if live.contains(where: { $0.kind == "tmux" }) { detail += " tmux sessions are detached and keep running on the server." }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(n) session\(n == 1 ? " is" : "s are") still open."
        alert.informativeText = detail
        let quit = alert.addButton(withTitle: "Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return presses the button that loses nothing.
        quit.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        let parent = WindowManager.shared.focused?.nsWindow
        if let parent, parent.isVisible, !parent.isMiniaturized {
            let r = await withCheckedContinuation { cont in
                alert.beginSheetModal(for: parent) { cont.resume(returning: $0) }
            }
            return r == .alertFirstButtonReturn
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct CloseConfirmView: View {
    let what: String
    let count: Int
    let names: [String]
    let done: (Bool, Bool) -> Void
    @StateObject private var again = LocalFlag()

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Close \(what)?", width: 460) {
            VStack(alignment: .leading, spacing: 8) {
                Text(count == 1 ? "A session is open in it, and closing ends it:" : "\(count) sessions are open in it, and closing ends them:")
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names.prefix(8), id: \.self) { Text("•  \($0)").font(.system(size: 12.5)) }
                    if names.count > 8 { Text("•  and \(names.count - 8) more").font(.system(size: 12.5)) }
                }
                .padding(.leading, 6)
                Text("Whatever is running in them stops. A tmux session would keep running — open it in tmux to be able to close the window and come back.")
                    .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                Toggle("Do not ask again", isOn: $again.on).toggleStyle(.checkbox).font(.system(size: 12))
            }
        } footer: {
            Button("Cancel") { done(false, false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Close") { done(true, again.on) }.buttonStyle(.primary)
        }
    }
}
