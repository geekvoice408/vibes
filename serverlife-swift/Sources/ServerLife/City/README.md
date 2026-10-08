# City — the 3D view of an explorer

Owner: **city**. This is the port of `city3d.js`, `cityarch.js`, `cityactors.js`, `cityprocs.js`,
`src/main/cityscan.js`, `src/main/procscan.js` and main.js's `city:*` handlers. It is built on
SceneKit with all geometry made in code (no `.scn` assets).

In the city, every folder is a building. Its height is the data under the folder, its width is
how many files it holds, and it is painted in bands by kind of file (FileKinds colours). Loose
files sit in the plaza. Double-click a building or press Enter to walk inside: files are crates
and folders are doors. The city is a **view of an explorer**: navigation, selection, the name
filter, hidden files, search and the right-click menu all belong to the explorer.

## Action ids (registered in `CityFeature.install`)

| id | args | does |
|---|---|---|
| `city-open` | `explorer`: an `ExplorerModel` (Files/Explorer), or anything conforming to `CityExplorerHost`; `on` Bool (optional; omitted = toggle) | Opens the city for that explorer. An `ExplorerModel` gets it back through `attachCity(_:)` as its `XPCityAttachment`. |
| `city-panel` | `path` (default home, or `--city-path`), `connId` (optional) | A stand-in host: a small explorer in a panel with the city in it. Used for development and `--snapshot`. Not on any menu. |

Also installed:
- A `Store.onSettingsChanged` hook: turning off `show3dView` closes every city (`apply3dSetting`).

## API

- `CityExplorerHost` (CityHost.swift): what the view needs from its explorer — path, entries,
  shown entries (hidden ones removed, sorted the way the list is), source key/kind, `connId`,
  matcher, selection (plus `citySelectionChanged`), navigate, goParent, open, context menu,
  focus/clear filter, maximized, and the `city` slot.
  - `CityExplorerAdapter` maps `ExplorerModel` onto this protocol.
  - `CityPanelExplorer` is the stand-in host.
- `City.toggle(host, on:)`: `toggle3d(force)`. It refuses S3 ("The 3D view does not reach into
  buckets yet") and refuses when `show3dView` is false.
- `CityController` (`@Observable`): `view` (the SwiftUI view that replaces the list), `sync()`,
  `invalidate()` (Refresh), `destroy()` (safe to call more than once), `focus()`. If the host is
  `@Observable`, the controller also picks up changes on its own through
  `withObservationTracking`.
- Services:
  - `CityService.scanLocal/scanRemote(connId:dir:)/procsLocal/procsRemote(connId:)` — the
    `city:*` handlers. Remote work goes through `ConnectionManager.exec`.
  - `CityScans.shared` — scans per source and directory, shared across explorers, with
    in-flight scans de-duplicated.
- Pure functions (tested):
  - `CityScan.scanLocal / remoteCommand / parseRemote` (300k entries / 15 s limit locally;
    `find | awk` with `timeout 20` and `head` remotely).
  - `ProcScan.parse / remoteCommand / scanLocal`.
  - `CityKinds.bands / summary / heightFor / footFor / crateFor`.
  - `CitySeeded` — bit-for-bit the JavaScript mulberry32/FNV, so a folder gets the same building
    as in the original.
  - `cityChaseRoute`, `CityProcRules`.

## Settings

| key | default | notes |
|---|---|---|
| `show3dView` | `true` | |
| `city3dStyle` | `"today"` | One of 10 styles in 3 groups. |
| `city3dTraffic` | `false` | |

Keys and defaults match the original.

## What is ported

- City and room layouts, with these limits from the original: 600 buildings, 400 crates, at
  least 4×4 blocks with parks filling the gaps.
- A woodland belt with the plaza approach kept clear, street lamps, and the "+N more" and
  "Nothing here" signs.
- All 10 architecture styles and their kinds, including halos, flags and mill smoke.
- Dusk at night and day in light themes. The sky follows the theme.
- Clouds, flocks that scatter when you get close, planes with banners, the superhero (barrel roll
  and rippling cape), and the police chase.
- Process traffic: cars, boats and rockets. Polled every 5 s locally, 10 s remotely, 60 s after
  an error. Kept by pid, and departing ones sink or shrink away.
- The MFA gate on tsh connections: "Measure folders (approve MFA)".
- Movement and controls:
  - Walking with collisions and jumping; flying.
  - Drag to look, wheel to glide, WASD/arrows/Space/X/C/Shift, G, H/?, /, ⌘F, ⌘A, Esc, Enter,
    Backspace.
  - Click / ⌘-click to select, double-click to activate, right-click for the explorer's menu.
- Hover cards, the legend, the crosshair, the help card, and the original's tooltips and status
  messages word for word.

## Differences / gaps

- **Fill the window (⤢)** forwards to `ExplorerModel.maximized`: the whole pane, toolbar
  included, covers its window, as `.c3-max` did. Esc brings it back.
- **Lighting**:
  - The hemisphere light is an image-based `lightingEnvironment`.
  - Stars are drawn into the backdrop. SceneKit fog cannot be switched off per material, so
    stars as geometry would be hidden by the fog.
  - Intensities were tuned by eye against snapshots. There is no ACES tone mapping.
- **Rendering details**:
  - Trees and lamps are merged meshes (one per colour) rather than instanced meshes.
  - The wall colour is baked into a copy of the window texture per colour, because SceneKit
    cannot multiply a colour by a map.
- **Mouse wheel**: line-based wheels move 40 pt per line. Chromium's per-line pixel step is
  approximated.
- **Debug flags (development only)**: `--city-shot out.png [--city-shot-delay s] [--city-style id]
  [--city-walk] [--city-enter name]` writes the rendered scene, which `--snapshot` cannot capture
  from a Metal layer. `--city-explorer N` presses 3D on the first explorer after N seconds.
- Windows `Get-Process` is left out (macOS only).

## Tests

`Tests/ServerLifeTests/City/CityScanTests.swift`:
- `tests/cityscan.test.mjs` and `tests/procscan.test.mjs` in full, including the remote command
  run through `/bin/sh` against the local walk.
- Seeded-RNG parity with node, bands, sizes, chase routes, and process kinds.
