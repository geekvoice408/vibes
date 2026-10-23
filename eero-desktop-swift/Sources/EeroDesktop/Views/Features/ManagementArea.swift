#if os(macOS)
import SwiftUI
import EeroCore

/// Pages implemented by the Windows `ManagementFeatures.cs`.
enum ManagementArea: FeatureArea {
    static let routes: Set<String> = [
        "Home/Internet",
        "Activity/Data usage",
        "Activity/Security activity",
        "Settings/User permissions",
        "Settings/Software updates",
        "Settings/Notifications",
        "Settings/Troubleshooting",
        "Settings/Account settings",
        "Settings/Account settings/Subscriptions",
        "Settings/Connected services",
        "Settings/Network management",
        "Settings/Advanced networking/Internet backup",
        "Settings/Advanced networking/Multi-WAN",
        "Settings/About",
        "Help/Service availability",
        "Help",
    ]

    static func handles(_ route: String) -> Bool { routes.contains(route) }
    static func load(_ route: String, model: AppModel) async throws -> JSON? { try await FeatureLoads.load(route, model: model) }
    static func previewData(_ route: String) -> JSON? { FeatureLoads.previewData(route) }
    static func view(_ route: String, model: AppModel) -> AnyView { AnyView(ManagementPage(route: route, model: model)) }
}

@MainActor
struct ManagementPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        FeatureRoutePage(route: route, model: model) { data in
            page(data)
        }
    }

    @ViewBuilder private func page(_ data: JSON) -> some View {
        switch route {
        case "Home/Internet": InternetPage(route: route, model: model, history: data)
        case "Activity/Data usage": DataUsagePage(route: route, model: model, data: data)
        case "Activity/Security activity": InsightsPage(route: route, model: model, data: data)
        case "Settings/User permissions": PermissionsPage(route: route, model: model, data: data)
        case "Settings/Software updates": UpdatesPage(route: route, model: model, data: data)
        case "Settings/Notifications": NotificationsPage(route: route, model: model, data: data)
        case "Settings/Troubleshooting": TroubleshootingPage(route: route, model: model)
        case "Settings/Account settings": AccountPage(route: route, model: model)
        case "Settings/Account settings/Subscriptions": SubscriptionPage(route: route, model: model)
        case "Settings/Connected services": ConnectedPage(route: route, model: model, data: data)
        case "Settings/Network management": NetworkManagementPage(route: route, model: model)
        case "Settings/Advanced networking/Internet backup": BackupPage(route: route, model: model, data: data)
        case "Settings/Advanced networking/Multi-WAN": MultiWanPage(route: route, model: model, data: data)
        case "Settings/About": AboutPage(route: route, model: model)
        case "Help/Service availability": PlatformPage(route: route)
        case "Help": HelpPage(route: route, model: model)
        default: EmptyView()
        }
    }
}

// MARK: - Internet

@MainActor
struct InternetPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let history: JSON

    var body: some View {
        FeatureSub("Internet", route: route)
        ObjectCards(.obj(
            ("health", model.network["health"]), ("gateway_ip", model.network["gateway_ip"]),
            ("internet_provider", model.network["isp"]), ("last_speed_measurement", model.network["speed"])))
        FeatureActionRow {
            Button("Run speed test") { model.perform { try await model.startSpeedTest() } }
            FeatureSectionButton("Internet connection", "Settings/Advanced networking/Internet connection", model: model)
            FeatureSectionButton("Internet backup", "Settings/Advanced networking/Internet backup", model: model)
            FeatureSectionButton("Multi-WAN", "Settings/Advanced networking/Multi-WAN", model: model)
        }
        ObjectCards(history, "Speed test history")
    }
}

// MARK: - Activity

