#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import EeroCore

// Shared building blocks for the networking, profiles/security, network-creation and
// registration pages: the generic `Edit` dialog, `Info` dialog, `Details` renderer,
// `Change`/`Read` helpers and the small dialogs these pages open.
// Names carry a `Net` prefix so they never collide with other feature areas.

// MARK: - Helpers (ports of small MainWindow statics)

enum NetUI {
    /// Port of `Human`: turns an API key into a readable label.
    static func human(_ key: String) -> String {
        let special = ["ip": "IP address", "mac": "MAC address", "ssid": "Wifi name", "up_mbps": "Upload (Mbps)", "down_mbps": "Download (Mbps)",
                       "ipv6_upstream": "IPv6", "led_on": "Status light", "sqm": "Optimize for conferencing and gaming"]
        if let s = special[key] { return s }
        let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        // TextInfo.ToTitleCase: capitalise each word, leaving words that are entirely upper case alone.
        return spaced.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            if w.isEmpty { return w }
            if w.contains(where: { $0.isLetter }) && w == w.uppercased() { return w }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Port of `Device(d).Name`.
    static func deviceName(_ d: JSON) -> String { d.first("nickname", "display_name", "hostname", "mac") }
    /// Port of `ObjectUrl`.
    static func objectURL(_ data: JSON?, _ fallback: String? = nil) -> String? { (data ?? .null).s("url").nilIfEmpty ?? fallback }

    /// Last path segment of an API URL (`url.TrimEnd('/').Split('/').Last()`).
    static func lastSegment(_ url: String) -> String {
        url.trimmingSuffix("/").split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// Port of `Entries`.
    static func entries(_ data: JSON?, _ names: String...) -> [JSON] {
        let data = data ?? .null
        let direct = data.list
        if !direct.isEmpty { return direct }
        for name in names { let a = data[name].list; if !a.isEmpty { return a } }
        return []
    }

    /// `Uri.EscapeDataString`.
    static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Port of `StatsRange`.
    static func statsRange(_ days: Int = 7) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let end = Date(), start = end.addingTimeInterval(-Double(days) * 86400)
        return "start=" + escape(f.string(from: start)) + "&end=" + escape(f.string(from: end))
    }

    /// Port of `Official`: opens an official service link in the default browser.
    static func openOfficial(_ url: String) throws {
        guard url != "about:blank", ServiceLinks.allowed(url), let u = URL(string: url) else {
            throw EeroError.operation("The service returned a link outside the supported official domains.")
        }
        NSWorkspace.shared.open(u)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Wifi QR image (port of the QRCoder usage in `ShowWifiQr`, error correction level Q).
    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

extension String {
    var netTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - AppModel helpers (ports of Read / Change)

extension AppModel {
    /// The selected network URL (`networkUrl`), or an error when none is selected.
    func netURL() throws -> String {
        guard let networkURL, !networkURL.isEmpty else { throw EeroError.operation("Select a network first.") }
        return networkURL
    }

    /// Port of `Read`.
    func netRead(_ path: String) async throws -> JSON {
        if preview { throw EeroError.operation("Sign in to load this information.") }
        return try await api.send("GET", path)
    }

    /// Port of `Change`: sends a change, then refreshes the network and the current page.
    func netChange(_ method: String, _ path: String, _ body: JSON?, form: Bool = false, _ message: String) async throws {
        if preview { throw EeroError.operation("Preview mode is read only. Sign in to manage your network.") }
        try await api.send(method, path, body, form: form)
        do {
            if let networkURL, !networkURL.isEmpty { try await loadNetwork() }
            if currentPage == "Home/Profiles/Profile" && !selectedProfile.isNull {
                selectedProfile = try await api.send("GET", selectedProfile.s("url"))
            } else if currentPage == "Home/eeros/Details" && !selectedNode.isNull {
                selectedNode = try await api.send("GET", selectedNode.s("url"))
            } else {
                try await FeatureAreas.load(currentPage, model: self)
            }
            setNotice(message)
        } catch {
            setNotice(message + " Refresh did not finish: " + userMessage(error), error: true)
        }
    }

    /// Port of the session-expiry branch of the `Edit` dialog.
    func netSessionExpired() async {
        await api.forget()
        clearData()
        screen = .login(verify: false)
        setNotice("Your session expired. Sign in again.", error: true)
    }

    /// Runs a synchronous "LocalButton" action, reporting validation errors as a notice.
    func netLocal(_ action: () throws -> Void) {
        do { try action() } catch { setNotice(userMessage(error), error: true) }
    }
}

// MARK: - Edit dialog (port of `Field` / `Edit`)

struct NetField {
    enum Kind { case text, long, multiline, password, bool, choice, link }
    var key: String
    var label: String
    var value: JSON
    var kind: Kind
    var choices: [String]

    init(_ key: String, _ label: String, _ value: JSONConvertible? = nil, _ kind: Kind = .text, _ choices: [String] = []) {
        self.key = key; self.label = label; self.value = value?.json ?? .null; self.kind = kind; self.choices = choices
    }
    static func bool(_ key: String, _ label: String, _ on: Bool) -> NetField { NetField(key, label, on, .bool) }
    static func choice(_ key: String, _ label: String, _ value: String, _ choices: [String]) -> NetField { NetField(key, label, value, .choice, choices) }
    static func password(_ key: String, _ label: String) -> NetField { NetField(key, label, nil, .password) }
    static func link(_ label: String, _ url: String) -> NetField { NetField("", label, url, .link) }
}

/// Values collected by an edit dialog (`V` / `Flag`), plus the dialog's confirmation prompt.
@MainActor
final class NetValues {
    private let text: [String: String]
    private let flags: [String: Bool]
    private let ask: (String) async -> Bool
    init(text: [String: String], flags: [String: Bool], ask: @escaping (String) async -> Bool) {
        self.text = text; self.flags = flags; self.ask = ask
    }
    /// `V(values, key)`.
    subscript(_ key: String) -> String {
        if let f = flags[key] { return f ? "True" : "False" }
        return text[key] ?? ""
    }
    /// `Flag(values, key)`.
    func flag(_ key: String) -> Bool { flags[key] ?? false }
    /// `Confirm(...)` shown on top of the dialog.
    func confirm(_ message: String) async -> Bool { await ask(message) }
}

struct NetEditRequest {
    var title: String
    var fields: [NetField]
    var submit = "Save"
    var description: String?
    var save: (NetValues) async throws -> Void
}

/// Confirmation prompt owned by a dialog (WPF `Confirm` while a dialog is open).
@MainActor
final class NetConfirmer: ObservableObject {
    final class Pending: Identifiable {
        let id = UUID(); let message: String
        private var resume: ((Bool) -> Void)?
        init(_ message: String, _ resume: @escaping (Bool) -> Void) { self.message = message; self.resume = resume }
        func finish(_ value: Bool) { let r = resume; resume = nil; r?(value) }
    }
    @Published var pending: Pending?
    func ask(_ message: String) async -> Bool {
        await withCheckedContinuation { c in pending = Pending(message) { c.resume(returning: $0) } }
    }
}

struct NetConfirmAlert: ViewModifier {
    @ObservedObject var confirmer: NetConfirmer
    func body(content: Content) -> some View {
        content.alert("eero", isPresented: Binding(get: { confirmer.pending != nil }, set: { shown in
            if !shown, let p = confirmer.pending { confirmer.pending = nil; p.finish(false) }
        }), presenting: confirmer.pending) { p in
            Button("Continue") { confirmer.pending = nil; p.finish(true) }
            Button("Cancel", role: .cancel) { confirmer.pending = nil; p.finish(false) }
        } message: { p in Text(p.message) }
    }
}

extension View {
    func netConfirmAlert(_ confirmer: NetConfirmer) -> some View { modifier(NetConfirmAlert(confirmer: confirmer)) }
}

@MainActor
struct NetEditSheet: View {
    let request: NetEditRequest
    @ObservedObject var model: AppModel
    /// Called instead of `dismiss` when the form is hosted outside a sheet (registration window).
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var confirmer = NetConfirmer()
    @State private var text: [String: String]
    @State private var flags: [String: Bool]
    @State private var status = ""
    @State private var working = false

    init(request: NetEditRequest, model: AppModel, onClose: (() -> Void)? = nil) {
        self.request = request; self.model = model; self.onClose = onClose
        var t: [String: String] = [:], f: [String: Bool] = [:]
        for field in request.fields {
            switch field.kind {
            case .link: continue
            case .bool: f[field.key] = field.value == .bool(true)
            case .choice:
                let v = field.value.string
                t[field.key] = field.choices.contains(v) ? v : (field.choices.first ?? "")
            case .password: t[field.key] = ""
            default: t[field.key] = field.value.string
            }
        }
        _text = State(initialValue: t); _flags = State(initialValue: f)
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }

    private func textBinding(_ key: String, max: Int) -> Binding<String> {
        Binding(get: { text[key] ?? "" }, set: { text[key] = String($0.prefix(max)) })
    }

    @ViewBuilder private func fieldView(_ field: NetField) -> some View {
        switch field.kind {
        case .link:
            Button(field.label) { model.netLocal { try NetUI.openOfficial(field.value.string) } }
                .buttonStyle(.link)
        case .bool:
            Toggle(isOn: Binding(get: { flags[field.key] ?? false }, set: { flags[field.key] = $0 })) {
                Text(field.label).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.checkbox)
        case .choice:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.callout.bold())
                Picker(field.label, selection: textBinding(field.key, max: 4096)) {
                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
        case .password:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.callout.bold())
                SecureField("", text: textBinding(field.key, max: 512)).textFieldStyle(.roundedBorder)
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.callout.bold())
                TextEditor(text: textBinding(field.key, max: 4096))
                    .font(.body).frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            }
        case .text, .long:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.callout.bold())
                TextField("", text: textBinding(field.key, max: field.kind == .long ? 4096 : 254)).textFieldStyle(.roundedBorder)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.title).font(.title2.bold())
                    if let d = request.description { Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(Array(request.fields.enumerated()), id: \.offset) { _, field in fieldView(field) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(working ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(request.submit) { commit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(working)
                Button("Cancel") { if !working { close() } }.keyboardShortcut(.cancelAction).disabled(working)
            }
        }
        .padding(28)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 260, idealHeight: 520)
        .interactiveDismissDisabled(working)
        .netConfirmAlert(confirmer)
        .onDisappear {
            // Clear secrets when the dialog closes.
            for f in request.fields where f.kind == .password { text[f.key] = "" }
        }
    }

    private func commit() {
        if working { return }
        working = true; status = "Saving…"
        let confirmer = self.confirmer
        let values = NetValues(text: text, flags: flags) { await confirmer.ask($0) }
        Task { @MainActor in
            do {
                try await request.save(values)
                working = false
                close()
            } catch {
                working = false
                status = userMessage(error)
                if let a = error as? ApiError, a.sessionExpired { close(); await model.netSessionExpired() }
            }
            working = false
        }
    }
}

// MARK: - Details renderer (port of `Details` / `ObjectCards` / `Info`)

enum NetDetails {
    private static let hidden = try! NSRegularExpression(pattern: "(^resources$|^url$|token|password|secret|credential|certificate|master_key|private_key|psk|operational_dataset|software_key|invite_code|signed_upload_url|kms_key_id|mwb_full_report_url|^coupon$)", options: [.caseInsensitive])

