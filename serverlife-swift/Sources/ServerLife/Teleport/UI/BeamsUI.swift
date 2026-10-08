import AppKit
import SwiftUI

/// beams.js (the UI half): starting a beam, its right-click menu and the
/// dialogs behind it — run a command, publish a service, copy files, delete.
/// The beam list itself lives in `Inventory` (refreshed there); the sidebar
/// draws the rows and calls in here (see README: `beam-start`, `beam-menu`,
/// `BeamsUI.visibleBeams`, `BeamExpiryLabel`).
@MainActor
enum BeamsUI {
    /// Regions offered when starting one. Blank lets the service choose.
    static let regions: [(value: String, label: String)] = [
        ("", "Wherever the cluster puts it"), ("us-east-1", "us-east-1"), ("us-east-2", "us-east-2"),
        ("us-west-1", "us-west-1"), ("us-west-2", "us-west-2"), ("eu-west-1", "eu-west-1"),
        ("eu-central-1", "eu-central-1"), ("ap-southeast-1", "ap-southeast-1"), ("ap-northeast-1", "ap-northeast-1"),
    ]

    /// `beamHost`: a beam as a host descriptor the session machinery understands.
    static func host(_ b: Beam) -> Host {
        var h = Host(type: Host.beam, id: "beam:\(b.proxy):\(b.id)", name: b.id)
        h.proxy = b.proxy
        h.home = b.home
        return h
    }

    /// The beams to draw for a proxy: the inventory's list minus the ones
    /// being deleted (off the list at once, back if the delete fails).
    static func visibleBeams(_ proxy: String) -> [Beam] {
        let removing = BeamsUIState.shared.removing
        return Inventory.shared.beamsFor(proxy).filter { !removing.contains(key($0)) }
    }

    static func key(_ b: Beam) -> String { "\(b.proxy)|\(b.id)" }

    // MARK: Opening

    /// sidebar.js `opensInTmux` for a beam: per host, then per cluster, then
    /// the global default.
    static func opensInTmux(_ h: Host) -> Bool {
        let s = Store.shared.settings
        if let v = s["tmuxHosts"][h.prefKey].bool { return v }
        if let v = s["tmuxClusters"][h.clusterPrefKey].bool { return v }
        return s["tmuxDefault"].bool == true
    }

    static func tmuxName(_ h: Host) -> String {
        let s = Store.shared.settings
        return s["tmuxSessionNames"][h.prefKey].string?.nilIfEmpty ?? s["tmuxSessionName"].string?.nilIfEmpty ?? "serverlife"
    }

    /// `openBeam`: an ordinary connection — terminal, files, transfers.
    static func open(_ b: Beam, filesOnly: Bool = false, window: WindowModel? = nil) {
        let h = host(b)
        // "Open every new session in tmux" means beams too.
        if !filesOnly && opensInTmux(h) {
            Actions.shared.perform("tmux-open", window: window, host: h, args: ["session": tmuxName(h)])
            return
        }
        var args: [String: Any] = [:]
        if filesOnly { args["filesOnly"] = true }
        Actions.shared.perform("open-host", window: window, host: h, args: args)
    }

    /// `splitBeam`: beside (`right`) or below (`down`) the focused pane.
    static func split(_ b: Beam, _ dir: String, window: WindowModel? = nil) {
        TUIStatus.show("Opening \(b.id)…", ms: 0)
        Actions.shared.perform("open-host", window: window, host: host(b), args: ["split": dir])
        TUIStatus.clear()
    }

    // MARK: Start

