import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A presented dialog or panel. Content views receive it so they can close
/// themselves (`handle.close()`), and owners can close it from outside.
@MainActor
final class ModalHandle {
    let window: NSWindow
    let isSheet: Bool
    /// Called once, after the window has gone (however it was closed).
    var onClose: [() -> Void] = []
    private(set) var closed = false

    init(window: NSWindow, isSheet: Bool) {
        self.window = window
        self.isSheet = isSheet
    }

    func close() {
        guard !closed else { return }
        closed = true
        if isSheet, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        window.close()
        onClose.forEach { $0() }
        Modal.forget(self)
    }

    /// Change the title of a panel.
    func setTitle(_ t: String) { window.title = t }
}

/// The NSWindow behind every dialog: Escape closes it unless told otherwise.
final class ModalWindow: NSPanel {
    var closeOnEscape = true
    weak var handle: ModalHandle?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if closeOnEscape { MainActor.assumeIsolated { handle?.close() } }
    }
}

/// Dialogs, sheets, panels and the standard pickers — the port of ui.js's
/// `modal()`, `confirm()`, `prompt()` and the dialog:* IPC handlers.
@MainActor
enum Modal {
    private static var open: [ModalHandle] = []
    private static var panelsById: [String: ModalHandle] = [:]

    fileprivate static func forget(_ h: ModalHandle) {
        open.removeAll { $0 === h }
        for (k, v) in panelsById where v === h { panelsById.removeValue(forKey: k) }
    }

    /// The topmost window to attach a sheet to: the owner's frontmost sheet if
    /// one is already up, so dialogs stack the way the web version's did.
    private static func sheetParent(_ owner: WindowModel?) -> NSWindow? {
        guard var w = (owner ?? WindowManager.shared.focused)?.nsWindow ?? NSApp.keyWindow else { return nil }
        while let s = w.attachedSheet { w = s }
        return w
    }

