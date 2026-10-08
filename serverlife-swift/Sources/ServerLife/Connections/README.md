# Connections

Port of `src/main/connections.js`, the local-shell half of `local.js`,
`authprobe.js`, the `conn:*` / `term:*` / `localterm:*` / `forward:*` (not
favourites) / `x11:status` / `ssh:authProbe` / `tools:status` handlers of
`main.js`, and the dialling helpers of `teleport.js`. `sshbin.js` lives in
`Core/Tools.swift` and is used from here.

No UI actions are registered: sessions and the sidebar own the interface.

## Files

| File | What |
|---|---|
| `ConnectionManager.swift` | `ConnectionManager.shared`, `ConnPrefs` (agent forwarding host → cluster → global, `hostUsers`, `mfaHosts`), Store accessors |
| `Connection.swift` | `Connection`: ControlMaster on a pty, state machine, exec, SFTP channel, terminals, logging, forwards, server profile, shell history, rsync transport, `tsh scp` |
| `ConnSpec.swift` | `ConnSpec`: everything argv — ssh/tsh/beam, X11, -A/-C, direct hosts, `-F`, `-J`; `ConnRuntime` (runtime dir, control paths) |
| `ConnText.swift` | prompt / MFA-failure detection, `cleanupError`, `firstProblem`, `stripAnsi`, the probe scripts and their parsers |
| `ConnNetProbes.swift` | `hostTools`, `hostFacts`, `probeTcp` (`ssh -W`), `probePorts`, `hostPing`, `hostTrace`, `withSocks` (for nettools) |
| `RemoteTerminal.swift` | `RemoteTerminal: TerminalBackend` (`ssh -tt` / `tsh ssh` / `tsh beams ssh`), session-log tee |
| `TeleportSSH.swift` | `writeClusterSshConfig`, `sshTarget` (teleportSshTarget), `isLeafCluster`, `listClusters`, `homeName` |
| `LocalShells.swift` | local shells: list, login shell, blank starts, commands (`tsh play` …) |
| `AuthProbe.swift` | `ssh -vv` auth probe + summary; `X11Status`; `ToolsStatus` |

## ConnectionManager (`@MainActor @Observable`, `.shared`)

- `connections: [Connection]` (creation order), `connection(id)`, `require(id)` (throws "No such connection: …").
- `create(host:options:) async throws -> Connection` — applies host prefs
  (`agentForward` nil → host/cluster/global; `login` nil → `settings.hostUsers`).
  Beams → `.beam`; no ssh client → Teleport forced to tsh (`transportForced
  "no-ssh"`), plain ssh throws; Teleport leaf cluster → tsh (`"leaf"`); otherwise
  writes the cluster's `tsh config` into `ConnRuntime.configDir` and uses `-F`.
  `options.reuse` (default **false**) returns `find(host:login:)` when no x11/transport was asked for.
