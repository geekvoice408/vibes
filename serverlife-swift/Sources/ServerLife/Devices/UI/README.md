# Devices/UI — tmux, VNC, serial, telnet and RDP (consoles)

Owner: **consoles**. Ports `src/renderer/js/tmux.js`, `vnc.js`, and the
console/screen opening flows of `sessions.js` (`openDeviceSession`,
`startDeviceSession`, `openVncSession`, the device/tmux/VNC pane-menu
entries), `sidebar.js` `launchProfile` (serial/telnet/vnc/rdp branches) and
`quickconnect.js` `connectQuick` (the same). Built on Devices/Service and on
Sessions' extension points. No forms live here: the profile editor (hosts),
the `+` picker (hosts), the network tools' serial/telnet tab (nettools) and
the host menu's "Open in tmux: …" routing submenu (sidebar) call the ids below.

## Action ids

| id | does | host / args |
|---|---|---|
| `tmux-open` | Open a host in tmux. With `session` it attaches straight away (`openTmux`); without, the **tmux on <host>** dialog lists the sessions already running and offers to start one (`openTmuxDialog`). `Host.localMachine` (type `local`) = tmux on this Mac. | host; `login` String, `session` String, `dialog` Bool (true = always the dialog, even with `session`) |
| `serial-open` | A serial console in a tab (`openDeviceSession` kind serial). | host = device spec (below); `split` "right"/"down" |
| `telnet-open` | A telnet session in a tab. | host = device spec; `split` |
| `vnc-open` | A VNC screen in a pane (`openVncSession`). | host = VNC spec; `password` String (used once, never saved); `split` |
| `rdp-open` | Write the `.rdp` file and open it with the app this Mac opens `.rdp` files with (a Microsoft client by bundle id only when nothing claims `.rdp`, as rdp.js's `openPath`); status "<name> opened in your Remote Desktop client", errors as toasts. | host = RDP spec |
| `serial-ports` | The serial ports present now, for the `+` picker (rows: label = path, meta = `ConsolesText.serialPortMeta(port)` = "label · 115200 8N1", badge "serial", group "This machine"; choosing one = `serial-open` with `{type:"serial", path, name: path}`). | `reply` `([SerialPortInfo]) -> Void` and/or `replyJSON` `(JSON) -> Void` |

### Specs (the original's field names, carried on `Host` — unknown keys sit in `Host.extra` and round-trip)

- **serial**: `type` "serial", `name`, `path`, `baudRate`, `dataBits`, `parity`, `stopBits`, `rtscts`, `xon`, `xoff`,
  `newline` ("cr" default / "lf" / "crlf"), `localEcho`, `startupCommand` (sent once the console is open, as
  `launchProfile` did). Defaults 115200 8N1.
- **telnet**: `type` "telnet", `name`, `host` (or `hostname`), `port` (or `devicePort`, default 23), `newline`
  (default "crlf"), `localEcho`, `startupCommand`. With no `name` the tab reads `host:port`.
- **vnc**: `type` "vnc", `name`, `host`/`hostname`, `port`/`devicePort` (5900), `viewOnly`, `scaling`
  ("scale"/"resize"/"none"), `quality` (0–9, default 6), `compression`, `shared`, `clipboard`.
- **rdp**: `name`, `host`/`hostname`, `devicePort`/`port` (3389), `username` (or `user`), `domain`, `fullscreen`,
  `multimon`, `width`, `height`, `colorDepth`, `clipboard`, `audio`, `printers`, `drives`, `adminSession`, `gateway`.

Every option is read from `Host.extra` first (`ConsolesDevices.options(host)` — how profiles and quick connect
pass them, see Hosts' `HostsOpen.deviceHost`), then from the descriptor's own fields (`hostname` → `host`, `port`,
`user`, `name`); "true"/"false" strings are read as booleans. `serial-open` / `telnet-open` also take a
`startupCommand` arg; either way it is typed (plus "\n") once, when the console first opens. It is not kept on
the pane's descriptor, so a restored layout only reopens the port.
A saved profile record (`Host(json: profileJSON)`) can be passed as is. The pane's `host` is the spec (password
removed), which is what Sessions saves in a layout and hands back to `<type>-open` on restore.

## What each does

**Consoles.** The tab opens first, then the port/socket; a serial console prints `[serial — /dev/cu.x · 115200 8N1]`
(telnet prints its own Trying/Connected lines). A failure to open is written in red in the pane, followed by
"[press Enter to reconnect]"; an ended session reconnects on Enter (Sessions' `reconnect` closure, which reprints the
banner). Pane menu (top): **Send break** on serial (300 ms; "Break sent"). Sessions adds "Close this console" /
"Open it again". Enter-sends and local echo are the spec's `newline` / `localEcho`.

**VNC.** `VNCPaneModel` + `VNCPaneView` (a `view` pane): "Connecting to host:port…", then the screen; on failure
"Could not connect" / "Session ended" with "host:port — why", the localhost-tunnel hint and **Try again**. The password
is asked for when the server wants one ("VNC password" / "<host> is asking for a password" / Connect) and never kept.
Scaling, quality, view-only from the spec. A **screen ▾** button in the pane header (right-click goes to the remote
screen when connected) and a right-click menu while nothing is drawn: **Send Ctrl+Alt+Del** ("Sent Ctrl+Alt+Del"),
**Paste into the session** ("Pasted into the remote session"; "Not connected" when it is not), **Reconnect**.
`pane.status` follows the session (connecting/connected/error/closed) for the quit guard.

**tmux** (`ConsolesTmux`, one `TmuxRecord` per attached session):
- Opening: MFA hosts refused ("<host> asks for MFA per session — tmux is not available on it"); a pending tab with
  the connect overlay and log ("Opening tmux on <host>…", Connecting…, Looking for tmux…, "tmux 3.4 is there.",
  Attaching…, "Attached — 2 windows, 3 panes. Reading back what is on them…"); failures as "Could not open tmux" with
  Retry. A host without tmux gets **This host has no tmux** / **This machine has no tmux** with the reason and the
  install command. The opening pane becomes the session's first pane; every other window is a tab; each pane is
  primed from `capture-pane` so a reattached session is not blank. Status "tmux 3.4 on web-1 — 2 windows".
- Layout follows tmux (`%layout-change` → Sessions `applyTmuxLayout`; foreign panes in the tab are kept); new and
  closed windows add/close tabs; renamed windows rename tabs and pane titles (`titleProvider`: "window · host",
  long "window · host · tmux %3").
- Splitting asks tmux (`SessionsTmux.split` for ⌘⇧D/⌘⇧E, and the menus).
- Client size = the active window's tmux layout measured over its panes' grids (`ConsolesText.clientSize`),
  debounced 120 ms, sent only when it changes.
- Header **tmux ▾** menu: heading, Split right/down, Layout ▸ (five + Next layout; disabled with one pane), Swap with
  the next pane, Move this pane to its own window, Type in all panes at once (asks tmux for `synchronize-panes` as it
  opens; "✓ on"), New tmux window, Close this tmux pane…, Close this tmux window… (confirmations worded as the original).
- Pane menu (top): Split right (tmux), Split down (tmux), New tmux window, Rename this window…, Rename the session…
  (validated; pins the new name in `tmuxSessionNames` for the host), Detach — leave it running, End this tmux
  session… (confirm, danger).
- Closing the last pane of a session (tab ×, window close) detaches; the session keeps running.
- Ended/detached/lost (`TmuxService` `onEnded`): every pane gets `tmuxEnded`, a grey line, no tmux menu; the tab is
  marked; the first pane of each tab gets the notice with **Reattach** unless the session is gone.
- Focus follows: `select-pane` on the focused pane, and its `#{pane_current_path}` as `pane.cwd` (fires
  `SessionHooks.cwdChanged`) so the file browser follows.
- One file browser per session: a new pane opens without one while another pane of the session shows one.
- Flow control: a paused pane says so, and is continued (`refresh-client -A %N:continue`) so "[resumed]" follows.

## Extension points used

Sessions: `open-backend` (with `reconnect`), `open-view-pane`, `openPendingTab`, `openTmuxWindow`,
`applyTmuxLayout`, `showOverlay`/`noteOverlay`/`hideOverlay`, `attach`, `endPaneSession`, `offerReconnect`,
`createConnection`, `PaneMenuItems` (.top), `PaneHeaderItems` (.tmuxControls), `SessionsTmux.split`,
`SessionHooks.paneClosing`, `SessionHooks.cwdChanged`, `SessionPane.titleProvider/tmuxEnded/attachments`.
Misc: `MiscUI.prompt/confirm`, `CtxMenu`, `MiscField`, `MiscHint`.

## Gaps / differences

- A VNC session whose password prompt was cancelled shows "Not connected — the connection was closed" with Try again
  (the original left "Connecting…" on screen).
- tmux checks over a connection time out as the original's (probe and list 15 s, `has-session` 10 s) via `TimedTmuxHost`.
- tmux tabs are not saved in layouts (as in the original; Sessions skips them).
