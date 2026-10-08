import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Pieces the folder browser and the hosts pane share: a right-click catcher
// that hands back an NSMenu, the host row's marks, drop targets, and the
// click / ⌘-click / shift-click selection rule.

/// Catches a right-click (or control-click) over a SwiftUI view without
/// taking ordinary clicks from it.
private final class RightClickNSView: NSView {
    var action: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let e = NSApp.currentEvent else { return nil }
        let right = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
        return right ? super.hitTest(point) : nil
    }
    override func rightMouseDown(with event: NSEvent) { action() }
    override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { action() } }
}

private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> RightClickNSView { let v = RightClickNSView(); v.action = action; return v }
    func updateNSView(_ v: RightClickNSView, context: Context) { v.action = action }
}

extension View {
    /// Run `action` on a right-click (the original's `contextmenu` handler).
    func hostsRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }
}

@MainActor
enum FolderBits {
    /// Whether a live connection is open to this host (`.st.connected`).
    static func connected(_ host: Host) -> Bool {
        ConnectionManager.shared.connections.contains { $0.host.id == host.id && $0.state == .connected }
    }

    /// Click, ⌘-click, shift-click over `order` (the keys of the rows on screen).
    static func pick(_ k: String, picked: inout Set<String>, last: inout String?, order: [String]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let l = last, let a = order.firstIndex(of: l), let b = order.firstIndex(of: k) {
            for key in order[min(a, b)...max(a, b)] { picked.insert(key) }
        } else if mods.contains(.command) || mods.contains(.control) {
            if picked.contains(k) { picked.remove(k) } else { picked.insert(k) }
        } else {
            picked = [k]
        }
        last = k
    }

    static func countText(_ shown: Int, _ total: Int) -> String {
        shown == total ? "\(total) host\(total == 1 ? "" : "s")" : "\(shown) of \(total)"
    }

    static func color(_ folder: HostFolder?) -> Color? {
        let hex = FolderModel.folderColorHex(folder)
        return hex.isEmpty ? nil : Color(hex: hex)
    }
}

/// The 6-pt status dot.
struct HostDot: View {
    let on: Bool
    var color: Color? = nil
    var body: some View {
        let p = Theme.shared.p
        Circle().fill(color ?? (on ? p.green : p.muted)).frame(width: 6, height: 6)
    }
}

/// `chip sm`: a label as key / value.
struct LabelChip: View {
    let key: String
    let value: String
    var onAccent = false
    var body: some View {
        let p = Theme.shared.p
        HStack(spacing: 2) {
            Text(key).foregroundStyle(onAccent ? Color.white.opacity(0.75) : p.muted)
            Text(value.isEmpty ? "—" : value).foregroundStyle(onAccent ? Color.white : p.textDim)
        }
        .font(.system(size: 9.5))
        .lineLimit(1)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(onAccent ? Color.white.opacity(0.15) : p.panel3))
    }
}

/// `.tag.rule` / `.tag.hb` / `.tag.stale` / `.tag.gone` / `.tag.req`.
struct SmallTag: View {
    enum Kind { case rule, hb, stale, gone, req }
    let kind: Kind
    let text: String
    var help: String? = nil
    var body: some View {
        let p = Theme.shared.p
        let (fg, bg, border): (Color, Color, Color?) = {
            switch kind {
            case .rule: return (p.muted, p.panel3, nil)
            case .hb: return (p.muted, .clear, nil)
            case .stale: return (p.amber, p.amber.opacity(0.18), p.amber.opacity(0.4))
            case .gone: return (p.amber, p.amber.opacity(0.14), nil)
            case .req: return (p.accent, p.accent.opacity(0.15), nil)
            }
        }()
        Text(text)
            .font(.system(size: 9))
            .lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 0.5)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 3).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(border ?? .clear))
            .fixedSize()
            .help(help ?? "")
    }
}

/// The heartbeat mark: `⚠ quiet 5m` or `♥ 30s`, nothing without a beat.
struct HeartbeatTag: View {
    let host: Host
    var body: some View {
        if let b = HostsHooks.heartbeat(host) {
            if b.stale { SmallTag(kind: .stale, text: "⚠ " + b.staleLabel) }
            else if let age = b.ageLabel { SmallTag(kind: .hb, text: "♥ " + age) }
        }
    }
}

/// Which view a drag of hosts or folders started in. Every drag of ours
/// writes it, and only our drags carry `HostsDrag.type`, so a drag that was
/// cancelled can never be completed later by someone else's drop (SwiftUI
/// has no drag-end to clear it on).
@MainActor
enum HostsDrag {
    static var owner: ObjectIdentifier?
    nonisolated static let type = UTType(exportedAs: "com.serverlife.hosts-drag", conformingTo: .data)

    /// The drag payload: the name as text (what the original set), plus the
    /// private type that marks it as ours.
    static func provider(_ name: String, from owner: AnyObject) -> NSItemProvider {
        Self.owner = ObjectIdentifier(owner)
        let p = NSItemProvider(object: name as NSString)
        p.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
            done(Data(name.utf8), nil)
            return nil
        }
        return p
    }

    static func isFrom(_ owner: AnyObject) -> Bool { Self.owner == ObjectIdentifier(owner) }
}

/// A drop target driven by the views' own drag state (the payload is only
/// text, so a drop from anywhere else is refused by `canDrop`).
struct FolderDropDelegate: DropDelegate {
    let canDrop: () -> Bool
    let onTarget: (Bool) -> Void
    let onDrop: () -> Void
    func validateDrop(info: DropInfo) -> Bool { canDrop() }
    func dropEntered(info: DropInfo) { if canDrop() { onTarget(true) } }
    func dropExited(info: DropInfo) { onTarget(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { canDrop() ? DropProposal(operation: .move) : DropProposal(operation: .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        onTarget(false)
        guard canDrop() else { return false }
        onDrop()
        return true
    }
}

extension View {
    func folderDrop(canDrop: @escaping () -> Bool, onTarget: @escaping (Bool) -> Void, onDrop: @escaping () -> Void) -> some View {
        self.onDrop(of: [HostsDrag.type],
               delegate: FolderDropDelegate(canDrop: canDrop, onTarget: onTarget, onDrop: onDrop))
    }
}
