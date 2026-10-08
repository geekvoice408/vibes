# ServerLife (Swift) — instructions for agents

A native macOS port, **feature for feature**, of the Electron app in
`/Users/paul/git/teleport-toys-internal/serverlife` ("the original"). The
original's GUIDE.md (copied to `Resources/GUIDE.md`) is the spec; its source is
the reference for every behaviour, string, default and edge case. When the two
disagree, the source wins. Read the JS for your area **in full** before writing
Swift — the comments in it explain decisions that must survive the port.

Do not invent features, drop features, or "simplify" behaviour. Every menu
item, context-menu entry, setting, dialog field, tooltip that carries
information, keyboard shortcut and status message in your area must exist in the
Swift version. User-facing wording should match the original (it is careful).
Windows/Linux-only branches are the one thing to leave out (macOS only).

## Toolchain (hard constraints)

- SwiftPM + **Command Line Tools only** (Swift 6.4, macOS 27 SDK). No Xcode.
  Language mode Swift 5. Deployment target macOS 14.
- **`@State` does not compile** (its macro plugin ships only with Xcode). Use
  `@StateObject private var x = Local(value)` (App/LocalState.swift:
  `Local<T>`, `LocalFlag`, `HoverPopover`) and bind with `$x.value`.
  `@Observable`, `@Environment`, `@Bindable`, `@FocusState`, `@StateObject`,
  `@ObservedObject` are fine. No `#Preview`.
- No XCTest: tests use Swift Testing (`import Testing`, `@Test`, `#expect`),
  run with `Scripts/test.sh` (or `Scripts/agent.sh … test`).
- Bare-slash regex literals need `#/…/#`. Prefer `NSRegularExpression` when
  porting JS regexes (same semantics for the common subset).
- SwiftTerm is pinned to **1.11.2** (later versions need Xcode's `metal`).
- `CShim` (Sources/CShim) exposes zlib, `forkpty`, termios, ioctl, sockets,
  `libproc`. `import CShim` to use them.
- Child output: never `FileHandle.bytes`/AsyncBytes (stalls once stdin is
  written). Use `Proc.run` / `RunningProcess` / `PTYProcess` / `ProcessChannel`
  (Core/), which read on dedicated threads with bounded EOF waits.
- Concurrent `tsh` invocations contend on a credential lock in `~/.tsh`; don't
  fan out many tsh calls against one profile at once. Use timeouts.

## Layout

```
Sources/ServerLife/
  Core/        JSON, Store (sessions.json, compatible with the original), Proc,
               PTYProcess, ByteChannel/ProcessChannel, TerminalBackend/PTYBackend,
               Host (descriptor + prefKey/clusterPrefKey), Tools (ssh/tsh lookup,
               tsh homes, runTsh), Util (Fmt, Posix, shellQuote, HostColor …)
  App/         Main/AppDelegate/Features, MainMenu (every menu item → action id),
               Actions (registry), Windows (WindowModel, WindowManager,
               WindowFeature), MainWindowView (Slots), Modal (sheets, panels,
               confirm/prompt/choose, pickers, Clipboard), Theme (Palette),
               Components (button styles, Badge, Chip, SearchField,
               DialogScaffold, FormRow, OutputBlock, ColorSwatchPicker,
               EmojiPicker), DebugSnapshot, AppResources
  <Feature>/   one directory per owner — see Ownership
```

Shell owner (Core/, App/, Package.swift, Scripts/, CLAUDE.md) is the lead.
**Do not edit files outside the paths you own.** If you need something in
Core/App, add what you need in your own directory (extensions are fine; keep
helpers `fileprivate` or prefixed to avoid name clashes) and list the request
in your final report. Never add stored properties to another owner's types.

## Architecture rules

- **Singletons for services** (`static let shared`), `@MainActor @Observable
  final class` for anything the UI reads. Background work in `Task`s /
  `Proc.run`; hop back to the main actor to mutate observed state.
- **Per-window state**: `final class X: WindowFeature` and
  `window.feature(X.self)` — created lazily per window. No edits to
  WindowModel needed.
- **Store**: `Store.shared` holds the original's `sessions.json` document as
  `JSON`. Read/write settings with typed accessors you declare in your own
  files (`extension Store { var foo: Bool { get { setting("foo", false) } set {
  setSetting("foo", newValue) } } }`) — same keys and defaults as store.js
  (`Core/StoreDefaults.swift` is generated from it). Top-level collections:
  `Store.shared["profiles"]`, `list(_:as:)`, `setList`, `mutate`. The *data*
  owner ports store.js's methods (`upsertProfile`, `startHistory`, …) as
  `extension Store` in `Data/` with Codable record types; use those.
- **Actions**: cross-feature calls go through `Actions.shared.perform(id,
  ActionContext(window:host:paneId:connId:args:))`. Register yours in your
  feature's `install()`. Menu ids are the original's `menu` event strings.
  Documented ids are listed below; if you add one others should call, report it.
- **Slots**: the shell draws `Slots.tabStrip/titlebarActions/sidebar/
  workspace/dock/overlays`; the owning feature assigns them in `install()`.
  Status bar items: `StatusItems.shared.register`. Messages:
  `StatusBus.shared.show(text, kind:)`, `.toast(…)`.
- **Dialogs**: `Modal.sheet(window) { handle in DialogScaffold(…) }` for
  modal dialogs (stack over existing sheets), `Modal.panel(id:…)` for
  free-standing windows (guide, net tools, recordings, monitor),
  `await Modal.confirm/choose/prompt/alert`, `Modal.saveText`,
  `Modal.openFiles`, `Modal.chooseDirectory`, `Modal.saveFile`.
  Resizable dialogs that remember size: pass `autosave:`.
- **Return key**: the original's dialogs put focus on Cancel (or the first
  field), so Return never confirmed anything consequential. Do not give a
  destructive or data-changing button `.keyboardShortcut(.defaultAction)`;
  Escape (`.cancelAction`) closes. Return may submit only where the original
  bound Enter explicitly (e.g. prompt fields, search boxes).
  `Modal.confirm/choose` already behave this way (`detail:` = the hint line).
