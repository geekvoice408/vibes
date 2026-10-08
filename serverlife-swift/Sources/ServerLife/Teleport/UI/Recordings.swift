import AppKit
import SwiftUI

/// recordings.js: the Sessions dialog — the local connection history,
/// Teleport's recordings (flag, note, play in a tab, web UI, open by pasted
/// session id) and a search through recorded transcripts.
///
/// Its choices (tab, cluster, filter, the two switches, the last search)
/// last for the life of the app, as the module's variables did.
@MainActor
final class RecordingsModel: ObservableObject {
    /// recordings.js kept this per renderer, so: one per window.
    static func forWindow(_ w: WindowModel?) -> RecordingsModel {
        guard let w = w ?? WindowManager.shared.focused else { return orphan }
        return w.feature(RecordingsWindowState.self).model
    }
    private static let orphan = RecordingsModel()

    @Published var tab = "history"
    @Published var filterText = ""
    @Published var recordings: [Recording] = []
    @Published var loaded = false
    @Published var loading = false
    @Published var loadError: String?
    @Published var proxy: String?
    /// Which tsh home the chosen cluster's certificate is in.
    @Published var home: String?
    /// Non-interactive (exec) sessions are hidden by default.
    @Published var showNonInteractive = false
    @Published var flaggedOnly = false
    @Published var notes: [String: JSON] = [:]
    @Published var historyVersion = 0

    // Transcript search.
    @Published var query = ""
    @Published var days = 7
    @Published var limit = "200"
    @Published var caseSensitive = false
    @Published var useRegex = false
    @Published var includeAll = false
    @Published var saveDir: String?
    @Published var running = false
    @Published var progress = ""
    @Published var searchResult: RecordingSearchResult?
    @Published var searchError: String?
    @Published var searchedQuery = ""
    @Published var searchedRegex = false
    @Published var collapsed: Set<String> = []

    weak var window: WindowModel?

    static let ranges: [(label: String, days: Int)] = [
        ("Today and yesterday", 1), ("Last 7 days", 7), ("Last 30 days", 30), ("Last 90 days", 90),
        // Teleport rejects ranges beyond roughly half a year.
        ("Last 180 days (maximum)", 180),
    ]

    var liveProfiles: [TeleportProfile] { Inventory.shared.liveProfiles }

    /// `currentKey`: the profile chosen, falling back to the first.
    func currentProfile() -> TeleportProfile? {
        let ps = liveProfiles
        return ps.first { $0.proxy == proxy && $0.homeDir == (home ?? $0.homeDir) } ?? ps.first
    }

    func choose(_ p: TeleportProfile) {
        proxy = p.proxy
        home = p.homeDir
        recordings = []; loaded = false
        loadRecordings()
    }

    func loadNotes() {
        var m: [String: JSON] = [:]
        for n in TUIData.listSessionNotes() { if let sid = n["sid"].stringish { m[sid] = n } }
        notes = m
    }

    func loadRecordings() {
        guard let p = currentProfile() else { return }
        proxy = p.proxy; home = p.homeDir
        loading = true; loadError = nil
        let px = p.proxy, h = p.homeDir
        Task { @MainActor in
            let res = await Teleport.listRecordings(proxy: px, fromUtc: nil, toUtc: nil, home: h)
            guard px == self.proxy else { return }
            self.loading = false
            if res.ok { self.recordings = res.items; self.loaded = true } else { self.loadError = res.error ?? "Could not list recordings" }
            self.loadNotes()
        }
    }

    func refresh() {
        recordings = []; loaded = false
        historyVersion += 1
        if tab == "recordings" { loadRecordings() }
    }

    // MARK: Rows

    /// A recording or a flagged session the cluster no longer lists.
    struct Row: Identifiable {
        var sid: String
        var cluster: String?
        var proxy: String?
        var home: String?
        var node: String?
        var user: String?
        var login: String?
        var startedAt: Double?
        var durationMs: Double?
        var playable: Bool
        var interactive: Bool
        var fromNote = false
        var id: String { sid }

        init(_ r: Recording) {
            sid = r.sid; cluster = r.cluster; proxy = r.proxy; node = r.node; user = r.user; login = r.login
            startedAt = r.startedAt; durationMs = r.durationMs; playable = r.playable; interactive = r.interactive
        }

