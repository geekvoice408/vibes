#if os(macOS)
import SwiftUI
import EeroCore

// MARK: - Internet backup

@MainActor
struct BackupPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        let points = FeatureLoads.entries(data["access_points"], "access_points")
        FeatureSub("Internet backup", route: route)
        ObjectCards(data["status"], "Backup status")
        FeatureSectionButton("Find backup wifi", "Settings/Advanced networking/Internet backup/Find backup wifi", model: model)
        Button("Backup wifi priority") { model.runLocal { try ManagementArea.backupPriority(model, points) } }
        FeatureActionRow {
            Button("Backup options") {
                let model = self.model
                model.edit("Internet backup", [Field("enabled", "Enable backup internet", data.b("status", "backup_internet_enabled"), .bool)]) { v in
                    try await model.change("PUT", try model.featureURL("backupinternet"), .obj(("backup_internet_enabled", v.flag("enabled"))),
                                           message: "Backup internet updated.")
                }
            }
            Button("Add backup wifi") { ManagementArea.backupEdit(model, nil) }
            Button("Test backup connectivity") {
                model.perform {
                    if model.preview { throw EeroError.operation("Sign in to test backup connectivity.") }
                    try await model.api.send("POST", try model.featureURL("backup_access_points/connectivity_check"))
                    model.setNotice("Backup connectivity check requested. Refresh this page for results.")
                }
            }
        }
        ForEach(points.indices, id: \.self) { i in
            let item = points[i]
            FeatureCard {
                ObjectDetailsView(value: item)
                FeatureActionRow {
                    Button("Edit") { ManagementArea.backupEdit(model, item) }
                    Button("Remove backup") {
                        model.perform {
                            if !(await model.confirm("Remove this backup wifi network?")) { return }
                            try await model.change("DELETE", try model.featureURL("backup_access_points/" + FeatureLoads.escape(item.s("uuid"))), nil,
                                                   message: "Backup wifi removed.")
                        }
                    }
                }
            }
        }
        FeatureActionRow {
            Button("Discover backup wifi networks") {
                model.perform {
                    if model.preview { throw EeroError.operation("Sign in to discover backup networks.") }
                    try await model.api.send("POST", try model.featureURL("backup_access_points/ssid_discovery"))
                    model.setNotice("Discovery requested. Use Discovery results shortly.")
                }
            }
            Button("Discovery results") {
                model.perform { model.info("Backup wifi discovery", try await model.read(try model.featureURL("backup_access_points/ssid_discovery"))) }
            }
        }
    }
}

extension ManagementArea {
    /// Port of `BackupEdit(data, discoveredSsid)`: adds (`data == nil`) or edits a backup wifi network.
    /// Also used by the "Find backup wifi" page ("Use as backup").
    @MainActor
    static func backupEdit(_ model: AppModel, _ data: JSON?, discoveredSsid: String? = nil) {
        let existing = data.flatMap { $0.isNull ? nil : $0 }
        model.edit(existing == nil ? "Add backup wifi" : "Edit backup wifi", [
            Field("ssid", "Backup wifi name", discoveredSsid ?? existing?.s("ssid") ?? ""),
            Field("password", "Backup wifi password", nil, .password),
            Field("enabled", "Enabled", existing == nil || existing!.b("enabled"), .bool),
        ], description: existing == nil ? "Use a backup hotspot that your eero can reach." : "Leave the password blank to keep the existing password.") { v in
            try Validation.validateSsid(v["ssid"])
            if existing == nil || !v["password"].isEmpty { try Validation.validatePassword(v["password"]) }
            let id = existing == nil ? UUID().uuidString.lowercased() : existing!.s("uuid")
            var body = JSON.obj(("ssid", v["ssid"].trimmingCharacters(in: .whitespacesAndNewlines)), ("uuid", id))
            if existing != nil { body["enabled"] = .bool(v.flag("enabled")) }
            if !v["password"].isEmpty { body["password"] = .string(v["password"]) }
            try await model.change(existing == nil ? "POST" : "PUT",
                                   try model.featureURL("backup_access_points" + (existing == nil ? "" : "/" + FeatureLoads.escape(id))),
                                   body, message: "Backup wifi saved.")
        }
    }

    /// Port of `BackupPriority` (EverydayFeatures.cs), used by the Internet backup page.
    @MainActor
    static func backupPriority(_ model: AppModel, _ networks: [JSON]) throws {
        if networks.count < 2 { throw EeroError.operation("Save at least two backup wifi networks to choose their priority.") }
        let id = UUID()
        FeatureDialogs.shared.show(.custom(id: id, title: "Backup wifi priority",
                                           content: AnyView(ManagementBackupPriority(model: model, networks: networks) { FeatureDialogs.shared.close(id) })))
    }
}

