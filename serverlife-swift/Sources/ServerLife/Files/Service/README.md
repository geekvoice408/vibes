# Files service

Owner: **files-service**. The port of `sftp.js`, `transfers.js`, `crosstransfer.js`,
`syncdirs.js`, `watchdirs.js`, `findfiles.js`, `fsx.js`, `filekinds.js`, `rsync.js`,
the local-filesystem half of `local.js`, and main.js's `sftp:*`, `local:*`, `xfer:*`,
`sync:*`, `watch:*`, `downloads:*` and `rsync:*` handlers. No UI lives here: the
explorer, the transfers panel, the Watch and Downloads dock panels draw what these
types publish.

Everything a person can read comes back as `AppError` with the original's wording
(`errorText(error)` gives the text of any error thrown here).

## Where to start

| You want to… | Use |
|---|---|
| Browse/change files without caring where they are | `FileSource` (`LocalFileSource.shared`, `SFTPFileSource(connId:)`) |
| Anything per connection (`sftp:*`, `xfer:*`, `sync:*`) | `FilesService.shared` |
| Draw the transfers panel | `FilesService.shared.queues[connId]` → `TransferQueue.jobs` |
| This machine's filesystem (`local:*`) | `LocalFS` |
| Search a tree | `FindFiles` (or `FileSource.search`) |
| Keep a folder up to date / Edit in my editor | `Watches.shared` |
| Copy between two servers | `FilesService.shared.crossPlan` / `.cross` |
| rsync dialog | `Rsync` |
| Download history | `DownloadHistory` |
| File kinds (3D view colours) | `FileKinds.kindOf(name)` |

All `@MainActor` unless noted. Paths are POSIX strings everywhere.

## FileSource — the explorer's seam (FileSource.swift)

```swift
protocol FileSource: AnyObject, Sendable {
    var id: String { get }                       // "local", "sftp:<connId>", "s3:<id>"
    @MainActor var label: String { get }
    var kind: FileSourceKind { get }             // .local / .sftp / .s3
    var capabilities: FileSourceCapabilities { get }  // .chmod .search .posix .exec .watch .open .transfers
    func home() async throws -> String
    func list(_ dir: String?) async throws -> FileListing   // nil/""/"~" = home; absolute path back; symlinks resolved
    func stat(_ path: String) async throws -> FileEntry
    func mkdir(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func remove(_ entries: [FileEntry]) async throws         // folders (not links to them) recursively
    func readText(_ path: String, maxBytes: Int) async throws -> String   // refuses big/binary files with a message
    func writeText(_ path: String, _ text: String) async throws
    func chmod(_ path: String, mode: UInt32) async throws
    func search(_ options: FindFiles.Options) async throws -> FindFiles.Outcome
    func parent(of path: String) -> String       // default Posix.parent
    func join(_ dir: String, _ name: String) -> String
}
```

`FileEntry` (FileModels.swift) is the row: `name, path, type (.file/.directory/
.symlink/.special), targetType (links: .file/.directory/.broken), size, mode,
modeString ("drwxr-xr-x"), mtime/atime (ms), uid/gid, owner/group (names), links,
longname (SFTP), extra ([String: JSON], free for S3)`, plus `isDirectoryLike` and
`perm`. Remote `mode` keeps the file-type bits (as sftp.js); local `mode` is the
permission bits (as local.js) — use `perm` for just the bits.

**S3 (automation owner):** add `final class S3FileSource: FileSource` in Automation/
with `kind = .s3`, `capabilities = []` (or `.search` if you implement it); throw
`AppError` from what a bucket cannot do. Put storage class/etag in `FileEntry.extra`.

Things that are *not* on the protocol because only one kind has them: local
`LocalFS.info/treeSize/reveal/open/openWith`; remote Get info/du/chown, which the
original ran as shell commands in explorer.js (use `ConnectionManager.exec`).

## FilesService.shared (FilesService.swift)

One SFTP channel and one `TransferQueue` per connection id.

- `sftp(connId) async throws -> SFTPClient` — opened on first use and kept
  (`getSftp()`); re-opened after the far side drops it.
