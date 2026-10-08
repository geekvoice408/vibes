import Testing
import Foundation
@testable import ServerLife

// Ports of tests/livesessions.test.mjs, tests/profiles.test.mjs and
// tests/profileswitch.test.mjs, plus parser tests against real tsh output
// shapes (tsh 18.11) and the ssh_config writers on temp files.

private func tempDir(_ prefix: String = "sl-tp-") -> String {
    let d = NSTemporaryDirectory() + prefix + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func write(_ path: String, _ text: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

// MARK: - livesessions

private let sshTracker: JSON = [
    "kind": "session_tracker", "version": "v1",
    "metadata": ["name": "37689402-1b94-4576-9547-45856e3fd409"],
    "spec": [
        "session_id": "37689402-1b94-4576-9547-45856e3fd409", "kind": "ssh", "state": 1,
        "created": "2026-10-06T10:50:18.871263461Z",
        "target_hostname": "beam-9be7a318-f331-4be5-be0a-e0a472790df3",
        "target_address": "9be7a318-f331-4be5-be0a-e0a472790df3",
        "cluster_name": "red-fire.beams.sh", "login": "beams",
        "participants": [["id": "x", "user": "steven@goteleport.com", "mode": "peer"]],
        "host_user": "steven@goteleport.com",
    ],
]
private let appTracker: JSON = [
    "kind": "session_tracker",
    "spec": ["session_id": "63297a4e-c983-4224-9473-56eccaa8ae31", "kind": "app", "state": 1,
             "created": "2026-10-06T09:00:00Z", "app_name": "grafana", "cluster_name": "red-fire.beams.sh"],
]
private let kubeTracker: JSON = [
    "kind": "session_tracker",
    "spec": ["session_id": "k-1", "kind": "k8s", "created": "2026-10-06T11:00:00Z",
             "kubernetes_cluster": "prod-eks", "cluster_name": "red-fire.beams.sh", "login": "steven",
             "participants": [["user": "alice", "mode": "moderator"]]],
]

@Test func liveSessionsNewestFirstWithTargets() throws {
    let rows = try Teleport.parseSessionList(JSON.array([sshTracker, appTracker, kubeTracker]).text())
    #expect(rows.map(\.id) == ["k-1", "37689402-1b94-4576-9547-45856e3fd409", "63297a4e-c983-4224-9473-56eccaa8ae31"])
    let (k, s, a) = (rows[0], rows[1], rows[2])
    #expect(s.target == "beam-9be7a318-f331-4be5-be0a-e0a472790df3")
    #expect(s.login == "beams")
    #expect(s.participants == [ActiveSession.Participant(user: "steven@goteleport.com", mode: "peer")])
    #expect(k.target == "prod-eks")
    #expect(a.target == "grafana")
    #expect(s.joinable && k.joinable && !a.joinable)
}

@Test func liveSessionsStates() throws {
    let k = try Teleport.parseSessionList(JSON.array([kubeTracker]).text())[0]
    #expect(k.state == "pending" && k.joinable)
    var done = sshTracker
    done["spec"]["state"] = 2
    let s = try Teleport.parseSessionList(JSON.array([done]).text())[0]
    #expect(s.state == "terminated" && !s.joinable)
    #expect(try Teleport.parseSessionList("").isEmpty)
    #expect(try Teleport.parseSessionList("null").isEmpty)
    #expect(try Teleport.parseSessionList("[]").isEmpty)
}

@Test func joinArgs() throws {
    #expect(try Teleport.joinArgs("abc", proxy: "red-fire.beams.sh:443", cluster: "red-fire.beams.sh", kind: "ssh", mode: "peer")
            == ["--proxy=red-fire.beams.sh:443", "join", "--mode=peer", "--cluster=red-fire.beams.sh", "abc"])
    #expect(try Teleport.joinArgs("k-1", proxy: nil, cluster: nil, kind: "k8s", mode: "moderator")
            == ["kube", "join", "--mode=moderator", "k-1"])
    #expect(try Teleport.joinArgs("abc", proxy: nil, cluster: nil, kind: "ssh", mode: "admin") == ["join", "--mode=observer", "abc"])
    #expect(throws: AppError.self) { try Teleport.joinArgs("x", proxy: nil, cluster: nil, kind: "app", mode: "observer") }
    #expect(throws: AppError.self) { try Teleport.joinArgs("", proxy: nil, cluster: nil, kind: "ssh", mode: nil) }
}

