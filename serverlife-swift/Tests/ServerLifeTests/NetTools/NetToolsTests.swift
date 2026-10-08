import Testing
import Foundation
@testable import ServerLife

// tests/nettools.test.mjs, plus the pure parts of nettools.js and sshkeys.js.

/// A server on a free local port that runs `onConn` with each accepted socket.
private final class TestServer: @unchecked Sendable {
    let fd: Int32
    let port: Int
    private let stopFlag = Flag()
    private let closed = DispatchSemaphore(value: 0)

    init(_ onConn: @escaping @Sendable (Int32) -> Void) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        listen(fd, 8)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: addr.sin_port))
        let lfd = fd
        let flag = stopFlag, done = closed
        // The accept loop owns the listening socket and closes it itself: an
        // fd closed under a blocked accept() can be reused by the next test's
        // socket, and the old loop would then steal its connections.
        Thread {
            while true {
                var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
                let r = poll(&pfd, 1, 50)
                if flag.isSet { Darwin.close(lfd); done.signal(); return }
                if r <= 0 { continue }
                let c = accept(lfd, nil, nil)
                if c < 0 { continue }
                Thread { onConn(c) }.start()
            }
        }.start()
    }

    func close() {
        guard !stopFlag.isSet else { return }
        stopFlag.set()
        closed.wait()
    }
}

/// Nothing listens on 127.0.0.1:1 (and no test can bind below 1024), so it
/// refuses — without freeing a port a parallel test might then be given.
private let refusingPort = 1

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

private func send(_ fd: Int32, _ bytes: [UInt8]) { bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) } }
private func send(_ fd: Int32, _ s: String) { send(fd, Array(s.utf8)) }

// MARK: - The telnet probe

@Test func telnetBannerIsReportedAndRecognised() async throws {
    let s = TestServer { c in send(c, "SSH-2.0-OpenSSH_9.6\r\n"); close(c) }
    defer { s.close() }
    let r = try await NetLocal.telnetProbe(host: "127.0.0.1", port: String(s.port), wait: "1500")
    #expect(r.state == "open")
    #expect(r.text == "SSH-2.0-OpenSSH_9.6")
    #expect(r.guess == "an SSH server")
    #expect(r.telnet == false)
    #expect(r.command == "telnet 127.0.0.1 \(s.port)")
}

@Test func telnetNegotiationIsAnsweredSoTheDeviceShowsItsPrompt() async throws {
    let s = TestServer { c in
        // Like a switch: ask first, and only greet once something has answered.
        send(c, [255, 253, 24, 255, 251, 1])
        var buf = [UInt8](repeating: 0, count: 64)
        _ = read(c, &buf, 64)
        send(c, "\u{1b}[1mUser Access Verification\u{1b}[0m\r\n\r\nUsername: ")
        sleep(3)
        close(c)
    }
    defer { s.close() }
    let r = try await NetLocal.telnetProbe(host: "127.0.0.1", port: String(s.port), wait: "2000")
    #expect(r.state == "open")
    #expect(r.telnet == true)
    #expect(r.guess == "a telnet server")
    #expect(r.text == "User Access Verification\n\nUsername:")
}

@Test func telnetSilentPortIsOpenNotBroken() async throws {
    let s = TestServer { c in sleep(2); close(c) }
    defer { s.close() }
    let r = try await NetLocal.telnetProbe(host: "127.0.0.1", port: String(s.port), wait: "500")
    #expect(r.state == "open")
    #expect(r.text == "")
    #expect(r.guess == nil)
}

@Test func telnetNothingListeningIsARefusal() async throws {
    let r = try await NetLocal.telnetProbe(host: "127.0.0.1", port: String(refusingPort), wait: "500")
    #expect(r.state == "closed")
    #expect(r.error?.contains("Connection refused") == true)
}

