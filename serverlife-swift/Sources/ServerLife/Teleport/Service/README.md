# Teleport service

Port of `src/main/teleport.js` (minus the dialling helpers), `beams.js`,
`livesessions.js`, `sshconfig.js`, nettools.js `webapiPing`, the main.js
`teleport:*` / `beams:*` / `discovery:*` / `sshconfig:*` / `recordings:*`
handlers, and the renderer's inventory loading (sidebar.js `refreshInventory`,
`refreshProfile`, `refreshSshConfigs`; nodewatch.js; beams.js loop;
requestwatch.js; teleportpanel.js `autoLoginSavedClusters` / `runLoginInShell`).

No UI. Every function that names a proxy also takes the tsh `home`: pass the
profile's `homeDir` (two homes can hold the same proxy), or nil to let
`Tools.runTsh` pick the home from `--proxy=`.

`writeClusterSshConfig`, `teleportSshTarget` and `isLeafCluster` are in
Connections/TeleportSSH.swift; `Teleport.listClusters` feeds its leaf cache
(`TeleportSSH.recordClusters`).

## Files

| File | What |
|---|---|
| `TeleportBase.swift` | `TeleportHomes` (default home, `name`, `isDefault`, `active`, `setHomes`, proxy claims), `TPText` (plain/tshError/regex/date helpers), `TeleportProfile`, `TeleportCluster`, `TshList<T>`, `TshOutput`, `TshCommand`, `Host.nodeExpiresMs` / `nodeHomeName`, `TPLocked` |
| `TeleportService.swift` | `Teleport`: status, statusText, homesReport, listClusters, listNodes, markAmbiguous, clusterSshConfigText, login/logout/switch, profile removal, web links, latency |
| `TeleportRequests.swift` | access requests: list (+ name resolution), search, roles, show/assume/drop, create (+ args/preview), probe, role choices, rolesForResources |
| `TeleportRecordings.swift` | recordings (list, play, text, search with progress + cancel, save transcript, web link) and live sessions (list, join) |
| `Beams.swift` | `Beams`: probe (cached), list/add/remove/stillListed/exec/publish/unpublish/scp, ssh/exec argv, `expiresIn` |
| `SSHConfig.swift` | ssh_config discovery, the managed ServerLife block, `tsh config` preview/write |
| `WebAPIPing.swift` | `/webapi/ping` and its field layout |
| `Inventory.swift` | `Inventory.shared`: the live model + loops |

## Profile key (`tpKey`)

`TeleportProfile.key` / `TeleportProfile.key(cluster:proxy:home:)`:

- `cluster`, or the proxy when tsh did not name a cluster;
- for a profile from a **non-default** tsh home, `"<cluster>@@<home>"`, where
  `<home>` is the expanded home directory (`profile.home`; nil for the default
  home, so a default-home profile keeps the bare cluster name every stored
  setting refers to).

Node lists, cluster lists and live requests in `Inventory` are keyed by it.

## Inventory (`@MainActor @Observable`, `.shared`)

Started by `TeleportServiceFeature.install()`: applies `settings.tshHomes` /
`tshPath` (and follows later changes through `Store.onSettingsChanged`; a
changed home list triggers a full reload; a changed `nodeRefreshSeconds`
restarts the node loop), runs the first full load, starts the loops, then
auto-logs-in saved clusters flagged `autoLogin` (one at a time; ones naming a
user open a terminal tab).

**Change signal.** Collections are read through accessors that read a counter:
`generation` (hosts, profiles, nodes, clusters, errors, tool info),
`beamsGeneration`, `requestsGeneration`. Counters move only on real change
(full loads always bump). Observed directly: `loading`, `loadedOnce`,
`refreshingGroups` (profile keys, or "ssh"/config path, while their own refresh runs).
Callbacks: `onInventory`, `onBeams`, `onRequests`.

Data: `sshHosts: [Host]`, `sshConfigFiles: [SSHConfigFile]`,
`managedSshHosts: [String]`, `profiles` / `liveProfiles: [TeleportProfile]`,
`nodesByKey: [key: [Host]]` (unfiltered), `nodes(for: profile)` (without the
`beam-<uuid>` nodes beams register as), `allNodes`, `nodeCount`,
`clustersByKey` / `clusters(for:)`, `teleportError`, `tshInfo`, `toolInfo`
(`{tsh, ssh}`), `tshMissing`, `homeErrors`, `badge` (text, kind — the sidebar's
tsh badge), `beamsByProxy`, `beamSupport`, `beamsFor(proxy)`, `beamProfiles`,
`markedAsBeams`, `beamsSupported`, `beamNodeNames()`, `accessRequests`,
`requestsFor(profile)`, `allLiveRequests()`, `requestSummary()`,
`profile(forKey:)`, `profile(for: host)`, `host(id:)`, `anyWindowVisible`.

Actions: `refresh()` (full; concurrent calls share one load),
`refreshProfile(p)`, `refreshSshConfigs(key:)`, `refreshProfiles()`,
`refreshNodes(emit:)`, `markExpiredByClock()`, `refreshBeams(refresh:proxy:)`,
`hideBeamsFor`, `showBeamsFor`, `setMarkedAsBeams`, `refreshRequests()`,
`autoLoginSavedClusters()`, `runLoginInTerminal(options, title:, window:)`,
`start/stopNodeLoop`, `start/stopBeamsLoop`, `start/stopRequestLoop`.

