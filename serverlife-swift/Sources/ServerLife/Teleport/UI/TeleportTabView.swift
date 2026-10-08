import AppKit
import SwiftUI

/// The sidebar's Teleport tab (teleportpanel.js `renderTeleportTab`): one row
/// per tsh profile, the saved clusters, and the buttons along the bottom.
///
/// The sidebar owner embeds it: `TeleportTabView(window: w)`. It follows the
/// inventory and the store by itself (both are observed).
struct TeleportTabView: View {
    let window: WindowModel

    var body: some View {
        let inv = Inventory.shared
        let profiles = inv.profiles
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if profiles.isEmpty {
                    VStack(spacing: 9) {
                        Text(inv.teleportError ?? "Not logged in to Teleport.")
                            .font(.system(size: 12)).foregroundStyle(Theme.shared.p.textDim)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Button("tsh login…") { TeleportPanel.openLoginDialog(window: window) }.buttonStyle(.ghost)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16).padding(.horizontal, 10)
                    // Saved clusters are the whole point when nothing is logged
                    // in: the proxy address is gone from every list, and this is
                    // where it was kept.
                    SavedLoginsSection(window: window)
                } else {
                    ForEach(profiles, id: \.key) { p in ProfileRow(p: p, window: window) }
                    SavedLoginsSection(window: window)
                    TUIFlow(spacing: 6) {
                        Button("Add cluster…") { TeleportPanel.openLoginDialog(window: window) }.buttonStyle(.ghost)
                        Button("Requests…") { AccessRequestsUI.openRequestsDialog(TUI.activeProfile(), window: window) }
                            .buttonStyle(.ghost)
                        MonitorButton(window: window)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Monitor requestable…", carrying the count and any bad news.
private struct MonitorButton: View {
    let window: WindowModel
    var body: some View {
        let n = ReqMonitor.monitorCount()
        let gone = ReqMonitor.missingCount()
        let label = n == 0 ? "Monitor requestable…" : gone > 0 ? "Monitor requestable — \(gone) missing" : "Monitor requestable — \(n)"
        Button(label) { ReqMonitor.openPane(window) }
            .buttonStyle(GhostButtonStyle(destructive: gone > 0))
            .help("Confirm on a timer that the resources you expect to be able to request are still offered")
    }
}

/// One tsh profile.
struct ProfileRow: View {
    let p: TeleportProfile
    let window: WindowModel

    var body: some View {
        let pal = Theme.shared.p
        let nodes = Inventory.shared.nodesByKey[p.key] ?? []
        let colour = TUI.clusterColor(p)
        let icon = TUI.clusterIcon(p)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                TUIDot(color: p.expired ? pal.red : pal.green)
                if !icon.isEmpty { Text(icon).font(.system(size: 12)) }
                Text(TUI.name(p)).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(colour ?? pal.text).lineLimit(1).truncationMode(.middle)
                if !p.homeName.isEmpty { TUITag(text: p.homeName, help: "TELEPORT_HOME=" + p.homeDir) }
                LeafClusterTag(p: p, window: window)
                if p.active { TUITag(text: "active", kind: .live, help: "Plain tsh commands use this cluster") }
                if p.expired { TUITag(text: "expired", kind: .expired, help: "The certificate has lapsed") }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(p.username)
                Text(p.expired ? "certificate expired" : "valid until \(TUI.formatUntil(p.validUntil))")
                    .foregroundStyle(p.expired ? pal.red : pal.muted)
                if !p.activeRequests.isEmpty {
                    Text("\(p.activeRequests.count) assumed request(s)").foregroundStyle(pal.accent)
                }
                if !p.expired { Text("\(nodes.count) nodes · \(p.logins.count) logins") }
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(pal.muted)
            .padding(.leading, 13)
            TUIFlow(spacing: 5) { actions }
                .padding(.leading, 13).padding(.top, 5)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { if let colour { colour.frame(width: 2) } }
        .overlay(alignment: .bottom) { pal.borderSoft.frame(height: 1) }
        .contentShape(Rectangle())
        // The same two entries the host list's cluster heading offers.
        .onRightClick { TUI.showClusterMarkMenu(p) }
    }

    @ViewBuilder private var actions: some View {
        let sm = GhostButtonStyle(small: true)
        if p.expired {
            Button("Login") { Task { await TeleportPanel.doLogin(p) } }.buttonStyle(sm)
        } else {
            Button(p.active ? "Active" : "Switch to") { Task { await TeleportPanel.doSwitch(p) } }
                .buttonStyle(sm).disabled(p.active)
        }
        if !TeleportPanel.leavesFor(p).isEmpty {
            Button("Cluster…") { TeleportPanel.openClusterSwitcher(p, window: window) }.buttonStyle(sm)
                .help("Switch between this root and its leaf clusters")
        }
        Button("Copy login cmd") { TeleportPanel.copyLoginCommand(p) }.buttonStyle(sm)
            .help("Copy the tsh login command for this cluster, to paste into a terminal")
        Button("Save cluster") {
            TeleportPanel.saveClusterLogin(["name": .string(TUI.name(p)), "proxy": .string(p.proxy),
                                            "cluster": .string(p.cluster), "user": .string(p.username),
                                            "home": .string(p.home != nil ? p.homeDir : "")])
        }.buttonStyle(sm).help("Keep this cluster so it can be logged into again after the certificate goes")
        Button("Status") { Task { await TeleportPanel.openClusterStatus(p, window: window) } }.buttonStyle(sm)
            .help("What tsh status says about this cluster")
        if !p.expired {
            Button("Add to ssh config…") { Task { await TeleportPanel.openTshConfigDialog(p, window: window) } }.buttonStyle(sm)
                .help("Put this cluster\u{2019}s tsh config block into ~/.ssh/config, so plain ssh, scp and rsync reach its nodes")
            Button("Logout") { Task { await TeleportPanel.doLogout(p, window: window) } }.buttonStyle(sm)
                .help("Delete this cluster\u{2019}s certificate (tsh logout --proxy=…)")
        }
        Button("Requests") { AccessRequestsUI.openRequestsDialog(p, window: window) }.buttonStyle(sm)
        Button("Web UI") { TeleportPanel.openClusterWeb(proxy: p.proxy, cluster: p.cluster) }.buttonStyle(sm)
            .help("Open this cluster in the Teleport web UI")
        Button("Cluster info") { TeleportPanel.openClusterInfo(proxy: p.proxy, window: window) }.buttonStyle(sm)
            .help("Version, edition, auth connector and proxy listeners, from /webapi/ping")
    }
}

/// The saved clusters (`renderSavedLogins`): listed even while their
/// certificate is live — a saved cluster is a record of how you log in.
private struct SavedLoginsSection: View {
    let window: WindowModel

    var body: some View {
        let list = TUIData.listTshLogins()
        let profiles = Inventory.shared.profiles
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("SAVED CLUSTERS").font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(Theme.shared.p.muted)
                    .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 3)
                ForEach(Array(list.enumerated()), id: \.offset) { _, t in
                    let home = t["home"].stringish ?? ""
                    let live = profiles.first { $0.proxy == t["proxy"].stringish && $0.homeDir == (home.nilIfEmpty ?? $0.homeDir) }
                    SavedLoginRow(t: t, live: live, window: window)
                }
            }
        }
    }
}

private struct SavedLoginRow: View {
    let t: JSON
    let live: TeleportProfile?
    let window: WindowModel

