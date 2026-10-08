# ServerLife — test plan

## Automated

```sh
make test                  # syntax check, then the unit tests
make test FILTER=folders   # one file's worth
```

The unit tests cover the logic that decides things rather than draws them:
the tag query language (`tests/tags.test.mjs`), the folder model, its rules
and its import/export (`tests/folders.test.mjs`), heartbeat ages and
staleness (`tests/heartbeat.test.mjs`), and the shared odds and ends
(`tests/util.test.mjs`). They import the real modules — nothing is
reimplemented — and run under `node:test` after esbuild has bundled them,
because this package declares CommonJS for the main process while the
renderer is ES modules.

They are deliberately not a UI harness. What they guard is the part where a
wrong answer looks exactly like a right one: a filter that quietly matches
the wrong hosts, a folder that claims a machine it should not, a node
reported as quiet because nobody looked. Anything involving the DOM stays in
the manual plan below.

---

## Manual

Acceptance tests. Each one says what to do, what confirms it worked, and what
a failure looks like.

**Before you start**

```sh
tsh status          # at least one profile not expired
ssh -G ent          # a plain SSH host that resolves
make run
```

You need two reachable hosts on the same Teleport cluster, one on a *different*
cluster (or a plain SSH host), and somewhere writable on each (`/tmp` is fine).

Legend: ✅ pass condition · ❌ what failure looks like

---

## 1. Discovery and inventory

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 1.1 | Launch the app | Sidebar lists Teleport nodes grouped by cluster, and SSH config hosts under **SSH CONFIG** | Empty sidebar, or "tsh: not logged in" while `tsh status` is valid |
| 1.2 | Check the footer | Reads `N nodes · N profiles`, amber if any profile expired | Counts disagree with `tsh ls \| wc -l` |
| 1.3 | Expired profile group | Shows "Session expired" and a **tsh login** button instead of nodes | Expired cluster lists nodes that cannot be reached |
| 1.4 | Type in **Filter hosts** | List narrows on name, cluster, address and labels | Filtering misses a host you can see |
| 1.5 | `⌘R` | Footer count refreshes; a node added with `tsh` since launch appears | Nothing changes |

---

## 2. Connecting

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 2.1 | Double-click a Teleport node | Tab opens, terminal shows the login banner and a prompt | Pane stays on "Connecting…" |
| 2.2 | **Immediately look at the file browser** | Path bar shows the home directory and the listing is populated **within a second or two of connect** | Panel says "Session is idle" or stays blank — this was the v0.1.0 bug where the listing only loaded via the 4s cwd poll |
| 2.3 | Double-click a plain SSH host | Same as 2.1 and 2.2 | — |
| 2.4 | Status bar | Reads `user@hostname · connected` | Stuck on a stale host |
| 2.5 | Open a host with password auth | An input box appears in the connecting pane; typing the password connects | Silent timeout with no prompt |
| 2.6 | Open the same host twice | Second tab attaches instantly (no re-auth); `tsh status` / audit log shows **one** session per host, not one per tab | Re-authentication each time |
| 2.7 | Dock → **Connection log** | Shows the `ssh` command and any server output | Empty for a failed connection |

**Multiplexing check** — the core design claim:

```sh
ls /private/tmp/serverlife-$(id -u)/     # one c-<hash> socket per connection
ssh -O check -o ControlPath=/private/tmp/serverlife-$(id -u)/c-<hash> <target>
# ✅ "Master running (pid=…)"
```

---

## 3. Terminals, tabs and splits

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 3.1 | `⌘⇧D` | Pane splits right, **same** host, new shell prompt | New pane blank or errors |
| 3.2 | `⌘⇧E` | Pane splits down | — |
| 3.3 | `⌘⌥D`, pick a **different** host | Two different servers side by side; run `hostname` in each to prove it | Both panes show the same host |
| 3.4 | `⌘⌥E` with another host | Same, stacked vertically | — |
| 3.5 | Right-click a host → *Open beside current* | Same as 3.3 from the sidebar | — |
| 3.6 | Drag the divider between panes | Both terminals reflow; run `tput cols` to confirm the size changed | Text clipped or not reflowed |
| 3.7 | `⌘⇧B`, then type | `BROADCAST` appears in the status bar and keystrokes land in **every** pane of the tab | Only the focused pane receives input |
| 3.8 | `⌘⇧B` again | Broadcast indicator clears | — |
| 3.9 | `⌘1`…`⌘9`, `⌘⌥←/→` | Tab switching | — |
| 3.10 | `⌘T` | Local shell tab; `uname -a` shows **your Mac** | Opens a remote shell |
| 3.11 | `⌘F`, search for on-screen text | Match highlights | — |
| 3.12 | `⌘K` | Screen clears | — |
| 3.13 | Resize the window | Terminal reflows, `tput cols` tracks it | Fixed-width output |

