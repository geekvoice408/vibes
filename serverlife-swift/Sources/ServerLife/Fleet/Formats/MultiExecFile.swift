import Foundation

/// Saving and loading multi-exec runs as YAML (multiexecfile.js).
///
/// A run that was worth doing once is usually worth doing again. The saved file
/// is the command plus the host list, in a form that is readable, diffable and
/// safe to commit next to the code it operates on.
enum MultiExecFile {
    static let formatVersion = 1

    /// One host as the file records it: the small, stable shape.
    struct Target: Equatable {
        var type: String          // "teleport" | "ssh"
        var name: String?
        var cluster: String?
        var proxy: String?
        var login: String?
        var alias: String?
        var user: String?
        var port: Int?
        /// Not written to the file; carried so a selection can be re-dialled.
        var home: String?
    }

    struct Options: Equatable {
        var concurrency = 10
        /// Milliseconds.
        var timeout = 120_000
        var stopOnError = false
    }

    /// A tag run: a cluster and a query resolved when it runs.
    struct Selector: Equatable {
        var cluster: String?
        var query: String
    }

    /// What `toYaml` writes and `fromYaml` gives back.
    struct Definition: Equatable {
        var name = ""
        var description = ""
        var command = ""
        var options = Options()
        var selector: Selector?
        var targets: [Target] = []
        /// Where it was loaded from (mxfile:load's `path`).
        var path: String?
    }

    /// `target(t)`: normalise a target to the shape the file records.
    static func target(_ t: Target) -> YAMLValue {
        if t.type == "teleport" {
            return stripNulls(.map([("type", "teleport"), ("name", opt(t.name)), ("cluster", opt(t.cluster)),
                                    ("proxy", opt(t.proxy)), ("login", opt(t.login))]))
        }
        return stripNulls(.map([("type", "ssh"), ("alias", opt(t.alias?.nilIfEmpty ?? t.name)),
                                ("user", opt(t.user?.nilIfEmpty ?? t.login)),
                                ("port", t.port.flatMap { $0 == 0 ? nil : YAMLValue.int($0) } ?? .null)]))
    }

    /// `x || null` for an optional string.
    private static func opt(_ s: String?) -> YAMLValue {
        guard let s, !s.isEmpty else { return .null }
        return .string(s)
    }

    static func stripNulls(_ v: YAMLValue) -> YAMLValue {
        switch v {
        case .seq(let a): return .seq(a.map(stripNulls))
        case .map(let m): return .map(m.filter { !$0.1.isNull }.map { ($0.0, stripNulls($0.1)) })
        default: return v
        }
    }

