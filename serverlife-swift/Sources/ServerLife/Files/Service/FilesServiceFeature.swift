import AppKit
import Foundation

/// SFTP v3, transfers, cross-server copy, sync, watches, search, rsync,
/// downloads (sftp.js, transfers.js …). See README.md in this directory.
///
/// Owner: files-service (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens.
@MainActor
enum FilesServiceFeature {
    static func install() {
        // A watcher whose connection has gone would upload into nothing, and
        // its row would claim to be live. Both go with the session, as does
        // its file channel and its queue.
        ConnectionManager.shared.willRemove.append { id in
            FilesService.shared.connectionClosed(id)
        }
        // The speed limit is a preference about the link: however it is
        // changed (Settings, the transfers panel), every open queue follows.
        Store.shared.onSettingsChanged.append {
            MainActor.assumeIsolated {
                let bytes = Store.shared.filesTransferLimitKb * 1024
                for q in FilesService.shared.queues.values where q.limit != bytes { q.setLimit(bytes) }
            }
        }
        // Nothing of ours outlives the app: an rsync left running unwatched, or
        // an editor's temporary copy left in /tmp.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Rsync.cancelAll()
                Watches.shared.stopAll()
            }
        }
    }
}
