import AppKit
import SwiftUI

/// The guided tour: the port of tour.js.
///
/// The tour points at the real interface rather than describing it. Each step
/// spotlights the actual view (tagged by its owner with `.tourAnchor("id")`)
/// and says what it does; the app underneath is untouched and stays usable,
/// so the tour can be left at any point. A step whose anchor is missing or
/// hidden still runs, centred and without a spotlight.
///
/// Offered once on a first run, and in Help afterwards.
@MainActor
enum Tour {
    /// Bumped when the tour gains steps worth showing to someone who has
    /// already seen it: "seen" means "seen this much".
    static let version = 3

    struct Step {
        let title: String
        /// A `.tourAnchor` id, or nil for a centred card.
        let target: String?
        let body: String
    }

    static let steps: [Step] = [
        Step(title: "ServerLife in one minute", target: nil,
             body: "Teleport nodes and plain SSH hosts, treated as the same thing: tabbed "
                + "terminals, a real file browser, fleet-wide commands and port forwarding in "
                + "one window.\n\nThis tour points at each part and says what it is for. "
                + "Nothing you see here changes anything — leave whenever you like."),
        Step(title: "Every host in one list", target: "sidebar",
             body: "Teleport nodes from every cluster you are logged in to, grouped by cluster "
                + "with their labels, and every Host in ~/.ssh/config below them. Nothing has to "
                + "be registered with the app first.\n\nDouble-click a host to open a session. "
                + "Right-click for the rest: open as another user, files only, beside the current "
                + "pane, port forward, run one command.\n\nThe star on a row keeps that host in a "
                + "Starred group at the top, and the \u{27F3} on a cluster heading re-reads just that "
                + "cluster instead of the whole inventory. More than one ssh_config file can be "
                + "read — each gets its own group, in Settings."),
        Step(title: "What a host remembers about itself", target: "sidebar",
             body: "Two things are worth setting per host, both on its right-click menu.\n\n"
                + "\"Preferred username\" pins the account it always connects as — kept against a "
                + "Teleport node\u{2019}s uuid, so renaming the machine does not lose it.\n\n"
                + "\"Agent forwarding\" decides whether your keys are reachable from that host: on, "
                + "off, or follow the cluster, which itself can follow the global setting. What a "
                + "jump host needs and a shared box should not have."),
        Step(title: "Leaf clusters and beams", target: "sidebar",
             body: "A root cluster that trusts others shows a leaf badge on its heading; clicking "
                + "it switches between the root and any leaf, with labels, and a search box once "
                + "there are more than ten.\n\nBeams \u{2014} ephemeral sandbox VMs \u{2014} are listed "
                + "inside their cluster under their own heading, with a region and a countdown to "
                + "expiry. Everything the app does to a server it does to a beam: a terminal, the "
                + "file browser, synchronise, drag and drop. Publishing a service takes the place "
                + "of port forwards, which a beam does not have."),
        Step(title: "Find a host by name or label", target: "host-filter",
             body: "Text matches anywhere. Labels are searchable too: env=prod for an exact "
                + "value, env:pro for a partial one, env=a,b for either, -env=dev to exclude, "
                + "env=pre* as a glob. Terms combine, so \"web env=prod\" means both.\n\n"
                + "There is more when you need it: and, or, not and brackets, and ~ for a "
                + "regular expression — name~^(web|api)-\\d+$. The same language writes a "
                + "folder’s rule and picks multi-exec targets."),
        Step(title: "Folders, and a pane for the fleet", target: "btn-folders",
             body: "A cluster’s list is whatever tsh ls returns, in whatever order. Folders "
                + "are the other way round: make one on a cluster heading, drag hosts in, and "
                + "they stay — kept by the node’s uuid, so a rename cannot empty a folder. "
                + "A filed host is listed inside its folder and nowhere else.\n\nA folder can "
                + "also fill itself from a rule — env=prod and (role:web or role:api) and not "
                + "name~canary — re-asked every time the inventory changes. Folders nest, take "
                + "an emoji and a colour, and the whole arrangement exports to a file a colleague "
                + "can import.\n\nThe Folders button opens the big view. A cluster heading will "
                + "also open its hosts in a pane of the window, with folders on or off and rows "
                + "or tiles — which is where a list of three hundred nodes belongs. The "
                + "sidebar itself stops at twenty per group and offers that pane for the rest."),
        Step(title: "Starting a session", target: "tab-add",
             body: "⌘N opens the picker — recent connections first, then every host, "
                + "searchable, Enter to connect.\n\n⌘⌥C is Quick connect, for a server that is "
                + "in no list yet: type ubuntu@10.0.0.5, or paste a whole ssh command line. It "
                + "can test the connection or run a single command without opening a terminal, "
                + "and saves nothing unless you ask it to."),
        // The title bar rather than the tab strip: the strip is empty until a
        // session exists, which is exactly the first-run case.
        Step(title: "One authentication per host", target: "titlebar",
             body: "Opening a session creates a single SSH ControlMaster. Every terminal, file "
                + "operation, tunnel and remote command after that rides the same connection — so "
                + "you tap your MFA key once, not once per panel, and ten terminals to one host is "
                + "one Teleport session.\n\nSessions are tabs. ⌘1–⌘9 jump between them, ⌘D "
                + "duplicates one, ⌘W closes a pane.\n\nEach tab says what its session is "
                + "doing, not just what it is connected to: three bars ripple while output is "
                + "arriving, and an amber ? appears when something in there is waiting to be "
                + "answered — a password, a yes/no, or a coding agent asking permission."),
        Step(title: "Two servers side by side", target: "panes",
             body: "Any tab splits into panes. ⌘⇧D and ⌘⇧E split with the same host; ⌘⌥D and "
                + "⌘⌥E split with a different one, so two servers sit next to each other.\n\n"
                + "⌘⇧B turns on broadcast typing: what you type goes to every pane in the tab at "
                + "once — the \"same command on four servers\" trick, without scripting it."),
        Step(title: "The file browser is part of the session", target: "toggle-files",
             body: "It appears the moment a session connects, because it is riding the "
                + "connection that is already open — no second authentication, no separate SFTP "
                + "app.\n\n⌘E shows and hides it. Drag files in from Finder to upload, drag them "
                + "out to download, or press the 💻 button in the explorer to put your local "
                + "files underneath and drag between the two. ⌕ filters by name, and the arrow "
                + "keys walk the matches.\n\nThe \u{2261} button adds permissions and owner beside "
                + "size and date, and \"Get info\" explains what a mode actually grants. \u{21C4} "
                + "compares two folders; \u{21C6} synchronises them, showing every action with a tick "
                + "beside it before anything moves. \"Edit in my editor\" opens a remote file in "
                + "whatever you actually edit in and uploads every save."),
        Step(title: "Words worth seeing", target: "panes",
             body: "Beside each pane\u{2019}s search box is a highlighting toggle. Switch it on and "
                + "errors, warnings and good news are coloured in the output as it arrives, so "
                + "\"error\" is visible without searching for it. It is off until you ask for it, "
                + "here or in Settings.\n\nRight-click that button to add your own words, or "
                + "to set it per host \u{2014} a mail relay\u{2019}s \"deferred\" is routine, a build "
                + "box\u{2019}s is not. It stands aside while vim, less or htop is drawing its own "
                + "screen."),
        Step(title: "One command, every host", target: "toggle-multiexec",
             body: "Tick hosts in the sidebar, then ⌘⇧M and type a command. It runs on all of "
                + "them in parallel, with each result in its own collapsible card — exit code, "
                + "duration, stdout and stderr.\n\nUseful for the questions that are not worth a "
                + "session each: which of these is out of disk, which kernel is everyone on."),
        Step(title: "Transfers, tunnels and the log", target: "toggle-transfers",
             body: "⌘J opens the dock. Transfers shows progress and rate for every upload and "
                + "download, including server-to-server ones. Tunnels lists your port forwards "
                + "— local, remote and SOCKS — and the connection log is every line the ssh or "
                + "tsh process printed, which is where to look when something refuses you.\n\n"
                + "A tunnel worth having again can be starred into Favourites, which reopens it "
                + "(dialling the host first if needed). Downloads answers \"where did that file "
                + "go\", and Watch lists the folders being kept up to date."),
        Step(title: "Teleport", target: "teleport-tab",
             body: "Clusters you are logged in to, with their proxies and your roles; log in "
                + "and out per cluster; request access and assume approved requests; monitor "
                + "whether the resources you expect to be able to request are still offered; and play "
                + "back recorded sessions, or search their transcripts for a word across a date "
                + "range.\n\nPer-session-MFA nodes are handled too — those open over tsh, since a "
                + "shared connection cannot satisfy an MFA challenge per session.\n\nRecordings "
                + "list the interactive ones by default \u{2014} the rest have nothing to replay \u{2014} "
                + "a session id pasted into the filter is recognised even when it is outside the "
                + "dates loaded, and the \u{2606} keeps one with a note. \"Add to ssh config\" writes "
                + "a cluster\u{2019}s tsh config block into ~/.ssh/config, so scp, rsync and Ansible "
                + "reach its nodes too. A node\u{2019}s menu will also measure latency to it, both "
                + "halves of the path."),
        Step(title: "When a node goes quiet, or goes away", target: "btn-heartbeats",
             body: "A Teleport node stays in the inventory for ten or fifteen minutes after its "
                + "agent stops heartbeating — same row, same labels, still offering a session "
                + "that will hang on a tunnel with nobody on the far end. Past a couple of "
                + "minutes of silence its row says ⚠ and how long it has been quiet. "
                + "Heartbeats puts the figure on every row.\n\nThe button beside it gathers "
                + "them: all nodes, the quiet ones hidden, or only the quiet ones — which is "
                + "the list to have open when something has taken a rack with it.\n\nAnd for a "
                + "machine you would want to hear about: right-click → \"Tell me if this host "
                + "disappears\". Its node id and last known details are kept, so when it stops "
                + "being listed at all the row stays, struck through, with how long it has been "
                + "gone — instead of the host quietly ceasing to exist."),
        Step(title: "Your keys, and what the agent holds", target: "keys",
             body: "Every keypair in ~/.ssh with its fingerprint, type, whether it has a "
                + "passphrase, and which ssh_config hosts use it — plus what ssh-agent is "
                + "currently holding.\n\nGenerate a key, add one to the agent, or install a "
                + "public key on a server you are already connected to, which is ssh-copy-id "
                + "without the second authentication."),
        Step(title: "When a host will not answer", target: "nettools",
             body: "Ping, traceroute, DNS, port checks, TLS certificates and HTTP probes, in "
                + "the same window as the session that is failing (⌘⇧T). Answers \"is it me, the "
                + "network, or the server\" without leaving for a terminal.\n\nThere is a full curl "
                + "in there as well \u{2014} method, headers, body, bearer or basic auth \u{2014} with "
                + "the command shown as it will run, the response formatted, and the call keepable "
                + "to run again. Examples fills in the typical shapes for every tool, Recent "
                + "reruns what you just did, and any output can be saved to a file."),
        Step(title: "Where the rest lives", target: nil,
             body: "Macros and snippets keep commands you retype. Every session\u{2019}s \u{25B6} "
                + "button runs one on that host, and the last entry in that menu writes a new one. "
                + "A macro can be pinned as a button in the session header \u{2014} with an icon, and "
                + "a choice of every session, hosts only, or the local shell only.\n\nLayouts save "
                + "an arrangement of sessions and bring it back (⌘⇧S, ⌘⇧O), and the last one is "
                + "offered on launch. S3 buckets can be browsed and copied to and from servers "
                + "directly. An agent can drive the app through the bundled MCP server \u{2014} open "
                + "sessions, run a macro you wrote, preview and apply a folder synchronisation "
                + "\u{2014} and it is off until you turn it on.\n\nSettings (⌘,) has the theme, font, "
                + "accent, keyword highlighting, agent forwarding, the extra ssh_config files, and "
                + "the hidden-files and follow-the-terminal toggles. Every shortcut is in the "
                + "menus, and the README has the full list.\n\nThis tour is in Help whenever you "
                + "want it again."),
    ]