    /// `addBeam`: start one, then offer to open it.
    @discardableResult
    static func start(_ p: TeleportProfile, window: WindowModel? = nil) async -> Beam? {
        let m = StartBeamModel(p: p)
        let res: Beam? = await TUIModal.ask(window, title: "Start a beam", width: 520) { finish, _ in
            StartBeamView(m: m, finish: finish)
        }
        guard let b = res else { return nil }
        TUIStatus.show("Beam \(b.id) started in \(b.region)", ms: 8000)
        await Inventory.shared.refreshBeams()
        let detail = ["Region: \(b.region)", b.requestedRegion.isEmpty ? "" : "(you asked for \(b.requestedRegion))",
                      Beams.expiresIn(b).isEmpty ? "" : "Expires: \(Beams.expiresIn(b))"].filter { !$0.isEmpty }.joined(separator: "\n")
        if await MiscUI.confirm(window, title: "Beam \(b.id) is up", message: "Open a session on it now?", detail: detail,
                                confirmLabel: "Open a session") {
            open(b, window: window)
        }
        return b
    }

    // MARK: Delete

    /// `removeBeam`: always asked, because nothing on it comes back.
    @discardableResult
    static func remove(_ b: Beam, window: WindowModel? = nil) async -> Bool {
        guard await MiscUI.confirm(window, title: "Delete beam \(b.id)?", message: "The VM and everything on it goes.",
                                   detail: "Anything you have not copied off is lost. Open sessions on it will die.",
                                   confirmLabel: "Delete it", danger: true) else { return false }
        TUIStatus.show("Deleting \(b.id)…", ms: 0)
        defer { TUIStatus.clear() }
        let st = BeamsUIState.shared
        st.removing.insert(key(b))
        do {
            let r = try await Beams.remove(name: b.id, proxy: b.proxy, home: b.home)
            if !r.ok { throw AppError(r.output.nilIfEmpty ?? "tsh beams rm failed") }
            // `rm` returning is not the beam being gone: confirm rather than
            // refreshing once into a stale answer.
            var gone = false
            for wait in [0.8, 1.6, 2.5, 4.0] {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                let still = await Beams.stillListed(name: b.id, proxy: b.proxy, home: b.home)
                if still == false { gone = true; break }
                if still == nil { break }
            }
            await Inventory.shared.refreshBeams()
            st.removing.remove(key(b))
            if gone || r.gone { TUIStatus.toast("Deleted \(b.id)", "success") }
            else { TUIStatus.toast("\(b.id) was deleted, but the cluster is still listing it — it should drop off the next refresh.", "info", ms: 9000) }
            return true
        } catch {
            // Put it back: it is still there.
            st.removing.remove(key(b))
            TUIStatus.toast(error.localizedDescription, "error", ms: 12000)
            return false
        }
    }

    // MARK: Run, publish, copy

    /// `execInBeam`: one command, answered in a dialog — no session needed.
    static func exec(_ b: Beam, window: WindowModel? = nil) {
        let m = BeamOutputModel(b)
        m.command = "uname -a; id -un; df -h /"
        m.output = "Output appears here."
        m.shown = true
        TUIModal.show(window, title: "Run in a beam", width: 760) { handle in BeamExecView(m: m, handle: handle) }
    }

    /// `publishBeam`: put a service inside the beam behind the cluster's address.
    static func publish(_ b: Beam, window: WindowModel? = nil) {
        let m = BeamOutputModel(b)
        TUIModal.show(window, title: "Publish a service", width: 620) { handle in BeamPublishView(m: m, handle: handle) }
    }

    /// `scpBeam`: `tsh beams scp`, either direction.
    static func scp(_ b: Beam, toBeam: Bool = true, window: WindowModel? = nil) {
        let m = BeamOutputModel(b)
        m.up = toBeam
        m.window = window
        TUIModal.show(window, title: "Copy files", width: 680) { handle in BeamScpView(m: m, handle: handle) }
    }

    /// "Active sessions in this beam…": the tracker names a beam by the node
    /// it registers as, `beam-<uuid>`.
    static func activeSessions(_ b: Beam, window: WindowModel? = nil) {
        LiveSessionsUI.open(proxy: b.proxy, home: b.home,
                            match: [b.uuid.isEmpty ? "" : "beam-" + b.uuid, b.uuid, "beam-" + b.id, b.id].filter { !$0.isEmpty },
                            title: "Active sessions in \(b.id)", window: window)
    }

    // MARK: The menu

