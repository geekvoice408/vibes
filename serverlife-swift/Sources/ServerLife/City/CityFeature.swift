import SwiftUI

/// The 3D city view of a directory (city3d.js, cityarch.js, cityactors.js, cityprocs.js, cityscan.js, procscan.js).
///
/// Owner: city (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here.
@MainActor
enum CityFeature {
    static func install() {
        let a = Actions.shared

        // The explorer's 3D button: args `explorer` (a CityExplorerHost),
        // optional `on` Bool (toggle3d(force)); without `on` it toggles.
        a.register("city-open", enabled: { _ in Store.shared.setting("show3dView", true) }) { ctx in
            if let ex = ctx.args["explorer"] as? ExplorerModel {
                let on = ctx.args["on"] as? Bool ?? (ex.city == nil)
                if on == (ex.city != nil) { return }
                // Off goes through the explorer, which destroys and detaches.
                if !on { ex.toggle3d(false); return }
                let adapter = CityExplorerAdapter(ex)
                City.toggle(adapter, on: true)
                (ex.city as? CityController)?.keepAlive = adapter
                return
            }
            guard let host = ctx.args["explorer"] as? CityExplorerHost else {
                StatusBus.shared.show("The 3D view needs an explorer to show", kind: .warn)
                return
            }
            City.toggle(host, on: ctx.args["on"] as? Bool)
        }

        // A city in a panel of its own (a stand-in host until the explorer
        // hosts it): args `path` (default home, or `--city-path` when
        // snapshotting), `connId` for a connection's files.
        a.register("city-panel", enabled: { _ in Store.shared.setting("show3dView", true) }) { ctx in
            guard Store.shared.setting("show3dView", true) else { return }
            let connId = ctx.connId ?? ctx.args["connId"] as? String
            let source: FileSource = connId.map { SFTPFileSource(connId: $0) } ?? LocalFileSource.shared
            let path = ctx.args["path"] as? String ?? DebugSnapshot.arg("--city-path")
            CityPanelExplorer.open(source: source, path: path)
        }

        // `--city-explorer N`: press 3D on the first explorer after N seconds
        // (for checking the explorer integration with --snapshot).
        if let d = DebugSnapshot.arg("--city-explorer"), let secs = Double(d) {
            after(secs) {
                var first: ExplorerModel?
                Explorers.shared.forEach { if first == nil { first = $0 } }
                first?.toggle3d(true)
            }
        }

        // Turning the setting off closes every city.
        Store.shared.onSettingsChanged.append { City.applySetting() }
    }
}
