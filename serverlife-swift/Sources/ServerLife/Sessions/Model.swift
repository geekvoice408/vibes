import AppKit
import SwiftUI
import Observation

/// What a pane is running.
enum PaneKind: String {
    /// A shell (or files-only browser) on a connection.
    case remote
    /// A local shell, or a local program on a pty (tsh play, tsh latency).
    case local
    /// A serial console, a telnet session — any backend with no connection.
    case device
    /// One pane of a tmux window.
    case tmux
    /// Not a terminal at all: a VNC screen, a hosts list.
    case view
}

/// The connect overlay: progress, prompts answered in the pane, failures and
/// the ways forward from them (sessions.js `showOverlay`).
struct PaneOverlay {
    struct Action { var label: String; var run: () -> Void }
    struct MfaOffer { var current: String; var retry: (String) -> Void; var copyCommand: () -> Void }
    struct LoginsOffer { var current: String?; var options: [String]; var retry: (String) -> Void }

    var id = UUID()
    var title: String
    var sub: String = ""
    var error: String?
    var showLog = false
    var retry: (() -> Void)?
    var promptInput = false
    var alt: Action?
    var mfa: MfaOffer?
    var logins: LoginsOffer?
    /// Lines added by callers that are not `connectPane` (`noteOverlay`).
    var notes = ""
    /// The scene playing while it dials; none on an error.
    var scene: ConnectAnim?
}

/// One pane: the port of the pane objects sessions.js kept in `state.panes`.
///
/// The pane object never changes hands when it moves — between splits, tabs
/// or windows — so its terminal, scrollback and whatever runs behind it carry
/// on without noticing.
@MainActor
@Observable
final class SessionPane: Identifiable {
    let id: String
    var tabId: String
    var kind: PaneKind
    var connId: String?
    /// The descriptor behind a device or view pane (serial, telnet, vnc …),
    /// saved with a layout so it can be opened again.
    var host: Host?

    var cwd: String?
    var remoteHome: String?
    /// Its own title (local program, console, screen, hosts list).
    var title: String?
    /// The title the program in the terminal asked for (OSC 0/2).
    var remoteTitle: String?
    var shellName: String?
    var blankShell = false

    /// idle | connecting | connected | error | closed
    var status = "idle"
    var error: String?
    var overlay: PaneOverlay?
    /// The prompt input stays once a prompt has been seen in this overlay.
    var overlaySawPrompt = false

    @ObservationIgnored var backend: TerminalBackend?
    /// Whether something is attached and running (the original's `termId`).
    var hasTerm = false

    /// The terminal, for every kind but `view`.
    @ObservationIgnored private(set) var term: SessionTermView?
    /// A view pane's content (VNC, hosts list).
    @ObservationIgnored var content: (() -> AnyView)?
    @ObservationIgnored var onClose: (() -> Void)?

    // Highlighting: compiled rules (nil = off), the rewriter's state, and the
    // pane's own override (nil = follow the host / global setting).
    @ObservationIgnored var highlight: [Highlight.Compiled]?
    @ObservationIgnored var highlightState = Highlight.State()
    var highlightOverride: Bool?
    var highlightCount = 0

    var explorerVisible = false {
        didSet {
            // Nothing is polled while it is hidden: catch up on the way in.
            guard explorerVisible, !oldValue else { return }
            let id = self.id
            DispatchQueue.main.async { MainActor.assumeIsolated { XPFiles.catchUpVisible(id) } }
        }
    }
    var filesOnly = false
    var isHosts = false
    var hostsGroup: String?
    /// Explorer size beside / above the terminal, in points (nil = default).
    var accessorySize: CGFloat?

    /// Run when the program in this pane finishes (a login run in a tab).
    @ObservationIgnored var onExit: ((Int32?) -> Void)?
    /// How a console with no connection is opened again after it ended.
    @ObservationIgnored var reconnect: (() async throws -> TerminalBackend)?
    var reconnectArmed = false

