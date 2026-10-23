#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Feature-load failures by route (the `ApiException` the Windows client stored in `featureData`).
/// Only mutated on the main actor.
final class FeatureLoadErrors: ObservableObject {
    static let shared = FeatureLoadErrors()
    @Published var messages: [String: String] = [:]
}

extension AppModel {
    /// Port of `Navigate`: shows `route` immediately and, for sub-pages, loads its data.
    func navigate(_ route: String) {
        if busy { return }
        currentPage = route
        setNotice(pageStatus)
        if route.contains("/") {
            let name = (route.split(separator: "/").last.map(String.init) ?? route).lowercased()
            perform("Loading \(name)…") {
                try await self.loadFeature(route)
                if self.currentPage == route { self.setNotice(self.pageStatus) }
            }
        }
    }

    /// Port of `LoadFeature`: fetches a route's data through its `FeatureArea`. API failures other than
    /// an expired session are kept per route and shown on the page with "Try again".
    func loadFeature(_ route: String) async throws {
        if !preview { guard await api.signedIn else { return } }
        do {
            try await FeatureAreas.load(route, model: self)
            FeatureLoadErrors.shared.messages[route] = nil
        } catch let e as ApiError where !e.sessionExpired {
            FeatureLoadErrors.shared.messages[route] = e.message
        }
    }

    /// The status-bar text written after every page render.
    var pageStatus: String {
        if preview { return "Preview mode · No network requests or changes" }
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return "Updated " + f.string(from: lastRefresh) + " · Refreshes every minute while active"
    }
}