@Test func telnetTargetsValidatedAndPortFieldWins() async throws {
    await #expect(throws: AppError.self) { try await NetLocal.telnetProbe(host: "bad host!", port: "23") }
    do { _ = try await NetLocal.telnetProbe(host: "bad host!", port: "23") } catch {
        #expect(error.localizedDescription.hasPrefix("Host names may only"))
    }
    do { _ = try await NetLocal.telnetProbe(host: "example.com", port: "70000"); Issue.record("should throw") } catch {
        #expect(error.localizedDescription.contains("1 to 65535"))
    }
    let s = TestServer { c in send(c, "hi\r\n"); close(c) }
    defer { s.close() }
    let r = try await NetLocal.telnetProbe(host: "127.0.0.1:1", port: String(s.port), wait: "500")
    #expect(r.port == s.port)
}

@Test func bannersCleanedAndObviousServicesNamed() {
    #expect(NetLocal.cleanBanner("\u{1b}[2J\u{1b}[Hhello\r\n\r\n\r\n\r\nworld\u{07}") == "hello\n\nworld")
    #expect(NetLocal.guessService("220 mail.example.com ESMTP Postfix", spokeTelnet: false) == "a mail server (SMTP)")
    #expect(NetLocal.guessService("RFB 003.008", spokeTelnet: false) == "a VNC server")
    #expect(NetLocal.guessService("Password: ", spokeTelnet: false) == "something asking you to log in")
    #expect(NetLocal.guessService("", spokeTelnet: false) == nil)
}

