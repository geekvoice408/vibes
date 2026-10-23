#if os(macOS)
import SwiftUI
import EeroCore

/// Wifi, guest wifi, nickname/timezone and advanced-networking pages (port of `NetworkingFeatures.cs`).
enum NetworkingArea: FeatureArea {
    static let routes: Set<String> = [
        "Settings/Wifi name & password",
        "Settings/Guest wifi network",
        "Settings/Nickname & location",
        "Settings/Advanced networking/Internet connection",
        "Settings/Advanced networking/DHCP & NAT",
        "Settings/Advanced networking/DNS",
        "Settings/Advanced networking/Reservations & port forwarding",
        "Settings/Advanced networking/IPv6",
        "Settings/Advanced networking/UPnP",
        "Settings/Advanced networking/Wireless settings",
        "Settings/Advanced networking/Thread",
        "Settings/Advanced networking/Dynamic DNS",
        "Settings/Advanced networking/Power saving",
        "Devices/Blocked devices",
    ]

    static func handles(_ route: String) -> Bool { routes.contains(route) }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        // These loads live in the Windows `LoadFeature` switch (ported as `FeatureLoads`).
        try await FeatureLoads.load(route, model: model)
    }

    static func previewData(_ route: String) -> JSON? { FeatureLoads.previewData(route) }

    static func view(_ route: String, model: AppModel) -> AnyView { AnyView(NetworkingPage(route: route, model: model)) }
}

