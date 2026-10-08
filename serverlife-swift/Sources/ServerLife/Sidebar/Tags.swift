import Foundation

// Port of src/renderer/js/tags.js — Teleport labels ("tags"): reading them off
// a node, and the small query language the host filter, folder rules and
// fan-out targeting all understand.
//
// `tsh ls --format=json` hands over both kinds of label: the static ones in
// `metadata.labels` and the dynamic command labels in `spec.cmd_labels`, which
// the Teleport service merges into one flat `labels` map per node. Everything
// here works off that map, so plain SSH hosts (which have none) simply fall
// through to matching on their name and address.
//
// Everything in `Tags` is pure and thread-safe.

/// One term of a query: either free text, or `key op value` (op is `=`, `:` or `~`).
struct TagTerm: Equatable, Sendable {
    var neg: Bool
    /// Set for a free-text term (lowercased).
    var text: String?
    var key: String = ""
    var op: String = ""
    var value: String = ""

    static func text(_ s: String, neg: Bool = false) -> TagTerm { TagTerm(neg: neg, text: s) }
    static func keyed(_ key: String, _ op: String, _ value: String, neg: Bool = false) -> TagTerm {
        TagTerm(neg: neg, text: nil, key: key, op: op, value: value)
    }
}

/// A compiled query (`compileQuery`): `empty` when there is nothing to ask,
/// `error` when the boolean grammar would not read it (the match then falls
/// back to the plain AND reading of the same words), and `match`.
struct CompiledQuery: Sendable {
    let empty: Bool
    let error: String?
    fileprivate let ast: TagNode?
    fileprivate let terms: [TagTerm]?

    /// Does this host satisfy the query?
    func match(_ host: Host) -> Bool {
        if let ast { return Tags.eval(host, ast) }
        if let terms { return Tags.hostMatchesQuery(host, terms) }
        return true
    }

    /// Whether the query parsed as a boolean expression (an AST exists).
    var hasAST: Bool { ast != nil }
}

fileprivate indirect enum TagNode: Sendable {
    case and(TagNode, TagNode)
    case or(TagNode, TagNode)
    case not(TagNode)
    case term(TagTerm)
}

fileprivate enum TagToken: Equatable {
    case term(String), and, or, not, lparen, rparen
    var isTerm: Bool { if case .term = self { return true }; return false }
}

enum Tags {
    /// Labels Teleport sets for its own bookkeeping, not for humans to filter on.
    static let internalPrefixes = ["teleport.internal/", "teleport.hidden/", "teleport.dev/"]

    static func isInternalLabel(_ key: String) -> Bool {
        internalPrefixes.contains { key.hasPrefix($0) }
    }

