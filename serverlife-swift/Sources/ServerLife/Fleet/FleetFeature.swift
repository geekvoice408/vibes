import AppKit
import SwiftUI

/// The dock, multi-exec, macros, snippets (dock.js, macros.js, snippets.js, multiexec.js).
///
/// Owner: fleet (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here.
@MainActor
enum FleetFeature {
    static func install() {
        Slots.dock = { AnyView(FleetDockView(window: $0)) }

        let a = Actions.shared
        // Menu ids.
        a.register("multiexec") { ctx in
            guard let w = ctx.window else { return }
            if let ids = ctx.arg("hostIds", as: [String].self), !ids.isEmpty {
                let fw = w.feature(FleetWindow.self)
                fw.tagSelector = MXSelector()
                FleetHooks.setChecked(w, ids)
                fw.mxView = "command"
            }
            w.showDock("multiexec")
        }
        a.register("toggle-multiexec") { ctx in ctx.window?.showDock("multiexec") }
        a.register("run-macro") { ctx in MacroMenu.open(window: ctx.window, paneId: ctx.paneId) }
        a.register("snippets") { ctx in Snippets.open(ctx.window) }
        // Cross-feature ids.
        a.register("snippet-from-selection") { ctx in
            Task { @MainActor in await Snippets.fromSelection(ctx.arg("text"), window: ctx.window) }
        }
        a.register("snippet-edit") { ctx in
            var initial: JSON = [:]
            if let c: String = ctx.arg("command") { initial["command"] = .string(c) }
            Task { @MainActor in await Snippets.edit(initial, window: ctx.window) }
        }
        a.register("dock-show") { ctx in
            guard let w = ctx.window else { return }
            w.showDock(ctx.arg("tab", as: String.self) ?? w.dockTab)
        }
        // `macro` JSON (absent → a new macro; `command`, `name`, `category`,
        // `where` may seed one), `reply` gets the saved record (nil if cancelled).
        a.register("macro-edit") { ctx in
            let reply = ctx.arg("reply", as: ((JSON?) -> Void).self)
            var m: Macro
            if let j = ctx.arg("macro", as: JSON.self), j.object != nil {
                let id = j["id"].string ?? ""
                m = Macros.shared.macro(id) ?? Macro(json: j, builtin: id.hasPrefix("b:"))
                if j["id"].isNull, Macros.shared.macro(id) == nil { m.id = "" }
            } else {
                m = MacroDialogs.newMacro(command: ctx.arg("command") ?? "", name: ctx.arg("name") ?? "",
                                          category: ctx.arg("category") ?? "Custom", where: ctx.arg("where"))
            }
            Task { @MainActor in reply?(await MacroDialogs.edit(m, window: ctx.window)) }
        }
        a.register("forward-favorite-new") { ctx in
            Task { @MainActor in await FavoriteEditor.open(nil, window: ctx.window) }
        }

        // Status bar: watches, tunnels, transfers (the original's order).
        StatusItems.shared.register("watches", order: 50) { AnyView(WatchStatusItem(window: $0)) }
        StatusItems.shared.register("forwards", order: 51) { AnyView(ForwardStatusItem(window: $0)) }
        StatusItems.shared.register("transfers", order: 52) { AnyView(TransferStatusItem(window: $0)) }

        // Pinned macros in every pane header; repeats go with their pane.
        PaneHeaderItems.shared.register("fleet.macro-pins", slot: .macroPins) { pane in
            guard pane.kind != .view, !pane.filesOnly else { return nil }
            return AnyView(MacroPinButtons(pane: pane))
        }
        SessionHooks.paneClosing.append { pane in Macros.shared.stopRepeatsForPane(pane.id) }

        MultiExecService.shared.onDone.append { view in
            // Recent runs records the outcome, so it is written now that there is one.
            FleetHistory.shared.finish(view)
            let failed = view.results.filter { $0.status != "done" }.count
            StatusBus.shared.show(failed > 0
                ? "Multi-exec finished \u{2014} \(failed) of \(view.results.count) failed"
                : "Multi-exec finished on \(view.results.count) host(s)")
        }

        // The control socket's list_macros / run_macro: only macros the user
        // can read in the app (built-ins and their own), never a free command.
        AutomationHooks.listMacros = { _ in
            Macros.shared.all.map { m in
                var j = m.json
                j["id"] = .string(m.id)
                j["builtin"] = .bool(m.builtin)
                return j
            }
        }
        AutomationHooks.runMacro = { w, j, all in
            guard let m = Macros.shared.macro(j["id"].string ?? "") ?? Macros.shared.all.first(where: { $0.name == j["name"].string }) else {
                throw AppError("No macro named \"\(j["name"].stringish ?? "")\".")
            }
            await Macros.shared.send(m, all: all, window: w)
        }

        SidebarHooks.macros = sidebarMacros

        // For `--snapshot` only: reach each dock panel and the ▶ menu without arguments.
        if CommandLine.arguments.contains("--snapshot") {
            for t in FleetDockView.tabs.map(\.id) {
                a.register("fleet-debug-dock-\(t)") { ctx in ctx.window?.showDock(t) }
            }
            a.register("fleet-debug-mx-macros") { ctx in ctx.window?.feature(FleetWindow.self).mxView = "macros"; ctx.window?.showDock("multiexec") }
            a.register("fleet-debug-mx-history") { ctx in ctx.window?.feature(FleetWindow.self).mxView = "history"; ctx.window?.showDock("multiexec") }
            a.register("fleet-debug-macro-menu") { ctx in
                FleetMenu.show(MacroMenu.build(kind: "remote", paneId: nil, window: ctx.window), at: NSPoint(x: 900, y: 800))
            }
            a.register("fleet-debug-macro-editor") { ctx in
                Task { @MainActor in await MacroDialogs.edit(Macros.builtins[0], window: ctx.window) }
            }
            a.register("fleet-debug-fav-editor") { ctx in Task { @MainActor in await FavoriteEditor.open(nil, window: ctx.window) } }
        }

        TransferNotices.start()
    }

