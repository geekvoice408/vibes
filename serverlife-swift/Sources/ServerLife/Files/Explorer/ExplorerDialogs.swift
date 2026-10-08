import AppKit
import SwiftUI

// The explorer's dialogs: Go to a path, Search, Permissions and owner, Get
// info (with "What do these permissions mean?"), the inline editor, "Which
// list?", and Copy to another server.

@MainActor
enum XPDialogs {
    /// "Which list?" — the explorers compare/sync/copy could mean.
    static func pickList(_ owner: WindowModel?, title: String, subtitle: String, candidates: [ExplorerModel],
                         s3Labels: Bool) async -> ExplorerModel? {
        let ids = await XPDialog.present(owner, title: title, width: 460) { (done: @escaping (String?) -> Void) in
            AnyView(DialogScaffold(title: title, subtitle: subtitle) {
                XPPickerList {
                    ForEach(candidates, id: \.id) { e in
                        XPPickerRow(name: label(for: e, s3: s3Labels),
                                    meta: s3Labels ? (e.view.path?.nilIfEmpty ?? "/") : (e.view.path ?? "")) { done(e.id) }
                    }
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            })
        }
        return ids.flatMap { id in candidates.first { $0.id == id } }
    }

    static func label(for e: ExplorerModel, s3: Bool) -> String {
        if e.isS3 { return "S3: " + (e.s3Id.flatMap { XPS3.bucketName($0) } ?? e.s3Id ?? "") }
        if e.isLocal { return s3 ? "Local machine" : "This machine" }
        return e.conn?.label ?? (s3 ? "session" : "Session")
    }

    // MARK: - Go to a path

    static func goToPath(_ ex: ExplorerModel) async {
        let local = ex.isLocal
        let home = NSHomeDirectory()
        let places: [(String, String)] = local
            ? [("Home", home), ("Desktop", home + "/Desktop"), ("Downloads", home + "/Downloads"),
               ("Documents", home + "/Documents"), ("Root", "/"), ("Temp", "/tmp")]
            : [("Home", ex.conn?.homeDir ?? "."), ("Root", "/"), ("Logs", "/var/log"), ("Config", "/etc"),
               ("Temp", "/tmp"), ("Web root", "/var/www"), ("Services", "/etc/systemd/system"), ("Opt", "/opt")]
        let view = ex.view
        var seen = Set<String>()
        let recent = view.history.suffix(8).reversed().filter { seen.insert($0).inserted }.filter { $0 != view.path }
        let subtitle = local ? "Local machine" : (ex.conn?.label ?? "Remote")
        // The dialog opens at once; the starred list fills in when it is known.
        let chosen = await XPDialog.present(ex.window, title: "Go to path", width: 520) { (done: @escaping (String?) -> Void) in
            AnyView(GoToPathView(ex: ex, subtitle: subtitle, initial: view.path ?? "", places: places,
                                 recent: Array(recent), favs: [], done: done))
        }
        if let chosen, !chosen.isEmpty { try? await ex.navigate(chosen) }
    }

    // MARK: - Permissions and owner

    /// Permissions and ownership, for one entry or a selection. A single mode
    /// on a single file goes through SFTP; anything else — recursion, an
    /// owner, a group — is chmod/chown over the session, shown before it runs.
    static func permissions(_ ex: ExplorerModel, _ entries: [FileEntry]) async {
        let list = entries
        guard !list.isEmpty, let connId = ex.connId else { return }
        let one = list.count == 1 ? list[0] : nil
        let anyDir = list.contains(where: XP.isDir)
        let state = PermState(mode: one.map { XP.octal($0.mode) } ?? "", owner: one?.owner ?? "", group: one?.group ?? "")
        let paths = list.map(\.path)
        let go = await XPDialog.present(ex.window, title: "Permissions and owner", width: 620) { (done: @escaping (Bool?) -> Void) in
            AnyView(PermissionsView(state: state, one: one, count: list.count, anyDir: anyDir, paths: paths, done: done))
        }
        guard go == true else { return }
        let out = XP.permissionCommands(paths: paths, mode: state.mode, owner: state.owner, group: state.group,
                                        recursive: state.recursive)
        if out.isEmpty { return }
        let mode = state.mode.trimmed

        // The one case that needs no shell at all.
        if out.count == 1 && !mode.isEmpty && !state.recursive, let one {
            do {
                guard let m = UInt32(mode, radix: 8) else { throw AppError("\(mode) is not an octal mode") }
                try await FilesService.shared.chmod(connId, one.path, mode: m)
                xpStatus("Set \(mode) on \(one.name)")
                await ex.refresh()
            } catch { xpToast(errorText(error), "error") }
            return
        }

        xpStatus("Applying…", 0)
        do {
            let res = try await FilesBridge.run(connId, XP.permissionScript(out))
            let text = res.replacingOccurrences(of: "__ok__", with: "").trimmed
            if !text.isEmpty { xpToast(text.components(separatedBy: "\n").prefix(4).joined(separator: "\n"), "error", 9000) }
            else { xpStatus("Applied to \(one?.name ?? "\(list.count) items")") }
            await ex.refresh()
        } catch {
            xpToast(errorText(error), "error", 9000)
        }
        // finally { status('') } — but not over the message just shown.
        if StatusBus.shared.message?.text == "Applying…" { xpStatus("") }
    }

    // MARK: - Get info

    static func info(_ ex: ExplorerModel, _ entry: FileEntry) async {
        let folder = XP.isDir(entry)
        let st = XPInfoState()
        st.put("Path", entry.path)
        st.total = "Reading…"
        let load = Task { @MainActor in
            do {
                let sizeUp: (() async -> Void)?
                if ex.isS3 { sizeUp = try await XPS3.info(ex, entry, st) }
                else if ex.isLocal { sizeUp = try await localInfo(entry, st) }
                else { sizeUp = try await remoteInfo(ex, entry, st) }
                st.sizeUp = sizeUp
            } catch {
                st.total = ""
                st.error = errorText(error)
            }
            st.loaded = true
        }
        _ = await XPDialog.present(ex.window, title: entry.name.nilIfEmpty ?? entry.path, width: 560) { (done: @escaping (Bool?) -> Void) in
            AnyView(InfoView(title: entry.name.nilIfEmpty ?? entry.path, subtitle: folder ? "Folder" : "File",
                             folder: folder, st: st, done: done))
        }
        _ = await load.value
    }

    private static func localInfo(_ entry: FileEntry, _ st: XPInfoState) async throws -> (() async -> Void)? {
        let d = try await LocalFS.info(entry.path)
        st.perms = (d.mode, d.modeString, d.owner ?? String(d.uid), d.group ?? String(d.gid))
        st.put("Type", d.type.rawValue + (d.target.map { " → " + $0 } ?? ""))
        st.put("Size", Fmt.bytes(d.size) + (d.size >= 1024 ? " (\(d.size.formatted()) bytes)" : ""))
        st.put("Permissions", XP.permText(mode: d.mode, modeString: d.modeString))
        st.put("Owner", XP.ownerText(owner: d.owner, group: d.group, uid: d.uid, gid: d.gid)
               + (d.owner != nil || d.group != nil ? " (uid \(d.uid), gid \(d.gid))" : ""))
        st.put("Modified", Fmt.date(ms: d.mtime))
        st.put("Accessed", d.atime > 0 ? Fmt.date(ms: d.atime) : nil)
        st.put("Changed", d.ctime > 0 ? Fmt.date(ms: d.ctime) : nil)
        st.put("Created", d.birthtime > 0 ? Fmt.date(ms: d.birthtime) : nil)
        st.put("Links", String(d.links))
        if let f = d.files { st.put("Contains", "\(f) file(s), \(d.dirs ?? 0) folder(s) directly inside") }
        st.total = d.type == .directory ? "Total size not calculated yet." : ""
        guard d.type == .directory else { return nil }
        return { @MainActor in
            st.total = "Adding up…"
            let t = await LocalFS.treeSize(entry.path)
            st.total = "\(Fmt.bytes(t.bytes)) in \(t.files.formatted()) file(s)"
                + " across \(t.dirs.formatted()) folder(s)\(t.truncated ? " — stopped early, this is a floor" : "")"
        }
    }

    private static func remoteInfo(_ ex: ExplorerModel, _ entry: FileEntry, _ st: XPInfoState) async throws -> (() async -> Void)? {
        guard let connId = ex.connId else { throw AppError("No session for that pane") }
        let out = try await FilesBridge.run(connId, XP.remoteInfoCommand(entry.path))
        let d = XP.parseKv(out)
        st.put("Type", (d["kind"] ?? "") + (d["link"].map { " → " + $0 } ?? ""))
        if let s = d["size"], !s.isEmpty, let n = Double(s) { st.put("Size", Fmt.bytes(n) + " (\(Int64(n).formatted()) bytes)") }
        let oct = UInt32(d["oct"] ?? "0", radix: 8) ?? 0
        st.perms = (oct, d["mode"]?.nilIfEmpty ?? entry.modeString, d["owner"]?.nilIfEmpty, d["group"]?.nilIfEmpty)
        st.put("Permissions", XP.permText(mode: oct, modeString: d["mode"]))
        st.put("Owner", [d["owner"], d["group"]].compactMap { $0?.nilIfEmpty }.joined(separator: ":"))
        if let m = d["mtime"], let n = Double(m) { st.put("Modified", Fmt.date(ms: n * 1000)) }
        if let a = d["atime"], let n = Double(a), n != 0 { st.put("Accessed", Fmt.date(ms: n * 1000)) }
        st.put("Links", d["links"])
        st.put("Inode", d["inode"])
        if let f = d["files"] { st.put("Contains", "\(f) file(s), \(d["dirs"] ?? "") folder(s) directly inside") }
        st.put("Filesystem", d["fs"])
        guard XP.isDir(entry) else { st.total = ""; return nil }
        st.total = "Total size not calculated yet — it runs du on the host."
        return { @MainActor in
            st.total = "Running du…"
            do {
                let r = try await FilesBridge.run(connId, XP.remoteSizeCommand(entry.path))
                let parts = r.trimmed.components(separatedBy: "\n")
                let kb = Double(parts.first?.trimmed ?? "") ?? 0
                let count = Int(parts.count > 1 ? parts[1].trimmed : "") ?? 0
                st.total = "\(Fmt.bytes(kb * 1024)) in \(count.formatted()) entries"
            } catch { st.total = errorText(error) }
        }
    }

    // MARK: - The inline editor

    /// A small text file in the app's own editor — over SFTP, or the local
    /// filesystem for *Open as text*.
    static func editor(_ ex: ExplorerModel, _ entry: FileEntry, local: Bool) async {
        let text: String
        do {
            if local { text = try await LocalFS.readText(entry.path).text }
            else {
                guard let connId = ex.connId else { return }
                text = try await FilesService.shared.readFile(connId, entry.path)
            }
        } catch { xpToast(errorText(error), "error"); return }
        let connId = ex.connId
        let buf = Local(text)
        _ = await XPDialog.present(ex.window, title: entry.name, width: 920, height: 640, resizable: true,
                                   autosave: "explorer-editor") { (done: @escaping (Bool?) -> Void) in
            AnyView(EditorView(name: entry.name, path: entry.path, buf: buf, done: done) {
                do {
                    if local { try LocalFS.writeText(entry.path, buf.value) }
                    else if let connId { try await FilesService.shared.writeFile(connId, entry.path, buf.value) }
                    xpStatus("Saved " + entry.name)
                    done(true)
                    Task { await ex.refresh() }
                } catch { xpToast(errorText(error), "error") }
            })
        }
    }

    // MARK: - Copy to another server

    static func copyToServer(_ ex: ExplorerModel, srcConn: String, entries: [FileEntry]) async {
        let candidates = XPConn.all.filter { $0.id != srcConn && $0.connected }
        guard !candidates.isEmpty else { xpToast("Open a session on the other server first", "error"); return }
        let st = CopyState(chosen: candidates[0])
        st.check(srcConn)
        let res = await XPDialog.present(ex.window, title: "Copy to another server", width: 520) { (done: @escaping ((String, String)?) -> Void) in
            AnyView(CopyToServerView(st: st, candidates: candidates, srcConn: srcConn,
                                     subtitle: entries.count == 1 ? entries[0].name : "\(entries.count) items", done: done))
        }
        guard let (dest, dir) = res, !dir.isEmpty else { return }
        await XPTransfer.crossCopy(srcConn, entries, dest, dir, window: ex.window)
    }
}

// MARK: - Views

private struct GoToPathView: View {
    let ex: ExplorerModel
    let subtitle: String
    let places: [(String, String)]
    let recent: [String]
    let done: (String?) -> Void
    @StateObject private var path: Local<String>
    @StateObject private var favs: Local<[XPFavorite]>
    @StateObject private var focus = Local(0)