    /// `beamMenu`: the right-click menu for one beam.
    static func menuItems(_ b: Beam, window: WindowModel? = nil) -> [CtxItem] {
        var items: [CtxItem] = [.heading(b.id), CtxItem("Open a session") { open(b, window: window) }]
        // Beside or below the focused pane, only when there is one.
        if Actions.shared.isEnabled("split-right", ActionContext(window: window)) {
            items.append(CtxItem("Open beside current (split right)", icon: "\u{216E}") { split(b, "right", window: window) })
            items.append(CtxItem("Open below current (split down)", icon: "\u{2017}") { split(b, "down", window: window) })
        }
        items += [
            CtxItem("Open in tmux…", title: "Keeps running on the beam when this window goes away") {
                Actions.shared.perform("tmux-open", window: window, host: host(b), args: ["dialog": true])
            },
            CtxItem("Open the file browser", title: "A session with the files and no terminal") { open(b, filesOnly: true, window: window) },
            CtxItem("Run a command…") { exec(b, window: window) },
            CtxItem("Active sessions in this beam…",
                    title: "Watch, join or moderate a session that is going on in it now — an agent at work, say") {
                activeSessions(b, window: window)
            },
            .sep,
            CtxItem("Publish a service…") { publish(b, window: window) },
            CtxItem("Copy files (scp)…") { scp(b, window: window) },
            .sep,
            CtxItem("Copy its name") { Clipboard.write(b.id); TUIStatus.show("Copied " + b.id) },
        ]
        if !b.uuid.isEmpty { items.append(CtxItem("Copy its UUID") { Clipboard.write(b.uuid); TUIStatus.show("Copied " + b.uuid) }) }
        items += [.sep, CtxItem("Delete this beam…") { Task { await remove(b, window: window) } }]
        return items
    }

    static func showMenu(_ b: Beam, window: WindowModel? = nil) { CtxMenu.show(menuItems(b, window: window)) }

    /// Append the menu's items to someone else's NSMenu.
    static func appendMenu(_ menu: NSMenu, _ b: Beam, window: WindowModel? = nil) {
        let built = CtxMenu.build(menuItems(b, window: window))
        for item in built.items { built.removeItem(item); menu.addItem(item) }
    }

    /// Find a beam from an action context: args `beam` (Beam), or a beam host.
    static func beam(from ctx: ActionContext) -> Beam? {
        if let b = ctx.arg("beam", as: Beam.self) { return b }
        if let h = ctx.host, h.isBeam {
            return Inventory.shared.beamsFor(h.proxy ?? "").first { $0.id == h.name }
        }
        return nil
    }
}

@MainActor
@Observable
final class BeamsUIState {
    static let shared = BeamsUIState()
    /// `proxy|id` of beams whose delete is in flight.
    var removing: Set<String> = []
}

/// `expiresIn`, ticking: "45m left", "3h 12m left", "expired".
struct BeamExpiryLabel: View {
    let beam: Beam
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let text = Beams.expiresIn(beam, now: ctx.date.timeIntervalSince1970 * 1000)
            if !text.isEmpty {
                Text(text).font(.system(size: 10.5))
                    .foregroundStyle(text == "expired" ? Theme.shared.p.red : Theme.shared.p.muted)
            }
        }
    }
}

// MARK: - Dialogs

@MainActor
final class StartBeamModel: ObservableObject {
    let p: TeleportProfile
    @Published var region = ""
    @Published var busy = false
    @Published var note = "A beam is a sandbox VM. It is created on demand, expires on its own, and "
        + "is meant to be thrown away — nothing on it survives the expiry."
    init(p: TeleportProfile) { self.p = p }
}

