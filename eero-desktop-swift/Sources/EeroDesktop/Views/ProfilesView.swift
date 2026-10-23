#if os(macOS)
import SwiftUI
import EeroCore

/// Port of `ProfilesPageV2` / `NativeProfiles` (routes "Profiles" and "Home/Profiles").
@MainActor
struct ProfilesView: View {
    @ObservedObject var model: AppModel
    @ViewState private var sheet: DashboardSheet? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Subtitle("Organize devices, manage internet access, and set scheduled pauses.")
            DashboardAvailability(key: "Profiles", model: model)
            if model.network.s("connection", "mode") == "bridged" {
                Card { Text("Family profiles are unavailable while eero is in bridge mode.").font(.system(size: 14)) }
            } else {
                Button("Add a profile") { if !model.busy { sheet = createProfile() } }
                    .buttonStyle(.accent)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], alignment: .leading, spacing: 0) {
                    ForEach(Array(model.profiles.enumerated()), id: \.offset) { _, item in profileCard(item) }
                }
                .padding(.top, 12)
                if model.profiles.isEmpty {
                    Card { Text("No profiles yet. Add a profile to group devices and manage their internet access.").font(.system(size: 14)).foregroundStyle(DashboardKit.muted) }
                }
            }
        }
        .dashboardSheet($sheet, model: model)
    }

    private func profileCard(_ item: JSON) -> some View {
        let name = item.s("name")
        return Card {
            HStack(spacing: 14) {
                Text(name.isEmpty ? "P" : String(name.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(DashboardKit.accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.soft, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 20, weight: .semibold))
                    Text(DashboardKit.profileSummary(item)).font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                }
            }
            Button("Manage profile") {
                if model.busy { return }
                model.selectedProfile = item
                model.navigate("Home/Profiles/Profile")
            }
            .padding(.leading, 58).padding(.top, 12)
        }
    }

    private func createProfile() -> DashboardSheet {
        .form(DashboardForm(title: "Create profile", fields: [.text("name", "Profile name")], submit: "Create") { v, _ in
            try DashboardKit.validateName(v.v("name"))
            try await model.dashboardChange("POST", try model.netResource("profiles"),
                                            JSON.obj(("name", v.v("name").trimmingCharacters(in: .whitespacesAndNewlines)), ("paused", false), ("devices", JSON.array([]))),
                                            success: "Profile created.")
        })
    }
}

/// Port of `ProfileDetailPage` / `NativeProfileDetail` (route "Home/Profiles/Profile").
@MainActor
struct ProfileDetailView: View {
    @ObservedObject var model: AppModel
    @ViewState private var sheet: DashboardSheet? = nil
    var body: some View {
        let profile = model.selectedProfile
        Group {
            if profile.isNull { Text("Select a profile from the Profiles page.") }
            else { content(profile) }
        }
        .dashboardSheet($sheet, model: model)
    }

    /// Port of `ProfilePolicyUrl`.
    static func policyURL(_ profile: JSON, model: AppModel) throws -> String {
        try model.featureURL("dns_policies/profiles/" + (profile.s("url").trimmingSuffix("/").components(separatedBy: "/").last ?? ""))
    }