// MARK: - profiles.test.mjs

private func tshHome(proxy: String = "lab.example.com", port: String = ":443", keys: Bool = true, current: String? = nil) -> String {
    let dir = tempDir("tsh-home-")
    write(dir + "/\(proxy).yaml", "web_proxy_addr: \(proxy)\(port)\n")
    if keys { write(dir + "/keys/\(proxy)/cert", "stale") }
    if let current { write(dir + "/current-profile", current) }
    return dir
}

@Test func profileFilesFoundThroughPortedAddress() {
    let dir = tshHome()
    let files = Teleport.profileFiles(proxy: "lab.example.com:443", home: dir)
    #expect(files.count == 2)
    #expect(files[0].hasSuffix("lab.example.com.yaml"))
    #expect(files[1].hasSuffix("keys/lab.example.com"))
}

@Test func removeProfileTakesOnlyItsOwn() {
    let dir = tshHome(current: "lab.example.com")
    write(dir + "/other.example.com.yaml", "keep me")
    write(dir + "/keys/other.example.com/x", "")
    let r = Teleport.removeProfile(proxy: "lab.example.com:443", home: dir)
    #expect(r.ok && r.removed.count == 3)
    #expect(!exists(dir + "/lab.example.com.yaml") && !exists(dir + "/keys/lab.example.com") && !exists(dir + "/current-profile"))
    #expect(exists(dir + "/other.example.com.yaml") && exists(dir + "/keys/other.example.com"))
}

@Test func removeProfileLeavesOthersCurrent() throws {
    let dir = tshHome(current: "other.example.com")
    _ = Teleport.removeProfile(proxy: "lab.example.com", home: dir)
    #expect(try String(contentsOfFile: dir + "/current-profile", encoding: .utf8) == "other.example.com")
    let noKeys = tshHome(keys: false)
    let r = Teleport.removeProfile(proxy: "lab.example.com", home: noKeys)
    #expect(r.ok && r.removed.count == 1 && !exists(noKeys + "/lab.example.com.yaml"))
}

@Test func removeProfileRefusesNonProxies() {
    let dir = tshHome()
    for bad in ["../../etc/passwd", "a/b", "", "  ", "lab.example.com/../..", "./lab"] {
        let r = Teleport.removeProfile(proxy: bad, home: dir)
        #expect(!r.ok)
        #expect(r.error?.contains("does not look like a proxy") == true)
    }
    #expect(exists(dir + "/lab.example.com.yaml"))
    #expect(Teleport.profileFiles(proxy: "../../etc", home: dir).isEmpty)
    let r = Teleport.removeProfile(proxy: "never-logged-in.example.com", home: dir)
    #expect(r.ok && r.removed.filter(exists).isEmpty && exists(dir + "/lab.example.com.yaml"))
}

private func node(_ hostname: String, _ uuid: String) -> ServerLife.Host {
    var h = ServerLife.Host(type: "teleport", id: uuid, name: hostname); h.hostname = hostname; h.uuid = uuid; h.cluster = "tele1c"; return h
}

@Test func ambiguousHostnames() {
    var nodes = [node("duplicate", "uuid-1"), node("duplicate", "uuid-2"), node("web-1", "uuid-3")]
    Teleport.markAmbiguous(&nodes)
    #expect(nodes.map { $0.ambiguous == true } == [true, true, false])
    var plain = [node("a", "1"), node("b", "2"), node("c", "3")]
    Teleport.markAmbiguous(&plain)
    #expect(plain.map { $0.ambiguous == true } == [false, false, false])
}

