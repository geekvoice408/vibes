#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

// Shared building blocks for the cloud feature pages (ports of the MainWindow helpers
// `Sub`, `Details`, `ObjectCards`, `Entries`, `Human`, `Edit`, `Info`, `Read`, `Change`
// as used by AdditionalCloudFeatures/ExtendedFeatures/EverydayFeatures/RuntimeFeatures/
// BillingServices/SupportContacts). Names are prefixed with `Cloud` to stay independent
// of the equivalent helpers other feature areas define.

// MARK: - Text helpers

/// Port of `MainWindow.Human`: turns an API key into a readable label.
func cloudHuman(_ key: String) -> String {
    let special = ["ip": "IP address", "mac": "MAC address", "ssid": "Wifi name", "up_mbps": "Upload (Mbps)",
                   "down_mbps": "Download (Mbps)", "ipv6_upstream": "IPv6", "led_on": "Status light",
                   "sqm": "Optimize for conferencing and gaming"]
    if let s = special[key] { return s }
    var text = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
    text = text.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    return text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
        let w = String(word)
        if w.isEmpty || w == w.uppercased() { return w }   // ToTitleCase keeps all-caps words
        return w.prefix(1).uppercased() + w.dropFirst().lowercased()
    }.joined(separator: " ")
}

/// Port of `MainWindow.Entries`.
func cloudEntries(_ data: JSON, _ names: String...) -> [JSON] {
    let direct = data.list
    if !direct.isEmpty { return direct }
    for name in names { let a = data[name].list; if !a.isEmpty { return a } }
    return []
}

/// Port of `MainWindow.Flag` for checkbox values.
struct CloudValues {
    var text: [String: String] = [:]
    var flags: [String: Bool] = [:]
    func v(_ key: String) -> String { if let f = flags[key] { return f ? "True" : "False" }; return text[key] ?? "" }
    func flag(_ key: String) -> Bool { flags[key] ?? (text[key]?.lowercased() == "true") }
}

// MARK: - Validation shared with the Windows client (App.cs)

enum CloudValidation {
    static func ssid(_ s: String) throws { try Validation.validateSsid(s) }
    static func password(_ s: String) throws { try Validation.validatePassword(s) }
    static func name(_ s: String) throws { try Validation.validateName(s) }
    /// `FeatureContracts.Address(input, AddressFamily.InterNetwork)`.
    static func ipv4(_ input: String) throws -> String { try FeatureContracts.address(input, .inet) }
    /// `Uri.TryCreate(..., Absolute) && Scheme == https && UserInfo == ""`.
    static func httpsURL(_ s: String) -> Bool {
        guard let c = URLComponents(string: s), c.scheme?.lowercased() == "https", c.host?.isEmpty == false else { return false }
        return c.user == nil && c.password == nil
    }
}

func cloudCopy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - AppModel helpers

extension AppModel {
    /// `NetworkId` from ExtendedFeatures.cs: the validated identifier of the selected network.
    func validatedNetworkId() throws -> String {
        try ExtendedContracts.identifier(networkId)
    }

    /// Port of `MainWindow.Read`.
    func cloudRead(_ path: String) async throws -> JSON {
        if preview { throw EeroError.operation("Sign in to load this information.") }
        return try await api.send("GET", path)
    }

    /// Port of `MainWindow.Change`: send, then refresh the network and the current page.
    func cloudChange(_ method: String, _ path: String, _ body: JSON?, form: Bool = false, _ message: String) async throws {
        if preview { throw EeroError.operation("Preview mode is read only. Sign in to manage your network.") }
        _ = try await api.send(method, path, body, form: form)
        do {
            if !(networkURL ?? "").isEmpty { try await loadNetwork() }
            if currentPage == "Home/Profiles/Profile" && !selectedProfile.isNull {
                selectedProfile = try await api.send("GET", selectedProfile.s("url"))
            } else if currentPage == "Home/eeros/Details" && !selectedNode.isNull {
                selectedNode = try await api.send("GET", selectedNode.s("url"))
            } else {
                try await FeatureAreas.load(currentPage, model: self)
            }
            setNotice(message)
        } catch let e as ApiError where e.sessionExpired {
            throw e
        } catch {
            setNotice(message + " Refresh did not finish: " + userMessage(error), error: true)
        }
    }

