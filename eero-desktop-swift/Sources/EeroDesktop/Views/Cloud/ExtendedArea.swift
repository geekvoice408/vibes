#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Port of the pages in ExtendedFeatures.cs: invitations, transfers, license keys, partner benefits,
/// identity protection, connected-device setup, ISP settings and the DNS performance test.
enum ExtendedArea: FeatureArea {
    static let joinNetwork = "Settings/User permissions/Join a network"
    static let pendingTransfers = "Settings/Network management/Pending transfers"
    static let license = "Settings/Account settings/Subscriptions/Redeem a license key"
    static let outgoingTransfer = "Settings/Network management/Outgoing transfer"
    static let partnerBenefits = "Settings/Account settings/Subscriptions/Partner benefits"
    static let identityProtection = "Home/Security & privacy/Identity protection"
    static let setupVendors = "Settings/Connected services/Connected device setup"
    static let ispSettings = "Settings/Advanced networking/Internet connection/ISP settings"
    static let dnsPerformance = "Settings/Advanced networking/DNS/DNS performance"

    static func handles(_ route: String) -> Bool {
        [joinNetwork, pendingTransfers, license, outgoingTransfer, partnerBenefits, identityProtection, setupVendors, ispSettings, dnsPerformance].contains(route)
    }

    /// Port of `AccountOnlyPage`: routes that render without a selected network.
    static func accountOnlyPage(_ route: String) -> Bool {
        route == "Settings/Notifications/Windows notifications" || route == "Help" || route.hasPrefix("Help/") || route == "Settings"
            || route == "Settings/Appearance" || route == "Settings/About" || route.hasPrefix("Settings/Account settings")
            || route == "Settings/Network management" || route == "Settings/Network management/Pending transfers"
            || route == "Settings/User permissions/Join a network" || route == "Settings/User permissions/Incoming access invitations"
            || route == "Home/Add or replace eero" || route == "Home/Add or replace eero/Find nearby eeros" || route == "Home/Add or replace eero/Create a network"
    }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        guard await model.api.signedIn else { return nil }
        switch route {
        case pendingTransfers: return try await model.api.send("GET", "/2.2/network_transfers/pending")
        case outgoingTransfer: return try await model.api.send("GET", model.netResource("transfer"))
        case identityProtection: return try await model.api.send("GET", "/2.2/account/identity_protection")
        case setupVendors: return try await model.api.send("GET", model.featureURL("simple_setup/vendors"))
        case dnsPerformance:
            let action = model.featureData["dns_perf_action"] ?? .null
            if action.isNull { return nil }
            return try await model.api.send("GET", model.featureURL("dns_perf_test/" + ExtendedContracts.identifier(action.string)))
        default: return nil
        }
    }

    static func previewData(_ route: String) -> JSON? {
        switch route {
        case pendingTransfers:
            return .obj(("transfers", JSON.array([.obj(("id", 17), ("organization_name", "Sample provider"), ("subset_name", "Maple community"), ("created_at", "2026-10-22"))])))
        case outgoingTransfer: return .obj(("recipient_email_address", "recipient@example.com"), ("transfer_date", "2026-10-22"))
        case identityProtection: return .obj(("enabled", false), ("status", "Sample benefit status"))
        case setupVendors: return .obj(("vendors", JSON.array([.obj(("vendor_id", "sample"), ("name", "Sample connected-device vendor"), ("enabled", true))])))
        default: return nil
        }
    }

    static func view(_ route: String, model: AppModel) -> AnyView {
        switch route {
        case joinNetwork: return AnyView(JoinNetworkPage(route: route, model: model))
        case pendingTransfers: return AnyView(PendingTransfersPage(route: route, model: model))
        case license: return AnyView(LicensePage(route: route, model: model))
        case outgoingTransfer: return AnyView(OutgoingTransferPage(route: route, model: model))
        case partnerBenefits: return AnyView(PartnerBenefitsPage(route: route, model: model))
        case identityProtection: return AnyView(IdentityProtectionPage(route: route, model: model))
        case setupVendors: return AnyView(SetupVendorsPage(route: route, model: model))
        case ispSettings: return AnyView(IspSettingsPage(route: route, model: model))
        default: return AnyView(DnsPerformancePage(route: route, model: model))
        }
    }
}

