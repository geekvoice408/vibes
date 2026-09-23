import AppKit
import Foundation
import SwiftUI
import TshdKit
import TshdProto
import UniformTypeIdentifiers

struct ClusterRow: Identifiable, Hashable {
    let uri: String
    let name: String
    let connected: Bool
    let proxyHost: String
    /// Only populated after GetCluster (ListRootClusters doesn't include it).
    let loggedInUserName: String?
    let roles: [String]

    var id: String { uri }

    init(uri: String, name: String, connected: Bool, proxyHost: String, loggedInUserName: String? = nil, roles: [String] = []) {
        self.uri = uri
        self.name = name
        self.connected = connected
        self.proxyHost = proxyHost
        self.loggedInUserName = loggedInUserName
        self.roles = roles
    }
}

enum ResourceKind: String, CaseIterable {
    case server, database, kube, app, windowsDesktop

    /// Mirrors getFilterKindName() in UnifiedResources.tsx.
    var filterLabel: String {
        switch self {
        case .server: "Servers"
        case .database: "Databases"
        case .kube: "Kubernetes"
        case .app: "Applications"
        case .windowsDesktop: "Desktops"
        }
    }
}

struct ResourceRow: Identifiable {
    let id: String
    let kind: ResourceKind
    let name: String
    /// Mirrors cardViewProps.primaryDesc (the resource's type, e.g. "SSH Server").
    let typeLabel: String
    /// Mirrors cardViewProps.secondaryDesc (address/URL/etc).
    let description: String
    let labels: [String]
    let logins: [String]
    let launchURL: URL?
    let isSAMLApp: Bool
    /// Key into resourceIconSpecs (ResourceIconSpecs.generated.swift), computed via GuessAppIcon.
    let iconName: String
    /// Only meaningful for .database/.kube — TargetHealth.status ("", "unknown", "healthy",
    /// "unhealthy"). Mirrors shared/components/UnifiedResources/shared/StatusInfo.tsx.
    let healthStatus: String
    let healthMessage: String
    let healthError: String

    var subtitle: String {
        [typeLabel, description].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Mirrors shouldWarnResourceStatus() — only "unhealthy" gets the warning badge; "unknown"
    /// (no health checks configured/run yet) is informational, not a problem to flag.
    var hasHealthWarning: Bool { healthStatus == "unhealthy" }
}

enum ResourceViewMode { case grid, list }
enum ResourceTabKind { case all, pinned }
enum SortField: String { case name = "Name", kind = "Type" }

struct AuthProviderRow: Identifiable, Hashable {
    let type: String
    let name: String
    let displayName: String
    var id: String { "\(type):\(name)" }
}

/// Mirrors useClusterLogin.ts's state machine (initAttempt/loginAttempt/ssoPrompt), simplified:
/// local vs SSO choice is one screen instead of two views.
enum LoginState: Equatable {
    case idle
    case loadingProviders
    case choosingProvider(clusterURI: String, providers: [AuthProviderRow], localAuthEnabled: Bool, allowPasswordless: Bool)
    case passwordless
    case waitingForBrowser
    case syncing
    case failed(String)
}

/// Mirrors the PasswordlessLoginState machine in useClusterLogin.ts (the `ssoPrompt`-style
/// state driven by TshdClient.PasswordlessEvent).
enum PasswordlessState: Equatable {
    case waitingForTap
    case waitingForRetap
    case enteringPIN
    case choosingCredential([String])
}

/// Driven by TshdEventsServer's promptMFA handler — tshd calls back into us mid-Login when the
/// cluster requires a second factor (e.g. per-session MFA on a local-auth login), which a plain
/// unary RPC can't do on its own. See tshd_events_service.proto's PromptMFA doc comment.
enum MFAPromptState: Equatable {
    case none
    case waitingForWebAuthnTap
    case enteringTOTP
}

/// Mirrors TabHost's documents: the always-present Resources tab (doc.cluster) plus any number
/// of terminal tabs (doc.terminal_tsh_node for SSH sessions, doc.terminal_shell for a local
/// shell), each backed by a real PTY via TerminalHostView/SwiftTerm.
enum TabID: Hashable {
    case resources
    case terminal(UUID)
}

struct TerminalTab: Identifiable {
    let id = UUID()
    let title: String
    let executable: String
    let args: [String]
}

enum BrowserChoice: String, CaseIterable, Identifiable {
    case systemDefault, safari, chrome

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemDefault: "System Default"
        case .safari: "Safari"
        case .chrome: "Chrome"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .systemDefault: nil
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum ConnectionState {
        case starting
        case ready
        case failed(String)
    }

