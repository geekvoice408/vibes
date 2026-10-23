#if os(macOS)
import SwiftUI
import EeroCore

/// "Home/Add or replace eero/Find nearby eeros" (port of `BluetoothSetupPage`).
enum BluetoothArea: FeatureArea {
    static let route = "Home/Add or replace eero/Find nearby eeros"
    static func handles(_ route: String) -> Bool { route == Self.route }
    static func load(_ route: String, model: AppModel) async throws -> JSON? { nil }
    static func view(_ route: String, model: AppModel) -> AnyView {
        AnyView(BluetoothSetupView(model: model, scanner: BluetoothScanner.shared))
    }
}

struct BluetoothSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var scanner: BluetoothScanner
    @State private var info: PlatformInfo?

    private var entries: [BluetoothEero] {
        model.preview ? [BluetoothEero.advertisement(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, "4.0.0-Sample-1", -47)] : scanner.results
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Subtitle("Find nearby eeros advertising the setup service. Your Mac can read the serial number and firmware without changing network settings.")
            Button(scanner.scanning ? "Scanning…" : "Scan for nearby eeros") {
                model.perform("Scanning Bluetooth for \(BluetoothContracts.defaultScanSeconds) seconds…") {
                    if model.preview { throw EeroError.operation("Preview mode does not scan your devices.") }
                    let found = try await scanner.scan(seconds: BluetoothContracts.defaultScanSeconds)
                    model.setNotice("Bluetooth scan finished. Found \(found.count) eero device(s).")
                }
            }
            .disabled(scanner.scanning || model.busy)

            if entries.isEmpty {
                Card { Text("No scan results yet. Keep an eero ready for setup nearby, then scan.") }
            }
            ForEach(entries) { eero in
                Card {
                    SectionHeader(eero.name, size: 19)
                    Text("Signal: \(eero.signal) dBm").font(.callout).foregroundStyle(Palette.muted)
                    if eero.inNetwork == true {
                        Text("This eero reports that it is already in a network.").font(.callout).foregroundStyle(Palette.muted)
                    }
                    Button("Read eero identity") {
                        model.perform("Reading eero over Bluetooth…") {
                            let data = model.preview
                                ? JSON.obj(("serial", "SAMPLE-SERIAL"), ("firmware", "Preview"), ("ethernet_connected", true))
                                : try await scanner.readInfo(eero)
                            info = PlatformInfo(title: "Nearby eero", data: data)
                            model.setNotice("eero identity read over Bluetooth.")
                        }
                    }
                    .disabled(scanner.reading || model.busy)
                }
            }

            SectionLink(title: "Create a wired network", route: "Home/Add or replace eero/Create a network")

            Caption("The full Bluetooth provisioning and gateway replacement wizards are not implemented. These discovery controls perform no GATT writes.")
            Caption("macOS asks for Bluetooth permission the first time you scan. eero Desktop only listens for the eero setup service and reads two identity values.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $info) { PlatformInfoSheet(info: $0) }
    }
}

// MARK: Small shared pieces for the platform pages (Bluetooth, VPN)

/// Data shown by `Info(title, data)` on Windows.
struct PlatformInfo: Identifiable {
    let id = UUID()
    let title: String
    let data: JSON
}

/// Read-only key/value dialog (port of `Info`).
struct PlatformInfoSheet: View {
    let info: PlatformInfo
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String)] {
        if let o = info.data.object {
            return o.keys.sorted().map { key in
                (key.replacingOccurrences(of: "_", with: " ").capitalized, Self.describe(o[key] ?? .null))
            }
        }
        return [("Value", Self.describe(info.data))]
    }

    static func describe(_ value: JSON) -> String {
        switch value {
        case .bool(let b): return b ? "Yes" : "No"
        case .null: return "—"
        default: return value.string
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(info.title).font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1).textSelection(.enabled)
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
#endif
