#if os(macOS)
import SwiftUI
import EeroCore

/// Routes rendered by the dashboard pages. Ports the `RenderPage` / `RenderFeature` cases for
/// Overview, Devices, eero nodes, Profiles, Activity, Help, the profile and eero detail pages and the
/// product gallery, and the matching `LoadFeature` cases ("Home/Profiles/Profile", "Home/eeros/Details").
enum DashboardArea: FeatureArea {
    static let routes: Set<String> = ["Home", "Overview", "Devices", "eero nodes", "Home/eeros", "Profiles", "Home/Profiles",
                                      "Home/Profiles/Profile", "Home/eeros/Details", "Activity", "Help", "Product gallery"]

    static func handles(_ route: String) -> Bool { routes.contains(route) }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        // Shared with FeatureLoads (port of the LoadFeature cases for the detail pages).
        if route == "Home/Profiles/Profile" || route == "Home/eeros/Details" { return try await FeatureLoads.load(route, model: model) }
        return nil
    }

    static func view(_ route: String, model: AppModel) -> AnyView {
        switch route {
        case "Home", "Overview": return AnyView(OverviewView(model: model))
        case "Devices": return AnyView(DevicesView(model: model))
        case "eero nodes", "Home/eeros": return AnyView(NodesView(model: model))
        case "Profiles", "Home/Profiles": return AnyView(ProfilesView(model: model))
        case "Home/Profiles/Profile": return AnyView(ProfileDetailView(model: model))
        case "Home/eeros/Details": return AnyView(NodeDetailView(model: model))
        case "Activity": return AnyView(ActivityView(model: model))
        case "Help": return AnyView(HelpView(model: model))
        case "Product gallery": return AnyView(ProductGalleryView(model: model))
        default: return AnyView(EmptyView())
        }
    }
}

/// Actions shared by the eero cards.
@MainActor
enum NodeActions {
    /// Port of the "Rename" button (`Prompt("eero location", …)`).
    static func rename(_ node: JSON, model: AppModel) -> DashboardSheet {
        .form(DashboardForm(title: "eero location", fields: [.text("location", "", node.s("location"))]) { v, _ in
            let name = v.v("location")
            try DashboardKit.validateName(name)
            try await model.dashboardChange("PUT", node.s("url"), JSON.obj(("location", name.trimmingCharacters(in: .whitespacesAndNewlines))), form: true, success: "eero location updated.")
        })
    }

    /// Port of the "Restart eero" context-menu item on the node card.
    static func restart(_ node: JSON, model: AppModel) {
        model.perform("Restarting eero…") {
            guard await model.confirm("Restart " + node.first("location", "model") + "? Connected devices may briefly lose internet access.") else { return }
            if model.preview { throw EeroError.operation("Preview mode is read only.") }
            try await model.api.send("POST", node.s("url") + "/reboot")
            model.setNotice("Restart requested. Wait a few minutes, then refresh.")
        }
    }

    static func openDetails(_ node: JSON, model: AppModel) {
        if model.busy { return }
        model.selectedNode = node
        model.navigate("Home/eeros/Details")
    }
}

/// Port of `NodePage` (routes "eero nodes" and "Home/eeros").
struct NodesView: View {
    @ObservedObject var model: AppModel
    @ViewState private var sheet: DashboardSheet? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Subtitle("Inspect your mesh nodes and restart an individual eero.")
            DashboardAvailability(key: "eero nodes", model: model)
            SectionLink(title: "Placement tests", route: "Home/eeros/Placement tests")
            ForEach(Array(model.nodes.enumerated()), id: \.offset) { _, node in
                NodeCard(node: node, model: model, sheet: $sheet)
            }
            if model.nodes.isEmpty && model.loadErrors["eero nodes"] == nil {
                Card { Text("No eero nodes were returned.").frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .dashboardSheet($sheet, model: model)
    }
}

/// Port of `NativeNodeCard`.
struct NodeCard: View {
    let node: JSON
    @ObservedObject var model: AppModel
    @Binding var sheet: DashboardSheet?