    /// Every anchor id the steps point at (see README).
    static var anchorIds: [String] { Array(Set(steps.compactMap(\.target))).sorted() }

    /// Hooks the tour into the window: the overlay slot, the slot anchors
    /// Misc can tag itself, and the first-run offer.
    static func install() {
        Slots.overlays.append { window in AnyView(TourOverlay(window: window)) }
        // The whole sidebar and the whole workspace are slots; tag them here
        // so their owners do not have to.
        let sidebar = Slots.sidebar
        Slots.sidebar = { w in AnyView(sidebar(w).tourAnchor("sidebar")) }
        let workspace = Slots.workspace
        Slots.workspace = { w in AnyView(workspace(w).tourAnchor("panes")) }
        // After the window's restore offer has been answered (sessions), so a
        // first run is never asked two questions at once.
        SessionHooks.afterStartup.append { window in await offerOnFirstRun(window) }
    }

    static var running: Bool { WindowManager.shared.windows.contains { $0.feature(TourState.self).active } }

    /// Start the tour in a window. A second call while it runs is ignored.
    static func start(_ window: WindowModel) {
        let st = window.feature(TourState.self)
        guard !st.active, !running else { return }
        st.step = 0
        st.active = true
        st.installKeys()
    }

    static func markSeen() {
        guard Store.shared.setting("tourSeenVersion", 0) != version else { return }
        Store.shared.setSetting("tourSeenVersion", version)
    }