    /// A dialog as a sheet over the window. `width`/`height` are the initial
    /// content size; with `autosave` a resized dialog reopens at that size.
    @discardableResult
    static func sheet<V: View>(_ owner: WindowModel? = nil, title: String = "", width: CGFloat = 520,
                               height: CGFloat? = nil, resizable: Bool = false, autosave: String? = nil,
                               closeOnEscape: Bool = true,
                               @ViewBuilder content: (ModalHandle) -> V) -> ModalHandle {
        let win = ModalWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 200),
                              styleMask: resizable ? [.titled, .resizable] : [.titled],
                              backing: .buffered, defer: false)
        win.title = title
        win.closeOnEscape = closeOnEscape
        let handle = ModalHandle(window: win, isSheet: true)
        win.handle = handle
        let host = NSHostingController(rootView: AnyView(content(handle).themed()))
        if height == nil { host.sizingOptions = [.preferredContentSize] }
        win.contentViewController = host
        if height != nil || resizable { win.setContentSize(NSSize(width: width, height: height ?? 420)) }
        if let autosave { win.setFrameAutosaveName("sheet." + autosave) }
        open.append(handle)
        if let parent = sheetParent(owner) {
            parent.beginSheet(win) { _ in }
        } else {
            win.center()
            win.makeKeyAndOrderFront(nil)
        }
        return handle
    }

    /// A free-standing window: the guide, network tools, recordings, the
    /// requestable-resource monitor. With an `id`, a second request brings the
    /// open one forward instead of opening another.
    @discardableResult
    static func panel<V: View>(id: String? = nil, title: String, width: CGFloat = 720, height: CGFloat = 520,
                               floating: Bool = false, utility: Bool = false, autosave: String? = nil,
                               @ViewBuilder content: (ModalHandle) -> V) -> ModalHandle {
        if let id, let existing = panelsById[id], !existing.closed {
            existing.window.makeKeyAndOrderFront(nil)
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        if utility { style.insert(.utilityWindow) }
        let win = ModalWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: style, backing: .buffered, defer: false)
        win.title = title
        win.closeOnEscape = false
        win.isFloatingPanel = floating
        win.hidesOnDeactivate = false
        win.becomesKeyOnlyIfNeeded = false
        win.isReleasedWhenClosed = false
        let handle = ModalHandle(window: win, isSheet: false)
        win.handle = handle
        win.contentViewController = NSHostingController(rootView: AnyView(content(handle).themed()))
        win.setContentSize(NSSize(width: width, height: height))
        if let autosave { win.setFrameAutosaveName("panel." + autosave) } else { win.center() }
        if autosave == nil || !win.setFrameUsingName("panel." + (autosave ?? "")) { win.center() }
        let closer = PanelCloseObserver(handle: handle)
        objc_setAssociatedObject(win, &PanelCloseObserver.key, closer, .OBJC_ASSOCIATION_RETAIN)
        open.append(handle)
        if let id { panelsById[id] = handle }
        win.makeKeyAndOrderFront(nil)
        return handle
    }

    static func isPanelOpen(_ id: String) -> Bool { panelsById[id].map { !$0.closed } ?? false }
    static func panelHandle(_ id: String) -> ModalHandle? { panelsById[id] }

    // MARK: - Standard questions

    /// A yes/no question (ui.js `confirm`). Returns true for the OK button.
    ///
    /// As in the original, Return never confirms: focus starts on Cancel,
    /// and Escape cancels. `detail` is the smaller hint line under the message.
    static func confirm(_ owner: WindowModel? = nil, title: String, message: String = "", detail: String? = nil,
                        ok: String = "OK", cancel: String = "Cancel", destructive: Bool = false) async -> Bool {
        await choose(owner, title: title, message: message, detail: detail, buttons: [ok, cancel],
                     destructive: destructive) == 0
    }

    /// Several answers; returns the index of the button pressed. The last
    /// button is treated as Cancel (Escape, and the initial focus). Return
    /// presses nothing unless `returnPresses` names a button — the original's
    /// dialogs focused Cancel, so a stray Return never changed anything.
    static func choose(_ owner: WindowModel? = nil, title: String, message: String = "", detail: String? = nil,
                       buttons: [String], destructive: Bool = false, returnPresses: Int? = nil) async -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .informational
        var cancelButton: NSButton?
        for (i, b) in buttons.enumerated() {
            let btn = alert.addButton(withTitle: b)
            btn.keyEquivalent = ""
            if destructive && i == 0 { btn.hasDestructiveAction = true }
            if i == buttons.count - 1 && buttons.count > 1 { btn.keyEquivalent = "\u{1b}"; cancelButton = btn }
            if let r = returnPresses, r == i { btn.keyEquivalent = "\r" }
        }
        if let detail, !detail.isEmpty {
            let hint = NSTextField(wrappingLabelWithString: detail)
            hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            hint.textColor = .secondaryLabelColor
            hint.preferredMaxLayoutWidth = 300
            hint.frame = NSRect(x: 0, y: 0, width: 300, height: hint.fittingSize.height)
            alert.accessoryView = hint
        }
        if let cancelButton { alert.window.initialFirstResponder = cancelButton }
        return await run(alert, owner)
    }

    static func alert(_ owner: WindowModel? = nil, title: String, message: String = "") async {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        _ = await run(a, owner)
    }

    /// One line of text (ui.js `prompt`). nil when cancelled.
    static func prompt(_ owner: WindowModel? = nil, title: String, message: String = "", value: String = "",
                       placeholder: String = "", ok: String = "OK", secure: Bool = false) async -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let field: NSTextField = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                                        : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        a.accessoryView = field
        a.window.initialFirstResponder = field
        let r = await run(a, owner)
        return r == 0 ? field.stringValue : nil
    }

    private static func run(_ alert: NSAlert, _ owner: WindowModel?) async -> Int {
        if let parent = sheetParent(owner) {
            return await withCheckedContinuation { cont in
                alert.beginSheetModal(for: parent) { resp in
                    cont.resume(returning: resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
                }
            }
        }
        let resp = alert.runModal()
        return resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    // MARK: - Pickers (dialog:* handlers)

    static func openFiles(_ owner: WindowModel? = nil, directories: Bool = false, files: Bool = true,
                          multiple: Bool = true, directory: String? = nil, prompt: String? = nil,
                          types: [UTType]? = nil, title: String? = nil, message: String? = nil) async -> [URL] {
        let p = NSOpenPanel()
        if let title { p.title = title }
        if let message { p.message = message }
        p.canChooseFiles = files
        p.canChooseDirectories = directories
        p.allowsMultipleSelection = multiple
        p.canCreateDirectories = directories
        p.showsHiddenFiles = true
        if let directory { p.directoryURL = URL(fileURLWithPath: directory.expandingTilde) }
        if let prompt { p.prompt = prompt }
        if let types { p.allowedContentTypes = types }
        return await present(p, owner) ? p.urls : []
    }

    static func chooseDirectory(_ owner: WindowModel? = nil, defaultPath: String? = nil, prompt: String? = nil,
                                title: String? = nil, message: String? = nil) async -> URL? {
        await openFiles(owner, directories: true, files: false, multiple: false, directory: defaultPath, prompt: prompt,
                        title: title, message: message).first
    }

    static func chooseApp(_ owner: WindowModel? = nil) async -> URL? {
        await openFiles(owner, directories: false, files: true, multiple: false, directory: "/Applications",
                        types: [.application]).first
    }

    static func saveFile(_ owner: WindowModel? = nil, defaultName: String, directory: String? = nil,
                         types: [UTType]? = nil, title: String? = nil, message: String? = nil) async -> URL? {
        let p = NSSavePanel()
        if let title { p.title = title }
        if let message { p.message = message }
        p.nameFieldStringValue = defaultName
        p.canCreateDirectories = true
        p.showsHiddenFiles = true
        if let directory { p.directoryURL = URL(fileURLWithPath: directory.expandingTilde) }
        if let types { p.allowedContentTypes = types }
        return await present(p, owner) ? p.url : nil
    }

    /// Ask where, then write (dialog:saveText). Returns where it went.
    @discardableResult
    static func saveText(_ owner: WindowModel? = nil, _ text: String, defaultName: String, directory: String? = nil,
                         title: String? = nil) async -> URL? {
        guard let url = await saveFile(owner, defaultName: defaultName, directory: directory, title: title,
                                       message: title) else { return nil }
        do {
            try Data(text.utf8).write(to: url)
            StatusBus.shared.show("Saved \(url.lastPathComponent)", kind: .ok)
            return url
        } catch {
            await alert(owner, title: "Could not save", message: error.localizedDescription)
            return nil
        }
    }

    private static func present(_ panel: NSSavePanel, _ owner: WindowModel?) async -> Bool {
        if let parent = sheetParent(owner) {
            return await withCheckedContinuation { cont in
                panel.beginSheetModal(for: parent) { cont.resume(returning: $0 == .OK) }
            }
        }
        return panel.runModal() == .OK
    }
}


/// Closes the handle bookkeeping when a panel's own close button is used.
private final class PanelCloseObserver: NSObject {
    static var key = 0
    weak var handle: ModalHandle?
    private var token: NSObjectProtocol?
    init(handle: ModalHandle) {
        self.handle = handle
        super.init()
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: handle.window,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let h = self?.handle, !h.closed else { return }
                h.close()
            }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// Clipboard (clipboard:write / clipboard:read).
enum Clipboard {
    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func read() -> String { NSPasteboard.general.string(forType: .string) ?? "" }
}
