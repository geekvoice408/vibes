import SwiftUI
import AppKit

@main
struct TeleportConnectNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: appDelegate.sharedModel)
                .preferredColorScheme(appDelegate.sharedModel.colorSchemeOverride)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1280, height: 720)
        .commands {
            // Mirrors the "Open new terminal" action in TopBar/AdditionalActions.tsx, given a
            // real menu-bar shortcut (⌘T) instead of only being reachable via the tab strip's "+".
            CommandGroup(after: .newItem) {
                Button("New Terminal") {
                    appDelegate.sharedModel.openLocalShellTab()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
        }
    }
}

/// Ensures tshd is terminated gracefully on quit instead of being orphaned — SwiftUI's
/// App lifecycle has no reliable synchronous teardown hook, so we hold the model here and
/// delay termination until the daemon has actually been asked to stop.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sharedModel = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched via a raw `swift build` binary (no Finder/LaunchServices), so without this
        // the app may never become the frontmost/active app — its window still receives mouse
        // clicks either way, but global keyboard shortcuts like Cmd+T go to whichever app IS
        // frontmost (often the terminal that launched it) instead of us.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await sharedModel.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