// MARK: - Join a network

struct JoinNetworkPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Join a network", route: route)
            Card { Text("Paste an eero administrator invitation link or code. Review the network and requested role before accepting.").font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading) }
            CloudLocal("Review invitation", model) {
                let model = self.model, ui = self.ui
                ui.form("Review invitation", [.long("code", "Invitation link or code")], submit: "Look up invitation", model: model) { v in
                    let code = try ExtendedContracts.inviteCode(v.v("code"))
                    if model.preview { throw EeroError.operation("Sign in to review an invitation.") }
                    let data = try await model.api.send("POST", "/2.2/inviteQuery", .obj(("invite_code", code)))
                    ui.show(InvitationReviewView(code: code, data: data, model: model))
                }
            }
        }
        .cloudSheets(ui, model: model)
    }
}

/// Port of `InvitationReview`.
struct InvitationReviewView: View {
    let code: String
    let data: JSON
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = CloudDialogState()

    var body: some View {
        let pending = data.s("invite_status").lowercased() == "pending"
        VStack(alignment: .leading, spacing: 10) {
            CloudHeading("Network invitation", size: 23)
            CloudDetails(value: data)
            if !state.status.isEmpty { Text(state.status).font(.system(size: 13)).foregroundStyle(.red) }
            HStack {
                ForEach([true, false], id: \.self) { accept in
                    Button(accept ? "Accept invitation" : "Decline invitation") { respond(accept) }
                        .disabled(!pending || state.working)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.working)
            }
            if !pending { CloudNote("Only pending invitations can be accepted or declined.") }
        }
        .interactiveDismissDisabled(state.working)
    }

    private func respond(_ accept: Bool) {
        Task {
            if state.working { return }
            if !(await model.confirm((accept ? "Accept" : "Decline") + " the invitation to " + data.s("network_name") + "?")) { return }
            var done = false
            _ = await state.run(model) {
                let id = try ExtendedContracts.identifier(data.s("network_id"))
                _ = try await model.api.send("POST", "/2.2/networks/" + id + "/invites/response", try ExtendedContracts.inviteResponse(code, accept))
                done = true
            }
            if done {
                dismiss()
                await model.reloadMembership(accept ? "Network invitation accepted." : "Network invitation declined.")
            }
        }
    }
}

// MARK: - Pending transfers

struct PendingTransfersPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let data = model.featureData[route] ?? .null
        let transfers = cloudEntries(data, "transfers")
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Pending network transfers", route: route)
            if transfers.isEmpty { Card { Text("No pending transfers were returned.").frame(maxWidth: .infinity, alignment: .leading) } }
            ForEach(Array(transfers.enumerated()), id: \.offset) { _, transfer in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudDetails(value: transfer)
                        CloudFlow {
                            ForEach([true, false], id: \.self) { accept in
                                CloudAction(accept ? "Accept transfer" : "Decline transfer", model) {
                                    if model.preview { throw EeroError.operation("Preview mode is read only.") }
                                    let id = try ExtendedContracts.identifier(transfer.s("id"))
                                    if !(await model.confirm((accept ? "Accept ownership of" : "Decline") + " this network transfer from " + transfer.s("organization_name") + "?")) { return }
                                    _ = try await model.api.send("POST", "/2.2/network_transfers/" + id + (accept ? "/accept" : "/deny"))
                                    await model.reloadMembership(accept ? "Network transfer accepted." : "Network transfer declined.")
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let token = Int(data.s("next_token")) {
                CloudAction("Next page of transfers", model) {
                    model.featureData[route] = try await model.cloudRead("/2.2/network_transfers/pending?token=\(token)")
                }
            }
        }
    }
}

// MARK: - License keys

struct LicensePage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Redeem a software subscription key", route: route)
            if model.network.isNull {
                Text("Select a network before redeeming a key.")
            } else {
                Card { Text("Use a software key supplied by eero or your provider. First validate the key, then review the activation options. Automatic renewal starts unchecked.").font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading) }
                CloudLocal("Validate a license key", model) {
                    let model = self.model, ui = self.ui
                    ui.form("License key", [.password("key", "Software key")], submit: "Validate key", model: model) { v in
                        if model.preview { throw EeroError.operation("Sign in to validate a key.") }
                        let key = v.v("key").trimmingCharacters(in: .whitespacesAndNewlines)
                        let result = try await model.api.send("POST", "/2.2/license_keys", try ExtendedContracts.license(key))
                        ui.show(LicenseActivationView(key: key, result: result, model: model))
                    }
                }
            }
        }
        .cloudSheets(ui, model: model)
    }
}