    // MFA watch for tsh sessions that exit without reaching a shell.
    @ObservationIgnored var mfaTail = ""
    @ObservationIgnored var mfaSucceeded = false
    @ObservationIgnored var mfaOffered = false

    /// Session log (⌘⇧L): where it is going, if anywhere.
    var logPath: String?

    // Scrollback search (the box in the header).
    var searchText = ""
    var searchActive = false
    var searchCount = -1
    var searchIndex = -1
    @ObservationIgnored var searchFocusToken = 0
    var searchFocusRequest = 0

    /// The ▶ button's state, set by fleet when a macro repeats on this pane.
    var macroRepeating = false
    var macroButtonTitle: String?

    /// tmux: what the tab and the header say instead of a shell's title, and
    /// whether the session has ended (set by consoles).
    @ObservationIgnored var titleProvider: ((SessionPane, Bool) -> String?)?
    var tmuxEnded: String?
    var titleRevision = 0

    /// The window's sessions this pane is in now (it changes when a pane
    /// is moved to another window).
    @ObservationIgnored weak var owner: SessionsWindow?
    /// Anything another feature wants to keep with a pane.
    @ObservationIgnored var attachments: [String: Any] = [:]

    /// Where the pane is on screen (for "the pane to my left").
    @ObservationIgnored var frame: CGRect = .zero
    /// Partial UTF-8 sequence carried between chunks for the highlighter.
    @ObservationIgnored var pendingBytes = Data()

    init(id: String = uid("pane"), tabId: String, kind: PaneKind, connId: String?) {
        self.id = id
        self.tabId = tabId
        self.kind = kind
        self.connId = connId
        if kind != .view {
            term = SessionTermView()
        }
    }

    /// Re-read the highlight rules for this pane: when it is made, when its
    /// connection lands (the host is only known then), and when rules change.
    func applyHighlightSettings() {
        let key = SessionsCore.hostKey(of: self)
        let base = key.map { Highlight.isOn($0) } ?? (Store.shared.settingJSON("highlight").bool != false)
        let on = highlightOverride ?? base
        highlight = on ? Highlight.compile(Highlight.rulesFor(key)) : nil
        highlightCount = highlight?.count ?? 0
    }

    func disposeTerm() {
        term?.dispose()
        term = nil
    }
}

/// One tab: a tree of panes.
@MainActor
@Observable
final class SessionTab: Identifiable {
    let id: String
    var title: String
    /// remote | local — what the tab was opened as.
    var kind: String
    var connId: String?
    var root: PaneNode?
    /// The pane you were last in, so coming back puts you there.
    var lastPaneId: String?
    var tmux = false
    var tmuxEnded: String?

    init(id: String = uid("tab"), title: String, kind: String, connId: String?) {
        self.id = id
        self.title = title
        self.kind = kind
        self.connId = connId
    }

    var paneIds: [String] { root?.paneIds ?? [] }
    var firstPane: String? { root?.firstPane }
}

/// What this app knows about a connection beyond what the connection layer
/// says: which host it was dialled for, as whom, and what to call it.
@MainActor
@Observable
final class SessConnRecord {
    let id: String
    var host: Host
    var login: String?
    var x11: String
    /// The first block of the node id, when two nodes share one hostname.
    var dupe: String?
    /// A tab renamed by hand renames its connection's label too.
    var labelOverride: String?

    init(id: String, host: Host, login: String?, x11: String?) {
        self.id = id
        self.host = host
        self.login = login
        self.x11 = x11 ?? "off"
    }

    var hostId: String { host.id }
}

/// Connection records shared by every window (connections are shared).
@MainActor
@Observable
final class SessConnRecords {
    static let shared = SessConnRecords()
    private(set) var records: [String: SessConnRecord] = [:]
    func set(_ r: SessConnRecord) { records[r.id] = r }
    func get(_ id: String?) -> SessConnRecord? { id.flatMap { records[$0] } }
    func remove(_ id: String) { records.removeValue(forKey: id) }

    /// The label shown for a connection.
    func label(_ id: String?) -> String? { get(id)?.labelOverride ?? SessConn.label(id) }
}