@MainActor
struct DataUsagePage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        let days = FeatureLoads.usageDays
        FeatureSub("Data usage over the last \(days) days. History availability depends on your plan.", route: route)
        FeatureActionRow {
            Button("Devices & profiles breakdown") {
                model.perform {
                    model.info("Usage breakdown", try await model.read(try model.featureURL("data_usage/breakdown?") + FeatureLoads.statsRange(days: FeatureLoads.usageDays)))
                }
            }
            Button("Choose date range") { chooseRange() }
            Button("Data usage notifications") { model.perform { try await reportSettings() } }
        }
        ActivitySeriesCharts(data: data, bytes: true)
        Button("Measurement details") { model.info("Network usage", data) }
    }

    private func chooseRange() {
        let current = FeatureLoads.usageDays == 1 ? "1 day" : "\(FeatureLoads.usageDays) days"
        let route = self.route, model = self.model
        model.edit("Data usage range", [Field("days", "Period", current, .choice, "1 day", "7 days", "30 days")], submit: "Load") { v in
            FeatureLoads.usageDays = Int(v["days"].split(separator: " ").first.map(String.init) ?? "") ?? 7
            model.featureData[route] = try await model.read(try model.featureURL("data_usage?") + FeatureLoads.statsRange(days: FeatureLoads.usageDays) + "&cadence=daily")
        }
    }

    private func reportSettings() async throws {
        let model = self.model
        let settings = try await model.read(try model.featureURL("data_usage/report_settings"))
        model.edit("Data usage reports", [Field("cadence", "Report frequency", settings.s("cadence") == "monthly" ? "Monthly" : "Weekly", .choice, "Weekly", "Monthly")]) { v in
            let weekly = v["cadence"] == "Weekly"
            try await model.change("PUT", try model.featureURL("data_usage/report_settings"),
                                   .obj(("cadence", weekly ? "weekly" : "monthly"), ("notification_day", weekly ? 1 : 31)),
                                   message: "Data usage report frequency updated.")
        }
    }
}

@MainActor
struct InsightsPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        FeatureSub("Security activity over the last seven days. Requires the corresponding eero subscription.", route: route)
        FeatureActionRow {
            Button("By device") {
                model.perform { model.info("Security by device", try await model.read(try model.featureURL("insights/devices?") + FeatureLoads.statsRange())) }
            }
            Button("By profile") {
                model.perform { model.info("Security by profile", try await model.read(try model.featureURL("insights/profiles?") + FeatureLoads.statsRange())) }
            }
        }
        ActivitySeriesCharts(data: data, bytes: false)
        Button("Activity details") { model.info("Security activity", data) }
    }
}

// MARK: - Software updates

@MainActor
struct UpdatesPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        FeatureSub("Software updates", route: route)
        ObjectCards(data)
        Button("Install available update") {
            let model = self.model, data = self.data
            model.perform {
                if !data.b("can_update_now") { throw EeroError.operation("eero has not reported an update that can be installed now.") }
                if !(await model.confirm("Install the available eero software update? Your network will restart during installation.")) { return }
                try await model.change("POST", try model.netResource("updates"), .string(""), message: "Software update requested. Installation can take several minutes.")
            }
        }
        .disabled(!data.b("can_update_now"))
        Button("Preferred update hour") { model.runLocal { try preferredHour() } }
        FeatureNote("The app requests firmware installation from eero. It does not bypass rollout eligibility or supply its own firmware.")
    }

    private func preferredHour() throws {
        let model = self.model
        model.edit("Preferred update hour", [Field("hour", "Hour in network timezone (0–23)", data.s("preferred_update_hour"))]) { v in
            guard let n = Int(v["hour"].trimmingCharacters(in: .whitespaces)), (0...23).contains(n) else {
                throw EeroError.argument("Enter an hour between 0 and 23.")
            }
            try await model.change("POST", try model.netResource("updates") + "/preferred_update_hour", .obj(("preferred_update_hour", n)),
                                   message: "Preferred update hour updated.")
        }
    }
}

// MARK: - Notifications