---

## 4. File browser

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 4.1 | Click `+` on a folder | Expands **in place**, indented, `+` becomes `−` | Navigates into it instead |
| 4.2 | Click `−` | Collapses | — |
| 4.3 | Expand 3 levels, press ⟳ | Tree stays open at the same depth | Tree collapses |
| 4.4 | Select a row, use ↑↓←→ | Arrows walk the flattened tree; ← collapses, → expands | — |
| 4.5 | Double-click a folder | Navigates in; path bar updates | — |
| 4.6 | Type a path in the path bar, Enter | Navigates there | — |
| 4.7 | `↑` / `‹` / `›` buttons | Parent, back, forward | Back/forward jump to wrong place |
| 4.7b | `⌖` **Go to a path** | Dialog with a path field, quick places and recent directories; picking one navigates there | — |
| 4.8 | Toggle `•` (hidden files) | Dotfiles appear/disappear; footer count updates | — |
| 4.9 | Open a dir containing **only** dotfiles | Says *"Nothing visible — N hidden items"* with a **Show hidden files** button (not a bare "Empty directory") | Claims the directory is empty |
| 4.10 | `cd /var/log` in the terminal, wait ~5s | Browser follows to `/var/log` (⇲ enabled) | Browser stays put — check the cwd probe |
| 4.11 | Turn ⇲ off, `cd` again | Browser does **not** move | — |
| 4.12 | Right-click a file → *Edit / preview* | Contents open; Save writes back — verify with `cat` in the terminal | Save silently fails |
| 4.13 | Right-click → *Permissions…*, set `0644` | `ls -l` in the terminal shows `-rw-r--r--` | — |
| 4.14 | Right-click → *Rename…* | Name changes in place | — |
| 4.15 | Create a dir, put a file in it, delete the dir | Recursive delete after a confirmation that lists what goes | Deletes without confirming |
| 4.16 | In the **terminal**, `touch newfile`; don't touch the browser | Appears in the list within ~5s on its own | Only appears after ⟳ |
| 4.17 | Select a row, expand a folder, scroll, then `touch` another file remotely | List updates but selection, expansion and scroll position are **kept** | Selection lost or view jumps |
| 4.18 | Settings → *Refresh the file list* → **Off**; `touch` another file | List does **not** change until you press ⟳ | Still polling |
| 4.19 | Set it back to 5 seconds | Polling resumes without a restart | Needs a relaunch |

---

## 4b. Explorers per session, and local files

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 4b.1 | Open one session | A file explorer sits **beside** its terminal in the same pane, already listing the home directory | No explorer, or it is empty until you press ⟳ |
| 4b.2 | Split with a **different** host | Each pane has its **own** explorer; the dropdowns read "This session: <that host>" | Both explorers show the same server |
| 4b.3 | `⌘⇧P` | Explorers move **above** their terminals; again to go back beside | Layout unchanged |
| 4b.4 | `⌘E` | All explorers hide; again to show | — |
| 4b.5 | Click a pane's ☰ button | Only that pane's explorer toggles | Toggles all |
| 4b.6 | `⌘⇧F` (or the 💻 button) | The **local** filesystem appears *below* the session's files, in the same pane — both visible, terminal still there | Opens a separate pane, or replaces the remote list |
| 4b.7 | Drag a file from the local list to the session list | Uploads; status bar confirms | — |
| 4b.8 | Drag a file from the session list to the local list | Downloads; status bar confirms | — |
| 4b.9 | Drag the divider between the two lists | Resizes; terminal unaffected | — |
| 4b.10 | Change an explorer's dropdown to another open session | Shows that server's filesystem | — |
| 4b.11 | Right-click a **file** in an explorer | File menu: Edit/preview, Download, Copy to another server, Upload, New folder, Rename, Permissions, Delete, Copy path, cd here | The *terminal* menu (Copy/Paste/Split) appears — regression |
| 4b.12 | Right-click the **terminal** | Terminal menu, not the file menu | — |

