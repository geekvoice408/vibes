# Changelog

All notable changes to ServerLife are recorded here.
This project follows [Semantic Versioning](https://semver.org/).

Releases up to 0.1.15 were published from `stevenGravy/serverlife`, which is
where the links at the foot of this file point. From 0.1.16 the project lives in
`gravitational/saleseng` under `tools/serverlife`, and releases are tagged
`serverlife-v<version>`.

---

## [0.15.2] — 2026-10-07

Recent runs that tell the truth, multi-exec that follows the ticks, and an
Ansible export that runs on today's Ansible and yesterday's servers.

### Added

- **Recent runs show their hosts**, as a row of names under each command,
  every one of them in the tooltip.
- **Name the Ansible export.** The folder's name is asked for before where it
  goes — `ansible-df` for a `df` — and an existing folder is not replaced
  without asking; every export used to be `serverlife-ansible`, so the
  second quietly overwrote the first.
- **A shell in the export, on the way out.** After exporting, the offer of a
  local shell already in that folder, with `./run.sh` to type.

### Fixed

- **Recent runs marked every run as failed.** A run was written to the
  history the moment it started, with every host still pending, so a run that
  succeeded everywhere was remembered as 0 of N. It is now written when the
  run finishes, from the results. Runs recorded before this keep the counts
  they were given.
- Ticking hosts while multi-exec was open left its *Targets* line saying "No
  hosts selected" — nothing there heard the tick. It now follows the ticks as
  they change, from the checkboxes and from *Select for multi-exec* alike.
- *Edit* on a recent run put back only the command, so the run went wherever
  the ticks happened to be. It now re-selects that run's hosts (or its tag
  query) and its login, without running.
- With nothing ticked, the targets line now says the run will use the open
  sessions, and no longer names a login twice ("ent (ubuntu) (ubuntu)").
- The Ansible export would not start on current Ansible:
  `stdout_callback = yaml` named a plugin community.general removed in 12.0.
  It now uses the built-in callback's YAML output, and a test loads a real
  export in `ansible-playbook` wherever Ansible is installed.
- The export failed on hosts with an older Python — Amazon Linux 2's 3.7 —
  reporting "rc=1, command failed" for a command that never ran. It now runs
  the command with `raw`, straight over SSH as multi-exec does, needing
  nothing on the host; without a tty, so login banners stay out of the
  output; and a failure names its cause.

---

## [0.15.1] — 2026-10-07

Text sizes that stay where you put them, switching clusters that switches,
and a tmux session that looks ended when it has. This release also carries
everything in 0.15.0, whose own release has been withdrawn.

### Added

- **A text size for the host list.** Settings → *Host list text size*, apart
  from the terminal's. The whole list grows together — names, tags, headings,
  buttons — and keeps the width it was dragged to.
- **⌘+ and ⌘− act on where you are** (Ctrl on Windows and Linux): in a pane
  they size that pane's text and no other, and ⌘0 puts it back to the
  setting; in the host list they size the host list and the size is kept. The
  View menu has them as *Bigger Text*, *Smaller Text* and *Default Text
  Size*, and the + key and the keypad's + and − work as well as ⌘=.
- **Copies from remote programs reach the clipboard.** tmux with the mouse on,
  vim and coding agents copy with OSC 52; that is now handed to the system
  clipboard, capped so a runaway program cannot flood it.

- **A question before closing what is live.** Closing a tab or pane — its
  ×, Close tab, Close other tabs, ⌘W — that would end a shell on a host, a
  port forward, a console or a screen now says which and asks, once for all
  of them, with *Do not ask again* and a switch in Settings. Local shells and
  tmux tabs, which only detach, close without asking.

### Fixed

- **Make this the active profile** did nothing with two clusters logged in.
  `tsh login` against a certificate that is still valid prints the profile as
  active but, in tsh 18, does not record it, so plain `tsh` stayed on the old
  cluster. The switch is now recorded where tsh keeps it.
- Ending a tmux session left its panes looking alive, and a session that
  ended on the server said it was "still running, reattach". The host is now
  asked: an ended session's panes are dimmed and marked *ended* on the pane
  and the tab, with its tmux menu gone; a detached one says *detached* and
  offers Reattach; a lost connection says it cannot tell.
- ⌘= did nothing — the menu was bound to ⌘+, which is Shift+= on most
  keyboards.
- Saving Settings reset every pane's text size, even when the size was not
  what changed; and with a VNC screen open it could fail outright.

---

## [0.15.0] — 2026-10-07

tmux you can drive from the pane, tmux on this machine, who is in what on a
cluster right now, and a file browser that comes back by itself.

### Added

- **A tmux menu on every tmux pane.** One labelled *tmux* button on the
  pane's title bar, for the session itself: split right or down, a layout by
  name (side by side, stacked, one big on top, one big on the left, tiled) or
  the next in turn, swap with the next pane, move this pane to its own window,
  type in all panes at once, a new window, and close this pane or this window
  — the last two ask first, since they end what runs there. Each is the tmux
  command, so the change is in the session for whoever attaches next. Items
  that need two panes say so in a window that has one. ⌘⇧D and ⌘⇧E on a tmux
  pane now split inside tmux too.
- **tmux on this machine.** *Open in tmux…* on the Local shell's menu and on a
  local pane's menu attaches to, or starts, a tmux session on this laptop,
  with everything a server's has. Not offered on Windows, which has no native
  tmux.
- **Active sessions.** *Active sessions…* on a cluster's menu, *on this host*
  on a Teleport host's and *in this beam* on a beam's: who is in what right
  now, as what login, running what, for how long. SSH and Kubernetes sessions
  can be watched, joined as a peer or moderated, in a local tab running
  `tsh join` or `tsh kube join`; which modes you may use is the cluster's
  decision, and tsh says so in the tab. Database, app and desktop sessions are
  listed but not joinable from a terminal.

### Changed

- A new tmux pane opens without a file browser while another pane of the
  same session already shows one — every pane is on the same host, and a
  split is asked for to get more terminal. Any pane can still open its own.

### Fixed

- A tmux pane's file browser said "Session is error" for as long as tmux kept
  running when the connection was wrongly marked down — one slow check after
  a wake from sleep was enough, and nothing ever reconnected it, because the
  tmux terminal never exits. The check now asks twice before believing it, a
  tmux pane's browser takes its channel back by itself, and any file browser
  that loses its connection or its listing has *Reconnect files* or *Try
  again* in place.
- A new tmux window opened as a blank tab with no terminal and no tmux menu:
  the tab was built from tmux's first notice of the window, before its panes
  were known, and the layout that followed was skipped.
- tmux on this machine found no sessions and showed no panes when ServerLife
  was opened from the Dock or Finder. An app started that way has no locale,
  and tmux without a UTF-8 one rewrites tabs and non-ASCII text as `_`. The
  app now gives what it starts a UTF-8 locale when it was given none, which
  also reaches local shells and the LANG ssh passes to servers.
- The version history in the About box stopped at 0.1.16. It is now read from
  this changelog, so it lists every release.

---

## [0.14.1] — 2026-10-05

Beams beside the pane you are in, and the fast way to move a big folder.

### Added

- **Beams split right and down.** A beam's menu offers *Open beside current
  (split right)* and *Open below current (split down)*, as any host's does,
  and beams are listed under their own names in *Split right / down —
  another host…*.
- **A big folder to or from a beam: one archive.** A beam is reached through
  the proxy, so a tree of many small files spends its time on round trips. A
  folder transfer with a beam now says so and gives the commands: `tar czf`
  on the source, move the one `.tar.gz`, `tar xzf` on the destination. The
  *Copy files (scp)* dialog shows the same, filled in with its own paths,
  when *Recursive* is ticked.

### Fixed

- Splitting a pane into a beam, or into an SSH host reached through a
  ProxyJump, sent the wrong connection details: the beam as an SSH alias that
  did not exist, the host without its jump.
- The beam that is also a Teleport node (`beam-<uuid>`) no longer appears a
  second time in the split host picker.
- Release builds: each Linux runner now builds only its own architecture. Both
  were building both, raced to upload the same files — which failed the
  0.14.0 Linux jobs — and an arm64 package could carry the x64 terminal
  module.

---

## [0.14.0] — 2026-10-05

Thirty-seven themes for the whole window, tmux on a beam, and the 3D view
when you want it.

### Added

- **Named themes.** Settings → Theme now lists twenty-four dark and thirteen
  light themes beside Dark, Light and Automatic — Nord, Dracula, Solarized,
  Gruvbox, Tokyo Night, the Catppuccins, One Dark, Rosé Pine, Everforest,
  Kanagawa, a true-black Midnight, a high-contrast pair, a sepia Paper and
  more. One choice repaints the window and, unless another terminal palette
  is picked, the terminal too. An accent colour chosen on top of a theme
  still applies; leaving it on Default keeps the theme's own.
- **tmux on a beam.** A beam's menu offers **Open in tmux…**, and a beam
  follows *Open every new session in tmux* like any other host — the VM is
  where an agent's long run should survive a closed lid. `tsh beams exec`
  gives the far side no terminal, so tmux runs there in plain control mode
  (`tmux -C`) over pipes: no echo, no line cut off at a kilobyte, and no
  stray ^C or ^D turned into a signal.
- **The 3D button can be hidden.** Settings → *3D view button in the file
  browser*; turning it off also closes any town that is open.

### Changed

- Tags, request states and the primary button take their colours from the
  theme instead of fixed dark-theme shades, so they read on every theme.
- The project is linted with the rules Teleport uses for its own web code
  (oxlint, `make lint`). `make release` and the release workflow stop on an
  error before anything is tagged or built.

### Fixed

- The strip of terminal behind the scrollbar, and the corner where two
  scrollbars meet, were painted in the default colour rather than the
  terminal's background.

---

## [0.13.0] — 2026-10-03

The file explorer as a town you can fly over, a question before quitting with
sessions open, and telnet and serial wherever an address can be typed.

### Added

- **The file explorer in 3D.** A 3D button on every explorer turns the folder
  on screen into a town: each folder a building as tall as the data under it,
  as wide as its file count, and painted in bands by what those bytes are —
  code, config, documents, images, archives, logs, keys. Loose files are
  crates on the plaza. Double-click a building to walk in, where the files are
  crates on the floor and the subfolders are doors. Drag to look, WASD to
  move, G for walking or flying. It is a view of the explorer, not a second
  file manager: selection, the name filter, search and the right-click menu
  are all the explorer's own. On a server the folders are measured with one
  command over the open connection, and a per-session-MFA host waits for a
  click before spending an approval.
- **Architecture.** The town can be built in ten styles: today's mix;
  pagodas, domes and minarets, Mediterranean terracotta and canal-house
  gables from around the world; Greece and Rome, castles, Victorian
  mansards, 1930s Art Deco and the year 2200 through time. A style changes
  the shapes and roofs, never the facts — height, footprint and colours mean
  the same in all of them — and each has four or five kinds of building, so a
  street is a mix and a folder keeps its building between visits.
- **Processes as traffic**, off until you turn it on. The busiest forty
  processes on the machine drive around town: cars for the ones that are
  mostly CPU, faster the more they use; boats on a river for the ones that are
  mostly memory, bigger the more they hold; rockets taking off from launch
  pads for the three biggest. Hover for the name, pid, CPU and memory. Works
  on macOS, Linux and Windows locally, and on a server over the connection; a
  machine with no `ps` says so and the view stays a file browser.
- And company: birds that scatter when you fly into them, planes towing a
  banner about the folder you are in, a superhero who crosses town now and
  then, and a police chase through the streets.
- **A question before quitting with sessions open.** Quitting with anything
  other than a local shell live — SSH, Teleport, tmux, telnet, serial, VNC —
  says how many and which, and asks, Cancel the default. Asked once, across
  every window; a window that does not answer cannot hold the quit hostage.
  It can be turned off in Settings.
- **Telnet and serial in Network tools.** Telnet connects, listens, and says
  what the port said — open, refused, silent — naming the service when its
  first line gives it away, with a button to open it as a session; from a
  host it runs that host's own telnet, for the switch only a bastion can
  reach. Serial lists this machine's ports with speed and framing, and opens
  or saves a console on one.
- **Quick connect speaks the other protocols.** `telnet://switch-1`,
  `vnc://10.0.0.5:5901`, `rdp://win-1` and `/dev/ttyUSB0@9600`, as schemes or
  as a first word, each with its own default port. It still opens on the last
  ssh address, whatever was used most recently.
- **tmux through the MCP server.** `open_session` takes `tmux` and
  `tmuxSession`, and follows the host's own setting when the flag is not
  given.

### Fixed

- A telnet session said nothing until the far end did, which looked like a
  failure. It now prints what telnet has always printed — *Trying…*,
  *Connected to…*, *Escape character is '^]'* — and `^]` does what that line
  promises. Output that arrived before the pane was bound to the session (a
  greeting, a one-line server that hangs up) was being dropped; it is queued
  now.
- Assuming a request for particular resources emptied the cluster: the
  certificate is narrowed to just those, the node poll took that as the
  inventory, and every watched host was declared gone. A narrowed read now
  concludes nothing about what it cannot see, the rest of the cluster stays
  drawn, dimmed and tagged held, with a button to drop the request.
- tmux is no longer offered on a host that asks for MFA per session, where it
  could only fail; the menu says why.
- Requestable nodes can be dragged into folders, in the sidebar and in the
  Hosts pane. The drop looked the host up among the ones you hold, found
  nothing, and quietly filed nothing.
- Copy was greyed out when right-clicking a selection inside tmux, vim or
  anything else using the mouse: the click went to the program, which cleared
  the selection before the menu opened.

---

## [0.12.0] — 2026-10-02

Sessions that outlive the window, four more kinds of thing to connect to, and
a link that asks before it opens.

### Added

- **tmux, as tabs and panes.** A host's menu offers **Open in tmux…**, and
  that one choice changes what a session is: the work stops belonging to the
  connection. Close the lid, lose the network, quit the app by accident — what
  was running on the server is still running, with its scrollback, waiting.
  A tmux window is a tab and a tmux pane is a pane, so splitting, dragging a
  pane to another tab, search, highlighting and the file browser all work as
  they always did; the file browser reads the *server* and follows the shell.
  Splitting here asks tmux to split, so another client on the same session
  sees it too. Only the far side needs tmux — nothing is installed on this
  machine, because the control protocol is spoken here, over the connection
  that is already open: the same authentication and the same single MFA tap.
  A host without tmux says so and names the command that fixes it.