    @ViewBuilder private func content(_ profile: JSON) -> some View {
        let url = profile.s("url")
        let paused = profile.b("paused")
        let schedulesURL = model.resource(profile, "schedules", url + "/schedules")
        VStack(alignment: .leading, spacing: 0) {
            Subtitle("Manage devices, internet access, and scheduled pauses.")
            HStack {
                Button(paused ? "Resume internet" : "Pause internet") {
                    model.perform {
                        guard await model.confirm("Change internet access for all devices in this profile?") else { return }
                        try await model.dashboardChange("PUT", url, JSON.obj(("paused", !paused)), success: "Profile access updated.")
                    }
                }.buttonStyle(.accent)
                Button("Rename") { if !model.busy { sheet = rename(profile, url) } }
                Button("Assign devices") { if !model.busy { sheet = DashboardSheet(kind: .profileDevices(profile)) } }
            }
            .padding(.bottom, 16)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    Card { members(profile) }
                    Card { schedules(profile, schedulesURL) }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    Card { filters(profile) }
                    Card {
                        SectionHeader("Manage profile")
                        Text("Deleting a profile keeps its devices on your network.").font(.system(size: 13)).foregroundStyle(DashboardKit.muted)
                        Button("Delete profile") { if !model.busy { sheet = delete(profile, url) } }
                            .foregroundStyle(DashboardKit.danger)
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private func members(_ profile: JSON) -> some View {
        let devices = profile["devices"].list
        SectionHeader("Devices")
        if devices.isEmpty { Text("No devices assigned yet.").font(.system(size: 13)).foregroundStyle(DashboardKit.muted) }
        ForEach(Array(devices.enumerated()), id: \.offset) { _, device in
            let row = DashboardDevice(device)
            RouteRow(title: row.name, subtitle: row.status, route: "Devices") { sheet = .device(device) }
        }
    }

    @ViewBuilder private func schedules(_ profile: JSON, _ schedulesURL: String) -> some View {
        let items = profile["schedule"].list
        SectionHeader("Scheduled pauses")
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.s("name")).font(.system(size: 15, weight: .semibold))
                Text(item["days"].list.map { DashboardKit.human($0.string.lowercased()) }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                Text(item.s("start") + " – " + item.s("end") + " · " + (item.b("enabled") ? "Enabled" : "Disabled")).font(.system(size: 14))
                HStack {
                    Button("Edit") { if !model.busy { sheet = ProfileSchedules.edit(item, item.s("url"), model: model) } }
                    Button("Delete") {
                        model.perform {
                            guard await model.confirm("Delete this scheduled pause?") else { return }
                            try await model.dashboardChange("DELETE", item.s("url"), nil, success: "Scheduled pause deleted.")
                        }
                    }
                }
            }.padding(.bottom, 8)
        }
        if items.isEmpty { Text("No scheduled pauses.").font(.system(size: 13)).foregroundStyle(DashboardKit.muted) }
        Button("Add scheduled pause") { if !model.busy { sheet = ProfileSchedules.edit(nil, schedulesURL, model: model) } }
            .buttonStyle(.quiet)
            .padding(.top, 8)
    }

    @ViewBuilder private func filters(_ profile: JSON) -> some View {
        SectionHeader("Content filters & app controls")
        Text("Choose what devices in this profile can access.").font(.system(size: 13)).foregroundStyle(DashboardKit.muted)
        Button("Content filters") {
            model.perform {
                let policyURL = try Self.policyURL(profile, model: model)
                let data = try await model.dashboardRead(policyURL)
                sheet = try ProfilePolicies.edit(data, policyURL, model: model)
            }
        }
        Button("Block & allow websites") {
            model.perform {
                let domains = try await model.dashboardRead(try model.featureURL("dns_policies/advanced_content_filter"))
                sheet = DashboardSheet(kind: .domains(domains, profile: profile))
            }
        }
        Button("Block apps") {
            model.perform { sheet = try await ProfilePolicies.blockApps(profile, model: model) }
        }
        Button("Ad blocking") {
            if model.busy { return }
            sheet = .form(DashboardForm(title: "Profile ad blocking", fields: [.bool("enable", "Enable ad blocking", profile.b("premium_dns", "ad_block_settings", "enabled"))]) { v, _ in
                try await model.dashboardChange("POST", try Self.policyURL(profile, model: model) + "/adblock", JSON.obj(("enable", v.flag("enable"))), success: "Profile ad blocking updated.")
            })
        }
        Button("View filter details") { if !model.busy { sheet = .info("Profile filter details", profile["premium_dns"]) } }
            .buttonStyle(.quiet)
            .padding(.top, 8)
    }

    private func rename(_ profile: JSON, _ url: String) -> DashboardSheet {
        .form(DashboardForm(title: "Profile name", fields: [.text("name", "Name", profile.s("name"))]) { v, _ in
            try DashboardKit.validateName(v.v("name"))
            try await model.dashboardChange("PUT", url, JSON.obj(("name", v.v("name").trimmingCharacters(in: .whitespacesAndNewlines))), success: "Profile renamed.")
        })
    }

    private func delete(_ profile: JSON, _ url: String) -> DashboardSheet {
        .form(DashboardForm(title: "Delete profile", fields: [.text("confirm", "Type the profile name to confirm")], submit: "Delete profile") { v, _ in
            if v.v("confirm") != profile.s("name") { throw EeroError.argument("The profile name does not match.") }
            model.currentPage = "Home/Profiles"
            model.selectedProfile = .null
            try await model.dashboardChange("DELETE", url, nil, success: "Profile deleted. Devices remain on your network.")
        })
    }
}

/// Port of `ScheduleEdit` (NetworkingFeatures.cs) for profile scheduled pauses.
@MainActor
enum ProfileSchedules {
    static func edit(_ item: JSON?, _ url: String, model: AppModel, power: Bool = false) -> DashboardSheet {
        let item = item ?? .null
        let days = Set(item["days"].list.map(\.string))
        var fields: [DashboardField] = [
            .text("name", "Schedule name", item.s("name")),
            .text("start", "Start time (24-hour HH:mm)", item.s(power ? "start_time" : "start").nilIfEmpty ?? "22:00"),
            .text("end", "End time (24-hour HH:mm)", item.s(power ? "end_time" : "end").nilIfEmpty ?? "07:00"),
            .bool("enabled", "Enabled", item.isNull || item.b("enabled")),
        ]
        for day in DashboardKit.weekDays { fields.append(.bool(day, DashboardKit.human(day.lowercased()), days.contains(day))) }
        return .form(DashboardForm(title: item.isNull ? "Add schedule" : "Edit schedule", fields: fields, submit: "Save",
                                   description: "Times follow the network timezone. End times earlier than start times continue into the next day.") { v, _ in
            let selected = DashboardKit.weekDays.filter { v.flag($0) }
            let body = try FeatureContracts.schedule(v.v("name"), selected, v.v("start"), v.v("end"), v.flag("enabled"), power: power)
            try await model.dashboardChange(item.isNull ? "POST" : "PUT", url, body, success: "Schedule saved.")
        })
    }
}

/// Ports of `EditPolicies` and `BlockApps` (ProfilesSecurityFeatures.cs) as used by the profile page.
@MainActor
enum ProfilePolicies {
    static let allowed = ["ad_block", "block_illegal_content", "block_malware", "block_pornographic_content", "block_violent_content", "safe_search_enabled",
                          "youtube_restricted", "block_messaging_content", "block_social_content", "block_gaming_content", "block_streaming_content", "block_shopping_content"]

