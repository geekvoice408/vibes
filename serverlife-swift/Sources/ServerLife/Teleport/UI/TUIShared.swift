import AppKit
import SwiftUI

/// Helpers the Teleport tab, the request dialogs and the panes share
/// (teleportpanel.js's small functions, clustermarks.js's reads).
@MainActor
enum TUI {
    // MARK: Profiles

    /// `activeProfile()`: the active live one, else any live one, else the first.
    static func activeProfile() -> TeleportProfile? {
        let ps = Inventory.shared.profiles
        return ps.first { $0.active && !$0.expired } ?? ps.first { !$0.expired } ?? ps.first
    }

    /// The profile an action is about: args `profileKey`, else args `proxy`
    /// (+ `home`), else the context's host, else nil.
    static func profile(from ctx: ActionContext) -> TeleportProfile? {
        let inv = Inventory.shared
        if let key = ctx.arg("profileKey", as: String.self), let p = inv.profile(forKey: key) { return p }
        if let proxy = ctx.arg("proxy", as: String.self)?.nilIfEmpty {
            let home = ctx.arg("home", as: String.self)?.nilIfEmpty
            let ps = inv.profiles
            return ps.first { $0.proxy == proxy && (home == nil || $0.homeDir == home || $0.home == home) }
                ?? ps.first { Teleport.proxyAddress($0.proxy) == Teleport.proxyAddress(proxy) }
        }
        if let cluster = ctx.arg("cluster", as: String.self)?.nilIfEmpty,
           let p = inv.profiles.first(where: { $0.cluster == cluster }) { return p }
        if let h = ctx.host, h.isTeleport || h.isBeam { return inv.profile(for: h) }
        return nil
    }

    /// `p.cluster || p.proxy`.
    static func name(_ p: TeleportProfile) -> String { p.cluster.nilIfEmpty ?? p.proxy }

    /// Re-read everything (sidebar.js `refreshInventory`).
    static func refreshInventory() async { await Inventory.shared.refresh() }

    // MARK: Cluster marks (clustermarks.js reads)

    /// `groupKeyFor(profile)`: `tp:<proxy>[@<home>]` — what cluster icons and
    /// colours are filed under.
    static func clusterKey(_ p: TeleportProfile) -> String {
        "tp:" + p.proxy + ((p.home?.isEmpty == false) ? "@" + p.home! : "")
    }

    static func clusterIcon(_ p: TeleportProfile) -> String {
        Store.shared.settingJSON("clusterIcons")[clusterKey(p)].string ?? ""
    }

    static func clusterColorValue(_ p: TeleportProfile) -> String {
        Store.shared.settingJSON("clusterColors")[clusterKey(p)].string ?? ""
    }

    static func clusterColor(_ p: TeleportProfile) -> Color? { HostColor.color(clusterColorValue(p)) }

    /// The profile row's context menu: a heading, then the sidebar's
    /// cluster icon/colour entries (`cluster-mark-menu`).
    static func showClusterMarkMenu(_ p: TeleportProfile) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: name(p)))
        Actions.shared.perform("cluster-mark-menu", args: ["menu": menu, "profileKey": p.key])
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Formatting

    /// `formatUntil`: "45m", "3h 12m", "2d 4h", "expired", "unknown".
    static func formatUntil(_ s: String?, now: Double = nowMs()) -> String {
        guard let s, !s.isEmpty else { return "unknown" }
        guard let t = TPText.parseDate(s) else { return s }
        let mins = Int(((t - now) / 60000).rounded())
        if mins < 0 { return "expired" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        return h < 24 ? "\(h)h \(mins % 60)m" : "\(h / 24)d \(h % 24)h"
    }

    /// `formatSpan(mins)`.
    static func formatSpan(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        if h < 24 { return "\(h)h \(mins % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }

    /// `formatWhen`: an absolute time with how far off it is.
    static func formatWhen(_ iso: String?, now: Double = nowMs()) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        guard let t = TPText.parseDate(iso) else { return iso }
        let mins = Int(((t - now) / 60000).rounded())
        let rel = mins < 0 ? "\(formatSpan(-mins)) ago" : "in \(formatSpan(mins))"
        return "\(localeString(ms: t)) (\(rel))"
    }

    /// `new Date(ms).toLocaleString()`.
    static func localeString(ms: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// `new Date(ms).toLocaleDateString()`.
    static func localeDateString(ms: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// `firstLine`: tsh errors are verbose; the first meaningful line is the point.
    static func firstLine(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let line = text.components(separatedBy: "\n").map(\.trimmed)
            .first { !$0.isEmpty && !TPText.test("^usage", $0, .caseInsensitive) }
        guard let line else { return nil }
        return TPText.clip(TPText.plain(line), 200)
    }

    /// teleportpanel.js `shellQuote`: quote only what a shell would mangle,
    /// and for `--flag=value` only the value.
    static func shellQuote(_ s: String) -> String {
        let safe = #"^[\w@%+=:,./-]+$"#
        if TPText.test(safe, s) { return s }
        if s.hasPrefix("--"), let eq = s.firstIndex(of: "="), eq > s.startIndex {
            let v = String(s[s.index(after: eq)...])
            if TPText.test(#"^[\w@%+=:,./-]*$"#, v) { return s }
            return String(s[...eq]) + "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `futureIso`: RFC 3339 for a start time more than a minute ahead, else "".
    static func futureIso(_ d: Date?, now: Double = nowMs()) -> String {
        guard let d else { return "" }
        let ms = d.timeIntervalSince1970 * 1000
        return ms > now + 60000 ? TPText.isoString(ms: ms) : ""
    }

    /// `datetime-local` resolution: whole minutes.
    static func toMinute(_ d: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return cal.date(from: c) ?? d
    }
}