- **tmux as the default, where you want it.** Per host, per cluster or
  everywhere — the same three levels as agent forwarding — after which *Open
  session* means tmux and the menu offers *Open without tmux* for the once it
  does not. Sessions can be named as they are started and renamed afterwards,
  along with the window, which stops tmux renaming the tab after whatever is
  running in it.
- **Serial consoles and telnet.** The machines that answer only on a console
  cable or on port 23 — switches, routers, PDUs, BMCs, terminal servers — are
  the ones you reach for when SSH is what has stopped working. Saved beside
  everything else and opened the same way, with the settings that decide
  whether a console is usable at all: what Return sends (CR, LF or CRLF),
  local echo for a device that echoes nothing, a serial break for interrupting
  a boot loader, and 115200 8N1 by default. Ports plugged in right now are
  openable straight from the **+** picker with nothing to fill in.
- **VNC screens**, drawn in the pane. Scale to fit, ask the server to resize,
  or full size; quality; view-only. Ctrl+Alt+Del and paste-into-session on the
  pane's menu. The password is asked for when you connect and is never stored.
- **Remote Desktop**, opened in this machine's own client with the settings
  from the saved connection — user, domain, size or full screen, clipboard,
  drive redirect, gateway. RDP is a bundle of virtual channels rather than a
  screen protocol, and half an implementation of it would be worse than the
  client the platform already has; what is worth keeping is the settings.
- **Links in a terminal ask before they open.** The text in a pane is written
  by whatever is on the other end of the connection, so a mis-aimed click on a
  scrolling log could hand an address nobody read to the browser. The question
  shows the whole address and names the host above it, and can be turned off
  for good from inside itself or in Settings. Right-click a link for **Open
  link** and **Copy link** — copying works on a URL that wrapped over several
  rows, which is the one a mouse cannot select.

### Changed

- A host's right-click menu is shorter. Three ways to open plus the two
  splits, with the occasional ones — another account, files without a
  terminal — behind one entry; the star, the colour and the icon under
  **Mark this host**; and the quiet-node filter as one line that says where it
  stands. The splits are hidden when nothing is open, since "beside the
  current pane" with no current pane opened a plain tab and read as a bug.

### Fixed

- tmux attached on the second try and not the first. Control mode opens with
  an empty block that is nobody's reply; matched to the first command, every
  answer after it was the previous one's, the window list came back empty and
  no panes were built. The guard line says which blocks are replies, and that
  is now read.
- A tmux tab lost any pane tmux did not know about — another server split in
  beside it vanished the moment the size changed, after its connection had
  already been dialled. tmux owns the shape of its own window, not the tab.
- Attaching showed nothing until it finished, which on a node behind a proxy
  is twenty seconds of a click appearing to do nothing. The tab opens first
  and the waiting happens inside it, with the connect log, a line per step and
  Cancel.

---

## [0.11.0] — 2026-10-01

Access requests you can finish, hosts that say what they really are, and
panes that go where you put them.

### Added

- **Requestable resources, in the lists you already use.** The hosts pane
  has a **Requestable** toggle and a cluster heading offers *Show
  requestable nodes too* — both off by default, both remembered. What the
  cluster would let you ask for arrives tagged **req**; double-click one to
  start a request with it already chosen. They are host-shaped like
  everything else, so the filter, the folder rules and dragging into a
  folder all work on them: one arrangement of a cluster whether or not you
  hold the access today.
- **A request dialog that knows what the cluster wants.** Before you type,
  it puts the request to the cluster in a form that cannot succeed — it
  carries a role no cluster can have, so nothing is created — and reads the
  refusal: whether a reason is required, and the cluster's **own wording**
  for why, since a role may set `request_prompt` and *"Include a ticket or
  case reference"* beats anything we would write. A refusal for want of a
  reason is remembered against that cluster, so the next request marks the
  field before anything is sent. The dialog now submits from inside itself,
  so a refusal lands where it can be answered instead of over an empty
  screen.
- **The roles a request will carry, shown and chosen.** Teleport will not
  enumerate the roles a *resource* request resolves through — no dry run on
  `tsh request create`, no roles in the resource search, and
  `--roles` lists role requests rather than `search_as_roles` — but your own
  history does: a past request carries its resource ids and its roles, so
  the dialog ticks what these resources were granted through before. The
  **+ role** picker lists everything else — what the cluster says is
  requestable (with its descriptions), what you hold today, what you have
  used — each labelled with where it came from, and *Another name…* for the
  rest. A role typed from memory is a request that fails on a typo.
- **Panes go where you put them.** Drag a pane by its header: onto another
  pane to swap them, onto a tab to move it there, past the last tab for a
  tab of its own, out of the window for a **window** of its own. Nothing
  restarts — the connection and the shell live in the app's core, so the
  session, its scrollback and whatever is running come along, and a pane
  handed to a new window keeps the text that was on screen.
- **Drag within one file pane to move.** Dropping a file or folder on a
  folder row in the same list moves it — a rename underneath, so nothing is
  copied however large the folder, on your machine or on a server. It will
  not put a folder inside itself, and a name already taken stops the move
  rather than overwriting it.

### Fixed

- **A host you can no longer reach is not a host that has gone.** `tsh ls`
  is what you can reach and `tsh request search` is what you could ask to
  reach; a node moves between them when an approved request expires or a
  role changes, and to a watch reading only the first list that is
  indistinguishable from the machine being decommissioned. Watched hosts
  missing from the inventory are now looked for in the other list before
  anything is concluded, and read **req** rather than *gone* when they are
  there. A search that fails changes nothing.
- **`tsh request search --roles` was being read wrong**, so clusters that
  offer requestable roles looked like clusters that offer none: the answer
  spells them `{ "Role", "Description" }` where the resource search says
  `Name`.
- **An empty node list can no longer trap a wrong verdict.** On a cluster
  you have lost all access to, `tsh ls` answers with nothing — and the guard
  against concluding anything from that also stopped a host wrongly marked
  gone from ever being corrected.

---

## [0.10.1] — 2026-09-30

### Fixed

- **Two nodes with one hostname now work.** Teleport marks them, and the app
  knew what to do with that — dial the UUID, which is the only name meaning
  exactly one machine — but the flag never arrived: the renderer builds the
  payload for a new connection field by field, and `ambiguous` was not one
  of the fields, in any of the four places that build it. So every duplicate
  was dialled by a name that means two machines, which tsh refuses.
- **And they keep their shared connection.** A duplicate used to be forced
  onto `tsh ssh`, on the reasoning that the generated ssh_config addresses
  hosts as `hostname.cluster`. It does — and its Host pattern is
  `*.cluster`, so `uuid.cluster` matches and `tsh proxy ssh` resolves the
  UUID on the far side. Forcing tsh also broke the **file browser** on such
  nodes: `tsh ssh` has no subsystem flag, so the file channel must exec the
  host's own `sftp-server`, and a container node without that binary answers
  every listing with *sftp-server not found on this host (127)*. Over the
  shared connection the channel asks for the `sftp` subsystem, which the
  Teleport agent serves itself. There is no MFA prompt on these panes
  either — there was never an approval to spend. One that *also* wants MFA
  is unaffected: it is offered tsh as any MFA host is, and still dialled by
  id.
- **You can tell them apart.** A duplicate row carries **📋** and a tooltip
  naming the cluster and the id it is dialled by, in the host list and the
  hosts pane. Two agents on one box report one hostname, so the first block
  of the node id follows the tab title too: `ubuntu@1c2bcfe4e897 · 221fa4c5`.

---

## [0.10.0] — 2026-09-29

### Added

- **rsync, from the file browser's right-click menu.** The browser's own
  synchronise walks both folders over SFTP and moves whole files, which is
  right for a handful and wrong for a tree; rsync compares by rolling
  checksum and sends only the blocks that changed. It **rides the connection
  you already have** — rsync runs itself on the far side over a shell of the
  app's choosing, so it reuses the session's ControlMaster, with no second
  authentication and no second Teleport session. The dialog **opens on a dry
  run** and the real copy is a separate press with the plan on screen; the
  **exact command is shown**, selectable and copyable, and is what runs.
  Source and destination are prefilled from the two panes, **⇅ Swap
  direction** turns it round, and **☆** beside either path offers that side's
  **starred folders** — the pane's own list, so a host's defaults like
  `/var/log` are there before anything has been starred. Archive, compress,
  delete, checksum, excludes and extra flags are all yours; *Copy the
  contents of the source folder, not the folder itself* is the trailing-slash
  question asked in words. Output streams as it goes, **Stop** ends it, and
  closing the dialog stops the run. Where it cannot go it says so rather than
  failing halfway: a per-session-MFA node (every rsync would raise its own
  prompt), a beam, a bucket, two servers at once (rsync refuses two remote
  ends outright), and Windows.
- **Icons and colours for whole clusters.** Six clusters in a sidebar are six
  lines of near-identical grey text, and the one you must not fat-finger a
  command into looks exactly like the lab. Right-click a cluster heading in
  the host list, or its row in the Teleport tab, for the same emoji picker
  and the same eight colours a host or folder uses. The icon goes before the
  name, the colour tints the heading and draws the bar a coloured host row
  wears, and both marks appear in both lists.

### Fixed

- **One click on a tab, and you can type.** Clicking a tab moved the tab and
  left focus where it was, so the first keystroke went nowhere and every
  session needed two clicks. Worse, switching tabs always activated the
  *first* pane: coming back to a tab split three ways dropped you in the left
  one, so the next command went to the wrong server. A tab now remembers
  which pane you were last in, and the keyboard follows — on a deliberate
  switch only, never on an incidental redraw.
- **Reconnecting works after a session is forced out.** The guard against two
  connects racing was cleared only when an attempt *failed*, so after the
  first success it held a resolved promise for the life of the connection.
  Harmless while the connection was up; fatal once the master died, because
  every reconnect was handed that stale promise, resolved instantly and
  started nothing. A master that dies also leaves its control socket behind,
  and OpenSSH will not start a new one on a path that exists — so the socket
  is now tested before it is trusted: live, reused; dead, removed.
- **The expired-session block belongs to its cluster, and now looks it** —
  indented to match a host row, with the hairline rail a folder's contents
  get, rather than sitting flush against the panel edge like a notice about
  the app.
- **rsync is found wherever it is installed**, not only in a fixed list of
  directories: one under a version manager, in `~/bin` or in a Nix profile
  used to report "rsync was not found" while working perfectly in your shell.

---

## [0.9.2] — 2026-09-25

### Fixed

- **A verdict lasts only as long as it can be re-tested.** Reported from a
  real cluster: two watched hosts showed as *gone* once it was logged out,
  and they were not gone. The mark came from the empty-read bug fixed in
  0.9.1; what kept it on screen afterwards — and would have, for as long as
  the cluster stayed logged out — was that a verdict was drawn whatever the
  state of the cluster it came from. *Gone* is only ever reached by reading a
  list with other machines in it and finding this one absent, so the moment
  the cluster cannot be read that conclusion cannot be restated or withdrawn
  by anything the app does. A watched host whose cluster is not on screen now
  always reads **? unchecked**, and so does a monitored requestable resource
  whose cluster cannot be searched. Nothing is lost: the record keeps the
  finding and the tooltip reports it as a note — *it was absent from the last
  list that could be read (12:05)* — rather than as a claim. Log back in and
  the next successful read restates it, or clears it.

### Changed

- **The requestable-resource monitor's pane no longer opens itself.** Not
  even if it was open when you last quit — a floating window appearing over
  the app at launch is an interruption, and it has nothing urgent to say most
  mornings. *Settings → Open the requestable-resource monitor when the app
  starts* turns that on; it is off by default. The monitoring runs either
  way, and the count stays on the Teleport tab button and each cluster's
  heading.

---

## [0.9.1] — 2026-09-25

### Fixed

- **Missing means detected missing.** Nothing is ever declared gone because a
  cluster could not be reached — every path that can reach that conclusion
  already required a read that succeeded — but a read can succeed and still
  tell you nothing. A role that changed, a leaf that dropped out, a cluster
  mid-restart each return an **empty list, successfully**, and that was being
  read as "everything you were watching left at the same moment". The
  evidence for a host being gone is a list of the ones still there with it
  absent from them, and an empty list is not that list. Refusing outright
  would be wrong too — a lab really can be torn down to nothing — so the
  first empty answer now marks nothing and a second one, ten minutes or more
  later, is taken at its word; a proper list arriving in between clears the
  count. The same rule covers the requestable-resource monitor, where the
  pane distinguishes *could not search* from *the search came back empty*.
  Either way those rows read **? not checked**, never *gone*.

---

## [0.9.0] — 2026-09-25

Three things that report on what is happening while you are looking
somewhere else: tabs that say what their session is doing, a monitor for the
resources you expect to be able to request, and — running through both of
them, and through watching a host disappear — an honest answer for when
nobody could check.

### Added

- **The tabs say what each session is doing.** Beside the connection dot,
  three small bars ripple while output is arriving, so the tab running the
  build is findable without clicking through the strip. If a session stops at
  something that has to be answered — `[sudo] password for…`, a `[Y/n]`,
  *Press enter to continue*, an MFA code, or **a coding agent asking
  permission** — an amber **?** appears and the tab itself turns amber.
  Never on the tab you are looking at: the output is already in front of you.
  Nothing is asked of the shell for any of this. Whether output is arriving
  is read from the stream on its way to the terminal; whether something is
  being asked is read from the **screen**, because a full-screen program
  paints by moving the cursor about and the end of the stream is whichever
  line it redrew last, not the bottom of what you can see. A question counts
  only while the thing asking it is still on screen, so a prompt you have
  answered — or a log that happens to contain the words — leaves the tab
  alone. *Settings → Show what each tab is doing* turns it off.
- **Monitor requestable resources.** An access request tells you about access
  you asked for; this is the other direction — whether the thing you expect
  to be able to ask for is still on offer. `tsh request search` is not a
  stable list: a node is rebuilt under a new id, a role changes and a whole
  kind stops being offered, a resource is retired and stops appearing, and
  none of it announces itself. Pick resources from the same picker an access
  request uses and, every five minutes (1, 5, 15, 30 or hourly), the search
  runs again and each one is confirmed: **✓ requestable — confirmed 2m ago**,
  or **⊘ not requestable — missing 14m, last confirmed 3h ago**. It is a
  floating pane rather than a dialog, draggable and left open while you work,
  and the monitoring carries on whether or not it is. Open it from **Teleport
  → Monitor Requestable Resources…**, the button under the Teleport tab, or
  a right-click on a cluster heading in the host list, which goes straight to
  that cluster and carries the count.
