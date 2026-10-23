#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// "Home/Security & privacy/VPN" — VPN powered by Guardian (port of `VpnPage` in RuntimeFeatures.cs,
/// VpnUi.cs and `GuardianCredentials` in EverydayFeatures.cs). Tunnel control goes through `MacVpn`.
enum VpnArea: FeatureArea {
    static let route = "Home/Security & privacy/VPN"
    static func handles(_ route: String) -> Bool { route == Self.route }
    static func load(_ route: String, model: AppModel) async throws -> JSON? { nil }
    static func view(_ route: String, model: AppModel) -> AnyView {
        AnyView(VpnView(model: model, vpn: VpnController.shared))
    }
}

/// Per-network Guardian state the Windows `MainWindow` kept in `featureData["guardian_availability"]` and the VPN store.
@MainActor
final class VpnController: ObservableObject {
    static let shared = VpnController()

    /// Availability result and the scope it was loaded for.
    @Published var availability: (scope: String, result: Result<JSON, Error>)?
    @Published var status = "Disconnected"
    @Published var tunnelVisible = false
    @Published var revision = 0

    // Sheets
    @Published var registering: VpnSheetText?
    @Published var regionChoices: VpnSheetChoices?
    @Published var devices: VpnSheetDevices?
    @Published var credentials: VpnSheetCredentials?
    @Published var info: PlatformInfo?

    // MARK: Scope and saved state

    func scope(_ model: AppModel) throws -> String {
        try VpnContracts.scope(model.preview ? "preview-account" : model.account.first("log_id", "url", "id", "email"), model.networkId)
    }

    func state(_ model: AppModel) -> JSON {
        if model.preview { return JSON.obj(("nickname", "Mac"), ("region_label", "New York"), ("pet", "sample")) }
        guard let scope = try? self.scope(model), let text = MacVpn.store(scope).load(), !text.isEmpty,
              let value = try? JSON.parse(text), value.object != nil else { return .object([:]) }
        return value
    }

    func save(_ state: JSON, _ model: AppModel) throws {
        try MacVpn.store(try self.scope(model)).save(state.serialized())
        revision += 1
    }

    func availabilityMessage(_ model: AppModel) -> String {
        guard let a = availability, let scope = try? self.scope(model), a.scope == scope else { return VpnContracts.eligibilityMessage(JSON.null) }
        return VpnContracts.eligibilityMessage(a.result)
    }

    func refreshStatus(_ model: AppModel) async {
        if model.preview { status = "Disconnected · sample"; tunnelVisible = false; return }
        guard let scope = try? self.scope(model) else { status = "Disconnected"; tunnelVisible = false; return }
        tunnelVisible = await MacVpn.manager(scope) != nil
        status = await MacVpn.status(scope)
    }

    // MARK: Actions

    /// Port of `LoadGuardianAvailability`.
    @discardableResult
    func loadAvailability(_ model: AppModel) async throws -> Result<JSON, Error> {
        if model.preview { throw EeroError.operation("Sign in to check Guardian VPN eligibility.") }
        let scope = try self.scope(model)
        availability = nil
        let result: Result<JSON, Error>
        do { result = .success(try await model.api.send("GET", "/2.2/partners/guardian/networks/" + model.networkId + "/availability")) }
        catch let e as ApiError { if e.sessionExpired { throw e }; result = .failure(e) }
        if (try? self.scope(model)) == scope { availability = (scope, result) }
        return result
    }

    func checkEligibility(_ model: AppModel) async throws {
        let result = try await loadAvailability(model)
        if case .failure = result { model.setNotice(VpnContracts.eligibilityMessage(result), error: true) }
        else { model.setNotice(VpnContracts.eligibilityMessage(result)) }
    }

    /// Port of `RegisterGuardian` (opening the dialog).
    func beginRegistration(_ model: AppModel) async throws {
        let availability = try await loadAvailability(model)
        if !VpnContracts.canRegister(availability) { throw EeroError.operation(VpnContracts.eligibilityMessage(availability)) }
        registering = VpnSheetText(text: Host.current().localizedName ?? "Mac")
    }

