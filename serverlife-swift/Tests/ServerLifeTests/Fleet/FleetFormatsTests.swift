import Foundation
import Testing
@testable import ServerLife

/// The multi-exec YAML files and the Ansible export. The expected YAML in
/// FleetGolden.swift was produced by the Electron app's own code (js-yaml
/// 5.4.2 and multiexecfile.js, with the clock fixed), so a file written here
/// is the file the original wrote.
@Suite struct FleetFormatsTests {
    private static func s(_ v: String) -> YAMLValue { .string(v) }

    static let case0: YAMLValue = .map([
        ("a", s("plain")), ("b", s("yes")), ("c", s("123")), ("d", s("a: b")), ("e", s("#x")), ("f", s("- x")),
        ("g", s("")), ("h", s("ends ")), ("i", s("tab\there")), ("j", s("naïve ☃")), ("k", s("it's")),
        ("l", s("say \"hi\"")), ("m", s("null")), ("n", s("~")), ("o", s("0x1F")), ("p", s("1.5")), ("q", s(".inf")),
        ("r", s("2024-01-02")), ("s", s("on")), ("t", s("True")), ("u", s("@home")), ("v", s("%x")), ("w", s("`x")),
        ("x", s("!x")), ("y", s("&x")), ("z", s("*x")), ("aa", s("|x")), ("ab", s(">x")), ("ac", s("?x")),
        ("ad", s("x?")), ("ae", s("a #b")), ("af", s("a#b")), ("ag", s("{x}")), ("ah", s("[x]")), ("ai", s("x,y")),
        ("aj", s(" lead")), ("ak", s("-")), ("al", s("--- x")), ("am", s("1_000")), ("an", s("0o17")), ("ao", s("1e3")),
        ("ap", s("10:20")), ("aq", s("<<")), ("ar", s("Y")), ("as", s("x:")), ("at", s(":x")), ("au", s("é")),
        ("av", s("a\\b")), ("aw", s("\u{01}")), ("ax", s("π=3")), ("ay", s("=")), ("az", s("web-1.example.com")),
        ("ba", s("ubuntu@host")),
    ])
    static let case1: YAMLValue = .map([("n1", .int(10)), ("n2", .int(120)), ("n3", .double(1.5)), ("n4", .bool(true)),
                                        ("n5", .bool(false)), ("n6", .int(-3)), ("n7", .int(0))])
    static let case2: YAMLValue = .map([
        ("multi", s("line one\nline two\n")), ("nochomp", s("a\nb")), ("keep", s("a\nb\n\n")),
        ("lead", s("  indented\nnext\n")), ("onlynl", s("\n")), ("empty", s("")),
        ("long", s(Array(repeating: "word", count: 30).joined(separator: " "))),
        ("longml", s(String(repeating: String(repeating: "x", count: 20) + " ", count: 8) + "\nshort\n")),
        ("longnosp", s(String(repeating: "y", count: 130))), ("spacey", s("a  b")), ("trailnl", s("abc\n")),
        ("tabs", s("a\tb\nc\n")), ("crlf", s("a\r\nb\n")), ("unicodeml", s("héllo\nwörld\n")),
    ])
    static let case3: YAMLValue = .map([
        ("list", .seq([.map([("type", s("teleport")), ("name", s("n1")), ("cluster", s("c"))]),
                       .map([("type", s("ssh")), ("alias", s("ent"))])])),
        ("nested", .map([("a", .map([("b", s("c"))]))])),
        ("emptyl", .seq([])), ("emptym", .map([])), ("scal", .seq([s("a"), s("b")])),
    ])
    static let cases = [case0, case1, case2, case3]

    @Test func dumpMatchesJsYamlAtWidth100() {
        for (i, c) in Self.cases.enumerated() {
            #expect(YAMLEmitter.dump(c, .init(lineWidth: 100)) == FleetGolden.dump100[i], "case \(i)")
        }
    }

    @Test func dumpMatchesJsYamlAtWidth120() {
        for (i, c) in Self.cases.enumerated() {
            #expect(YAMLEmitter.dump(c, .init(lineWidth: 120)) == FleetGolden.dump120[i], "case \(i)")
        }
    }

    @Test func whatIsDumpedLoadsBackAsTheSameValues() throws {
        for c in [Self.case0, Self.case2, Self.case3] {
            let back = try YAMLReader.load(YAMLEmitter.dump(c, .init(lineWidth: 100)))
            #expect(back == c)
        }
    }

    static let now = ISO8601DateFormatter().date(from: "2026-10-07T12:34:56Z")!.addingTimeInterval(0.789)

    @Test func aRunIsWrittenAsTheOriginalWroteIt() {
        let text = MultiExecFile.toYaml(name: "df -h /", command: "df -h /\nuptime", targets: [
            .init(type: "teleport", name: "node-1", cluster: "example.teleport.sh", proxy: "example.teleport.sh:443", login: "ubuntu"),
            .init(type: "ssh", alias: "ent", user: "root", port: 2222),
            .init(type: "ssh", name: "web", login: "deploy"),
        ], options: .init(concurrency: 10, timeout: 120_000), now: Self.now)
        #expect(text == FleetGolden.basic)
    }