- **A Local shell button on the new-session dialog**, next to *Quick
  connect…*. It was in the list under *This machine*, which meant scrolling
  past or typing over whatever the search box was showing; a search is the
  wrong shape for a thing there is only one of.

### Changed

- **A watch ends when you end it**, not when its cluster stops being listed.
  The record lives in your settings, so a gone host keeps its row through an
  expired certificate, a logged-out cluster or a removed profile — an expired
  cluster now draws its ghosts above the login prompt, and any whose cluster
  is not listed at all are gathered into a **Watched** group at the foot of
  the host list. *Hide quiet* no longer hides them either: a node that
  stopped checking in is noise you may want out of the way, but a host you
  marked in advance and that has since left is the answer to a question you
  asked. The tooltip now carries the hostname, node id, last address, cluster
  and labels, all as of the last sighting.
- **Both monitors now say when nobody could check.** *Gone* and *still
  requestable* are verdicts, and each is only ever reached through a read
  that worked. When the cluster cannot be read — logged out, certificate
  lapsed, proxy down, the laptop shut all weekend — neither is available, and
  what the app did before was nothing: watched hosts stopped being drawn, and
  monitored resources kept a green tick with an ageing timestamp. A list with
  no marks on it reads as *all present* when it means *nobody has looked
  since Friday*. Watched hosts now carry an amber **? unchecked 4h** and are
  counted on their group heading — *1 gone · 3 unchecked* — and a monitored
  resource whose cluster could not be searched reads **? not checked —
  cluster unreachable**. Which cluster last answered and which last failed is
  kept in settings, so it survives a restart. Throughout, the wording blames
  the cluster and not the resource, and a verdict already reached stands.

---

## [0.8.1] — 2026-09-24

A fix release for four things that all showed up in the same place: the
terminal and the file browser standing next to each other.

### Fixed

- **The shell was told the wrong size, and only sometimes.** A terminal's
  size travels one way — xterm measures the pane, and its resize event
  carries the answer down to the pty — and until the pty exists there is
  nowhere to carry it to: a resize arriving before the pane has a terminal id
  was dropped. A fit landing in the gap between the pane being drawn and the
  shell being started was therefore lost, and because the grid was by then
  already the right size, nothing later re-announced it. The shell kept the
  80×24 xterm starts life with: lines wrapped in the middle of a wide pane,
  and a long command ran off the end of what you were typing. Whether the fit
  won that race came down to whether an IPC round trip beat a repaint, which
  is why the same session was fine one time and cramped the next. The pane is
  now fitted before the pty is opened, and the size is sent again once there
  is something to send it to — so toggling the file explorer to shake it
  loose is no longer the fix.
- **Opening the file explorer no longer squeezes the terminal.** The two
  share a row, and the explorer was allowed to shrink: on a narrow pane it
  collapsed towards its 160px minimum, so the panel you had just opened was
  too thin to read and the terminal's columns went with it. It keeps the
  width it is given — the default, or whatever you dragged it to — and the
  terminal takes what is left.
- **A host opened from the hosts pane or the folder browser now opens the
  same way as one opened from the sidebar.** Double-clicking in those two
  lists went in by a different door: no login was chosen, so a node with a
  preferred username was dialled as somebody else, and a node with per-session
  MFA missed the transport that can reach it. All three lists now open a host
  through one path, and the pane's own host menu carries the same entries as
  the sidebar's.
- **A local shell's file browser follows a `cd` like a remote one does.** The
  condition asked for a remote pane, so changing directory in a local shell
  moved the pane title and left the file list where it was.

---

## [0.8.0] — 2026-09-24

Tidying after the big release: a way to be rid of a cluster that has gone, a
leaf you can look into without switching to it, a file browser that keeps up
with the terminal beside it, and several things that were only ever hidden
behind a control nobody presses.

### Added

- **Remove an expired cluster.** A profile lives in the tsh home as a
  `<proxy>.yaml`, and that file is what `tsh status` reads — so a cluster
  whose certificate lapsed stays listed, with empty roles and *[EXPIRED]*
  against it, until the file goes. For a lab that was torn down, that is
  forever. The expired group now carries **Remove** beside *tsh login* and
  *Copy login cmd*: it names every path it is about to delete — the profile,
  any key material left behind, and the `current-profile` marker if it
  pointed there — and deletes them on confirmation. Deliberately not `tsh
  logout`, which is right for a live cluster and can sit waiting on a proxy
  that is no longer answering, which is exactly the case this exists for.
- **Leaf clusters in the hosts pane.** The pane's cluster list now includes
  them, each shown as `root › leaf`, and picking one reads that leaf with
  its own `tsh ls`. A question rather than a switch: the profile stays
  pointed where it is, and the sidebar is unchanged. A leaf whose proxy will
  not answer says so instead of looking empty.
- **Quick connect lists the servers you used before.** It always remembered
  them, but only inside the field's own dropdown — behind the little arrow
  nobody presses — so the address from an hour ago was effectively hidden.
  They are buttons under the field now, one click each, with *Forget* to
  drop the list. Addresses only, as before.
- **Files and folders can share a sort.** Folders above files is the
  convention and stays the default; it is also the wrong answer to "what
  changed here last" and "what is the biggest thing in this directory",
  which an order that holds the folders above it cannot give. *Settings →
  Folders before files*, or the ⇅ menu, turns it off and sorts everything
  together.
- **A bell on a watched host**, and a preference for it: thirty marked
  machines is thirty bells, which is where a mark stops meaning anything.
  The watch itself is unaffected by the switch.
- **Fresh screenshots in the README**, kept in the repository rather than
  hosted on a GitHub attachment — so the copy in every repository shows its
  own pictures.

### Changed

- **The file browser follows a `cd` straight away.** It always followed, on
  every transport that can be probed, but only when the poll came round —
  five seconds by default, long enough to look broken. The typed line is now
  watched for a `cd`, `pushd` or `popd`, and that pane's directory is read
  about half a second later: measured, an explorer that used to catch up in
  up to five seconds now moves in under one. Not a probe on every Enter —
  each probe is an exec, and on a recorded cluster an exec is a line in the
  audit log — and everything the line-watcher cannot see is still caught by
  the ordinary poll.
- **The dock takes a share of the window**, 15% rather than a flat 230px,
  which was a third of a laptop screen and a sliver of a monitor. A size
  dragged on a large display is clamped when the window shrinks.
- **A host's icon sits after its name.**
- **Split right and split down** moved up into the host menu's opening
  verbs, out of the block with the marks and the multi-exec checkbox.

### Fixed

- **tsh's colour codes no longer leak into the interface.** tsh colours its
  errors, and those escape sequences were drawn literally wherever a failure
  was reported — `␛[31mERROR:` in the middle of a dialog. Failed runs are
  stripped of colour, and of the `ERROR:` prefix, where they are read.

---

## [0.7.0] — 2026-09-23

The inventory, given room — and told to speak up when part of it goes
missing: a host you can mark as worth knowing about if it ever stops being
listed, a hosts pane, a sidebar that stops before it becomes a scrollbar,
columns you can sort by clicking, and the first automated tests, which found
two real bugs on their first run.

### Added

- **Tell me if this host disappears.** A quiet node is still in the
  inventory; the other failure is the one the list cannot show at all. A node
  that is decommissioned, rebuilt under a new id or dropped by an autoscaler
  stops being drawn, and nothing says so — the row is gone, so there is no
  row left to carry the news. Mark a host and its **node id and last known
  details** are kept — name, address, labels, cluster, when it was last seen
  — because once it has gone the cluster cannot be asked any of that. When it
  stops being listed you are told, and the host stays in the list, struck
  through, with **⊘ gone 2h** and the record in its tooltip; if it comes
  back, the mark clears itself and says so. A host is only ever declared gone
  off the back of a *successful* read of its cluster: an expired certificate,
  a proxy that will not answer and a failed `tsh ls` all produce a list with
  the host missing from it, and none of them means the machine is gone. Gone
  hosts count in the **quiet button** and its three states, so *Only quiet*
  is everything that has stopped answering however it stopped — and they are
  never hidden by the per-group cap, because a machine that has vanished is
  the news in that list.
- **A hosts pane.** *Open this list in a pane*, on a group's heading, gives a
  cluster the space a terminal would have had. The sidebar column is right
  for "open that host" and wrong for looking at a fleet: a hundred nodes in a
  column is a scroll, their labels are truncated to a badge, and the folders
  you built are a tree squeezed into a gutter. The pane has **folders on or
  off**, **rows or tiles**, the same filter language as everywhere else, a
  group switcher, and drag onto a folder heading to file something. It is a
  real pane — it splits, sits beside a terminal, closes like any other, and
  comes back with the workspace without dialling anything.
- **The sidebar stops at twenty hosts per group** and says how many it is
  holding back; that row opens the pane. A cluster with three hundred nodes
  turned the sidebar into a scrollbar with a list attached and pushed every
  other group off the bottom. The limit is in Settings, and a filter is
  exempt: you asked something specific, so you get the whole answer.
- **Column headings in the file browser** — *Name*, *Size*, *Date*, plus
  *Mode* and *Owner* when the details columns are on. Click to sort, click
  again to reverse, and an arrow says which is in force. Sorting was a button
  and a menu: two clicks and a read, for the thing a file list is asked to do
  most. The heading wears the same cell classes as the rows, so the widths
  and the points at which a narrow pane drops a column stay defined once.
- **Unit tests**, 70 of them, over the query language, the folder model,
  heartbeat ages and the shared helpers — `make test`, and in CI before
  anything is published. They import the real modules rather than a copy.

### Changed

- **Names sort the way people read them.** One rule now, everywhere: case
  insensitive, because `Downloads` belongs next to `docs` and nobody thinks
  of a capital letter as a sort key, and numeric, because `node-2` comes
  before `node-10` to every human being and after it to every plain string
  comparison. The file lists already did this; the Teleport node list did
  not. Folders in the host list sort by name too, rather than by when they
  happened to be made. Ties break on the name and *not* in the sort's
  direction, so "newest first" and "oldest first" agree about files sharing a
  timestamp.
- **A filed host is visibly inside its folder.** The indent gained one pixel
  at the first level, which said nothing; it is a real step now, with a
  hairline rail down the folder's contents.
- **A host's icon sits after its name**, not in front of it: the name is what
  you scan for, and anything ahead of it makes the column of names ragged.
- **Split right and split down** moved up into the host menu's opening
  verbs, out of the block with the marks and the multi-exec checkbox.
- **The tour covers the new ground**, and is offered again to anyone who has
  already taken it: a step on folders and the hosts pane, and one on a node
  going quiet or going away. The filter step now mentions `and`, `or`, `not`
  and the regular-expression operator.

### Fixed

- **Folders made from a group's own heading menu never appeared.** They were
  filed under the proxy address while the sidebar draws folders under the
  group key — two things that both sound like "this cluster", one of which is
  the scope for a preference that follows an identity and the other the list
  the rows are drawn in. They were saved correctly and rendered nowhere,
  which is the worst way for a feature to fail. Folders already saved that
  way are moved to where they belong on the next launch rather than being
  lost quietly.
- **A tag chip whose value contains a space never matched itself.** `termFor`
  quotes such a value — `"aws/Owner=Steven Martin"` — and the quotes were
  still attached when the chip asked "am I in the filter?", so the key read
  as `"aws/Owner`, the chip never lit up, and clicking it twice added the
  term twice. Found by the tests on their first run.
- **A quoted value with a space was truncated inside a boolean query.**
  `"region=us east"` was split again after the tokenizer had already split
  it, and matched `region=us` — silently the wrong hosts. Also found by the
  tests.
- **The twisty and the icon in a file row had no width**, so a file's name
  started a few pixels left of a folder's. Invisible until something above
  the list claimed to be a column heading.

---

## [0.6.1] — 2026-09-22

Folder rules, made usable by someone other than the person who wrote the
parser.

### Added

- **Regular expressions in a rule**, with `~`: `name~^(web|api)-\d+$`. A glob
  runs out quickly — "the numbered web and api boxes but not the canary" is
  one pattern and several globs — and a rule is written once and then decides
  membership for months, which is exactly where the extra precision is worth
  having. Case-insensitive like every other comparison here, and the brackets
  in a pattern are the pattern's own, so `name~^(web|api)$` is one condition
  rather than a bracketed group. A pattern that will not compile is reported
  in the rule editor instead of quietly matching nothing.
- **A rule builder in the folder dialog.** The hard part of a rule was never
  the syntax, it was knowing what *this* cluster calls things — `tsh ls`
  decides the labels and every cluster's are different, and nothing on screen
  said what they were. Now *Insert a tag…* lists every label the group
  actually sets with how many nodes carry each value, *Insert a field…* does
  the same for `name`, `addr`, `cluster` and the rest including the regex and
  glob forms, `and`/`or`/`not`/brackets are buttons, and an `and` is put in
  between two conditions that have nothing between them. What the rule matches
  **right now** — the count and every matching host by name — is under the box
  as it is typed.

### Fixed

- **A label no longer hides a field of the same name.** AWS nodes carry an
  `aws/Name` tag, whose last segment is `name`, and a keyed term stopped at
  the label: on those hosts `name=web-1` silently asked about the EC2 tag and
  never about the node's own name, so `name=prd-lku1-linux-ec2` matched
  nothing at all on the one host it obviously described. Both are asked now,
  and either matching counts — which is what anyone writing it meant.

---

## [0.6.0] — 2026-09-22

Somewhere to put things. A cluster's list is whatever `tsh ls` returns, in
whatever order, and on a real fleet that is several hundred rows in which the
fifteen you work on are scattered — so this release is folders, the rules that
fill them, and a view with room to do the filing in.

### Added

- **Folders in the host list**, per cluster and per ssh_config file. Drag a
  node in and it stays there. Membership is kept by the node's **UUID**, never
  its hostname: a hostname changes on a rename or a rebuild, and a filing
  system that empties itself when somebody renames a box is not one. An
  ssh_config host is kept by its alias, which is the same thing for a host
  with no uuid.
- **Folders that fill themselves.** Give one a tag query and it re-asks it
  whenever the inventory changes, so a node that comes up tagged `env=prod`
  files itself with nobody touching it. The editor says how many hosts the
  rule matches *right now* and names the first few, because a rule that
  matches nothing is easy to write and hard to notice. Hand-filed and
  rule-filled work together in the same folder, and taking a node out of a
  rule folder is remembered as an exception — otherwise the rule would put it
  straight back, which reads as the app ignoring you.
