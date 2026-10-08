import Foundation
import CShim

// The network questions a connection can answer from the far side
// (connections.js hostTools / hostFacts / probeTcp / probePorts / hostPing /
// hostTrace / withSocks). The net tools window (nettools owner) calls these.

/// Which diagnostic tools a host has, read in one exec and cached.
struct HostTools: Sendable {
    var tools: Set<String>
    var devtcp: Bool
    var ncFlavour: String
    var busybox: Bool
    var pkg: String
    var os: String
    /// A tsh session takes a port forward; a beam does not.
    var canForward: Bool
    /// Only a mux session can `ssh -W`.
    var canProbeDirect: Bool
    var transport: String
    var at: Double

    func has(_ t: String) -> Bool { tools.contains(t) }
}

/// Addresses, routes and resolvers, as the host sees them.
struct HostFacts: Sendable, Equatable {
    var hostname = ""
    var addresses = ""
    var routes = ""
    var resolvers = ""
}

/// One port check: open / closed / filtered / dns / error / unknown.
struct PortProbe: Sendable, Equatable {
    var port: Int
    /// nil when it could not be determined.
    var open: Bool?
    var state: String
    var ms: Double
    var how: String?
    var banner: String?
    var error: String?
}

/// Ping or traceroute output from the host. `missing` names the tool to install.
struct HostRunResult: Sendable {
    var ok: Bool
    var text: String
    var missing: String?
    var tool: String?
    var command: String
}

extension Connection {
    nonisolated static let wantedTools = [
        "ping", "ping6", "traceroute", "tracepath", "mtr", "dig", "host", "nslookup",
        "getent", "nc", "ncat", "socat", "openssl", "curl", "wget", "python3",
        "ip", "ss", "netstat", "timeout", "whois",
        // For opening a telnet session *from* the host.
        "telnet",
    ]

    nonisolated static var hostToolsScript: String {
        [
            "LC_ALL=C",
            "for t in \(wantedTools.joined(separator: " ")); do command -v \"$t\" >/dev/null 2>&1 && printf 'tool=%s\\n' \"$t\"; done",
            "printf 'devtcp=%s\\n' \"$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null && echo yes || echo no)\"",
            "printf 'ncflavour=%s\\n' \"$(nc -h 2>&1 | head -1 | tr -d '\\n')\"",
            "for p in apt dnf yum zypper apk pacman brew; do command -v \"$p\" >/dev/null 2>&1 && { printf 'pkg=%s\\n' \"$p\"; break; }; done",
            "printf 'os=%s\\n' \"$( . /etc/os-release 2>/dev/null; echo \"$PRETTY_NAME\" )\"",
        ].joined(separator: "; ")
    }

    /// Parse the hostTools probe.
    nonisolated static func parseHostTools(_ out: String, transport: ConnTransport) -> HostTools {
        var tools = Set<String>()
        var devtcp = false, nc = "", pkg = "", os = ""
        for line in out.components(separatedBy: "\n") {
            let parts = line.trimmed.components(separatedBy: "=")
            guard let k = parts.first else { continue }
            let v = parts.dropFirst().joined(separator: "=")
            switch k {
            case "tool": tools.insert(v)
            case "devtcp": devtcp = v == "yes"
            case "ncflavour": nc = v
            case "pkg": pkg = v
            case "os": os = v
            default: break
            }
        }
        return HostTools(tools: tools, devtcp: devtcp, ncFlavour: nc,
                         busybox: nc.range(of: "busybox", options: .caseInsensitive) != nil,
                         pkg: pkg, os: os, canForward: transport != .beam, canProbeDirect: transport == .mux,
                         transport: transport.rawValue, at: nowMs())
    }

    /// Which diagnostic tools this host has — one exec, cached for the connection.
    func hostTools(refresh: Bool = false) async throws -> HostTools {
        if let t = toolsCache, !refresh { return t }
        let out = try await exec(Connection.hostToolsScript)
        let t = Connection.parseHostTools(out, transport: transport)
        toolsCache = t
        return t
    }

