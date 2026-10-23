#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Email pattern used by the Windows account and transfer dialogs.
private func validEmail(_ s: String) -> Bool {
    s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
}

// MARK: - User permissions

@MainActor
struct PermissionsPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        FeatureSub("User permissions", route: route)
        FeatureSectionButton("Join a network", "Settings/User permissions/Join a network", model: model)
        FeatureSectionButton("Incoming access invitations", "Settings/User permissions/Incoming access invitations", model: model)
        Button("Create admin invitation") { model.perform { try await createInvite() } }
        FeatureHeading("Members")
        let members = FeatureLoads.entries(data["members"], "members")
        ForEach(members.indices, id: \.self) { i in member(members[i]) }
        FeatureHeading("Invitations")
        let invites = FeatureLoads.entries(data["invites"], "invites")
        ForEach(invites.indices, id: \.self) { i in invite(invites[i]) }
    }

    private func createInvite() async throws {
        let model = self.model, route = self.route
        if model.preview { throw EeroError.operation("Preview mode is read only.") }
        if !(await model.confirm("Create a link that grants administrator access to the person who accepts it?")) { return }
        let invite = try await model.api.send("POST", try model.featureURL("invites"), RuntimeContracts.adminInvite())
        let link = invite.s("invite_url")
        if link.isEmpty { throw EeroError.operation("eero created a response without an invitation link. Refresh invitations before trying again.") }
        model.presentDialog("Admin invitation") {
            FeatureNote("Share this link only with the person you want to administer your network.")
            Text(link)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)))
            Button("Copy invitation link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
        }
        try await FeatureAreas.load(route, model: model)
    }

    @ViewBuilder private func member(_ member: JSON) -> some View {
        let id = member.first("user_id", "id")
        let role = member.s("user_role")
        let name = member.first("user_name", "name")
        FeatureCard {
            ObjectDetailsView(value: member)
            if !id.isEmpty && role != "owner" && role != "admin" {
                Button("Invite to administrator access") {
                    model.perform {
                        if !(await model.confirm("Send an administrator access invitation to " + name + "?")) { return }
                        try await model.change("POST", try model.featureURL("member_promotion"),
                                               .obj(("member_id", try ExtendedContracts.identifier(id))),
                                               message: "Administrator access invitation sent.")
                    }
                }
            }
            if role != "owner" && !id.isEmpty {
                Button("Remove administrator") {
                    model.perform {
                        if !(await model.confirm("Remove administrator access for " + name + "?")) { return }
                        try await model.change("DELETE", try model.featureURL("admins/" + FeatureLoads.escape(id)), nil,
                                               message: "Administrator access removed.")
                    }
                }
            }
        }
    }

    @ViewBuilder private func invite(_ invite: JSON) -> some View {
        let id = invite.first("invite_id", "id")
        FeatureCard {
            ObjectDetailsView(value: invite)
            if !id.isEmpty {
                FeatureActionRow {
                    Button("Rename invitation") {
                        let model = self.model
                        model.edit("Invitation nickname", [Field("name", "Nickname", invite.s("invite_nickname"))]) { v in
                            try Validation.validateName(v["name"])
                            try await model.change("PUT", try model.featureURL("invites/" + FeatureLoads.escape(id)),
                                                   .obj(("invite_nickname", v["name"].trimmingCharacters(in: .whitespacesAndNewlines))),
                                                   message: "Invitation nickname updated.")
                        }
                    }
                    Button("Cancel invitation") {
                        model.perform {
                            if !(await model.confirm("Cancel this invitation? Its link will stop granting access.")) { return }
                            try await model.change("DELETE", try model.featureURL("invites/" + FeatureLoads.escape(id)), nil, message: "Invitation canceled.")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Account settings

/// Port of `Contact`: a contact value that is either a string or an object.
private func contact(_ value: JSON) -> String {
    if case .string(let s) = value { return s }
    return value.first("value", "email", "phone", "number")
}

@MainActor
struct AccountPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let account = model.account
        let auth = account.s("auth", "type")
        FeatureSub("Account settings", route: route)
        FeatureCard {
            FeatureDetail("Name", account.s("name"))
            FeatureDetail("Email", contact(account["email"]))
            FeatureDetail("Phone", contact(account["phone"]))
            FeatureDetail("Role", account.s("role"))
            FeatureDetail("Sign-in method", auth == "eero" ? "Email or text verification code" : auth == "amazon" ? "Amazon" : auth == "sso" ? "Internet provider" : "Not reported by eero")
        }
        FeatureActionRow {
            Button("Change name") { changeName() }
            Button("Change email") { changeEmail() }
            Button("Verify new email") { AccountPage.verifyContact(model, "email") }
            Button("Change phone") { changePhone() }
            Button("Verify new phone") { AccountPage.verifyContact(model, "phone") }
        }
        Button("Email preferences") { emailPreferences() }
        FeatureSectionButton("Subscriptions & partner services", "Settings/Account settings/Subscriptions", model: model)
        Button("Delete eero account") { deleteAccount() }
            .foregroundStyle(.red)
    }

    private func changeName() {
        let model = self.model
        model.edit("Account name", [Field("name", "Name", model.account.s("name"))]) { v in
            try Validation.validateName(v["name"])
            try await model.change("PUT", "/2.2/account/name", .obj(("name", v["name"].trimmingCharacters(in: .whitespacesAndNewlines))),
                                   form: true, message: "Account name updated.")
        }
    }

    private func changeEmail() {
        let model = self.model
        model.edit("Account email", [Field("email", "New email address")]) { v in
            let email = v["email"].trimmingCharacters(in: .whitespacesAndNewlines)
            if !validEmail(email) { throw EeroError.argument("Enter a valid email address.") }
            try await model.change("PUT", "/2.2/account/email", .obj(("email", email)), form: true,
                                   message: "Email change requested. Use Verify new email to enter its code.")
        }
    }

    private func changePhone() {
        let model = self.model
        model.edit("Account phone", [Field("phone", "New phone number (include country code)")]) { v in
            try await model.change("PUT", "/2.2/account/phone", .obj(("phone", try PhoneInput.normalize(v["phone"]))), form: true,
                                   message: "Phone change requested. Use Verify new phone to enter its code.")
        }
    }

    private func emailPreferences() {
        let model = self.model
        model.edit("Email preferences", [Field("marketing", "Receive eero marketing emails", model.account.b("consents", "marketing_emails"), .bool)]) { v in
            try await model.change("PUT", "/2.2/account/consents", .obj(("marketing_emails", v.flag("marketing"))), form: true,
                                   message: "Email preferences updated.")
        }
    }

    private func deleteAccount() {
        let model = self.model
        model.edit("Delete account", [Field("confirm", "Type DELETE MY EERO ACCOUNT to confirm")], submit: "Delete account") { v in
            if v["confirm"] != "DELETE MY EERO ACCOUNT" { throw EeroError.argument("The confirmation text does not match.") }
            if !(await v.confirm("Permanently delete your eero account and associated account data? This can remove your ability to manage networks.")) { return }
            if model.preview { throw EeroError.operation("Preview mode is read only.") }
            try await model.api.send("DELETE", "/2.2/account")
            await model.api.forget()
            model.clearData()
            model.screen = .login(verify: false)
            model.setNotice("Account deletion request accepted.")
        }
    }

    /// Port of `VerifyContact`.
    static func verifyContact(_ model: AppModel, _ type: String) {
        model.edit("Verify new " + type, [Field("code", "Verification code")], submit: "Verify") { v in
            let code = v["code"].trimmingCharacters(in: .whitespacesAndNewlines)
            if code.range(of: "^[0-9]{4,10}$", options: .regularExpression) == nil { throw EeroError.argument("Enter the numeric verification code.") }
            try await model.change("POST", "/2.2/account/" + type + "/verify", .obj(("code", code)), form: true, message: "Account " + type + " verified.")
        }
    }
}

// MARK: - Subscriptions

@MainActor
struct SubscriptionPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        let status = model.network["premium_status"].isNull ? model.account["premium_status"] : model.network["premium_status"]
        let details = model.network["premium_details"].isNull ? model.account["premium_details"] : model.network["premium_details"]
        FeatureSub("Subscriptions & partner services", route: route)
        if !status.isNull || !details.isNull {
            ObjectCards(.obj(("premium_status", status), ("premium_details", details)))
        } else {
            FeatureNote(model.preview ? "Sample account. Sign in to load your plan details." : "No subscription summary was returned. Open Subscription details to check your account.", size: 14)
        }
        Button("Subscription details") {
            model.perform { model.info("Subscription details", try await model.read("/2.2/premium/customer")) }
        }
        if !model.network.isNull {
            Button("Available plans") {
                model.perform { model.info("Available plans", try await model.read("/2.4/premium/plans/" + model.networkId)) }
            }
        }
        Button("eero Plus plans and information") { model.runLocal { try model.official("https://www.eero.com/eero-plus") } }
        FeatureCatalogLinks(parent: "Settings/Account settings/Subscriptions", model: model, explanation: false)
        FeatureNote("Software-key activation and partner benefit codes are available below. Store purchases, Amazon account authorization and the VPN tunnel use their provider integrations.", size: 14)
    }
}

// MARK: - Connected services

@MainActor
struct ConnectedPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        FeatureSub("Connected services", route: route)
        ObjectCards(.obj(
            ("amazon_account_linked", model.network["amazon_account_linked"]), ("alexa_skill", model.network["alexa_skill"]),
            ("frustration_free_setup", model.network["ffs"]), ("eero_built_in", data)))
        FeatureSectionButton("Connected device setup", "Settings/Connected services/Connected device setup", model: model)
        FeatureSectionButton("Amazon connected home", "Settings/Connected services/Amazon connected home", model: model)
        FeatureSectionButton("Accessories & cellular", "Settings/Connected services/Accessories & cellular", model: model)
        FeatureActionRow {
            Button("eero Built-in settings") {
                let model = self.model
                model.perform {
                    let settings = try await model.read(try model.featureURL("proxied_nodes"))
                    model.edit("eero Built-in", [Field("enabled", "Enable eero Built-in", settings.b("enabled"), .bool)]) { v in
                        try await model.change("PUT", try model.featureURL("proxied_nodes"), .obj(("enabled", v.flag("enabled"))),
                                               message: "eero Built-in setting updated.")
                    }
                }
            }
            Button("Connected setup vendors") {
                model.perform { model.info("Connected setup vendors", try await model.read(try model.featureURL("simple_setup/vendors"))) }
            }
        }
        FeatureNote("Amazon and Alexa account linking is managed by eero. New account links cannot be created here.")
    }
}