---

## 5. Transfers

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 5.1 | Drag a file from Finder onto the remote pane | Transfers panel shows progress; **status bar says `Uploaded <name> — <size> at <rate>`** on completion; a success toast appears | No confirmation, or progress bar never completes |
| 5.2 | Verify the upload | `sha256sum` on the remote matches `shasum -a 256` locally | Hashes differ |
| 5.3 | Drag a **folder** from Finder | Whole tree uploads; `find` on the remote shows the same structure | Flattened or missing files |
| 5.4 | Drop onto a **folder row** (not the pane) | File lands *inside that folder* | Lands in the current directory |
| 5.5 | Right-click a remote file → *Download* | Downloads; status bar says `Downloaded …`; hash matches | — |
| 5.6 | Download a large file, hit **×** mid-transfer | Job shows `cancelled`; partial file is not presented as complete | Cancel ignored |
| 5.7 | Transfer ~100MB | Rate is tens of MB/s, not ~1MB/s (pipelining works) | Very slow — pipeline depth regression |
| 5.8 | Upload to a read-only dir | Job shows `error` with the server's message; error toast | Silent failure |

---

## 6. Two explorers and server-to-server

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 6.1 | Click `⇅` | Second pane appears | — |
| 6.2 | Second pane dropdown → another **session** | That server's filesystem loads in the lower pane | Stays on local |
| 6.3 | Top pane dropdown → *Pinned: <host>* | Top pane stops following focus; switch tabs to confirm it stays put | Follows anyway |
| 6.4 | Click `▤` | Panes go **side by side**; click again for stacked | Layout does not change |
| 6.5 | Drag a file from one server's pane to the other's, **same Teleport cluster** | Confirmation says *direct*; transfer completes; hash matches on the destination | Offers to relay when a direct hand-off was possible |
| 6.6 | Same across **different clusters** or to a plain SSH host | Dialog says it will **relay through this machine** and asks; on accept it completes and the hash matches | Relays without asking |
| 6.7 | Cancel at the relay confirmation | Nothing transfers | Transfers anyway |
| 6.8 | Right-click → *Copy to another server…* | Same routing, with a destination directory field | — |
| 6.9 | After a relay, check `$TMPDIR` | No leftover `serverlife-relay-*` directories | Temp files left behind |

---

## 7. Multi-exec

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 7.1 | Tick 3 hosts, `⌘⇧M`, run `hostname` | Three result cards, each with the **correct distinct** hostname, exit code 0 and a duration | Same hostname repeated |
| 7.2 | Run `sleep 3` on 5 hosts | Total wall time ≈3s, not ≈15s (concurrent) | Serialised |
| 7.3 | Include an unreachable host | It reports `error` with a message; the others still complete | One dead host blocks the run |
| 7.4 | Run `exit 3` | Card shows `exit 3` and is marked failed | Reported as success |
| 7.5 | Run something slow, click **Cancel** | Remaining hosts show `cancelled` | Keeps running |
| 7.6 | Tick nothing with sessions open | Falls back to all open sessions (the hint says so) | Errors out |
| 7.7 | **Save YAML…** | File written; open it — `command` is a `\|` block, `targets` lists each host with cluster/proxy | Malformed or missing hosts |
| 7.8 | Change the selection, then **Load YAML…** | Command restored **and** the original hosts re-ticked | Hosts not re-selected |
| 7.9 | Load a YAML naming a host you no longer have | Toast names the missing hosts; the rest still load | Silent partial load |
| 7.10 | On a finished run, **Save results…** | YAML with `summary`, per-host `status`, `exitCode`, `stdout` | — |
| 7.11 | **Ansible…** export, then `cd` there and `./run.sh` | Playbook runs against the same hosts and returns the same output | Inventory unusable |

---

