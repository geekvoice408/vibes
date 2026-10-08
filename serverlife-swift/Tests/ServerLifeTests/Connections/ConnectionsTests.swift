import Testing
import Foundation
@testable import ServerLife

private typealias SLHost = ServerLife.Host

// MARK: - argument building

private func teleportNode(ambiguous: Bool = false) -> SLHost {
    var h = SLHost(type: "teleport", id: "tsh:c1:web-1", name: "web-1")
    h.hostname = "web-1"
    h.uuid = "0123456789abcdef"
    h.cluster = "c1"
    h.proxy = "proxy.example.com:443"
    h.ambiguous = ambiguous
    return h
}

@Test func aliasSshArgs() {
    var s = ConnSpec(type: "ssh", target: "ubuntu@ent")
    s.configFile = "/x/extra.conf"
    s.proxyJump = "bastion"
    let a = s.sshArgs(controlPath: "/tmp/c-1", ["-T", "ubuntu@ent", "true"])
    #expect(a == ["-F", "/x/extra.conf", "-o", "IdentitiesOnly=yes", "-o", "ControlPath=/tmp/c-1",
                  "-J", "bastion", "-T", "ubuntu@ent", "true"])
}

@Test func plainAliasHasNoConfigFile() {
    let s = ConnSpec(type: "ssh", target: "ent")
    #expect(s.sshArgs(controlPath: "/c") == ["-o", "ControlPath=/c"])
}

@Test func directArgsCarryEverything() {
    var s = ConnSpec(type: "ssh", target: "root@10.0.0.5")
    s.direct = DirectSpec(hostname: "10.0.0.5", user: "root", port: 2222, identityFile: "~/.ssh/k",
                          proxyJump: "jump", options: ["-o ServerAliveInterval 10\nCompression yes", ""])
    s.proxyJump = "ignored-for-direct"
    let a = s.sshArgs(controlPath: "/c")
    #expect(a == ["-o", "ControlPath=/c", "-p", "2222", "-i", "~/.ssh/k", "-o", "IdentitiesOnly=yes",
                  "-J", "jump", "-o", "ServerAliveInterval 10", "-o", "Compression yes",
                  "-o", "StrictHostKeyChecking=accept-new"])
    var p22 = s
    p22.direct?.port = 22
    #expect(!p22.directArgs().contains("-p"))
}

@Test func masterArgsWithFeatures() {
    var s = ConnSpec(type: "teleport", target: "ubuntu@web-1.c1")
    s.configFile = "/r/tsh-c1.conf"
    s.x11 = "trusted"
    s.agentForward = true
    s.compression = true
    let a = s.masterArgs(controlPath: "/c")
    #expect(a == ["-F", "/r/tsh-c1.conf", "-o", "IdentitiesOnly=yes", "-o", "ControlPath=/c"]
                 + ConnSpec.baseOpts
                 + ["-Y", "-o", "ForwardX11Timeout=596h", "-A", "-C", "-N", "ubuntu@web-1.c1"])
    s.x11 = "untrusted"
    s.x11Timeout = "1h"
    #expect(s.x11Args() == ["-X", "-o", "ForwardX11Timeout=1h"])
    s.x11 = "off"
    #expect(s.x11Args().isEmpty)
}

@Test func terminalAndCommandPtyArgs() {
    var s = ConnSpec(type: "ssh", target: "ent")
    s.x11 = "untrusted"
    s.agentForward = true
    #expect(s.terminalSshArgs(controlPath: "/c", command: nil)
            == ["-o", "ControlPath=/c", "-X", "-o", "ForwardX11Timeout=596h", "-A", "-tt", "ent"])
    #expect(s.terminalSshArgs(controlPath: "/c", command: "top").last == "top")
    // tmux's pty gets no X11.
    #expect(s.commandPtySshArgs(controlPath: "/c", command: "tmux -CC")
            == ["-o", "ControlPath=/c", "-A", "-tt", "ent", "tmux -CC"])
}

