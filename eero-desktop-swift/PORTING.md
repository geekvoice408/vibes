# Porting conventions (C#/WPF → Swift/SwiftUI)

Original source (read-only reference): `/home/user/geekvoice206/unofficial_eero_windows_native/source/*.cs`.

## Layout
- `Sources/EeroCore/` — platform-neutral Swift (Foundation only). Must build and test on Linux with
  `PATH=/opt/swift/usr/bin:$PATH swift build && swift test`. No SwiftUI/AppKit/Security here except behind `#if canImport(...)`.
  - `Contracts/` — pure validation and request-body builders (`FeatureContracts`, `ExtendedContracts`, …).
  - `Services/` — non-UI services (`GuardianAPI`, conversation stream parsing, connection diagnostics, …).
- `Sources/EeroDesktop/` — the macOS 14+ SwiftUI app. **Every file is wrapped in `#if os(macOS)` … `#endif`** so the
  package still builds on Linux. This code cannot be compiled in this container, so write it carefully against
  documented macOS 14 SDK APIs only.
  - `App/` — entry point, `AppModel`, `FeatureArea` registry. `Views/` — pages. `Platform/` — macOS integrations
    (WebKit, CoreBluetooth, NetworkExtension, ServiceManagement, UserNotifications). `Theme/` — colours, styles.
- `Tests/EeroCoreTests/` — XCTest ports of the built-in self-tests (`Tests.cs`, `*Tests.cs`) that exercise core logic.

## Naming
- Keep the C# type names; methods become lowerCamelCase (`FeatureContracts.Forward` → `FeatureContracts.forward`).
  Static classes become `public enum X { public static func … }`.
- Request bodies are `JSON` (see `EeroCore/JSON.swift`): `JSON.obj(("key", value), …)` replaces `J.Obj`,
  `json.s("a","b")` replaces `J.S`, `json.b(...)` → `J.B`, `json.list` → `J.List`, `json.first(...)` → `J.First`,
  `json.get(...)` → `J.Get`.
- `ArgumentException` → `throw EeroError.argument("same message")`; `InvalidDataException` → `EeroError.data`;
  `InvalidOperationException` → `EeroError.operation`. Keep the user-facing messages verbatim, but say "macOS"/"Mac"
  where the original says "Windows"/"PC" when it refers to the local platform.
- Everything in EeroCore that the app uses must be `public`.

## App structure
- `AppModel` (App/AppModel.swift) holds shared state (`account`, `network`, `networkURL`, `devices`, `nodes`, `profiles`,
  `featureData[route]`, `selectedProfile`, `selectedNode`) and helpers: `run`, `perform`, `confirm`, `mutate`,
  `featureURL`, `netResource`, `resource`, `networkId`, `loadNetwork`, `startSpeedTest`. Add behaviour with
  `extension AppModel` in **your own files**; do not edit AppModel.swift (ask the coordinator in your final report instead).
- Pages are addressed by the same route strings as the Windows app (e.g. `"Settings/Advanced networking/DNS"`).
  Each feature area is an `enum XxxArea: FeatureArea` (App/FeatureArea.swift) that handles its routes: `load` ports the
  matching `LoadFeature` case, `previewData` ports `PreviewFeature`, `view` ports the `RenderFeature` UI.
  The coordinator registers areas in `FeatureAreas.all`; list your area type names in your final report.
- `api` is an actor: `try await model.api.send("GET", url)`.
- WPF dialogs → SwiftUI `.sheet`/`.alert`; `Confirm(...)` → `await model.confirm(...)`; `Button(title, async action)` →
  `Button(title) { model.perform { … } }`.

## Platform replacements
| Windows | macOS |
| --- | --- |
| DPAPI session file | Keychain (`KeychainSessionStore`) |
| WebView2 | WKWebView |
| Windows.Devices.Bluetooth | CoreBluetooth |
| WireGuard for Windows / rasdial | NetworkExtension (`NETunnelProviderManager`) + WireGuard config export |
| Registry Run key | `SMAppService.mainApp` |
| Tray icon | `MenuBarExtra` |
| Toast notifications | `UserNotifications` |
| Named mutex / pipe single instance | Not needed (macOS apps are single-instance); keep the API surface if callers need it |

Features that cannot work on macOS should still exist with an honest explanation in the UI, never silently dropped.