    private static let sidebarMacros = FleetSidebarMacros()
}

/**
 * Transfers report their own completion: a queue that silently finishes is
 * indistinguishable from one that never started (index.js `xfer.onUpdate`).
 */
@MainActor
enum TransferNotices {
    private static var notified = Set<String>()

    static func start() { observe() }

    private static func observe() {
        withObservationTracking {
            for q in FilesService.shared.queues.values { _ = q.jobs }
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { check(); observe() } }
        }
        check()
    }

    private static func check() {
        for (connId, q) in FilesService.shared.queues {
            for j in q.jobs where !notified.contains(j.id) && ["done", "error", "cancelled"].contains(j.status) {
                notified.insert(j.id)
                let label = FleetDock.connLabel(connId) ?? ""
                let whereStr = label.isEmpty ? "" : " \u{00B7} \(label)"
                if j.status == "done" {
                    let verb = j.kind == "upload" ? "Uploaded" : j.kind == "download" ? "Downloaded" : "Copied"
                    let secs = (j.endedAt != nil && j.startedAt != nil) ? (j.endedAt! - j.startedAt!) / 1000 : 0
                    let rate = secs > 0.2 && j.totalBytes > 0 ? " at \(Fmt.bytes(Double(j.totalBytes) / secs))/s" : ""
                    let files = j.fileCount > 1 ? " (\(j.fileCount) files)" : ""
                    let msg = "\(verb) \(j.label)\(files) \u{2014} \(Fmt.bytes(j.totalBytes))\(rate)"
                    StatusBus.shared.show(msg + whereStr, kind: .info, seconds: 9)
                    StatusBus.shared.toast(msg, kind: .ok, seconds: 5)
                } else if j.status == "error" {
                    StatusBus.shared.show("Transfer failed: \(j.label)\(whereStr)", seconds: 9)
                    StatusBus.shared.toast("Transfer failed: \(j.error ?? "")", kind: .error, seconds: 7)
                } else {
                    StatusBus.shared.show("Transfer cancelled: \(j.label)", seconds: 6)
                }
            }
        }
    }
}