    @Test func aTagRunSavesItsQuestionAndSaysSo() {
        let text = MultiExecFile.toYaml(
            name: "yes", description: "Check: all things",
            command: "systemctl restart nginx && sleep 2 && systemctl status nginx --no-pager --lines=50 | grep -v something-very-long-here-to-fold",
            targets: [.init(type: "teleport", name: "n2", cluster: "prod")],
            options: .init(concurrency: 5, timeout: 30_500, stopOnError: true),
            selector: .init(cluster: "prod", query: "env=prod role:web"), now: Self.now)
        #expect(text == FleetGolden.selector)
    }

    @Test func resultsAreWrittenAsTheOriginalWroteThem() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ms = { (s: String) in (f.date(from: s)!.timeIntervalSince1970 * 1000).rounded() }
        let view = MultiExecView(id: "run1", command: "uname -a", startedAt: ms("2026-01-02T03:04:05.006Z"),
                                 endedAt: ms("2026-01-02T03:04:09.000Z"), results: [
            .init(connId: "a", label: "web-1", status: "done", exitCode: 0, stdout: "Linux web-1 6.1.0\n\n", durationMs: 412),
            .init(connId: "b", label: "db (ubuntu)", status: "error", exitCode: 255,
                  stderr: "ssh: connect to host db port 22: Connection refused", durationMs: 1200),
            .init(connId: "c", label: "x", status: "timeout", stdout: "tab\there\n"),
            .init(connId: "d", label: "y", status: "cancelled"),
        ])
        #expect(MultiExecFile.resultsToYaml(view) == FleetGolden.results)
    }

    @Test func aSavedRunLoadsBack() throws {
        let def = try MultiExecFile.fromYaml(FleetGolden.basic)
        #expect(def.name == "df -h /")
        #expect(def.command == "df -h /\nuptime")
        #expect(def.options == .init(concurrency: 10, timeout: 120_000, stopOnError: false))
        #expect(def.selector == nil)
        #expect(def.targets.count == 3)
        #expect(def.targets[0] == .init(type: "teleport", name: "node-1", cluster: "example.teleport.sh",
                                        proxy: "example.teleport.sh:443", login: "ubuntu"))
        #expect(def.targets[1] == .init(type: "ssh", alias: "ent", user: "root", port: 2222))
        #expect(def.targets[2] == .init(type: "ssh", alias: "web", user: "deploy"))
        let sel = try MultiExecFile.fromYaml(FleetGolden.selector)
        #expect(sel.selector == .init(cluster: "prod", query: "env=prod role:web"))
        #expect(sel.options.timeout == 31_000 && sel.options.stopOnError)
        #expect(sel.command.hasPrefix("systemctl restart nginx && sleep 2") && sel.command.hasSuffix("to-fold"))
        #expect(sel.name == "yes")
    }

    @Test func theGuideExampleLoads() throws {
        let def = try MultiExecFile.fromYaml("""
        kind: serverlife.multiexec
        name: Check disk usage
        command: |
          df -h /
          uptime
        targets:
          - type: teleport
            name: example-cluster
            cluster: example-cluster
            login: ubuntu
          - type: ssh
            alias: ent
        """)
        #expect(def.command == "df -h /\nuptime")
        #expect(def.targets.map { $0.name ?? $0.alias } == ["example-cluster", "ent"])
        #expect(def.options.concurrency == 10 && def.options.timeout == 120_000)
    }

    @Test func notARunIsRefusedWithTheOriginalsWords() {
        func message(_ text: String) -> String {
            do { _ = try MultiExecFile.fromYaml(text); return "" } catch { return (error as? AppError)?.message ?? "" }
        }
        #expect(message("just text") == "File does not contain a multi-exec run")
        #expect(message("kind: other\ncommand: x") == "Unexpected kind \"other\"")
        #expect(message("name: x") == "Missing a \"command\" field")
        #expect(message("command: ls") == "Missing a \"targets\" list")
        #expect(message("command: ls\ntargets:\n  - 3") == "Target 1 is not a mapping")
        #expect(message("command: ls\ntargets:\n  - type: teleport") == "Teleport target 1 needs a \"name\"")
        #expect(message("command: ls\ntargets:\n  - user: x") == "SSH target 1 needs an \"alias\"")
        #expect(message("command: \"unterminated").hasPrefix("Not valid YAML: "))
        // A selector is a complete definition on its own.
        #expect(message("command: ls\nselector:\n  query: env=prod") == "")
    }

    @Test func theReaderHandlesTheUsualYaml() throws {
        let v = try YAMLReader.load("""
        # comment
        a: 1   # trailing
        b: [x, 'y z', {k: v}]
        c: {p: 2, q: "two\\nlines"}
        d: >-
          folded
          text

          para
        e:
        - one
        - two: 2
          three: 3
        f: &anchor hello
        g: *anchor
        h: ~
        i: true
        j: 0x10
        k: 1.5e3
        l: 'it''s'
        m: plain text
          continued
        """)
        #expect(v["a"] == .int(1))
        #expect(v["b"] == .seq([.string("x"), .string("y z"), .map([("k", .string("v"))])]))
        #expect(v["c"]["q"] == .string("two\nlines"))
        #expect(v["d"] == .string("folded text\npara"))
        #expect(v["e"] == .seq([.string("one"), .map([("two", .int(2)), ("three", .int(3))])]))
        #expect(v["g"] == .string("hello"))
        #expect(v["h"] == .null && v["i"] == .bool(true) && v["j"] == .int(16) && v["k"] == .double(1500))
        #expect(v["l"] == .string("it's"))
        #expect(v["m"] == .string("plain text continued"))
    }

    // MARK: Ansible (tests/ansible.test.mjs)

    static let targets: [AnsibleExport.Target] = [
        .init(type: "ssh", name: "web-1", alias: "web-1", hostname: "10.0.0.1", login: "ubuntu", port: 22),
        .init(type: "ssh", name: "web-2", alias: "web-2", hostname: "10.0.0.2", login: "ubuntu", port: 22),
    ]

    @Test func ansibleCfgAsksForYamlFromTheBuiltInCallback() {
        let cfg = AnsibleExport.build(Self.targets, command: "df -h").cfg
        let lines = cfg.components(separatedBy: "\n")
        #expect(!lines.contains("stdout_callback = yaml") && !lines.contains("stdout_callback = community.general.yaml"))
        #expect(lines.contains("stdout_callback = ansible.builtin.default"))
        #expect(lines.contains("callback_result_format = yaml"))
    }

    @Test func theCommandRunsWithRawAndNoTty() {
        let b = AnsibleExport.build(Self.targets, command: "df -h")
        #expect(b.playbook.contains("ansible.builtin.raw: |"))
        #expect(!b.playbook.contains("ansible.builtin.shell"))
        #expect(b.cfg.components(separatedBy: "\n").contains("usetty = False"))
        // A failure names its cause: stderr, else Ansible's own message.
        #expect(b.playbook.contains("result.msg"))
    }

    @Test func theInventoryGroupsByClusterWithSlugNames() {
        let b = AnsibleExport.build([
            .init(type: "teleport", name: "node.a", cluster: "prod.example", proxy: "prod.example:443", login: "ec2-user"),
            .init(type: "ssh", name: "web-1", alias: "web-1", user: "root", port: 2222),
        ], command: "uptime", .init(playName: "Run: uptime"))
        #expect(b.inventory.contains("    teleport_prod_example:\n      hosts:\n        node_a:\n          ansible_host: node.a.prod.example\n          ansible_user: ec2-user\n"))
        #expect(b.inventory.contains("        ansible_ssh_common_args: '-F ./ssh_config/tsh-prod_example.conf'"))
        #expect(b.inventory.contains("        web_1:\n          ansible_host: web-1\n          ansible_user: root\n          ansible_port: 2222\n"))
        #expect(b.inventory.contains("ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'"))
        #expect(b.playbook.contains("- name: 'Run: uptime'"))
        #expect(b.cfg.contains("forks = 5"))
    }

    @Test func theExportFolderNameIsOneSafeFolder() {
        #expect(AnsibleExport.exportFolderName("db backups") == "db backups")
        #expect(AnsibleExport.exportFolderName("../../etc/passwd") == "etc-passwd")
        #expect(AnsibleExport.exportFolderName("a/b\\c:d*e?") == "a-b-c-d-e")
        #expect(AnsibleExport.exportFolderName("trailing dots...") == "trailing dots")
        #expect(AnsibleExport.exportFolderName("   ") == "serverlife-ansible")
        #expect(AnsibleExport.exportFolderName("CON") == "serverlife-ansible")
    }

    @Test func theSuggestedNameComesFromTheCommand() {
        #expect(AnsibleExport.suggestFolderName("df -h") == "ansible-df")
        #expect(AnsibleExport.suggestFolderName("/usr/bin/systemctl restart nginx") == "ansible-systemctl")
        #expect(AnsibleExport.suggestFolderName("") == "serverlife-ansible")
    }

    @Test func theBundleLoadsInTheInstalledAnsiblePlaybook() async throws {
        guard Proc.which("ansible-playbook") != nil else { return }   // not installed here
        let dir = NSTemporaryDirectory() + "sl-ansible-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try await AnsibleExport.write(dir, AnsibleExport.build(Self.targets, command: "df -h"), teleport: false)
        // --syntax-check and --list-hosts read the config, inventory and play
        // and stop there: nothing is connected to.
        for flag in ["--syntax-check", "--list-hosts"] {
            let r = await Proc.run("ansible-playbook", ["playbook.yml", flag],
                                   env: ["ANSIBLE_CONFIG": dir + "/ansible.cfg"], cwd: dir, timeout: 60)
            #expect(r.code == 0, "ansible-playbook \(flag) failed:\n\(r.out)\n\(r.err)")
            if flag == "--list-hosts" {
                #expect(r.out.contains("hosts (2)") && r.out.contains("web_1") && r.out.contains("web_2"))
            }
        }
    }
}