@Test func tshArgsAndTarget() {
    var s = ConnSpec(type: "teleport", target: "ubuntu@web-1.c1")
    s.node = teleportNode()
    s.login = "ubuntu"
    s.mfaMode = "browser"
    s.agentForward = true
    s.x11 = "trusted"
    s.transport = .tsh
    #expect(s.tshArgs([], command: "uptime")
            == ["--proxy=proxy.example.com:443", "--mfa-mode=browser", "ssh", "--cluster=c1", "-A", "-X",
                "ubuntu@web-1", "uptime"])
    #expect(s.tshArgs(["-L", "8080:localhost:80", "-N"]).suffix(4) == ["-L", "8080:localhost:80", "-N", "ubuntu@web-1"])
    // An ambiguous hostname is dialled by UUID.
    s.node = teleportNode(ambiguous: true)
    #expect(s.tshTarget() == "ubuntu@0123456789abcdef")
    // No node: the target's host part, without the login or the cluster.
    var bare = ConnSpec(type: "teleport", target: "root@db-2.c9")
    bare.transport = .tsh
    #expect(bare.tshTarget() == "db-2")
}

@Test func tshScpArgs() {
    var s = ConnSpec(type: "teleport", target: "x")
    s.node = teleportNode()
    s.login = "root"
    #expect(s.tshScpArgs(upload: true, localPaths: ["/a", "/b"], remotePaths: ["/srv"], recursive: true)
            == ["--proxy=proxy.example.com:443", "scp", "--cluster=c1", "-r", "/a", "/b", "root@web-1:/srv"])
    #expect(s.tshScpArgs(upload: false, localPaths: ["/dl"], remotePaths: ["/x", "/y"], recursive: false)
            == ["--proxy=proxy.example.com:443", "scp", "--cluster=c1", "root@web-1:/x", "root@web-1:/y", "/dl"])
}

@Test func beamArgs() {
    var s = ConnSpec(type: "beam", target: "my-beam")
    s.beamName = "my-beam"
    s.beamProxy = "p.example.com"
    s.transport = .beam
    #expect(s.beamArgs() == ["--proxy=p.example.com", "beams", "ssh", "my-beam"])
    #expect(s.beamArgs(command: "ls") == ["--proxy=p.example.com", "beams", "exec", "my-beam", "--", "ls"])
    let inv = s.sftpInvocation(controlPath: "/c")
    #expect(inv.exe == Tools.tsh)
    #expect(inv.args.last == ConnText.sftpServerChain)
}

@Test func invocationsByTransport() {
    var s = ConnSpec(type: "ssh", target: "ent")
    let mux = s.execInvocation(controlPath: "/c", command: "id")
    #expect(mux.exe == Tools.ssh)
    #expect(mux.args == ["-o", "ControlPath=/c", "-T", "ent", "id"])
    #expect(s.sftpInvocation(controlPath: "/c").args == ["-o", "ControlPath=/c", "ent", "-s", "sftp"])
    s.transport = .tsh
    s.node = teleportNode()
    let tsh = s.execInvocation(controlPath: "/c", command: "id")
    #expect(tsh.exe == Tools.tsh)
    #expect(tsh.args.last == "id")
    #expect(s.terminalInvocation(controlPath: "/c", command: nil).args.last == "web-1")
}

@Test func tshByNecessity() {
    var s = ConnSpec(type: "teleport", target: "x")
    s.transport = .tsh
    #expect(!s.tshByNecessity)
    s.transportForced = "leaf"
    #expect(s.tshByNecessity)
}

@Test func forwardSpecs() {
    #expect(ForwardSpec(kind: "L", bindPort: 8080, destHost: "localhost", destPort: 80).specString == "8080:localhost:80")
    #expect(ForwardSpec(kind: "R", bindAddr: "0.0.0.0", bindPort: 9000, destHost: "db", destPort: 5432).specString
            == "0.0.0.0:9000:db:5432")
    #expect(ForwardSpec(kind: "D", bindAddr: "127.0.0.1", bindPort: 1080).specString == "127.0.0.1:1080")
}

@Test func controlPathIsShort() {
    let p = ConnRuntime.controlPath(for: "conn1|ubuntu@web-1.c1|/x/y.conf")
    #expect((p as NSString).lastPathComponent.count == 14)
    #expect((p as NSString).lastPathComponent.hasPrefix("c-"))
    #expect(p.utf8.count < 104)
    #expect(p == ConnRuntime.controlPath(for: "conn1|ubuntu@web-1.c1|/x/y.conf"))
}

