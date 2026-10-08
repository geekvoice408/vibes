import Foundation
import Testing
@testable import ServerLife

/// Live: multi-exec, headless macros and the net tools run *on* the host.
@Suite("Live fleet and net tools", .serialized, liveEnabled)
@MainActor
struct LiveFleetNetTests {

    private func waitRun(_ id: String, _ timeout: TimeInterval = 60) async -> MultiExecView? {
        await Live.waitUntil(timeout, every: 0.1) { MultiExecService.shared.view(id)?.running == false }
        return MultiExecService.shared.view(id)
    }

    @Test("multi-exec across two connections: results, streaming, failures, timeout, cancel")
    func multiExec() async throws {
        let a = try await Live.connect()
        let b = try await Live.connect()
        #expect(a.id != b.id)
        let mx = MultiExecService.shared

        let v = await mx.run([a.id, b.id], command: "echo hi-$((2+3)); echo warn >&2")
        #expect(v.results.count == 2)
        let done = try #require(await waitRun(v.id))
        for r in done.results {
            #expect(r.status == "done")
            #expect(r.exitCode == 0)
            #expect(r.stdout == "hi-5\n")
            #expect(r.stderr.contains("warn"))
            #expect((r.durationMs ?? -1) >= 0)
        }

        // streaming: partial output visible before the end
        var sawPartial = false
        let s = await mx.run([a.id], command: "for i in 1 2 3; do echo tick$i; sleep 1; done")
        await Live.waitUntil(10, every: 0.1) {
            if let r = mx.view(s.id)?.results.first, r.status == "running", r.stdout.contains("tick1"), !r.stdout.contains("tick3") {
                sawPartial = true
            }
            return mx.view(s.id)?.running == false
        }
        #expect(sawPartial, "output did not stream")
        #expect(mx.view(s.id)?.results.first?.stdout == "tick1\ntick2\ntick3\n")

        // a failing host
        let f = await mx.run([a.id, b.id], command: "echo before; exit 2")
        let fv = try #require(await waitRun(f.id))
        #expect(fv.results.allSatisfy { $0.status == "error" && $0.exitCode == 2 && $0.stdout == "before\n" })

        // timeout
        var o = MultiExecService.Options()
        o.timeout = 1500
        let t = await mx.run([a.id], command: "sleep 8; echo late", options: o)
        let tv = try #require(await waitRun(t.id, 15))
        Live.say("multi-exec timeout: \(tv.results.map { "\($0.status) code=\(String(describing: $0.exitCode)) dur=\($0.durationMs ?? -1)" })")
        #expect(tv.results.first?.status == "timeout")
        #expect(tv.results.first?.exitCode == nil)

        // cancel
        let cr = await mx.run([a.id, b.id], command: "sleep 8")
        try? await Task.sleep(nanoseconds: 800_000_000)
        mx.cancel(cr.id)
        let cv = try #require(await waitRun(cr.id, 15))
        #expect(cv.results.allSatisfy { $0.status == "cancelled" })

        // stopOnError with concurrency 1
        var so = MultiExecService.Options()
        so.concurrency = 1
        so.stopOnError = true
        let st = await mx.run([a.id, b.id], command: "exit 1", options: so)
        let sv = try #require(await waitRun(st.id))
        Live.say("stopOnError: \(sv.results.map(\.status))")
        #expect(sv.results.map(\.status) == ["error", "cancelled"])

        // a closed connection shows as an error, not a hang
        await Live.teardown(b)
        let afterClose = await mx.run([a.id, b.id], command: "true")
        let acv = try #require(await waitRun(afterClose.id))
        #expect(acv.results.count == 1, "a removed connection id was kept in the run")

        // the remote sleeps we killed should not linger
        try? await Task.sleep(nanoseconds: 500_000_000)
        let left = (try await a.exec("ps -u \"$(id -un)\" -o args= | grep -c '^sleep 8$' || true")).trimmed
        Live.say("remote 'sleep 8' processes after timeout/cancel: \(left)")
        await Live.teardown(a)
    }

    @Test("macros run headless: disk usage, memory and load, OS")
    func macrosHeadless() async throws {
        Live.wire()
        let host = Live.hostDescriptor()
        let id = try await FleetConn.ensure(host, login: nil)
        let again = try await FleetConn.ensure(host, login: nil)
        #expect(again == id, "FleetConn.ensure dialled a second connection")
        let c = try #require(ConnectionManager.shared.connection(id))
        for (mid, expect) in [("b:disk", "Filesystem"), ("b:memory", "load average"), ("b:os", "Linux")] {
            let m = try #require(Macros.builtins.first { $0.id == mid })
            #expect(!m.interactive && !m.noEnter)
            #expect(Macros.runsOn(m, "remote"))
            let r = try await ConnectionManager.shared.exec(id, m.command)
            Live.say("macro \(m.name): \(r.stdout.split(separator: "\n").first ?? "")")
            #expect(r.stdout.contains(expect))
        }
        await Live.teardown(c)
    }

