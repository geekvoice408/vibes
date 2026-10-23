#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

// Port of the generic dialog machinery in the Windows `FeatureUi.cs`:
// `Human`, `ObjectCards`, `Details`, `Info`, `Read`, `Change`, `Official` and the dialog host
// used by `Edit` (see FieldView.swift) and `ShowWifiQr` (see WifiQRCode.swift).

// MARK: - Key names and object details

enum FeatureText {
    private static let special: [String: String] = [
        "ip": "IP address", "mac": "MAC address", "ssid": "Wifi name", "up_mbps": "Upload (Mbps)", "down_mbps": "Download (Mbps)",
        "ipv6_upstream": "IPv6", "led_on": "Status light", "sqm": "Optimize for conferencing and gaming",
    ]

    /// Port of `Human`: turns an API key such as `last_speed_measurement` into "Last Speed Measurement".
    static func human(_ key: String) -> String {
        if let s = special[key] { return s }
        var s = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        s = s.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        // TextInfo.ToTitleCase: capitalize each word, keeping words that are entirely upper case.
        return s.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            if w.contains(where: { $0.isLetter }) && w == w.uppercased() { return w }
            guard let first = w.first else { return w }
            return String(first).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

/// One rendered line of `Details`.
struct DetailLine: Identifiable {
    enum Style { case heading, body, muted, gap }
    let id: Int
    let text: String
    let indent: Int
    let style: Style
}

/// Port of `Details`: flattens any JSON value into readable lines, hiding URLs and secrets.
enum ObjectDetails {
    static let hiddenKeys = try! NSRegularExpression(
        pattern: "(^resources$|^url$|token|password|secret|credential|certificate|master_key|private_key|psk|operational_dataset|software_key|invite_code|signed_upload_url|kms_key_id|mwb_full_report_url|^coupon$)",
        options: [.caseInsensitive])

    static func hidden(_ key: String) -> Bool {
        hiddenKeys.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    static func lines(_ value: JSON) -> [DetailLine] {
        var out: [(String, Int, DetailLine.Style)] = []
        walk(value, depth: 0, indent: 0, into: &out)
        return out.enumerated().map { DetailLine(id: $0.offset, text: $0.element.0, indent: $0.element.1, style: $0.element.2) }
    }

    private static func isScalar(_ v: JSON) -> Bool {
        switch v { case .array, .object: return false; default: return true }
    }

    private static func walk(_ value: JSON, depth: Int, indent: Int, into out: inout [(String, Int, DetailLine.Style)]) {
        if depth > 4 { return }
        if case .object(let map) = value {
            for key in map.keys.sorted() {
                if hidden(key) { continue }
                let item = map[key] ?? .null
                if !isScalar(item) {
                    out.append((FeatureText.human(key), indent, .heading))
                    walk(item, depth: depth + 1, indent: indent + 1, into: &out)
                } else {
                    let display: String
                    if case .bool(let b) = item { display = b ? "On" : "Off" } else { display = item.string }
                    if !display.isEmpty && !display.hasPrefix("/2.") { out.append((FeatureText.human(key) + ": " + display, indent, .body)) }
                }
            }
            return
        }
        let list = value.list
        if !list.isEmpty && list.allSatisfy(isScalar) {
            let words = list.prefix(60).map(\.string).filter { !$0.hasPrefix("/2.") }
            out.append((words.joined(separator: " · "), indent, .body))
        } else if !list.isEmpty {
            for item in list.prefix(60) {
                walk(item, depth: depth + 1, indent: indent, into: &out)
                out.append(("", indent, .gap))
            }
        } else if !value.isNull && isScalar(value) {
            out.append((value.string, indent, .body))
        } else {
            out.append(("No entries returned.", indent, .muted))
        }
    }
}

/// Renders `Details` for a value.
struct ObjectDetailsView: View {
    let value: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ObjectDetails.lines(value)) { line in
                switch line.style {
                case .heading:
                    Text(line.text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(line.indent) * 12).padding(.top, 4)
                case .body:
                    Text(line.text).font(.system(size: 13)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, CGFloat(line.indent) * 12)
                case .muted:
                    Text(line.text).font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(line.indent) * 12)
                case .gap:
                    Color.clear.frame(height: 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Port of `ObjectCards`: a card with an optional title and the value's details.
struct ObjectCards: View {
    let value: JSON
    var title: String? = nil
    init(_ value: JSON, _ title: String? = nil) { self.value = value; self.title = title }
    var body: some View {
        if value.isNull {
            Text("Use Refresh to load this section.").font(.system(size: 14)).foregroundStyle(.secondary)
        } else {
            FeatureCard {
                if let title { Text(title).font(.system(size: 20, weight: .semibold)) }
                ObjectDetailsView(value: value)
            }
        }
    }
}

// MARK: - Info

/// Port of `Info`: a dialog showing a title and the details of a value.
struct InfoSheet: View {
    let title: String
    let data: JSON
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.system(size: 23, weight: .semibold))
                    ObjectDetailsView(value: data)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 600)
    }
}

// MARK: - Dialog host

/// Dialogs requested by feature pages (the WPF `Dialog(...).ShowDialog()` windows).
@MainActor
final class FeatureDialogs: ObservableObject {
    static let shared = FeatureDialogs()

    enum Dialog: Identifiable {
        case info(id: UUID, title: String, data: JSON)
        case edit(EditForm)
        case wifiQr(id: UUID, name: String, password: String)
        case custom(id: UUID, title: String, content: AnyView)

        var id: UUID {
            switch self {
            case .info(let id, _, _), .wifiQr(let id, _, _), .custom(let id, _, _): return id
            case .edit(let f): return f.id
            }
        }
    }

    @Published var current: Dialog?

    func show(_ dialog: Dialog) { current = dialog }
    /// Closes `id` if it is still the dialog on screen.
    func close(_ id: UUID) { if current?.id == id { current = nil } }
}

private struct FeatureDialogsHostedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var featureDialogsHosted: Bool {
        get { self[FeatureDialogsHostedKey.self] }
        set { self[FeatureDialogsHostedKey.self] = newValue }
    }
}

/// Presents `FeatureDialogs.shared`. Attach once near the root (`.featureDialogs(model)`); nested hosts are inert.
@MainActor
struct FeatureDialogHost: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject private var dialogs = FeatureDialogs.shared
    @Environment(\.featureDialogsHosted) private var hosted

