import SwiftUI

/// requestwatch.js's drawing half (the loop itself is Inventory's): the
/// badge on the sidebar's Teleport tab, the per-cluster `N req` tag, and the
/// tab strip's right-click menu of outstanding requests (sidebar.js
/// `openRequestsMenu` / `renderRequestBadge`).
@MainActor
enum RequestWatchUI {
    /// The badge model: nil when nothing is outstanding (so it stays news),
    /// otherwise the count, whether it is green (an approval to use) or amber
    /// (waiting on a reviewer), and its tooltip.
    static func badge() -> (text: String, approved: Bool, tooltip: String)? {
        let s = Inventory.shared.requestSummary()
        if s.total == 0 { return nil }
        let tip = [s.pending > 0 ? "\(s.pending) request\(s.pending == 1 ? "" : "s") awaiting review" : "",
                   s.approved > 0 ? "\(s.approved) approved and ready to assume" : "",
                   "Right-click the tabs for the request list"].filter { !$0.isEmpty }.joined(separator: "\n")
        return (String(s.total), s.approved > 0, tip)
    }

    /// The Teleport tab's own tooltip.
    static var tabTooltip: String {
        let n = Inventory.shared.allLiveRequests().count
        return n > 0 ? "\(n) access request(s) outstanding — right-click for the list"
            : "Clusters, requests and recordings — right-click for access requests"
    }

    /// `openRequestsMenu`: what is outstanding, per cluster, then the two
    /// things anyone does about it.
    static func requestsMenuItems(window: WindowModel? = nil) -> [CtxItem] {
        let inv = Inventory.shared
        let live = inv.allLiveRequests().map(\.request)
        let s = inv.requestSummary(live)
        let profiles = inv.liveProfiles
        var items: [CtxItem] = [.heading(live.isEmpty ? "Access requests" : "Access requests — \(s.pending) waiting, \(s.approved) approved")]
        if profiles.isEmpty {
            items.append(CtxItem("No cluster is logged in", disabled: true))
            return items
        }
        for p in profiles {
            let mine = inv.requestsFor(p)
            let approved = mine.contains { $0.state == "APPROVED" || $0.state == "PROMOTED" }
            items.append(CtxItem(TUI.name(p), key: mine.isEmpty ? nil : (approved ? "approved" : "\(mine.count) waiting"),
                                 title: mine.isEmpty ? "No requests outstanding on this cluster"
                                     : mine.map { "\($0.state.lowercased()): \($0.roles.isEmpty ? "\($0.resources.count) resources" : $0.roles.joined(separator: ", "))" }
                                         .joined(separator: "\n")) {
                AccessRequestsUI.openRequestsDialog(p, window: window)
            })
        }
        items.append(.sep)
        items.append(CtxItem("New request…") {
            AccessRequestsUI.openRequestsDialog(profiles.first { $0.active } ?? profiles[0], window: window)
        })
        items.append(CtxItem("Check again now") {
            Task { @MainActor in
                await Inventory.shared.refreshRequests()
                let n = Inventory.shared.allLiveRequests().count
                TUIStatus.show(n > 0 ? "\(n) request(s) outstanding" : "Nothing outstanding")
            }
        })
        return items
    }

    static func showRequestsMenu(window: WindowModel? = nil) { CtxMenu.show(requestsMenuItems(window: window)) }
}

/// The `.req-badge` on the Teleport tab: amber for waiting, green once there
/// is an approval to use. Draws nothing when nothing is outstanding.
struct TeleportRequestBadge: View {
    var body: some View {
        if let b = RequestWatchUI.badge() {
            let p = Theme.shared.p
            Text(b.text)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 0.5)
                .background(Capsule().fill(b.approved ? p.green : p.amber))
                .help(b.tooltip)
        }
    }
}

/// `clusterRequestTag(profile)`: `N req` on a cluster heading; click for its list.
struct ClusterRequestTag: View {
    let p: TeleportProfile
    var window: WindowModel? = nil
    var body: some View {
        let list = Inventory.shared.requestsFor(p)
        if !list.isEmpty {
            let s = Inventory.shared.requestSummary(list)
            Button { AccessRequestsUI.openRequestsDialog(p, window: window) } label: {
                TUITag(text: "\(list.count) req", kind: s.approved > 0 ? .ok : .warn)
            }
            .buttonStyle(.plain)
            .help([s.pending > 0 ? "\(s.pending) awaiting review" : "",
                   s.approved > 0 ? "\(s.approved) approved — click to assume" : "",
                   "Click for the request list"].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }
}