    var connectionState: ConnectionState = .starting
    var showSettings = false
    var browserChoice: BrowserChoice = .systemDefault

    func setBrowserChoice(_ choice: BrowserChoice) {
        browserChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "browserChoice")
    }
    private let customIconStore = CustomIconStore()
    /// Lowercased resource name -> absolute file path. Loaded once at start(); see CustomIconStore.
    var customIcons: [String: String] = [:]

    private let appConfigStore = AppConfigStore()
    var appConfig = AppConfig()

    /// Persists appConfig and applies whatever can take effect immediately (theme). Settings
    /// that affect the tshd daemon's own launch flags (sshAgent.addKeysToAgent,
    /// hardwareKeyAgent.enabled) need a restart to apply — tshd is already running.
    func saveAppConfig() {
        appConfigStore.save(appConfig)
        switch appConfig.theme {
        case "light": colorSchemeOverride = .light
        case "dark": colorSchemeOverride = .dark
        default: colorSchemeOverride = nil
        }
    }
    var clusters: [ClusterRow] = []
    var selectedClusterURI: String?
    var resources: [ResourceRow] = []
    var resourcesLoading = false
    var resourcesError: String?
    var statusMessage: String?

    /// UI-only state hoisted here instead of `@State` — this SDK's SwiftUI ships the
    /// `SwiftUIMacros` plugin (backing `@State`/`@Binding`) only inside Xcode.app, which
    /// isn't installed on this machine (Command Line Tools only), so `@State` can't compile
    /// via `swift build`. `@Observable` itself works fine since it's backed by the
    /// open-source `ObservationMacros` plugin, which ships with the toolchain.
    var showClusterPicker = false
    var showConnectionsMenu = false
    var showAddClusterField = false
    var addClusterAddress = ""
    var showAccessRequestsTopBarInfo = false
    var showAccessRequestsFilterInfo = false
    var showHealthStatusFilterInfo = false
    var expandedRolesClusterURIs: Set<String> = []

    /// nil = follow the OS setting. Applied via .preferredColorScheme in App.swift.
    var colorSchemeOverride: ColorScheme?

    func cycleColorScheme() {
        switch colorSchemeOverride {
        case nil: colorSchemeOverride = .light
        case .light: colorSchemeOverride = .dark
        case .dark: colorSchemeOverride = nil
        @unknown default: colorSchemeOverride = nil
        }
        appConfig.theme = colorSchemeOverride == .light ? "light" : colorSchemeOverride == .dark ? "dark" : "system"
        appConfigStore.save(appConfig)
    }

    var loginState: LoginState = .idle
    var loginUsername = ""
    var loginPassword = ""
    var loginOTP = ""
    var passwordlessState: PasswordlessState = .waitingForTap
    var passwordlessPIN = ""
    private var passwordlessPINResponder: (@Sendable (String) -> Void)?
    var mfaPromptState: MFAPromptState = .none
    var mfaTOTPCode = ""
    private var mfaTOTPResponder: (@Sendable (String) -> Void)?
    private var passwordlessCredentialResponder: (@Sendable (Int) -> Void)?

