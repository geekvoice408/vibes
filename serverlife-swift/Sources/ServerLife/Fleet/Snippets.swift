import AppKit
import SwiftUI

/// Saved commands (snippets.js).
///
/// The thing you actually repeat on servers is a command, not a keystroke —
/// a log tail, a service restart, a diagnostic one-liner. These are stored once
/// and sent into whichever terminal is in front of you, or into every pane at
/// once when you are working across a set of machines.
@MainActor
enum Snippets {
    /// ⌘⇧C: the library.
    static func open(_ window: WindowModel?) {
        Modal.sheet(window, title: "Command snippets", width: 760, height: 560, resizable: true, autosave: "snippets") { handle in
            LibraryView(window: window, handle: handle)
        }
    }

    /// The editor. Returns the saved record.
    @discardableResult
    static func edit(_ initial: JSON = [:], window: WindowModel?) async -> JSON? {
        let res: JSON? = await FleetDialog.ask(window, title: "Snippet", width: 520) { done in
            EditorView(initial: initial, done: done)
        }
        guard let res else { return nil }
        let saved = FleetStore.upsertSnippet(res)
        StatusBus.shared.show("Saved snippet \u{201C}\(saved["name"].stringish ?? "")\u{201D}")
        return saved
    }

    /// Send a snippet to the focused pane, or to every remote pane in the tab.
    static func run(_ sn: JSON, all: Bool, window wIn: WindowModel?) {
        let window = wIn ?? WindowManager.shared.focused
        guard let s = window?.feature(SessionsWindow.self) else { return }
        var text = sn["command"].stringish ?? ""
        while text.hasSuffix("\n") { text.removeLast() }
        text += "\n"
        let targets: [SessionPane] = all
            ? s.panesOf(s.activeTabId).compactMap { s.pane($0) }.filter { $0.hasTerm && $0.kind == .remote }
            : [s.activePane].compactMap { $0 }.filter { $0.hasTerm }
        guard !targets.isEmpty else { StatusBus.shared.toast("No terminal to send to", kind: .error); return }
        for p in targets { Macros.sendText(text, to: p, window: window) }
        if let id = sn["id"].string { FleetStore.markSnippetUsed(id) }
        StatusBus.shared.show("Ran \u{201C}\(sn["name"].stringish ?? "")\u{201D} in \(targets.count) pane(s)")
    }

    /// Save whatever is selected in the terminal as a snippet.
    static func fromSelection(_ selection: String?, window: WindowModel?) async {
        guard let sel = selection?.trimmed, !sel.isEmpty else {
            StatusBus.shared.toast("Nothing selected", kind: .error); return
        }
        await edit(["command": .string(sel)], window: window)
    }

    /// Most-used first: the list should converge on what you actually run.
    static func sorted(_ list: [JSON], filter: String) -> [JSON] {
        let f = filter.trimmed.lowercased()
        var out = list
        if !f.isEmpty {
            out = out.filter { s in
                let tags = s["tags"].items.compactMap(\.stringish).joined(separator: " ")
                return "\(s["name"].stringish ?? "") \(s["command"].stringish ?? "") \(tags)".lowercased().contains(f)
            }
        }
        return out.enumerated().sorted { a, b in
            let ua = a.element["useCount"].double ?? 0, ub = b.element["useCount"].double ?? 0
            if ua != ub { return ua > ub }
            let c = (a.element["name"].stringish ?? "").localizedCompare(b.element["name"].stringish ?? "")
            if c != .orderedSame { return c == .orderedAscending }
            return a.offset < b.offset
        }.map(\.element)
    }

    private struct LibraryView: View {
        let window: WindowModel?
        let handle: ModalHandle
        @StateObject private var filter = Local("")