/// Port of `LicenseActivation`.
struct LicenseActivationView: View {
    let key: String
    let result: JSON
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = CloudDialogState()
    @ViewState private var renew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudHeading("Review license activation", size: 23)
            CloudDetails(value: result)
            CloudHeading("Network: " + model.network.s("name"), size: 16)
            Toggle("Enable automatic renewal under the provider's subscription terms", isOn: $renew).toggleStyle(.checkbox)
            if !state.status.isEmpty { Text(state.status).font(.system(size: 13)).foregroundStyle(.red) }
            HStack {
                Button("Activate for this network") {
                    Task {
                        if state.working { return }
                        let name = model.network.s("name")
                        if !(await model.confirm("Activate this subscription key for " + name + "? Automatic renewal: " + (renew ? "enabled" : "disabled") + ".")) { return }
                        let ok = await state.run(model) {
                            try await model.cloudChange("POST", "/2.2/license_keys", try ExtendedContracts.license(key, model.validatedNetworkId(), autoRenew: renew), "Subscription key activated.")
                        }
                        if ok { dismiss() }
                    }
                }.disabled(state.working)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.working)
            }
        }
        .interactiveDismissDisabled(state.working)
    }
}

// MARK: - Outgoing transfer

struct OutgoingTransferPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let data = model.featureData[route]
        let d = data ?? .null
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Outgoing ownership transfer", route: route)
            CloudObjectCard(value: data)
            if d.s("recipient_email_address").isEmpty && d.s("transfer_date").isEmpty {
                CloudNote("No outgoing ownership invitation was returned.", size: 14)
            } else {
                CloudFlow {
                    CloudAction("Resend invitation", model) {
                        if !(await model.confirm("Resend the pending ownership invitation to the current recipient?")) { return }
                        try await model.cloudChange("POST", model.netResource("transfer"), nil, "Ownership invitation resent.")
                    }
                    CloudAction("Cancel ownership invitation", model) {
                        if !(await model.confirm("Cancel the outgoing ownership invitation?")) { return }
                        try await model.cloudChange("DELETE", model.netResource("transfer"), nil, "Ownership invitation canceled.")
                    }
                }
            }
        }
    }
}

// MARK: - Partner benefits

struct PartnerBenefitsPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "eero Plus partner benefits", route: route)
            CloudNote("Benefits require the corresponding subscription. Redemption codes are shown only when you request them.", size: 14)
            CloudFlow {
                CloudAction("1Password status", model) { ui.info("1Password", try await model.cloudRead("/2.2/account/1password_status")) }
                CloudAction("1Password redemption code", model) { try showCode("1Password", try await model.cloudRead("/2.2/partners/onepassword/coupon?test=false")) }
                CloudAction("Malwarebytes redemption code", model) { try showCode("Malwarebytes", try await model.cloudRead("/2.2/partners/malwarebytes/coupon?test=false")) }
                SectionLink(title: "Identity protection & digital footprint", route: "Home/Security & privacy/Identity protection", model: model)
            }
            if !model.network.isNull {
                CloudAction("VPN seat availability", model) {
                    ui.info("VPN seats", try await model.cloudRead("/2.2/partners/guardian/networks/" + model.validatedNetworkId() + "/availability"))
                }
            }
            CloudNote("A native macOS VPN tunnel and the partner applications themselves remain separate integrations. These controls retrieve the eero benefit status and redemption information.")
        }
        .cloudSheets(ui, model: model)
    }

    /// Port of `ShowPartnerCode`.
    private func showCode(_ title: String, _ result: JSON) throws {
        let code = result.s("coupon")
        if code.isEmpty { throw EeroError.operation("No redemption code was returned for this account.") }
        ui.show(PartnerCodeView(title: title, code: code))
    }
}