    var body: some View {
        let pal = Theme.shared.p
        let on = live != nil && !live!.expired
        let proxy = t["proxy"].stringish ?? ""
        let cluster = t["cluster"].stringish ?? ""
        let name = t["name"].stringish ?? proxy
        let ttl = t["ttl"].stringish ?? ""
        let meta = [t["user"].stringish ?? "", t["authConnector"].stringish ?? "", ttl.isEmpty ? "" : ttl + "m"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let sm = GhostButtonStyle(small: true)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                TUIDot(color: on ? pal.green : nil)
                Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if let h = t["home"].stringish?.nilIfEmpty { TUITag(text: "home", help: "TELEPORT_HOME=" + h) }
                if on { TUITag(text: "logged in") }
                if t["autoLogin"].truthy {
                    TUITag(text: "auto", help: "Logged in automatically when the app starts, if the certificate has gone")
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(proxy)
                if !meta.isEmpty { Text(meta) }
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(pal.muted).padding(.leading, 13)
            TUIFlow(spacing: 5) {
                Button(on ? "Log in again" : "Log in") { TeleportPanel.loginFromSaved(t, window: window) }
                    .buttonStyle(GhostButtonStyle(small: true, prominent: !on))
                Button("Copy login cmd") {
                    TeleportPanel.copyLoginCommand(proxy: proxy, username: t["user"].stringish ?? "",
                                                   homeDir: t["home"].stringish?.nilIfEmpty,
                                                   authConnector: t["authConnector"].stringish?.nilIfEmpty,
                                                   ttl: ttl.nilIfEmpty)
                }.buttonStyle(sm)
                // Works whether or not the certificate is still good: it is the
                // browser's own session, often the way back in.
                Button("Web UI") { TeleportPanel.openClusterWeb(proxy: proxy, cluster: cluster) }.buttonStyle(sm)
                    .help(cluster.isEmpty ? "Open this proxy in the Teleport web UI" : "Open this cluster in the Teleport web UI")
                Button("Edit…") { TeleportPanel.openLoginDialog(TeleportPanel.LoginPrefill(record: t), window: window) }
                    .buttonStyle(sm)
                Button("Forget") {
                    Task { @MainActor in
                        guard await MiscUI.confirm(window, title: "Forget " + name, message: "Stop keeping \(proxy) for re-login?",
                                                   detail: "Nothing is logged out; only the saved details are removed.",
                                                   confirmLabel: "Forget") else { return }
                        if let id = t["id"].string { TUIData.deleteTshLogin(id) }
                    }
                }.buttonStyle(sm)
            }
            .padding(.leading, 13).padding(.top, 5)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { pal.borderSoft.frame(height: 1) }
    }
}

// MARK: - Leaf badge

/// `leafClusterTag`: drawn only when there is somewhere else to go; on a
/// profile pointed at a leaf it says "leaf". Click to switch cluster.
/// Public for the sidebar's cluster headings: `LeafClusterTag(p:window:)`.
struct LeafClusterTag: View {
    let p: TeleportProfile
    var window: WindowModel? = nil

    var body: some View {
        let leaves = TeleportPanel.leavesFor(p)
        if !leaves.isEmpty {
            let sel = TeleportPanel.selectedCluster(p)
            let onLeaf = sel?.leaf == true
            let pal = Theme.shared.p
            let c = onLeaf ? pal.green : pal.textDim
            let tip = [
                onLeaf ? "On leaf cluster \(sel!.name). Click to switch cluster — the root and "
                    + "\(leaves.count) leaf\(leaves.count == 1 ? "" : "ves") are listed."
                    : "\(leaves.count) leaf cluster\(leaves.count == 1 ? "" : "s") behind this root. Click to switch to one.",
                onLeaf ? TeleportPanel.clusterLabels(sel)
                    : leaves.map { [$0.name, TeleportPanel.clusterLabels($0)].filter { !$0.isEmpty }.joined(separator: "  ") }
                        .joined(separator: "\n"),
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            Button { TeleportPanel.openClusterSwitcher(p, window: window) } label: {
                HStack(spacing: 3) {
                    LeafShape().fill(c.opacity(0.3)).overlay(LeafShape().stroke(c, lineWidth: 1.1)).frame(width: 10, height: 10)
                    Text(onLeaf ? "leaf" : String(leaves.count)).font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(c)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(onLeaf ? pal.green.opacity(0.14) : pal.panel3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(onLeaf ? pal.green.opacity(0.35) : pal.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(tip)
        }
    }
}

/// The leaf of LEAF_SVG (16×16 viewBox), with its midrib.
private struct LeafShape: Shape {
    func path(in r: CGRect) -> Path {
        let s = r.width / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var p = Path()
        p.move(to: pt(3, 13))
        p.addCurve(to: pt(13, 3), control1: pt(3, 7.2), control2: pt(7.2, 3))
        p.addCurve(to: pt(3, 13), control1: pt(13, 8.8), control2: pt(8.8, 13))
        p.closeSubpath()
        p.move(to: pt(4.6, 11.4))
        p.addLine(to: pt(11.4, 4.6))
        return p
    }
}
