import SwiftUI

/// Extension points other owners fill in (in their `install()`), for the parts
/// of Settings, the tour and backup that show their data. Each is optional:
/// unset, the dialog says the thing is not available rather than failing.
@MainActor
enum MiscHooks {
    /// teleport-service: the answer to the original's `teleport:homes` —
    /// `{ tsh: {found, searched}, homes: [{ path, name, default, exists,
    /// error, profiles: [{ cluster, expired }] }] }`. Used by Settings →
    /// "Check what they hold".
    static var teleportHomes: (() async -> JSON)?

    /// sessions (connectanim.js): a preview of a connect animation by id
    /// (`buildConnectAnim`), shown under the setting.
    static var connectAnimPreview: ((String) -> AnyView)?

    /// sessions: whether a window already has tabs open (a restored
    /// workspace) — the tour is then not offered on that launch.
    static var windowHasSessions: ((WindowModel) -> Bool)?

    /// Called after Settings is saved, with the settings before and after, so
    /// a feature can apply what changed at once (font sizes to open panes,
    /// refresh intervals, the explorer's sort …). Store.onSettingsChanged
    /// also fires; this one carries the old values for comparison.
    static var settingsSaved: [(_ before: JSON, _ after: JSON) -> Void] = []
}
