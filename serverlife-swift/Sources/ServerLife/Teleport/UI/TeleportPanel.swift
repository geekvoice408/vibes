import AppKit
import SwiftUI

/// teleportpanel.js: everything the Teleport tab's buttons do — logging in,
/// out and between clusters, saved clusters, `tsh status`, `tsh config` into
/// ~/.ssh/config, the leaf-cluster switcher, the web UI.
///
/// Several tsh profiles can be logged in at once. Connections always carry an
/// explicit --proxy/--cluster, so which profile is "active" never changes where
/// a session goes — but switching matters for tsh commands, and assuming an
/// approved request re-issues the certificate with the extra roles.
@MainActor
enum TeleportPanel {
    // MARK: - Saved clusters

    /// `savedClusterFor`: the saved record behind a live profile — same
    /// proxy and home, the same user preferred.
    static func savedClusterFor(_ p: TeleportProfile) -> JSON? {
        if p.proxy.isEmpty { return nil }
        let same = TUIData.listTshLogins().filter {
            Teleport.proxyAddress($0["proxy"].stringish) == Teleport.proxyAddress(p.proxy)
                && ($0["home"].stringish ?? "") == (p.home ?? "")
        }
        return same.first { ($0["user"].stringish ?? "") == p.username } ?? same.first
    }

    /// `saveClusterLogin`: keep a cluster for logging in again.
    @discardableResult
    static func saveClusterLogin(_ rec: JSON) -> JSON {
        let saved = TUIData.upsertTshLogin(rec)
        TUIStatus.show("Saved \(saved["name"].stringish ?? "") for re-login")
        return saved
    }

    /// `loginFromSaved`: the login dialog filled from the record.
    static func loginFromSaved(_ t: JSON, window: WindowModel? = nil) {
        if let id = t["id"].string { TUIData.markTshLoginUsed(id) }
        openLoginDialog(LoginPrefill(record: t), window: window)
    }

    // MARK: - Login dialog

    struct LoginPrefill {
        var id: String?
        var proxy = "", user = "", cluster = "", auth = "", home = "", ttl = "", mfaMode = ""
        var autoLogin = false
        var remember = true

        init(proxy: String = "", home: String = "", user: String = "", cluster: String = "") {
            self.proxy = proxy; self.home = home; self.user = user; self.cluster = cluster
        }

        init(record t: JSON) {
            id = t["id"].string
            proxy = t["proxy"].stringish ?? ""; user = t["user"].stringish ?? ""
            cluster = t["cluster"].stringish ?? ""; auth = t["authConnector"].stringish ?? ""
            home = t["home"].stringish ?? ""; ttl = t["ttl"].stringish ?? ""
            mfaMode = t["mfaMode"].stringish ?? ""; autoLogin = t["autoLogin"].truthy
            remember = true
        }
    }

    /// `openLoginDialog(prefill)`.
    static func openLoginDialog(_ prefill: LoginPrefill = LoginPrefill(), window: WindowModel? = nil) {
        let m = LoginDialogModel(prefill)
        Task { @MainActor in
            let res: Teleport.LoginOptions? = await TUIModal.ask(window, title: "tsh login", width: 620) { finish, _ in
                LoginDialogView(m: m, finish: finish, window: window)
            }
            guard let res else { return }
            // Keep the cluster either way: a proxy typed once should not have
            // to be typed again, whichever route the login takes.
            if m.remember { saveClusterLogin(m.record()) }
            // A named user means a prompt, and a prompt needs a terminal.
            if res.user != nil {
                Inventory.shared.runLoginInTerminal(res, window: window)
                return
            }
            TUIStatus.show("Running tsh login - check your browser if SSO is configured...", ms: 0)
            let r = await Teleport.login(res)
            TUIStatus.clear()
            if !r.ok {
                // The original read a field tsh's result never had, so the
                // fixed sentence is what people saw; it still is.
                TUIStatus.toast("Login failed. Check the proxy address, or run the command in a terminal.", "error")
                return
            }
            TUIStatus.toast("Logged in to " + (res.proxy ?? ""), "success")
            await TUI.refreshInventory()
        }
    }

    // MARK: - Login, switch, logout