/// Reorders saved backup wifi networks (highest priority first) and saves the order.
@MainActor
struct ManagementBackupPriority: View {
    @ObservedObject var model: AppModel
    @State private var ordered: [JSON]
    @State private var selected: Int? = 0
    @State private var status = ""
    @State private var working = false
    let done: () -> Void

    init(model: AppModel, networks: [JSON], done: @escaping () -> Void) {
        self.model = model; self.done = done
        _ordered = State(initialValue: networks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureNote("Move the preferred backup to the top. All saved backups stay in the order.", size: 14)
            List(selection: $selected) {
                Section("Backup wifi (highest priority first)") {
                    ForEach(ordered.indices, id: \.self) { i in Text(ordered[i].s("ssid")).tag(Optional(i)) }
                }
            }
            .frame(height: 240)
            HStack {
                Button("Move up") { move(-1) }
                Button("Move down") { move(1) }
            }
            if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(.red) }
            Button("Save priority") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(working)
        }
        .interactiveDismissDisabled(working)
    }

    private func move(_ offset: Int) {
        guard let from = selected else { return }
        let to = from + offset
        if from < 0 || to < 0 || to >= ordered.count { return }
        let item = ordered.remove(at: from)
        ordered.insert(item, at: to)
        selected = to
    }

    private func save() {
        if working { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                if model.preview { throw EeroError.operation("Preview mode is read only.") }
                try await model.change("POST", try model.featureURL("backup_access_points/rearrange"),
                                       try EverydayContracts.backupOrder(ordered.map { $0.s("uuid") }), message: "Backup priority saved.")
                done()
            } catch {
                status = userMessage(error)
            }
        }
    }
}

// MARK: - Multi-WAN

@MainActor
struct MultiWanPage: View {
    let route: String
    @ObservedObject var model: AppModel
    let data: JSON

    var body: some View {
        let links = FeatureLoads.entries(data, "links")
        FeatureSub("Multi-WAN is available only on supported gateways and firmware.", route: route)
        ObjectCards(data, "WAN links")
        FeatureActionRow {
            Button("Discover WAN links") {
                model.perform { model.info("Discovered WAN links", try await model.read(try model.featureURL("wan/discover"))) }
            }
            Button("WAN limits") {
                model.perform { model.info("WAN limits", try await model.read(try model.featureURL("wan/limits"))) }
            }
            Button("WAN mode") { wanMode() }
        }
        ForEach(links.indices, id: \.self) { i in
            let link = links[i]
            let id = link.s("link_id")
            if !id.isEmpty {
                FeatureCard {
                    Text(link.first("name", "link_id")).font(.system(size: 19, weight: .semibold))
                    ObjectDetailsView(value: link)
                    FeatureActionRow {
                        Button("Connection details") {
                            model.perform { model.info("WAN link", try await model.read(try model.featureURL("wan/links/" + FeatureLoads.escape(id)))) }
                        }
                        Button("Name & priority") { ManagementArea.editWanPriority(model, link, links) }
                        Button("Remove link") {
                            model.perform {
                                if !(await model.confirm("Remove this WAN link? It may be your active internet connection.")) { return }
                                try await model.change("DELETE", try model.featureURL("wan/links/" + FeatureLoads.escape(id)), nil, message: "WAN link removed.")
                            }
                        }
                    }
                }
            }
        }
        Button("Add WAN link") { model.runLocal { try addLink() } }
    }

    private func wanMode() {
        let model = self.model
        model.edit("WAN mode", [Field("mode", "Routing mode", "Automatic failover", .choice, "Automatic failover", "Strict", "Legacy")]) { v in
            let mode = v["mode"] == "Strict" ? "MULTI_WAN_STRICT" : v["mode"] == "Legacy" ? "MULTI_WAN_LEGACY" : "MULTI_WAN_AUTOMATIC"
            if !(await v.confirm("Change WAN routing mode? Internet connectivity may be interrupted.")) { return }
            try await model.change("PUT", try model.featureURL("wan/enable_multi_wan"), .obj(("wan_mode", mode)), message: "WAN mode updated.")
        }
    }

