#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Command-line options (port of the argument handling in `Program.Main`).
/// `--preview` and `--theme-preview` start with sample data; `--theme System|Light|Dark` overrides the
/// saved theme for this launch. The Windows-only diagnostics switches (`--self-test`, `--render`,
/// `--vpn-control`, …) are covered by `swift test` and are not needed on macOS.
struct LaunchOptions {
    var preview = false
    var themePreview = false
    var theme: String?

    init(_ args: [String] = CommandLine.arguments) {
        themePreview = args.contains("--theme-preview")
        preview = args.contains("--preview") || themePreview
        if let i = args.firstIndex(of: "--theme"), i + 1 < args.count { theme = args[i + 1] }
    }
}

/// Owns the current `AppModel`. Leaving preview mode ("Back to sign in") replaces the model with a
/// signed-out live one, because `AppModel.preview` is fixed for a model's lifetime.
@MainActor
final class AppHost: ObservableObject {
    static let shared = AppHost()
    @Published private(set) var model: AppModel

    private init() {
        let options = LaunchOptions()
        model = AppModel(preview: options.preview)
        if options.themePreview { model.currentPage = "Theme preview" }
    }

    /// Leaves preview mode and shows the sign-in screen.
    func leavePreview(notice: String) {
        let live = AppModel(preview: false)
        live.setNotice(notice)
        model = live
    }
}

/// The bundled application icon (port of `ApplicationIcon`).
enum ApplicationIcon {
    static let image: NSImage? = Bundle.module.url(forResource: "app-icon", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    /// A small template-free copy for the menu bar (port of `CreateTrayIcon`).
    static let menuBarImage: NSImage? = {
        guard let source = image?.copy() as? NSImage else { return nil }
        source.size = NSSize(width: 18, height: 18)
        return source
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let icon = ApplicationIcon.image { NSApplication.shared.applicationIconImage = icon }
            UiPreferences.shared.applyAppearance()
        }
    }

    /// Port of the window `Closing` handler: with "keep running" enabled and a signed-in live session,
    /// closing the window leaves the app in the menu bar instead of quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            let model = AppHost.shared.model
            return !(UiPreferences.shared.background && model.screen == .shell && !model.preview)
        }
    }
}

/// The macOS app (port of `Program.Main` + `MainWindow` construction).
struct EeroDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var host = AppHost.shared
    @StateObject private var preferences = UiPreferences.shared

    init() {
        let options = LaunchOptions()
        if let theme = options.theme { UiPreferences.shared.applyLaunchTheme(theme) }
    }

    var body: some Scene {
        Window("eero Desktop · Unofficial · v1.0", id: "main") {
            RootView(model: host.model)
                .id(ObjectIdentifier(host.model))
                .frame(minWidth: 1040, minHeight: 720)
        }
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsWindow()
                .environmentObject(host.model)
        }

        // Port of the notification-area icon: shown while alerts or "keep running" are enabled.
        MenuBarExtra(isInserted: Binding(
            get: { (preferences.notifications || preferences.background) && !host.model.preview },
            set: { _ in })) {
            MenuBarContent()
        } label: {
            if let icon = ApplicationIcon.menuBarImage { Image(nsImage: icon) } else { Image(systemName: "wifi") }
        }
    }
}

/// Menu of the menu bar extra (the tray `ContextMenuStrip`: "Open eero Desktop" and "Exit").
/// Its colours follow the app appearance, which replaces `DarkTrayColors`.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open eero Desktop") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Exit") { NSApplication.shared.terminate(nil) }
    }
}
#endif
