import Foundation

/// The control socket's owner in the app (main.js `control:*` handlers and the
/// activity line automation.js put in the status bar).
@MainActor
enum AutomationControl {
    private(set) static var server: ControlServer?

    static var enabled: Bool { Store.shared.setting("controlSocket", false) }

    static var dataDir: String { Store.shared.dir.path }

    /// This program, which is also the MCP server (`ServerLife --mcp`).
    static var binaryPath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    static var defaultDataDir: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerLife-Swift", isDirectory: true).path
    }

    /// What to paste into Claude Code. The bridge reads the token from the
    /// file itself, so the command carries no secret. A data directory other
    /// than the usual one has to be named, or the bridge would look elsewhere.
    static var mcpCommand: String {
        let env = dataDir == defaultDataDir ? "" : " -e SERVERLIFE_USER_DATA=\(shellQuote(dataDir))"
        return "claude mcp add serverlife\(env) -- \"\(binaryPath)\" --mcp"
    }

    static func makeServer() -> ControlServer {
        if let s = server { return s }
        let s = ControlServer(dir: dataDir, handle: { verb, params, client in
            try await AutomationControl.handle(verb, params, client: client)
        }, onLog: { _, text in
            Task { @MainActor in AutomationControl.activity(text) }
        })
        server = s
        return s
    }

    /// `handleControl`: every accepted call is visible — automation that opens
    /// sessions should not be the one thing that happens quietly.
    static func handle(_ verb: String, _ params: JSON, client: String) async throws -> JSON {
        guard ControlVerbs.mainVerbs.contains(verb) || AutomationWindow.verbs.contains(verb) else {
            throw AppError("Unknown verb \"\(verb)\". Known: \(ControlVerbs.all.joined(separator: ", "))")
        }
        var line = "\(client.isEmpty ? "automation" : client) → \(verb)"
        if let o = params.object, !o.isEmpty {
            line += " " + String(params.jsText().prefix(200))
        }
        activity(line)
        return try await ControlVerbs.handle(verb, params)
    }

    /// Automation that opens sessions should be visible while it happens.
    static func activity(_ text: String) {
        StatusBus.shared.show("Automation: " + text, seconds: 5)
    }

    /// `control:status`.
    static func status() -> JSON {
        var j = makeServer().info
        j["enabled"] = .bool(enabled)
        j["mcpCommand"] = .string(mcpCommand)
        j["bridge"] = .string(binaryPath)
        j["verbs"] = JSON(ControlVerbs.all)
        return j
    }

    /// `control:setEnabled`.
    static func setEnabled(_ on: Bool) throws -> JSON {
        Store.shared.setSetting("controlSocket", on)
        let s = makeServer()
        // Off always stops: it also clears a socket file left behind.
        if on { try s.start() } else { s.stop() }
        var j = s.info
        j["enabled"] = .bool(on)
        return j
    }

    /// `control:rotateToken`: anything already connected was authorised with
    /// the old token, so a running socket is restarted.
    static func rotateToken() throws -> JSON {
        let s = makeServer()
        let t = try s.rotateToken()
        if s.running { s.stop(); try s.start() }
        return ["token": .string(t)]
    }

    /// At launch: off unless the user has turned it on — something that can
    /// open sessions on request should not appear because the app was installed.
    static func startIfEnabled() {
        guard enabled else { return }
        do { try makeServer().start() } catch { NSLog("control socket: \(s3Message(error))") }
    }

    static func shutdown() {
        if let s = server, s.running { s.stop() }
    }
}
