import AppKit
import SwiftUI

/// The Settings dialog: the port of index.js `openSettings()` and
/// `locateTsh()`. Everything is edited as a draft and written in one
/// `Store.updateSettings` patch on Save, with the original's keys, defaults
/// and coercions; Cancel undoes the live theme preview.
@MainActor
enum SettingsDialog {
    struct Option: Hashable {
        let value: String
        let label: String
    }

    static let accentOptions: [Option] = [
        .init(value: "blue", label: "Default (blue, or the theme\u{2019}s own)"),
        .init(value: "violet", label: "Violet"), .init(value: "teal", label: "Teal"),
        .init(value: "green", label: "Green"), .init(value: "amber", label: "Amber"),
        .init(value: "rose", label: "Rose"), .init(value: "slate", label: "Slate"),
    ]

    static var skinOptions: [Option] {
        [.init(value: "none", label: "None — plain dark or light")]
            + MiscThemes.skins.map { .init(value: $0.id, label: $0.label) }
    }

    /// connectanim.js CONNECT_ANIMS: id, name, first of the cast.
    static let connectAnims: [(id: String, name: String, glyph: String)] = [
        ("robots", "Robots shaking hands", "🤖"), ("tubes", "Pneumatic tubes", "📦"),
        ("rocket", "Rocket post", "🚀"), ("pigeon", "Carrier pigeon", "🐦"),
        ("satellite", "Satellite relay", "🛰️"), ("train", "Freight train", "🚂"),
        ("submarine", "Undersea cable", "🚢"), ("plane", "Paper plane", "✈️"),
        ("ants", "Ants with packets", "🐜"), ("laser", "Laser link", "✨"),
        ("conveyor", "Conveyor belt", "📦"), ("hamster", "Hamster-powered", "🐹"),
        ("lightning", "Lightning link", "⚡"), ("teleport", "Teleporter", "🫠"),
        ("snail", "Snail mail", "🐌"), ("balloon", "Hot air balloon", "🎈"),
        ("bucket", "Bucket brigade", "🪣"), ("zipline", "Zip line", "🧗"),
        ("morse", "Morse code", "•"), ("tincan", "Tin can telephone", "🥫"),
        ("drone", "Drone delivery", "🛸"), ("cat", "Cat chasing a packet", "🐈"),
        ("wormhole", "Wormhole", "🌀"), ("bridge", "Bridge builder", "🔨"),
        ("bees", "Busy bees", "🐝"), ("traffic", "Rush hour", "🚚"),
        ("radio", "Radio waves", "📡"), ("dolphin", "Dolphin express", "🐬"),
        ("ghost", "Friendly packet ghost", "👻"), ("scooter", "Courier scooter", "🛵"),
    ]

    static var animOptions: [Option] {
        [.init(value: "rotate", label: "Rotate through all of them"), .init(value: "off", label: "Off — just the log")]
            + connectAnims.map { .init(value: $0.id, label: $0.glyph + "  " + $0.name) }
    }

    static let recentOptions: [Option] = [
        .init(value: "0", label: "Off — do not offer recent connections"), .init(value: "5", label: "Last 5"),
        .init(value: "10", label: "Last 10"), .init(value: "20", label: "Last 20"), .init(value: "50", label: "Last 50"),
    ]
    static let refreshOptions: [Option] = [
        .init(value: "0", label: "Off — refresh only when I ask"), .init(value: "2", label: "Every 2 seconds"),
        .init(value: "5", label: "Every 5 seconds"), .init(value: "10", label: "Every 10 seconds"),
        .init(value: "30", label: "Every 30 seconds"),
    ]
    static let nodeRefreshOptions: [Option] = [
        .init(value: "0", label: "Off — only when I press Refresh"), .init(value: "10", label: "Every 10 seconds"),
        .init(value: "30", label: "Every 30 seconds"), .init(value: "60", label: "Every minute"),
        .init(value: "300", label: "Every 5 minutes"),
    ]
    static let staleOptions: [Option] = [
        .init(value: "0", label: "Off — do not warn"), .init(value: "2", label: "Quiet for 2 minutes"),
        .init(value: "5", label: "Quiet for 5 minutes"), .init(value: "10", label: "Quiet for 10 minutes"),
    ]
    static let hostLimitOptions: [Option] = [
        .init(value: "0", label: "No limit — list every host"), .init(value: "10", label: "Stop at 10 per group"),
        .init(value: "20", label: "Stop at 20 per group"), .init(value: "30", label: "Stop at 30 per group"),
        .init(value: "50", label: "Stop at 50 per group"), .init(value: "100", label: "Stop at 100 per group"),
    ]
    static let mfaOptions: [Option] = [
        .init(value: "platform", label: "Touch ID / platform authenticator"),
        .init(value: "cross-platform", label: "Security key (YubiKey)"),
        .init(value: "otp", label: "OTP code"), .init(value: "browser", label: "Browser"),
        .init(value: "auto", label: "Automatic (tsh decides)"),
    ]
    static let x11Options: [Option] = [
        .init(value: "off", label: "Off"), .init(value: "untrusted", label: "On - untrusted (ssh -X)"),
        .init(value: "trusted", label: "On - trusted (ssh -Y)"),
    ]
    static let starredOptions: [Option] = [
        .init(value: "inline", label: "At the top of the group they belong to"),
        .init(value: "group", label: "Gathered in a Starred group above everything"),
    ]