@MainActor
struct NotificationsPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        FeatureSub("Notifications", route: route)
        ObjectCards(data, "Network preferences")
        FeatureActionRow {
            Button("Edit network notifications") {
                model.runLocal { try ManagementArea.editReturnedBooleans(model, "Network notifications", data, try model.featureURL("notifications")) }
            }
            Button("Notification history") {
                model.perform { model.info("Notification history", try await model.read(try model.featureURL("notifications_history?limit=50"))) }
            }
            Button("Mark notifications read") {
                model.perform { try await model.change("POST", try model.featureURL("notifications/mark_read"), nil, message: "Notifications marked read.") }
            }
            Button("Account offline notifications") {
                model.runLocal { try ManagementArea.editReturnedBooleans(model, "Offline notifications", model.account["push_settings"], "/2.2/account/push_settings") }
            }
        }
        FeatureSectionButton("Mac notifications & startup", "Settings/Notifications/Windows notifications", model: model)
        FeatureNote("macOS alerts check eero notification history while the app is running. Enable background mode to keep receiving alerts after closing the main window.")
    }
}

extension ManagementArea {
    /// Port of `EditReturnedBooleans`: edits every boolean flag the API returned.
    @MainActor
    static func editReturnedBooleans(_ model: AppModel, _ title: String, _ data: JSON, _ url: String) throws {
        guard let map = data.object else { throw EeroError.operation("eero did not return editable settings.") }
        let fields = map.keys.sorted().compactMap { key -> Field? in
            guard case .bool(let b) = map[key] ?? .null else { return nil }
            return Field(key, FeatureText.human(key), b, .bool)
        }
        if fields.isEmpty { throw EeroError.operation("No editable notification flags were returned.") }
        model.edit(title, fields) { v in
            var body = JSON.object([:])
            for f in fields { body[f.key] = .bool(v.flag(f.key)) }
            try await model.change("PUT", url, body, message: "Notification preferences updated.")
        }
    }
}

// MARK: - Troubleshooting

@MainActor
struct TroubleshootingPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let networkId = FeatureLoads.escape(model.networkId)
        FeatureSub("Troubleshooting", route: route)
        FeatureCatalogLinks(parent: route, model: model, explanation: false)
        FeatureActionRow {
            Button("Check cloud connection") {
                model.perform { try await model.api.checkConnection(); model.setNotice("Secure connection to eero verified.") }
            }
            Button("Network diagnostics") {
                model.perform { model.info("Network diagnostics", try await model.read(try model.netResource("diagnostics"))) }
            }
            Button("Run network diagnostics") {
                model.perform {
                    if model.preview { throw EeroError.operation("Sign in to run diagnostics.") }
                    try await model.api.send("POST", try model.netResource("diagnostics"))
                    model.setNotice("Diagnostics requested. Open Network diagnostics shortly to review the results.")
                }
            }
            Button("Network scan") {
                model.perform { model.info("Network scan", try await model.read(try model.featureURL("network_scan"))) }
            }
        }
        FeatureActionRow {
            Button("Coverage scan") {
                model.perform { model.info("Coverage scan", try await model.read("/2.4/networks/" + networkId + "/placement/wifi_coverage_scan?allDevices=true")) }
            }
            Button("eero upgrade report") {
                model.perform { model.info("Upgrade report", try await model.read("/2.4/networks/" + networkId + "/placement/wifi_generation_scan?allDevices=true")) }
            }
            FeatureSectionButton("Legacy device compatibility", "Settings/Advanced networking/Wireless settings", model: model)
        }
        Button("Official troubleshooting articles") { model.runLocal { try model.official("https://www.eero.com/support") } }
    }
}

// MARK: - Help, About and service availability