@Test func historyEntryShape() {
    var s = ConnSpec(type: "teleport", target: "u@web-1.c1", label: "web-1 (c1)")
    s.node = teleportNode()
    s.login = "u"
    let j = s.historyEntry(user: "u", hostname: "web-1")
    #expect(j["node"].string == "web-1")
    #expect(j["cluster"].string == "c1")
    #expect(j["login"].string == "u")
    #expect(j["direct"].isNull)
}

// MARK: - text

@Test func promptDetection() {
    #expect(ConnText.isPrompt("ubuntu@host's password: "))
    #expect(ConnText.isPrompt("Enter passphrase for key '/Users/x/.ssh/id_ed25519': "))
    #expect(ConnText.isPrompt("Tap any security key"))
    #expect(ConnText.isPrompt("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
    #expect(ConnText.isPrompt("Enter your OTP token:"))
    #expect(!ConnText.isPrompt("Last login: Mon Oct  6 from 10.0.0.1"))
}

@Test func mfaFailureSignatures() {
    #expect(ConnText.looksLikeMfa("Received disconnect: Too many authentication failures"))
    #expect(ConnText.looksLikeMfa("ubuntu@web-1.c1: Permission denied (publickey)."))
    #expect(ConnText.looksLikeMfa("ERROR: per-session MFA is required"))
    #expect(!ConnText.looksLikeMfa("ERROR: access denied to steven connecting to web-1 — Permission denied (publickey)"))
    #expect(!ConnText.looksLikeMfa("ssh: Could not resolve hostname x: nodename nor servname provided"))
}

@Test func cleanupErrors() {
    let text = "debug1: something\r\nWarning: Permanently added\nubuntu@x: Permission denied (publickey).\n\u{1b}[31mERROR: boom\u{1b}[0m\n"
    #expect(ConnText.cleanupError(text) == "ubuntu@x: Permission denied (publickey). — ERROR: boom")
    #expect(ConnText.cleanupError("") == nil)
    #expect(ConnText.cleanupError("just one line") == "just one line")
}

@Test func firstProblemLine() {
    #expect(ConnText.firstProblem("a\nchannel 0: open failed: connect failed: Connection refused\nb") == "channel 0: open failed: connect failed: Connection refused")
    #expect(ConnText.firstProblem("a\nlast\n") == "last")
}

@Test func ansiStripping() {
    let s = "\u{1b}]0;title\u{07}\u{1b}[1;32mgreen\u{1b}[0m\u{1b}(B\u{1b}=line\r\nnext\rover"
    #expect(ConnText.stripAnsi(s) == "greenline\r\nnext\nover")
}

@Test func historyParsing() {
    let text = [
        "@@SLHIST@@/home/u/.bash_history",
        "#1700000000",
        "ls -la",
        "",
        "cd /tmp",
        "@@SLHIST@@/home/u/.zsh_history",
        ": 1700000100:0;git status",
        ": 1700000200:0;echo one \\",
        "two",
        ": 1700000300:0;",
        "@@SLHIST@@/home/u/.local/share/fish/fish_history",
        "- cmd: make test",
        "  when: 1700000400",
        "  paths:",
        "    - foo",
    ].joined(separator: "\n")
    let e = ConnText.parseHistory(text)
    #expect(e.map { $0.command } == ["ls -la", "cd /tmp", "git status", "echo one \ntwo", "make test"])
    #expect(e[0].shell == "bash")
    #expect(e[2].shell == "zsh")
    #expect(e[2].at == Double(1_700_000_100_000))
    #expect(e[4].shell == "fish")
    let d = ConnText.dedupeNewestFirst([
        ShellHistoryEntry(command: "a", shell: "bash", at: nil),
        ShellHistoryEntry(command: "b", shell: "bash", at: nil),
        ShellHistoryEntry(command: "a", shell: "bash", at: nil),
    ], limit: 10)
    #expect(d.map { $0.command } == ["a", "b"])
}

