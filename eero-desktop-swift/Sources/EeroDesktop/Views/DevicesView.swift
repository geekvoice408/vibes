#if os(macOS)
import SwiftUI
import EeroCore

/// Port of `NativeDevicePage` (route "Devices"): searchable device table with a details pane.
@MainActor
struct DevicesView: View {
    @ObservedObject var model: AppModel
    @ViewState private var query = ""
    @ViewState private var statusFilter = "All devices"
    @ViewState private var selection: String?
    @ViewState private var sheet: DashboardSheet?

    private static let filters = ["All devices", "Online", "Offline", "Paused", "Blocked"]

    private var rows: [DashboardDevice] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = model.devices.enumerated().map { DashboardDevice($0.element, index: $0.offset) }
        let filtered = all.filter { d in
            (statusFilter == Self.filters[0] || d.status == statusFilter)
                && (q.isEmpty || (d.name + " " + d.ip + " " + d.raw.s("mac") + " " + d.raw.s("manufacturer")).range(of: q, options: .caseInsensitive) != nil)
        }
        // OrderBy(status != "Online").ThenBy(name), stable.
        return filtered.enumerated().sorted { a, b in
            let ao = a.element.status != "Online", bo = b.element.status != "Online"
            if ao != bo { return !ao }
            let c = a.element.name.localizedCompare(b.element.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        let rows = self.rows
        let selected = rows.first { $0.id == selection } ?? rows.first
        VStack(alignment: .leading, spacing: 0) {
            Subtitle("Find devices and inspect their connection details.")
            DashboardAvailability(key: "Devices", model: model)
            HStack(spacing: 12) {
                TextField("Search devices by name, MAC or IP", text: Binding(get: { query }, set: { query = String($0.prefix(254)) }))
                    .textFieldStyle(.roundedBorder)
                    .help("Search by name, IP, MAC, or manufacturer")
                    .accessibilityLabel("Search devices")
                Picker("Device status filter", selection: $statusFilter) {
                    ForEach(Self.filters, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel("Device status filter")
                SectionLink(title: "Blocked devices", route: "Devices/Blocked devices")
            }
            .padding(.bottom, 16)
            HStack(alignment: .top, spacing: 20) {
                Table(rows, selection: $selection) {
                    TableColumn("Name") { Text($0.name) }.width(min: 120, ideal: 200)
                    TableColumn("Status") { Text($0.status) }.width(min: 75, ideal: 100)
                    TableColumn("IP address") { Text($0.ip) }.width(min: 110, ideal: 130)
                    TableColumn("Connection") { Text($0.connection) }.width(min: 100, ideal: 120)
                }
                .contextMenu(forSelectionType: String.self) { _ in
                    EmptyView()
                } primaryAction: { ids in
                    guard !model.busy, let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
                    sheet = .device(row.raw)
                }
                .frame(height: 440)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DashboardKit.border))
                .frame(maxWidth: .infinity)

                Card { details(selected) }
                    .frame(width: 280)
            }
            Text(countText(rows))
                .font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                .padding(.top, 12)
        }
        .onChange(of: rows.map(\.id), initial: true) {
            let ids = self.rows.map(\.id)
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
        .dashboardSheet($sheet, model: model)
    }

    private func countText(_ rows: [DashboardDevice]) -> String {
        "\(rows.count)" + (rows.count == 1 ? " device" : " devices") + " · \(model.devices.filter { $0.b("connected") }.count) online"
            + (rows.isEmpty ? " · No devices match your search." : "")
    }

    @ViewBuilder private func details(_ selected: DashboardDevice?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selected {
                Text(selected.name).font(.system(size: 20, weight: .semibold))
                StatusBadge(text: selected.status, online: selected.status == "Online")
                Spacer().frame(height: 12)
                DetailRow(name: "Connection", value: selected.connection)
                DetailRow(name: "IP address", value: selected.ip)
                DetailRow(name: "MAC address", value: selected.raw.s("mac"))
                DetailRow(name: "Connected eero", value: selected.raw.s("source", "location"))
                DetailRow(name: "Profile", value: selected.profile.nilIfEmpty ?? "Unassigned")
                Button("Manage device") { if !model.busy { sheet = .device(selected.raw) } }
                    .padding(.top, 12)
            } else {
                Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 32)).foregroundStyle(DashboardKit.muted)
                    .frame(maxWidth: .infinity)
                Text("Device details").font(.system(size: 18, weight: .semibold))
                Text("Select a device to view its connection and profile.").font(.system(size: 13)).foregroundStyle(DashboardKit.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Port of `DeviceDialog`: nickname, pause/resume, block/unblock and the extra device actions.
@MainActor
struct DeviceDetailSheet: View {
    let device: JSON
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var nickname: String
    @ViewState private var status = ""
    @StateObject private var confirmer = SheetConfirmer()

    init(device: JSON, model: AppModel) {
        self.device = device
        self.model = model
        _nickname = ViewState(wrappedValue: DashboardDevice(device).name)
    }

    private var row: DashboardDevice { DashboardDevice(device) }
    private var mac: String { device.s("mac") }
    private var url: String { device.s("url").nilIfEmpty ?? (model.networkURL ?? "") + "/devices/" + DashboardKit.escape(mac) }

    var body: some View {
        let row = self.row
        let paused = device.b("paused"), blocked = device.b("blocked")
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.name).font(.system(size: 25, weight: .semibold))
                    DetailRow(name: "Connection", value: row.status + " · " + row.connection)
                    DetailRow(name: "IP address", value: row.ip)
                    DetailRow(name: "MAC address", value: mac)
                    DetailRow(name: "Manufacturer", value: device.s("manufacturer"))
                    DetailRow(name: "Connected eero", value: device.s("source", "location"))
                    DetailRow(name: "Profile", value: row.profile)
                    Text("Device nickname").font(.system(size: 13, weight: .semibold)).padding(.top, 8)
                    TextField("Device nickname", text: Binding(get: { nickname }, set: { nickname = String($0.prefix(100)) }))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Button("Save nickname") { saveNickname() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                    if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(DashboardKit.danger) }
                    HStack {
                        Button(paused ? "Resume internet" : "Pause internet") {
                            Task {
                                guard await confirmer.ask("Change internet access for \(row.name)?") else { return }
                                let url = self.url
                                dismiss()
                                model.perform { try await model.mutate("PUT", url, JSON.obj(("paused", !paused)), success: "Device access updated.") }
                            }
                        }
                        Button(blocked ? "Unblock device" : "Block device") {
                            Task {
                                guard await confirmer.ask((blocked ? "Allow " : "Block ") + row.name + " on this network?") else { return }
                                let mac = self.mac
                                dismiss()
                                model.perform {
                                    try await model.dashboardChange(blocked ? "DELETE" : "POST",
                                                                    try model.featureURL("blacklist" + (blocked ? "/" + DashboardKit.escape(mac) : "")),
                                                                    blocked ? nil : JSON.obj(("mac", mac)), form: true, success: "Device block setting updated.")
                                }
                            }
                        }
                    }
                    .disabled(model.busy)
                    DeviceExtraActionsView(device: device, model: model)
                    Text("Pausing or blocking this Mac may disconnect the app from the internet.")
                        .font(.system(size: 12)).foregroundStyle(DashboardKit.muted).padding(.top, 8)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 700)
        .sheetConfirmations(confirmer)
    }

    private func saveNickname() {
        do { try DashboardKit.validateName(nickname) } catch { status = userMessage(error); return }
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines), url = self.url
        dismiss()
        model.perform { try await model.mutate("PUT", url, JSON.obj(("nickname", name)), success: "Device nickname updated.") }
    }
}
#endif
