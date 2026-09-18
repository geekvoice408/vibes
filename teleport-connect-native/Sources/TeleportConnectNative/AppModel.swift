import AppKit
import Foundation
import SwiftUI
import TshdKit
import TshdProto

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

    var subtitle: String {
        [typeLabel, description].filter { !$0.isEmpty }.joined(separator: " · ")
    }
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

@MainActor
@Observable
final class AppModel {
    enum ConnectionState {
        case starting
        case ready
        case failed(String)
    }

    var connectionState: ConnectionState = .starting
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
    }

    var loginState: LoginState = .idle
    var loginUsername = ""
    var loginPassword = ""
    var loginOTP = ""
    var passwordlessState: PasswordlessState = .waitingForTap
    var passwordlessPIN = ""
    private var passwordlessPINResponder: (@Sendable (String) -> Void)?
    private var passwordlessCredentialResponder: (@Sendable (Int) -> Void)?

    // Mirrors FilterPanel.tsx / ResourceTab.tsx / UnifiedResources.tsx local view state.
    var resourceViewMode: ResourceViewMode = .grid
    var resourceTab: ResourceTabKind = .all
    var selectedKindFilters: Set<ResourceKind> = []
    var sortField: SortField = .name
    var sortAscending = true
    var pinnedResourceIDs: Set<String> = []
    var hoveredResourceID: String?

    var terminalTabs: [TerminalTab] = []
    var selectedTab: TabID = .resources

    var visibleResources: [ResourceRow] {
        var rows = resources
        if resourceTab == .pinned {
            rows = rows.filter { pinnedResourceIDs.contains($0.id) }
        }
        if !selectedKindFilters.isEmpty {
            rows = rows.filter { selectedKindFilters.contains($0.kind) }
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

    private var tshd: TshdProcess?
    private var client: TshdClient?
    private var connectionTask: Task<Void, Never>?

    func start() async {
        let process = TshdProcess()
        tshd = process
        do {
            try await process.start()
            let client = try TshdClient(socketPath: process.socketPath)
            self.client = client

            connectionTask = Task { try? await client.run() }

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
        let tab = TerminalTab(
            title: "\(login)@\(hostname)",
            executable: tshPath,
            args: ["--proxy=\(proxyHost)", "ssh", "\(login)@\(hostname)"]
        )
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
    func openConfigFile() {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TeleportConnectNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let configFile = supportDir.appendingPathComponent("config.yaml")
        if !FileManager.default.fileExists(atPath: configFile.path) {
            let placeholder = "# TeleportConnectNative has no configurable settings yet.\n"
            try? placeholder.write(to: configFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(configFile)
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

    /// Mirrors loginSso() in useClusterLogin.ts — the RPC blocks until tshd's own browser-based
    /// SSO flow completes (tshd opens the browser itself; we don't).
    func loginWithSSO(clusterURI: String, provider: AuthProviderRow) async {
        guard let client else { return }
        loginState = .waitingForBrowser
        do {
            try await client.loginSSO(clusterURI: clusterURI, providerType: provider.type, providerName: provider.name)
            await finishLogin(clusterURI: clusterURI)
        } catch {
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
            await finishLogin(clusterURI: clusterURI)
        } catch {
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
            let iconName = (boardInfo.lowercased().contains("raspberry") || boardInfo.lowercased().contains("rasberry"))
                ? "raspberrypi"
                : "server"
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
                iconName: iconName
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
                iconName: GuessAppIcon.forDatabase(protocol: database.protocol)
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
                iconName: "kube"
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
                )
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
                iconName: "windows"
            )
        }
    }
}
