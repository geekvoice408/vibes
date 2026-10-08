import AppKit
import UniformTypeIdentifiers
import Foundation

// Recorded sessions (teleport.js listRecordings/playText/searchRecordings/
// playArgs/webSessionUrl + the main.js `recordings:*` handlers) and sessions
// in progress (livesessions.js + listActiveSessions).

/// One recorded session (a `session.end` audit event).
struct Recording: Codable, Hashable, Identifiable, Sendable {
    var sid: String
    var cluster: String?
    var proxy: String?
    var user: String?
    var login: String?
    /// Hostname, or the server id when there is none.
    var node: String?
    var nodeId: String?
    var addr: String?
    var proto: String
    var interactive: Bool
    var participants: [String]
    var recordingMode: String?
    var labels: [String: String]
    var startedAt: Double?
    var endedAt: Double?
    var durationMs: Double?
    /// A session recorded with mode "off" has no playable stream.
    var playable: Bool
    var id: String { sid }
}

/// A transcript search hit.
struct RecordingHit: Codable, Hashable, Sendable {
    var line: Int
    var text: String
    var before: [String]
    var after: [String]
}

struct RecordingMatch: Codable, Hashable, Sendable {
    var recording: Recording
    var matchCount: Int
    var hits: [RecordingHit]
    /// Transcript length (JavaScript string length).
    var bytes: Int
}

struct RecordingSearchProgress: Sendable {
    var scanned: Int
    var total: Int
    var matches: Int
    var current: String?
}

struct RecordingSearchResult: Sendable {
    var ok: Bool
    var error: String?
    var results: [RecordingMatch]
    var scanned = 0
    var failed = 0
    var total = 0
    var skippedNonInteractive = 0
    var listed = 0
    var savedTo: String?
    var stopped = false
}

/// A session going on right now (`tsh sessions ls`), livesessions.js shapes.
struct ActiveSession: Codable, Hashable, Identifiable, Sendable {
    struct Participant: Codable, Hashable, Sendable { var user: String; var mode: String }
    var id: String
    /// ssh | k8s | app | db | desktop …
    var kind: String
    /// pending | running | terminated
    var state: String
    var created: String?
    /// What the session is on, in the words its kind uses.
    var target: String
    var hostname: String
    var address: String
    var kubeCluster: String
    var cluster: String
    var login: String
    var owner: String
    var command: String
    var reason: String
    var participants: [Participant]
    var joinable: Bool
}

extension Teleport {
    // MARK: - Recordings

    /// `toRecordingDate`: `tsh recordings ls` takes `2006-01-02` only.
    static func toRecordingDate(_ value: String?) -> String? {
        guard let v = value?.trimmed, !v.isEmpty else { return nil }
        if TPText.test(#"^\d{4}-\d{2}-\d{2}$"#, v) { return v }
        guard let ms = TPText.parseDate(v) else { return nil }
        return String(TPText.isoString(ms: ms).prefix(10))
    }

    static func toRecordingDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return String(TPText.isoString(ms: date.timeIntervalSince1970 * 1000).prefix(10))
    }

    /// `listRecordings`: newest first. Always send a range — without one tsh
    /// lists only the last 24 hours.
    static func listRecordings(proxy: String?, fromUtc: String?, toUtc: String?, limit: Int? = nil,
                               home: String?) async -> TshList<Recording> {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["recordings", "ls", "--format=json"]
        if let f = toRecordingDate(fromUtc) { args.append("--from-utc=" + f) }
        if let t = toRecordingDate(toUtc) { args.append("--to-utc=" + t) }
        if let limit, limit > 0 { args.append("--limit=\(limit)") }
        let r = await run(args, home: home, timeout: 60)
        let errText = TPText.errText(r)
        // tsh exits 0 on a rejected range, so the message has to be read.
        if TPText.test("too large", errText, .caseInsensitive) {
            return .failed("That date range is larger than the cluster allows — try 180 days or less.")
        }
        if !r.ok || TPText.test("^ERROR:", errText, .caseInsensitive) {
            return .failed(errText.isEmpty ? "tsh recordings ls failed" : errText)
        }
        guard let recs = parseRecordings(r.out.isEmpty ? "[]" : r.out, proxy: proxy) else {
            return .failed("unparseable recordings output")
        }
        return TshList(ok: true, error: nil, items: recs)
    }