    /// Offer the tour on a first run: an offer, not an automatic start, and
    /// only an explicit answer settles it (Escape asks again next launch).
    static func offerOnFirstRun(_ window: WindowModel) async {
        if Store.shared.setting("tourSeenVersion", 0) == version { return }
        // A debug snapshot is not a first run.
        if CommandLine.arguments.contains("--snapshot") { return }
        // Not now, but not "seen" either: a window with sessions already
        // restored, or a second window, should not be interrupted.
        guard WindowManager.shared.windows.contains(where: { $0 === window }) else { return }
        if WindowManager.shared.windows.count > 1 { return }
        if MiscHooks.windowHasSessions?(window) == true { return }
        if !window.feature(SessionsWindow.self).tabs.isEmpty { return }
        if running { return }

        let answer: Bool? = await withCheckedContinuation { cont in
            var done = false
            let finish: (Bool?) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let h = Modal.sheet(window, title: "First time here?", width: 460) { handle in
                DialogScaffold(title: "First time here?") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ServerLife puts terminals, a file browser, fleet-wide commands and "
                             + "port forwarding for Teleport and SSH hosts in one window.")
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Text("A short tour points at each part and says what it is for — about a "
                             + "minute, and you can leave at any point. It stays in the Help menu "
                             + "either way.")
                            .font(.system(size: 12)).foregroundStyle(Theme.shared.p.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Button("Not now") { finish(false); handle.close() }.buttonStyle(.ghost)
                    Button("Take the tour") { finish(true); handle.close() }
                        .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                }
            }
            h.onClose.append { finish(nil) }
        }
        if answer == true { start(window) } else if answer == false { markSeen() }
    }
}

