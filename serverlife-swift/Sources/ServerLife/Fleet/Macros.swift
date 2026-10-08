import AppKit
import Foundation
import Observation

/// A blank in a macro's command: `{{name}}`, with a default and maybe a list.
struct MacroVar: Equatable {
    var name: String
    var choices: [String]?
    var defaultValue: String

    var json: JSON {
        ["name": .string(name), "choices": choices.map { JSON($0) } ?? .null, "default": .string(defaultValue)]
    }

    init(name: String, choices: [String]? = nil, defaultValue: String = "") {
        self.name = name; self.choices = choices; self.defaultValue = defaultValue
    }

    init?(json j: JSON) {
        guard let n = j["name"].stringish else { return nil }
        name = n
        choices = j["choices"].array.map { $0.compactMap(\.stringish) }
        defaultValue = j["default"].stringish ?? ""
    }
}

/// A macro: a command aimed at a job on a host (macros.js). Built-ins live in
/// code; the user's own are store records.
struct Macro: Identifiable, Equatable {
    var id: String
    var name: String
    var description = ""
    var category = "Custom"
    var command = ""
    /// "all" | "hosts" | "local", or nil for a record saved before scopes.
    var whereScope: String?
    var confirm = false
    var interactive = false
    var noEnter = false
    /// Declared blanks; nil when the record has none (then `variableSpec` is read).
    var variables: [MacroVar]?
    var variableSpec = ""
    var repeatSeconds = 0
    var builtin = false
    var useCount = 0
    var lastUsed: Double?

    init(id: String, category: String, name: String, description: String, command: String,
         interactive: Bool = false, noEnter: Bool = false, confirm: Bool = false, where w: String? = nil) {
        self.id = id; self.category = category; self.name = name; self.description = description
        self.command = command; self.interactive = interactive; self.noEnter = noEnter; self.confirm = confirm
        self.whereScope = w
    }

    init(json j: JSON, builtin: Bool = false) {
        id = j["id"].stringish ?? ""
        name = j["name"].stringish ?? ""
        description = j["description"].stringish ?? ""
        category = j["category"].stringish ?? "Custom"
        command = j["command"].stringish ?? ""
        whereScope = j["where"].string
        confirm = j["confirm"].truthy
        interactive = j["interactive"].truthy
        noEnter = j["noEnter"].truthy
        variables = j["variables"].array.map { $0.compactMap(MacroVar.init(json:)) }
        variableSpec = j["variableSpec"].stringish ?? ""
        repeatSeconds = Int(j["repeatSeconds"].double ?? 0)
        self.builtin = builtin
        useCount = j["useCount"].int ?? 0
        lastUsed = j["lastUsed"].double
    }

    /// What the editor saves (`macros:save`'s argument).
    var json: JSON {
        var o: [String: JSON] = [
            "name": .string(name), "description": .string(description), "category": .string(category),
            "command": .string(command), "confirm": .bool(confirm), "interactive": .bool(interactive),
            "noEnter": .bool(noEnter), "variableSpec": .string(variableSpec),
            "variables": .array((variables ?? []).map(\.json)), "repeatSeconds": .number(Double(repeatSeconds)),
        ]
        if let whereScope { o["where"] = .string(whereScope) }
        if !builtin && !id.isEmpty { o["id"] = .string(id) }
        return .object(o)
    }
}

/// A macro ticking on a pane.
struct MacroRepeat: Identifiable {
    var macro: Macro
    var paneId: String
    var every: Int
    var since: Double
    var runs: Int
    var id: String { Macros.repeatKey(paneId, macro.id) }
}

/// Macros: commands you run *on a host*, rather than text you paste.
///
/// Snippets already send text into a terminal. A macro is the same idea aimed
/// at a specific job — "is the agent running", "what is filling the disk" — so
/// it ships with a starter set, carries a description of what it answers, and
/// can be run without a terminal open by showing its output in a dialog.
///
/// The built-ins live here rather than being seeded into the store, so they
/// improve between releases instead of freezing at whatever shipped first.
@MainActor
@Observable
final class Macros {
    static let shared = Macros()

    // MARK: Built-ins