    static func parseRecordings(_ text: String, proxy: String?) -> [Recording]? {
        guard let raw = try? JSON.parse(text) else { return nil }
        var out = raw.items.map { e -> Recording in
            let start = TPText.parseDate(e["session_start"].string)
            let stop = TPText.parseDate(e["session_stop"].string)
            let mode = e["session_recording"].string
            return Recording(
                sid: e["sid"].stringish ?? "", cluster: e["cluster_name"].string, proxy: proxy,
                user: e["user"].string, login: e["login"].string,
                node: e["server_hostname"].string?.nilIfEmpty ?? e["server_id"].string,
                nodeId: e["server_id"].string, addr: e["server_addr"].string,
                proto: e["proto"].string?.nilIfEmpty ?? "ssh", interactive: e["interactive"].truthy,
                participants: e["participants"].items.compactMap(\.stringish), recordingMode: mode,
                labels: e["server_labels"].entries.compactMapValues(\.stringish),
                startedAt: start, endedAt: stop,
                durationMs: (start != nil && stop != nil && start != 0 && stop != 0) ? stop! - start! : nil,
                playable: mode != "off")
        }.filter { !$0.sid.isEmpty }
        out.sort { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
        return out
    }

    /// `playArgs`: replay a recording in a terminal.
    static func playArgs(_ sid: String, proxy: String?, cluster: String?, speed: String? = nil, skipIdle: Bool = false) -> [String] {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args.append("play")
        if let c = cluster?.nilIfEmpty { args.append("--cluster=" + c) }
        if let s = speed?.nilIfEmpty { args.append("--speed=" + s) }
        if skipIdle { args.append("--skip-idle-time") }
        args.append(sid)
        return args
    }

    /// `recordings:playArgs`.
    static func playCommand(_ sid: String, proxy: String?, cluster: String?, speed: String? = nil, skipIdle: Bool = false,
                            home: String?) -> TshCommand {
        TshCommand(command: tshPath, args: playArgs(sid, proxy: proxy, cluster: cluster, speed: speed, skipIdle: skipIdle),
                   teleportHome: TeleportHomes.resolve(home, proxy: proxy))
    }

    /// `playText`: a plain-text transcript.
    static func playText(_ sid: String, proxy: String?, cluster: String?, home: String?) async -> (ok: Bool, text: String, error: String?) {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["play", "--format=text"]
        if let c = cluster?.nilIfEmpty { args.append("--cluster=" + c) }
        args.append(sid)
        let r = await run(args, home: home, timeout: 120)
        let text = r.out
        // tsh exits 0 even when a recording is missing.
        if TPText.test("was not found", r.err, .caseInsensitive)
            || (text.trimmed.isEmpty && TPText.test("not found", r.err, .caseInsensitive)) {
            return (false, "", "no stored recording")
        }
        if !r.ok && text.isEmpty {
            return (false, "", (r.err.isEmpty ? (r.spawnError ?? "tsh play failed") : r.err).trimmed)
        }
        return (true, text, nil)
    }

    /// `webSessionUrl`: a recording in the Teleport web UI.
    static func webSessionUrl(proxy: String?, cluster: String?, sid: String?) -> String? {
        guard let proxy = proxy?.nilIfEmpty, let sid = sid?.nilIfEmpty else { return nil }
        let host = proxy.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        return "https://\(host)/web/cluster/\(uriComponent(cluster ?? ""))/session/\(uriComponent(sid))"
    }

    /// `recordings:openWeb`.
    @MainActor @discardableResult
    static func openWebSession(proxy: String?, cluster: String?, sid: String?) throws -> String {
        guard let url = webSessionUrl(proxy: proxy, cluster: cluster, sid: sid), let u = URL(string: url) else {
            throw AppError("Could not build a web UI link for this recording")
        }
        NSWorkspace.shared.open(u)
        return url
    }

    // MARK: - Transcript search

    struct RecordingSearch: Sendable {
        var proxy: String?
        var cluster: String?
        var fromUtc: String?
        var toUtc: String?
        var query: String
        var caseSensitive = false
        var useRegex = false
        var limit = 200
        var concurrency = 4
        var contextLines = 1
        /// Non-interactive exec sessions carry no transcript.
        var interactiveOnly = true
        var saveDir: String?
        var home: String?
        init(proxy: String? = nil, cluster: String? = nil, fromUtc: String? = nil, toUtc: String? = nil, query: String,
             caseSensitive: Bool = false, useRegex: Bool = false, limit: Int = 200, concurrency: Int = 4,
             contextLines: Int = 1, interactiveOnly: Bool = true, saveDir: String? = nil, home: String? = nil) {
            self.proxy = proxy; self.cluster = cluster; self.fromUtc = fromUtc; self.toUtc = toUtc; self.query = query
            self.caseSensitive = caseSensitive; self.useRegex = useRegex; self.limit = limit
            self.concurrency = concurrency; self.contextLines = contextLines; self.interactiveOnly = interactiveOnly
            self.saveDir = saveDir; self.home = home
        }
    }

    private static let searchCancelled = TPLocked(false)

    /// `recordings:cancelSearch`: stop the running search between sessions.
    static func cancelRecordingSearch() {
        searchCancelled.set(true)
    }

    private static var searchStopped: Bool {
        searchCancelled.get()
    }

    /// `recordings:search` / `searchRecordings`: each transcript is a `tsh
    /// play`, so it is bounded (range, cap, small concurrency) and reports
    /// progress as it goes. `onProgress` is called on a background thread.
    /// Resets the cancel flag at the start, as the handler did.
    static func searchRecordings(_ o: RecordingSearch,
                                 onProgress: (@Sendable (RecordingSearchProgress) -> Void)? = nil) async throws -> RecordingSearchResult {
        searchCancelled.set(false)
        let query = o.query
        if query.trimmed.isEmpty { throw AppError("Enter something to search for") }
        let listed = await listRecordings(proxy: o.proxy, fromUtc: o.fromUtc, toUtc: o.toUtc, home: o.home)
        if !listed.ok { return RecordingSearchResult(ok: false, error: listed.error, results: []) }

        let eligible = listed.items.filter { $0.playable && (!o.interactiveOnly || $0.interactive) }
        let skipped = listed.items.count - eligible.count
        let candidates = Array(eligible.prefix(max(0, o.limit)))
        var matcher: NSRegularExpression?
        if o.useRegex {
            do { matcher = try NSRegularExpression(pattern: query, options: o.caseSensitive ? [] : [.caseInsensitive]) }
            catch { throw AppError("Invalid regular expression: " + error.localizedDescription) }
        }
        let needle = o.caseSensitive ? query : query.lowercased()
        if let dir = o.saveDir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }

        let state = SearchState(candidates)
        let total = candidates.count
        let workers = min(o.concurrency, max(1, total))
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<max(1, workers) {
                g.addTask {
                    while true {
                        if searchStopped { return }
                        guard let rec = state.next() else { return }
                        let got = await playText(rec.sid, proxy: o.proxy, cluster: rec.cluster?.nilIfEmpty ?? o.cluster, home: o.home)
                        if !got.ok {
                            let p = state.finished(nil, failed: true, current: rec.node)
                            onProgress?(p)
                            continue
                        }
                        if let dir = o.saveDir {
                            let stamp = String(TPText.isoString(ms: rec.startedAt ?? nowMs()).prefix(19))
                                .replacingOccurrences(of: ":", with: "-")
                            let name = "\(stamp)_\(rec.node?.nilIfEmpty ?? "node")_\(rec.sid.prefix(8)).txt"
                            try? Data(got.text.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                        }
                        let lines = got.text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
                        var hits: [RecordingHit] = []
                        for (i, line) in lines.enumerated() {
                            let found: Bool
                            if let matcher { found = matcher.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
                            else { found = (o.caseSensitive ? line : line.lowercased()).contains(needle) }
                            if !found { continue }
                            let c = o.contextLines
                            hits.append(RecordingHit(
                                line: i + 1, text: TPText.clip(line, 400),
                                before: lines[max(0, i - c)..<i].map { TPText.clip($0, 400) },
                                after: lines[min(lines.count, i + 1)..<min(lines.count, i + 1 + c)].map { TPText.clip($0, 400) }))
                            if hits.count >= 50 { break }   // enough to judge relevance
                        }
                        let match = hits.isEmpty ? nil
                            : RecordingMatch(recording: rec, matchCount: hits.count, hits: hits, bytes: got.text.utf16.count)
                        let p = state.finished(match, failed: false, current: rec.node)
                        onProgress?(p)
                    }
                }
            }
        }
        var results = state.results
        results.sort { ($0.recording.startedAt ?? 0) > ($1.recording.startedAt ?? 0) }
        return RecordingSearchResult(ok: true, error: nil, results: results, scanned: state.scanned, failed: state.failed,
                                     total: total, skippedNonInteractive: skipped, listed: listed.items.count,
                                     savedTo: o.saveDir, stopped: searchStopped)
    }

    /// `recordings:saveTranscript`: ask where (in Documents by default) and
    /// write the transcript. nil when the dialog was cancelled.
    @MainActor
    static func saveTranscript(_ sid: String, proxy: String?, cluster: String?, node: String?, startedAt: Double?,
                               home: String?, window: WindowModel? = nil) async throws -> (path: String, bytes: Int)? {
        let got = await playText(sid, proxy: proxy, cluster: cluster, home: home)
        if !got.ok { throw AppError(got.error ?? "No stored recording") }
        let stamp = String(TPText.isoString(ms: startedAt ?? nowMs()).prefix(19)).replacingOccurrences(of: ":", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        guard let url = await Modal.saveFile(window, defaultName: "\(stamp)_\(node?.nilIfEmpty ?? "session")_\(sid.prefix(8)).txt",
                                             directory: docs, types: [.plainText, .log],
                                             title: "Save transcript") else { return nil }
        try Data(got.text.utf8).write(to: url)
        return (url.path, got.text.utf16.count)
    }

    /// `recordings:chooseSaveDir`: where a search should save transcripts.
    @MainActor
    static func chooseTranscriptDir(window: WindowModel? = nil) async -> String? {
        await Modal.chooseDirectory(window, prompt: "Save here", title: "Save transcripts into")?.path
    }

    // MARK: - Live sessions

    /// Kinds with a terminal on the far side (`JOINABLE_KINDS`).
    static let joinableKinds: Set<String> = ["ssh", "k8s"]
    /// `JOIN_MODES`, in the order they are offered.
    static let joinModes = ["observer", "peer", "moderator"]

    /// `listActiveSessions`: sessions going on right now on one cluster.
    static func listActiveSessions(proxy: String?, home: String?) async -> TshList<ActiveSession> {
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += ["sessions", "ls", "--format=json"]
        let r = await run(args, home: home, timeout: 30)
        if r.ok, let s = try? parseSessionList(r.out) { return TshList(ok: true, error: nil, items: s) }
        let msg = TPText.errText(r)
        return .failed(msg.isEmpty ? "tsh sessions ls failed" : msg)
    }

    /// `toActiveSession`: one session tracker.
    static func toActiveSession(_ t: JSON) -> ActiveSession {
        let s = t["spec"]
        let kind = s["kind"].stringish ?? ""
        let kube = s["kubernetes_cluster"].stringish?.nilIfEmpty ?? s["kube_cluster"].stringish ?? ""
        let stateNum = s["state"].int ?? 0
        let states = [0: "pending", 1: "running", 2: "terminated"]
        func str(_ k: String) -> String { s[k].stringish ?? "" }
        let target: String
        switch kind {
        case "k8s": target = kube
        case "app": target = str("app_name").nilIfEmpty ?? str("target_hostname")
        case "db": target = str("database_name").nilIfEmpty ?? str("target_hostname")
        case "desktop": target = str("desktop_name").nilIfEmpty ?? str("target_hostname")
        default: target = str("target_hostname").nilIfEmpty ?? str("target_address")
        }
        return ActiveSession(
            id: str("session_id").nilIfEmpty ?? t["metadata"]["name"].stringish ?? "",
            kind: kind, state: states[stateNum] ?? (s["state"].stringish ?? ""),
            created: s["created"].string, target: target, hostname: str("target_hostname"),
            address: str("target_address"), kubeCluster: kube, cluster: str("cluster_name"), login: str("login"),
            owner: str("host_user"),
            command: s["initial_command"].array.map { $0.compactMap(\.stringish).joined(separator: " ") } ?? "",
            reason: str("reason"),
            participants: s["participants"].items.map {
                ActiveSession.Participant(user: $0["user"].stringish ?? "", mode: $0["mode"].stringish ?? "")
            },
            joinable: joinableKinds.contains(kind) && stateNum != 2)
    }

    /// `parseSessionList`: newest first; `null`/empty is an empty list.
    static func parseSessionList(_ text: String) throws -> [ActiveSession] {
        let raw = text.trimmed
        if raw.isEmpty || raw == "null" { return [] }
        let body: String
        if let at = raw.firstIndex(of: "["), at != raw.startIndex { body = String(raw[at...]) } else { body = raw }
        let data = try JSON.parse(body)
        guard let arr = data.array else { return [] }
        return arr.map(toActiveSession).filter { !$0.id.isEmpty }
            .sorted { ($0.created ?? "") > ($1.created ?? "") }
    }

    /// `joinArgs`: `tsh [--proxy] join|kube join --mode=<mode> [--cluster] <id>`.
    /// An unknown mode falls back to observer, never to more access.
    static func joinArgs(_ sid: String, proxy: String?, cluster: String?, kind: String?, mode: String?) throws -> [String] {
        if sid.isEmpty { throw AppError("no session id") }
        guard let kind, joinableKinds.contains(kind) else {
            throw AppError("a \(kind?.nilIfEmpty ?? "session") session cannot be joined from a terminal")
        }
        let m = mode.flatMap { joinModes.contains($0) ? $0 : nil } ?? "observer"
        var args: [String] = []
        if let p = proxy?.nilIfEmpty { args.append("--proxy=" + p) }
        args += kind == "k8s" ? ["kube", "join"] : ["join"]
        args.append("--mode=" + m)
        if let c = cluster?.nilIfEmpty { args.append("--cluster=" + c) }
        args.append(sid)
        return args
    }

    /// `teleport:joinArgs`.
    static func joinCommand(_ sid: String, proxy: String?, cluster: String?, kind: String?, mode: String?,
                            home: String?) throws -> TshCommand {
        TshCommand(command: tshPath, args: try joinArgs(sid, proxy: proxy, cluster: cluster, kind: kind, mode: mode),
                   teleportHome: TeleportHomes.resolve(home, proxy: proxy))
    }
}

/// The shared queue and tallies of one transcript search.
private final class SearchState: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Recording]
    private(set) var results: [RecordingMatch] = []
    private(set) var scanned = 0
    private(set) var failed = 0

    init(_ candidates: [Recording]) { queue = candidates }

    func next() -> Recording? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func finished(_ match: RecordingMatch?, failed f: Bool, current: String?) -> RecordingSearchProgress {
        lock.lock(); defer { lock.unlock() }
        scanned += 1
        if f { failed += 1 }
        if let match { results.append(match) }
        return RecordingSearchProgress(scanned: scanned, total: scanned + queue.count, matches: results.count, current: current)
    }
}
