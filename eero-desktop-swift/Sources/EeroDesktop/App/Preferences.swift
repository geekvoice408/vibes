#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Desktop preferences (port of `UiPreferences` in DesktopFeatures.cs), stored in `UserDefaults`
/// instead of `%LOCALAPPDATA%\EeroDesktop\preferences.json`.
///
/// SwiftUI views observe `UiPreferences.shared`; other code can use the static accessors that mirror
/// the Windows names (`UiPreferences.theme`, `.notifications`, `.background`, `.startWithWindows`,
/// `.allNetworks`, `.dark`, `.save()`, `.color(_:)`). Values persist as soon as they are assigned.
@MainActor
final class UiPreferences: ObservableObject {
    static let shared = UiPreferences()

    static let themes = ["System", "Light", "Dark"]
    private enum Key {
        static let theme = "theme", notifications = "notifications", background = "background"
        static let startAtLogin = "start_with_login", allNetworks = "all_networks"
    }
    private let defaults = UserDefaults.standard

    /// "System", "Light" or "Dark". Assigning persists the choice, clears a `--theme` launch override
    /// and applies the appearance to every window.
    @Published var theme: String {
        didSet {
            if !UiPreferences.themes.contains(theme) { theme = oldValue; return }
            launchTheme = nil
            defaults.set(theme, forKey: Key.theme)
            applyAppearance()
        }
    }
    /// Show network alerts from eero's notification history.
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: Key.notifications) } }
    /// Keep running in the menu bar when the window closes.
    @Published var background: Bool { didSet { defaults.set(background, forKey: Key.background) } }
    /// Open eero Desktop when the user logs in to macOS (the Windows "Start with Windows" option).
    @Published var startAtLogin: Bool { didSet { defaults.set(startAtLogin, forKey: Key.startAtLogin) } }
    /// Monitor all networks in this account for alerts.
    @Published var allNetworks: Bool { didSet { defaults.set(allNetworks, forKey: Key.allNetworks) } }
    /// Theme given with `--theme` on the command line; used for this launch only and never saved.
    @Published private(set) var launchTheme: String?

    private init() {
        let stored = defaults.string(forKey: Key.theme) ?? "System"
        theme = UiPreferences.themes.contains(stored) ? stored : "System"
        notifications = defaults.bool(forKey: Key.notifications)
        background = defaults.bool(forKey: Key.background)
        startAtLogin = defaults.bool(forKey: Key.startAtLogin)
        allNetworks = defaults.object(forKey: Key.allNetworks) == nil ? true : defaults.bool(forKey: Key.allNetworks)
    }

    /// The theme in effect: the launch override when present, otherwise the saved choice.
    var effectiveTheme: String { launchTheme ?? theme }

    /// Applies `--theme <System|Light|Dark>` for this launch without saving it.
    func applyLaunchTheme(_ value: String) {
        guard UiPreferences.themes.contains(value) else { return }
        launchTheme = value
        applyAppearance()
    }

    /// Port of `Program.ApplyTheme`: sets the app-wide appearance, which every window, menu, alert and
    /// the menu bar extra inherit (replacing the DWM caption colours and `DarkTrayColors`).
    /// Does nothing before the application object exists; `AppDelegate` applies it at launch.
    func applyAppearance() {
        guard let app = NSApp else { return }
        switch effectiveTheme {
        case "Dark": app.appearance = NSAppearance(named: .darkAqua)
        case "Light": app.appearance = NSAppearance(named: .aqua)
        default: app.appearance = nil
        }
    }

    /// True when the dark palette is in effect (port of `UiPreferences.Dark`).
    var isDark: Bool {
        switch effectiveTheme {
        case "Dark": return true
        case "Light": return false
        default: return UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
        }
    }

    /// Writes every value (kept for parity with `UiPreferences.Save`; assignments already persist).
    func save() {
        defaults.set(theme, forKey: Key.theme)
        defaults.set(notifications, forKey: Key.notifications)
        defaults.set(background, forKey: Key.background)
        defaults.set(startAtLogin, forKey: Key.startAtLogin)
        defaults.set(allNetworks, forKey: Key.allNetworks)
    }

    // MARK: Static accessors with the Windows names

    static var theme: String { get { shared.theme } set { shared.theme = newValue } }
    static var notifications: Bool { get { shared.notifications } set { shared.notifications = newValue } }
    static var background: Bool { get { shared.background } set { shared.background = newValue } }
    static var startAtLogin: Bool { get { shared.startAtLogin } set { shared.startAtLogin = newValue } }
    /// Alias of `startAtLogin` matching the Windows `StartWithWindows` field.
    static var startWithWindows: Bool { get { shared.startAtLogin } set { shared.startAtLogin = newValue } }
    static var allNetworks: Bool { get { shared.allNetworks } set { shared.allNetworks = newValue } }
    static var dark: Bool { shared.isDark }
    static func save() { shared.save() }

    /// Port of `UiPreferences.Color`: maps a legacy Windows page colour to the current palette hex.
    static func color(_ hex: String) -> String {
        guard let pair = Palette.legacyPair(hex) else { return hex }
        return "#" + String(format: "%06X", dark ? pair.dark : pair.light)
    }
}
#endif
