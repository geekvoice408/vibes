import SwiftUI

/// Mirrors web/packages/teleterm/src/ui/TopBar/TopBar.tsx: a fixed-height bar with three
/// zones — left (Connections), center (search — the Clusters selector next to it in the real
/// app only renders when the active root cluster has leaf clusters, `Clusters.tsx:53`, which
/// this app doesn't support yet, so it's correctly absent here too), right (access-requests
/// checklist slot + menu + identity). Root-cluster switching lives in the Identity avatar's
/// menu instead (TopBar/Identity/Identity.tsx), not in the center.
struct TopBarView: View {
    let model: AppModel

    private var showIdentityMenu: Binding<Bool> {
        Binding(get: { model.showClusterPicker }, set: { model.showClusterPicker = $0 })
    }
    private var showConnectionsMenu: Binding<Bool> {
        Binding(get: { model.showConnectionsMenu }, set: { model.showConnectionsMenu = $0 })
    }

    var body: some View {
        HStack(spacing: Theme.space[3]) {
            HStack {
                Button {
                    model.showConnectionsMenu.toggle()
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Theme.textSlightlyMuted)
                }
                .buttonStyle(.plain)
                .help("Connections")
                .popover(isPresented: showConnectionsMenu) {
                    ConnectionsMenuView(model: model)
                }
                Spacer()
            }
            .frame(width: 160)

            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Text("Search resources, run commands")
                    .font(Theme.uiFontSmall)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text("⌘K")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDisabled)
            }
            .padding(.horizontal, Theme.space[2])
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiiSmall)
                    .strokeBorder(Theme.buttonBorder, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: Theme.space[2]) {
                Spacer()
                Button {
                    model.cycleColorScheme()
                } label: {
                    Image(systemName: colorSchemeIconName)
                        .foregroundStyle(Theme.textSlightlyMuted)
                }
                .buttonStyle(.plain)
                .help(colorSchemeHelpText)

                Button {
                    model.showAccessRequestsTopBarInfo.toggle()
                } label: {
                    Image(systemName: "checklist")
                        .foregroundStyle(Theme.textSlightlyMuted)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { model.showAccessRequestsTopBarInfo },
                    set: { model.showAccessRequestsTopBarInfo = $0 }
                )) {
                    Text("Access requests aren't implemented in the native app yet.")
                        .font(Theme.uiFontSmall)
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 220)
                        .padding(Theme.space[2])
                }
                Menu {
                    Button("Open New Terminal") {
                        model.openLocalShellTab()
                    }
                    Button("Open Config File") {
                        model.openConfigFile()
                    }
                    Divider()
                    Button("Install tsh in PATH") {
                        model.reportTshPathStatus()
                    }
                    Button("Remove tsh from PATH") {
                        model.reportTshPathStatus()
                    }
                    Divider()
                    Button("Check for Updates…") {
                        model.checkForUpdates()
                    }
                    Divider()
                    Button("Preferences…") {
                        model.showSettings = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSlightlyMuted)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    model.showClusterPicker.toggle()
                } label: {
                    identityAvatar
                }
                .buttonStyle(.plain)
                .popover(isPresented: showIdentityMenu) {
                    IdentityMenuView(model: model)
                }
            }
            .frame(width: 160)
        }
        .padding(.horizontal, Theme.space[3])
        .frame(height: Theme.topBarHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.levelSurface)
    }

    private var colorSchemeIconName: String {
        switch model.colorSchemeOverride {
        case nil: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        @unknown default: "circle.lefthalf.filled"
        }
    }

    private var colorSchemeHelpText: String {
        switch model.colorSchemeOverride {
        case nil: "Appearance: System (click to force Light)"
        case .light: "Appearance: Light (click to force Dark)"
        case .dark: "Appearance: Dark (click to follow System)"
        @unknown default: "Appearance"
        }
    }

    private var selectedCluster: ClusterRow? {
        model.clusters.first { $0.uri == model.selectedClusterURI }
    }

    private var identityAvatar: some View {
        Circle()
            .fill(Theme.brand)
            .frame(width: 26, height: 26)
            .overlay(
                Text(String((selectedCluster?.name.first).map(String.init) ?? "?").uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            )
    }
}

