#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Port of the UI in RuntimeFeatures.cs: incoming access invitations, automatic setup, accessories &
/// cellular, placement tests, subscription web management and eero Insight. The VPN page
/// (`VpnPage`) is shared with the VPN area: see `VpnPageIntro` / `VpnPageLinks`.
enum RuntimeArea: FeatureArea {
    static let incomingAccess = "Settings/User permissions/Incoming access invitations"
    static let automaticSetup = "Home/Add or replace eero/Automatic setup"
    static let accessories = "Settings/Connected services/Accessories & cellular"
    static let placement = "Home/eeros/Placement tests"
    static let subscriptionWeb = "Settings/Account settings/Subscriptions/Manage subscriptions & purchases"
    static let insight = "Settings/Business guest wifi/eero Insight"

    static func handles(_ route: String) -> Bool {
        [incomingAccess, automaticSetup, accessories, placement, subscriptionWeb, insight].contains(route)
    }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        guard await model.api.signedIn else { return nil }
        switch route {
        case incomingAccess: return try await model.api.send("GET", "/2.2/incoming_member_promotions")
        case automaticSetup: return try await model.api.send("GET", model.featureURL("auto_discovered_eeros"))
        case accessories: return try await model.api.send("GET", model.featureURL("accessories/setup/status"))
        default: return nil
        }
    }

    static func previewData(_ route: String) -> JSON? {
        switch route {
        case incomingAccess:
            return .obj(("promotions", JSON.array([.obj(("invite_id", "sample-invite"), ("network_id", "sample"), ("network_name", "Sample family network"), ("invite_role", "admin"))])))
        case automaticSetup:
            return .obj(("eeros", JSON.array([.obj(("serial", "SAMPLE-SERIAL"), ("model", "Sample eero"), ("ineligible_for_zts", JSON.obj(("reason", "Preview example"))))])))
        case accessories: return .array([.obj(("model", "Sample accessory"), ("status", "connected"))])
        default: return nil
        }
    }

    static func view(_ route: String, model: AppModel) -> AnyView {
        switch route {
        case incomingAccess: return AnyView(IncomingAccessPage(route: route, model: model))
        case automaticSetup: return AnyView(AutomaticSetupPage(route: route, model: model))
        case accessories: return AnyView(AccessoriesPage(route: route, model: model))
        case placement: return AnyView(PlacementPage(route: route, model: model))
        case subscriptionWeb: return AnyView(SubscriptionWebPage(route: route, model: model))
        default: return AnyView(BusinessInsightsPage(route: route, model: model))
        }
    }
}

// MARK: - Incoming access invitations