- `queue(connId) -> TransferQueue`; `queues: [String: TransferQueue]` (observable).
- `connectionClosed(connId)` — wired to `ConnectionManager.willRemove`: stops the
  connection's watches, closes its channel, cancels and drops its queue.
- `sftp:*`: `home`, `list(connId, dir)` → `FileListing`, `realpath`, `mkdir`,
  `rename`, `chmod(mode:)`, `stat`, `remove(connId, [FileEntry])`,
  `readFile(connId, path, maxBytes:)` → String, `writeFile`, `search`.
- `xfer:*`: `upload(connId, localPaths:, remoteDir:)` / `download(connId, entries:,
  localDir:)` → job id; `crossPlan(src, dest)` → `CrossTransfer.Route`;
  `cross(src, entries:, to:, destDir:, mode:)` → `CrossTransfer.Started`;
  `setLimit(kbPerSecond:)` (stores `transferLimitKb`, applies to every queue).
  Queue controls are on the queue: `cancel pause resume pauseAll resumeAll retry
  move(id, ±1) clearFinished`.
- `sync:*`: `syncPlan(connId, SyncPlanner.Request)` → `SyncPlanner.Plan`;
  `syncApply(connId, plan, actions:)` → `SyncPlanner.ApplyResult`.
- `onJobFinished` — every finished job; defaults to recording downloads.

## TransferQueue (TransferQueue.swift, engine in Transfers.swift)

`jobs: [TransferJobView]` — `id, kind ("upload"/"download"/"cross"), label, status
("queued"/"running"/"paused"/"done"/"error"/"cancelled"), paused, resumed,
totalBytes, doneBytes, fileIndex, fileCount, currentFile, phase ("the server is
closing the file", "setting permissions", "writing out the file"), error, rate
(B/s, sampled every 400 ms), startedAt, endedAt, limit`. `onUpdate`, `onFinished`
(`FinishedTransfer`: items, dirs, roots, bytes, startedAt, endedAt, from) for the
status-bar "what finished, how much, how fast" confirmation.

Behaviour as the original: one job at a time per connection; 16 requests in
flight per file; pause holds *between chunks* (handles stay open); `pauseAll`
also holds jobs added later; `retry` resumes from the local file's size (download)
or the server's (upload) — only on retry; `move` only among queued jobs; the speed
limit is one sliding-window allowance per queue, serialised so 16 chunks cannot
each claim it; uploads restore mode and mtime. Custom jobs (`TransferJobSpec.customRun`)
report through `TransferRunContext`.

`Transfers.uploadFile/downloadFile/planUpload/planDownload/parallelChunks` are usable
on their own (relay, watches and S3-to-server use them).

## SFTPClient (SFTPClient.swift)

SFTP v3 over any `ByteChannel` and nothing else. `connect(timeout:)`, `realpath`,
`stat`, `lstat`, `readlink`, `list(dir) -> [FileEntry]`, `resolveEntry`, `mkdir`,
`rmdir`, `remove`, `rename` (posix-rename@openssh.com when offered), `chmod`,
`utimes`, `open/close/readChunk/writeChunk`, `removeTree`, `readFile(maxBytes:)`,
`writeFile`, `destroy`, `onClose`. Thread-safe; concurrent requests are the point.
Errors: `SFTPError` ("No such file: /path"), "SFTP connection closed",
"sftp transport exited: <stderr>", "SFTP handshake timed out".

## SyncPlanner (SyncPlanner.swift)

`plan(sftp, Request(localDir:remoteDir:direction:"up"|"down"|"both", del:, compare:"both"|"size"|"time"))`
→ `Plan { actions: [Action(op, rel, size, why, overwritesNewer?, dir?)], dirsUp,
dirsDown, summary }`. Ops: upload, download, deleteRemote, deleteLocal, rmdirRemote,
rmdirLocal (deepest first), same, skip. Symlinks and `.DS_Store`-type noise are never
transferred; 2 s mtime slack; 200k entries / 45 s walk limits (`summary.truncated`).
`apply(plan, keptActions, queue:, sftp:)`: transfers go to the queue; deletions run
here; a folder removal is dropped when any deletion beneath it was unticked, and a
folder is re-listed and kept ("kept — still has N item(s) in it") if not empty.
`describe(plan)` → the control socket's capped JSON summary; `doingOps`.