Loops (only while a window is visible): nodes every `nodeRefreshSeconds`
(default 10, 0 = off; skipped during a full load or while the last tick runs;
expiry by clock, then `tsh status`, then `tsh ls` per live profile; a failed
read keeps the old list), beams every 60 s (only if some cluster has beams),
requests every 90 s.

Hooks for the sidebar: `nodesRead` (each list actually read, before change
detection — heartbeat `observe`, `noteRead`, `noteSeen`), `nodeSignatureExtra`
(heartbeat signature folded into change detection), `afterLoad` (run at the end
of each full load: folder repair, macros, S3 …).

Host nodes: `id` (`tsh:<cluster>:<uuid>`, or `tsh:<homeName>:<cluster>:<uuid>`
outside the default home), name/hostname, uuid, addr (`tunnel` when tunnelled),
tunnel, subKind, `expires` (ISO; only when it really expires — read
`nodeExpiresMs`), cluster, proxy, home, labels (command labels resolved),
ambiguous, `extra.homeName`. ssh hosts: see `SSHConfig.hostsFromConfig`.

## Teleport (static)

Status: `status() -> Status{loggedIn, profiles, tsh, homes, error, homeErrors}`,
`statusIn(home:)`, `parseStatusJSON`, `parseStatusText`, `statusText(proxy:home:)`,
`homesReport()` (teleport:homes), `version()`, `tshStatus`, `toolStatus`.
Inventory: `listClusters(proxy:home:)`, `listNodes(proxy:cluster:home:)`,
`parseNodes`, `parseClusters`, `markAmbiguous`, `clusterSshConfigText`.
Login: `LoginOptions`, `proxyAddress`, `loginArgs`, `login` (background, 5 min),
`loginCommandArgs -> TshCommand` (teleport:loginArgs — **use this for logins
naming a user**: `cmd.open(title:onExit:)` runs it via `open-command`),
`loginCommand` (paste line with TELEPORT_HOME), `switchProfile`,
`markCurrentProfile`, `logout`. Profiles on disk: `profilePaths`,
`removeProfile`, `profileFiles`. Web: `webClusterUrl`, `openWebCluster`,
`webSessionUrl`, `openWebSession`. Terminal commands (`TshCommand`):
`latencyCommand`, `playCommand`, `joinCommand` (args-only variants too).
Requests: `requestKinds`, `listRequests(resolveNames:refresh:)`,
`searchRequestable`, `searchRequestableRoles`, `parseRequestableRoles`,
`parseLabelString`, `showRequest`, `assumeRequest`, `dropRequest`, `RequestSpec`,
`createRequestArgs`, `requestPreview`, `createRequest -> CreatedRequest{requestId,
roleChoices, needsReason}`, `probeRequest`, `readProbe`, `roleChoicesFrom`,
`rolesForResources`. Recordings: `listRecordings`, `toRecordingDate`, `playText`,
`searchRecordings(RecordingSearch, onProgress:)`, `cancelRecordingSearch()`,
`saveTranscript(...)`, `chooseTranscriptDir()`. Live sessions:
`listActiveSessions`, `parseSessionList`, `joinArgs`, `joinableKinds`, `joinModes`.

## SSHConfig (static)

`listSshHosts(extra:)` (discovery:ssh), `listConfigFiles(extra)`,
`collectAliases`, `resolveHost` (`ssh -G`), `readAliasFromFile` (no-ssh
fallback), `addHost(ManagedSSHHost)`, `removeHost(alias)`, `managedAliases()`,
`tshPreview(proxy:cluster:home:) -> (text, TshConfigState{present, foreign})`,
`writeTshConfig(cluster:proxy:text:)`, `pickConfigFile()`, `pickKey()`.
Writers take `configPath:` (default `~/.ssh/config`).

## Beams (static)

`supported(proxy:home:refresh:)`, `list(all:)`, `add(region:)`,
`remove(name:)` (3 tries on the concurrency race; "does not exist" = gone),
`stillListed`, `exec`, `publish(tcp:) -> url`, `unpublish`, `scp`, `sshArgs`,
`execArgs`, `expiresIn`.

## WebAPIPing

`ping(proxy:insecure:) -> Result{url, ms, ping, badges, sections,
licenseWarnings, note}` — no credentials, no redirects, 15 s, 2 MB.

## Action ids

`MiscHooks.teleportHomes` is set to `Teleport.homesReportJSON()` (teleport:homes JSON).

`inventory-refresh` — full inventory reload (the sidebar's `refresh` can call
`Inventory.shared.refresh()` directly).

## Not done / differences

- One shared inventory for all windows (the original kept one per window).
- Saved logins come from Data/'s `Store.listTshLogins()`; `markSavedLoginUsed`
  forwards to `Store.markTshLoginUsed`.
- Connector sections of the ping list keys sorted (JS used insertion order).
