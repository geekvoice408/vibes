# Explorer

Owner: **explorer**. Port of `explorer.js`, `files.js` and `rsyncsync.js` (the
renderer side of the file browser). `watch.js` (watched hosts) was ported by the
sidebar owner as `Sidebar/HostWatch.swift` with its tests, so it is not duplicated
here. Built on Files/Service (`FileSource`, `FilesService`, `SyncPlanner`,
`CrossTransfer`, `Watches`, `FindFiles`, `Rsync`, `LocalFS`).

## Files

| File | What |
|---|---|
| `ExplorerModel.swift` | `ExplorerModel` (one explorer), `XPViewState` (per-source view), `XPSource`, `Explorers.shared` (every live explorer), `xpStatus` / `xpToast` |
| `ExplorerFavorites.swift` | starred folders/files: built-ins (`autoFlagLocal`/`autoFlagHost`, existence-checked, hide/restore), scopes, toggle, rename |
| `ExplorerActions.swift` | new folder, move (clash refusal, not-into-itself), rename, delete, compare, sync, keep up to date, edit in my editor, cd, drops; `XPTransfer` (uploadTo, downloadTo, crossCopy, beam advice) |
| `ExplorerMenus.swift` | list context menu, ⇅ sort menu, ☆ scope menu, starred-row menu, Open with… |
| `ExplorerDialogs.swift` | Go to path, Permissions and owner (live command preview), Get info (+ recursive size, "What do these permissions mean?"), inline editor, Which list?, Copy to another server |
| `ExplorerSearch.swift`, `ExplorerSyncDialog.swift`, `RsyncDialog.swift` | Search, Synchronize, rsync |
| `ExplorerS3.swift` | buckets as sources, `explorer-show-source`, bucket menus/transfers/info through automation's `S3UI` |
| `ExplorerView.swift` | the pane: header, path bar, starred list, filter bar, sortable columns, tree list, notices (MFA gate, Reconnect files), status line, drag & drop |
| `FilesController.swift` | `XPPaneExplorers` (each pane's explorer + local companion), `ExplorerPaneView`, `XPFiles` (files.js: tick, follow, catch-up, toggles) |
| `ExplorerSessionsGlue.swift` | the only file that touches Sessions types |
| `ExplorerHooks.swift` | settings accessors (`Store.xp…`), `XPPanes` bridge, `XPConn`, source registry, `XPCityAttachment` |
| `ExplorerPure.swift` | pure helpers (`XP.sortEntries`, `matcher`, `permText`, `explainPermissions`, `permissionCommands`, `compareVerdict`, `builtinFavoriteId`, …) |

## Action ids

| id | does | args |
|---|---|---|
| `toggle-files` | ⌘E: show/hide the focused pane's explorer ("No pane focused") | — |
| `explorer-position` | ⌘⇧P: beside ↔ above (settings.explorerPosition) | `position` "left"/"top" (optional) |
| `local-files` | ⌘⇧F: local list under the focused pane (opens a local shell when there is no pane) | `path` (show that folder), `show` Bool (force on); neither toggles off |
| `explorers-all` | toggleAllExplorers: every pane **in the window**, sets settings.explorersVisible, status | `visible` Bool (omit = toggle) |
| `files-button-menu` | fills the title-bar file-browser button's right-click menu (this pane / all in this tab / every pane) | `menu` NSMenu |
| `files-local-path` | setLocalPath (a profile's local start path) | `path` |
| `explorer-show-source` | point the focused pane's explorer at a source, opening a local shell first if none | `source` ("s3:<id>", "local", "conn:<id>", "pane") |
| `debug-explorer-panel`, `debug-explorer-dialog` | `--snapshot` aids: an explorer in a panel; env `XP_DIALOG` = goto/search/info/edit/rsync, or `max` (focused pane's explorer fills the window) | — |

Performs: `city-open` (args `explorer`: the `ExplorerModel`), `new-local`, `send-text` fallback.

## For other owners

- Explorers are tracked per window, as each Electron window had its own `explorers` map:
  `Explorers.shared.inWindow(w)` is what "the other list", the rsync far end, *Upload to …*, show/hide-all
  and a profile's local start path consider.
- `XPFiles.focusFilterIfListFocused(window:) -> Bool` — call first from ⌘F (`find`); true means a file
  list had the keyboard and its name filter now has it.
- `XPFiles.anyVisible(window:) -> Bool` — the title-bar button's lit state.

- **City**: on `city-open`, build your view from `args["explorer"] as ExplorerModel` and call
  `explorer.attachCity(obj)` with an `XPCityAttachment` (`view`, `sync()`, `invalidate()`, `destroy()`).
  The explorer shows `view` in place of the list while a folder is listed, calls `sync()` on every
  `render()`, `invalidate()` on refresh, `destroy()` when the 3D button / a bucket / the setting closes it.
  Drive it with `view` (path, entries, selection, expanded), `source.kind`/`isLocal`/`isRemote`,
  `sourceKey`, `connId`, `navigate(_:)`, `open(_:)`, `goParent()`, `filter`, `focusFilter()`,
  `clearFilter()`, `notHidden(_:)`, `matcher`, `sorted(_:)`/`sortOptions`, `selected()`, `lastClicked`,
  `render()`, `showContextMenu(for:)` / `contextMenuItems(for:)`, `toggle3d(false)`.
  **Fill the window (⤢)**: set `explorer.maximized = true` (false for ⤡ / Esc). The whole explorer pane,
  toolbar included, is then drawn over its window (`.fpane.c3-max`) in an NSHostingView above the window
  content (above the terminals); the pane's own slot shows blank panel. Closing 3D or the explorer clears
  it. With this, the city adapter no longer needs its own overlay (`fillsByOverlay`).
- **Sources**: `ExplorerSources.register(XPSourceProvider)` adds picker entries (`options()`,
  `fileSource(value)`); call `ExplorerSources.changed()` when they change. S3 is registered from here.
- **Sessions**: uses `PaneAccessories.provider`, `SessionHooks.cwdChanged` (follow) and `paneClosing`.
  Explorer visibility changes go through `setExplorerVisible`.
- `MiscHooks.settingsSaved`: refresh interval, starred defaults, 3D setting, sort.

## Behaviour kept

A remote tmux pane drawn before its connection exists shows this machine only until the connection is
known, then switches to the server (a tmux pane on this Mac stays local).

Per-explorer source and per-source view state; "This session" for remote/tmux panes; a tmux pane on this
Mac (no connection) shows local files; MFA gate ("Load files (approve MFA)", leaf-cluster wording, Try
again); "Reconnect files" and tmux self-heal once a minute; filter (substring / anchored glob, arrows +
Enter from the box, type-ahead, Esc clears then closes, ancestors of matches kept); hidden/filtered
counts; sortable columns with folders-first; tree with Loading…/Cannot read directory/empty; background
refresh preserving selection/expansion/scroll, paused while off screen and caught up when shown, never
on tsh sessions; follow the terminal's directory (moves, not position); compare marks both panes;
narrow-pane column/button shedding at the stylesheet's widths.

## Not done / differs

- Sessions probes the cwd on every typed `cd`; the original only did when follow was on and the explorer
  was on screen (audit #6, sessions-owned).

- Drag *out* to Finder is not offered (the original had none either).
- The pane right-click menu gets no explorer items: the original's pane menu had none (the ☰ button and
  its scope menu are Sessions').
- Menu "key" hints (ascending/descending, every host, ✓) are shown as the item's second line.
- `--snapshot` cannot exercise clicks/keys; keyboard navigation uses SwiftUI `onKeyPress` on the list.