    static func edit(_ data: JSON, _ url: String, model: AppModel) throws -> DashboardSheet {
        var map = data["dns_policies"].object
        let unified = data.get("unified_content_filters", "dns_policies").object
        if let unified { var m = map ?? [:]; for (k, v) in unified { m[k] = v }; map = m }
        if map == nil { map = data.object }
        guard let map else { throw EeroError.operation("eero did not return editable content-filter settings.") }
        var original: [String: Bool] = [:]
        let fields: [DashboardField] = map.keys.sorted().compactMap { key in
            guard case .bool(let b) = map[key]!, allowed.contains(key) || unified != nil else { return nil }
            original[key] = b
            return .bool(key, DashboardKit.human(key), b)
        }
        if fields.isEmpty { throw EeroError.operation("No editable content-filter settings were returned for this account.") }
        let originalValues = original
        return .form(DashboardForm(title: "Security & content filters", fields: fields) { v, _ in
            var changed: [String: JSON] = [:]
            for f in fields where v.flag(f.key) != originalValues[f.key] { changed[f.key] = .bool(v.flag(f.key)) }
            if changed.isEmpty { return }
            try await model.dashboardChange("POST", url, .object(changed), form: true, success: "Security settings updated.")
        })
    }

    static func blockApps(_ profile: JSON, model: AppModel) async throws -> DashboardSheet {
        let baseURL = try ProfileDetailView.policyURL(profile, model: model) + "/applications"
        let available = try await model.dashboardRead(baseURL)
        let list = DashboardKit.entries(available, "applications", "data")
        if list.isEmpty { return .info("Blocked applications", available) }
        let current = Set(profile.get("premium_dns", "blocked_applications").list.map(\.string))
        var fields: [DashboardField] = []
        for app in list {
            let id = app.first("id", "slug", "name")
            if !id.isEmpty { fields.append(.bool(id, app.first("display_name", "name", "slug"), current.contains(id) || app.b("is_blocked"))) }
        }
        if fields.isEmpty { return .info("Available app controls", available) }
        return .form(DashboardForm(title: "Blocked applications", fields: fields) { v, _ in
            let selected = fields.filter { v.flag($0.key) }.map { JSON.string($0.key) }
            try await model.dashboardChange("PUT", baseURL + "/blocked", JSON.obj(("applications", JSON.array(selected))), success: "Blocked applications updated.")
        })
    }
}

/// Port of `ProfileDevices`: choose which devices belong to a profile.
@MainActor
struct ProfileDevicesSheet: View {
    let profile: JSON
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var checked: Set<String>
    @ViewState private var working = false
    @ViewState private var status = ""