    private func addLink() throws {
        let model = self.model
        var labels: [String] = []
        var ids: [String: String] = [:]
        for n in model.nodes {
            let url = n.s("url")
            if url.isEmpty { continue }
            let last = url.split(separator: "/").last.map(String.init) ?? ""
            let label = n.first("location", "model") + " · " + last
            if ids[label] == nil { labels.append(label); ids[label] = last }
        }
        if labels.isEmpty { throw EeroError.operation("No eero node identifiers were returned.") }
        model.edit("Add WAN link", [
            Field("name", "Connection name"),
            Field("node", "Gateway eero", labels[0], .choice, choices: labels),
            Field("port", "Ethernet port number"),
            Field("priority", "Priority", "1"),
            Field("type", "Internet connection type", "DHCP", .choice, "DHCP", "Static IP", "PPPoE"),
            Field("vlan", "VLAN ID (optional)"),
            Field("ip", "Static IPv4 address (Static IP only)"),
            Field("mask", "Static subnet mask (Static IP only)"),
            Field("gateway", "Static gateway IPv4 (Static IP only)"),
            Field("username", "PPPoE username (PPPoE only)"),
            Field("password", "PPPoE password (PPPoE only)", nil, .password),
        ], submit: "Add link") { v in
            try Validation.validateName(v["name"])
            func int(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces)) }
            guard let node = ids[v["node"]].flatMap(int),
                  let port = int(v["port"]), (0...48).contains(port),
                  let priority = int(v["priority"]), (0...100).contains(priority) else {
                throw EeroError.argument("Enter valid port and priority values.")
            }
            let connectionType = v["type"] == "Static IP" ? "STATIC_IP" : v["type"] == "PPPoE" ? "PPPOE" : "DHCP"
            var body = JSON.obj(("name", v["name"].trimmingCharacters(in: .whitespacesAndNewlines)), ("eero_id", node), ("port_number", port),
                                ("priority", priority), ("connection_type", connectionType))
            if connectionType == "STATIC_IP" {
                body["static_ip"] = .obj(
                    ("static_ip", try FeatureContracts.address(v["ip"], .inet)),
                    ("subnet_mask", try FeatureContracts.address(v["mask"], .inet)),
                    ("gateway_ip", try FeatureContracts.address(v["gateway"], .inet)))
            }
            if connectionType == "PPPOE" {
                if v["username"].isEmpty || v["password"].isEmpty { throw EeroError.argument("Enter the PPPoE username and password supplied by your ISP.") }
                body["pppoe"] = .obj(("username", v["username"]), ("password", v["password"]))
            }
            if !v["vlan"].isEmpty {
                guard let vlan = int(v["vlan"]), (1...4094).contains(vlan) else { throw EeroError.argument("VLAN IDs must be between 1 and 4094.") }
                body["vlan_id"] = .string(String(vlan))
            }
            if !(await v.confirm("Add this DHCP WAN link?")) { return }
            try await model.change("POST", try model.featureURL("wan/links"), body, message: "WAN link added.")
        }
    }
}

extension ManagementArea {
    /// Port of `EditWanPriority`: renames a WAN link and moves it to a new priority position.
    @MainActor
    static func editWanPriority(_ model: AppModel, _ link: JSON, _ links: [JSON]) {
        func priority(_ x: JSON) -> Int { Int(x.s("priority")) ?? 0 }
        // Stable ordering by priority, like LINQ OrderBy.
        let ordered = links.enumerated().sorted { a, b in
            priority(a.element) != priority(b.element) ? priority(a.element) < priority(b.element) : a.offset < b.offset
        }.map(\.element)
        let linkId = link.s("link_id")
        let position = (ordered.firstIndex { $0.s("link_id") == linkId } ?? -1) + 1
        model.edit("WAN name & priority", [
            Field("name", "Connection name", link.s("name")),
            Field("position", "Priority position (1 is highest)", String(position)),
        ]) { v in
            try Validation.validateName(v["name"])
            guard let index = Int(v["position"].trimmingCharacters(in: .whitespaces)), index >= 1, index <= ordered.count else {
                throw EeroError.argument("Enter a priority position between 1 and \(ordered.count).")
            }
            var others = ordered.filter { $0.s("link_id") != linkId }
            others.insert(link, at: min(index - 1, others.count))
            let baseline = Int(ordered.first?.s("priority") ?? "") ?? 0
            var updates: [JSON] = []
            for (i, item) in others.enumerated() {
                let isLink = item.s("link_id") == linkId
                var entry = JSON.obj(("link_id", item.s("link_id")),
                                     ("name", isLink ? v["name"].trimmingCharacters(in: .whitespacesAndNewlines) : item.s("name")),
                                     ("priority", baseline + i))
                if !item["metadata"].isNull { entry["metadata"] = item["metadata"] }
                updates.append(entry)
            }
            if !(await v.confirm("Apply the WAN priorities? This can switch your active internet connection.")) { return }
            try await model.change("PUT", try model.featureURL("wan/links"), .obj(("links", JSON.array(updates))), message: "WAN names and priorities updated.")
        }
    }
}
#endif
