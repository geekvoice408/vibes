import AppKit
import SwiftUI

/// Pinned macros as buttons in a pane's header (sessions.js
/// `renderPaneMacroButtons`). A local shell shows the pins scoped to it (or to
/// everything); a host session the ones scoped to hosts (or to everything).
struct MacroPinButtons: View {
    let pane: SessionPane
    var body: some View {
        let p = Theme.shared.p
        let pins = Macros.shared.pinnedMacros(kind: Macros.paneKind(pane))
        HStack(spacing: 1) {
            ForEach(pins, id: \.macro.id) { pin in
                let m = pin.macro
                Button(pin.icon) {
                    // The button belongs to this pane, so run it here whatever had focus.
                    pane.owner?.setActivePane(pane.id)
                    Task { @MainActor in await Macros.shared.send(m, window: pane.owner?.window) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .frame(minWidth: 18, minHeight: 18)
                .foregroundStyle(m.confirm ? p.amber : p.textDim)
                .help("\(m.name)\(m.description.isEmpty ? "" : " \u{2014} " + m.description)\n\n\(m.command)"
                      + (m.confirm ? "\n\n(asks first \u{2014} it changes something)" : ""))
                // Right-click the button to be rid of it, without going to find the list.
                .overlay(RightClickMenu { pinMenu(m, icon: pin.icon, where: pin.where) })
            }
        }
    }
}

extension MacroPinButtons {
    /// The pinned button's own menu: its name, "Icon and where it shows…"
    /// with the scope on the right, and "Unpin this button".
    func pinMenu(_ m: Macro, icon: String, where w: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.sessHeading(m.name)
        let label = Macros.scopeLabel(w)
        let key = label == "Host sessions only" ? "hosts" : label == "The local shell only" ? "local" : "all"
        let win = pane.owner?.window
        menu.sessAdd("Icon and where it shows\u{2026}", key: key) {
            Task { @MainActor in
                guard let next = await MacroDialogs.pinOptions(icon: icon, where: w, name: m.name, window: win) else { return }
                Macros.shared.setPinned(m.id, pinned: true, icon: next.icon, where: next.where)
            }
        }
        menu.sessAdd("Unpin this button") { Task { @MainActor in await Macros.shared.togglePin(m, window: win) } }
        return menu
    }
}

/// Shows an NSMenu on right-click and lets every other click through.
struct RightClickMenu: NSViewRepresentable {
    let make: @MainActor () -> NSMenu
    func makeNSView(context: Context) -> RightClickView { RightClickView(make: make) }
    func updateNSView(_ v: RightClickView, context: Context) { v.make = make }

    final class RightClickView: NSView {
        var make: @MainActor () -> NSMenu
        init(make: @escaping @MainActor () -> NSMenu) { self.make = make; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let t = NSApp.currentEvent?.type
            return (t == .rightMouseDown || t == .rightMouseUp) ? super.hitTest(point) : nil
        }
        override func menu(for event: NSEvent) -> NSMenu? { MainActor.assumeIsolated { make() } }
    }
}

/// Saved → Macros is the sidebar's (SavedTab.swift); this is the macros.js
/// half it draws from (`SidebarHooks.macros`).
@MainActor
final class FleetSidebarMacros: SidebarMacroSource {
    private var ms: Macros { Macros.shared }

    private func macro(_ j: JSON) -> Macro {
        if let id = j["id"].string, let m = ms.macro(id) {
            // An edited copy ("Duplicate and edit…") carries its own name.
            var out = m
            if let n = j["name"].string { out.name = n }
            return out
        }
        return Macro(json: j, builtin: j["builtin"].truthy)
    }

    private func json(_ m: Macro) -> JSON {
        var j = m.json
        j["id"] = .string(m.id)
        j["builtin"] = .bool(m.builtin)
        j["where"] = .string(Macros.runScopeOf(m.whereScope))
        return j
    }

    func all() -> [JSON] { ms.all.map(json) }

    func categories(_ list: [JSON]) -> [(category: String, items: [JSON])] {
        let byId = Dictionary(list.map { ($0["id"].stringish ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        return ms.categories(list.map(macro)).map { (cat, ms) in (cat, ms.compactMap { byId[$0.id] }) }
    }

    func isPinned(_ id: String) -> Bool { ms.isPinned(id) }
    func pinnedIcon(_ id: String) -> String { ms.pinnedIconFor(id) }
    func pinnedScopeLabel(_ id: String) -> String { Macros.scopeLabel(ms.pinnedScopeFor(id)) }
    func runScope(_ m: JSON) -> String { Macros.runScopeOf(m["where"].string) }
    func runScopeLabel(_ scope: String) -> String { Macros.runScopeLabel(scope) }

    func send(_ m: JSON, all: Bool, window: WindowModel) {
        let mac = macro(m)
        Task { @MainActor in await Macros.shared.send(mac, all: all, window: window) }
    }

    func runOnHost(_ m: JSON, host: Host, login: String?, window: WindowModel) {
        let mac = macro(m)
        Task { @MainActor in await Macros.shared.runOnHost(mac, host: host, login: login, window: window) }
    }

    func promptRepeat(_ m: JSON, window: WindowModel) {
        let mac = macro(m)
        let pane = window.feature(SessionsWindow.self).activePaneId
        Task { @MainActor in await MacroDialogs.promptRepeat(mac, paneId: pane, window: window) }
    }

    func togglePin(_ m: JSON, window: WindowModel) async { await ms.togglePin(macro(m), window: window) }

    func edit(_ m: JSON, window: WindowModel) async {
        await MacroDialogs.edit(m.object?.isEmpty ?? true ? nil : macro(m), window: window)
    }

    func delete(_ m: JSON, window: WindowModel) async -> Bool { await ms.delete(macro(m), window: window) }
    func restoreBuiltins() async { ms.restoreBuiltins() }
    func moveCategory(_ category: String, _ delta: Int) async -> Bool { ms.moveCategory(category, delta) }
}
