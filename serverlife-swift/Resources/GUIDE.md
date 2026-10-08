# The ServerLife guide

**What everything in the app does.** The README is for getting it built and
installed; this is the reference for using it — every panel, every menu, and
the reasoning where the reasoning matters.

It is also *in* the app: **Help → Guide** (or `⌘/`) opens this same text with
a section list and a search box, because the moment you want it is while you
are looking at the thing you are asking about.

---

## Contents

- [Sessions and connections](#connections)
- [The file browser and transfers](#file-browser-and-transfers)
- [Starred hosts and folders](#starred-hosts-and-folders)
- [Folders in the host list](#folders-in-the-host-list)
- [What a host remembers](#what-a-host-remembers)
- [Keyword highlighting](#keyword-highlighting)
- [Local shells](#local-shells)
- [tmux: sessions that outlive the window](#tmux)
- [Consoles and screens: serial, telnet, VNC and RDP](#consoles-and-screens)
- [Saving what you are looking at](#saving-what-you-are-looking-at)
- [Adding servers](#adding-servers)
- [Running one command](#running-one-command)
- [Command snippets](#command-snippets)
- [Macros](#macros)
- [Fleet operations](#fleet-operations)
- [Port forwarding](#port-forwarding)
- [X11 forwarding](#x11-forwarding)
- [Per-session MFA](#per-session-mfa)
- [Keys and known hosts](#keys-and-known-hosts)
- [Teleport](#teleport)
- [Beams](#beams)
- [Windows](#windows)
- [S3](#s3)
- [Network tools](#network-tools)
- [Interface](#interface)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)

---

## Connections

**Both kinds of host, one list.** Teleport nodes from every logged-in profile
appear grouped by cluster with their labels; SSH config hosts appear below.
Nothing needs to be registered with the app first.

**Quick connect** (`⌘⌥C`) for a server that is in no inventory yet. Type
`ubuntu@10.0.0.5`, or paste the whole `ssh -p 2222 -i key user@host` line from
the ticket you were sent, and get three choices: **Test connect** dials once and
reports who and what answered, a **single command** runs and prints its output
in the dialog without opening a terminal, and **Connect** opens a session.
Nothing is written to `~/.ssh/config` or saved as a profile — *Save as server…*
is there when it turns out to be a machine you keep. The New session dialog
(`⌘N`) offers the same thing for an address typed into its search box.

**The servers you quick-connected to before** are listed under the field, one
click each. They were always remembered, but only inside the field's own
dropdown — behind the little arrow nobody presses — so the address you used an
hour ago was effectively hidden. *Forget* drops the list. Only addresses are
kept: an identity path travels with one, and nothing that could be a secret is
ever written down.

**One authentication per host.** Opening a session creates a single
ControlMaster. Every terminal, file operation, tunnel and remote command after
that reuses it. Interactive prompts — password, key passphrase, Teleport MFA —
appear in the connecting pane with an input box, once.

**Two servers side by side, or stacked.** Sessions are tabs, and any tab splits
into panes. `⌘⇧D` / `⌘⇧E` split with the *same* host; `⌘⌥D` / `⌘⌥E` (or
right-click a host → *Open beside current*) split with a **different** one — so
two servers sit next to each other horizontally, or one above the other.

**The tabs say what each session is doing.** Beside the connection dot, three
small bars **ripple while output is arriving** — so the tab running the build
is findable without clicking through the strip. If a session stops at
something that has to be answered — `[sudo] password for…`, a `[Y/n]`, *Press
enter to continue*, an MFA code, or **a coding agent asking permission**
(`Do you want to proceed?` above its numbered options) — the bars give way
to an amber **?** and the tab itself turns amber. That is the one worth going to: it is not
slow, it is waiting for you, and it will wait all afternoon.

Never on the tab you are looking at: the output is already in front of you,
and an animation beside it would only be movement in the corner of your eye.
The marks appear the moment you switch away. Nothing moves in the strip
either — the space is reserved whether or not anything is shown in it, so
tabs and the **+** stay where they are.

Nothing is asked of the shell to work any of this out. Whether output is
arriving is read from the stream on its way to the terminal; whether
something is being asked is read from the **screen**, because a full-screen
program — an editor, a pager, an agent drawing a box — paints by moving the
cursor about, and the end of the stream is whichever line it redrew last
rather than the bottom of what you can see. A question counts only while the
thing asking it is still on screen, so a prompt you have answered, or a log
that happens to contain the words, leaves the tab alone. *Settings → Show
what each tab is doing* turns the whole thing off.

**Panes can be dragged where you want them.** Pick a pane up by its header
and drop it on another pane in the same tab to **swap** the two, on a tab in
the strip to **move it into that tab**, or past the last tab to give it a
**tab of its own**. Drag it clean out of the window and it gets a **window of
its own** — *Move to its own window* in the pane's menu does the same thing
for anyone who would rather not aim. Nothing restarts and nothing
reconnects: the connection and the shell live in the app's core, so the
session, its scrollback and whatever is running come along. A pane handed to
a new window keeps the text that was on screen, and the shell on the far
side never knows it moved.

**Broadcast typing** (`⌘⇧B`) sends your keystrokes to every pane in the current
tab — the "same command on four servers" trick, without scripting it.

**Local shell tabs** (`⌘T`) for when you need your own machine.

**Agent forwarding, compression and X11** are per-connection options, and
**session logging** (`⌘⇧L`) tees a terminal to a file with escape sequences
stripped so the log is readable afterwards.

**Your layout comes back.** The open sessions and their arrangement are saved,
and offered back next launch. Reopening dials real servers, so it is always an
offer — never silent.

## File browser and transfers

The browser speaks **SFTP directly over the multiplexed connection**. It is a
protocol implementation, not a wrapper around the `sftp` command, so filenames
with spaces, exact sizes, permissions and timestamps are all correct.

- **Scrollback search** in each pane header, beside the host name: type and
  every match highlights across the whole buffer with a live `3/17` counter.
  `⌘F` focuses it (and picks up the current selection), Enter and Shift+Enter
  step through, Escape clears.
- **Filter by name** (`⌕`, or just start typing with the list focused). Plain
  text matches anywhere; `*` and `?` make it a glob anchored at both ends, so
  `log` finds `mylog.txt` and `*.log` does not. **The arrow keys move through
  the matches from inside the filter box** and Enter opens the one you land on,
  so finding a file is type, arrow, Enter — without clicking into the list.
  Escape clears it. A directory that does not match itself is kept when
  something expanded inside it does, and the status bar always says how many
  entries the filter is holding back.
- **Column headings you can sort by.** A thin strip above the list — *Name*,
  *Size*, *Date*, plus *Mode* and *Owner* when the details columns are on.
  Click one to sort by it, click it again to reverse, and the arrow says
  which is in force. The ⇅ button and its menu still work; this is the same
  sort where everybody expects to click. Ordering is **case-insensitive and
  numeric**, so `Downloads` sits next to `docs` and `node-2` comes before
  `node-10`. Folders always sort before files, and anything that ties on size
  or timestamp falls back to the name so the list never reshuffles itself.
- **Expandable tree.** `+` and `−` open directories in place. Arrow keys walk
  the tree; `←` and `→` collapse and expand. Double-click navigates into a
  folder instead.
- **Go to a path** (`⌖`) jumps straight somewhere — type it, or pick from quick
  places (`/var/log`, `/etc`, `/tmp`, web root, systemd units) and this pane's
  recent directories.
- **It shares the pane with the terminal**, so showing it costs the terminal
  those columns — about 36 at the default width. Drag the divider to change
  the split, or put the explorer **above** the terminal instead (the ▤
  button), which gives the terminal the full width back and takes the height
  instead. Whatever you drag it to is what it reopens at.
- **Two explorers at once.** Each pane independently shows the local machine,
  the focused session, or any other open session — and they arrange **stacked
  or side by side** (the ▤ button).
- **Drag between two servers.** Put one server in each pane and drag. Two
  Teleport nodes on the same cluster hand off directly via `tsh scp` — the bytes
  never touch your machine. Any other pairing is relayed through your machine,
  and ServerLife says which route it will take and asks first. The same is
  available from the context menu as *Copy to another server*.
- **Drag within one pane to move.** Drop a file or folder onto a folder row
  in the same list and it is moved there — a rename underneath, so nothing is
  copied and nothing is at risk however large the folder, on your machine or
  on a server. The pointer shows *move* rather than *copy* so you know which
  it will be before you let go. Two things it will not do: put a folder
  inside itself, and overwrite something of the same name — a clash stops the
  move and says which name it was, because a drag is an easy gesture to make
  by accident.
- **Drag from Finder** straight onto a remote pane to upload. Dropping onto a
  *folder row* targets that folder, not the current directory.
- **Transfer queue** with per-job progress, transfer rates, file counts and
  cancellation — plus an explicit status-bar confirmation naming what finished,
  how much moved and how fast.
- Rename, recursive delete, new folder, and an inline editor for small text
  files.
- **Permissions and owner…** on one entry or a whole selection: an octal mode,
  an owner and a group, with one *Apply to everything inside as well* box that
  makes all three recursive. Blank fields are left alone, an owner and group
  together become a single `chown user:group` while a group on its own becomes
  `chgrp`, and **the exact commands are shown, and update as you type**, before
  anything runs.
- **Details columns.** The **≣** button in the pane header puts permissions and
  owner beside size and date — `drwxr-xr-x`, `ubuntu ubuntu` — and the choice is
  remembered. *Get info…* on an entry adds the numeric mode, the link count,
  the symlink target, every timestamp the server keeps, and, for a folder, its
  recursive size behind a button (walking a deep tree unasked would make every
  right-click expensive).
- **"What do these permissions mean?"** — a button in that dialog that reads the
  mode back in words: what each `rwx` triple grants *this* file, who the owner
  and group actually are, how the octal adds up, and what a `setuid`, `setgid`
  or sticky bit is doing when one is set. It explains the file in front of you,
  not permissions in general.
- **Compare with the other list** (**⇄**) marks both panes at once: what exists
  only here, what is newer on each side, what is identical — with a count of
  each in the status bar. Clearing it clears both panes.
- **Synchronize with the other list…** (**⇆**) walks both trees and shows every
  action before it takes one. Choose the direction (*This machine → server*,
  *Server → this machine*, or *Both ways (newer wins)*), what counts as a match
  (*Size and time*, *Size only*, *Time only*), and whether files the other side
  no longer has are deleted. **Every row has a tick**, so the plan is editable
  rather than take-it-or-leave-it, and the summary says how many files would be
  deleted and how many uploads would overwrite something newer. Uploads carry
  the original modification time, so running it twice does nothing the second
  time. See the [deletion warning](#warnings-and-limitations) below.
- **Synchronize with rsync…** (**⇆**) does the same job with the tool that is
  best at it. The one above walks both trees over SFTP and moves whole files,
  which is right for a handful and wrong for a tree; rsync compares by rolling
  checksum and sends only the blocks that changed, which for "make this 4GB
  directory look like that one" is a different order of magnitude rather than
  a little faster.

  It **rides the connection you already have** — rsync runs itself on the far
  side over a shell of the app's choosing, so it reuses the session's
  ControlMaster: no second authentication, no second Teleport session. It
  therefore needs one to ride, which is why it is offered for ordinary
  Teleport and SSH sessions but not for a per-session-MFA node (every rsync
  would raise its own prompt), a beam, or a bucket; each of those says so
  rather than failing halfway.

  The dialog **opens on a dry run** and the real copy is a separate press with
  the plan already on screen. Source and destination are prefilled from the two
  panes, **⇅ Swap direction** turns it round, and the **☆** beside either path
  offers that side's **starred folders** — the same list the star button shows,
  including a host's defaults like `/var/log`. A path picked from a list is a
  path you have not fat-fingered into a `--delete`. Archive, compress, delete,
  checksum, excludes and any extra flags are yours to set, *Copy the contents
  of the source folder, not the folder itself* is the trailing-slash question
  asked in words, and **the exact command is on screen** — selectable, copyable,
  and precisely what runs. Output streams as it goes, **Stop** ends it, and
  closing the dialog stops the run rather than leaving one going unwatched.

  An old rsync gets a plainer command: macOS ships `openrsync` as
  `/usr/bin/rsync`, which has neither `--info=progress2` nor `-s`, so a
  Homebrew rsync is preferred when one is installed and the flags are trimmed
  to what the binary understands. Any rsync **on your PATH** counts, not only
  one in the usual directories.

  **Not between two servers.** rsync refuses two remote ends outright — *The
  source and destination cannot both be remote* — before it connects to
  either, and there is no flag for it; every workaround is two transfers
  through this machine. Use **Copy to another server…** on the selection,
  which streams them through the app, or sync each server against here in
  turn.

  **Not on Windows.** It says so rather than half-working: there is no rsync
  in the platform to find, Win32 OpenSSH has no ControlMaster for it to ride
  — so the "no second authentication" that makes this worth using is not
  available — and rsync reads `C:\Users\me` as *host C, path \Users\me*, which
  needs translating into whichever convention the installed build uses. The
  synchronise above works there and is the answer until someone can test the
  other properly.
- **Keep this folder up to date from here…** watches a local folder and uploads
  each file as it is saved, new ones included. It never deletes on the server
  and never downloads; `.git`, `node_modules` and editor scratch files are
  ignored. Running watches are listed in the dock's **Watch** panel, and stop
  there or when the session closes.
- **Edit in my editor…** downloads a remote file, opens it in whatever this
  machine uses for that type — or the editor named in Settings — and uploads
  **every save** until you stop it. The local copy is temporary and is removed
  when the watch ends. This is usually the last reason a second file-transfer
  tool stays installed.
- **A download history** in the dock, after the connection log: what you pulled,
  from which host, how big, when, and where it landed, with **Open**, **Show in
  Finder**, *Copy name* and *Copy path*. An entry whose file has since moved is
  greyed and says so instead of failing when clicked, and forgetting an entry
  never touches the file itself.
- **Follow the terminal's directory.** `cd` somewhere in the terminal and the
  browser beside it moves too, within a second: the typed line is watched for
  a `cd`, `pushd` or `popd`, and the pane's directory is read as soon as one
  goes past rather than at the next poll. Anything that route cannot see — a
  command recalled with the up arrow, an alias, a script that ends somewhere
  else — is still caught by the background refresh a few seconds later.
  *Settings → Follow the terminal's working directory* turns the whole thing
  off. It does not apply to sessions opened over `tsh ssh` (per-session-MFA
  nodes, leaf clusters, beams): reading the directory is an exec, and on those
  an exec is another MFA prompt or another line in the audit log.
- **Folders first, or mixed in.** Listings put the folders above the files by
  convention. That is the wrong answer to "what changed here last" and "what
  is the biggest thing in here", so it can be turned off — in *Settings*, or
  from the ⇅ sort menu — and everything then sorts together by whichever
  column is in force.
- **Background refresh.** Every 5 seconds by default, the visible directories
  are re-listed so files created outside the app appear on their own. The
  refresh is non-destructive: it redraws only on a real change and keeps your
  selection, expanded folders and scroll position. Set it to 2/5/10/30 seconds
  or **Off** in Settings — each tick is one SFTP round trip per visible pane.

Transfers are pipelined (16 requests in flight), which on a normal link means
roughly 12–15 MB/s rather than the ~1 MB/s a naive sequential SFTP client gets.

### Controlling the queue

The **Transfers** panel is not only a progress report:

- **Pause and resume**, per transfer or the whole queue. A paused transfer is
  held *between chunks* rather than torn down, so nothing is re-authenticated
  and resuming is instant — and a file dropped in while the queue is held waits
  with the rest rather than starting behind your back.
- **Retry picks up where it stopped.** A download resumes from what is already
  on disk, an upload from what the server already has, so a dropped VPN does
  not mean starting a 4 GB file again. Only on an explicit retry: a fresh
  transfer to a path that exists still means "replace it", and appending to
  whatever was there would quietly produce a corrupt file.
- **Reorder** what has not started yet, for when the small one matters more than
  the big one in front of it.
- **A speed limit** in KB/s across every transfer, because what is being
  protected is the link out of this machine rather than any one copy. One
  allowance, handed out in order — sixteen parallel chunks each claiming
  "2 MB/s" is not a limit anyone meant.

### Searching a whole tree

The filter narrows what is listed; **search** (the magnifier in the toolbar)
walks the folder and everything under it. It answers the question people
actually arrive with — *where on this box is that file* — and works the same on
a server and on this machine.

- **By name.** A bare word matches anywhere in the name, so `nginx` finds
  `nginx.conf`; `*` and `?` work as usual.
- **By content.** Give it a string and it looks inside the files, reporting the
  line number and the line itself. The name box then narrows *which* files, so
  "`*.conf` containing `proxy_pass`" is one search.
- **Clicking a result** shows it in the list with the file selected;
  double-clicking opens it. Right-click for its folder, or to copy the path.

On a server this is `find` and `grep`, with the cap applied by `head` on the far
end so a search of `/` cannot pull a million lines back over the connection.
Locally it is a bounded walk inside the app. Either way it stops rather than
hanging — after six seconds or a quarter of a million entries — and **says
which**, because "no results" from a search that gave up is the wrong thing to
believe.

## Starred hosts and folders

Two stars, for two different kinds of "I come back to this constantly".

**A host's star** is the one on its row in the host list — visible on hover,
filled and amber once set. Starred hosts are listed again, together, in a
**Starred** group at the top of the list. They stay in their own cluster's
group as well, marked with the star: moving them out would leave a cluster's
list quietly incomplete, which is worse than naming a host twice. The group is
collapsible and can be dragged elsewhere like any other; drag it and it stays
where you put it.

**A folder's star** is the one in an explorer's toolbar (**☆**), and it applies
to the folder on screen. Starred places are listed as a **starred** section
above the file list — name, where it is, and highlighted when you are in it —
which collapses by its heading when the files are what you came for. The same
list appears in *Go to a path* (`⌖`).

**Files can be starred too.** A starred folder is somewhere to go and opens on
click; a starred file is something to open, and clicking it does that — handed
to the OS locally, opened in the built-in editor on a server. *Star this
file* / *Star this folder* is on any row's right-click menu, so neither has to
be opened first.

Right-click the toolbar star for the scope:

| | |
|---|---|
| **this machine** | a local folder — `~/Downloads`, a repository you live in |
| **this host** | a folder that only means something on one server — an app's deploy directory |
| **every host** | the same question everywhere — `/var/log`, `/etc/nginx` |

Per-host stars are kept against the host's uuid where there is one, so renaming
a Teleport node does not lose them.

### What gets starred without being asked

Some folders are flagged from the start, so the list is useful before anyone
has starred anything: your home, Desktop, Documents and Downloads here, and on
a server the same plus `/var/log`, `/etc` and `/tmp`.

Both lists are configurable in Settings — one path per line, `~` for the home
directory of whichever side it applies to. Two things keep them honest:

- **Nothing that is not there is offered.** A local path is checked before it
  is listed, and a `~/name` entry on a server only appears on hosts that
  actually have that folder — the home directory is listed once per connection
  to find out. A cloud instance is therefore not offered a Desktop it does not
  have.
- **They live in code, not in your settings**, the same arrangement the
  built-in macros use: they improve between releases, and *Hide this one*
  hides one without editing a list you never wrote. *Restore the built-in
  ones* brings them all back.

---

## Folders in the host list

A cluster's list is whatever `tsh ls` returns, in whatever order. On a real
fleet that is several hundred rows in which the fifteen you actually work on
are scattered. Stars help and stop at one flat list; the filter box helps and
is something you retype. Folders are the other answer: a name, a place to drag
a machine into, and it stays there.

Every cluster and every ssh_config file can have its own folders. Right-click
a group's heading → **Folders → New folder…**, or press **Folders** above the
list for the big view.

### Two ways in

**By hand.** Drag a host onto a folder. It is kept by the node's **UUID**,
never its hostname — a hostname changes on a rename or a rebuild, and a
filing system that empties itself when somebody renames a box is not one.
An ssh_config host is kept by its alias, which is the same thing for a host
that has no uuid.

**By rule.** Give the folder a tag query and it fills itself, re-asking every
time the inventory changes, so a node that comes up tagged `env=prod` files
itself without anyone touching it. The rule is written when the folder is made
or edited, and the dialog says how many hosts it matches *right now* and names
the first few, because a rule that matches nothing is easy to write and hard
to notice.

A folder can use both at once. A host in a rule folder shows a **by rule**
badge in the big view, and taking one out is remembered as an exception —
otherwise the rule would put it straight back, which reads as the app ignoring
you.

### Once something is filed

**It stops being listed loose.** A filed host is listed inside its folder and
nowhere else in that group, because the point of filing something is that it
is now somewhere. *Folders → Also list filed hosts at the top* puts them back
in both places if you would rather see the whole cluster flat as well.

**Folders nest**, as deep as you like. Drag a folder onto another folder to
move it; a folder cannot be dropped inside itself or inside its own
descendant, and the cursor says no rather than the app explaining afterwards.

**Dragging a host into a folder under a different top-level folder asks**
whether to list it in both or move it. Both answers are ordinary — the same
box is one of the web servers *and* one of the things on call this week — so
it is a question rather than a guess. Dragging between two folders of the same
tree is a tidy-up and moves it without asking.

### The big view

The pane's cluster list includes **leaf clusters**, each shown as
`root › leaf`. Picking one reads that leaf with its own `tsh ls` and lists
its nodes — a question, not a switch: the profile stays pointed where it is,
and the sidebar is unchanged. A leaf whose proxy will not answer says so
rather than looking empty.

**Folders** (above the host list, or a group's *Folders → Open the folder
browser*) opens the same folders with room to work in: the tree on the left,
what is in the selected folder on the right, breadcrumbs across the top, and
an **Unfiled** entry per group which is where the filing gets done. It is a
file manager, so it behaves like one — click, ⌘-click and shift-click to
select, drag a selection onto any folder in the tree, double-click a folder to
go in or a host to open a session on it. A folder's rule is shown above what
it currently claims, with the *Edit rule* button beside it.

### Boolean rules

Folder rules — and the host filter box, and multi-exec's tag selector — take
`and`, `or`, `not` and brackets, on top of the older syntax where a space
means "and" and a leading `-` means "not":

| Query | Matches |
|---|---|
| `env=prod role:web` | both, as before |
| `env=prod and role:web` | the same, said out loud |
| `env=prod or env=staging` | either |
| `not env=dev` | the same as `-env=dev` |
| `env=prod and (role:web or role:api)` | brackets group |
| `env=prod and not name=web-canary` | everything in prod except that one |
| `"or"` | quoted, it is a word to search for again |

`and` binds tighter than `or`, so `a or b and c` reads as `a or (b and c)`. A
half-written query is not an error: while you are still typing, the filter
falls back to reading the words as a plain list of conditions rather than
blanking the list. A folder's rule dialog does say what the parser made of it.

### Names and patterns, not only tags

A rule does not have to be about labels. Anything the host list knows can be
matched — `name`, `hostname`, `addr`, `cluster`, `proxy`, `type`, `user`,
`uuid`, `tunnel` — and three ways to say it:

| Query | Matches |
|---|---|
| `name=web-01` | exactly that |
| `name=web-*` | a glob |
| `name:web` | contains |
| `name~^(web\|api)-\d+$` | a **regular expression**, case-insensitive |

`~` is the regex operator. It is there because a glob runs out quickly — "the
numbered web and api boxes but not the canary" is one pattern and several
globs — and because the brackets in a pattern are the pattern's own: `name~^(web\|api)$`
is one condition, not a group. A pattern that will not compile is
reported in the rule editor rather than quietly matching nothing.

**A label never hides a field of the same name.** AWS nodes carry an
`aws/Name` tag, whose last segment is `name`, and `name=` used to ask about
that tag and never about the node's own name — so `name=prd-lku1-linux-ec2`
matched nothing on the one host it obviously described. Both are asked now,
and either matching counts.

### Writing one without knowing the vocabulary

The hard part of a rule is never the syntax, it is knowing what *this* cluster
calls things: `tsh ls` decides the labels, and every cluster's are different.
So the folder dialog does not ask you to remember them.

- **Insert a tag…** lists every label the group actually sets, with how many
  nodes carry each value. Picking one drops `key=value` into the rule.
- **Insert a field…** does the same for the non-label ones, including the
  regex and glob forms of `name`.
- **and / or / not / ( )** are buttons, and an `and` is put in for you between
  two conditions that have nothing between them.
- **What it matches right now** is under the box as you type: the count, and
  every matching host by name.

### Icons and colours

A folder can carry an **emoji and one of the eight host colours** — the icon
because 🔥 and 🧪 are read faster than two folder shapes with different names,
the colour because it is the same mark its hosts can carry, so a red folder
and a red host match.

**Hosts can carry an emoji too** — right-click one → *Give it an icon…* — and
that includes ssh_config hosts. It is separate from the host's colour on
purpose: the colour is "careful", the icon is *which* of these it is. A red 🐧
and a red 🪟 are both production and not the same problem.

### Sharing an arrangement

*Folders → Export these folders…* writes the whole arrangement — the tree, the
rules, the membership, the icons and colours — to a JSON file, and *Import
folders…* reads one back. No addresses, no logins, nothing secret: it is a way
of looking at a cluster, and it is safe to put in a pull request.

Membership travels as UUIDs, so a colleague importing your file gets the same
machines in the same folders on the same cluster. Rules travel anywhere, since
a rule means the same thing on any cluster — which is why the import offers to
land a file from a cluster you do not have into one you do. Imported folders
are given new ids, so importing the same file twice makes a second copy rather
than quietly overwriting the folders you have since edited; *replace* is there
when overwriting is what you meant.

---

## What a host remembers

These settings live on a host rather than in Settings, all of them on its
right-click menu in the host list.

**Preferred username.** *Preferred username…* pins the account this host is
always opened as. This is a decision, and it outranks the login the app
happens to have learned — which is otherwise whatever worked last. It is
stored against a Teleport node's **uuid**, not its name: the hostname in an
inventory is a label that changes when a machine is renamed or rebuilt, and a
setting that evaporates on a rename is worse than no setting. A username that
is not one of the cluster's principals is still honoured; the cluster decides
whether it is allowed, and silently substituting a different account would be
worse than failing.

**Whether it opens with the file browser.** *Opens with the file browser*, just
below *Preferred username…*, decides whether a new session on this host shows
its files beside the terminal. Some hosts are a shell and nothing else — a jump
box, a router, an appliance with no SFTP subsystem at all — and on those the
explorer is half a pane spent on an error message; others on the same cluster
are entirely about the files. The same three levels as agent forwarding: this
host, then the cluster (also on the group heading's menu), then the global
preference — which is simply how you last left the show/hide-all-explorers
toggle. Asking for the files outranks all of it —
⌘E still opens the explorer, and *Open files only* still opens a host flagged
against them.

**Agent forwarding.** Forwarding your agent (`ssh -A`, `tsh ssh -A`) lets
anything running as root on that host use the keys in your agent for as long as
the session is open. That is exactly what a jump host needs and exactly what a
shared box should not have, which is why it is worth deciding per host. Three
levels, most specific first:

1. **This host** — on, off, or *follow the cluster*.
2. **The cluster** (or all ssh_config hosts) — on, off, or *follow the global
   preference*. On the group heading's menu.
3. **The global preference** — in Settings. Off by default.

Every route into a connection obeys the same three levels — a double-click, a
saved profile, multi-exec, an agent through MCP — because the answer is resolved
where the connection is made rather than in the button that asked for it.

**Whether to be told if it disappears.** *Tell me if this host disappears*
keeps the node's id and last known details, and marks the row **⊘ gone**
instead of letting it silently stop being drawn. See [Hosts that disappear
entirely](#hosts-that-disappear-entirely).

**An icon.** *Give it an icon…* puts an emoji beside the name, in the host
list and in the folder browser. Any host can have one, an ssh_config alias
included, and it is kept against a Teleport node's uuid like everything else
here. Separate from the colour below because they answer different questions:
the colour is "careful", the icon is *which* of these it is.

**A colour.** *Give it a colour…* marks a host in one of eight colours, drawn as
a bar down its row in the host list, its tabs and its panes, with the name
tinted to match. Not decoration: it is how you know the pane you are typing into
is production without reading it. The same menu can mark a host **careful**, and
multi-exec then asks before a command fans out to it — which is the case the
colour exists to prevent.

### The same two marks, for a whole cluster

Six clusters in a sidebar are six lines of near-identical grey text —
`lku1.teleportdemo.com` against `a4232.teleportdemo.com` — and the one you
must not fat-finger a command into looks exactly like the lab. **Right-click
a cluster heading** in the host list, or **a cluster's row in the Teleport
tab**, for *Give the cluster an icon…* and *Give the cluster a colour…*, from
the same emoji picker and the same eight colours a host or a folder uses.

The icon sits **before** the name — a heading is read rather than scanned down
a column — and the colour tints the heading and draws a bar down the group's
left edge, the same bar a coloured host row wears, so a red cluster and a red
host inside it read as one statement. Both marks appear in **both** lists, and
the icon rides along in the hosts pane's cluster picker.

They are filed against the cluster's **group key**, not its name: the same
cluster reached through two tsh homes is two rows, and they are not
interchangeable.

---

## Keyword highlighting

Reading a log in a terminal is mostly looking for four or five words.
Highlighting colours them as the output arrives, so `error` is visible without
searching for it.

**It is off until you turn it on** — colour in a terminal belongs to the
program, and rewriting its output is a decision worth making rather than one
that arrives. Turn it on for everything in Settings, or for one host with the
toggle beside that pane's search box (**▤**), which is lit whenever it is
doing something. Right-clicking that toggle opens the rules.

Three sets are ready to go, because they are the words people are actually
looking for:

| | |
|---|---|
| **Errors** | error, fatal, critical, panic, traceback, denied, refused, failed, cannot, unable to |
| **Warnings** | warn, deprecated, timeout, timed out, retrying, degraded, throttled |
| **Good news** | success, succeeded, active (running), healthy, ready, completed, enabled |

They live in code rather than being copied into your settings, so they improve
between releases. Editing one copies it into your settings under the same id,
where it replaces the original; hiding one leaves it hidden until *Restore
built-ins*.

Your own rules take plain text or a regular expression, a colour, and whether
to fill the background or colour the text. A rule can be added for **one host
only** — a mail relay's "deferred" is routine, a build box's is not — and any
rule can be switched off for one host without touching what the others do.

Two things worth knowing about how it works. It rewrites the byte stream on its
way to the terminal, wrapping matches in colour and putting back whatever
colour the program had set, so highlighting a word inside a red line leaves the
rest of that line red. And it **stands aside entirely while a full-screen
program is drawing** — vim, less, htop, top — because those paint their own
colours and a highlighter recolouring an editor's buffer is vandalism rather
than help. Highlighting applies to new output only: what is already on screen
was written with whatever was in force at the time, and repainting it would
mean replaying the session.

---

## Local shells

Double-clicking **Local shell** opens your login shell. Its right-click menu
has two more things.

**The + above the tabs opens one too.** The new-session picker lists *This
machine* between your recent sessions and the inventory: your login shell
first, then every other shell installed here. A local shell was always in that
list, but below the last of however many hundred hosts, which is not somewhere
anyone finds it. Right-clicking the + still goes straight there, and `⌘T` skips
the dialog entirely.

**Open another shell** lists the shells actually installed on this machine —
read from `/etc/shells` and the usual Homebrew and system paths, filtered to
what exists and is executable. Useful for the "what does this look like in bash
rather than my zsh" question.

**Open with a blank configuration** starts a shell that reads no startup file
at all: `bash --noprofile --norc`, `zsh -f -d`, `fish --no-config`. Worth having
for two quite different reasons — reproducing what a *script* sees, with none of
the aliases, prompt or PATH your rc file adds, and getting a working shell when
an rc file is what just broke. A blank shell is deliberately not a login shell,
since `-l` is what reads the profile being avoided, and it carries
`SERVERLIFE_BLANK_SHELL=1` so a prompt can tell.

---

## tmux

<a id="tmux"></a>

A host's right-click menu has **Open in tmux…**, and that one choice changes
what a session *is*: the work stops belonging to the connection. Close the
lid, lose the wifi, quit the app by accident — the shell on the far side is
still running, with its scrollback, waiting. Reattach and it is where you left
it.

Only the server needs tmux. Nothing is installed on this machine: ServerLife
speaks tmux's control protocol itself, over the connection that is already
open — the same authentication, the same ControlMaster, the same single MFA
tap. A host without tmux says so, and names the one command that fixes it.

**It looks like the rest of the app.** A tmux window is a tab, a tmux pane is
a pane, and the arrangement is the one tmux reports — split a pane here and
tmux is asked to split, so another client looking at the same session sees it
too. The file browser is there as on any other session, reading the server
over the same connection, and following the shell as it moves. Search,
keyword highlighting, macros, saving the buffer and dragging a pane to another
tab all work exactly as they do elsewhere.

### Making it the default

On the host's menu, **Open in tmux: …** sets it three ways, as agent
forwarding and the file browser are set: for this host, for every host on the
cluster, or everywhere (also in Settings). With it on, **Open session** means
tmux and the menu offers **Open without tmux** for the one time you want a
plain shell. The session name is `serverlife` unless you change it — globally
in Settings, or per host from the same menu, which is how you keep separate
sessions for separate jobs on the same machine.

### Attaching, detaching, ending

**Open in tmux…** lists what is already running there and offers to start
something new. Picking the wrong one is the only mistake here that looks like
data loss — your work is not gone, it is in the session you did not pick — so
it asks rather than assuming.

A pane's right-click menu has **Detach — leave it running**, which is what
closing the tab does too, and **End this tmux session…**, which is the only
action here that destroys work and says so.

### What it costs

Two things are worth knowing. tmux must be installed on the far side, which
is one `apt install` and nothing on this machine. And Teleport records a
control-mode session as the protocol stream rather than as a readable
terminal, so `tsh play` of that session shows the protocol, not what you saw
— every attach is still audited and recorded, but the recording is not
watchable. That is why this is off by default and set per host: on the
machines where a dropped connection costs an afternoon it is obviously worth
it, and those are not usually all of them.

---

## Consoles and screens

<a id="consoles-and-screens"></a>

Four more things you can save and open, beside SSH hosts and Teleport nodes
and in the same folders: a **serial console**, a **telnet** session, a **VNC
screen** and a **Remote Desktop** connection. They are in **New profile…**
under Type, and they open the way everything else does — double-click in the
Saved list, or find them in the `+` picker.

They are here because of what they are for. The machines that answer only on a
console cable or on port 23 are switches, routers, PDUs, BMCs, terminal servers
and appliances — the things you reach for *when SSH is what has stopped
working*. A tool for looking after servers that cannot talk to a console is a
tool that leaves at the moment it is needed.

None of them is a connection in the sense the rest of this guide means. There
is no ControlMaster, no SFTP, no port forwarding and no second channel: a
serial port is one stream of bytes with no multiplexing in it at all. So these
panes have no file browser and no network tools, and everything else — splits,
dragging a pane to another tab or its own window, search, keyword
highlighting, macros, saving the buffer to a file — works exactly as it does
on a shell.

### Serial consoles

The port can be picked from **Ports on this machine now**, which lists what is
plugged in as you fill the form, or typed — a saved console should not require
the cable to be attached when you create it.

Speed, data bits, parity, stop bits and flow control are the usual settings
and default to **115200 8N1**, which is what almost everything made this
century uses. Hardware flow control on a console cable with no CTS wire looks
exactly like a dead port, so it is off unless you ask for it.

**Enter sends** is worth knowing about. Nothing agrees about what Return
means: xterm sends CR, most network gear wants CR, a Linux getty usually wants
LF, and some appliances insist on CRLF and show you a staircase if they do not
get it. Guessing wrong gives you a console that looks dead or one that
double-spaces everything, and both get blamed on the cable.

**Show what I type** echoes your keystrokes locally, for a device in its boot
loader or a port with nothing on the other end yet — which otherwise shows
nothing at all as you type, and is indistinguishable from a broken lead. When
the far end echoes too you will see everything twice, which is why it is off
unless asked for.

The pane's right-click menu has **Send break** — a long break on the line,
which is how you interrupt a boot loader and the reason the option exists at
all.

A port that is already open elsewhere, or that you have no permission for,
says so in those words: "in use by something else — screen, minicom or another
window", and on Linux "add yourself to the dialout group".

The `+` picker also lists the serial ports present right now under *This
machine*, openable at 115200 8N1 without saving anything. A console cable is
usually wanted five seconds after it is plugged in and for one look at a
switch that will not boot, which is not an occasion for filling in a form.

### Telnet

Host and port, and the same **Enter sends** and local echo settings — the
default here is CRLF, which is what telnet's own NVT specifies.

The protocol negotiation is handled: the terminal type is reported as
`xterm-256color` when asked, the window size is sent and re-sent as the pane
is resized, and a server offering to echo is taken up on it. None of that is
visible, which is the point.

### VNC screens

Drawn in the pane, not handed to another application. Host and port — 5900 is
display `:0`, 5901 is `:1` — and three settings: whether to **scale** the
screen to the pane, ask the **server** to match the pane, or show it full size
and scroll; the picture quality; and **view only**, for watching something
without the risk of clicking in it.

The password is asked for when you connect and is **not** saved. ServerLife
keeps its settings in a plain file, and a VNC password in one is a VNC
password in every backup of it.

The right-click menu sends **Ctrl+Alt+Del**, which no browser will let through
by itself, and pastes the local clipboard into the session.

A VNC server usually listens only on localhost. If yours does, open a tunnel
to it from **Tunnels** on the host that can see it, and point the connection
at `127.0.0.1` and the local port.

### Remote Desktop

RDP opens in **this machine's own client** — Remote Desktop Connection on
Windows, Windows App (formerly Microsoft Remote Desktop) on macOS, FreeRDP or
Remmina on Linux — with the settings from the saved connection written into
the file it reads.

This is the one protocol here that is not drawn in the app, and the reason is
worth stating rather than hiding. RDP is not a screen protocol with a keyboard
bolted on; it is a bundle of virtual channels — printers, drives, smart cards,
audio, clipboard, RemoteApp, multi-monitor — and a viewer that implements the
drawing orders and none of the rest is a demo, not something to work in. What
is worth keeping is the *settings*, which is the part people retype: the
address, the user and domain, the window size or full screen, the gateway, and
which redirections are on. Those live here, in the same list and the same
folders as everything else.

---

## Saving what you are looking at

- **A terminal.** Right-click a pane → *Save this terminal to a file…* writes
  everything in its buffer, scrollback included, as plain text. *Copy
  everything* does the same to the clipboard. Colours are escape sequences, so
  they are dropped: a file full of them is worse than useless in every other
  tool.
- **A network tool's output.** *Save output…* in Network Tools writes the last
  result — the text for ping and traceroute, the JSON for DNS, ports, TLS and
  `/webapi/ping`, the response body for a curl call — with a filename already
  shaped from the target.
- **A multi-exec run.** *Save results…* on a finished run writes every host's
  output as YAML, and *Save YAML…* saves the command and host selection to run
  again later.
- **The guide.** *Save as a file…* in Help → Guide, or *Copy the whole guide*.

---

## Adding servers

`⌘⇧N`, or **+ Add** in the sidebar footer, defines a server that is not in your
config yet — hostname, user, port, key, jump host and any extra `ssh` options —
with a **Test connection** button that dials it once and reports what answered
before you commit.

Two destinations, and the dialog is explicit about the difference:

- **Write to `~/.ssh/config`** — the host becomes available to `ssh`, `scp`,
  Ansible and everything else on the machine. Entries go inside a marked
  ServerLife block; your own configuration is never reformatted or reordered, a
  backup is taken first, and it refuses to shadow a `Host` you defined yourself.
  Right-click → *Remove from ~/.ssh/config* takes it out again.
- **Save in ServerLife only** — the connection details ride on the `ssh` command
  line instead. Nothing else on the machine learns about the host.

## Running one command

Right-click a host → **Run a command…** for the questions that do not justify a
session: is it up, what version, is the disk full. It runs over the shared
connection, shows stdout, stderr, exit status and duration, and offers to save
the command as a snippet or copy the output. For the same question across many
hosts, use multi-exec.

## Command snippets

`⌘⇧C` opens the snippets library: the commands you repeat, saved once.

- **Run here** sends one into the focused terminal.
- **Run in all panes** sends it to every remote pane in the tab.
- Select text in a terminal and right-click → *Save selection as snippet*.
- The list orders itself by how often you actually use each one.

Saved profiles also carry a **startup command** and remote/local start
directories, run automatically when that profile opens.

## Fleet operations

**Multi-exec** runs one command across many hosts at once. Tick hosts in the
sidebar, press `⌘⇧M`, type a command. Each host runs over its own connection,
concurrently; results stream back per host with stdout, stderr, exit code and
duration. A dead host reports its error without blocking the others.

**Save runs as YAML.** *Save YAML…* writes the command and its host list to a
readable, diffable file; *Load YAML…* restores both and re-selects the hosts.
Finished runs export their results as YAML too.

```yaml
kind: serverlife.multiexec
name: Check disk usage
command: |
  df -h /
  uptime
targets:
  - type: teleport
    name: example-cluster
    cluster: example-cluster
    login: ubuntu
  - type: ssh
    alias: ent
```

**Ansible export** turns that same selection into a runnable bundle:

```
serverlife-ansible/
├── inventory.yml      # hosts grouped by cluster, with the right proxy settings
├── playbook.yml       # your command as a task
├── ansible.cfg
├── ssh_config/        # generated tsh config so Teleport nodes resolve
├── run.sh
└── README.md
```

Use it when an ad-hoc command turns out to be something you will run again.

### Choosing targets by tag

Ticking hosts says *these eleven*; a tag says *whatever matches*, which is the
instruction people actually have — "every prod web node" — and it does not go
stale when a node is added. Tick **Choose by tag instead of ticking hosts**,
pick a cluster (or all of them) and write a query in the same syntax as the host
filter: `env=prod role:web`. The panel says how many match right now.

The query is what a saved run keeps, so a YAML saved today runs against next
month's fleet; the hosts it matched go in as a commented snapshot so the file
still says what it meant. **Run again** on a remembered tag run re-asks the
question rather than repeating the answer. The **Ansible export** resolves it
first — an inventory is a list of machines — and names the query in the play.

### Recent runs

Every multi-exec is remembered: the command, the hosts it ran on, how many
succeeded and when. **Run again** re-selects those hosts and runs the same
command; **Edit** puts the command back in the box without running it.

What is kept is the *question*, not the answers — the results are long and go
stale immediately, while "the same thing again after the fix" is the most
common follow-up, and the tedious part of that is never the command but
re-ticking eleven hosts. Hosts are matched by id rather than name, so a renamed
Teleport node still matches; if some of them have genuinely gone, it says how
many are left and asks before running on a smaller set than you asked for.

---

## Port forwarding

Right-click a host → **Port forward…**

| Type | Flag | What it does |
|---|---|---|
| Local | `-L` | A port on your machine reaches a service the server can see |
| Remote | `-R` | A port on the server reaches a service your machine can see |
| Dynamic | `-D` | A SOCKS5 proxy that exits through the server |

Tunnels are created on the **existing** connection (`ssh -O forward`), so they
need no new authentication and can be opened and closed while sessions stay up.
The *Tunnels* panel lists them with a one-click copy of the local address.

### Favourite tunnels

A tunnel dies with its session, and the interesting ones are the same three or
four every day — the database on its private address, the admin UI that only
listens on localhost. Retyping `5432 → 10.0.4.12:5432` from memory is how a
client ends up pointed at the wrong replica.

The **Tunnels** panel therefore has a Favourites section above the open ones:

- **Star an open tunnel** to keep it. The moment you know a tunnel is worth
  having again is usually after something has connected through it, not while
  typing the ports in.
- **Tick "Keep this as a favourite"** in the port-forward dialog, and name it.
- **+ New…** defines one without opening anything — pick a host, a type, the
  ports, and an account if it needs a particular one.

**Open** puts a favourite back up, dialling its host first if it is not already
connected. A favourite stores the host *whole* rather than by id, because it has
to outlive the inventory it was made from: log out of the cluster and back in,
restart the app, and it must still know what to dial. A favourite already up is
marked **open** rather than offering to open a second copy on the same port.

---

## X11 forwarding

Right-click a host → **Open with X11 forwarding** to run `xeyes`, `xclock`,
graphical installers and the like. Works over Teleport and plain SSH. Choose
untrusted (`-X`) or trusted (`-Y`) in Settings.

On macOS this needs [XQuartz](https://www.xquartz.org/). ServerLife checks for
a local X server first and tells you what is missing rather than letting the
program fail with `cannot open display`.

> Teleport nodes must also allow it: the role needs `permit-X11-forwarding`,
> and the node needs `X11Forwarding: yes`.

## Per-session MFA

Some Teleport nodes require an MFA tap for *every session*. `tsh proxy ssh` —
the transport behind the shared connection — cannot perform that ceremony, so
those nodes fail with `too many authentication failures` over the normal path.

Right-click such a host and choose **Open with MFA (tsh ssh)**. The session is
dialled with `tsh ssh` directly and the prompt appears in the terminal:

```
MFA is required to access node "mfa-node"
Available MFA methods [WEBAUTHN, BROWSER]. Continuing with WEBAUTHN.
Using platform authenticator, follow the OS prompt
```

ServerLife also recognises that failure signature on its own and offers the MFA
transport in the failed pane, rather than a retry that would fail identically.

**The file browser still works.** `tsh ssh` has no SFTP subsystem flag, but it
can run a command — so ServerLife execs the remote `sftp-server` over a tsh
session and speaks SFTP down that. One MFA approval opens the channel; browsing,
uploads and downloads then run on it with no further prompts.

Because each channel costs an approval, they are never opened at the same time:
the terminal prompts first, and the file list waits behind a **Load files
(approve MFA)** button. Two OS prompts at once would simply cancel each other.

**Hosts remember.** The first time a node turns out to need MFA — whether you
chose it or the shared path failed — it is marked, and future connections go
straight to `tsh`. Marked hosts show an `mfa` badge; right-click → *Forget that
this needs MFA* clears it.

If a ceremony is cancelled or times out, the pane offers the alternatives
rather than leaving a dead terminal: retry, a security key, an **OTP code**
(typed in the terminal, needing no OS prompt at all), the browser, or a copy of
the exact `tsh` command to run elsewhere. Terminals, port
forwards (`-L`/`-R`/`-D`) and multi-exec all work too.

Pick the method in Settings — **Touch ID** is the default. It matters: tsh's
`auto` mode can choose a path that fails in a spawned process, and the failed
attempt consumes the challenge so the fallback fails as well:

```
MFA authentication with WEBAUTHN failed, check logs for details
Attempting MFA authentication with BROWSER
ERROR: failed to verify WebAuthn response: ".../webauthnsessiondata/login" is not found
```

Naming the method up front avoids that.

## Keys and known hosts

**SSH keys** sits under *Local* in the host list, beside the local shell and the
network tools, since "which key am I actually offering, and does the agent have
it?" is a question asked while a host is refusing you. `⌘⇧K` opens the same view.

Every keypair in `~/.ssh` with its fingerprint, type and size, whether it is
passphrase-protected, where it lives, when it changed, which `ssh_config` hosts
name it with `IdentityFile`, and a warning on any private key whose permissions
sshd will silently ignore.

- **What the agent holds, including identities that are not files here** —
  keys from the login keychain, a hardware token, another agent, or a Teleport
  certificate. These are listed separately and named by cluster and user rather
  than by their raw `teleport:proxy:cluster:user` comment; `tsh` loads each one
  twice (the certificate and the key it signs), so entries sharing a
  fingerprint are shown as one identity.
- **Run `ssh-add`** for the default identities, from the footer — and per key,
  with the passphrase asked for up front, since `ssh-add` cannot prompt usefully
  from a GUI app. Offered even when the agent is not answering, because
  `ssh-add` reports the real reason better than a guess does. Where there is no
  OpenSSH client at all, that is said plainly instead of failing obscurely.
- **Generate** an Ed25519, ECDSA or RSA key.
- **Install a public key** on any connected server — the `ssh-copy-id` step,
  done over the connection that is already open, so it needs no extra
  authentication.
- **Forget a host key** (host right-click) to clear
  `REMOTE HOST IDENTIFICATION HAS CHANGED` after a rebuild.

## Teleport

- **Several profiles logged in at once.** Each is listed with its cluster,
  username, expiry and node count. Switch the active profile, or log in to a new
  cluster, from the Teleport tab. The login dialog takes a proxy, optional user,
  **auth connector**, cluster, TTL and MFA mode, and previews the exact `tsh`
  command before running it. Connections always carry an explicit
  `--proxy`/`--cluster`, so which profile is "active" never changes where a
  session goes.
- **Leaf clusters.** A root that trusts other clusters gets a leaf badge on its
  heading, carrying the number behind it, and clicking it switches — the root
  and every leaf in one list, each with its labels, since a leaf is usually
  remembered by `env=prod` or a region rather than by name. Past ten leaves the
  menu becomes a searchable dialog that matches names *and* labels. When the
  profile is already pointed at a leaf the badge says **leaf** instead of a
  count, because the name in the heading is then the leaf's and nothing else on
  screen would tell you which of the two you are looking at. Switching runs
  `tsh login <cluster>` against that profile.
  **Sessions on a leaf node always use `tsh ssh`**, never the multiplexed
  OpenSSH transport: the certificate is issued by the root and the node wants
  the leaf's role mapping, so the session pane says the transport was forced
  rather than letting the connection fail.
- **Access requests.** List them with their state, see details, create new ones,
  **assume** approved roles, and drop them when done. Assumed requests are
  marked on the profile.
  - **Browse what you can request** — *New request → Browse…* lists everything
    `tsh request search` reports for the cluster (servers, applications,
    databases, Kubernetes clusters, desktops…) by name and label, filterable as
    you type. This is deliberately a different set from the sidebar: a request
    is for a resource you **cannot** see yet, so `tsh ls` may show 3 nodes where
    13 are requestable.
  - **Names, not UUIDs.** Requests show `node/a4232-monitoring` instead of
    `node/d68f45ed-cbe5-433b-9eab-f8400966da4f`, resolved through
    `tsh request search`; the raw id stays in the tooltip.
  - **Requestable roles** come from `tsh request search --roles` as a checklist.
  - **Timing.** Say when access takes effect (defaults to now), when the
    request expires unreviewed, how long access lasts once approved, and when
    the elevated certificate ends — `--assume-start-time`, `--request-ttl`,
    `--max-duration` and `--session-ttl`. **Suggested reviewers** optional.
  - **The exact `tsh` command** is shown back, folded away, with a Copy button
    that works without expanding it.
  - **Save and raise again.** Keep a set of resources, roles and reason under a
    name against its cluster, then load it back from *Saved…*. *Save as
    reusable…* does the same from an existing request — pending, approved or
    expired — so the access you had to ask for once is one click away next time.
- **Tags.** Every label on a node — static ones and dynamic command labels
  alike — is read from `tsh ls --format=json` and shown in the sidebar. **Show
  tags** puts them under each host as `key = value` chips; with it off, the row
  summarises the most telling one (`dev +9`) without squeezing the host's name,
  which keeps its width and lets the badge truncate instead.
  Hover a host for the full set, or
  right-click → *Tags…* for a list including Teleport's internal labels.
  Clicking a chip filters by that tag; clicking it again removes it.
- **Search by tag.** The host filter reads labels, not just text:

  | Query | Matches |
  |---|---|
  | `env=prod` | label `env` is exactly `prod` |
  | `env:pro` | label `env` contains `pro` |
  | `env=prod,staging` | either value |
  | `env=prod*` | glob |
  | `env:` | has an `env` label at all |
  | `tag:gpu` | any label key or value contains `gpu` |
  | `cluster=corp` | a non-label field: name, host, cluster, addr, proxy, type, tunnel |
  | `-env=dev` | exclude |
  | `name~^web-\d+$` | a regular expression against a field or a label |
  | `a and b`, `a or b`, `not a` | spelled out, with brackets to group |

  See [Boolean rules](#boolean-rules) for the longer version — the same
  syntax a folder's rule is written in.

  Terms combine with AND, quotes hold values containing spaces together, and a
  key written without its prefix still finds it — `location=east` matches
  `aws/location`. **Tags…** browses every label in the inventory grouped by key,
  with a count per value, and the box autocompletes pairs it has seen.
- **Session recordings** — *Teleport → Recorded Sessions…* (`⌘⇧Y`), or
  right-click a host → *Recorded sessions for this host…* to land pre-filtered.
  Each row shows node, user, login, duration and time. **Play** replays it in a
  tab via `tsh play`; **Web UI** opens it in Teleport.
  - **Interactive sessions only, by default.** A cluster's recording list is
    mostly `exec` records — every scripted command, every health check — and
    none of them have anything to replay. They are filtered out, the count of
    what was hidden is shown, and one checkbox brings them back.
  - **Paste a session id** into the filter and it is recognised as one even when
    that session is outside the range loaded, offering to play it, open it in
    the web UI, or flag it. A recording you were sent in a ticket needs no date
    arithmetic first.
  - **Flags and notes.** The **☆** on any row keeps that session, with a note
    saying what happened there and why you might want it again. *Flagged only*
    lists what you kept — including sessions the cluster has since aged out of
    the range on screen, since a flagged session is one you decided mattered.
- **Search what was typed.** The *Search transcripts* tab fetches the text of
  every recorded session in a time range and looks for a word or regular
  expression, showing matching lines with context and a jump to play or open
  each session. Optionally it downloads every transcript it scans into a folder.
  Non-interactive exec sessions have no transcript and are skipped by default;
  progress is reported and the run can be stopped. Teleport lists recordings by
  **date**, and rejects ranges beyond roughly half a year, so 180 days is the
  maximum offered.
- **Connection history.** A local log of every session this app opened,
  successes and failures, including plain SSH hosts that Teleport's audit log
  never sees.
- **Server profile.** Right-click a host → *Server profile* for distribution,
  kernel, architecture, CPU, memory, disk, virtualisation, init system and
  package manager — one round trip over the existing connection.

### Access requests, where you will see them

A request is something you are waiting on, and waiting is the wrong shape for a
button you have to remember to press. The list is re-read every ninety seconds
(paused while the window is hidden) and what it finds goes where it will be
noticed:

- **A badge on the Teleport tab** with the count — amber while a reviewer still
  has it, green once there is an approval ready to assume.
- **A `n req` tag on each cluster's heading** in the host list, clickable
  straight into that cluster's list.
- **Right-click a cluster heading** for *Access requests — 1 waiting, 4
  approved…*, or right-click the sidebar's tab strip for every cluster at once,
  plus *New request…*.

Only what you could act on is counted: pending review, or approved and still
usable. An approval that expired unused is history rather than something to do.

### Monitoring what you could ask for

The other direction. A request tells you about access you have asked for;
this tells you whether the thing you **expect to be able to ask for** is still
on offer. `tsh request search` is not a stable list: a node is rebuilt under a
new id, a role changes and a whole kind stops being offered, a resource is
retired and simply stops appearing. None of that announces itself, so you find
out at the moment you needed the access — which is the worst moment, because
the request you were about to raise is the thing that has gone.

Open it from **Teleport → Monitor Requestable Resources…**, the *Monitor
requestable…* button under the Teleport tab, or **right-click a cluster
heading** in the host list, which goes straight to that cluster's resources.
Pick what matters from the same picker an access request uses, and a small
pane floats above the app — drag it by its head, and it stays where you put
it:

- **Every five minutes** (1, 5, 15, 30 or hourly, at the foot of the pane) the
  search runs again. Each resource reads **✓ requestable — confirmed 2m ago**,
  or **⊘ not requestable — missing 14m, last confirmed 3h ago**.
- **What was saved is what is shown.** The name, the node id, the cluster and
  the labels are written down while the resource is there, and drawn from that
  record once it is not — `env=prod`, `role=database` and the name it went by
  are all anyone has to go on afterwards, and a row reading
  `/cluster/node/ea9f6ccd-…` is a row nobody can act on.
- **A resource is only ever called missing off a successful search.** A lapsed
  certificate, a proxy that will not answer, a role that cannot search that
  kind — each produces an empty list that means nothing, and the pane says
  *could not search…* instead of condemning everything on it.
- **An unreachable cluster says so, per row.** Those resources read
  **? not checked — cluster unreachable, last confirmed 4h ago** in amber,
  and the head counts them alongside the missing. Which cluster last answered
  and which last failed is kept in your settings, so logging out on Friday and
  opening the app on Monday shows *not checked* rather than a tidy row of
  green ticks confirmed three days ago. The same applies when the app simply
  has not run a check in a while.
- Monitoring **carries on with the pane closed** — that is the point of it —
  and the cluster heading's menu carries the count, so *2 of 7 missing* is
  visible without opening anything. Closing the pane stops nothing; the **×**
  on a row is what stops watching that one.
- **The pane never opens itself.** Not even if you left it open when you last
  quit: a floating window appearing over the app at launch is an
  interruption, and this one has nothing urgent to say most mornings.
  *Settings → Open the requestable-resource monitor when the app starts*
  turns that on if you would rather have it up.

### What tsh says

*Status (tsh status)…* on a cluster's heading — and the **Status** button on its
profile row — shows the app's own view of that profile (cluster, proxy, user,
roles, logins, expiry, tsh home) above the **printed** `tsh status` output,
which is what people compare against a terminal and paste into tickets.

`tsh status` leads with whichever profile is *active* and lists the others after
it, so when the cluster you asked about is not the one at the top, the dialog
says so rather than leaving you to notice.

### An expired cluster that will not go away

A profile lives in the tsh home as a `<proxy>.yaml`, and that file is what
`tsh status` reads — so a cluster whose certificate expired stays listed,
with empty roles and *[EXPIRED]* against it, until the file goes. For a lab
that was torn down or a demo cluster that no longer resolves, that is
forever.

An expired group now carries **Remove** beside *tsh login* and *Copy login
cmd*. It names every file it is about to delete — the profile, any key
material left behind, and the `current-profile` marker if it pointed there —
and deletes them on confirmation. Not `tsh logout`: that is right for a live
cluster and can sit waiting on a proxy that is no longer answering, which is
precisely the case this exists for. Nothing on the cluster is touched, and
logging in again recreates the profile.

### Logging in again

A Teleport profile only exists while its certificate does. *Save cluster* keeps
the details that survive a logout — proxy, user, connector, tsh home, TTL — so
logging back in is a click rather than a remembered hostname. Saved clusters
are listed under the live ones in the Teleport tab.

**The proxy address is the host and port, and nothing else.** The address
anyone has to hand is the one in their browser's bar, so it arrives as
`https://example.teleport.sh/web` — and `tsh login --proxy=https://…` fails,
or logs in and stores a profile under a name nothing else in the app matches.
The scheme and anything after the host are dropped as soon as the field loses
focus, where you can see it happen; the port is part of the host and stays.
Every command built from a cluster applies the same rule, so one saved before
this gets it too.

**Save** and **Login** are separate buttons in the cluster dialog, because
editing a kept cluster — correcting a proxy address, switching the connector,
pinning a tsh home — is not the same act as logging in, and before that the
only way to keep a change was to run a login you may not have wanted to run
right then.

**A login that names a user opens a terminal.** `tsh login --user=…` is heading
for a password, an OTP or a hardware key, and a prompt in a spawned process with
nowhere to draw is a login that hangs and then fails — so it runs in a local
shell tab where you can answer it, and the inventory is re-read when the command
exits. That applies wherever a login starts: the dialog, the **tsh login**
button on an expired cluster, and automatic login.

**Log in automatically when the app starts** is per cluster and off unless
asked for. Ticked, that cluster is logged in at launch if its certificate has
gone. One at a time, because an SSO login opens a browser and four browser tabs
fighting over the foreground is worse than clicking one button; a cluster whose
connector needs a terminal is exactly the case this cannot serve, and it says
so rather than taking the others down with it.

### Leaf clusters

A root cluster that trusts others gets a leaf badge on its heading, carrying
the number behind it. Clicking it switches: the root and every leaf in one
list, each with its labels, since a leaf is usually remembered by `env=prod` or
a region rather than by name. Past ten leaves the menu becomes a searchable
dialog that matches names *and* labels.

When the profile is already pointed at a leaf the badge says **leaf** instead of
a count, because the name in the heading is then the leaf's and nothing else on
screen would tell you which of the two you are looking at. Switching runs `tsh
login <cluster>` against that profile.

**A session on a leaf node always uses `tsh ssh`**, whatever transport was
asked for. The ssh_config route would connect — the leaf trusts the root's user
CA — but it would do so holding the root's certificate, which is the only one
`tsh config` names; going through tsh gets a certificate issued *for the leaf*,
so the leaf's role mapping and principals decide what the session can do. The
session pane says the transport was forced rather than letting it fail.

### Putting a cluster in ~/.ssh/config

*Add to ssh config…* — on a profile row in the Teleport tab, and on the
cluster's heading menu in the host list — writes that cluster's `tsh config`
block into `~/.ssh/config`. The app itself does not need it: it generates its
own config per connection. This is for everything else that speaks ssh and
nothing else — `ssh node.cluster`, scp, rsync, Ansible, git, VS Code Remote.

What it would write is shown first, and then:

- It goes in **between markers naming the cluster**, so writing it again
  replaces it in place. A literal `tsh config >> ~/.ssh/config` run twice
  leaves two blocks with the same `Host` patterns, where the first quietly wins
  and the second is dead text that reads as live.
- It goes at the **top** of the file when it is new, because ssh takes the
  first value it sees for an option and a block after a catch-all `Host *`
  can be silently overridden.
- Everything outside the markers is left alone, and the file is backed up
  first.
- **If the cluster is already in there** — a `tsh config` someone ran by hand —
  it says so, names the patterns it found, and asks again before adding a
  second block, because that duplicate is the user's own text and the app
  cannot clean it up for them.

### Nodes that have gone quiet

A node is in the cluster's inventory because its agent keeps announcing it. If
that stops — the agent crashed, the machine is wedged, the network went — the
node does not disappear straight away. It sits in the list looking exactly like
a healthy one, still offering to connect, for the ten or fifteen minutes the
cluster waits before dropping it. A session opened in that window does not fail
quickly: it hangs waiting for a tunnel with nobody on the far end.

So a node that has not been heard from for a couple of minutes gets an amber
**⚠ 6m** on its row, counting the silence, and its tooltip says how long it has
left before the cluster forgets it entirely.

The cluster does not publish a "last seen" time; what it publishes is when it
will give up on the node, and every heartbeat pushes that a full announce
interval into the future. The age is the difference between the two. The
interval itself is not in the output either, so it is read off the cluster's
own healthy nodes — the freshest of them has just heartbeated, and that is the
full interval. A cluster with a single node in it cannot be measured that way
and will warn late or not at all, which is the harmless direction to be wrong
in. Hosts with no heartbeat to be late — agentless OpenSSH nodes, anything
registered without an expiry — are never marked.

**Heartbeats**, beside *Show tags*, puts the same figure on every Teleport row
— `♥ <1m` on a node that is answering — for when you are watching something
come back, or want to know whether the list is telling you the truth. It is in
minutes because changing the text rebuilds the list; the exact seconds are in
each row's tooltip.

**The quiet button** appears next to it as soon as something has gone quiet,
carrying the count, and cycles through three states:

| It says | The list holds |
|---|---|
| `Quiet: 2` | everything, the quiet ones marked where they stand |
| `Quiet hidden (2)` | only the nodes that are answering |
| `Only quiet (2)` | only the ones that have stopped — what you want when something has taken a rack or a subnet with it |

The count stays on the button in all three, because a cluster that is quietly
two nodes short is the thing worth knowing. Right-click any Teleport host for
the same three as named items.

*Settings → Warn about nodes that have gone quiet* moves the threshold, or
turns the warning off.

### Hosts that disappear entirely

A quiet node is still in the inventory. The other failure is the one the
list cannot show you at all: a node that is decommissioned, rebuilt under a
new id, or dropped by an autoscaler stops being drawn, and nothing says so.
The row is gone, so there is no row left to carry the news — you find out by
going to look for the machine.

Right-click a host → **Tell me if this host disappears**. From then on its
**node id and everything last known about it** — name, address, labels,
cluster, and when it was last seen — are kept, because once it has gone the
cluster cannot be asked any of that, and "something has vanished" is not
enough to act on.

A watched host carries a small **🔔** beside its star, so you can see at a
glance which machines you are being told about. *Settings → Bell on hosts
watched for disappearance* turns that mark off — thirty marked machines is
thirty bells, which is where a mark stops meaning anything — and the same
place says how many are being watched and will stop watching all of them.
The watch itself is unaffected: the message when something goes, and the row
that stays behind, are the part that matters.

When it stops being listed you get a message, and the host **stays in the
list**, struck through and dimmed, with **⊘ gone 2h** and a tooltip holding
the record. It cannot be opened or ticked for multi-exec — there is nothing
there — and its menu offers the node id and *Stop watching and forget it*.
If it comes back, the mark clears itself and says so.

A host is only ever declared gone off the back of a **successful read** of
its cluster. An expired certificate, a proxy that will not answer, a `tsh
ls` that failed — each produces a list with the host missing from it, and
none of them means the machine is gone.

Gone hosts are counted by the **quiet button** and listed by *Only quiet*, so
that mode is everything that has stopped answering, whether it went silent or
went away. But *Hide quiet* does not hide them, and neither does the
twenty-per-group cap: a node that stopped checking in is noise you may
reasonably want out of the way, while a host you marked in advance and that
has since left the inventory is the answer to a question you asked.

**A watch ends when you end it.** Not when its cluster expires, is logged out
of, or is removed: the record lives in your settings, not in the cluster, so
a gone host keeps its row through all of that. An expired cluster still draws
its ghosts above the login prompt, and any whose cluster is no longer listed
at all are gathered into a **Watched** group at the foot of the host list.
They leave when you choose *Stop watching and forget it*, and not before.

**Out of reach is not gone.** A cluster describes itself with two lists that
do not overlap: `tsh ls` is what you can reach, and `tsh request search` is
what you could ask to reach. A node moves between them without changing in
any way — an approved request expires, a role is edited — and to anything
watching only the first list that move looks exactly like the machine being
decommissioned. So a watched host missing from the inventory is now looked
for in the other list before anything is concluded. If it is there the row
says **req**, in blue rather than red: the machine is fine, the access is
what went. **Double-click it to start a request** with that node already
chosen, or use *Request access to it…* from its menu. If it comes back to
standing access the mark clears itself and says so.

**The hosts pane has a `Requestable` toggle**, off by default, which adds
everything that cluster would let you ask for — tagged **req**, double-click
to ask. They are host-shaped like everything else in that list, so the
filter matches them, a folder rule claims them, and they can be dragged into
a folder by hand: one arrangement of a cluster, whether or not you hold the
access today.

**And a third answer: `? unchecked 4h`.** *Gone* is a verdict, and it is only
ever reached through a successful read of a list that had other machines in
it. When the cluster cannot be read at all — logged out, certificate lapsed,
proxy down, the laptop shut all weekend — a watched host is neither confirmed
nor known to have left, and the app used to say nothing at all. Saying
nothing is the one wrong answer: a list of watched hosts with no marks on it
reads as *all present* when what it means is *nobody has looked since
Friday*. Those hosts carry an amber **? unchecked** with how long it has been
since anything confirmed them, and the group heading counts them.

**A verdict lasts only as long as it can be re-tested.** A host marked gone
whose cluster you then log out of stops being reported as gone: nothing can
check it any more, so *gone* is a claim with nothing behind it, and a row
asserting a machine has been decommissioned when the honest answer is "we
have not been able to look since you logged out" is worse than saying
nothing. It shows as **? unchecked** instead, and the tooltip keeps the
finding as a note — *it was absent from the last list that could be read, at
12:05* — so nothing is lost. Log back in and the next successful read
restates it, or clears it. The requestable-resource monitor follows the same
rule.

### Latency to a node

*Latency to this node…* on a Teleport host runs `tsh latency ssh`, which
measures both halves of the path: you to the proxy, and the proxy to the node.
That is the question when a session feels slow but a ping to the proxy looks
fine.

It is a live view that draws its own screen and insists on a real terminal, so
it opens in a tab of its own rather than being captured into a dialog — the
same treatment session replay gets. Close the tab to stop it.

---

## Beams

A **beam** is an ephemeral sandbox VM: `tsh beams` creates one on demand, it
expires on its own, and it never appears in the cluster's node inventory.
ServerLife lists them **inside their cluster's group** under a `beams` heading —
with the cluster, because that is where they run; marked off, because a beam is
not a server. Each row carries its region, a live countdown to its expiry and a
**beam** badge, and the last row is always *+ Start a beam…*.

- **Support is discovered, not configured.** `tsh beams ls` answering at all is
  the test; a cluster without the service replies *unknown service
  teleport.beams.v1.BeamService*, and the answer is remembered per proxy. A
  cluster that cannot be asked right now — an expired certificate, a slow proxy
  — can be marked as a beams cluster by hand from its heading menu, and any
  cluster's beams can be hidden.
- **Everything the app does to a server, it does to a beam.** Double-click one
  and you get an ordinary session: a terminal, the file browser beside it, the
  transfer queue, compare, synchronize, keep-a-folder-up-to-date, *Edit in my
  editor*, and drag-and-drop between panes. None of it is beams-specific code —
  `tsh beams ssh` is the terminal, and `tsh beams exec` runs the beam's own
  `sftp-server` to carry SFTP, so a beam is just another connection to
  everything above.
- **The whole `tsh beams` command set** is on the row's menu:

  | | |
  |---|---|
  | *Open a session* / *Open the file browser* | a terminal, or files with no terminal |
  | *Run a command…* | one command answered in a dialog, no session needed |
  | *Publish a service…* | expose an HTTP or TCP service running inside the beam; the address is captured and copied, and unpublishing is the same dialog |
  | *Copy files (scp)…* | `tsh beams scp`, in either direction, for a whole directory in one call |
  | *Delete this beam…* | asked first, because nothing on it comes back |

- **A beam takes no port forwards.** Publishing a service is the beams-shaped
  answer to the same question, and the refusal says so rather than failing
  obscurely.
- **The list re-reads itself every minute** (and pauses while the window is
  hidden), because beams expire on their own and anyone with access to the
  cluster can start or delete one. Deleting retries the concurrency error the
  service returns for a beam created moments earlier, then confirms the beam has
  actually gone before saying it did.
- A beam also registers as a node called `beam-<uuid>`; those are filtered out
  of the cluster's node list, so each beam appears exactly once — under its own
  name, where it can be managed.

## Windows

*Session → New Window* (`⌘⌥N`), or the button on the start page. Each window
has its own tabs, panes, sidebar and file browsers; connections are shared, so
a host already dialled is not dialled twice.

Every window's layout is remembered on its own, and reopening the app offers
them all back at once — the restore prompt says how many more windows come with
it, and one answer brings back the lot, each landing in the window it came
from. A window closed on purpose does not come back. Windows take their title
from what is open in them, so the Window menu lists `web-01, db-02` rather than
three entries called ServerLife.

## S3

Register buckets under *Saved → S3* and they appear as a source in every file
explorer, beside your sessions and the local machine.

Credentials come from one of four places:

| Source | What it uses |
|---|---|
| **Teleport** | An AWS app and IAM role via `tsh proxy aws` — per-session, audited, nothing stored |
| **AWS profile** | `~/.aws` as it already is: SSO, assumed roles, `credential_process`, static keys |
| **Environment** | `AWS_ACCESS_KEY_ID` and friends, optionally under a prefix |
| **Stored key** | Encrypted with the OS keychain; refused if the machine has none |

Browse the buckets the credentials can see and pick one rather than typing it;
the region is detected, and a bucket in another region corrects itself from the
header S3 sends back. Download, upload, delete, copy a key and re-tier objects.
Uploads choose a **storage class** — Standard through Deep Archive — defaulting
to whatever the bucket was registered with.

Signature V4 is implemented directly rather than pulling in the AWS SDK, and is
verified against AWS's published test vectors.

## Macros

Commands aimed at a host, under *Saved → Macros*. Where a snippet is text you
paste, a macro answers a question — "is the agent running", "what is filling
the disk" — so it carries a description and can run without a terminal open.

Sixteen ship built in. **Teleport**: service status, follow the agent log,
errors in the last hour, version, config, restart. **System**: disk usage with
inodes, largest directories in `/var`, memory and load, top processes,
listening ports, recent errors, who is logged in, addresses and routes, OS and
kernel, pending reboot. They live in code rather than being copied into your
settings, so they improve between releases — hide any you do not want and
restore them later.

- **Every session pane has a ▶ button** in its header that drops down the macro
  list, grouped by category, and runs the one you pick on that host. `⌘⇧R`
  opens the same menu on the focused pane.
- **Double-click** in the list sends a macro to the focused terminal.
- With **nothing focused**, it offers to run on a host you pick and shows the
  output in a dialog.
- Right-click for *send to every pane*, *run on a host and show output*,
  *copy*, *edit* (built-ins duplicate first) and *hide/delete*.
- Macros that change something are marked **careful** and ask before running.
  Ones that follow a log are never run headless.
- **A `?` on every row** of the ▶ menu, with its own tooltip: what the macro is
  for, the command it runs, and whether it asks first, follows a log, is pasted
  without Enter, or has blanks to fill in. A separate hover target, so "what
  does this do" does not mean hovering the thing you have not decided to run.
- **Submenus open from the arrow**, not from the row. Every macro row both runs
  something and carries variations, so opening on hover threw a second panel
  under the pointer at each step down the list.
- **Where a macro can run** is part of the macro: **hosts and the local
  shell**, **hosts only**, or **the local shell only**. `sudo journalctl -fu
  teleport` is not something you run on a Mac and `brew upgrade` is not
  something you run on the server, so the ▶ menu offers only what fits the pane
  it was opened from, multi-exec leaves out anything local-only, and a pinned
  button never appears where its macro would not run. Set it in the macro
  editor, under the command.

  The built-ins are host commands — systemd, `journalctl`, `ss -tulpn` — so
  they say so; the three written to fall back to the BSD tools (disk usage,
  addresses and routes, OS and kernel) are marked for both. A macro of your own
  from before this existed is offered everywhere, as it was; a new one written
  from a pane's ▶ menu starts as whatever that pane is.

  Sending one somewhere it is not set for still works — the sidebar's
  double-click goes to whatever is focused — but it asks first, because the
  scope is a default about where a macro belongs rather than a lock.
- **Pin a macro as a button.** *Pin as a button* — from the macro's menu or its
  editor — puts it directly in every session header with an icon you choose,
  instead of two clicks into the ▶ menu. Each pin says where the *button*
  belongs: **every session and the local shell**, **host sessions only**, or
  **the local shell only** — narrowing the macro's own scope, never widening
  it. The scope can be changed later from either place.
- **Variables.** A command can leave blanks — `{{service}}` — filled in when it
  runs, so "restart a service" is one macro rather than twenty. Declare them in
  the editor, one per line:

  | Written as | Means |
  |---|---|
  | `service = teleport` | a default, so the macro still runs on one click |
  | `level = info \| warn \| error` | a list to pick from; mark the default with `*` |
  | `lines =` | no default, so it is always asked for |

  A `{{name}}` used in the command but never declared is treated as a blank
  with no default rather than left in as literal text. A macro whose blanks all
  have defaults runs straight away; one with an empty blank opens a dialog with
  the command previewed as you type. **Fill in variables…** in the macro's
  submenu opens that dialog either way, for the times you want to change a
  value that has a perfectly good default. Across multi-exec, the values are
  asked for once and the same ones go to every host.
- **The last entry in the ▶ menu writes a new macro**, because the moment you
  want one is the moment you have just typed the same command for the third
  time — and you are looking at that menu, not at the Saved tab.
- **Multi-exec** has **Command**, **Macros** and **Recent runs** tabs, so a
  macro can run across every selected host with the same run-as login.

## Network tools

*Session → Network Tools…* (`⌘⇧T`). One target — a host, `host:port` or URL —
and nine tools against it, so several can be run in a row without retyping:

| Tool | What it tells you |
|---|---|
| Ping | Round-trip time and packet loss |
| Traceroute | The path packets take, hop by hop |
| DNS | A, AAAA, CNAME, MX, TXT, NS, SRV, and PTR for an address |
| Port check | Whether a TCP port accepts a connection, and how fast |
| TLS certificate | What the server presents, valid or not — chain, cipher, SANs, fingerprint, days left |
| HTTP | Status, timing, size, redirect chain and response headers |
| Whois | Registration for a domain or address |
| Teleport cluster | A proxy's `/webapi/ping`, laid out (below) |
| This machine | Local interfaces and resolvers |

The port check is one host at a time with a 32-port ceiling — a reachability
check, not a scanner. Nothing runs through a shell: external commands get an
argument array and every target is validated first.

**A port has three answers, not two.** *open* is a connection that was
accepted. *refused* means the host answered and nothing is listening on that
port — something is there. *no answer* means nothing came back before the
timeout, which is a firewall dropping the packet, or an address with nothing
at it. The distinction is the whole diagnosis: a refusal is a service to
start, silence is a rule to change.

**Teleport cluster information** — also on *Teleport → Cluster Information…*
and the **Cluster info** button on any profile. Reads `/webapi/ping`, which
needs no credentials, and lays out the cluster name, version, minimum client,
edition and FIPS mode; managed-update settings; the auth connector in play with
its display name, second factor, passwordless support and session TTL; and
every proxy listener including Kubernetes and database addresses and whether
TLS routing is on. The raw JSON is one click away.

### Running them on a host

The question is usually not what your laptop can reach — it is what *that
server* can reach. **Run on** at the top of the window switches between this
machine and any session that is open, and the network icon on a session's own
header opens the tools already pointed at that host.

Five checks work there. Three need nothing at all installed on the far side:

| | |
|---|---|
| **Port check** | The server is asked to open the connection, over the session that is already authenticated (`ssh -W`). The answer comes from its own network stack, and a service that announces itself hands back its banner — `SSH-2.0-OpenSSH_9.6p1` — as free evidence of *what* is listening |
| **HTTP request (curl)** | Sent through a SOCKS proxy over the session, with `--socks5-hostname`, so the name is resolved on the host as well. A request to `169.254.169.254` therefore reaches *its* metadata service, not yours |
| **That host** | Its addresses, routes and resolvers, from `ip` and `/etc/resolv.conf` |

Two more do need a tool, and get one anyway, because they are the first two
things anyone reaches for:

| | |
|---|---|
| **Ping** | `ping` is on almost every box. The output is shown as the host printed it — including a run that lost every packet, which is an answer. Worth knowing: a container without `cap_net_raw` gets "Operation not permitted", and plenty of networks drop ICMP while passing TCP perfectly well, so a failed ping is not a failed network |
| **Traceroute** | The name everyone knows is the one least often installed. `traceroute` is used where it exists, then `tracepath` (iputils, no root needed), then `mtr --report`. The result says which answered it |

Both are greyed with the reason when the host has none of them, rather than
failing when pressed — and the reason comes with the command that would fix
it. The remaining tools — DNS, TLS, whois — are still marked *from this
machine only*: they would need their output parsed per distribution, which is
a different piece of work.

The icon sits on every session's header, and can be turned off in Settings for
anyone whose header is busy enough already — the tools are still on `⌘⇧T`, with
the same **Run on** selector.

**What the host has** is read once per session, in a single command, and shown
under the selector: the distribution, what is installed, and what is missing
with the exact command that would fix it (`sudo apt install traceroute`) taken
from the package manager the server profile already detects. One command rather
than one per tool, because on a per-session-MFA node every exec is a prompt and
on any Teleport node it is an audit entry. *Re-check* asks again, for after you
have installed something.

A session dialled with `tsh ssh`, or a beam, cannot forward — so a port check
there falls back to what the host has: the `bash` `/dev/tcp` builtin, then `nc`
(whose flags differ between the OpenBSD, nmap and busybox versions, which is
why the probe records which one it found), then `python3`. Every port goes in
one command rather than one each, since on a per-session-MFA node that is the
difference between one prompt and five.

> A check run on a host runs *on someone else's machine*: it appears in that
> cluster's audit log, and the same 32-port ceiling applies as locally. It is a
> reachability question, not a scanner.

### HTTP requests (curl)

A full request, built in a form and run through **curl itself** — the same
proxy variables, the same CA store, the same HTTP/2 as your own `curl`, and a
command line you can paste elsewhere. Method, headers one per line, a body sent
exactly as typed, a content type, and either a bearer token or basic auth.

The command is shown as it will run, built from the same argv the request uses
so the preview and the call cannot drift apart. Nothing goes near a shell: a
header containing `$(…)` is one argument, not an opportunity.

The response comes back as a status line with timing and size, the headers, and
the body — pretty-printed when it is JSON, because an API's error message is
usually in there and one line of minified JSON hides it. A redirect chain is
kept, hop by hop, since "which hop set that cookie" is a question this is used
to answer.

**Examples…** fills in the typical shapes rather than explaining them: read a
JSON API, send JSON, send a form, PATCH one field, DELETE, fire a webhook,
check a health endpoint, HEAD for headers only, and a Teleport proxy's
`/webapi/ping` with your own proxy already in the URL. Every other tool has its
own examples on the same button — the Teleport port set for a port check, a
reverse lookup for DNS, twenty packets for a ping that flaps.

> A token in a command line is visible to anything that can read the process
> list — the same exposure a hand-typed `curl` has. The alternative, a
> temporary file, leaves it on disk instead.

### Saved requests and recent runs

**Saved** keeps a request whole — method, headers, body, auth — under a name,
because a POST with three headers and a JSON body is not something anyone wants
to retype. Click one to run it; right-click to rename it, copy it as a `curl`
command, or delete it.

**Recent** is every run of every tool, newest first, with the options it was run
with — and where it ran, so the same check from the same server is one click.
A saved request keeps its host the same way, by host rather than by session, so
it still means something tomorrow; if that host has no session open the request
runs from this machine and says so rather than dialling a server because a chip
was clicked. Clicking one runs it again — the same ports, the same packet count, the
same request body — so "check that again" costs one click. Runs that failed are
kept too, since those are the ones most worth repeating after a change. The
same tool against the same target replaces its earlier entry rather than
filling the list with one host.

---

## Interface

- **A guided tour** (*Help → Take the Tour…*, offered once on a first run).
  Sixteen steps that spotlight the real interface — the host list, the filter,
  quick connect, splits, the file browser, multi-exec, the dock, Teleport, keys
  and network tools — and say what each is for and how to use it. The app
  underneath stays live and usable, so nothing has to be undone afterwards, and
  Escape or *Skip tour* leaves at any point.
- **This guide** (*Help → Guide*, `⌘/`) with a section list, a search box that
  marks every hit and steps between them, and buttons to copy or save the whole
  thing. It is the same text as GUIDE.md in the repository, bundled into the
  app so it works from a packaged build.
- **Resizable dialogs.** Network tools and this guide have a drag handle in the
  corner and remember the size you left them at — the useful shape depends on
  what is being read, not on what the dialog is.
- **Saved profiles** with folders, a startup command, and remote/local start
  directories.
- **Themes**: light, dark, or automatic (follows the OS), plus seven accent
  colours. Terminals recolour with the UI.
- **Terminal palettes**, separately from the theme: Solarized dark and light,
  Gruvbox, Nord, Dracula and a high-contrast set. Someone who asked for
  Solarized asked for Solarized whatever colour the sidebar is, so a named
  palette wins over both the theme and any skin.
- **Titles say who and where.** A pane and its tab read `ubuntu@tele1c: ~` or
  `local: /var/log`, and follow the shell as it moves — a row of tabs all saying
  "Local shell" tells you nothing. The directory is read from the shell's own
  *process* rather than by typing `pwd` into your terminal, and only for the tab
  you are looking at. A pane over `tsh` or a beam keeps the directory it started
  in, since a probe there would cost another MFA prompt. Naming the shell as
  well (`zsh: ~`) is a preference, off by default.
- **The window and the panels remember their size**: where the window was, how
  big, whether it was maximised, and the widths of the sidebar, the file panel,
  the dock and the terminal split. The window is checked against the displays
  that exist at launch, so one last used on a monitor you have since unplugged
  is clamped to fit rather than opening somewhere unreachable.
- **Reopening a session** offers your last layout with each tab's panes named as
  `ubuntu@ent: ~/deploy` — who, where, and in which directory. Clicking one row
  reopens just that session and closes the offer; the rest stay saved for next
  launch. A local shell comes back in the directory it was in, and a remote one
  is sent a `cd` once its shell is up.
- **Hide hosts** you never use; show them again from any host's menu.
- Searchable host filter across names, clusters, addresses and
  [tags](#teleport), with a count of how many hosts matched.
- Terminal search (`⌘F`), zoom, and configurable font and scrollback.
- **The dock** along the bottom collects the things that outlive a single
  action: transfers, port forwards, multi-exec runs, the connection log, the
  [download history](#file-browser-and-transfers) and the
  [folders being watched](#file-browser-and-transfers).
- **An external editor** can be named in Settings for *Edit in my editor…*;
  left empty, each file opens in whatever this machine already uses for it.

---

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘N` | New session |
| `⌘⌥C` | Quick connect to a typed address |
| `⌘T` | New local shell |
| `⌘D` | Duplicate tab |
| `⌘⇧D` / `⌘⇧E` | Split right / split down |
| `⌘W` | Close pane |
| `⌘1`–`⌘9` | Jump to tab |
| `⌘⌥←` / `⌘⌥→` | Previous / next tab |
| `⌘⌥D` / `⌘⌥E` | Split with **another** host, right / down |
| `⌘⇧M` | Multi-exec |
| `⌘⇧C` | Command snippets |
| `⌘⇧K` | SSH keys |
| `⌘⇧T` | Network tools |
| `⌘⇧R` | Run a macro on the focused host |
| `⌘⌥N` | New window |
| `⌘⇧L` | Toggle session log |
| `⌘⇧F` | Show/hide local files in this pane |
| `⌘⇧P` | Explorer beside / above the terminal |
| `⌘⇧S` / `⌘⇧O` | Save layout as / load layout |
| `⌘⇧N` | Add a server |
| `⌘F` | Search this pane's scrollback |
| `⌘⇧B` | Toggle broadcast typing |
| `⌘B` | Show/hide the hosts list |
| `⌘E` | Show/hide every file explorer |
| `⌘J` | Show/hide transfers |
| `⌘F` | Find in terminal |
| `⌘K` | Clear terminal |
| `⌕` / typing | Filter the focused file list by name; `↑` `↓` walk the matches |
| `⌘R` | Refresh inventory |
| `⌘Y` / `⌘⇧Y` | Session history / recorded sessions |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / reset |

---

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

For Teleport hosts, ServerLife generates an `ssh_config` with `tsh config` whose
`ProxyCommand` routes through `tsh proxy ssh`. From that point on both host
types are identical to every layer above.

---

---

## Troubleshooting

**macOS: "Apple could not verify 'ServerLife' is free of malware"**
Expected — the build is ad-hoc signed rather than notarised. If you pressed
*Move to Trash*, restore it from the Trash (or download it again) and follow
[macOS install](#macos): clear the quarantine flag before the first launch, or
allow it once under System Settings → Privacy & Security → *Open Anyway*.
Control-click → *Open* stopped working for unnotarised apps in macOS 15.

**Windows: "Windows protected your PC"**
SmartScreen, for the same reason. *More info* → *Run anyway*.

**Sidebar shows "tsh: not logged in"**
Run `tsh login --proxy=your.proxy.com`, then press `⌘R`. Expired profiles get a
*tsh login* button in place of their node list.

**A host connects in a terminal but the file browser says "not connected"**
The node may not offer the SFTP subsystem. Check the *Connection log* tab in the
bottom dock for what the server actually said.

**Connection times out with no prompt**
Open the *Connection log* tab. If authentication is waiting on input, the
connecting pane shows a text box — MFA taps and passwords are answered there.

**X11: `cannot open display`**
Start XQuartz, then launch ServerLife **from a terminal** so it inherits
`DISPLAY`. Settings shows what was detected.

**Native module errors after upgrading Node or Electron**
```sh
make rebuild
```

---
