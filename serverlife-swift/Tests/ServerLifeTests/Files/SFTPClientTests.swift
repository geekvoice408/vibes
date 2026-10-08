import Foundation
import Testing
@testable import ServerLife

/// The SFTP client against a real sftp-server (this machine's, over a pipe).
@Suite(.serialized) struct SFTPClientTests {
    @Test func handshakeAndRealpath() async throws {
        let dir = try scratchDir("rp"); defer { cleanup(dir) }
        let c = try await localSFTP(startDir: dir)
        defer { c.destroy() }
        #expect(c.version == 3)
        #expect(c.extensions["posix-rename@openssh.com"] != nil)
        #expect(try await c.realpath(".") == realPath(dir))
    }

    @Test func listStatMkdirRenameRemove() async throws {
        let dir = realPath(try scratchDir("ops")); defer { cleanup(dir) }
        try writeFile(dir + "/a.txt", "hello")
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/sub")
        try FileManager.default.createSymbolicLink(atPath: dir + "/dangling", withDestinationPath: dir + "/nope")
        let c = try await localSFTP()
        defer { c.destroy() }

        let entries = try await c.list(dir).sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["a.txt", "dangling", "link", "sub"])
        let a = entries[0]
        #expect(a.type == .file && a.size == 5 && a.path == dir + "/a.txt")
        #expect(a.modeString.hasPrefix("-rw"))
        #expect(a.owner == NSUserName(), "names come from the longname")
        #expect(a.links == 1)
        #expect(a.mtime != nil)
        #expect(entries[3].type == .directory && entries[3].modeString.hasPrefix("d"))
        let link = await c.resolveEntry(entries[2])
        #expect(link.type == .symlink && link.targetType == .directory && link.isDirectoryLike)
        #expect(await c.resolveEntry(entries[1]).targetType == .broken)
        #expect(try await c.readlink(dir + "/link") == dir + "/sub")

        let st = try await c.stat(dir + "/a.txt")
        #expect(st.size == 5 && st.type == .file && st.uid == getuid())
        #expect(try await c.lstat(dir + "/link").type == .symlink)

        try await c.mkdir(dir + "/new")
        #expect(LocalFS.isDir(dir + "/new"))
        try await c.rename(dir + "/new", dir + "/renamed")
        #expect(LocalFS.isDir(dir + "/renamed") && !LocalFS.isDir(dir + "/new"))
        try await c.chmod(dir + "/a.txt", 0o600)
        #expect(LocalFS.stat(dir + "/a.txt")!.mode & 0o777 == 0o600)
        try await c.utimes(dir + "/a.txt", atime: 1_000_000, mtime: 1_500_000_000)
        #expect(LocalFS.stat(dir + "/a.txt")!.mtimeMs == 1_500_000_000_000)

        try await c.remove(dir + "/a.txt")
        #expect(LocalFS.lstat(dir + "/a.txt") == nil)
        try await c.rmdir(dir + "/renamed")

        // Errors read like the original's: the server's text, then the path.
        do {
            _ = try await c.stat(dir + "/missing")
            Issue.record("expected an error")
        } catch let e as SFTPError {
            #expect(e.code == 2)
            #expect(e.description == "No such file: \(dir)/missing")
        }
    }

    @Test func removeTreeAndWholeFiles() async throws {
        let dir = realPath(try scratchDir("tree")); defer { cleanup(dir) }
        try writeFile(dir + "/t/a/b/c.txt", "x")
        try writeFile(dir + "/t/d.txt", "y")
        let c = try await localSFTP()
        defer { c.destroy() }
        var removed: [String] = []
        try await c.removeTree(dir + "/t") { removed.append($0) }
        #expect(!FileManager.default.fileExists(atPath: dir + "/t"))
        #expect(removed.count == 4)

        let text = String(repeating: "line of text ✓\n", count: 10_000)   // > one 32K chunk
        try await c.writeFile(dir + "/w.txt", Data(text.utf8))
        #expect(String(decoding: try await c.readFile(dir + "/w.txt"), as: UTF8.self) == text)
        do {
            _ = try await c.readFile(dir + "/w.txt", maxBytes: 10)
            Issue.record("expected a refusal")
        } catch {
            #expect(errorText(error).hasPrefix("File is too large to preview ("))
        }
    }

    @Test func concurrentRequestsAndClose() async throws {
        let dir = realPath(try scratchDir("conc")); defer { cleanup(dir) }
        for i in 0..<40 { try writeFile(dir + "/f\(i)", String(repeating: "z", count: i)) }
        let c = try await localSFTP()
        let sizes = try await withThrowingTaskGroup(of: (Int, UInt64).self) { g in
            for i in 0..<40 { g.addTask { (i, try await c.stat(dir + "/f\(i)").size ?? 0) } }
            var out: [Int: UInt64] = [:]
            for try await (i, s) in g { out[i] = s }
            return out
        }
        #expect(sizes.count == 40 && sizes.allSatisfy { UInt64($0.key) == $0.value })
        c.destroy()
        #expect(c.closed)
        await #expect(throws: (any Error).self) { try await c.stat(dir) }
    }

    @Test func longnameParsing() {
        #expect(parseLongname("-rw-r--r--    1 ubuntu   ubuntu       220 Jan  6  2022 .bash_logout")! == (1, "ubuntu", "ubuntu"))
        #expect(parseLongname("drwxr-xr-x@ 12 me  staff  384 Mar  4 09:12 x")?.owner == "me")
        #expect(parseLongname("something else entirely here ok") == nil)
        #expect(FileMode.string(0o100644) == "-rw-r--r--")
        #expect(FileMode.string(0o040755) == "drwxr-xr-x")
        #expect(FileMode.string(nil) == "?---------")
        #expect(FileMode.string(0o755, isDir: true, isLink: false) == "drwxr-xr-x")
        #expect(FileMode.type(0o120777) == .symlink)
    }
}
