import Testing
import Foundation
@testable import ServerLife

private typealias SLHost = ServerLife.Host

/// A local shell on a pty delivers output and an exit code.
@MainActor @Test func localCommandRunsOnPty() async throws {
    let s = try LocalShells.shared.openSession(cols: 80, rows: 24, command: "/bin/echo", args: ["hello-pty"])
    var got = Data()
    let code: Int32? = await withCheckedContinuation { cont in
        s.backend.onData = { got.append($0) }
        s.backend.onExit = { c, _ in cont.resume(returning: c) }
    }
    #expect(code == 0)
    #expect(String(decoding: got, as: UTF8.self).contains("hello-pty"))
}

/// The ControlMaster path end to end against localhost with BatchMode, which
/// can only fail (no prompt can be answered). Opt-in: SL_CONN_LIVE=1.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SL_CONN_LIVE"] != nil))
func masterFailsCleanlyAgainstLocalhost() async throws {
    var h = SLHost(type: "ssh", id: "live:localhost", name: "localhost")
    h.direct = DirectSpec(hostname: "127.0.0.1", user: "nobody-serverlife", port: 1,
                          options: ["BatchMode=yes", "ConnectTimeout=3"])
    let m = ConnectionManager.shared
    let c = try await m.create(host: h, options: ConnectOptions(timeout: 20))
    var states: [ConnState] = []
    let tok = m.subscribe { e in if case .state(_, let s, _) = e { states.append(s) } }
    defer { m.unsubscribe(tok) }
    do {
        try await m.connect(c.id)
        Issue.record("connected unexpectedly")
    } catch {
        print("live error:", error)
        print("log:", c.log.map { $0.text }.joined())
    }
    #expect(c.state == .error)
    #expect(c.lastError?.isEmpty == false)
    #expect(states.contains(.connecting))
    #expect(c.master == nil)
    // A second attempt starts afresh rather than returning a stale result.
    do { try await c.connect() } catch {}
    #expect(c.log.filter { $0.text.hasPrefix("$ ssh") }.count == 2)
    let r = await c.execReport("true", timeout: 5)
    print("exec without master:", r.error ?? "ok")
    #expect(r.error != nil)
    await m.disconnectAndWait(c.id)
    #expect(m.connection(c.id) == nil)
}