    /// Port of the `RegisterGuardian` dialog's save action. Returns false when the user cancelled.
    func register(_ model: AppModel, nickname raw: String, agree: Bool) async throws -> Bool {
        if model.preview { throw EeroError.operation("Sample mode does not register VPN devices.") }
        if !agree { throw EeroError.argument("Review and accept Guardian's terms before registering.") }
        let nickname = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try RuntimeContracts.validateName(nickname)
        if !state(model).s("pet").isEmpty {
            throw EeroError.operation("This network already has a saved Mac registration. Choose a location or use Manage VPN devices.")
        }
        if !(await model.confirm("Use an available Guardian VPN device slot for " + nickname + " on this network?")) { return false }
        let result = try await model.api.send("POST", "/2.2/partners/guardian/networks/" + model.networkId + "/pet", JSON.obj(("nickname", nickname)))
        let pet = result.s("guardian_pet")
        if pet.isEmpty { throw EeroError.data("eero did not return a VPN device token. Refresh Manage VPN devices before registering again.") }
        do { try save(JSON.obj(("pet", pet), ("uuid", result.s("uuid")), ("nickname", nickname), ("expiration", result.s("expiration"))), model) }
        catch { throw EeroError.operation("eero registered the device, but macOS could not save it. Check Manage VPN devices and remove the registration before trying again.") }
        model.setNotice("Mac registered. Choose a VPN location, then export the WireGuard configuration.")
        return true
    }

    /// Port of `ChooseGuardianRegion` (loading the choices).
    func beginRegionChoice(_ model: AppModel) async throws {
        if model.preview { throw EeroError.operation("Sign in to choose a Guardian VPN location.") }
        let regions = try await GuardianAPI().regions()
        var choices: [String: String] = [:]
        for region in regions.list {
            let name = region.s("name"), label = region.first("name-pretty", "name")
            if name.isEmpty { continue }
            var key = label + " · " + region.s("country-iso-code")
            if choices[key] != nil { key += " · " + name }
            choices[key] = name
        }
        if choices.isEmpty { throw EeroError.operation("Guardian did not return any VPN locations.") }
        regionChoices = VpnSheetChoices(values: choices)
    }

    /// Port of the `ChooseGuardianRegion` dialog's save action.
    func chooseRegion(_ model: AppModel, label selected: String, region: String) async throws {
        let scope = try self.scope(model)
        if await MacVpn.running(scope) { throw EeroError.operation("Disconnect VPN before changing its location.") }
        var state = self.state(model)
        let pet = state.s("pet")
        if pet.isEmpty { throw EeroError.operation("Register this Mac first.") }
        let keys = try MacVpn.keyPair()
        state["profile"] = try await GuardianAPI().createProfile(pet, region, keys.privateKey, keys.publicKey)
        state["region"] = .string(region)
        state["region_label"] = .string(selected)
        if var o = state.object { o.removeValue(forKey: "verified_utc"); state = .object(o) }
        try save(state, model)
        model.setNotice("VPN location saved. Export the WireGuard configuration and import it into the WireGuard app to connect.")
    }

    /// Exports the WireGuard configuration for the official WireGuard app (replaces the Windows tunnel service install).
    func export(_ model: AppModel) async throws {
        if model.preview { throw EeroError.operation("Sample mode does not export VPN configurations.") }
        let profile = state(model)["profile"]
        if profile.isNull { throw EeroError.operation("Register this Mac and choose a location first.") }
        if !(await model.confirm("Export this network's WireGuard configuration? The file contains your Mac's private VPN key. Import it into the WireGuard app, then delete the exported file.")) { return }
        if let url = try MacVpn.exportConfiguration(scope: try self.scope(model), profile: profile) {
            model.setNotice("WireGuard configuration saved to " + url.lastPathComponent + ". In the WireGuard app choose Import Tunnel(s) from File, then delete the exported file.")
        }
    }

    /// Port of `ConnectGuardian`.
    func connect(_ model: AppModel) async throws {
        if model.preview { throw EeroError.operation("Sample mode does not connect a VPN.") }
        var state = self.state(model)
        if state["profile"].isNull { throw EeroError.operation("Register this Mac and choose a location first.") }
        if !(await model.confirm("Connect this Mac to Guardian through " + state.s("region_label") + "? macOS may ask you to allow the VPN. Full-tunnel protection can block local network access while connected.")) { return }
        let message = try await MacVpn.connect(try self.scope(model))
        state["verified_utc"] = .string(ISO8601DateFormatter().string(from: Date()))
        try save(state, model)
        await refreshStatus(model)
        model.setNotice(message)
    }

    /// Port of `DisconnectGuardian`.
    func disconnect(_ model: AppModel) async throws {
        if model.preview { throw EeroError.operation("Sample mode does not change a VPN.") }
        let scope = try self.scope(model)
        if !(await MacVpn.running(scope)) { model.setNotice("This network's VPN is already disconnected."); return }
        let message = try await MacVpn.disconnect(scope)
        await refreshStatus(model)
        model.setNotice(message)
    }

    /// Port of `GuardianDevices` (loading the list).
    func loadDevices(_ model: AppModel) async throws {
        if model.preview { info = PlatformInfo(title: "VPN devices", data: JSON.obj(("device", "Sample Mac"), ("status", "Registered"))); return }
        let credentials = try await model.api.send("POST", "/2.2/partners/guardian")
        let list = try await GuardianAPI().devices(credentials).list
        devices = VpnSheetDevices(credentials: credentials, list: list)
    }