    /// `doLogin`: an expired profile, logged in the way it is *saved* to be.
    static func doLogin(_ p: TeleportProfile) async {
        let saved = savedClusterFor(p)
        TUIStatus.show("Logging in to \(p.proxy)… (a browser window may open)", ms: 0)
        defer { TUIStatus.clear() }
        let r = await Teleport.login(Teleport.LoginOptions(
            proxy: p.proxy, cluster: p.cluster.nilIfEmpty ?? saved?["cluster"].stringish?.nilIfEmpty,
            // Only from the record: the profile's username passed as --user
            // sends tsh down the local-auth path instead of the connector's.
            user: saved?["user"].stringish?.nilIfEmpty, authConnector: saved?["authConnector"].stringish?.nilIfEmpty,
            ttl: saved?["ttl"].stringish?.nilIfEmpty, mfaMode: saved?["mfaMode"].stringish?.nilIfEmpty, home: p.homeDir))
        if !r.ok { TUIStatus.toast("tsh login failed — try running it in a terminal", "error"); return }
        TUIStatus.toast("Logged in", "success")
        await TUI.refreshInventory()
    }

    /// `switchCluster`: point a profile at another cluster in its trust web.
    static func switchCluster(_ p: TeleportProfile, _ name: String, done: String? = nil) async {
        if name.isEmpty { return }
        TUIStatus.show("Switching to \(name)…", ms: 0)
        defer { TUIStatus.clear() }
        let r = await Teleport.switchProfile(Teleport.LoginOptions(proxy: p.proxy, cluster: name, home: p.homeDir))
        if !r.ok { TUIStatus.toast(r.output.nilIfEmpty ?? "tsh login failed", "error"); return }
        TUIStatus.toast(done ?? "Now on \(name)", "success")
        await TUI.refreshInventory()
    }

    /// `doSwitch`: the "Switch to" button.
    static func doSwitch(_ p: TeleportProfile) async {
        await switchCluster(p, p.cluster, done: "Active profile: \(p.cluster)")
    }

    /// `makeProfileActive`: the one plain `tsh` commands use, with the saved
    /// cluster's whole login command where there is one.
    static func makeProfileActive(_ p: TeleportProfile) async {
        let saved = savedClusterFor(p)
        let name = TUI.name(p)
        TUIStatus.show("Switching to \(name)…", ms: 0)
        defer { TUIStatus.clear() }
        let r = await Teleport.switchProfile(Teleport.LoginOptions(
            proxy: p.proxy, cluster: p.cluster.nilIfEmpty ?? saved?["cluster"].stringish?.nilIfEmpty,
            user: saved?["user"].stringish?.nilIfEmpty, authConnector: saved?["authConnector"].stringish?.nilIfEmpty,
            ttl: saved?["ttl"].stringish?.nilIfEmpty, mfaMode: saved?["mfaMode"].stringish?.nilIfEmpty,
            home: p.homeDir.nilIfEmpty ?? saved?["home"].stringish?.nilIfEmpty))
        if !r.ok { TUIStatus.toast(r.output.nilIfEmpty ?? "tsh login failed", "error"); return }
        TUIStatus.toast("\(name) is now the active profile", "success")
        await TUI.refreshInventory()
    }

    /// `doLogout`: one cluster's certificate, offering to keep the cluster first.
    static func doLogout(_ p: TeleportProfile, window: WindowModel? = nil) async {
        let whereName = TUI.name(p)
        let alreadySaved = TUIData.listTshLogins().contains {
            $0["proxy"].stringish == p.proxy && ($0["home"].stringish ?? "") == (p.home ?? "")
        }
        let remember = Local(!alreadySaved)
        let ok: Bool? = await TUIModal.ask(window, title: "Log out of " + whereName, width: 480) { finish, _ in
            LogoutView(p: p, whereName: whereName, alreadySaved: alreadySaved, remember: remember, finish: finish)
        }
        guard ok == true else { return }
        if !alreadySaved && remember.value {
            saveClusterLogin(["name": .string(whereName), "proxy": .string(p.proxy), "cluster": .string(p.cluster),
                              "user": .string(p.username), "home": .string(p.home ?? "")])
        }
        TUIStatus.show("Logging out of \(whereName)…", ms: 0)
        defer { TUIStatus.clear() }
        let r = await Teleport.logout(proxy: p.proxy, home: p.homeDir)
        if !r.ok { TUIStatus.toast(TUI.firstLine(r.output) ?? "tsh logout failed", "error"); return }
        TUIStatus.toast("Logged out of \(whereName)", "success")
        await TUI.refreshInventory()
    }

