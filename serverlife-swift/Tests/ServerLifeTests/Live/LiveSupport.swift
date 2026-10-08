import Foundation
import CryptoKit
import Testing
@testable import ServerLife

// Support for the opt-in live suite (LiveHostTests.swift).
//
// Everything here dials a REAL host, so it only runs when SL_LIVE_HOST names
// one (an ssh_config alias with key auth). Every file it creates, changes or
// removes on that host is inside ~/serverlife-swift-test; `LiveEnv.remote(_:)`
// refuses any other path.

enum LiveEnv {
    static var host: String? { ProcessInfo.processInfo.environment["SL_LIVE_HOST"]?.nilIfEmpty }
    static var enabled: Bool { host != nil }
    /// The scratch folder's name under the remote home.
    static let scratchName = "serverlife-swift-test"
}

/// Swift Testing condition: the live suite is skipped unless SL_LIVE_HOST is set.
let liveEnabled = ConditionTrait.enabled(if: LiveEnv.enabled, "set SL_LIVE_HOST=<ssh alias> to run the live suite")

typealias LiveHost = ServerLife.Host

@MainActor
enum Live {
    private static var wired = false

    /// What the app's install() steps would wire: files-service lets go of a
    /// connection's channel, queue and watches when it is removed.
    static func wire() {
        guard !wired else { return }
        wired = true
        _ = ConnRuntime.dir
        ConnectionManager.shared.willRemove.append { id in FilesService.shared.connectionClosed(id) }
        // Keep the throwaway store out of the download history path.
        FilesService.shared.onJobFinished = { _ in }
    }

    static func hostDescriptor() -> LiveHost {
        let alias = LiveEnv.host!
        var h = LiveHost(type: LiveHost.ssh, id: "ssh:" + alias, name: alias)
        h.alias = alias
        return h
    }

    /// Create and dial a connection (Host type ssh, alias from SL_LIVE_HOST).
    static func connect(reuse: Bool = false) async throws -> Connection {
        wire()
        let m = ConnectionManager.shared
        let c = try await m.create(host: hostDescriptor(), options: ConnectOptions(reuse: reuse, timeout: 40))
        try await m.connect(c.id)
        return c
    }

    /// The remote scratch root (absolute), created if missing.
    static func scratchRoot(_ c: Connection) async throws -> String {
        var home = c.homeDir ?? ""
        if home.isEmpty { home = (try await c.exec("echo \"$HOME\"")).trimmed }
        let root = home + "/" + LiveEnv.scratchName
        _ = try await c.exec("mkdir -p \(shellQuote(root))")
        return root
    }

    /// A fresh per-test folder inside the scratch root.
    static func scratch(_ c: Connection, _ tag: String) async throws -> String {
        let root = try await scratchRoot(c)
        let dir = root + "/" + tag + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        _ = try await c.exec("mkdir -p \(shellQuote(dir))")
        return dir
    }

    /// Refuse anything outside the scratch folder (a guard for the test itself).
    static func guardScratch(_ path: String) -> String {
        precondition(path.contains("/" + LiveEnv.scratchName), "live test tried to touch \(path) outside the scratch folder")
        return path
    }

