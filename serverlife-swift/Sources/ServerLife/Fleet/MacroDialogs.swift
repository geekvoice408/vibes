import AppKit
import SwiftUI

/// The macro dialogs of macros.js: filling in blanks, choosing a button's icon
/// and scope, a repeat interval, and the editor.
@MainActor
enum MacroDialogs {
    /**
     * Icons to choose from, with what each one is for. A pinned macro is a
     * button you hit without reading, so the icon is the whole label — which
     * only works if the choice is quick.
     */
    static let icons: [(glyph: String, label: String)] = [
        ("\u{25B6}", "run"), ("\u{23F1}", "timing"), ("\u{1F504}", "restart"),
        ("\u{1F4CA}", "stats"), ("\u{1F4C8}", "load"), ("\u{1F4BE}", "disk"),
        ("\u{1F4DC}", "logs"), ("\u{1F50D}", "inspect"), ("\u{1F9F9}", "clean up"),
        ("\u{1F6A6}", "status"), ("\u{1F525}", "errors"), ("\u{1F514}", "alerts"),
        ("\u{1F680}", "deploy"), ("\u{2699}", "config"), ("\u{1F310}", "network"),
        ("\u{1F512}", "security"), ("\u{1F464}", "who"), ("\u{1F4E6}", "packages"),
        ("\u{1F433}", "containers"), ("\u{26A1}", "quick check"), ("\u{2764}", "health"),
        ("\u{1F6D1}", "stop"), ("\u{267B}", "reload"), ("\u{1F4CB}", "report"),
    ]

    // MARK: Variables

    /// Ask for the values. nil if the dialog was dismissed.
    static func askVars(_ m: Macro, _ vars: [MacroVar], window: WindowModel?) async -> [String: String]? {
        await FleetDialog.ask(window, title: m.name, width: 520) { done in
            VarsForm(macro: m, vars: vars, done: done)
        }
    }

    private struct VarsForm: View {
        let macro: Macro
        let vars: [MacroVar]
        let done: ([String: String]?) -> Void
        @StateObject private var values: Local<[String: String]>

        init(macro: Macro, vars: [MacroVar], done: @escaping ([String: String]?) -> Void) {
            self.macro = macro; self.vars = vars; self.done = done
            var v: [String: String] = [:]
            for x in vars { v[x.name] = x.defaultValue.isEmpty ? (x.choices?.first ?? "") : x.defaultValue }
            for x in vars where x.choices == nil { v[x.name] = x.defaultValue }
            _values = StateObject(wrappedValue: Local(v))
        }

        private func trimmed() -> [String: String] { values.value.mapValues { $0.trimmed } }

        var body: some View {
            let p = Theme.shared.p
            DialogScaffold(title: macro.name,
                           subtitle: vars.count == 1 ? "One value to fill in" : "\(vars.count) values to fill in") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(vars, id: \.name) { v in
                        MiscField(label: v.name, hint: (v.choices?.isEmpty == false) ? "Pick one, or edit the macro to change the list" : nil) {
                            let b = Binding(get: { values.value[v.name] ?? "" }, set: { values.value[v.name] = $0 })
                            if let c = v.choices, !c.isEmpty {
                                FleetPicker(options: c.map { ($0, $0) }, selection: b)
                            } else {
                                FleetField(placeholder: "value for " + v.name, text: b)
                            }
                        }
                    }
                    Text("Command").font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 10)
                    Text(Macros.expand(macro.command, trimmed()))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(p.textDim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                        .padding(.top, 4)
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Run") {
                    let v = trimmed()
                    let missing = vars.filter { (v[$0.name] ?? "").isEmpty }.map(\.name)
                    if !missing.isEmpty {
                        StatusBus.shared.toast("Still needed: \(missing.joined(separator: ", "))", kind: .error)
                        return
                    }
                    done(v)
                }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Pinning

