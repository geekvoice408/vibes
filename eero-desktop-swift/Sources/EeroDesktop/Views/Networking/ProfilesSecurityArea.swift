#if os(macOS)
import SwiftUI
import EeroCore

/// Security & privacy and "Add or replace eero" pages plus the device-dialog extras
/// (port of the page code in `ProfilesSecurityFeatures.cs`). The profile list/detail and eero detail pages
/// from the same file are rendered by `DashboardArea` (ProfilesView.swift / NodesView.swift).
enum ProfilesSecurityArea: FeatureArea {
    static let routes: Set<String> = [
        "Home/Security & privacy",
        "Home/Add or replace eero",
    ]

    static func handles(_ route: String) -> Bool { routes.contains(route) }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        try await FeatureLoads.load(route, model: model)
    }

    static func previewData(_ route: String) -> JSON? { FeatureLoads.previewData(route) }

    static func view(_ route: String, model: AppModel) -> AnyView { AnyView(ProfilesSecurityPage(route: route, model: model)) }
}

@MainActor
struct ProfilesSecurityPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var sheets = NetSheets()

    private var data: JSON? { model.featureData[route] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = FeatureLoads.error(data) {
                FeatureErrorView(message: message, route: route, model: model)
            } else if route == "Home/Security & privacy" {
                securityPage
            } else {
                addEeroPage
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .netSheets(sheets)
    }

    private func sub(_ text: String) -> some View { NetSubtitle(text: text, route: route) }

    // MARK: Security & privacy

    @ViewBuilder private var securityPage: some View {
        sub("Security & privacy")
        NetCaption("Features depend on your eero subscription and network permissions.")
        NetObjectCard(value: data, title: "Advanced Security and content filters")
        NetFlow {
            Button("Edit network protection") { model.netLocal { try editPolicies(data ?? .null, try model.featureURL("dns_policies/network")) } }
            Button("Block & allow websites") {
                model.perform {
                    let domains = try await model.netRead(try model.featureURL("dns_policies/advanced_content_filter"))
                    sheets.show(NetDomainSheet(data: domains, profile: nil, model: model, sheets: sheets))
                }
            }
            Button("Ad blocking") {
                let ad = (data ?? .null)["ad_block_settings"]
                sheets.edit(model, "Ad blocking", [.bool("enable", "Enable ad blocking", ad.b("enabled"))]) { v in
                    try await model.netChange("POST", try model.featureURL("dns_policies/adblock"), .obj(("enable", v.flag("enable")), ("profiles", JSON.array(ad["profiles"].list))), "Ad blocking updated.")
                }
            }
            SectionLink(title: "Security activity", route: "Activity/Security activity", model: model)
            SectionLink(title: "Family content filters", route: "Home/Profiles", model: model)
        }
        SectionLink(title: "Subnet content filters", route: "Home/Security & privacy/Content filters", model: model)
        SectionLink(title: "Identity protection & digital footprint", route: "Home/Security & privacy/Identity protection", model: model)
        SectionLink(title: "VPN powered by Guardian", route: "Home/Security & privacy/VPN", model: model)
    }

    /// Port of `EditPolicies`.
    private func editPolicies(_ data: JSON, _ url: String) throws {
        var map = data["dns_policies"].object
        let unified = data.get("unified_content_filters", "dns_policies").object
        if let unified {
            var merged = map ?? [:]
            for (k, v) in unified { merged[k] = v }
            map = merged
        }
        if map == nil { map = data.object }
        guard let policies = map else { throw EeroError.operation("eero did not return editable content-filter settings.") }
        let allowed = ["ad_block", "block_illegal_content", "block_malware", "block_pornographic_content", "block_violent_content", "safe_search_enabled",
                       "youtube_restricted", "block_messaging_content", "block_social_content", "block_gaming_content", "block_streaming_content", "block_shopping_content"]
        var original: [String: Bool] = [:]
        var fields: [NetField] = []
        for key in policies.keys.sorted() {
            guard case .bool(let on) = policies[key]!, allowed.contains(key) || unified != nil else { continue }
            original[key] = on
            fields.append(.bool(key, NetUI.human(key), on))
        }
        if fields.isEmpty { throw EeroError.operation("No editable content-filter settings were returned for this account.") }
        sheets.edit(model, "Security & content filters", fields) { v in
            var changed = JSON.object([:])
            for f in fields where v.flag(f.key) != original[f.key] { changed[f.key] = .bool(v.flag(f.key)) }
            if changed.object?.isEmpty ?? true { return }
            try await model.netChange("POST", url, changed, form: true, "Security settings updated.")
        }
    }

    // MARK: Add or replace eero

    @ViewBuilder private var addEeroPage: some View {
        sub("Add or replace eero")
        ForEach(FeatureCatalog.children(route), id: \.path) { entry in
            SectionLink(title: entry.title, route: entry.path, model: model)
        }
        Card {
            NetCaption("Add an eligible eero to the selected network by serial number. Nearby discovery, automatic setup and new wired networks are grouped above. Full Bluetooth provisioning and gateway replacement are not available in this client.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button("Add eero by serial number") {
            sheets.edit(model, "Add eero", [NetField("serial", "eero serial number"), NetField("location", "Location")], submit: "Add eero") { v in
                let serial = v["serial"].netTrimmed
                if serial.range(of: "^[A-Za-z0-9-]{8,40}$", options: .regularExpression) == nil { throw EeroError.argument("Enter the serial number printed on the eero.") }
                try Validation.validateName(v["location"])
                guard await v.confirm("Add the eero with this serial number to the selected network?") else { return }
                try await model.netChange("POST", "/2.2/eeros?requireSession=true", .obj(("serial", serial), ("location", v["location"].netTrimmed), ("network", try model.netURL())), form: true, "eero addition requested.")
            }
        }
    }
}

// MARK: - Dialogs

/// Port of `DomainDialog`: shows website rules and opens the add/remove editor.
@MainActor
struct NetDomainSheet: View {
    let data: JSON
    let profile: JSON?
    @ObservedObject var model: AppModel
    let sheets: NetSheets
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Block & allow websites").font(.title2.bold())
                    NetCaption(profile == nil ? "Applies to the whole network." : "Applies to " + (profile ?? .null).s("name") + ".")
                    Button("Add or remove a website rule") { addRule() }
                    NetDetails.view(data)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(minWidth: 480, idealWidth: 620, minHeight: 300, idealHeight: 600)
    }

    private func addRule() {
        let profileId: String? = profile.map { NetUI.lastSegment($0.s("url")) }
        let model = self.model, sheets = self.sheets
        dismiss()
        sheets.after {
            sheets.edit(model, "Website rule", [
                NetField("domain", "Domain, e.g. example.com"),
                .choice("list", "Rule", "Block", ["Block", "Allow"]),
                .bool("remove", "Remove this rule instead of adding it", false),
            ]) { v in
                var body = JSON.obj(("domain", try FeatureContracts.domain(v["domain"])), ("is_delete", v.flag("remove")))
                if let profileId { body["profiles"] = .array([.string(profileId)]) }
                let path = try model.featureURL("dns_policies/" + (profileId == nil ? "network/" : "profiles/") + (v["list"] == "Allow" ? "allowed" : "blocked"))
                try await model.netChange("PUT", path, body, "Website rule updated.")
            }
        }
    }
}

