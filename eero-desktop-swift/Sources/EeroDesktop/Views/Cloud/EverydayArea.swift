#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Port of the UI in EverydayFeatures.cs (offers & referrals, guided diagnostics, connect a device,
/// fast roaming, backup wifi discovery and priority, Amazon connected home, Guardian/Thread credentials).
enum EverydayArea: FeatureArea {
    static let offers = "Settings/Account settings/Subscriptions/Offers & referrals"
    static let diagnostics = "Settings/Troubleshooting/Guided diagnostics"
    static let connectDevice = "Settings/Troubleshooting/Connect a device"
    static let fastRoaming = "Settings/Advanced networking/Wireless settings/Fast roaming"
    static let backupDiscovery = "Settings/Advanced networking/Internet backup/Find backup wifi"
    static let amazonHome = "Settings/Connected services/Amazon connected home"

    static func handles(_ route: String) -> Bool {
        [offers, diagnostics, connectDevice, fastRoaming, backupDiscovery, amazonHome].contains(route)
    }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        guard await model.api.signedIn else { return nil }
        switch route {
        case diagnostics: return try await model.api.send("GET", model.netResource("diagnostics"))
        case fastRoaming: return try await model.api.send("GET", model.featureURL("fast_transition"))
        case backupDiscovery: return try await model.api.send("GET", model.featureURL("backup_access_points/ssid_discovery"))
        case offers:
            if (model.networkURL ?? "").isEmpty { return nil }
            return try await model.api.send("GET", "/2.4/premium/plans/" + model.validatedNetworkId())
        default: return nil
        }
    }

    static func previewData(_ route: String) -> JSON? {
        switch route {
        case offers: return .obj(("plans", JSON.array([.obj(("id", "sample-product"), ("name", "Sample eero Plus plan"), ("currency", "USD"), ("price", 999))])))
        case diagnostics: return .obj(("status", "completed"), ("issue_area", "none"), ("issues", JSON.array([])))
        case fastRoaming: return .obj(("fast_transition", true))
        case backupDiscovery: return .obj(("status", "SUCCESS"), ("discovered_ssids", JSON.array([.obj(("ssid", "Sample phone hotspot"), ("rssi", -53))])))
        default: return nil
        }
    }

    static func view(_ route: String, model: AppModel) -> AnyView {
        switch route {
        case offers: return AnyView(SubscriptionOffersPage(route: route, model: model))
        case diagnostics: return AnyView(GuidedDiagnosticsPage(route: route, model: model))
        case connectDevice: return AnyView(DeviceConnectionPage(route: route, model: model))
        case fastRoaming: return AnyView(FastRoamingPage(route: route, model: model))
        case backupDiscovery: return AnyView(BackupDiscoveryPage(route: route, model: model))
        default: return AnyView(AmazonHomePage(route: route, model: model))
        }
    }
}

// MARK: - Offers & referrals