        init(note n: JSON, proxy px: String?) {
            sid = n["sid"].stringish ?? ""; cluster = n["cluster"].stringish; proxy = n["proxy"].stringish?.nilIfEmpty ?? px
            home = n["home"].stringish; node = n["node"].stringish; user = n["user"].stringish; login = n["login"].stringish
            startedAt = n["startedAt"].double; durationMs = n["durationMs"].double
            playable = n["playable"].bool ?? true; interactive = true; fromNote = true
        }

        init(sid: String, proxy: String?, home: String?) {
            self.sid = sid; self.proxy = proxy; self.home = home; playable = true; interactive = true
        }
    }

    func matches(_ r: Row) -> Bool {
        let f = filterText.trimmed.lowercased()
        if f.isEmpty { return true }
        return [r.node, r.login, r.user, r.sid, r.cluster, notes[r.sid]?["note"].stringish]
            .compactMap { $0?.nilIfEmpty }.joined(separator: " ").lowercased().contains(f)
    }

    var hiddenExec: Int { recordings.filter { !$0.interactive }.count }

    var shownRows: [Row] {
        var shown = recordings.filter { showNonInteractive || $0.interactive }.map(Row.init).filter(matches)
        if flaggedOnly {
            // Flagged sessions are shown even when the cluster no longer lists them.
            let inList = Set(shown.map(\.sid))
            let saved = notes.values.filter { $0["flagged"].truthy && !inList.contains($0["sid"].stringish ?? "") }
                .filter { n in proxy == nil || (n["proxy"].stringish ?? "").isEmpty || n["proxy"].stringish == proxy }
                .map { Row(note: $0, proxy: proxy) }.filter(matches)
            shown = (shown.filter { notes[$0.sid]?["flagged"].truthy == true } + saved)
                .sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
        }
        return shown
    }

    /// `sidLookup`: a pasted session id that is not in the loaded range.
    var pastedSid: String? {
        let sid = filterText.trimmed
        guard TPText.test(#"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, sid, .caseInsensitive) else { return nil }
        if recordings.contains(where: { $0.sid.lowercased() == sid.lowercased() }) { return nil }
        return sid
    }

    /// `recordKey`: what a saved note keeps about its session.
    func recordKey(_ r: Row) -> JSON {
        ["sid": .string(r.sid), "cluster": .string(r.cluster ?? ""), "proxy": .string(r.proxy ?? proxy ?? ""),
         "home": JSON(r.home ?? home), "node": .string(r.node ?? ""), "user": .string(r.user ?? ""),
         "login": .string(r.login ?? ""), "startedAt": JSON(r.startedAt), "durationMs": JSON(r.durationMs),
         "playable": .bool(r.playable)]
    }

    func toggleFlag(_ r: Row) {
        var rec = recordKey(r)
        rec["flagged"] = .bool(!(notes[r.sid]?["flagged"].truthy ?? false))
        TUIData.upsertSessionNote(rec)
        loadNotes()
    }

    // MARK: Search

    func runSearch() {
        let q = query.trimmed
        if q.isEmpty { TUIStatus.toast("Enter something to search for", "error"); return }
        if running { return }
        guard let p = currentProfile() else { return }
        proxy = p.proxy; home = p.homeDir
        running = true
        searchResult = nil; searchError = nil
        progress = "Listing recordings…"
        searchedQuery = q; searchedRegex = useRegex
        let from = String(TPText.isoString(ms: nowMs() - Double(days == 0 ? 180 : days) * 86_400_000).prefix(10))
        let spec = Teleport.RecordingSearch(proxy: p.proxy, fromUtc: from, query: q, caseSensitive: caseSensitive,
                                            useRegex: useRegex, limit: { let n = Int(limit.trimmed) ?? 0; return n > 0 ? n : 200 }(), contextLines: 1,
                                            interactiveOnly: !includeAll, saveDir: saveDir, home: p.homeDir)
        Task { @MainActor in
            do {
                let me = self
                let res = try await Teleport.searchRecordings(spec) { pr in
                    let text = "Scanned \(pr.scanned)/\(pr.total) — \(pr.matches) matching" + (pr.current.map { " · " + $0 } ?? "")
                    Task { @MainActor in
                        if me.running { me.progress = text }
                    }
                }
                if !res.ok {
                    self.searchError = res.error ?? "Search failed"
                    self.progress = ""
                } else {
                    self.searchResult = res
                    self.progress = [
                        "\(res.results.count) session\(res.results.count == 1 ? "" : "s") matched",
                        "\(res.scanned) scanned",
                        res.failed > 0 ? "\(res.failed) without a stored recording" : nil,
                        res.skippedNonInteractive > 0 ? "\(res.skippedNonInteractive) non-interactive skipped" : nil,
                        res.savedTo.map { "transcripts saved to \($0)" },
                        res.stopped ? "stopped early" : nil,
                    ].compactMap { $0 }.joined(separator: " · ")
                }
            } catch {
                self.progress = ""
                self.searchError = error.localizedDescription
            }
            self.running = false
        }
    }

    func stopSearch() {
        Teleport.cancelRecordingSearch()
        progress = "Stopping…"
    }
}

@MainActor
enum RecordingsUI {
    /// `openSessionsDialog(initialTab, { filter, proxy, home })`.
    static func open(tab: String = "history", filter: String? = nil, proxy: String? = nil, home: String? = nil,
                     window: WindowModel? = nil) {
        let m = RecordingsModel.forWindow(window)
        m.window = window ?? WindowManager.shared.focused
        m.tab = tab
        // Opening this for one host should land on that host.
        if let filter { m.filterText = filter.lowercased() }
        if let proxy { m.proxy = proxy; m.home = home; m.recordings = []; m.loaded = false }
        m.historyVersion += 1
        if tab == "recordings" && !m.loaded { m.loadRecordings() }
        m.loadNotes()
        Modal.sheet(window, title: "Sessions", width: 920, height: 660, resizable: true, autosave: "sessions") { handle in
            SessionsDialogView(m: m, handle: handle)
        }
    }

