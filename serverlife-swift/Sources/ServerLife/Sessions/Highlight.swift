import Foundation
import SwiftUI

/// Keyword highlighting in the terminal — the port of highlight.js.
///
/// Reading a log in a terminal is mostly looking for four or five words. This
/// colours them as the output arrives, so `error` is visible without searching
/// for it. It rewrites the byte stream on its way to the terminal, wrapping
/// matches in SGR sequences and restoring whatever colour the program had set.
enum Highlight {
    struct ColorChoice { let value: String; let label: String; let fg: String; let bg: String; let css: String }

    static let colors: [ColorChoice] = [
        ColorChoice(value: "red", label: "Red", fg: "1;31", bg: "1;97;41", css: "#f85149"),
        ColorChoice(value: "amber", label: "Amber", fg: "1;33", bg: "1;30;43", css: "#d29922"),
        ColorChoice(value: "green", label: "Green", fg: "1;32", bg: "1;30;42", css: "#3fb950"),
        ColorChoice(value: "blue", label: "Blue", fg: "1;34", bg: "1;97;44", css: "#4c8dff"),
        ColorChoice(value: "cyan", label: "Cyan", fg: "1;36", bg: "1;30;46", css: "#39c5cf"),
        ColorChoice(value: "magenta", label: "Magenta", fg: "1;35", bg: "1;97;45", css: "#bc8cff"),
        ColorChoice(value: "grey", label: "Grey", fg: "1;90", bg: "1;97;100", css: "#8b949e"),
    ]

    static func color(_ value: String?) -> ColorChoice { colors.first { $0.value == value } ?? colors[0] }

    /// One rule, as stored in settings (`highlightRules`, a host's `extra`).
    struct Rule: Equatable, Identifiable {
        var id: String
        var name: String = ""
        var pattern: String = ""
        var regex = false
        var caseSensitive = false
        var color = "amber"
        var background = true
        var enabled = true
        var builtin = false

        init(id: String, name: String = "", pattern: String = "", regex: Bool = false, caseSensitive: Bool = false,
             color: String = "amber", background: Bool = true, enabled: Bool = true, builtin: Bool = false) {
            self.id = id; self.name = name; self.pattern = pattern; self.regex = regex
            self.caseSensitive = caseSensitive; self.color = color; self.background = background
            self.enabled = enabled; self.builtin = builtin
        }

        init(json j: JSON) {
            id = j["id"].string ?? uid("hl")
            name = j["name"].string ?? ""
            pattern = j["pattern"].stringish ?? ""
            regex = j["regex"].truthy
            caseSensitive = j["caseSensitive"].truthy
            color = j["color"].string ?? "red"
            background = j["background"].bool != false
            enabled = j["enabled"].bool != false
            builtin = j["builtin"].truthy
        }

        var json: JSON {
            ["id": .string(id), "name": .string(name), "pattern": .string(pattern), "regex": .bool(regex),
             "caseSensitive": .bool(caseSensitive), "color": .string(color), "background": .bool(background),
             "enabled": .bool(enabled), "builtin": .bool(builtin)]
        }

        var sgr: String { background ? Highlight.color(color).bg : Highlight.color(color).fg }
    }

    /// What ships on: kept as data here so they can improve between releases.
    static let defaultRules: [Rule] = [
        Rule(id: "builtin-error", name: "Errors",
             pattern: #"\b(error|errors|errno|fatal|critical|panic|traceback|denied|refused|failed|failure|cannot|unable to)\b"#,
             regex: true, color: "red", background: true, builtin: true),
        Rule(id: "builtin-warn", name: "Warnings",
             pattern: #"\b(warn|warning|warnings|deprecated|timeout|timed out|retrying|retry|degraded|throttled)\b"#,
             regex: true, color: "amber", background: true, builtin: true),
        Rule(id: "builtin-ok", name: "Good news",
             pattern: #"\b(success|successful|succeeded|active \(running\)|healthy|ready|completed|enabled)\b"#,
             regex: true, color: "green", background: false, builtin: true),
    ]

    // MARK: Settings

    @MainActor static var ownRules: [Rule] { Store.shared.settingJSON("highlightRules").items.map(Rule.init(json:)) }
    @MainActor static var hiddenRules: [String] { Store.shared.settingJSON("hiddenHighlightRules").stringArray }

