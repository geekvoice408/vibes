import Foundation
import Testing
@testable import ServerLife

/// Live: ConnectionManager, exec, server profile, history, terminals,
/// forwards — against SL_LIVE_HOST over a real ControlMaster.
@Suite("Live connections", .serialized, liveEnabled)
@MainActor
struct LiveConnectionTests {

    @Test("connect → state transitions, identity, reuse, teardown")
    func lifecycle() async throws {
        Live.wire()
        let m = ConnectionManager.shared
        let c = try await m.create(host: Live.hostDescriptor(), options: ConnectOptions(timeout: 40))
        #expect(c.state == .idle)
        #expect(c.type == "ssh")
        #expect(c.transport == .mux)
        #expect(c.target == LiveEnv.host)
        var states: [ConnState] = []
        let tok = m.subscribe { e in if case .state(let id, let s, _) = e, id == c.id { states.append(s) } }
        defer { m.unsubscribe(tok) }
        try await m.connect(c.id)
        Live.say("states \(states.map(\.rawValue)) log=\(c.log.map(\.text).joined().prefix(300))")
        #expect(c.state == .connected)
        #expect(states.first == .connecting)
        #expect(states.contains(.connected))
        #expect(!states.contains(.error))
        #expect(FileManager.default.fileExists(atPath: c.controlPath))
        #expect(await c.checkMaster())
        #expect(c.homeDir?.hasPrefix("/") == true)
        #expect(c.remoteUser?.isEmpty == false)
        #expect(c.remoteHostname?.isEmpty == false)
        Live.say("info home=\(c.homeDir ?? "-") user=\(c.remoteUser ?? "-") host=\(c.remoteHostname ?? "-")")

        // A second connect is a no-op.
        try await c.connect()
        #expect(c.log.filter { $0.text.hasPrefix("$ ssh") }.count == 1)

        // reuse:true returns the open one; the default creates a new one.
        let again = try await m.create(host: Live.hostDescriptor(), options: ConnectOptions(reuse: true))
        #expect(again === c)
        let fresh = try await m.create(host: Live.hostDescriptor())
        #expect(fresh !== c)
        await m.disconnectAndWait(fresh.id)   // never dialled

        // history recorded on success
        let hist = Store.shared["history"].array ?? []
        #expect(hist.contains { $0["id"].string == c.historyId })

        // conn:list shape
        let row = m.list().first { $0["id"].string == c.id }
        #expect(row?["state"].string == "connected")
        #expect(row?["transport"].string == "mux")

        let hid = c.historyId
        await Live.teardown(c)
        // history entry ended
        let ended = (Store.shared["history"].array ?? []).first { $0["id"].string == hid }
        #expect(ended?["endedAt"].isNull == false)
    }

