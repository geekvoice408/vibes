# Fleet

Owner: **fleet**. Ports `dock.js`, `macros.js`, `snippets.js`, `multiexec.js`
and main.js `multiexec:*` / `mxfile:*` / `ansible:*`, plus — because the data
owner stopped — `multiexecfile.js`, `ansible.js` and the js-yaml subset they
need (`Formats/`), and the store.js record methods for snippets, macros,
exec runs and forward favourites (`_FleetDataStandIn.swift`).

## Files

| File | What |
|---|---|
| `FleetFeature.swift` | `install()`: `Slots.dock`, actions, status items, pane-header pins, automation + sidebar hooks, transfer completion notices |
| `DockView.swift` | dock head (6 tabs, Clear, ×); Transfers (pause/resume/retry/reorder/cancel, Pause all, KB/s limit); Connection log; Downloads; Watch; status items |
| `DockTunnels.swift` | Tunnels: favourites (+ New…, Open, Edit, ×, "open" mark), open forwards (☆/★, Copy, Close); `FavoriteEditor` |
| `DockMultiExec.swift` | Multi-Exec: Command / Macros / Recent runs, run as, tag selector (live count, Tags…), failed-hosts box, streaming result cards, Cancel / Save results… |
| `FleetWindow.swift` | per-window multi-exec state and workflow: targets, `loginForTarget`, careful confirm, dialling, retry, rerun/edit, YAML save/load, results, Ansible export; `FleetHistory` |
| `MultiExec.swift` | `MultiExecService.shared` (fan-out over each connection's `execInvocation`, concurrency, timeout, stopOnError, cancel, 400 000-char tail cap) |
| `Macros.swift` | the 20 built-ins, scopes, pins, categories, variables, send/repeat/headless rules |
| `MacroMenu.swift` | the ▶ menu (`run-macro`) | 
| `FleetMenu.swift` | the drop-down used by ▶: rows that run *and* carry a submenu opened from `›`, `?` with its own tooltip |
| `MacroDialogs.swift` | fill-in (with preview), pin icon/scope, repeat interval, editor |
| `MacroList.swift` | pinned-macro header buttons; `FleetSidebarMacros` (the sidebar's `SidebarMacroSource`) |
| `Snippets.swift` | ⌘⇧C library, editor, Run here / Run in all panes, from selection, usage order |
| `FleetRunCommand.swift` | `FleetConn.ensure`; "Run a command…" fallback when `run-command` is not registered |
| `FleetHostPicker.swift`, `FleetUI.swift`, `FleetHooks.swift` | host picker, shared view pieces, hooks |
| `Formats/YAML.swift` | js-yaml 5 presenter port (DUMP schema quoting, block/folded scalars, folding, escapes) + a block-YAML reader (core schema) |
| `Formats/MultiExecFile.swift`, `Formats/Ansible.swift` | multiexecfile.js, ansible.js |

## Action ids

Registered: `multiexec` (args `hostIds` [String] → ticks them), `toggle-multiexec`,
`run-macro` (paneId, else focused; "Open a session first"), `snippets`,
`snippet-from-selection` (args `text`), `snippet-edit` (args `command`),
`dock-show` (args `tab`: transfers|multiexec|forwards|log|downloads|watch),
`macro-edit` (args `macro` JSON — absent = new, or `command`/`name`/`category`/`where`
to seed one; `reply: (JSON?) -> Void` gets the saved record), `forward-favorite-new`.
`fleet-debug-*` exist only under `--snapshot`.

Performed (others own): `send-text` (paneId, text, enter false — the text carries
its own newline), `run-command` (host; args login, command, title, autoRun),
`forward-favorite-open` (args favorite), `tag-browser` (args `getFilter: () -> String`,
`setFilter: (String?) -> Void`), `open-local` (args cwd, `title`), `backup-export`.

Status items: `watches` (50), `forwards` (51), `transfers` (52).

## Hooks set here

`PaneHeaderItems` slot `.macroPins`; `SessionHooks.paneClosing` (stops repeats);
`SessionPane.macroRepeating/macroButtonTitle`; `AutomationHooks.listMacros/runMacro`;
`SidebarHooks.macros`. `FleetHooks` (checked hosts, query, careful, hidden,
preferred login) default to the sidebar's `SidebarWindow.checkedHosts`,
`Tags.compileQuery`, `HostPrefs`; set them to override.

## Notes / differences

- Multi-exec runs each host through `Connection.execInvocation` (ssh -T over the
  ControlMaster, `tsh ssh`, or `tsh beams exec`). The original's runner checked
  a `transport` field it never set, so tsh-transport hosts went through ssh.
- js-yaml 5 ignores v4's `quotingType: '"'`, so the original's files quote with
  single quotes; the port matches (tests compare against output produced by the
  original code).
- Transfer "finished/failed/cancelled" toasts (index.js) are done here.
- Ansible export writes `ssh_config/` through `TeleportSSH.writeClusterSshConfig`
  (no tsh home, as the original's group carried none).
- The ▶ menu anchors under the pointer when clicked, else near the pane's header.
- "Manage macros…" opens the sidebar's Saved → Macros.

## Tests

`Tests/ServerLifeTests/Fleet`: YAML dump goldens (from js-yaml 5.4.2), multiexec
file save/load/results goldens, error wording, ansible.test.mjs (incl. the
`ansible-playbook --syntax-check/--list-hosts` run when installed), variables,
scopes, store records (on a throwaway store).