    private static func isHidden(_ key: String) -> Bool {
        hidden.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    private static func isScalar(_ v: JSON) -> Bool {
        switch v { case .array, .object: return false; default: return true }
    }

    static func view(_ value: JSON?, depth: Int = 0) -> AnyView {
        if depth > 4 { return AnyView(EmptyView()) }
        let value = value ?? .null
        if case .object(let map) = value {
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                ForEach(map.keys.sorted().filter { !isHidden($0) }, id: \.self) { key in
                    let item = map[key]!
                    if !isScalar(item) {
                        Text(NetUI.human(key)).font(.callout.bold()).foregroundStyle(.secondary)
                        view(item, depth: depth + 1).padding(.leading, 12).padding(.bottom, 12)
                    } else {
                        let display: String = { if case .bool(let b) = item { return b ? "On" : "Off" }; return item.string }()
                        if !display.isEmpty && !display.hasPrefix("/2.") {
                            Text(NetUI.human(key) + ": " + display).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            })
        }
        let list = value.list
        if !list.isEmpty && list.allSatisfy(isScalar) {
            let joined = list.prefix(60).map(\.string).filter { !$0.hasPrefix("/2.") }.joined(separator: " · ")
            return AnyView(Text(joined).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true))
        }
        if !list.isEmpty {
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(list.prefix(60).enumerated()), id: \.offset) { _, item in view(item, depth: depth + 1) }
            })
        }
        if isScalar(value) && !value.isNull {
            return AnyView(Text(value.string).font(.callout).textSelection(.enabled))
        }
        return AnyView(Text("No entries returned.").font(.callout).foregroundStyle(.secondary))
    }
}

