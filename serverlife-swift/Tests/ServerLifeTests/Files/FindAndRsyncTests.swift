import Foundation
import Testing
@testable import ServerLife

@Suite struct FindFilesTests {
    @Test func globs() throws {
        #expect(FindFiles.toGlob("nginx") == "*nginx*", "a bare word means contains")
        #expect(FindFiles.toGlob("*.conf") == "*.conf")
        #expect(FindFiles.toGlob("  ") == "*")
        let re = try #require(FindFiles.globToRegex("*.conf", caseSensitive: false))
        #expect(re.matches("NGINX.CONF") && !re.matches("nginx.conf.bak"))
        #expect(try #require(FindFiles.globToRegex("a?c", caseSensitive: true)).matches("abc"))
        #expect(!(try #require(FindFiles.globToRegex("a?c", caseSensitive: true))).matches("ABC"))
    }

    @Test func localNamesContentsAndBudgets() async throws {
        let dir = try scratchDir("find"); defer { cleanup(dir) }
        try writeFile(dir + "/etc/nginx.conf", "server {\n  proxy_pass http://x;\n}\n")
        try writeFile(dir + "/etc/other.conf", "nothing here\n")
        try writeFile(dir + "/node_modules/nginx.conf", "skipped")
        try writeFile(dir + "/logs/nginx/access.log", "proxy_pass in a log\n")

        let names = try await FindFiles.searchLocal(.init(dir: dir, pattern: "nginx"))
        #expect(Set(names.results.map(\.path)) == [dir + "/etc/nginx.conf", dir + "/logs/nginx"], "node_modules is not walked")
        #expect(names.results.first { $0.name == "nginx" }?.type == .directory)
        #expect(!names.truncated && names.stopped == nil)

        let content = try await FindFiles.searchLocal(.init(dir: dir, pattern: "*.conf", content: "PROXY_PASS"))
        #expect(content.results.count == 1)
        #expect(content.results[0].line == 2 && content.results[0].excerpt == "proxy_pass http://x;")

        let files = try await FindFiles.searchLocal(.init(dir: dir, pattern: "nginx", kinds: "dirs"))
        #expect(files.results.map(\.name) == ["nginx"])

        var o = FindFiles.Options(dir: dir, pattern: "zzz")
        o.maxEntries = 2
        let stopped = try await FindFiles.searchLocal(o)
        #expect(stopped.stopped == "entries" && stopped.truncated, "it says why it stopped")

        await #expect(throws: AppError.self) { try await FindFiles.searchLocal(.init(dir: "")) }
    }

    @Test func remoteCommands() throws {
        let name = try FindFiles.remoteCommand(.init(dir: "/var/log", pattern: "sys"))
        #expect(name == "find '/var/log' -maxdepth 6 -iname '*sys*' -printf '%y\\t%s\\t%T@\\t%p\\n' 2>/dev/null | head -n 400")
        let grep = try FindFiles.remoteCommand(.init(dir: "/etc", pattern: "*.conf", content: "it's", caseSensitive: true))
        #expect(grep == "grep -rIn --include='*.conf' -e 'it'\\''s' -- '/etc' 2>/dev/null | head -n 400")
        let plain = FindFiles.remoteCommandPlain(.init(dir: "/", pattern: "x", kinds: "files", limit: 10))
        #expect(plain == "find '/' -maxdepth 6 -type f -iname '*x*' -print 2>/dev/null | head -n 10")
    }

    @Test func parsingTheThreeShapes() {
        let printf = FindFiles.parseRemote("d\t4096\t1700000000.5\t/etc/nginx\nf\t12\t1700000000\t/etc/a b.conf\r\n")
        #expect(printf.results.map(\.path) == ["/etc/nginx", "/etc/a b.conf"])
        #expect(printf.results[0].type == .directory && printf.results[1].size == 12)
        #expect(printf.results[0].mtime == 1_700_000_000_500)
        let grep = FindFiles.parseRemote("/etc/x.conf:12:  listen 80;\nnot a match\n", content: "listen")
        #expect(grep.results.count == 1 && grep.results[0].line == 12 && grep.results[0].excerpt == "listen 80;")
        let plain = FindFiles.parseRemote("/a/b\n/c\n", limit: 2)
        #expect(plain.results.map(\.name) == ["b", "c"] && plain.truncated)
    }
}

/// Ported from tests/rsync.test.mjs: building an rsync command. rsync's two
/// famous foot-guns are both in it: a trailing slash means something, and
/// `--delete` means it permanently.
@Suite struct RsyncTests {
    let local = Rsync.Side(kind: "local", label: "this machine")
    let remote = Rsync.Side(kind: "remote", label: "web-1", target: "ubuntu@web-1.lab")
    let modern = Rsync.Features(infoProgress: true, protectArgs: true)

    @Test func trailingSlash() {
        #expect(Rsync.endpoint(local, "/Users/me/site", contents: true) == "/Users/me/site/")
        #expect(Rsync.endpoint(local, "/Users/me/site", contents: false) == "/Users/me/site")
        #expect(Rsync.endpoint(local, "/Users/me/site///", contents: true) == "/Users/me/site/")
        #expect(Rsync.endpoint(local, "/Users/me/site/", contents: false) == "/Users/me/site")
        #expect(Rsync.endpoint(remote, "/srv/app", contents: true) == "ubuntu@web-1.lab:/srv/app/")
        #expect(Rsync.endpoint(remote, "/srv/app", contents: false) == "ubuntu@web-1.lab:/srv/app")
    }