## 8. Port forwarding

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 8.1 | Right-click host → *Port forward…*, Local, `18080` → `localhost:22` | Toast confirms; **Tunnels** dock lists it | — |
| 8.2 | Prove it carries traffic | `nc -v localhost 18080` prints the remote **SSH banner** | Connection refused |
| 8.3 | **Close** the tunnel | `nc localhost 18080` now refuses | Port stays open |
| 8.4 | Dynamic `-D` on `18081` | `curl --socks5 localhost:18081 https://example.com` succeeds | — |
| 8.5 | Open a tunnel, then open a new terminal tab | No re-authentication (it rides the existing connection) | Prompts again |
| 8.6 | Take a used local port | Clear error, no phantom entry in the list | Silent failure |

---

## 9. X11

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 9.1 | With XQuartz **not** running, right-click → *Open with X11 forwarding* | Warns that no X server was detected, offers to continue | Connects and fails cryptically later |
| 9.2 | Start XQuartz, relaunch ServerLife **from a terminal**, retry | Session opens; `echo $DISPLAY` on the remote is set (e.g. `localhost:10.0`) | `DISPLAY` empty |
| 9.3 | Run `xeyes` | Window appears on your Mac | `cannot open display` |
| 9.4 | Settings → X11 trusted (`-Y`), reconnect | Works for apps that reject untrusted mode | — |

---

## 9b. Per-session MFA

Needs a node whose role requires MFA per session (e.g. `mfa-node`).

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 9b.1 | Open it normally (double-click) | Fails with `too many authentication failures`, **and the pane offers "Connect with MFA (tsh ssh)"** | Just a Retry button with no explanation |
| 9b.2 | Click that button (or right-click the host → *Open with MFA (tsh ssh)*) | Terminal shows `MFA is required to access node …` and the WebAuthn prompt; tapping the key logs you in | No prompt appears |
| 9b.3 | Look at the file explorer on that session | Approves MFA **once**, then lists the home directory | Stays empty or errors |
| 9b.4 | Browse to `/etc` on that session | Lists immediately, **no new MFA prompt** | Prompts again per directory |
| 9b.5 | Download a file, then upload one | Both complete; hashes match | Fails |
| 9b.6 | Settings → MFA method → Touch ID | Used for the next MFA session (`--mfa-mode=platform` in the connection log) | Falls back to auto |
| 9b.6b | Watch the prompts | **One** prompt at a time: the terminal first; the file list waits behind *Load files (approve MFA)* | Two OS prompts appear and cancel each other |
| 9b.6c | Cancel the Touch ID prompt | Pane offers Retry / Security key / OTP / Browser / Copy tsh command — not a dead terminal | Terminal just ends |
| 9b.6d | Approve it instead | Shell opens; **no** overlay covers the working terminal | Overlay hides a session that worked |
| 9b.6e | After connecting once, look at the sidebar | Host shows an `mfa` badge; opening it again goes straight to tsh | Fails on the shared path again |
| 9b.6f | Right-click → *Forget that this needs MFA* | Badge clears; next open uses the shared connection | Still forced to tsh |
| 9b.7 | Port forward on that session | `tsh ssh -L` tunnel opens after an MFA tap and carries traffic | — |
| 9b.8 | A **non**-MFA Teleport node | Still uses the shared connection — one auth for terminal, files and tunnels | Prompts per channel |

---

## 10. Teleport specifics

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 10.1 | Teleport tab | Every profile listed with cluster, user, expiry, node count | Missing a profile `tsh status` shows |
| 10.2 | **Switch to** another profile | Becomes active; `tsh status` agrees | — |
| 10.3 | Connect to nodes on **two different clusters at once** | Both work simultaneously regardless of which profile is "active" | Second cluster fails |
| 10.4 | Teleport → *tsh login…* | Proxy, user, auth connector, cluster, TTL, MFA mode; the **command preview** updates as you type | Preview wrong |
| 10.5 | **Requests** on a profile | Existing requests listed with state | — |
| 10.6 | Create a request, have it approved, **Assume roles** | Profile shows the assumed request; new roles are usable | — |
| 10.7 | **Drop** it | Roles removed; `tsh status` agrees | — |
| 10.8 | `⌘⇧Y` Recorded sessions | Sessions listed with node, user, duration | Empty while `tsh recordings ls` returns rows |
| 10.9 | **Play** a recording | Opens a tab replaying it via `tsh play` | — |
| 10.10 | **Web UI** | Browser opens the recording in Teleport | Wrong URL |
| 10.11 | `⌘Y` history | Every session you opened, **including plain SSH**, with durations; failures recorded too | Only Teleport sessions |