/// Port of `ObjectCards`.
struct NetObjectCard: View {
    let value: JSON?
    var title: String?
    var body: some View {
        if let value, !value.isNull {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    if let title { Text(title).font(.title3.bold()) }
                    NetDetails.view(value)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Use Refresh to load this section.").foregroundStyle(.secondary)
        }
    }
}

/// Port of `Info`.
struct NetInfoSheet: View {
    let title: String
    let data: JSON
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.title2.bold())
                    NetDetails.view(data)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(minWidth: 480, idealWidth: 620, minHeight: 300, idealHeight: 600)
    }
}

/// Port of `ShowPassword`.
struct NetPasswordSheet: View {
    @State var password: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wifi password").font(.title2.bold())
            Text(password).font(.body.monospaced()).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(minWidth: 420)
        .onDisappear { password = "" }
    }
}

/// Port of `ShowWifiQr`.
struct NetQRSheet: View {
    let name: String
    let password: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join " + name).font(.title2.bold())
            if let image = NetUI.qrImage(FeatureContracts.wifiQr(name, password)) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 320, height: 320).padding(.vertical, 12)
            }
            Text("This QR code contains your wifi credentials. Anyone who scans it can join the network.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(minWidth: 400)
    }
}

/// Port of `ShowCredentials`.
struct NetCredentialsSheet: View {
    let title: String
    @State var values: [(String, String)]
    @State private var revealed: Set<Int> = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            Text("Reveal or copy only when you need these details. Copied values remain in the Mac clipboard.").font(.callout).foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { index, entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.0).font(.callout.bold())
                    Text(revealed.contains(index) ? entry.1 : String(repeating: "•", count: min(max(entry.1.count, 8), 24)))
                        .font(.body.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(revealed.contains(index) ? "Hide" : "Reveal") { if revealed.contains(index) { revealed.remove(index) } else { revealed.insert(index) } }
                        Button("Copy") { NetUI.copy(entry.1) }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(minWidth: 460)
        .onDisappear { revealed = []; values = [] }
    }
}

