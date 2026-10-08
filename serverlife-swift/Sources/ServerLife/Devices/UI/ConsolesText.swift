import Foundation

/// The pure parts of tmux.js, vnc.js and the console openers: wording,
/// sizing and the shape conversions, kept apart so they can be tested
/// without a window.
enum ConsolesText {
    // MARK: tmux

    /// `host.name || host.alias || fallback`.
    static func hostLabel(_ h: Host, _ fallback: String = "host") -> String {
        if !h.name.isEmpty { return h.name }
        if let a = h.alias, !a.isEmpty { return a }
        return fallback
    }

    /// "1 window" / "3 windows".
    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// The line the opening overlay shows once attached.
    static func attachedNote(windows: Int, panes: Int) -> String {
        "Attached — \(plural(windows, "window")), \(plural(panes, "pane")). Reading back what is on them…"
    }

    /// One row of the session picker: `work — 2 windows, attached elsewhere`.
    static func sessionOption(_ s: TmuxSessionInfo) -> String {
        "\(s.name) — \(plural(s.windows, "window"))\(s.attached ? ", attached elsewhere" : "")"
    }

    /// What a session name may not be (tmux addresses windows and panes with
    /// `:` and `.`, so a name holding one is ambiguous).
    static func validateSessionName(_ v: String) -> String? {
        if v.trimmed.isEmpty { return "Give it a name" }
        if v.contains(":") || v.contains(".") { return "A tmux session name cannot contain : or ." }
        return nil
    }

    /// What an ended, detached or lost session is called (`routeTmuxEnded`):
    /// the word on the tab and the pane, the notice's title and its line.
    static func ended(name: String, host: String, reason: String?, alive: Bool?) -> (word: String, title: String, sub: String) {
        let word = alive == false ? "ended" : alive == true ? "detached" : "disconnected"
        let title = alive == false ? "tmux session “\(name)” has ended"
            : alive == true ? "Detached from “\(name)”"
            : "Lost the connection to “\(name)”"
        let sub = alive == false
            ? "Nothing is running in it any more on \(host)."
            : alive == true
                ? "It is still running on \(host), with everything in it."
                : "It may still be running on \(host)\(reason.map { $0.isEmpty ? "" : " (\($0))" } ?? "")."
        return (word, title, sub)
    }

    /// The grey line written into each pane of an ended session.
    static func endedLine(title: String, sub: String) -> String {
        let t = title.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        return "\r\n\u{1b}[90m[\(t) — \(sub)]\u{1b}[0m"
    }

    /// tmux's `[` (a column, "col") and `{` (a row) as Sessions' layout tree.
    static func node(_ t: TmuxLayout?) -> TmuxLayoutNode? {
        guard let t else { return nil }
        if case .pane(_, _, _, _, let p) = t {
            return p.map { .pane($0) }
        }
        let kids = t.children.compactMap { node($0) }
        if kids.isEmpty { return nil }
        return .split(t.dir == "row" ? .row : .col, kids)
    }

    /// How many panes a layout holds (`panesOf`).
    static func paneCount(_ t: TmuxLayout?) -> Int {
        guard let t else { return 0 }
        if t.pane != nil { return 1 }
        return t.children.reduce(0) { $0 + paneCount($1) }
    }

    /// The size of a window as tmux would measure it (`clientSize`): panes side
    /// by side add their widths plus a column for each divider, stacked panes
    /// add their heights plus a row each. Panes with no size yet are left out;
    /// nil when nothing has a size.
    static func clientSize(_ tree: TmuxLayout?, size: (String) -> (cols: Int, rows: Int)) -> (cols: Int, rows: Int)? {
        func measure(_ n: TmuxLayout) -> (cols: Int, rows: Int) {
            if let p = n.pane { return size(p) }
            let kids = n.children.map(measure).filter { $0.cols > 0 && $0.rows > 0 }
            if kids.isEmpty { return (0, 0) }
            if n.dir == "row" {
                return (kids.reduce(0) { $0 + $1.cols } + kids.count - 1, kids.map(\.rows).max() ?? 0)
            }
            return (kids.map(\.cols).max() ?? 0, kids.reduce(0) { $0 + $1.rows } + kids.count - 1)
        }
        guard let tree else { return nil }
        let s = measure(tree)
        return s.cols > 0 && s.rows > 0 ? s : nil
    }

    /// A captured screen, ready to write into a pane (`primePane`): trailing
    /// blank rows dropped, so the cursor is not forty lines below the text.
    static func primeText(_ captured: String) -> String? {
        var t = captured
        while let last = t.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            t.unicodeScalars.removeLast()
        }
        return t.isEmpty ? nil : t.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }

    /// What tmux pane `%3`'s title says: window and host, and on the long
    /// form the pane id (`paneTitle` for kind tmux).
    static func tmuxPaneTitle(window: String?, host: String?, pane: String?, long: Bool) -> String {
        let label = [window, host].compactMap { ($0?.isEmpty ?? true) ? nil : $0 }.joined(separator: " \u{00b7} ")
        if long { return "\(label) \u{00b7} tmux \(pane ?? "")".trimmed }
        return label.isEmpty ? "tmux" : label
    }

    static let layouts: [(name: String, label: String)] = [
        ("even-horizontal", "Side by side"),
        ("even-vertical", "Stacked"),
        ("main-horizontal", "One big on top, the rest below"),
        ("main-vertical", "One big on the left, the rest beside it"),
        ("tiled", "Tiled grid"),
    ]

    // MARK: Consoles

    /// What a console's tab is called: its name, else `host:port` for telnet
    /// or the device path.
    static func deviceTitle(_ spec: JSON) -> String {
        if let n = spec["name"].string, !n.isEmpty { return n }
        if spec["kind"].string == "telnet" {
            let h = spec["host"].stringish ?? spec["hostname"].stringish ?? ""
            let port = spec["port"].int ?? spec["devicePort"].int ?? 23
            return "\(h):\(port > 0 ? port : 23)"
        }
        return spec["path"].string?.nilIfEmpty ?? "serial"
    }

    /// The banner a serial console starts with (telnet prints its own).
    static func deviceGreeting(kind: String, label: String) -> String {
        "[\(kind == "telnet" ? "telnet" : "serial") — \(label)]"
    }

    /// A row in the `+` picker for a port.
    static func serialPortMeta(_ p: SerialPortInfo) -> String {
        [p.label, "115200 8N1"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Where an RDP connection went.
    static func rdpOpened(_ name: String, client: String) -> String {
        "\(name) opened in \(client == "mstsc" ? "Remote Desktop Connection" : client == "system" ? "your Remote Desktop client" : client)"
    }

    // MARK: VNC

    static func vncTarget(host: String, port: Int?) -> String { "\(host):\((port ?? 0) > 0 ? port! : 5900)" }

    static let vncTunnelHint = "A VNC server usually listens only on localhost. If this one does, open a "
        + "tunnel to it from Tunnels and point this connection at 127.0.0.1 and the "
        + "local port."
}