    /// sidebar.js `copyLoginCommand`: the `tsh login` for a profile, with the
    /// saved cluster's details and TELEPORT_HOME where it matters.
    @discardableResult
    static func copyLoginCommand(proxy: String, cluster: String = "", username: String = "", homeDir: String? = nil,
                                 home: String? = nil, user: String? = nil, authConnector: String? = nil,
                                 ttl: String? = nil) -> String {
        let probe = TeleportProfile(proxy: proxy, cluster: cluster, username: username, home: home,
                                    homeDir: homeDir ?? TeleportHomes.defaultHome)
        let saved = savedClusterFor(probe)
        let o = Teleport.LoginOptions(
            proxy: proxy, cluster: cluster.nilIfEmpty ?? saved?["cluster"].stringish?.nilIfEmpty,
            user: user ?? saved?["user"].stringish?.nilIfEmpty,
            authConnector: authConnector ?? saved?["authConnector"].stringish?.nilIfEmpty,
            ttl: ttl ?? saved?["ttl"].stringish?.nilIfEmpty, mfaMode: saved?["mfaMode"].stringish?.nilIfEmpty,
            home: homeDir?.nilIfEmpty ?? home?.nilIfEmpty)
        let cmd = Teleport.loginCommand(o)
        Clipboard.write(cmd)
        TUIStatus.show("Copied: " + cmd, ms: 8000)
        return cmd
    }

    @discardableResult
    static func copyLoginCommand(_ p: TeleportProfile) -> String {
        copyLoginCommand(proxy: p.proxy, cluster: p.cluster, username: p.username, homeDir: p.homeDir, home: p.home)
    }

    /// sidebar.js `removeExpiredProfile`: delete a dead profile's files,
    /// after naming every one of them.
    static func removeExpiredProfile(_ p: TeleportProfile, window: WindowModel? = nil) async {
        let files = Teleport.profileFiles(proxy: p.proxy, home: p.homeDir)
        let go = await MiscUI.confirm(
            window, title: "Remove \(TUI.name(p))?",
            message: files.isEmpty ? "There is nothing left of this profile to delete."
                : "This deletes \(files.count) item\(files.count == 1 ? "" : "s") from your tsh home.",
            detail: (files + ["", "The cluster stops being listed here and by tsh status. Nothing on the",
                              "cluster itself is touched, and logging in again recreates the profile."]).joined(separator: "\n"),
            confirmLabel: "Remove")
        guard go else { return }
        let r = Teleport.removeProfile(proxy: p.proxy, home: p.homeDir)
        if !r.ok { TUIStatus.toast(r.error ?? "Could not remove that profile", "error"); return }
        TUIStatus.show("Removed \(TUI.name(p))")
        await TUI.refreshInventory()
    }

    // MARK: - Web UI, cluster info

    /// `openClusterWeb`: no certificate needed, so it works on an expired
    /// profile or a saved cluster too.
    static func openClusterWeb(proxy: String?, cluster: String?) {
        do {
            let url = try Teleport.openWebCluster(proxy: proxy, cluster: cluster)
            TUIStatus.show("Opened in browser: " + url)
        } catch {
            TUIStatus.toast(error.localizedDescription, "error")
        }
    }

    /// "Cluster info": network tools' /webapi/ping view, or ours.
    static func openClusterInfo(proxy: String?, window: WindowModel? = nil) {
        if Actions.shared.isRegistered("webapi-ping") {
            var args: [String: Any] = [:]
            if let proxy { args["proxy"] = proxy }
            Actions.shared.perform("webapi-ping", window: window, args: args)
        } else {
            ClusterInfoPanel.open(proxy: proxy ?? "", window: window)
        }
    }

    // MARK: - tsh status

    /// `openClusterStatus`: `tsh status` as it prints it, under the app's own
    /// summary of the same profile.
    static func openClusterStatus(_ p: TeleportProfile, window: WindowModel? = nil) async {
        TUIStatus.show("Reading tsh status…", ms: 0)
        let info = await Teleport.statusText(proxy: p.proxy, home: p.homeDir)
        TUIStatus.clear()
        TUIModal.show(window, title: "tsh status", width: 760, height: 560, autosave: "tshstatus") { handle in
            StatusDialogView(p: p, info: info, handle: handle, window: window)
        }
    }