    @Test("net tools on the host: tools, facts, ports, ping, trace, curl via SOCKS")
    func netTools() async throws {
        let c = try await Live.connect()
        let caps = try await NetRemote.hostTools(c.id)
        Live.say("hostTools: tools=\(caps.tools.sorted()) pkg=\(caps.pkg) os=\(caps.os) devtcp=\(caps.devtcp) hints=\(caps.hints.map { "\($0.tool): \($0.hint)" })")
        #expect(caps.pkg == "apt")
        #expect(caps.os.contains("Debian"))
        #expect(caps.canForward && caps.canProbeDirect)
        #expect(caps.tools.contains("ping"))
        #expect(caps.tools.contains("curl"))
        #expect(!caps.tools.contains("traceroute"))
        if !caps.tools.contains("tracepath") && !caps.tools.contains("mtr") {
            #expect(caps.hints.contains { $0.tool == "traceroute" && $0.hint == "sudo apt install traceroute" })
        }

        let facts = try await NetRemote.hostFacts(c.id)
        #expect(facts.hostname == c.remoteHostname)
        #expect(facts.addresses.contains("lo"))
        Live.say("hostFacts: hostname=\(facts.hostname) resolvers=\(facts.resolvers.split(separator: "\n").count) lines")

        let ports = try await NetRemote.hostPorts(c.id, host: "127.0.0.1", ports: "22,1")
        Live.say("hostPorts: \(ports.results.map { "\($0.port)=\($0.state) how=\($0.how ?? "-") banner=\($0.banner ?? "-") err=\($0.error ?? "-")" })")
        let allowed = await Live.forwardingAllowed(c)
        Live.say("server permits TCP forwarding: \(allowed)")
        let p22 = ports.results.first { $0.port == 22 }
        let p1 = ports.results.first { $0.port == 1 }
        #expect(p22?.how == "ssh -W")
        if allowed {
            #expect(p22?.state == "open")
            #expect(p22?.banner?.hasPrefix("SSH-2.0") == true)
        }
        #expect(p1?.state == "closed")
        #expect(ports.from == c.label)

        let short = try await NetRemote.hostPorts(c.id, host: "127.0.0.1:22", ports: nil)
        #expect(short.results.map(\.port) == [22])

        let ping = try await NetRemote.hostPing(c.id, host: "127.0.0.1", count: "2")
        Live.say("hostPing ok=\(ping.ok) cmd=\(ping.command) text=\(ping.text.split(separator: "\n").last ?? "")")
        #expect(ping.ok)
        #expect(ping.text.contains("2 packets transmitted"))
        #expect(ping.missing == nil)

        let trace = try await NetRemote.hostTrace(c.id, host: "127.0.0.1")
        Live.say("hostTrace ok=\(trace.ok) missing=\(trace.missing ?? "-") hint=\(trace.hint ?? "-") tool=\(trace.tool ?? "-")")
        if !caps.tools.contains("tracepath") && !caps.tools.contains("mtr") {
            #expect(!trace.ok)
            #expect(trace.missing == "traceroute")
            #expect(trace.hint == "sudo apt install traceroute")
        }

        // curl through SOCKS against a server on the host's own loopback (started here, in the scratch folder)
        let dir = try await Live.scratch(c, "www")
        _ = try await c.exec("printf 'hello from the host' > \(shellQuote(dir + "/index.txt"))")
        let port = 18000 + Int.random(in: 0..<2000)
        let pid = (try await c.exec("cd \(shellQuote(dir)) && (nohup python3 -m http.server \(port) --bind 127.0.0.1 >/dev/null 2>&1 & echo $!)", timeout: 10)).trimmed
        Live.say("started python http.server pid \(pid) on 127.0.0.1:\(port) on the host")
        defer {
            Task { @MainActor in _ = try? await c.exec("kill \(pid) 2>/dev/null; true") }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard allowed else {
            var o = CurlOptions(); o.url = "http://127.0.0.1:\(port)/index.txt"; o.timeout = 5
            do { _ = try await NetRemote.hostCurl(c.id, o); Issue.record("curl through a prohibited SOCKS succeeded") }
            catch { Live.say("hostCurl with forwarding prohibited → \(errorText(error))") }
            #expect(c.forwards.isEmpty, "withSocks left its forward")
            _ = try await c.exec("kill \(pid) 2>/dev/null; rm -rf \(shellQuote(Live.guardScratch(dir)))")
            await Live.teardown(c)
            return
        }
        var o = CurlOptions()
        o.url = "http://127.0.0.1:\(port)/index.txt"
        o.timeout = 10
        let res = try await NetRemote.hostCurl(c.id, o)
        Live.say("hostCurl: ok=\(res.ok) status=\(res.status) body=\(res.body.prefix(40)) cmd=\(res.command)")
        #expect(res.status == 200)
        #expect(res.body == "hello from the host")
        #expect(res.command.contains("--socks5-hostname"))
        #expect(c.forwards.isEmpty, "withSocks left its forward")
        // name resolved at the far side: "localhost" is the host's own
        o.url = "http://localhost:\(port)/index.txt"
        let res2 = try await NetRemote.hostCurl(c.id, o)
        #expect(res2.status == 200)

        _ = try await c.exec("kill \(pid) 2>/dev/null; rm -rf \(shellQuote(Live.guardScratch(dir)))")
        await Live.teardown(c)
    }
}
