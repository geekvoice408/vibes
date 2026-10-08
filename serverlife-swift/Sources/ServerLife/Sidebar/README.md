# Sidebar

Owner: **sidebar**. Ports sidebar.js (the host list), hostactions.js,
tags.js, tagbrowser.js, heartbeat.js, nodewatch.js (as Inventory hooks),
narrowed.js, clustermarks.js, requestable.js, watch.js (watched hosts — the
host-disappearance watch, not folder watching) and the model half of
folders.js.

## Files

| File | What |
|---|---|
| `SidebarFeature.swift` | `install()`: `Slots.sidebar`, actions, Inventory/Session/Hosts hooks, status item |
| `SidebarView.swift` | `SidebarRoot`: tabs, filter (+ tag autocomplete), buttons, Hosts panel, rows, footer |
| `SavedTab.swift` | Saved tab: hosts' `SavedProfilesList`, macros via `SidebarHooks.macros`, automation's `S3SavedTab` |
| `SidebarModel.swift` | `SidebarWindow` (per window), `SB2` (groups, rows, cap, ghosts, quiet), `SBRequestableCache` |
| `HostMenu.swift` | `SBMenus`: host menu, three-level submenus, folder menus, group heading menu, local shell menu |
| `SidebarActions.swift` | `SBActions`: open/MFA/split/X11/files-only/latency, request access, refresh, expired-cluster login, copy login, remove profile, drop request |
| `HostActions.swift` | `SBHostActions`: run a command, port forward (+ favourites), server profile, `ensureConnection`, `pickHost` |
| `SidebarDialogs.swift` | `SBModal.ask`, pick login, preferred username, SSH config files |
| `TagBrowser.swift` | tag browser, one host's tags |
| `Tags.swift` | the query engine (pure) |
| `FolderModel.swift` | folder model (pure-ish, on `SB.store`) |
| `Heartbeat.swift`, `Narrowed.swift`, `Requestable.swift`, `HostWatch.swift`, `ClusterMarks.swift`, `HostPrefs.swift` | the original modules of the same names; HostPrefs = per-host/cluster prefs of sidebar.js |
| `SidebarHooks.swift` | extension points |
| `_SidebarDataStandIn.swift` | store.js `addForwardFavorite` / `markForwardFavoriteUsed` |

## Action ids registered

| id | does | args |
|---|---|---|
| `refresh` | ⌘R: full inventory reload, then "N Teleport nodes · M SSH hosts" | — |
| `host-menu` | append the host context menu to `menu` | host; `menu` NSMenu, `groupKey`, `folderId` |
| `cluster-mark-menu` | append the cluster icon/colour items | `menu` NSMenu, `profileKey` |
| `run-command` | "Run a command…" | host / `connId`; `login`, `command`, `title`, `autoRun` |
| `port-forward` | port forward dialog | host / `connId`; `login`, `preset` JSON |
| `forward-favorite-open` | dial and re-open a favourite tunnel | `favorite` JSON |
| `server-profile` | server profile | host / `connId`; `login` |
| `ssh-config-files` | "SSH config files" dialog | — |
| `choose-host` | hostactions.js `pickHost` | `completion: (Host?) -> Void` |
| `tag-browser` | tag browser (default: the sidebar filter) | `getFilter: () -> String`, `setFilter: (String?) -> Void` (a term to toggle in; nil = clear) |
| `host-tags` | one host's tags | host |
| `open-host-from-list` | open a host exactly as the list does (tmux / MFA routing, preferred login) | host; `login` |
| `request-access-for` | start a request for a requestable/out-of-reach node | host |
| `watch-forget-all` | stop watching every host | — |
| `sidebar-debug-next-tab` | `--snapshot` only: step through tabs | — |

## Extension points

- `SidebarHooks.teleportTab`, `.leafClusterTag`, `.clusterSwitchMenuItem`, `.beamMenu` (teleport-ui sets them),
  `.macros: SidebarMacroSource` (**fleet: please implement** — until then Saved → Macros says it is not available).