    /// `localeCompare` for label keys.
    static func localeLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [], range: nil, locale: Locale(identifier: "en_US")) == .orderedAscending
    }

    /// A node's labels as sorted (key, value) pairs. Internal labels are dropped
    /// unless asked for — noise in the sidebar, useful in the details dialog.
    static func labelEntries(_ host: Host, includeInternal: Bool = false) -> [(key: String, value: String)] {
        host.labels
            .filter { includeInternal || !isInternalLabel($0.key) }
            .map { (key: $0.key, value: $0.value) }
            .sorted { localeLess($0.key, $1.key) }
    }

    static func labelCount(_ host: Host) -> Int { labelEntries(host).count }

    /// Every distinct key=value across a set of nodes, with how many nodes
    /// carry it. Keys sorted; values in the order first met.
    static func collectTags(_ nodes: [Host]) -> [(key: String, values: [(value: String, count: Int)])] {
        var order: [String] = []
        var vals: [String: [String]] = [:]
        var counts: [String: [String: Int]] = [:]
        for n in nodes {
            for (k, v) in labelEntries(n) {
                if vals[k] == nil { order.append(k); vals[k] = []; counts[k] = [:] }
                if counts[k]![v] == nil { vals[k]!.append(v) }
                counts[k]![v, default: 0] += 1
            }
        }
        return order.sorted(by: localeLess).map { k in
            (key: k, values: vals[k]!.map { (value: $0, count: counts[k]![$0]!) })
        }
    }

    // MARK: - Tokenising

    /// Split on whitespace, but let quotes hold a value together, so both
    /// `env="us east"` and `"env=us east"` survive as one term.
    static func tokenize(_ text: String) -> [String] {
        tokenizeRich(text).map(\.value)
    }

    /// `tokenize`, saying which tokens were quoted.
    static func tokenizeRich(_ text: String) -> [(value: String, quoted: Bool)] {
        var out: [(value: String, quoted: Bool)] = []
        var cur = ""
        var quote: Character? = nil
        var quoted = false, wasQuoted = false
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; quoted = true; wasQuoted = true; continue }
            if ch.isWhitespace {
                if !cur.isEmpty || quoted { out.append((cur, wasQuoted)) }
                cur = ""; quoted = false; wasQuoted = false
                continue
            }
            cur.append(ch)
        }
        if !cur.isEmpty || quoted { out.append((cur, wasQuoted)) }
        return out
    }

    // MARK: - Terms

    private static let termRe = try! NSRegularExpression(pattern: #"^([^:=~\s]+)([:=~])(.*)$"#, options: [.dotMatchesLineSeparators])

    /// One already-separated token as a term. A regular expression keeps its
    /// case; everything else is lowercased on both sides.
    static func termFromToken(_ tok: String) -> TagTerm {
        var s = tok
        var neg = false
        if s.first == "-" && s.count > 1 { neg = true; s.removeFirst() }
        if let g = groups(termRe, s), let k = g[1], let op = g[2] {
            let v = g[3] ?? ""
            return .keyed(k.lowercased(), op, op == "~" ? v : v.lowercased(), neg: neg)
        }
        return .text(s.lowercased(), neg: neg)
    }

    /// Parse the filter box into terms, all of which must match (AND):
    ///
    ///     web                text anywhere — name, address, cluster or any label
    ///     env=prod           label `env` is exactly `prod`
    ///     env:pro            label `env` contains `pro`
    ///     env=prod*          label `env` matches the glob
    ///     name~^web-\d+$     a real regular expression
    ///     env=prod,staging   either value
    ///     env:               the node has an `env` label at all
    ///     tag:gpu            any label key or value contains `gpu`
    ///     cluster=corp       a non-label field: name, host, cluster, addr, proxy, type …
    ///     -env=dev           exclude
    static func parseQuery(_ text: String) -> [TagTerm] {
        tokenize(text).filter { !$0.isEmpty }.map(termFromToken)
    }

    // MARK: - Regular expressions

    private static let reLock = NSLock()
    nonisolated(unsafe) private static var reCache: [String: NSRegularExpression?] = [:]

    /// A case-insensitive regular expression, compiled once and kept; nil
    /// when it will not compile (it then never matches).
    static func toRe(_ pattern: String) -> NSRegularExpression? {
        reLock.lock(); defer { reLock.unlock() }
        if let hit = reCache[pattern] { return hit }
        let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        reCache[pattern] = re
        return re
    }

    /// Does this pattern compile? nil when it does, else why not.
    static func regexError(_ pattern: String) -> String? {
        do { _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]); return nil } catch {
            let why = regexReason(pattern)
            return "Invalid regular expression: /\(pattern)/" + (why.map { ": " + $0 } ?? "")
        }
    }

    /// Why a pattern will not compile, in the words JavaScript's engine uses
    /// (NSRegularExpression gives no reason of its own).
    static func regexReason(_ pattern: String) -> String? {
        let a = Array(pattern)
        var depth = 0, i = 0
        var inClass = false
        var prevAtom = false
        while i < a.count {
            let c = a[i]
            if c == "\\" {
                if i + 1 >= a.count { return "\\ at end of pattern" }
                i += 2; prevAtom = true; continue
            }
            if inClass {
                if c == "]" { inClass = false; prevAtom = true }
                i += 1; continue
            }
            switch c {
            case "[": inClass = true
            case "(":
                depth += 1; prevAtom = false
                if i + 1 < a.count, a[i + 1] == "?" { i += 1 }
                i += 1; continue
            case ")":
                if depth == 0 { return "Unmatched ')'" }
                depth -= 1; prevAtom = true
            case "|": prevAtom = false; i += 1; continue
            case "*", "+", "?":
                if !prevAtom { return "Nothing to repeat" }
                if i + 1 < a.count, a[i + 1] == "?" || a[i + 1] == "+" { i += 1 }
                prevAtom = false; i += 1; continue
            case "{":
                let rest = String(a[i...])
                if rest.range(of: #"^\{\d+(,\d*)?\}"#, options: .regularExpression) != nil {
                    if !prevAtom { return "Nothing to repeat" }
                    i += rest.firstIndex(of: "}").map { rest.distance(from: rest.startIndex, to: $0) + 1 } ?? 1
                    prevAtom = false; continue
                }
            default: break
            }
            prevAtom = true
            i += 1
        }
        if inClass { return "Unterminated character class" }
        if depth > 0 { return "Unterminated group" }
        return nil
    }

    private static func globMatches(_ pattern: String, _ s: String) -> Bool {
        let body = pattern.components(separatedBy: "*").map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: ".*")
        guard let re = try? NSRegularExpression(pattern: "^\(body)$", options: [.dotMatchesLineSeparators]) else { return false }
        return re.matches(s)
    }

    private static func matchValue(_ actual: String, _ want: String, _ op: String) -> Bool {
        // A regex is one pattern, never a comma list: `a{1,3}` is regex syntax.
        if op == "~" {
            if want.isEmpty { return true }
            guard let re = toRe(want) else { return false }
            return re.matches(actual)
        }
        // `key:` / `key=` with nothing after it asks only that the key exists.
        let alts = want.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        if alts.isEmpty { return true }
        let lower = actual.lowercased()
        return alts.contains { w in
            if op == ":" { return lower.contains(w) }
            if w.contains("*") { return globMatches(w, lower) }
            return lower == w
        }
    }

    /// Non-label fields a keyed term may address, so `cluster=corp` works too.
    static func fieldValue(_ host: Host, _ key: String) -> String? {
        switch key {
        case "name": return host.name.nilIfEmpty ?? host.alias ?? ""
        case "host", "hostname": return host.hostname ?? ""
        case "alias": return host.alias ?? ""
        case "cluster": return host.cluster ?? ""
        case "proxy": return host.proxy ?? ""
        case "addr": return host.addr ?? ""
        case "type": return host.type
        case "user": return host.user ?? ""
        case "uuid": return host.uuid ?? ""
        case "tunnel": return host.tunnel == true ? "true" : "false"
        default: return nil
        }
    }

    static func textHaystack(_ host: Host) -> String {
        var parts: [String] = [host.name, host.alias ?? "", host.hostname ?? "", host.cluster ?? "", host.addr ?? "", host.user ?? ""]
        for (k, v) in labelEntries(host) { parts.append(contentsOf: [k, v, "\(k)=\(v)"]) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    static func termMatches(_ host: Host, _ term: TagTerm) -> Bool {
        if let t = term.text { return textHaystack(host).contains(t) }
        let entries = labelEntries(host, includeInternal: true)

        // `tag:` / `label:` searches across every key and value at once.
        if term.key == "tag" || term.key == "label" || term.key == "labels" {
            if term.value.isEmpty { return !entries.isEmpty }
            if term.op == "~" {
                guard let re = toRe(term.value) else { return false }
                return entries.contains { re.matches($0.key) || re.matches($0.value) || re.matches("\($0.key)=\($0.value)") }
            }
            return entries.contains {
                $0.key.lowercased().contains(term.value) || $0.value.lowercased().contains(term.value)
                    || "\($0.key)=\($0.value)".lowercased().contains(term.value)
            }
        }

        // `teleport.internal/foo` (or `aws/location`) is also reachable as
        // plain `foo` (`location`): the prefix is what the user is least likely to type.
        let keyed = entries.filter {
            let lower = $0.key.lowercased()
            return lower == term.key || lower.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) == term.key
        }
        let field = fieldValue(host, term.key)

        // A label and a field can both answer to the same word; either matching counts.
        if !keyed.isEmpty || field != nil {
            return keyed.contains { matchValue($0.value, term.value, term.op) }
                || (field.map { matchValue($0, term.value, term.op) } ?? false)
        }

        // Neither a label nor a known field: match the raw token as text,
        // which rescues `web-01:3022` and `https://grafana/...`.
        return textHaystack(host).contains(term.key + term.op + term.value)
    }

    static func hostMatchesQuery(_ host: Host, _ terms: [TagTerm]) -> Bool {
        if terms.isEmpty { return true }
        return terms.allSatisfy { $0.neg ? !termMatches(host, $0) : termMatches(host, $0) }
    }

    // MARK: - Boolean queries

    private static let ops: [String: TagToken] = ["and": .and, "&": .and, "&&": .and, "or": .or, "|": .or, "||": .or,
                                                  "not": .not, "!": .not]
    private static let regexTermStart = try! NSRegularExpression(pattern: #"^-?[^:=~\s()]+~"#)

    /// Tokens for the boolean parser. Quoting takes a token out of the grammar.
    fileprivate static func lex(_ text: String) -> [TagToken] {
        var out: [TagToken] = []
        for (value, quoted) in tokenizeRich(text) {
            if quoted { out.append(.term(value)); continue }
            var rest = Array(value)
            while !rest.isEmpty {
                if rest[0] == "(" || rest[0] == ")" {
                    out.append(rest[0] == "(" ? .lparen : .rparen)
                    rest.removeFirst()
                    continue
                }
                // A regular expression owns its own brackets.
                if regexTermStart.matches(String(rest)) {
                    var depth = 0
                    var cut = rest.count
                    var i = 0
                    while i < rest.count {
                        let c = rest[i]
                        if c == "\\" { i += 2; continue }
                        if c == "(" { depth += 1 } else if c == ")" {
                            if depth == 0 { cut = i; break }
                            depth -= 1
                        }
                        i += 1
                    }
                    out.append(.term(String(rest[0..<cut])))
                    rest = Array(rest[cut...])
                    continue
                }
                let upto = rest.firstIndex { $0 == "(" || $0 == ")" }
                let chunk = String(upto.map { rest[0..<$0] } ?? rest[...])
                rest = upto.map { Array(rest[$0...]) } ?? []
                if let op = ops[chunk.lowercased()] { out.append(op) } else { out.append(.term(chunk)) }
            }
        }
        return out
    }

    private struct ParseError: Error { let message: String }

    private static func parseExpr(_ ts: [TagToken], _ i: inout Int) throws -> TagNode {
        var left = try parseAnd(ts, &i)
        while i < ts.count, ts[i] == .or {
            i += 1
            left = .or(left, try parseAnd(ts, &i))
        }
        return left
    }

    private static func parseAnd(_ ts: [TagToken], _ i: inout Int) throws -> TagNode {
        var left = try parseUnary(ts, &i)
        while i < ts.count {
            let t = ts[i]
            if t == .rparen || t == .or { break }
            // Juxtaposition is AND; an explicit `and` is the same thing, spelled.
            if t == .and { i += 1 }
            left = .and(left, try parseUnary(ts, &i))
        }
        return left
    }

    private static func parseUnary(_ ts: [TagToken], _ i: inout Int) throws -> TagNode {
        guard i < ts.count else { throw ParseError(message: "the query ends where a condition was expected") }
        let t = ts[i]
        switch t {
        case .not:
            i += 1
            return .not(try parseUnary(ts, &i))
        case .and: throw ParseError(message: "\"and\" needs something on both sides")
        case .or: throw ParseError(message: "\"or\" needs something on both sides")
        case .lparen:
            i += 1
            let inner = try parseExpr(ts, &i)
            guard i < ts.count, ts[i] == .rparen else { throw ParseError(message: "a bracket is left open") }
            i += 1
            return inner
        case .rparen: throw ParseError(message: "a closing bracket with nothing open")
        case .term(let v):
            i += 1
            let term = termFromToken(v)
            // A broken pattern is worth saying out loud.
            if term.op == "~", !term.value.isEmpty, let bad = regexError(term.value) {
                throw ParseError(message: "that regular expression will not compile (\(bad))")
            }
            return .term(term)
        }
    }

    fileprivate static func eval(_ host: Host, _ n: TagNode) -> Bool {
        switch n {
        case .and(let a, let b): return eval(host, a) && eval(host, b)
        case .or(let a, let b): return eval(host, a) || eval(host, b)
        case .not(let a): return !eval(host, a)
        case .term(let t): return t.neg ? !termMatches(host, t) : termMatches(host, t)
        }
    }

    private static let compileLock = NSLock()
    nonisolated(unsafe) private static var compileCache: [String: CompiledQuery] = [:]

    /// Turn a query into something that can be asked of a host. A query that
    /// will not parse still gets a usable match (the plain AND reading of the
    /// same words, operators dropped) — half-typed queries are the normal
    /// state of a filter box. `error` is for the places that should complain.
    static func compileQuery(_ text: String) -> CompiledQuery {
        let src = text.trimmed
        if src.isEmpty { return CompiledQuery(empty: true, error: nil, ast: nil, terms: nil) }
        compileLock.lock()
        if let hit = compileCache[src] { compileLock.unlock(); return hit }
        compileLock.unlock()
        let result = compileUncached(src)
        compileLock.lock()
        if compileCache.count > 400 { compileCache.removeAll() }
        compileCache[src] = result
        compileLock.unlock()
        return result
    }

    private static func compileUncached(_ src: String) -> CompiledQuery {
        let tokens = lex(src)
        if tokens.isEmpty { return CompiledQuery(empty: true, error: nil, ast: nil, terms: nil) }
        do {
            var i = 0
            let ast = try parseExpr(tokens, &i)
            if i < tokens.count { throw ParseError(message: "there is more here than the query can read") }
            return CompiledQuery(empty: false, error: nil, ast: ast, terms: nil)
        } catch {
            let words = tokens.compactMap { t -> String? in if case .term(let v) = t { return v }; return nil }
            let terms = parseQuery(words.joined(separator: " "))
            return CompiledQuery(empty: terms.isEmpty, error: (error as? ParseError)?.message ?? "\(error)",
                                 ast: nil, terms: terms)
        }
    }

    /// Does this query use any of the boolean syntax, or is it the plain old list?
    static func isBooleanQuery(_ text: String) -> Bool {
        lex(text).contains { !$0.isTerm }
    }

    // MARK: - Chip helpers

    /// Take the quotes off a term, if it arrived wearing them.
    static func unquote(_ tok: String) -> String {
        let a = Array(tok)
        if a.count > 1, (a[0] == "\"" || a[0] == "'"), a[a.count - 1] == a[0] { return String(a[1..<(a.count - 1)]) }
        return tok
    }

    private static let splitRe = try! NSRegularExpression(pattern: #"^(-?)([^:=~\s]+)([:=~])(.*)$"#, options: [.dotMatchesLineSeparators])

    private struct Split { var neg: Bool; var key: String; var op: String; var value: String }

    private static func splitTerm(_ tok: String) -> Split? {
        guard let g = groups(splitRe, unquote(tok)) else { return nil }
        return Split(neg: !(g[1] ?? "").isEmpty, key: g[2] ?? "", op: g[3] ?? "", value: g[4] ?? "")
    }

    private static func sameKeyIndex(_ tokens: [String], _ t: Split) -> Int? {
        tokens.firstIndex { x in
            guard let p = splitTerm(x) else { return false }
            return !p.neg && p.key.lowercased() == t.key.lowercased() && p.op == t.op
        }
    }

    /// Add or remove `key=value` in a query string, so clicking the same tag
    /// chip twice leaves the filter as it was found. A second value for a key
    /// folds into that key's comma list.
    static func toggleTerm(_ query: String, _ term: String) -> String {
        var tokens = tokenize(query)
        let bare = unquote(term)
        guard let t = splitTerm(bare) else {
            if let i = tokens.firstIndex(where: { $0.lowercased() == bare.lowercased() }) { tokens.remove(at: i) } else { tokens.append(bare) }
            return joinTokens(tokens)
        }

        // "any value of this key" replaces whatever values were pinned, and
        // toggles off when it is already all that is asked.
        if t.value.isEmpty {
            let hits = tokens.enumerated().compactMap { (ix, x) -> (Split, Int)? in
                guard let p = splitTerm(x), !p.neg, p.key.lowercased() == t.key.lowercased() else { return nil }
                return (p, ix)
            }
            let hadValues = hits.contains { !$0.0.value.isEmpty }
            for (_, ix) in hits.reversed() { tokens.remove(at: ix) }
            if hits.isEmpty || hadValues { tokens.append(bare) }
            return joinTokens(tokens)
        }

        guard let i = sameKeyIndex(tokens, t) else {
            tokens.append(bare)
            return joinTokens(tokens)
        }
        let cur = splitTerm(tokens[i])!
        var values = cur.value.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        if let vi = values.firstIndex(where: { $0.lowercased() == t.value.lowercased() }) { values.remove(at: vi) } else { values.append(t.value) }
        if values.isEmpty { tokens.remove(at: i) } else { tokens[i] = "\(cur.key)\(cur.op)\(values.joined(separator: ","))" }
        return joinTokens(tokens)
    }

    static func hasTerm(_ query: String, _ term: String) -> Bool {
        let bare = unquote(term)
        let t = splitTerm(bare)
        return tokenize(query).contains { x in
            if x.lowercased() == bare.lowercased() { return true }
            guard let t, let p = splitTerm(x), !p.neg, p.key.lowercased() == t.key.lowercased() else { return false }
            // "any value" is satisfied by any term on that key, whatever the operator.
            if t.value.isEmpty { return true }
            if p.op != t.op { return false }
            return p.value.split(separator: ",").contains { $0.lowercased() == t.value.lowercased() }
        }
    }

    static func joinTokens(_ tokens: [String]) -> String {
        tokens.map(quoteIfNeeded).joined(separator: " ")
    }

    static func quoteIfNeeded(_ tok: String) -> String {
        tok.contains(where: { $0.isWhitespace }) ? "\"\(tok)\"" : tok
    }

    /// `key=value`, quoted when the value has spaces, ready to drop in the filter.
    static func termFor(_ key: String, _ value: String) -> String {
        quoteIfNeeded(value.isEmpty ? "\(key):" : "\(key)=\(value)")
    }

    // MARK: - Helpers

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return String(s[rr])
        }
    }
}
