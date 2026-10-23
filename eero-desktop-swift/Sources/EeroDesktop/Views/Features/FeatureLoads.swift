#if os(macOS)
import Foundation
import EeroCore

/// Port of `LoadFeature` and `PreviewFeature` from the Windows `FeatureUi.cs`.
/// Every route the original route switch fetched data for is loaded here, whichever
/// area renders it, so other areas can fall back on `FeatureLoads.load` / `previewData`.
@MainActor
enum FeatureLoads {
    /// Period used by "Activity/Data usage" (`usageDays` in the Windows client).
    static var usageDays = 7

    /// Every route `load` fetches data for.
    static let routes: Set<String> = [
        "Help/Contact support",
        "Settings/Account settings/Subscriptions/Billing & status",
        "Settings/Troubleshooting/Guided diagnostics",
        "Settings/Advanced networking/Wireless settings/Fast roaming",
        "Settings/Advanced networking/Internet backup/Find backup wifi",
        "Settings/Account settings/Subscriptions/Offers & referrals",
        "Settings/User permissions/Incoming access invitations",
        "Home/Add or replace eero/Automatic setup",
        "Settings/Connected services/Accessories & cellular",
        "Home/Profiles/Profile",
        "Home/eeros/Details",
        "Settings/Network management/Pending transfers",
        "Settings/Network management/Outgoing transfer",
        "Settings/Connected services/Connected device setup",
        "Home/Security & privacy/Identity protection",
        "Settings/Advanced networking/DNS/DNS performance",
        "Devices/Blocked devices",
        "Home/Internet",
        "Home/Security & privacy",
        "Settings/Guest wifi network",
        "Settings/Advanced networking/Reservations & port forwarding",
        "Settings/Advanced networking/Thread",
        "Settings/User permissions",
        "Settings/Software updates",
        "Settings/Notifications",
        "Settings/Account settings",
        "Settings/Advanced networking/Power saving",
        "Settings/Advanced networking/Internet backup",
        "Settings/Advanced networking/Multi-WAN",
        "Activity/Data usage",
        "Activity/Security activity",
        "Activity/Network events",
        "Settings/Connected services",
        "Settings/Additional wifi networks",
        "Home/Security & privacy/Content filters",
        "Settings/Business guest wifi",
        "Settings/Advanced networking/Multiple static IPs",
    ]

    // MARK: Error marker

    /// The Windows client stored an `ApiException` in `featureData[route]` and rendered it in place of the page.
    /// Here a load failure (other than an expired session) becomes this marker object.
    static let errorKey = "__feature_error"
    static func errorMarker(_ message: String) -> JSON { .object([errorKey: .string(message)]) }
    /// The load error stored for a route, if any.
    static func error(_ data: JSON?) -> String? {
        guard let data, case .string(let m) = data[errorKey] else { return nil }
        return m
    }

    // MARK: Load