    static func open(_ window: WindowModel? = nil) {
        let draft = SettingsDraft()
        MiscAppInfo.shared.refreshTshVersion()
        let h = Modal.sheet(window, title: "Settings", width: 660, height: 760, resizable: true, autosave: "settings") { handle in
            SettingsView(d: draft, handle: handle)
        }
        h.onClose.append {
            // Undo any live preview that was not saved.
            if MiscThemes.preview != nil { MiscThemes.preview = nil; Theme.shared.refresh() }
        }
    }

    /// Apply a settings patch the way main.js `settings:set` does: write it,
    /// and apply the tool paths and tsh homes at once.
    static func apply(_ patch: [String: JSON]) {
        Store.shared.updateSettings(patch)
        if let h = patch["tshHomes"] { Tools.homes = h.stringArray }
        if let p = patch["tshPath"] { Tools.setTshPath(p.string) }
        if let p = patch["sshPath"] { Tools.setSshPath(p.string) }
        if patch["tshPath"] != nil { MiscAppInfo.shared.refreshTshVersion() }
    }

    /// "Locate tsh / ssh…" — the Command-line tools dialog (`locateTsh`).
    static func locateTools(_ window: WindowModel? = nil) async {
        let s = Store.shared.settings
        let result: (String, String)? = await withCheckedContinuation { cont in
            var done = false
            let finish: ((String, String)?) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let h = Modal.sheet(window, title: "Command-line tools", width: 640) { handle in
                LocateToolsView(tsh: s["tshPath"].string ?? "", ssh: s["sshPath"].string ?? "") { v in
                    finish(v); handle.close()
                }
            }
            h.onClose.append { finish(nil) }
        }
        guard let (tsh, ssh) = result else { return }
        apply(["tshPath": .string(tsh), "sshPath": .string(ssh)])
        Actions.shared.perform("refresh", window: window)
    }

    /// x11:status for macOS: XQuartz provides the server and sets DISPLAY
    /// for its own clients.
    static func x11Status() -> (available: Bool, hint: String, display: String?) {
        let display = ProcessInfo.processInfo.environment["DISPLAY"].flatMap { $0.isEmpty ? nil : $0 }
        let installed = ["/opt/X11/bin/Xquartz", "/Applications/Utilities/XQuartz.app", "/opt/X11"]
            .contains { FileManager.default.fileExists(atPath: $0) }
        let hint = !installed
            ? "XQuartz is not installed. Install it (brew install --cask xquartz), log out and back in."
            : display == nil
                ? "XQuartz is installed but DISPLAY is not set for this app. Launch XQuartz, then restart ServerLife from a terminal so it inherits DISPLAY."
                : "XQuartz detected."
        return (display != nil && installed, hint, display)
    }
}

/// Everything the dialog edits, read from settings with the original's defaults.
@MainActor
final class SettingsDraft: ObservableObject {
    @Published var theme: String { didSet { preview() } }
    @Published var accent: String { didSet { preview() } }
    @Published var skin: String { didSet { preview() } }
    @Published var terminalPalette: String
    @Published var fontSize: String
    @Published var sidebarFontSize: String
    @Published var scrollback: String
    @Published var fontFamily: String
    @Published var follow: Bool
    @Published var hidden: Bool
    @Published var details: Bool
    @Published var foldersFirst: Bool
    @Published var show3d: Bool
    @Published var editor: String
    @Published var blink: Bool
    @Published var highlight: Bool
    @Published var shellTitle: Bool
    @Published var netIcon: Bool
    @Published var tabActivity: Bool
    @Published var linkAsk: Bool
    @Published var closeAsk: Bool
    @Published var quitAsk: Bool
    @Published var tmuxDefault: Bool
    @Published var tmuxName: String
    @Published var reqPane: Bool
    @Published var watchMark: Bool
    @Published var agent: Bool
    @Published var autoLocal: String
    @Published var autoHost: String
    @Published var starredMode: String
    @Published var connectAnim: String { didSet { pickPreviewAnim() } }
    @Published var recentLimit: String
    @Published var refreshSeconds: String
    @Published var nodeRefreshSeconds: String
    @Published var staleNodeMinutes: String
    @Published var sidebarHostLimit: String
    @Published var mfaMode: String
    @Published var x11: String
    @Published var tshHomes: [String]
    @Published var homesNote = ""
    /// The automation status (`control:status`): nil while reading, `.null`
    /// when no automation is registered in this build.
    @Published var control: JSON?
    @Published var previewAnim: String?
    let fontSizeBefore: Double
    let before: JSON

