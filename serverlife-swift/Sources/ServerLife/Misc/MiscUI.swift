import AppKit
import SwiftUI

// The parts of ui.js that App/ does not already have: the context-menu
// builder (`contextMenu` with icons, headings, two-line items, `?` help
// cards, submenus and shortcut keys), `prompt` with a label and validation,
// `confirm` with a detail line, `pickIcon`, and the `field` / `checkbox`
// form pieces as SwiftUI views.

// MARK: - Context menus

/// One entry of a context menu (ui.js `contextMenu` item).
struct CtxItem {
    var label: String = ""
    /// Shortcut shown at the right ("⌘N", "⌘⇧D"). Display and accelerator while open.
    var key: String? = nil
    /// An emoji or glyph in the icon gutter.
    var icon: String? = nil
    /// A dim second line under the label.
    var sub: String? = nil
    /// What the item answers / the command it runs / notes: shown as a tooltip card.
    var help: CtxHelp? = nil
    var disabled = false
    /// Hover text.
    var title: String? = nil
    var submenu: [CtxItem]? = nil
    var onClick: (() -> Void)? = nil
    fileprivate var kind: Kind = .item

    fileprivate enum Kind { case item, separator, heading }

    init(_ label: String, key: String? = nil, icon: String? = nil, sub: String? = nil, help: CtxHelp? = nil,
         disabled: Bool = false, title: String? = nil, submenu: [CtxItem]? = nil, onClick: (() -> Void)? = nil) {
        self.label = label; self.key = key; self.icon = icon; self.sub = sub; self.help = help
        self.disabled = disabled; self.title = title; self.submenu = submenu; self.onClick = onClick
    }

    private init(kind: Kind, label: String = "") { self.kind = kind; self.label = label }

    static let sep = CtxItem(kind: .separator)
    /// A non-clickable heading grouping the items under it.
    static func heading(_ text: String) -> CtxItem { CtxItem(kind: .heading, label: text) }
}

/// The `?` card on a menu item: a string, or `{ answers, command, notes }`.
struct CtxHelp {
    var answers: String?
    var command: String?
    var notes: [String] = []
    init(_ answers: String) { self.answers = answers }
    init(answers: String? = nil, command: String? = nil, notes: [String] = []) {
        self.answers = answers; self.command = command; self.notes = notes
    }
    var text: String {
        var parts: [String] = []
        if let answers { parts.append(answers) }
        if let command { parts.append("runs:\n" + command) }
        parts.append(contentsOf: notes)
        return parts.joined(separator: "\n\n")
    }
}