- **Theme**: `Theme.shared.p` (Palette: bg, panel, panel2, panel3, border,
  borderSoft, text, textDim, muted, accent, accentDim, green, red, amber,
  purple). Never hard-code UI colours except the data colours the original
  hard-codes (host colours, kind colours).
- **Hosts**: `Host` mirrors the JS descriptor (same JSON keys; unknown keys in
  `extra`). Per-host prefs are keyed by `host.prefKey`, per-cluster by
  `host.clusterPrefKey`, exactly as store.js.
- IDs: `newId("p")` (store records), `uid("tab")` (UI objects). Timestamps in
  stored records are ms since epoch (`nowMs()`), as in the original.
- Errors shown to people: throw `AppError("message")`; the message is shown
  verbatim, so write it the way the original does.

## Working in parallel (mirrors)

Several agents work at once. Each works in a **private mirror** and publishes
only its own paths when they compile:

```sh
Scripts/agent.sh <name> <owned,paths> pull      # refresh mirror from the published tree
Scripts/agent.sh <name> <owned,paths> path      # where to edit (do ALL edits there)
Scripts/agent.sh <name> <owned,paths> build     # swift build in the mirror
Scripts/agent.sh <name> <owned,paths> test [--filter X]
Scripts/agent.sh <name> <owned,paths> publish   # pull + build + copy owned paths out
```

Pull often (others publish as they go). Publish whenever you reach a
compiling milestone, and always before you finish. Never write directly into
the published tree. Put tests in `Tests/ServerLifeTests/<YourArea>/` (owned
by you).

To look at UI: build in the mirror, then run
`.build/debug/ServerLife --snapshot /tmp/x.png --data-dir /tmp/sl-<name> --actions id1,id2 --delay 3`
from the mirror and Read the PNG(s) (main window, plus `-1`, `-2` … for
sheets/panels). Screen capture is not available; this is how to see.

**Do not connect to the user's real servers, log in, or change anything in
`~/.ssh`, `~/.tsh` or `~/.aws`.** Read-only commands (`tsh status`, `tsh ls`
on an already-logged-in profile, `ssh -G`) are fine for checking parsers. For
SFTP, test against a local `/usr/libexec/sftp-server` over stdin/stdout.

## Ownership

| Owner | Paths | Ports (original files) |
|---|---|---|
| lead | Core/, App/, Package.swift, Scripts/ | main.js shell, preload.js, util.js, state.js plumbing |
| data | Data/ | store.js methods, backup.js, multiexecfile.js, ansible.js, js-yaml subset |
| connections | Connections/ | connections.js, local.js (local shells), authprobe.js, x11 status, sshbin.js glue |
| teleport-service | Teleport/Service/ | teleport.js, beams.js, livesessions.js, sshconfig.js, inventory loading (renderer state/teleport loading) |
| files-service | Files/Service/ | local.js (local filesystem half), sftp.js, transfers.js, crosstransfer.js, syncdirs.js, watchdirs.js, findfiles.js, fsx.js, filekinds.js, rsync.js, downloads |
| devices-service | Devices/Service/ | devices.js, tmuxctl.js, localhost.js, rdp.js, VNC (RFB client replacing noVNC + vncbridge.js) |
| sessions | Sessions/ | sessions.js, tabs.js, term.js, activity.js, highlight.js, links.js, workspace.js, connectanim.js, quitguard.js, index.js glue |
| sidebar | Sidebar/ | sidebar.js, hostactions.js, tags.js, tagbrowser.js, heartbeat.js, nodewatch.js, narrowed.js, clustermarks.js, requestable.js |
| hosts | Hosts/ | folders.js, folderview.js, hostspane.js, profiles.js, addserver.js, quickconnect.js, history.js |
| explorer | Files/Explorer/ | explorer.js, files.js, rsyncsync.js, watch.js |
| teleport-ui | Teleport/UI/ | teleportpanel.js, requestpicker.js, requestwatch.js, reqmonitor.js, recordings.js, livesessions.js (UI), beams.js (UI) |
| fleet | Fleet/ | dock.js, macros.js, snippets.js, multiexec.js |
| nettools | NetTools/ | nettools.js (main + renderer), keys.js, sshkeys.js |
| consoles | Devices/UI/ | tmux.js, vnc.js, serial/telnet/RDP panes and forms |
| city | City/ | city3d.js, cityarch.js, cityactors.js, cityprocs.js, cityscan.js, procscan.js |
| misc | Misc/ | settings dialog (index.js `openSettings`), themes.js, guide.js, tour.js, changelog.js, versions.js, ui.js leftovers, backup.js UI, about |
| automation | Automation/ | control.js, mcp/serverlife-mcp.mjs (as `ServerLife --mcp`), automation.js, s3.js (both), awscreds.js, awsproxy.js |