    /// `/\n*$/` → `\n`: exactly one trailing newline, so the block scalar is `|`.
    static func oneTrailingNewline(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") { t.removeLast() }
        return t + "\n"
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Serialise a run definition.
    static func toYaml(name: String?, description: String? = nil, command: String, targets: [Target],
                       options: Options = Options(), selector: Selector? = nil, now: Date = Date()) -> String {
        var doc: [(String, YAMLValue)] = [
            ("version", .int(formatVersion)),
            ("kind", "serverlife.multiexec"),
            ("name", .string(name?.nilIfEmpty ?? "Untitled run")),
            ("description", opt(description)),
            ("created", .string(iso(now))),
            // A trailing newline makes the block scalar render as `|` rather than `|-`.
            ("command", .string(oneTrailingNewline(command))),
            ("options", .map([("concurrency", .int(options.concurrency)),
                              ("timeoutSeconds", .int(Int((Double(options.timeout) / 1000).rounded(.toNearestOrAwayFromZero)))),
                              ("stopOnError", .bool(options.stopOnError))])),
        ]
        /*
         * A tag run saves the question rather than the answer: `selector` is what
         * runs, and `targets` is the set it matched when the file was written —
         * kept so the file still says what it meant to someone reading it later,
         * and ignored on load when a selector is present.
         */
        doc.append(("selector", selector.map { .map([("cluster", opt($0.cluster)), ("query", .string($0.query))]) } ?? .null))
        doc.append(("targets", .seq(targets.map(target))))
        let body = YAMLEmitter.dump(stripNulls(.map(doc)), .init(lineWidth: 100))
        var head = ["# ServerLife multi-exec run", "# Re-open with: Multi-Exec panel -> Load YAML"]
        if selector != nil {
            head += ["#",
                     "# This run selects its hosts by tag, so it runs against whatever matches",
                     "# at the time. The targets below are a snapshot of what matched when it",
                     "# was saved, and are not what will be used."]
        }
        return (head + [body]).joined(separator: "\n")
    }

    /// Parse a run definition, rejecting anything that is not one.
    static func fromYaml(_ text: String) throws -> Definition {
        let doc: YAMLValue
        do { doc = try YAMLReader.load(text) } catch {
            throw AppError("Not valid YAML: " + String(describing: error))
        }
        // typeof doc !== 'object' (an array is an object to JavaScript).
        switch doc {
        case .map, .seq: break
        default: throw AppError("File does not contain a multi-exec run")
        }
        let kind = doc["kind"]
        if kind.truthy && kind.jsString != "serverlife.multiexec" {
            throw AppError("Unexpected kind \"\(kind.jsString)\"")
        }
        guard case .string(let command) = doc["command"], !command.isEmpty else {
            throw AppError("Missing a \"command\" field")
        }
        let sel = doc["selector"]
        let selector: Selector? = sel.isMap
            ? Selector(cluster: sel["cluster"].truthy ? sel["cluster"].jsString : nil,
                       query: sel["query"].truthy ? sel["query"].jsString : "")
            : nil
        let list = doc["targets"].items
        // A selector is a complete definition on its own; a list is only
        // required when there is nothing to resolve.
        if selector == nil && (list == nil || list!.isEmpty) {
            throw AppError("Missing a \"targets\" list")
        }
        var targets: [Target] = []
        for (i, t) in (list ?? []).enumerated() {
            switch t {
            case .map, .seq: break
            default: throw AppError("Target \(i + 1) is not a mapping")
            }
            func s(_ k: String) -> String? { t[k].truthy ? t[k].jsString : nil }
            if t["type"] == .string("teleport") {
                guard let name = s("name") else { throw AppError("Teleport target \(i + 1) needs a \"name\"") }
                targets.append(Target(type: "teleport", name: name, cluster: s("cluster"), proxy: s("proxy"), login: s("login")))
                continue
            }
            guard let alias = s("alias") ?? s("name") else { throw AppError("SSH target \(i + 1) needs an \"alias\"") }
            let pn = t["port"].jsNumber
            let port: Int? = t["port"].truthy && pn.isFinite ? Int(pn) : nil
            targets.append(Target(type: "ssh", alias: alias, user: s("user"), port: port))
        }
        let o = doc["options"]
        let conc = o["concurrency"].jsNumber
        let secs = o["timeoutSeconds"].jsNumber
        var def = Definition()
        def.name = doc["name"].truthy ? doc["name"].jsString : "Untitled run"
        def.description = doc["description"].truthy ? doc["description"].jsString : ""
        def.command = command.hasSuffix("\n") ? String(command.dropLast()) : command
        def.options = Options(concurrency: conc.isFinite && conc != 0 ? Int(conc) : 10,
                              timeout: Int((secs.isFinite && secs != 0 ? secs : 120) * 1000),
                              stopOnError: o["stopOnError"].truthy)
        def.selector = selector
        def.targets = targets
        return def
    }

    /// Serialise the results of a completed run, for a report or an artefact.
    static func resultsToYaml(_ view: MultiExecView, includeOutput: Bool = true) -> String {
        let results = view.results
        func out(_ s: String) -> YAMLValue { includeOutput && !s.isEmpty ? .string(oneTrailingNewline(s)) : .null }
        let doc: YAMLValue = .map([
            ("version", .int(formatVersion)),
            ("kind", "serverlife.multiexec.results"),
            ("command", .string(oneTrailingNewline(view.command))),
            ("startedAt", view.startedAt > 0 ? .string(iso(Date(timeIntervalSince1970: view.startedAt / 1000))) : .null),
            ("endedAt", (view.endedAt ?? 0) > 0 ? .string(iso(Date(timeIntervalSince1970: view.endedAt! / 1000))) : .null),
            ("summary", .map([("total", .int(results.count)),
                              ("succeeded", .int(results.filter { $0.status == "done" }.count)),
                              ("failed", .int(results.filter { ["error", "timeout"].contains($0.status) }.count))])),
            ("results", .seq(results.map { r in
                stripNulls(.map([("host", .string(r.label)), ("status", .string(r.status)),
                                 ("exitCode", r.exitCode.map { .int(Int($0)) } ?? .null),
                                 ("durationMs", r.durationMs.map { .int(Int($0)) } ?? .null),
                                 ("stdout", out(r.stdout)), ("stderr", out(r.stderr))]))
            })),
        ])
        return "# ServerLife multi-exec results\n" + YAMLEmitter.dump(stripNulls(doc), .init(lineWidth: 120))
    }

    /// mxfile:save's file name: the run's name, made safe.
    static func safeFileName(_ name: String?) -> String {
        let base = name?.nilIfEmpty ?? "multiexec"
        guard let re = try? NSRegularExpression(pattern: "[^A-Za-z0-9_.-]+") else { return base }
        let ns = base as NSString
        return re.stringByReplacingMatches(in: base, range: NSRange(location: 0, length: ns.length), withTemplate: "-").lowercased()
    }
}