/// Builds and shows NSMenus from `CtxItem`s.
@MainActor
enum CtxMenu {
    /// Show at the mouse pointer (where the right-click happened).
    static func show(_ items: [CtxItem]) {
        let menu = build(items)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Show at a point in a view (for buttons that open a menu).
    static func show(_ items: [CtxItem], in view: NSView, at point: NSPoint) {
        build(items).popUp(positioning: nil, at: point, in: view)
    }

    static func build(_ items: [CtxItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let delegate = CtxMenuDelegate()
        menu.delegate = delegate
        // The delegate lives as long as the menu.
        objc_setAssociatedObject(menu, &CtxMenuDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        // An icon gutter only in a panel that has icons, and then for every row.
        let anyIcon = items.contains { $0.icon != nil }
        for it in items {
            switch it.kind {
            case .separator: menu.addItem(.separator())
            case .heading:
                menu.addItem(NSMenuItem.sectionHeader(title: it.label))
            case .item:
                let mi = NSMenuItem(title: it.label, action: nil, keyEquivalent: "")
                mi.isEnabled = !it.disabled
                if anyIcon { mi.image = glyphImage(it.icon ?? "") }
                if let sub = it.sub {
                    if #available(macOS 14.4, *) { mi.subtitle = sub } else { mi.title = it.label + " — " + sub }
                }
                if let t = it.title { mi.toolTip = t }
                if let h = it.help {
                    delegate.help[ObjectIdentifier(mi)] = h
                    // A `?` after the label says there is a card to read.
                    mi.attributedTitle = NSAttributedString(string: mi.title + "  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                        + NSAttributedString(string: "?", attributes: [.font: NSFont.menuFont(ofSize: 10),
                                                                       .foregroundColor: NSColor.secondaryLabelColor])
                }
                if let key = it.key { applyKey(key, to: mi) }
                let hasSub = !(it.submenu ?? []).isEmpty
                if hasSub { mi.submenu = build(it.submenu!) }
                if let click = it.onClick {
                    let target = CtxTarget(click)
                    mi.representedObject = target   // keeps the target alive with the item
                    if hasSub && !it.disabled {
                        // A row that does something keeps its click; the
                        // submenu is reached from the arrow (hover there).
                        mi.view = CtxClickRow(item: mi, label: it.label, sub: it.sub, icon: anyIcon ? (it.icon ?? "") : nil,
                                              key: it.key, action: click)
                    } else {
                        mi.target = target
                        mi.action = #selector(CtxTarget.fire(_:))
                    }
                }
                menu.addItem(mi)
            }
        }
        return menu
    }

    /// "⌘⇧D" → key equivalent D with command+shift.
    static func applyKey(_ key: String, to mi: NSMenuItem) {
        var mods: NSEvent.ModifierFlags = []
        var rest = ""
        for ch in key {
            switch ch {
            case "⌘": mods.insert(.command)
            case "⌥": mods.insert(.option)
            case "⇧": mods.insert(.shift)
            case "⌃": mods.insert(.control)
            default: rest.append(ch)
            }
        }
        let k = rest.trimmed
        guard !k.isEmpty else { return }
        let map: [String: Int] = ["←": NSLeftArrowFunctionKey, "→": NSRightArrowFunctionKey,
                                  "↑": NSUpArrowFunctionKey, "↓": NSDownArrowFunctionKey]
        if let f = map[k], let u = UnicodeScalar(f) { mi.keyEquivalent = String(Character(u)) }
        else if k.count == 1 { mi.keyEquivalent = k.lowercased() }
        else { return }
        mi.keyEquivalentModifierMask = mods
    }

    fileprivate static func glyphImage(_ s: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            guard !s.isEmpty else { return true }
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            let str = NSAttributedString(string: s, attributes: attr)
            let b = str.size()
            str.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2))
            return true
        }
    }
}

private func + (a: NSAttributedString, b: NSAttributedString) -> NSAttributedString {
    let m = NSMutableAttributedString(attributedString: a); m.append(b); return m
}

private final class CtxTarget: NSObject {
    let action: () -> Void
    init(_ a: @escaping () -> Void) { action = a }
    @objc func fire(_ sender: Any?) { action() }
}

/// Shows an item's help as a card beside the menu while it is highlighted
/// (ui.js `helpMark`): placed clear of the whole menu panel, not clickable.
private final class CtxMenuDelegate: NSObject, NSMenuDelegate {
    static var key = 0
    var help: [ObjectIdentifier: CtxHelp] = [:]
    private var card: NSPanel?

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        MainActor.assumeIsolated {
            hide()
            for i in menu.items { i.view?.needsDisplay = true }
            guard let item, let h = help[ObjectIdentifier(item)] else { return }
            show(h)
        }
    }

    func menuDidClose(_ menu: NSMenu) { MainActor.assumeIsolated { hide() } }

    @MainActor private func hide() { card?.orderOut(nil); card = nil }

    @MainActor private func show(_ h: CtxHelp) {
        let host = NSHostingView(rootView: CtxHelpCard(help: h).themed())
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        let mouse = NSEvent.mouseLocation
        // The menu panel under the pointer, so the card clears all of it.
        let menuFrame = NSApp.windows.first {
            $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue && $0.frame.contains(mouse)
        }?.frame ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = menuFrame.maxX + 10
        if x + size.width > screen.maxX { x = max(screen.minX + 8, menuFrame.minX - size.width - 10) }
        var y = mouse.y + 6 - size.height
        y = max(screen.minY + 8, min(y, screen.maxY - size.height - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)
        card = panel
    }
}