- **A filed host stops being listed loose**, because the point of filing
  something is that it is now somewhere. The group's menu will list them in
  both places for anyone who would rather see the cluster flat as well.
- **Folders nest**, to any depth, and can be dragged into one another. A
  folder cannot be dropped inside itself or inside its own descendant: the
  cursor refuses rather than the app explaining afterwards.
- **Dragging a host into a folder under a different top-level folder asks**
  whether to list it in both or move it. Both answers are ordinary — the same
  box is one of the web servers *and* one of the things on call this week — so
  it is a question rather than a guess. A drag within one tree is a tidy-up
  and moves without asking; a drag of fifteen machines asks once, not fifteen
  times.
- **A folder browser** (*Folders*, above the host list): the tree on the left,
  what is in the selected folder on the right, breadcrumbs, and an **Unfiled**
  entry per group, which is where the filing actually gets done. It behaves
  like a file manager because that is the shape people already know — click,
  ⌘-click and shift-click to select, drag a selection onto any folder, double
  click a folder to go in or a host to open a session. A folder's rule is
  shown above the hosts it currently claims.
- **Boolean tag queries** — `and`, `or`, `not` and brackets — in folder rules,
  the host filter box and multi-exec's tag selector, on top of the older
  syntax where a space means "and" and a leading `-` means "not". One rule can
  now say `env=prod and (role:web or role:api) and not name=web-canary`, which
  is the shape a real rule takes and could not be written as a list of ANDs. A
  half-written query is not an error: while you are still typing, the box
  falls back to reading the words as a plain list of conditions rather than
  blanking the list.
- **Icons and colours.** A folder can carry an emoji and one of the eight host
  colours — 🔥 and 🧪 are read faster than two folder shapes with different
  names, and the colour is the same mark its hosts take, so a red folder and a
  red host match. **Hosts can carry an emoji too**, ssh_config hosts included.
  It is separate from the colour on purpose: the colour is "careful", the icon
  is *which* of these it is. A red 🐧 and a red 🪟 are both production and not
  the same problem.
- **An arrangement can be shared.** *Export these folders…* writes the tree,
  the rules, the membership, the icons and the colours to a file; *Import
  folders…* reads one back. No addresses, no logins, nothing secret — it is a
  way of looking at a cluster, and it is safe to put in a pull request.
  Membership travels as UUIDs, so a colleague's import lands on the same
  machines; rules travel anywhere, which is why the import offers to land a
  file from a cluster you do not have into one you do. Imported folders are
  given new ids, so importing twice copies rather than quietly overwriting
  what you have since edited.

### Fixed

- **Nodes stopped falsely reporting as quiet.** The heartbeat age added in
  0.5.0 was worked out against the wall clock, and the wall clock keeps going
  when the reading stops — the background poll pauses while the window is
  hidden, it can be switched off in Settings, and a proxy that will not answer
  leaves the previous list in place on purpose. Any of those for a few minutes
  and every node in the cluster grew a warning while being perfectly healthy.
  The age is now taken as of the moment the list was actually read, and past a
  grace period it is not taken at all: not looking is not the same as nobody
  answering.

---

## [0.5.0] — 2026-09-21

The theme is what is true while nobody is looking: a node that stopped
answering ten minutes ago and still offers to connect, a file browser polling
servers on a tab you are not on, and a fan-out that reached eighteen of twenty
and reported eighteen.

### Added

- **Nodes that have gone quiet are marked.** A Teleport node stays in the
  inventory for ten or fifteen minutes after its agent stops heartbeating —
  same row, same labels, still offering to connect — and it then disappears
  without ever having looked wrong. A session opened into that window does not
  fail quickly either; it hangs waiting for a tunnel with nobody on the far
  end. Past two minutes of silence the row carries an amber **⚠ 7m**, and its
  tooltip says how long is left before the cluster drops it.
  The cluster publishes no "last seen". What it publishes is when it will give
  up on the node, which every heartbeat pushes a full announce interval into
  the future, so the age is the difference between the two. The interval is
  not in the output either, so it is read off the cluster's own healthy nodes
  — the freshest of them has just heartbeated, and that is the whole interval.
  A cluster with a single node in it warns late rather than inventing
  staleness, and hosts with no heartbeat to be late, such as agentless OpenSSH
  nodes, are never marked. *Settings → Warn about nodes that have gone quiet*
  moves the threshold or turns it off.
- **Heartbeats on every row.** A button beside *Show tags* puts the same
  figure on each Teleport host — `♥ <1m` for one that is answering — for when
  you are watching something come back, or wondering whether the list is
  telling you the truth. In minutes, because changing the text rebuilds the
  list and a rebuild costs the scroll position; the exact seconds are in the
  tooltip.
- **One button for the quiet ones**, appearing beside it as soon as something
  goes quiet and cycling `Quiet: 2` → `Quiet hidden (2)` → `Only quiet (2)`.
  The count stays on it in all three states, because a cluster that is quietly
  two nodes short is the thing worth knowing; the last state is the list to
  have open when something has taken a rack or a subnet with it.
- **Whether a host opens with its file browser**, on its own menu below
  *Preferred username…* and on the cluster's. Some hosts are a shell and
  nothing else — a jump box, a router, an appliance with no SFTP subsystem at
  all — and there the explorer is half a pane spent on an error; others on the
  same cluster are entirely about the files. Three levels like agent
  forwarding: the host, then the cluster, then the global preference. Asking
  for the files still outranks all of it: ⌘E and *Open files only* are
  unaffected.
- **Multi-exec says who it will run as**, next to every target and on every
  result row, resolved exactly as the connection will resolve it. A fan-out
  run as the wrong account fails on every host at once, and the only previous
  sign was twenty *permission denied* lines from an unnamed user.
- **Hosts a fan-out could not dial are kept, with a Retry.** A failure to
  connect was a toast and nothing else, so the host was simply absent from the
  results — twenty boxes reported eighteen. They now sit above the results
  with what each was tried as and why it failed, and *Retry these* re-runs the
  same command over just those hosts, which is what an expired certificate, a
  timed-out MFA prompt or a proxy that blinked deserves.

### Changed

- **The file browser only polls what is on screen.** A hidden explorer — the
  file side collapsed, or the pane in a tab you are not on — is left alone and
  caught up the moment it is shown again, rather than re-listing every few
  seconds. With every explorer hidden the servers are asked nothing at all,
  including the directory probe: that probe is an exec, and on a cluster with
  session recording it was an audit entry every few seconds per pane. Where it
  does run, following the shell now reuses the directory the pane title just
  read instead of probing a second time, halving the execs per pane per tick.

---

## [0.4.0] — 2026-09-20

The theme is the far side of the connection. Network checks made *by* a
server rather than about it, the history that server already has, and a long
tail of places where the app guessed at a username, a login command or a node
and guessed wrong.

### Added

- **Network tools that run on a chosen host.** *Run on* at the top of the
  window switches between this machine and any open session, and the network
  icon on a session's header opens the tools already pointed at that host.
  Three checks need nothing installed on the far side: a **port check** the
  server itself makes over the session already authenticated (`ssh -W`, so the
  answer is its own network stack, and a service that speaks first hands back
  its banner), an **HTTP request** sent through a SOCKS proxy with
  `--socks5-hostname` so the name resolves *there* too, and the host's own
  **addresses, routes and resolvers**. **Ping** and **traceroute** need a tool
  and get one anyway — `traceroute`, else `tracepath`, else `mtr --report` —
  and are greyed with the install command for the host's own package manager
  when it has none of them. What a host has is read once per session in a
  single command, because on a per-session-MFA node every exec is a prompt.
- **A port has three answers, not two.** *open* was accepted, *refused* means
  the host answered and nothing is listening, *no answer* means the packet was
  dropped. The distinction is the diagnosis: a refusal is a service to start,
  silence is a firewall rule to change.
- **Command history, per host.** Right-click a terminal → *Command history on
  this host*. Read from the shell's own history files — bash, zsh with or
  without timestamps, and fish — newest first with each command once, searched
  by any word in any order. Copy it, put it at the prompt, run it, or turn it
  into a macro.
- **Macros say where they can run**: hosts, the local shell, or both. A
  `systemctl` check is not offered in a Mac's shell and `brew upgrade` is not
  offered on the server, multi-exec leaves out anything local-only, and a
  pinned button never appears where its macro would not run. Sending one
  somewhere it is not set for still works, but asks.
- **`tsh ls`, `tsh ssh…` and `tsh scp…`** as built-in macros, scoped to the
  local shell. The last two paste at the prompt without Enter, to be finished
  by hand.
- **The + above the tabs opens a local shell.** *This machine* now leads the
  new-session picker instead of sitting below the last of several hundred
  hosts, with every other installed shell behind it.
- **Teleport node lists and certificate expiry refresh on a timer.** One
  `tsh status` and one `tsh ls` per live cluster, paused while the window is
  hidden, redrawn only when something actually changed. Expiry is watched in
  both directions: a certificate that lapses while you are looking at it, and
  one you have just logged back into from a terminal.
- **Make this the active profile**, on a cluster in the Hosts list.
- **`cd` to a folder in the terminal** from a starred folder or from the blank
  space below a file list.
- **Open as text** and **Open with…** for local files, with the applications
  you choose remembered.
- **Move a pane to its own tab**, keeping its session, scrollback and whatever
  is running in it.
- **Icons in the menus**, and a `?` that opens a card with what an item
  answers and the command it runs, rather than a tooltip that wanted a steady
  second of hover.

### Changed

- **A proxy address is the host and port, and nothing else.** The address
  people have is the one in their browser, so it arrives as
  `https://example.teleport.sh/web`; the scheme and anything after the host
  are now dropped where you can see it happen, and every command built from a
  cluster applies the same rule.
- **An expired cluster logs in the way it was saved to.** The connector, TTL
  and MFA mode come from the saved record instead of a bare
  `tsh login --proxy=`, which on an SSO cluster picks local auth.
- **Duplicate hostnames are dialled by node id.** Two nodes in a cluster can
  answer to the same hostname, and `tsh ssh user@name` then refuses rather
  than choosing. Those nodes go through `tsh ssh` by UUID, and carry the first
  block of it in the tab title so two sessions are not identical.

### Fixed

- **A wrong username is now something you can correct.** *Server profile* and
  *Port forward* used the cluster's first login rather than the one that last
  worked on that host, so they could fail as an account the terminal had never
  used. When a profile fails it names the account it tried, lists the others
  the cluster grants, and offers to dial again as one — remembering it if it
  works.
- **A failing server profile says what went wrong.** It used to print Node's
  `Command failed:` with the whole probe script flattened into it. The probe
  also ended with whatever its last command returned, so a good read was
  discarded over a missing `command -v`; and a partial read is now kept and
  labelled rather than thrown away.
- **An expired cluster no longer opens a shell tab to log in over SSO.**
  Naming the user was what made tsh prompt, and a prompt was what the shell
  tab was for; a terminal is now used only for genuine local auth.
- **Terminal rendering.** The WebGL glyph atlas is rebuilt when the display
  scale changes, so moving the window between a Retina screen and an external
  monitor no longer smears the text; fallback glyphs are scaled to the cell
  so powerline and box-drawing characters stop overlapping their neighbours;
  and a window resize sends one SIGWINCH at the end of the drag rather than
  one per frame, which is what garbled a full-screen program mid-resize.
- **Closing a pane lets its neighbour have the space.** Dragging a splitter
  sets a fixed pixel width, and that survived the pane it was sharing with —
  so the survivor kept its old size, left a gap, and would not grow with the
  window.
- **A new macro kept the scope it was given.** It was dropped on first save,
  so every new macro was offered everywhere until it was edited again.
- **Cancel worked.** Several dialogs spell "close, answering nothing" as
  `value: undefined`, which read as "no value" and called an `onClick` that
  was not there — a dead button on the rename prompt, the layout picker and
  the key dialogs, where Escape was the only way out.
- **Dates show in a narrower file list.** The column needed 348px of pane but
  was only hidden below 330, so in between it was pushed off the end of the
  row.
- **Active and expired clusters are coloured**, instead of being the same grey
  as the home name beside them.

---

## [0.3.0] — 2026-09-18

Mostly the gaps the other SSH clients had and this one did not: a transfer
queue you can steer, a recursive search, colour where it prevents mistakes, and
an app that remembers how you left it.

### Added

- **Transfer queue control.** Pause and resume, per transfer or the whole
  queue; **retry picks up where it stopped** — a download resumes from what is
  on disk, an upload from what the server already has, so a dropped VPN does
  not mean starting a 4 GB file again. Reorder what has not started, and cap
  the speed in KB/s across every transfer. A pause holds the transfer *between
  chunks* rather than tearing it down, so resuming is instant and nothing is
  re-authenticated; a file added while the queue is held waits with the rest.
- **Recursive search**, on a server and on this machine. By name (a bare word
  matches anywhere) or by content, with the line number and the line. On a
  server it is `find` and `grep` with the cap applied by `head` on the far end;
  locally it is a bounded walk. Either way it stops after six seconds or a
  quarter of a million entries and **says which**, because "no results" from a
  search that gave up is the wrong thing to believe.
- **A colour per host**, drawn down its row, its tabs and its panes, with the
  name tinted. How you know the pane you are typing into is production without
  reading it. A host can also be marked **careful**, and multi-exec then asks
  before a command fans out to it.
- **Terminal palettes** separately from the app's theme: Solarized dark and
  light, Gruvbox, Nord, Dracula, high contrast. A named palette wins over the
  theme and over any skin — someone who asked for Solarized asked for
  Solarized whatever colour the sidebar is.
- **Multi-exec targets by tag.** A cluster and a query in the host filter's own
  syntax — `env=prod role:web` — resolved when the command runs, so it does not
  go stale when a node is added. The query is what a saved run keeps (the hosts
  it matched go in as a commented snapshot), *Run again* re-asks it, and the
  **Ansible export resolves it first**, because an inventory is a list of
  machines.
- **Access requests where you will see them.** A badge on the Teleport tab —
  amber while a reviewer has it, green once something is approved — a `n req`
  tag on each cluster's heading, and the list on a right-click of the heading
  or of the tab strip. Only what you could act on is counted.
- **`tsh status` on any cluster**, from its heading or its profile row: the
  app's own view above the printed output, and a note when tsh leads with a
  different active profile.
- **The window and the panels remember their size** — where the window was, how
  big, whether it was maximised, and the widths of the sidebar, file panel,
  dock and terminal split. Checked against the displays that exist at launch,
  so a window last used on a monitor you have unplugged is clamped to fit
  rather than opening somewhere unreachable.