- `window.feature(SidebarWindow.self)`: `checkedHosts` (multi-exec ticks; fleet reads/writes it — the
  original's `state.checkedHosts` + `'checked'` event; it is observable), `filterText`, `setFilter`, `tab`.
- `HostWatch.onChange`, `Inventory.nodesRead` (installed here), `Heartbeat.*` for any view that wants
  heartbeat marks, `SB2.hostsInGroup`, `SB2.folderGroups`, `SB2.groupKeyForHost`, `SB2.hostById`.
- `Host` accessors for host-shaped rows: `watchMissing`, `watchUnconfirmed`, `isRequestableRow`,
  `isHeldBack`, `heldBy`, `watchKey`, `watchMissingSince`, `watchLastSeen`, `requestableSince`,
  `requestResourceId`, `configRoot`, `viaTsh`, `proxied`.

Hooks set by `install()`: `Inventory.nodesRead` (heartbeat observe, narrowed noteRead, watch noteSeen +
toasts), `nodeSignatureExtra` (heartbeat signature), `afterLoad` (folder-group repair);
`SessionHooks.hostById/preferredLogin` (+`loginOptions`, `waitForInventory` if unset);
`HostsHooks.heartbeat/requestableHosts/folderGroups/hostsInGroup/missingIn/isWatched`.

## Tag queries — `Tags` (pure, thread-safe)

`compileQuery(text) -> CompiledQuery {empty, error, match(host)}` — bare text, `key=v` (exact, comma =
either, `*` glob), `key:v` (contains; `key:` = has it), `key~regex` (case-insensitive, brackets belong to
the pattern), `tag:`/`label:`, fields `name host hostname alias cluster proxy addr type user uuid tunnel`
(a label and a field both answer), suffix keys (`location=east` → `aws/location`), leading `-`,
`and or not & && | || !`, brackets, quotes. Half-written queries still match (plain AND) and carry `error`.
Also `parseQuery`, `hostMatchesQuery`, `isBooleanQuery`, `regexError`, `labelEntries`, `labelCount`,
`isInternalLabel`, `collectTags`, `termFor`, `toggleTerm`, `hasTerm`, `tokenize`, `quoteIfNeeded`.

## Folder model — `FolderModel`

`settings.hostFolders` / `settings.folderMembers`, as the original. `hostKey`, `groupKey(for:)`,
`groupKey(proxy:home:)`, `allFolders`, `folder(id:)`, `folders(in:parent:)`, `groupHasFolders`,
`childFolders`, `folderPath`, `pathLabel`, `rootOf`, `members`, `rule(for:)`, `hostsInFolder`
(manual ∪ rule − excluded), `hostsInTree`, `foldersForHost`, `isFiled`, `folderIcon`, `folderColorHex`,
`showFiledHosts`; `createFolder`, `updateFolder`, `reparentFolder` (refuses loops), `subtreeIds`,
`deleteFolder`, `fileHost(removeFrom:)`, `unfileHost` (rule match → exclusion), `clearExclusion`,
`isExcluded`, `isManualMember`, `setShowFiledHosts`, `repairFolderGroups`, `fileHostsInto` (asks
`askBothOrOne` — the hosts owner installs its dialog), `exportData`, `parseImport`, `importData`.

## Actions this calls

sessions: `open-host` (`login`, `transport`, `mfaMode`, `x11`, `filesOnly`, `split`, `noTmux`, `tmux`,
`session`), `open-local` (`shell`, `blank`, `title`, `split`), `open-command` (latency), `send-text`.
hosts: `add-server`, `hosts-pane` (`groupKey`, `split`), `folders-browser` (`groupKey`, `folderId`),
`folder-dialog` (`groupKey`, `parentId`, `folderId`, `hosts`, **`completion: (HostFolder?) -> Void`** —
please call it, "New folder with this host…" files the host into what was made), `folders-export`,
`folders-import`, `new-profile` (`profile`), `remove-managed-host` (`alias`).
teleport-ui: `access-requests`, `access-request-new`, `request-monitor-add`, `tsh-status`, `tsh-login`,
`tsh-logout`, `tsh-make-active`, `tsh-config`, `live-sessions`, `recordings`, `beam-start`, `beam-open`,
`beam-menu` (all with `profileKey` where a profile is meant). consoles: `tmux-open` (no `session` → its
dialog). nettools: `keys`, `nettools`, `forget-host-key`. explorer: `local-files` (`path`; **`show: true`** for "Show local files in this pane" — explorer, please honour it as force-on).
misc: `locate-tools`, `backup-export`, `backup-import`. fleet: `snippet-from-selection` (`text`).

## Differences / not done

- Watching / filing from the Starred or Watched gatherings uses the host's real group (the original
  filed a watch under the group key "starred", where nothing ever read it again).
- The filter's autocomplete is a small list under the field matching the word being typed (no
  `<datalist>`); picking one replaces that word.
- Group drag drops on the heading (upper/lower half), not anywhere on the group.
- Drags carry a one-off token; a drop acts only on the current drag's own token (SwiftUI has no drag-end).
- "Connecting…" stays until the host's connection settles (connected / error / closed; 120 s cap).
- `sidebarFontSize` scales every sidebar font (the original's CSS `zoom`).
- Menus show "✓" via the key column (CtxMenu has no checkmark state).
- Context-menu right-clicks are caught by a transparent overlay (`SBRightClick`) so menus can be built
  from `CtxItem`s with icons, subtitles and tooltips.
