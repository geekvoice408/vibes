#if os(macOS)
import SwiftUI
import EeroCore

/// "Create a wired network" (port of the UI part of `NetworkCreation.cs`; the request contract is `WiredNetworkSetup`).
enum NetworkCreationArea: FeatureArea {
    static let route = "Home/Add or replace eero/Create a network"

    /// One setup per app session, like the Windows `wiredSetup` field: a created network is reused, and an
    /// interrupted creation is never repeated.
    @MainActor static let wiredSetup = WiredNetworkSetup()

    static func handles(_ route: String) -> Bool { route == self.route }

    static func load(_ route: String, model: AppModel) async throws -> JSON? { nil }

    static func view(_ route: String, model: AppModel) -> AnyView { AnyView(CreateNetworkPage(route: route, model: model)) }
}

@MainActor
struct CreateNetworkPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var sheets = NetSheets()
    /// Bumped to re-render after the (non-observable) setup state changes (`RenderPage`).
    @ViewState private var revision = 0

    private var setup: WiredNetworkSetup { NetworkCreationArea.wiredSetup }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NetSubtitle(text: "Create a wired network", route: route)
            Card {
                Text("Use a separate, unconfigured eero connected by Ethernet to a working DHCP internet connection. Review eero's agreements, create the network, then add the gateway by serial number. This flow has not been validated with an unconfigured eero. Keep your active network's gateway in place.")
                    .font(.system(size: 15)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            let _ = revision
            if setup.createdURL != nil {
                Text("A network was created. Continue adding its gateway; this will reuse the created network.").foregroundStyle(.secondary)
                Button("Continue adding gateway") { model.perform { try await claimCreatedGateway() } }
            } else if setup.creationUncertain {
                Text("The creation response was interrupted. Use Refresh to inspect your account before starting another creation. This window will not repeat the creation request.")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Review setup & agreements") { reviewSetup() }
            }
            SectionLink(title: "Find nearby eeros", route: "Home/Add or replace eero/Find nearby eeros", model: model)
            NetCaption("PPPoE/static WAN bootstrap, cellular activation and gateway replacement still require the official setup wizard. Existing-network ISP settings remain available under Advanced networking.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .netSheets(sheets)
    }

    private func reviewSetup() {
        sheets.edit(model, "Gateway for new network", [NetField("serial", "Serial number of the unconfigured gateway")], submit: "Continue") { v in
            let serial = try RuntimeContracts.serial(v["serial"])
            if model.nodes.contains(where: { $0.s("serial").caseInsensitiveCompare(serial) == .orderedSame }) {
                throw EeroError.argument("This eero belongs to the active network. Use a separate eero ready for setup.")
            }
            if model.preview { throw EeroError.operation("Sign in to create a network.") }
            let agreements = try await model.api.send("GET", "/2.2/consents/network?serial=" + NetUI.escape(serial))
            let list = agreements.list
            sheets.after { networkCreationEditor(serial, list) }
        }
    }

    /// Port of `NetworkCreationEditor`.
    private func networkCreationEditor(_ serial: String, _ agreements: [JSON]) {
        var fields: [NetField] = [
            NetField("name", "New wifi name"),
            .password("password", "Wifi password"),
            NetField("timezone", "IANA timezone (for example America/Chicago)", model.network.s("timezone", "value")),
            NetField("location", "Gateway location"),
        ]
        do {
            for (i, agreement) in agreements.enumerated() {
                if agreement.s("name").isEmpty || agreement.s("localized_consent").isEmpty {
                    throw EeroError.operation("eero returned an incomplete agreement. Setup cannot continue.")
                }
                fields.append(.bool("consent_\(i)", agreement.s("localized_consent") + (agreement.b("requires_consent") ? " (required)" : " (optional)"), false))
                for link in agreement["links"].list {
                    let url = link.s("link")
                    _ = try ServiceLinks.eero(url)
                    fields.append(.link("Read agreement on eero.com", url))
                }
            }
        } catch {
            model.setNotice(userMessage(error), error: true)
            return
        }
        sheets.edit(model, "Create new network", fields, submit: "Create network",
                    description: "The gateway must be separate from your active network and already connected to internet by Ethernet.") { v in
            if setup.createdURL != nil || setup.creationUncertain {
                throw EeroError.operation("A creation request was already sent. Close this dialog and review its result.")
            }
            try Validation.validateName(v["location"])
            var consents: [String: JSON] = [:]
            for (i, agreement) in agreements.enumerated() {
                let accepted = v.flag("consent_\(i)")
                if agreement.b("requires_consent") && !accepted { throw EeroError.argument("Review and accept each required agreement to continue.") }
                consents[agreement.s("name")] = .bool(accepted)
            }
            let body = try RuntimeContracts.createNetwork(v["name"], v["password"], v["timezone"].netTrimmed, consents)
            guard await v.confirm("Create a new network named " + v["name"] + " and add the gateway with serial " + serial + "? Your current network is separate.") else { return }
            do { try await setup.create(model.api, body, serial, v["location"]) }
            catch { revision += 1; throw error }
            revision += 1
            sheets.after { model.perform("Adding new gateway…") { try await claimCreatedGateway() } }
        }
    }

    /// Port of `ClaimCreatedGateway`. The created resource survives a failed claim; retrying never creates another network.
    private func claimCreatedGateway() async throws {
        if model.preview || setup.createdURL == nil { throw EeroError.operation("Create a network first.") }
        let destination = try await setup.claim(model.api)
        revision += 1
        do {
            try await model.loadAccount()
            model.networkURL = destination
            try await model.loadNetwork()
            model.currentPage = "Home"
            model.screen = .shell
            model.setNotice("Gateway addition accepted. Check the network status while setup finishes.")
        } catch {
            model.setNotice("Gateway addition was accepted. Refresh did not finish: " + userMessage(error), error: true)
        }
    }
}
#endif
