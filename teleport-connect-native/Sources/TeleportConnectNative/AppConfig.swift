import Foundation

/// Ported from web/packages/teleterm/src/services/config/appConfigSchema.ts — Connect's real
/// app_config.json schema. Not every key applies here (runInBackground is a menu-bar/tray
/// feature we don't have; the keymap.* shortcuts would need a full keybinding editor; debug.*
/// and headless.* have no equivalent feature in this app yet) — this covers the subset that
/// maps onto something this app can actually act on, using the exact same key names and
/// defaults as the real schema for familiarity.
struct AppConfig: Codable, Equatable {
    var theme: String = "system" // "light" | "dark" | "system"
    var terminalFontFamily: String = "Menlo, Monaco, monospace"
    var terminalFontSize: Int = 15
    var terminalCopyOnSelect: Bool = false
    var sshNoResume: Bool = false
    var sshForwardAgent: Bool = false
    var sshAgentAddKeysToAgent: String = "auto" // "auto" | "no" | "yes" | "only"
    var hardwareKeyAgentEnabled: Bool = false

    private enum CodingKeys: String, CodingKey {
        case theme
        case terminalFontFamily = "terminal.fontFamily"
        case terminalFontSize = "terminal.fontSize"
        case terminalCopyOnSelect = "terminal.copyOnSelect"
        case sshNoResume = "ssh.noResume"
        case sshForwardAgent = "ssh.forwardAgent"
        case sshAgentAddKeysToAgent = "sshAgent.addKeysToAgent"
        case hardwareKeyAgentEnabled = "hardwareKeyAgent.enabled"
    }
}

/// Loads/saves AppConfig as app_config.json in Application Support — same filename Connect
/// itself uses (main.ts), though this is our own app's copy, not shared with the real one.
struct AppConfigStore {
    let fileURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TeleportConnectNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("app_config.json")
    }

    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