struct PartnerCodeView: View {
    let title: String
    let code: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudHeading(title + " redemption code", size: 23)
            Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Copy redemption code") { cloudCopy(code) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - Identity protection

struct IdentityProtectionPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Identity protection & digital footprint", route: route)
            CloudObjectCard(value: model.featureData[route], title: "Protection status")
            CloudFlow {
                CloudAction("Supported countries", model) { ui.info("Supported countries", try await model.cloudRead(model.featureURL("identity_protection/countries"))) }
                CloudLocal("Activate identity protection", model) { activate() }
                CloudLocal("Scan an email address", model) { scan() }
                CloudLocal("Send email verification", model) { sendVerification() }
                CloudLocal("Verify scan email", model) { verify() }
            }
            if let previous = model.featureData["identity_scan"] {
                CloudLocal("Latest scan result", model) { ui.show(IdentityScanResultView(result: previous, model: model)) }
            }
        }
        .cloudSheets(ui, model: model)
    }

    private func activate() {
        let model = self.model
        ui.form("Activate identity protection", [.text("country", "Two-letter country code", "US")], submit: "Activate", model: model) { v in
            let country = v.v("country").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if country.range(of: "^[A-Z]{2}$", options: .regularExpression) == nil { throw EeroError.argument("Enter a two-letter country code.") }
            if !(await model.confirm("Activate the identity-protection benefit for this account and country?")) { return }
            try await model.cloudChange("POST", "/2.2/account/identity_protection/signup", .obj(("country_code", country)), "Identity protection activation requested.")
        }
    }

    private func scan() {
        let model = self.model, ui = self.ui
        ui.form("Digital footprint scan", [.text("email", "Email address to scan")], submit: "Run scan", model: model) { v in
            let email = try ExtendedContracts.email(v.v("email"))
            if model.preview { throw EeroError.operation("Sign in to run a scan.") }
            if !(await model.confirm("Send " + email + " to eero's identity-protection service for a digital-footprint scan?")) { return }
            let result = try await model.api.send("POST", "/2.2/account/identity_protection/scan", .obj(("email", email)))
            model.featureData["identity_scan"] = result
            ui.show(IdentityScanResultView(result: result, model: model))
        }
    }

    private func sendVerification() {
        let model = self.model
        ui.form("Email verification", [.text("email", "Email address")], submit: "Send verification email", model: model) { v in
            if model.preview { throw EeroError.operation("Sign in to request verification.") }
            _ = try await model.api.send("POST", "/2.2/account/identity_protection/scan/email", .obj(("email", try ExtendedContracts.email(v.v("email")))))
            model.setNotice("Identity-protection verification email requested.")
        }
    }

    private func verify() {
        let model = self.model, ui = self.ui
        ui.form("Verify digital-footprint email", [.text("code", "Verification code")], submit: "Verify", model: model) { v in
            let code = v.v("code").trimmingCharacters(in: .whitespacesAndNewlines)
            if code.range(of: "^[A-Za-z0-9-]{4,32}$", options: .regularExpression) == nil { throw EeroError.argument("Enter the code from the verification email.") }
            if model.preview { throw EeroError.operation("Sign in to verify an email.") }
            let result = try await model.api.send("POST", "/2.2/account/identity_protection/verify_email", .obj(("code", code)))
            model.featureData["identity_scan"] = result
            ui.show(IdentityScanResultView(result: result, model: model))
        }
    }
}

/// Port of `IdentityScanResult`.
struct IdentityScanResultView: View {
    let result: JSON
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudHeading("Digital footprint", size: 23)
            CloudDetails(value: result)
            let report = result.s("mwb_full_report_url")
            if !report.isEmpty {
                Button("Open detailed report at Malwarebytes") {
                    do { try Self.openPartnerReport(report) } catch { status = userMessage(error) }
                }
            }
            if result.b("email_unverified") { CloudNote("Use Send email verification, then Verify scan email to unlock verified results.", size: 14) }
            if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(.red) }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    /// Port of `OpenPartnerReport`.
    static func openPartnerReport(_ url: String) throws {
        guard let c = URLComponents(string: url), c.scheme == "https", c.port == nil || c.port == 443, c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), host == "malwarebytes.com" || host.hasSuffix(".malwarebytes.com"), let u = c.url else {
            throw EeroError.operation("The service did not return a supported secure Malwarebytes report link.")
        }
        NSWorkspace.shared.open(u)
    }
}

// MARK: - Connected device setup

