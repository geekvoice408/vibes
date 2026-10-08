import Foundation

/// Store records and portable formats: store.js methods, YAML, multi-exec files, Ansible bundles, backup.
///
/// Owner: data (see CLAUDE.md → Ownership). `install()` runs once at launch,
/// after the store has loaded and before the first window opens: register
/// actions, slots, status items and timers here.
@MainActor
enum DataFeature {
    static func install() {}
}