---

## 10b. Searching recorded sessions

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 10b.1 | Sessions → **Search transcripts**, pick a cluster, search a word you know appears | Matching sessions listed with the hit lines in context, term highlighted | "No session mentioned…" for a word you can see in a recording |
| 10b.2 | Try each time range | All work, including **Last 180 days**; progress counts up as it scans | An error about the date range — tsh takes dates (`YYYY-MM-DD`), not timestamps |
| 10b.3 | Search a nonsense string | 0 matches, with a note about skipped non-interactive sessions | A crash or a silent blank |
| 10b.4 | Tick **Download to folder**, search again | Every scanned transcript written there, named by date/host/id | Nothing written |
| 10b.5 | **Play** / **Web UI** / **Save transcript** on a result | Replays in a tab / opens Teleport / writes a .txt | — |
| 10b.6 | Start a wide search, click **Stop** | Stops promptly, keeps what it found | Runs to completion |

---

## 10c. Defining new servers

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 10c.1 | `⌘⇧N`, fill in host/user/key, **Test connection** | Toast naming the user, hostname and kernel that answered | Silent, or a misleading success |
| 10c.2 | Choose **Save in ServerLife only**, add it | Appears in **Saved**; double-click connects, terminal and explorer both work | Cannot connect without an ssh_config entry |
| 10c.3 | Choose **Write to ~/.ssh/config**, add it | Appears under SSH CONFIG; `ssh -G <alias>` from a terminal resolves it | Not visible to plain ssh |
| 10c.4 | Inspect `~/.ssh/config` | New entry sits inside the ServerLife markers; **your own entries are untouched**; `~/.ssh/config.serverlife-backup` exists | Your config reformatted or reordered |
| 10c.5 | Add a host whose alias already exists outside the block | Refused, with the option to override deliberately | Silently shadows your entry |
| 10c.6 | Add the same alias twice | One entry, updated in place — not duplicated | Two `Host` blocks, or a repeated header comment |
| 10c.7 | Right-click → *Remove from ~/.ssh/config* | Entry gone; the rest of the file byte-identical | Leftover empty marker block |

---

## 10d. Quick connect

Nothing here should write to `~/.ssh/config` or the profile store. Check the
file and the **Saved** tab afterwards to be sure.

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 10d.1 | `⌘⌥C`, type `user@host`, **Test connect** | Result box names the user, host, kernel and uptime that answered; `ssh -O check` shows no master left behind | A connection left open, or a silent failure |
| 10d.2 | Same dialog, **Connect** | Session tab opens, explorer attaches, one authentication | A second dial, or no file browser |
| 10d.3 | Type `uptime` in **Single command**, **Run command** | Output in the dialog, no tab opened, connection closed after | A terminal opens, or the master persists |
| 10d.4 | With a command still in the box, **Connect** | Session opens *and* runs the command at its prompt | Command ignored |
| 10d.5 | Paste `ssh -p 2222 -i ~/.ssh/k -J bastion user@host uptime` | Address normalises to `user@host:2222`; key, jump host and command land in their own fields | Details used but not shown, or the port lost |
| 10d.6 | Paste an address on a non-22 port, connect, then reopen it from **Recent** in `⌘N` | Same port, key and jump host; reuses the open connection rather than dialling a second | Dials port 22, or opens a duplicate connection |
| 10d.7 | Quick-connect to two different ports on one machine, open `⌘N` | Two distinct Recent rows | Collapsed into one |
| 10d.8 | Reopen `⌘⌥C` | Last address prefilled and selected; the last dozen offered as suggestions | Forgotten, or the field not selected |
| 10d.9 | Type an address into `⌘N`'s search box | A **Quick connect** row last in the list; Enter on a real match still opens that match | The quick row steals Enter |
| 10d.10 | **Save as server…** | Add-server dialog opens with the host, user, port, key and jump host filled in | Empty dialog |
| 10d.11 | Clear history (Sessions → *Clear history*) | Quick connect's suggestions go too | Addresses left behind |
| 10d.12 | Enter nonsense (`two words`, `host:99999`) | Refused with a toast; nothing dialled | A dial attempt on a malformed address |