- **Titles say who and where.** `ubuntu@tele1c: ~` on the pane and its tab, and
  `local: /var/log` for a shell, following the shell as it moves. The directory
  comes from the shell's own process rather than from typing `pwd` into your
  terminal. Naming the shell as well (`zsh: ~`) is a preference, off by
  default.
- **The reopen offer says what it would reopen**, as `ubuntu@ent: ~/deploy` —
  and **clicking one row reopens just that session** and closes the offer, with
  the rest still saved for next launch. A local shell comes back in the
  directory it was in; a remote one is sent a `cd` once its shell is up.
- **A `?` on every macro row**, with its own tooltip: what it is for, the
  command, and whether it asks first, follows a log, or has blanks to fill in.

### Changed

- **Keyword highlighting is now off by default.** Colour in a terminal belongs
  to the program, and rewriting its output is a decision worth making rather
  than one that arrives. Switch it on in Settings, or per host from the toggle
  beside a pane's search box.
- **Submenus open from the arrow, not from the row.** Every macro row both runs
  something and carries variations, so opening on hover threw a second panel
  under the pointer at each step down the list.
- **A login that names a user runs in a terminal.** `tsh login --user=…` heads
  for a password, an OTP or a hardware key, and a prompt in a spawned process
  with nowhere to draw is a login that hangs and then fails. It now opens a
  local shell tab and re-reads the inventory when the command exits —
  everywhere a login starts, including automatic login.
- **The request tag is `5 req`** rather than `4 approved`: a cluster heading
  already carries its home, leaf and beam badges, and the count is the news
  while the colour says which kind.

### Fixed

- **Submenus closed as the pointer moved towards them.** Moving diagonally left
  the parent panel, which closed the submenu on the way — so the shells, the
  transports and the scope menus could only be hit by luck.
- **The access-request indicator never appeared.** Its first pass ran before
  the inventory had read any Teleport profile, found no clusters, and then
  waited ninety seconds; it now asks as part of the inventory load.
- **A speed limit was four times what it said.** Sixteen parallel chunk
  requests each saw the same allowance, waited the same second and reset the
  window; the accounting is now serialised.
- **"Pause all" did not hold what came next.** A transfer added while the queue
  was paused started immediately.
- **A pane's highlighting could not be turned on** once the global default was
  off: the per-pane override could only subtract. It is now three-valued —
  follow, on, off.
- **An ssh session's tooltip claimed its login was a cluster**, because the
  bracketed part of a label means different things for a Teleport node and an
  ssh_config host.

---

## [0.2.0] — 2026-09-17

A minor rather than a patch: the host list, the file browser, the terminal and
the documentation each gained something this release, and a few of them changed
shape.

### Added

- **Keyword highlighting in the terminal.** Errors, warnings and good news are
  coloured as the output arrives, so `error` is visible without searching for
  it. The toggle sits beside each pane's search box; right-clicking it opens
  the rules. Three sets ship on and live in code so they improve between
  releases; your own take plain text or a regular expression, a colour, and
  background or foreground. A rule can be added for **one host only** — a mail
  relay's "deferred" is routine, a build box's is not — and any rule can be
  switched off for one host without touching the others. It works by rewriting
  the stream on its way to the terminal, putting back whatever colour the
  program had set, and **stands aside entirely while a full-screen program is
  drawing** (vim, less, htop), which draw their own.
- **Starred hosts and starred folders.** A star on a host row sorts it to the
  top of its own group — or gathers every starred host into one group, which
  is a preference — and hosts can be **dragged into the order you want** within
  a group, which outranks the star. A star in an explorer's toolbar keeps the
  folder on screen: starred places are listed above the file list with their
  paths, and in *Go to a path*. **Files can be starred too**: a starred folder
  is somewhere to go, a starred file is something to open. Per-host stars are
  kept against a node's uuid, so renaming it does not lose them.
- **Folders flagged without being asked.** Home, Desktop, Documents and
  Downloads here; the same plus `/var/log`, `/etc` and `/tmp` on a server. Both
  lists are configurable in Settings, one path per line with `~` for home.
  Nothing that is not there is offered: a local path is checked first, and a
  `~/name` entry only appears on hosts that actually have that folder, from one
  listing of the home directory per connection.
- **More than one `ssh_config` file.** Each extra file is a root, not an
  include, and gets its own group in the host list; its hosts are opened with
  `ssh -F <that file>` so the file's own options and defaults are what apply,
  and two aliases of the same name in two files are genuinely two hosts.
- **A refresh on each cluster and each config file.** The toolbar's Refresh
  re-reads everything, which on several clusters is seconds of `tsh` for the
  sake of the one that changed. The `⟳` on a heading asks only that cluster —
  its nodes, its leaves and its beams.
- **A preferred username per host**, said deliberately rather than learned, and
  stored **against a Teleport node's uuid**: the hostname in an inventory is a
  label that changes when a machine is renamed or rebuilt, and a setting that
  evaporates on a rename is worse than no setting.
- **Agent forwarding, decided at three levels** — the host, its cluster, then a
  global preference, most specific first. Off by default: forwarding the agent
  lets anything running as root on that host use your keys while the session is
  open, which is what a jump host needs and what a shared box should not have.
  Every route into a connection obeys it, including an agent through MCP.
- **Favourite port forwards.** Star an open tunnel, tick *Keep this as a
  favourite* while creating one, or define one outright. **Open** puts it back
  up, dialling its host first if needed. A favourite stores the host whole
  rather than by id, because it has to outlive the inventory it was made from.
- **Macro variables.** A command can leave blanks — `{{service}}` — with a
  default, a list of values to choose from, or nothing, in which case it is
  always asked for. A macro whose blanks all have defaults still runs on one
  click; *Fill in variables…* in its submenu opens the dialog either way, with
  the command previewed as you type. Across multi-exec the values are asked for
  once and the same ones go to every host. The last entry in the ▶ menu now
  **writes a new macro**, because the moment you want one is the moment you
  have just typed the same command for the third time.
- **Recent multi-exec runs.** Every run is remembered by its command and the
  hosts it ran on — not its output, which is long and stale immediately — and
  **Run again** re-selects those hosts and runs it. Hosts are matched by id, so
  a renamed node still matches; if some have gone it says how many are left and
  asks first.
- **curl in Network Tools.** A full request — method, headers, body, bearer or
  basic auth — run through curl itself, with the command shown as it will run,
  the response formatted (JSON pretty-printed, the redirect chain kept), and
  the call keepable to run again. **Examples…** fills in the typical shapes for
  every tool, **Recent** reruns what you just did with the options it used, and
  **Save output…** writes any tool's result to a file.
- **`tsh config` into `~/.ssh/config`.** *Add to ssh config…* on a cluster
  writes its block between markers naming that cluster, at the top of the file,
  with a backup taken — so scp, rsync, Ansible and VS Code Remote reach its
  nodes. Writing again replaces it rather than stacking a second copy, and if
  the cluster is **already in there** from a `tsh config` run by hand it says
  so, names the patterns it found, and asks again before adding a duplicate ssh
  would silently half-ignore.
- **Latency to a Teleport node** (`tsh latency ssh`): the round trip from here
  to the proxy and from the proxy to the node, live, in a tab of its own.
- **ProxyJump on a saved profile**, alongside an optional hostname and port, so
  a profile can reach a host through a bastion without an `ssh_config` entry.
- **Automatic login for saved clusters**, per cluster and off unless asked for,
  one at a time — an SSO login opens a browser, and four browser tabs fighting
  over the foreground is worse than clicking one button.
- **Any shell, with or without its startup files.** The local shell's menu
  lists the shells installed on this machine, and can open one that reads no
  profile or rc file at all — for reproducing what a script sees, and for
  getting a working shell when an rc file is what just broke.
- **Save a terminal to a file**, scrollback included, from a pane's own menu.
- **Four more MCP tools**: `list_forwards`, `open_forward`, `list_requests` and
  `run_request`. They keep the same rule as `run_macro` — a caller can ask for
  something you wrote and can read, never an arbitrary command, port or URL —
  and `list_hosts` now also says whether a host is starred, which account it
  prefers, and whether the agent is forwarded to it.
- **Resizable dialogs** (Network Tools, the guide) that remember their size.

### Changed

- **The documentation is split.** [GUIDE.md](GUIDE.md) is the reference — every
  panel and every menu, and the reasoning where it matters — and the README is
  back to what it is for: what this is, how to build it, and what to be careful
  of. It went from 1110 lines to 497.
- **The guide is in the app.** *Help → Guide* (`⌘/`) opens it with a section
  list, a search box that marks every hit and steps between them, and buttons
  to copy or save it. Bundled as text at build time, so it works from a
  packaged build where the markdown is inside `app.asar`.
- **The tour covers what has been added**, and is offered again to anyone who
  saw the old one: sixteen steps now, including beams, leaf clusters, the
  per-host settings, highlighting and the newer parts of the file browser.

### Fixed

- **A submenu was almost unreachable.** Moving the pointer towards one left the
  parent panel, which closed it on the way — so the shells, the transports and
  the scope menus could only be hit by luck. Closing now waits, and arriving in
  either the item or the panel cancels it.
- **Editing a saved cluster needed a login.** Save and Login are separate
  buttons: correcting a proxy address or switching a connector is not the same
  act as logging in, and before this the only way to keep the change was to run
  a login you may not have wanted to run right then.
- **A pane's highlighting could not be turned back on.** The toggle asked the
  *setting* whether it was on, not the pane, so a pane switched off by hand
  switched itself off again — off was a one-way door.

---

## [0.1.26] — 2026-09-16

### Changed

- **Recordings list the sessions someone sat in, not every exec.** A cluster
  logs a recording for each command run over SSH — health checks, config
  reads, everything the app's own *Run a command* does — and they have no
  transcript to search and nothing to watch. On the demo cluster this was 47
  of 50 rows. Interactive sessions are what the list shows now, with a count
  of what is held back and a checkbox to include the rest.

### Added

- **Flag a recording, and write a note on it.** The star on a row keeps a
  session; the note is where the circumstance goes, because by the time you
  want a recording again you remember "the deploy that went wrong", not a
  timestamp or a session id. **Flagged only** narrows the list to them, and a
  flagged session stays listed even after it falls outside the range the
  cluster will answer for — the note carries the node, user and time needed to
  find and replay it.
- **Search by session id.** The filter already matched ids in the list; a full
  id pasted in that is *not* in the loaded range now offers to play it, open
  it in the web UI, or flag it — a recording can be opened by id alone, so
  there was never a reason to make someone widen a date range to reach one.
  Notes are searchable too.

### Fixed

- **A long duration read as minutes.** A session left open overnight showed
  "1593m 13s"; durations now roll into hours and days, which also tidies
  transfer and command timings.

---

## [0.1.25] — 2026-09-16

### Added

- **Synchronise from an agent.** `serverlife_sync_preview` says what a sync
  would do — every upload, download and deletion, with its reason — and
  `serverlife_sync_apply` runs it, between this machine and either a server or
  a **beam** (`host` or `beam`, `local` and `remote` paths, direction and
  match rule). `serverlife_list_beams` lists the beams to name. The connection
  is made the way the window makes it, **including the login the app remembers
  for that host** — usually the difference between reading the files and
  "permission denied" — and transfers appear in the app's own queue.

### Fixed

- **A folder the source no longer has is now removed, not just emptied.**
  Synchronising compared files only, so deleting a folder locally deleted its
  files on the server and left the folder — and every folder ever deleted
  stayed as an empty shell. Folders are matched too now, removed deepest
  first, and an empty folder on the source side is created on the other side
  for the same reason.
- **A folder removal can no longer take anything the plan did not list.** A
  Teleport node's SFTP service implements the protocol's `RMDIR` as a
  *recursive* delete, so removing a folder destroyed whatever was still inside
  it — a file added since the plan was made, one the sync ignores, or one
  whose row you had unticked. Folders are now checked to be empty immediately
  before removal and kept, with a reason, if anything is in them; unticking a
  file also unticks the removal of the folder holding it.
- The sync dialog **says when it is leaving deletions alone** — "3 file(s)
  exist only on the other side" — rather than showing nothing for a file the
  source no longer has and letting it look as though the sync had missed it.

---

## [0.1.24] — 2026-09-16

### Fixed

- **Deleting a beam often did not delete it.** The service uses optimistic
  concurrency, so removing a beam created moments earlier comes back with
  `condition failed … please reload the current state and try again` — a race,
  not a refusal. The app took it as a refusal and gave up. It is retried now,
  and "does not exist" counts as deleted, since that is the outcome that was
  wanted.
- **A deleted beam came back in the list.** `tsh beams rm` returning is not
  the beam being gone: a list taken straight afterwards still reports it for a
  few seconds, so the one refresh that followed the delete put the row back.
  The row now goes at once and the deletion is confirmed by re-reading the
  list a few times over the next several seconds; if the cluster is still
  listing it after that, it says so rather than letting the row reappear
  silently, and a delete that genuinely failed puts the row back with the
  error.

### Changed

- **The beam list re-reads itself every minute.** Beams expire on their own
  and anyone with the cluster can start or delete one, so the list (and the
  countdown on each row) went stale until the next refresh. The loop pauses
  while the window is hidden and does nothing for a cluster without beams, so
  it costs one `tsh beams ls` per beams-capable cluster per minute.

---

## [0.1.23] — 2026-09-16

### Added

- **Beams** — the ephemeral sandbox VMs `tsh beams` manages — listed **with
  their cluster**, under a `beams` heading inside that cluster's group, each
  row badged as a beam and showing its region and how long it has left. With
  the cluster because a beam is something running on it; marked off because a
  beam is not a node — it expires on its own and its row offers to delete it.
  A cluster is asked once whether it runs the service (`tsh beams ls`
  answering at all is the test) and the answer is remembered; one that cannot
  be asked can be **marked as a beams cluster** by hand from its menu, and any
  cluster's beams can be hidden.
- **Everything the app does to a server, it now does to a beam.** Opening one
  creates an ordinary connection — `tsh beams ssh` for the terminal, `tsh
  beams exec` running the beam's own `sftp-server` for the file channel — so
  the file browser, transfer queue, **synchronize**, **compare**, **keep up to
  date**, remote editing and drag-and-drop all work on a beam with no
  special-casing. A beam registers as a `beam-<uuid>` node as well, and those
  are filtered out of the cluster's list so each beam appears once, under its
  own name, where it can be managed.