    static let builtins: [Macro] = {
        var list: [Macro] = [
            /* ---- Teleport ---- */
            Macro(id: "b:tp-status", category: "Teleport", name: "Teleport service status",
                  description: "Is the agent running, and since when.",
                  command: "sudo systemctl status teleport --no-pager || sudo service teleport status"),
            // Never useful headless: it does not end.
            Macro(id: "b:tp-journal", category: "Teleport", name: "Follow Teleport logs",
                  description: "Live agent log. Ctrl-C to stop.", command: "sudo journalctl -fu teleport", interactive: true),
            Macro(id: "b:tp-journal-recent", category: "Teleport", name: "Teleport errors, last hour",
                  description: "Recent agent problems without following the log.",
                  command: "sudo journalctl -u teleport --since \"1 hour ago\" -p warning --no-pager | tail -n 80"),
            Macro(id: "b:tp-version", category: "Teleport", name: "Teleport version",
                  description: "Agent build on this host.", command: "teleport version; tsh version 2>/dev/null | head -1"),
            Macro(id: "b:tp-status-session", category: "Teleport", name: "Teleport session status",
                  description: "Who this host is logged in as: cluster, user, roles and how long the certificate lasts.",
                  command: "tsh status"),
            /*
             * The client commands, which run here rather than on a server.
             *
             * `tsh` is the thing on your own machine that talks to the cluster, so
             * these are marked for the local shell: `tsh ssh` typed into a session you
             * reached *with* `tsh ssh` is not the thing anyone means.
             */
            Macro(id: "b:tsh-ls", category: "Teleport", name: "tsh ls",
                  description: "Every node the current cluster will let you see, with its labels.",
                  command: "tsh ls", where: "local"),
            // The point is to finish the line yourself — the target is the part that
            // changes every time, and it is not worth a variable prompt to type it.
            Macro(id: "b:tsh-ssh", category: "Teleport", name: "tsh ssh…",
                  description: "Pasted at the prompt without Enter, to finish by hand: add `user@node`, "
                      + "then Enter. `tsh ssh --cluster=leaf user@node` for a leaf.",
                  command: "tsh ssh ", noEnter: true, where: "local"),
            Macro(id: "b:tsh-scp", category: "Teleport", name: "tsh scp…",
                  description: "Pasted without Enter, to finish by hand: `./file user@node:/tmp/`, "
                      + "or `-r` for a directory. Either side can be the remote one.",
                  command: "tsh scp ", noEnter: true, where: "local"),
            Macro(id: "b:tp-config", category: "Teleport", name: "Teleport config",
                  description: "The agent\u{2019}s teleport.yaml.", command: "sudo cat /etc/teleport.yaml"),
            Macro(id: "b:tp-restart", category: "Teleport", name: "Restart Teleport",
                  description: "Restarts the agent \u{2014} drops this host\u{2019}s tunnel briefly.",
                  command: "sudo systemctl restart teleport && sleep 2 && sudo systemctl status teleport --no-pager",
                  confirm: true),

            /* ---- System ---- */
            // df is df everywhere, so this one is useful in the local shell too.
            Macro(id: "b:disk", category: "System", name: "Disk usage",
                  description: "Filesystems, and inodes when a disk is \"full\" but is not.",
                  command: "df -h; echo; df -i | head -n 20", where: "all"),
            Macro(id: "b:big-files", category: "System", name: "Largest directories in /var",
                  description: "What is filling the disk.",
                  command: "sudo du -xh /var --max-depth=2 2>/dev/null | sort -rh | head -n 20"),
            Macro(id: "b:memory", category: "System", name: "Memory and load",
                  description: "Free memory, swap, uptime and load average.", command: "free -h; echo; uptime"),
            Macro(id: "b:top-procs", category: "System", name: "Top processes",
                  description: "The heaviest processes by memory, then CPU.",
                  command: "ps aux --sort=-%mem | head -n 12; echo; ps aux --sort=-%cpu | head -n 12"),
            Macro(id: "b:listening", category: "System", name: "Listening ports",
                  description: "What is bound, and which process owns it.",
                  command: "sudo ss -tulpn 2>/dev/null || sudo netstat -tulpn"),
            Macro(id: "b:errors", category: "System", name: "Recent system errors",
                  description: "Priority error and above from the journal.",
                  command: "sudo journalctl -p err -n 60 --no-pager"),
            Macro(id: "b:who", category: "System", name: "Who is logged in",
                  description: "Current sessions and recent logins.", command: "who -a; echo; last -n 15"),
            // Already written to fall back to the BSD tools, so it answers on a Mac.
            Macro(id: "b:net", category: "System", name: "Network addresses and routes",
                  description: "Interfaces, addresses and the default route.",
                  command: "ip -brief address 2>/dev/null || ifconfig; echo; ip route 2>/dev/null || netstat -rn", where: "all"),
            Macro(id: "b:os", category: "System", name: "OS and kernel",
                  description: "Distribution, kernel and architecture.",
                  command: "cat /etc/os-release 2>/dev/null | head -n 5; echo; uname -a", where: "all"),
            Macro(id: "b:reboot", category: "System", name: "Pending reboot / updates",
                  description: "Whether the box is waiting on a restart.",
                  command: "[ -f /var/run/reboot-required ] && cat /var/run/reboot-required || echo \"no reboot required\"; "
                      + "echo; (sudo needs-restarting -r 2>/dev/null || true)"),
        ]
        /*
         * `where` is left off above and filled in here: every built-in is aimed at a
         * server — systemd, journalctl, `ss -tulpn`, /etc/teleport.yaml — and none of
         * them means anything typed into a Mac's own shell. The handful that fall
         * back to something portable say so for themselves.
         */
        for i in list.indices {
            list[i].builtin = true
            if list[i].whereScope == nil { list[i].whereScope = "hosts" }
        }
        return list
    }()

