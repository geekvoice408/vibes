import AppKit

@main
enum Main {
    static func main() {
        // `ServerLife --mcp` is the MCP server over stdio: the same binary,
        // so registering it needs no Node and no second install.
        if CommandLine.arguments.contains("--mcp") {
            MCPBridge.runStdio()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Asked before quitting; any `false` cancels (quit guard, running transfers).
    static var shouldTerminate: [() async -> Bool] = []
    /// Run on the way out (tear down ControlMasters, stop watchers).
    static var willTerminate: [() -> Void] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Proc.warmUp()
        Store.shared.load()
        Tools.setSshPath(Store.shared.setting("sshPath", ""))
        Tools.setTshPath(Store.shared.setting("tshPath", ""))
        Theme.shared.start()
        MainMenu.shared.install()
        Features.installAll()
        WindowManager.shared.open(slot: "w1", options: ["launch": true])
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.runIfRequested()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppDelegate.shouldTerminate.isEmpty else { return .terminateNow }
        Task { @MainActor in
            for check in AppDelegate.shouldTerminate where !(await check()) {
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.willTerminate.forEach { $0() }
        Store.shared.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.open() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Every feature's `install()`, in dependency order: data and services
/// before the interface that uses them.
@MainActor
enum Features {
    static func installAll() {
        AppActions.install()
        DataFeature.install()
        ConnectionsFeature.install()
        TeleportServiceFeature.install()
        FilesServiceFeature.install()
        DevicesServiceFeature.install()
        SessionsFeature.install()
        SidebarFeature.install()
        HostsFeature.install()
        ExplorerFeature.install()
        TeleportUIFeature.install()
        FleetFeature.install()
        NetToolsFeature.install()
        ConsolesFeature.install()
        CityFeature.install()
        MiscFeature.install()
        AutomationFeature.install()
    }
}

/// The handful of actions that belong to the shell itself.
@MainActor
enum AppActions {
    static func install() {
        let a = Actions.shared
        a.register("new-window") { _ in WindowManager.shared.open() }
        a.register("toggle-sidebar") { ctx in
            guard let w = ctx.window else { return }
            w.sidebarVisible.toggle()
        }
        a.register("toggle-transfers") { ctx in
            guard let w = ctx.window else { return }
            // dock.js toggleDock(): show or hide, on whichever tab was last open.
            w.dockVisible.toggle()
        }
        a.register("teleport-docs") { _ in
            NSWorkspace.shared.open(URL(string: "https://goteleport.com/docs/connect-your-client/tsh/")!)
        }
    }
}
