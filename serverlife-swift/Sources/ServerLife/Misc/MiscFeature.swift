import AppKit
import SwiftUI

/// Settings, themes, guide, tour, changelog, about, backup UI (index.js
/// `openSettings`, themes.js, guide.js, tour.js, changelog.js, versions.js,
/// backup.js, ui.js leftovers). See Misc/README.md.
@MainActor
enum MiscFeature {
    static func install() {
        // Themes: named themes, accents, skins and terminal palettes.
        Theme.shared.resolvers.insert({ s, base in MiscThemes.resolve(s, base) }, at: 0)
        Theme.shared.refresh()

        let a = Actions.shared
        a.register("settings") { ctx in SettingsDialog.open(ctx.window) }
        a.register("locate-tools") { ctx in Task { await SettingsDialog.locateTools(ctx.window) } }
        a.register("about") { ctx in AboutBox.open(ctx.window) }
        a.register("version-history") { ctx in VersionHistory.open(ctx.window) }
        a.register("guide") { ctx in GuidePanel.open(topic: ctx.arg("topic", as: String.self) ?? "") }
        a.register("tour") { ctx in Tour.start(ctx.window ?? WindowManager.shared.current()) }
        a.register("backup-export") { ctx in
            Task {
                await BackupUI.exportSettings(ctx.window, what: ctx.arg("what", as: String.self) ?? "all",
                                              ids: ctx.arg("ids", as: [String].self))
            }
        }
        a.register("backup-import") { ctx in
            Task {
                let done = await BackupUI.importSettings(ctx.window)
                if done { BackupUI.reloadAfterImport() }
                ctx.arg("reply", as: ((Bool) -> Void).self)?(done)
            }
        }

        Tour.install()
        MiscAppInfo.shared.refreshTshVersion()
    }
}
