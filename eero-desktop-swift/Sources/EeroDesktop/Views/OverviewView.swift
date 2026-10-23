#if os(macOS)
import SwiftUI
import AppKit
import EeroCore

// Port of NativeOverview / CompactNode (NativeLayout.cs, ProductImages.cs) plus the small page helpers
// shared by the dashboard pages (Overview, Devices, eero nodes, Profiles, Activity, Help):
// Human, IsOnline, StatusBadge, RouteRow, Speed, Metric, Device, ProfileSummary, Detail, Change, Read,
// and the Edit / Info / Confirm dialogs re-expressed as SwiftUI sheets.

// MARK: - Helpers

enum DashboardKit {
    static var green: Color { Palette.success }
    static var muted: Color { Palette.muted }
    static var danger: Color { Palette.error }
    static var accent: Color { Palette.accent }
    static var bar: Color { Palette.accent }
    static var border: Color { Palette.edge }

    /// Port of `Human`: friendly names for API keys.
    static func human(_ key: String) -> String {
        let special = ["ip": "IP address", "mac": "MAC address", "ssid": "Wifi name", "up_mbps": "Upload (Mbps)", "down_mbps": "Download (Mbps)",
                       "ipv6_upstream": "IPv6", "led_on": "Status light", "sqm": "Optimize for conferencing and gaming"]
        if let s = special[key] { return s }
        var t = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        t = t.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        // TextInfo.ToTitleCase: capitalise each word, but keep words that are entirely upper case.
        return t.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            let s = String(w)
            if s.isEmpty || (s == s.uppercased() && s != s.lowercased()) { return s }
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Port of `ValidateName`.
    static func validateName(_ s: String) throws { try Validation.validateName(s) }

    /// Port of `IsOnline`.
    static func isOnline(_ data: JSON) -> Bool {
        let status = data.s("health", "internet", "status").nilIfEmpty ?? data.s("status")
        return status == "connected" || status == "green" || status == "online"
    }

    /// Port of `Speed`.
    static func speed(_ network: JSON, _ direction: String) -> String {
        let value = network.s("speed", direction, "value")
        return value.isEmpty ? "—" : value + " " + (network.s("speed", direction, "units").nilIfEmpty ?? "Mbps")
    }

    /// Port of `ProfileSummary`.
    static func profileSummary(_ profile: JSON) -> String {
        let count: String
        if !profile["devices"].isNull { count = "\(profile["devices"].list.count) devices · " }
        else if !profile["device_count"].isNull { count = profile.s("device_count") + " devices · " }
        else { count = "" }
        return count + (profile.b("paused") ? "Paused" : "Internet enabled")
    }

    /// Port of `Entries`.
    static func entries(_ data: JSON, _ names: String...) -> [JSON] {
        let direct = data.list
        if !direct.isEmpty { return direct }
        for n in names { let a = data[n].list; if !a.isEmpty { return a } }
        return []
    }

    /// `Uri.EscapeDataString`.
    static func escape(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// `url.TrimEnd('/').Split('/').Last()`.
    static func lastSegment(_ url: String) -> String {
        url.trimmingSuffix("/").components(separatedBy: "/").last ?? ""
    }

    static let weekDays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
}

/// Port of `DeviceRow` / `Device(object)`.
struct DashboardDevice: Identifiable {
    let raw: JSON
    let id: String
    let name: String
    let status: String
    let ip: String
    let connection: String
    let profile: String

    init(_ d: JSON, index: Int = 0) {
        raw = d
        id = d.s("url").nilIfEmpty ?? d.s("mac").nilIfEmpty ?? "device-\(index)"
        name = d.first("nickname", "display_name", "hostname", "mac")
        status = d.b("blocked") ? "Blocked" : d.b("paused") ? "Paused" : d.b("connected") ? "Online" : "Offline"
        ip = d.first("ip", "ip_address")
        connection = d.b("wireless") ? (d.s("frequency").nilIfEmpty ?? "Wifi") : "Ethernet"
        profile = d.s("profile", "name")
    }
}

extension AppModel {
    /// Port of `Read`.
    func dashboardRead(_ path: String) async throws -> JSON {
        if preview { throw EeroError.operation("Sign in to load this information.") }
        return try await api.send("GET", path)
    }

    /// Port of `Change`: sends a change, then refreshes the network and the current page.
    func dashboardChange(_ method: String, _ path: String, _ body: JSON?, form: Bool = false, success: String) async throws {
        if preview { throw EeroError.operation("Preview mode is read only. Sign in to manage your network.") }
        try await api.send(method, path, body, form: form)
        do {
            if !(networkURL ?? "").isEmpty { try await loadNetwork() }
            if currentPage == "Home/Profiles/Profile", !selectedProfile.isNull { selectedProfile = try await api.send("GET", selectedProfile.s("url")) }
            else if currentPage == "Home/eeros/Details", !selectedNode.isNull { selectedNode = try await api.send("GET", selectedNode.s("url")) }
            else { try await FeatureAreas.load(currentPage, model: self) }
            setNotice(success)
        } catch {
            setNotice(success + " Refresh did not finish: " + userMessage(error), error: true)
        }
    }
}

// MARK: - Small shared views

/// Port of `Availability`.
struct DashboardAvailability: View {
    let key: String
    @ObservedObject var model: AppModel
    var body: some View {
        if let error = model.loadErrors[key] {
            Card { Text("Could not load \(key.lowercased()): \(error)").font(.system(size: 14)).foregroundStyle(DashboardKit.danger).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

/// Port of `Metric`: a small titled number card.
struct DashboardMetric: View {
    let title: String
    let value: String
    let caption: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(DashboardKit.muted)
                Text(value).font(.system(size: 25, weight: .semibold))
                Text(caption).font(.system(size: 11)).foregroundStyle(DashboardKit.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Dialog ports (Edit, Info, Confirm, Prompt)

/// Confirmation shown inside a sheet (the root-level `model.confirm` cannot appear above an open sheet).
@MainActor
final class SheetConfirmer: ObservableObject {
    struct Pending: Identifiable { let id = UUID(); let message: String; let resume: (Bool) -> Void }
    @Published var pending: Pending?

    func ask(_ message: String) async -> Bool {
        await withCheckedContinuation { c in pending = Pending(message: message) { c.resume(returning: $0) } }
    }
    func resolve(_ value: Bool) {
        guard let p = pending else { return }
        pending = nil
        p.resume(value)
    }
}

@MainActor
extension View {
    func sheetConfirmations(_ c: SheetConfirmer) -> some View {
        alert("Confirm change", isPresented: Binding(get: { c.pending != nil }, set: { shown in
            if !shown { Task { @MainActor in c.resolve(false) } }
        }), presenting: c.pending) { _ in
            Button("Cancel", role: .cancel) { c.resolve(false) }
            Button("Continue") { c.resolve(true) }
        } message: { p in Text(p.message) }
    }
}

/// Port of the `Field` class used by `Edit`.
struct DashboardField {
    enum Kind { case text, multiline, bool, choice([String]) }
    let key: String
    let label: String
    let value: String
    let kind: Kind

    static func text(_ key: String, _ label: String, _ value: String = "") -> DashboardField { .init(key: key, label: label, value: value, kind: .text) }
    static func bool(_ key: String, _ label: String, _ value: Bool) -> DashboardField { .init(key: key, label: label, value: value ? "True" : "False", kind: .bool) }
    static func choice(_ key: String, _ label: String, _ value: String, _ choices: [String]) -> DashboardField { .init(key: key, label: label, value: value, kind: .choice(choices)) }
}

/// Values read back from an Edit dialog (`V` / `Flag`).
struct DashboardValues {
    let values: [String: String]
    func v(_ key: String) -> String { values[key] ?? "" }
    func flag(_ key: String) -> Bool { v(key).lowercased() == "true" }
}

/// Port of `Edit(title, fields, save, submit, description)`.
struct DashboardForm {
    let title: String
    let fields: [DashboardField]
    var submit = "Save"
    var description: String? = nil
    let save: @MainActor (DashboardValues, SheetConfirmer) async throws -> Void
}

/// Which dialog a dashboard page is showing.
struct DashboardSheet: Identifiable {
    enum Kind {
        case form(DashboardForm)
        case info(String, JSON)
        case device(JSON)
        case profileDevices(JSON)
        case ports(node: JSON, connections: JSON)
        case domains(JSON, profile: JSON?)
    }
    let id = UUID()
    let kind: Kind

    static func form(_ f: DashboardForm) -> DashboardSheet { .init(kind: .form(f)) }
    static func info(_ title: String, _ data: JSON) -> DashboardSheet { .init(kind: .info(title, data)) }
    static func device(_ d: JSON) -> DashboardSheet { .init(kind: .device(d)) }
}

@MainActor
extension View {
    /// Presents the dashboard dialogs for `sheet`.
    func dashboardSheet(_ sheet: Binding<DashboardSheet?>, model: AppModel) -> some View {
        self.sheet(item: sheet) { s in
            DashboardSheetContent(sheet: s, model: model) { next in
                sheet.wrappedValue = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    sheet.wrappedValue = next
                }
            }
        }
    }
}

struct DashboardSheetContent: View {
    let sheet: DashboardSheet
    @ObservedObject var model: AppModel
    /// Closes this sheet and opens another one (WPF code closed one window and opened the next).
    let present: (DashboardSheet) -> Void

    var body: some View {
        switch sheet.kind {
        case .form(let f): DashboardFormSheet(form: f, model: model)
        case .info(let title, let data): DashboardInfoSheet(title: title, data: data)
        case .device(let d): DeviceDetailSheet(device: d, model: model)
        case .profileDevices(let p): ProfileDevicesSheet(profile: p, model: model)
        case .ports(let node, let connections): NodePortsSheet(node: node, connections: connections, model: model)
        case .domains(let data, let profile): ProfileDomainSheet(data: data, profile: profile, model: model, present: present)
        }
    }
}

/// Port of `Edit`: a modal form that stays open and shows the error until the save succeeds.
@MainActor
struct DashboardFormSheet: View {
    let form: DashboardForm
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var values: [String: String] = [:]
    @ViewState private var status = ""
    @ViewState private var working = false
    @StateObject private var confirmer = SheetConfirmer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(form.title).font(.system(size: 24, weight: .semibold))
                if let d = form.description { Text(d).font(.system(size: 13)).foregroundStyle(DashboardKit.muted) }
                ForEach(Array(form.fields.enumerated()), id: \.offset) { _, field in fieldView(field) }
                if !status.isEmpty { Text(status).font(.system(size: 13)).foregroundStyle(DashboardKit.danger) }
                HStack {
                    Button(form.submit) { commit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(working)
                    Button("Cancel") { if !working { dismiss() } }.keyboardShortcut(.cancelAction).disabled(working)
                }.padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 220, idealHeight: 420)
        .interactiveDismissDisabled(working)
        .sheetConfirmations(confirmer)
        .onAppear {
            for f in form.fields where values[f.key] == nil {
                if case .choice(let choices) = f.kind, !choices.contains(f.value) { values[f.key] = choices.first ?? "" }
                else { values[f.key] = f.value }
            }
        }
    }

    @ViewBuilder private func fieldView(_ f: DashboardField) -> some View {
        switch f.kind {
        case .bool:
            Toggle(isOn: Binding(get: { values[f.key] == "True" }, set: { values[f.key] = $0 ? "True" : "False" })) {
                Text(f.label).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.checkbox)
        case .choice(let choices):
            if !f.label.isEmpty { Text(f.label).font(.system(size: 13, weight: .semibold)) }
            Picker(f.label, selection: Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0 })) {
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }.labelsHidden()
        case .text, .multiline:
            if !f.label.isEmpty { Text(f.label).font(.system(size: 13, weight: .semibold)) }
            let limit: Int = { if case .multiline = f.kind { return 4096 }; return 254 }()
            let binding = Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = String($0.prefix(limit)) })
            if case .multiline = f.kind { TextEditor(text: binding).frame(minHeight: 80) }
            else { TextField(f.label, text: binding).textFieldStyle(.roundedBorder).labelsHidden() }
        }
    }

    private func commit() {
        if working { return }
        working = true
        status = "Saving…"
        let snapshot = DashboardValues(values: values)
        Task { @MainActor in
            do {
                try await form.save(snapshot, confirmer)
                working = false
                dismiss()
            } catch {
                working = false
                status = userMessage(error)
                if let ex = error as? ApiError, ex.sessionExpired {
                    dismiss()
                    await model.api.forget()
                    model.clearData()
                    model.screen = .login(verify: false)
                    model.setNotice("Your session expired. Sign in again.", error: true)
                }
            }
        }
    }
}

/// Port of `Info`: shows a JSON payload through `Details`.
struct DashboardInfoSheet: View {
    let title: String
    let data: JSON
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 23, weight: .semibold))
                    DashboardDetails(value: data)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 700)
    }
}