    var body: some View {
        let online = DashboardKit.isOnline(node)
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ProductImage(node: node, size: 36).frame(width: 42, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(node.first("location", "model")).font(.system(size: 15, weight: .semibold))
                        Text((node.b("gateway") ? "Gateway · " : "") + node.s("model")).font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                    }
                    Spacer(minLength: 8)
                    StatusBadge(text: online ? "Online" : (node.s("status").nilIfEmpty ?? "Unknown"), online: online)
                }
                Text((node.first("ip_address", "ip").nilIfEmpty ?? "IP unavailable") + "  ·  " + (node.s("connected_clients_count").nilIfEmpty ?? "—") + " connected devices")
                    .font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                    .padding(.leading, 42).padding(.vertical, 12)
                HStack(spacing: 4) {
                    Button("View details") { NodeActions.openDetails(node, model: model) }
                    Button("Rename") { if !model.busy { sheet = NodeActions.rename(node, model: model) } }
                    Menu("More") {
                        Button("Restart eero") { NodeActions.restart(node, model: model) }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(model.busy)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 42)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Port of `NodeDetailsPage` (route "Home/eeros/Details").
@MainActor
struct NodeDetailView: View {
    @ObservedObject var model: AppModel
    @ViewState private var sheet: DashboardSheet? = nil
    var body: some View {
        let node = model.selectedNode
        Group {
            if node.isNull {
                Text("Select an eero from Home.")
            } else {
                content(node)
            }
        }
        .dashboardSheet($sheet, model: model)
    }

    @ViewBuilder private func content(_ node: JSON) -> some View {
        let url = node.s("url")
        let online = DashboardKit.isOnline(node)
        let ledURL = model.resource(node, "led_action", "").nilIfEmpty
        let connectionsURL = model.resource(node, "connections", "").nilIfEmpty
        VStack(alignment: .leading, spacing: 16) {
            Subtitle("Connection details and settings for this eero.")
            Card {
                HStack(spacing: 0) {
                    ProductImage(node: node, size: 72).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.s("model")).font(.system(size: 22, weight: .semibold))
                        Text(node.b("gateway") ? "Gateway eero" : "Mesh eero").font(.system(size: 13)).foregroundStyle(DashboardKit.muted)
                        StatusBadge(text: online ? "Online" : "Offline", online: online)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Device information").font(.system(size: 20, weight: .semibold))
                            DetailRow(name: "IP address", value: node.first("ip_address", "ip"))
                            DetailRow(name: "Connected devices", value: node.s("connected_clients_count"))
                            DetailRow(name: "eeroOS version", value: node.first("os_version", "firmware_version"))
                            DetailRow(name: "Serial number", value: node.s("serial"))
                            DetailRow(name: "MAC address", value: node.first("mac_address", "mac"))
                            Button("All device details") { if !model.busy { sheet = .info("eero details", node) } }
                                .buttonStyle(.borderless).padding(.top, 8)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Device settings").font(.system(size: 20, weight: .semibold))
                            if let ledURL {
                                Button("Status light") { if !model.busy { sheet = statusLight(node, ledURL) } }
                                Button("Light brightness") { if !model.busy { sheet = brightness(node, ledURL) } }
                            }
                            if !node["nightlight"].isNull {
                                Button("Nightlight") { if !model.busy { sheet = nightlight(node) } }
                            }
                            if let connectionsURL {
                                Button("Ethernet connections & ports") {
                                    model.perform {
                                        let data = try await model.dashboardRead(connectionsURL)
                                        sheet = DashboardSheet(kind: .ports(node: node, connections: data))
                                    }
                                }
                            }
                            Button("Firmware update history") {
                                model.perform {
                                    let data = try await model.dashboardRead("/2.2/eeros/" + DashboardKit.lastSegment(url) + "/firmware_update/history?limit=20&offset=0")
                                    sheet = .info("Firmware history", data)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Manage eero").font(.system(size: 20, weight: .semibold))
                            Button("Restart this eero") {
                                model.perform {
                                    guard await model.confirm("Restart this eero? Connected devices may lose internet access temporarily.") else { return }
                                    try await model.dashboardChange("POST", model.resource(node, "reboot", url + "/reboot"), nil, success: "Restart requested.")
                                }
                            }
                            Button("Remove this eero") { if !model.busy { sheet = remove(node, url) } }
                                .foregroundStyle(DashboardKit.danger)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func statusLight(_ node: JSON, _ ledURL: String) -> DashboardSheet {
        .form(DashboardForm(title: "Status light", fields: [.bool("led_on", "Enable status light", node.b("led_on"))]) { v, _ in
            try await model.dashboardChange("PUT", ledURL, JSON.obj(("led_on", v.flag("led_on"))), form: true, success: "Status light updated.")
        })
    }

    private func brightness(_ node: JSON, _ ledURL: String) -> DashboardSheet {
        .form(DashboardForm(title: "Status light brightness", fields: [.text("brightness", "Brightness (0–100)", node.s("led_brightness"))]) { v, _ in
            guard let n = Int(v.v("brightness").trimmingCharacters(in: .whitespaces)), (0...100).contains(n) else {
                throw EeroError.argument("Enter a brightness from 0 to 100.")
            }
            try await model.dashboardChange("PUT", ledURL, JSON.obj(("led_brightness", n)), form: true, success: "Brightness updated.")
        })
    }

    /// Port of `NightlightEdit`.
    private func nightlight(_ node: JSON) -> DashboardSheet {
        let light = node["nightlight"]
        return .form(DashboardForm(title: "Nightlight", fields: [
            .bool("enabled", "Enable nightlight", light.b("enabled")),
            .text("brightness", "Brightness (0–100)", light.s("brightness_percentage")),
            .bool("scheduled", "Use a schedule", light.b("schedule", "enabled")),
            .text("on", "On (HH:mm)", light.s("schedule", "on").nilIfEmpty ?? "20:00"),
            .text("off", "Off (HH:mm)", light.s("schedule", "off").nilIfEmpty ?? "07:00"),
        ]) { v, _ in
            guard let b = Int(v.v("brightness").trimmingCharacters(in: .whitespaces)), (0...100).contains(b) else {
                throw EeroError.argument("Enter a brightness from 0 to 100.")
            }
            _ = try FeatureContracts.schedule("Nightlight", ["MON"], v.v("on"), v.v("off"), true)
            try await model.dashboardChange("PUT", node.s("url") + "/nightlight/settings", JSON.obj(
                ("enabled", v.flag("enabled")), ("brightness_percentage", b),
                ("schedule", JSON.obj(("enabled", v.flag("scheduled")), ("on", v.v("on")), ("off", v.v("off"))))
            ), success: "Nightlight updated.")
        })
    }

    private func remove(_ node: JSON, _ url: String) -> DashboardSheet {
        .form(DashboardForm(title: "Remove eero", fields: [.text("confirm", "Type the eero location name to confirm")], submit: "Remove eero") { v, confirmer in
            if v.v("confirm") != node.s("location") { throw EeroError.argument("The location name does not match.") }
            guard await confirmer.ask("Remove this eero from the network? Removing the gateway can take the entire network offline.") else { return }
            model.currentPage = "Home/eeros"
            model.selectedNode = .null
            try await model.dashboardChange("DELETE", url, nil, success: "eero removed.")
        })
    }
}

/// Port of `PortDialog`: Ethernet port details and port / PoE actions.
@MainActor
struct NodePortsSheet: View {
    let node: JSON
    let connections: JSON
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var working = false
    @ViewState private var status = ""
    @StateObject private var confirmer = SheetConfirmer()

    static let portActions = ["ENABLE_DATA", "DISABLE_DATA", "ENABLE_POE", "DISABLE_POE", "ENABLE_PORT", "DISABLE_PORT", "RESTART_POWER", "ENABLE_PORT_SECURITY", "DISABLE_PORT_SECURITY"]
    static let nodeActions = ["POWER_CYCLE_ALL_PORTS", "POWER_CYCLE_ALL_PORTS_AND_REBOOT"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ethernet connections").font(.system(size: 24, weight: .semibold))
                    ForEach(Array(connections.get("ports", "interfaces").list.enumerated()), id: \.offset) { _, port in
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(port.s("name").nilIfEmpty ?? "Port " + port.s("interface_number")).font(.system(size: 19, weight: .semibold))
                                DashboardDetails(value: port)
                                ForEach(port["actions"].list.map { $0.s("type") }.filter { Self.portActions.contains($0) }, id: \.self) { type in
                                    Button(DashboardKit.human(type.lowercased())) {
                                        act("Apply " + DashboardKit.human(type.lowercased()) + " to " + port.s("name") + "? It may interrupt data or PoE power.",
                                            node.s("url") + "/ports/" + port.s("interface_number") + "/action", type, "Port action requested.")
                                    }.disabled(working)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(connections["node_actions"].list.map { $0.s("type") }.filter { Self.nodeActions.contains($0) }, id: \.self) { type in
                        Button(DashboardKit.human(type.lowercased())) {
                            act("Apply this action to every Ethernet port on this eero? Devices may lose power and internet access.",
                                node.s("url") + "/action", type, "eero port action requested.")
                        }.disabled(working)
                    }
                    if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(DashboardKit.danger) }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working) }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 700)
        .interactiveDismissDisabled(working)
        .sheetConfirmations(confirmer)
    }

    private func act(_ question: String, _ path: String, _ type: String, _ success: String) {
        if working { return }
        Task { @MainActor in
            guard await confirmer.ask(question) else { return }
            working = true
            do {
                try await model.dashboardChange("POST", path, JSON.obj(("action", type)), success: success)
                working = false
                dismiss()
            } catch {
                working = false
                status = userMessage(error)
            }
        }
    }
}
#endif