- **The whole `tsh beams` command set**: list, start one (with a region, then
  an offer to open it), delete it, a shell, a one-off command answered in a
  dialog, publish and unpublish a service (the address is captured and
  copied), and `scp` for a whole directory in one call.
- A beam refuses port forwards and says why: publishing a service is the
  beams-shaped answer to the same question, and it is one menu item away.

### Fixed

- **A drag was only accepted over the file rows themselves.** Dropping on the
  path bar, the toolbar, the status line or the empty space under a short
  listing did nothing at all — indistinguishable from the drop not being
  allowed. The whole pane is the target now, and highlights to say so; the row
  under the pointer still chooses the destination folder when there is one.

---

## [0.1.22] — 2026-09-16

### Added

- **Synchronize a folder with a server**, with the plan shown first: direction,
  what counts as the same file (size and time, or either alone), optional
  deletion of what the source does not have — then every action as a line you
  can untick, with its reason, and an amber flag on anything that would
  overwrite a newer copy. Transfers ride the existing queue, so progress, rates
  and cancelling work as they always did. Symlinks are skipped, not followed.
- **Compare two file lists**, marked on the rows: newer here, newer there, only
  here, or same time and different size. Instant, from the listings already on
  screen, and identical files stay unmarked so only the differences are lit.
- **Keep a folder up to date.** Every save in a local folder is uploaded, new
  files and subfolders included. It never deletes, and it ignores `.git`,
  `node_modules` and editor scratch files.
- **Edit a remote file in your own editor** — a temporary copy, opened by this
  machine's default for the type or a command you name in Preferences
  (`code -w`), with every save going back up until you stop. Both this and the
  folder watch live in a new **Watch** panel with a stop button, and both end
  with their session.
- **Permissions, owner and group in one dialog, recursively**, with the exact
  `chmod -R` / `chown -R` shown before it runs. One mode on one file still goes
  over SFTP and needs no shell.
- **Macros can be buttons.** Pin one and it appears in every session's title
  bar as an icon you choose, one click from running on that host. Built-ins pin
  too; right-click a button to change its icon or unpin it.
- **"Too many authentication failures" now gets an explanation** in Quick
  connect, because the message names a count rather than a cause. It says what
  actually happened — your agent offers every identity it holds and sshd stops
  after six attempts, so the right key can be refused for being seventh —
  offers to retry with one key (`-i key -o IdentitiesOnly=yes`), and has a
  **Debug info** button that lists every key offered, in order, with what the
  server accepts.

### Fixed

- **An upload did not preserve the file's modification time**, so any sync
  comparing timestamps saw every file as changed again and would have re-sent
  the whole tree on every run.

---

## [0.1.21] — 2026-09-16

### Added

- **Downloads**, in the dock after *Connection log*: everything pulled off a
  server or out of a bucket, with where it landed. A transfer row answers "is
  it done"; this answers "where did that go", which is asked later — often
  after the transfer list has been cleared, so it is kept across restarts. Each
  row opens the file, shows it in the Finder, or hands over its name or path. A
  folder is one row; loose files are a row each. A file that has since been
  moved or deleted stays listed and says so, rather than offering an *Open*
  that does nothing.
- **Permissions and owner as columns** in any file list (`≡`, or Preferences).
  The names come free: SFTP already sends the `ls -l` line the server wrote, so
  `root:wheel` needs no extra round trip, and a local listing resolves uid and
  gid through `/etc/passwd`. A uid from a directory service is shown as the
  number rather than dressed up as a name.
- **"What do these permissions mean?"** in *Get info* — the nine letters split
  into named groups, then the file read back in sentences: who can do what, in
  the verbs that apply to what it is (`x` on a directory is "enter it", not
  "run it"). It calls out the cases that bite: a directory nobody can enter,
  world-writable, executable but not readable, sticky, setuid.
- *Get info* also reports **accessed and changed times, the inode, and the
  setuid, setgid and sticky bits**, with the octal in its four-digit form when
  any of them is set.

### Fixed

- **Opening a folder in the file browser bounced back out of it.** Following
  the terminal's directory was following the shell's *position*, so every few
  seconds the list was dragged back to wherever the shell was sitting — which
  made browsing anywhere else impossible. It follows the shell *changing*
  directory now: open what you like, and it picks the terminal up again the
  moment it cds somewhere new.
- **A transfer looked stuck at 100%.** The bytes being across is not the file
  being on the disk — the local copy is still being written out, and on an
  upload the server flushes when the handle closes. That tail now says what it
  is waiting for instead of showing a frozen bar.

---

## [0.1.20] — 2026-09-16

### Added

- **Leaf clusters are visible, and you can switch to one.** A trusted cluster is
  not a profile of its own — `tsh status` names only the cluster your
  certificate points at — so a root with a dozen leaves behind it looked exactly
  like a root with none. A cluster with leaves now carries a leaf badge in the
  host list and on the Teleport tab; clicking it lists the root alongside every
  leaf, with each cluster's labels, and moves the login between them. The badge
  says which side you are on — the count on the root, *leaf* in the accent
  colour once you are on one, since the heading then shows the leaf's name and
  nothing else would tell you. Also on the heading's right-click menu. An
  offline leaf is shown but not offered; the cluster in use is ticked.
- **Past ten leaves the switcher becomes a searchable dialog**, matching names
  *and* labels — across an estate's worth of trusted clusters the label
  (`env=prod`, a region, a customer) is often all anyone remembers.
- **Open a cluster in the Teleport web UI** — from the Teleport tab, a saved
  cluster, or the cluster heading. It needs no certificate, so it works on an
  expired profile, which is often the way back in.

### Changed

- **A node in a leaf cluster is dialled with `tsh ssh`**, not with OpenSSH over
  the generated `ssh_config`. Both routes connect, but the config route presents
  the *root* cluster's certificate — the only one `tsh config` names for any
  block — whereas tsh has one issued for the leaf, so the leaf's own role
  mapping and principals decide what the session can do. Settled in one place,
  so it holds for sessions, splits, multi-exec and the file browser alike.
- **The server profile works on a leaf node.** It was refused on anything using
  `tsh ssh`, to avoid spending an MFA approval nobody asked for — reasoning that
  only applies where the transport was chosen *for* per-session MFA, not where
  tsh is simply the only route.

### Fixed

- **"Switch to" never switched.** The profile switch ran
  `tsh login --proxy=… --cluster=<name>`, and `tsh login` has no `--cluster`
  flag — it takes the cluster as a positional argument — so every attempt
  failed with `unknown long flag '--cluster'`.

---

## [0.1.19] — 2026-09-15

### Fixed

- **The first-run tour offer could be spent without ever being answered.**
  Dismissing it with Escape or a click outside counted as a decision, and a
  launch that deliberately did not ask — sessions already restored, or a second
  window — marked it seen anyway. Only *Not now* or finishing the tour settles
  it now; anything else asks again next time. *Help → Take the Tour…* was
  unaffected.

---

## [0.1.18] — 2026-09-15

### Added

- **A guided tour** — *Help → Take the Tour…*, and offered once on a first run.
  Thirteen steps spotlight the real interface and say what each part is for: the
  host list, the filter, quick connect, splits and broadcast typing, the file
  browser, multi-exec, the dock, Teleport, keys and network tools. The app stays
  live underneath, so nothing has to be undone, and Escape leaves at any point.
  A step whose target is hidden — a collapsed sidebar, no Teleport profile —
  centres itself rather than pointing at nothing.
- **Filter a file list by name** (`⌕`, or just start typing with the list
  focused). Plain text matches anywhere; `*` and `?` make it a glob anchored at
  both ends, so `log` finds `mylog.txt` and `*.log` does not. **The arrow keys
  move through the matches from inside the filter box**, and Enter opens the one
  you land on — type, arrow, Enter, without clicking into the list. The status
  bar counts what is held back, hidden files and filtered names separately, and
  a folder that does not match is kept when something expanded inside it does.
- **SSH keys under *Local* in the host list**, beside the local shell and the
  network tools, since "which key am I offering, and does the agent have it?" is
  asked while a host is refusing you. Keys now also show whether they are
  passphrase-protected, where they live, when they changed, and which
  `ssh_config` hosts name them with `IdentityFile`.
- **The agent's own identities are listed.** The view was built from files in
  `~/.ssh` and only used the agent to tag them, so a banner reading "8 keys
  loaded" could sit above three cards and account for none of them — keys from
  the login keychain, a hardware token, another agent, or `tsh login` were
  counted and then shown nowhere. They have their own section, named by cluster
  and user rather than by a raw `teleport:proxy:cluster:user` comment, and the
  two entries `tsh` loads per identity (the certificate and the key it signs)
  are shown as one.
