import AppKit
import SwiftUI

/// Synchronising a folder with rsync, from the file browser's own menu
/// (rsyncsync.js). It opens on a dry run, rides the session's own connection,
/// and the command on screen is exactly what runs.
@MainActor
enum XPRsyncDialog {
    /// A side of the sync: a local path, or a path on a connected host.
    struct Side {
        var kind: String
        var path: String
        var label: String
        var connId: String?
        var target: String?
        weak var explorer: ExplorerModel?
        var unsupported = false

        var rsyncSide: Rsync.Side { Rsync.Side(kind: kind, label: label, target: target) }
    }

    static func sideOf(_ e: ExplorerModel?) -> Side? {
        guard let e else { return nil }
        if e.isLocal { return Side(kind: "local", path: e.view.path ?? "", label: "this machine", explorer: e) }
        if e.isRemote, let c = e.connId {
            let conn = XPConn.get(c)
            return Side(kind: "remote", path: e.view.path ?? "", label: conn?.label.nilIfEmpty ?? conn?.target ?? "the server",
                        connId: c, explorer: e)
        }
        // S3 has no shell to run rsync on, and no ssh to reach it with.
        return Side(kind: e.kind, path: "", label: e.isS3 ? "a bucket" : "this pane", explorer: nil, unsupported: true)
    }

    /// The other file pane, if there is one worth syncing with.
    static func otherSide(_ e: ExplorerModel) -> Side? {
        let usable = Explorers.shared.inWindow(e.window).filter { $0 !== e && ($0.isLocal || $0.isRemote) }
        return usable.first.flatMap(sideOf)
    }

    /// The pane's own starred folders (saved and built-in), else the saved ones.
    static func starsFor(_ side: Side) async -> [(path: String, label: String)] {
        if let e = side.explorer {
            let favs = await e.favoriteFolders()
            if !favs.isEmpty { return favs.map { ($0.path, $0.label) } }
        }
        return XPFavoriteStore.starredFolders(local: side.kind == "local", favorites: Store.shared.xpFolderFavorites)
    }

    static func open(_ explorer: ExplorerModel) async {
        let check = await Rsync.check()
        if !check.ok { xpToast(check.error ?? "", "error", 9000); return }

        guard let here = sideOf(explorer) else { return }
        let there = otherSide(explorer)
        if here.unsupported { xpToast("rsync cannot run against \(here.label).", "error"); return }
        guard var there else { xpToast("Open a second file pane — rsync copies between two places", "error"); return }
        if there.unsupported { xpToast("rsync cannot run against \(there.label).", "error"); return }
        var hereSide = here
        if hereSide.kind == "remote" && there.kind == "remote" {
            // rsync refuses two remote endpoints outright — before it opens a
            // connection to either.
            xpToast("rsync will not copy server to server \u{2014} it refuses two remote ends outright. "
                    + "Select the files and use Copy to another server\u{2026}, or sync each side against this machine.",
                    "error", 11000)
            return
        }

        // The ssh the remote side will be reached through, and its refusal if
        // it cannot be: a per-session-MFA node, a beam, a session not yet connected.
        var transport: Rsync.Transport?
        if let rc = hereSide.kind == "remote" ? hereSide.connId : there.kind == "remote" ? there.connId : nil {
            let t = Rsync.transport(rc)
            if !t.ok { xpToast(t.reason ?? "", "error", 10000); return }
            transport = t
            if hereSide.kind == "remote" { hereSide.target = t.target } else { there.target = t.target }
        }

        let st = XPRsyncState(here: hereSide, there: there, check: check, transport: transport)
        _ = await XPDialog.present(explorer.window, title: "Synchronise with rsync", width: 760, height: 680,
                                   resizable: true, autosave: "rsync") { (done: @escaping (Bool?) -> Void) in
            AnyView(RsyncView(st: st, done: done))
        }
        // Closing the dialog stops the run: an rsync nobody is watching, with
        // no way left to stop it, is not something to leave behind.
        st.stopAll()
        st.runId = nil
    }
}