    /// Disconnect and check nothing is left: no process holding the control
    /// path, no socket file, connection gone from the manager.
    static func teardown(_ c: Connection) async {
        let path = c.controlPath
        await ConnectionManager.shared.disconnectAndWait(c.id)
        // A master given `-O exit` takes a moment to go.
        var left: [String] = []
        for _ in 0..<20 {
            left = await processesMentioning(path)
            if left.isEmpty { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(left.isEmpty, "ssh processes still holding \(path): \(left)")
        #expect(!FileManager.default.fileExists(atPath: path), "control socket left at \(path)")
        #expect(ConnectionManager.shared.connection(c.id) == nil)
        #expect(c.state == .closed)
    }

    static func processesMentioning(_ s: String) async -> [String] {
        let r = await Proc.run("/bin/ps", ["-axww", "-o", "pid=,command="], timeout: 5)
        return r.out.split(separator: "\n").map(String.init).filter { $0.contains(s) && !$0.contains("/bin/ps") }
    }

    /// Poll (on the main actor) until `cond` holds or `timeout` passes.
    @discardableResult
    static func waitUntil(_ timeout: TimeInterval, every: TimeInterval = 0.1, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
        return cond()
    }

    static func job(_ q: TransferQueue, _ id: String) -> TransferJobView? { q.jobs.first { $0.id == id } }

    /// Wait for a job to reach a final state.
    static func finish(_ q: TransferQueue, _ id: String, timeout: TimeInterval = 120) async -> TransferJobView? {
        await waitUntil(timeout, every: 0.2) { ["done", "error", "cancelled"].contains(job(q, id)?.status ?? "") }
        return job(q, id)
    }

    /// Wait until the queue has nothing queued or running.
    static func idle(_ q: TransferQueue, timeout: TimeInterval = 120) async {
        await waitUntil(timeout, every: 0.2) { !q.isBusy }
    }

    static func remoteSha(_ c: Connection, _ path: String) async throws -> String {
        let out = try await c.exec("sha256sum \(shellQuote(guardScratch(path)))")
        return String(out.split(separator: " ").first ?? "")
    }

    static func remoteMtime(_ c: Connection, _ path: String) async throws -> Int {
        Int(try await c.exec("stat -c %Y \(shellQuote(guardScratch(path)))").trimmed) ?? -1
    }

    /// Whether the host's sshd allows TCP forwarding at all (`ssh -W` over the master).
    static func forwardingAllowed(_ c: Connection) async -> Bool {
        // Asked of the server directly (not through the code under test).
        let r = await Proc.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-W", "127.0.0.1:22", c.target], timeout: 8)
        return r.out.hasPrefix("SSH-2.0")
    }

    static func say(_ s: String) { print("LIVE: " + s) }
}

// MARK: - local helpers

enum LiveLocal {
    static func dir(_ tag: String) throws -> String {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("sl-live-\(tag)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        guard let r = realpath(base, nil) else { return base }
        defer { free(r) }
        return String(cString: r)
    }

    static func write(_ p: String, _ d: Data) throws {
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try d.write(to: URL(fileURLWithPath: p))
    }

    static func write(_ p: String, _ s: String) throws { try write(p, Data(s.utf8)) }

    static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
        return d
    }

    static func sha(_ p: String) -> String {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return "" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    static func setMtime(_ p: String, _ secs: Int) {
        var tv = [timeval(tv_sec: secs, tv_usec: 0), timeval(tv_sec: secs, tv_usec: 0)]
        _ = utimes(p, &tv)
    }

    static func mtime(_ p: String) -> Int {
        guard let a = try? FileManager.default.attributesOfItem(atPath: p),
              let d = a[.modificationDate] as? Date else { return -1 }
        return Int(d.timeIntervalSince1970)
    }

    static func remove(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
}

// MARK: - sockets (blocking, run off the main actor)

enum LiveSocket {
    /// Connect to 127.0.0.1:port; nil on failure.
    static func connect(_ port: Int, timeout: Int = 5) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 { Darwin.close(fd); return nil }
        return fd
    }

    static func read(_ fd: Int32, max: Int = 256) -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        let n = Darwin.read(fd, &buf, max)
        return n > 0 ? Data(buf[0..<n]) : Data()
    }

    static func readExactly(_ fd: Int32, _ n: Int) -> Data {
        var out = Data()
        while out.count < n {
            let d = read(fd, max: n - out.count)
            if d.isEmpty { break }
            out.append(d)
        }
        return out
    }

    static func send(_ fd: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// Read whatever a server says first (an SSH banner) on 127.0.0.1:port.
    static func banner(_ port: Int) async -> String? {
        await Task.detached {
            guard let fd = connect(port) else { return nil as String? }
            defer { Darwin.close(fd) }
            let d = read(fd)
            return d.isEmpty ? nil : String(decoding: d, as: UTF8.self)
        }.value
    }

    /// SOCKS5 (no auth) CONNECT to ip:port through 127.0.0.1:socksPort, then
    /// read the first thing the far end says.
    static func socksBanner(_ socksPort: Int, ip: (UInt8, UInt8, UInt8, UInt8), port: Int) async -> String? {
        await Task.detached {
            guard let fd = connect(socksPort) else { return nil as String? }
            defer { Darwin.close(fd) }
            send(fd, [5, 1, 0])
            let hello = readExactly(fd, 2)
            guard hello == Data([5, 0]) else { return "bad greeting \(Array(hello))" }
            send(fd, [5, 1, 0, 1, ip.0, ip.1, ip.2, ip.3, UInt8(port >> 8), UInt8(port & 0xff)])
            let rep = readExactly(fd, 10)
            guard rep.count == 10, rep[1] == 0 else { return "socks refused \(Array(rep))" }
            let d = read(fd)
            return d.isEmpty ? nil : String(decoding: d, as: UTF8.self)
        }.value
    }
}