    /// Port of `ReloadMembership` (ExtendedFeatures.cs): reload everything after joining or leaving a network.
    func reloadMembership(_ message: String) async {
        selectedProfile = .null; selectedNode = .null; network = .null; networkURL = nil
        devices = []; nodes = []; profiles = []; featureData = [:]
        currentPage = "Home"
        do { try await loadAccount(); screen = .shell; setNotice(message) }
        catch { screen = .shell; setNotice(message + " Refresh did not finish: " + userMessage(error), error: true) }
    }

    /// Port of `MainWindow.Official`: opens an allowed official link in the default browser.
    func cloudOfficial(_ url: String) throws {
        if url == "about:blank" || !ServiceLinks.allowed(url) {
            throw EeroError.operation("The service returned a link outside the supported official domains.")
        }
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Page building blocks

/// Port of `Sub`: subtitle unless it repeats the page name.
struct CloudSub: View {
    let text: String
    let route: String
    var body: some View {
        if text.caseInsensitiveCompare(route.split(separator: "/").last.map(String.init) ?? "") != .orderedSame {
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary).padding(.bottom, 6)
        }
    }
}

struct CloudNote: View {
    let text: String
    var size: CGFloat = 13
    init(_ text: String, size: CGFloat = 13) { self.text = text; self.size = size }
    var body: some View { Text(text).font(.system(size: size)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct CloudHeading: View {
    let text: String
    var size: CGFloat = 20
    init(_ text: String, size: CGFloat = 20) { self.text = text; self.size = size }
    var body: some View { Text(text).font(.system(size: size, weight: .semibold)) }
}

/// Port of `Button(title, async action)`: runs through `model.run` (busy indicator, errors in the notice bar).
struct CloudAction: View {
    let title: String
    @ObservedObject var model: AppModel
    let action: () async throws -> Void
    init(_ title: String, _ model: AppModel, _ action: @escaping () async throws -> Void) {
        self.title = title; self.model = model; self.action = action
    }
    var body: some View { Button(title) { model.perform { try await action() } }.disabled(model.busy) }
}

/// Port of `LocalButton`: a synchronous local action, ignored while busy.
struct CloudLocal: View {
    let title: String
    @ObservedObject var model: AppModel
    let action: () -> Void
    init(_ title: String, _ model: AppModel, _ action: @escaping () -> Void) { self.title = title; self.model = model; self.action = action }
    var body: some View { Button(title) { if !model.busy { action() } } }
}

/// Wrapping row of buttons (port of `ActionRow` / `WrapPanel`).
struct CloudFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// Port of `MainWindow.Details`: a readable rendering of an API object.
struct CloudDetails: View {
    let value: JSON
    struct Line: Identifiable { let id: Int; let text: String; let indent: Int; let heading: Bool; let secondary: Bool; let spacer: Bool }

    static let hidden = try! NSRegularExpression(pattern: "(^resources$|^url$|token|password|secret|credential|certificate|master_key|private_key|psk|operational_dataset|software_key|invite_code|signed_upload_url|kms_key_id|mwb_full_report_url|^coupon$)", options: [.caseInsensitive])

    static func lines(_ value: JSON) -> [Line] {
        var out: [Line] = []
        func add(_ text: String, _ indent: Int, heading: Bool = false, secondary: Bool = false, spacer: Bool = false) {
            out.append(Line(id: out.count, text: text, indent: indent, heading: heading, secondary: secondary, spacer: spacer))
        }
        func walk(_ value: JSON, _ depth: Int, _ indent: Int) {
            if depth > 4 { return }
            if case .object(let map) = value {
                for key in map.keys.sorted() {
                    let item = map[key]!
                    if hidden.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil { continue }
                    switch item {
                    case .object, .array:
                        add(cloudHuman(key), indent, heading: true, secondary: true)
                        walk(item, depth + 1, indent + 1)
                    default:
                        let display: String
                        if case .bool(let b) = item { display = b ? "On" : "Off" } else { display = item.string }
                        if !display.isEmpty && !display.hasPrefix("/2.") { add(cloudHuman(key) + ": " + display, indent) }
                    }
                }
                return
            }
            if case .array(let list) = value, !list.isEmpty {
                let scalar = list.allSatisfy { if case .object = $0 { return false }; if case .array = $0 { return false }; return true }
                if scalar {
                    add(list.prefix(60).map(\.string).filter { !$0.hasPrefix("/2.") }.joined(separator: " · "), indent)
                } else {
                    for item in list.prefix(60) { walk(item, depth + 1, indent); add("", indent, spacer: true) }
                }
                return
            }
            switch value {
            case .null, .array: add("No entries returned.", indent, secondary: true)
            default: add(value.string, indent)
            }
        }
        walk(value, 0, 0)
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Self.lines(value)) { line in
                if line.spacer { Spacer().frame(height: 8) }
                else {
                    Text(line.text)
                        .font(.system(size: line.heading ? 14 : 13, weight: line.heading ? .semibold : .regular))
                        .foregroundStyle(line.secondary ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, CGFloat(line.indent) * 12)
                }
            }
        }
    }
}

/// Port of `ObjectCards`.
struct CloudObjectCard: View {
    let value: JSON?
    var title: String? = nil
    var body: some View {
        if let value, !value.isNull {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    if let title { CloudHeading(title) }
                    CloudDetails(value: value)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            CloudNote("Use Refresh to load this section.", size: 14)
        }
    }
}

// MARK: - Dialogs

/// A field of a `CloudForm` (port of `MainWindow.Field`).
struct CloudField {
    enum Kind { case text, long, multiline, password, bool, choice, link }
    let key: String
    let label: String
    let kind: Kind
    var text = ""
    var flag = false
    var choices: [String] = []