    // MARK: Loading

    /// Built-ins the user has not dismissed, plus their own (`loadMacros`).
    var all: [Macro] {
        let hidden = Set(FleetStore.hiddenMacros())
        return Macros.builtins.filter { !hidden.contains($0.id) } + FleetStore.savedMacros().map { Macro(json: $0) }
    }

    var categoryOrder: [String] { FleetStore.macroCategoryOrder() }
    var pins: [JSON] { FleetStore.macroPins() }

    func macro(_ id: String) -> Macro? { all.first { $0.id == id } }

    // MARK: Scopes

    /// Where a pinned button is allowed to appear.
    static let pinScopes: [(value: String, label: String)] = [
        ("all", "Every session and the local shell"),
        ("hosts", "Host sessions only"),
        ("local", "The local shell only"),
    ]

    /**
     * Where a macro can be run at all — a property of the macro, not of its
     * button. The same three words as the pin scopes, deliberately: one
     * vocabulary.
     */
    static let runScopes: [(value: String, label: String)] = [
        ("all", "Hosts and the local shell"),
        ("hosts", "Hosts only"),
        ("local", "The local shell only"),
    ]

    static func scopeLabel(_ w: String?) -> String {
        (pinScopes.first { $0.value == (w?.nilIfEmpty ?? "hosts") } ?? pinScopes[1]).label
    }

    static func runScopeLabel(_ w: String?) -> String {
        let s = runScopeOf(w)
        return (runScopes.first { $0.value == s } ?? runScopes[0]).label
    }

    /// A macro's run scope, with the default for one that does not carry it:
    /// `all`, because a macro saved before this existed was offered everywhere.
    static func runScopeOf(_ w: String?) -> String {
        ["all", "hosts", "local"].contains(w ?? "") ? w! : "all"
    }

    /// Does this macro belong in a pane of this kind ("remote" | "local")?
    static func runsOn(_ m: Macro, _ kind: String = "remote") -> Bool {
        let w = runScopeOf(m.whereScope)
        if w == "all" { return true }
        return kind == "local" ? w == "local" : w == "hosts"
    }

    /// The macros that can run in a pane of this kind, in the stored order.
    func macrosFor(_ kind: String = "remote", _ macros: [Macro]? = nil) -> [Macro] {
        (macros ?? all).filter { Macros.runsOn($0, kind) }
    }