/// Mirrors TopBar/Connections/Connections.tsx: lists active connections — here, open terminal
/// sessions — with a way to jump to or close each one.
private struct ConnectionsMenuView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connections").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.space[2])
                .padding(.top, Theme.space[1])

            if model.terminalTabs.isEmpty {
                Text("No active connections")
                    .font(Theme.uiFontSmall)
                    .foregroundStyle(Theme.textMuted)
                    .padding(Theme.space[2])
            } else {
                ForEach(model.terminalTabs) { terminalTab in
                    HStack {
                        Button {
                            model.selectedTab = .terminal(terminalTab.id)
                            model.showConnectionsMenu = false
                        } label: {
                            HStack {
                                Image(systemName: "terminal").font(.system(size: 11))
                                Text(terminalTab.title).font(Theme.uiFont)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.closeTerminalTab(terminalTab.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Theme.space[2])
                    .padding(.vertical, Theme.space[1])
                }
            }
        }
        .padding(Theme.space[1])
        .frame(width: 280)
        .background(Theme.levelPopout)
    }
}

/// Mirrors TopBar/Identity/IdentityList: one card per logged-in/known root cluster (Electron
/// calls these "workspaces") — avatar, cluster name, user email, role count, refresh/logout —
/// plus a way to log in to one that isn't connected, and an "Add Cluster..." row.
private struct IdentityMenuView: View {
    let model: AppModel

    private static let avatarColors: [Color] = [.purple, .teal, .orange, .pink, .indigo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.clusters.enumerated()), id: \.element.id) { index, cluster in
                clusterCard(cluster, color: Self.avatarColors[index % Self.avatarColors.count])
                if index < model.clusters.count - 1 {
                    Divider()
                }
            }

            Divider()

            if model.showAddClusterField {
                HStack {
                    TextField("proxy.example.com", text: Binding(
                        get: { model.addClusterAddress },
                        set: { model.addClusterAddress = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await model.addCluster(proxyAddress: model.addClusterAddress) }
                    }
                    Button("Add") {
                        Task { await model.addCluster(proxyAddress: model.addClusterAddress) }
                    }
                    .disabled(model.addClusterAddress.isEmpty)
                }
                .padding(Theme.space[2])
            } else {
                Button {
                    model.showAddClusterField = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle").foregroundStyle(Theme.textMuted)
                        Text("Add Cluster…").font(Theme.uiFont)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.space[2])
                .padding(.vertical, Theme.space[2])
            }
        }
        .padding(Theme.space[1])
        .frame(width: 300)
        .background(Theme.levelPopout)
    }

    private func clusterCard(_ cluster: ClusterRow, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.space[1]) {
            HStack(alignment: .top) {
                Button {
                    Task { await model.selectCluster(cluster.uri) }
                } label: {
                    HStack(spacing: Theme.space[2]) {
                        Circle()
                            .fill(color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Text(String(cluster.name.first.map(String.init) ?? "?").uppercased())
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cluster.name).font(Theme.uiFontMedium)
                            if let user = cluster.loggedInUserName {
                                Text(user).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            } else {
                                Text("Not logged in").font(.system(size: 11)).foregroundStyle(Theme.textDisabled)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                if cluster.connected {
                    Button {
                        Task {
                            if model.selectedClusterURI == cluster.uri {
                                await model.refreshSelectedCluster()
                            } else {
                                await model.selectCluster(cluster.uri)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .help("Refresh")

                    Button {
                        Task { await model.logoutCluster(cluster.uri) }
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.interactiveDanger)
                    .help("Log Out")
                }
            }

            if cluster.connected {
                let isExpanded = model.expandedRolesClusterURIs.contains(cluster.uri)
                Button {
                    if isExpanded {
                        model.expandedRolesClusterURIs.remove(cluster.uri)
                    } else {
                        model.expandedRolesClusterURIs.insert(cluster.uri)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        Text("Roles (\(cluster.roles.count))")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.textMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(cluster.roles, id: \.self) { role in
                            Text(role)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSlightlyMuted)
                        }
                    }
                    .padding(.leading, Theme.space[3])
                }
            } else {
                Button("Log In") {
                    model.showClusterPicker = false
                    Task { await model.startLogin(clusterURI: cluster.uri) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(Theme.space[2])
    }
}
