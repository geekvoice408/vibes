import Darwin
import Foundation

/// `ServerLife --mcp`: ServerLife as an MCP server (mcp/serverlife-mcp.mjs).
///
/// MCP clients — Claude Code and the rest — spawn a server and speak JSON-RPC
/// over stdio. ServerLife is a GUI process that is already running, so this is
/// a bridge rather than a server proper: it forwards each tool call to the
/// app's local control socket and hands back the answer. It is the same
/// binary, run with `--mcp`, so registering it needs no Node and no second
/// install — and it never starts NSApplication or touches the app's state.
///
/// Nothing here decides what is allowed. The app does: the socket is off
/// until the user turns it on, the token is theirs, and the verb list is
/// fixed. This only translates.
///
///     claude mcp add serverlife -- "/Applications/ServerLife.app/Contents/MacOS/ServerLife" --mcp
///
/// The protocol is implemented by hand — initialize, tools/list, tools/call
/// is the whole of it.
enum MCPBridge {
    static let protocolVersion = "2024-11-05"

    // MARK: finding the app

    /// Where the app keeps its settings (and the token): `SERVERLIFE_USER_DATA`,
    /// else `--data-dir`, else `~/Library/Application Support/ServerLife-Swift`.
    static func userDataDir(env: [String: String] = ProcessInfo.processInfo.environment,
                            args: [String] = CommandLine.arguments) -> String {
        if let d = env["SERVERLIFE_USER_DATA"]?.nilIfEmpty { return d }
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]).path }
        return NSHomeDirectory() + "/Library/Application Support/ServerLife-Swift"
    }

    static func socketPath(_ dir: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        env["SERVERLIFE_SOCKET"]?.nilIfEmpty ?? ControlServer.socketPath(for: dir)
    }

    static func readToken(_ dir: String, env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let t = env["SERVERLIFE_TOKEN"]?.nilIfEmpty { return t.trimmed }
        guard let t = try? String(contentsOfFile: ControlServer.tokenFile(for: dir), encoding: .utf8) else {
            throw AppError("ServerLife has no control token yet. Turn on Settings → Local automation in the app.")
        }
        return t.trimmed
    }

    // MARK: talking to the app

    /// One request, one connection. Reconnecting per call costs nothing on a
    /// local socket and means a restarted app (or one started after this
    /// bridge) is picked up without the client restarting anything.
    static func callApp(_ verb: String, _ params: JSON, dir: String? = nil, timeout: Double = 300) throws -> JSON {
        let d = dir ?? userDataDir()
        let token = try readToken(d)
        let path = socketPath(d)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError("Could not reach ServerLife: socket \(errnoName(errno))") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw AppError("Could not reach ServerLife: connect ENAMETOOLONG \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            let e = errno
            if e == ENOENT || e == ECONNREFUSED {
                throw AppError("ServerLife is not listening. Is the app running, with Settings → Local automation turned on?")
            }
            throw AppError("Could not reach ServerLife: connect \(errnoName(e)) \(path)")
        }

        let req: JSON = ["token": .string(token), "client": "mcp", "id": 1, "verb": .string(verb),
                         "params": params.object != nil ? params : .object([:])]
        var out = Data(req.jsText().utf8)
        out.append(0x0a)
        let sent = out.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        if !sent { throw AppError("Could not reach ServerLife: write \(errnoName(errno))") }

        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buf.firstIndex(of: 0x0a) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw AppError("ServerLife did not answer in time.") }
            if n < 0 { throw AppError("Could not reach ServerLife: read \(errnoName(errno))") }
            if n == 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard let nl = buf.firstIndex(of: 0x0a), let res = try? JSON.parse(Data(buf[..<nl])) else {
            throw AppError("Unreadable reply from ServerLife.")
        }
        if res["ok"].bool == true { return res["data"] }
        throw AppError(res["error"].string?.nilIfEmpty ?? "ServerLife refused the request.")
    }

    // MARK: JSON-RPC over stdio

    private static let writeLock = NSLock()

    static func write(_ msg: JSON) {
        var d = Data(msg.jsText().utf8)
        d.append(0x0a)
        writeLock.lock()
        FileHandle.standardOutput.write(d)
        writeLock.unlock()
    }

    static func result(_ id: JSON, _ value: JSON) { write(["jsonrpc": "2.0", "id": id, "result": value]) }

    static func failure(_ id: JSON, _ code: Int, _ message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    /// The answer to one message, or nil for a notification (no id, no answer).
    /// `call` reaches the app; tests pass their own.
    static func respond(_ msg: JSON, call: (String, JSON) throws -> JSON = { try callApp($0, $1) }) -> JSON? {
        let id = msg["id"]
        // Notifications carry no id and expect no answer.
        if id.isNull { return nil }
        func ok(_ v: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": v] }
        func err(_ code: Int, _ m: String) -> JSON {
            ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(m)]]
        }
        switch msg["method"].string ?? "" {
        case "initialize":
            return ok([
                "protocolVersion": .string(protocolVersion),
                "capabilities": ["tools": .object([:])],
                "serverInfo": ["name": "serverlife", "version": "1.0.0"],
                "instructions": .string("Drives a running ServerLife window: list hosts and beams, open sessions (singly "
                    + "or as a set), synchronise folders with a server or a beam, manage layouts, read Teleport "
                    + "cluster state and run the user's saved macros. "
                    + "The app must be running with Settings → Local automation turned on."),
            ])
        case "ping":
            return ok(.object([:]))
        case "tools/list":
            return ok(["tools": .array(MCPTools.all.map { ["name": .string($0.name), "description": .string($0.description),
                                                            "inputSchema": $0.inputSchema] })])
        case "tools/call":
            let name = msg["params"]["name"].string
            guard let tool = MCPTools.all.first(where: { $0.name == name }) else {
                return err(-32602, "Unknown tool \"\(name ?? "undefined")\"")
            }
            do {
                let args = msg["params"]["arguments"]
                let data = try call(tool.verb, args.object != nil ? args : .object([:]))
                return ok(["content": [["type": "text", "text": .string(data.jsText(indent: 2))]]])
            } catch {
                // A tool that failed is a result, not a protocol error: the
                // model should see the reason and be able to act on it.
                return ok(["isError": true, "content": [["type": "text", "text": .string((error as? AppError)?.message ?? error.localizedDescription)]]])
            }
        case "resources/list":
            return ok(["resources": []])
        case "prompts/list":
            return ok(["prompts": []])
        default:
            return err(-32601, "Method not found: \(msg["method"].string ?? "undefined")")
        }
    }

    /// Read stdin line by line until it closes; each message is answered on
    /// its own queue so a slow call never holds up a ping.
    static func runStdio() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let queue = DispatchQueue(label: "mcp.calls", attributes: .concurrent)
        let pending = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            let text = line.trimmed
            if text.isEmpty { continue }
            guard let msg = try? JSON.parse(text) else {
                failure(.null, -32700, "Parse error")
                continue
            }
            // `null` is the one value the original could not take apart.
            if msg.isNull {
                failure(.null, -32603, "Cannot destructure property 'id' of 'msg' as it is null.")
                continue
            }
            if msg.object == nil { continue }
            pending.enter()
            queue.async {
                if let answer = respond(msg) { write(answer) }
                pending.leave()
            }
        }
        // stdin closed: answer what was asked before going.
        pending.wait()
        exit(0)
    }

    /// Node's error code for an errno ("EACCES"), as its messages carry them.
    static func errnoName(_ e: Int32) -> String {
        let names: [Int32: String] = [
            EPERM: "EPERM", ENOENT: "ENOENT", EINTR: "EINTR", EIO: "EIO", EBADF: "EBADF", EAGAIN: "EAGAIN",
            ENOMEM: "ENOMEM", EACCES: "EACCES", EFAULT: "EFAULT", ENOTDIR: "ENOTDIR", EINVAL: "EINVAL",
            EMFILE: "EMFILE", ENFILE: "ENFILE", EPIPE: "EPIPE", ENOTSOCK: "ENOTSOCK", EPROTOTYPE: "EPROTOTYPE",
            EADDRINUSE: "EADDRINUSE", EADDRNOTAVAIL: "EADDRNOTAVAIL", ENETDOWN: "ENETDOWN", ECONNABORTED: "ECONNABORTED",
            ECONNRESET: "ECONNRESET", ENOBUFS: "ENOBUFS", ENOTCONN: "ENOTCONN", ETIMEDOUT: "ETIMEDOUT",
            ECONNREFUSED: "ECONNREFUSED", ELOOP: "ELOOP", ENAMETOOLONG: "ENAMETOOLONG", EHOSTUNREACH: "EHOSTUNREACH",
        ]
        return names[e] ?? "E\(e)"
    }
}