@MainActor
final class XPRsyncState: ObservableObject {
    let here: XPRsyncDialog.Side
    let there: XPRsyncDialog.Side
    let check: Rsync.Check
    let transport: Rsync.Transport?
    @Published var reversed = false
    @Published var dryRun = true
    @Published var archive = true
    @Published var compress = true
    @Published var del = false
    @Published var checksum = false
    @Published var contents = true
    @Published var excludes = ""
    @Published var extra = ""
    @Published var src: String
    @Published var dst: String
    @Published var out = ""
    /// The line under the output: "Ready.", "Dry run…", the result.
    @Published var foot = "Ready."
    @Published var footKind = "hint"   // hint | run | ok | bad
    @Published var running = false
    @Published var finished = false
    @Published var lastWasDry = true
    var runId: String?
    /// Every run started from this dialog, so closing it stops them all.
    var started: Set<String> = []

    init(here: XPRsyncDialog.Side, there: XPRsyncDialog.Side, check: Rsync.Check, transport: Rsync.Transport?) {
        self.here = here; self.there = there; self.check = check; self.transport = transport
        src = here.path
        dst = there.path
    }

    var sides: (XPRsyncDialog.Side, XPRsyncDialog.Side) { reversed ? (there, here) : (here, there) }

    func args() -> [String] {
        let (s, d) = sides
        var o = Rsync.Options(from: Rsync.endpoint(s.rsyncSide, src, contents: contents),
                              to: Rsync.endpoint(d.rsyncSide, dst, contents: false))
        o.archive = archive
        o.compress = compress
        o.del = del
        o.checksum = checksum
        o.dryRun = dryRun
        o.excludes = excludes.components(separatedBy: CharacterSet(charactersIn: "\n,"))
        o.extra = extra
        o.features = check.features ?? Rsync.Features(infoProgress: false, protectArgs: false)
        o.shellArg = transport?.shell ?? ""
        return Rsync.buildArgs(o)
    }

    var commandLine: String { Rsync.commandLine(args()) }

    func swap() {
        reversed.toggle()
        let a = src; src = dst; dst = a
    }

    func start(real: Bool) {
        // One run at a time: a second press must not leave the first going unwatched.
        if running { return }
        if let old = runId { Rsync.cancel(old) }
        dryRun = !real
        let id = uid("rsync")
        runId = id
        lastWasDry = !real
        out = ""
        foot = real ? "Copying…" : "Dry run…"
        footKind = "run"
        running = true
        finished = false
        let argv = args()
        started.insert(id)
        do {
            try Rsync.run(id: id, args: argv, onOut: { [weak self] m in
                Task { @MainActor in
                    guard let self, self.runId == id else { return }
                    self.out += m.text
                    if self.out.count > 400_000 { self.out = String(self.out.suffix(300_000)) }
                }
            }, onDone: { [weak self] m in
                Task { @MainActor in
                    guard let self, self.runId == id else { return }
                    self.done(m)
                }
            })
        } catch {
            runId = nil
            running = false
            foot = errorText(error)
            footKind = "bad"
        }
    }

    private func done(_ m: Rsync.Done) {
        runId = nil
        running = false
        finished = true
        let ok = m.code == 0
        let text = m.error ?? m.message
        out += "\n" + text + "\n"
        foot = text
        footKind = ok ? "ok" : "bad"
        if ok && !lastWasDry {
            xpStatus("rsync finished")
            for e in [here.explorer, there.explorer] { if let e { Task { await e.refresh() } } }
        }
    }

    func stop() { if let id = runId { Rsync.cancel(id) } }

    /// Closing the dialog stops every run it started.
    func stopAll() { for id in started where Rsync.isRunning(id) { Rsync.cancel(id) } }
}

private struct RsyncView: View {
    @ObservedObject var st: XPRsyncState
    let done: (Bool?) -> Void

