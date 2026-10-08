import Foundation

/// SSH ControlMaster connections, terminals, exec, forwards, local shells (connections.js, local.js, authprobe.js).
///
/// Owner: connections (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens. Registers no
/// UI actions: sessions and the sidebar own the interface. See README.md.
@MainActor
enum ConnectionsFeature {
    private static var lastSshPath: String?

    static func install() {
        // The runtime directory (control sockets, generated configs), 0700.
        _ = ConnRuntime.dir
        _ = ConnectionManager.shared

        // A corrected ssh path takes effect at once (settings:set → setSshPath).
        lastSshPath = Store.shared.setting("sshPath", "")
        Store.shared.onSettingsChanged.append {
            MainActor.assumeIsolated {
                let p: String = Store.shared.setting("sshPath", "")
                if p != lastSshPath {
                    lastSshPath = p
                    Tools.setSshPath(p)
                }
            }
        }

        // Quitting: hang up local shells, then every ControlMaster.
        AppDelegate.willTerminate.append {
            LocalShells.shared.closeAll()
            ConnectionManager.shared.shutdown()
        }
    }
}