    /// Port of the "Remove this VPN device" action.
    func removeDevice(_ model: AppModel, id: String, name: String) async throws {
        guard let credentials = devices?.credentials else { return }
        if !(await model.confirm("Remove " + name + " from your Guardian subscription? Its VPN access will stop.")) { return }
        let local = state(model).s("uuid") == id
        let scope = try self.scope(model)
        if local, await MacVpn.running(scope) { throw EeroError.operation("Disconnect this Mac's VPN before removing its registration.") }
        _ = try await GuardianAPI().removeDevice(credentials, id)
        if local { MacVpn.store(scope).clear(); revision += 1 }
        devices = nil
        model.setNotice("VPN device removed.")
    }

    /// Port of `GuardianCredentials`.
    func showCredentials(_ model: AppModel) async throws {
        if model.preview { credentials = VpnSheetCredentials(title: "Sample Guardian sign-in", values: [("Guardian username", "Sample account"), ("Guardian password", "sample-only-password")]); return }
        if !(await model.confirm("Retrieve your Guardian sign-in details from eero? Use them only in Guardian's official app or website.")) { return }
        let data = try await model.api.send("POST", "/2.2/partners/guardian")
        let values = try EverydayContracts.guardianLogin(data)
        credentials = VpnSheetCredentials(title: "Guardian sign-in", values: EverydayContracts.guardianLoginOrder.compactMap { key in values[key].map { (key, $0) } })
    }
}