    /// Set once tshd's SSO redirect URL is captured from its stderr — see
    /// TshdProcess.awaitSSOLoginURL. Non-nil while an in-app SSO browser window should be shown.
    var ssoBrowserURL: URL?
    /// Tracks the in-app browser's live location so "Open in Browser" hands off from wherever
    /// the user currently is in the flow, not back to square one — some providers' advanced
    /// 2FA (passkeys/Touch ID needing real app entitlements we don't have as an ad-hoc build;
    /// phone+Bluetooth QR pairing needing Web Bluetooth, which WebKit doesn't implement at all)
    /// simply cannot complete inside any embedded WebView and need a real browser to finish in.
    var ssoBrowserCurrentURL: URL?

    func openSSOInSystemBrowser() {
        guard let url = ssoBrowserCurrentURL ?? ssoBrowserURL else { return }
        openInBrowserOfChoice(url)
        statusMessage = "Opened sign-in in your browser — this window will finish automatically once you complete it there."
    }

    /// Opens `url` using browserChoice's app if available, falling back to the system default
    /// (whatever's set in System Settings) if that browser isn't installed.
    func openInBrowserOfChoice(_ url: URL) {
        if let bundleID = browserChoice.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // Mirrors FilterPanel.tsx / ResourceTab.tsx / UnifiedResources.tsx local view state.
    var resourceViewMode: ResourceViewMode = .grid
    var resourceTab: ResourceTabKind = .all
    var selectedKindFilters: Set<ResourceKind> = []
    /// "healthy" | "unhealthy" | "unknown" — mirrors resourceStatusOptions in FilterPanel.tsx.
    var selectedHealthStatuses: Set<String> = []
    var sortField: SortField = .name
    var sortAscending = true
    var pinnedResourceIDs: Set<String> = []
    var hoveredResourceID: String?
    var showingHealthInfoForResourceID: String?

    var terminalTabs: [TerminalTab] = []
    var selectedTab: TabID = .resources

    /// Mirrors resourceStatusFilterSupported() in FilterPanel.tsx — health data only exists
    /// for db/kube, so the filter only makes sense when the type filter isn't excluding both.
    var isHealthStatusFilterSupported: Bool {
        selectedKindFilters.isEmpty || selectedKindFilters.contains(.database) || selectedKindFilters.contains(.kube)
    }

    var visibleResources: [ResourceRow] {
        var rows = resources
        if resourceTab == .pinned {
            rows = rows.filter { pinnedResourceIDs.contains($0.id) }
        }
        if !selectedKindFilters.isEmpty {
            rows = rows.filter { selectedKindFilters.contains($0.kind) }
        }
        if !selectedHealthStatuses.isEmpty {
            rows = rows.filter { row in
                (row.kind == .database || row.kind == .kube) && selectedHealthStatuses.contains(row.healthStatus)
            }
        }
        rows.sort { a, b in
            let ordered: Bool
            switch sortField {
            case .name: ordered = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .kind: ordered = a.kind.filterLabel.localizedCaseInsensitiveCompare(b.kind.filterLabel) == .orderedAscending
            }
            return sortAscending ? ordered : !ordered
        }
        return rows
    }

    func togglePinned(_ id: String) {
        if pinnedResourceIDs.contains(id) {
            pinnedResourceIDs.remove(id)
        } else {
            pinnedResourceIDs.insert(id)
        }
    }

    /// Opens a file picker for an SVG/PNG/JPEG icon and, if the user picks one, assigns it to
    /// every resource named `resourceName` (matches how every other icon override in this app
    /// is keyed) and persists it via CustomIconStore.
    func pickCustomIcon(forResourceName resourceName: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose an Icon"
        panel.message = "Pick an SVG, PNG, or JPEG to use for \"\(resourceName)\"."
        panel.allowedContentTypes = [.svg, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let path = customIconStore.setIcon(forResourceName: resourceName, sourceFile: url) else {
            statusMessage = "Couldn't set that icon for \(resourceName)."
            return
        }
        customIcons[resourceName.lowercased()] = path
        statusMessage = "Set a custom icon for \(resourceName)."
    }

    func removeCustomIcon(forResourceName resourceName: String) {
        let key = resourceName.lowercased()
        if let path = customIcons[key] {
            ResourceIconCache.shared.invalidate(path: path)
        }
        customIconStore.removeIcon(forResourceName: resourceName)
        customIcons.removeValue(forKey: key)
    }

    private var tshd: TshdProcess?
    private var client: TshdClient?
    private var connectionTask: Task<Void, Never>?
    private var eventsServerTask: Task<Void, Never>?

    func start() async {
        browserChoice = BrowserChoice(rawValue: UserDefaults.standard.string(forKey: "browserChoice") ?? "") ?? .systemDefault
        customIcons = customIconStore.loadMapping()
        appConfig = appConfigStore.load()
        switch appConfig.theme {
        case "light": colorSchemeOverride = .light
        case "dark": colorSchemeOverride = .dark
        default: colorSchemeOverride = nil
        }

        let process = TshdProcess()
        tshd = process
        do {
            try await process.start(
                addKeysToAgent: appConfig.sshAgentAddKeysToAgent,
                hardwareKeyAgentEnabled: appConfig.hardwareKeyAgentEnabled
            )
            let client = try TshdClient(socketPath: process.socketPath)
            self.client = client

            connectionTask = Task { try? await client.run() }

            // Must happen before any other TerminalService RPC (service.proto's doc comment on
            // UpdateTshdEventsServerAddress) — tshd needs somewhere to call back into for MFA
            // prompts, relogin, etc. before it'll do anything else with us.
            let eventsServer = TshdEventsServer(socketPath: process.eventsSocketPath, model: self)
            eventsServerTask = try await eventsServer.start()
            try await client.updateTshdEventsServerAddress("unix://\(process.eventsSocketPath)")

            let response = try await client.listRootClusters()
            clusters = response.clusters.map {
                ClusterRow(uri: $0.uri, name: $0.name, connected: $0.connected, proxyHost: $0.proxyHost)
            }
            connectionState = .ready

            for cluster in clusters where cluster.connected {
                await refreshClusterDetails(cluster.uri)
            }

            if let first = clusters.first(where: { $0.connected }) ?? clusters.first {
                await selectCluster(first.uri)
            }
        } catch {
            connectionState = .failed(String(describing: error))
        }
    }

    func selectCluster(_ uri: String) async {
        selectedClusterURI = uri
        guard let client else { return }
        resourcesLoading = true
        resourcesError = nil
        do {
            let response = try await client.listUnifiedResources(clusterURI: uri)
            resources = response.resources.compactMap(Self.row(from:))
        } catch {
            resourcesError = String(describing: error)
        }
        resourcesLoading = false
    }

    func refreshSelectedCluster() async {
        guard let uri = selectedClusterURI else { return }
        await selectCluster(uri)
    }

    /// Mirrors connectToServer() in documentsService/connectToServer.ts — until Phase C wires up
    /// an embedded terminal, we hand the same `tsh ssh` invocation Connect would run to Terminal.app.
    /// Mirrors connectToServer() in documentsService/connectToServer.ts: opens a new terminal
    /// document titled "login@hostname" running `tsh ssh`. Unlike Electron (node-pty), the PTY
    /// here comes from SwiftTerm's LocalProcessTerminalView — see TerminalHostView.
    func connectToServer(login: String, row: ResourceRow, clusterURI: String) {
        guard let proxyHost = clusters.first(where: { $0.uri == clusterURI })?.proxyHost,
              let tshPath = TshdProcess.locateBinary() else { return }
        let hostname = row.name
        var args = ["--proxy=\(proxyHost)", "ssh"]
        if appConfig.sshForwardAgent { args.append("--forward-agent") }
        if appConfig.sshNoResume { args.append("--no-resume") }
        args.append("\(login)@\(hostname)")
        let tab = TerminalTab(title: "\(login)@\(hostname)", executable: tshPath, args: args)
        terminalTabs.append(tab)
        selectedTab = .terminal(tab.id)
    }

    /// Mirrors the "Open new terminal" action in TopBar/AdditionalActions.tsx (doc.terminal_shell).
    func openLocalShellTab() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let tab = TerminalTab(title: "Terminal", executable: shell, args: ["-l"])
        terminalTabs.append(tab)
        selectedTab = .terminal(tab.id)
    }

    /// Mirrors "Open config file" in AdditionalActions.tsx — Connect has app_config.yaml;
    /// this app doesn't have a config file yet, so creates a minimal placeholder one on first
    /// use and opens it in the default editor, rather than silently doing nothing.
    /// Mirrors "Open config file" in AdditionalActions.tsx — opens the real app_config.json
    /// (same filename Connect itself uses, per main.ts, though this is our own app's copy).
    /// Editing it directly and relaunching picks up changes; the Preferences window
    /// (Cmd+,) is the same data, just with a UI instead of hand-editing JSON.
    func openConfigFile() {
        appConfigStore.save(appConfig) // make sure what's on disk matches what's currently loaded
        NSWorkspace.shared.open(appConfigStore.fileURL)
    }

    /// Mirrors "Install/Remove tsh in PATH" in AdditionalActions.tsx — Connect bundles its own
    /// tsh and symlinks it into PATH. This app doesn't bundle one; it drives whatever tsh is
    /// already installed, so there's no separate copy of our own to install/remove — report
    /// the real status instead of pretending to do something there's nothing to do.
    func reportTshPathStatus() {
        if let path = TshdProcess.locateBinary() {
            statusMessage = "tsh is already on your PATH at \(path) — nothing for this app to install."
        } else {
            statusMessage = "No tsh binary found. Install Teleport (e.g. `brew install teleport`) first."
        }
    }

    /// Mirrors "Check for updates..." — this is a locally built dev binary, not something
    /// distributed through Connect's auto-update channel, so there's nothing to check.
    func checkForUpdates() {
        statusMessage = "This is a locally-built development build — no update channel is configured."
    }

    func closeTerminalTab(_ id: UUID) {
        terminalTabs.removeAll { $0.id == id }
        if selectedTab == .terminal(id) {
            selectedTab = .resources
        }
    }

    /// Mirrors useClusterLogin's `init()`: fetch auth settings, then either go straight to SSO
    /// (single provider, no local auth) or let the user choose (ClusterLogin.tsx's behavior).
    func startLogin(clusterURI: String) async {
        guard let client else { return }
        loginState = .loadingProviders
        do {
            let settings = try await client.getAuthSettings(clusterURI: clusterURI)
            let providers = settings.authProviders.map {
                AuthProviderRow(
                    type: $0.type,
                    name: $0.name,
                    displayName: $0.displayName.isEmpty ? $0.name : $0.displayName
                )
            }
            if providers.count == 1, !settings.localAuthEnabled {
                await loginWithSSO(clusterURI: clusterURI, provider: providers[0])
            } else {
                if settings.localAuthEnabled, let saved = KeychainCredentialStore.load(clusterURI: clusterURI) {
                    loginUsername = saved.username
                    loginPassword = saved.password
                }
                loginState = .choosingProvider(
                    clusterURI: clusterURI,
                    providers: providers,
                    localAuthEnabled: settings.localAuthEnabled,
                    allowPasswordless: settings.allowPasswordless
                )
            }
        } catch {
            loginState = .failed(String(describing: error))
        }
    }

    /// Mirrors loginSso() in useClusterLogin.ts, except the browser step happens in an embedded
    /// WKWebView instead of the system browser: tshd is spawned with a shadowed `open` command
    /// (see TshdProcess.init) so its own browser-launch attempt silently no-ops, and we race a
    /// scan of its stderr for the clickable SSO URL it always prints regardless (see
    /// TshdProcess.awaitSSOLoginURL) against the blocking Login RPC.
    func loginWithSSO(clusterURI: String, provider: AuthProviderRow) async {
        guard let client, let tshd else { return }
        loginState = .waitingForBrowser
        ssoBrowserURL = nil; ssoBrowserCurrentURL = nil
        let urlWatcher = Task {
            if let url = await tshd.awaitSSOLoginURL() {
                self.ssoBrowserURL = url
            }
        }
        do {
            try await client.loginSSO(clusterURI: clusterURI, providerType: provider.type, providerName: provider.name)
            urlWatcher.cancel()
            ssoBrowserURL = nil; ssoBrowserCurrentURL = nil
            await finishLogin(clusterURI: clusterURI)
        } catch {
            urlWatcher.cancel()
            ssoBrowserURL = nil; ssoBrowserCurrentURL = nil
            loginState = .failed(String(describing: error))
        }
    }

    /// Mirrors loginPasswordless() in useClusterLogin.ts: drives the bidirectional
    /// LoginPasswordless RPC, updating passwordlessState as tshd's own WebAuthn library
    /// reports tap/PIN/credential-selection prompts.
    func loginWithPasswordless(clusterURI: String) {
        guard let client else { return }
        loginState = .passwordless
        passwordlessState = .waitingForTap
        passwordlessPIN = ""
        Task {
            do {
                try await client.loginPasswordless(clusterURI: clusterURI) { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        switch event {
                        case .tap:
                            self.passwordlessState = .waitingForTap
                        case .retap:
                            self.passwordlessState = .waitingForRetap
                        case .pin(let respond):
                            self.passwordlessPINResponder = respond
                            self.passwordlessState = .enteringPIN
                        case .credentials(let usernames, let respond):
                            self.passwordlessCredentialResponder = respond
                            self.passwordlessState = .choosingCredential(usernames)
                        }
                    }
                }
                await finishLogin(clusterURI: clusterURI)
            } catch {
                loginState = .failed(String(describing: error))
            }
        }
    }