Each owner documents its public API in `<dir>/README.md` (types, functions,
action ids, what is not done yet and why).

## Action ids (cross-feature contract)

Menu ids (registered by the owner in brackets): about, settings,
version-history, guide, tour [misc] · new-window, toggle-sidebar,
toggle-transfers, teleport-docs [lead] · new-session, new-local,
duplicate-tab, split-right, split-down, split-right-host, split-down-host,
move-pane-left/right/up/down, close-pane, toggle-log, broadcast, find,
clear-terminal, zoom-in, zoom-out, zoom-reset, tab-1…tab-9, tab-prev,
tab-next, save-layout-as, load-layout, manage-layouts, save-layout,
clear-layout, disconnect [sessions] · quick-connect, add-server, history
[hosts] · toggle-files, explorer-position, local-files [explorer] · refresh
[sidebar] · teleport-panel, cluster-info, request-monitor, recordings,
tsh-login [teleport-ui] · snippets, run-macro, multiexec [fleet] · keys,
nettools [nettools] · s3 [automation].

Cross-feature ids (args in `ActionContext.args`):

- `open-host` [sessions] — host; args: `login` String, `transport` "tsh",
  `x11` "trusted"/"untrusted", `filesOnly` Bool, `tmux` Bool,
  `tmuxSession` String, `split` "right"/"down", `newWindow` Bool,
  `profileId`, `startupCommand`, `remoteStartPath`, `localStartPath`,
  `mfaMode`, `noTmux` Bool.
- `open-local` [sessions] — args: `shell` path, `blank` Bool, `cwd`, `split`.
- `open-command` [sessions] — a tab running a local program on a pty
  (tsh play, tsh latency, tsh login --user …): args `title`, `exe`, `argv`
  [String], `env` [String:String], `cwd`, `onExit` `(Int32?) -> Void`.
- `open-backend` [sessions] — a tab/pane for any TerminalBackend: args
  `backend` TerminalBackend, `title`, `host` (optional), `split`.
- `open-view-pane` [sessions] — a pane showing a non-terminal view (VNC):
  args `title`, `view` `() -> AnyView`, `onClose` `() -> Void`, `host`.
- `send-text` [sessions] — args `text`, `enter` Bool; to `paneId` or the
  focused pane. `send-text-all` — every remote pane in the tab.
- `host-menu` [sidebar] — args `menu` NSMenu: append the host context menu
  items for `host` (used by the hosts pane and folder browser).
- `run-command` [sidebar, from hostactions.js] — "Run a command…" dialog for `host`.
- `port-forward` [sidebar, from hostactions.js] — dialog for `host`/`connId`;
  args `preset` JSON. `forward-favorite-open` [sidebar] — args `favorite` JSON.
- `server-profile` [sidebar, from hostactions.js] — "Server profile" for `host`/`connId`.
- `run-macro` [fleet] — macro menu on `paneId` (or focused pane).
- `multiexec` [fleet] — args `hostIds` [String] preselects.
- `nettools` [nettools] — args `connId` to run on that session.
- `recordings` [teleport-ui] — `host` pre-filters.
- `access-request-new` [teleport-ui] — args `cluster`, `proxy`,
  `resourceIds` [String].
- `tsh-status` [teleport-ui] — host/cluster's status dialog.
- `tsh-login` [teleport-ui] — args `proxy`, `cluster`, `user`, `home`.
- `tmux-open` [consoles] — host. `vnc-open`, `serial-open`, `telnet-open`,
  `rdp-open` [consoles] — host (device descriptor).
- `hosts-pane` [hosts] — args `groupKey`. `folders-browser` [hosts] — args
  `groupKey`. `edit-profile` [hosts] — args `profileId` or `profile` JSON.
- `webapi-ping` [nettools] — args `proxy`: the Teleport cluster tool on that proxy.
- `open-on-connection` [sessions] — open a pane on an existing `connId`.
- Stand-in files for unpublished owners must have owner-unique names
  (`_<Owner>DataStandIn.swift`): SwiftPM rejects duplicate file names.
- `city-open` [city] — args `explorer` (the explorer model), optional `on` Bool.
- `city-panel` [city] — development-only stand-alone city window.