struct SubscriptionOffersPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let plans = cloudEntries(model.featureData[route] ?? .null, "plans")
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Offers & referrals", route: route)
            if model.network.isNull {
                Card { Text("Select a network to load its eligible plans and referrals.").frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                CloudNote("Plans returned for this network. Offers and referrals depend on eligibility and purchase channel. Review final prices and terms in eero's payment service.", size: 14)
                if plans.isEmpty { Card { Text("No plans were returned for this network.").frame(maxWidth: .infinity, alignment: .leading) } }
                ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                    let id = plan.s("id")
                    if !id.isEmpty { planCard(plan, id) }
                }
                CloudFlow {
                    CloudAction("Referral status", model) { ui.info("Subscription referrals", try await model.cloudRead(model.featureURL("managed/subscription_referrals"))) }
                    CloudAction("Manage purchases", model) { try await model.openPaymentService("MANAGE_PURCHASES") }
                }
            }
        }
        .cloudSheets(ui, model: model)
    }

    private func planCard(_ plan: JSON, _ id: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CloudHeading(plan.s("name").nilIfEmpty ?? "eero plan")
                if !plan.s("interval").isEmpty { CloudNote("Billing interval: " + plan.s("interval"), size: 14) }
                CloudFlow {
                    CloudAction("Check offers", model) {
                        if model.preview { throw EeroError.operation("Sign in to retrieve current offers.") }
                        let offers = try await model.api.send("POST", "/2.2/premium/in_app_payments/offers/" + model.validatedNetworkId(), try EverydayContracts.offers([id]))
                        ui.info("Available offers", .obj(("offers", JSON.array(cloudEntries(offers, "offers").map { JSON.obj(("title", $0.s("title")), ("ends_at", $0.s("ends_at"))) }))))
                    }
                    CloudAction("Create referral link", model) {
                        if model.preview { throw EeroError.operation("Sign in to create a referral link.") }
                        let referral = try await model.api.send("PUT", "/2.2/subscription_referrals", try EverydayContracts.referral(model.validatedNetworkId(), id))
                        let url = try ServiceLinks.eero(referral.s("referral_url")).absoluteString
                        ui.show(ReferralLinkView(url: url, model: model))
                    }
                    CloudAction("Email this plan to me", model) {
                        if model.preview { throw EeroError.operation("Sign in to email a referral.") }
                        if !(await model.confirm("Ask eero to email this subscription referral to your account email address?")) { return }
                        _ = try await model.api.send("POST", "/2.2/subscription_referral/email", try EverydayContracts.referral(model.validatedNetworkId(), id))
                        model.setNotice("Referral email requested from eero.")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Port of `ShowReferralLink`.
struct ReferralLinkView: View {
    let url: String
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudHeading("Subscription referral", size: 24)
            Text(url).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Copy link") { cloudCopy(url) }
                Button("Open referral") { do { try model.openServiceWindow("Subscription referral", url) } catch { status = userMessage(error) } }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(.red) }
        }
    }
}

// MARK: - Guided diagnostics

struct GuidedDiagnosticsPage: View {
    let route: String
    @ObservedObject var model: AppModel
    private static let checks = [("My internet is slow", "internet_slow"), ("My internet is offline", "internet_offline"),
                                 ("My connection drops", "connection_drops"), ("My eeros are red", "eeros_red")]

    var body: some View {
        let data = model.featureData[route]
        VStack(alignment: .leading, spacing: 10) {
            CloudSub(text: "Diagnose a connection problem", route: route)
            CloudNote("Choose the symptom to run eero's network health checks, then refresh the results. Review the findings before changing network settings.", size: 14)
            ForEach(Self.checks, id: \.1) { check in
                let symptom = check.1
                CloudAction(check.0, model) {
                    if model.preview { throw EeroError.operation("Sign in to run network health checks.") }
                    _ = try await model.api.send("POST", model.netResource("diagnostics"), try EverydayContracts.symptom(symptom))
                    model.setNotice("Health check requested. Refresh results to see progress; the request will not be automatically repeated.")
                }
            }
            CloudAction("Refresh results", model) { model.featureData[route] = try await model.cloudRead(model.netResource("diagnostics")) }
            if let data, !data.isNull { CloudObjectCard(value: data, title: "Health check results") }
        }
    }
}

// MARK: - Connect a device

struct DeviceConnectionPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let flag = model.network.get("temporary_flags", "hide_5g")
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Connect a device", route: route)
            Card { Text("Some devices need a 2.4 GHz connection during setup. Temporarily hide the 5 GHz network while you connect the device. eero controls when the temporary setting expires; you can also restore it here.").font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading) }
            if !flag.isNull { CloudObjectCard(value: flag, title: "Temporary 5 GHz setting") }
            CloudFlow {
                CloudAction("Temporarily hide 5 GHz", model) {
                    if !(await model.confirm("Temporarily hide 5 GHz on this network? Wireless clients may reconnect while you set up the device.")) { return }
                    try await model.cloudChange("PUT", model.featureURL("temporary_flags/hide_5g"), .obj(("value", true)), form: true, "Temporary 5 GHz pause requested.")
                }
                CloudAction("Restore 5 GHz", model) {
                    try await model.cloudChange("DELETE", model.featureURL("temporary_flags/hide_5g"), nil, "Temporary 5 GHz pause removed.")
                }
            }
            SectionLink(title: "Legacy compatibility & wireless settings", route: "Settings/Advanced networking/Wireless settings", model: model)
        }
    }
}

// MARK: - Fast roaming