    func submitPasswordlessPIN() {
        passwordlessPINResponder?(passwordlessPIN)
        passwordlessPINResponder = nil
        passwordlessPIN = ""
    }

    func selectPasswordlessCredential(index: Int) {
        passwordlessCredentialResponder?(index)
        passwordlessCredentialResponder = nil
    }

    /// Called from TshdEventsServer's promptMFA handler when the cluster wants WebAuthn/Touch ID.
    /// tshd performs the actual system prompt itself once we've acknowledged; we just show a
    /// waiting state while that happens.
    func beginMFAWebAuthnWait() {
        mfaPromptState = .waitingForWebAuthnTap
    }

    /// Called from TshdEventsServer's promptMFA handler when TOTP is the (only) offered method.
    /// `respond` resumes the gRPC handler that's blocked waiting for this — call it exactly once.
    func beginMFATOTPPrompt(respond: @Sendable @escaping (String) -> Void) {
        mfaTOTPResponder = respond
        mfaPromptState = .enteringTOTP
    }

    func submitMFATOTP() {
        mfaTOTPResponder?(mfaTOTPCode)
        mfaTOTPResponder = nil
        mfaTOTPCode = ""
        mfaPromptState = .none
    }

    private func clearMFAPrompt() {
        // Resume any pending TOTP wait with an empty code rather than leaving tshd's promptMFA
        // call hanging until it times out on its own.
        mfaTOTPResponder?("")
        mfaTOTPResponder = nil
        mfaTOTPCode = ""
        mfaPromptState = .none
    }