    init(profile: JSON, model: AppModel) {
        self.profile = profile
        self.model = model
        _checked = ViewState(wrappedValue: Set(profile["devices"].list.map { $0.s("url") }))
    }

    /// Network devices plus current members, unique by url.
    private var all: [JSON] {
        var seen = Set<String>(), out: [JSON] = []
        for d in model.devices + profile["devices"].list {
            let u = d.s("url")
            if u.isEmpty || seen.contains(u) { continue }
            seen.insert(u); out.append(d)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assign profile devices").font(.system(size: 24, weight: .semibold))
                    Text("Choose the devices that belong to " + profile.s("name") + ".").font(.system(size: 13)).foregroundStyle(DashboardKit.muted)
                    ForEach(all.map { $0.s("url") }, id: \.self) { u in
                        let d = all.first { $0.s("url") == u } ?? .null
                        Toggle(DashboardDevice(d).name + " · " + d.s("mac"), isOn: Binding(get: { checked.contains(u) }, set: { if $0 { checked.insert(u) } else { checked.remove(u) } }))
                            .toggleStyle(.checkbox)
                    }
                    if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(DashboardKit.danger) }
                    Button("Save device assignments") { save() }.disabled(working).padding(.top, 8)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working) }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 700)
        .interactiveDismissDisabled(working)
    }

    private func save() {
        if working { return }
        working = true
        let selected = all.map { $0.s("url") }.filter { checked.contains($0) }.map { JSON.obj(("url", $0)) }
        Task { @MainActor in
            do {
                try await model.dashboardChange("PUT", profile.s("url"), JSON.obj(("devices", JSON.array(selected))), success: "Profile devices updated.")
                working = false
                dismiss()
            } catch {
                working = false
                status = userMessage(error)
            }
        }
    }
}

/// Port of `DomainDialog`: website block/allow rules for a profile (or the whole network when `profile` is nil).
@MainActor
struct ProfileDomainSheet: View {
    let data: JSON
    let profile: JSON?
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Block & allow websites").font(.system(size: 24, weight: .semibold))
                    Text(profile == nil ? "Applies to the whole network." : "Applies to " + (profile?.s("name") ?? "") + ".")
                        .font(.system(size: 13)).foregroundStyle(DashboardKit.muted)
                    Button("Add or remove a website rule") { present(ruleForm()) }
                    DashboardDetails(value: data)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 700)
    }

    private func ruleForm() -> DashboardSheet {
        let profileId = profile.map { DashboardKit.lastSegment($0.s("url")) }
        return .form(DashboardForm(title: "Website rule", fields: [
            .text("domain", "Domain, e.g. example.com"),
            .choice("list", "Rule", "Block", ["Block", "Allow"]),
            .bool("remove", "Remove this rule instead of adding it", false),
        ]) { v, _ in
            var body = JSON.obj(("domain", try FeatureContracts.domain(v.v("domain"))), ("is_delete", v.flag("remove")))
            if let profileId { body["profiles"] = .array([.string(profileId)]) }
            let path = try model.featureURL("dns_policies/" + (profileId == nil ? "network/" : "profiles/") + (v.v("list") == "Allow" ? "allowed" : "blocked"))
            try await model.dashboardChange("PUT", path, body, success: "Website rule updated.")
        })
    }
}
#endif