@MainActor
struct NetworkingPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var sheets = NetSheets()

    private var network: JSON { model.network }
    private var data: JSON? { model.featureData[route] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = FeatureLoads.error(data) {
                FeatureErrorView(message: message, route: route, model: model)
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .netSheets(sheets)
    }

    @ViewBuilder private var page: some View {
            switch route {
            case "Settings/Wifi name & password": wifiPage
            case "Settings/Guest wifi network": guestPage
            case "Settings/Nickname & location": nicknamePage
            case "Settings/Advanced networking/Internet connection": wanPage
            case "Settings/Advanced networking/DHCP & NAT": dhcpPage
            case "Settings/Advanced networking/DNS": dnsPage
            case "Settings/Advanced networking/Reservations & port forwarding": routingPage
            case "Settings/Advanced networking/IPv6": booleanPage("ipv6_upstream", "IPv6", "IPv6 connectivity from your internet provider.")
            case "Settings/Advanced networking/UPnP": booleanPage("upnp", "UPnP", "Allow devices to request port mappings automatically.")
            case "Settings/Advanced networking/Wireless settings": wirelessPage
            case "Settings/Advanced networking/Thread": threadPage
            case "Settings/Advanced networking/Dynamic DNS": ddnsPage
            case "Settings/Advanced networking/Power saving": powerPage
            case "Devices/Blocked devices": blockedPage
            default: EmptyView()
            }
    }

    private func sub(_ text: String) -> some View { NetSubtitle(text: text, route: route) }

    // MARK: Wifi name & password

    /// Port of `WifiPassword`.
    private func wifiPassword(_ url: String) async throws -> String {
        let result = try await model.netRead(url)
        let password: String
        if case .string(let s) = result { password = s } else { password = result.s("password") }
        if password.isEmpty { throw EeroError.operation("eero did not return the wifi password for this account.") }
        return password
    }

    private var wifiPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("Wifi name & password")
            Card { NetDetail("Wifi name", network.s("name")).frame(maxWidth: .infinity, alignment: .leading) }
            NetFlow {
                Button("Change wifi name") {
                    sheets.edit(model, "Wifi name", [NetField("name", "Wifi name", network.s("name"))]) { v in
                        try Validation.validateSsid(v["name"])
                        guard await v.confirm("Change the wifi name? Devices may need to reconnect.") else { return }
                        try await model.netChange("PUT", try model.netURL(), .obj(("name", v["name"].netTrimmed)), form: true, "Wifi name updated.")
                    }
                }
                Button("Change wifi password") {
                    sheets.edit(model, "Wifi password", [.password("password", "New password")]) { v in
                        try Validation.validatePassword(v["password"])
                        guard await v.confirm("Change the wifi password? Devices will need the new password to reconnect.") else { return }
                        try await model.netChange("PUT", try model.netResource("password"), .obj(("password", v["password"])), form: true, "Wifi password updated.")
                    }
                }
                Button("Show password") {
                    model.perform { sheets.password(try await wifiPassword(try model.netResource("password"))) }
                }
                Button("Share QR code") {
                    model.perform { sheets.qr(network.s("name"), try await wifiPassword(try model.netResource("password"))) }
                }
                Button("Copy wifi details") {
                    model.perform {
                        let password = try await wifiPassword(try model.netResource("password"))
                        NetUI.copy("Wifi: " + network.s("name") + "\n" + "Password: " + password)
                        model.setNotice("Wifi details copied to the Mac clipboard.")
                    }
                }
            }
        }
    }

    // MARK: Guest wifi

    @ViewBuilder private var guestPage: some View {
        sub("A separate wifi network for your guests.")
        if let data, !data.isNull {
            let guestURL = NetUI.objectURL(data, (try? model.netResource("guestnetwork")) ?? "") ?? ""
            let passwordURL = model.resource(data, "password", guestURL + "/password")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    NetDetail("Guest network", data.s("name"))
                    NetDetail("Guest access", data.b("enabled") ? "Enabled" : "Disabled")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            NetFlow {
                Button("Edit guest network") {
                    sheets.edit(model, "Guest wifi", [NetField("name", "Guest wifi name", data.s("name")), .bool("enabled", "Enable guest wifi", data.b("enabled"))]) { v in
                        try Validation.validateSsid(v["name"])
                        try await model.netChange("PUT", guestURL, .obj(("name", v["name"].netTrimmed), ("enabled", v.flag("enabled"))), form: true, "Guest network updated.")
                    }
                }
                Button("Change guest password") {
                    sheets.edit(model, "Guest password", [.password("password", "New guest password")]) { v in
                        try Validation.validatePassword(v["password"])
                        try await model.netChange("PUT", passwordURL, .obj(("password", v["password"])), form: true, "Guest password updated.")
                    }
                }
                Button("Show guest password") { model.perform { sheets.password(try await wifiPassword(passwordURL)) } }
                Button("Share guest QR code") { model.perform { sheets.qr(data.s("name"), try await wifiPassword(passwordURL)) } }
            }
        } else {
            Text("Loading guest network…").foregroundStyle(.secondary)
        }
    }

    // MARK: Nickname & location

    private var nicknamePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("Nickname & location")
            NetObjectCard(value: .obj(("nickname", network.first("nickname_label", "nickname")), ("timezone", network["timezone"])))
            NetFlow {
                Button("Change nickname") {
                    sheets.edit(model, "Network nickname", [NetField("label", "Nickname", network.first("nickname_label", "nickname"))]) { v in
                        try Validation.validateName(v["label"])
                        try await model.netChange("PUT", try model.featureURL("label?labelType=specialMarket"), .obj(("label", v["label"].netTrimmed)), form: true, "Network nickname updated.")
                    }
                }
                Button("Change timezone") {
                    let current = network.s("timezone", "value").nilIfEmpty ?? network.s("timezone")
                    sheets.edit(model, "Network timezone", [NetField("timezone", "IANA timezone, e.g. America/Chicago", current)]) { v in
                        let zone = v["timezone"].netTrimmed
                        if zone.range(of: #"^[A-Za-z_+-]+(?:/[A-Za-z0-9_+-]+){1,2}$|^UTC$"#, options: .regularExpression) == nil {
                            throw EeroError.argument("Enter an IANA timezone such as America/Chicago.")
                        }
                        guard await v.confirm("Change the network timezone? Scheduled pauses will follow the new timezone.") else { return }
                        try await model.netChange("PUT", try model.netResource("settings"), .obj(("timezone", JSON.obj(("value", zone)))), "Timezone updated.")
                    }
                }
            }
        }
    }

    // MARK: Internet connection

    private var wanPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("Internet connection")
            NetObjectCard(value: .obj(("connection", network["connection"]), ("ip_settings", network["ip_settings"]), ("lease", network["lease"]),
                                      ("ipv6_lease", network["ipv6_lease"]), ("pppoe_enabled", network["pppoe_enabled"]), ("pppoe_username", network["pppoe_username"])))
            Button("Configure WAN addressing") { editWanAddress() }
            SectionLink(title: "PPPoE & ISP VLAN settings", route: "Settings/Advanced networking/Internet connection/ISP settings", model: model)
        }
    }

    /// Port of `EditWanAddress`.
    private func editWanAddress() {
        let lease = network["lease"], stat = lease["static"]
        sheets.edit(model, "Internet addressing", [
            .choice("mode", "WAN address assignment", lease.s("mode") == "static" ? "Static IP" : "DHCP", ["DHCP", "Static IP"]),
            NetField("ip", "Static IPv4 address", stat.s("ip")),
            NetField("mask", "Subnet mask", stat.s("mask")),
            NetField("router", "Router / gateway", stat.s("router")),
        ]) { v in
            let isStatic = v["mode"] == "Static IP"
            var body = JSON.obj(("mode", isStatic ? "static" : "dhcp"))
            if isStatic {
                body["static"] = .obj(("ip", try FeatureContracts.address(v["ip"], .inet)), ("mask", try FeatureContracts.address(v["mask"], .inet)),
                                      ("router", try FeatureContracts.address(v["router"], .inet)))
            }
            guard await v.confirm("Apply the internet addressing settings supplied by your ISP? Incorrect values can disconnect the network.") else { return }
            try await model.netChange("PUT", try model.netResource("settings"), .obj(("lease", body)), "Internet addressing updated.")
        }
    }

    // MARK: DNS

    private var dnsPage: some View {
        let dns = network["dns"]
        return VStack(alignment: .leading, spacing: 12) {
            sub("DNS and local DNS caching")
            NetObjectCard(value: dns)
            SectionLink(title: "DNS performance", route: "Settings/Advanced networking/DNS/DNS performance", model: model)
            Button("Edit DNS settings") {
                let servers = dns.get("custom", "ips").list.map(\.string).joined(separator: "\n")
                sheets.edit(model, "DNS", [
                    .choice("mode", "DNS servers", dns.s("mode") == "custom" ? "Custom" : "ISP default", ["ISP default", "Custom"]),
                    NetField("servers", "Custom DNS server IP addresses (one per line)", servers, .multiline),
                    .bool("caching", "Local DNS caching", dns.b("caching")),
                ]) { v in
                    let body = try FeatureContracts.dns(v["mode"] == "Custom", v["servers"], v.flag("caching"))
                    guard await v.confirm("Apply DNS settings? eero may restart the network. Advanced Security can prevent custom DNS.") else { return }
                    try await model.netChange("PUT", try model.netResource("settings"), body, "DNS settings updated.")
                }
            }
        }
    }

    // MARK: DHCP & NAT

    private var dhcpPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("DHCP & NAT")
            NetObjectCard(value: .obj(("connection", network["connection"]), ("dhcp", network["dhcp"]), ("nat_port_randomization", network["nat_port_randomization"])))
            Button("Edit DHCP & NAT") {
                let mode = network.s("connection", "mode") == "bridged" ? "Bridge" : network.s("dhcp", "mode") == "custom" ? "Manual" : "Automatic"
                sheets.edit(model, "DHCP & NAT", [
                    .choice("mode", "Mode", mode, ["Automatic", "Manual", "Bridge"]),
                    NetField("subnet", "Manual subnet network address", network.s("dhcp", "custom", "subnet_ip")),
                    NetField("mask", "Manual subnet mask", network.s("dhcp", "custom", "subnet_mask")),
                    NetField("first", "First DHCP address", network.s("dhcp", "custom", "start_ip")),
                    NetField("last", "Last DHCP address", network.s("dhcp", "custom", "end_ip")),
                    .bool("randomization", "NAT port randomization", network.b("nat_port_randomization")),
                ]) { v in
                    let selected = v["mode"] == "Bridge" ? "bridge" : v["mode"] == "Manual" ? "custom" : "automatic"
                    let body = try FeatureContracts.dhcp(selected, v["subnet"], v["mask"], v["first"], v["last"], v.flag("randomization"))
                    guard await v.confirm("Apply DHCP & NAT settings? The network may restart. Bridge mode disables routing, profiles and some security features.") else { return }
                    try await model.netChange("PUT", try model.netResource("settings"), body, "DHCP & NAT settings updated.")
                }
            }
        }
    }

    // MARK: IPv6 / UPnP

    /// Port of `NetworkBooleanPage`.
    @ViewBuilder private func booleanPage(_ key: String, _ title: String, _ description: String) -> some View {
        sub(description)
        if case .bool(let on) = network[key] {
            Card { Text(title + ": " + (on ? "On" : "Off")).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading) }
            Button("Change " + title) {
                sheets.edit(model, title, [.bool(key, "Enable " + title, on)]) { v in
                    guard await v.confirm("Apply " + title + " settings? Some devices may reconnect.") else { return }
                    try await model.netChange("PUT", try model.netResource("settings"), .obj((key, v.flag(key))), title + " updated.")
                }
            }
        } else {
            Card { Text("eero did not report this setting for the selected network.").frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    // MARK: Wireless settings

    private var wirelessFields: [NetField] {
        ["wpa3", "band_steering", "sqm", "ffs"].compactMap { key -> NetField? in
            guard case .bool(let on) = network[key] else { return nil }
            let label = key == "band_steering" ? "Client steering" : key == "wpa3" ? "WPA3 security" : key == "ffs" ? "Amazon Frustration-Free Setup" : NetUI.human(key)
            return .bool(key, label, on)
        }
    }

    private var wirelessPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("Wireless settings")
            SectionLink(title: "Fast roaming", route: "Settings/Advanced networking/Wireless settings/Fast roaming", model: model)
            NetObjectCard(value: .obj(("wpa3", network["wpa3"]), ("client_steering", network["band_steering"]), ("optimization", network["sqm"]), ("multi_link_operation", network["mlo_mode"])))
            if !wirelessFields.isEmpty {
                Button("Edit wireless options") {
                    let fields = wirelessFields
                    let snapshot = network
                    sheets.edit(model, "Wireless options", fields) { v in
                        var body = JSON.object([:])
                        for f in fields where v.flag(f.key) != snapshot.b(f.key) { body[f.key] = .bool(v.flag(f.key)) }
                        if body.object?.isEmpty ?? true { return }
                        guard await v.confirm("Apply these wireless options? Devices may briefly reconnect.") else { return }
                        try await model.netChange("PUT", try model.netResource("settings"), body, "Wireless options updated.")
                    }
                }
            }
            Button("Legacy compatibility mode") {
                model.perform {
                    let url = try model.featureURL("ac_compat")
                    let value = try await model.netRead(url)
                    sheets.edit(model, "Legacy compatibility", [.bool("enabled", "Enable legacy compatibility", value.b("enabled"))]) { v in
                        try await model.netChange("PUT", url, .obj(("enabled", v.flag("enabled"))), form: true, "Compatibility setting updated.")
                    }
                }
            }
            if !network["mlo_mode"].isNull {
                Button("Multi-link operation") {
                    sheets.edit(model, "Multi-link operation", [.choice("mlo_mode", "Mode", network.s("mlo_mode"), ["disabled", "single", "multi"])]) { v in
                        guard await v.confirm("Change multi-link operation? Connected devices may reconnect.") else { return }
                        try await model.netChange("PUT", try model.featureURL("mlo_mode"), .obj(("mlo_mode", v["mlo_mode"])), "Multi-link operation updated.")
                    }
                }
            }
            NetFlow {
                Button("Security by radio band") { model.perform { try await bandSecurity() } }
                Button("Radio settings") { model.perform { sheets.info("Radio settings", try await model.netRead(try model.featureURL("radio_settings"))) } }
                Button("Channel utilization") {
                    model.perform { sheets.info("Channel utilization", try await model.netRead(try model.featureURL("channel_utilization?") + NetUI.statsRange(1))) }
                }
            }
        }
    }

    /// Port of `BandSecurity`.
    private func bandSecurity() async throws {
        let path = try model.featureURL("wpa3_per_band")
        let data = try await model.netRead(path)
        let modes = ["WPA2", "WPA2_WPA3", "WPA3"]
        sheets.edit(model, "Security by radio band", [
            .choice("band_2_4_ghz", "2.4 GHz security", data.s("band_2_4_ghz"), modes),
            .choice("band_5_ghz", "5 GHz security", data.s("band_5_ghz"), modes),
        ], description: "6 GHz uses WPA3 as required by that band; this endpoint edits the 2.4 and 5 GHz modes.") { v in
            guard await v.confirm("Change wifi authentication modes? Some devices may need to reconnect or may not support the new mode.") else { return }
            try await model.netChange("PUT", path, .obj(("band_2_4_ghz", v["band_2_4_ghz"]), ("band_5_ghz", v["band_5_ghz"])), "Per-band wifi security updated.")
        }
    }

    // MARK: Thread

    private var threadPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("Thread smart-home network")
            NetObjectCard(value: data)
            NetFlow {
                Button("View Thread credentials") {
                    model.netLocal {
                        let values: [(String, String)]
                        if model.preview { values = [("Thread dataset", "Sample-only-dataset")] }
                        else { values = try NetworkingPage.threadCredentials(data ?? .null) }
                        sheets.credentials("Thread credentials", values)
                    }
                }
                Button("Regenerate Thread credentials") {
                    model.perform {
                        guard await model.confirm("Regenerate this Thread network's credentials? Thread devices may need to be paired again.") else { return }
                        try await model.netChange("POST", try model.featureURL("thread"), nil, "Thread credential regeneration requested.")
                    }
                }
            }
            Button("Edit Thread settings") {
                sheets.edit(model, "Thread", [
                    .bool("thread_enable", "Enable Thread network", network.b("thread")),
                    .bool("enable_credential_syncing", "Sync Thread credentials", (data ?? .null).b("enable_credential_syncing")),
                ]) { v in
                    try await model.netChange("PUT", try model.featureURL("thread"), .obj(("thread_enable", v.flag("thread_enable")), ("enable_credential_syncing", v.flag("enable_credential_syncing"))), "Thread settings updated.")
                }
            }
        }
    }

    /// `EverydayContracts.threadCredentials`, in the original key order.
    static func threadCredentials(_ data: JSON) throws -> [(String, String)] {
        let values = try EverydayContracts.threadCredentials(data)
        let order = ["active operational dataset", "commissioning credential", "master key"]
        return values.sorted { (order.firstIndex(of: $0.key) ?? order.count, $0.key) < (order.firstIndex(of: $1.key) ?? order.count, $1.key) }
            .map { ($0.key, $0.value) }
    }

    // MARK: Dynamic DNS

    private var ddnsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("Dynamic DNS requires an eligible eero subscription.")
            NetObjectCard(value: network["dynamic_dns"])
            NetFlow {
                Button("Enable Dynamic DNS") { model.perform { try await model.netChange("PUT", try model.featureURL("ddns/enable"), nil, "Dynamic DNS enabled.") } }
                Button("Disable Dynamic DNS") {
                    model.perform {
                        guard await model.confirm("Disable Dynamic DNS for this network?") else { return }
                        try await model.netChange("PUT", try model.featureURL("ddns/disable"), nil, "Dynamic DNS disabled.")
                    }
                }
            }
        }
    }

    // MARK: Reservations & port forwarding

    @ViewBuilder private var routingPage: some View {
        sub("IPv4 reservations & port forwards / IPv6 firewall rules")
        if network.s("connection", "mode") == "bridged" {
            Card { Text("These routing features require eero to run in Automatic or Manual NAT mode.").frame(maxWidth: .infinity, alignment: .leading) }
        } else if let data, !data.isNull {
            ForEach(["reservations", "forwards", "pinholes"], id: \.self) { kind in
                let list = data[kind].list
                Text(kind == "reservations" ? "IPv4 reservations" : kind == "forwards" ? "Port forwards" : "IPv6 firewall rules").font(.title3.bold()).padding(.top, 6)
                ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            NetDetails.view(item)
                            NetFlow {
                                Button("Edit") { model.netLocal { try routingEdit(kind, item, data) } }
                                Button("Delete") {
                                    model.perform {
                                        guard await model.confirm(kind == "reservations" ? "Delete this reservation and its associated port forwards?" : "Delete this rule?") else { return }
                                        guard let url = NetUI.objectURL(item) else { throw EeroError.operation("eero did not provide an edit URL for this entry.") }
                                        try await model.netChange("DELETE", url + (kind == "reservations" ? "?delete_forwards=true" : ""), nil, "Rule deleted.")
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if list.isEmpty { Text("No entries returned.").font(.callout).foregroundStyle(.secondary) }
                Button(kind == "reservations" ? "Add reservation" : kind == "forwards" ? "Open a port" : "Add IPv6 firewall rule") {
                    model.netLocal { try routingEdit(kind, nil, data) }
                }
            }
        } else {
            Text("Loading network rules…").foregroundStyle(.secondary)
        }
    }

    /// Port of `RoutingEdit`.
    private func routingEdit(_ kind: String, _ item: JSON?, _ rules: JSON) throws {
        let edit = item != nil
        let it = item ?? .null
        let container = try rules.s(kind, "url").nilIfEmpty ?? (kind == "pinholes" ? model.featureURL("ipv6/pinholes") : model.netResource(kind))
        let url = edit ? (NetUI.objectURL(it) ?? "") : container
        let method = edit ? "PUT" : "POST"
        if kind == "reservations" {
            sheets.edit(model, edit ? "Edit reservation" : "Add reservation", [
                NetField("name", "Nickname", it.s("description")), NetField("mac", "MAC address", it.s("mac")), NetField("ip", "Reserved IPv4 address", it.s("ip")),
            ]) { v in
                try await model.netChange(method, url, try FeatureContracts.reservation(v["name"], v["mac"], v["ip"]), "Reservation saved.")
            }
        } else if kind == "forwards" {
            sheets.edit(model, edit ? "Edit port forward" : "Open a port", [
                NetField("description", "Nickname", it.s("description")),
                NetField("ip", "Device IPv4 address", it.s("ip")),
                NetField("gateway_port", "External port or range", it.s("gateway_port")),
                NetField("client_port", "Internal port or range", it.s("client_port")),
                .choice("protocol", "Protocol", it.s("protocol").nilIfEmpty ?? "tcp", ["tcp", "udp", "both"]),
                .bool("enabled", "Enabled", !edit || it.b("enabled")),
            ]) { v in
                let body = try FeatureContracts.forward(v["ip"], v["gateway_port"], v["client_port"], v["protocol"], v["description"], v.flag("enabled"))
                guard await v.confirm("Save this port forward? It allows matching inbound internet traffic to the selected device.") else { return }
                try await model.netChange(method, url, body, "Port forward saved.")
            }
        } else {
            var choices: [(String, String)] = []
            for d in model.devices where !d.s("url").isEmpty {
                let label = NetUI.deviceName(d) + " · " + d.s("mac")
                if !choices.contains(where: { $0.0 == label }) { choices.append((label, d.s("url"))) }
            }
            if choices.isEmpty { throw EeroError.operation("No device URLs were returned for an IPv6 rule.") }
            let chosen = choices.first(where: { $0.1 == it.s("device") })?.0 ?? choices[0].0
            let lookup = Dictionary(choices, uniquingKeysWith: { a, _ in a })
            sheets.edit(model, edit ? "Edit IPv6 firewall rule" : "IPv6 firewall rule", [
                .choice("device", "Device", chosen, choices.map(\.0)),
                .choice("protocol", "Protocol", it.s("protocol").nilIfEmpty ?? "tcp", ["tcp", "udp", "both"]),
                NetField("port", "Port or range", it.s("port")),
            ]) { v in
                let body = JSON.obj(("device", lookup[v["device"]] ?? ""), ("protocol", v["protocol"]), ("port", try FeatureContracts.portRange(v["port"])))
                guard await v.confirm("Allow this inbound IPv6 traffic to the selected device?") else { return }
                try await model.netChange(method, url, body, "IPv6 firewall rule saved.")
            }
        }
    }

    // MARK: Power saving

    private var powerPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sub("Power optimization and scheduled power saving.")
            NetFlow {
                Button("Power saving options") {
                    sheets.edit(model, "Power saving", [
                        .bool("enable", "Enable power saving", network.b("power_saving")),
                        .bool("scheduled", "Enable scheduled power saving", network.b("power_saving_schedule_enabled")),
                    ]) { v in
                        try await model.netChange("PUT", try model.featureURL("power_saving"), .obj(("enable", v.flag("enable")), ("power_saving_schedule_enabled", v.flag("scheduled"))), "Power saving updated.")
                    }
                }
                Button("Add power schedule") { model.netLocal { NetSchedule.edit(sheets, model, nil, try model.featureURL("power_saving/schedules"), power: true) } }
            }
            ForEach(Array(NetUI.entries(data, "schedules").enumerated()), id: \.offset) { _, item in
                let url = NetUI.objectURL(item, (try? model.featureURL("power_saving/schedules/" + item.first("id", "schedule_id"))) ?? "") ?? ""
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        NetDetails.view(item)
                        NetFlow {
                            Button("Edit schedule") { NetSchedule.edit(sheets, model, item, url, power: true) }
                            Button("Delete schedule") {
                                model.perform {
                                    guard await model.confirm("Delete this power saving schedule?") else { return }
                                    try await model.netChange("DELETE", url, nil, "Schedule deleted.")
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Blocked devices

    private var blockedPage: some View {
        let list = NetUI.entries(data, "devices")
        return VStack(alignment: .leading, spacing: 12) {
            sub("Blocked devices")
            ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NetUI.deviceName(item)).font(.title3.bold())
                        NetDetail("MAC address", item.s("mac"))
                        Button("Unblock device") {
                            model.perform {
                                guard await model.confirm("Allow this device to access your network?") else { return }
                                try await model.netChange("DELETE", try model.featureURL("blacklist/" + NetUI.escape(item.s("mac"))), nil, "Device unblocked.")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let data, !data.isNull, list.isEmpty { Text("No blocked devices returned.").foregroundStyle(.secondary) }
        }
    }
}

/// Port of `ScheduleEdit` (scheduled pauses and power-saving schedules).
@MainActor
enum NetSchedule {
    static func edit(_ sheets: NetSheets, _ model: AppModel, _ item: JSON?, _ url: String, power: Bool = false) {
        let it = item ?? .null
        let days = Set(it["days"].list.map(\.string))
        var fields: [NetField] = [
            NetField("name", "Schedule name", it.s("name")),
            NetField("start", "Start time (24-hour HH:mm)", it.s(power ? "start_time" : "start").nilIfEmpty ?? "22:00"),
            NetField("end", "End time (24-hour HH:mm)", it.s(power ? "end_time" : "end").nilIfEmpty ?? "07:00"),
            .bool("enabled", "Enabled", item == nil || it.b("enabled")),
        ]
        for day in FeatureContracts.scheduleDays { fields.append(.bool(day, NetUI.human(day.lowercased()), days.contains(day))) }
        sheets.edit(model, item == nil ? "Add schedule" : "Edit schedule", fields,
                    description: "Times follow the network timezone. End times earlier than start times continue into the next day.") { v in
            let selected = FeatureContracts.scheduleDays.filter { v.flag($0) }
            let body = try FeatureContracts.schedule(v["name"], selected, v["start"], v["end"], v.flag("enabled"), power: power)
            try await model.netChange(item == nil ? "POST" : "PUT", url, body, "Schedule saved.")
        }
    }
}
#endif