    /// `playRecording`: replay in a local tab via `tsh play`.
    static func play(_ r: RecordingsModel.Row, _ m: RecordingsModel) {
        let window = m.window
        let cmd = Teleport.playCommand(r.sid, proxy: r.proxy ?? m.proxy, cluster: r.cluster, home: r.home ?? m.home)
        cmd.open(title: "\u{25B6} \(r.node?.nilIfEmpty ?? "recording") · \(r.sid.prefix(8))", window: window)
        TUIStatus.show("Replaying session \(r.sid.prefix(8))")
    }

    /// `openInWeb`.
    static func openInWeb(_ r: RecordingsModel.Row, _ m: RecordingsModel) {
        do {
            let url = try Teleport.openWebSession(proxy: r.proxy ?? m.proxy, cluster: r.cluster, sid: r.sid)
            TUIStatus.show("Opened in browser: " + url)
        } catch {
            TUIStatus.toast(error.localizedDescription, "error")
        }
    }

    /// `editSessionNote`: write (or clear) the note on a session.
    static func editNote(_ r: RecordingsModel.Row, _ m: RecordingsModel) async {
        let window = m.window
        let existing = m.notes[r.sid]
        let text = Local(existing?["note"].stringish ?? "")
        let flag = Local(existing?["flagged"].bool != false)
        let sub = [r.node ?? "", r.user ?? "", r.startedAt.map { Fmt.date(ms: $0) } ?? "", String(r.sid.prefix(8))]
            .filter { !$0.isEmpty }.joined(separator: "  ·  ")
        let res: String? = await TUIModal.ask(window, title: "Note on a session", width: 620) { finish, _ in
            NoteEditorView(subtitle: sub, hasExisting: existing != nil, text: text, flag: flag, finish: finish)
        }
        guard let res else { return }
        if res == "delete" {
            TUIData.deleteSessionNote(r.sid)
        } else {
            var rec = m.recordKey(r)
            rec["note"] = .string(text.value.trimmed)
            rec["flagged"] = .bool(flag.value)
            TUIData.upsertSessionNote(rec)
        }
        m.loadNotes()
    }
}

// MARK: - Views

private struct SessionsDialogView: View {
    @ObservedObject var m: RecordingsModel
    let handle: ModalHandle