@MainActor
struct HelpPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        FeatureSub("Help & support", route: route)
        FeatureActionRow {
            Button("Official eero support") { model.runLocal { try model.official("https://www.eero.com/support") } }
            FeatureSectionButton("Troubleshooting", "Settings/Troubleshooting", model: model)
            FeatureSectionButton("Feature availability", "Settings/About", model: model)
            FeatureSectionButton("Service availability", "Help/Service availability", model: model)
        }
        if !model.preview {
            Button("Account support details") {
                model.perform { model.info("eero support", try await model.read("/2.2/account/eero_support")) }
            }
        }
        FeatureActionRow {
            Button("Chat with eero") { model.runLocal { try openChat(history: false) } }
            Button("Support history") { model.runLocal { try openChat(history: true) } }
        }
        FeatureSectionButton("Contact support", "Help/Contact support", model: model)
        FeatureNote("Chat availability depends on your eero account. eero's assistant and a human support conversation are separate services.")
    }

    /// Port of `OpenChat`: chat runs on its own page in this client.
    private func openChat(history: Bool) throws {
        if (model.networkURL ?? "").isEmpty { throw EeroError.operation("Select a network before opening chat or its support history.") }
        model.navigate(history ? "Help/Support history" : "Home/Chat")
    }
}

@MainActor
struct AboutPage: View {
    let route: String
    @ObservedObject var model: AppModel

    private var groups: [(root: String, lines: [String])] {
        var out: [(root: String, lines: [String])] = []
        for entry in FeatureCatalog.entries where !entry.parent.isEmpty {
            let root = FeatureCatalog.root(entry.path)
            let line = entry.path.replacingOccurrences(of: "/", with: " › ") + " — " + entry.description
            if let i = out.firstIndex(where: { $0.root == root }) { out[i].lines.append(line) } else { out.append((root, [line])) }
        }
        return out
    }

    var body: some View {
        FeatureSub("eero Desktop v1.0 · Independent macOS client", route: route)
        Text("Made by: Carlos B. (Los33)").font(.system(size: 16, weight: .semibold))
        FeatureCard {
            Text("A native macOS application for managing your eero network. Availability depends on your network's hardware, firmware, account role and subscription.")
                .font(.system(size: 14))
        }
        FeatureSectionButton("Service availability", "Help/Service availability", model: model)
        ForEach(groups, id: \.root) { group in
            FeatureHeading(group.root)
            ForEach(group.lines, id: \.self) { line in FeatureNote(line) }
        }
        FeatureNote("QR code generation uses Apple Core Image. Product-image sources and software licenses are listed in THIRD-PARTY-NOTICES.txt.", size: 12)
    }
}

/// Port of `PlatformPage` ("Help/Service availability").
struct PlatformPage: View {
    let route: String

    static let items: [(String, String)] = [
        ("Bluetooth setup and gateway replacement",
         "Discover nearby eeros, run placement checks, or create a wired DHCP network from Add or replace eero. Full Bluetooth provisioning and the gateway replacement wizard are not available in this client."),
        ("Billing and sign-in",
         "Subscription management, payment methods, purchase history and business billing open their official service pages. Benefits are refreshed from eero. Purchases made through another billing provider remain managed by that provider. Amazon sign-in opens Amazon’s secure page and requires an existing eero account using that Amazon login. It does not require a developer account or Business subscription."),
        ("Guardian VPN",
         "Mac registration, locations, device removal and connect/disconnect controls are grouped under Security & privacy > VPN. macOS asks you to approve the VPN configuration before it is installed. Connection is reported verified only after a fresh Guardian handshake; failed startup attempts remove the tunnel. Live subscription eligibility and tunnel operation still require account testing."),
        ("Chat and background delivery",
         "Chat, history, recommendations and human support depend on your eero account. Review requested network changes before approving them. Alexa opens as a separate web service. macOS alerts check notification history while the app is running, including in background mode."),
        ("Business, ISP, cellular and accessory provisioning",
         "Portal settings/uploads, eero Insight handoff, license activation, existing-network PPPoE/VLAN, accessory details/removal, cellular status and phone-line associations are implemented. Initial PPPoE/static bootstrap, cellular activation and physical accessory pairing still require the provider setup flow."),
    ]

    var body: some View {
        FeatureSub("Availability depends on your account, hardware, and service provider.", route: route)
        ForEach(PlatformPage.items, id: \.0) { item in
            FeatureCard {
                Text(item.0).font(.system(size: 19, weight: .semibold))
                FeatureNote(item.1, size: 14)
            }
        }
    }
}
#endif