    /// Mirrors loginLocal() in useClusterLogin.ts.
    func loginWithLocalCredentials(clusterURI: String) async {
        guard let client else { return }
        loginState = .syncing
        do {
            try await client.loginLocal(
                clusterURI: clusterURI,
                username: loginUsername,
                password: loginPassword,
                otpToken: loginOTP
            )
            KeychainCredentialStore.save(clusterURI: clusterURI, username: loginUsername, password: loginPassword)
            clearMFAPrompt()
            await finishLogin(clusterURI: clusterURI)
        } catch {
            clearMFAPrompt()
            loginState = .failed(String(describing: error))
        }
    }

    func cancelLogin() {
        loginState = .idle
        loginUsername = ""
        loginPassword = ""
        loginOTP = ""
        passwordlessPIN = ""
        passwordlessPINResponder = nil
        passwordlessCredentialResponder = nil
        ssoBrowserURL = nil; ssoBrowserCurrentURL = nil
        clearMFAPrompt()
    }

    /// Mirrors syncAndWatchRootClusterWithErrorHandling — refreshes the cluster's connected
    /// status and re-loads its resource list now that we have valid credentials.
    private func finishLogin(clusterURI: String) async {
        loginState = .syncing
        await refreshClusterDetails(clusterURI)
        loginUsername = ""
        loginPassword = ""
        loginOTP = ""
        loginState = .idle
        await selectCluster(clusterURI)
    }