@Test func serverInfoParsing() {
    let raw = "kernel_sys=Linux\nkernel=6.1\nos_name=Ubuntu\nos_version=22.04\nvirt=\nmem_total_kb=2048\n=bad\nhas_docker=yes\n"
    let v = ConnText.parseKeyValues(raw)
    #expect(v["virt"] == nil)
    #expect(v["has_docker"] == "yes")
    let info = ConnText.serverInfo(from: v, partial: nil, at: 1)
    #expect(info.osLabel == "Ubuntu 22.04")
    #expect(info.memTotal == Double(2048 * 1024))
    #expect(ConnText.serverInfo(from: ["kernel_sys": "Darwin"], partial: "x").osLabel == "Darwin")
    #expect(ConnText.serverInfo(from: [:], partial: nil).osLabel == "Unknown")
}

// MARK: - auth probe

@Test func authProbeArgs() {
    let a = AuthProbe.args(target: "u@h", AuthProbe.Options(port: 2200, identityFile: "/k", proxyJump: "j",
                                                            extraOptions: "-o Foo bar\n\nBaz 1"))
    #expect(a == ["-vv", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-p", "2200",
                  "-i", "/k", "-o", "IdentitiesOnly=yes", "-J", "j", "-o", "Foo bar", "-o", "Baz 1", "u@h", "true"])
    let b = AuthProbe.args(target: "h", AuthProbe.Options(identityFile: "/k", identitiesOnly: false))
    #expect(!b.contains("IdentitiesOnly=yes"))
}

@Test func authProbeSummary() {
    var lines = ["OpenSSH_9.6, LibreSSL 3.3.6",
                 "debug1: Authentications that can continue: publickey,password",
                 "debug1: Next authentication method: publickey",
                 "debug1: Will attempt key: /Users/x/.ssh/id_ed25519 ED25519 SHA256:abc",
                 "debug1: Trying private key: /Users/x/.ssh/id_dsa",
                 "Warning: Identity file /nope not accessible: No such file or directory."]
    for i in 1...7 { lines.append("debug1: Offering public key: key\(i) RSA SHA256:x agent") }
    lines += ["Received disconnect from 1.2.3.4 port 22:2: Too many authentication failures",
              "Disconnected from 1.2.3.4 port 22"]
    let s = AuthProbe.summarise(lines.joined(separator: "\n"))
    #expect(s.offered.count == 7)
    #expect(s.offered[0] == "key1 RSA SHA256:x agent")
    #expect(s.considered.count == 2)
    #expect(s.methods == "publickey,password")
    #expect(s.methodsTried == ["publickey"])
    #expect(s.tooMany)
    #expect(!s.denied)
    #expect(s.pastLimit)
    #expect(s.missingIdentity == "/nope")
    #expect(s.accepted == nil)
    #expect(s.finalError.hasSuffix("Disconnected from 1.2.3.4 port 22"))
    #expect(!s.finalError.contains("debug1"))
}

// MARK: - teleport ssh_config

@Test func teleportTargets() {
    #expect(TeleportSSH.sshTarget(teleportNode(), login: "ubuntu") == "ubuntu@web-1.c1")
    #expect(TeleportSSH.sshTarget(teleportNode(ambiguous: true), login: nil) == "0123456789abcdef.c1")
    var noHostname = teleportNode()
    noHostname.hostname = nil
    #expect(TeleportSSH.sshTarget(noHostname, login: nil) == "0123456789abcdef.c1")
}

@Test func teleportConfigNames() {
    #expect(TeleportSSH.configFileName(proxy: "p:443", cluster: "c1", home: nil) == "tsh-c1.conf")
    #expect(TeleportSSH.configFileName(proxy: "p.example.com:443", cluster: nil, home: nil) == "tsh-p.example.com_443.conf")
    #expect(TeleportSSH.configFileName(proxy: nil, cluster: nil, home: "~/.tsh-work") == "tsh-work-default.conf")
    #expect(TeleportSSH.homeName("~/.tsh-work") == "work")
    #expect(TeleportSSH.homeName("/opt/acme/.tsh") == "acme")
    #expect(TeleportSSH.homeName(nil) == "")
    #expect(TeleportSSH.configBody("Host *.c1\n").hasSuffix("Host *\n    StrictHostKeyChecking accept-new\n"))
}