    init() {
        let s = Store.shared.settings
        before = s
        func num(_ k: String, _ d: Double) -> Double { let v = s[k].double ?? 0; return v == 0 || v.isNaN ? d : v }
        func nn(_ k: String, _ d: Int) -> String { s[k].isNull ? String(d) : (s[k].stringish ?? String(d)) }
        func notFalse(_ k: String) -> Bool { s[k].bool != false }
        func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        func pick(_ v: String, _ opts: [SettingsDialog.Option]) -> String {
            opts.contains { $0.value == v } ? v : (opts.first?.value ?? v)
        }
        theme = s["theme"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "dark"
        accent = pick(s["accent"].string ?? "blue", SettingsDialog.accentOptions)
        skin = pick(s["skin"].string ?? "none", SettingsDialog.skinOptions)
        terminalPalette = s["terminalPalette"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "app"
        fontSizeBefore = num("fontSize", 13)
        fontSize = fmt(num("fontSize", 13))
        sidebarFontSize = fmt(num("sidebarFontSize", 13))
        scrollback = fmt(num("scrollback", 10000))
        fontFamily = s["fontFamily"].string ?? ""
        follow = notFalse("followTerminalFolder")
        hidden = s["showHiddenFiles"].truthy
        details = s["showFileDetails"].truthy
        foldersFirst = notFalse("foldersFirst")
        show3d = notFalse("show3dView")
        editor = s["externalEditor"].string ?? ""
        blink = notFalse("cursorBlink")
        highlight = s["highlight"].bool == true
        shellTitle = s["showShellInTitle"].truthy
        netIcon = notFalse("showPaneNetIcon")
        tabActivity = notFalse("showTabActivity")
        linkAsk = notFalse("confirmLinkOpen")
        closeAsk = notFalse("confirmCloseWithSessions")
        quitAsk = notFalse("confirmQuitWithSessions")
        tmuxDefault = s["tmuxDefault"].bool == true
        tmuxName = s["tmuxSessionName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "serverlife"
        reqPane = s["requestMonitorAutoOpen"].bool == true
        watchMark = notFalse("showWatchMark")
        agent = s["agentForward"].truthy
        autoLocal = s["autoFlagLocal"].stringArray.joined(separator: "\n")
        autoHost = s["autoFlagHost"].stringArray.joined(separator: "\n")
        starredMode = s["starredMode"].string == "group" ? "group" : "inline"
        connectAnim = pick(s["connectAnim"].string ?? "rotate", SettingsDialog.animOptions)
        recentLimit = pick(nn("recentLimit", 20), SettingsDialog.recentOptions)
        refreshSeconds = pick(nn("refreshSeconds", 5), SettingsDialog.refreshOptions)
        nodeRefreshSeconds = pick(nn("nodeRefreshSeconds", 10), SettingsDialog.nodeRefreshOptions)
        staleNodeMinutes = pick(nn("staleNodeMinutes", 2), SettingsDialog.staleOptions)
        sidebarHostLimit = pick(nn("sidebarHostLimit", 20), SettingsDialog.hostLimitOptions)
        mfaMode = pick(s["mfaMode"].string ?? "platform", SettingsDialog.mfaOptions)
        x11 = pick(s["x11"].string ?? "off", SettingsDialog.x11Options)
        tshHomes = s["tshHomes"].stringArray
        pickPreviewAnim()
        readControl()
    }

    private func preview() {
        MiscThemes.preview = (theme, accent, skin)
        Theme.shared.refresh()
    }

    func pickPreviewAnim() {
        switch connectAnim {
        case "off": previewAnim = nil
        case "rotate": previewAnim = SettingsDialog.connectAnims.randomElement()?.id
        default: previewAnim = connectAnim
        }
    }

    // MARK: Automation (owned by automation; reached through actions)

    func readControl() {
        guard Actions.shared.isRegistered("automation-status") else { control = .null; return }
        control = nil
        Actions.shared.perform("automation-status", args: ["reply": { (j: JSON) in
            MainActor.assumeIsolated { self.control = j }
        } as (JSON) -> Void])
    }

    func setControl(_ on: Bool) {
        guard Actions.shared.isRegistered("automation-toggle") else {
            StatusBus.shared.toast("Local automation is not available in this build", kind: .error); return
        }
        Actions.shared.perform("automation-toggle", args: ["enabled": on, "reply": { (j: JSON) in
            MainActor.assumeIsolated {
                if let e = j["error"].string { StatusBus.shared.toast(e, kind: .error); return }
                var c = self.control ?? .object([:])
                c.merge(j)
                self.control = c
            }
        } as (JSON) -> Void])
    }

    func rotateToken() {
        guard Actions.shared.isRegistered("automation-rotate") else {
            StatusBus.shared.toast("Local automation is not available in this build", kind: .error); return
        }
        Actions.shared.perform("automation-rotate", args: ["reply": { (j: JSON) in
            MainActor.assumeIsolated {
                if let e = j["error"].string { StatusBus.shared.toast(e, kind: .error); return }
                self.readControl()
                StatusBus.shared.toast("Token replaced — re-register any client", kind: .ok)
            }
        } as (JSON) -> Void])
    }

    func copy(_ what: String) {
        if Actions.shared.isRegistered("automation-copy-command") {
            Actions.shared.perform("automation-copy-command", args: ["what": what])
        } else {
            Clipboard.write(control?[what == "bridge" ? "bridge" : "mcpCommand"].string ?? "")
        }
        StatusBus.shared.show("Copied")
    }

    // MARK: tsh homes

    var defaultHome: String { MiscAppInfo.shared.defaultTshHome }

    func moveHome(_ i: Int, by d: Int) {
        let j = i + d
        guard tshHomes.indices.contains(i), tshHomes.indices.contains(j) else { return }
        tshHomes.swapAt(i, j)
    }

    func addHomeDirectories() async {
        let dirs = await Modal.openFiles(nil, directories: true, files: false, multiple: true)
        guard !dirs.isEmpty else { return }
        // The list replaces the default rather than adding to it, so the first
        // directory added brings the default along — otherwise the clusters
        // already on screen would quietly disappear.
        if tshHomes.isEmpty { tshHomes.append(defaultHome) }
        for d in dirs.map(\.path) where !tshHomes.contains(d) { tshHomes.append(d) }
    }

    func addDefaultHome() {
        if !tshHomes.contains(defaultHome) { tshHomes.append(defaultHome) }
    }

    func checkHomes() async {
        homesNote = "Reading profiles…"
        // Applied first: what the check reports has to be what will be used.
        SettingsDialog.apply(["tshHomes": JSON(tshHomes)])
        guard let read = MiscHooks.teleportHomes else {
            homesNote = "Reading Teleport homes is not available in this build."
            return
        }
        let r = await read()
        if r["tsh"]["found"].bool == false {
            homesNote = "tsh was not found, so no home can be read. Looked in:\n"
                + r["tsh"]["searched"].stringArray.joined(separator: "\n")
            return
        }
        if let e = r["error"].string { homesNote = e; return }
        homesNote = r["homes"].items.map { h -> String in
            let name = h["name"].string ?? ""
            let whereText = h["default"].truthy ? "default" : (name.isEmpty ? (h["path"].string ?? "") : name)
            if h["exists"].bool == false { return "\(whereText): directory not found" }
            if let e = h["error"].string, !e.isEmpty { return "\(whereText): \(e)" }
            let profiles = h["profiles"].items
            if profiles.isEmpty { return "\(whereText): no profiles" }
            return "\(whereText): " + profiles.map { ($0["cluster"].string ?? "") + ($0["expired"].truthy ? " (expired)" : "") }
                .joined(separator: ", ")
        }.joined(separator: "\n")
    }

    // MARK: Watch (settings.watchedHosts, watch.js)

    var watchCount: Int { Store.shared.settings["watchedHosts"].entries.count }
    var watchMissing: Int { Store.shared.settings["watchedHosts"].entries.values.filter { $0["missingSince"].truthy }.count }

    // MARK: Save

    var patch: [String: JSON] {
        func int(_ s: String) -> Int? { Int(s.trimmed) ?? Double(s.trimmed).map { Int($0) } }
        func lines(_ s: String) -> JSON { JSON(s.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }) }
        let fs = int(fontSize).flatMap { $0 == 0 ? nil : $0 } ?? 13
        return [
            "theme": .string(theme), "accent": .string(accent), "skin": .string(skin),
            "terminalPalette": .string(terminalPalette), "x11": .string(x11), "mfaMode": .string(mfaMode),
            "connectAnim": .string(connectAnim), "recentLimit": JSON(int(recentLimit) ?? 20),
            "tshHomes": JSON(tshHomes),
            "refreshSeconds": JSON(int(refreshSeconds) ?? 5),
            "nodeRefreshSeconds": JSON(int(nodeRefreshSeconds) ?? 10),
            "staleNodeMinutes": JSON(int(staleNodeMinutes) ?? 2),
            "sidebarHostLimit": JSON(int(sidebarHostLimit) ?? 20),
            "fontSize": JSON(fs),
            "sidebarFontSize": JSON(max(10, min(22, int(sidebarFontSize).flatMap { $0 == 0 ? nil : $0 } ?? 13))),
            "fontFamily": .string(fontFamily.trimmed),
            "scrollback": JSON(int(scrollback).flatMap { $0 == 0 ? nil : $0 } ?? 10000),
            "cursorBlink": .bool(blink), "followTerminalFolder": .bool(follow),
            "showHiddenFiles": .bool(hidden), "showFileDetails": .bool(details),
            "foldersFirst": .bool(foldersFirst), "show3dView": .bool(show3d),
            "externalEditor": .string(editor.trimmed), "highlight": .bool(highlight),
            "showShellInTitle": .bool(shellTitle), "showPaneNetIcon": .bool(netIcon),
            "showTabActivity": .bool(tabActivity), "confirmLinkOpen": .bool(linkAsk),
            "confirmQuitWithSessions": .bool(quitAsk), "confirmCloseWithSessions": .bool(closeAsk),
            "tmuxDefault": .bool(tmuxDefault),
            "tmuxSessionName": .string(tmuxName.trimmed.isEmpty ? "serverlife" : tmuxName.trimmed),
            "requestMonitorAutoOpen": .bool(reqPane), "showWatchMark": .bool(watchMark),
            "agentForward": .bool(agent), "starredMode": .string(starredMode),
            "autoFlagLocal": lines(autoLocal), "autoFlagHost": lines(autoHost),
        ]
    }

    func save(_ window: WindowModel?) {
        let p = patch
        let homesChanged = before["tshHomes"].stringArray != tshHomes
        MiscThemes.preview = nil
        SettingsDialog.apply(p)
        let after = Store.shared.settings
        for hook in MiscHooks.settingsSaved { hook(before, after) }
        // A changed home list is a changed inventory.
        if homesChanged { Actions.shared.perform("refresh", window: window) }
        StatusBus.shared.show("Settings saved")
    }
}

// MARK: - Views

private struct SettingsView: View {
    @ObservedObject var d: SettingsDraft
    let handle: ModalHandle

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "Settings") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    MiscField(label: "Theme") { ThemePicker(selection: $d.theme) }
                    MiscField(label: "Accent colour") { OptionPicker(options: SettingsDialog.accentOptions, selection: $d.accent) }
                }
                MiscField(label: "Skin", hint: "A skin repaints everything, terminals included, and ignores the two above.") {
                    OptionPicker(options: SettingsDialog.skinOptions, selection: $d.skin)
                }
                MiscField(label: "Terminal colours",
                          hint: "The palette programs\u{2019} output is drawn in. \"Follow the app theme\" keeps the old behaviour, "
                            + "including skins; a named palette wins over both.") {
                    OptionPicker(options: MiscThemes.terminalPalettes.map { .init(value: $0.value, label: $0.label) },
                                 selection: $d.terminalPalette)
                }
                MiscRule()
                HStack(alignment: .top, spacing: 10) {
                    MiscField(label: "Terminal font size") { NumberField(text: $d.fontSize) }
                    MiscField(label: "Host list text size") { NumberField(text: $d.sidebarFontSize) }
                    MiscField(label: "Scrollback lines") { NumberField(text: $d.scrollback) }
                }
                MiscHint(text: "\u{2318} + and \u{2212} change the pane you are in, or the host list when that is where you "
                         + "clicked last; 0 puts it back.")
                    .padding(.top, -4).padding(.bottom, 10)
                MiscField(label: "Font family") {
                    TextField("", text: $d.fontFamily).textFieldStyle(.roundedBorder)
                }
                MiscRule()
                MiscField(label: "Local automation") { AutomationBox(d: d) }
                MiscRule()
                MiscField(label: "Teleport homes (TELEPORT_HOME)",
                          hint: "Every directory listed is read for clusters, and every tsh command for a cluster runs with the home it came from. Order is precedence.") {
                    HomesList(d: d, window: WindowManager.shared.model(for: handle.window))
                }
                if !d.homesNote.isEmpty { MiscHint(text: d.homesNote).padding(.top, -4).padding(.bottom, 8) }
                MiscRule()
                MiscField(label: "Remember recent connections",
                          hint: "Offered at the top of New session, newest first, one row per destination. The full session history (⌘Y) is kept either way.") {
                    OptionPicker(options: SettingsDialog.recentOptions, selection: $d.recentLimit)
                }
                MiscRule()
                MiscField(label: "While a session connects",
                          hint: "A small scene plays over the connection log. Thirty of them, rotating.") {
                    OptionPicker(options: SettingsDialog.animOptions, selection: $d.connectAnim)
                }
                if let a = d.previewAnim, let make = MiscHooks.connectAnimPreview {
                    make(a).frame(maxWidth: .infinity).padding(.bottom, 10)
                }
                MiscRule()
                MiscField(label: "Refresh the file list",
                          hint: "Also how often the browser follows the terminal\u{2019}s directory. Each tick is one SFTP round trip per visible pane.") {
                    OptionPicker(options: SettingsDialog.refreshOptions, selection: $d.refreshSeconds)
                }
                MiscField(label: "Refresh the Teleport clusters",
                          hint: "Whether each certificate is still valid, and one `tsh ls` per live cluster. "
                            + "Paused while the window is hidden, and only redrawn when a node, an address, "
                            + "a label or a cluster’s expiry has actually changed.") {
                    OptionPicker(options: SettingsDialog.nodeRefreshOptions, selection: $d.nodeRefreshSeconds)
                }
                MiscField(label: "Hosts listed per group in the sidebar",
                          hint: "Past this many the list stops and says how many it is holding back — and that row "
                            + "opens the same hosts in a pane, which has the room for them. A filter is exempt: "
                            + "you asked a specific question, so you get the whole answer.") {
                    OptionPicker(options: SettingsDialog.hostLimitOptions, selection: $d.sidebarHostLimit)
                }
                MiscField(label: "Warn about nodes that have gone quiet",
                          hint: "A node stays in the inventory for ten or fifteen minutes after its agent stops "
                            + "heartbeating, offering to connect the whole time. Past this much silence its row "
                            + "is marked, and the tooltip says how long it has left before the cluster drops it.") {
                    OptionPicker(options: SettingsDialog.staleOptions, selection: $d.staleNodeMinutes)
                }
                MiscRule()
                MiscField(label: "MFA method for per-session-MFA nodes",
                          hint: "Automatic can pick a method that fails in a spawned process and consumes the challenge; naming one avoids that.") {
                    OptionPicker(options: SettingsDialog.mfaOptions, selection: $d.mfaMode)
                }
                MiscRule()
                MiscField(label: "X11 forwarding (default for new sessions)") {
                    OptionPicker(options: SettingsDialog.x11Options, selection: $d.x11)
                }
                let x = SettingsDialog.x11Status()
                MiscHint(text: x.available ? "X server detected (DISPLAY=\(x.display ?? ""))." : x.hint,
                         color: x.available ? p.muted : p.amber)
                    .padding(.top, -6)
                MiscRule()
                toggles
                MiscRule()
                MiscCheck(label: "Highlight keywords in terminal output", isOn: $d.highlight)
                Button("Edit the highlights…") { Actions.shared.perform("highlights") }
                    .buttonStyle(.ghostSmall).padding(.top, -2)
                MiscHint(text: "Off unless you ask for it: colour in a terminal belongs to the program. Switched on, the "
                         + "built-in rules cover errors, warnings and good news; more can be added here or for one "
                         + "host, and each session has its own toggle beside its search box.")
                    .padding(.top, 6)
                MiscRule().padding(.top, 10)
                MiscField(label: "Automatically starred here",
                          hint: "One folder per line, `~` for your home directory. They appear in the starred list of every "
                            + "local file pane. Anything that is not there is skipped, and any one of them can be hidden "
                            + "from its own menu.") {
                    LinesEditor(text: $d.autoLocal, rows: 4)
                }
                MiscField(label: "Automatically starred on servers",
                          hint: "The same for a server. A `~/name` entry only appears on hosts that actually have that "
                            + "folder — checked once per connection — so a cloud instance is not offered a Desktop.") {
                    LinesEditor(text: $d.autoHost, rows: 5)
                }
                MiscRule()
                MiscField(label: "Starred hosts",
                          hint: "A star keeps a host where you can find it. Either it sorts to the top of its own cluster, "
                            + "or every starred host is gathered into one group. Hosts can also be dragged into the "
                            + "order you want within a group.") {
                    OptionPicker(options: SettingsDialog.starredOptions, selection: $d.starredMode)
                }
                MiscRule()
                MiscCheck(label: "Forward the ssh agent by default (-A)", isOn: $d.agent)
                MiscHint(text: "Agent forwarding lets processes on the far host use the keys in your agent while the session "
                         + "is open \u{2014} what a jump host needs, and what a shared box should not have. A cluster or a "
                         + "single host can override this from its menu in the host list.")
                    .padding(.top, -3)
                MiscRule().padding(.top, 10)
                Button("SSH config files…") { Actions.shared.perform("ssh-config-files") }.buttonStyle(.ghostSmall)
                MiscHint(text: "Read hosts from more than one OpenSSH config file. Each extra file gets its own group in the "
                         + "host list, and its hosts are opened with ssh -F so that file\u{2019}s own settings apply.")
                    .padding(.top, 6)
                MiscRule().padding(.top, 10)
                MiscField(label: "Editor for remote files",
                          hint: "Left blank, a remote file opens in whatever this machine opens that file type with. "
                            + "Name a command — code -w, subl -w, mate — to use one editor for all of them. "
                            + "Every save goes back to the server until you stop the edit.") {
                    TextField("code -w", text: $d.editor).textFieldStyle(.roundedBorder)
                }
                MiscRule()
                ToolsLine()
            }
        } footer: {
            Button("Cancel") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") {
                d.save(WindowManager.shared.model(for: handle.window))
                handle.close()
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var toggles: some View {
        MiscCheck(label: "Follow the terminal’s working directory in the file browser", isOn: $d.follow)
        MiscCheck(label: "Show hidden files", isOn: $d.hidden)
        MiscCheck(label: "Show permissions and owner in file lists", isOn: $d.details)
        MiscCheck(label: "Folders before files in file lists", isOn: $d.foldersFirst)
        MiscCheck(label: "3D view button in the file browser", isOn: $d.show3d)
        MiscCheck(label: "Blinking cursor", isOn: $d.blink)
        MiscCheck(label: "Name the shell in a local tab\u{2019}s title", isOn: $d.shellTitle)
        MiscCheck(label: "Network tools icon on every session header", isOn: $d.netIcon)
        MiscCheck(label: "Show what each tab is doing (output, and waiting for an answer)", isOn: $d.tabActivity,
                  note: "Three bars ripple beside the tab while output is arriving, and the tab turns amber "
                    + "when the session is waiting on something — a password, a yes/no, or a coding agent "
                    + "asking permission. Never on the tab you are looking at: you can already see it.")
        MiscCheck(label: "Ask before opening a link clicked in a terminal", isOn: $d.linkAsk,
                  note: "The question shows the whole address and names the host it would open, so a link "
                    + "that reads one way and goes another is visible before the browser starts. "
                    + "Right-click a link for Open link and Copy link — copying works even when the "
                    + "URL wrapped over several rows.")
        MiscCheck(label: "Ask before quitting with remote sessions open", isOn: $d.quitAsk,
                  note: "Servers, consoles, VNC and tmux count, across every window; local shells do not. "
                    + "The question lists what would be disconnected.")
        MiscCheck(label: "Ask before closing a tab or pane with a live session", isOn: $d.closeAsk)
        MiscCheck(label: "Open every new session in tmux", isOn: $d.tmuxDefault,
                  note: "What runs inside tmux keeps running when the window goes away — a dropped "
                    + "connection, a closed laptop, a restarted app — and reattaching brings back the "
                    + "scrollback with it. The host needs tmux installed; nothing is needed here. "
                    + "Individual hosts and clusters can say otherwise from their own menu.")
        MiscField(label: "tmux session name") {
            TextField("serverlife", text: $d.tmuxName).textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 280).padding(.leading, 22).padding(.top, -3)
        MiscCheck(label: "Open the requestable-resource monitor when the app starts", isOn: $d.reqPane,
                  note: "Off by default: the pane floats above the app, and it has nothing urgent to say most "
                    + "mornings. The monitoring itself runs either way, and the count appears on the Teleport "
                    + "tab and on a cluster\u{2019}s heading — Teleport \u{2192} Monitor Requestable Resources\u{2026} opens it.")
        WatchRow(d: d)
    }
}