    static func text(_ key: String, _ label: String, _ value: String = "") -> CloudField { CloudField(key: key, label: label, kind: .text, text: value) }
    static func long(_ key: String, _ label: String, _ value: String = "") -> CloudField { CloudField(key: key, label: label, kind: .long, text: value) }
    static func multiline(_ key: String, _ label: String, _ value: String = "") -> CloudField { CloudField(key: key, label: label, kind: .multiline, text: value) }
    static func password(_ key: String, _ label: String) -> CloudField { CloudField(key: key, label: label, kind: .password) }
    static func bool(_ key: String, _ label: String, _ value: Bool) -> CloudField { CloudField(key: key, label: label, kind: .bool, flag: value) }
    static func choice(_ key: String, _ label: String, _ value: String, _ choices: [String]) -> CloudField {
        CloudField(key: key, label: label, kind: .choice, text: choices.contains(value) ? value : (choices.first ?? ""), choices: choices)
    }
    static func link(_ label: String, _ url: String) -> CloudField { CloudField(key: "", label: label, kind: .link, text: url) }
}

/// Port of `MainWindow.Edit`: a modal form whose save action closes it on success.
struct CloudForm {
    let title: String
    let fields: [CloudField]
    var submit = "Save"
    var description: String? = nil
    let save: @MainActor (CloudValues) async throws -> Void
}

/// One modal sheet on a cloud page.
struct CloudSheet: Identifiable {
    let id = UUID()
    let content: AnyView
}

/// Presents forms, information dialogs and bespoke dialogs for one page.
@MainActor
final class CloudPresenter: ObservableObject {
    @Published var sheet: CloudSheet?

    func show<V: View>(_ view: V) {
        let next = CloudSheet(content: AnyView(view))
        if sheet != nil {
            // `AfterEditor`: let the previous sheet close before presenting the next one.
            sheet = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.sheet = next }
        } else { sheet = next }
    }
    func form(_ title: String, _ fields: [CloudField], submit: String = "Save", description: String? = nil, model: AppModel,
              _ save: @escaping @MainActor (CloudValues) async throws -> Void) {
        show(CloudFormView(form: CloudForm(title: title, fields: fields, submit: submit, description: description, save: save), model: model))
    }
    /// Port of `MainWindow.Info`.
    func info(_ title: String, _ data: JSON) { show(CloudInfoView(title: title, data: data)) }
}

extension View {
    /// Hosts a page's `CloudPresenter` sheets, with the shared confirmation alert available inside them.
    func cloudSheets(_ presenter: CloudPresenter, model: AppModel) -> some View {
        modifier(CloudSheetHost(presenter: presenter, model: model))
    }
}

private struct CloudSheetHost: ViewModifier {
    @ObservedObject var presenter: CloudPresenter
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
        content.sheet(item: $presenter.sheet) { sheet in
            ScrollView { sheet.content.padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minWidth: 480, idealWidth: 520, minHeight: 240, idealHeight: 480)
                .cloudConfirmations(model)
        }
    }
}