    /// Port of `LoadFeature`. Returns nil for routes it does not fetch.
    /// API failures other than an expired session are returned as an `errorMarker`.
    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        guard routes.contains(route) else { return nil }
        if model.preview { return previewData(route) }
        guard await model.api.signedIn else { return nil }
        do { return try await fetch(route, model: model) }
        catch let e as ApiError {
            if e.sessionExpired { throw e }
            return errorMarker(e.message)
        }
    }

    private static func fetch(_ route: String, model: AppModel) async throws -> JSON {
        let api = model.api
        switch route {
        case "Help/Contact support":
            return try await api.send("GET", "/2.2/account/eero_support")
        case "Settings/Account settings/Subscriptions/Billing & status":
            let data = try await api.send("GET", "/2.2/premium/customer")
            model.featureData["billing_customer"] = data
            return data
        case "Settings/Troubleshooting/Guided diagnostics":
            return try await api.send("GET", try model.netResource("diagnostics"))
        case "Settings/Advanced networking/Wireless settings/Fast roaming":
            return try await api.send("GET", try model.featureURL("fast_transition"))
        case "Settings/Advanced networking/Internet backup/Find backup wifi":
            return try await api.send("GET", try model.featureURL("backup_access_points/ssid_discovery"))
        case "Settings/Account settings/Subscriptions/Offers & referrals":
            guard let url = model.networkURL, !url.isEmpty else { return .null }
            return try await api.send("GET", "/2.4/premium/plans/" + model.networkId)
        case "Settings/User permissions/Incoming access invitations":
            return try await api.send("GET", "/2.2/incoming_member_promotions")
        case "Home/Add or replace eero/Automatic setup":
            return try await api.send("GET", try model.featureURL("auto_discovered_eeros"))
        case "Settings/Connected services/Accessories & cellular":
            return try await api.send("GET", try model.featureURL("accessories/setup/status"))
        case "Home/Profiles/Profile":
            guard !model.selectedProfile.isNull else { return .null }
            let data = try await api.send("GET", model.selectedProfile.s("url"))
            model.selectedProfile = data
            return data
        case "Home/eeros/Details":
            guard !model.selectedNode.isNull else { return .null }
            let data = try await api.send("GET", model.selectedNode.s("url"))
            model.selectedNode = data
            return data
        case "Settings/Network management/Pending transfers":
            return try await api.send("GET", "/2.2/network_transfers/pending")
        case "Settings/Network management/Outgoing transfer":
            return try await api.send("GET", try model.netResource("transfer"))
        case "Settings/Connected services/Connected device setup":
            return try await api.send("GET", try model.featureURL("simple_setup/vendors"))
        case "Home/Security & privacy/Identity protection":
            return try await api.send("GET", "/2.2/account/identity_protection")
        case "Settings/Advanced networking/DNS/DNS performance":
            guard let action = model.featureData["dns_perf_action"] else { return .null }
            return try await api.send("GET", try model.featureURL("dns_perf_test/" + (try ExtendedContracts.identifier(action.string))))
        case "Devices/Blocked devices":
            return try await api.send("GET", try model.featureURL("blacklist"))
        case "Home/Internet":
            return try await api.send("GET", try model.netResource("speedtest"))
        case "Home/Security & privacy":
            return try await api.send("GET", try model.featureURL("dns_policies/network"))
        case "Settings/Guest wifi network":
            return try await api.send("GET", try model.netResource("guestnetwork"))
        case "Settings/Advanced networking/Reservations & port forwarding":
            return try await api.send("GET", try model.netResource("routing"))
        case "Settings/Advanced networking/Thread":
            return try await api.send("GET", try model.netResource("thread"))
        case "Settings/User permissions":
            let members = try await api.send("GET", try model.featureURL("members"))
            let invites = try await api.send("GET", try model.featureURL("invites"))
            return .obj(("members", members), ("invites", invites))
        case "Settings/Software updates":
            return try await api.send("GET", try model.netResource("updates"))
        case "Settings/Notifications":
            return try await api.send("GET", try model.featureURL("notifications"))
        case "Settings/Account settings":
            model.account = try await api.send("GET", "account")
            return model.account
        case "Settings/Advanced networking/Power saving":
            return try await api.send("GET", try model.featureURL("power_saving/schedules"))
        case "Settings/Advanced networking/Internet backup":
            let status = try await api.send("GET", try model.featureURL("backupinternet"))
            let points = try await api.send("GET", try model.featureURL("backup_access_points"))
            return .obj(("status", status), ("access_points", points))
        case "Settings/Advanced networking/Multi-WAN":
            return try await api.send("GET", try model.featureURL("wan/links"))
        case "Activity/Data usage":
            return try await api.send("GET", try model.featureURL("data_usage?") + statsRange(days: usageDays) + "&cadence=daily")
        case "Activity/Security activity":
            return try await api.send("GET", try model.featureURL("insights?") + statsRange() + "&cadence=daily")
        case "Activity/Network events":
            return try await api.send("GET", try model.featureURL("app_events?page_size=50"))
        case "Settings/Connected services":
            return try await api.send("GET", try model.featureURL("proxied_nodes"))
        case "Settings/Additional wifi networks", "Home/Security & privacy/Content filters":
            return try await api.send("GET", try model.featureURL("subnets_config"))
        case "Settings/Business guest wifi":
            return try await api.send("GET", try model.featureURL("captive_portal/configurations"))
        case "Settings/Advanced networking/Multiple static IPs":
            guard let url = model.networkURL, !url.isEmpty else { throw EeroError.operation("Select a network first.") }
            return try await api.send("GET", "/2.3/networks/" + model.networkId + "/multistaticip")
        default:
            return .null
        }
    }

    // MARK: Helpers

    /// Port of `StatsRange`: `start=…&end=…` for the last `days` days, in UTC.
    nonisolated static func statsRange(days: Int = 7) -> String {
        let end = Date()
        let start = end.addingTimeInterval(-Double(days) * 86_400)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return "start=" + escape(f.string(from: start)) + "&end=" + escape(f.string(from: end))
    }

    /// `Uri.EscapeDataString`: percent-encodes everything except RFC 3986 unreserved characters.
    nonisolated static func escape(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Port of `Entries`: the value itself when it is a list, otherwise the first named member that is a non-empty list.
    nonisolated static func entries(_ data: JSON, _ names: String...) -> [JSON] {
        let direct = data.list
        if !direct.isEmpty { return direct }
        for name in names {
            let a = data[name].list
            if !a.isEmpty { return a }
        }
        return []
    }

    // MARK: Preview

    /// Port of `PreviewFeature`.
    nonisolated static func previewData(_ path: String) -> JSON? {
        if path == "Help/Contact support" {
            return .obj(("contacts", JSON.array([
                .obj(("type", "CHAT"), ("title", "Sample support chat"), ("content", "https://www.eero.com/support")),
                .obj(("type", "MAIL"), ("title", "Sample support email"), ("content", "support@example.com")),
            ])))
        }
        if path.hasSuffix("Offers & referrals") {
            return .obj(("plans", JSON.array([.obj(("id", "sample-product"), ("name", "Sample eero Plus plan"), ("currency", "USD"), ("price", 999))])))
        }
        if path.hasSuffix("Guided diagnostics") { return .obj(("status", "completed"), ("issue_area", "none"), ("issues", JSON.array([]))) }
        if path.hasSuffix("Fast roaming") { return .obj(("fast_transition", true)) }
        if path.hasSuffix("Find backup wifi") {
            return .obj(("status", "SUCCESS"), ("discovered_ssids", JSON.array([.obj(("ssid", "Sample phone hotspot"), ("rssi", -53))])))
        }
        if path.hasSuffix("Incoming access invitations") {
            return .obj(("promotions", JSON.array([.obj(("invite_id", "sample-invite"), ("network_id", "sample"), ("network_name", "Sample family network"), ("invite_role", "admin"))])))
        }
        if path.hasSuffix("Automatic setup") {
            return .obj(("eeros", JSON.array([.obj(("serial", "SAMPLE-SERIAL"), ("model", "Sample eero"), ("ineligible_for_zts", JSON.obj(("reason", "Preview example"))))])))
        }
        if path.hasSuffix("Accessories & cellular") { return .array([.obj(("model", "Sample accessory"), ("status", "connected"))]) }
        if path.hasSuffix("Guest wifi network") { return .obj(("name", "Maple Guest"), ("enabled", true)) }
        if path.hasSuffix("Reservations & port forwarding") {
            return .obj(
                ("reservations", JSON.obj(("data", JSON.array([.obj(("description", "Office PC"), ("ip", "192.168.4.20"), ("mac", "02:00:00:00:00:01"))])))),
                ("forwards", JSON.obj(("data", JSON.array([])))),
                ("pinholes", JSON.obj(("data", JSON.array([])))))
        }
        if path.hasSuffix("Security & privacy") { return .obj(("dns_policies", JSON.obj(("block_malware", true), ("ad_block", true)))) }
        if path.hasSuffix("Software updates") { return .obj(("target_firmware", "Preview"), ("update_status", "up_to_date"), ("can_update_now", false)) }
        if path.hasSuffix("Notifications") { return .obj(("device.new", true), ("network.updated", true)) }
        if path.hasSuffix("Pending transfers") {
            return .obj(("transfers", JSON.array([.obj(("id", 17), ("organization_name", "Sample provider"), ("subset_name", "Maple community"), ("created_at", "2026-10-22"))])))
        }
        if path.hasSuffix("Outgoing transfer") { return .obj(("recipient_email_address", "recipient@example.com"), ("transfer_date", "2026-10-22")) }
        if path.hasSuffix("Identity protection") { return .obj(("enabled", false), ("status", "Sample benefit status")) }
        if path.hasSuffix("Connected device setup") {
            return .obj(("vendors", JSON.array([.obj(("vendor_id", "sample"), ("name", "Sample connected-device vendor"), ("enabled", true))])))
        }
        if path.hasSuffix("Business guest wifi") {
            return .obj(("configurations", JSON.array([.obj(
                ("configuration_id", 5), ("header", "Welcome to Maple House"), ("sub_header", "Guest wifi"), ("color_theme", "Dark"),
                ("capture_email", false), ("capture_name", false), ("access_expiration_in_minutes", 240))])))
        }
        if path == "Activity/Data usage" || path == "Activity/Security activity" {
            let points: [(String, Double)] = [
                ("2026-10-16", 1_200_000_000), ("2026-10-17", 2_100_000_000), ("2026-10-18", 1_600_000_000), ("2026-10-19", 2_800_000_000),
                ("2026-10-20", 1_800_000_000), ("2026-10-21", 2_200_000_000), ("2026-10-22", 1_700_000_000),
            ]
            return .obj(("series", JSON.array([.obj(
                ("type", "download"), ("sum", 13_400_000_000.0),
                ("values", JSON.array(points.map { JSON.obj(("time", $0.0), ("value", $0.1)) })))])))
        }
        return nil
    }
}
#endif
