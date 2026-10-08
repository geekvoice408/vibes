import Foundation

/// One configured ssh_config file (`sshconfig:files`).
struct SSHConfigFile: Codable, Hashable, Sendable {
    var file: String
    /// "~/.ssh/config" for the primary, else the file's basename.
    var label: String
    var primary: Bool
    var exists: Bool
    var size: Int
}

/// A Host entry to write into the managed block (`sshconfig:add`).
struct ManagedSSHHost: Sendable {
    var alias: String
    var hostname: String
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?
    var forwardAgent = false
    /// Extra `Key value` lines, one per line.
    var extraOptions: String?
    /// Write even when the user's own config already defines the alias.
    var force = false
    init(alias: String, hostname: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil,
         proxyJump: String? = nil, forwardAgent: Bool = false, extraOptions: String? = nil, force: Bool = false) {
        self.alias = alias; self.hostname = hostname; self.user = user; self.port = port
        self.identityFile = identityFile; self.proxyJump = proxyJump; self.forwardAgent = forwardAgent
        self.extraOptions = extraOptions; self.force = force
    }
}

/// Host discovery from OpenSSH config, and the app's edits to it: the port of
/// src/main/sshconfig.js.
///
/// Parsing only enumerates candidate aliases; the effective options for each
/// come from `ssh -G` (authoritative: Include, Match, wildcards). Extra config
/// files (settings.sshConfigFiles) are separate roots resolved with `ssh -F`.
///
/// Every function that reads or writes `~/.ssh/config` takes `configPath`,
/// defaulting to the real file, so the writers can be tested on temp files.
enum SSHConfig {
    static let defaultPath = NSHomeDirectory() + "/.ssh/config"
    static let blockStart = "# >>> ServerLife managed hosts >>>"
    static let blockEnd = "# <<< ServerLife managed hosts <<<"
    static let blockNote = "# Edited by ServerLife; entries outside these markers are left alone."

    /// `expandHome` (sshconfig.js flavour: only `~` and `~/`).
    static func expandHome(_ p: String) -> String {
        if p == "~" { return NSHomeDirectory() }
        if p.hasPrefix("~/") { return NSHomeDirectory() + "/" + p.dropFirst(2) }
        return p
    }