extension View {
    /// Shows `model.confirm(...)` prompts while a sheet is in front of the root view.
    func cloudConfirmations(_ model: AppModel) -> some View { modifier(CloudConfirmHost(model: model)) }
}

private struct CloudConfirmHost: ViewModifier {
    @ObservedObject var model: AppModel
    func resolve(_ c: AppModel.Confirmation, _ ok: Bool) {
        guard model.confirmation?.id == c.id else { return }
        model.confirmation = nil
        c.resume(ok)
    }
    func body(content: Content) -> some View {
        content.alert("Confirm", isPresented: Binding(get: { model.confirmation != nil }, set: { shown in
            if !shown, let c = model.confirmation { resolve(c, false) }
        }), presenting: model.confirmation) { c in
            Button("OK") { resolve(c, true) }
            Button("Cancel", role: .cancel) { resolve(c, false) }
        } message: { c in Text(c.message) }
    }
}

/// Status/actions shared by bespoke dialogs: error text and a "working" guard that blocks closing.
@MainActor
final class CloudDialogState: ObservableObject {
    @Published var status = ""
    @Published var working = false

    /// Runs a dialog action; returns true on success. A session expiry signs out like the Windows client.
    func run(_ model: AppModel, _ action: @escaping () async throws -> Void) async -> Bool {
        if working { return false }
        working = true; status = ""
        defer { working = false }
        do { try await action(); return true }
        catch let e as ApiError where e.sessionExpired {
            await model.api.forget(); model.clearData(); model.screen = .login(verify: false)
            model.setNotice("Your session expired. Sign in again.", error: true)
            return true
        }
        catch { status = userMessage(error); return false }
    }
}

struct CloudFormView: View {
    let form: CloudForm
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = CloudDialogState()
    @ViewState private var text: [String: String]
    @ViewState private var flags: [String: Bool]

    init(form: CloudForm, model: AppModel) {
        self.form = form; self.model = model
        var t: [String: String] = [:], f: [String: Bool] = [:]
        for field in form.fields where !field.key.isEmpty {
            if field.kind == .bool { f[field.key] = field.flag } else { t[field.key] = field.text }
        }
        _text = ViewState(wrappedValue: t); _flags = ViewState(wrappedValue: f)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { text[key] ?? "" }, set: { text[key] = String($0.prefix(4096)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudHeading(form.title, size: 24)
            if let d = form.description { CloudNote(d) }
            ForEach(Array(form.fields.enumerated()), id: \.offset) { _, field in
                switch field.kind {
                case .link:
                    Button(field.label) { do { try model.cloudOfficial(field.text) } catch { state.status = userMessage(error) } }
                case .bool:
                    Toggle(field.label, isOn: Binding(get: { flags[field.key] ?? false }, set: { flags[field.key] = $0 }))
                        .toggleStyle(.checkbox)
                default:
                    Text(field.label).font(.system(size: 13, weight: .semibold))
                    switch field.kind {
                    case .choice:
                        Picker("", selection: binding(field.key)) { ForEach(field.choices, id: \.self) { Text($0).tag($0) } }
                            .labelsHidden()
                    case .password:
                        SecureField("", text: binding(field.key)).textFieldStyle(.roundedBorder)
                    case .multiline:
                        TextEditor(text: binding(field.key)).font(.body).frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    default:
                        TextField("", text: binding(field.key)).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if !state.status.isEmpty { Text(state.status).font(.system(size: 13)).foregroundStyle(.red) }
            else if state.working { Text("Saving…").font(.system(size: 13)).foregroundStyle(.secondary) }
            HStack {
                Button(form.submit) {
                    Task {
                        var values = CloudValues(text: [:], flags: flags)
                        for field in form.fields where field.kind != .bool && !field.key.isEmpty {
                            let v = text[field.key] ?? ""
                            values.text[field.key] = field.kind == .multiline || field.kind == .long ? v : String(v.prefix(field.kind == .password ? 512 : 254))
                        }
                        if await state.run(model, { try await form.save(values) }) {
                            text = text.mapValues { _ in "" }   // clear secrets
                            dismiss()
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(state.working)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.working)
            }
        }
        .interactiveDismissDisabled(state.working)
    }
}

/// Port of `MainWindow.Info`.
struct CloudInfoView: View {
    let title: String
    let data: JSON
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudHeading(title, size: 23)
            CloudDetails(value: data)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}

#endif