@Test func roleChoices() {
    let numbered = ["Available roles:", "  1. access", "  2. dev-access", "  3. prod-access",
                    "Choose roles to request [1]: ", "ERROR: failed reading prompt response: EOF"].joined(separator: "\n")
    #expect(Teleport.roleChoicesFrom(numbered) == ["access", "dev-access", "prod-access"])
    #expect(Teleport.roleChoicesFrom("Choose roles to request [access, dev-access]: failed reading prompt response: EOF")
            == ["access", "dev-access"])
    #expect(Teleport.roleChoicesFrom("ERROR: access denied").isEmpty)
    #expect(Teleport.roleChoicesFrom("ERROR: request reason must be specified").isEmpty)
    #expect(Teleport.roleChoicesFrom("").isEmpty)
    #expect(Teleport.roleChoicesFrom("Nodes:\n  1. web-1\n  2. web-2").isEmpty)
}

private func req(_ roles: [String], _ ids: [String]) -> AccessRequest {
    AccessRequest(id: UUID().uuidString, user: "", roles: roles,
                  resources: ids.map { RequestResource(kind: "node", name: "", sub: "", cluster: "", id: $0, label: nil) },
                  state: "APPROVED", reason: "", reviewers: [])
}

@Test func rolesForResources() {
    let history = [req(["access"], ["/c1/node/aaa"]), req(["access", "staging-access"], ["/c1/node/bbb"]), req(["aws-access"], [])]
    #expect(Teleport.rolesForResources(history, ["/c1/node/bbb"]) == ["access", "staging-access"])
    #expect(Teleport.rolesForResources(history, ["/c1/node/aaa"]) == ["access"])
    #expect(Teleport.rolesForResources(history, ["/c1/node/aaa", "/c1/node/bbb"]) == ["access", "staging-access"])
    #expect(Teleport.rolesForResources([req(["admin-access"], ["/c1/node/aaa"])], ["/c1/node/zzz"]).isEmpty)
    #expect(Teleport.rolesForResources(history, []).isEmpty)
    #expect(Teleport.rolesForResources([], ["/c1/node/aaa"]).isEmpty)
}

@Test func requestableRoles() {
    let raw: JSON = [["Role": "staging-access", "Description": "SSH to staging RHEL hosts and Kibana."],
                     ["Role": "aws-access", "Description": "AWS console access to account 165258854585."]]
    #expect(Teleport.parseRequestableRoles(raw) == [
        RequestableRole(name: "aws-access", description: "AWS console access to account 165258854585."),
        RequestableRole(name: "staging-access", description: "SSH to staging RHEL hosts and Kibana."),
    ])
    #expect(Teleport.parseRequestableRoles(["plain"]) == [RequestableRole(name: "plain", description: "")])
    #expect(Teleport.parseRequestableRoles([["name": "lower"]]) == [RequestableRole(name: "lower", description: "")])
    #expect(Teleport.parseRequestableRoles([["nothing": true]]).isEmpty)
    #expect(Teleport.parseRequestableRoles(.null).isEmpty)
}

// MARK: - profileswitch.test.mjs

@Test func markCurrentProfile() throws {
    let dir = tempDir("sl-tsh-")
    for p in ["old.example.com", "red-fire.beams.sh"] { write(dir + "/\(p).yaml", "web_proxy_addr: x\n") }
    write(dir + "/current-profile", "old.example.com\n")
    #expect(Teleport.markCurrentProfile(proxy: "https://red-fire.beams.sh:443/web", home: dir))
    #expect(try String(contentsOfFile: dir + "/current-profile", encoding: .utf8) == "red-fire.beams.sh\n")
    #expect(!Teleport.markCurrentProfile(proxy: "nowhere.example.com:443", home: dir))
    #expect(try String(contentsOfFile: dir + "/current-profile", encoding: .utf8) == "red-fire.beams.sh\n")
}

// MARK: - Login commands

