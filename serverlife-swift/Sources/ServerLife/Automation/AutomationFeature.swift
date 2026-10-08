import AppKit
import Foundation

/// Control socket, MCP bridge, S3 and AWS (control.js, serverlife-mcp.mjs,
/// automation.js, s3.js, awscreds.js, awsproxy.js). See Automation/README.md.
///
/// `ServerLife --mcp` is `MCPBridge.runStdio()` (Control/MCPBridge.swift),
/// called by App/Main.swift before NSApplication starts.
@MainActor
enum AutomationFeature {
    static func install() {
        let a = Actions.shared

        // S3 Buckets… (the `s3` menu item: s3.js openS3Manager)
        a.register("s3") { ctx in S3UI.openManager(ctx.window) }
        // Register a bucket… / Edit… — args `target` JSON (a record from S3Service.shared.targets) to edit.
        a.register("s3-register") { ctx in
            Task { await S3UI.openEditor(ctx.window, initial: ctx.arg("target", as: JSON.self) ?? [:]) }
        }
        // Re-read the registered buckets after the store was replaced (backup import).
        a.register("s3-reload") { _ in S3Service.shared.reload() }
        S3Service.shared.reload()

        // Settings → Local automation (the misc owner's dialog calls these).
        a.register("automation-status") { ctx in
            ctx.arg("reply", as: ((JSON) -> Void).self)?(AutomationControl.status())
        }
        a.register("automation-toggle") { ctx in
            let reply = ctx.arg("reply", as: ((JSON) -> Void).self)
            do {
                reply?(try AutomationControl.setEnabled(ctx.arg("enabled", as: Bool.self) ?? false))
            } catch {
                reply?(["error": .string(s3Message(error))])
            }
        }
        a.register("automation-rotate") { ctx in
            let reply = ctx.arg("reply", as: ((JSON) -> Void).self)
            do { reply?(try AutomationControl.rotateToken()) } catch { reply?(["error": .string(s3Message(error))]) }
        }
        a.register("automation-copy-command") { ctx in
            let s = AutomationControl.status()
            let what = ctx.arg("what", as: String.self) ?? "mcp"
            Clipboard.write((what == "bridge" ? s["bridge"] : s["mcpCommand"]).string ?? "")
            StatusBus.shared.show("Copied")
        }

        AutomationControl.startIfEnabled()
        AppDelegate.willTerminate.append {
            AutomationControl.shutdown()
            AWSProxy.stopAll()
        }
    }
}