    /**
     * Pick an icon for a macro about to be pinned (and where its button shows).
     * Offered rather than assumed: two buttons with the same glyph are worse
     * than no buttons.
     */
    static func pinOptions(icon: String = "", where w: String = "hosts", name: String = "", iconOnly: Bool = false,
                           window: WindowModel?) async -> (icon: String, where: String)? {
        await FleetDialog.ask(window, title: iconOnly ? "Button icon" : "Button on the session header", width: 520) { done in
            PinForm(initialIcon: icon, initialWhere: w.nilIfEmpty ?? "hosts", name: name, iconOnly: iconOnly, done: done)
        }
    }

    private struct PinForm: View {
        let name: String
        let iconOnly: Bool
        let done: ((icon: String, where: String)?) -> Void
        @StateObject private var picked: Local<String>
        @StateObject private var scope: Local<String>

        init(initialIcon: String, initialWhere: String, name: String, iconOnly: Bool,
             done: @escaping ((icon: String, where: String)?) -> Void) {
            self.name = name; self.iconOnly = iconOnly; self.done = done
            _picked = StateObject(wrappedValue: Local(initialIcon))
            _scope = StateObject(wrappedValue: Local(initialWhere))
        }

        var body: some View {
            let p = Theme.shared.p
            DialogScaffold(title: iconOnly ? "Button icon" : "Button on the session header", subtitle: name.nilIfEmpty) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Icon").font(.system(size: 11)).foregroundStyle(p.muted).padding(.bottom, 5)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 5), count: 12), spacing: 5) {
                        ForEach(MacroDialogs.icons, id: \.glyph) { ic in
                            // Choosing an icon does not close the dialog: there is
                            // a second decision below it.
                            Button { picked.value = ic.glyph } label: {
                                Text(ic.glyph).font(.system(size: 16)).frame(width: 34, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(picked.value == ic.glyph ? p.accentDim : p.panel2))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(picked.value == ic.glyph ? p.accent : p.border))
                            }
                            .buttonStyle(.plain)
                            .help(ic.label)
                        }
                    }
                    .padding(.bottom, 12)
                    MiscField(label: "Or type one", hint: "Any character or emoji. It is the whole button, so one is plenty.") {
                        TextField("\u{25B6}", text: Binding(get: { picked.value }, set: { v in
                            picked.value = String(v.trimmed.prefix(4))
                        }))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 15))
                        .frame(width: 70)
                    }
                    // The editor carries its own scope control, so this dialog is
                    // then only about the icon.
                    if !iconOnly {
                        MiscField(label: "Show it on",
                                  hint: "A macro that reads a server\u{2019}s journal has no business on a local prompt, "
                                      + "and one that opens a local tool has none on a server.") {
                            FleetPicker(options: Macros.pinScopes, selection: $scope.value)
                        }
                    }
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Use this") { done((picked.value.trimmed.nilIfEmpty ?? "\u{25B6}", scope.value)) }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Repeating

    /// Ask for an interval, then start one.
    static func promptRepeat(_ m: Macro, paneId: String?, window: WindowModel?) async {
        let secs: Int? = await FleetDialog.ask(window, title: "Repeat \u{201C}\(m.name)\u{201D}", width: 440) { done in
            RepeatForm(macro: m, done: done)
        }
        guard let secs else { return }
        await Macros.shared.startRepeat(m, seconds: secs, paneId: paneId, window: window)
    }

    private struct RepeatForm: View {
        let macro: Macro
        let done: (Int?) -> Void
        @StateObject private var amount: Local<String>
        @StateObject private var unit: Local<String>
        init(macro: Macro, done: @escaping (Int?) -> Void) {
            self.macro = macro; self.done = done
            let r = macro.repeatSeconds
            let minutes = r > 0 && r % 60 == 0
            _amount = StateObject(wrappedValue: Local(String(minutes ? r / 60 : (r > 0 ? r : 30))))
            _unit = StateObject(wrappedValue: Local(minutes ? "minutes" : "seconds"))
        }
        var body: some View {
            DialogScaffold(title: "Repeat \u{201C}\(macro.name)\u{201D}") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("It is typed into this pane on every tick, so pick something slower than the command takes.")
                        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    MiscField(label: "Run it every") {
                        HStack(spacing: 8) {
                            FleetField(placeholder: "", text: $amount.value).frame(width: 90)
                            FleetPicker(options: [("seconds", "seconds"), ("minutes", "minutes")], selection: $unit.value).frame(width: 120)
                        }
                    }
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Start") {
                    let n = Double(amount.value.trimmed) ?? 0
                    if !(n >= 1) { StatusBus.shared.toast("Give an interval", kind: .error); return }
                    done(Int((unit.value == "minutes" ? n * 60 : n).rounded()))
                }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Editor

    /// The button scope, narrowed to what the run scope allows.
    nonisolated static func clampPin(_ pin: String, run: String) -> String {
        run == "all" || pin == run ? pin : run
    }

    /// What the editor gives back: the macro to save, and its button.
    struct Edited {
        var macro: JSON
        var pin: (icon: String, where: String)?
    }

    /// The macro editor. Saves, pins (after the save, because a new macro has
    /// no id to pin until it exists) and returns the saved record.
    @discardableResult
    static func edit(_ initial: Macro?, window: WindowModel?) async -> JSON? {
        let res: Edited? = await FleetDialog.ask(window, title: "Macro", width: 640, height: 640, resizable: true,
                                                 autosave: "macro-editor") { done in
            EditorForm(initial: initial, window: window, done: done)
        }
        guard let res else { return nil }
        let saved = FleetStore.upsertMacro(res.macro)
        if let id = saved["id"].string {
            if let pin = res.pin {
                Macros.shared.setPinned(id, pinned: true, icon: pin.icon, where: pin.where)
            } else if let iid = initial?.id, !iid.isEmpty, !Macros.shared.pinnedIconFor(iid).isEmpty {
                Macros.shared.setPinned(id, pinned: false)
            }
        }
        Macros.headersChanged()
        return saved
    }

    /// A new macro with some fields filled in (from a pane's ▶ menu, history…).
    static func newMacro(command: String = "", name: String = "", category: String = "Custom", where w: String? = nil) -> Macro {
        var m = Macro(id: "", category: category, name: name, description: "", command: command)
        m.whereScope = w
        return m
    }

    private struct EditorForm: View {
        let initial: Macro?
        let window: WindowModel?
        let done: (Edited?) -> Void
        @StateObject private var name: Local<String>
        @StateObject private var desc: Local<String>
        @StateObject private var cat: Local<String>
        @StateObject private var cmd: Local<String>
        @StateObject private var confirm: LocalFlag
        @StateObject private var interactive: LocalFlag
        @StateObject private var noEnter: LocalFlag
        @StateObject private var runWhere: Local<String>
        @StateObject private var pinOn: LocalFlag
        @StateObject private var pinIcon: Local<String>
        @StateObject private var pinWhere: Local<String>
        @StateObject private var every: Local<String>
        @StateObject private var everyUnit: Local<String>
        @StateObject private var vars: Local<String>

        init(initial: Macro?, window: WindowModel?, done: @escaping (Edited?) -> Void) {
            self.initial = initial; self.window = window; self.done = done
            let m = initial
            _name = StateObject(wrappedValue: Local(m?.name ?? ""))
            _desc = StateObject(wrappedValue: Local(m?.description ?? ""))
            _cat = StateObject(wrappedValue: Local(m?.category.nilIfEmpty ?? "Custom"))
            _cmd = StateObject(wrappedValue: Local(m?.command ?? ""))
            _confirm = StateObject(wrappedValue: LocalFlag(m?.confirm ?? false))
            _interactive = StateObject(wrappedValue: LocalFlag(m?.interactive ?? false))
            _noEnter = StateObject(wrappedValue: LocalFlag(m?.noEnter ?? false))
            _runWhere = StateObject(wrappedValue: Local(Macros.runScopeOf(m?.whereScope)))
            let id = (m?.id).flatMap { $0.isEmpty ? nil : $0 }
            let icon = id.map { Macros.shared.pinnedIconFor($0) } ?? ""
            _pinOn = StateObject(wrappedValue: LocalFlag(!icon.isEmpty))
            _pinIcon = StateObject(wrappedValue: Local(icon))
            // A stored button scope the run scope rules out is corrected on open.
            let run = Macros.runScopeOf(m?.whereScope)
            let stored = id.map { Macros.shared.pinnedScopeFor($0) }?.nilIfEmpty ?? "hosts"
            _pinWhere = StateObject(wrappedValue: Local(MacroDialogs.clampPin(stored, run: run)))
            let r = m?.repeatSeconds ?? 0
            _every = StateObject(wrappedValue: Local(r > 0 ? String(r % 60 == 0 ? r / 60 : r) : ""))
            _everyUnit = StateObject(wrappedValue: Local(r > 0 && r % 60 == 0 ? "minutes" : "seconds"))
            _vars = StateObject(wrappedValue: Local(m?.variableSpec.nilIfEmpty ?? Macros.renderVarSpec(m?.variables)))
        }

        private var categories: [String] {
            var out: [String] = []
            for c in Macros.builtins.map(\.category) + ["Custom"] where !out.contains(c) { out.append(c) }
            return out
        }

        /// The pin scopes the run scope allows: a button cannot be shown where
        /// the macro would not run.
        private var impossibleScopes: Set<String> {
            let run = runWhere.value
            return run == "all" ? [] : Set(Macros.pinScopes.map(\.value).filter { $0 != run })
        }

        private func syncPin() {
            if impossibleScopes.contains(pinWhere.value) { pinWhere.value = runWhere.value }
        }

        private var varsNote: String {
            let declared = Macros.parseVarSpec(vars.value)
            let used = Macros.varsOf(command: cmd.value, variables: declared, variableSpec: "")
            let undeclared = used.filter { u in !declared.contains { $0.name == u.name } }.map(\.name)
            let unused = declared.filter { d in !used.contains { $0.name == d.name } }.map(\.name)
            var parts: [String] = []
            if used.isEmpty { parts.append("No {{blanks}} in the command yet.") }
            else {
                let asked = used.filter { $0.defaultValue.isEmpty }.map(\.name).joined(separator: ", ")
                parts.append("Will ask for: \(asked.isEmpty ? "nothing \u{2014} every blank has a default" : asked)")
            }
            if !undeclared.isEmpty { parts.append("Used but not declared (no default, so always asked): \(undeclared.joined(separator: ", "))") }
            if !unused.isEmpty { parts.append("Declared but not used: \(unused.joined(separator: ", "))") }
            return parts.joined(separator: "  \u{00B7}  ")
        }

        var body: some View {
            let p = Theme.shared.p
            let repeatOff = interactive.on || noEnter.on
            DialogScaffold(title: (initial.map { !$0.id.isEmpty && !$0.builtin } ?? false) ? "Edit macro" : "New macro") {
                VStack(alignment: .leading, spacing: 0) {
                    MiscField(label: "Name") { FleetField(placeholder: "Teleport service status", text: $name.value) }
                    MiscField(label: "What it answers") { FleetField(placeholder: "What question does this answer?", text: $desc.value) }
                    MiscField(label: "Category") {
                        HStack(spacing: 6) {
                            FleetField(placeholder: "Teleport, System, Custom\u{2026}", text: $cat.value)
                            Menu {
                                ForEach(categories, id: \.self) { c in Button(c) { cat.value = c } }
                            } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                    MiscField(label: "Command", hint: "Runs through the login shell of wherever it is sent. Write {{name}} for a blank to fill in.") {
                        FleetTextArea(text: $cmd.value, placeholder: "sudo systemctl status teleport --no-pager", minHeight: 96)
                    }
                    MiscField(label: "Where it can run", hint: "Which panes offer it. A server command has no business in the local shell, and vice versa.") {
                        FleetPicker(options: Macros.runScopes, selection: Binding(get: { runWhere.value },
                                                                                  set: { runWhere.value = $0; syncPin() }))
                    }
                    MiscField(label: "Variables",
                              hint: "One per line. `name = value` gives a default; `name = a | b | c` offers a list (mark the "
                                  + "default with *); `name =` has no default and is always asked for.") {
                        FleetTextArea(text: $vars.value, placeholder: "service = teleport\nlevel = info | warn | error\nlines =", minHeight: 56)
                    }
                    MiscHint(text: varsNote).padding(.top, -5).padding(.bottom, 10)
                    MiscCheck(label: "Ask before running \u{2014} this changes something", isOn: $confirm.on)
                    MiscCheck(label: "Does not finish on its own (follows a log)", isOn: $interactive.on)
                    MiscCheck(label: "Paste it without pressing Enter, to finish by hand", isOn: $noEnter.on)
                    MiscCheck(label: "Pin as a button on the session header", isOn: Binding(get: { pinOn.on }, set: { v in
                        pinOn.on = v
                        if v && pinIcon.value.isEmpty { pinIcon.value = "\u{25B6}" }
                        syncPin()
                    }))
                    if pinOn.on {
                        HStack(spacing: 8) {
                            Text("Button:").font(.system(size: 12)).foregroundStyle(p.muted)
                            Button(pinIcon.value.nilIfEmpty ?? "Choose an icon\u{2026}") {
                                Task { @MainActor in
                                    guard let next = await MacroDialogs.pinOptions(icon: pinIcon.value, where: pinWhere.value,
                                                                                   name: name.value.trimmed, iconOnly: true,
                                                                                   window: window) else { return }
                                    pinIcon.value = next.icon
                                    pinOn.on = true
                                    syncPin()
                                }
                            }
                            .buttonStyle(.ghostSmall)
                            .font(.system(size: pinIcon.value.isEmpty ? 11 : 15))
                            Text("shown on").font(.system(size: 12)).foregroundStyle(p.muted)
                            // Only the scopes the run scope allows: a button cannot be
                            // shown where the macro would not run.
                            FleetPicker(options: Macros.pinScopes.filter { !impossibleScopes.contains($0.value) },
                                        selection: $pinWhere.value)
                                .frame(maxWidth: 260)
                        }
                        .padding(.leading, 22).padding(.top, -4).padding(.bottom, 12)
                    }
                    // Repeating only makes sense for a command that ends.
                    MiscField(label: "Repeat automatically",
                              hint: "Leave blank to run once. A repeating macro keeps typing itself into the session until you stop it.") {
                        HStack(spacing: 8) {
                            Text("every").font(.system(size: 12.5)).foregroundStyle(p.muted)
                            FleetField(placeholder: "off", text: $every.value).frame(width: 90)
                            FleetPicker(options: [("seconds", "seconds"), ("minutes", "minutes")], selection: $everyUnit.value)
                                .frame(width: 120)
                        }
                        .disabled(repeatOff)
                    }
                    .opacity(repeatOff ? 0.5 : 1)
                }
            } footer: {
                Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.primary)
            }
        }

        private func save() {
            let command = cmd.value.trimmed
            guard !command.isEmpty else { StatusBus.shared.toast("Give a command", kind: .error); return }
            var o: [String: JSON] = [
                "name": .string(name.value.trimmed.nilIfEmpty ?? FleetStore.firstLine(command)),
                "description": .string(desc.value.trimmed),
                "category": .string(cat.value.trimmed.nilIfEmpty ?? "Custom"),
                "command": .string(command),
                "where": .string(runWhere.value),
                "confirm": .bool(confirm.on),
                "interactive": .bool(interactive.on),
                "noEnter": .bool(noEnter.on),
                "variableSpec": .string(vars.value.trimmed),
                "variables": .array(Macros.parseVarSpec(vars.value).map(\.json)),
                "repeatSeconds": .number(interactive.on || noEnter.on ? 0
                    : max(0, ((Double(every.value.trimmed) ?? 0).rounded()) * (everyUnit.value == "minutes" ? 60 : 1))),
            ]
            if let m = initial, !m.builtin, !m.id.isEmpty { o["id"] = .string(m.id) }
            // The icon *and* where the button shows: two decisions, so this
            // carries both.
            done(Edited(macro: .object(o), pin: pinOn.on ? (pinIcon.value.nilIfEmpty ?? "\u{25B6}",
                                                                          MacroDialogs.clampPin(pinWhere.value.nilIfEmpty ?? "hosts", run: runWhere.value)) : nil))
        }
    }
}