// MARK: - Sheet presenter

struct NetSheet: Identifiable {
    let id = UUID()
    let content: AnyView
}

@MainActor
final class NetSheets: ObservableObject {
    @Published var current: NetSheet?

    func show<V: View>(_ view: V) { current = NetSheet(content: AnyView(view)) }

    func edit(_ model: AppModel, _ title: String, _ fields: [NetField], submit: String = "Save", description: String? = nil,
              _ save: @escaping (NetValues) async throws -> Void) {
        show(NetEditSheet(request: NetEditRequest(title: title, fields: fields, submit: submit, description: description, save: save), model: model))
    }
    func info(_ title: String, _ data: JSON) { show(NetInfoSheet(title: title, data: data)) }
    func password(_ password: String) { show(NetPasswordSheet(password: password)) }
    func qr(_ name: String, _ password: String) { show(NetQRSheet(name: name, password: password)) }
    func credentials(_ title: String, _ values: [(String, String)]) { show(NetCredentialsSheet(title: title, values: values)) }

    /// Port of `AfterEditor`: runs once the current dialog has closed.
    func after(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            action()
        }
    }
}

extension View {
    func netSheets(_ sheets: NetSheets) -> some View { modifier(NetSheetHost(sheets: sheets)) }
}

struct NetSheetHost: ViewModifier {
    @ObservedObject var sheets: NetSheets
    func body(content: Content) -> some View {
        content.sheet(item: $sheets.current) { $0.content }
    }
}

// MARK: - Layout helpers

/// Wrapping row of buttons (port of `ActionRow` / `WrapPanel`).
struct NetFlow: Layout {
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

/// Page subtitle (port of `Sub`): hidden when it repeats the page title.
struct NetSubtitle: View {
    let text: String
    let route: String
    var body: some View {
        if text.lowercased() != (route.split(separator: "/").last.map(String.init) ?? "").lowercased() {
            Text(text).foregroundStyle(.secondary).padding(.bottom, 4)
        }
    }
}

/// Muted helper text (`Text(…, 13, "#64738A")`).
struct NetCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

/// Port of `Detail`.
struct NetDetail: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }
    var body: some View { DetailRow(name: name, value: value.isEmpty ? "Unavailable" : value) }
}
#endif