- `find(host:login:)` (findConnectionForHost), `findOpen(name:beam:cluster:login:)` (targetConnection's reuse rule).
- `connect(id)` — dials; records history (failed attempts too). An MFA-looking
  failure on a Teleport node throws `AppError` with `code == "mfa"` (the
  original appended `" [mfa]"`) and sets `connection.lastErrorMfaLikely`.
- `disconnect(id)` / `disconnectAndWait(id)` — ends history, runs `willRemove`
  hooks (files-service: stop watchers), `ssh -O exit`, removes it.
- `writeMaster(id, text)`; `exec(id, cmd, timeout:)` throws the reason on
  failure (as `conn:exec`); `execResult(id, …)` never throws for a failed command.
  `ExecResult`: code, stdout, stderr, durationMs, timedOut, error.
- `openSFTPChannel(id) -> ByteChannel` (`ssh -s sftp`; `tsh ssh … sftp-server`
  after logging "Opening a file channel (approve MFA once)."; `tsh beams exec …
  sftp-server`). A new channel per call — cache it in files-service. On tsh, a
  channel the far side closed makes the next open throw "The file channel
  closed. Press Refresh to reopen it (needs MFA approval)."
- `openTerminal(id, options:) -> TerminalBackend` (a `RemoteTerminal`).
  `TerminalOptions`: id, cols, rows, command, startupCommand, remoteStartPath —
  **the last two are typed into the shell by openTerminal** (as connectPane
  did); do not send them again.
- `addForward(id, ForwardSpec)`, `removeForward(id, fwdId)`, `listForwards(id?)`, `allForwards()`.
- `serverInfo(id, refresh:)`, `shellHistory(id, limit:refresh:)`.
- `startLog(id, termId:, path:)`, `stopLog`, `logState`; `Connection.defaultLogFileName` for the save dialog.
- `terminalCwd(id, termId:)`, `x11Status()`, `toolsStatus()`, `authProbe(target:options:)`, `list()` (conn:list JSON).
- Events: `subscribe { ConnEvent in }` → `.state`, `.log`, `.info`,
  `.forwards`, `.serverInfo`, `.logging`, `.terminalExit`, `.changed`.
- `startHistory` / `endHistory` closures default to writing `history` exactly
  like store.js; data may replace them.
- `shutdown(cap:)` — installed on `AppDelegate.willTerminate` (with
  `LocalShells.shared.closeAll()`): children torn down on the main actor, then
  every master's `ssh -O exit` in parallel off the main thread, ~6 s cap overall.

## Connection (`@MainActor @Observable`)

Observed: `state` (`ConnState`: idle/connecting/prompting/connected/error/closed),
`lastError`, `log: [ConnLogLine]` (≤500; stream "out"/"sys"), `info`
(homeDir/user/hostname), `forwards`, `prompt` (latest prompt line while
prompting), `lastErrorMfaLikely`, `serverInfo`, `terminalIds`, `logging`.
Descriptive: `id`, `spec`, `host`, `label`, `target`, `type`
("ssh"/"teleport"/"beam"), `transport` (`.mux/.tsh/.beam`), `transportKind`,
`transportForced`, `tshByNecessity`, `login`, `x11`, `controlPath`, `historyEntry`.

Also: `connect()`, `checkMaster()`, `exec(_:timeout:keepOutput:)`,
`execResult(_:timeout:) -> ProcResult` (tmux layer), `execReport`,
`execInvocation(cmd)` (exe/args/env, for multi-exec's own processes),
`spawnCommandPTY(_:cols:rows:) -> PTYProcess` (tmux; no X11),
`spawnCommandPipe(_:onData:onExit:)` (beams), `sshArgs`, `tshArgs`,
`beamArgs`, `procEnv`, `rsyncTransport()`, `tshScp(_:localPaths:remotePaths:)`,
`hostTools`, `hostFacts`, `probeTcp`, `probePorts`, `hostPing`, `hostTrace`, `withSocks`.

Behaviour kept from the original: one foreground master on our pty
(`ControlPersist=no`), `PROMPT_RE` → prompting, socket polled every 0.6 s,
120 s timeout ("Authentication is still waiting for input." / "The host did
not respond."), live socket reused / dead socket removed, health check every
15 s asked twice before declaring "Control connection lost", master exit →
"Connection closed" and children torn down, a finished attempt never reused.
Identity probe after connecting. tsh/beam are "connected" immediately.
terminalCwd only over the mux. Server profile refused on tsh-for-MFA (not on
tsh by necessity). Beams refuse forwards with the original's message.

## LocalShells (`.shared`)

`shells() -> [ShellInfo]` (path, name, canBlank, isDefault, note);
`open(shell:blank:cwd:cols:rows:) -> TerminalBackend` (a `LocalTerminal` wrapping `PTYBackend`, kind
"local"; cwd of the shell's own pid, not the foreground group); `openSession(…, command:args:
teleportHome:env:)` returns the shell actually started and runs programs
(kind "command"). Blank: bash `--noprofile --norc`, zsh `-f -d`, fish
`--no-config`, tcsh/csh `-f`, ksh `-p`, with `SERVERLIFE_BLANK_SHELL=1`;
otherwise a login shell (`-l`).

## TeleportSSH

For teleport-service: `writeClusterSshConfig(dir:proxy:cluster:home:)`,
`clusterSshConfigText`, `sshTarget(_:login:)`, `isLeafCluster`,
`listClusters`, `recordClusters` (feed the leaf cache from your own listing),
`homeName`, `expandHome`, and `defaultHome` — the one `DEFAULT_HOME`
($TELEPORT_HOME expanded, else `~/.tsh`); Teleport/Service uses it too.

Remote commands run through `ConnRun` (Proc.run plus the killing signal), so
a killed command reads "The command was killed on <host> (SIGTERM)."; a master
killed before its socket was up reads "Connection failed (ssh exited with code
N, signal SIG…)" (PTYProcess reports 128+N for signal N).

## Differences / not done

- Runtime dir is `$TMPDIR/sl-<uid>` (not `serverlife-<uid>`) so the Electron
  app and this one never share control sockets; it is no longer than the
  original's, so ControlPath fits macOS's 103-character socket limit even
  with a 10-digit uid.
- `direct.extraOptions` (Core `DirectSpec`) is read through its `options` lines.
- The transfer queue (`conn.queue`) belongs to files-service.
- `tsh beams` publish etc. are teleport-service's.
- Windows (no-mux) branches are omitted.
- `sshPath` changes are applied on settings change here; `tshPath`/`tshHomes` are teleport-service's.