private struct StartBeamView: View {
    @ObservedObject var m: StartBeamModel
    let finish: (Beam?) -> Void
    var body: some View {
        DialogScaffold(title: "Start a beam", subtitle: TUI.name(m.p), scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                TUIField(label: "Region", hint: "The cluster may put it somewhere else if the region you ask for is unavailable.") {
                    Picker("", selection: $m.region) {
                        ForEach(BeamsUI.regions, id: \.value) { Text($0.label).tag($0.value) }
                    }.labelsHidden().frame(maxWidth: 300, alignment: .leading)
                }
                if !m.note.isEmpty { MiscHint(text: m.note, size: 11) }
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Start it") {
                if m.busy { return }
                m.busy = true
                m.note = "Starting a sandbox VM — this takes a moment…"
                Task { @MainActor in
                    let r = await Beams.add(proxy: m.p.proxy, home: m.p.homeDir, region: m.region.nilIfEmpty)
                    m.busy = false
                    if !r.ok || r.beam == nil {
                        m.note = ""
                        TUIStatus.toast(r.error ?? "Could not start a beam", "error", ms: 9000)
                        return
                    }
                    finish(r.beam)
                }
            }.buttonStyle(.primary).disabled(m.busy)
        }
        .frame(width: 520)
    }
}

@MainActor
final class BeamOutputModel: ObservableObject {
    let b: Beam
    weak var window: WindowModel?
    @Published var command = ""
    @Published var output = ""
    @Published var shown = false
    @Published var busy = false
    @Published var tcp = false
    // scp
    @Published var up = true
    @Published var local = ""
    @Published var remote = ""
    @Published var recursive = false

    init(_ b: Beam) { self.b = b }

    func runExec() {
        let c = command.trimmed
        if c.isEmpty || busy { return }
        busy = true
        output = "Running…"
        Task { @MainActor in
            do {
                let r = try await Beams.exec(name: b.id, proxy: b.proxy, home: b.home, command: c)
                output = [r.output, r.error].filter { !$0.isEmpty }.joined(separator: "\n").nilIfEmpty ?? "(no output)"
            } catch { output = error.localizedDescription }
            busy = false
        }
    }

    /// The tar advice under "Recursive", in terms of the paths typed above it.
    var tarNote: String {
        let src0 = (up ? local : remote).trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let src = src0.nilIfEmpty ?? (up ? "/path/to/folder" : "/home/beams/folder")
        let dest = (up ? remote : local).trimmed.nilIfEmpty ?? (up ? "/home/beams/somewhere" : "/path/on/this/machine")
        let parts = src.components(separatedBy: "/")
        let name = parts.last?.nilIfEmpty ?? "folder"
        let parent = parts.dropLast().joined(separator: "/").nilIfEmpty ?? "/"
        let pack = "tar czf \(name).tar.gz -C '\(parent)' '\(name)'"
        let unpack = "tar xzf \(name).tar.gz -C '\(dest)'"
        return "A large folder is much faster as one archive. " + (up
            ? "Here: \(pack) — copy the .tar.gz (Recursive off) — then in the beam: \(unpack)"
            : "In the beam: \(pack) (Run a command… does it) — copy the .tar.gz (Recursive off) — then here: \(unpack)")
    }
}

private struct BeamExecView: View {
    @ObservedObject var m: BeamOutputModel
    let handle: ModalHandle
    @FocusState private var focused: Bool
    var body: some View {
        DialogScaffold(title: "Run in a beam", subtitle: m.b.id, scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                TUIField(label: "Command", hint: "Runs through `tsh beams exec`, with no session open.") {
                    TextField("", text: $m.command).textFieldStyle(.roundedBorder).focused($focused)
                        .font(.system(size: 12, design: .monospaced)).onSubmit { m.runExec() }
                }
                TUIPre(text: m.output, maxHeight: 320)
            }
        } footer: {
            Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Run") { m.runExec() }.buttonStyle(.primary).disabled(m.busy)
        }
        .frame(width: 760)
        .onAppear { after(0.05) { focused = true } }
    }
}