- **`ssh-add` is reachable when it is actually needed.** A footer button runs it
  for the default identities, and the per-key button is offered even when the
  agent is not answering — previously a failed probe hid the one control that
  would have said why. Where there is no OpenSSH client at all, that is now
  reported plainly: `pty.spawn` of a missing binary throws, so it is checked
  first, and `ssh-add`/`ssh-keygen` are resolved through the same search that
  finds `ssh` (which matters on Windows, where none of them are on a GUI
  process's `PATH`).

### Fixed

- **`explorer.js` was binary to `grep`.** Four NUL bytes were written literally
  into a delimiter string instead of as `\0` escapes, so `file` called the
  source "data" and `grep`, `git grep` and editor search silently matched
  nothing in the largest file in the tree. Same value, written as escapes.
- `sm` sized only ghost and icon buttons, so a small primary button beside one
  came out a size larger.

---

## [0.1.17] — 2026-09-15

### Added

- **Quick connect (`⌘⌥C`) — an OpenSSH server that is in no inventory yet.**
  Type `ubuntu@10.0.0.5`, or paste the whole `ssh -p 2222 -i key user@host`
  line out of the ticket you were sent, and pick one of three things:
  - **Test connect** dials once and reports who and what answered, then hangs
    up — the address and the credentials are proved before anything is built
    on them.
  - **A single command** runs and prints its output in the dialog. No terminal,
    no tab.
  - **Connect** opens a session. A command in the box runs at its prompt.

  Nothing reaches `~/.ssh/config` or the profile store; *Save as server…* hands
  the details to the Add-server dialog when it turns out to be a keeper.
  Typing an address into the New session dialog (`⌘N`) offers the same row, and
  the last dozen addresses come back as suggestions.

### Fixed

- **The local automation (MCP) settings were hard to read, dark mode
  especially.** The socket path, token file and `claude mcp add` line were drawn
  in the muted 10.5px treatment meant for a one-line note under a field —
  3.8:1 against the panel, below the 4.5:1 small text needs. They are now a
  proper code box at 12:1, and the panel's prose is 7:1.
- **Reopening a details-dialled host from Recents dropped its port, key and
  jump host** and dialled port 22 instead. Those details are now recorded with
  the session, and two ports on one machine no longer collapse into one entry.

### Changed

- Release notes are cut from this file's entry for the version being released
  rather than being the whole changelog, so the download list is near the top
  of the release page instead of below every version ever shipped.
  `make notes` shows what CI will publish.

---

## [0.1.16] — 2026-09-15

### Changed

- **ServerLife now lives in `gravitational/saleseng` under `tools/serverlife`,**
  and releases are published from there. Tags are prefixed —
  `serverlife-v0.1.16` — so another tool in `tools/` can release without
  colliding, and a tag says what it is releasing. Downloads move with it:
  [releases](https://github.com/gravitational/saleseng/releases?q=serverlife),
  which needs access to that repository.
- `make release` and the install instructions use the prefixed tag; the release
  workflow checks that the tag matches `package.json` before creating anything,
  since a mismatch would name every asset after a different version.

### Fixed

- The macOS install helper reported an empty `signature intact ()` for a
  certificate-signed build: it only looked for the ad-hoc marker. It now names
  the signing authority instead.

---

## [0.1.15] — 2026-09-15

### Automation

- **ServerLife can be driven by an agent.** A bundled MCP server —
  `mcp/serverlife-mcp.mjs` — gives Claude Code and other MCP clients 13 tools
  for the repetitive part of the work: list the inventory, open a **set** of
  sessions in one call, close them, save and load layouts, read Teleport
  cluster state, get a `tsh login` line to paste, and run macros you have
  saved. Off until you turn it on: Settings → *Local automation (MCP)*, which
  also hands you the `claude mcp add` line.
  - The socket lives in your own runtime directory at mode `0600` (a named pipe
    on Windows), every connection must present a token only you can read, and
    each accepted call appears in the status bar.
  - **There is no verb that runs a command of the caller's choosing.**
    `run_macro` runs a macro you wrote and can read, and that is as far as it
    goes. Nothing types into a session, reads its output, or moves files.
  - [MCP.md](MCP.md) documents the tools, the bridge paths per platform, the
    socket protocol for writing your own client, and what it deliberately
    cannot do.

### Fixed

- **Downloading a file into the root of a Windows drive failed.**
  `fs.mkdir(dir, { recursive: true })` is a no-op for a directory that already
  exists — except at a drive root, where it raises `EPERM`. Since the parent of
  `C:\file.txt` *is* `C:\`, every download there died before a byte moved.
  Local directory creation now recognises the paths that cannot be created
  (`/`, a drive, a UNC share root) and treats "already there" as success.

### Documentation

- **The macOS install instructions were wrong.** They recommended
  Control-click → *Open*, which Apple removed in macOS 15 for unnotarised apps;
  what you actually get is "Apple could not verify ServerLife is free of
  malware", with *Move to Trash* as the default button. Install now leads with
  the fact that the builds carry no developer certificate and gives each
  platform its own steps, including both macOS routes that work and how to
  recover if the app has already been trashed.
- **`tools/install-mac.sh`** does the macOS install in one command — copy,
  clear the quarantine flag, verify the signature — and ships as a release
  asset, so installing a DMG needs no clone of the repository.
- **[UNINSTALL.md](UNINSTALL.md)** — removing the app and, step by step,
  everything it wrote, with what to leave alone (`~/.ssh`, `~/.tsh`).
- Requirements corrected: Teleport nodes no longer need an `ssh` client.

### Build

- The release actions are pinned to current majors; `checkout@v4` and
  `setup-node@v4` declare the retired `node20` runtime and warned on every run.

---

## [0.1.14] — 2026-09-15

### Sessions

- **A machine with no ssh client can still reach Teleport nodes.** The OpenSSH
  client is an optional feature on Windows and absent on plenty of machines;
  where it is missing, a Teleport node now opens over `tsh ssh` instead of
  failing. `tsh` dials the node itself, carries its own MFA and serves the file
  browser through the same channel, so nothing is lost but the shared
  connection. Multi-exec takes the same route. A plain ssh_config host has no
  such path and says so — "No OpenSSH client found on this machine, and a plain
  SSH host needs one" — rather than dying on a spawn error.
- **ssh is looked for where it actually lives**: `System32\OpenSSH`,
  `Program Files\OpenSSH`, the copy inside Git for Windows, then `where ssh`.
  Its directory is added to the environment of anything spawned, since a GUI
  process rarely has it on PATH.

### Teleport

- **Log out of one cluster.** `tsh logout --proxy=…` drops that certificate and
  leaves every other profile alone — on each profile row in the Teleport tab,
  and on the right-click menu of a cluster in the host list. The confirmation
  names the tsh home and the user, and says that open sessions may stop working.
- **Clusters can be saved for logging back into.** Logging out removes a cluster
  from every list, its proxy address included, so there is nothing left to log
  back into. A saved record keeps the proxy, cluster, user, connector and tsh
  home: *Save cluster* on a profile row, a **Saved clusters** list in the
  Teleport tab (shown even when nothing is logged in, which is when it matters),
  and a *Keep this cluster* option on both the login and logout dialogs.

### Fixed

- **A stray "null" in the tsh login dialog**, above *Additional flags*, whenever
  no tsh homes were configured. A conditional child passed to `append()` is
  rendered as the text "null"; `el()` drops it, and this now does too.
- **Without `ssh -G`, every ssh_config host disappeared** — the aliases are
  resolved through ssh, and with no ssh the list looked empty. The config file
  is now read directly as a fallback, wildcard `Host` blocks included, which
  reproduces `ssh -G` for the ordinary Host/HostName/User/Port case.
- **Correcting a tool path needed a restart.** Whether tsh and ssh were found is
  re-read on every inventory refresh.

---

## [0.1.13] — 2026-09-15

### Fixed

- **Windows could not find tsh, so no Teleport cluster was ever listed.** Every
  path the app looked in was a macOS one, leaving a bare `tsh` to be resolved
  through `PATH` — where no Teleport installer puts it. Teleport Connect keeps
  it under `%LOCALAPPDATA%\Programs\teleport-connect\resources\bin`, the
  standalone package in `C:\Program Files\Teleport`. With nothing to run,
  `C:\Users\<you>\.tsh` was never read and a machine with live logins looked
  as though Teleport had never been installed. Those locations are now searched
  (along with chocolatey, scoop, and `where tsh`).
- **The PATH handed to tsh was built with POSIX separators**, so on Windows the
  last entry of the real `PATH` was corrupted by having `:/usr/local/bin`
  appended to it.
- **"tsh: not logged in" was shown when tsh was missing entirely**, which sends
  you off to run a login that was never the problem. A missing binary now says
  so — in red — and the Teleport list offers *Locate tsh…*.

### Teleport

- **Locate tsh…** in Settings (and from the Teleport list when it is missing):
  point the app at the binary yourself, with a file picker and a list of
  everywhere it looked.

### Build

- **Each platform publishes its builds straight to the release.** They used to
  be parked as Actions artifacts for a final job to collect — a second copy of
  every build, ~1.9 GB a run, held against the storage quota. When that quota
  filled, 0.1.12 built successfully on all four platforms and shipped nothing.
  Release assets are a separate store, so this path cannot fill up the same way,
  and `SHA256SUMS.txt` is now computed from the files people actually download.

---

## [0.1.12] — 2026-09-15

### Teleport

- **More than one tsh home.** `tsh` keeps who you are under a single
  `TELEPORT_HOME`, which means one identity per cluster — awkward if you hold
  two logins to the same cluster, or keep work and personal clusters apart.
  *Settings → Teleport homes* takes a list of directories instead: every one of
  them is read for clusters, and each profile remembers where it came from.
  Order is precedence when two homes offer the same proxy, and adding your first
  extra directory brings the default along so nothing already on screen
  disappears.
- **Every tsh command runs in its own home.** Not just `tsh ssh` — node
  inventory, access requests, recordings, `tsh scp`, `tsh proxy aws` and
  `tsh play`, and also the plain `ssh` processes, since a Teleport node reached
  over OpenSSH goes through `tsh proxy ssh` from the generated config. Each home
  gets its own generated `ssh_config`. Where a proxy alone would be ambiguous,
  the call carries its home explicitly.
- **The same cluster in two homes is two clusters.** Sidebar groups are per
  profile and badged with the home they came from, nodes from a non-default home
  carry it in their id — so hidden hosts, remembered logins and the MFA list you
  already have keep working — and recent connections, saved profiles and the
  recordings cluster picker all record and honour it.
- **Copy login cmd.** On every Teleport profile row, on an expired cluster in
  the sidebar, and in the login dialog: the exact `tsh login` as a line to paste
  into a terminal, `TELEPORT_HOME=` included when the profile is not in the
  default home — without it the command would write the certificate where
  nothing looks for it. For the logins that only complete in a real terminal: a
  hardware key that wants a TTY, an SSO flow already open in a browser.
- **The login dialog asks which home** when more than one is configured, so
  *Add cluster…* cannot quietly log into the wrong directory. Its preview, its
  copy button and the login it runs are now the same string.

### Build

- Release build artifacts expire after a day instead of ninety. The release job
  downloads them to publish the assets, so they were a second copy of every
  build — 1.9 GB per run — held against the Actions storage quota for nothing.

---

## [0.1.11] — 2026-09-14

### Sessions

- **New session remembers where you have been.** The launcher opens with a
  *Recent* list at the top — newest first, one row per destination, with who you
  logged in as and how long ago. It is built from the session history rather
  than a second list, so the memory is already there for hosts you connected to
  before this release, plain SSH included. An attempt that failed keeps its
  place, marked, since those are the ones worth another go. How many are kept is
  a setting: off, 5, 10, 20 (the default) or 50.
- **A scene plays while a session dials.** Thirty of them rotate — robots,
  pneumatic tubes, a carrier pigeon, a satellite relay, snail mail, a
  hamster-powered link — each a courier crossing from this machine to the
  server over a pipe, rails, a wire or waves. *Settings → While a session
  connects* pins one or turns them off, and a machine asking for reduced motion
  gets the scene standing still.
- **Panes can be moved inside a tab.** Right-click a pane → *Move this pane*, or
  ⌘⇧ with an arrow key. It trades places with the pane in that direction; when
  there is none, it is pulled out and laid along that whole edge, which is how a
  stacked pair becomes side by side.
- **Files-only sessions can open beside the pane you are in.** The host menu's
  *Open files only* now offers a new tab, a split to the right, or a split below,
  so a file browser can sit next to the shell you are already working in.

### Sidebar

- **The groups can be rearranged.** Drag a heading — Local, SSH config, each
  Teleport cluster — or right-click it for *Move up / down / to top / to bottom*.
  The order is remembered, and a cluster you log into later falls in behind what
  you have arranged rather than pushing it around.

### Files

- **Get info on a folder.** Right-click anything in a file browser: type,
  permissions, owner, timestamps and what is directly inside. The recursive
  total sits behind a button, because adding up a deep tree is a real walk of
  the filesystem — locally, `du` on a server, a prefix count in a bucket. It
  works on files and on S3 objects too.

### Macros

- **A macro can repeat on a timer.** Set an interval in the editor, or pick
  *Repeat every…* from any macro in the pane menu, and it retypes itself into
  that session until stopped. Only commands that finish can repeat — following a
  log or pasting without Enter cannot. A repeat belongs to its pane: the ▶
  button glows while one is running, the menu offers to stop it, and closing the
  pane takes its timers with it.
- **`tsh status` is a built-in macro.** Which cluster the host is logged into, as
  whom, with what roles, and how long the certificate has left.

### Fixed

- **Dropping a file into a bucket did nothing.** A bucket's root prefix is the
  empty string, and the drop handler read that as "no destination" and gave up
  — so every drag into a bucket at its top level was silently ignored. Dragging
  from Finder into a bucket works now too.
- **Server-to-bucket transfers silently produced nothing.** The renderer chained
  a queued download into an upload, and a queued transfer returns as soon as the
  job is registered, not when the bytes land — so the upload read files that had
  not arrived yet. Server↔bucket and bucket↔bucket now relay inside the main
  process, where the SFTP transfer is awaited properly, and the scratch
  directory is removed whether or not it succeeds.
- **Switching to a bucket left the previous path on screen.** The path bar is
  shared by every source, so a local directory stayed visible while the bucket
  loaded, reading as though the bucket had folders it did not.

---

## [0.1.10] — 2026-09-14

### Files

- **Move files between buckets, servers and this machine.** Drag between two
  file panes, or right-click objects → *Copy to another pane…*, which avoids
  the precision dragging needs. Local↔S3 is one hop; a server and a bucket have
  no way to reach each other, so those are relayed through this machine and say
  so rather than looking direct. Bucket→bucket is relayed the same way.
- **A local shell can be opened beside or below the current pane.** The Local
  shell row was the only one in the sidebar with no right-click menu, so there
  was no way to put a local pane next to a session — it now offers the same
  splits every host does, plus *Show local files in this pane* for browsing a
  bucket and the local disk together.

---

## [0.1.9] — 2026-09-14

### S3

- **Register S3 buckets** under *Saved → S3*, beside profiles and macros. Each
  one becomes a source in every file explorer's dropdown, so a bucket sits
  alongside your sessions and the local machine.
- **Four ways to get credentials**, in the order worth reaching for them:
  - **Teleport** — pick an AWS application and IAM role, and `tsh proxy aws`
    mints throwaway credentials per session. Nothing long-lived is stored, and
    every call is re-signed by Teleport and lands in the cluster's audit log.
  - **An AWS profile on this machine** — whatever `~/.aws` already holds: SSO,
    an assumed role, a `credential_process` hook or a static key. The AWS CLI
    resolves the profile, so the whole provider chain works rather than a
    re-implementation of part of it.
  - **Environment variables**, optionally under a prefix so several buckets can
    use different ones.
  - **A stored access key**, last because it is the only one that puts a
    long-lived secret on disk — and even then it is encrypted with the OS
    keychain, or refused if the machine has none.
- **Browse buckets to pick one**, rather than typing a name, and the region is
  detected rather than asked for. A bucket in another region corrects itself:
  S3 names the right region in a header, so the request is retried there.
- **Move files both ways.** Download objects to a folder you choose, upload
  files into the current prefix, delete, copy a key, and re-tier an object.
- **Choose the storage class on upload** — Standard, Intelligent-Tiering,
  Standard-IA, One Zone-IA, Glacier Instant, Glacier Flexible, Deep Archive or
  Reduced Redundancy — defaulting to whatever the bucket was registered with.
  An object's class can be changed afterwards too.
- Signature V4 is implemented directly rather than pulling in the AWS SDK, and
  is checked against AWS's own published test vectors.

### Sessions

- **Open a server as files only**, with no terminal — right-click a host →
  *Open files only*. It is the same single ControlMaster as ever; the file
  browser simply becomes the whole tab.

---

## [0.1.8] — 2026-09-14

### Windows

- **As many windows as you want.** *Session → New Window* (`⌘⌥N`), or the
  button on the start page. Each window has its own tabs, panes, sidebar and
  file browsers; connections are shared, so a host already dialled is not
  dialled twice.
- **Each window is remembered separately**, and reopening offers them all back
  at once — "Reopen your last session?" now says how many more windows come
  with it, and answering once brings back the lot, each layout landing in the
  window it came from. A window you closed on purpose does not return.
- **Windows are named after what is open in them**, so the Window menu lists
  `web-01, db-02` rather than ServerLife three times.

### File browser

- **Names survive longer before being cut.** The name column now has a floor;
  the size and date give up their space first and drop out entirely on a narrow
  pane, instead of every name being squeezed into an ellipsis. At 270px only
  21 of 309 names clipped, where the date alone had been taking 86px.
- **Dates line up.** `fmtDate` pads every date to the same width, but the
  column collapsed that padding, so nothing aligned. Every date now shares one
  left edge, and every size one right edge.
- **Sort by name, size or date.** The explorer always sorted internally but
  never let you say how; there is now a control in its toolbar, with the
  active key marked and a click on it to reverse. Each explorer remembers its
  own, so two panes can be ordered differently.

### Interface

- The four start-page buttons carry icons.

---

## [0.1.7] — 2026-09-14

### Macros

- **Macros work on a local shell** too — the ▶ button is on every pane, not
  just remote ones.
- **Categories are yours to arrange.** A macro's category is free text, and the
  headings in *Saved → Macros* carry arrows to move a category up or down, so
  the ones you wrote can sit above the built-ins. Anything not yet placed falls
  in behind what is, so a new category never needs the order updating first.
- **Paste without pressing Enter.** A macro can be marked to land at the prompt
  and wait, for the ones you mean to finish by hand. The default is unchanged:
  it runs. Such a macro is kept out of multi-exec and out of headless runs,
  where "edit it first" cannot mean anything.

### Settings

- **Export and import.** *Saved → Export all…* writes profiles, folders,
  macros, snippets, saved access requests, layouts and preferences to one JSON
  file; *Import…* reads it back on another machine. Macros alone can be
  exported from the Macros tab. Import shows what the file holds and asks
  before applying: **merge** adds what is new and matches on id, so importing
  twice changes nothing; **replace** makes the machine match the file, and asks
  again first. Nothing secret travels — the store holds aliases, key *paths*
  and cluster names, never passwords or keys.
- **Skins.** Nine of them, over and above the dark/light theme and accent:
  Party, Halloween, Christmas, Winter, Valentine, Shamrock, Fireworks,
  Synthwave and Matrix. A skin repaints every colour token, and terminals read
  their palette back out of those tokens, so they follow without each skin
  having to restate sixteen ANSI colours.

### Fixed

- **Hiding a file explorer hid every one of them.** `⌘E` and the toolbar button
  swept every pane in the app. They now act on the focused pane; the tab-wide
  and app-wide sweeps moved to the button's right-click menu, where they cannot
  be hit while aiming at one pane.

---

## [0.1.6] — 2026-09-14

### Macros

- **Macros** — commands aimed at a host, under *Saved → Macros*. The Saved tab
  now has a **Profiles / Macros** selector above the filter box, and the filter
  searches macro names, descriptions and commands.
- **A starter set of 16**, because an empty list teaches nothing. Teleport:
  service status, follow the agent log, errors in the last hour, version,
  config, and a restart. System: disk usage (with inodes, for when a disk is
  "full" but is not), what is filling `/var`, memory and load, top processes,
  listening ports, recent errors, who is logged in, addresses and routes, OS
  and kernel, and whether a reboot is pending. They live in code rather than
  being seeded into your settings, so they improve between releases; hide the
  ones you do not want, and restore them later.
- **Running one.** Double-click sends it to the focused terminal. With nothing
  focused it offers to run on a host you pick and shows the output in a dialog,
  so a macro is useful before you have a session open. Macros that change
  something — *Restart Teleport* — are marked and ask first. Ones that follow a
  log are never run headless, where they would simply hang.
- **Macros in multi-exec.** The dock now has **Command** and **Macros** tabs:
  the same macros, run across every selected host, sharing the run-as login and
  host selection rather than a second form. Log-followers are left out.
- **A macro button on every session.** The pane header carries a ▶ button that
  drops down the macro list, grouped by category, and runs the one you pick on
  that host — it is the host already in front of you, so nothing has to be
  chosen twice. `⌘⇧R` opens the same menu on the focused pane.

### Network tools

- **A general network tools panel** (`⌘⇧T`, *Session → Network Tools…*). One
  target — a host, `host:port` or URL — and nine tools against it, so several
  can be run in a row without retyping: **ping**, **traceroute**, **DNS**
  (A/AAAA/CNAME/MX/TXT/NS/SRV, plus PTR for an address), **port check**,
  **TLS certificate**, **HTTP**, **whois**, **Teleport cluster**, and **this
  machine**'s interfaces and resolvers.
  - The **port check** colours each result open, closed, filtered or errored
    with the time it took; a target written `host:port` checks that port, and
    it is deliberately one host at a time with a 32-port ceiling.
  - **TLS** reports what the server actually presents, valid or not — chain,
    protocol, cipher, SANs, fingerprint and days remaining, with a warning
    under three weeks.
  - **HTTP** shows status, timing, size, the redirect chain and every response
    header, with the first 2 KB of body folded away.
  - Nothing runs through a shell: external commands get an argument array and
    every target is validated first.
- **Teleport cluster information** — *Teleport → Cluster Information…*, or
  **Cluster info** on any profile, reads the proxy's `/webapi/ping` and lays it
  out: cluster name, version, minimum client, edition, FIPS and managed-update
  settings; the auth connector in play with its display name, second factor,
  passwordless and session TTL; and every proxy listener including Kubernetes
  and database addresses and whether TLS routing is on. The raw document is
  one click away, so fields this build has never heard of are not lost. It
  needs no credentials, which makes it the one thing you can always ask a
  cluster.

---

## [0.1.4] — 2026-09-13

0.1.3 was tagged but never published, so its section below ships here too.

### Access requests

- **Timing.** A request can now say when it takes effect and how long
  everything lasts, rather than silently taking the cluster's defaults:
  *takes effect* (`--assume-start-time`), *request expires*
  (`--request-ttl`), *access lasts* (`--max-duration`) and *session expires*
  (`--session-ttl`). The start time defaults to **now** and is only sent once
  you move it into the future — immediate is Teleport's own default, and a
  start time in the past is at best redundant. Durations autocomplete from the
  usual values but accept anything `tsh` does.
- **Suggested reviewers** (`--reviewers`), optional and comma separated. The
  cluster still applies its own review rules.
- **The exact command, foldable.** The argv is built in one place and shown
  back, so what you read is what runs. It stays collapsed behind *tsh command*
  — it is there to be checked, not read — with **Copy** in the summary so it
  works without expanding.
- **Copy to new request.** Opens the form prefilled from an existing request.
  Its timings come back as the absolute instants Teleport resolved them to,
  which cannot be replayed — a request raised tomorrow cannot expire last
  Tuesday — so they are turned back into durations measured from when the
  original was created.

### Fixed

- **A request's expiry never displayed.** It was read from
  `metadata.expires`, which Teleport does not set; all four timings live on the
  spec. Requests now show when they take effect, when they expire, how long
  access lasts and when the session ends, each with a relative time.

---

## [0.1.3] — 2026-09-13

Tagged but never published; its changes ship as part of 0.1.4.

### Access requests

- **Copy an existing request to a saved one.** *Save as reusable…* on any
  request — pending, approved or expired — keeps its resources, roles and reason
  under a name you choose, defaulting to the original reason. The access you had
  to ask for once is usually the access you will have to ask for again, and by
  then the original has dropped off the list. Resources are stored under the
  names they resolved to, so the entry stays readable even though it is the id
  that gets raised.

---

## [0.1.2] — 2026-09-13

### Access requests

- **Browse what you can actually request.** *Requests → New request → Browse…*
  lists everything `tsh request search` reports for the cluster — servers,
  applications, databases, Kubernetes clusters, desktops and the rest — by name,
  with their labels, filterable as you type. This is a different set from the
  hosts in the sidebar, and deliberately so: an access request is for a resource
  you **cannot** see yet. On one demo cluster `tsh ls` returns 3 nodes while 13
  are requestable.
- **Resource names instead of UUIDs.** A request names servers by UUID, which is
  useless when deciding whether to approve one. Requests now show
  `node/a4232-monitoring` rather than
  `node/d68f45ed-cbe5-433b-9eab-f8400966da4f`, resolved through
  `tsh request search` — which, unlike the node inventory, also covers resources
  not yet granted. The raw id stays in the tooltip. Unresolvable resources keep
  their id rather than failing the listing.
- **Requestable roles** are offered as a checklist from `tsh request search
  --roles`, instead of being typed from memory.
- **Save a request and raise it again.** A chosen set of resources, roles and
  reason can be saved under a name against its cluster, then loaded back from
  *Saved…* — for the access you end up asking for every time. Saved entries are
  matched on cluster as well as proxy, so re-logging in does not orphan them.

### Fixed

- **Requests for more than one resource failed.** The resource ids were joined
  with commas into a single `--resource=` flag, but `tsh` declares that flag as
  repeatable and read the whole string as one malformed id — `a,b is not a valid
  ResourceID string`. Each resource is now passed as its own flag.
- **Submitting a request appeared to fail.** `tsh request create` blocks until a
  reviewer resolves the request, so the dialog waited until the two-minute
  timeout and then reported an error for a request that had in fact been
  created. It now passes `--nowait` and the request shows up as PENDING, which
  is the truth.

---

## [0.1.1] — 2026-09-13

### Teleport tags

- **Tags on Teleport hosts.** Every label a node carries — both the static ones
  and the dynamic command labels like `uptime` — is now visible in the sidebar.
  **Show tags** lists them under each host as `key = value` chips; with it off,
  a host's most telling label is summarised on the row (`dev +9`), where the
  `tunnel` badge used to be the only thing shown. The host's name keeps its
  width either way — the badge truncates first, and only one is drawn.
  Hovering a host shows the full set,
  and right-click → *Tags…* lists them all, including Teleport's internal
  labels, with a copy button.
- **Search by tag.** The host filter understands labels rather than just
  matching text:

  | Query | Matches |
  |---|---|
  | `env=prod` | label `env` is exactly `prod` |
  | `env:pro` | label `env` contains `pro` |
  | `env=prod,staging` | either value — a label holds one value, so a second can only mean *or* |
  | `env=prod*` | glob |
  | `env:` | has an `env` label at all |
  | `tag:gpu` | any label key or value contains `gpu` |
  | `cluster=corp` | a non-label field: name, host, cluster, addr, proxy, type, tunnel |
  | `-env=dev` | exclude |

  Terms combine with AND, quotes hold values with spaces together, and a key
  written without its prefix still finds it — `location=east` matches
  `aws/location`. Anything that only looks like a query (`10.0.0.1:3022`) still
  matches as plain text.
- **Browse the tags you have.** *Tags…* opens every label in the inventory
  grouped by key, with a count per value; clicking one filters the list, and
  clicking a second value of the same key widens the filter instead of
  contradicting it. The filter box also autocompletes known `key=value` pairs,
  and shows how many hosts survived the query.
- **Click a tag to filter by it** from any host row, and click it again to
  remove it.
- Teleport labels now appear in the **Server profile** dialog, beside what the
  machine reports about itself.

---

## [0.1.0] — 2026-09-13

First release. A maximum SSH-style desktop interface for macOS, Linux and
Windows that treats Teleport and plain SSH as the same thing.

### Connections

- **Teleport and plain SSH side by side.** Nodes from every logged-in `tsh`
  profile and every `Host` entry in `~/.ssh/config`, in one list.
- **One authentication per host.** Each connection opens a single OpenSSH
  ControlMaster; terminals, the file browser, tunnels and multi-exec all ride
  it. MFA taps, passwords and key passphrases are asked once, in the UI.
- **Interactive auth surfaced.** Password, passphrase and Teleport MFA prompts
  appear in the connecting pane with an input box.
- **Tabs and split panes.** Split the same host (`⌘⇧D` right, `⌘⇧E` down) or a
  **different** host (`⌘⌥D` / `⌘⌥E`), so two servers sit side by side or one
  above the other in one window.
- **Broadcast typing** (`⌘⇧B`) sends keystrokes to every pane in a tab.
- **Agent forwarding** (`-A`) and **compression** (`-C`) per connection.
- **X11 forwarding** (`-X` untrusted or `-Y` trusted) for `xeyes`, `xclock` and
  other graphical programs, over Teleport or plain SSH.
- **Per-session MFA.** Nodes that demand MFA per session are dialled with
  `tsh ssh`, so the prompt lands in the terminal you are looking at. The MFA
  method is chosen explicitly (Touch ID by default) because tsh's automatic
  mode can pick one that fails in a spawned process and consume the challenge.
  When the shared-connection path fails on such a node the failure is
  recognised and the MFA transport is offered, rather than a futile retry.
  **The file browser works on these nodes too**: `tsh ssh` runs the remote
  `sftp-server`, giving a real SFTP channel for one approval — requested
  explicitly, so it never races the terminal's prompt. Hosts that need MFA are
  remembered (with a badge) and can be un-marked; a cancelled ceremony offers
  retry, security key, OTP, browser, or the command to run elsewhere.
- **Session logging** (`⌘⇧L`) tees a terminal to a file with escape sequences
  stripped.
- **Layouts.** Save the current arrangement under a name, load one back, and
  mark one as the default that opens at launch. The last session is also
  remembered automatically and offered back — never reopened silently, because
  reopening dials real servers.

### Servers

- **Add a server** (`⌘⇧N`) with hostname, user, port, key, jump host and extra
  `ssh` options, and a **Test connection** button that dials it before you
  commit. Write it to `~/.ssh/config` — inside a marked block, backed up first,
  refusing to shadow your own entries — or keep it to ServerLife, where the
  details ride on the `ssh` command line instead.
- **Run a command** on a single host from its context menu, with stdout, stderr,
  exit status and duration, without opening a session.

### Commands

- **Snippets.** Save the commands you actually repeat, then send one into the
  focused terminal or into every pane in the tab at once. Save the terminal
  selection as a snippet directly from its context menu.
- **Startup commands** per saved profile, with remote and local start
  directories.

### Files

- **Real SFTP**, spoken directly over the multiplexed connection — a protocol
  implementation, not a wrapper around the `sftp` command.
- **Scrollback search** per pane, in the header beside the host name: live
  match count, every hit highlighted across the buffer, `⌘F` to focus.
- **Expandable tree.** `+` / `−` opens directories in place; arrow keys walk
  the tree, `←` and `→` collapse and expand.
- **Go to a path** button with quick places and this pane's recent directories.
- **An explorer per session.** Every terminal pane carries its own file
  explorer beside it (or above it — `⌘⇧P` switches), so two open sessions each
  show their own filesystem. `⌘E` shows or hides them all; each pane has its
  own toggle too.
- **Local files without leaving the session** (`⌘⇧F`): the local filesystem
  opens *below* the session's files in the same pane, both visible at once —
  drag between them to upload or download.
- Each explorer can be re-pointed at the local machine or any other open
  session from its dropdown.
- **Background refresh** every 5 seconds (configurable, or off) so files
  created outside the app appear on their own, without losing your selection,
  expanded folders or scroll position.
- **Drag between two servers.** Dragging files from one server's pane to
  another's transfers them directly where the cluster allows it, and relays
  through this machine otherwise — after saying which, and asking.
- **Server-to-server copy** also available from the context menu.
- Drag from Finder to upload; drop onto a folder row to target that folder.
- **Transfer queue** with progress, rates, file counts and cancellation, and an
  explicit status-bar confirmation when a transfer finishes or fails.
- Rename, recursive delete, `chmod`, new folder, inline text editor.
- **Follow the terminal's directory** so the browser tracks where you `cd`.

### Fleet

- **Multi-exec.** Run one command across many hosts concurrently, with per-host
  output, exit codes and timings.
- **Save and load runs as YAML** — the command plus its host list, in a
  readable, diffable file. Results export to YAML too.
- **Ansible export.** Turn a multi-exec selection into a runnable bundle:
  inventory, playbook, `ansible.cfg`, and the generated `tsh` ssh_config.
- **Port forwarding.** Local (`-L`), remote (`-R`) and dynamic SOCKS (`-D`)
  tunnels created on the live connection, listed and closable.

### Teleport

- **Several profiles at once**, with expiry shown and one-click switching.
- **Full `tsh login` dialog**: proxy, user, auth connector, cluster, TTL and
  MFA mode, with a live preview of the command it will run.
- **Access requests**: list, view, create, assume approved roles, and drop them.
- **Session recordings**: browse them (`⌘⇧Y`, or per host from its context
  menu), replay in a tab with `tsh play`, or open in the Teleport web UI.
- **Search recorded sessions** for a word or pattern across a time range,
  with matching lines in context, and optional download of every transcript.
- **Connection history** covering plain SSH too, which Teleport's audit log
  never sees.

### Keys and hosts

- **Key management**: list `~/.ssh` keypairs with fingerprints, flag private
  keys with permissions sshd will ignore, and see what the agent holds.
- **Generate keys** (Ed25519, ECDSA, RSA) and **install a public key** on any
  connected server — `ssh-copy-id` over the connection already open.
- **Forget a host key** to clear the "REMOTE HOST IDENTIFICATION HAS CHANGED"
  wall after a rebuild.

### Interface

- Saved profiles with folders, startup commands and start directories.
- Light, dark and automatic themes, plus seven accent colours.
- Hide hosts you never use; show them again on demand.
- Server profile panel: distribution, kernel, architecture, CPU, memory, disk,
  virtualisation, init system and package manager.
- An idle animation of servers orbiting a core, until the first session opens.

[0.1.0]: https://github.com/stevengravy/serverlife/releases/tag/v0.1.0