    // MARK: - tsh config into ~/.ssh/config

    /// `openTshConfigDialog`: `tsh config >> ~/.ssh/config`, shown before it is written.
    static func openTshConfigDialog(_ p: TeleportProfile, window: WindowModel? = nil) async {
        TUIStatus.show("Asking tsh what it would write…", ms: 0)
        let info: (text: String, state: SSHConfig.TshConfigState)
        do {
            info = try await SSHConfig.tshPreview(proxy: p.proxy, cluster: p.cluster, home: p.homeDir)
        } catch {
            TUIStatus.clear()
            TUIStatus.toast(error.localizedDescription, "error")
            return
        }
        TUIStatus.clear()
        let go: Bool? = await TUIModal.ask(window, title: "Add this cluster to ~/.ssh/config", width: 680) { finish, _ in
            TshConfigView(p: p, text: info.text, st: info.state, finish: finish)
        }
        guard go == true else { return }
        let foreign = info.state.foreign
        if !foreign.isEmpty {
            let ok = await MiscUI.confirm(
                window, title: "Add a second block for this cluster?",
                message: "\(info.state.path) already defines \(foreign.prefix(3).joined(separator: ", ")) outside this app\u{2019}s markers.",
                detail: "Both blocks will be in the file. ssh will use whichever comes first for any option they "
                    + "both set, which makes the other one silently inert. Only the new block can be replaced or "
                    + "removed by this app later.",
                confirmLabel: "Add it anyway", danger: true)
            guard ok else { return }
        }
        do {
            let r = try SSHConfig.writeTshConfig(cluster: p.cluster, proxy: p.proxy, text: info.text)
            TUIStatus.toast("\(r.replaced ? "Replaced" : "Added") \(TUI.name(p)) in \(r.path)" + (r.backup != nil ? " (backup taken)" : ""),
                            "success", ms: 8000)
            await Inventory.shared.refreshSshConfigs()
        } catch {
            TUIStatus.toast(error.localizedDescription, "error")
        }
    }

    // MARK: - Leaf clusters

    /// Past this many leaves the switcher is a searchable dialog, not a menu.
    static let leafSearchAt = 10

    static func clustersFor(_ p: TeleportProfile) -> [TeleportCluster] { Inventory.shared.clusters(for: p) }
    static func leavesFor(_ p: TeleportProfile) -> [TeleportCluster] { clustersFor(p).filter(\.leaf) }

    /// `selectedCluster`: the one the certificate points at.
    static func selectedCluster(_ p: TeleportProfile) -> TeleportCluster? {
        let list = clustersFor(p)
        return list.first { $0.selected } ?? list.first { $0.name == p.cluster }
    }

    /// `clusterLabels`: `k=v · k2=v2`, sorted.
    static func clusterLabels(_ c: TeleportCluster?) -> String {
        guard let labels = c?.labels, !labels.isEmpty else { return "" }
        return labels.keys.sorted().map { "\($0)=\(labels[$0]!)" }.joined(separator: " · ")
    }

    /// `openClusterSwitcher`: a menu at the pointer, or the searchable list.
    static func openClusterSwitcher(_ p: TeleportProfile, window: WindowModel? = nil) {
        if leavesFor(p).count > leafSearchAt { openClusterPicker(p, window: window); return }
        let items = clusterMenuItems(p)
        if items.isEmpty { return }
        CtxMenu.show(items)
    }

    /// `clusterSwitchMenuItem`: what other menus embed (the sidebar's cluster heading).
    static func clusterSwitchMenuItem(_ p: TeleportProfile, window: WindowModel? = nil) -> CtxItem? {
        let leaves = leavesFor(p)
        if leaves.isEmpty { return nil }
        if leaves.count > leafSearchAt {
            return CtxItem("Switch cluster…", title: "Search this root and its \(leaves.count) leaf clusters") {
                openClusterPicker(p, window: window)
            }
        }
        return CtxItem("Switch cluster", title: "This root and the leaf clusters it trusts", submenu: clusterMenuItems(p))
    }