    nonisolated static func parseHostFacts(_ text: String) -> HostFacts {
        var out: [String: String] = ["hostname": "", "addresses": "", "routes": "", "resolvers": ""]
        var key: String?
        let marker = ConnText.re(#"^--(hostname|addresses|routes|resolvers)$"#)
        for line in text.components(separatedBy: "\n") {
            if let m = ConnText.match(marker, line) { key = m[1]; continue }
            if let k = key { out[k] = (out[k]!.isEmpty ? "" : out[k]! + "\n") + line }
        }
        return HostFacts(hostname: out["hostname"]!.trimmed, addresses: out["addresses"]!.trimmed,
                         routes: out["routes"]!.trimmed, resolvers: out["resolvers"]!.trimmed)
    }

    /// Addresses, routes and resolvers, as the host sees them.
    func hostFacts() async throws -> HostFacts {
        let script = [
            "LC_ALL=C",
            "echo \"--hostname\"; hostname 2>/dev/null",
            "echo \"--addresses\"; { ip -brief addr 2>/dev/null || ifconfig 2>/dev/null; }",
            "echo \"--routes\"; { ip route 2>/dev/null || netstat -rn 2>/dev/null; }",
            "echo \"--resolvers\"; { cat /etc/resolv.conf 2>/dev/null; }",
        ].joined(separator: "; ")
        return Connection.parseHostFacts(try await exec(script))
    }

    /// Narrowed again before it goes into a shell command on someone else's machine.
    nonisolated static func safeHost(_ host: String) -> String {
        ConnText.replace(ConnText.re(#"[^A-Za-z0-9._:-]"#), in: host, with: "")
    }

    /// Can this host open TCP to `host:port`? Over the mux by `ssh -W` (the
    /// verdict is ssh's exit status; a timeout is "filtered"); elsewhere with
    /// the host's own tools.
    func probeTcp(_ host: String, port: Int, timeout: TimeInterval = 4) async -> PortProbe {
        guard transport == .mux else {
            return await probePortsWithTools(host, ports: [port], timeout: timeout).first
                ?? PortProbe(port: port, open: nil, state: "unknown", ms: 0, how: nil, error: nil)
        }
        let started = Date()
        let args = sshArgs(["-W", "\(host):\(port)", target])
        let banner = LockedText(), err = LockedText()
        return await withCheckedContinuation { (cont: CheckedContinuation<PortProbe, Never>) in
            var settled = false
            var proc: RunningProcess?
            var timer: DispatchWorkItem?
            let done: @MainActor (String, String?) -> Void = { state, note in
                if settled { return }
                settled = true
                timer?.cancel()
                proc?.terminate(grace: 1)
                let open = state == "open"
                let b = ConnText.replace(ConnText.re(#"[^\x20-\x7e]"#), in: banner.text, with: " ").trimmed
                cont.resume(returning: PortProbe(
                    port: port, open: open, state: state, ms: (Date().timeIntervalSince(started) * 1000).rounded(),
                    how: "ssh -W", banner: b.isEmpty ? nil : String(b.prefix(120)),
                    error: open ? nil : (note ?? ConnText.firstProblem(err.text).nilIfEmpty)))
            }
            do {
                proc = try RunningProcess(Tools.ssh, args, env: procEnv(), onStdout: { d in
                    banner.append(String(decoding: d, as: UTF8.self))
                }, onStderr: { d in
                    err.append(String(decoding: d, as: UTF8.self))
                }, onExit: { code in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if code == 0 { return done("open", nil) }
                            let e = err.text
                            if ConnText.test(ConnText.re(#"not known|Name or service|could not resolve|no address"#, ci: true), e) {
                                return done("dns", nil)
                            }
                            if ConnText.test(ConnText.re(#"refused by peer|Session open refused"#, ci: true), e) {
                                return done("closed", "the host refused it — nothing listening, or the name does not resolve from there")
                            }
                            done("closed", nil)
                        }
                    }
                })
                // stdin at EOF: an open port connects, sees no input, and exits 0.
                proc?.closeStdin()
            } catch {
                done("error", (error as? AppError)?.message ?? error.localizedDescription)
                return
            }
            let w = DispatchWorkItem { MainActor.assumeIsolated { done("filtered", "no answer before the timeout") } }
            timer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1.5, timeout), execute: w)
        }
    }

    /// Several ports in one command on the host (bash /dev/tcp, nc, python3).
    func probePortsWithTools(_ host: String, ports: [Int], timeout: TimeInterval = 4) async -> [PortProbe] {
        let started = Date()
        let caps = try? await hostTools()
        let secs = max(1, Int((timeout).rounded()))
        let h = Connection.safeHost(host)
        let list = ports.filter { $0 > 0 && $0 < 65536 }

        var how: String?
        var probe: ((Int) -> String)?
        if let caps, caps.devtcp {
            how = "bash /dev/tcp"
            let to = caps.has("timeout") ? "timeout \(secs) " : ""
            probe = { p in "\(to)bash -c 'exec 3<>/dev/tcp/\(h)/\(p)'" }
        } else if let caps, caps.has("nc") || caps.has("ncat") {
            let bin = caps.has("nc") ? "nc" : "ncat"
            how = bin
            probe = { p in caps.busybox ? "\(bin) -w \(secs) \(h) \(p) </dev/null >/dev/null" : "\(bin) -z -w \(secs) \(h) \(p)" }
        } else if let caps, caps.has("python3") {
            how = "python3"
            probe = { p in "python3 -c 'import socket,sys;s=socket.socket();s.settimeout(\(secs));sys.exit(s.connect_ex((\"\(h)\",\(p))))'" }
        }
        guard let probe else {
            return list.map { PortProbe(port: $0, open: nil, state: "unknown", ms: 0, how: nil,
                                        error: "This session cannot forward, and the host has no nc, python3 or bash /dev/tcp") }
        }
        let script = (["LC_ALL=C"] + list.map { p in
            "e=$( { \(probe(p)); } 2>&1 ); printf 'p=%s rc=%s %s\\n' \(p) \"$?\" \"$(printf '%s' \"$e\" | tr '\\n' ' ')\""
        }).joined(separator: "; ")

        let out: String
        do { out = try await exec(script) } catch {
            let ms = (Date().timeIntervalSince(started) * 1000).rounded()
            return list.map { PortProbe(port: $0, open: nil, state: "unknown", ms: ms, how: how, error: (error as? AppError)?.message) }
        }
        let ms = (Date().timeIntervalSince(started) * 1000).rounded()
        return Connection.parsePortProbes(out, ports: list, ms: ms, how: how)
    }

    nonisolated static func parsePortProbes(_ out: String, ports: [Int], ms: Double, how: String?) -> [PortProbe] {
        var byPort: [Int: PortProbe] = [:]
        let line = ConnText.re(#"^p=(\d+) rc=(\d+)\s*(.*)$"#)
        let to = ConnText.re(#"timed out|timeout"#, ci: true)
        let dns = ConnText.re(#"not known|Name or service|could not resolve|no address|nodename"#, ci: true)
        for l in out.components(separatedBy: "\n") {
            guard let m = ConnText.match(line, l), let port = Int(m[1]) else { continue }
            let rc = Int(m[2]) ?? -1
            let note = m[3].trimmed
            var state = "closed"
            if rc == 0 { state = "open" }
            else if rc == 124 || rc == 137 || ConnText.test(to, note) { state = "filtered" }
            else if ConnText.test(dns, note) { state = "dns" }
            byPort[port] = PortProbe(port: port, open: state == "open", state: state, ms: ms, how: how, banner: nil,
                                     error: state == "open" ? nil
                                        : (note.nilIfEmpty ?? (state == "filtered" ? "no answer before the timeout" : "connection refused")))
        }
        return ports.map { byPort[$0] ?? PortProbe(port: $0, open: nil, state: "unknown", ms: ms, how: how,
                                                  error: "the host gave no answer for this port") }
    }

    /// Several ports, whichever route this session has: `ssh -W` four at a
    /// time over the mux, one batched exec otherwise.
    func probePorts(_ host: String, ports: [Int], timeout: TimeInterval = 4, concurrency: Int = 4) async -> [PortProbe] {
        let list = ports.filter { $0 > 0 && $0 < 65536 }
        if transport != .mux { return await probePortsWithTools(host, ports: list, timeout: timeout) }
        var out = [PortProbe?](repeating: nil, count: list.count)
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(concurrency, list.count) {
                group.addTask { @MainActor in
                    while true {
                        let i = next; next += 1
                        if i >= list.count { return }
                        out[i] = await self.probeTcp(host, port: list[i], timeout: timeout)
                    }
                }
            }
        }
        return out.compactMap { $0 }
    }

    /// Ping, from the host; the output is shown as the host printed it.
    func hostPing(_ host: String, count: Int = 5) async -> HostRunResult {
        let caps = try? await hostTools()
        let h = Connection.safeHost(host)
        let n = min(max(count, 1), 20)
        if let caps, !caps.has("ping") {
            return HostRunResult(ok: false, text: "", missing: "ping", tool: nil, command: "ping -c \(n) \(h)")
        }
        let cmd = "ping -c \(n) -i 0.3 \(h) 2>&1"
        let command = caps?.has("timeout") == true ? "timeout \(n * 2 + 8) \(cmd)" : cmd
        let text: String
        do { text = try await exec("LC_ALL=C; \(command)", timeout: TimeInterval(n * 2 + 20), keepOutput: true) }
        catch { text = (error as? AppError)?.message ?? error.localizedDescription }
        let t = text.trimmed
        return HostRunResult(ok: t.range(of: #"bytes from|packets transmitted"#, options: [.regularExpression, .caseInsensitive]) != nil,
                             text: t, missing: nil, tool: "ping", command: "ping -c \(n) \(h)")
    }

    /// The path from the host: traceroute, else tracepath, else mtr.
    func hostTrace(_ host: String, maxHops: Int = 20) async -> HostRunResult {
        let caps = try? await hostTools()
        let h = Connection.safeHost(host)
        let hops = min(max(maxHops, 1), 40)
        let chain: [(tool: String, cmd: String)] = [
            ("traceroute", "traceroute -m \(hops) -w 2 -q 1 \(h)"),
            ("tracepath", "tracepath -m \(hops) \(h)"),
            ("mtr", "mtr --report --report-cycles 1 -m \(hops) \(h)"),
        ]
        guard let pick = chain.first(where: { caps?.has($0.tool) == true }) else {
            return HostRunResult(ok: false, text: "", missing: "traceroute", tool: nil, command: chain[0].cmd)
        }
        let budget = hops * 3 + 10
        let command = caps?.has("timeout") == true ? "timeout \(budget) \(pick.cmd)" : pick.cmd
        let text: String
        do { text = try await exec("LC_ALL=C; \(command) 2>&1", timeout: TimeInterval(budget + 15), keepOutput: true) }
        catch { text = (error as? AppError)?.message ?? error.localizedDescription }
        return HostRunResult(ok: !text.trimmed.isEmpty, text: text.trimmed, missing: nil, tool: pick.tool, command: pick.cmd)
    }

    /// Run something with a SOCKS proxy through this host (a temporary -D
    /// forward, torn down afterwards whatever happened). `body` gets
    /// "127.0.0.1:<port>".
    func withSocks<T>(_ body: (String) async throws -> T) async throws -> T {
        if transport == .beam {
            throw AppError("A beam does not take port forwards, so there is no proxy to run through.")
        }
        let port = try Connection.freeLocalPort()
        let rec = try await addForward(ForwardSpec(kind: "D", bindAddr: "127.0.0.1", bindPort: port))
        do {
            let r = try await body("127.0.0.1:\(port)")
            await removeForward(rec.id)
            return r
        } catch {
            await removeForward(rec.id)
            throw error
        }
    }

    /// A local port nothing is listening on.
    nonisolated static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError("Could not open a socket") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { throw AppError("Could not find a free local port") }
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { throw AppError("Could not find a free local port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
