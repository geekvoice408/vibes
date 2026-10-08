# Data

Owner: data. Ports `src/main/store.js` (record methods) and `src/main/backup.js`.

## Store records — `StoreRecords.swift`

`extension Store` (main actor), one implementation per collection. Records are
`JSON` objects, not Codable structs, so updates merge exactly like store.js's
`{ ...existing, ...patch }` and fields this build does not know survive an
edit. Feature code may wrap them (e.g. `DownloadHistory.Row`).

| Collection | Methods | Rules |
|---|---|---|
| profiles | `listProfiles` `getProfile` `upsertProfile` `deleteProfile` `markProfileUsed` (store.js `markUsed`) | id `p_`; new record gets store.js's full shape; append |
| folders | `listFolders` `upsertFolder` `deleteFolder` | id `f_`; delete unfiles its profiles |
| history | `startHistory` `endHistory` `listHistory(limit: 200)` `listRecent(limit: 20)` `Store.listRecent(_:limit:)` `clearHistory` | id `h_`; newest first, cap 500; ends once; recent = one per type+cluster+node/target/label+login+home+direct port |
| workspaces | `saveWorkspace(_:slot:)` `getWorkspace` `listWorkspaces` `Store.workspaceList` `clearWorkspace` | `workspace` mirrors slot w1; list skips empty, slot-number order |
| layouts | `listLayouts` (adds `isDefault`) `getLayout` `saveLayout(id:name:workspace:)` `deleteLayout` `setDefaultLayout` `getDefaultLayout` | id `l_`; overwrite by id, else by name (case-insensitive) |
| snippets | `listSnippets` `upsertSnippet` `deleteSnippet` `markSnippetUsed` | id `s_`; name = first line, 40 UTF-16 units |
| macros | `listMacros` → `{macros, hidden, categoryOrder, pins}` `upsertMacro` `deleteMacro` `setMacroPin` `setMacroHidden` `setMacroCategoryOrder` `markMacroUsed` | id `m_`; pins append, re-pin keeps place, icon ≤ 8, scope default hosts; delete unpins; hidden is an ordered set |
| s3Targets | `listS3Targets` `getS3Target` `upsertS3Target` `deleteS3Target` | id `s3_`; whole record rewritten, `createdAt` kept |
| downloads | `addDownload` `listDownloads` `deleteDownload` `clearDownloads` | id `dl_`; one per localPath (merged, moved to top); cap 300; list newest `at` first |
| execRuns | `addExecRun` `listExecRuns` `deleteExecRun` `clearExecRuns` | id `mx_`; same command + same host set replaces; hosts ≤ 60; cap 40 |
| netRequests | `listNetRequests` `saveNetRequest` `deleteNetRequest` | id `req_`; update keeps first `savedAt`; sorted by `lastRunAt || savedAt` |
| netRuns | `addNetRun` `listNetRuns` `clearNetRuns` | id `run_`; cap 25; summary ≤ 160. **Never replaces** — see below |
| forwardFavorites | `listForwardFavorites` `addForwardFavorite` (throws) `updateForwardFavorite` `markForwardFavoriteUsed` `deleteForwardFavorite` | id `fwd_`; one per host.id + bindPort + kind |
| sessionNotes | `listSessionNotes` `upsertSessionNote` `deleteSessionNote` | keyed by `sid`; no flag and blank note deletes; newest `updatedAt` first |
| tshLogins | `listTshLogins` `upsertTshLogin` `deleteTshLogin` `markTshLoginUsed` | id `tl_`; one per proxy + user + home; sorted by `lastUsed || updatedAt` |
| requestTemplates | `listRequestTemplates(proxy:cluster:)` `upsertRequestTemplate` `deleteRequestTemplate` `markRequestTemplateUsed` `Store.trimRequestResources` | id `rq_`; filter proxy *or* cluster; resources trimmed to id/kind/name/cluster |

JS helpers (module-level): `dOr` (`a || b`), `dStr` (`String(x || '')`),
`dNum` (`Number(x) || n`), `dSlice` (UTF-16 `.slice`), `dTime`, `dSortedDesc`
(stable, like `Array.prototype.sort`).

`addNetRun` is ported as written: store.js builds a tool+target+host key and
compares it with `tool + '\0' + target`, so nothing is ever replaced and
"Recent" is every run — which is also what GUIDE.md describes.

store.js's `emit('changed')` has no counterpart: `Store` is `@Observable`.

## Backup — `Backup.swift`

`Backup.exportAll(store)`, `exportMacros(store, ids)`, `parse(text)` (throws
the original's messages), `describe(doc)`, `applyImport(store, doc, mode:)`,
`envelope`, `fullKeys`, `listKeys`. `Misc/BackupOps` forwards here.

## Forwarders elsewhere

`SBData` (Sidebar), `HostsData` (Hosts), `FleetStore` (Fleet), `NetSaved`
(NetTools), `TUIData` (Teleport/UI), `Store.auto…` (Automation),
`DownloadHistory` (Files/Service), `WorkspaceStore` (Sessions),
`Inventory.savedLogins/markSavedLoginUsed` (Teleport/Service),
`SessionsWindow.markProfileUsed`, `ConnectionManager.defaultStart/EndHistory`.

## Not done

multiexecfile.js, ansible.js and the js-yaml subset are not part of this pass.

Tests: `Tests/ServerLifeTests/Data/StoreRecordsTests.swift` (throwaway `Store(dir:)`).