@Test func targetFieldReadAsTelnetWouldReadIt() throws {
    func t(_ v: String, _ p: String) throws -> String { let r = try NetCheck.telnetTarget(v, p); return "\(r.host) \(r.port)" }
    #expect(try t("switch-1", "23") == "switch-1 23")
    #expect(try t("switch-1", "") == "switch-1 23")
    #expect(try t("telnet://console-1:2001", "23") == "console-1 2001")
    #expect(try t("https://proxy.example.com/web", "22") == "proxy.example.com 22")
    #expect(try t("[2001:db8::1]:23", "") == "2001:db8::1 23")
    #expect(try t("admin@10.0.0.5", "23") == "10.0.0.5 23")
    #expect(throws: AppError.self) { try NetCheck.telnetTarget("box; rm -rf /", "23") }
    #expect(throws: AppError.self) { try NetCheck.telnetTarget("", "23") }
    #expect(throws: AppError.self) { try NetCheck.telnetTarget("box", "99999") }
    do { _ = try NetCheck.telnetTarget("", "23") } catch { #expect(error.localizedDescription == "Give a host") }
}

// MARK: - Targets and ports

@Test func hostsAreValidated() throws {
    #expect(try NetCheck.checkHost(" [::1] ") == "::1")
    #expect(try NetCheck.checkHost("web-1.example.com") == "web-1.example.com")
    #expect(throws: AppError.self) { try NetCheck.checkHost("") }
    #expect(throws: AppError.self) { try NetCheck.checkHost("a b") }
    #expect(throws: AppError.self) { try NetCheck.checkHost("$(reboot)") }
    #expect(throws: AppError.self) { try NetCheck.checkHost(String(repeating: "a", count: 254)) }
}

@Test func targetsSplitIntoHostAndPort() {
    #expect(NetCheck.splitHostPort("https://proxy.example.com:443/web").host == "proxy.example.com")
    #expect(NetCheck.splitHostPort("https://proxy.example.com:443/web").port == 443)
    #expect(NetCheck.splitHostPort("[::1]:22").host == "::1")
    #expect(NetCheck.splitHostPort("[::1]:22").port == 22)
    #expect(NetCheck.splitHostPort("2001:db8::1").port == nil)
    #expect(NetCheck.splitHostPort("box").port == nil)
    #expect(NetCheck.splitHostPort("box:abc").port == nil)
}

@Test func portListsAreBounded() throws {
    #expect(try NetCheck.parsePorts("") == NetCheck.defaultPorts)
    #expect(try NetCheck.parsePorts("22, 443,3022-3025,22") == [22, 443, 3022, 3023, 3024, 3025])
    do { _ = try NetCheck.parsePorts("10-5") } catch { #expect(error.localizedDescription == "\"10-5\" runs backwards.") }
    do { _ = try NetCheck.parsePorts("1-40") } catch { #expect(error.localizedDescription == "Ranges are limited to 32 ports.") }
    do { _ = try NetCheck.parsePorts("abc") } catch { #expect(error.localizedDescription == "\"abc\" is not a port number.") }
    do { _ = try NetCheck.parsePorts("0") } catch { #expect(error.localizedDescription == "Ports run from 1 to 65535.") }
    do { _ = try NetCheck.parsePorts(",") } catch { #expect(error.localizedDescription == "Give at least one port.") }
    let many = (1...33).map(String.init).joined(separator: ",")
    do { _ = try NetCheck.parsePorts(many) } catch { #expect(error.localizedDescription == "At most 32 ports at a time.") }
}

@Test func localPortCheckSaysOpenAndRefused() async throws {
    let s = TestServer { c in close(c) }
    defer { s.close() }
    let shut = refusingPort
    let r = try await NetLocal.portCheck(host: "127.0.0.1", ports: "\(s.port),\(shut)")
    #expect(r.results.first { $0.port == s.port }?.state == "open")
    #expect(r.results.first { $0.port == shut }?.state == "closed")
    // A target written host:port names the port when the list is blank.
    let one = try await NetLocal.portCheck(host: "127.0.0.1:\(s.port)", ports: "")
    #expect(one.results.map(\.port) == [s.port])
}

// MARK: - curl

@Test func curlArgvIsBuiltOnceAndQuotedForDisplay() throws {
    var o = CurlOptions()
    o.method = "post"
    o.url = "api.example.com/v1/things"
    o.headers = "Accept: application/json\r\nnot a header\n X-Id: $(whoami) "
    o.body = "{\n \"a\": 1\n}"
    o.bearer = " tok "
    o.timeout = 999
    let (args, method) = try NetCurl.args(o)
    #expect(method == "POST")
    #expect(args == ["-sS", "-q", "-i", "--max-time", "300", "-X", "POST", "-L", "--max-redirs", "5",
                     "-H", "Accept: application/json", "-H", "X-Id: $(whoami)", "-H", "Authorization: Bearer tok",
                     "--data-binary", "{\n \"a\": 1\n}", "-H", "Content-Type: application/json",
                     "--", "https://api.example.com/v1/things"])
    let cmd = NetCurl.command(args)
    #expect(cmd.hasPrefix("curl -sS -q -i --max-time 300 -X POST -L --max-redirs 5 -H 'Accept: application/json' -H 'X-Id: $(whoami)'"))
    #expect(cmd.hasSuffix("-- https://api.example.com/v1/things"))
}

@Test func curlBodyIsNotSentWithGetAndContentTypeIsNotDoubled() throws {
    var o = CurlOptions()
    o.url = "https://example.com"
    o.body = "x=1"
    o.followRedirects = false
    #expect(try !NetCurl.args(o).args.contains("--data-binary"))
    #expect(try NetCurl.args(o).args.last == "https://example.com/")
    o.method = "PUT"
    o.headers = "content-type: text/plain"
    let a = try NetCurl.args(o).args
    #expect(a.filter { $0.lowercased().hasPrefix("content-type") }.count == 1)
    o.bearer = ""; o.basicUser = "u"; o.basicPass = "p"
    #expect(try NetCurl.args(o).args.contains("u:p"))
    o.proxy = "127.0.0.1:1080"
    #expect(try NetCurl.args(o).args.contains("--socks5-hostname"))
}

@Test func curlUrlsAreChecked() {
    do { _ = try NetCurl.checkUrl("") } catch { #expect(error.localizedDescription == "Give a URL.") }
    do { _ = try NetCurl.checkUrl("ftp://example.com/x") } catch {
        #expect(error.localizedDescription == "Only http and https URLs are fetched here.")
    }
    #expect((try? NetCurl.checkUrl("HTTPS://Example.COM:443")) == "https://example.com/")
}

@Test func curlOutputSplitsIntoHopsHeadersAndBody() {
    let text = "HTTP/1.1 301 Moved Permanently\r\nLocation: https://x/\r\nSet-Cookie: a=1\r\n\r\n"
        + "HTTP/2 200 \r\ncontent-type: application/json\r\nset-cookie: b=2\r\nset-cookie: c=3\r\n\r\n{\"ok\":true}"
    let r = NetCurl.parse(text)
    #expect(r.status == 200)
    #expect(r.httpVersion == "2")
    #expect(r.hops.count == 2)
    #expect(r.hops[0].header("Location") == "https://x/")
    #expect(r.headers.first { $0.0 == "set-cookie" }?.1 == "b=2, c=3")
    #expect(r.contentType == "application/json")
    #expect(r.body == "{\"ok\":true}")
    #expect(r.bytes == 11)
    #expect(r.ok)
    #expect(NetCurl.displayBody(r.body, contentType: r.contentType).contains("\n"))
}

// MARK: - Hosts, hints and words

@Test func installHintsNameThePackageManager() {
    #expect(NetInstall.hint("dig", "apt") == "sudo apt install dnsutils")
    #expect(NetInstall.hint("dig", "brew") == "brew install bind")
    #expect(NetInstall.hint("mtr", "pacman") == "sudo pacman -S mtr")
    #expect(NetInstall.hint("tracepath", "apk") == "")
    #expect(NetInstall.hint("dig", "") == "")
    // A tool with a working stand-in on the box is not missing anything.
    let hints = NetRemote.hints(tools: ["tracepath", "host", "curl", "ping"], devtcp: true, pkg: "apt").map(\.tool)
    #expect(!hints.contains("traceroute"))
    #expect(!hints.contains("dig"))
    #expect(!hints.contains("nc"))
    #expect(hints.contains("mtr"))
}

@Test func toolsGreyWithTheReason() {
    var caps = HostCaps()
    caps.tools = ["tracepath"]
    #expect(NetTool.missing(NetTool.find("ping"), caps) == "ping")
    #expect(NetTool.missing(NetTool.find("traceroute"), caps) == nil)
    #expect(NetTool.missing(NetTool.find("ping"), nil) == nil)
    #expect(!NetTool.canRunRemotely("dns"))
    #expect(NetTool.canRunRemotely("local"))
}

@Test func namesAndNotes() {
    #expect(NetText.safeName("https://proxy.example.com:443/web?x=1") == "proxy.example.com_443_web_x_1")
    #expect(NetText.safeName("") == "output")
    #expect(NetText.shortUrl("example.com/v1/") == "example.com/v1")
    #expect(NetText.bodyExt("application/json; charset=utf-8") == ".json")
    #expect(NetText.pingNote(text: "5 packets transmitted, 5 received, 0.0% packet loss\nround-trip min/avg/max/stddev = 6.8/7.3/8.1/0.4 ms", missing: nil)
            == "0.0% loss · 7.3ms avg")
    #expect(PortStateInfo.of(state: "closed").label == "refused")
    #expect(PortStateInfo.of(state: nil, open: true).label == "open")
    #expect(PortStateInfo.of(state: "filtered").label == "no answer")
}

@Test func dnsRecordsDecode() {
    #expect(DNSQuery.decode(Data([1, 2, 3, 4]), type: 1)?.string == "1.2.3.4")
    let mx = DNSQuery.decode(Data([0, 10, 4] + Array("mail".utf8) + [3] + Array("com".utf8) + [0]), type: 15)
    #expect(mx?["exchange"].string == "mail.com")
    #expect(mx?["priority"].int == 10)
    let txt = DNSQuery.decode(Data([2] + Array("ab".utf8) + [1] + Array("c".utf8)), type: 16)
    #expect(DNSResult.format(txt!) == "abc")
    #expect(DNSQuery.reverseName("8.8.4.4") == "4.4.8.8.in-addr.arpa")
    #expect(DNSQuery.reverseName("::1").hasPrefix("1.0.0.0"))
}

// MARK: - SSH keys (temporary directory only)

@Test func keysParsersAndIdentities() {
    let k = SSHKeys.parseFingerprintLine("256 SHA256:abc teleport:proxy.example.com:443:c1:alice (ED25519-CERT)")
    #expect(k.bits == 256)
    #expect(k.type == "ED25519-CERT")
    let tp = SSHKeys.teleportIdentity(k.comment)
    #expect(tp?.proxy == "proxy.example.com:443")
    #expect(tp?.cluster == "c1")
    #expect(tp?.user == "alice")
    #expect(SSHKeys.teleportIdentity("alice@laptop") == nil)
    let agent = [AgentKey(bits: 256, fingerprint: "A", comment: "x", type: "ED25519-CERT"),
                 AgentKey(bits: 256, fingerprint: "A", comment: "x", type: "ED25519"),
                 AgentKey(bits: 256, fingerprint: "B", comment: "y", type: "ED25519")]
    let local = [SSHKey(name: "id", publicPath: "/x/id.pub", privatePath: "/x/id", hasPrivate: true, privMode: 0o600,
                        encrypted: false, mtime: nil, permissionsOk: true, publicKey: "", fingerprint: "B")]
    let (groups, extra) = SSHKeys.agentOnly(agent, local: local)
    #expect(groups.count == 1)
    #expect(extra == 2)
    #expect(groups[0].entries == 2)
    #expect(groups[0].types == ["ED25519-CERT", "ED25519"])
    #expect(SSHKeys.sameKeyPath("~/.ssh/id", local[0]))
    #expect(!SSHKeys.sameKeyPath("~/.ssh/id_rsa", local[0]))
}

@Test func installScriptRefusesWhatIsNotAKeyAndQuotesWhatIs() throws {
    #expect(throws: AppError.self) { try SSHKeys.installScript("rm -rf /") }
    let s = try SSHKeys.installScript("ssh-ed25519 AAAAC3Nza it's me")
    #expect(s.contains("grep -qF 'ssh-ed25519 AAAAC3Nza it'\\''s me'"))
    #expect(SSHKeys.installResult("x\nalready-present\n").alreadyPresent)
    #expect(SSHKeys.installResult("installed").installed)
}

// MARK: - Numbers that used to trap

@Test func absurdNumbersAreRefusedNotTrapped() throws {
    #expect(ntNumber("nan") == nil)
    #expect(ntNumber("inf") == nil)
    #expect(ntParseInt("25abc") == 25)
    #expect(ntParseInt("nan") == nil)
    #expect(ntParseInt("99999999999999999999999") != nil)
    #expect(NetCheck.splitHostPort("host:99999999999999999999").port == 65536)
    do { _ = try NetCheck.parsePorts("99999999999999999999"); Issue.record("should throw") } catch {
        #expect(error.localizedDescription == "Ports run from 1 to 65535.")
    }
    do { _ = try NetCheck.parsePorts("5-99999999999999999999"); Issue.record("should throw") } catch {
        #expect(error.localizedDescription == "Ranges are limited to 32 ports.")
    }
    #expect(ntInt(JSON.number(1e20)) == nil)
    var o = CurlOptions(json: ["timeout": .number(1e300)])
    #expect(o.timeout == 1_000_000)
    #expect(CurlOptions(json: ["timeout": .number(-5)]).timeout == -5)
    o.url = "https://example.com"
    #expect(try NetCurl.args(o).args.contains("300"))
}

@Test func hugePortInTargetIsAnErrorNotACrash() async {
    do { _ = try await NetLocal.portCheck(host: "127.0.0.1:99999999999999999999", ports: ""); Issue.record("should throw") } catch {
        #expect(error.localizedDescription == "Ports run from 1 to 65535.")
    }
}

@Test func bigBodiesAreDrawnBounded() {
    let big = String(repeating: "x", count: NetCurl.drawLimit + 10)
    let (shown, cut) = NetCurl.displayText(big, contentType: "text/plain")
    #expect(cut)
    #expect(shown.utf16.count == NetCurl.drawLimit)
    #expect(NetCurl.displayText("{\"a\":1}", contentType: "application/json").0.contains("\n"))
}

/// Both change `SSHKeys.sshDir`, so they must not run at the same time.
@Suite(.serialized) struct SSHKeysOnDisk {
    @Test func keysListGenerateAndKnownHostsInATemporaryDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-keys-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let saved = SSHKeys.sshDir
        SSHKeys.sshDir = dir
        defer { SSHKeys.sshDir = saved }

        let plain = try await SSHKeys.generate(name: "id_plain", comment: "test@plain")
        #expect(plain.type == "ED25519")
        _ = try await SSHKeys.generate(name: "id_locked", type: "ecdsa", comment: "test@locked", passphrase: "correct horse")
        await #expect(throws: AppError.self) { try await SSHKeys.generate(name: "id_plain") }
        await #expect(throws: AppError.self) { try await SSHKeys.generate(name: "../escape") }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir + "/id_locked")

        let keys = await SSHKeys.listKeys()
        #expect(keys.map(\.name) == ["id_locked", "id_plain"])
        let locked = keys[0], open = keys[1]
        #expect(locked.encrypted == true)
        #expect(open.encrypted == false)
        #expect(locked.permissionsOk == false)
        #expect(locked.privMode == 0o644)
        #expect(open.permissionsOk)
        #expect(open.comment == "test@plain")
        #expect(open.fingerprint?.hasPrefix("SHA256:") == true)
        #expect(await SSHKeys.isEncrypted(dir + "/id_locked"))
        #expect(!(await SSHKeys.isEncrypted(dir + "/id_plain")))

        let kh = "web-1.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"
            + "other.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"
        try kh.write(toFile: dir + "/known_hosts", atomically: true, encoding: .utf8)
        let entries = await SSHKeys.knownHostEntries("web-1.example.com")
        #expect(entries.count == 1)
        #expect(entries.first?.type == "ssh-ed25519")
        #expect(entries.first?.key.hasSuffix("…") == true)
        #expect(try await SSHKeys.forgetHost("web-1.example.com") == 1)
        #expect(await SSHKeys.knownHostEntries("web-1.example.com").isEmpty)
        #expect(await SSHKeys.knownHostEntries("other.example.com").count == 1)
        #expect(try await SSHKeys.forgetHost("nobody.example.com") == 0)
    }

    @Test func symlinkedPrivateKeysAreFollowed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-keys-\(UUID().uuidString)").path
        let real = dir + "-real"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: real) }
        let saved = SSHKeys.sshDir
        SSHKeys.sshDir = real
        _ = try await SSHKeys.generate(name: "id_linked", comment: "t@linked")
        SSHKeys.sshDir = dir
        defer { SSHKeys.sshDir = saved }
        try FileManager.default.createSymbolicLink(atPath: dir + "/id_linked", withDestinationPath: real + "/id_linked")
        try FileManager.default.createSymbolicLink(atPath: dir + "/id_linked.pub", withDestinationPath: real + "/id_linked.pub")
        let k = try #require(await SSHKeys.listKeys().first)
        #expect(k.hasPrivate)
        #expect(k.privMode == 0o600)
        #expect(k.permissionsOk)
        #expect(k.encrypted == false)
    }
}