---

## 10e. Filtering a file list

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 10e.1 | In an explorer, press `⌕` | Filter row appears, tinted, focused; the button lights | No row, or focus stays in the list |
| 10e.2 | Type `log` | Only names containing `log` — `mylog.txt` included; status says `N filtered out` | Anchored match, or a silent count |
| 10e.3 | Type `*.log` | Only names ending `.log`; `mylog.txt` gone | Treated as a substring |
| 10e.4 | Type `ID_` | Matches `id_rsa` — case-insensitive | Case-sensitive |
| 10e.5 | With matches showing, press `↓` then `↑` **in the filter box** | Selection moves through the matches only, scrolling into view; focus stays in the box | Selection leaves the matches, or focus jumps |
| 10e.6 | Press `↓` past the last match | Clamps to the last match | Wraps, or selects a filtered-out row |
| 10e.7 | Press Enter on a selected folder | Navigates into it | Nothing, or opens the wrong entry |
| 10e.8 | Filter to one match, press Enter with nothing selected | Opens that match | Requires an arrow key first |
| 10e.9 | Type something matching nothing | `No name matches “…”` with a **Clear the filter** button | Bare "Empty directory" |
| 10e.10 | Press Escape in the filter box | Filter clears, full list returns; Escape again closes the row | Row closes with the filter still applied |
| 10e.11 | With the list focused, just type a letter | Filter row opens, seeded with it (type-ahead) | Keystroke lost |
| 10e.12 | With the list focused, press `⌘R` / `⌃R` | Does **not** type into the filter | Modified keys leak into the filter |
| 10e.13 | With a filter active, `⌘A` | Selects only the matches | Selects filtered-out entries too |
| 10e.14 | Expand a folder, filter on a **child's** name | The child shows and its non-matching parent is kept | Parent hidden, taking the match with it |
| 10e.15 | Filter one explorer with two open | Only that one filters | Both filter |

---

## 11. Keys and known hosts

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 11.1 | `⌘⇧K` | Keypairs listed with fingerprint and type; agent status shown | Missing a key that is in `~/.ssh` |
| 11.2 | `chmod 644 ~/.ssh/somekey`, reopen | That key is flagged **PERMISSIONS** | Not flagged |
| 11.3 | **Generate new key…** | Created; `ssh-keygen -l -f ~/.ssh/<name>.pub` matches the shown fingerprint | — |
| 11.4 | **Install on server…** | Key appended to the remote `~/.ssh/authorized_keys`; verify with `tail` | — |
| 11.5 | Install the same key again | Reports *already installed*; no duplicate line | Duplicated |
| 11.6 | **Add to agent** | `ssh-add -l` lists it | — |
| 11.7 | Right-click host → *Forget host key…* | Lists the entries and asks; after accepting, `ssh-keygen -F <host>` finds nothing | Removes without asking |
| 11.8 | *Local* group in the host list | An **SSH keys** row between *Local shell* and *Network tools*; double-click opens the same view as `⌘⇧K` | Row missing |
| 11.9 | Right-click that row → *Browse ~/.ssh…* | Local file list opens at `~/.ssh` (and does not toggle shut if already open) | Panel closes, or opens at home |
| 11.10 | With `tsh login` done, open the keys view | Banner's count is explained (`N from ~/.ssh and M from elsewhere`); an **In the agent only** section lists the Teleport identities by *user @ cluster* | A count with nothing behind it |
| 11.11 | Compare that section's count with `ssh-add -l \| wc -l` | Header reads `X identities, Y entries` when `tsh` has loaded each key twice; fingerprints match | Duplicate-looking rows, or counts that disagree |
| 11.12 | A passphrase-protected key | Tagged **passphrase**; adding it asks for one first. An unprotected key is tagged **no passphrase** and adds with no prompt | Mislabelled, or ssh-add stalls |
| 11.13 | Wrong passphrase | *Incorrect passphrase* — promptly, not after a timeout | Hangs |
| 11.14 | **Run ssh-add** (footer) | Default identities added; `ssh-add -l` agrees | — |
| 11.15 | `kill` the agent (`SSH_AUTH_SOCK` unset/stale), reopen | Amber dot, *not reachable*, and a **Try ssh-add** button that reports the real error. Per-key *Add to agent* still offered | Buttons hidden, leaving no way to try |
| 11.16 | Rename `ssh-add` out of `PATH` (or test on Windows without OpenSSH) | Red dot, *ssh-add not found*, keys still listed from `~/.ssh`; nothing throws | Crash, or a broken-agent message |
| 11.17 | A key named by `IdentityFile` in `~/.ssh/config` | Card says which hosts use it | Not shown |