        var body: some View {
            let p = Theme.shared.p
            let list = Snippets.sorted(FleetStore.snippets(), filter: filter.value)
            DialogScaffold(title: "Command snippets", subtitle: "Saved commands, sent into a terminal", scroll: false) {
                VStack(alignment: .leading, spacing: 10) {
                    SearchField(placeholder: "Filter snippets\u{2026}", text: $filter.value)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            if list.isEmpty { FleetEmpty(text: filter.value.trimmed.isEmpty ? "No snippets yet." : "No matches.") }
                            ForEach(list.indices, id: \.self) { i in card(list[i], p) }
                        }
                    }
                }
            } footer: {
                Button("New snippet\u{2026}") { Task { @MainActor in await Snippets.edit([:], window: window) } }.buttonStyle(.ghost)
                Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            }
        }

        @ViewBuilder
        private func card(_ sn: JSON, _ p: Palette) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(sn["name"].stringish ?? "").font(.system(size: 13, weight: .semibold))
                    if let n = sn["useCount"].int, n > 0 { FleetTag(text: "used \(n)\u{00D7}") }
                    ForEach(sn["tags"].items.compactMap(\.stringish), id: \.self) { FleetTag(text: $0) }
                }
                ScrollView {
                    Text(sn["command"].stringish ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                }
                .frame(maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                HStack(spacing: 6) {
                    Button("Run here") { Snippets.run(sn, all: false, window: window) }
                        .buttonStyle(.primary).help("Send to the focused terminal")
                    Button("Run in all panes") { Snippets.run(sn, all: true, window: window) }
                        .buttonStyle(.ghost).help("Send to every remote pane in the current tab")
                    Button("Copy") { Clipboard.write(sn["command"].stringish ?? ""); StatusBus.shared.show("Copied") }
                        .buttonStyle(.ghost)
                    Button("Edit") { Task { @MainActor in await Snippets.edit(sn, window: window) } }.buttonStyle(.ghost)
                    Button("Delete") {
                        Task { @MainActor in
                            let ok = await MiscUI.confirm(window, title: "Delete snippet",
                                                          message: "Delete \u{201C}\(sn["name"].stringish ?? "")\u{201D}?",
                                                          confirmLabel: "Delete", danger: true)
                            if ok, let id = sn["id"].string { FleetStore.deleteSnippet(id) }
                        }
                    }
                    .buttonStyle(GhostButtonStyle(destructive: true))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.borderSoft))
        }
    }

    private struct EditorView: View {
        let initial: JSON
        let done: (JSON?) -> Void
        @StateObject private var name: Local<String>
        @StateObject private var cmd: Local<String>
        @StateObject private var tags: Local<String>

        init(initial: JSON, done: @escaping (JSON?) -> Void) {
            self.initial = initial; self.done = done
            _name = StateObject(wrappedValue: Local(initial["name"].stringish ?? ""))
            _cmd = StateObject(wrappedValue: Local(initial["command"].stringish ?? ""))
            _tags = StateObject(wrappedValue: Local(initial["tags"].items.compactMap(\.stringish).joined(separator: ", ")))
        }

        var body: some View {
            DialogScaffold(title: initial["id"].truthy ? "Edit snippet" : "New snippet") {
                VStack(alignment: .leading, spacing: 0) {
                    MiscField(label: "Name") { FleetField(placeholder: "Tail syslog", text: $name.value) }
                    MiscField(label: "Command", hint: "Sent to the terminal followed by Enter") {
                        FleetTextArea(text: $cmd.value, placeholder: "sudo tail -f /var/log/syslog", minHeight: 150)
                    }
                    MiscField(label: "Tags (optional)") { FleetField(placeholder: "logs, diagnostics", text: $tags.value) }
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard !cmd.value.trimmed.isEmpty else { StatusBus.shared.toast("Enter a command", kind: .error); return }
                    var command = cmd.value
                    while command.hasSuffix("\n") { command.removeLast() }
                    var o: [String: JSON] = [
                        "name": .string(name.value.trimmed.nilIfEmpty ?? FleetStore.firstLine(cmd.value)),
                        "command": .string(command),
                        "tags": JSON(tags.value.components(separatedBy: ",").map { $0.trimmed }.filter { !$0.isEmpty }),
                    ]
                    if let id = initial["id"].string { o["id"] = .string(id) }
                    done(.object(o))
                }
                .buttonStyle(.primary)
            }
        }
    }
}