private struct CtxHelpCard: View {
    let help: CtxHelp
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 6) {
            if let a = help.answers { Text(a).font(.system(size: 12)).foregroundStyle(p.text) }
            if let c = help.command {
                Text("RUNS").font(.system(size: 9.5, weight: .semibold)).kerning(0.6).foregroundStyle(p.muted)
                Text(c).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(p.bg))
            }
            ForEach(Array(help.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.system(size: 11)).foregroundStyle(p.textDim)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 300, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }
}

/// A menu row that runs its action when clicked and still carries a
/// submenu, opened by hovering the arrow at its right edge.
private final class CtxClickRow: NSView {
    weak var item: NSMenuItem?
    let action: () -> Void
    private let label: String, sub: String?, icon: String?, key: String?

    init(item: NSMenuItem, label: String, sub: String?, icon: String?, key: String?, action: @escaping () -> Void) {
        self.item = item; self.label = label; self.sub = sub; self.icon = icon; self.key = key; self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: sub == nil ? 22 : 36))
        let w = (label as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        frame.size.width = max(160, w + 90 + (icon != nil ? 22 : 0))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    private var arrowRect: NSRect { NSRect(x: bounds.maxX - 26, y: 0, width: 26, height: bounds.height) }

    override func draw(_ dirtyRect: NSRect) {
        let lit = item?.isHighlighted ?? false
        if lit {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let fg: NSColor = lit ? .white : .labelColor
        var x: CGFloat = 14
        if let icon {
            CtxMenu.glyphImage(icon).draw(in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16))
            x += 22
        }
        let font = NSFont.menuFont(ofSize: 0)
        let ls = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: fg])
        let lh = ls.size().height
        if let sub {
            ls.draw(at: NSPoint(x: x, y: bounds.height / 2 + 1))
            NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                         .foregroundColor: lit ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor])
                .draw(at: NSPoint(x: x, y: bounds.height / 2 - 15))
        } else {
            ls.draw(at: NSPoint(x: x, y: (bounds.height - lh) / 2))
        }
        var right = bounds.maxX - 12
        let arrow = NSAttributedString(string: "\u{203A}", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: fg])
        arrow.draw(at: NSPoint(x: right - arrow.size().width, y: (bounds.height - arrow.size().height) / 2))
        right -= 22
        if let key {
            let ks = NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: lit ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor])
            ks.draw(at: NSPoint(x: right - ks.size().width, y: (bounds.height - ks.size().height) / 2))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The arrow is a control of its own: it opens, it does not run.
        if arrowRect.contains(p) { return }
        item?.menu?.cancelTracking()
        let run = action
        DispatchQueue.main.async { run() }
    }
}

// MARK: - Form pieces (ui.js field / checkbox / hint)

/// `field(label, input, hint)`: a label above the control, a hint below.
struct MiscField<Content: View>: View {
    let label: String?
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.textDim) }
            content()
            if let hint { MiscHint(text: hint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 10)
    }
}

/// `.hint`: a small muted note.
struct MiscHint: View {
    let text: String
    var color: Color? = nil
    var size: CGFloat = 10.5
    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(color ?? Theme.shared.p.muted)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// `checkbox(label, checked)`: a checkbox with its label, optionally a note under it.
struct MiscCheck: View {
    let label: String
    @Binding var isOn: Bool
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $isOn) { Text(label).font(.system(size: 12)) }
                .toggleStyle(.checkbox)
            if let note { MiscHint(text: note).padding(.leading, 22) }
        }
        .padding(.bottom, 9)
    }
}

/// `border-top:1px solid var(--border-soft);margin:14px 0 12px`.
struct MiscRule: View {
    var body: some View { Theme.shared.p.borderSoft.frame(height: 1).padding(.top, 4).padding(.bottom, 12) }
}