    /// `clusterMenuItems`: root first, then leaves; the current one ticked
    /// and not pickable, an offline one shown and not offered.
    static func clusterMenuItems(_ p: TeleportProfile) -> [CtxItem] {
        let list = clustersFor(p)
        if list.count < 2 { return [] }
        let sel = selectedCluster(p)
        let roots = list.filter { !$0.leaf }, leaves = list.filter(\.leaf)
        func item(_ c: TeleportCluster) -> CtxItem {
            let current = sel != nil && c.name == sel!.name
            let offline = !c.status.isEmpty && c.status != "online"
            let labels = clusterLabels(c)
            let title = [current ? "Already the cluster in use"
                         : offline ? "This cluster is \(c.status) — nothing can be issued for it right now"
                         : "tsh login --proxy=\(p.proxy) \(c.name)", labels].filter { !$0.isEmpty }.joined(separator: "\n")
            return CtxItem(c.name, key: current ? "\u{2713}" : (offline ? c.status : nil), sub: labels.nilIfEmpty,
                           disabled: current || offline, title: title) {
                Task { await switchCluster(p, c.name) }
            }
        }
        return [.heading(roots.count == 1 ? "Root cluster" : "Root")] + roots.map(item)
            + [.heading("Leaf cluster\(leaves.count == 1 ? "" : "s")")] + leaves.map(item)
    }

    /// `openClusterPicker`: the searchable form, over names *and* labels.
    static func openClusterPicker(_ p: TeleportProfile, window: WindowModel? = nil) {
        let list = clustersFor(p)
        if list.count < 2 { return }
        Task { @MainActor in
            let name: String? = await TUIModal.ask(window, title: "Switch cluster", width: 520, height: 520) { finish, _ in
                ClusterPickerView(p: p, list: list, sel: selectedCluster(p), finish: finish)
            }
            if let name { await switchCluster(p, name) }
        }
    }
}

// MARK: - Login dialog

@MainActor
final class LoginDialogModel: ObservableObject {
    let prefill: TeleportPanel.LoginPrefill
    @Published var proxy: String
    @Published var user: String
    @Published var cluster: String
    @Published var auth: String
    @Published var ttl = ""
    @Published var mfa: String
    @Published var home: String
    @Published var extra = ""
    @Published var remember: Bool { didSet { if !remember { autoLogin = false } } }
    @Published var autoLogin: Bool

    /// Configured tsh homes; with none there is nothing to ask.
    let homes: [String] = Store.shared.setting("tshHomes", [String]())

    init(_ p: TeleportPanel.LoginPrefill) {
        prefill = p
        proxy = p.proxy; user = p.user; cluster = p.cluster; auth = p.auth
        mfa = p.mfaMode; remember = p.remember; autoLogin = p.autoLogin
        home = LoginDialogModel.configuredHome(p.home, in: Store.shared.setting("tshHomes", [String]()))
    }

    /// The pre-filled home as one of the configured entries, or "" (Default)
    /// when it is not one of them — a `select` given a value it has no
    /// option for falls back to its first option, and so does this.
    static func configuredHome(_ h: String, in homes: [String]) -> String {
        let want = TeleportHomes.expand(h)
        if want.isEmpty || TeleportHomes.isDefault(want) { return "" }
        return homes.first { TeleportHomes.expand($0) == want } ?? ""
    }

    /// `collectLogin()`.
    var options: Teleport.LoginOptions {
        Teleport.LoginOptions(
            proxy: Teleport.proxyAddress(proxy), cluster: cluster.trimmed.nilIfEmpty, user: user.trimmed.nilIfEmpty,
            authConnector: auth.trimmed.nilIfEmpty, ttl: ttl.trimmed.nilIfEmpty, mfaMode: mfa.nilIfEmpty,
            extraArgs: extra.trimmed.isEmpty ? [] : extra.trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init),
            home: homes.isEmpty ? nil : home.nilIfEmpty)
    }

    /// Built by the same function as the one that runs, so what is
    /// previewed, copied and run are the same string.
    var command: String { Teleport.loginCommand(options) }

    /// `collectRecord()`: the saved-cluster record these fields describe.
    func record() -> JSON {
        let v = options
        var r: JSON = [
            "name": .string(v.cluster ?? v.proxy ?? ""), "proxy": .string(v.proxy ?? ""),
            "cluster": .string(v.cluster ?? ""), "user": .string(v.user ?? ""),
            "authConnector": .string(v.authConnector ?? ""), "home": .string(v.home ?? ""),
            "ttl": .string(v.ttl ?? ""), "mfaMode": .string(v.mfaMode ?? ""), "autoLogin": .bool(autoLogin),
        ]
        if let id = prefill.id { r["id"] = .string(id) }
        return r
    }

    /// The proxy field is tidied as soon as it loses focus.
    func tidyProxy() {
        let clean = Teleport.proxyAddress(proxy)
        if clean != proxy { proxy = clean }
    }
}