@Test func loginArgsNormaliseProxy() {
    let o = Teleport.LoginOptions(proxy: "https://user@example.teleport.sh:3080/web/cluster/x", cluster: "leaf1",
                                  user: "alice", authConnector: "okta", ttl: "720", mfaMode: "platform",
                                  extraArgs: ["--insecure", ""])
    #expect(Teleport.loginArgs(o) == ["login", "--proxy=example.teleport.sh:3080", "--user=alice", "--auth=okta",
                                      "--ttl=720", "--mfa-mode=platform", "--insecure", "leaf1"])
    #expect(Teleport.proxyAddress("  https://a.b:443  ") == "a.b:443")
    let cmd = Teleport.loginCommand(Teleport.LoginOptions(proxy: "a.b", user: "o'brien", home: "/tmp/tsh home"))
    #expect(cmd == "TELEPORT_HOME='/tmp/tsh home' tsh login --proxy=a.b '--user=o'\\''brien'")
}

@Test func webLinks() {
    #expect(Teleport.webClusterUrl(proxy: "https://example.com:3080/web", cluster: "my cluster")
            == "https://example.com:3080/web/cluster/my%20cluster/resources")
    #expect(Teleport.webClusterUrl(proxy: "example.com", cluster: "") == "https://example.com/web")
    #expect(Teleport.webClusterUrl(proxy: "example.com", cluster: "c", section: "audit") == "https://example.com/web/cluster/c/audit/events")
    #expect(Teleport.webClusterUrl(proxy: nil, cluster: "c") == nil)
    #expect(Teleport.webSessionUrl(proxy: "https://p:443", cluster: "c", sid: "s1") == "https://p:443/web/cluster/c/session/s1")
}

@Test func homeNames() {
    #expect(TeleportHomes.name(NSHomeDirectory() + "/.tsh-work") == "work")
    #expect(TeleportHomes.name("/opt/acme/.tsh") == "acme")
    #expect(TeleportHomes.name(TeleportHomes.defaultHome) == "")
    #expect(TeleportProfile.key(cluster: "c", proxy: "p:443", home: nil) == "c")
    #expect(TeleportProfile.key(cluster: "", proxy: "p:443", home: "/h") == "p:443@@/h")
}

// MARK: - tsh output parsers

/// Trimmed from tsh 18.11 `tsh status --format=json`.
private let statusJSON = """
{
  "active": {
    "profile_url": "https://super-grass.beams.sh:443", "username": "paul@example.net",
    "cluster": "super-grass.beams.sh", "roles": ["access", "editor"], "logins": ["paul", "beams"],
    "valid_until": "2026-10-06T03:24:39-07:00",
    "active_requests": ["r-1"],
    "allowed_resources": [{"id": {"cluster": "c", "kind": "node", "name": "n1"}}, {"kind": "app", "name": "grafana"}]
  },
  "profiles": [
    {"profile_url": "https://super-grass.beams.sh:443", "cluster": "super-grass.beams.sh", "username": "paul@example.net"},
    {"profile_url": "https://stitch.example.net:443", "username": "admin", "cluster": "stitch.example.net",
     "roles": ["access"], "logins": ["paul"], "valid_until": "2099-10-05T21:28:21-07:00"}
  ]
}
"""

@Test func statusJSONParse() throws {
    let now = TPText.parseDate("2026-10-07T00:00:00Z")!
    let ps = try #require(Teleport.parseStatusJSON(statusJSON, now: now))
    #expect(ps.count == 2)
    #expect(ps[0].proxy == "super-grass.beams.sh:443" && ps[0].active && ps[0].expired)
    #expect(ps[0].activeRequests == ["r-1"])
    #expect(ps[0].allowedResources == ["node/n1", "app/grafana"])
    #expect(ps[1].proxy == "stitch.example.net:443" && !ps[1].active && !ps[1].expired && ps[1].username == "admin")
}