    var body: some View {
        DialogScaffold(title: "Sessions", subtitle: "History and recordings", scroll: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 2) {
                    tabButton("history", "Connection history")
                    tabButton("recordings", "Teleport recordings")
                    tabButton("search", "Search transcripts")
                    Spacer()
                }
                if m.tab != "search" { SearchField(placeholder: "Filter…", text: $m.filterText) }
                ScrollView {
                    Group {
                        switch m.tab {
                        case "history": HistoryTab(m: m)
                        case "search": TranscriptSearchTab(m: m)
                        default: RecordingsTab(m: m)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        } footer: {
            Button("Refresh") { m.refresh() }.buttonStyle(.ghost)
            Button("Close") { handle.close() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
        }
    }

    private func tabButton(_ key: String, _ label: String) -> some View {
        let p = Theme.shared.p
        let on = m.tab == key
        return Button {
            m.tab = key
            if key == "recordings" && !m.loaded && !m.loading { m.loadRecordings() }
        } label: {
            Text(label).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? p.text : p.textDim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(alignment: .bottom) { (on ? p.accent : Color.clear).frame(height: 2) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct HistoryTab: View {
    @ObservedObject var m: RecordingsModel

    var body: some View {
        let pal = Theme.shared.p
        let _ = m.historyVersion
        let entries = TUIData.listHistory(limit: 300)
        let f = m.filterText.trimmed.lowercased()
        let shown = entries.filter { h in
            f.isEmpty || ["label", "node", "cluster", "login", "target", "hostname"].compactMap { h[$0].stringish?.nilIfEmpty }
                .joined(separator: " ").lowercased().contains(f)
        }
        if shown.isEmpty {
            TUIEmpty(lines: [entries.isEmpty ? "No sessions recorded yet." : "No matches."])
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Spacer()
                    Button("Clear history") {
                        Task { @MainActor in
                            guard await MiscUI.confirm(m.window, title: "Clear history", message: "Delete the local session history?",
                                                       detail: "The addresses Quick connect offers back go with it. Teleport\u{2019}s own audit log is unaffected.",
                                                       confirmLabel: "Clear", danger: true) else { return }
                            TUIData.clearHistory()
                            // Quick connect's typed addresses go too, or "clear history" did not.
                            TUIData.clearQuickConnectHistory()
                            m.historyVersion += 1
                        }
                    }.buttonStyle(GhostButtonStyle(small: true, destructive: true))
                }
                .padding(.bottom, 6)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, h in
                    let ended = h["endedAt"].double
                    let err = h["error"].stringish?.nilIfEmpty
                    let live = ended == nil && err == nil
                    let started = h["startedAt"].double ?? 0
                    let dur = ended.map { Fmt.duration(ms: $0 - started) } ?? (live ? "open" : "")
                    let meta = [h["type"].string == "teleport" ? "tsh · \(h["cluster"].stringish ?? "")" : "ssh",
                                h["login"].stringish?.nilIfEmpty.map { "as " + $0 } ?? "",
                                err.map { "failed: " + $0 } ?? ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                    HStack(spacing: 10) {
                        TUIDot(color: err != nil ? pal.red : live ? pal.green : nil)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h["label"].stringish?.nilIfEmpty ?? h["target"].stringish ?? "").font(.system(size: 12.5))
                            Text(meta).font(.system(size: 11)).foregroundStyle(pal.muted)
                        }
                        Spacer()
                        Text(Fmt.date(ms: started)).font(.system(size: 11)).foregroundStyle(pal.muted).frame(width: 120, alignment: .trailing)
                        Text(dur).font(.system(size: 11)).foregroundStyle(pal.muted).frame(width: 64, alignment: .trailing)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(pal.panel2))
                }
            }
        }
    }
}

private struct ProfileChooser: View {
    @ObservedObject var m: RecordingsModel
    var reload = true

    var body: some View {
        let ps = m.liveProfiles
        let cur = m.currentProfile()
        TUIField(label: "Cluster") {
            Picker("", selection: Binding(get: { cur?.key ?? "" }, set: { k in
                if let p = ps.first(where: { $0.key == k }) {
                    if reload { m.choose(p) } else { m.proxy = p.proxy; m.home = p.homeDir }
                }
            })) {
                ForEach(ps, id: \.key) { p in Text(TUI.name(p) + (p.homeName.isEmpty ? "" : " · " + p.homeName)).tag(p.key) }
            }.labelsHidden().frame(maxWidth: 360, alignment: .leading)
        }
    }
}

private struct RecordingsTab: View {
    @ObservedObject var m: RecordingsModel

    var body: some View {
        let pal = Theme.shared.p
        if m.liveProfiles.isEmpty {
            TUIEmpty(lines: ["No active Teleport profile. Log in first."])
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ProfileChooser(m: m)
                if m.loading && !m.loaded {
                    TUIEmpty(lines: ["Loading recordings…"])
                } else if let e = m.loadError {
                    TUIEmpty(lines: [e], error: true)
                } else {
                    HStack(spacing: 16) {
                        MiscCheck(label: "Include non-interactive (exec) sessions", isOn: $m.showNonInteractive)
                        MiscCheck(label: "Flagged only", isOn: $m.flaggedOnly)
                    }
                    let rows = m.shownRows
                    if rows.isEmpty {
                        TUIEmpty(lines: [m.flaggedOnly ? "Nothing flagged yet."
                                         : (m.recordings.isEmpty ? "No recordings found for this cluster." : "No matches.")]
                                 + (m.flaggedOnly ? ["Flag a recording with its \u{2606} to keep it here."]
                                    : (m.hiddenExec > 0 && !m.showNonInteractive
                                       ? ["\(m.hiddenExec) non-interactive session(s) are hidden — tick the box above to include them."] : [])))
                    } else {
                        VStack(spacing: 2) { ForEach(rows) { row($0) } }
                        if !m.showNonInteractive && m.hiddenExec > 0 {
                            MiscHint(text: "\(m.hiddenExec) non-interactive session(s) hidden.", size: 11).padding(.top, 8)
                        }
                    }
                    if let sid = m.pastedSid { SidLookup(sid: sid, m: m) }
                }
            }
            .foregroundStyle(pal.text)
            // Opened before the inventory had any profile: load once it has.
            .task(id: m.liveProfiles.map(\.key)) {
                if !m.loaded && !m.loading && m.loadError == nil { m.loadRecordings() }
            }
        }
    }

    private func row(_ r: RecordingsModel.Row) -> some View {
        let pal = Theme.shared.p
        let note = m.notes[r.sid]
        let flagged = note?["flagged"].truthy == true
        let noteText = note?["note"].stringish ?? ""
        return HStack(spacing: 10) {
            // Flagging is one click, on the row.
            Button(flagged ? "\u{2605}" : "\u{2606}") { m.toggleFlag(r) }
                .buttonStyle(IconButtonStyle(active: flagged))
                .help(flagged ? "Flagged — click to unflag" : "Flag this session to come back to it")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(r.node?.nilIfEmpty ?? "unknown node").font(.system(size: 12.5))
                    TUITag(text: r.fromNote ? "outside the range" : (r.interactive ? "interactive" : "exec"))
                    if !r.playable { TUITag(text: "not recorded", kind: .warn) }
                }
                Text(["\(r.user ?? "") \u{2192} \(r.login ?? "")", r.durationMs.map { Fmt.duration(ms: $0) } ?? "",
                      String(r.sid.prefix(8))].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 11)).foregroundStyle(pal.muted)
                if !noteText.isEmpty {
                    Text(noteText).font(.system(size: 11)).foregroundStyle(pal.accent).lineLimit(1).help(noteText)
                }
            }
            Spacer(minLength: 0)
            Text(Fmt.date(ms: r.startedAt)).font(.system(size: 11)).foregroundStyle(pal.muted).frame(width: 118, alignment: .trailing)
            Button(noteText.isEmpty ? "Note…" : "Note \u{270E}") { Task { await RecordingsUI.editNote(r, m) } }
                .buttonStyle(.ghostSmall).help(noteText.nilIfEmpty ?? "Write a note about this session")
            Button("Play") { RecordingsUI.play(r, m) }.buttonStyle(.ghostSmall)
                .disabled(!r.playable).help(!r.playable ? "This session was not recorded" : "Replay in a local tab")
            Button("Web UI") { RecordingsUI.openInWeb(r, m) }.buttonStyle(.ghostSmall).help("Open in the Teleport web UI")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4).fill(flagged ? pal.amber.opacity(0.08) : pal.panel2))
    }
}