    @Test("exec: stdout, stderr, exit codes, timeouts, errors")
    func exec() async throws {
        let c = try await Live.connect()
        let m = ConnectionManager.shared

        let ok = try await m.exec(c.id, "echo out-line; echo err-line >&2; printf 'ü✓'")
        #expect(ok.code == 0)
        #expect(ok.stdout == "out-line\nü✓")
        #expect(ok.stderr.contains("err-line"))
        #expect(ok.durationMs >= 0)

        let bad = try await m.execResult(c.id, "echo partial; echo 'went wrong' >&2; exit 3")
        #expect(bad.code == 3)
        #expect(bad.stdout == "partial\n")
        #expect(bad.error == "went wrong")
        do {
            _ = try await m.exec(c.id, "echo 'went wrong' >&2; exit 3")
            Issue.record("exec should throw on a non-zero exit")
        } catch {
            #expect((error as? AppError)?.message == "went wrong")
        }

        let silent = try await m.execResult(c.id, "exit 4")
        #expect(silent.code == 4)
        #expect(silent.error == "The command exited 4 on \(c.label) and printed no error.")

        let slow = try await m.execResult(c.id, "sleep 6", timeout: 1.5)
        #expect(slow.timedOut)
        #expect(slow.error == "\(c.label) did not answer within the time allowed.")
        Live.say("timeout exec error: \(slow.error ?? "nil") in \(slow.durationMs)ms")

        // keepOutput: a failure with output returns it
        let kept = try await c.exec("echo some; exit 1", keepOutput: true)
        #expect(kept.contains("some"))

        // missing connection
        do { _ = try await m.exec("conn-nope", "true"); Issue.record("expected throw") }
        catch { #expect((error as? AppError)?.message == "No such connection: conn-nope") }

        // the sleep we timed out must not linger on the host
        try? await Task.sleep(nanoseconds: 300_000_000)
        let ps = try await c.exec("ps -u \"$(id -un)\" -o args= | grep -c '^sleep 6$' || true")
        Live.say("remote 'sleep 6' still running after local timeout: \(ps.trimmed)")

        await Live.teardown(c)
    }

    @Test("server profile and shell history")
    func serverProfile() async throws {
        let c = try await Live.connect()
        let m = ConnectionManager.shared
        let info = try await m.serverInfo(c.id)
        Live.say("serverInfo \(info.values.keys.sorted()) os=\(info.osLabel) partial=\(info.partial ?? "-")")
        #expect(info["kernel_sys"] == "Linux")
        #expect(info["arch"] == "aarch64")
        #expect(info["os_id"] == "debian")
        #expect(info["hostname"]?.isEmpty == false)
        #expect(info["user"] == c.remoteUser)
        #expect(info["pkg"] == "apt")
        #expect((info.memTotal ?? 0) > 0)
        #expect(info.osLabel.contains("Debian"))
        #expect(info.partial == nil)
        #expect(c.serverInfo != nil)
        // cached until refresh
        let cached = try await m.serverInfo(c.id)
        #expect(cached.fetchedAt == info.fetchedAt)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let fresh = try await m.serverInfo(c.id, refresh: true)
        #expect(fresh.fetchedAt > info.fetchedAt)

        let h = try await m.shellHistory(c.id, limit: 50)
        Live.say("shell history: \(h.entries.count) entries, truncated=\(h.truncated), shells=\(Set(h.entries.map(\.shell)))")
        #expect(h.entries.count <= 50)
        #expect(Set(h.entries.map(\.command)).count == h.entries.count)
        let h2 = try await m.shellHistory(c.id, limit: 50)
        #expect(h2.at == h.at)

        await Live.teardown(c)
    }

    @Test("terminal: write, read, resize, cwd, startup command, log, close")
    func terminal() async throws {
        let c = try await Live.connect()
        let m = ConnectionManager.shared
        let dir = try await Live.scratch(c, "term")

        let t = try #require(try await m.openTerminal(c.id, options: TerminalOptions(cols: 100, rows: 30,
                                                                       startupCommand: "echo START-$((40+2))",
                                                                       remoteStartPath: dir)) as? RemoteTerminal)
        #expect(t.kind == "ssh")
        var out = Data()
        var exitCode: Int32?? = nil
        t.onData = { out.append($0) }
        t.onExit = { code, _ in exitCode = .some(code) }
        func text() -> String { String(decoding: out, as: UTF8.self) }

        #expect(await Live.waitUntil(15) { text().contains("START-42") }, "startup command output: \(text().suffix(400))")
        t.write(Data("echo MARK-$((6*7))\n".utf8))
        #expect(await Live.waitUntil(10) { text().contains("MARK-42") })
        t.write(Data("pwd\n".utf8))
        #expect(await Live.waitUntil(10) { text().contains(dir) }, "remoteStartPath not applied: \(text().suffix(300))")

        t.resize(cols: 123, rows: 41)
        try? await Task.sleep(nanoseconds: 300_000_000)
        t.write(Data("stty size\n".utf8))
        #expect(await Live.waitUntil(10) { text().contains("41 123") }, "resize not seen: \(text().suffix(300))")

        // cwd probe over the mux
        t.write(Data("cd /tmp\n".utf8))
        try? await Task.sleep(nanoseconds: 600_000_000)
        let cwd = await t.cwd()
        Live.say("terminal cwd after cd /tmp: \(cwd ?? "nil")")
        #expect(cwd == "/tmp")
        #expect(await m.terminalCwd(c.id, termId: t.id) == "/tmp")

        // session log
        let logDir = try LiveLocal.dir("log")
        defer { LiveLocal.remove(logDir) }
        let logPath = logDir + "/s.log"
        try m.startLog(c.id, termId: t.id, path: logPath)
        #expect(try m.logState(c.id, termId: t.id).active)
        t.write(Data("printf 'LOGGED-\\033[1m%s\\033[0m\\n' $((1+1))\n".utf8))
        #expect(await Live.waitUntil(10) { text().contains("LOGGED-") })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(try m.stopLog(c.id, termId: t.id) == logPath)
        let logged = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        #expect(logged.contains("ServerLife session log"))
        #expect(logged.contains("LOGGED-2"))
        #expect(!logged.contains("\u{1b}["))

        #expect(c.terminalIds.contains(t.id))
        // the shell's own exit is reported
        t.write(Data("exit 7\n".utf8))
        #expect(await Live.waitUntil(10) { exitCode != nil })
        Live.say("terminal exit code: \(String(describing: exitCode))")
        #expect(exitCode == .some(7))
        #expect(!c.terminalIds.contains(t.id))

        // close() on a live terminal
        let t2 = try await c.openTerminal(TerminalOptions(cols: 80, rows: 24))
        var out2 = Data()
        t2.onData = { out2.append($0) }
        t2.write("echo T2-UP\n")
        #expect(await Live.waitUntil(10) { String(decoding: out2, as: UTF8.self).contains("T2-UP") })
        t2.close()
        t2.close()   // safe twice
        #expect(!c.terminalIds.contains(t2.id))
        #expect(await Live.waitUntil(5) { t2.hasExited }, "terminal process did not exit after close()")

        _ = try await c.exec("rm -rf \(shellQuote(Live.guardScratch(dir)))")
        await Live.teardown(c)
    }

    @Test("forwards: -L to the host's sshd, -D SOCKS to the host's sshd, remove")
    func forwards() async throws {
        let c = try await Live.connect()
        let m = ConnectionManager.shared
        let allowed = await Live.forwardingAllowed(c)
        Live.say("server permits TCP forwarding: \(allowed)")

        let lport = try Connection.freeLocalPort()
        let f = try await m.addForward(c.id, ForwardSpec(kind: "L", bindAddr: "127.0.0.1", bindPort: lport,
                                                          destHost: "127.0.0.1", destPort: 22, label: "live"))
        #expect(f.spec == "127.0.0.1:\(lport):127.0.0.1:22")
        #expect(try m.listForwards(c.id).count == 1)
        #expect(m.allForwards().contains { $0.id == f.id })
        let b = await LiveSocket.banner(lport)
        Live.say("-L banner: \(b?.trimmed ?? "nil")")
        if allowed { #expect(b?.hasPrefix("SSH-2.0-") == true) }

        do {
            _ = try await m.addForward(c.id, ForwardSpec(kind: "L", bindAddr: "127.0.0.1", bindPort: lport,
                                                         destHost: "127.0.0.1", destPort: 22))
            Issue.record("duplicate forward accepted")
        } catch { #expect((error as? AppError)?.message == "That forward already exists") }

        // A port already taken locally: the master refuses.
        do {
            let busy = try await m.addForward(c.id, ForwardSpec(kind: "L", bindAddr: "127.0.0.1", bindPort: lport,
                                                                destHost: "127.0.0.1", destPort: 2222))
            Live.say("second -L on a taken local port was ACCEPTED as \(busy.id)")
            Issue.record("a -L on a local port already in use was accepted")
            try await m.removeForward(c.id, busy.id)
        } catch {
            Live.say("second -L on a taken local port refused: \((error as? AppError)?.message ?? "\(error)")")
        }

        try await m.removeForward(c.id, f.id)
        #expect(try m.listForwards(c.id).isEmpty)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await LiveSocket.banner(lport) == nil, "-L port still answering after removal")

        let dport = try Connection.freeLocalPort()
        let d = try await m.addForward(c.id, ForwardSpec(kind: "D", bindAddr: "127.0.0.1", bindPort: dport))
        #expect(d.spec == "127.0.0.1:\(dport)")
        let sb = await LiveSocket.socksBanner(dport, ip: (127, 0, 0, 1), port: 22)
        Live.say("SOCKS → 127.0.0.1:22 banner: \(sb?.trimmed ?? "nil")")
        if allowed { #expect(sb?.hasPrefix("SSH-2.0-") == true) } else { #expect(sb?.hasPrefix("SSH-2.0-") != true) }
        try await m.removeForward(c.id, d.id)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(LiveSocket.connect(dport).map { Darwin.close($0); return true } == nil, "SOCKS port still open after removal")

        // withSocks tears its forward down
        let seen = try await c.withSocks { proxy -> String in
            let port = Int(proxy.split(separator: ":").last!)!
            return await LiveSocket.socksBanner(port, ip: (127, 0, 0, 1), port: 22) ?? ""
        }
        if allowed { #expect(seen.hasPrefix("SSH-2.0-")) }
        #expect(c.forwards.isEmpty)

        // forwards go with the connection
        let p3 = try Connection.freeLocalPort()
        _ = try await m.addForward(c.id, ForwardSpec(kind: "L", bindAddr: "127.0.0.1", bindPort: p3, destHost: "127.0.0.1", destPort: 22))
        await Live.teardown(c)
        #expect(await LiveSocket.banner(p3) == nil, "-L port still answering after disconnect")
    }

    @Test("tmux probe on a host without tmux")
    func tmuxProbe() async throws {
        let c = try await Live.connect()
        let p = await TmuxService.shared.probe(c)
        Live.say("tmux probe: ok=\(p.ok) reason=\(p.reason ?? "-") install=\(p.install ?? "-")")
        #expect(!p.ok)
        #expect(p.reason == "tmux is not installed on this host")
        #expect(p.install == "apt install tmux · dnf install tmux · apk add tmux")
        do {
            _ = try await TmuxService.shared.attach(c, session: nil, cols: 80, rows: 24) { _ in }
            Issue.record("attach should refuse without tmux")
        } catch {
            #expect((error as? AppError)?.message == "tmux is not installed on this host")
        }
        await Live.teardown(c)
    }
}
