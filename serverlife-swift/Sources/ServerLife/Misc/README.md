# Misc

Settings, themes, the guide, the tour, version history, About, the backup
dialogs and the ui.js pieces App/ does not have. Ports index.js
`openSettings`/`locateTsh`/`openAbout`, themes.js (+ the skin/accent blocks of
styles.css and term.js `activeTheme`), guide.js, tour.js, changelog.js,
versions.js, backup.js (renderer), ui.js leftovers.

## Action ids (registered in `MiscFeature.install`)

| id | does | args |
|---|---|---|
| `settings` | Settings dialog | — |
| `locate-tools` | "Command-line tools" (tsh/ssh path overrides) | — |
| `about` | About box | — |
| `version-history` | Version history from Resources/CHANGELOG.md | — |
| `guide` | Guide panel (Resources/GUIDE.md) | `topic` String: scroll to the first section whose title contains it |
| `tour` | Start the guided tour in the window | — |
| `backup-export` | Export all / macros to a JSON file | `what` "all"/"macros", `ids` [String] (macros subset) |
| `backup-import` | Pick a file, show its contents, merge or replace | `reply` `(Bool) -> Void` (true when imported) |

Actions Misc **calls** (owners please register):

- `highlights` [sessions] — "Edit the highlights…" (highlight.js `openHighlightSettings`).
- `ssh-config-files` [sidebar] — "SSH config files…" (sidebar.js `openSshConfigDialog`).
- `refresh` [sidebar] — after tsh homes or tool paths change, and after an import.
- `s3-reload` [automation] — after an import.
- `automation-status` — args `reply: (JSON) -> Void`; JSON `{enabled, socketPath, tokenFile, mcpCommand, bridge}`.
- `automation-toggle` — args `enabled: Bool`, `reply: (JSON) -> Void` (new status fields, or `{error}`).
- `automation-rotate` — args `reply: (JSON) -> Void`.
- `automation-copy-command` — args `what: "mcp" | "bridge"` (copies to the clipboard).
  Unregistered automation actions → the section says "not available in this build".

## Hooks (`MiscHooks`, set from your `install()`)

- `teleportHomes: () async -> JSON` [teleport-service] — the original's `teleport:homes` answer
  (`{tsh:{found,searched}, homes:[{path,name,default,exists,error,profiles:[{cluster,expired}]}]}`), for "Check what they hold".
- `connectAnimPreview: (String) -> AnyView` [sessions] — preview of a connect animation id under the setting.
- `windowHasSessions: (WindowModel) -> Bool` [sessions] — a window with restored tabs is not offered the tour.
- `settingsSaved: [(before, after) -> Void]` — after Save (font size to panes only if `fontSize` changed,
  restart refresh loops, redraw explorers…). `Store.onSettingsChanged` fires too.

## Settings

`SettingsDialog.open(window)`. Writes one `Store.updateSettings` patch with the original keys:
theme, accent, skin, terminalPalette, x11, mfaMode, connectAnim, recentLimit, tshHomes, refreshSeconds,
nodeRefreshSeconds, staleNodeMinutes, sidebarHostLimit, fontSize, sidebarFontSize, fontFamily, scrollback,
cursorBlink, followTerminalFolder, showHiddenFiles, showFileDetails, foldersFirst, show3dView, externalEditor,
highlight, showShellInTitle, showPaneNetIcon, showTabActivity, confirmLinkOpen, confirmQuitWithSessions,
confirmCloseWithSessions, tmuxDefault, tmuxSessionName, requestMonitorAutoOpen, showWatchMark, agentForward,
starredMode, autoFlagLocal, autoFlagHost. "Stop watching all" clears `watchedHosts`.

`SettingsDialog.apply(patch)` = main.js `settings:set`: writes, and applies `tshHomes` → `Tools.homes`,
`tshPath`/`sshPath` → `Tools.setTshPath/setSshPath`. Use it when you change those keys.

Theme/accent/skin preview live while the dialog is open (`MiscThemes.preview`); Cancel restores.

## Themes