---

## 12. Sessions, layout, appearance

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 12.1 | `⌘⇧L` on a remote terminal | Prompts for a file; status bar confirms logging | — |
| 12.2 | Type commands, `⌘⇧L` again, open the file | Readable plain text, **no escape sequences** | Full of `\x1b[` junk |
| 12.3 | Open several tabs/splits, quit, relaunch | Asks *"Reopen your last session?"* listing the tabs | Reopens silently, or forgets |
| 12.4 | Choose **Reopen** | Tabs and splits come back with the same hosts | Wrong arrangement |
| 12.5 | Choose **Start fresh** | Empty workspace; the offer returns next launch | Layout discarded |
| 12.6 | Tick *Always restore*, relaunch | Restores without asking | — |
| 12.7 | Settings → Theme **Light** | UI **and terminals** turn light immediately | Terminal stays dark |
| 12.8 | Theme **Automatic**, flip macOS appearance | Follows the system live | — |
| 12.9 | Change accent colour | Highlights recolour; survives restart | Not persisted |
| 12.10 | Right-click host → *Hide from list* | Disappears; *Show hidden hosts* brings it back struck through | — |
| 12.11 | Right-click host → *Server profile…* | Distro, kernel, CPU, memory, disk, package manager — cross-check with `cat /etc/os-release` | Wrong or blank |
| 12.12 | Save a profile with a startup command and remote start folder, launch it | Connects, `cd`s there, runs the command | Ignored |
| 12.13 | Close all tabs | Idle animation returns (orbiting servers, "servers are life · life is servers") | Blank pane |
| 12.14 | Help → About, then **Version history** | Version 0.1.0, platform, tsh version, multiplexing state; history lists the release | — |

---

## 12b. Context menus (regression check)