/// "That looks like a session id": open a recording by id alone.
private struct SidLookup: View {
    let sid: String
    @ObservedObject var m: RecordingsModel
    var body: some View {
        let pal = Theme.shared.p
        let rec = RecordingsModel.Row(sid: sid, proxy: m.proxy, home: m.home)
        VStack(alignment: .leading, spacing: 6) {
            Text("That looks like a session id").font(.system(size: 12, weight: .semibold))
            Text("It is not in the range loaded here, but a recording can be opened by id alone.")
                .font(.system(size: 11.5)).foregroundStyle(pal.textDim)
            HStack(spacing: 6) {
                Button("Play it") { RecordingsUI.play(rec, m) }.buttonStyle(GhostButtonStyle(small: true, prominent: true))
                Button("Open in web UI") { RecordingsUI.openInWeb(rec, m) }.buttonStyle(.ghostSmall)
                Button("Flag it with a note…") { Task { await RecordingsUI.editNote(rec, m) } }.buttonStyle(.ghostSmall)
            }.padding(.top, 3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(pal.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(pal.accent.opacity(0.35)))
        .padding(.top, 10)
    }
}

private struct NoteEditorView: View {
    let subtitle: String
    let hasExisting: Bool
    @ObservedObject var text: Local<String>
    @ObservedObject var flag: Local<Bool>
    let finish: (String?) -> Void

    var body: some View {
        DialogScaffold(title: "Note on a session", subtitle: subtitle, scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                MiscHint(text: "Kept against the session id, so it survives the recording falling out of the range the cluster will list.", size: 11)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text.value).font(.system(size: 12)).frame(height: 100)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.shared.p.bg))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.shared.p.border))
                    if text.value.isEmpty {
                        Text("What happened here, and why you might want it again.").font(.system(size: 12))
                            .foregroundStyle(Theme.shared.p.muted).padding(.horizontal, 9).padding(.vertical, 5).allowsHitTesting(false)
                    }
                }
                MiscCheck(label: "Keep it flagged", isOn: $flag.value)
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            if hasExisting { Button("Remove") { finish("delete") }.buttonStyle(GhostButtonStyle(destructive: true)) }
            Button("Save") { finish("save") }.buttonStyle(.primary)
        }
        .frame(width: 620)
    }
}