    init(ex: ExplorerModel, subtitle: String, initial: String, places: [(String, String)], recent: [String],
         favs: [XPFavorite], done: @escaping (String?) -> Void) {
        self.ex = ex; self.subtitle = subtitle; self.places = places; self.recent = recent; self.done = done
        _path = StateObject(wrappedValue: Local(initial))
        _favs = StateObject(wrappedValue: Local(favs))
    }

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Go to path", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Path") {
                    XPTextField(text: $path.value, placeholder: "/var/log", size: 12.5, focusToken: focus.value,
                                onEnter: { done(path.value.trimmed) })
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                }
                // Favourites first: they are the ones this person chose.
                if !favs.value.isEmpty {
                    XPGroupLabel(text: "Favourites")
                    XPFlow {
                        ForEach(favs.value) { f in
                            Button("\u{2605} " + f.label) { done(f.path) }
                                .buttonStyle(.ghostSmall)
                                .help(f.path + (f.scope == "hosts" ? "  ·  starred for every host" : ""))
                                .xpOnRightClick {
                                    CtxMenu.show([
                                        .heading(f.path),
                                        CtxItem("Go here") { done(f.path) },
                                        CtxItem("Unstar") {
                                            ex.unstarFavorite(id: f.id, path: f.path)
                                            favs.value.removeAll { $0.id == f.id }
                                        },
                                    ])
                                }
                        }
                    }
                    .padding(.bottom, 12)
                }
                XPGroupLabel(text: "Quick places")
                XPFlow {
                    ForEach(places, id: \.0) { pl in
                        Button(pl.0) { done(pl.1) }.buttonStyle(.ghostSmall).help(pl.1)
                    }
                }
                // The history of this pane is worth one click too.
                if !recent.isEmpty {
                    XPGroupLabel(text: "Recent").padding(.top, 12)
                    XPFlow {
                        ForEach(recent, id: \.self) { r in
                            Button(r) { done(r) }.buttonStyle(.ghostSmall)
                        }
                    }
                }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Go") { done(path.value.trimmed) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            after(0.05) { focus.value += 1 }
            Task { @MainActor in favs.value = await ex.favorites() }
        }
    }
}