    /// The user's own rules, plus whichever built-ins they have not overridden.
    @MainActor static func allRules() -> [Rule] {
        let own = ownRules
        let overridden = Set(own.map(\.id))
        let hidden = Set(hiddenRules)
        return defaultRules.filter { !overridden.contains($0.id) && !hidden.contains($0.id) } + own
    }

    @MainActor static func hostEntry(_ key: String) -> JSON {
        Store.shared.settingJSON("highlightHosts")[key]
    }

    /// Is highlighting on for this host? Its own answer, else the global one.
    @MainActor static func isOn(_ hostKey: String?) -> Bool {
        if let hostKey, let on = hostEntry(hostKey)["on"].bool { return on }
        return Store.shared.settingJSON("highlight").bool != false
    }

    @MainActor static func source(_ hostKey: String?) -> String {
        if let hostKey, hostEntry(hostKey)["on"].bool != nil { return "host" }
        return "default"
    }

    @MainActor static func setForHost(_ hostKey: String, _ value: Bool?) {
        Store.shared.mutateSetting("highlightHosts") { map in
            var entry = map[hostKey]
            if entry.object == nil { entry = .object([:]) }
            if let value { entry["on"] = .bool(value) } else { entry.removeKey("on") }
            if entry.entries.isEmpty { map.removeKey(hostKey) } else { map[hostKey] = entry }
            if map.object == nil { map = .object([:]) }
        }
    }

    @MainActor static func setDefault(_ on: Bool) { Store.shared.setSetting("highlight", on) }

    /// The rules in force for a host: the shared set, plus anything set for it.
    @MainActor static func rulesFor(_ hostKey: String?) -> [Rule] {
        let entry = hostKey.map(hostEntry) ?? .null
        let off = Set(entry["off"].stringArray)
        let shared = allRules().filter { $0.enabled && !off.contains($0.id) }
        let extra = entry["extra"].items.map(Rule.init(json:)).filter { $0.enabled }
        return shared + extra
    }

    @MainActor static func saveRules(_ rules: [Rule]) {
        Store.shared.setSettingJSON("highlightRules", .array(rules.map(\.json)))
    }

    // MARK: The rewriter

    struct Compiled { let re: NSRegularExpression; let sgr: String; let id: String }

