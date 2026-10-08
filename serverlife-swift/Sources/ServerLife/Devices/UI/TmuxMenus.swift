import AppKit
import SwiftUI

/*
 * A "tmux" menu on a tmux pane's title bar, for the session itself.
 *
 * Every item is a tmux command sent down the control stream, and what it does
 * comes back as the layout tmux reports — the same as typing the command in a
 * shell in the session, or pressing the prefix keys in any other client.
 *
 * One labelled button rather than a row of glyphs: these are commands to a
 * different program than the buttons beside them. Zoom is left out on
 * purpose: the layout followed is the window's full one, which a zoom does
 * not change, so it would appear to do nothing.
 */
extension ConsolesTmux {
    /// The `tmux ▾` button, for an attached pane whose session has not ended.
    static func headerControls(_ p: SessionPane) -> AnyView? {
        guard p.kind == .tmux, p.tmuxEnded == nil, info(p) != nil else { return nil }
        return AnyView(TmuxHeaderButton(pane: p))
    }

    static func showControlsMenu(_ p: SessionPane, at screenPoint: NSPoint) async {
        guard let i = info(p) else { return }
        let s = p.owner
        s?.setActivePane(p.id)
        let rec = records[i.sessionId]
        let window = s?.window
        // A layout is an arrangement of panes; with one there is nothing to
        // arrange, and an item that silently does nothing reads as broken.
        let win = rec?.window(ofTab: p.tabId)
        let count = win.flatMap { rec?.trees[$0] }.map { ConsolesText.paneCount($0) } ?? 1
        let alone = count < 2
        let needsTwo = alone ? " — needs two or more panes" : ""
        /*
         * Whether typing goes to every pane is tmux's to say — another client
         * may have turned it on — so it is asked as the menu opens, one round
         * trip, rather than remembered here and wrong.
         */
        var synced = false
        if let rec, !alone {
            let out = (try? await rec.session.command("display-message -p -t \(i.pane) '#{synchronize-panes}'")) ?? []
            synced = out.first == "1"
        }
        let tp = i.pane
        func send(_ cmd: String, then: (() -> Void)? = nil) {
            Task {
                guard let rec = record(of: p) else {
                    StatusBus.shared.toast("This pane is no longer attached to tmux", kind: .error); return
                }
                do { try await rec.session.command(cmd); then?() }
                catch { StatusBus.shared.toast(error.localizedDescription, kind: .error) }
            }
        }

        let m = NSMenu()
        m.autoenablesItems = false
        m.sessHeading("tmux · \(rec?.name ?? "session")")
        m.sessAdd("Split right", key: "⌘⇧D", tooltip: "A new tmux pane beside this one (split-window -h)") {
            send("split-window -h -t \(tp)")
        }
        m.sessAdd("Split down", key: "⌘⇧E", tooltip: "A new tmux pane below this one (split-window -v)") {
            send("split-window -v -t \(tp)")
        }
        let layouts = NSMenu()
        layouts.autoenablesItems = false
        for (name, label) in ConsolesText.layouts {
            layouts.sessAdd(label, key: name, tooltip: "select-layout \(name)") { send("select-layout -t \(tp) \(name)") }
        }
        layouts.addItem(.separator())
        layouts.sessAdd("Next layout", tooltip: "The next of the five, in turn (next-layout)") { send("next-layout -t \(tp)") }
        let layoutItem = NSMenuItem(title: "Layout" + needsTwo, action: nil, keyEquivalent: "")
        layoutItem.submenu = layouts
        layoutItem.isEnabled = !alone
        m.addItem(layoutItem)
        m.sessAdd("Swap with the next pane" + needsTwo, enabled: !alone,
                  tooltip: "This pane and the one after it change places (swap-pane -D)") {
            send("swap-pane -D -t \(tp)")
        }
        m.sessAdd("Move this pane to its own window" + needsTwo, enabled: !alone,
                  tooltip: "Takes this pane out into a new tmux window, shown as a tab (break-pane)") {
            send("break-pane -s \(tp)")
        }
        m.sessAdd("Type in all panes at once" + needsTwo, key: synced ? "✓ on" : "", enabled: !alone,
                  tooltip: synced
                    ? "On: every key goes to every pane in this window. Click to turn it off."
                    : "Every key goes to every pane in this window — one command on several servers (synchronize-panes)") {
            send("set-window-option -t \(tp) synchronize-panes \(synced ? "off" : "on")") {
                StatusBus.shared.show(synced ? "Typing goes to this pane only" : "Typing goes to every pane in this window")
            }
        }
        m.addItem(.separator())
        m.sessAdd("New tmux window", tooltip: "A new window in this session, shown as a tab (new-window)") { send("new-window") }
        m.addItem(.separator())
        m.sessAdd("Close this tmux pane…", tooltip: "Ends what runs in it, on the server (kill-pane)") {
            Task {
                let ok = await MiscUI.confirm(window, title: "Close this tmux pane?",
                                              message: "What is running in it stops, on the server, for everyone attached.",
                                              detail: "To keep it running and only stop showing it here, close the pane with \u{00d7} instead.",
                                              confirmLabel: "Close the tmux pane")
                if ok { send("kill-pane -t \(tp)") }
            }
        }
        m.sessAdd("Close this tmux window…", tooltip: "Ends every pane in it, on the server (kill-window)") {
            Task {
                let ok = await MiscUI.confirm(window, title: "Close this tmux window?",
                                              message: "Its \(count == 1 ? "pane" : "\(count) panes") and what runs in \(count == 1 ? "it" : "them") stop, on the server, for everyone attached.",
                                              detail: "To keep it running and only stop showing it here, close the tab instead.",
                                              confirmLabel: "Close the tmux window")
                if ok { send("kill-window -t \(tp)") }
            }
        }
        m.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    /// The tmux part of a pane's right-click menu (top of it): splits that
    /// tmux makes, windows, names, detach and end.
    static func paneMenuItems(_ p: SessionPane, _ window: WindowModel) -> [NSMenuItem] {
        // An ended session's pane is a record of what was on screen, not a session.
        guard p.kind == .tmux, p.tmuxEnded == nil else { return [] }
        let m = NSMenu()
        m.sessAdd("Split right (tmux)", tooltip: "Asks tmux to split, so the other clients see it too") { split(p, .row) }
        m.sessAdd("Split down (tmux)") { split(p, .col) }
        m.sessAdd("New tmux window") { newWindow(p) }
        m.sessAdd("Rename this window\u{2026}", tooltip: "Stops tmux renaming the tab after whatever is running in it") {
            Task { await renameWindow(p, window: window) }
        }
        m.sessAdd("Rename the session\u{2026}", tooltip: "How you find it again \u{2014} here, and in tmux ls on the host") {
            guard let id = info(p)?.sessionId else { return }
            Task { await renameSession(id, window: window) }
        }
        m.addItem(.separator())
        m.sessAdd("Detach \u{2014} leave it running", tooltip: "The session stays on the server with everything in it") {
            guard let id = info(p)?.sessionId else { return }
            Task { await detach(id) }
        }
        m.sessAdd("End this tmux session\u{2026}") {
            guard let id = info(p)?.sessionId else { return }
            Task { await kill(id, window: window) }
        }
        let items = m.items
        m.removeAllItems()
        return items
    }
}

/// `tmux ▾` in a tmux pane's header.
private struct TmuxHeaderButton: View {
    let pane: SessionPane
    var body: some View {
        Button {
            let at = NSEvent.mouseLocation
            Task { await ConsolesTmux.showControlsMenu(pane, at: at) }
        } label: {
            Text("tmux \u{25BE}").font(.system(size: 10.5))
        }
        .buttonStyle(GhostButtonStyle(small: true))
        .help("Commands for this tmux session — split, layout, windows")
    }
}