struct SetupVendorsPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let data = model.featureData[route]
        let vendors = cloudEntries(data ?? .null, "vendors", "configurations")
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Connected device setup", route: route)
            if vendors.isEmpty { CloudObjectCard(value: data) }
            ForEach(Array(vendors.enumerated()), id: \.offset) { _, vendor in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudDetails(value: vendor)
                        let id = vendor.s("vendor_id")
                        if !id.isEmpty {
                            CloudLocal("Edit setup permission", model) {
                                let model = self.model
                                ui.form("Connected setup", [.bool("enabled", "Allow setup for this vendor", vendor.b("enabled"))], model: model) { v in
                                    if !(await model.confirm("Change connected-device setup for this vendor?")) { return }
                                    try await model.cloudChange("PUT", model.featureURL("simple_setup/vendors/" + cloudEscape(id)), .obj(("enabled", v.flag("enabled"))),
                                                                form: true, "Setup permission updated.")
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .cloudSheets(ui, model: model)
    }
}

// MARK: - ISP settings

struct IspSettingsPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let network = model.network
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "PPPoE & ISP VLAN settings", route: route)
            CloudObjectCard(value: .obj(("pppoe_enabled", network["pppoe_enabled"]), ("pppoe_username", network["pppoe_username"]), ("vlan", network["vlan"])))
            CloudLocal("Edit ISP settings", model) { edit() }
        }
        .cloudSheets(ui, model: model)
    }

    private func edit() {
        let model = self.model, network = model.network
        ui.form("ISP settings", [
            .bool("enabled", "Use PPPoE", network.b("pppoe_enabled")),
            .bool("replace", "Replace the saved PPPoE credentials", false),
            .text("username", "PPPoE username", network.s("pppoe_username")),
            .password("password", "New PPPoE password"),
            .text("vlan", "ISP VLAN ID (blank disables VLAN tagging)", network.s("vlan")),
        ], submit: "Apply ISP settings",
           description: "Use the settings supplied by your ISP. This changes an existing network; physical setup of a new gateway still needs provisioning.",
           model: model) { v in
            let enabled = v.flag("enabled"), replace = v.flag("replace")
            if enabled && !model.network.b("pppoe_enabled") && !replace { throw EeroError.argument("Enter new credentials when enabling PPPoE for the first time.") }
            let body = try ExtendedContracts.pppoe(enabled, v.v("username"), v.v("password"), replace, v.v("vlan"))
            if !(await model.confirm("Apply ISP settings? Incorrect PPPoE credentials or VLAN settings can disconnect the network.")) { return }
            try await model.cloudChange("PUT", model.netResource("settings"), body, "ISP settings updated.")
        }
    }
}

// MARK: - DNS performance

struct DnsPerformancePage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let result = model.featureData[route]
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Measure DNS resolver performance from the eero gateway. A test does not change your DNS configuration.", route: route)
            CloudLocal("Start DNS performance test", model) { start() }
            if let result, !result.isNull { CloudObjectCard(value: result, title: "Resolver test results") }
            else { Card { Text("No resolver test has been started during this session.").frame(maxWidth: .infinity, alignment: .leading) } }
            if model.featureData["dns_perf_action"] != nil {
                CloudAction("Refresh results", model) { try await FeatureAreas.load(route, model: model) }
            }
        }
        .cloudSheets(ui, model: model)
    }

    private func start() {
        let model = self.model, route = self.route
        let existing = model.network.get("dns", "custom", "ips").list.map(\.string).joined(separator: "\n")
        ui.form("DNS performance test", [.multiline("servers", "DNS server IP addresses (one per line)", existing), .text("port", "DNS server port", "53")],
                submit: "Start test", model: model) { v in
            guard let port = Int(v.v("port")) else { throw EeroError.argument("Enter a numeric DNS port.") }
            let body = try ExtendedContracts.dnsPerformance(v.v("servers"), port)
            if model.preview { throw EeroError.operation("Sign in to start a gateway test.") }
            let kickoff = try await model.api.send("POST", model.featureURL("dns_perf_test"), body)
            model.featureData["dns_perf_action"] = .string(try ExtendedContracts.identifier(kickoff.s("action_uuid")))
            try await FeatureAreas.load(route, model: model)
            model.setNotice("DNS test requested. Use Refresh results until it finishes.")
        }
    }
}
#endif