/// The text form, as tsh 18.11 prints it.
private let statusText = """
> Profile URL:        https://super-grass.beams.sh:443
  Logged in as:       paul@example.net
  Cluster:            super-grass.beams.sh
  Roles:              access, beam-admin, editor
  Logins:             paul, paul_hall, beams
  Kubernetes:         enabled
  Valid until:        2026-10-06 03:24:39 -0700 PDT [EXPIRED]
  Extensions:         login-ip, permit-pty

  Profile URL:        https://stitch.example.net:443
  Logged in as:       teleport-k8s-admin
  Cluster:            stitch.example.net
  Roles:              access, editor
  Logins:             paul
  Valid until:        2099-10-05 21:28:21 -0700 PDT [valid for 1h0m0s]
"""

@Test func statusTextParse() {
    let ps = Teleport.parseStatusText(statusText)
    #expect(ps.count == 2)
    #expect(ps[0].proxy == "super-grass.beams.sh:443" && ps[0].active && ps[0].expired)
    #expect(ps[0].roles == ["access", "beam-admin", "editor"] && ps[0].logins.count == 3)
    #expect(ps[0].validUntil == "2026-10-06 03:24:39 -0700 PDT")
    #expect(ps[0].validUntilMs != nil)
    #expect(ps[1].cluster == "stitch.example.net" && !ps[1].active && !ps[1].expired)
}

@Test func nodesParse() throws {
    let text = """
    [{"kind":"node","sub_kind":"","metadata":{"name":"uuid-2","labels":{"env":"prod"},"expires":"2026-10-07T10:00:00.123456789Z"},
      "spec":{"hostname":"Node-10","addr":"","use_tunnel":true,"cmd_labels":{"uptime":{"period":"1m","command":["uptime"],"result":"up 1 day, 2 hours"}}}},
     {"kind":"node","metadata":{"name":"uuid-1","expires":"0001-01-01T00:00:00Z"},"spec":{"hostname":"node-2","addr":"10.0.0.1:3022"}},
     {"kind":"node","metadata":{"name":"uuid-3"},"spec":{"hostname":"node-2","addr":"10.0.0.2:3022"}}]
    """
    let nodes = try #require(Teleport.parseNodes(text, proxy: "p:443", cluster: "c1", home: nil))
    #expect(nodes.map(\.name) == ["node-2", "node-2", "Node-10"])
    #expect(nodes[0].id == "tsh:c1:uuid-1" && nodes[0].ambiguous == true && nodes[2].ambiguous == false)
    #expect(nodes[0].nodeExpiresMs == nil && nodes[0].tunnel == false && nodes[0].subKind == "teleport")
    #expect(nodes[2].addr == "tunnel" && nodes[2].tunnel == true)
    #expect(nodes[2].labels == ["env": "prod", "uptime": "up 1 day, 2 hours"])
    #expect(nodes[2].nodeExpiresMs != nil)
    let other = try #require(Teleport.parseNodes(text, proxy: "p:443", cluster: "c1", home: "/tmp/.tsh-work"))
    #expect(other[0].id == "tsh:work:c1:uuid-1" && other[0].home == "/tmp/.tsh-work" && other[0].nodeHomeName == "work")
}