// MARK: - Network management

@MainActor
struct NetworkManagementPage: View {
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        FeatureSub("Network management", route: route)
        FeatureNote("Use the network selector at the top to switch networks.", size: 14)
        FeatureSectionButton("Create a wired network", "Home/Add or replace eero/Create a network", model: model)
        if model.network.isNull {
            FeatureActionRow {
                FeatureSectionButton("Join a network", "Settings/User permissions/Join a network", model: model)
                FeatureSectionButton("Pending transfers", "Settings/Network management/Pending transfers", model: model)
            }
        } else {
            Button("Transfer network ownership") { transfer() }
            FeatureActionRow {
                FeatureSectionButton("Pending network transfers", "Settings/Network management/Pending transfers", model: model)
                FeatureSectionButton("Outgoing ownership transfer", "Settings/Network management/Outgoing transfer", model: model)
            }
            Button("Delete this network") { deleteNetwork() }
                .foregroundStyle(.red)
            FeatureNote("Full Bluetooth provisioning and physical gateway replacement require the official setup wizard.")
        }
    }

    private func transfer() {
        let model = self.model
        model.edit("Transfer network", [
            Field("name", "Recipient name"),
            Field("email", "Recipient email (or leave blank for phone)"),
            Field("phone", "Recipient phone with country code (or leave blank for email)"),
        ], submit: "Send transfer invitation") { v in
            try Validation.validateName(v["name"])
            let email = v["email"].trimmingCharacters(in: .whitespacesAndNewlines)
            var phone = v["phone"].trimmingCharacters(in: .whitespacesAndNewlines)
            if email.isEmpty == phone.isEmpty { throw EeroError.argument("Enter either an email address or a phone number.") }
            if !phone.isEmpty { phone = try PhoneInput.normalize(phone) }
            else if !validEmail(email) { throw EeroError.argument("Enter a valid email address.") }
            if !(await v.confirm("Send an ownership-transfer invitation to this recipient? Ownership changes when the recipient accepts.")) { return }
            try await model.change("POST", try model.netResource("transfer"),
                                   .obj(("name", v["name"].trimmingCharacters(in: .whitespacesAndNewlines)), ("email", email), ("phone", phone)),
                                   form: true, message: "Ownership transfer requested.")
        }
    }

    private func deleteNetwork() {
        let model = self.model
        model.edit("Delete network", [Field("confirm", "Type the current wifi name to confirm")], submit: "Delete network") { v in
            if v["confirm"] != model.network.s("name") { throw EeroError.argument("The wifi name does not match.") }
            if !(await v.confirm("Delete this network from your account? This will disrupt its management and may require setting it up again.")) { return }
            if model.preview { throw EeroError.operation("Preview mode is read only.") }
            guard let url = model.networkURL, !url.isEmpty else { throw EeroError.operation("Select a network first.") }
            try await model.api.send("DELETE", url)
            model.featureData = [:]
            model.network = .null
            model.networkURL = nil
            try await model.loadAccount()
            model.currentPage = "Home"
            model.setNotice("Network deleted.")
        }
    }
}
#endif