Right-click menus are driven by real mouse input, and a synthetic `.click()`
will **not** reproduce a bug here — a real press fires `mousedown` first. Test
these with an actual mouse.

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 12b.1 | Right-click a host, click **Open session** with the mouse | Menu closes **and** the session opens | Menu closes and nothing happens — the v0.1.0 bug where the dismiss handler removed the menu before the click landed |
| 12b.2 | Right-click a host, click *Open beside current* | Splits with that host | Nothing happens |
| 12b.3 | Right-click a file in the browser, click any item | Action runs | Nothing happens |
| 12b.4 | Right-click inside a terminal, click **Copy**/**Paste** | Works | — |
| 12b.5 | Open a menu, click **outside** it | Menu dismisses, nothing else triggers | Menu stays open |
| 12b.6 | Open a menu, press **Escape** | Dismisses | — |

---

## 12c. Snippets and layouts

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 12c.1 | `⌘⇧C` → New snippet, save a command | Appears in the list | — |
| 12c.2 | **Run here** | Command is typed into the focused terminal and executed | Goes to the wrong pane |
| 12c.3 | Split into two panes, **Run in all panes** | Runs in every remote pane of the tab | Only one |
| 12c.4 | Select text in a terminal → right-click → *Save selection as snippet* | Editor opens pre-filled | — |
| 12c.5 | Use one snippet repeatedly, reopen the list | It has risen to the top (ordered by use) | — |
| 12c.6 | Session → Layouts → **Save Layout As…** | Name suggested from the open tabs; saves | — |
| 12c.7 | Close everything, **Load Layout…**, pick it | Tabs and splits come back with the same hosts | Wrong arrangement |
| 12c.8 | **Manage Layouts…** → Set default | Marked "opens by default" | — |
| 12c.9 | Quit and relaunch | Offers to open the **default layout** by name | Offers the generic snapshot instead |
| 12c.10 | Rename and delete a layout | Both take effect | — |

---

## 12d. Guided tour

`tourSeenVersion` in the settings store gates the first-run offer; set it to `0`
to get it back.

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 12d.1 | Reset `tourSeenVersion` to 0 and relaunch | Offer appears **after** any restore-layout prompt, never both at once | Two dialogs competing |
| 12d.2 | Choose *Not now* and relaunch | Not asked again | Asked every launch |
| 12d.3 | Choose *Take the tour* | Step 1 of 13, centred | — |
| 12d.4 | Step through with **Next** | Each anchored step's spotlight sits on its element; the card stays fully on screen | Spotlight on the wrong element, or a card off screen |
| 12d.5 | Steps 2–4, 6–12 | Sidebar, host filter, `+` button, panes, the three title-bar buttons, the Teleport tab, the SSH keys and Network tools rows each get the ring | A step silently centres when its target is visible |
| 12d.6 | `←` `→` and Enter | Move back and forward; Enter on the last step finishes | Keys ignored |
| 12d.7 | Escape, and *Skip tour* | Closes immediately, leaving the app exactly as it was | State changed, or overlay stuck |
| 12d.8 | Click a dot | Jumps to that step | — |
| 12d.9 | While the tour is open, click the app behind it | Still usable — the overlay does not swallow clicks (only the card does) | App inert |
| 12d.10 | Resize the window mid-tour | Spotlight and card follow | Ring left behind |
| 12d.11 | Run it with the sidebar collapsed (`⌘B`) | Steps whose target is hidden centre instead, and still read sensibly | Ring at 0,0 or off screen |
| 12d.12 | *Help → Take the Tour…* any time | Runs again; invoking it twice does not stack two overlays | Two tours at once |
| 12d.13 | Finish the tour | `tourSeenVersion` is 1 | Offered again next launch |

---

## 13. Failure handling

| # | Do this | ✅ Confirms | ❌ Failure |
|---|---|---|---|
| 13.1 | Connect to an offline host | Pane shows *Connection failed* with the real reason and a **Retry** | Generic or blank error |
| 13.2 | Connect with an expired `tsh` profile | Group shows expired with a login button, not a confusing SSH error | — |
| 13.3 | Mid-session, run `pkill -f "ControlPath.*<hash>"` | Within ~15s the session reports the connection was lost | Hangs forever |
| 13.4 | Kill the network mid-transfer | Job goes to `error` with a message; app stays usable | App hangs |
| 13.5 | Browse a directory you cannot read | Permission error shown in the pane | Blank pane |

---

## 14. Packaging

```sh
make verify            # ✅ "All sources parse."
make dist-mac          # ✅ release/ServerLife-<v>-macOS-arm64.dmg
open release/*.dmg     # ✅ drags to Applications, launches, no Gatekeeper hard block
```

| # | Check | ✅ |
|---|---|---|
| 14.1 | Launch the **packaged** app | Starts, menu bar reads **ServerLife** (not "Electron") |
| 14.2 | Open a session in it | node-pty works from inside the asar (`app.asar.unpacked/node_modules/node-pty` present) |
| 14.3 | `make check-cross` | Honestly reports what this machine can cross-build |
| 14.4 | Push a tag | CI builds macOS arm64, Linux x64+arm64, Windows x64 |

---

## Known limitations — not bugs

- **Windows**: no ControlMaster, so each terminal/transfer dials its own
  connection. Password and per-session-MFA hosts will prompt repeatedly. Shown
  in About as *Connection multiplexing: unavailable*.
- **Follow-terminal-folder** picks the newest interactive shell on the host. With
  several shells open as the same user it may follow a different one.
- **`tsh scp` server-to-server** is undocumented Teleport behaviour. If it stops
  working, the relay path still does.
- Sessions recorded with mode `off` cannot be replayed and are marked so.
- macOS builds are signed but **not notarised** unless Apple credentials are
  supplied to CI.