// MARK: - Dialogs

@MainActor
enum MiscUI {
    /// ui.js `confirm({ title, message, detail, confirmLabel, danger })`.
    static func confirm(_ owner: WindowModel? = nil, title: String, message: String = "", detail: String? = nil,
                        confirmLabel: String = "Confirm", danger: Bool = false) async -> Bool {
        await Modal.confirm(owner, title: title, message: message, detail: detail, ok: confirmLabel, destructive: danger)
    }

    /// ui.js `prompt({ title, label, value, placeholder, confirmLabel, validate })`.
    /// `validate` returns an error message to show under the field, or nil.
    /// Resolves to the trimmed text, or nil when cancelled.
    static func prompt(_ owner: WindowModel? = nil, title: String, label: String? = nil, value: String = "",
                       placeholder: String = "", confirmLabel: String = "OK",
                       validate: ((String) -> String?)? = nil) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var answered = false
            let finish: (String?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
            }
            let h = Modal.sheet(owner, title: title, width: 440) { handle in
                PromptView(title: title, label: label, initial: value, placeholder: placeholder,
                           confirmLabel: confirmLabel, validate: validate) { v in
                    finish(v)
                    handle.close()
                }
            }
            h.onClose.append { finish(nil) }
        }
    }

    /// ui.js `pickIcon`: the icon picker as a dialog of its own, for a menu
    /// item that has no form. nil when cancelled; "" for "no icon".
    static func pickIcon(_ owner: WindowModel? = nil, title: String = "Icon", subtitle: String = "",
                         value: String = "") async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var answered = false
            let finish: (String?) -> Void = { v in
                if answered { return }
                answered = true
                cont.resume(returning: v)
            }
            let h = Modal.sheet(owner, title: title, width: 460) { handle in
                IconPickView(title: title, subtitle: subtitle, initial: value) { v in
                    finish(v)
                    handle.close()
                }
            }
            h.onClose.append { finish(nil) }
        }
    }
}

private struct PromptView: View {
    let title: String
    let label: String?
    let placeholder: String
    let confirmLabel: String
    let validate: ((String) -> String?)?
    let done: (String?) -> Void
    @StateObject private var text: Local<String>
    @StateObject private var error = Local("")
    @FocusState private var focused: Bool

    init(title: String, label: String?, initial: String, placeholder: String, confirmLabel: String,
         validate: ((String) -> String?)?, done: @escaping (String?) -> Void) {
        self.title = title; self.label = label; self.placeholder = placeholder
        self.confirmLabel = confirmLabel; self.validate = validate; self.done = done
        _text = StateObject(wrappedValue: Local(initial))
    }

    private func submit() {
        let v = text.value.trimmed
        if let validate, let msg = validate(v) { error.value = msg; return }
        done(v)
    }

    var body: some View {
        DialogScaffold(title: title) {
            VStack(alignment: .leading, spacing: 5) {
                if let label { Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.shared.p.textDim) }
                TextField(placeholder, text: $text.value)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                if !error.value.isEmpty { MiscHint(text: error.value, color: Theme.shared.p.red) }
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(confirmLabel, action: submit).buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .onAppear { after(0.05) { focused = true } }
    }
}

private struct IconPickView: View {
    let title: String
    let subtitle: String
    let done: (String?) -> Void
    @StateObject private var value: Local<String>

    init(title: String, subtitle: String, initial: String, done: @escaping (String?) -> Void) {
        self.title = title; self.subtitle = subtitle; self.done = done
        _value = StateObject(wrappedValue: Local(initial))
    }

    var body: some View {
        DialogScaffold(title: title, subtitle: subtitle.isEmpty ? nil : subtitle) {
            VStack(alignment: .leading, spacing: 8) {
                EmojiPicker(selection: $value.value)
                MiscHint(text: "It shows beside the name in the host list, and anywhere else that names this host.")
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") { done(value.value.trimmed) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