    /// The pinned macros for one kind of pane, in button order. A pin whose
    /// macro is hidden or gone is not drawn (the pin stays, so restoring the
    /// macro brings its button back); nor is one where its macro would not run.
    func pinnedMacros(kind: String) -> [(macro: Macro, icon: String, where: String)] {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = kind == "local" ? ["all", "local"] : ["all", "hosts"]
        return pins.compactMap { p in
            let w = p["where"].string?.nilIfEmpty ?? "hosts"
            guard wanted.contains(w), let id = p["id"].string, let m = byId[id], Macros.runsOn(m, kind) else { return nil }
            return (m, p["icon"].string?.nilIfEmpty ?? "\u{25B6}", w)
        }
    }

    func isPinned(_ id: String) -> Bool { pins.contains { $0["id"].string == id } }

    /// The icon a macro is pinned with, or "" when it is not pinned at all.
    func pinnedIconFor(_ id: String) -> String {
        guard let p = pins.first(where: { $0["id"].string == id }) else { return "" }
        return p["icon"].string?.nilIfEmpty ?? "\u{25B6}"
    }

    /// Where a macro's button is shown, or "" when it is not pinned.
    func pinnedScopeFor(_ id: String) -> String {
        guard let p = pins.first(where: { $0["id"].string == id }) else { return "" }
        return p["where"].string?.nilIfEmpty ?? "hosts"
    }

    func setPinned(_ id: String, pinned: Bool = true, icon: String = "", where w: String? = nil) {
        FleetStore.setMacroPin(id, pinned: pinned, icon: icon, where: w)
        Macros.headersChanged()
    }

    /// Pinning a macro adds its button to every session already open.
    static func headersChanged() { PaneHeaderItems.shared.revision += 1 }

    // MARK: Categories