## Watches.shared (Watches.swift)

`list: [Watches.View]` (observable; the dock's Watch panel). `watchDir(connId:,
localDir:, remoteDir:)` — FSEvents, 400 ms settle, uploads changed/new files, makes
parent dirs, ignores `.git`, `node_modules`, `.DS_Store`, `.swp`, `~`, `.#…`, `.tmp`,
`.~lock`; never deletes or downloads. `editRemote(connId:, remotePath:)` — downloads
to `$TMPDIR/serverlife-edit-<hex>/<name>`, opens with the OS default or
`settings.externalEditor` (split on spaces, no shell), uploads every real change
(atomic saves included); `openError` set if opening failed. `stop(id, keepTemp:)`
removes the temp copy; `stopForConnection`, `stopAll` (also on quit). `onEvent`.

## FindFiles (FindFiles.swift)

`Options(dir:, pattern:, content:, caseSensitive:, kinds: "all"|"files"|"dirs",
limit: 400, maxDepth: 6)` plus `maxEntries` 250k / `maxMs` 6000. `searchLocal` →
`Outcome { results: [Hit(path,name,type,size,mtime,line,excerpt)], scanned,
truncated, stopped: "time"|"entries"|nil, elapsedMs, where }`.
`searchRemote(connId:, opts)` (find -printf, falling back to plain find; grep -rIn for
content; `head` on the server) adds `command`. `toGlob`, `remoteCommand`,
`remoteCommandPlain`, `parseRemote` are pure.

## Rsync (Rsync.swift)

`check() async -> Check { ok, error, bin, version, features{infoProgress, protectArgs} }`
(Homebrew/MacPorts first, then PATH; openrsync and < 3.1 get plain flags).
`transport(connId) -> Transport` (the connection's `rsyncTransport()`, with its
refusals). `run(id:, args:, onOut:, onDone:)` streams `Output(id,text,stream
"sys"|"out"|"err")` and ends with `Done(code, signal, message: explain(code))`;
`cancel(id)` (SIGINT, SIGKILL after 4 s), `cancelAll()`. Pure builders shared with
the dialog (ported from rsyncsync.js, tested as tests/rsync.test.mjs was):
`endpoint(Side, path, contents:)`, `buildArgs(Options)`, `commandLine(args)`.

## LocalFS (LocalFS.swift)

`listing(dir)` (`local:list`), `list`, `entry`, `info(path)` → `Info` (target, ctime,
birthtime, immediate files/dirs), `treeSize(path)` (400k / 20 s, `truncated`),
`ensureDir` (`local:mkdir`), `ensureParentDir`, `remove(paths)`, `removeEntry`,
`rename`, `parentOf`, `home`, `shortcuts()`, `existingDirs(paths)`, `reveal`, `open`,
`openWith(file, app:)` (`open -a`), `readText(path, max:)` (2 MB default, 16 MB cap,
binary refusal), `writeText`, `stat/lstat`, `userName/groupName`.

## DownloadHistory (DownloadHistory.swift)

`list()`, `forget(id)`, `clear()`, `check(paths) -> [path: Bool]`, `add(…)` (for S3),
`record(FinishedTransfer)` (folders as one row, loose files capped at 20),
`plan(job)` (pure). Rows live in the store's `downloads` array in store.js's shape.

## Not done / notes

- The store side of downloads uses small `fileprivate` stand-ins in
  DownloadHistory.swift until the data owner publishes `addDownload` & co.; switch
  `DownloadHistory` to theirs then.
- The speed-limit window is per connection queue, as in transfers.js (the guide
  says "across every transfer"; the source wins).
- Windows refusals are dropped (macOS only). `Watches.View.flatOnly` is always false (FSEvents is recursive).