@Test func clusterListParsing() {
    let out = "WARNING: something\n[{\"cluster_name\":\"root\",\"cluster_type\":\"root\",\"status\":\"online\",\"selected\":true},{\"cluster_name\":\"leaf-a\",\"cluster_type\":\"leaf\",\"status\":\"online\"}]"
    let c = TeleportSSH.parseClusters(out)
    #expect(c?.count == 2)
    #expect(c?[1].leaf == true)
    #expect(c?[0].selected == true)
    #expect(TeleportSSH.parseClusters("no json") == nil)
}

@Test func leafCacheAnswersWithoutTsh() async {
    TeleportSSH.recordClusters(proxy: "unit.test:443", home: "/tmp/unit-home", clusters: [
        TeleportSSH.ClusterInfo(name: "leafy", leaf: true, status: "", selected: false, labels: .null),
        TeleportSSH.ClusterInfo(name: "rooty", leaf: false, status: "", selected: true, labels: .null),
    ])
    #expect(await TeleportSSH.isLeafCluster(proxy: "unit.test:443", cluster: "leafy", home: "/tmp/unit-home"))
    #expect(!(await TeleportSSH.isLeafCluster(proxy: "unit.test:443", cluster: "rooty", home: "/tmp/unit-home")))
    #expect(!(await TeleportSSH.isLeafCluster(proxy: "unit.test:443", cluster: nil, home: "/tmp/unit-home")))
}

// MARK: - local shells

@Test func shellList() {
    let etc = "# comment\n/bin/bash\n/bin/zsh\n/usr/local/bin/fish\n/bin/missing\n"
    let have: Set<String> = ["/bin/zsh", "/bin/bash", "/usr/local/bin/fish", "/bin/sh"]
    let list = LocalShells.listShells(etcShells: etc, loginShell: "/bin/zsh", isExecutable: { have.contains($0) })
    #expect(list.map { $0.path } == ["/bin/zsh", "/bin/bash", "/usr/local/bin/fish", "/bin/sh"])
    #expect(list[0].note == "your login shell")
    #expect(list.allSatisfy { $0.canBlank })
}

@Test func shellArgs() {
    #expect(LocalShells.blankArgs("/bin/bash") == ["--noprofile", "--norc"])
    #expect(LocalShells.blankArgs("/bin/zsh") == ["-f", "-d"])
    #expect(LocalShells.blankArgs("/opt/homebrew/bin/fish") == ["--no-config"])
    #expect(LocalShells.blankArgs("/bin/tcsh") == ["-f"])
    #expect(LocalShells.blankArgs("/bin/sh") == [])
    #expect(LocalShells.loginArgs("/bin/zsh") == ["-l"])
    #expect(LocalShells.loginArgs("/usr/bin/nu") == [])
    #expect(LocalShells.invocation(shell: "/bin/bash", blank: true).args == ["--noprofile", "--norc"])
    #expect(LocalShells.invocation(shell: "/bin/bash", blank: false).args == ["-l"])
    let cmd = LocalShells.invocation(shell: nil, blank: true, command: "tsh", args: ["play", "x"])
    #expect(cmd.file == "tsh" && cmd.args == ["play", "x"])
}

// MARK: - preferences

@MainActor @Test func agentForwardLevels() {
    var host = SLHost(type: "ssh", id: "ssh:ent", name: "ent")
    host.alias = "ent"
    var s: JSON = ["agentForward": true, "agentForwardHosts": [:], "agentForwardClusters": [:]]
    #expect(ConnPrefs.agentForward(for: host, settings: s))
    s["agentForwardClusters"] = ["ssh": false]
    #expect(!ConnPrefs.agentForward(for: host, settings: s))
    s["agentForwardHosts"] = ["ssh:ent": true]
    #expect(ConnPrefs.agentForward(for: host, settings: s))
    s["hostUsers"] = ["ssh:ent": "deploy"]
    let o = ConnPrefs.apply(to: ConnectOptions(), host: host, settings: s)
    #expect(o.login == "deploy")
    #expect(o.agentForward == true)
    let kept = ConnPrefs.apply(to: ConnectOptions(login: "me", agentForward: false), host: host, settings: s)
    #expect(kept.login == "me" && kept.agentForward == false)
}