private struct TranscriptSearchTab: View {
    @ObservedObject var m: RecordingsModel

    var body: some View {
        let pal = Theme.shared.p
        if m.liveProfiles.isEmpty {
            TUIEmpty(lines: ["No active Teleport profile. Log in first."])
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    ProfileChooser(m: m, reload: false)
                    TUIField(label: "Time range") {
                        Picker("", selection: $m.days) {
                            ForEach(RecordingsModel.ranges, id: \.days) { Text($0.label).tag($0.days) }
                        }.labelsHidden()
                    }
                    TUIField(label: "Max sessions") {
                        TextField("200", text: $m.limit).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                }
                TUIField(label: "Find", hint: "Searches the text of each recorded session") {
                    TextField("sudo, systemctl restart, a hostname…", text: $m.query).textFieldStyle(.roundedBorder)
                        .onSubmit { m.runSearch() }
                }
                HStack(spacing: 14) {
                    MiscCheck(label: "Match case", isOn: $m.caseSensitive)
                    MiscCheck(label: "Regular expression", isOn: $m.useRegex)
                    MiscCheck(label: "Include non-interactive sessions (usually have no transcript)", isOn: $m.includeAll)
                }
                HStack(spacing: 8) {
                    Button("Download to folder…") {
                        Task { @MainActor in if let d = await Teleport.chooseTranscriptDir(window: m.window) { m.saveDir = d } }
                    }.buttonStyle(.ghostSmall).help("Also write every transcript scanned into a folder")
                    Button("Don\u{2019}t save") { m.saveDir = nil }.buttonStyle(.ghostSmall)
                    Text(m.saveDir ?? "not saving").font(.system(size: 11)).foregroundStyle(pal.muted).lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 10)
                HStack(spacing: 8) {
                    if m.running {
                        Button("Stop") { m.stopSearch() }.buttonStyle(.ghost)
                    } else {
                        Button("Search") { m.runSearch() }.buttonStyle(.primary)
                    }
                }
                if !m.progress.isEmpty { MiscHint(text: m.progress, size: 11).padding(.vertical, 10) }
                if let e = m.searchError { TUIEmpty(lines: [e], error: true) }
                if let res = m.searchResult { results(res) }
            }
        }
    }

    @ViewBuilder private func results(_ res: RecordingSearchResult) -> some View {
        let pal = Theme.shared.p
        if res.results.isEmpty {
            TUIEmpty(lines: ["No session mentioned \u{201C}\(m.searchedQuery)\u{201D}."]
                     + (res.skippedNonInteractive > 0
                        ? ["\(res.skippedNonInteractive) non-interactive session(s) were skipped — tick the box above to include them."] : []))
        } else {
            VStack(spacing: 8) {
                ForEach(res.results, id: \.recording.sid) { r in
                    let rec = r.recording
                    let row = RecordingsModel.Row(rec)
                    let open = !m.collapsed.contains(rec.sid)
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            if open { m.collapsed.insert(rec.sid) } else { m.collapsed.remove(rec.sid) }
                        } label: {
                            HStack(spacing: 8) {
                                TUIDot(color: pal.green)
                                Text("\(rec.node?.nilIfEmpty ?? "unknown") — \(rec.user ?? "") \u{2192} \(rec.login ?? "")")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(r.matchCount) match\(r.matchCount == 1 ? "" : "es") · \(Fmt.date(ms: rec.startedAt)) · \(Fmt.duration(ms: rec.durationMs))")
                                    .font(.system(size: 11)).foregroundStyle(pal.muted)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if open {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(r.hits.prefix(12).enumerated()), id: \.offset) { _, h in
                                    ForEach(Array(h.before.enumerated()), id: \.offset) { _, b in Text("  " + b).opacity(0.45) }
                                    highlight(h.text)
                                    ForEach(Array(h.after.enumerated()), id: \.offset) { _, a in Text("  " + a).opacity(0.45) }
                                    Color.clear.frame(height: 6)
                                }
                                if r.matchCount > 12 { Text("… \(r.matchCount - 12) more matches in this session").opacity(0.6) }
                            }
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.bottom, 6)
                        }
                        HStack(spacing: 6) {
                            Button("Play") { RecordingsUI.play(row, m) }.buttonStyle(.ghostSmall)
                            Button("Web UI") { RecordingsUI.openInWeb(row, m) }.buttonStyle(.ghostSmall)
                            Button("Save transcript…") {
                                Task { @MainActor in
                                    do {
                                        if let out = try await Teleport.saveTranscript(rec.sid, proxy: rec.proxy ?? m.proxy, cluster: rec.cluster,
                                                                                       node: rec.node, startedAt: rec.startedAt,
                                                                                       home: m.home, window: m.window) {
                                            TUIStatus.show("Saved \(out.path)")
                                            TUIStatus.toast("Transcript saved", "success")
                                        }
                                    } catch { TUIStatus.toast(error.localizedDescription, "error") }
                                }
                            }.buttonStyle(.ghostSmall)
                            Spacer()
                            Text(String(rec.sid.prefix(8))).font(.system(size: 11)).foregroundStyle(pal.muted)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(pal.panel2)
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(pal.bg))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(pal.border))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    /// Mark the matched term inside a line so the eye lands on it.
    private func highlight(_ line: String) -> Text {
        let pattern = m.searchedRegex ? m.searchedQuery : NSRegularExpression.escapedPattern(for: m.searchedQuery)
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return Text(line) }
        var out = Text("")
        var last = line.startIndex
        for match in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let r = Range(match.range, in: line), !r.isEmpty else { continue }
            if r.lowerBound > last { out = out + Text(line[last..<r.lowerBound]) }
            var a = AttributedString(String(line[r]))
            a.backgroundColor = Theme.shared.p.amber
            a.foregroundColor = .black
            out = out + Text(a)
            last = r.upperBound
        }
        return out + Text(line[last...])
    }
}

/// The Sessions dialog's state for one window.
@MainActor
final class RecordingsWindowState: WindowFeature {
    let model = RecordingsModel()
    init(window: WindowModel) { model.window = window }
}
