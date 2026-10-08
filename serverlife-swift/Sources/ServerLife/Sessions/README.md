# Sessions

Port of `sessions.js`, `tabs.js`, `term.js`, `activity.js`, `highlight.js`,
`links.js`, `workspace.js`, `connectanim.js`, `quitguard.js`, the
session/tab/pane/zoom/layout half of `index.js` (menu dispatch, keyboard),
and the matching parts of `index.html` / `styles.css`.

## Files

| File | What |
|---|---|
| `SessionsFeature.swift` | `install()`: slots, status item, actions, window hooks, quit guard, settings/theme follow, ⌘+ / keypad zoom, zoom region, cwd loop |
| `SessionsWindow.swift` | `SessionsWindow: WindowFeature` — tabs, panes, active ids, broadcast; byte stream (attach, write, input, resize), endings, close, focus, session log |
| `SessionsOpen.swift` | `openHost`, `connectPane`, local shells/commands, `openBackend`, `openViewPane`, `openOnConnection`, reopen with login / MFA / other MFA method, overlays |
| `SessionsLayout.swift` | split, pick-host split, move (nearest pane / edge), swap, move to tab / new tab / own window, adopt, duplicate, tmux tree API |
| `Model.swift` | `SessionPane`, `SessionTab`, `PaneKind`, `PaneOverlay`, `SessConnRecord(s)` |
| `PaneTree.swift` | `PaneNode` / `PaneSplit` and the tree helpers of state.js |
| `TermView.swift` | `SessionTermView` (SwiftTerm), `TermPalette`, `TermClickWatcher` (plain click on a link) |
| `WorkspaceView.swift` | `Slots.workspace`: split views + dividers, pane view, body/accessory, overlay, pane drag & drop |
| `PaneHeader.swift` | header: title + host colour, search box (n/m), ▤, ⌗, tmux/macro slots, ▶, ☰, × |
| `PaneMenu.swift` | pane right-click menu, save/copy terminal, zoom, ⌘⇧L, ⌘⇧B, BROADCAST badge |
| `TabStrip.swift` | `Slots.tabStrip`: tabs, activity marks, + (right-click menu), drop targets |
| `EmptyStart.swift` | start page with the orbiter |
| `ConnectAnim.swift` | the 30 connect scenes |
| `Activity.swift`, `Highlight.swift`, `Links.swift`, `QuitGuard.swift`, `Workspace.swift` | as named |
| `SessConn.swift` | the only file that talks to `ConnectionManager` / `LocalShells` |

## Using it

`window.feature(SessionsWindow.self)` gives a window's sessions:
`tabs`, `panes`, `activePane`, `activeTabId`, `activeConnId`, `openHost(_:_:)`,
`openLocalShell(...)`, `splitActivePane(_:_:)`, `closePane`, `closeTab`,
`requestClosePane/Tab(s)` (asks first), `sendToPane`, `writeToPane`
(output with highlighting + activity), `focusActivePane`, `probeCwd`,
`captureWorkspace` / `restoreWorkspace`. `SessionsCore.allWindows()`,
`SessionsCore.owner(ofPane:)`, `SessionsCore.paneTitle(_:long:)`,
`SessionsCore.hostKey(of:)` (the per-host pref key a pane obeys).

`SessionPane` (observable): `id`, `tabId`, `kind` (`remote/local/device/tmux/view`),
`connId`, `host` (device/view descriptor), `cwd`, `remoteHome`, `title`,
`status`, `hasTerm`, `backend`, `term` (the SwiftTerm view), `explorerVisible`,
`filesOnly`, `isHosts`, `accessorySize`, `macroRepeating` / `macroButtonTitle`
(fleet sets these for ▶), `titleProvider` + `tmuxEnded` (consoles),
`attachments` (anything else; `"localStartPath"` is set from `open-host`).

## Actions registered

Menu: `new-session` (performs `new-session-dialog` — **hosts, please register
it**), `new-local`, `duplicate-tab`, `split-right`, `split-down`,
`split-right-host`, `split-down-host`, `move-pane-left/right/up/down`,
`close-pane`, `toggle-log`, `broadcast`, `disconnect`, `find`,
`clear-terminal`, `zoom-in/out/reset`, `tab-1…9`, `tab-prev`, `tab-next`,
`save-layout-as`, `load-layout`, `manage-layouts`, `save-layout`, `clear-layout`.

Cross-feature (as CLAUDE.md): `open-host`, `open-local` (also `title`: a named shell keeps it as its title), `open-command`,
`open-backend`, `open-view-pane`, `send-text`, `send-text-all`. Extras:

- `open-backend` also takes `reconnect: () async throws -> TerminalBackend`
  (a console that ended offers "[press Enter to reconnect]" and "Open it
  again") and `greeting` (a grey first line). Backend `kind` "tmux" makes a
  tmux pane, "local"/"command" a local one, anything else a device pane.
  `close()` is called when the pane closes — for tmux, make it detach the view only.
- `open-view-pane` also takes `isHosts` Bool and `hostsGroup` (a hosts pane,
  saved with layouts as `{kind:'hosts'}` and restored via `hosts-pane` with
  `groupKey` and `split` "right"/"down").
- `open-on-connection` — args `connId`, `startupCommand`, `title` (sessions.js `openOnConnection`).
- `highlights` — the keyword-highlighting dialog; args `hostKey`, `hostLabel` (for Settings' "Edit the highlights…").

`open-host` resolves the login (`SessionHooks.preferredLogin`, else
settings.hostLogins), routes to `tmux-open` (args `login`, `session`) when
`tmux` is true or the host/cluster/global tmux default says so (never for an
MFA host; `noTmux` skips), and opens known-MFA Teleport hosts with tsh.

Actions this performs that others own: `new-session-dialog` (hosts),
`pick-host` (hosts — args `title`, `includeLocal: true`, `completion: ([String: Any]?) -> Void`
called with `["kind": "local"]` or `["kind": "host", "host": Host, "login": String?]`),
`command-history` (hosts, paneId/connId), `snippets`, `snippet-from-selection`
(args `text`), `run-macro` (fleet, paneId), `nettools` (args `connId`, `tool`),
`tmux-open` (consoles), `hosts-pane` (hosts), `serial-open` / `telnet-open` /
`vnc-open` / `rdp-open` (consoles, restoring layouts: host = saved descriptor).

## Extension points

- `SessionHooks` — `hostById`, `preferredLogin`, `loginOptions` ("Try as …"),
  `forwardCount` (quit/close census), `waitForInventory` (before the launch
  restore offer), `afterStartup` (misc: tour offer), `cwdChanged`,
  `directoryChangeTyped` (explorer follow), `paneCreated`, `paneClosing`.
- `PaneMenuItems.shared.register(id, section: .top | .middle) { pane, window in [NSMenuItem] }`
  — Send break, tmux's split/rename/detach/end, VNC's Ctrl+Alt+Del/paste/reconnect.
- `PaneHeaderItems.shared.register(id, slot: .tmuxControls | .macroPins) { pane in AnyView? }`;
  bump `PaneHeaderItems.shared.revision` when pins change.
- `PaneAccessories.shared.provider = { pane in AnyView }` — the file browser
  beside/above the terminal (settings.explorerPosition, draggable, 270pt /
  240pt default, min 140); a files-only pane is the accessory alone. The ☰
  header button and its scope menu appear once a provider is set.
- `SessionsTmux.split = { pane, dir in Bool }` — a plain split on a tmux pane.
- tmux tabs: `openPendingTab(title:)`, `openTmuxWindow(title:tree:bind:)`,
  `applyTmuxLayout(tabId:tree:bind:paneFor:)` with `TmuxLayoutNode`; bind a
  backend with `attach(pane, backend)`; `showOverlay` / `hideOverlay` /
  `noteOverlay` for the waiting state.
- `SessMenuItem` / `NSMenu.sessAdd` — closure menu items.

## Behaviour notes

- Panes are objects that move: splits, tabs and windows re-parent the same
  SwiftTerm view, so nothing reconnects ("Move to its own window", or drag a
  header out of the window). Drop on a pane in the same tab swaps, on a tab
  moves into it, past the last tab gives it its own tab.
- Connections are released when no tab or pane in **any** window uses them.
- The cwd loop (every settings.refreshSeconds) probes panes of the visible tab
  whose file browser is showing (all of them while no explorer exists), never
  over tsh/beam; titles follow.
- Session logging uses the connection's log API (remote terminals only, as in
  the original).
- Layouts are stored in the original's shapes (`workspaces[slot]`, `layouts`,
  `defaultLayoutId`); a window closed on purpose clears its slot.

## Not done / differs

- Scrollback search highlights the current match only (SwiftTerm 1.11.2 has no
  public "decorate all matches"); the n/m counter is computed from the buffer.
- Line height 1.18 and xterm's glyph rescaling have no SwiftTerm equivalent.
- The find dialog fallback (`openFind`) was only reachable for a VNC pane,
  where it did nothing; ⌘F always uses the pane's search box.