struct IncomingAccessPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let invites = cloudEntries(model.featureData[route] ?? .null, "promotions")
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Incoming access invitations", route: route)
            if invites.isEmpty { Card { Text("No pending access invitations.").frame(maxWidth: .infinity, alignment: .leading) } }
            ForEach(Array(invites.enumerated()), id: \.offset) { _, invite in
                let id = invite.s("invite_id"), net = invite.s("network_id")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudHeading(invite.s("network_name"))
                        CloudNote("Requested access: " + invite.s("invite_role"), size: 14)
                        if !id.isEmpty && !net.isEmpty {
                            ForEach([true, false], id: \.self) { accept in
                                CloudAction(accept ? "Accept invitation" : "Decline invitation", model) {
                                    if !(await model.confirm((accept ? "Accept" : "Decline") + " this access invitation for " + invite.s("network_name") + "?")) { return }
                                    try await model.cloudChange("POST", "/2.2/networks/" + ExtendedContracts.identifier(net) + "/invites/response",
                                                                try RuntimeContracts.invitationResponse(id, accept),
                                                                accept ? "Access invitation accepted." : "Access invitation declined.")
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Automatic setup

struct AutomaticSetupPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()
    private static let modes = ["OFF", "ZTS", "LTS", "DEFAULT"]

    var body: some View {
        let current = model.network.s("auto_setup_mode")
        let found = cloudEntries(model.featureData[route] ?? .null, "eeros")
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Automatic eero setup", route: route)
            Card { Text("Current mode: " + (current.nilIfEmpty ?? "Not reported")).frame(maxWidth: .infinity, alignment: .leading) }
            CloudLocal("Automatic setup preference", model) {
                let model = self.model
                ui.form("Automatic eero setup", [.choice("mode", "Mode", Self.modes.contains(current) ? current : "DEFAULT", Self.modes)], model: model) { v in
                    if !(await model.confirm("Change automatic setup for this network? OFF disables automatic setup; ZTS and LTS use eero's automatic setup policies; DEFAULT follows the provider default.")) { return }
                    try await model.cloudChange("PUT", model.featureURL("auto_setup_mode"), try RuntimeContracts.autoSetup(v.v("mode")), "Automatic setup preference updated.")
                }
            }
            CloudHeading("Discovered eeros")
            if found.isEmpty { CloudNote("No cloud-discovered eeros were returned. Bluetooth discovery is also available under Add or replace eero.", size: 14) }
            ForEach(Array(found.enumerated()), id: \.offset) { _, eero in
                let serial = eero.s("serial")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudDetails(value: eero)
                        if !serial.isEmpty { CloudLocal("Add this eero", model) { addDiscovered(serial) } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .cloudSheets(ui, model: model)
    }

    /// Port of `AddDiscoveredEero`.
    private func addDiscovered(_ serial: String) {
        let model = self.model
        ui.form("Add discovered eero", [.text("serial", "Serial number", serial), .text("location", "Location")], submit: "Add eero", model: model) { v in
            let validated = try RuntimeContracts.serial(v.v("serial"))
            try CloudValidation.name(v.v("location"))
            if !(await model.confirm("Add eero " + validated + " to the selected network?")) { return }
            try await model.cloudChange("POST", "/2.2/eeros?requireSession=true",
                                        .obj(("serial", validated), ("location", v.v("location").trimmingCharacters(in: .whitespacesAndNewlines)), ("network", model.networkURL)),
                                        form: true, "eero addition requested.")
        }
    }
}

// MARK: - Accessories & cellular

struct AccessoriesPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let cellular = model.network["cellular_backup"]
        let accessories = model.network["accessories"].list
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Accessories & cellular", route: route)
            CloudObjectCard(value: model.featureData[route], title: "Accessory setup status")
            if !cellular.isNull { CloudObjectCard(value: cellular, title: "Cellular backup") }
            if accessories.isEmpty { CloudNote("No registered accessories were reported for this network.", size: 14) }
            ForEach(Array(accessories.enumerated()), id: \.offset) { _, accessory in
                accessoryCard(accessory)
            }
            CloudNote("New cellular service activation and physical accessory pairing require the provider's setup flow. Existing registration, connection and phone-line details are shown when your network supports them.")
        }
        .cloudSheets(ui, model: model)
    }

    private func accessoryCard(_ accessory: JSON) -> some View {
        let serial = accessory.first("dsn", "serial"), eeroId = accessory.s("eero_id")
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HardwareImage(node: accessory, size: 72)
                CloudHeading(accessory.first("name", "model"))
                CloudDetails(value: accessory)
                CloudFlow {
                    if !serial.isEmpty {
                        CloudAction("Refresh accessory details", model) {
                            ui.info("Accessory", try await model.cloudRead(model.featureURL("accessories/" + cloudEscape(try RuntimeContracts.serial(serial)))))
                        }
                        CloudLocal("Remove accessory", model) { remove(serial) }
                    }
                    if !eeroId.isEmpty {
                        CloudAction("Phone line associations", model) {
                            ui.info("Phone lines", try await model.cloudRead(model.featureURL("sip_config_associations/" + ExtendedContracts.identifier(eeroId))))
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func remove(_ serial: String) {
        let model = self.model
        ui.form("Remove accessory", [.text("serial", "Type the accessory serial number to confirm")], submit: "Remove accessory", model: model) { v in
            if v.v("serial").trimmingCharacters(in: .whitespacesAndNewlines) != serial { throw EeroError.argument("The accessory serial number does not match.") }
            if !(await model.confirm("Remove this accessory? Its cellular backup or phone service may stop working.")) { return }
            try await model.cloudChange("DELETE", model.featureURL("accessories/" + cloudEscape(try RuntimeContracts.serial(serial))), nil, "Accessory removed.")
        }
    }
}

// MARK: - Placement tests

struct PlacementPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Placement tests", route: route)
            CloudNote("Run a cloud placement test for a configured eero, then retrieve its signal and placement rating. Results can take a little time to appear.", size: 14)
            ForEach(Array(model.nodes.enumerated()), id: \.offset) { _, node in
                let serial = node.s("serial")
                if !serial.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            CloudHeading(node.first("location", "model"))
                            CloudFlow {
                                CloudAction("Run placement test", model) {
                                    let url = try placementURL(serial)
                                    if !(await model.confirm("Run a placement test for " + node.first("location", "model") + "?")) { return }
                                    try await model.cloudChange("POST", url, nil, "Placement test requested. Use View results after the test finishes.")
                                }
                                CloudAction("View results", model) { ui.info("Placement results", try await model.cloudRead(try placementURL(serial))) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .cloudSheets(ui, model: model)
    }

    private func placementURL(_ serial: String) throws -> String {
        "/2.3/networks/" + (try model.validatedNetworkId()) + "/placement_test/" + cloudEscape(try RuntimeContracts.serial(serial))
    }
}

// MARK: - VPN page pieces (port of `VpnPage`; the status card and controls belong to the VPN area)

/// Top of the VPN page: subtitle and the eligibility explanation.
struct VpnPageIntro: View {
    let route: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CloudSub(text: "VPN powered by Guardian", route: route)
            CloudNote("Guardian must be included with your eero service. Some internet providers do not offer this benefit. Check eligibility before installing or registering a device.")
        }
    }
}

/// Bottom of the VPN page: Guardian sign-in details and the official Guardian links.
struct VpnPageLinks: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuardianCredentialsButton(model: model)
            CloudFlow {
                CloudLocal("Activate or manage Guardian", model) {
                    do { try model.cloudOpenService("Guardian VPN", "https://guardianapp.com/login?connect-api-env=wifi-company-prod") }
                    catch { model.setNotice(userMessage(error), error: true) }
                }
                CloudLocal("Guardian Mac download", model) {
                    do { try model.cloudOfficial("https://guardianapp.com/") } catch { model.setNotice(userMessage(error), error: true) }
                }
                CloudLocal("VPN setup instructions", model) {
                    do { try model.cloudOpenService("Guardian setup", "https://eero.com/support/articles/how-do-i-set-up-vpn-powered-by-guardian") }
                    catch { model.setNotice(userMessage(error), error: true) }
                }
            }
            CloudNote("Guardian's own Mac app is also available through the download above.")
        }
    }
}

// MARK: - Manage subscriptions & purchases

struct SubscriptionWebPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Manage subscriptions & purchases", route: route)
            Card { Text("Open eero's subscription service with a temporary account sign-in. Review prices, terms and payment details in the service window before submitting anything.").font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading) }
            CloudFlow {
                CloudAction("Manage subscription", model) { try await model.cloudPaymentService("MANAGE_SUBSCRIPTION") }
                CloudAction("Manage purchases", model) { try await model.cloudPaymentService("MANAGE_PURCHASES") }
                CloudAction("Available add-ons", model) { try await model.cloudPaymentService("MOBILE_ADDON_PAYMENT") }
            }
            CloudLocal("Manage a Google Play subscription", model) {
                if let url = URL(string: "https://play.google.com/store/account/subscriptions") { NSWorkspace.shared.open(url) }
            }
            CloudNote("For a subscription purchased through Google Play, sign in with the Google account that made the purchase. Google Play management opens in your browser.")
        }
    }
}

// MARK: - eero Insight

struct BusinessInsightsPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "eero Insight", route: route)
            Text("Open the official network management portal. Access depends on your business account and permissions.").font(.system(size: 15))
            CloudAction("Open eero Insight", model) {
                if model.preview { throw EeroError.operation("Sign in to open eero Insight.") }
                let temporary = try await model.api.send("GET", "/2.2/login/temporary")
                try model.cloudOpenService("eero Insight", "https://insight.eero.com/login/mobile?next=/networks/" + model.validatedNetworkId(),
                                           headers: try ServiceLinks.tokenHeader(temporary.s("temporary_token")))
            }
        }
    }
}
#endif
