#if os(macOS)
import CoreBluetooth
import Foundation
import EeroCore

// `BluetoothEero` (with `advertisement(id:name:signal:)`) and the UUIDs/messages live in EeroCore `BluetoothContracts`.

/// Port of `NativeBluetooth`: passive discovery of eeros advertising the setup service and read-only
/// identity checks (serial number and firmware characteristics). It never writes GATT values.
@MainActor
final class BluetoothScanner: NSObject, ObservableObject {
    static let shared = BluetoothScanner()

    static let eeroService = CBUUID(string: BluetoothContracts.eeroServiceUUID)
    static let serialCharacteristic = CBUUID(string: BluetoothContracts.serialCharacteristicUUID)
    static let firmwareCharacteristic = CBUUID(string: BluetoothContracts.firmwareCharacteristicUUID)

    @Published private(set) var results: [BluetoothEero] = []
    @Published private(set) var scanning = false
    @Published private(set) var reading = false

    private var central: CBCentralManager?
    private var found: [String: BluetoothEero] = [:]
    private var peripherals: [String: CBPeripheral] = [:]
    private var stateWaiters: [CheckedContinuation<Void, Never>] = []

    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var servicesWaiter: CheckedContinuation<[CBService], Error>?
    private var characteristicsWaiter: CheckedContinuation<[CBCharacteristic], Error>?
    private var readWaiter: CheckedContinuation<Data?, Never>?
    private weak var active: CBPeripheral?

    private static let unreachable = BluetoothContracts.unreachableMessage

    func clear() { results = []; found = [:]; peripherals = [:] }

    // MARK: Adapter