/// Port of `Details`: renders any JSON value as readable text, hiding links and secrets.
struct DashboardDetails: View {
    let value: JSON
    var depth = 0
    static let hidden = "(^resources$|^url$|token|password|secret|credential|certificate|master_key|private_key|psk|operational_dataset|software_key|invite_code|signed_upload_url|kms_key_id|mwb_full_report_url|^coupon$)"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
    }

    private var content: AnyView {
        if depth > 4 { return AnyView(EmptyView()) }
        if let map = value.object {
            let keys = map.keys.sorted().filter { $0.range(of: Self.hidden, options: [.regularExpression, .caseInsensitive]) == nil }
            return AnyView(ForEach(keys, id: \.self) { key in entry(key, map[key] ?? .null) })
        }
        let list = value.list
        let scalar: (JSON) -> Bool = { j in if case .array = j { return false }; if case .object = j { return false }; return true }
        if !list.isEmpty && list.allSatisfy(scalar) {
            let text = list.prefix(60).map(\.string).filter { !$0.hasPrefix("/2.") }.joined(separator: " · ")
            return AnyView(Text(text).font(.system(size: 13)).textSelection(.enabled))
        }
        if !list.isEmpty {
            return AnyView(ForEach(Array(list.prefix(60).enumerated()), id: \.offset) { _, item in
                DashboardDetails(value: item, depth: depth + 1).padding(.bottom, 8)
            })
        }
        switch value {
        case .string, .number, .bool: return AnyView(Text(value.string).font(.system(size: 13)).textSelection(.enabled))
        default: return AnyView(Text("No entries returned.").font(.system(size: 13)).foregroundStyle(DashboardKit.muted))
        }
    }

    private func entry(_ key: String, _ v: JSON) -> AnyView {
        switch v {
        case .object, .array:
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                Text(DashboardKit.human(key)).font(.system(size: 14, weight: .semibold)).foregroundStyle(DashboardKit.muted)
                DashboardDetails(value: v, depth: depth + 1).padding(.leading, 12).padding(.bottom, 12)
            })
        default:
            let display: String
            if case .bool(let b) = v { display = b ? "On" : "Off" } else { display = v.string }
            if display.isEmpty || display.hasPrefix("/2.") { return AnyView(EmptyView()) }
            return AnyView(Text(DashboardKit.human(key) + ": " + display).font(.system(size: 13)).textSelection(.enabled))
        }
    }
}