@Test func clustersAndRequestsParse() throws {
    let cl = try #require(Teleport.parseClusters("noise\n[{\"cluster_name\":\"root\",\"cluster_type\":\"root\",\"status\":\"online\",\"selected\":true},{\"cluster_name\":\"leaf1\",\"cluster_type\":\"leaf\",\"status\":\"online\"},{\"cluster_name\":\"\"}]"))
    #expect(cl.map(\.name) == ["root", "leaf1"] && cl[0].selected && cl[1].leaf && !cl[0].leaf)
    let reqs = try #require(Teleport.parseRequests("""
    [{"metadata":{"name":"r1"},"spec":{"user":"alice","roles":["access"],"state":2,"request_reason":"ticket",
      "resource_ids":[{"kind":"node","name":"uuid-1","cluster":"c1"},{"kind":"kube","name":"k","cluster":"c1","sub_resource_name":"ns/x"}],
      "max_duration":"2099-01-01T00:00:00Z"}},
     {"metadata":{"name":"r2"},"spec":{"state":"PENDING"}}]
    """, proxy: "p"))
    #expect(reqs[0].state == "APPROVED" && reqs[0].resources.map(\.id) == ["/c1/node/uuid-1", "/c1/kube/k/ns/x"])
    #expect(reqs[0].isLive() && reqs[1].isLive() && reqs[1].state == "PENDING")
    #expect(Teleport.parseLabelString("uptime=up 1 day, 22 hours,env=prod") == ["uptime": "up 1 day, 22 hours", "env": "prod"])
}

@Test func requestArgsAndProbe() {
    let args = Teleport.createRequestArgs(Teleport.RequestSpec(proxy: "p", roles: ["a", "b"], resources: ["/c/node/1", "/c/node/2"],
                                                               reason: "why", maxDuration: "2h"))
    #expect(args == ["--proxy=p", "request", "create", "--roles=a,b", "--resource=/c/node/1", "--resource=/c/node/2",
                     "--reason=why", "--max-duration=2h", "--nowait"])
    let probe = Teleport.readProbe("""
    ERROR: request reason must be specified (required for role "access")
    Include a ticket or case reference
    """)
    #expect(probe.roles == ["access"] && probe.reasonRequired && probe.prompt == "Include a ticket or case reference")
}

@Test func recordingsAndBeamsParse() throws {
    let recs = try #require(Teleport.parseRecordings("""
    [{"sid":"a","session_start":"2026-10-06T10:00:00Z","session_stop":"2026-10-06T10:05:00Z","interactive":true,"server_hostname":"web"},
     {"sid":"b","session_start":"2026-10-06T11:00:00Z","session_recording":"off","server_id":"id-2"},
     {"sid":""}]
    """, proxy: "p"))
    #expect(recs.map(\.sid) == ["b", "a"] && !recs[0].playable && recs[0].node == "id-2" && recs[1].durationMs == 300_000)
    #expect(Teleport.toRecordingDate("2026-10-06") == "2026-10-06")
    #expect(Teleport.toRecordingDate("2026-10-06T23:30:00-07:00") == "2026-10-07")
    let beams = try #require(Beams.parseList("[{\"id\":\"b1\",\"uuid\":\"u1\",\"region\":\"us-east-1\",\"requested_region\":\"us-west-2\",\"expires\":\"2099-01-01T00:00:00Z\"}]", proxy: "p", home: nil))
    #expect(beams[0].requestedRegion == "us-west-2" && beams[0].expires != nil)
    #expect(Beams.publishedAddress("Published at https://x.beams.sh:443/ now") == "https://x.beams.sh:443/")
    #expect(Beams.sshArgs(name: "b1", proxy: "p") == ["--proxy=p", "beams", "ssh", "b1"])
    #expect(Beams.execArgs(name: "b1", proxy: nil, command: "sftp-server") == ["beams", "exec", "b1", "--", "sftp-server"])
}

@Test func webapiPingLayout() {
    #expect(WebAPIPing.splitHostPort("https://proxy.example.com:3080/web").host == "proxy.example.com")
    #expect(WebAPIPing.splitHostPort("https://proxy.example.com:3080/web").port == 3080)
    #expect(WebAPIPing.splitHostPort("[::1]:443").host == "::1")
    let p: JSON = ["cluster_name": "c", "server_version": "18.1.0", "edition": "ent",
                   "auth": ["type": "saml", "saml": ["name": "okta", "display": "Okta"], "second_factor": "on"],
                   "proxy": ["tls_routing_enabled": true, "ssh": ["public_addr": "c:443"]]]
    #expect(WebAPIPing.badges(p).map(\.text) == ["c", "v18.1.0", "Enterprise", "TLS routing"])
    let s = WebAPIPing.sections(p)
    #expect(s.map(\.title) == ["Cluster", "Authentication", "SAML connector", "Proxy listeners"])
    #expect(s[1].rows.first?.value == "saml — Okta")
}

// MARK: - ssh_config

@Test func sshConfigDiscovery() throws {
    let dir = tempDir()
    write(dir + "/config", """
    # Web box
    Host web web-alias
      HostName 10.0.0.5
    Host *.example
      User shared
    Include conf.d/*
    Host !neg *
      Port 2200
    """)
    write(dir + "/conf.d/a.conf", "Host db.example\n  Port 2222\n")
    let aliases = SSHConfig.collectAliases(dir + "/config")
    #expect(aliases.map(\.alias) == ["web", "web-alias", "db.example"])
    #expect(aliases[0].comment == "Web box")
    let cfg = SSHConfig.readAliasFromFile(aliases[2])
    #expect(cfg["port"] == ["2222"])
    let g = SSHConfig.parseSshG("hostname 10.0.0.5\nuser paul\nidentityfile ~/.ssh/a\nidentityfile ~/.ssh/b\n")
    #expect(g["identityfile"] == ["~/.ssh/a", "~/.ssh/b"])
    let roots = SSHConfig.configRoots(["~/x.conf", "~/x.conf", ""], primary: dir + "/config")
    #expect(roots.count == 2 && roots[1].file == NSHomeDirectory() + "/x.conf" && !roots[1].primary)
}

@Test func managedBlockAddRemove() throws {
    let dir = tempDir()
    let path = dir + "/config"
    write(path, "Host mine\n  HostName 1.2.3.4\n")
    #expect(throws: AppError.self) { try SSHConfig.addHost(ManagedSSHHost(alias: "mine", hostname: "x"), configPath: path) }
    #expect(throws: AppError.self) { try SSHConfig.addHost(ManagedSSHHost(alias: "two words", hostname: "x"), configPath: path) }
    try SSHConfig.addHost(ManagedSSHHost(alias: "a1", hostname: "h1", user: "u", port: 2222, identityFile: "~/.ssh/k"), configPath: path)
    try SSHConfig.addHost(ManagedSSHHost(alias: "a2", hostname: "h2"), configPath: path)
    try SSHConfig.addHost(ManagedSSHHost(alias: "a1", hostname: "h1b"), configPath: path)
    #expect(exists(path + ".serverlife-backup"))
    #expect(SSHConfig.managedAliases(configPath: path) == ["a2", "a1"])
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.hasPrefix("Host mine\n  HostName 1.2.3.4\n\n# >>> ServerLife managed hosts >>>"))
    #expect(text.contains("Host a1\n  HostName h1b") && !text.contains("2222"))
    #expect(try SSHConfig.removeHost("a2", configPath: path))
    #expect(try !SSHConfig.removeHost("nope", configPath: path))
    #expect(try SSHConfig.removeHost("A1", configPath: path))
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "Host mine\n  HostName 1.2.3.4\n")
}

@Test func tshConfigWriteAndStatus() throws {
    let dir = tempDir()
    let path = dir + "/config"
    let generated = "Host *.c1 c1.proxy\n    Port 3022\n"
    write(path, "\n\nHost *\n  User me\nHost *.c1\n  User old\n")
    var st = SSHConfig.tshConfigStatus(cluster: "c1", proxy: "p", generated: generated, configPath: path)
    #expect(!st.present && st.foreign == ["*.c1"] && st.hasFile)
    let r1 = try SSHConfig.writeTshConfig(cluster: "c1", proxy: "p", text: generated, configPath: path)
    #expect(!r1.replaced && r1.backup != nil && r1.lines == 6)
    var text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.hasPrefix("# >>> ServerLife: tsh config for c1 >>>"))
    #expect(text.contains("# <<< ServerLife: tsh config for c1 <<<\n\nHost *\n  User me"))
    let r2 = try SSHConfig.writeTshConfig(cluster: "c1", proxy: "p", text: generated.replacingOccurrences(of: "3022", with: "3023"), configPath: path)
    #expect(r2.replaced)
    text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.components(separatedBy: "tsh config for c1 >>>").count == 2 && text.contains("3023") && !text.contains("3022"))
    st = SSHConfig.tshConfigStatus(cluster: "c1", proxy: "p", generated: generated, configPath: path)
    #expect(st.present)
    #expect(throws: AppError.self) { try SSHConfig.writeTshConfig(cluster: "c1", proxy: nil, text: "nothing", configPath: path) }
}