/// Theme, with the named themes grouped by tone.
private struct ThemePicker: View {
    @Binding var selection: String
    var body: some View {
        Picker("", selection: $selection) {
            Text("Automatic (follow system)").tag("auto")
            Text("macOS (system colours, follows light/dark)").tag("system")
            Text("Dark").tag("dark")
            Text("Light").tag("light")
            Section("Dark themes") {
                ForEach(MiscThemes.appThemes.filter { $0.tone == "dark" }, id: \.id) { Text($0.label).tag($0.id) }
            }
            Section("Light themes") {
                ForEach(MiscThemes.appThemes.filter { $0.tone == "light" }, id: \.id) { Text($0.label).tag($0.id) }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }
}

/// ui.js `select(options, value)`.
struct OptionPicker: View {
    let options: [SettingsDialog.Option]
    @Binding var selection: String
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }
}

private struct NumberField: View {
    @Binding var text: String
    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
    }
}

private struct LinesEditor: View {
    @Binding var text: String
    let rows: Int
    var body: some View {
        let p = Theme.shared.p
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: CGFloat(rows) * 17 + 10)
            .background(RoundedRectangle(cornerRadius: 5).fill(p.bg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
            .autocorrectionDisabled()
    }
}

private struct WatchRow: View {
    @ObservedObject var d: SettingsDraft
    var body: some View {
        let n = d.watchCount
        let gone = d.watchMissing
        VStack(alignment: .leading, spacing: 0) {
            MiscCheck(label: "Bell on hosts watched for disappearance", isOn: $d.watchMark,
                      note: n > 0
                        ? "\(n) host\(n == 1 ? "" : "s") watched\(gone > 0 ? ", \(gone) currently missing" : "")."
                        : "Nothing is being watched yet — the mark is on a host’s right-click menu.")
            if n > 0 {
                Button("Stop watching all \(n)") {
                    Task { @MainActor in
                        let go = await MiscUI.confirm(title: "Stop watching \(n) host\(n == 1 ? "" : "s")?",
                                                      message: "The records kept of them go too.",
                                                      detail: "Any that are currently shown as gone disappear from the list with them.",
                                                      confirmLabel: "Stop watching")
                        if go {
                            SettingsDialog.apply(["watchedHosts": .object([:])])
                            d.objectWillChange.send()
                        }
                    }
                }
                .buttonStyle(.ghostSmall)
                .padding(.leading, 22).padding(.top, -3).padding(.bottom, 8)
            }
        }
    }
}

private struct AutomationBox: View {
    @ObservedObject var d: SettingsDraft
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 0) {
            if d.control == nil {
                MiscHint(text: "Reading…", size: 11.5)
            } else if d.control?.isNull == true {
                MiscHint(text: "Local automation is not available in this build.", color: p.textDim, size: 11.5)
            } else if let c = d.control {
                Toggle(isOn: Binding(get: { c["enabled"].truthy }, set: { d.setControl($0) })) {
                    Text("Allow local automation (MCP)").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                MiscHint(text: "A program on this machine can then list hosts, open sessions, load layouts and run your saved macros. "
                         + "It cannot run arbitrary commands. Every call is shown in the status bar.",
                         color: p.textDim, size: 11.5)
                    .padding(.top, 6)
                if c["enabled"].truthy {
                    codeBox(Text("socket  ").foregroundColor(p.textDim) + Text(c["socketPath"].string ?? "")
                            + Text("\n") + Text("token   ").foregroundColor(p.textDim) + Text(c["tokenFile"].string ?? ""))
                    HStack(spacing: 6) {
                        Button("Copy claude mcp add") { d.copy("mcp") }.buttonStyle(.ghostSmall)
                            .help("Register this app with Claude Code")
                        Button("Copy bridge path") { d.copy("bridge") }.buttonStyle(.ghostSmall)
                        Button("New token") { d.rotateToken() }
                            .buttonStyle(GhostButtonStyle(small: true, destructive: true))
                            .help("Anything currently authorised loses access")
                    }
                    .padding(.top, 8)
                    codeBox(Text(c["mcpCommand"].string ?? ""))
                }
            }
        }
    }

