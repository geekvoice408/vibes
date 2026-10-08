# Teleport UI

Ports teleportpanel.js, requestpicker.js, requestwatch.js (drawing half),
reqmonitor.js, recordings.js, livesessions.js (UI) and beams.js (UI), plus
the bits of sidebar.js that are really this feature's (`openRequestsMenu`,
`renderRequestBadge`, `removeExpiredProfile`, `copyLoginCommand`,
`requestAccessFor`). Built on Teleport/Service (`Teleport`, `Beams`,
`Inventory`, `WebAPIPing`, `TshCommand`).

## Files

| File | What |
|---|---|
| `TeleportUIFeature.swift` | `install()`: action ids, SidebarHooks, the monitor |
| `TeleportTabView.swift` | `TeleportTabView(window:)` (the sidebar's Teleport tab), `LeafClusterTag(p:window:)` |
| `TeleportPanel.swift` | login dialog, doLogin/switch/makeProfileActive/logout, saved clusters, `tsh status`, `tsh config` → ~/.ssh/config, leaf-cluster switcher (menu ≤10, searchable dialog >10), web UI, cluster info, removeExpiredProfile, copyLoginCommand |
| `AccessRequests.swift` | requests list (assume/drop/details/copy/save as reusable), new request (roles chips + probe, Browse…, timing, folded tsh command with Copy, Load saved…/Save…), saved requests |
| `RequestPicker.swift` | `RequestPicker.pickResources/pickRoles`, `ReqResource` |
| `RequestWatchUI.swift` | `TeleportRequestBadge()`, `RequestWatchUI.tabTooltip`, `RequestWatchUI.requestsMenuItems()` (tab-strip right-click), `ClusterRequestTag(p:)` |
| `ReqMonitor.swift` | the requestable-resource monitor: list edits, loop, floating pane (overlay), `ReqMonitorLogic` (pure, tested) |
| `Recordings.swift` | Sessions dialog: Connection history / Teleport recordings / Search transcripts |
| `LiveSessions.swift` | active sessions list, watch/join/moderate |
| `BeamsUI.swift` | start, menu, run, publish, scp, delete, `BeamExpiryLabel`, `BeamsUI.visibleBeams` |
| `ClusterInfo.swift` | fallback /webapi/ping view when nettools' `webapi-ping` is not registered |
| `TUIKit.swift`, `TUIShared.swift` | tags, flow layout, right-click, `TUIModal.ask`, formatting helpers |
| `_TeleportUIDataStandIn.swift` | `TUIData`: forwarders to Data/'s store.js tshLogins / requestTemplates / sessionNotes / history methods on `TUIData.store` |

## For the sidebar

Set in `install()` on `SidebarHooks`: `teleportTab`, `leafClusterTag`,
`clusterSwitchMenuItem`, `beamMenu`. Also available:

- `TeleportRequestBadge()` — the amber/green count for the Teleport tab (draws nothing when none);
  `RequestWatchUI.tabTooltip`; `RequestWatchUI.showRequestsMenu(window:)` / `requestsMenuItems` for the tab strip's right-click.
- `ClusterRequestTag(p:window:)` — `N req` on a cluster heading.
- `BeamsUI.visibleBeams(proxy)` — draw these, not `Inventory.beamsFor` (a beam being deleted is hidden at once, back on failure).
- `BeamExpiryLabel(beam:)` — the ticking "3h 12m left".
- `ReqMonitor.summary(profile)` → `(total, missing)`; `ReqMonitor.monitorCount/missingCount`.
- `TeleportPanel.removeExpiredProfile / copyLoginCommand / makeProfileActive / doLogout / savedClusterFor / loginFromSaved / openTshConfigDialog / openClusterStatus / openClusterWeb`, `AccessRequestsUI.openRequestsDialog`.
- The profile row's right-click is a heading plus the sidebar's `cluster-mark-menu` (args `menu`, `profileKey`).

## Action ids

Profile-taking actions resolve the profile from args `profileKey`, else `proxy` (+`home`), else `cluster`, else `ctx.host`.

| id | does | args |
|---|---|---|
| `teleport-panel` | requests of the active profile, or tsh login | — |
| `cluster-info` | `webapi-ping` if registered, else own panel | `proxy` |
| `request-monitor` | toggle the floating monitor pane in the window | — |
| `recordings` | Sessions dialog; a teleport/beam host pre-filters | `tab` ("history"/"recordings"/"search"), `filter`, `proxy`, `home` |
| `tsh-login` | login dialog (saved record for that proxy pre-fills) | `proxy`, `cluster`, `user`, `home` |
| `tsh-status` | `tsh status` dialog | profile |
| `access-request-new` | new request with resources chosen | profile + `resourceIds` [String] or `resources` [ReqResource]; host names them |
| `access-requests` | requests list | profile |
| `access-requests-menu` | the tab strip's request menu at the pointer | — |
| `live-sessions` | active sessions; a host/beam narrows to it | profile or `proxy`,`home`, `match` [String], `title`, `subtitle` |
| `request-monitor-add` | open pane + pick resources for that cluster | profile |
| `tsh-relogin` | the heading's "Log in…" (sidebar.js:2255): the saved record's whole login dialog, else proxy + home | profile |
| `tsh-logout`, `tsh-make-active`, `tsh-remove-profile`, `tsh-copy-login`, `tsh-config`, `cluster-switch`, `cluster-web` | heading-menu verbs | profile |
| `beam-start` | Start a beam… | profile |
| `beam-menu` | beam menu; appends to args `menu` NSMenu, else pops up | `beam` (Beam) or a beam host |
| `beam-open`, `beam-delete` | | `beam`/host, `filesOnly` |
| `sessions-history` | Sessions dialog on Connection history (also registers `history` if nobody did) | — |

Calls: `open-command` (via `TshCommand.open`: tsh login with user, play, join), `open-host` (beams: `filesOnly`, `split` right/down), `tmux-open` (beams; args `session`, or `dialog: true` for "Open in tmux…"), `webapi-ping`, `cluster-mark-menu`, `split-right` validator (to decide whether to offer the beam split items).

## Not done / differences

- MFA-host check in beam tmux decision (`isMfaHost`) not ported (beams are not MFA hosts in practice).
- The requests dialog reads the profile's assumed requests fresh from the inventory after assume/drop (the original kept the stale profile).
- Transcript highlight honours "Regular expression" (the original escaped the query always).
- Sessions dialog state is per window (`RecordingsWindowState`).
- Return never confirms a consequential button (CLAUDE.md); only Close is the default.
- Monitor pane: one per window, drawn as an overlay; position shared in `requestMonitorPos`.
- Under `--snapshot` only, `teleport-ui-debug-tab` shows the tab in a panel with two made-up profiles.
