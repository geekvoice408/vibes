# Hosts

Owner: **hosts**. Ports folders.js (dialogs: new/edit with the rule builder,
both-or-move, export/import — the model is the sidebar's `FolderModel`),
folderview.js (the folder browser), hostspane.js (the hosts pane),
profiles.js (profile editor, New session launcher, `pickHost`, recents),
the Saved-tab profiles list and `launchProfile` from sidebar.js,
addserver.js (⌘⇧N), quickconnect.js (⌘⌥C) and history.js (command history).

## Files

| File | What |
|---|---|
| `HostsFeature.swift` | `install()`: every action below; `HostsFeature.savedList(window, filter)` |
| `QuickConnectParse.swift` | `QuickTarget`, `QuickConnect.parseTarget / targetLabel / quickHost / tokenize`, recent targets (`settings.quickConnects`, 12) |
| `QuickConnectDialog.swift` | the dialog: Test connect, Run command, Connect, recent chips + Forget, advice for "too many authentication failures" / "permission denied", "Offer one key only", `ssh -vv` debug; `QuickConnect.connect(t, window:)` (ssh/telnet/vnc/rdp/serial) |
| `AddServer.swift` | Add a server: ~/.ssh/config managed block (with "Alias already in use" override) or app-only, Test connection, also-save-as-profile; `AddServer.removeManagedHost` |
| `ProfileEditor.swift` | `Profiles.openEditor` (ssh/teleport/serial/telnet/vnc/rdp, folder, startup command, remote/local start folders), `defaultPort`, `meta`, `kindLabel` |
| `ProfileLaunch.swift` | `Profiles.launch(profile, window:)`, `openRecent`, `profileForNode`, `host(for:)` |
| `NewSession.swift` | `NewSession.open` (the + / ⌘N launcher), `NewSession.pickHost`, `recentMeta`, `HostPick` |
| `SavedList.swift` | `SavedProfilesList` (the Saved tab's profiles view), row menu (Open session / Edit… / Duplicate / Delete) |
| `CommandHistory.swift` | history.js: the host's shell history, search, put at prompt / run / copy / make a macro |
| `FolderDialogs.swift` | New/Edit folder (Insert a tag… / Insert a field… / and / or / not / ( ) / Clear, live "Matches N of M", parser complaint, hits, icon, colour, Inside), both-or-move (installed as `FolderModel.askBothOrOne`), export, import (merge/replace, "Put them in") |
| `FolderBrowser.swift` | the big folder view (sheet, size remembered as `folders`) |
| `HostsPane.swift` | the hosts pane (an `open-view-pane` pane with `isHosts`), leaf picker `root › leaf` read with its own `tsh ls` (30 s cache) |
| `HostsHooks.swift` | what the folder views need from sidebar/teleport-ui, with working defaults |
| `FolderBits.swift`, `HostsUI.swift`, `HostsOpen.swift` | shared views, right-click catcher, drop delegate, how things are opened |
| `_HostsDataStandIn.swift` | forwarders to Data/'s store.js port (see below) |

## Action ids registered

| id | does | args |
|---|---|---|
| `quick-connect` | Quick connect dialog | optional `target`, `identityFile`, `proxyJump`, `command` |
| `add-server` | Add a server | optional `name`, `hostname`, `user`, `port` Int, `identityFile`, `proxyJump`, `extraOptions`, `destination` "config"/"app" |
| `history` | ⌘Y → performs `recordings` with `tab: "history"` (the original opened recordings.js's Sessions dialog on "Connection history") | — |
| `command-history` | history.js for a pane | `paneId`, `connId` |
| `new-session-dialog` | profiles.js New session launcher (sessions' `new-session` calls it) | — |
| `pick-host` | host picker | `title`, `includeLocal` Bool, `completion: ([String: Any]?) -> Void` (`["kind":"local"]` / `["kind":"host","host":Host,"login":String?]`) or `reply: (HostPick?) -> Void` |
| `edit-profile` | profile editor on a saved profile | `profileId` or `profile` JSON |
| `new-profile` | profile editor prefilled | optional `profile` JSON (e.g. sidebar's "Save as profile…" `profileFromHost`) |
| `launch-profile` | open a saved profile, any kind | `profileId` or `profile` JSON |
| `remove-managed-host` | "Remove from ~/.ssh/config" | `host` (alias) or `alias` |
| `folders-browser` | folder browser | `groupKey`, `folderId` |
| `hosts-pane` | hosts pane | `groupKey`, `split` "right"/"down" (also `dir`) |
| `folder-dialog` | New folder / Edit folder | `groupKey`, `parentId` (new inside), `folderId` (edit), `hosts` [Host] (default: the group's), `completion: (HostFolder?) -> Void` |
| `folders-export` | Export these folders… | `groupKey` (nil = all) |
| `folders-import` | Import folders… | — |

**For the sidebar:** the Saved tab's profiles view is
`SavedProfilesList(window: w, filter: text, groupHeader: optional)` (or
`HostsFeature.savedList(w, text)`); `groupHeader(title, count, key "sf:<id|none>", rows)`
lets you draw the groups with your own `group()` heading and menu. The group
menu's *Folders → …* items map to `folder-dialog`, `folders-browser`,
`folders-export`, `folders-import`; the host menu's *Save as profile…* to
`new-profile`; *Remove from ~/.ssh/config* to `remove-managed-host`.

## Actions this calls (owners)

`open-host`, `open-local` (args `shell`, **`title`**), `open-backend`,
`open-view-pane`, `send-text` [sessions] · `serial-open`, `telnet-open`,
`vnc-open` [consoles] — the device `Host` (type serial/telnet/vnc) carries the
original `openDeviceSession`/`openVncSession` options in `extra` (`kind`,
`path`, `baudRate`, `dataBits`, `parity`, `stopBits`, `rtscts`, `xon`, `xoff`,
`host`, `port`, `newline`, `localEcho`, `viewOnly`, `scaling`, `quality`, and
**`startupCommand`** — type it, plus "\n", once the console is open).
Without `serial-open`/`telnet-open` registered the device is opened here via
`DeviceSessions` and handed to `open-backend`. RDP goes straight to
`RDPLauncher.launch`. · `host-menu` [sidebar] (args `menu`, plus `groupKey`
and `folderId` when the row is inside a folder — the folder items of
`openHostMenu(e, host, {folder, groupKey})`) · `access-request-new`
[teleport-ui] (`cluster`, `proxy`, `home`, `resourceIds`) · `recordings`
[teleport-ui] (`tab: "history"`) · `macro-edit` [fleet] (args `macro` JSON
`{command, category, where, name}`, `reply: (JSON?) -> Void`) ·
`open-host-from-list` / `request-access-for` [sidebar] (double-click in the folder browser and hosts pane) · `backup-export` / `backup-import` [misc] · `files-local-path` [explorer] (`path`, a profile's local start folder).

## Hooks (`HostsHooks`, set from your `install()`)

Defaults are built from `Inventory` and settings exactly as sidebar.js did:
`folderGroups`, `hostsInGroup` (beam nodes excluded; ssh by `configRoot`),
`missingIn` / `isWatched` (from `settings.watchedHosts`), `leavesFor`
(`Inventory.clusters(for:)`). Two have no real default and wait for the sidebar:
`heartbeat: (Host) -> HostBeat?` (heartbeat.js; nil = no mark) and
`requestableHosts(proxy, home, cluster) async -> (hosts, error)` (requestable.js;
default empty). Requestable/missing rows are recognised by `extra["requestable"]`
/ `extra["missing"]`, `extra["missingSince"]`.

## Data stand-in

`_HostsDataStandIn.swift` (`HostsData`): `profiles`, `profile(id)`,
`upsertProfile` (store.js record shape, merge on update), `deleteProfile`,
`markUsed`, `profileFolders`, `upsertProfileFolder`, `deleteProfileFolder`,
`listHistory`, `listRecent` (pure overload tested), `clearHistory`. Named
`_HostsDataStandIn.swift` because SwiftPM refuses two files called
`_DataStandIn.swift` in one target. Every function now forwards to Data/'s
store.js port (Data/StoreRecords.swift).

## Not done / differences

- The quick-connect address field has no `<datalist>`; the full recent list
  is a ▾ menu beside the field (the chips show the first 8, as before).
- Right-clicking a command-history row does not also select it (SwiftUI
  context menus); the menu acts on that row.
- The hosts pane's Backspace/Delete-to-unfile needs the card focused (it was
  effectively unreachable in the original, whose cards were not focusable).
- Heartbeat marks and requestable rows appear once the sidebar sets the hooks.
- Drags between folder views carry a private type (`com.serverlife.hosts-drag`)
  and record which view started them (`HostsDrag`), since SwiftUI has no
  drag-end: a cancelled drag can never be completed by a later drop.
- The export save panel has no "Export folders" title (`Modal.saveText` takes none).