    private func codeBox(_ t: Text) -> some View {
        let p = Theme.shared.p
        return t.font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(p.text)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.panel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            .padding(.top, 8)
    }
}

private struct HomesList: View {
    @ObservedObject var d: SettingsDraft
    let window: WindowModel?
    var body: some View {
        let p = Theme.shared.p
        VStack(alignment: .leading, spacing: 4) {
            if d.tshHomes.isEmpty {
                MiscHint(text: "Just the default — \(d.defaultHome). Add a directory to read more than one.")
                    .padding(.vertical, 2)
            }
            ForEach(Array(d.tshHomes.enumerated()), id: \.offset) { i, home in
                HStack(spacing: 4) {
                    Text(home).font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                        .help(home)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("▲") { d.moveHome(i, by: -1) }.buttonStyle(.icon).disabled(i == 0)
                        .help("Earlier — owns a cluster both homes hold")
                    Button("▼") { d.moveHome(i, by: 1) }.buttonStyle(.icon).disabled(i == d.tshHomes.count - 1)
                        .help("Later")
                    Button("×") { d.tshHomes.remove(at: i) }.buttonStyle(.icon).help("Remove")
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.borderSoft))
            }
            FlowButtons {
                Button("Add a directory…") { Task { await d.addHomeDirectories() } }.buttonStyle(.ghostSmall)
                Button("Add the default (~/.tsh)") { d.addDefaultHome() }.buttonStyle(.ghostSmall)
                    .help("Name the default explicitly, so its place in the order is yours to set")
                Button("Locate tsh / ssh…") { Task { await SettingsDialog.locateTools(window) } }.buttonStyle(.ghostSmall)
                    .help("Point the app at the tsh and ssh binaries, if they are somewhere unusual")
                Button("Check what they hold") { Task { await d.checkHomes() } }.buttonStyle(.ghostSmall)
            }
            .padding(.top, 4)
        }
    }
}