struct FastRoamingPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let data = model.featureData[route]
        let hasSetting: Bool = { if case .bool = (data ?? .null)["fast_transition"] { return true }; return false }()
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Fast roaming", route: route)
            CloudObjectCard(value: data)
            if !hasSetting {
                CloudNote("This network did not return a fast roaming setting.", size: 14)
            } else {
                CloudLocal("Configure fast roaming", model) {
                    let model = self.model
                    ui.form("Fast roaming", [.bool("enabled", "Enable fast transition", (data ?? .null).b("fast_transition"))], model: model) { v in
                        if !(await model.confirm("Change fast roaming? Some wireless devices may reconnect or need compatibility settings.")) { return }
                        try await model.cloudChange("PUT", model.featureURL("fast_transition"), .obj(("fast_transition", v.flag("enabled"))), "Fast roaming preference updated.")
                    }
                }
            }
        }
        .cloudSheets(ui, model: model)
    }
}

// MARK: - Backup wifi discovery and priority

struct BackupDiscoveryPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let data = model.featureData[route]
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Find backup wifi networks", route: route)
            CloudFlow {
                CloudAction("Scan for backup wifi", model) {
                    if model.preview { throw EeroError.operation("Sign in to scan for backup networks.") }
                    _ = try await model.api.send("POST", model.featureURL("backup_access_points/ssid_discovery"))
                    model.setNotice("Discovery requested. Refresh results shortly.")
                }
                CloudAction("Refresh results", model) { model.featureData[route] = try await model.cloudRead(model.featureURL("backup_access_points/ssid_discovery")) }
            }
            if let data, !data.isNull { CloudHeading("Discovery status: " + data.s("status"), size: 16) }
            ForEach(Array(cloudEntries((data ?? .null)["discovered_ssids"]).enumerated()), id: \.offset) { _, found in
                let ssid = found.s("ssid")
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        CloudHeading(ssid, size: 19)
                        CloudNote("Signal: " + found.s("rssi") + " dBm")
                        CloudLocal("Use as backup", model) { addBackup(ssid) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .cloudSheets(ui, model: model)
    }

    /// `BackupEdit(null, ssid)` from ManagementFeatures.cs: add a discovered network as backup wifi.
    private func addBackup(_ ssid: String) {
        let model = self.model
        ui.form("Add backup wifi", [.text("ssid", "Backup wifi name", ssid), .password("password", "Backup wifi password"), .bool("enabled", "Enabled", true)],
                description: "Use a backup hotspot that your eero can reach.", model: model) { v in
            try CloudValidation.ssid(v.v("ssid"))
            try CloudValidation.password(v.v("password"))
            let id = UUID().uuidString.lowercased()
            var body = JSON.obj(("ssid", v.v("ssid").trimmingCharacters(in: .whitespacesAndNewlines)), ("uuid", id))
            if !v.v("password").isEmpty { body["password"] = .string(v.v("password")) }
            try await model.cloudChange("POST", model.featureURL("backup_access_points"), body, "Backup wifi saved.")
        }
    }
}

// MARK: - Amazon connected home

struct AmazonHomePage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let network = model.network
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Amazon connected home", route: route)
            CloudObjectCard(value: .obj(("amazon_account_linked", network["amazon_account_linked"]), ("alexa_skill", network["alexa_skill"])))
            if network.b("amazon_account_linked") {
                CloudAction("Find Zigbee devices", model) {
                    if !(await model.confirm("Start discovering nearby Zigbee devices on a compatible eero hub? Put the device you want to add in pairing mode first.")) { return }
                    try await model.cloudChange("POST", "/2.3/networks/" + model.validatedNetworkId() + "/shh/start_zigbee_discovery", nil,
                                                "Zigbee discovery requested. Check your Amazon smart-home app for discovered devices.")
                }
                CloudAction("Unlink Amazon account", model) {
                    if !(await model.confirm("Unlink the Amazon account from this network? Connected-home integrations may stop working.")) { return }
                    try await model.cloudChange("POST", "/2.2/amazon/networks/" + model.validatedNetworkId() + "/account_unlink", nil, "Amazon account unlinked.")
                }
            }
            SectionLink(title: "Connected device setup permissions", route: "Settings/Connected services/Connected device setup", model: model)
            CloudNote("New Amazon account links cannot be created here. Discovery requires a linked Amazon account, a supported hub, and an eligible Zigbee device.")
        }
    }
}
#endif