@MainActor
private final class PermState: ObservableObject {
    @Published var mode: String
    @Published var owner: String
    @Published var group: String
    @Published var recursive = false
    init(mode: String, owner: String, group: String) { self.mode = mode; self.owner = owner; self.group = group }
}

private struct PermissionsView: View {
    @ObservedObject var state: PermState
    let one: FileEntry?
    let count: Int
    let anyDir: Bool
    let paths: [String]
    let done: (Bool?) -> Void

    var body: some View {
        let p = Theme.shared.p
        let cmds = XP.permissionCommands(paths: paths, mode: state.mode, owner: state.owner, group: state.group,
                                         recursive: state.recursive)
        DialogScaffold(title: "Permissions and owner", subtitle: one?.path ?? "\(count) items") {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Mode (octal)", hint: one.map { "Currently \($0.modeString) — blank leaves it alone." }
                          ?? "Blank leaves every selected item as it is.") {
                    TextField("755", text: $state.mode).textFieldStyle(.roundedBorder).frame(width: 110)
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 12) {
                    MiscField(label: "Owner") {
                        TextField("leave blank to keep", text: $state.owner).textFieldStyle(.roundedBorder)
                    }
                    MiscField(label: "Group") {
                        TextField("leave blank to keep", text: $state.group).textFieldStyle(.roundedBorder)
                    }
                }
                MiscCheck(label: anyDir ? "Apply to everything inside as well" : "Apply recursively", isOn: $state.recursive)
                MiscHint(text: "Runs on the host:").padding(.top, 2).padding(.bottom, 4)
                Text(cmds.isEmpty ? "Nothing to change yet." : cmds.joined(separator: "\n"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                MiscHint(text: "Changing an owner normally needs root, so this may come back with "
                         + "\"Operation not permitted\" — that is the host refusing, not a failure to ask.")
                    .padding(.top, 8)
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Apply") { done(true) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

/// Get info's contents, filled while the dialog is on screen.
@MainActor
final class XPInfoState: ObservableObject {
    @Published var rows: [(String, String)] = []
    @Published var total = ""
    @Published var error: String?
    @Published var loaded = false
    @Published var sizeUp: (() async -> Void)?
    @Published var sizing = false
    @Published var showHelp = false
    /// What the loaders found out about the mode, for the explainer.
    @Published var perms: (mode: UInt32, modeString: String?, owner: String?, group: String?)?

    func put(_ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        rows.append((label, value))
    }

    var copyText: String {
        rows.map { "\($0.0): \($0.1)\n" }.joined() + (total.isEmpty ? "" : total + "\n")
    }
}

private struct InfoView: View {
    let title: String
    let subtitle: String
    let folder: Bool
    @ObservedObject var st: XPInfoState
    let done: (Bool?) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 0) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(Array(st.rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.0).font(.system(size: 12)).foregroundStyle(p.muted)
                            Text(r.1).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !st.total.isEmpty { MiscHint(text: st.total, size: 11.5).padding(.top, 10) }
                if st.loaded, st.sizeUp != nil || st.perms?.modeString != nil {
                    HStack(spacing: 6) {
                        if let up = st.sizeUp {
                            Button("Calculate total size") {
                                st.sizing = true
                                Task { await up() }
                            }
                            .buttonStyle(.ghost).disabled(st.sizing)
                        }
                        if st.perms?.modeString != nil {
                            Button(st.showHelp ? "Hide the explanation" : "What do these permissions mean?") {
                                st.showHelp.toggle()
                            }
                            .buttonStyle(.ghost)
                        }
                    }
                    .padding(.top, 10)
                }
                if st.showHelp, let perms = st.perms {
                    XPPermHelpView(x: XP.explainPermissions(mode: perms.mode, modeString: perms.modeString,
                                                          owner: perms.owner, group: perms.group, folder: folder))
                        .padding(.top, 10)
                }
                if let e = st.error { Text(e).font(.system(size: 12)).foregroundStyle(p.red).padding(.top, 8) }
            }
        } footer: {
            Button("Copy") {
                Clipboard.write(st.copyText)
                xpStatus("Copied")
            }
            .buttonStyle(.ghost)
            Button("Close") { done(true) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

/// The permissions, read back in words (`.perm-help`).
struct XPPermHelpView: View {
    let x: XP.PermExplanation
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 8) {
            Text(x.intro).font(.system(size: 12)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(x.lanes, id: \.who) { lane in
                    VStack(spacing: 2) {
                        Text(lane.bits).font(.system(size: 15, weight: .semibold, design: .monospaced))
                        Text(lane.who).font(.system(size: 10)).foregroundStyle(p.muted)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(x.lines, id: \.label) { l in
                    (Text("•  ") + Text(l.label).bold().foregroundColor(p.text) + Text(l.text))
                        .font(.system(size: 12)).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(x.notes, id: \.self) { n in
                Text(n).font(.system(size: 12)).foregroundStyle(p.amber).fixedSize(horizontal: false, vertical: true)
            }
            Text(x.octalNote).font(.system(size: 12)).foregroundStyle(p.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
    }
}

private struct EditorView: View {
    let name: String
    let path: String
    @ObservedObject var buf: Local<String>
    let done: (Bool?) -> Void
    let save: () async -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: name, subtitle: path, scroll: false) {
            TextEditor(text: $buf.value)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                .frame(minHeight: 300)
        } footer: {
            Button("Close") { done(false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") { Task { await save() } }.buttonStyle(.primary).keyboardShortcut("s", modifiers: .command)
        }
    }
}

@MainActor
private final class CopyState: ObservableObject {
    @Published var chosen: XPConn
    @Published var dir: String
    @Published var note = ""
    @Published var noteColor: Color = Theme.shared.p.muted
    init(chosen: XPConn) { self.chosen = chosen; self.dir = chosen.homeDir ?? "~" }

    func check(_ src: String) {
        dir = chosen.homeDir ?? "~"
        note = "Checking route…"
        noteColor = Theme.shared.p.muted
        do {
            let plan = try FilesService.shared.crossPlan(src, chosen.id)
            note = plan.mode == "direct" ? "Direct transfer. \(plan.reason)" : "Relayed. \(plan.reason)"
            noteColor = plan.mode == "direct" ? Theme.shared.p.green : Theme.shared.p.amber
        } catch {
            note = errorText(error)
            noteColor = Theme.shared.p.red
        }
    }
}

private struct CopyToServerView: View {
    @ObservedObject var st: CopyState
    let candidates: [XPConn]
    let srcConn: String
    let subtitle: String
    let done: ((String, String)?) -> Void

    var body: some View {
        DialogScaffold(title: "Copy to another server", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Destination session") {
                    XPPickerList(maxHeight: 220) {
                        ForEach(candidates, id: \.id) { c in
                            XPPickerRow(name: c.label, meta: c.type == "teleport" ? "tsh" : "ssh", active: c.id == st.chosen.id) {
                                st.chosen = c
                                st.check(srcConn)
                            }
                        }
                    }
                }
                MiscField(label: "Destination directory") {
                    TextField("", text: $st.dir).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
                Text(st.note).font(.system(size: 11)).foregroundStyle(st.noteColor).fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Copy") {
                let d = st.dir.trimmed
                done(d.isEmpty ? nil : (st.chosen.id, d))
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