    @Test func safeDefaults() {
        let args = Rsync.buildArgs(.init(from: "/a/", to: "/b", features: modern))
        #expect(args.contains("-n"), "nothing moves until asked twice")
        #expect(args.contains("-a") && args.contains("-z"))
        #expect(!args.contains("--delete") && !args.contains("-c"))
        #expect(Array(args.suffix(2)) == ["/a/", "/b"])
        #expect(Rsync.buildArgs(.init(from: "/a/", to: "/b", del: true, features: modern)).contains("--delete"))
        let dry = Rsync.buildArgs(.init(from: "/a/", to: "/b", dryRun: true, features: modern))
        let real = Rsync.buildArgs(.init(from: "/a/", to: "/b", dryRun: false, features: modern))
        #expect(real == dry.filter { $0 != "-n" }, "what you approved is what runs")
    }

    @Test func oldRsyncGetsAPlainerCommand() {
        let old = Rsync.buildArgs(.init(from: "/a/", to: "/b"))
        #expect(old.contains("--progress"))
        #expect(!old.contains { $0.hasPrefix("--info=") } && !old.contains("-s"))
        #expect(Rsync.Features.of(Rsync.parseVersion("openrsync: protocol version 29\nrsync version 2.6.9 compatible\n"))
                == .init(infoProgress: false, protectArgs: false))
        #expect(Rsync.Features.of(Rsync.parseVersion("rsync  version 3.3.0  protocol version 31\n")) == modern)
        #expect(Rsync.Features.of(Rsync.parseVersion("rsync  version 3.0.9  protocol version 30\n")).infoProgress == false)
    }

    @Test func excludesExtraAndShell() {
        let args = Rsync.buildArgs(.init(from: "/a/", to: "/b", excludes: [".git", "  ", "node_modules", ""],
                                         extra: "  --bwlimit=8M   --partial ", features: modern))
        let ex = args.indices.filter { $0 > 0 && args[$0 - 1] == "--exclude" }.map { args[$0] }
        #expect(ex == [".git", "node_modules"])
        #expect(args.contains("--bwlimit=8M") && args.contains("--partial") && !args.contains(""))
        let shell = "ssh -F /tmp/cfg -o IdentitiesOnly=yes -o ControlPath=/tmp/c-1 -o ControlMaster=no"
        let withShell = Rsync.buildArgs(.init(from: "/a/", to: "ubuntu@web-1:/b", features: modern, shellArg: shell))
        let i = try! #require(withShell.firstIndex(of: "-e"))
        #expect(withShell[i + 1] == shell, "one argv entry: nothing needs quoting")
    }

    @Test func commandLineShowsSpaces() {
        let line = Rsync.commandLine(Rsync.buildArgs(.init(from: "/a b/", to: "/c", features: modern)))
        #expect(line.hasPrefix("rsync "))
        #expect(line.contains("\"/a b/\""))
        #expect(line.hasSuffix(" /c"))
    }

    @Test func explanationsAndDiscovery() async {
        #expect(Rsync.explain(0) == "Finished.")
        #expect(Rsync.explain(23) == "rsync exited 23: some files could not be transferred — check the errors above")
        #expect(Rsync.explain(99) == "rsync exited 99.")
        #expect(Rsync.unsupportedReason() == "", "macOS is allowed to try")
        // Homebrew's ahead of the system's, and PATH counts too.
        let dir = try! scratchDir("rsyncbin"); defer { cleanup(dir) }
        try! writeFile(dir + "/rsync", "#!/bin/sh\necho 'rsync  version 3.3.0  protocol version 31'\n")
        chmod(dir + "/rsync", 0o755)
        #expect(Rsync.find(searchPath: dir, candidates: [], useCache: false) == dir + "/rsync")
        #expect(Rsync.find(searchPath: dir, candidates: ["/usr/bin/rsync"], useCache: false) == "/usr/bin/rsync")
        let v = await Rsync.versionOf(dir + "/rsync")
        #expect(v?.major == 3 && v?.minor == 3 && v?.openrsync == false)
    }

    @Test func runStreamsAndCanBeCancelled() async throws {
        guard Rsync.find() != nil else { return }
        let dir = try scratchDir("rsyncrun"); defer { cleanup(dir) }
        try writeFile(dir + "/a/x.txt", "x")
        let out = PhaseLog()
        let done: Rsync.Done = await withCheckedContinuation { cont in
            _ = try? Rsync.run(id: "t1", args: ["-a", dir + "/a/", dir + "/b"],
                               onOut: { out.add($0.stream + ":" + $0.text) }, onDone: { cont.resume(returning: $0) })
        }
        #expect(done.code == 0 && done.message == "Finished.")
        #expect(out.all.first??.hasPrefix("sys:$ ") == true)
        #expect(readData(dir + "/b/x.txt") == Data("x".utf8))
        #expect(!Rsync.cancel("nope"))
    }
}

@Suite struct FileKindsTests {
    @Test func kinds() {
        #expect(FileKinds.extOf("a/b/App.JS") == "js")
        #expect(FileKinds.extOf(".bashrc") == "")
        #expect(FileKinds.extOf("syslog.1") == "")
        #expect(FileKinds.extOf("app.log.3") == "log")
        #expect(FileKinds.extOf("x.averyveryverylongext") == "")
        #expect(FileKinds.kindOf("main.swift") == "code")
        #expect(FileKinds.kindOf("Cargo.lock") == "config")
        #expect(FileKinds.kindOf("id_rsa.pub") == "secrets")
        #expect(FileKinds.kindOf("README") == "other")
    }
}