`Theme.shared.p` and `Theme.shared.terminal` reflect theme/accent/skin/terminalPalette (resolver installed
first in `Theme.shared.resolvers`). 37 named themes (`MiscThemes.appThemes`), 9 skins, 7 accents,
terminal palettes (`MiscThemes.terminalPalettes`: app, Solarized dark/light, Gruvbox, Nord, Dracula, High
contrast, plus every theme with its own colours). Precedence as the original: skin > accent > named theme
for the window; for the terminal named palette > named theme (unless a skin) > skin-derived > plain dark/light.
"auto" follows the system (`Theme.systemIsDark`; the shell refreshes on system changes).

`Theme.shared.terminal` keys (hex `#rrggbb`, selection `#rrggbbaa`):
`background foreground cursor cursorAccent selectionBackground selection` (alias) and the 16 ANSI
`black red green yellow blue magenta cyan white brightBlack brightRed brightGreen brightYellow brightBlue
brightMagenta brightCyan brightWhite`. `Theme.shared.terminalNSColor(key)` gives an NSColor (alpha included).

## Tour anchors

Tag the view a step points at with `.tourAnchor("id")` (records its frame per window; a view
that is hidden or smaller than 4×4 is skipped and the step is shown centred).

| id | what (original selector) | owner |
|---|---|---|
| `sidebar` | the whole host list (`#sidebar`) | **tagged by Misc** (wraps `Slots.sidebar`) |
| `panes` | the workspace (`#panes`) | **tagged by Misc** (wraps `Slots.workspace`) |
| `titlebar` | title bar (`#titlebar`) | built-in fallback (top 38 pt) |
| `host-filter` | sidebar filter field (`#host-filter`) | sidebar |
| `btn-folders` | Folders button (`#btn-folders`) | sidebar / hosts |
| `btn-heartbeats` | Heartbeats button (`#btn-heartbeats`) | sidebar |
| `teleport-tab` | sidebar's Teleport tab (`.sb-tab[data-tab=teleport]`) | sidebar |
| `keys` | sidebar "SSH keys" item (`[data-tour=keys]`) | sidebar |
| `nettools` | sidebar "Network tools" item (`[data-tour=nettools]`) | sidebar |
| `tab-add` | the + new-tab button (`#tab-add`) | sessions (tab strip) |
| `toggle-files` | title-bar explorer button | whoever fills `Slots.titlebarActions` |
| `toggle-multiexec` | title-bar multi-exec button | 〃 |
| `toggle-transfers` | title-bar transfers/dock button | 〃 |

The tour is offered once per `Tour.version` (settings.`tourSeenVersion` = 3) via
`WindowManager.didOpen` 1.5 s after the first window opens, not in a second window, not when
`windowHasSessions`, never under `--snapshot`. Escape / ←/→/Return drive it.

## Shared UI (ui.js leftovers)

- `CtxMenu.show([CtxItem])` / `CtxMenu.build` — context menus with `icon`, `sub` (second line),
  `key` ("⌘⇧D"), `help` (`CtxHelp(answers:command:notes:)` → tooltip card), `.heading("…")`, `.sep`,
  `submenu`, `disabled`, `title`.
- `MiscUI.prompt(title:label:value:placeholder:confirmLabel:validate:)` — inline error from `validate`.
- `MiscUI.confirm(title:message:detail:confirmLabel:danger:)`.
- `MiscUI.pickIcon(title:subtitle:value:)` — EmojiPicker as a dialog (nil = cancelled, "" = none).
- Form pieces: `MiscField(label:hint:)`, `MiscCheck(label:isOn:note:)`, `MiscHint`, `MiscRule`,
  `OptionPicker(options:selection:)` (ui.js `select`).

## Backup

`BackupUI.exportSettings / importSettings / reloadAfterImport`. The envelope functions in
`BackupOps.swift` forward to Data/'s port of main/backup.js (`Backup`, Data/Backup.swift).

## Not done / differences

- About omits the Electron/Chromium/Node rows (not applicable); adds Build and macOS.
- Guide search marks every occurrence (the original marked the first per DOM text node) and a hit under
  a `###` heading marks its enclosing section in the list.
- Settings shows an extra `ssh:` line next to the `tsh:` line.