struct VpnView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vpn: VpnController

    var body: some View {
        let state = vpn.state(model)
        VStack(alignment: .leading, spacing: 12) {
            Subtitle("VPN powered by Guardian")
            Card { Text(vpn.availabilityMessage(model)).font(.system(size: 15)) }
            Caption("Guardian must be included with your eero service. Some internet providers do not offer this benefit. Check eligibility before registering a device.")
            Button("Check VPN eligibility") { model.perform("Checking VPN eligibility…") { try await vpn.checkEligibility(model) } }

            Card {
                SectionHeader(vpn.status, size: 22)
                Text("Region: " + (state.s("region_label").nilIfEmpty ?? "Choose a location")).font(.system(size: 15))
                Text("Mac: " + (state.s("nickname").nilIfEmpty ?? "Not registered")).font(.system(size: 14)).foregroundStyle(Palette.muted)
                if !state.s("verified_utc").isEmpty { Caption("Last connected: " + state.s("verified_utc")) }
                if !model.preview && !state["profile"].isNull {
                    Caption(vpn.tunnelVisible
                        ? "eero Desktop can see this network's tunnel in the WireGuard app."
                        : "eero Desktop cannot see this network's tunnel. Connect and disconnect it in the WireGuard app.")
                }
            }

            HStack {
                Button("Connect VPN") { model.perform("Connecting VPN…") { try await vpn.connect(model) } }
                Button("Disconnect VPN") { model.perform("Disconnecting VPN…") { try await vpn.disconnect(model) } }
                Button("Refresh VPN status") { Task { await vpn.refreshStatus(model) } }
            }
            HStack {
                Button("Register this Mac") { model.perform { try await vpn.beginRegistration(model) } }
                Button("Choose VPN location") { model.perform("Loading VPN locations…") { try await vpn.beginRegionChoice(model) } }
                Button("Manage VPN devices") { model.perform("Loading VPN devices…") { try await vpn.loadDevices(model) } }
            }
            HStack {
                Button("Export WireGuard configuration") { model.perform { try await vpn.export(model) } }
                Button(MacVpn.wireGuardInstalled ? "Open WireGuard" : "Get WireGuard for Mac") { openWireGuard() }
            }
            Caption("macOS only lets signed Network Extensions create VPN tunnels, so eero Desktop does not run the tunnel itself. Export this network's configuration and import it into the official WireGuard app, which provides the tunnel, DNS protection and full-tunnel routing. Connect and Disconnect here work only when macOS lets eero Desktop see the WireGuard tunnel; otherwise use the WireGuard app or System Settings > VPN. Quitting this app leaves a connected VPN running.")

            Button("View Guardian sign-in details") { model.perform { try await vpn.showCredentials(model) } }
            HStack {
                Button("Activate or manage Guardian") { open("https://guardianapp.com/login?connect-api-env=wifi-company-prod") }
                Button("Guardian website") { open("https://guardianapp.com/") }
                Button("VPN setup instructions") { open("https://eero.com/support/articles/how-do-i-set-up-vpn-powered-by-guardian") }
            }
            Caption("Guardian's own apps are also available from its website.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(vpn.revision)
        .task(id: model.networkURL) { await vpn.refreshStatus(model) }
        .sheet(item: $vpn.registering) { VpnRegisterSheet(model: model, vpn: vpn, nickname: $0.text) }
        .sheet(item: $vpn.regionChoices) { VpnRegionSheet(model: model, vpn: vpn, choices: $0.values) }
        .sheet(item: $vpn.devices) { VpnDevicesSheet(model: model, vpn: vpn, devices: $0.list) }
        .sheet(item: $vpn.credentials) { VpnCredentialsSheet(title: $0.title, values: $0.values) }
        .sheet(item: $vpn.info) { PlatformInfoSheet(info: $0) }
    }

    private func open(_ link: String) {
        guard ServiceLinks.allowed(link), let url = URL(string: link) else {
            model.setNotice("The service returned a link outside the supported official domains.", error: true); return
        }
        NSWorkspace.shared.open(url)
    }

    private func openWireGuard() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacVpn.wireGuardAppBundle) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else if let url = URL(string: MacVpn.wireGuardAppStore) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct VpnSheetText: Identifiable { let id = UUID(); let text: String }
struct VpnSheetChoices: Identifiable { let id = UUID(); let values: [String: String] }
struct VpnSheetDevices: Identifiable { let id = UUID(); let credentials: JSON; let list: [JSON] }
struct VpnSheetCredentials: Identifiable { let id = UUID(); let title: String; let values: [(String, String)] }

/// Error line shown inside a sheet while it stays open.
private struct SheetError: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.noticeIsError && !model.notice.isEmpty {
            Text(model.notice).font(.callout).foregroundStyle(Palette.error).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Register this Mac VPN device" dialog.
struct VpnRegisterSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vpn: VpnController
    @State var nickname: String
    @State private var agree = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Register this Mac VPN device").font(.title2.weight(.semibold))
            Text("Registration uses one of your subscription's VPN device slots. No connection is started here.").foregroundStyle(Palette.muted)
            TextField("Device name", text: $nickname)
            Link("Read Guardian terms", destination: URL(string: "https://guardianapp.com/terms-and-conditions/")!)
            Toggle("I agree to Guardian's terms and privacy policy", isOn: $agree)
            SheetError(model: model)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Register device") {
                    Task {
                        var done = false
                        await model.run { done = try await vpn.register(model, nickname: nickname, agree: agree) }
                        if done { vpn.registering = nil }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
        .padding(24).frame(width: 460)
    }
}

/// "VPN location" dialog.
struct VpnRegionSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vpn: VpnController
    let choices: [String: String]
    @State private var selected = ""
    @Environment(\.dismiss) private var dismiss

    private var keys: [String] { choices.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VPN location").font(.title2.weight(.semibold))
            Picker("Location", selection: $selected) { ForEach(keys, id: \.self) { Text($0).tag($0) } }
            SheetError(model: model)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use location") {
                    let label = selected, region = choices[selected] ?? ""
                    Task {
                        var done = false
                        await model.run("Creating VPN profile…") { try await vpn.chooseRegion(model, label: label, region: region); done = true }
                        if done { vpn.regionChoices = nil }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(model.busy || choices[selected] == nil)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { if selected.isEmpty { selected = keys.first ?? "" } }
    }
}

/// "VPN devices · eero Desktop" window.
struct VpnDevicesSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vpn: VpnController
    let devices: [JSON]
    @Environment(\.dismiss) private var dismiss

    private var rows: [JSON] { devices.filter { !$0.s("ep-grd-device-uuid").isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Devices using your Guardian subscription").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty { Text("No devices were returned.").font(.system(size: 14)) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, device in
                        let id = device.s("ep-grd-device-uuid")
                        let name = device.s("ep-grd-device-nickname").nilIfEmpty ?? "VPN device"
                        Card(padding: 16) {
                            SectionHeader(name, size: 19)
                            Caption("Activated: " + device.s("ep-grd-device-created-at"))
                            Button("Remove this VPN device") {
                                model.perform("Removing VPN device…") { try await vpn.removeDevice(model, id: id, name: name) }
                            }
                            .disabled(model.busy)
                        }
                    }
                }
            }
            SheetError(model: model)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 640, height: 600)
    }
}

/// Guardian sign-in details (port of `ShowCredentials`).
struct VpnCredentialsSheet: View {
    let title: String
    let values: [(String, String)]
    @State private var revealed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text("Use these only in Guardian's official app or website. They are not saved by eero Desktop.").foregroundStyle(Palette.muted)
            ForEach(Array(values.enumerated()), id: \.offset) { _, pair in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.0).font(.caption).foregroundStyle(Palette.muted)
                        Text(pair.0.contains("password") && !revealed ? String(repeating: "•", count: 12) : pair.1)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pair.1, forType: .string)
                    }
                }
            }
            Toggle("Show password", isOn: $revealed)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 480)
    }
}
#endif