/// The tour's state in one window.
@MainActor
@Observable
final class TourState: WindowFeature {
    @ObservationIgnored weak var window: WindowModel?
    var active = false
    var step = 0
    @ObservationIgnored private var monitor: Any?

    init(window: WindowModel) { self.window = window }

    func go(_ n: Int) { step = max(0, min(Tour.steps.count - 1, n)) }

    func end() {
        guard active else { return }
        active = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Tour.markSeen()
    }

    /// Escape leaves; → and Return step on; ← steps back. Only while this
    /// window (not a sheet or another window) has the keyboard.
    func installKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            let num = e.windowNumber
            let consumed: Bool = MainActor.assumeIsolated { self?.handleKey(code, windowNumber: num) ?? false }
            return consumed ? nil : e
        }
    }

    private func handleKey(_ code: UInt16, windowNumber: Int) -> Bool {
        guard active, let w = window?.nsWindow, w.windowNumber == windowNumber else { return false }
        let last = step == Tour.steps.count - 1
        switch code {
        case 53: end(); return true
        case 124, 36, 76: if last { end() } else { go(step + 1) }; return true
        case 123: go(step - 1); return true
        default: return false
        }
    }
}

// MARK: - Anchors

/// Where the views the tour points at are, per window. Owners tag a view with
/// `.tourAnchor("id")`; the tour asks for its frame when a step is shown.
@MainActor
final class TourAnchors {
    static let shared = TourAnchors()
    private final class Weak { weak var view: NSView?; init(_ v: NSView) { view = v } }
    private var byId: [String: [Weak]] = [:]

