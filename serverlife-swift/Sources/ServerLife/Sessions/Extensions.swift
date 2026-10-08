import AppKit
import SwiftUI

// Seams other owners fill. Each is documented in Sessions/README.md.

/// Answers Sessions needs from features it does not own. All optional:
/// unset, Sessions falls back to what it can work out from settings alone.
@MainActor
enum SessionHooks {
    /// The live descriptor for a host id (sidebar / teleport-service:
    /// `hostById`, searching Teleport nodes then ssh_config hosts).
    static var hostById: ((String) -> Host?)?
    /// Which login to connect as when none was given (sidebar `preferredLogin`).
    static var preferredLogin: ((Host) -> String?)?
    /// The logins a host's cluster certificate carries (teleport-service),
    /// offered as "Try as …" when authentication fails.
    static var loginOptions: ((Host) -> [String])?
    /// How many port forwards ride a connection (connections). A shell that
    /// has exited still counts as live while a forward uses its connection.
    static var forwardCount: ((String) -> Int)?
    /// Awaited before the launch restore is offered, so saved panes can be
    /// matched to hosts (teleport-service / sidebar: inventory loaded).
    static var waitForInventory: (() async -> Void)?
    /// Run once per window after the restore offer (misc: the tour's
    /// first-run offer, so a first run is not asked two questions at once).
    static var afterStartup: [(WindowModel) async -> Void] = []
    /// More for the status bar after the session item (sidebar: "N selected
    /// for multi-exec").
    static var statusExtra: ((WindowModel) -> String?)?
    /// A pane's directory changed (explorer: follow the terminal).
    static var cwdChanged: [(SessionPane) -> Void] = []
    /// A line that looked like `cd` was just typed in a pane; probe soon
    /// (explorer: `followPaneNow`). Sessions also re-reads the pane's cwd.
    static var directoryChangeTyped: [(SessionPane) -> Void] = []
    /// A pane is being closed for good (fleet: stop its repeating macros;
    /// explorer: tear down; consoles: forget a tmux pane).
    static var paneClosing: [(SessionPane) -> Void] = []
    /// A pane was created (explorer may prepare its browser).
    static var paneCreated: [(SessionPane) -> Void] = []
}

/// Items other owners add to a pane's right-click menu.
///
/// `.top` items appear first, where the original put a console's, a tmux
/// pane's and a screen's own commands (Send break, Split (tmux), Detach …,
/// Send Ctrl+Alt+Del). `.middle` items appear after "Command history on this
/// host…". Return no items for panes that are not yours.
@MainActor
final class PaneMenuItems {
    static let shared = PaneMenuItems()
    enum Section { case top, middle }
    struct Provider {
        let id: String
        let section: Section
        let make: @MainActor (SessionPane, WindowModel) -> [NSMenuItem]
    }
    private(set) var providers: [Provider] = []

    func register(_ id: String, section: Section = .top,
                  _ make: @escaping @MainActor (SessionPane, WindowModel) -> [NSMenuItem]) {
        providers.removeAll { $0.id == id }
        providers.append(Provider(id: id, section: section, make: make))
    }

    func items(_ section: Section, _ pane: SessionPane, _ window: WindowModel) -> [NSMenuItem] {
        providers.filter { $0.section == section }.flatMap { $0.make(pane, window) }
    }
}

/// Views other owners put in a pane's header: the tmux session's controls
/// (consoles) and the pinned-macro buttons (fleet), in the places the
/// original reserved for them (`.ptmux-ctl`, `.pmacro-pins`).
@MainActor
@Observable
final class PaneHeaderItems {
    static let shared = PaneHeaderItems()
    enum Slot { case tmuxControls, macroPins }
    struct Provider {
        let id: String
        let slot: Slot
        let make: @MainActor (SessionPane) -> AnyView?
    }
    private(set) var providers: [Provider] = []
    /// Bump to redraw every header (e.g. the macro pins changed).
    var revision = 0

    func register(_ id: String, slot: Slot, _ make: @escaping @MainActor (SessionPane) -> AnyView?) {
        providers.removeAll { $0.id == id }
        providers.append(Provider(id: id, slot: slot, make: make))
        revision += 1
    }

    func views(_ slot: Slot, _ pane: SessionPane) -> [AnyView] {
        _ = revision
        return providers.filter { $0.slot == slot }.compactMap { $0.make(pane) }
    }
}

/// What sits beside (or above) a pane's terminal: the file browser.
///
/// The explorer owner sets `provider`; it is drawn when the pane's
/// `explorerVisible` is on, on the left or the top according to
/// settings.explorerPosition, at the size it was dragged to. A files-only
/// pane is the accessory alone.
@MainActor
@Observable
final class PaneAccessories {
    static let shared = PaneAccessories()
    var provider: (@MainActor (SessionPane) -> AnyView)?
    var hasProvider: Bool { provider != nil }
}

/// An NSMenuItem that runs a closure.
final class SessMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, key: String = "", enabled: Bool = true, tooltip: String? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.isEnabled = enabled
        self.toolTip = tooltip
        if !key.isEmpty {
            // Shown, not bound: the shortcut belongs to the main menu.
            self.attributedTitle = nil
            self.title = title
            self.toolTip = tooltip
            self.keyHint = key
        }
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }

    /// The original's right-aligned shortcut hint, drawn as part of the title.
    var keyHint: String? {
        didSet {
            guard let keyHint else { return }
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
            let s = NSMutableAttributedString(string: title + "\t", attributes: [.paragraphStyle: para,
                                                                                  .font: NSFont.menuFont(ofSize: 0)])
            s.append(NSAttributedString(string: keyHint, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                       .font: NSFont.menuFont(ofSize: 0),
                                                                       .paragraphStyle: para]))
            attributedTitle = s
        }
    }
}

extension NSMenu {
    @discardableResult
    func sessAdd(_ title: String, key: String = "", enabled: Bool = true, tooltip: String? = nil,
             _ run: @escaping () -> Void) -> NSMenuItem {
        let item = SessMenuItem(title, key: key, enabled: enabled, tooltip: tooltip, run)
        addItem(item)
        return item
    }

    func sessHeading(_ title: String) {
        let item = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        addItem(item)
    }
}