/// A row of small buttons.
private struct FlowButtons<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 6) { content() }
    }
}

/// The last line: which tsh, and which version of it.
private struct ToolsLine: View {
    var body: some View {
        let info = MiscAppInfo.shared
        let tsh = Tools.tshStatus
        let path = (tsh["found"].bool == true ? tsh["path"].string : nil) ?? "not found"
        let ver = info.tshVersion.map { " (v\($0))" } ?? ""
        let ssh = Tools.sshStatus
        let sshPath = (ssh["found"].bool == true ? ssh["path"].string : nil) ?? "not found"
        VStack(alignment: .leading, spacing: 2) {
            MiscHint(text: "tsh: \(path)\(ver)")
            MiscHint(text: "ssh: \(sshPath)")
        }
    }
}

private struct LocateToolsView: View {
    let done: ((String, String)?) -> Void
    @StateObject private var tsh: Local<String>
    @StateObject private var ssh: Local<String>

    init(tsh: String, ssh: String, done: @escaping ((String, String)?) -> Void) {
        _tsh = StateObject(wrappedValue: Local(tsh))
        _ssh = StateObject(wrappedValue: Local(ssh))
        self.done = done
    }

    private func report(_ st: JSON, _ label: String) -> String {
        st["found"].bool == true
            ? "Currently using: \(st["path"].string ?? "")"
            : "\(label) not found. Looked in:\n" + st["searched"].stringArray.joined(separator: "\n")
    }