    private func readyCentral() async throws -> CBCentralManager {
        let manager = central ?? CBCentralManager(delegate: self, queue: nil)
        central = manager
        if manager.state == .unknown || manager.state == .resetting {
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                if !Task.isCancelled { self?.resumeStateWaiters() }
            }
            await withCheckedContinuation { stateWaiters.append($0) }
            timeout.cancel()
        }
        switch manager.state {
        case .poweredOn: return manager
        case .unauthorized:
            throw EeroError.operation("eero Desktop does not have permission to use Bluetooth. Allow it in System Settings > Privacy & Security > Bluetooth, then scan again.")
        case .poweredOff:
            throw EeroError.operation("Bluetooth is turned off. Turn it on in Control Center or System Settings, then scan again.")
        case .unsupported:
            throw EeroError.operation(BluetoothContracts.noAdapterMessage)
        default:
            throw EeroError.operation(BluetoothContracts.scanFailedMessage(nil))
        }
    }

    private func resumeStateWaiters() {
        let waiters = stateWaiters; stateWaiters = []
        for w in waiters { w.resume() }
    }

    // MARK: Scan

    /// Port of `NativeBluetooth.Scan`: listens for 1–30 seconds and returns candidates strongest first.
    @discardableResult
    func scan(seconds: Int) async throws -> [BluetoothEero] {
        if scanning { throw EeroError.operation("A Bluetooth scan is already running.") }
        let manager = try await readyCentral()
        scanning = true
        found = [:]
        defer { if manager.isScanning { manager.stopScan() }; scanning = false }
        manager.scanForPeripherals(withServices: [Self.eeroService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        try? await Task.sleep(nanoseconds: UInt64(BluetoothContracts.scanSeconds(seconds)) * 1_000_000_000)
        manager.stopScan()
        if manager.state != .poweredOn { throw EeroError.operation(BluetoothContracts.scanFailedMessage("Bluetooth became unavailable")) }
        results = BluetoothContracts.ordered(Array(found.values))
        return results
    }

    fileprivate func discovered(_ peripheral: CBPeripheral, _ advertisement: [String: Any], _ rssi: NSNumber) {
        let services = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        if !services.isEmpty && !services.contains(Self.eeroService) { return }
        let name = advertisement[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let key = peripheral.identifier.uuidString
        let signal = rssi.intValue == 127 ? (found[key]?.signal ?? -127) : rssi.intValue
        peripherals[key] = peripheral
        found[key] = BluetoothEero.advertisement(peripheral.identifier, name, signal)
    }

    // MARK: Identity

    /// Port of `NativeBluetooth.ReadInfo`: connects, reads the serial number and firmware revision
    /// characteristics of the setup service, then disconnects. Read-only.
    func readInfo(_ eero: BluetoothEero) async throws -> JSON {
        if reading { throw EeroError.operation("Another Bluetooth read is in progress.") }
        let manager = try await readyCentral()
        let known = manager.retrievePeripherals(withIdentifiers: [eero.id])
        guard let peripheral = peripherals[eero.id.uuidString] ?? known.first else {
            throw EeroError.operation(Self.unreachable)
        }
        reading = true
        active = peripheral
        peripheral.delegate = self
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            if !Task.isCancelled { self?.failPending(EeroError.operation("The eero did not respond over Bluetooth in time. Keep it nearby and try again.")) }
        }
        defer {
            timeout.cancel()
            manager.cancelPeripheralConnection(peripheral)
            active = nil
            reading = false
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectWaiter = c
            manager.connect(peripheral)
        }
        let services = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[CBService], Error>) in
            servicesWaiter = c
            peripheral.discoverServices([Self.eeroService])
        }
        guard let service = services.first(where: { $0.uuid == Self.eeroService }) else {
            throw EeroError.operation(BluetoothContracts.serviceUnavailableMessage)
        }
        let characteristics = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[CBCharacteristic], Error>) in
            characteristicsWaiter = c
            peripheral.discoverCharacteristics([Self.serialCharacteristic, Self.firmwareCharacteristic], for: service)
        }
        let serial = await readString(peripheral, characteristics.first { $0.uuid == Self.serialCharacteristic })
        let firmware = await readString(peripheral, characteristics.first { $0.uuid == Self.firmwareCharacteristic })
        return BluetoothContracts.info(eero, serial: serial, firmware: firmware)
    }

    private func readString(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic?) async -> String {
        guard let characteristic, characteristic.properties.contains(.read) else { return BluetoothContracts.unavailable }
        let data = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            readWaiter = c
            peripheral.readValue(for: characteristic)
        }
        return BluetoothContracts.characteristicString(data)
    }

    private func failPending(_ error: Error) {
        if let c = connectWaiter { connectWaiter = nil; c.resume(throwing: error) }
        if let c = servicesWaiter { servicesWaiter = nil; c.resume(throwing: error) }
        if let c = characteristicsWaiter { characteristicsWaiter = nil; c.resume(throwing: error) }
        if let c = readWaiter { readWaiter = nil; c.resume(returning: nil) }
    }

    fileprivate func connected(_ peripheral: CBPeripheral) {
        guard peripheral == active, let c = connectWaiter else { return }
        connectWaiter = nil; c.resume()
    }
    fileprivate func disconnected(_ peripheral: CBPeripheral) {
        guard peripheral == active else { return }
        failPending(EeroError.operation(Self.unreachable))
    }
    fileprivate func servicesDiscovered(_ peripheral: CBPeripheral, _ error: Error?) {
        guard peripheral == active, let c = servicesWaiter else { return }
        servicesWaiter = nil
        if error != nil { c.resume(throwing: EeroError.operation(BluetoothContracts.serviceUnavailableMessage)) }
        else { c.resume(returning: peripheral.services ?? []) }
    }
    fileprivate func characteristicsDiscovered(_ service: CBService, _ error: Error?) {
        guard let c = characteristicsWaiter else { return }
        characteristicsWaiter = nil
        c.resume(returning: error == nil ? (service.characteristics ?? []) : [])
    }
    fileprivate func valueRead(_ characteristic: CBCharacteristic, _ error: Error?) {
        guard let c = readWaiter else { return }
        readWaiter = nil
        c.resume(returning: error == nil ? characteristic.value : nil)
    }
}

// CoreBluetooth calls these on the main queue (the manager is created with `queue: nil`).
extension BluetoothScanner: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .unknown && central.state != .resetting { resumeStateWaiters() }
            if central.state != .poweredOn { failPending(EeroError.operation(Self.unreachable)) }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { discovered(peripheral, advertisementData, RSSI) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { connected(peripheral) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { disconnected(peripheral) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { disconnected(peripheral) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { servicesDiscovered(peripheral, error) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { characteristicsDiscovered(service, error) }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { valueRead(characteristic, error) }
    }
}
#endif
