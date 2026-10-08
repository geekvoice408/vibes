# Automation — control socket, MCP bridge, S3, AWS

Owner: **automation**. Ports `src/main/control.js`, `src/renderer/js/automation.js`,
main.js `CONTROL_VERBS` / `control:*` / `s3:*` / `aws:*`, `mcp/serverlife-mcp.mjs`
(as `ServerLife --mcp`), `src/main/s3.js`, `src/main/awscreds.js`,
`src/main/awsproxy.js` and `src/renderer/js/s3.js`. Resources/MCP.md is the
protocol spec and is followed as written (paths differ: see below).

## Files

| File | What |
|---|---|
| `AutomationFeature.swift` | `install()`: actions, S3 list load, control socket start, quit teardown |
| `Control/ControlServer.swift` | the Unix socket (0600, in the per-user temp dir), token file (0600), auth, NDJSON, 1 MB line cap |
| `Control/ControlVerbs.swift` | main-side verbs: status, list_hosts, list_clusters, login_command, list_layouts, list_beams, list_forwards, open_forward, list_requests, run_request, sync_preview, sync_apply; `targetConnection` |
| `Control/AutomationWindow.swift` | window-side verbs (automation.js): list_sessions, open_session(s), list_tmux, close_session, load/save_layout, list/run_macro, focus_window; `findHost`, `openOne`; `AutoHostPrefs` |
| `Control/AutomationControl.swift` | `control:status/setEnabled/rotateToken`, activity line, `mcpCommand` |
| `Control/AutomationHooks.swift` | extension point for fleet (macros) |
| `Control/MCPBridge.swift`, `MCPTools.swift` | `ServerLife --mcp` (JSON-RPC over stdio; the 21 tools generated verbatim from the original's TOOLS array) |
| `S3/SigV4.swift` | Signature V4 (tested against AWS's published S3 vectors) |
| `S3/S3Target.swift` | pure s3.js: storage classes, credentials, endpoints/URIs, prefixes, XML, errors |
| `S3/S3HTTP.swift`, `S3/S3Client.swift` | URLSession exchange (no redirects, streamed uploads, tunnel + CA pinning; downloads to a file go through `/usr/bin/curl --raw` so a Content-Encoded object is saved byte for byte — URLSession always decodes); list/prefixInfo/head/download/upload/remove/copy/listBuckets/bucketRegion/test; 301 region retry |
| `S3/AWSCreds.swift`, `S3/AWSProxy.swift` | ~/.aws profiles (CLI `export-credentials`, static-key fallback); `tsh proxy aws` per app, apps/roles/login/logout |
| `S3/S3Secrets.swift` | stored keys sealed with AES-GCM, key in the login Keychain; refused without one |
| `S3/S3Service.swift` | `S3Service.shared`: targets (no secrets), save/delete, `usable`, every `s3:*` / `aws:*` handler, relays |
| `S3/S3FileSource.swift` | a bucket as a `FileSource` |
| `S3/S3UI.swift`, `S3Editor.swift`, `S3UIBase.swift` | manager, register/edit, browse buckets, storage-class picker, *Saved → S3* tab view, explorer helpers |
| `_AutomationDataStandIn.swift` | `auto…` forwarders to Data/'s store.js port (s3Targets, layouts, forwardFavorites, netRequests, tshLogins, profiles) |

## Action ids

| id | does | args |
|---|---|---|
| `s3` (menu) | S3 buckets manager | — |
| `s3-register` | Register / edit dialog | `target` JSON (a record from `S3Service.shared.targets`) to edit |
| `s3-reload` | re-read `s3Targets` (after a backup import) | — |
| `automation-status` | `control:status` | `reply: (JSON) -> Void` → `{running, socketPath, tokenFile, token, clients, enabled, mcpCommand, bridge, verbs}` |
| `automation-toggle` | `control:setEnabled` | `enabled` Bool, `reply` (status fields or `{error}`) |
| `automation-rotate` | `control:rotateToken` (restarts a running socket) | `reply` → `{token}` |
| `automation-copy-command` | copies the `claude mcp add` line (`what` "mcp") or the binary path ("bridge"), status "Copied" | `what` |

Actions this **performs** that others own: `explorer-show-source` (explorer —
please register: args `source` "s3:<targetId>"; point the focused pane's explorer
at it, opening a local shell first if none, as sidebar.js `openS3InExplorer`),
`tmux-open` (consoles; args `login`, `session`).

## For the explorer (Files/Explorer)

- Sources: `S3Service.shared.sources: [S3FileSource]` (one per bucket, same order
  as `targets`; observe `S3Service.shared.generation` or append to `onChange`).
  Paths are key prefixes ("" = bucket root); entry paths are full keys;
  `extra["storageClass"]`. `capabilities` is empty; unsupported calls throw messages.
- `S3UI.contextMenu(owner, targetId:, entry:, selection:, prefix:, open:, copyToPane:, info:, refresh:) -> [CtxItem]`
  is `_s3ContextMenu` (feed it to `CtxMenu.show`).
- `S3UI.transfer(owner, from: .local/.s3(id:)/.remote(connId:), to:, entries:, destDir:)` is
  `s3Transfer` (storage-class prompt, relays, toasts); returns true when the
  destination should refresh. Copy-to-pane's picker stays yours.
- `S3UI.info(targetId:, entry:) -> [(label, value)]` is `_s3Info`;
  `download/upload/retier/delete` are `_s3Download/_s3Upload/_s3Retier/_s3Delete`;
  `pickStorageClass(owner, target:, current:)`.
- The original hides Sync, Details, search and the 3D view for a bucket.

## For the sidebar

`S3SavedTab(window:, filter:)` is *Saved → S3* (`renderS3Tab` + `s3Row`: empty
state, Buckets group, Register…/Manage…, row tooltip, double-click to browse,
the row's context menu). `S3UI.rowMenu(owner, t)` gives the menu as `CtxItem`s if
you draw rows yourself. The `s3Targets` reload the original did on sidebar
refresh is `S3Service.shared.reload()`.

## For fleet

Set `AutomationHooks.listMacros` (every macro incl. built-ins, as state.macros)
and `AutomationHooks.runMacro(window, macro, all)` (`sendMacro`). Until then
`list_macros` / `run_macro` answer "… is not available to automation in this build yet."

## Behaviour notes

- Off until Settings turns it on (`settings.controlSocket`). Socket:
  `<per-user temp dir>/serverlife-<sha256(dataDir+uid)[0:16]>.sock` (the temp dir is
  asked of the system, `confstr(_CS_DARWIN_USER_TEMP_DIR)`, so a shell with another
  TMPDIR still finds it). Token: `<dataDir>/control-token`, 64 hex, 0600. Every
  accepted call, the start/stop and denials show as "Automation: …" for 5 s.
- `ServerLife --mcp` finds the app by `SERVERLIFE_USER_DATA`, else `--data-dir`,
  else `~/Library/Application Support/ServerLife-Swift`; `SERVERLIFE_SOCKET`,
  `SERVERLIFE_TOKEN` override. One connection per call; calls are answered
  concurrently; never starts NSApplication or reads the Store.
- `mcpCommand` is `claude mcp add serverlife -- "<binary>" --mcp`, plus
  `-e SERVERLIFE_USER_DATA=…` when the app runs on a non-default data dir.
- Window verbs go to the focused window with the original's timeouts (60/120/300 s).

## Differences / not done

- Resources/MCP.md is rewritten for this port (`ServerLife --mcp`, ServerLife-Swift paths).
- Paths: data dir is ServerLife-Swift, so the socket hash differs from the
  Electron app's and the two never collide; MCP.md's `node …mjs` lines read
  `"…/ServerLife" --mcp` here.
- `enc:` secrets from the Electron app (Chromium safeStorage) cannot be opened;
  such a bucket says to enter its key again.
- `s3:list` kept profile/app/role (the original dropped them, so editing a
  profile or Teleport bucket forgot its choice). A blank secret on a stored
  bucket is used for *Test* in the editor too.
- A bucket registered with a prefix: listings no longer join the prefix twice
  when opening a folder (`S3Pure.listingBase`).
- `open_session` throws "Could not open X." when the connection could not be
  created (the original reported success with the host name).
- tmux opens through `tmux-open` (fire and forget): the answer carries the
  session name asked for, not one read back.
- No original tests covered these files; Swift tests: SigV4 vectors, pure S3,
  AWS parsing, socket auth/rotation/permissions, MCP protocol, the `--mcp`
  binary end to end.
