import Darwin
import Foundation
import Testing
@testable import ServerLife

/// A throwaway settings directory with a control server on it.
private func withServer(_ body: (ControlServer, String) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-ctl-\(UUID().uuidString.prefix(8))").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let server = ControlServer(dir: dir, handle: { verb, params, client in
        if verb == "boom" { throw AppError("it broke") }
        return ["verb": .string(verb), "params": params, "client": .string(client)]
    }, onLog: { _, _ in })
    try server.start()
    defer { server.stop() }
    try body(server, dir)
}

/// Send lines on one connection and read `count` reply lines.
private func exchange(_ path: String, _ lines: [String], count: Int) throws -> [JSON] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { throw AppError("connect failed") }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let out = Array((lines.joined(separator: "\n") + "\n").utf8)
    _ = out.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while buf.filter({ $0 == 0x0a }).count < count {
        let n = recv(fd, &chunk, chunk.count, 0)
        if n <= 0 { break }
        buf.append(contentsOf: chunk[0..<n])
    }
    return String(decoding: buf, as: UTF8.self).split(separator: "\n").map { JSON.tryParse(String($0)) }
}

@Suite(.serialized) struct ControlServerTests {
    @Test func socketAndTokenFiles() throws {
        try withServer { server, dir in
            let path = server.socketPath
            #expect(path == ControlServer.socketPath(for: dir))
            #expect((path as NSString).lastPathComponent.hasPrefix("serverlife-"))
            var st = stat()
            #expect(lstat(path, &st) == 0)
            #expect(st.st_mode & 0o777 == 0o600)
            #expect(stat(server.tokenFile, &st) == 0)
            #expect(st.st_mode & 0o777 == 0o600)
            let token = try String(contentsOfFile: server.tokenFile, encoding: .utf8).trimmed
            #expect(token.count == 64)
            #expect(server.info["running"].bool == true)
        }
    }

    @Test func authAndVerbs() throws {
        try withServer { server, _ in
            let token = server.token ?? ""
            let r = try exchange(server.socketPath, [
                #"{"token":"\#(token)"}"#,
                #"{"id":7,"verb":"list_hosts","params":{"query":"db"},"client":"t"}"#,
                "not json",
                #"{"id":"x","verb":"boom"}"#,
            ], count: 4)
            #expect(r.count == 4)
            #expect(r[0]["ok"].bool == true && r[0]["data"]["hello"].bool == true && r[0]["id"].isNull)
            #expect(r[1]["id"].int == 7 && r[1]["data"]["verb"].string == "list_hosts")
            #expect(r[1]["data"]["params"]["query"].string == "db" && r[1]["data"]["client"].string == "t")
            #expect(r[2]["ok"].bool == false && r[2]["error"].string == "malformed JSON")
            #expect(r[3]["ok"].bool == false && r[3]["id"].string == "x" && r[3]["error"].string == "it broke")
        }
    }