    /// Fetches LoggedInUser (name + roles) via GetCluster, which ListRootClusters omits, and
    /// merges it into the matching ClusterRow — powers the Identity menu's "Roles (N)" line.
    private func refreshClusterDetails(_ clusterURI: String) async {
        guard let client, let updated = try? await client.getCluster(clusterURI: clusterURI),
              let index = clusters.firstIndex(where: { $0.uri == clusterURI }) else { return }
        clusters[index] = ClusterRow(
            uri: updated.uri,
            name: updated.name,
            connected: updated.connected,
            proxyHost: updated.proxyHost,
            loggedInUserName: updated.hasLoggedInUser ? updated.loggedInUser.name : nil,
            roles: updated.hasLoggedInUser ? updated.loggedInUser.roles : []
        )
    }

    /// Mirrors logout() in useIdentity.ts / IdentityContainer's logout action.
    func logoutCluster(_ clusterURI: String) async {
        guard let client else { return }
        do {
            try await client.logout(clusterURI: clusterURI)
        } catch {
            statusMessage = "Couldn't log out: \(error)"
            return
        }
        if let index = clusters.firstIndex(where: { $0.uri == clusterURI }) {
            let old = clusters[index]
            clusters[index] = ClusterRow(uri: old.uri, name: old.name, connected: false, proxyHost: old.proxyHost)
        }
        if selectedClusterURI == clusterURI {
            resources = []
        }
        statusMessage = "Logged out of \(clusters.first { $0.uri == clusterURI }?.name ?? clusterURI)"
    }