    func register(_ id: String, _ view: NSView) {
        var list = (byId[id] ?? []).filter { $0.view != nil && $0.view !== view }
        list.append(Weak(view))
        byId[id] = list
    }

    func unregister(_ id: String, _ view: NSView) {
        byId[id] = (byId[id] ?? []).filter { $0.view != nil && $0.view !== view }
    }

    /// The first usable view with this id in `window`, in window coordinates.
    /// "Usable" as tour.js has it: on screen and at least 4×4.
    func frame(_ id: String, in window: NSWindow) -> NSRect? {
        for w in byId[id] ?? [] {
            guard let v = w.view, v.window === window, !v.isHiddenOrHasHiddenAncestor else { continue }
            let r = v.convert(v.bounds, to: nil)
            if r.width >= 4 && r.height >= 4 { return r }
        }
        return nil
    }

    func ids() -> [String] { byId.filter { $0.value.contains { $0.view != nil } }.map(\.key).sorted() }
}

extension View {
    /// Marks this view as something the guided tour can spotlight. The ids
    /// each step uses are listed in Misc/README.md.
    func tourAnchor(_ id: String) -> some View {
        background(TourAnchorView(id: id).allowsHitTesting(false))
    }
}

private struct TourAnchorView: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> AnchorNSView { AnchorNSView(id: id) }
    func updateNSView(_ v: AnchorNSView, context: Context) {
        if v.anchorId != id {
            TourAnchors.shared.unregister(v.anchorId, v)
            v.anchorId = id
            TourAnchors.shared.register(id, v)
        }
    }

    final class AnchorNSView: NSView {
        var anchorId: String
        init(id: String) { anchorId = id; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                if window != nil { TourAnchors.shared.register(anchorId, self) }
                else { TourAnchors.shared.unregister(anchorId, self) }
            }
        }
    }
}

// MARK: - Overlay

private struct TourOverlay: View {
    let window: WindowModel
    var body: some View {
        let st = window.feature(TourState.self)
        if st.active {
            TourLayer(window: window, state: st)
        }
    }
}

private struct TourLayer: View {
    let window: WindowModel
    let state: TourState
    @StateObject private var cardHeight = Local<CGFloat>(260)