    @Test func tokenAndVerbOnOneLine() throws {
        try withServer { server, _ in
            let r = try exchange(server.socketPath, [#"{"token":"\#(server.token ?? "")","verb":"status"}"#], count: 1)
            #expect(r.first?["data"]["verb"].string == "status")
            #expect(r.first?["data"]["client"].string == "unknown")
        }
    }

    @Test func badTokenEndsTheConversation() throws {
        try withServer { server, _ in
            let r = try exchange(server.socketPath, [#"{"token":"nope","verb":"status"}"#, #"{"verb":"status"}"#], count: 2)
            #expect(r.count == 1)
            #expect(r[0]["ok"].bool == false && r[0]["error"].string == "unauthorized")
        }
    }

    @Test func rotatingRevokes() throws {
        try withServer { server, _ in
            let old = server.token ?? ""
            let new = try server.rotateToken()
            #expect(new != old && new.count == 64)
            let r = try exchange(server.socketPath, [#"{"token":"\#(old)","verb":"status"}"#], count: 1)
            #expect(r.first?["error"].string == "unauthorized")
            let ok = try exchange(server.socketPath, [#"{"token":"\#(new)","verb":"status"}"#], count: 1)
            #expect(ok.first?["ok"].bool == true)
        }
    }

    @Test func stopRemovesTheSocket() throws {
        var path = ""
        try withServer { server, _ in path = server.socketPath }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func safeEqual() {
        #expect(ControlServer.safeEqual("abc", "abc"))
        #expect(!ControlServer.safeEqual("abc", "abd"))
        #expect(!ControlServer.safeEqual("abc", "abcd"))
    }
}

@Suite(.serialized) struct MCPBridgeTests {
    @Test func initializeAndList() {
        let i = MCPBridge.respond(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])!
        #expect(i["result"]["protocolVersion"].string == "2024-11-05")
        #expect(i["result"]["serverInfo"]["name"].string == "serverlife")
        #expect(i["result"]["capabilities"]["tools"].object != nil)
        let l = MCPBridge.respond(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])!
        let tools = l["result"]["tools"].items
        #expect(tools.count == 21)
        #expect(l["id"].string == "a")
        let names = tools.compactMap { $0["name"].string }
        #expect(names.first == "serverlife_status" && names.last == "serverlife_run_macro")
        let open = tools.first { $0["name"].string == "serverlife_open_session" }!
        #expect(open["inputSchema"]["required"].stringArray == ["host"])
        #expect(open["inputSchema"]["properties"]["split"]["enum"].stringArray == ["right", "down"])
        #expect(open["inputSchema"]["properties"]["tmux"]["description"].string?.contains("host\u{2019}s own setting") == true)
        // Every tool forwards to a verb the app knows.
        let verbs = Set(ControlVerbs.mainVerbs.union(AutomationWindow.verbs))
        #expect(MCPTools.all.allSatisfy { verbs.contains($0.verb) })
    }

    @Test func callsAndErrors() {
        var seen: (String, JSON)?
        let ok = MCPBridge.respond(["id": 2, "method": "tools/call",
                                    "params": ["name": "serverlife_list_hosts", "arguments": ["query": "db"]]]) { verb, params in
            seen = (verb, params)
            return ["count": 0]
        }!
        #expect(seen?.0 == "list_hosts" && seen?.1["query"].string == "db")
        #expect(ok["result"]["content"][0]["type"].string == "text")
        #expect(JSON.tryParse(ok["result"]["content"][0]["text"].string ?? "")["count"].int == 0)

        let failed = MCPBridge.respond(["id": 3, "method": "tools/call", "params": ["name": "serverlife_status"]]) { _, _ in
            throw AppError("ServerLife is not listening.")
        }!
        #expect(failed["result"]["isError"].bool == true)
        #expect(failed["result"]["content"][0]["text"].string == "ServerLife is not listening.")

        let unknown = MCPBridge.respond(["id": 4, "method": "tools/call", "params": ["name": "nope"]])!
        #expect(unknown["error"]["code"].int == -32602 && unknown["error"]["message"].string == "Unknown tool \"nope\"")
        #expect(MCPBridge.respond(["id": 5, "method": "bogus"])!["error"]["code"].int == -32601)
        #expect(MCPBridge.respond(["id": 6, "method": "ping"])!["result"].object?.isEmpty == true)
        #expect(MCPBridge.respond(["id": 7, "method": "resources/list"])!["result"]["resources"].array?.isEmpty == true)
        #expect(MCPBridge.respond(["id": 8, "method": "prompts/list"])!["result"]["prompts"].array?.isEmpty == true)
        // A notification has no id and gets no answer.
        #expect(MCPBridge.respond(["method": "notifications/initialized"]) == nil)
    }

    @Test func discovery() {
        #expect(MCPBridge.userDataDir(env: ["SERVERLIFE_USER_DATA": "/x"], args: []) == "/x")
        #expect(MCPBridge.userDataDir(env: [:], args: ["ServerLife", "--mcp", "--data-dir", "/tmp/sl"]) == "/tmp/sl")
        #expect(MCPBridge.userDataDir(env: [:], args: []).hasSuffix("/Library/Application Support/ServerLife-Swift"))
        #expect(MCPBridge.socketPath("/d", env: ["SERVERLIFE_SOCKET": "/s.sock"]) == "/s.sock")
        #expect(MCPBridge.socketPath("/d", env: [:]) == ControlServer.socketPath(for: "/d"))
    }

    /// The bridge's own client against a real server, through the same files
    /// the app writes.
    @Test func bridgeTalksToServer() throws {
        try withServer { _, dir in
            let data = try MCPBridge.callApp("list_layouts", ["a": 1], dir: dir)
            #expect(data["verb"].string == "list_layouts" && data["client"].string == "mcp" && data["params"]["a"].int == 1)
            #expect(throws: AppError.self) { try MCPBridge.callApp("boom", [:], dir: dir) }
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("sl-none-\(UUID().uuidString.prefix(6))").path
        do { _ = try MCPBridge.callApp("status", [:], dir: missing); Issue.record("should throw") } catch {
            #expect((error as? AppError)?.message == "ServerLife has no control token yet. Turn on Settings → Local automation in the app.")
        }
    }

    /// `ServerLife --mcp` as a process: answers over stdio without starting the app.
    @Test func binaryServesStdio() throws {
        let bin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/ServerLife").path
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        try withServer { _, dir in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--mcp"]
            p.environment = ProcessInfo.processInfo.environment.merging(["SERVERLIFE_USER_DATA": dir]) { $1 }
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            try p.run()
            let msgs = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"serverlife_list_layouts","arguments":{}}}"#,
            ]
            input.fileHandleForWriting.write(Data((msgs.joined(separator: "\n") + "\n").utf8))
            var lines: [JSON] = []
            var buf = Data()
            let deadline = Date().addingTimeInterval(10)
            let fh = output.fileHandleForReading
            while lines.count < 2 && Date() < deadline {
                let d = fh.availableData
                if d.isEmpty { break }
                buf.append(d)
                lines = String(decoding: buf, as: UTF8.self).split(separator: "\n").map { JSON.tryParse(String($0)) }
            }
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            #expect(lines.count == 2)
            let byId = Dictionary(uniqueKeysWithValues: lines.map { ($0["id"].int ?? 0, $0) })
            #expect(byId[1]?["result"]["serverInfo"]["name"].string == "serverlife")
            let text = byId[2]?["result"]["content"][0]["text"].string ?? ""
            #expect(JSON.tryParse(text)["verb"].string == "list_layouts")
            #expect(p.terminationStatus == 0)
        }
    }
}
