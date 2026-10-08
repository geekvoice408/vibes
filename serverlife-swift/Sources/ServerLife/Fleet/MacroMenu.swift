import AppKit
import SwiftUI

/// The ▶ menu on a pane (macros.js `openMacroMenu`): the macro list as a
/// drop-down, grouped by category, for the host already in front of you.
/// A menu rather than a dialog: this is picking one of a short list, not a
/// search across everything.
@MainActor
enum MacroMenu {
    /// `run-macro`: the menu on `paneId` (or the focused pane).
    static func open(window wIn: WindowModel?, paneId: String?) {
        let window = wIn ?? WindowManager.shared.focused
        guard let s = window?.feature(SessionsWindow.self) else { return }
        guard let pane = s.pane(paneId) ?? s.activePane, !pane.filesOnly, pane.kind != .view else {
            StatusBus.shared.toast("Open a session first", kind: .error)
            return
        }
        s.setActivePane(pane.id)
        // A console on a serial cable takes the same commands a host does.
        let kind = Macros.paneKind(pane)
        let items = build(kind: kind, paneId: pane.id, window: window)
        guard !items.isEmpty else { return }
        FleetMenu.show(items, at: anchor(pane, window), alignRight: true)
    }

    /// Where the menu hangs from: under the pointer when the ▶ button was
    /// clicked, else from the top-right of the pane's header.
    private static func anchor(_ pane: SessionPane, _ window: WindowModel?) -> NSPoint {
        if let e = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown].contains(e.type) {
            let m = NSEvent.mouseLocation
            return NSPoint(x: m.x + 10, y: m.y - 10)
        }
        guard let w = window, let nsw = w.nsWindow else { return NSEvent.mouseLocation }
        let left: CGFloat = w.sidebarVisible ? w.sidebarWidth + 5 : 0
        let f = pane.frame
        let x = nsw.frame.minX + left + (f == .zero ? nsw.frame.width - left - 40 : f.maxX - 40)
        let y = nsw.frame.maxY - 38 - (f == .zero ? 0 : f.minY) - 24
        return NSPoint(x: x, y: y)
    }

    static func build(kind: String, paneId: String?, window: WindowModel?) -> [FleetMenuItem] {
        let ms = Macros.shared
        let all = ms.all
        let macros = ms.macrosFor(kind, all)
        guard !macros.isEmpty else {
            StatusBus.shared.toast(!all.isEmpty
                ? "None of your macros are set to run in \(kind == "local" ? "the local shell" : "host sessions") \u{2014} change that under Saved \u{2192} Macros"
                : "No macros yet \u{2014} add one under Saved \u{2192} Macros", kind: .error)
            return []
        }
        var items: [FleetMenuItem] = []

        // Anything already on a timer here goes first, because the reason to
        // open this menu while something is ticking is usually to stop it.
        let running = paneId.map { ms.repeatsOnPane($0) } ?? []
        if !running.isEmpty {
            items.append(.heading("Repeating here"))
            let tf = DateFormatter()
            tf.timeStyle = .medium
            for r in running {
                items.append(FleetMenuItem(label: "Stop \u{201C}\(r.macro.name)\u{201D}", key: "every " + Macros.fmtEvery(Double(r.every)),
                                           title: "\(r.runs) run(s) since \(tf.string(from: Date(timeIntervalSince1970: r.since / 1000)))",
                                           onClick: {
                                               ms.stopRepeat(r.paneId, r.macro.id)
                                               StatusBus.shared.show("Stopped \(r.macro.name)")
                                           }))
            }
        }

        for (category, group) in ms.categories(macros) {
            if !items.isEmpty { items.append(.separator) }
            items.append(.heading(category))
            for m in group {
                let canRepeat = !m.interactive && !m.noEnter
                let ticking = paneId.map { ms.isRepeating($0, m.id) } ?? false
                let vars = Macros.varsOf(m)
                let key = [m.confirm ? "careful" : "", m.noEnter ? "edit first" : "",
                           ticking ? "running" : (m.repeatSeconds > 0 ? "every " + Macros.fmtEvery(Double(m.repeatSeconds)) : "")]
                    .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
                var sub: [FleetMenuItem] = [
                    FleetMenuItem(label: "Run once (default)", onClick: {
                        var once = m; once.repeatSeconds = 0
                        Task { @MainActor in await ms.send(once, window: window) }
                    }),
                ]
                if canRepeat {
                    sub.append(ticking
                        ? FleetMenuItem(label: "Stop repeating", onClick: {
                            if let paneId { ms.stopRepeat(paneId, m.id) }
                            StatusBus.shared.show("Stopped \(m.name)")
                        })
                        : FleetMenuItem(label: "Repeat every\u{2026}", onClick: {
                            Task { @MainActor in await MacroDialogs.promptRepeat(m, paneId: paneId, window: window) }
                        }))
                }
                if !vars.isEmpty {
                    sub.append(.separator)
                    sub.append(FleetMenuItem(label: "Fill in variables\u{2026}", key: vars.map(\.name).joined(separator: ", "),
                                             title: "Confirm or change every value before it runs", onClick: {
                        Task { @MainActor in
                            guard var filled = await ms.resolve(m, ask: true, window: window) else { return }
                            filled.repeatSeconds = 0
                            // Already filled in: nothing left to ask.
                            filled.variables = []
                            await ms.send(filled, window: window)
                        }
                    }))
                }
                /*
                 * What this macro is for, on a mark of its own. A macro's name is
                 * short by design, and the sentence explaining which question it
                 * answers is the thing worth reading before running something on
                 * a server.
                 */
                let notes = [m.confirm ? "Asks before running: it changes something." : "",
                             m.interactive ? "Does not finish on its own \u{2014} follows a log." : "",
                             m.noEnter ? "Pasted at the prompt without Enter, to finish by hand." : "",
                             vars.isEmpty ? "" : "Fills in: " + vars.map(\.name).joined(separator: ", ")].filter { !$0.isEmpty }
                items.append(FleetMenuItem(
                    label: m.name, key: key,
                    title: (m.description.isEmpty ? "" : m.description + "\n\n") + m.command
                        + (m.noEnter ? "\n\n(pasted without pressing Enter)" : ""),
                    help: CtxHelp(answers: m.description.nilIfEmpty, command: m.command, notes: notes),
                    submenu: sub,
                    onClick: { Task { @MainActor in await ms.send(m, window: window) } }))
            }
        }

        /*
         * Writing one, at the end. The moment you want a macro is the moment you
         * have just typed the command for the third time — and you are looking at
         * this menu, not at the Saved tab.
         */
        items.append(.separator)
        items.append(FleetMenuItem(label: "New macro\u{2026}", icon: "+", title: "Write one, and it appears in this menu on every host",
                                   onClick: {
            Task { @MainActor in
                // Where it was written is the best guess at where it belongs.
                let saved = await MacroDialogs.edit(MacroDialogs.newMacro(category: "Custom", where: kind == "local" ? "local" : "hosts"),
                                                    window: window)
                if let saved {
                    StatusBus.shared.show("Saved \(saved["name"].stringish?.nilIfEmpty ?? "macro") \u{2014} it is in this menu now")
                }
            }
        }))
        items.append(FleetMenuItem(label: "Manage macros\u{2026}", title: "The full list, including the built-in ones",
                                   onClick: { Macros.openManager(window: window) }))
        return items
    }
}
