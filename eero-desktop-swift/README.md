# eero Desktop for macOS (Unofficial) — Swift port

A native macOS (SwiftUI) port of [unofficial_eero_windows_native](https://github.com/geekvoice206/unofficial_eero_windows_native)
by Carlos B. (Los33). It is licensed under AGPL-3.0, like the original.

Not affiliated with or endorsed by Amazon or eero.

**Status: work in progress.** The port is still being assembled.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/EeroCore` | Platform-neutral API client, request contracts, validation and services. Builds and tests on macOS and Linux. |
| `Sources/EeroDesktop` | The macOS 14+ SwiftUI app. Uses WebKit for sign-in, CoreBluetooth for discovery, Keychain for sessions, and SMAppService for start at login. |
| `Tests/EeroCoreTests` | XCTest ports of the original app's built-in self-tests. |
| `PORTING.md` | How the C#/WPF code maps onto Swift. |

## Build

```sh
swift build
swift test
swift run EeroDesktop --preview   # demonstration data, no network changes
```

## macOS differences

- **Saved sign-in:** stored in the Keychain instead of Windows DPAPI.
- **Embedded sign-in and service pages:** use WKWebView instead of WebView2.
- **Guardian VPN:** the app exports a WireGuard configuration for the official WireGuard app. Connect/disconnect from the app only works when macOS exposes that tunnel to it.
- **Packaging:** notifications and start at login need a bundled, signed app, which means a bundle identifier, Info.plist and entitlements.