/// Signed-in window: sidebar navigation, network picker, page area and notice bar
/// (port of `NativeShell`, `UpdateNavigation`, `PageHeading` and `RenderPage`).
@MainActor
struct ShellView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var errors = FeatureLoadErrors.shared

    private struct NavItem: Identifiable { let title, route, symbol: String; var id: String { route } }
    private let primary = [
        NavItem(title: "Home", route: "Home", symbol: "house"),
        NavItem(title: "Devices", route: "Devices", symbol: "laptopcomputer.and.iphone"),
        NavItem(title: "Activity", route: "Activity", symbol: "chart.bar"),
        NavItem(title: "Settings", route: "Settings", symbol: "gearshape"),
    ]
    private let secondary = [
        NavItem(title: "Profiles", route: "Home/Profiles", symbol: "person.2"),
        NavItem(title: "Security & privacy", route: "Home/Security & privacy", symbol: "lock.shield"),
        NavItem(title: "Help & support", route: "Help", symbol: "questionmark.circle"),
    ]

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 212, max: 280)
        } detail: {
            detail
        }
        .onAppear { model.setNotice(model.pageStatus) }
        .task { await autoRefresh() }
    }

    // MARK: Sidebar

    /// The highlighted sidebar entry for the current page.
    private var selectedNav: String {
        let page = model.currentPage
        if page.hasPrefix("Home/Profiles") { return "Home/Profiles" }
        if page.hasPrefix("Home/Security & privacy") { return "Home/Security & privacy" }
        return page.split(separator: "/").first.map(String.init) ?? page
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("eero").font(.system(size: 42, weight: .light)).foregroundStyle(Palette.text)
                Text("Desktop for Mac").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .padding(.leading, 24).padding(.top, 16).padding(.bottom, 20)

            List(selection: Binding<String?>(get: { selectedNav }, set: { route in
                if let route, route != selectedNav { model.navigate(route) }
            })) {
                Section {
                    ForEach(primary) { item in Label(item.title, systemImage: item.symbol).tag(item.route) }
                }
                Section {
                    ForEach(secondary) { item in Label(item.title, systemImage: item.symbol).tag(item.route) }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 8) {
                Button { if !model.busy { model.navigate("Settings/Account settings") } } label: {
                    Label(model.preview ? "Preview account" : model.account.first("name", "email", "phone"), systemImage: "person.crop.circle")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Account settings")
                Button(model.preview ? "Back to sign in" : "Sign out") { signOut() }
                    .buttonStyle(.quiet)
                    .padding(.leading, -8)
                Text("Unofficial client · v1.0").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
            .disabled(model.busy)
        }
    }

    private func signOut() {
        if model.preview {
            AppHost.shared.leavePreview(notice: "Signed out. Your saved session has been cleared.")
            return
        }
        model.perform {
            await model.signOut()
            FeatureLoadErrors.shared.messages = [:]
            model.setNotice("Signed out. Your saved session has been cleared.")
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    page
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 24)
                .disabled(model.busy)
            }
            .id(model.currentPage) // scroll to top when the route changes
            Divider()
            Text(model.notice)
                .font(.system(size: 11))
                .foregroundStyle(model.noticeIsError ? Palette.error : Palette.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 10)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .background(Palette.page)
        .toolbar {
            ToolbarItem(placement: .navigation) { networkPicker }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { refresh() } label: { Label("Refresh network", systemImage: "arrow.clockwise") }
                    .help("Refresh network")
                Button { model.navigate("Settings/Notifications") } label: { Label("Notifications", systemImage: "bell") }
                    .help("Notifications")
                Button { model.navigate("Home/Add or replace eero") } label: { Label("Add or replace eero", systemImage: "plus") }
                    .help("Add or replace eero")
            }
        }
    }

    private var networkPicker: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi").foregroundStyle(Palette.accent)
            Picker("Selected network", selection: Binding<String>(
                get: { model.networkURL ?? "" },
                set: { selectNetwork($0) })) {
                ForEach(model.networkList.indices, id: \.self) { i in
                    let n = model.networkList[i]
                    Text(n.first("name", "url")).tag(n.s("url"))
                }
            }
            .labelsHidden()
            .frame(width: 230)
            .disabled(model.busy)
            Text(model.preview ? "Sample network" : "eero network").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private func selectNetwork(_ url: String) {
        if model.busy || url.isEmpty || url == model.networkURL { return }
        Task {
            await model.run("Loading network…") {
                model.networkURL = url
                model.network = .null; model.selectedProfile = .null; model.selectedNode = .null
                model.currentPage = "Home"
                model.devices = []; model.nodes = []; model.profiles = []; model.featureData = [:]
                FeatureLoadErrors.shared.messages = [:]
                if !model.preview { try await model.loadNetwork() }
                model.setNotice(model.pageStatus)
            }
        }
    }

    private func refresh() {
        model.perform {
            if !model.preview {
                if model.network.isNull { try await model.loadAccount() } else { try await model.loadNetwork() }
            }
            if model.currentPage.contains("/") { try await model.loadFeature(model.currentPage) }
            model.setNotice(model.pageStatus)
        }
    }

    /// Port of the 60-second `DispatcherTimer`: refreshes Home and Devices while the app is active.
    private func autoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
            guard !model.busy, !model.preview, model.screen == .shell, NSApplication.shared.isActive,
                  model.currentPage == "Home" || model.currentPage == "Devices" else { continue }
            guard await model.api.signedIn else { continue }
            await model.run("Refreshing network…") {
                try await model.loadNetwork()
                model.setNotice(model.pageStatus)
            }
        }
    }

    // MARK: Page heading and routing

    @ViewBuilder private var heading: some View {
        let route = model.currentPage
        let parts = route.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1 {
            HStack(spacing: 2) {
                ForEach(0..<(parts.count - 1), id: \.self) { i in
                    let target = parts[0...i].joined(separator: "/")
                    Button(parts[i]) { if !model.busy { model.navigate(target) } }.buttonStyle(.quiet)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.leading, -8).padding(.top, -4).padding(.bottom, 12)
        }
        PageTitle(title(for: route))
    }

    private func title(for route: String) -> String {
        var heading = route.split(separator: "/").last.map(String.init) ?? route
        if heading == "Details", !model.selectedNode.isNull { heading = model.selectedNode.first("location", "model") }
        if heading == "Profile", !model.selectedProfile.isNull { heading = model.selectedProfile.s("name") }
        return heading
    }

    @ViewBuilder private var page: some View {
        let route = model.currentPage
        if model.network.isNull && !(ExtendedArea.accountOnlyPage(route) || route == "Theme preview") {
            Card { Text("No network loaded. Refresh your account, join a network or create one using a separate eero ready for setup.").font(.system(size: 16)) }
            VStack(alignment: .leading, spacing: 8) {
                SectionLink(title: "Join a network", route: "Settings/User permissions/Join a network")
                SectionLink(title: "Pending transfers", route: "Settings/Network management/Pending transfers")
                SectionLink(title: "Create a wired network", route: "Home/Add or replace eero/Create a network")
                SectionLink(title: "Incoming access invitations", route: "Settings/User permissions/Incoming access invitations")
            }
        } else {
            switch route {
            case "Home", "Overview": OverviewView(model: model)
            case "Devices": DevicesView(model: model)
            case "eero nodes", "Home/eeros": NodesView(model: model)
            case "Profiles", "Home/Profiles": ProfilesView(model: model)
            case "Activity": ActivityView(model: model)
            case "Help": HelpView(model: model)
            case "Settings": FeatureMenuView(parent: "Settings")
            default:
                if let message = errors.messages[route] {
                    ErrorCard(message: message)
                    Caption("Availability depends on your account permissions, subscription, hardware and firmware.")
                    Button("Try again") {
                        model.perform {
                            try await model.loadFeature(route)
                            model.setNotice(model.pageStatus)
                        }
                    }
                    .padding(.vertical, 8)
                    FeatureMenuView(parent: route, explanation: false)
                } else if let area = FeatureAreas.area(for: route) {
                    area.view(route, model: model)
                } else {
                    FeatureMenuView(parent: route)
                }
            }
        }
    }
}
#endif
