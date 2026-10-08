# ServerLife (native Swift)

A native macOS port of **ServerLife**, the Teleport and SSH desktop client:
tabbed terminals, a real SFTP file browser, fleet-wide command execution,
port forwarding and session replay — with Teleport nodes, beams and plain SSH
hosts treated as the same thing.

The original is an Electron app. This is the same app, feature for feature,
written in Swift with SwiftUI and AppKit: no Node, no Chromium, one ~30 MB
app bundle. It reads and writes the same `sessions.json` format, so profiles,
folders, macros and settings carry over.

macOS 14 or later.

---

## Contents

- [Build and run](#build-and-run)
- [What it does](#what-it-does)
- [How it works](#how-it-works)
- [Automation and MCP](#automation-and-mcp)
- [Where things are kept](#where-things-are-kept)
- [Differences from the Electron app](#differences-from-the-electron-app)
- [Development](#development)
- [Project layout](#project-layout)

The full user guide — every panel, menu and shortcut — is in
[Resources/GUIDE.md](Resources/GUIDE.md), and inside the app under
**Help → Guide** (`⌘/`).

---

## Build and run

### What you need

| | |
|---|---|
| **Xcode Command Line Tools** | `xcode-select --install`. Full Xcode is not needed. |
| **Swift 6** | Comes with the Command Line Tools. |
| **Network access on first build** | SwiftPM fetches [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). |

Found at runtime, not build time:

- **OpenSSH** (`ssh`, `ssh-keygen`) — part of macOS.
- **`tsh`** — only if you use Teleport. Looked for in `/usr/local/bin`,
  Homebrew and Teleport Connect; anywhere else, set it in
  **Settings → Locate tsh / ssh…**.
- **XQuartz** — only for X11 forwarding.

### Build

```sh
Scripts/bundle.sh          # release build → build/ServerLife.app
open build/ServerLife.app
```

`bundle.sh` builds with SwiftPM, assembles and ad-hoc signs the `.app`,
generates the icon, and bumps `BUILD_NUMBER`. `VERSION` holds the marketing
version (kept in step with the Electron app it ports).

To install, copy `build/ServerLife.app` to `/Applications`. The build is
ad-hoc signed, not notarised: fine on the machine that built it; copied to
another Mac it needs *Privacy & Security → Open Anyway* (or
`xattr -dr com.apple.quarantine ServerLife.app`).

For a quick debug build without bundling:

```sh
swift build && .build/debug/ServerLife
```

---

## What it does

The short version — [Resources/GUIDE.md](Resources/GUIDE.md) has all of it.

- **Every host in one list.** Teleport nodes from every logged-in profile
  with their labels, `~/.ssh/config` hosts (and extra config files), leaf
  clusters, and beams under the cluster they run on. Star, colour, give an
  icon, pin the login, hide.
- **One authentication per host.** A session opens one SSH ControlMaster;
  terminals, the file browser, transfers, tunnels and remote commands all
  ride it. One MFA tap, not one per panel.
- **Tabs, splits and broadcast typing.** Drag panes between tabs and windows
  without reconnecting. Local shells, including blank-config shells.
- **A real SFTP browser** — an SFTP v3 client, not a wrapper. Two panes,
  drag between servers, permissions and owners, compare, synchronise with
  every action shown first, rsync over the existing connection, keep a
  folder uploading as you save, edit in your own editor, recursive search.
- **A transfer queue** with pause/resume, retry-from-where-it-stopped,
  reordering and a speed limit.
- **Fleet operations** — multi-exec across ticked hosts or a tag query, recent
  runs, YAML save/load, Ansible export.
- **Macros** with variables, scopes and pinned header buttons; **snippets**.
- **Keyword highlighting** in the terminal, global or per host.
- **Teleport** — several profiles at once, access requests (with a
  requestable-resource monitor), recordings with playback and transcript
  search, live sessions, `tsh config` into `~/.ssh/config`, latency.
- **Folders in the host list** — by hand or by a tag rule
  (`env=prod and (role:web or role:api)`), nested, exportable.
- **Quiet and disappearing hosts** — heartbeat ages, and watched hosts that
  stay listed when they vanish from the inventory.
- **Network tools** — ping, traceroute, DNS, ports, TLS, HTTP, whois,
  `/webapi/ping`, and a full curl builder — several of them runnable *on a
  chosen host*.
- **tmux** — sessions that outlive the window, spoken over tmux's control
  protocol; tmux windows are tabs, tmux panes are panes.
- **Consoles and screens** — serial, telnet, VNC drawn in the pane (a native
  RFB client), and RDP handed to the Mac's own client.
- **S3** — buckets as a file source in every explorer, with SigV4 signing
  done directly.
- **A 3D city** view of a directory (SceneKit).
- **Themes** — dark, light, automatic, 37 named themes, skins, terminal
  palettes, and **macOS (system colours)**, which uses the native
  light/dark appearance and your system accent colour.

### Keyboard shortcuts worth knowing

`⌘N` new session · `⌘⌥C` quick connect · `⌘T` local shell · `⌘E` file
browser · `⌘⇧M` multi-exec · `⌘J` the dock · `⌘F` find · `⌘/` the guide ·
`⌘,` settings. The full table is in the guide.

---

## How it works

```
                    ┌──────────── one authentication ────────────┐
                    │                                            │
  ServerLife ──► ssh ControlMaster ──► (tsh proxy ssh) ──► server
                    │
                    ├── ssh -tt            → terminal tab
                    ├── ssh -tt            → split pane
                    ├── ssh -s sftp        → file browser (SFTP v3)
                    ├── ssh -O forward     → port forwards
                    └── ssh -T <command>   → multi-exec, server probe
```

For Teleport hosts the app generates an `ssh_config` with `tsh config`
whose `ProxyCommand` routes through `tsh proxy ssh`; from there both kinds
of host are identical. Nodes needing per-session MFA, leaf clusters and
beams go through `tsh ssh` / `tsh beams` instead, and the file browser runs
the host's `sftp-server` over that channel.

No credentials are stored. Authentication is always `ssh`'s and `tsh`'s.

---

## Automation and MCP

Off until you turn it on: **Settings → Local automation (MCP)**. It opens a
Unix socket in your runtime directory (mode `0600`), and every connection
must present a token only you can read.

The MCP server is the app's own binary — no Node:

```sh
claude mcp add serverlife -- "/Applications/ServerLife.app/Contents/MacOS/ServerLife" --mcp
```

Settings has a button that copies that line. The 21 tools (open sessions,
list hosts, layouts, clusters, macros, beams, sync preview/apply …) are the
same as the Electron app's. There is no verb that runs an arbitrary command.
Details: [Resources/MCP.md](Resources/MCP.md).

---

## Where things are kept

| What | Where |
|---|---|
| Settings, profiles, folders, macros, history | `~/Library/Application Support/ServerLife-Swift/sessions.json` |
| ControlMaster sockets | `$TMPDIR/sl-<uid>/` |
| Control socket and token (when enabled) | in the settings directory |

Separate from the Electron app (`…/Application Support/ServerLife`), so the
two can run side by side. On first launch, if this app has no data yet and
the Electron app's `sessions.json` exists, it is imported once.

Saves are atomic, and a file that cannot be read is moved aside as
`sessions.json.corrupt-<ms>` rather than overwritten.

---

## Differences from the Electron app

Deliberate, and listed in full in each area's `README.md` under
`Sources/ServerLife/`. The main ones:

- **macOS only.** The Windows and Linux branches were not ported.
- **VNC is a native RFB client** (Raw, CopyRect, RRE, Hextile, ZRLE, Tight,
  cursor and desktop-size pseudo-encodings) instead of noVNC over a
  websocket bridge.
- **The 3D city uses SceneKit** instead of three.js; lighting is tuned by eye.
- **Terminal search highlights the current match only** — SwiftTerm 1.11 has
  no API for marking every match.
- **A few original bugs are fixed** rather than copied: tmux 3.6+ window and
  session lists, paused tmux panes never resuming, sync creating nested new
  folders in the wrong order, multi-exec ignoring the tsh transport, and
  Return confirming destructive dialogs.

---

## Development

The toolchain notes and conventions are in [CLAUDE.md](CLAUDE.md). The
essentials:

- **Command Line Tools only.** SwiftUI's `@State` does not compile without
  Xcode's macro plugins, so per-view state uses `@StateObject` with the
  `Local<T>` / `LocalFlag` helpers in `App/LocalState.swift`.
- **SwiftTerm is pinned to 1.11.2**; later versions need Xcode's `metal`
  compiler.
- **Child processes** go through `Core/Proc.swift` and
  `Core/SpawnProcess.swift` (`posix_spawn`, so arguments keep their exact
  Unicode bytes), never `FileHandle.bytes`.

### Tests

```sh
Scripts/test.sh                      # the whole suite (Swift Testing)
Scripts/test.sh --filter Sidebar     # one area
```

Tests never touch your real settings: under the test runner the store uses
a throwaway directory.

There is also an opt-in suite that drives a **real host** — connections,
terminals, SFTP, transfers, sync, rsync, forwards, multi-exec, network tools.
It only writes inside `~/serverlife-swift-test` on that host and removes it
afterwards:

```sh
SL_LIVE_HOST=myhost Scripts/test.sh --filter Live --no-parallel
```

### Looking at the UI without screen recording

```sh
.build/debug/ServerLife --snapshot /tmp/x.png --data-dir /tmp/sl-dev \
    [--open-host alias] [--actions new-local,toggle-transfers] [--delay 3] [--size 1400x900]
```

opens the app against a throwaway data directory, performs the listed
action ids, renders every window (and open sheet or panel) to PNGs, and
quits. The window comes to the front while it runs.

---

## Project layout

```
Sources/ServerLife/
  Core/          JSON, Store (sessions.json), Proc/SpawnProcess, PTY, Host, Tools (ssh/tsh lookup)
  App/           app delegate, menu bar, action registry, windows, dialogs, theme, shared components
  Data/          the store's record methods (profiles, history, macros …) and backup
  Connections/   ControlMaster connections, terminals, exec, forwards, local shells
  Teleport/      Service/ (tsh, inventory, beams, ssh_config) and UI/ (panels, requests, recordings)
  Files/         Service/ (SFTP, transfers, sync, watches, rsync) and Explorer/ (the file browser)
  Sessions/      tabs, panes, terminal view, activity, highlighting, layouts
  Sidebar/       the host list, tag queries, folder model, host menu
  Hosts/         folders UI, hosts pane, profiles, quick connect, add server
  Fleet/         dock, multi-exec, macros, snippets, YAML and Ansible
  NetTools/      network tools and SSH keys
  Devices/       Service/ (serial, telnet, tmux, VNC, RDP) and UI/
  City/          the 3D view
  Misc/          settings, themes, guide, tour, version history, backup UI
  Automation/    control socket, MCP bridge, S3 and AWS credentials
Sources/CShim/   zlib, pty, termios and socket headers for Swift
Resources/       GUIDE.md, CHANGELOG.md, MCP.md, app icon
Scripts/         bundle.sh, test.sh, agent.sh
Tests/           Swift Testing suites, one directory per area
```

Each directory under `Sources/ServerLife/` has a `README.md` describing its
API and anything it does differently from the original.