/// Port of `DeviceExtraActions`: extra buttons for a device dialog (profile assignment,
/// connection details, device type, data usage and internet-backup access).
/// Embedded in the device dialog (`DevicesView`); it presents its own editors on top of that dialog.
@MainActor
struct DeviceExtraActionsView: View {
    let device: JSON
    @ObservedObject var model: AppModel
    @StateObject private var sheets = NetSheets()

    init(device: JSON, model: AppModel) { self.device = device; self.model = model }

    private var profileChoices: [(String, String)] {
        var out: [(String, String)] = []
        for p in model.profiles where !p.s("url").isEmpty {
            let label = p.s("name") + " · " + (p.s("url").split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "")
            if !out.contains(where: { $0.0 == label }) { out.append((label, p.s("url"))) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let choices = profileChoices
            if !choices.isEmpty {
                Button("Assign to a profile") {
                    let lookup = Dictionary(choices, uniquingKeysWith: { a, _ in a })
                    sheets.edit(model, "Assign device to profile", [.choice("profile", "Profile", choices[0].0, choices.map(\.0))]) { v in
                        try await model.netChange("PUT", device.s("url"), .obj(("profile", JSON.obj(("url", lookup[v["profile"]] ?? "")))), "Device profile updated.")
                    }
                }
            }
            Button("Full connection details") { sheets.info("Device details", device) }
            Button("Device type") {
                var names: [String: String] = [:]
                for t in FeatureContracts.deviceTypes { names[NetUI.human(t)] = t }
                let current = FeatureContracts.deviceTypes.contains(device.s("device_type")) ? NetUI.human(device.s("device_type")) : NetUI.human("generic")
                sheets.edit(model, "Device type", [.choice("type", "Type", current, names.keys.sorted())]) { v in
                    try await model.netChange("PUT", try model.featureURL("devices/" + NetUI.escape(device.s("mac"))), .obj(("device_type", names[v["type"]] ?? "")), "Device type updated.")
                }
            }
            Button("Data usage") {
                model.perform {
                    sheets.info("Device data usage", try await model.netRead(try model.featureURL("data_usage/devices/" + NetUI.escape(device.s("mac")) + "?") + NetUI.statsRange() + "&cadence=daily"))
                }
            }
            if case .bool(let denied) = device["secondary_wan_deny_access"] {
                Button("Internet backup access") {
                    sheets.edit(model, "Device internet backup", [.bool("allow", "Allow this device to use secondary WAN / backup internet", !denied)]) { v in
                        let id = NetUI.lastSegment(try model.netURL())
                        try await model.netChange("PUT", "/2.3/networks/" + id + "/devices/" + NetUI.escape(device.s("mac")), .obj(("secondary_wan_deny_access", !v.flag("allow"))), "Device backup access updated.")
                    }
                }
            }
        }
        .netSheets(sheets)
    }
}

#endif