// MARK: - Overview

/// Port of `NativeOverview` (routes "Home" and "Overview").
@MainActor
struct OverviewView: View {
    @ObservedObject var model: AppModel
    @ViewState private var sheet: DashboardSheet? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your network at a glance").font(.system(size: 14)).foregroundStyle(DashboardKit.muted).padding(.bottom, 18)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    internetCard
                    meshCard
                    RouteRow(title: "Chat with eero", subtitle: "Get help with your network", route: "Home/Chat")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .layoutPriority(1.45)
                VStack(alignment: .leading, spacing: 16) {
                    devicesCard
                    profilesCard
                    RouteRow(title: "Security & privacy", subtitle: "Protection, content filters, and privacy", route: "Home/Security & privacy")
                    RouteRow(title: "Internet backup", subtitle: "Keep your network connected", route: "Settings/Advanced networking/Internet backup")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.loadErrors.keys.sorted(), id: \.self) { DashboardAvailability(key: $0, model: model) }
            }.padding(.top, 16)
        }
        .dashboardSheet($sheet, model: model)
    }

    private var internetCard: some View {
        let online = DashboardKit.isOnline(model.network)
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Image(systemName: "globe").font(.system(size: 26)).foregroundStyle(DashboardKit.accent).frame(width: 44, alignment: .leading)
                    Text("Internet").font(.system(size: 20, weight: .semibold)).padding(.leading, 4)
                    Spacer()
                    StatusBadge(text: online ? "Online" : "Check connection", online: online)
                }
                Divider().padding(.vertical, 16)
                HStack(alignment: .top) {
                    ForEach([("↓  Download", DashboardKit.speed(model.network, "down")), ("↑  Upload", DashboardKit.speed(model.network, "up"))], id: \.0) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0).font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                            Text(item.1).font(.system(size: 28, weight: .semibold))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Latest measured internet speed").font(.system(size: 11)).foregroundStyle(DashboardKit.muted).padding(.top, 4)
                HStack {
                    Button("Run speed test") { model.perform { try await model.startSpeedTest() } }.buttonStyle(.borderedProminent)
                    SectionLink(title: "Internet details", route: "Home/Internet")
                }.padding(.top, 10)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meshCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Your eeros").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text("\(model.nodes.count) on this network").font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                }.padding(.bottom, 16)
                ForEach(Array(model.nodes.enumerated()), id: \.offset) { _, node in
                    CompactNodeRow(node: node, model: model, sheet: $sheet)
                }
                if model.nodes.isEmpty {
                    Text(model.loadErrors["eero nodes"] != nil ? "eero information could not be loaded. Refresh to try again." : "No eeros were returned.")
                        .font(.system(size: 14))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var devicesCard: some View {
        let failed = model.loadErrors["Devices"] != nil
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Devices").font(.system(size: 20, weight: .semibold))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(failed ? "—" : "\(model.devices.filter { $0.b("connected") }.count)").font(.system(size: 32, weight: .semibold))
                        Text("Online").font(.system(size: 12)).foregroundStyle(DashboardKit.green)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(failed ? "—" : "\(model.devices.filter { !$0.b("connected") }.count)").font(.system(size: 32, weight: .semibold))
                        Text("Offline").font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                SectionLink(title: "View all devices", route: "Devices")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var profilesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles").font(.system(size: 20, weight: .semibold))
                ForEach(Array(model.profiles.prefix(3).enumerated()), id: \.offset) { _, profile in
                    RouteRow(title: profile.s("name"), subtitle: DashboardKit.profileSummary(profile), route: "Home/Profiles") {
                        model.selectedProfile = profile
                        model.navigate("Home/Profiles/Profile")
                    }
                }
                if model.profiles.isEmpty {
                    Text("Create profiles to manage devices and scheduled pauses.").font(.system(size: 12)).foregroundStyle(DashboardKit.muted)
                }
                SectionLink(title: "Manage profiles", route: "Home/Profiles")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Port of `CompactNode`: an eero row on the Overview page.
struct CompactNodeRow: View {
    let node: JSON
    @ObservedObject var model: AppModel
    @Binding var sheet: DashboardSheet?

    private var online: Bool { DashboardKit.isOnline(node) }
    private var subtitle: String { (node.b("gateway") ? "Gateway · " : "") + node.s("model") }
    private var statusLine: String {
        let count = node.s("connected_clients_count")
        let state: String = online ? "● Online" : "○ " + (node.s("status").nilIfEmpty ?? "Unknown")
        return count.isEmpty ? state : state + " · " + count + " devices"
    }
    private var statusColor: Color { online ? DashboardKit.green : DashboardKit.muted }

    var body: some View {
        HStack(spacing: 0) {
            ProductImage(node: node, size: 52).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.first("location", "model")).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(DashboardKit.muted).padding(.bottom, 4)
                Text(statusLine).font(.system(size: 11)).foregroundStyle(statusColor)
            }.padding(.trailing, 10)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button("View details") {
                    if model.busy { return }
                    model.selectedNode = node
                    model.navigate("Home/eeros/Details")
                }
                Button("Rename") { if !model.busy { sheet = NodeActions.rename(node, model: model) } }
            }.buttonStyle(.borderless).controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(DashboardKit.border))
        .padding(.bottom, 8)
    }
}
#endif