private struct BeamPublishView: View {
    @ObservedObject var m: BeamOutputModel
    let handle: ModalHandle
    var body: some View {
        DialogScaffold(title: "Publish a service", subtitle: m.b.id, scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                TUIField(label: "Kind", hint: "HTTP is published as an application; TCP as a TCP app you reach with a local proxy.") {
                    Picker("", selection: $m.tcp) {
                        Text("HTTP service").tag(false)
                        Text("TCP service").tag(true)
                    }.labelsHidden().frame(maxWidth: 220, alignment: .leading)
                }
                MiscHint(text: "The service has to already be listening inside the beam. Publishing exposes it "
                         + "through the cluster, so it is reachable by anyone the cluster lets in.", size: 11)
                if m.shown { TUIPre(text: m.output, maxHeight: 240).padding(.top, 10) }
            }
        } footer: {
            Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Unpublish") {
                m.shown = true
                m.output = "Unpublishing…"
                Task { @MainActor in
                    do {
                        let r = try await Beams.unpublish(name: m.b.id, proxy: m.b.proxy, home: m.b.home)
                        m.output = r.output.nilIfEmpty ?? (r.ok ? "Unpublished." : "Nothing was published.")
                    } catch { m.output = error.localizedDescription }
                }
            }.buttonStyle(.ghost)
            Button("Publish") {
                m.shown = true
                m.output = "Publishing…"
                Task { @MainActor in
                    do {
                        let r = try await Beams.publish(name: m.b.id, proxy: m.b.proxy, home: m.b.home, tcp: m.tcp)
                        m.output = r.output.nilIfEmpty ?? (r.ok ? "Published." : "Could not publish.")
                        if !r.url.isEmpty {
                            Clipboard.write(r.url)
                            TUIStatus.show("Published — address copied: " + r.url, ms: 9000)
                        }
                    } catch { m.output = error.localizedDescription }
                }
            }.buttonStyle(.primary)
        }
        .frame(width: 620)
    }
}

private struct BeamScpView: View {
    @ObservedObject var m: BeamOutputModel
    let handle: ModalHandle
    var body: some View {
        DialogScaffold(title: "Copy files", subtitle: "\(m.b.id) · tsh beams scp", scroll: false) {
            VStack(alignment: .leading, spacing: 0) {
                TUIField(label: "Direction") {
                    Picker("", selection: $m.up) {
                        Text("This machine \u{2192} beam").tag(true)
                        Text("Beam \u{2192} this machine").tag(false)
                    }.labelsHidden().frame(maxWidth: 240, alignment: .leading)
                }
                TUIField(label: "On this machine") {
                    HStack(spacing: 6) {
                        TextField("/path/on/this/machine", text: $m.local).textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            Task { @MainActor in if let d = await Modal.chooseDirectory(m.window) { m.local = d.path } }
                        }.buttonStyle(.ghostSmall)
                    }
                }
                TUIField(label: "In the beam") {
                    TextField("/home/beams/somewhere", text: $m.remote).textFieldStyle(.roundedBorder)
                }
                Toggle(isOn: $m.recursive) { Text("Recursive (a whole directory)").font(.system(size: 12.5)) }
                    .toggleStyle(.checkbox)
                if m.recursive { MiscHint(text: m.tarNote, size: 11).padding(.top, 8) }
                if m.shown { TUIPre(text: m.output, maxHeight: 200).padding(.top, 10) }
            }
        } footer: {
            Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Copy") {
                let local = m.local.trimmed, remote = m.remote.trimmed
                if local.isEmpty || remote.isEmpty { TUIStatus.toast("Both paths are needed", "error"); return }
                m.shown = true
                m.output = "Copying…"
                let b = m.b, up = m.up
                Task { @MainActor in
                    do {
                        // tsh spells the beam side `beam:path`.
                        let r = try await Beams.scp(src: up ? local : "\(b.id):\(remote)", dest: up ? "\(b.id):\(remote)" : local,
                                                    proxy: b.proxy, home: b.home, recursive: m.recursive)
                        m.output = r.output.nilIfEmpty ?? (r.ok ? "Copied." : "Copy failed.")
                        if r.ok { TUIStatus.show("Copied") }
                    } catch { m.output = error.localizedDescription }
                }
            }.buttonStyle(.primary)
        }
        .frame(width: 680)
    }
}