    /**
     * Categories in the order the user has arranged them. Anything not yet
     * placed falls in behind what is — Teleport first, then alphabetically —
     * which means a new category appears somewhere sensible without the saved
     * order having to know about it.
     */
    func categories(_ macros: [Macro]) -> [(String, [Macro])] {
        var byCat: [(String, [Macro])] = []
        for m in macros {
            let key = m.category.nilIfEmpty ?? "Custom"
            if let i = byCat.firstIndex(where: { $0.0 == key }) { byCat[i].1.append(m) } else { byCat.append((key, [m])) }
        }
        let order = categoryOrder
        func rank(_ k: String) -> Int {
            if let i = order.firstIndex(of: k) { return i }
            return order.count + (k == "Teleport" ? 0 : k == "Custom" ? 2 : 1)
        }
        return byCat.enumerated().sorted { a, b in
            let ra = rank(a.element.0), rb = rank(b.element.0)
            if ra != rb { return ra < rb }
            let c = a.element.0.localizedCompare(b.element.0)
            if c != .orderedSame { return c == .orderedAscending }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Move a category one place up or down and remember it. The saved order
    /// is rewritten from what is on screen, so the first move on an untouched
    /// list pins every category where it already appeared.
    @discardableResult
    func moveCategory(_ name: String, _ delta: Int) -> Bool {
        var current = categories(all).map(\.0)
        guard let from = current.firstIndex(of: name) else { return false }
        let to = from + delta
        guard to >= 0, to < current.count else { return false }
        current.insert(current.remove(at: from), at: to)
        FleetStore.setMacroCategoryOrder(current)
        return true
    }

    // MARK: Variables

    /// `{{ name }}` in a command.
    nonisolated static let varRe = try! NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_.-]+)\\s*\\}\\}")
    nonisolated static let varNameRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]+$")

    /**
     * The declaration block, one variable per line:
     *
     *   service = teleport
     *   level = info | warn | error
     *   lines =
     *
     * An `=` with nothing after it means "no default, ask me". A `|` list is a
     * choice; the first is the default unless one is marked with `*`.
     */
    nonisolated static func parseVarSpec(_ text: String?) -> [MacroVar] {
        var out: [MacroVar] = []
        for raw in (text ?? "").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let eq = line.firstIndex(of: "=")
            let name = (eq.map { String(line[..<$0]) } ?? line).trimmingCharacters(in: .whitespaces)
            guard varNameRe.matches(name) else { continue }
            let rest = eq.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
            if rest.contains("|") {
                let parts = rest.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                // A starred entry is the default; otherwise the first one is.
                let starred = parts.first { $0.hasPrefix("*") }
                let unstar: (String) -> String = { s in
                    (s.hasPrefix("*") ? String(s.dropFirst()) : s).trimmingCharacters(in: .whitespaces)
                }
                out.append(MacroVar(name: name, choices: parts.map(unstar), defaultValue: unstar(starred ?? parts.first ?? "")))
            } else {
                out.append(MacroVar(name: name, choices: nil, defaultValue: rest))
            }
        }
        return out
    }

    nonisolated static func renderVarSpec(_ vars: [MacroVar]?) -> String {
        (vars ?? []).map { v in
            if let c = v.choices, !c.isEmpty {
                return "\(v.name) = " + c.map { $0 == v.defaultValue ? "*" + $0 : $0 }.joined(separator: " | ")
            }
            return "\(v.name) = \(v.defaultValue)"
        }.joined(separator: "\n")
    }

    /// The `{{names}}` a command uses, in order of first use.
    nonisolated static func usedNames(_ command: String) -> [String] {
        let ns = command as NSString
        var out: [String] = []
        for m in varRe.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1))
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /**
     * Every variable this macro needs: the declared ones first, then any
     * `{{placeholder}}` in the command that was never declared — treated as a
     * variable with no default rather than left in the command as literal text.
     * A declared variable the command never mentions is not asked for.
     */
    nonisolated static func varsOf(command: String, variables: [MacroVar]?, variableSpec: String) -> [MacroVar] {
        let declared = variables ?? parseVarSpec(variableSpec)
        return usedNames(command).map { name in declared.first { $0.name == name } ?? MacroVar(name: name) }
    }

    static func varsOf(_ m: Macro) -> [MacroVar] {
        varsOf(command: m.command, variables: m.variables, variableSpec: m.variableSpec)
    }

    nonisolated static func expand(_ command: String, _ values: [String: String]) -> String {
        let ns = command as NSString
        var out = ""
        var last = 0
        for m in varRe.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += values[name] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /**
     * The macro as it will actually run. `ask` forces the dialog even when
     * every blank has a default — which is what the submenu entry is for.
     * Without it, a macro whose variables all have defaults runs on one click,
     * and one with a blank still asks, because there is nothing sensible to
     * put there.
     */
    func resolve(_ m: Macro, ask: Bool = false, window: WindowModel?) async -> Macro? {
        let vars = Macros.varsOf(m)
        if vars.isEmpty { return m }
        let needed = vars.contains { $0.defaultValue.isEmpty }
        var out = m
        if !ask && !needed {
            out.command = Macros.expand(m.command, Dictionary(vars.map { ($0.name, $0.defaultValue) }, uniquingKeysWith: { a, _ in a }))
            return out
        }
        guard let values = await MacroDialogs.askVars(m, vars, window: window) else { return nil }
        out.command = Macros.expand(m.command, values)
        return out
    }

    // MARK: Running

    private func allowed(_ m: Macro, window: WindowModel?) async -> Bool {
        if !m.confirm { return true }
        return await MiscUI.confirm(window, title: m.name, message: "Run this on the target host?", detail: m.command,
                                    confirmLabel: "Run", danger: true)
    }

    func markUsed(_ m: Macro) {
        if !m.builtin { FleetStore.markMacroUsed(m.id) }
    }

    /// "remote" or "local": what a pane is, for scopes. A console or a tmux
    /// pane takes the same commands a host does.
    static func paneKind(_ p: SessionPane) -> String { p.kind == .local ? "local" : "remote" }

    private func sessions(_ window: WindowModel?) -> SessionsWindow? {
        (window ?? WindowManager.shared.focused)?.feature(SessionsWindow.self)
    }

    /// Type it into the focused terminal (or every remote pane in the tab) —
    /// the default, and the only way to follow a log.
    func send(_ mIn: Macro, all: Bool = false, window wIn: WindowModel?) async {
        let window = wIn ?? WindowManager.shared.focused
        guard let s = sessions(window) else { return }
        let targets: [SessionPane] = all
            ? s.panesOf(s.activeTabId).compactMap { s.pane($0) }.filter { $0.hasTerm && $0.kind == .remote }
            : [s.activePane].compactMap { $0 }.filter { $0.hasTerm }
        guard !targets.isEmpty else {
            StatusBus.shared.toast("Open a session first, or use \u{201C}Run and show output\u{201D}", kind: .error)
            return
        }
        /*
         * A macro can reach a pane it is not meant for — the sidebar's
         * double-click sends to whatever is focused, and the focused thing may be
         * the local shell. Asked rather than refused: the scope is a default
         * about where it belongs, not a lock.
         */
        let wrong = targets.filter { !Macros.runsOn(mIn, Macros.paneKind($0)) }
        if !wrong.isEmpty {
            let detail = wrong.count == targets.count
                ? "The focused pane is \(wrong[0].kind == .local ? "the local shell" : "a host session")."
                : "\(wrong.count) of \(targets.count) panes are not what it is set for."
            let ok = await MiscUI.confirm(window, title: "Run it here?",
                                          message: "\u{201C}\(mIn.name)\u{201D} is set to run in \(Macros.runScopeLabel(mIn.whereScope).lowercased()).",
                                          detail: detail, confirmLabel: "Run it anyway")
            if !ok { return }
        }
        guard let m = await resolve(mIn, window: window) else { return }
        guard await allowed(m, window: window) else { return }
        // A macro with an interval of its own starts ticking rather than running once.
        if m.repeatSeconds > 0 && !m.interactive && !m.noEnter {
            for p in targets { await startRepeat(m, seconds: m.repeatSeconds, paneId: p.id, window: window, askFirst: false) }
            return
        }
        // Normally the newline is the point — the macro runs. A macro marked
        // `noEnter` is one you mean to finish by hand, so it is left on the prompt.
        let text = m.noEnter ? Macros.trimTrailingNewlines(m.command) : Macros.trimTrailingNewlines(m.command) + "\n"
        for p in targets { Macros.sendText(text, to: p, window: window) }
        markUsed(m)
        let n = targets.count
        StatusBus.shared.show(m.noEnter
            ? "\(m.name) \u{2192} \(n) pane\(n == 1 ? "" : "s") \u{2014} press Enter to run"
            : "\(m.name) \u{2192} \(n) pane\(n == 1 ? "" : "s")")
    }

    nonisolated static func trimTrailingNewlines(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    /// Into a pane's shell, exactly as typed (`sendToPane`).
    static func sendText(_ text: String, to p: SessionPane, window: WindowModel?) {
        Actions.shared.perform("send-text", window: p.owner?.window ?? window, paneId: p.id,
                               args: ["text": text, "enter": false])
    }

    // MARK: Repeating

    /**
     * Macros that finish can be put on a timer: watch a queue drain, keep an eye
     * on load, poll a service coming back up. Only commands that end are
     * eligible. A repeat belongs to a pane, not to the macro: the same macro
     * can tick on two hosts at once, and closing a pane takes its repeats with it.
     */
    private(set) var repeats: [String: MacroRepeat] = [:]
    @ObservationIgnored private var timers: [String: Timer] = [:]

    nonisolated static func repeatKey(_ paneId: String, _ macroId: String) -> String { "\(paneId):\(macroId)" }

    func repeatsOnPane(_ paneId: String) -> [MacroRepeat] {
        repeats.values.filter { $0.paneId == paneId }.sorted { $0.since < $1.since }
    }

    func isRepeating(_ paneId: String, _ macroId: String) -> Bool { repeats[Macros.repeatKey(paneId, macroId)] != nil }

    /// Seconds as a human would say them: 45s, 2m, 1h 30m.
    nonisolated static func fmtEvery(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 != 0 ? "\(s / 60)m \(s % 60)s" : "\(s / 60)m" }
        let h = s / 3600
        let m = Int((Double(s % 3600) / 60).rounded())
        return m != 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private func pane(_ id: String) -> SessionPane? { SessionsCore.owner(ofPane: id)?.pane(id) }

    @discardableResult
    func startRepeat(_ m: Macro, seconds: Int, paneId: String?, window: WindowModel?, askFirst: Bool = true) async -> Bool {
        guard let paneId, let p = pane(paneId), p.hasTerm else {
            StatusBus.shared.toast("Open a session first", kind: .error); return false
        }
        if m.interactive { StatusBus.shared.toast("\u{201C}\(m.name)\u{201D} follows a log \u{2014} it cannot repeat", kind: .error); return false }
        if m.noEnter { StatusBus.shared.toast("\u{201C}\(m.name)\u{201D} is left at the prompt \u{2014} it cannot repeat", kind: .error); return false }
        let every = max(1, seconds)
        if askFirst { guard await allowed(m, window: window) else { return false } }
        stopRepeat(paneId, m.id)
        let text = Macros.trimTrailingNewlines(m.command) + "\n"
        let key = Macros.repeatKey(paneId, m.id)
        repeats[key] = MacroRepeat(macro: m, paneId: paneId, every: every, since: nowMs(), runs: 0)
        let tick: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // The pane went away, or its shell did: stop rather than write into nothing.
            guard let p = self.pane(paneId), p.hasTerm else { self.stopRepeat(paneId, m.id); return }
            Macros.sendText(text, to: p, window: window)
            self.repeats[key]?.runs += 1
        }
        tick()
        // In the common modes, so it keeps ticking through scrolling, drags and alerts.
        let timer = Timer(timeInterval: Double(every), repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[key] = timer
        markUsed(m)
        refreshPaneButtons()
        let paneName = SessionsCore.paneTitle(p).nilIfEmpty ?? "this pane"
        StatusBus.shared.show("\(m.name) every \(Macros.fmtEvery(Double(every))) on \(paneName)")
        return true
    }

    @discardableResult
    func stopRepeat(_ paneId: String, _ macroId: String) -> Bool {
        let key = Macros.repeatKey(paneId, macroId)
        guard repeats[key] != nil else { return false }
        timers.removeValue(forKey: key)?.invalidate()
        repeats.removeValue(forKey: key)
        refreshPaneButtons()
        return true
    }

    /// Everything a pane had on a timer — called when the pane closes.
    @discardableResult
    func stopRepeatsForPane(_ paneId: String) -> Int {
        var n = 0
        for (key, r) in repeats where r.paneId == paneId {
            timers.removeValue(forKey: key)?.invalidate()
            repeats.removeValue(forKey: key)
            n += 1
        }
        if n > 0 { refreshPaneButtons() }
        return n
    }

    /// Mark the panes with a macro on a timer. The run button is where the
    /// repeat was started and where it is stopped, so it is where the fact belongs.
    func refreshPaneButtons() {
        for s in SessionsCore.allWindows() {
            for p in s.panes.values {
                let running = repeatsOnPane(p.id)
                p.macroRepeating = !running.isEmpty
                p.macroButtonTitle = running.isEmpty ? nil
                    : running.map { "\($0.macro.name) \u{2014} every \(Macros.fmtEvery(Double($0.every)))" }.joined(separator: "\n")
                        + "\n\nClick to stop or run another"
            }
        }
    }

    // MARK: Headless

    /**
     * Run without a terminal and show what came back. Refuses the macros that
     * never finish, since a headless exec would simply hang until its timeout.
     */
    func runOnHost(_ mIn: Macro, host: Host, login: String?, window: WindowModel?) async {
        if mIn.interactive {
            StatusBus.shared.toast("\u{201C}\(mIn.name)\u{201D} follows a log \u{2014} send it to a terminal instead", kind: .error); return
        }
        // Running it headless is precisely the thing this macro asked not to happen.
        if mIn.noEnter {
            StatusBus.shared.toast("\u{201C}\(mIn.name)\u{201D} is meant to be edited before running \u{2014} send it to a terminal", kind: .error); return
        }
        /*
         * This path is a host by definition — it is reached by picking one — so a
         * macro set for the local shell is being sent somewhere it does not belong.
         * Asked rather than refused, the same as sending one to the wrong pane.
         */
        if !Macros.runsOn(mIn, "remote") {
            let ok = await MiscUI.confirm(window, title: "Run it on a host?",
                                          message: "\u{201C}\(mIn.name)\u{201D} is set to run in \(Macros.runScopeLabel(mIn.whereScope).lowercased()).",
                                          detail: "It is about to run on a server instead.", confirmLabel: "Run it anyway")
            if !ok { return }
        }
        guard let m = await resolve(mIn, window: window) else { return }
        guard await allowed(m, window: window) else { return }
        markUsed(m)
        FleetRunCommand.open(host: host, login: login, command: m.command, title: m.name, window: window)
    }

    /// The host behind the focused pane, when there is one (`activeHost`).
    func activeHost(_ window: WindowModel?) -> (id: String?, label: String)? {
        guard let s = sessions(window), let connId = s.activeConnId, let c = ConnectionManager.shared.connection(connId) else { return nil }
        let label = SessConnRecords.shared.label(connId) ?? c.label
        return (c.hostId, label.isEmpty ? (c.remoteHostname ?? "") : label)
    }

    /**
     * What the Saved → Macros list does on double-click: send to the focused
     * terminal; with nothing focused, offer to run it on a host the user picks
     * and show the output.
     */
    func runHere(_ m: Macro, window: WindowModel?) async {
        if let s = sessions(window), s.activePane?.hasTerm == true {
            await send(m, window: window)
            return
        }
        guard let host = await FleetHostPicker.pick(window, title: "Run on which host?", visibleOnly: true) else { return }
        await runOnHost(m, host: host, login: FleetHooks.preferredLogin(host), window: window)
    }

    // MARK: Editing

    /// Hide a built-in (they cannot be deleted) or delete one of your own.
    @discardableResult
    func delete(_ m: Macro, window: WindowModel?) async -> Bool {
        if m.builtin {
            let ok = await MiscUI.confirm(window, title: "Hide built-in macro", message: "Hide \u{201C}\(m.name)\u{201D}?",
                                          detail: "Built-in macros cannot be deleted, only hidden. Restore them from the Macros menu.",
                                          confirmLabel: "Hide")
            if !ok { return false }
            FleetStore.setMacroHidden(m.id, true)
        } else {
            let ok = await MiscUI.confirm(window, title: "Delete macro", message: "Delete \u{201C}\(m.name)\u{201D}?",
                                          confirmLabel: "Delete", danger: true)
            if !ok { return false }
            FleetStore.deleteMacro(m.id)
        }
        Macros.headersChanged()
        return true
    }

    /// Bring back every dismissed built-in.
    func restoreBuiltins() {
        let hidden = FleetStore.hiddenMacros()
        if hidden.isEmpty { StatusBus.shared.show("No hidden macros"); return }
        for id in hidden { FleetStore.setMacroHidden(id, false) }
        Macros.headersChanged()
        StatusBus.shared.show("Restored \(hidden.count) built-in macro\(hidden.count == 1 ? "" : "s")")
    }

    /**
     * Pin or unpin from a menu, asking for an icon on the way in. Unpinning
     * asks nothing: it is instantly reversible.
     */
    func togglePin(_ m: Macro, window: WindowModel?) async {
        if isPinned(m.id) {
            setPinned(m.id, pinned: false)
            StatusBus.shared.show("Unpinned \(m.name)")
            return
        }
        guard let opts = await MacroDialogs.pinOptions(name: m.name, window: window) else { return }
        setPinned(m.id, pinned: true, icon: opts.icon, where: opts.where)
        StatusBus.shared.show("\(m.name) is now a button \u{2014} \(Macros.scopeLabel(opts.where).lowercased())")
    }

    /// The full list: the sidebar's Saved tab, on its Macros view.
    static func openManager(window: WindowModel?) {
        guard let w = window ?? WindowManager.shared.focused else { return }
        w.sidebarVisible = true
        let sw = w.feature(SidebarWindow.self)
        sw.tab = "saved"
        sw.savedView = "macros"
    }
}