    /// Compile rules once per pane. A bad pattern is dropped rather than thrown.
    static func compile(_ rules: [Rule]) -> [Compiled]? {
        var out: [Compiled] = []
        for r in rules {
            let body = r.regex ? r.pattern : NSRegularExpression.escapedPattern(for: r.pattern)
            if body.isEmpty { continue }
            if let re = try? NSRegularExpression(pattern: body, options: r.caseSensitive ? [] : [.caseInsensitive]) {
                out.append(Compiled(re: re, sgr: r.sgr, id: r.id))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Per-pane rewriter state: what colour is in force, and which screen.
    struct State { var sgr = ""; var alt = false }

    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]|\u{1b}\\][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)|\u{1b}[@-Z\\\\-_]")
    private static let sgrRe = try! NSRegularExpression(pattern: "^\u{1b}\\[([0-9;]*)m$")
    private static let altOn = try! NSRegularExpression(pattern: "^\u{1b}\\[\\?(?:1049|47|1047)h$")
    private static let altOff = try! NSRegularExpression(pattern: "^\u{1b}\\[\\?(?:1049|47|1047)l$")

    private static func test(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Wrap every match in `chunk` with its rule's colour. No buffering across
    /// chunks; stands aside entirely while the program is on the alternate
    /// screen (vim, less, htop).
    static func chunk(_ chunk: String, _ compiled: [Compiled]?, _ hs: inout State) -> String {
        guard let compiled, !chunk.isEmpty else { return chunk }
        let ns = chunk as NSString
        var out = ""
        var last = 0
        func emitText(_ t: String) { out += hs.alt ? t : paint(t, compiled, hs) }
        for m in ansi.matches(in: chunk, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                emitText(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            let esc = ns.substring(with: m.range)
            out += esc
            if test(altOn, esc) != nil { hs.alt = true }
            else if test(altOff, esc) != nil { hs.alt = false }
            else if let s = test(sgrRe, esc) {
                let body = (esc as NSString).substring(with: s.range(at: 1))
                hs.sgr = (body.isEmpty || body == "0") ? "" : esc
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { emitText(ns.substring(from: last)) }
        return out
    }

    /// One text run: matches for every rule, earlier rules win an overlap, each
    /// wrapped in its colour and followed by a restore of the program's colour.
    static func paint(_ text: String, _ compiled: [Compiled], _ hs: State) -> String {
        let ns = text as NSString
        var hits: [(start: Int, end: Int, sgr: String)] = []
        outer: for c in compiled {
            for m in c.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                hits.append((m.range.location, m.range.location + m.range.length, c.sgr))
                if hits.count > 400 { break outer }
            }
        }
        if hits.isEmpty { return text }
        hits.sort { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var out = ""
        var at = 0
        for h in hits {
            if h.start < at { continue }
            out += ns.substring(with: NSRange(location: at, length: h.start - at))
            out += "\u{1b}[\(h.sgr)m" + ns.substring(with: NSRange(location: h.start, length: h.end - h.start)) + "\u{1b}[0m" + hs.sgr
            at = h.end
        }
        return out + ns.substring(from: at)
    }
}

// MARK: - The editor

@MainActor
enum HighlightEditor {
    /// Re-read the rules into every open pane. Only new output is recoloured.
    static func refreshAll() {
        for w in WindowManager.shared.windows {
            for p in w.feature(SessionsWindow.self).panes.values { p.applyHighlightSettings() }
        }
        StatusBus.shared.show("Highlighting updated — it applies to new output")
    }

    /// The list of highlights, for everything or for one host.
    static func open(_ window: WindowModel? = nil, hostKey: String? = nil, hostLabel: String = "") {
        Modal.sheet(window, title: "Keyword highlighting", width: 680, height: 520, resizable: true,
                    autosave: "highlights") { handle in
            HighlightListView(hostKey: hostKey, hostLabel: hostLabel, window: window) { handle.close() }
        }
    }

    /// Edit one rule (nil = a new one). A built-in is copied into settings the
    /// moment it is changed.
    static func edit(_ rule: Highlight.Rule?, hostKey: String?, window: WindowModel?,
                     done: @escaping (Highlight.Rule?) -> Void) {
        Modal.sheet(window, title: rule == nil ? "New highlight" : "Edit highlight", width: 480) { handle in
            HighlightRuleEditor(rule: rule, hostKey: hostKey) { r in
                handle.close()
                done(r)
            }
        }
    }
}

private struct HighlightListView: View {
    let hostKey: String?
    let hostLabel: String
    let window: WindowModel?
    let close: () -> Void
    @StateObject private var tick = Local(0)

    var body: some View {
        let p = Theme.shared.p
        let _ = tick.value
        let store = Store.shared
        DialogScaffold(title: "Keyword highlighting", subtitle: hostKey != nil ? hostLabel : "Applies to every session") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Highlight keywords in every session", isOn: Binding(
                    get: { store.settingJSON("highlight").bool != false },
                    set: { Highlight.setDefault($0); HighlightEditor.refreshAll(); tick.value += 1 }))
                    .toggleStyle(.checkbox)
                if let hostKey {
                    FormRow(label: "For \(hostLabel)") {
                        Picker("", selection: Binding(
                            get: { Highlight.source(hostKey) == "host" ? (Highlight.isOn(hostKey) ? "on" : "off") : "default" },
                            set: { v in
                                Highlight.setForHost(hostKey, v == "default" ? nil : v == "on")
                                HighlightEditor.refreshAll(); tick.value += 1
                            })) {
                            Text("Follow the global setting (\(store.settingJSON("highlight").bool != false ? "on" : "off"))").tag("default")
                            Text("Always on for this host").tag("on")
                            Text("Always off for this host").tag("off")
                        }
                        .labelsHidden().frame(maxWidth: 320)
                    }
                }
                Color.clear.frame(height: 4)
                VStack(spacing: 0) {
                    let entry = hostKey.map(Highlight.hostEntry) ?? .null
                    let off = Set(entry["off"].stringArray)
                    ForEach(Highlight.allRules()) { r in ruleRow(r, on: r.enabled && !off.contains(r.id), p: p) }
                    if let hostKey {
                        ForEach(entry["extra"].items.map(Highlight.Rule.init(json:))) { r in
                            HStack(spacing: 8) {
                                Badge(text: "this host")
                                Text(r.pattern).font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("×") {
                                    Store.shared.mutateSetting("highlightHosts") { map in
                                        var e = map[hostKey]
                                        e["extra"] = .array(e["extra"].items.filter { $0["id"].string != r.id })
                                        map[hostKey] = e
                                    }
                                    HighlightEditor.refreshAll(); tick.value += 1
                                }.buttonStyle(.icon)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                        }
                    }
                    if Highlight.allRules().isEmpty {
                        Text("Nothing is highlighted yet.").font(.system(size: 12)).foregroundStyle(p.muted).padding(10)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.borderSoft))
                Text("Highlighting stands aside while a full-screen program is running — vim, less, htop — so it never recolours something drawing its own screen.")
                    .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Add a highlight…") {
                        HighlightEditor.edit(nil, hostKey: nil, window: window) { added in
                            guard let added else { return }
                            Highlight.saveRules(Highlight.ownRules + [added])
                            HighlightEditor.refreshAll(); tick.value += 1
                        }
                    }.buttonStyle(GhostButtonStyle(small: true, prominent: true))
                    if let hostKey {
                        Button("Add for this host only…") {
                            HighlightEditor.edit(nil, hostKey: hostKey, window: window) { added in
                                guard let added else { return }
                                Store.shared.mutateSetting("highlightHosts") { map in
                                    var e = map[hostKey]
                                    if e.object == nil { e = .object([:]) }
                                    e["extra"] = .array(e["extra"].items + [added.json])
                                    map[hostKey] = e
                                }
                                HighlightEditor.refreshAll(); tick.value += 1
                            }
                        }.buttonStyle(.ghostSmall)
                    }
                    if !Highlight.hiddenRules.isEmpty {
                        Button("Restore built-ins") {
                            Store.shared.setSettingJSON("hiddenHighlightRules", .array([]))
                            HighlightEditor.refreshAll(); tick.value += 1
                        }.buttonStyle(.ghostSmall)
                    }
                }
            }
        } footer: {
            Button("Close") { close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func ruleRow(_ r: Highlight.Rule, on: Bool, p: Palette) -> some View {
        let c = Highlight.color(r.color)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { on }, set: { v in setEnabled(r, v) })).toggleStyle(.checkbox).labelsHidden()
            Text(r.pattern)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(r.background ? Color(hex: "#0d1117") : Color(hex: c.css))
                .padding(.horizontal, r.background ? 3 : 0)
                .background(RoundedRectangle(cornerRadius: 2).fill(r.background ? Color(hex: c.css) : .clear))
                .frame(maxWidth: 210, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(r.name).font(.system(size: 12)).opacity(0.8).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if r.regex { Badge(text: "regex") }
            if r.builtin { Badge(text: "built in") }
            Button("Edit") {
                HighlightEditor.edit(r, hostKey: nil, window: window) { edited in
                    guard let edited else { return }
                    var own = Highlight.ownRules
                    if let i = own.firstIndex(where: { $0.id == edited.id }) { own[i] = edited } else { own.append(edited) }
                    Highlight.saveRules(own)
                    HighlightEditor.refreshAll(); tick.value += 1
                }
            }.buttonStyle(.ghostSmall)
            Button("×") {
                if r.builtin {
                    var hidden = Highlight.hiddenRules
                    if !hidden.contains(r.id) { hidden.append(r.id) }
                    Store.shared.setSettingJSON("hiddenHighlightRules", JSON(hidden))
                } else {
                    Highlight.saveRules(Highlight.ownRules.filter { $0.id != r.id })
                }
                HighlightEditor.refreshAll(); tick.value += 1
            }
            .buttonStyle(.icon)
            .help(r.builtin ? "Hide this built-in highlight" : "Delete this highlight")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func setEnabled(_ r: Highlight.Rule, _ v: Bool) {
        if let hostKey {
            // Off *here*, without touching what every other host does.
            Store.shared.mutateSetting("highlightHosts") { map in
                var e = map[hostKey]
                if e.object == nil { e = .object([:]) }
                var list = e["off"].stringArray
                if v { list.removeAll { $0 == r.id } } else if !list.contains(r.id) { list.append(r.id) }
                e["off"] = JSON(list)
                map[hostKey] = e
            }
        } else {
            var own = Highlight.ownRules
            if let i = own.firstIndex(where: { $0.id == r.id }) { own[i].enabled = v }
            else { var c = r; c.builtin = false; c.enabled = v; own.append(c) }
            Highlight.saveRules(own)
        }
        HighlightEditor.refreshAll()
        tick.value += 1
    }
}

private struct HighlightRuleEditor: View {
    let rule: Highlight.Rule?
    let hostKey: String?
    let done: (Highlight.Rule?) -> Void
    @StateObject private var name: Local<String>
    @StateObject private var pattern: Local<String>
    @StateObject private var regex: LocalFlag
    @StateObject private var cs: LocalFlag
    @StateObject private var color: Local<String>
    @StateObject private var bg: LocalFlag

    init(rule: Highlight.Rule?, hostKey: String?, done: @escaping (Highlight.Rule?) -> Void) {
        self.rule = rule; self.hostKey = hostKey; self.done = done
        _name = StateObject(wrappedValue: Local(rule?.name ?? ""))
        _pattern = StateObject(wrappedValue: Local(rule?.pattern ?? ""))
        _regex = StateObject(wrappedValue: LocalFlag(rule?.regex ?? false))
        _cs = StateObject(wrappedValue: LocalFlag(rule?.caseSensitive ?? false))
        _color = StateObject(wrappedValue: Local(rule?.color ?? "amber"))
        _bg = StateObject(wrappedValue: LocalFlag(rule?.background ?? true))
    }

    var body: some View {
        let p = Theme.shared.p
        let css = Highlight.color(color.value).css
        DialogScaffold(title: rule == nil ? "New highlight" : "Edit highlight",
                       subtitle: hostKey != nil ? "For this host only" : "For every session", width: 480) {
            VStack(alignment: .leading, spacing: 10) {
                labelled("Name (optional)") { TextField("Disk pressure", text: $name.value).textFieldStyle(.roundedBorder) }
                labelled("Text to highlight", hint: "Plain text unless you tick the box below") {
                    TextField("no space left", text: $pattern.value).textFieldStyle(.roundedBorder)
                }
                Toggle("It is a regular expression", isOn: $regex.on).toggleStyle(.checkbox)
                Toggle("Match case", isOn: $cs.on).toggleStyle(.checkbox)
                labelled("Colour") {
                    Picker("", selection: $color.value) {
                        ForEach(Highlight.colors, id: \.value) { Text($0.label).tag($0.value) }
                    }.labelsHidden().frame(maxWidth: 200)
                }
                Toggle("Fill the background (rather than colour the text)", isOn: $bg.on).toggleStyle(.checkbox)
                Text("Preview").font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 6)
                HStack(spacing: 0) {
                    Text("nginx: ")
                    Text(pattern.value.trimmed.isEmpty ? "keyword" : pattern.value.trimmed)
                        .fontWeight(.semibold)
                        .foregroundStyle(bg.on ? Color(hex: "#0d1117") : Color(hex: css))
                        .padding(.horizontal, bg.on ? 2 : 0)
                        .background(RoundedRectangle(cornerRadius: 2).fill(bg.on ? Color(hex: css) : .clear))
                    Text(" while reading upstream")
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(hex: "#c9d1d9"))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: "#11151c")))
            }
            .font(.system(size: 12))
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(rule == nil ? "Add" : "Save") { save() }.buttonStyle(.primary)
        }
    }

    private func labelled<C: View>(_ label: String, hint: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.shared.p.textDim)
            c()
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Theme.shared.p.muted) }
        }
    }

    private func save() {
        let pat = pattern.value.trimmed
        if pat.isEmpty { StatusBus.shared.toast("Give it some text to look for", kind: .error); return }
        if regex.on {
            do { _ = try NSRegularExpression(pattern: pat) } catch {
                StatusBus.shared.toast("That regular expression will not compile: \(error.localizedDescription)", kind: .error)
                return
            }
        }
        var r = rule ?? Highlight.Rule(id: uid("hl"))
        r.builtin = false
        r.name = name.value.trimmed
        r.pattern = pat
        r.regex = regex.on
        r.caseSensitive = cs.on
        r.color = color.value
        r.background = bg.on
        r.enabled = rule?.enabled ?? true
        done(r)
    }
}
