# Devices/Service — serial, telnet, tmux control mode, VNC, RDP

Owner: **devices-service**. Ports `src/main/devices.js`, `tmuxctl.js`,
`localhost.js`, `rdp.js`, the `device:* / tmux:* / vnc:* / rdp:*` handlers in
main.js, and replaces noVNC + `vncbridge.js` with a native RFB client.
No UI lives here: panes, dialogs and menus are the consoles owner's
(`Devices/UI`). Nothing here registers actions. `DevicesServiceFeature.install()`
only closes everything on quit.

## Serial and telnet (`DeviceBackend.swift`, `Serial.swift`, `Telnet.swift`)

`DeviceBackend` is a `TerminalBackend` (kind `"serial"` / `"telnet"`), main actor.

| Call | Original |
|---|---|
| `await DeviceSessions.shared.listPorts() -> [SerialPortInfo]` (`path`, `manufacturer`, `serialNumber`, `vendorId`, `productId`, `label`; `.json`) | `device:ports` |
| `try await DeviceSessions.shared.open(_ json: JSON)` — `kind` "serial"/"telnet" plus the original's option names | `device:open` |
| `try await DeviceSessions.shared.openSerial(SerialOptions)` / `openTelnet(TelnetOptions)` | same, typed |
| `backend.label` (`/dev/cu.x · 115200 8N1`, `host:port`), `backend.greeted` (telnet printed its own Trying/Connected lines — don't add a banner) | open's answer |
| `write`, `resize` (re-sends NAWS once agreed), `close()` | `device:write/resize/close` |
| `try await backend.sendBreak(ms:)` (clamped 50…2000; the pane menu used 300) | `device:break` |
| `try backend.setSignals(SerialSignals(dtr:rts:brk:))`, `try backend.getSignals()` (CTS/DSR/DCD/RI) | `device:signals` |
| `backend.newline` ("cr"/"lf"/"crlf"), `backend.localEcho` — settable live | |

- `SerialOptions(json:)` reads `path, baudRate, dataBits, stopBits, parity,
  rtscts, xon, xoff, newline, localEcho` with the original defaults
  (115200 8N1, no flow control, Enter sends CR). `TelnetOptions(json:)` reads
  `host` (or `hostname`), `port` (or `devicePort`, default 23), `cols`, `rows`,
  `newline` (default CRLF), `localEcho`.
- Output before `onData` is set is held and delivered on assignment (the
  original's `device:ready`); an end before `onExit` is set is delivered on
  assignment. `onExit(0, reason)` reasons: `port closed`, the port error text,
  `connection closed by foreign host`, `closed from this end` (also on `close()`
  and on `^]`).
- Error wording is the original's: `"<path> is in use by something else —
  screen, minicom or another window"`, `"<path>: permission denied"`,
  `"<path> is not there — the adapter may have been unplugged"`,
  `"telnet: Unable to connect to remote host: Connection refused (h:23)"` …
- All writes to the line (keys, telnet replies, NAWS) go through one serial
  queue per backend: in order, never interleaved, never on the main thread.
- Ports are opened exclusively (TIOCEXCL + flock, as serialport did);
  non-standard rates use IOSSIOSPEED; DTR/RTS are raised on open.
- Pure helpers (tested): `Telnet.parse/nawsFrame/escapeIAC/greeting/errorText`,
  `translateNewline`, `UTF8Carry`, `SerialPorts.hint`, `SerialOptions.flags`.

## tmux control mode (`TmuxProtocol.swift`, `TmuxSession.swift`, `TmuxLocalHost.swift`)

```swift
@MainActor protocol TmuxHost: AnyObject {
    func execResult(_ cmd: String) async -> ProcResult
    func spawnCommandPTY(_ cmd: String, cols: Int, rows: Int) throws -> PTYProcess
    var transportKind: String { get }                       // "local", "mux", "tsh", "beam"
    func spawnCommandChannel(_ cmd: String) throws -> ByteChannel  // default throws; beams need it
}
```

Implemented by `TmuxLocalHost.shared` (this Mac; id `TmuxLocalHost.localId` =
"local") and by `Connection` (`Connection+TmuxHost.swift`; beams run `tmux -C`
over `spawnCommandPipe`).

`TmuxService.shared` (the `tmux:*` handlers):

- `await probe(host) -> TmuxProbe` (`ok, version, major, minor, flowControl,
  clientNeeded, reason, install`; reason/install worded as the original —
  `brew install tmux` here, `apt install tmux · dnf install tmux · apk add
  tmux` on a host).
- `await listSessions(host) -> [TmuxSessionInfo]`.
- `try await attach(host, session: name?, cols:, rows:, configure: { s in … })
  -> TmuxSession` — probes (throws its reason), attach-or-create, flow control
  on 3.2+, first window list loaded. Set callbacks in `configure` to see the
  first events.
- `session(id)` (throws "that tmux session is not attached any more"),
  `await detach(id)` (→ `onEnded("detached", true)`), `await kill(id)`
  (→ `onEnded("ended", false)`), `stillThere(s)`, `closeAll()`.

`TmuxSession` (main actor): `id`, `sessionName`, `version`, `ready`,
`activeWindow`; `try await command(_:) -> [String]` (a `%error` throws tmux's
words), `writePane(pane, data)` (hex `send-keys`, batched 6 ms),
`await resize(cols:rows:)` (client size: `refresh-client -C`),
`try await capture(pane, lines: 2000)`, `await refreshWindows()`,
`windowList() -> [TmuxWindow]` (`id, name, active, layout, tree, panes,
zoomed`), `activePane(of:)`, `await continuePane(pane)`, `await detach()`,
`await kill()`, `close()`, `backend(for: pane) -> TmuxPaneBackend`.
Callbacks: `onOutput(pane, data, ageMs)`, `onWindows`, `onLayout(window,
layout, tree)`, `onWindowClose`, `onActiveWindow`, `onPause(pane, paused)`,
`onSessionName`, `onExitNotice`, `onClientExit`, `onEnded(reason, alive)`
(alive: true still on the host, false gone, nil connection lost — main.js
`tmux:ended`).

`TmuxPaneBackend` is a `TerminalBackend` (kind "tmux") for one pane: output
from `%output`, keys via `send-keys -H`, `cwd()` via `#{pane_current_path}`.
`resize` only records the size and calls `onResize` — the window turns all
pane sizes into one client size (tmux.js `clientSize`) and calls
`session.resize`. `close()` stops the view only; it never ends by itself —
call `finish(reason:)` when a pane should show as ended. `paused` mirrors
flow control.

Pure, tested: `Tmux.unescapeOutput/hexKeys/probeAnswers`, `TmuxLayout.parse`
(tree with `w,h,x,y,pane|dir,children`, `.panes`, `.json`), `TmuxParser`
(chunked feed → `TmuxEvent`s), `TmuxControl.parseProbe/parseSessions/fields`.

## RDP (`RDP.swift`)

`RDPConnection(json:)` (hostname/host, port/devicePort, username, domain,
fullscreen, multimon, width, height, colorDepth, clipboard, audio, printers,
drives, adminSession, gateway, name) → `RDPLauncher.rdpFile(_:)` (CRLF `.rdp`),
`rdpPath(_:)` (`$TMPDIR/serverlife-<name>.rdp`), `clientAvailable()`,
`clientName()`, `clientApp()` (Windows App / Microsoft Remote Desktop by bundle
id `com.microsoft.rdc.macos` and older ids, else whatever opens `.rdp`), and
`try await launch(_:) -> Launched(client: "system", file, app)` — throws "No
hostname" or the original's "No RDP client is set up to open .rdp files —
install Windows App (formerly Microsoft Remote Desktop) from the App Store".

## VNC (`VNC/`)

`VNCSession` (main actor, `@Observable`):

- `VNCSession(options: .init(json: spec))` — `shared` (default true),
  `viewOnly`, `quality` 0…9 (default 6), `compression` 0…9 (default 2),
  `scaling` `.scale` / `.resize` / `.none` (the form's "scale", "resize",
  "none"), `clipboard` (default true).
- `connect(host:port:password:)` — the password is used for that handshake
  only and never kept. Without one, `onPasswordNeeded(session) async ->
  String?` is asked (default: `Modal.prompt` "VNC password" / "<host> is asking
  for a password" / Connect); nil closes.
- `state`: `.idle, .connecting, .authenticating, .connected, .failed(msg)`
  ("Could not connect"), `.ended(msg)` ("Session ended" — "the server closed
  the session"), `.closed`. Messages: "the connection was refused — nothing is
  listening on port N", "the connection timed out", "no route to host", "could
  not resolve h", "this is not a VNC server (it said …)", the server's own
  security-failure reason / "Authentication failure", unsupported security
  types (with the macOS Screen Sharing hint), "the connection dropped".
- `desktopName`, `width`, `height`, `cursor`, `supportsRemoteResize`,
  `target` ("host:port"), `viewOnly`, `scaling` (settable).
- `sendCtrlAltDel()`, `sendCtrlEsc()`, `sendKey(keysym, down:)`,
  `sendPointer(x:y:mask:)`, `paste(text)`, `pasteLocalClipboard() -> Bool`,
  `requestRemoteSize(width:height:)`, `disconnect()`, `VNCSession.closeAll()`.
- Callbacks: `onClipboard` (default: local clipboard unless
  `options.clipboard == false`), `onState`, `onBell`, `onNotice` (refused
  remote resize).

`VNCFramebufferView(session:)` (`NSView`; SwiftUI: `VNCView(session:)`) draws
the screen in the three modes, forwards keys (macOS key codes → X keysyms,
modifiers by side, Caps Lock as a tap), mouse buttons, drags and the wheel
(buttons 4–7; in 1:1 mode the wheel scrolls the view when the screen is
larger — Option sends it to the remote), shows the server's cursor (a dot when
it is invisible), releases held keys on focus loss, sends nothing in view-only
mode, and asks the server to match the pane (debounced 0.5 s) in `.resize`.
`focus()`, `applyScaling()` after changing `session.scaling`. The pane's own
context menu (Ctrl+Alt+Del, paste) is the consoles owner's to attach; while
connected, right-click goes to the remote.

The RFB client (`RFBClient`, protocol thread): RFB 3.3/3.7/3.8 (003.889 and
4.x answered as 3.8), security None and VNC Authentication (DES via
CommonCrypto, bit-reversed key), 32bpp true-colour pixel format, encodings
CopyRect, Tight (fill, JPEG via ImageIO, copy/palette/gradient filters, four
persistent zlib streams with resets), ZRLE (one persistent stream; raw, solid,
packed palette, RLE, palette RLE), Hextile, RRE, Raw; pseudo-encodings
quality, compression, DesktopSize, LastRect, ExtendedDesktopSize
(SetDesktopSize), Cursor. ServerCutText/ClientCutText (Latin-1), Bell,
SetColourMapEntries/Fence skipped safely. Client messages go out on a serial
background queue (pointer motion is dropped while over 1 MB is waiting); the
desktop name (1 MB) and ServerCutText (16 MB) lengths are capped and fail
cleanly.

## Not done / differences

- Linux/Windows branches (FreeRDP args, `mstsc`, the dialout hint) are
  macOS-only by design.
- The original never resumed a pane that tmux flow control paused (tmux waits
  for `refresh-client -A '%N:continue'`); `continuePane` exists for the window
  to call — behaviour otherwise unchanged.
- `%session-renamed $id name` updates `sessionName` with the name only, so
  End and the ended-vs-detached check keep working after a rename. Local tmux
  commands get `LANG=en_US.UTF-8` when no locale is set (main.js). Over a
  connection the probe and session list use 15 s, has-session 10 s.
- `.rdp` files open in whatever app the user chose for them; Microsoft's
  clients by bundle id only when nothing claims the type.
- tmux 3.6+ prints the tabs in `-F` output as `_` (control mode too), which
  broke the original's `list-sessions` / `list-windows` parsing on current
  tmux; lines are now matched from both ends (`TmuxControl.fields`).
- `vncbridge.js` has no equivalent: the client speaks TCP directly. TightPNG
  and the 8-bit low-bandwidth pixel modes noVNC offered are not implemented
  (never requested).