    /// Mirrors addCluster() in useIdentity.ts ("Add Cluster..." row) — registers a new proxy
    /// address with tshd, then immediately starts the login flow for it.
    func addCluster(proxyAddress: String) async {
        guard let client else { return }
        do {
            let cluster = try await client.addCluster(proxyAddress: proxyAddress)
            clusters.append(ClusterRow(uri: cluster.uri, name: cluster.name, connected: cluster.connected, proxyHost: cluster.proxyHost))
            showClusterPicker = false
            await startLogin(clusterURI: cluster.uri)
        } catch {
            loginState = .failed(String(describing: error))
        }
    }

    func stop() async {
        connectionTask?.cancel()
        client?.shutdown()
        await tshd?.stop()
    }

    private static func row(from resource: Teleport_Lib_Teleterm_V1_PaginatedResource) -> ResourceRow? {
        guard let oneOf = resource.resource else { return nil }
        switch oneOf {
        case .server(let server):
            let boardInfo = server.labels.first { $0.name.caseInsensitiveCompare("board_info") == .orderedSame }?.value ?? ""
            let cloudLabel = server.labels.first { $0.name.caseInsensitiveCompare("cloud") == .orderedSame }?.value ?? ""
            let hasWorkToolsLabel = server.labels.contains {
                $0.name.caseInsensitiveCompare("work-tools") == .orderedSame
                    || $0.value.caseInsensitiveCompare("work-tools") == .orderedSame
            }
            let iconName: String
            if boardInfo.lowercased().contains("raspberry") || boardInfo.lowercased().contains("rasberry") {
                iconName = "raspberrypi"
            } else if cloudLabel.caseInsensitiveCompare("aws") == .orderedSame {
                // Reuses Teleport's own bundled "ec2" icon (the AWS logo) rather than a new one.
                iconName = "ec2"
            } else if hasWorkToolsLabel {
                iconName = "worktools"
            } else if resourceIconSpecs[server.hostname.lowercased()] != nil {
                // Direct name match (e.g. a server named after something with a registered
                // icon, real brand or custom) — same idea as guessAppIcon's direct lookup step.
                iconName = server.hostname.lowercased()
            } else {
                iconName = "server"
            }
            return ResourceRow(
                id: server.uri,
                kind: .server,
                name: server.hostname,
                typeLabel: "SSH Server",
                description: server.addr,
                labels: server.labels.map { "\($0.name): \($0.value)" },
                logins: server.logins,
                launchURL: nil,
                isSAMLApp: false,
                iconName: iconName,
                healthStatus: "", healthMessage: "", healthError: ""
            )
        case .database(let database):
            return ResourceRow(
                id: database.uri,
                kind: .database,
                name: database.name,
                typeLabel: database.protocol,
                description: database.desc,
                labels: database.labels.map { "\($0.name): \($0.value)" },
                logins: [],
                launchURL: nil,
                isSAMLApp: false,
                iconName: GuessAppIcon.forDatabase(protocol: database.protocol),
                healthStatus: database.hasTargetHealth ? database.targetHealth.status : "",
                healthMessage: database.hasTargetHealth ? database.targetHealth.message : "",
                healthError: database.hasTargetHealth ? database.targetHealth.error : ""
            )
        case .kube(let kube):
            return ResourceRow(
                id: kube.uri,
                kind: .kube,
                name: kube.name,
                typeLabel: "Kubernetes cluster",
                description: "",
                labels: kube.labels.map { "\($0.name): \($0.value)" },
                logins: [],
                launchURL: nil,
                isSAMLApp: false,
                iconName: "kube",
                healthStatus: kube.hasTargetHealth ? kube.targetHealth.status : "",
                healthMessage: kube.hasTargetHealth ? kube.targetHealth.message : "",
                healthError: kube.hasTargetHealth ? kube.targetHealth.error : ""
            )
        case .app(let app):
            var url: URL?
            if !app.publicAddr.isEmpty {
                url = URL(string: "https://\(app.publicAddr)")
            } else if !app.endpointUri.isEmpty {
                url = URL(string: app.endpointUri)
            }
            let iconLabel = app.labels.first { $0.name == "teleport.icon" }?.value
            return ResourceRow(
                id: app.uri,
                kind: .app,
                name: app.name,
                typeLabel: app.samlApp ? "SAML Application" : "Application",
                description: app.desc,
                labels: app.labels.map { "\($0.name): \($0.value)" },
                logins: [],
                launchURL: url,
                isSAMLApp: app.samlApp,
                iconName: GuessAppIcon.forApp(
                    name: app.name,
                    friendlyName: app.friendlyName,
                    awsConsole: app.awsConsole,
                    teleportIconLabel: iconLabel
                ),
                healthStatus: "", healthMessage: "", healthError: ""
            )
        case .windowsDesktop(let desktop):
            return ResourceRow(
                id: desktop.uri,
                kind: .windowsDesktop,
                name: desktop.name,
                typeLabel: "Windows Desktop",
                description: desktop.addr,
                labels: [],
                logins: [],
                launchURL: nil,
                isSAMLApp: false,
                iconName: "windows",
                healthStatus: "", healthMessage: "", healthError: ""
            )
        }
    }
}