private struct LoginDialogView: View {
    @ObservedObject var m: LoginDialogModel
    let finish: (Teleport.LoginOptions?) -> Void
    let window: WindowModel?
    @FocusState private var proxyFocused: Bool

    static let connectors = ["local", "passwordless", "github", "okta", "saml", "oidc", "headless", "ad"]
    static let mfaModes: [(String, String)] = [
        ("", "Automatic"), ("platform", "Platform (Touch ID / Windows Hello)"),
        ("cross-platform", "Cross-platform (security key)"), ("otp", "OTP code"), ("sso", "SSO"),
    ]

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: "tsh login", subtitle: "Opens your browser for SSO when the connector requires it") {
            VStack(alignment: .leading, spacing: 0) {
                TUIField(label: "Proxy address", hint: "Host and port of the Teleport proxy") {
                    TextField("teleport.example.com:443", text: $m.proxy)
                        .textFieldStyle(.roundedBorder).focused($proxyFocused)
                }
                HStack(alignment: .top, spacing: 12) {
                    TUIField(label: "User (optional)") {
                        TextField("optional - defaults to your local user", text: $m.user).textFieldStyle(.roundedBorder)
                    }
                    TUIField(label: "Auth connector (optional)") {
                        HStack(spacing: 4) {
                            TextField("optional - e.g. local, github, okta, saml", text: $m.auth).textFieldStyle(.roundedBorder)
                            Menu {
                                ForEach(Self.connectors, id: \.self) { c in Button(c) { m.auth = c } }
                            } label: { Image(systemName: "chevron.down") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    TUIField(label: "Cluster (optional)") {
                        TextField("optional - root cluster by default", text: $m.cluster).textFieldStyle(.roundedBorder)
                    }
                    TUIField(label: "TTL minutes (optional)") {
                        TextField("optional - minutes", text: $m.ttl).textFieldStyle(.roundedBorder)
                            .onChange(of: m.ttl) { _, v in
                                let digits = v.filter(\.isNumber)
                                if digits != v { m.ttl = digits }
                            }
                    }
                }
                TUIField(label: "MFA mode") {
                    Picker("", selection: $m.mfa) {
                        ForEach(Self.mfaModes, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().frame(maxWidth: 320, alignment: .leading)
                }
                if !m.homes.isEmpty {
                    TUIField(label: "tsh home", hint: "Where the certificate is written. Every command for this cluster will use it.") {
                        Picker("", selection: $m.home) {
                            Text("Default (\(TeleportHomes.defaultHome.tildePath))").tag("")
                            ForEach(m.homes, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: 420, alignment: .leading)
                    }
                }
                TUIField(label: "Additional flags (optional)", hint: "Passed to tsh as-is") {
                    TextField("--insecure --browser=none", text: $m.extra).textFieldStyle(.roundedBorder)
                }
                MiscCheck(label: "Keep this cluster for logging in again", isOn: $m.remember)
                MiscCheck(label: "Log in automatically when the app starts", isOn: $m.autoLogin)
                    .disabled(!m.remember).opacity(m.remember ? 1 : 0.5)
                Text("Command").font(.system(size: 11)).foregroundStyle(p.muted).padding(.top, 10).padding(.bottom, 4)
                Text(m.command)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.textDim)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Copy login cmd") {
                m.tidyProxy()
                Clipboard.write(m.command)
                TUIStatus.show("Copied — paste it into a terminal", ms: 8000)
            }.buttonStyle(.ghost)
            Button(m.prefill.id != nil ? "Save" : "Save without logging in") {
                m.tidyProxy()
                if m.proxy.isEmpty { TUIStatus.toast("Proxy address is required", "error"); return }
                TeleportPanel.saveClusterLogin(m.record())
                finish(nil)
            }.buttonStyle(.ghost).help("Keep these details for later. No tsh command is run.")
            Button("Login") {
                m.tidyProxy()
                if m.proxy.isEmpty { TUIStatus.toast("Proxy address is required", "error"); return }
                finish(m.options)
            }.buttonStyle(.primary)
        }
        .frame(width: 620)
        .onChange(of: proxyFocused) { _, focused in if !focused { m.tidyProxy() } }
        .onAppear { after(0.05) { proxyFocused = true } }
    }
}

// MARK: - Logout

private struct LogoutView: View {
    let p: TeleportProfile
    let whereName: String
    let alreadySaved: Bool
    @ObservedObject var remember: Local<Bool>
    let finish: (Bool?) -> Void

    var body: some View {
        DialogScaffold(title: "Log out of " + whereName, scroll: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Delete the certificate for \(whereName)?").font(.system(size: 13))
                MiscHint(text: [p.homeName.isEmpty ? nil : "Home: \(p.homeDir)",
                                p.username.isEmpty ? nil : "Logged in as \(p.username)",
                                "Sessions already open may stop working, and listing this cluster needs a fresh tsh login."]
                    .compactMap { $0 }.joined(separator: "\n"), size: 11.5)
                Group {
                    if alreadySaved {
                        MiscHint(text: "This cluster is already saved for re-login.", size: 11.5)
                    } else {
                        MiscCheck(label: "Keep this cluster so I can log back in", isOn: $remember.value)
                    }
                }.padding(.top, 10)
            }
        } footer: {
            Button("Cancel") { finish(false) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Log out") { finish(true) }.buttonStyle(GhostButtonStyle(destructive: true))
        }
        .frame(width: 480)
    }
}

// MARK: - tsh status

private struct StatusDialogView: View {
    let p: TeleportProfile
    let info: Teleport.StatusText
    let handle: ModalHandle
    let window: WindowModel?

    var body: some View {
        let validUntil: String = {
            guard let v = p.validUntil, let ms = TPText.parseDate(v) else { return p.validUntil ?? "" }
            return TUI.localeString(ms: ms) + (p.expired ? "  (expired)" : "")
        }()
        let rows: [(String, String)] = [
            ("cluster", p.cluster), ("proxy", p.proxy), ("logged in as", p.username),
            ("roles", p.roles.joined(separator: ", ")), ("logins", p.logins.joined(separator: ", ")),
            ("valid until", validUntil), ("tsh home", info.home), ("active", p.active ? "yes" : "no"),
        ].filter { !$0.1.isEmpty }
        DialogScaffold(title: "tsh status", subtitle: TUI.name(p), scroll: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.0) { TUIKeyValue(key: $0.0, value: $0.1) }
                Text("as tsh prints it — \(info.home)").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.shared.p.textDim).padding(.top, 10).padding(.bottom, 4)
                if !info.activeMatches {
                    MiscHint(text: "tsh leads with the active profile\(info.activeCluster.isEmpty ? "" : " (\(info.activeCluster))")"
                             + ", and lists the others after it — \(TUI.name(p)) is in there rather than at the top.", size: 11)
                        .padding(.bottom, 6)
                }
                TUIPre(text: info.text).frame(maxHeight: .infinity)
            }
        } footer: {
            Button("Cluster info…") { TeleportPanel.openClusterInfo(proxy: p.proxy, window: window) }
                .buttonStyle(.ghost).help("Version, edition, auth connector and listeners, from /webapi/ping")
            Button("Copy") { Clipboard.write(info.text); TUIStatus.show("Copied tsh status") }.buttonStyle(.ghost)
            Button("Close") { handle.close() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - tsh config

private struct TshConfigView: View {
    let p: TeleportProfile
    let text: String
    let st: SSHConfig.TshConfigState
    let finish: (Bool?) -> Void

    var body: some View {
        let pal = Theme.shared.p
        let foreign = st.foreign
        DialogScaffold(title: "Add this cluster to ~/.ssh/config", subtitle: "\(TUI.name(p)) → \(st.path)") {
            VStack(alignment: .leading, spacing: 0) {
                if !foreign.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This cluster is already in that file.").fontWeight(.semibold)
                        Text("\(st.path) already defines \(foreign.prefix(4).joined(separator: ", "))"
                             + (foreign.count > 4 ? " and \(foreign.count - 4) more" : "")
                             + " outside anything this app wrote — most likely a tsh config run by hand.")
                        Text("ssh uses the first value it finds for each option, so adding a second block for the "
                             + "same hosts leaves one of the two doing nothing while both look live. Removing the old "
                             + "block by hand first is the cleaner path.")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(pal.amber).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                } else if st.present {
                    Text("A block for \(TUI.name(p)) written by this app is already in \(st.path). Writing again replaces it in place.")
                        .font(.system(size: 11.5)).foregroundStyle(pal.amber).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                }
                MiscHint(text: "Written between markers naming this cluster, so writing it again replaces it rather than "
                         + "stacking another copy. Everything outside the markers is left alone, and the file is "
                         + "backed up first.", size: 11).padding(.bottom, 8)
                Text("tsh config").font(.system(size: 11)).foregroundStyle(pal.muted).padding(.bottom, 4)
                TUIPre(text: text, maxHeight: 240)
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button("Copy it instead") {
                Clipboard.write(text)
                TUIStatus.show("Copied — paste it into ~/.ssh/config", ms: 8000)
            }.buttonStyle(.ghost).help("Copy the block and edit the file yourself")
            Button(!foreign.isEmpty ? "Add it anyway" : (st.present ? "Replace it" : "Add it")) { finish(true) }
                .buttonStyle(GhostButtonStyle(prominent: true, destructive: !foreign.isEmpty))
        }
        .frame(width: 680)
    }
}

// MARK: - Cluster picker

private struct ClusterPickerView: View {
    let p: TeleportProfile
    let list: [TeleportCluster]
    let sel: TeleportCluster?
    let finish: (String?) -> Void
    @StateObject private var q = Local("")
    @FocusState private var focused: Bool

    private var matching: [TeleportCluster] {
        let s = q.value.trimmed.lowercased()
        if s.isEmpty { return list }
        return list.filter { ($0.name + " " + TeleportPanel.clusterLabels($0)).lowercased().contains(s) }
    }

    var body: some View {
        let pal = Theme.shared.p
        let found = matching
        // Root first whatever the query: it is the way back.
        let sorted = found.sorted { ($0.leaf ? 1 : 0, $0.name) < ($1.leaf ? 1 : 0, $1.name) }
        let leaves = list.filter(\.leaf).count
        DialogScaffold(title: "Switch cluster", subtitle: "\(TUI.name(p)) · \(leaves) leaf cluster\(leaves == 1 ? "" : "s")", scroll: false) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search name or label…", text: $q.value).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit {
                        // One match left, and it is somewhere to go: Enter takes it.
                        let go = matching.filter { $0.name != sel?.name && ($0.status.isEmpty || $0.status == "online") }
                        if go.count == 1 { finish(go[0].name) }
                    }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sorted, id: \.name) { c in
                            let current = sel != nil && c.name == sel!.name
                            let offline = !c.status.isEmpty && c.status != "online"
                            let labels = TeleportPanel.clusterLabels(c)
                            Button {
                                if current || offline { return }
                                finish(c.name)
                            } label: {
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.name).font(.system(size: 12.5))
                                        if !labels.isEmpty { Text(labels).font(.system(size: 10.5)).foregroundStyle(pal.muted) }
                                    }
                                    Spacer()
                                    TUITag(text: c.leaf ? "leaf" : "root")
                                    if offline { TUITag(text: c.status, kind: .warn) }
                                    if current { TUITag(text: "current") }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 4).fill(current ? pal.accent.opacity(0.14) : pal.panel2))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .opacity(offline && !current ? 0.5 : 1)
                            .help(offline ? "This cluster is \(c.status)" : (current ? "Already the cluster in use" : ""))
                        }
                        if found.isEmpty { TUIEmpty(lines: ["No cluster matches that."]) }
                    }
                }
                MiscHint(text: "\(found.count) of \(list.count) shown")
            }
        } footer: {
            Button("Cancel") { finish(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
        .onAppear { after(0.05) { focused = true } }
    }
}