    private func starMenu(_ which: Int) {
        let (s, d) = st.sides
        let side = which == 0 ? s : d
        Task {
            let favs = await XPRsyncDialog.starsFor(side)
            if favs.isEmpty { xpToast("No starred folders for that side yet", "error"); return }
            CtxMenu.show([.heading("Starred on \(side.label)")] + favs.map { f in
                CtxItem(f.label, title: f.path) { if which == 0 { st.src = f.path } else { st.dst = f.path } }
            })
        }
    }

    private func row(_ label: String, _ sideLabel: String, _ text: Binding<String>, _ which: Int) -> some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .semibold))
                Text(sideLabel).font(.system(size: 10.5)).foregroundStyle(Theme.shared.p.muted)
            }
            .frame(width: 108, alignment: .leading)
            XPTextField(text: text, size: 12).modifier(XPFieldBox())
            Button("☆") { starMenu(which) }.buttonStyle(.ghostSmall).help("Pick one of your starred folders")
        }
        .padding(.bottom, 7)
    }

    private func plainRow(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        HStack(spacing: 9) {
            Text(label).font(.system(size: 12, weight: .semibold)).frame(width: 108, alignment: .leading)
            XPTextField(text: text, placeholder: placeholder, size: 12).modifier(XPFieldBox())
        }
        .padding(.bottom, 7)
    }

    var body: some View {
        let p = Theme.shared.p
        let (s, d) = st.sides
        DialogScaffold(title: "Synchronise with rsync", subtitle: st.check.version, scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Button("⇅ Swap direction") { st.swap() }.buttonStyle(.ghostSmall)
                    MiscHint(text: "Opens on a dry run: nothing moves until you say so.", size: 11)
                }
                .padding(.bottom, 9)
                row("Source", "from \(s.label)", $st.src, 0)
                row("Destination", "to \(d.label)", $st.dst, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: $st.archive) { Text("Archive (-a) — recurse, and keep times, links and permissions") }
                    Toggle(isOn: $st.compress) { Text("Compress in flight (-z)") }
                    Toggle(isOn: $st.del) { Text("Delete what is not in the source (--delete)").foregroundStyle(p.amber) }
                    Toggle(isOn: $st.checksum) { Text("Compare by checksum rather than size and time (-c)") }
                    Toggle(isOn: $st.contents) { Text("Copy the contents of the source folder, not the folder itself") }
                }
                .toggleStyle(.checkbox).font(.system(size: 12))
                .padding(.vertical, 9)
                plainRow("Exclude", $st.excludes, ".git, node_modules, *.tmp")
                plainRow("Extra flags", $st.extra, "--bwlimit=8M --partial")
                Text(st.commandLine)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                    .padding(.bottom, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(st.out.isEmpty ? " " : st.out)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: st.out) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                HStack(spacing: 8) {
                    Text(st.foot).font(.system(size: 11.5)).lineLimit(2)
                        .foregroundStyle(st.footKind == "ok" ? p.green : st.footKind == "bad" ? p.red : p.muted)
                    if st.running {
                        Button("Stop") { st.stop() }.buttonStyle(.ghostSmall)
                    } else if st.finished {
                        if st.footKind == "ok" && st.lastWasDry {
                            Button("Run it for real") { st.start(real: true) }
                                .buttonStyle(GhostButtonStyle(small: true, prominent: true))
                                .help("Everything above, without -n")
                        }
                        Button(st.lastWasDry ? "Dry run again" : "Run again") { st.start(real: !st.lastWasDry) }
                            .buttonStyle(.ghostSmall)
                    }
                    Spacer()
                }
                .frame(minHeight: 26)
                .padding(.top, 8)
            }
        } footer: {
            Button("Close") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Dry run") { st.start(real: false) }.buttonStyle(.ghost).disabled(st.running)
            Button("Copy the command") {
                Clipboard.write(st.commandLine)
                xpStatus("Command copied")
            }
            .buttonStyle(.ghost)
        }
    }
}