    static func stripQuotes(_ s: String) -> String {
        let t = s.trimmed
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    /// `splitLine`: keyword (lower-cased) and raw value; `key value` or `key=value`.
    static func splitLine(_ line: String) -> (key: String, value: String)? {
        let t = line.trimmed
        if t.isEmpty || t.hasPrefix("#") { return nil }
        guard let m = TPText.match(#"^([A-Za-z0-9_-]+)\s*(?:=\s*|\s+)(.*)$"#, t), let k = m[1] else { return nil }
        return (k.lowercased(), (m[2] ?? "").trimmed)
    }

    /// `tokens`: split a value respecting quotes.
    static func tokens(_ value: String) -> [String] {
        TPText.matches(#""([^"]*)"|'([^']*)'|(\S+)"#, value).map { $0[1] ?? $0[2] ?? $0[3] ?? "" }
    }

    static func globToRegex(_ glob: String) -> NSRegularExpression? {
        var r = ""
        for ch in glob {
            switch ch {
            case "*": r += "[^/]*"
            case "?": r += "[^/]"
            default: r += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return try? NSRegularExpression(pattern: "^" + r + "$")
    }

    static func expandInclude(_ pattern: String, baseDir: String) -> [String] {
        let p = expandHome(pattern)
        let abs = p.hasPrefix("/") ? p : (baseDir as NSString).appendingPathComponent(p)
        let dir = (abs as NSString).deletingLastPathComponent
        let base = (abs as NSString).lastPathComponent
        if !base.contains("*") && !base.contains("?") {
            return FileManager.default.fileExists(atPath: abs) ? [abs] : []
        }
        guard let re = globToRegex(base), let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { re.matches($0) }.map { (dir as NSString).appendingPathComponent($0) }.sorted()
    }

    struct Alias: Sendable { var alias: String; var source: String; var comment: String? }

    /// `collectAliases`: literal Host aliases across the config tree, in file
    /// order, following Include (8 levels, each file once).
    static func collectAliases(_ configPath: String = defaultPath) -> [Alias] {
        var seen = Set<String>()
        return collect(configPath, &seen, 0)
    }

    private static func collect(_ configPath: String, _ seen: inout Set<String>, _ depth: Int) -> [Alias] {
        if depth > 8 || seen.contains(configPath) { return [] }
        seen.insert(configPath)
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        var out: [Alias] = []
        let baseDir = (configPath as NSString).deletingLastPathComponent
        var lastComment: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmed
            if trimmed.hasPrefix("#") {
                lastComment = trimmed.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                continue
            }
            guard let kv = splitLine(line) else { if trimmed.isEmpty { lastComment = nil }; continue }
            if kv.key == "include" {
                for pat in tokens(kv.value) {
                    for f in expandInclude(stripQuotes(pat), baseDir: baseDir) { out += collect(f, &seen, depth + 1) }
                }
                continue
            }
            if kv.key == "host" {
                for pat in tokens(kv.value) {
                    let alias = stripQuotes(pat)
                    // Skip wildcards, negations and the catch-all.
                    if alias.contains(where: { "*?!".contains($0) }) { continue }
                    out.append(Alias(alias: alias, source: configPath, comment: lastComment))
                }
                lastComment = nil
            }
        }
        return out
    }

    /// `resolveHost`: `ssh [extra] -G alias` → lower-cased key → values.
    static func resolveHost(_ alias: String, extraArgs: [String] = []) async -> [String: [String]]? {
        let r = await Proc.run(Tools.ssh, extraArgs + ["-G", alias], timeout: 10)
        if !r.ok && r.out.isEmpty { return nil }
        return parseSshG(r.out)
    }

    static func parseSshG(_ text: String) -> [String: [String]] {
        var cfg: [String: [String]] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let i = line.firstIndex(of: " "), i != line.startIndex else { continue }
            let k = line[..<i].lowercased()
            cfg[k, default: []].append(String(line[line.index(after: i)...]).trimmed)
        }
        return cfg
    }

    /// `configRoots`: the primary config, then each extra file (as its own root).
    static func configRoots(_ extra: [String], primary: String = defaultPath) -> [(file: String, primary: Bool)] {
        var roots: [(file: String, primary: Bool)] = [(primary, true)]
        var seen: Set<String> = [primary]
        for raw in extra {
            let file = expandHome(raw.trimmed)
            if file.isEmpty || seen.contains(file) { continue }
            seen.insert(file)
            roots.append((file, false))
        }
        return roots
    }

    /// `listConfigFiles`: which config files are configured, and whether they exist.
    static func listConfigFiles(_ extra: [String], primary: String = defaultPath) -> [SSHConfigFile] {
        configRoots(extra, primary: primary).map { r in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: r.file, isDirectory: &isDir) && !isDir.boolValue
            let size = (try? FileManager.default.attributesOfItem(atPath: r.file)[.size] as? Int) ?? 0
            return SSHConfigFile(file: r.file, label: r.primary ? "~/.ssh/config" : (r.file as NSString).lastPathComponent,
                                 primary: r.primary, exists: exists, size: exists ? size : 0)
        }
    }

    /// `discovery:ssh` / `listSshHosts`: every config root's hosts, resolved.
    static func listSshHosts(extra: [String], primary: String = defaultPath) async -> [Host] {
        var out: [Host] = []
        for root in configRoots(extra, primary: primary) { out += await hostsFromConfig(file: root.file, primary: root.primary) }
        return out
    }

    /// The hosts one config file defines, on its own terms.
    ///
    /// Host fields: id (`ssh:<alias>` in the primary config, `ssh:<alias>|<file>`
    /// in an extra one), alias, name, hostname, user, port, identityFile,
    /// configFile (nil for the primary). In `extra`: proxied, viaTsh, comment,
    /// source, configRoot, configLabel, unresolved.
    static func hostsFromConfig(file: String, primary: Bool) async -> [Host] {
        var uniq: [Alias] = []
        var seenAlias = Set<String>()
        for a in collectAliases(file) where !seenAlias.contains(a.alias) { seenAlias.insert(a.alias); uniq.append(a) }
        let asked = primary ? [] : ["-F", file]
        // Without an ssh client there is nothing to ask, so the file is read
        // instead — weaker, and marked `unresolved`.
        let canResolve = Tools.sshAvailable
        let resolved = await withTaskGroup(of: (Int, [String: [String]]?).self) { g -> [[String: [String]]?] in
            var out = [[String: [String]]?](repeating: nil, count: uniq.count)
            var next = 0
            // At most eight `ssh -G` at once.
            func add() {
                guard next < uniq.count else { return }
                let i = next, a = uniq[i]
                next += 1
                g.addTask { (i, canResolve ? await resolveHost(a.alias, extraArgs: asked) : readAliasFromFile(a)) }
            }
            for _ in 0..<8 { add() }
            for await (i, cfg) in g { out[i] = cfg; add() }
            return out
        }
        var hosts: [Host] = []
        for (i, a) in uniq.enumerated() {
            guard let cfg = resolved[i] else { continue }
            func first(_ k: String) -> String? { cfg[k]?.first?.nilIfEmpty }
            let proxied = first("proxycommand") != nil || first("proxyjump") != nil
            var h = Host(type: Host.ssh, id: primary ? "ssh:" + a.alias : "ssh:\(a.alias)|\(file)", name: a.alias)
            h.alias = a.alias
            h.hostname = first("hostname") ?? a.alias
            h.user = first("user") ?? NSUserName()
            h.port = Int(first("port") ?? "22") ?? 22
            h.identityFile = first("identityfile")
            h.configFile = primary ? nil : file
            h.extra["proxied"] = .bool(proxied)
            // A Teleport-generated ProxyCommand: this alias already routes through tsh.
            h.extra["viaTsh"] = .bool(TPText.test(#"\btsh\b"#, first("proxycommand") ?? ""))
            h.extra["comment"] = JSON(a.comment)
            h.extra["source"] = .string(a.source)
            h.extra["configRoot"] = .string(file)
            h.extra["configLabel"] = .string(primary ? "~/.ssh/config" : (file as NSString).lastPathComponent)
            h.extra["unresolved"] = .bool(!canResolve)
            hosts.append(h)
        }
        return hosts
    }

    /// `readAliasFromFile`: one Host block's keys, straight from the file (first value wins).
    static func readAliasFromFile(_ a: Alias) -> [String: [String]] {
        guard let text = try? String(contentsOfFile: a.source, encoding: .utf8) else { return [:] }
        var cfg: [String: [String]] = [:]
        var inBlock = false
        for raw in text.components(separatedBy: "\n") {
            guard let kv = splitLine(raw.hasSuffix("\r") ? String(raw.dropLast()) : raw) else { continue }
            if kv.key == "host" {
                inBlock = tokens(kv.value).map(stripQuotes).contains { pat in
                    pat == a.alias || ((pat.contains("*") || pat.contains("?")) && (globToRegex(pat)?.matches(a.alias) ?? false))
                }
                continue
            }
            if !inBlock { continue }
            if cfg[kv.key] == nil { cfg[kv.key] = [stripQuotes(kv.value)] }
        }
        return cfg
    }

    // MARK: - The managed block

    /// `parseEntries`: split a managed block into Host entries (anything
    /// before the first `Host` line — our note — is dropped).
    static func parseEntries(_ block: String) -> [String] {
        var entries: [String] = []
        var current: [String]?
        for line in block.components(separatedBy: "\n") {
            if TPText.test(#"^Host\s+\S"#, line) {
                if let c = current { entries.append(trimEnd(c.joined(separator: "\n"))) }
                current = [trimEnd(line)]
            } else if current != nil {
                current?.append(trimEnd(line))
            }
        }
        if let c = current { entries.append(trimEnd(c.joined(separator: "\n"))) }
        return entries.filter { !$0.isEmpty }
    }

    static func aliasOf(_ entry: String) -> String? { TPText.match(#"^Host\s+(\S+)"#, entry)?[1] ?? nil }

    static func renderBlock(_ entries: [String]) -> String {
        entries.isEmpty
            ? "\(blockStart)\n\(blockNote)\n\(blockEnd)"
            : "\(blockStart)\n\(blockNote)\n\n\(entries.joined(separator: "\n\n"))\n\n\(blockEnd)"
    }

    static func renderHostBlock(_ h: ManagedSSHHost) -> String {
        var lines = ["Host \(h.alias)"]
        if !h.hostname.isEmpty { lines.append("  HostName \(h.hostname)") }
        if let u = h.user?.nilIfEmpty { lines.append("  User \(u)") }
        if let p = h.port, p != 22, p != 0 { lines.append("  Port \(p)") }
        if let k = h.identityFile?.nilIfEmpty {
            lines.append("  IdentityFile \(k)")
            lines.append("  IdentitiesOnly yes")
        }
        if let j = h.proxyJump?.nilIfEmpty { lines.append("  ProxyJump \(j)") }
        if h.forwardAgent { lines.append("  ForwardAgent yes") }
        for line in (h.extraOptions ?? "").components(separatedBy: "\n").map(\.trimmed) where !line.isEmpty {
            lines.append("  " + line)
        }
        return lines.joined(separator: "\n")
    }

    /// `addHostToConfig`: append (or replace) a Host entry inside the marked
    /// block. Backs the file up once (`<config>.serverlife-backup`) and refuses
    /// to shadow a Host the user defined outside the block unless `force`.
    @discardableResult
    static func addHost(_ host: ManagedSSHHost, configPath: String = defaultPath) throws -> (alias: String, path: String) {
        if host.alias.isEmpty || host.alias.contains(where: { $0.isWhitespace }) { throw AppError("Give the host a single-word alias") }
        if host.hostname.isEmpty { throw AppError("Hostname is required") }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if !text.isEmpty {
            let backup = configPath + ".serverlife-backup"
            if !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: configPath, toPath: backup) }
        }
        let outside = jsSplit(text, blockStart)[0] + (jsSplit(text, blockEnd).count > 1 ? jsSplit(text, blockEnd)[1] : "")
        let clash = TPText.test(#"^\s*Host\s+(.*\s)?"# + TPText.escapeRegex(host.alias) + #"(\s|$)"#, outside,
                                [.caseInsensitive, .anchorsMatchLines])
        if clash && !host.force {
            throw AppError("~/.ssh/config already defines \"\(host.alias)\" outside the ServerLife block")
        }
        let s = text.range(of: blockStart), e = text.range(of: blockEnd)
        var block = ""
        if let s, let e, s.upperBound <= e.lowerBound { block = String(text[s.upperBound..<e.lowerBound]).trimmed }
        var kept = parseEntries(block).filter { (aliasOf($0) ?? "").lowercased() != host.alias.lowercased() }
        kept.append(renderHostBlock(host))
        let newBlock = renderBlock(kept)
        let out: String
        if let s, let e, s.upperBound <= e.lowerBound {
            out = String(text[..<s.lowerBound]) + newBlock + String(text[e.upperBound...])
        } else {
            out = (text.isEmpty ? "" : trimEnd(text) + "\n\n") + newBlock + "\n"
        }
        try writeAtomically(out, configPath)
        return (host.alias, configPath)
    }

    /// `removeHostFromConfig`: remove an alias from the managed block; an
    /// empty block leaves no markers behind. Hosts outside it are untouched.
    @discardableResult
    static func removeHost(_ alias: String, configPath: String = defaultPath) throws -> Bool {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8),
              let s = text.range(of: blockStart), let e = text.range(of: blockEnd), s.upperBound <= e.lowerBound
        else { return false }
        let block = String(text[s.upperBound..<e.lowerBound])
        let all = parseEntries(block)
        let kept = all.filter { (aliasOf($0) ?? "").lowercased() != alias.lowercased() }
        if kept.count == all.count { return false }
        let out = kept.isEmpty
            ? collapseTrailingNewlines(collapseTrailingNewlines(String(text[..<s.lowerBound]), to: "\n\n")
                                       + String(text[e.upperBound...]), to: "\n")
            : String(text[..<s.lowerBound]) + renderBlock(kept) + String(text[e.upperBound...])
        try writeAtomically(out, configPath)
        return true
    }

    /// `managedAliases`: which aliases this app wrote.
    static func managedAliases(configPath: String = defaultPath) -> [String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8),
              let s = text.range(of: blockStart), let e = text.range(of: blockEnd), s.upperBound <= e.lowerBound
        else { return [] }
        return parseEntries(String(text[s.upperBound..<e.lowerBound])).compactMap(aliasOf)
    }

    // MARK: - tsh config

    static func tshMarkers(_ tag: String) -> (start: String, end: String) {
        ("# >>> ServerLife: tsh config for \(tag) >>>", "# <<< ServerLife: tsh config for \(tag) <<<")
    }

    struct TshWriteResult: Sendable { var path: String; var replaced: Bool; var backup: String?; var lines: Int }

    /// `appendTshConfig`: put a cluster's `tsh config` output into the config
    /// between per-cluster markers — replacing its earlier block, or at the
    /// *top* of the file when new (ssh takes the first value it sees). Backs
    /// the file up first (`<config>.serverlife-backup-<ms>`).
    @discardableResult
    static func writeTshConfig(cluster: String?, proxy: String?, text: String,
                               configPath: String = defaultPath) throws -> TshWriteResult {
        let tag = (cluster?.nilIfEmpty ?? proxy?.nilIfEmpty ?? "teleport").trimmed
        if tag.isEmpty { throw AppError("Which cluster? A name or proxy is needed.") }
        let body = text.trimmed
        if !body.contains("Host ") { throw AppError("That does not look like ssh config output.") }
        let (start, end) = tshMarkers(tag)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        var backedUp: String?
        if !existing.isEmpty {
            let backup = "\(configPath).serverlife-backup-\(Int64(nowMs()))"
            try? fm.copyItem(atPath: configPath, toPath: backup)
            if fm.fileExists(atPath: backup) { backedUp = backup }
        }
        let block = [start, "# Written by ServerLife from `tsh config`. Edits inside these markers are",
                     "# replaced the next time this cluster is written.", body, end].joined(separator: "\n")
        let si = existing.range(of: start), ei = existing.range(of: end)
        let replaced = si != nil && ei != nil && si!.lowerBound < ei!.lowerBound
        let out: String
        if replaced, let si, let ei {
            out = String(existing[..<si.lowerBound]) + block + String(existing[ei.upperBound...])
        } else {
            out = block + "\n\n" + (existing.isEmpty ? "" : stripLeadingBlankLines(existing))
        }
        try writeAtomically(trimEnd(out) + "\n", configPath)
        return TshWriteResult(path: configPath, replaced: replaced, backup: backedUp, lines: block.components(separatedBy: "\n").count)
    }

    struct TshConfigState: Sendable {
        var path: String
        /// Our own marked block for this cluster is there.
        var present: Bool
        /// The block's Host patterns already defined outside our markers
        /// (usually a hand-run `tsh config >> ~/.ssh/config`).
        var foreign: [String]
        var hasFile: Bool
    }

    /// `tshConfigStatus`: is this cluster already in the file, and how?
    static func tshConfigStatus(cluster: String?, proxy: String?, generated: String,
                                configPath: String = defaultPath) -> TshConfigState {
        let tag = (cluster?.nilIfEmpty ?? proxy ?? "").trimmed
        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let (start, end) = tshMarkers(tag)
        let present = !tag.isEmpty && text.contains(start)
        var outside = text
        if let si = text.range(of: start), let ei = text.range(of: end), si.lowerBound < ei.lowerBound {
            outside = String(text[..<si.lowerBound]) + String(text[ei.upperBound...])
        }
        var patterns: [String] = []
        for line in generated.components(separatedBy: "\n") {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard let m = TPText.match(#"^\s*Host\s+(.+?)\s*$"#, l, .caseInsensitive), let v = m[1] else { continue }
            for h in v.split(whereSeparator: { $0.isWhitespace }).map(String.init) where h != "*" && !patterns.contains(h) {
                patterns.append(h)
            }
        }
        let foreign = patterns.filter {
            TPText.test(#"^\s*Host\s+(.*\s)?"# + TPText.escapeRegex($0) + #"(\s|$)"#, outside, [.caseInsensitive, .anchorsMatchLines])
        }
        return TshConfigState(path: configPath, present: present, foreign: foreign, hasFile: !text.isEmpty)
    }

    /// `sshconfig:tshPreview`: what `tsh config` would write, and where things stand.
    static func tshPreview(proxy: String?, cluster: String?, home: String?,
                           configPath: String = defaultPath) async throws -> (text: String, state: TshConfigState) {
        let text = try await Teleport.clusterSshConfigText(proxy: proxy, home: home)
        return (text, tshConfigStatus(cluster: cluster, proxy: proxy, generated: text, configPath: configPath))
    }

    // MARK: - Pickers

    /// `sshconfig:pickFile`: config files live in dotted directories, so hidden files show.
    @MainActor
    static func pickConfigFile(window: WindowModel? = nil) async -> String? {
        await Modal.openFiles(window, multiple: false, directory: NSHomeDirectory() + "/.ssh",
                              title: "Choose an SSH config file").first?.path
    }

    /// `sshconfig:pickKey`.
    @MainActor
    static func pickKey(window: WindowModel? = nil) async -> String? {
        await Modal.openFiles(window, multiple: false, directory: NSHomeDirectory() + "/.ssh",
                              title: "Choose a private key").first?.path
    }

    // MARK: - Helpers

    /// JavaScript `String.split(sep)`.
    static func jsSplit(_ s: String, _ sep: String) -> [String] { s.components(separatedBy: sep) }

    /// `trimEnd()`.
    static func trimEnd(_ s: String) -> String {
        var t = Substring(s)
        while let c = t.last, c.isWhitespace { t.removeLast() }
        return String(t)
    }

    /// `replace(/\n{3,}$/, replacement)`.
    static func collapseTrailingNewlines(_ s: String, to replacement: String) -> String {
        var n = 0
        for c in s.reversed() { if c == "\n" { n += 1 } else { break } }
        return n >= 3 ? String(s.dropLast(n)) + replacement : s
    }

    /// `replace(/^\s*\n/, '')`: leading whitespace through its last newline.
    static func stripLeadingBlankLines(_ s: String) -> String {
        var lastNewline: String.Index?
        var i = s.startIndex
        while i < s.endIndex, s[i].isWhitespace {
            if s[i] == "\n" || s[i] == "\r\n" { lastNewline = i }
            i = s.index(after: i)
        }
        guard let ln = lastNewline else { return s }
        return String(s[s.index(after: ln)...])
    }

    /// tmp + rename, mode 0600 (`<config>.serverlife-tmp`).
    static func writeAtomically(_ text: String, _ path: String) throws {
        let tmp = path + ".serverlife-tmp"
        let fm = FileManager.default
        guard fm.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw AppError("Could not write \(tmp)")
        }
        if rename(tmp, path) != 0 { throw AppError("Could not replace \(path): \(String(cString: strerror(errno)))") }
    }
}
