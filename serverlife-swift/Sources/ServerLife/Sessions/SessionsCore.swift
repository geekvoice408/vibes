import AppKit
import SwiftUI

/// Small pure helpers the panes, tabs and layouts share.
@MainActor
enum SessionsCore {
    /// Every window's sessions.
    static func allWindows() -> [SessionsWindow] {
        WindowManager.shared.windows.map { $0.feature(SessionsWindow.self) }
    }

    /// The window (and its sessions) holding a pane.
    static func owner(ofPane id: String) -> SessionsWindow? {
        allWindows().first { $0.panes[id] != nil }
    }

    /// A host descriptor for a host id: the live inventory if it knows it,
    /// else what the connection was dialled with.
    static func host(forId id: String) -> Host? {
        if let h = SessionHooks.hostById?(id) { return h }
        return SessConnRecords.shared.records.values.first { $0.host.id == id }?.host
    }

    /// `paneHostKey`: which host's preferences this pane obeys. A local shell
    /// has no host, and answers nil.
    static func hostKey(of pane: SessionPane) -> String? {
        // A pane with no connection — local, a console, tmux, a screen — has
        // no host's preferences to obey.
        guard pane.kind == .remote, let rec = SessConnRecords.shared.get(pane.connId) else { return nil }
        if let live = SessionHooks.hostById?(rec.hostId) { return live.prefKey }
        return rec.host.prefKey.nilIfEmpty ?? rec.hostId
    }

    /// The colour marked on the host behind a connection (sidebar
    /// `hostColorForConn`).
    static func hostColor(connId: String?) -> Color? {
        guard let rec = SessConnRecords.shared.get(connId) else { return nil }
        let host = SessionHooks.hostById?(rec.hostId) ?? rec.host
        return HostColor.color(Store.shared.settingJSON("hostColors")[host.prefKey].string)
    }

    /// A path short enough for a title: the home directory as `~`, and only
    /// the last couple of segments of anything long.
    nonisolated static func shortCwd(_ p: String?, home: String? = nil) -> String {
        guard var out = p, !out.isEmpty else { return "" }
        let h = home ?? NSHomeDirectory()
        if !h.isEmpty && (out == h || out.hasPrefix(h + "/")) { out = "~" + out.dropFirst(h.count) }
        if out.count <= 24 { return out }
        let parts = out.split(separator: "/").map(String.init)
        return (out.hasPrefix("~") ? "" : "…/") + parts.suffix(2).joined(separator: "/")
    }

    /// `who` for a remote title: login@host, plus the node-id block for a
    /// hostname two nodes share.
    nonisolated static func remoteWho(login: String?, host: String, dupe: String?) -> String {
        let l = login ?? ""
        return (l.isEmpty ? host : "\(l)@\(host)") + (dupe.map { " \u{00b7} \($0)" } ?? "")
    }

    /// The label without its bracketed suffix: "web-1 (prod)" → "web-1".
    nonisolated static func stripBracket(_ label: String) -> String {
        guard let r = try? NSRegularExpression(pattern: "\\s*\\(.*\\)$") else { return label }
        return r.stringByReplacingMatches(in: label, range: NSRange(location: 0, length: (label as NSString).length), withTemplate: "")
    }

    nonisolated static func bracketed(_ label: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: "\\(([^)]+)\\)$"),
              let m = r.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)) else { return nil }
        return (label as NSString).substring(with: m.range(at: 1))
    }

    /// What a pane is: who you are, where you are, and on what.
    static func paneTitle(_ pane: SessionPane?, long: Bool = false) -> String {
        guard let pane else { return "" }
        _ = pane.titleRevision
        if pane.isHosts { return pane.title ?? "Hosts" }
        if pane.kind == .tmux {
            if let t = pane.titleProvider?(pane, long) { return t }
            return pane.title ?? "tmux"
        }
        if pane.kind == .device { return pane.title ?? "console" }
        if pane.kind == .view { return pane.title ?? "screen" }
        if pane.kind == .local, let t = pane.title, pane.attachments["command"] != nil || pane.attachments["named"] != nil { return t }
        let dir = shortCwd(pane.cwd, home: pane.kind == .local ? nil : pane.remoteHome)

        if pane.kind == .local {
            let named = Store.shared.settingJSON("showShellInTitle").bool == true ? pane.shellName : nil
            let shell = named.map { $0 + (pane.blankShell ? " (blank)" : "") } ?? "local"
            return dir.isEmpty ? shell : "\(shell): \(dir)"
        }

        guard let connId = pane.connId, SessConn.exists(connId) || SessConnRecords.shared.get(connId) != nil else {
            return pane.title ?? ""
        }
        let rec = SessConnRecords.shared.get(connId)
        let label = SessConnRecords.shared.label(connId) ?? ""
        let login = rec?.login ?? SessConn.user(connId)
        let host = SessConn.hostname(connId)?.nilIfEmpty ?? stripBracket(label)
        let who = remoteWho(login: login, host: host, dupe: rec?.dupe)
        if long {
            let cluster = SessConn.type(connId) == "teleport" ? (SessConn.cluster(connId) ?? bracketed(label)) : nil
            return [who, dir, cluster.map { "· \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return dir.isEmpty ? who : "\(who): \(dir)"
    }

    /// stripAnsi from connections.js: what a session log is written as.
    nonisolated static func stripAnsi(_ s: String) -> String {
        var out = s
        let pats = ["\u{1b}\\][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)", "\u{1b}\\[[0-9;?]*[ -/]*[@-~]",
                    "\u{1b}[()][A-Za-z0-9]", "\u{1b}[=>]"]
        for p in pats {
            if let r = try? NSRegularExpression(pattern: p) {
                out = r.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
            }
        }
        if let r = try? NSRegularExpression(pattern: "\r(?!\n)") {
            out = r.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "\n")
        }
        return out
    }

    /// Split off a trailing incomplete UTF-8 sequence, so text can be decoded
    /// chunk by chunk without breaking a character in two.
    nonisolated static func splitUTF8(_ d: Data) -> (complete: Data, rest: Data) {
        let bytes = [UInt8](d)
        let n = bytes.count
        guard n > 0 else { return (d, Data()) }
        var i = n - 1
        var back = 0
        while i >= 0 && back < 4 && (bytes[i] & 0xC0) == 0x80 { i -= 1; back += 1 }
        guard i >= 0 else { return (d, Data()) }
        let lead = bytes[i]
        let need: Int = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        if n - i < need { return (Data(bytes[0..<i]), Data(bytes[i..<n])) }
        return (d, Data())
    }

    /// What has been typed on a line looks like it moves the shell.
    nonisolated static func changesDirectory(_ line: String) -> Bool {
        guard let r = try? NSRegularExpression(pattern: "(^|[;&|]\\s*)\\s*(cd|pushd|popd)(\\s|$)") else { return false }
        return r.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    nonisolated static func mfaLabel(_ mode: String) -> String {
        ["platform": "Touch ID", "cross-platform": "security key", "otp": "an OTP code",
         "browser": "the browser", "auto": "automatic"][mode] ?? mode
    }
}