@MainActor @Test func specsForSshAndBeams() async throws {
    let m = ConnectionManager.shared
    var alias = SLHost(type: "ssh", id: "ssh:ent", name: "ent")
    alias.alias = "ent"
    alias.configFile = "/x/extra"
    let a = try await m.buildSpec(host: alias, opts: ConnectOptions(login: "root", x11: "untrusted", agentForward: true))
    #expect(a.target == "root@ent")
    #expect(a.label == "ent (root)")
    #expect(a.configFile == "/x/extra")
    #expect(a.x11 == "untrusted" && a.agentForward && a.transport == .mux)

    var direct = SLHost(type: "ssh", id: "p_1", name: "My box")
    direct.direct = DirectSpec(hostname: "10.1.1.1", user: "admin", port: 22)
    let d = try await m.buildSpec(host: direct, opts: ConnectOptions())
    #expect(d.target == "admin@10.1.1.1")
    #expect(d.label == "My box")

    var beam = SLHost(type: "beam", id: "beam:p:b1", name: "b1")
    beam.proxy = "p"
    let b = try await m.buildSpec(host: beam, opts: ConnectOptions(transport: "tsh"))
    #expect(b.transport == .beam)
    #expect(b.label == "b1 (beam)")
    #expect(b.beamArgs() == ["--proxy=p", "beams", "ssh", "b1"])
}

@Test func x11StatusHints() {
    let none = X11Status.current(display: nil, exists: { _ in false })
    #expect(!none.available && !none.installed)
    #expect(none.hint.hasPrefix("XQuartz is not installed"))
    let noDisplay = X11Status.current(display: nil, exists: { $0 == "/opt/X11" })
    #expect(noDisplay.installed && !noDisplay.available)
    let ok = X11Status.current(display: "/private/tmp/launch-x/org.xquartz:0", exists: { $0 == "/opt/X11" })
    #expect(ok.available && ok.hint == "XQuartz detected.")
}

// MARK: - net probes

@Test func portProbeParsing() {
    let out = "p=22 rc=0 \np=81 rc=1 bash: connect: Connection refused \np=9 rc=124 \np=7 rc=1 nc: getaddrinfo: Name or service not known\n"
    let r = Connection.parsePortProbes(out, ports: [22, 81, 9, 7, 5], ms: 10, how: "bash /dev/tcp")
    #expect(r.map { $0.state } == ["open", "closed", "filtered", "dns", "unknown"])
    #expect(r[0].open == true && r[0].error == nil)
    #expect(r[2].error == "no answer before the timeout")
    #expect(r[4].open == nil)
}

@Test func hostToolsParsing() {
    let t = Connection.parseHostTools("tool=ping\ntool=nc\ndevtcp=yes\nncflavour=BusyBox v1.36\npkg=apk\nos=Alpine Linux v3.19=x\n", transport: .tsh)
    #expect(t.has("ping") && t.has("nc") && !t.has("dig"))
    #expect(t.devtcp && t.busybox)
    #expect(t.pkg == "apk")
    #expect(t.os == "Alpine Linux v3.19=x")
    #expect(t.canForward && !t.canProbeDirect)
}

@Test func hostFactsParsing() {
    let f = Connection.parseHostFacts("--hostname\nweb-1\n--addresses\nlo UP 127.0.0.1\neth0 UP 10.0.0.2\n--routes\ndefault via 10.0.0.1\n--resolvers\n")
    #expect(f.hostname == "web-1")
    #expect(f.addresses == "lo UP 127.0.0.1\neth0 UP 10.0.0.2")
    #expect(f.routes == "default via 10.0.0.1")
    #expect(f.resolvers == "")
    #expect(Connection.safeHost("a.b; rm -rf /") == "a.brm-rf")
}

@Test func freePort() throws {
    let p = try Connection.freeLocalPort()
    #expect(p > 1024 && p < 65536)
}
