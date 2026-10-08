import Foundation

/// Port of clustermarks.js — icons and colours for whole clusters, filed
/// against the group key (`tp:<proxy>[@<home>]`), shared by the host list
/// and the Teleport tab (`clusterMarkMenu`).
@MainActor
enum ClusterMarks {
    private static var s: JSON { SB.store.settings }

    static func key(_ p: TeleportProfile) -> String { FolderModel.groupKey(for: p) }

    static func icon(_ key: String) -> String { s["clusterIcons"][key].string ?? "" }
    static func icon(_ p: TeleportProfile) -> String { icon(key(p)) }

    /// The colour value ("red", …) or "".
    static func colorValue(_ key: String) -> String { s["clusterColors"][key].string ?? "" }
    static func colorValue(_ p: TeleportProfile) -> String { colorValue(key(p)) }

    /// The colour as hex, or "" for none.
    static func colorHex(_ key: String) -> String {
        let v = colorValue(key)
        return HostColor.all.first { !v.isEmpty && $0.value == v }?.hex ?? ""
    }

    private static func labelOf(_ p: TeleportProfile) -> String { p.cluster.nilIfEmpty ?? p.proxy }

    static func setIcon(_ p: TeleportProfile, window: WindowModel? = nil) async {
        let k = key(p)
        guard let icon = await MiscUI.pickIcon(window, title: "Icon for this cluster", subtitle: labelOf(p), value: self.icon(k)) else { return }
        var map = s["clusterIcons"].entries
        if icon.isEmpty { map.removeValue(forKey: k) } else { map[k] = .string(icon) }
        SB.store.updateSettings(["clusterIcons": .object(map)])
        StatusBus.shared.show(icon.isEmpty ? "Icon cleared" : "\(labelOf(p)) is \(icon)")
    }

    static func setColor(_ p: TeleportProfile, _ value: String) {
        let k = key(p)
        var map = s["clusterColors"].entries
        if value.isEmpty { map.removeValue(forKey: k) } else { map[k] = .string(value) }
        SB.store.updateSettings(["clusterColors": .object(map)])
        StatusBus.shared.show(value.isEmpty ? "Colour cleared for \(labelOf(p))" : "\(labelOf(p)) is \(value)")
    }

    /// The two entries, shared by the host list and the Teleport tab.
    static func menu(_ p: TeleportProfile, window: WindowModel? = nil) -> [CtxItem] {
        let k = key(p)
        let ic = icon(k), hex = colorHex(k), val = colorValue(k)
        return [
            CtxItem(ic.isEmpty ? "Give the cluster an icon…" : "Icon: \(ic)", icon: ic.isEmpty ? "\u{263A}" : ic,
                    title: "An emoji on the cluster heading, here and in the Teleport tab") {
                Task { await setIcon(p, window: window) }
            },
            CtxItem(hex.isEmpty ? "Give the cluster a colour…" : "Cluster colour…", icon: "\u{25C9}",
                    title: "Colours the heading, so production does not read like the lab",
                    submenu: HostColor.all.map { c in
                        CtxItem(c.label, key: (val == c.value || (c.value.isEmpty && hex.isEmpty)) ? "\u{2713}" : nil) {
                            setColor(p, c.value)
                        }
                    }),
        ]
    }
}
