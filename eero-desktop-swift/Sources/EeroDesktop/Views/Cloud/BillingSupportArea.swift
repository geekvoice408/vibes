#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

// MARK: - Billing (port of the UI in BillingServices.cs)

extension AppModel {
    /// Port of `OpenBillingWindow`: the provider's billing site in a private service window. A recognised
    /// completion callback closes it; closing it re-checks the entitlement with eero (a return URL alone
    /// never proves a purchase succeeded).
    func openBillingWindow(_ url: String, header: String? = nil) throws {
        if !ServiceLinks.allowed(url) { throw EeroError.operation("The billing service returned an unsupported provider address.") }
        let epoch = account
        try CloudServiceBrowser.show(title: "eero billing", url: url, headers: header, providerNavigation: true,
                                     callbackMatch: { BillingContracts.`return`($0) },
                                     onClose: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if await self.api.signedIn && self.account == epoch {
                    await self.run("Checking subscription status…") { try await self.refreshBilling() }
                }
            }
        })
    }

    /// Port of `RefreshBilling`.
    func refreshBilling() async throws {
        if preview { throw EeroError.operation("Sign in to refresh subscription benefits.") }
        let epoch = account
        let customer = try await api.send("GET", "/2.2/premium/customer")
        if !(await api.signedIn) || account != epoch { return }
        featureData["billing_customer"] = customer
        if !(networkURL ?? "").isEmpty { try await loadNetwork() }
        if await api.signedIn, account == epoch {
            setNotice("Subscription status refreshed from eero. Purchase and cancellation status comes from the service, including changes made in the billing window.")
        }
    }
}

enum BillingArea: FeatureArea {
    static let overview = "Settings/Account settings/Subscriptions/Billing & status"
    static let organization = "Settings/Account settings/Subscriptions/Business billing"

    static func handles(_ route: String) -> Bool { route == overview || route == organization }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        guard route == overview, await model.api.signedIn else { return nil }
        let data = try await model.api.send("GET", "/2.2/premium/customer")
        model.featureData["billing_customer"] = data
        return data
    }

    static func view(_ route: String, model: AppModel) -> AnyView {
        route == overview ? AnyView(BillingOverviewPage(route: route, model: model)) : AnyView(OrganizationBillingPage(route: route, model: model))
    }
}

struct BillingOverviewPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let customer: JSON? = model.preview
            ? .obj(("plan", "eero Plus"), ("status", "Active"), ("payment_channel", "eero"), ("renewal", "See billing service for your next renewal date and price"))
            : model.featureData["billing_customer"]
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Billing & subscription status", route: route)
            CloudObjectCard(value: customer, title: "Current subscription")
            CloudFlow {
                CloudAction("Refresh benefits / restore access", model) { try await model.refreshBilling() }
                CloudAction("Manage subscription & payment method", model) { try await model.cloudPaymentService("MANAGE_SUBSCRIPTION") }
                CloudAction("Purchase history", model) { try await model.cloudPaymentService("MANAGE_PURCHASES") }
            }
            SectionLink(title: "Plans, offers & referrals", route: "Settings/Account settings/Subscriptions/Offers & referrals", model: model)
            CloudNote("A billing-window return does not prove that a purchase succeeded. Refresh checks your current entitlement with eero. Purchases made through Google Play or another provider remain managed by that billing provider.")
        }
    }
}

struct OrganizationBillingPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Business billing", route: route)
            Text("Manage the payment account for your eero business organization. Access requires the appropriate organization role.").font(.system(size: 15))
            CloudFlow {
                CloudAction("Manage business payment account", model) {
                    let result = try await model.cloudRead("/2.2/organizations/self/payment_account/management_url")
                    try model.openBillingWindow(result.s("external_payment_account_management_url"))
                }
                CloudAction("Set up business payment account", model) {
                    if model.preview { throw EeroError.operation("Sample mode does not create payment accounts.") }
                    if !(await model.confirm("Start payment-account onboarding for your eero business organization? Review the provider's requirements before submitting its form.")) { return }
                    let result = try await model.api.send("POST", "/2.2/organizations/self/payment_account")
                    try model.openBillingWindow(result.s("external_payment_account_onboard_url"))
                }
            }
        }
    }
}

// MARK: - Support contacts (port of SupportContacts.cs)

enum SupportArea: FeatureArea {
    static let contact = "Help/Contact support"

    static func handles(_ route: String) -> Bool { route == contact }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        guard await model.api.signedIn else { return nil }
        return try await model.api.send("GET", "/2.2/account/eero_support")
    }

    static func previewData(_ route: String) -> JSON? {
        .obj(("contacts", JSON.array([
            .obj(("type", "CHAT"), ("title", "Sample support chat"), ("content", "https://www.eero.com/support")),
            .obj(("type", "MAIL"), ("title", "Sample support email"), ("content", "support@example.com")),
        ])))
    }

    static func view(_ route: String, model: AppModel) -> AnyView { AnyView(SupportContactsPage(route: route, model: model)) }
}

struct SupportContactsPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let contacts = (model.featureData[route] ?? .null)["contacts"].list
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Contact support", route: route)
            ForEach(Array(contacts.enumerated()), id: \.offset) { _, contact in
                contactCard(contact)
            }
            if contacts.isEmpty {
                CloudNote("No account-specific support contacts were returned. Open official support for the available contact options.", size: 14)
            }
            CloudLocal("Official eero support", model) {
                do { try model.cloudOpenService("eero support", "https://www.eero.com/support") }
                catch { model.setNotice(userMessage(error), error: true) }
            }
        }
    }

    private func contactCard(_ contact: JSON) -> some View {
        let type = contact.s("type"), content = contact.s("content"), title = contact.s("title").nilIfEmpty ?? "Support"
        let link = (type == "CHAT" || type == "HELP_LINK") && ServiceLinks.providerNavigation(content)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CloudHeading(title, size: 19)
                if link {
                    CloudNote(URL(string: content)?.host ?? "")
                    CloudLocal(type == "CHAT" ? "Open support chat" : "Open support page", model) {
                        do { try CloudServiceBrowser.show(title: title, url: content, providerNavigation: true) }
                        catch { model.setNotice(userMessage(error), error: true) }
                    }
                } else {
                    Text(content).font(.system(size: 14)).textSelection(.enabled)
                    if !content.isEmpty {
                        CloudLocal("Copy contact details", model) { cloudCopy(content); model.setNotice("Support contact copied.") }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
