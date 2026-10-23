import Foundation

/// A nearby eero advertising the setup service (port of `BluetoothEero`).
/// `id` is CoreBluetooth's per-Mac peripheral identifier (macOS does not expose the BLE address the Windows app used).
public struct BluetoothEero: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var version: String?
    public var signal: Int
    public var inNetwork: Bool?
    public var ethernet: Bool?

    public init(id: UUID, name: String, version: String? = nil, signal: Int, inNetwork: Bool? = nil, ethernet: Bool? = nil) {
        self.id = id; self.name = name; self.version = version; self.signal = signal; self.inNetwork = inNetwork; self.ethernet = ethernet
    }

    /// Parses the advertised local name `<version>-<in network>-<ethernet>` (port of `BluetoothEero.Advertisement`).
    /// Version 3 reports network membership only; version 4+ reports Ethernet only; anything else stays unknown.
    public static func advertisement(_ id: UUID, _ name: String?, _ signal: Int) -> BluetoothEero {
        var row = BluetoothEero(id: id, name: (name ?? "").isEmpty ? "eero Setup" : name!, signal: signal)
        let parts = (name ?? "").split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, let major = BluetoothContracts.versionMajor(parts[0]) {
            row.version = parts[0]
            if major == 3 { row.inNetwork = parts[1] == "1" } else if major >= 4 { row.ethernet = parts[2] == "1" }
        }
        return row
    }
}

/// Platform-neutral Bluetooth setup constants and parsing (pure parts of BluetoothSetup.cs).
/// The CoreBluetooth scanner and GATT reads live in the macOS app; it performs no GATT writes.
public enum BluetoothContracts {
    /// eero setup GATT service advertised by eeros ready for setup.
    public static let eeroServiceUUID = "D99A3D3F-C1EF-4533-809D-82DE05D509CA"
    public static var eeroService: String { eeroServiceUUID }
    /// Full 128-bit forms of the Serial Number and Firmware Revision characteristics.
    public static var serial: String { serialCharacteristicFullUUID }
    public static var firmware: String { firmwareCharacteristicFullUUID }
    /// Standard Device Information characteristics: Serial Number String and Firmware Revision String.
    public static let serialCharacteristicUUID = "2A25"
    public static let firmwareCharacteristicUUID = "2A26"
    public static let serialCharacteristicFullUUID = "00002A25-0000-1000-8000-00805F9B34FB"
    public static let firmwareCharacteristicFullUUID = "00002A26-0000-1000-8000-00805F9B34FB"

    /// Default scan (15 s) and the clamp applied to requested scan durations (1–30 s).
    public static let defaultScanSeconds = 15
    public static func scanSeconds(_ requested: Int) -> Int { max(1, min(requested, 30)) }

    /// Value shown for a characteristic that could not be read.
    public static let unavailable = "Unavailable"

    /// `System.Version.TryParse` major component: 2–4 dot-separated non-negative integers.
    static func versionMajor(_ text: String) -> Int? {
        let comps = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(comps.count) else { return nil }
        var values: [Int] = []
        for c in comps {
            let t = c.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.allSatisfy(\.isASCII), let v = Int32(t), v >= 0 else { return nil }
            values.append(Int(v))
        }
        return values[0]
    }

    /// Decodes a GATT string characteristic, trimming NUL and line terminators like the Windows reader.
    public static func characteristicString(_ data: Data?) -> String {
        guard let data else { return unavailable }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n"))
    }

    /// Identity details shown after reading an eero over Bluetooth (port of `NativeBluetooth.ReadInfo`'s result).
    public static func info(_ eero: BluetoothEero, serial: String, firmware: String) -> JSON {
        JSON.obj(
            ("serial", serial), ("firmware", firmware), ("bluetooth_version", eero.version),
            ("signal_dbm", eero.signal),
            ("already_in_network", eero.inNetwork.map { JSON.bool($0) } ?? "Not reported"),
            ("ethernet_connected", eero.ethernet.map { JSON.bool($0) } ?? "Not reported"))
    }

    /// Sorts scan results strongest signal first.
    public static func ordered(_ found: [BluetoothEero]) -> [BluetoothEero] {
        found.enumerated().sorted { $0.element.signal != $1.element.signal ? $0.element.signal > $1.element.signal : $0.offset < $1.offset }.map(\.element)
    }

    /// Diagnostic result written by the `--bluetooth-check` self-test (port of `NativeBluetooth.Check`).
    public static func checkResult(candidates: Int) -> JSON {
        JSON.obj(("ok", true), ("scan_completed", true), ("eero_candidates", candidates), ("gatt_writes", 0))
    }
    public static func checkFailure(_ error: Error) -> JSON {
        JSON.obj(("ok", false), ("error", userMessage(error)), ("gatt_writes", 0))
    }

    // Messages used by the platform scanner.
    public static let noAdapterMessage = "This Mac does not have an available Bluetooth Low Energy adapter."
    public static let unreachableMessage = "The eero could not be reached over Bluetooth. Keep it nearby and try scanning again."
    public static let serviceUnavailableMessage = "The eero setup service is not available. It may be out of range or no longer advertising setup."
    public static func scanFailedMessage(_ detail: String?) -> String {
        "macOS could not scan for Bluetooth devices" + (detail.map { " (" + $0 + ")" } ?? "") + ". Check that Bluetooth is enabled and that eero Desktop is allowed to use Bluetooth in System Settings > Privacy & Security."
    }
}
