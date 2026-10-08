import Foundation

/// One beam: an ephemeral sandbox VM as `tsh beams` exposes it.
struct Beam: Codable, Hashable, Identifiable, Sendable {
    /// The beam's name (what `beams ssh/exec/rm` take).
    var id: String
    var uuid: String
    var owner: String
    var region: String
    /// What was asked for, when the service put it somewhere else ("" otherwise).
    var requestedRegion: String
    var url: String
    /// ms since the epoch, for a countdown.
    var expires: Double?
    var proxy: String
    var home: String?
}

/// Whether a cluster runs the beams service (the `beams ls` probe).
struct BeamSupport: Sendable, Hashable {
    var ok: Bool
    var error: String?
    /// The signature of a cluster that simply does not run the service.
    var unsupported = false
}

/// The port of src/main/beams.js and the main.js `beams:*` handlers.
///
/// Not every cluster has the service; `beams ls` answering at all is the
/// capability probe, remembered per (home, proxy) because whether the service
/// exists does not change between two clicks (`supported(refresh: true)` asks again).
enum Beams {
    /// Global tsh flags that have to precede the subcommand.
    static func base(proxy: String?, jumphost: String? = nil) -> [String] {
        var a: [String] = []
        if let p = proxy?.nilIfEmpty { a.append("--proxy=" + p) }
        if let j = jumphost?.nilIfEmpty { a.append("--jumphost=" + j) }
        return a
    }

    /// `tsh … beams <sub> …`.
    static func argsFor(_ sub: String, _ rest: [String] = [], proxy: String?, jumphost: String? = nil) -> [String] {
        base(proxy: proxy, jumphost: jumphost) + ["beams", sub] + rest
    }

    private static func run(_ args: [String], home: String?, timeout: TimeInterval = 60) async -> ProcResult {
        await Teleport.run(args, home: home, timeout: timeout)
    }

    /// `toBeam`.
    static func toBeam(_ b: JSON, proxy: String?, home: String?) -> Beam {
        let region = b["region"].stringish ?? ""
        let req = b["requested_region"].stringish ?? ""
        return Beam(id: b["id"].stringish ?? "", uuid: b["uuid"].stringish ?? "", owner: b["owner"].stringish ?? "",
                    region: region, requestedRegion: !req.isEmpty && req != region ? req : "",
                    url: b["url"].stringish ?? "", expires: TPText.parseDate(b["expires"].string),
                    proxy: proxy ?? "", home: home?.nilIfEmpty)
    }

    private static let supportCache = TPLocked<[String: BeamSupport]>([:])

    /// `beams:supported`: the probe, cached per home|proxy.
    static func supported(proxy: String?, home: String?, refresh: Bool = false) async -> BeamSupport {
        let key = "\(home ?? "")|\(proxy ?? "")"
        if !refresh {
            if let hit = supportCache.get()[key] { return hit }
        }
        let r = await probe(proxy: proxy, home: home)
        supportCache.mutate { $0[key] = r }
        return r
    }