    private func browse(_ into: Local<String>) {
        Task { @MainActor in
            if let f = await Modal.openFiles(nil, multiple: false).first { into.value = f.path }
        }
    }

    var body: some View {
        let tshSt = Tools.tshStatus, sshSt = Tools.sshStatus
        DialogScaffold(title: "Command-line tools", subtitle: "Where tsh and ssh are on this machine") {
            VStack(alignment: .leading, spacing: 0) {
                MiscField(label: "Path to tsh",
                          hint: "Everything Teleport is read through this. Leave blank to search the usual locations again.") {
                    TextField(tshSt["path"].string ?? "/usr/local/bin/tsh", text: $tsh.value).textFieldStyle(.roundedBorder)
                }
                Button("Browse…") { browse(tsh) }.buttonStyle(.ghostSmall).padding(.bottom, 6)
                MiscHint(text: report(tshSt, "tsh"))
                MiscRule().padding(.top, 10)
                MiscField(label: "Path to ssh",
                          hint: "Used for plain SSH hosts and for Teleport nodes over the shared connection.") {
                    TextField(sshSt["path"].string ?? "/usr/bin/ssh", text: $ssh.value).textFieldStyle(.roundedBorder)
                }
                Button("Browse…") { browse(ssh) }.buttonStyle(.ghostSmall).padding(.bottom, 6)
                MiscHint(text: report(sshSt, "ssh"))
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Save") { done((tsh.value.trimmed, ssh.value.trimmed)) }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
