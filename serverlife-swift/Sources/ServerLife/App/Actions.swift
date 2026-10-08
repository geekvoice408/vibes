import AppKit
import SwiftUI

/// What an action is being asked to act on. Every field is optional: a menu
/// item passes only the window; a host's context menu passes the host; a pane
/// menu passes the pane and its connection.
struct ActionContext {
    var window: WindowModel?
    var host: Host?
    var paneId: String?
    var connId: String?
    /// Anything else, keyed by name (documented next to the action in CLAUDE.md).
    var args: [String: Any] = [:]

    @MainActor init(window: WindowModel? = nil, host: Host? = nil, paneId: String? = nil, connId: String? = nil,
         args: [String: Any] = [:]) {
        self.window = window ?? WindowManager.shared.focused
        self.host = host
        self.paneId = paneId
        self.connId = connId
        self.args = args
    }

    func arg<T>(_ key: String, as: T.Type = T.self) -> T? { args[key] as? T }
}

/// The action registry: how the menu bar, context menus and feature modules
/// reach each other without compile-time coupling.
///
/// The Electron main process sent `menu` events carrying an action string
/// (`'new-session'`, `'multiexec'`, …) to the focused renderer, which
/// dispatched them. The same ids are used here. A feature registers its
/// handlers in its `install()`; anyone may `perform` an id. An id nobody has
/// registered says so in the status bar instead of doing nothing silently.
@MainActor
final class Actions {
    static let shared = Actions()

    typealias Handler = @MainActor (ActionContext) -> Void
    private var handlers: [String: Handler] = [:]
    /// Optional "is it available right now" checks, used to grey menu items.
    private var validators: [String: @MainActor (ActionContext) -> Bool] = [:]

    func register(_ id: String, enabled: (@MainActor (ActionContext) -> Bool)? = nil, _ handler: @escaping Handler) {
        handlers[id] = handler
        if let enabled { validators[id] = enabled }
    }

    func isRegistered(_ id: String) -> Bool { handlers[id] != nil }

    func isEnabled(_ id: String, _ ctx: ActionContext? = nil) -> Bool {
        guard handlers[id] != nil else { return false }
        return validators[id]?(ctx ?? ActionContext()) ?? true
    }

    func perform(_ id: String, _ context: ActionContext? = nil) {
        let ctx = context ?? ActionContext()
        guard let h = handlers[id] else {
            StatusBus.shared.show("“\(id)” is not available in this build", kind: .warn)
            return
        }
        h(ctx)
    }

    /// Convenience for the common cases.
    func perform(_ id: String, window: WindowModel? = nil, host: Host? = nil, paneId: String? = nil,
                 connId: String? = nil, args: [String: Any] = [:]) {
        perform(id, ActionContext(window: window, host: host, paneId: paneId, connId: connId, args: args))
    }
}

/// Transient messages in the status bar (`status()` in ui.js), and toasts.
@MainActor
@Observable
final class StatusBus {
    static let shared = StatusBus()

    enum Kind: String { case info, ok, warn, error }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var kind: Kind
        var at = Date()
    }

    /// The current status-bar message.
    private(set) var message: Message?
    /// Toasts: short-lived notices drawn over the window's corner.
    private(set) var toasts: [Message] = []
    @ObservationIgnored private var clearWork: DispatchWorkItem?

    /// Show a status message; it fades after `seconds` (0 = stays). 4 s, as ui.js `status`.
    func show(_ text: String, kind: Kind = .info, seconds: Double = 4) {
        message = Message(text: text, kind: kind)
        clearWork?.cancel()
        guard seconds > 0 else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.message = nil } }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func toast(_ text: String, kind: Kind = .info, seconds: Double = 3.8) {
        let m = Message(text: text, kind: kind)
        toasts.append(m)
        after(seconds) { [weak self] in self?.toasts.removeAll { $0.id == m.id } }
    }

    func dismissToast(_ id: UUID) { toasts.removeAll { $0.id == id } }

    func clear() { message = nil }
}

/// Items drawn in the status bar by features (connection count, broadcast,
/// watches, forwards, transfer progress …), in registration order.
@MainActor
final class StatusItems {
    static let shared = StatusItems()
    struct Item {
        let id: String
        let order: Int
        let view: @MainActor (WindowModel) -> AnyView
    }
    private(set) var items: [Item] = []
    func register(_ id: String, order: Int, _ view: @escaping @MainActor (WindowModel) -> AnyView) {
        items.removeAll { $0.id == id }
        items.append(Item(id: id, order: order, view: view))
        items.sort { $0.order < $1.order }
    }
}