    func body(content: Content) -> some View {
        if hosted {
            content
        } else {
            content
                .environment(\.featureDialogsHosted, true)
                .sheet(item: $dialogs.current) { dialog in
                    sheet(dialog).environment(\.featureDialogsHosted, true)
                }
        }
    }

    @ViewBuilder private func sheet(_ dialog: FeatureDialogs.Dialog) -> some View {
        let close = { FeatureDialogs.shared.close(dialog.id) }
        switch dialog {
        case .info(_, let title, let data):
            InfoSheet(title: title, data: data, close: close)
        case .edit(let form):
            EditSheet(form: form, model: model, close: close)
        case .wifiQr(_, let name, let password):
            WifiQRSheet(name: name, password: password, close: close)
        case .custom(_, let title, let content):
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title).font(.system(size: 23, weight: .semibold))
                        content
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction) }.padding(12)
            }
            .frame(minWidth: 480, idealWidth: 620, minHeight: 300, idealHeight: 520)
        }
    }
}

extension View {
    /// Hosts feature dialogs (Info, Edit, wifi QR code and custom dialogs) for this view tree.
    func featureDialogs(_ model: AppModel) -> some View { modifier(FeatureDialogHost(model: model)) }
}

// MARK: - AppModel helpers from FeatureUi.cs

extension AppModel {
    /// Port of `Read`.
    func read(_ path: String) async throws -> JSON {
        if preview { throw EeroError.operation("Sign in to load this information.") }
        return try await api.send("GET", path)
    }

    /// Port of `Change`: sends a change, then refreshes the network and the current page.
    func change(_ method: String, _ path: String, _ body: JSON?, form: Bool = false, message: String) async throws {
        if preview { throw EeroError.operation("Preview mode is read only. Sign in to manage your network.") }
        try await api.send(method, path, body, form: form)
        do {
            if let url = networkURL, !url.isEmpty { try await loadNetwork() }
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

    /// Positional form matching the C# `Change(method, path, body, form, message)`.
    func change(_ method: String, _ path: String, _ body: JSON?, _ form: Bool, _ message: String) async throws {
        try await change(method, path, body, form: form, message: message)
    }

    /// Port of `Info`.
    func info(_ title: String, _ data: JSON) {
        FeatureDialogs.shared.show(.info(id: UUID(), title: title, data: data))
    }

    /// Port of `ShowWifiQr`.
    func showWifiQr(_ name: String, _ password: String) {
        FeatureDialogs.shared.show(.wifiQr(id: UUID(), name: name, password: password))
    }

    /// Shows an arbitrary dialog (used where the Windows client built a one-off `Dialog`).
    func presentDialog<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) {
        FeatureDialogs.shared.show(.custom(id: UUID(), title: title, content: AnyView(content())))
    }

    /// Port of `Official`: opens an official service link in the default browser.
    func official(_ url: String) throws {
        if url == "about:blank" || !ServiceLinks.allowed(url) {
            throw EeroError.operation("The service returned a link outside the supported official domains.")
        }
        guard let u = URL(string: url) else {
            throw EeroError.operation("The service returned a link outside the supported official domains.")
        }
        NSWorkspace.shared.open(u)
    }

    /// Port of `LocalButton`'s handler: runs a synchronous action and reports its error.
    func runLocal(_ action: () throws -> Void) {
        do { try action() } catch { setNotice(userMessage(error), error: true) }
    }
}
#endif