    /// The target's rect in this overlay's coordinates, or nil to centre.
    /// `origin` is the overlay's own origin in the window's content view.
    private func targetRect(size: CGSize, origin: CGPoint) -> CGRect? {
        let step = Tour.steps[state.step]
        guard let id = step.target, let nsw = window.nsWindow, let cv = nsw.contentView else { return nil }
        if let r = TourAnchors.shared.frame(id, in: nsw) {
            var local = cv.convert(r, from: nil)
            if !cv.isFlipped { local.origin.y = cv.bounds.height - local.maxY }
            return local.offsetBy(dx: -origin.x, dy: -origin.y)
        }
        // The title bar is the shell's own; its 38 points are known.
        if id == "titlebar" { return CGRect(x: 0, y: 0, width: size.width, height: 38) }
        return nil
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            GeometryReader { geo in
                let size = geo.size
                let target = targetRect(size: size, origin: geo.frame(in: .global).origin)
                ZStack(alignment: .topLeading) {
                    Color.clear.allowsHitTesting(false)
                    if let t = target {
                        let ring = t.insetBy(dx: -4, dy: -4)
                        Spotlight(hole: ring)
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                            .allowsHitTesting(false)
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Theme.shared.p.accent, lineWidth: 2)
                            .shadow(color: Theme.shared.p.accentDim, radius: 7)
                            .frame(width: ring.width, height: ring.height)
                            .offset(x: ring.minX, y: ring.minY)
                            .allowsHitTesting(false)
                            .animation(.easeInOut(duration: 0.18), value: ring)
                        card
                            .offset(cardOrigin(target: t, size: size))
                    } else {
                        Color.black.opacity(0.55).allowsHitTesting(false)
                        card
                            .offset(x: (size.width - 400) / 2, y: max(8, (size.height - cardHeight.value) / 2))
                    }
                }
            }
        }
    }

    /// The card on whichever side has room, preferring below and right; a
    /// target taking most of the window gets the card beside it.
    private func cardOrigin(target r: CGRect, size: CGSize) -> CGSize {
        let cw: CGFloat = min(400, size.width * 0.92)
        let ch = cardHeight.value
        let gap: CGFloat = 14
        var left = r.minX
        var top = r.maxY + gap
        if top + ch > size.height - 8 {
            top = r.minY - ch - gap
            if top < 8 { top = min(r.maxY + gap, size.height - ch - 8) }
        }
        if left + cw > size.width - 8 { left = size.width - cw - 8 }
        if r.width > size.width * 0.5 && r.height > size.height * 0.5 {
            left = min(r.maxX + gap, size.width - cw - 8)
            top = max(8, min(r.minY, size.height - ch - 8))
        }
        return CGSize(width: max(8, left), height: max(8, top))
    }

    private var card: some View {
        let p = Theme.shared.p
        let i = state.step
        let step = Tour.steps[i]
        let last = i == Tour.steps.count - 1
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(i + 1) of \(Tour.steps.count)".uppercased())
                .font(.system(size: 10, weight: .semibold)).kerning(0.7).foregroundStyle(p.muted)
            Text(step.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                .padding(.top, 2).padding(.bottom, 8)
            ForEach(Array(step.body.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, para in
                Text(para).font(.system(size: 12.5)).foregroundStyle(p.textDim)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            HStack(spacing: 5) {
                ForEach(0..<Tour.steps.count, id: \.self) { n in
                    Button { state.go(n) } label: {
                        Circle().fill(n == i ? p.accent : p.panel3).frame(width: 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .help(Tour.steps[n].title)
                }
            }
            .padding(.top, 2).padding(.bottom, 11)
            HStack(spacing: 7) {
                Button("Skip tour") { state.end() }.buttonStyle(.ghostSmall)
                Spacer()
                if i > 0 { Button("Back") { state.go(i - 1) }.buttonStyle(.ghostSmall) }
                Button(last ? "Done" : "Next") { if last { state.end() } else { state.go(i + 1) } }
                    .buttonStyle(GhostButtonStyle(small: true, prominent: true))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 18)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { cardHeight.value = g.size.height }
                .onChange(of: g.size.height) { _, h in cardHeight.value = h }
        })
    }
}

/// The darkened window with a hole where the spotlight is.
private struct Spotlight: Shape {
    var hole: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: 7, height: 7))
        return p
    }
}