    /// The uncached probe (beams.js `supported`).
    static func probe(proxy: String?, home: String?) async -> BeamSupport {
        let r = await run(argsFor("ls", ["--format=json"], proxy: proxy), home: home, timeout: 45)
        let out = TPText.plain(r.out)
        if r.ok && (out.hasPrefix("[") || out.hasPrefix("{")) { return BeamSupport(ok: true) }
        var error = TPText.plain(r.err)
        if error.isEmpty { error = out.isEmpty ? (r.spawnError ?? "tsh beams ls said nothing") : out }
        return BeamSupport(ok: false, error: error,
                           unsupported: TPText.test(#"unknown service teleport\.beams|not implement this feature"#, error, .caseInsensitive))
    }

    /// `beams:list`. `all` lists everyone's beams, not just yours.
    static func list(proxy: String?, home: String?, all: Bool = false) async -> TshList<Beam> {
        var rest = ["--format=json"]
        if all { rest.append("--all") }
        let r = await run(argsFor("ls", rest, proxy: proxy), home: home, timeout: 45)
        let out = TPText.plain(r.out)
        if let beams = parseList(out, proxy: proxy, home: home) { return TshList(ok: true, error: nil, items: beams) }
        let e = TPText.plain(r.err)
        return .failed(!e.isEmpty ? e : (!out.isEmpty ? out : "Could not read the beam list"))
    }

    static func parseList(_ out: String, proxy: String?, home: String?) -> [Beam]? {
        guard let at = out.firstIndex(of: "["), let data = try? JSON.parse(String(out[at...])), let arr = data.array
        else { return nil }
        return arr.map { toBeam($0, proxy: proxy, home: home) }
    }

    /// `beams:add`: start a beam (never with `--console`; the app opens the
    /// session itself). Creating a VM is not instant: 5 minutes.
    static func add(proxy: String?, home: String?, region: String? = nil) async -> (ok: Bool, beam: Beam?, error: String?) {
        var rest = ["--format=json"]
        if let r = region?.nilIfEmpty { rest.append("--region=" + r) }
        let r = await run(argsFor("add", rest, proxy: proxy), home: home, timeout: 300)
        let out = TPText.plain(r.out)
        if let at = out.firstIndex(of: "{"), let j = try? JSON.parse(String(out[at...])), j.object != nil {
            return (true, toBeam(j, proxy: proxy, home: home), nil)
        }
        let e = TPText.plain(r.err)
        return (false, nil, !e.isEmpty ? e : (!out.isEmpty ? out : "tsh beams add returned nothing to read"))
    }

    struct RemoveResult: Sendable { var ok: Bool; var output: String; var attempts: Int; var gone = false }

    /// `beams:remove`: delete, retrying the optimistic-concurrency race
    /// ("condition failed … reload the current state and try again") up to
    /// three times; "does not exist" counts as done.
    static func remove(name: String, proxy: String?, home: String?) async throws -> RemoveResult {
        if name.isEmpty { throw AppError("Which beam?") }
        let retryable = #"condition failed|reload the current state|try again"#
        var last: RemoveResult?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(700_000_000 * attempt)) }
            let r = await run(argsFor("rm", [name], proxy: proxy), home: home, timeout: 120)
            let output = TPText.plain(r.out + "\n" + r.err)
            if r.ok { return RemoveResult(ok: true, output: output, attempts: attempt + 1) }
            last = RemoveResult(ok: false, output: output, attempts: attempt + 1)
            if TPText.test("does not exist", output, .caseInsensitive) {
                return RemoveResult(ok: true, output: output, attempts: attempt + 1, gone: true)
            }
            if !TPText.test(retryable, output, .caseInsensitive) { break }
        }
        return last ?? RemoveResult(ok: false, output: "tsh beams rm said nothing", attempts: 0)
    }

    /// `beams:stillListed`: whether `ls` still shows it; nil when it cannot tell.
    static func stillListed(name: String, proxy: String?, home: String?) async -> Bool? {
        let r = await list(proxy: proxy, home: home)
        if !r.ok { return nil }
        return r.items.contains { $0.id == name || $0.uuid == name }
    }

    /// `beams:exec`: one command, output captured.
    static func exec(name: String, proxy: String?, home: String?, command: String,
                     timeout: TimeInterval = 120) async throws -> (ok: Bool, output: String, error: String) {
        if name.isEmpty { throw AppError("Which beam?") }
        if command.isEmpty { throw AppError("No command") }
        let r = await run(argsFor("exec", [name, "--", command], proxy: proxy), home: home, timeout: timeout)
        return (r.ok, TPText.plain(r.out), TPText.plain(r.err.isEmpty ? (r.spawnError ?? "") : r.err))
    }

    /// `beams:publish`: expose a service in the beam (HTTP, or TCP with `tcp`),
    /// capturing the address it printed.
    static func publish(name: String, proxy: String?, home: String?, tcp: Bool = false) async throws -> (ok: Bool, output: String, url: String) {
        if name.isEmpty { throw AppError("Which beam?") }
        var rest: [String] = []
        if tcp { rest.append("--tcp") }
        rest.append(name)
        let r = await run(argsFor("publish", rest, proxy: proxy), home: home, timeout: 120)
        let text = TPText.plain(r.out + "\n" + r.err)
        return (r.ok, text, publishedAddress(text))
    }

    /// Whatever the publish output says looks like where the service now lives.
    static func publishedAddress(_ text: String) -> String {
        if let m = TPText.match(#"https?://\S+"#, text), let u = m[0] { return u }
        if let m = TPText.match(#"\b[\w.-]+\.[a-z]{2,}(?::\d+)?\b"#, text, .caseInsensitive), let u = m[0] { return u }
        return ""
    }

    static func unpublish(name: String, proxy: String?, home: String?) async throws -> TshOutput {
        if name.isEmpty { throw AppError("Which beam?") }
        let r = await run(argsFor("unpublish", [name], proxy: proxy), home: home, timeout: 120)
        return TshOutput(ok: r.ok, output: TPText.plain(r.out + "\n" + r.err))
    }

    /// `beams:scp`: `beam:path` on the beam side, as tsh spells it.
    static func scp(src: String, dest: String, proxy: String?, home: String?, recursive: Bool = false,
                    quiet: Bool = true) async throws -> TshOutput {
        if src.isEmpty || dest.isEmpty { throw AppError("scp needs a source and a destination") }
        var rest: [String] = []
        if recursive { rest.append("--recursive") }
        if quiet { rest.append("--quiet") }
        rest += [src, dest]
        let r = await run(argsFor("scp", rest, proxy: proxy), home: home, timeout: 600)
        return TshOutput(ok: r.ok, output: TPText.plain(r.out + "\n" + r.err))
    }

    // MARK: - Transport argv (for the connection layer)

    /// `sshArgs`: a terminal in a beam — the name and nothing else.
    static func sshArgs(name: String, proxy: String?, jumphost: String? = nil, extra: [String] = []) -> [String] {
        argsFor("ssh", [], proxy: proxy, jumphost: jumphost) + extra + [name]
    }

    /// `execArgs`: a command in a beam, which is how SFTP gets a channel.
    static func execArgs(name: String, proxy: String?, jumphost: String? = nil, command: String? = nil) -> [String] {
        var rest = [name]
        if let c = command?.nilIfEmpty { rest += ["--", c] }
        return argsFor("exec", rest, proxy: proxy, jumphost: jumphost)
    }

    /// renderer `expiresIn`: "45m left", "3h 12m left", "1d 2h left", "expired".
    static func expiresIn(_ beam: Beam, now: Double = nowMs()) -> String {
        guard let e = beam.expires else { return "" }
        let ms = e - now
        if ms <= 0 { return "expired" }
        let mins = Int((ms / 60000).rounded())
        if mins < 60 { return "\(mins)m left" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h \(mins % 60)m left" }
        return "\(hours / 24)d \(hours % 24)h left"
    }
}
