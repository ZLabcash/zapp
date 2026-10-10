import CoreBluetooth
import Foundation

/// The Bluetooth link to the ZFlip app on a Flipper Zero.
///
/// The Flipper exposes its serial GATT service under a ZFlip profile of its own
/// (advertised as "ZFlip <name>"). The first write triggers iOS pairing: the
/// Flipper shows a 6-digit code to type on the iPhone.
@MainActor
final class FlipperLink: NSObject, ObservableObject {
    enum State: Equatable {
        case off
        case idle
        case scanning
        case connecting(String)
        case connected(String)
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    static let serviceUUID = CBUUID(string: "8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000")
    /// Phone -> Flipper (write).
    static let rxUUID = CBUUID(string: "19ed82ae-ed21-4c9d-4145-228e62fe0000")
    /// Flipper -> phone (indications).
    static let txUUID = CBUUID(string: "19ed82ae-ed21-4c9d-4145-228e61fe0000")

    @Published private(set) var state: State = .idle
    @Published private(set) var found: [Found] = []
    /// Set while the Flipper shows a prompt and waits for its user.
    @Published private(set) var awaitingFlipper = false
    /// Called when the Flipper reports the receiving address it shows.
    var onAddress: ((UInt32, String) -> Void)?

    /// Created on the first Connect, so iOS asks for Bluetooth then, not at launch.
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var decoder = FlipperProtocol.Decoder()
    private var waiting: CheckedContinuation<FlipperProtocol.Frame, Error>?
    private var writeDone: CheckedContinuation<Void, Error>?
    private var ready: CheckedContinuation<Void, Error>?
    /// A scan was asked for before Bluetooth was ready: start it once it is.
    private var wantsScan = false
    override init() {
        super.init()
        // Filming the send screen: the Flipper "has the transaction" and waits for OK.
        if Demo.scene == "send-confirm" { awaitingFlipper = true }
    }

    /// A new manager also makes iOS show its "Turn On Bluetooth" alert when it is off.
    @discardableResult
    private func manager(fresh: Bool = false) -> CBCentralManager {
        if let central, !fresh { return central }
        let made = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        central = made
        return made
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    func scan() {
        wantsScan = true
        let central = manager()
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting { state = .off }
            return
        }
        found = []
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    /// Bluetooth ready, or why not: asks for permission the first time; when it is
    /// off, iOS offers to turn it on.
    private func waitPoweredOn() async throws -> CBCentralManager {
        let first = central == nil
        var central = manager()
        for _ in 0..<30 where central.state == .unknown || central.state == .resetting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        switch central.state {
        case .poweredOn:
            return central
        case .unauthorized:
            throw FlipperError.bluetoothDenied
        default:
            if !first { central = manager(fresh: true) }
            throw FlipperError.bluetoothOff
        }
    }

    /// Connects to a scanned Flipper, or to a known one by identifier. Gives up after
    /// `timeout` seconds (ZFlip closed, Flipper out of range) so callers can retry.
    func connect(_ id: UUID, timeout: TimeInterval = 15) async throws {
        let central = try await waitPoweredOn()
        wantsScan = false
        central.stopScan()
        let target = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let target else { throw FlipperError.notConnected }
        peripheral = target
        target.delegate = self
        state = .connecting(target.name ?? "Flipper")
        let timer = Task { @MainActor [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, case .connecting = self.state else { return }
            central.cancelPeripheralConnection(target)
            self.ready?.resume(throwing: FlipperError.timeout)
            self.ready = nil
            self.state = .idle
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ready = c
            central.connect(target)
        }
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(.idle)
    }

    /// Sends a frame and waits for the Flipper's answer (STATUS frames only update
    /// `awaitingFlipper`). `timeout` covers the user deciding on the Flipper.
    func request(_ kind: FlipperProtocol.Kind, _ payload: Data = Data(), timeout: TimeInterval = 300) async throws -> FlipperProtocol.Frame {
        guard let peripheral, let rx else { throw FlipperError.notConnected }
        let frame = FlipperProtocol.encode(kind, payload)
        let chunk = min(peripheral.maximumWriteValueLength(for: .withResponse), 240)
        var offset = 0
        while offset < frame.count {
            let part = frame.subdata(in: offset..<min(offset + chunk, frame.count))
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writeDone = c
                peripheral.writeValue(part, for: rx, type: .withResponse)
            }
            offset += part.count
        }
        let reply = try await withThrowingTaskGroup(of: FlipperProtocol.Frame.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { self.waiting = $0 }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw FlipperError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        awaitingFlipper = false
        if reply.kind == FlipperProtocol.Kind.error.rawValue {
            throw FlipperError.rejected(FlipperProtocol.decodeError(reply.payload))
        }
        return reply
    }

    private func reset(_ next: State) {
        state = next
        rx = nil
        awaitingFlipper = false
        decoder = FlipperProtocol.Decoder()
        let error = FlipperError.notConnected
        waiting?.resume(throwing: error)
        writeDone?.resume(throwing: error)
        ready?.resume(throwing: error)
        waiting = nil
        writeDone = nil
        ready = nil
    }

    private func received(_ data: Data) {
        do {
            for frame in try decoder.push(data) {
                if frame.kind == FlipperProtocol.Kind.status.rawValue {
                    awaitingFlipper = frame.payload.first == FlipperProtocol.Status.awaitingUser.rawValue
                    continue
                }
                // Sent unprompted whenever the user changes address on the Flipper.
                if frame.kind == FlipperProtocol.Kind.address.rawValue {
                    if let (index, text) = FlipperProtocol.decodeAddress(frame.payload) { onAddress?(index, text) }
                    continue
                }
                waiting?.resume(returning: frame)
                waiting = nil
            }
        } catch {
            waiting?.resume(throwing: error)
            waiting = nil
        }
    }
}

extension FlipperLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if state == .off { state = .idle }
                if wantsScan { scan() }
            case .unknown, .resetting:
                break
            default:
                reset(.off)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix("ZFlip") else { return }
        MainActor.assumeIsolated {
            peripherals[peripheral.identifier] = peripheral
            let item = Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let i = found.firstIndex(where: { $0.id == item.id }) {
                found[i] = item
            } else {
                found.append(item)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([FlipperLink.serviceUUID])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { reset(.idle) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { reset(.idle) }
    }
}

extension FlipperLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == FlipperLink.serviceUUID }) else {
            MainActor.assumeIsolated { reset(.idle) }
            return
        }
        peripheral.discoverCharacteristics([FlipperLink.rxUUID, FlipperLink.txUUID], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == FlipperLink.txUUID { peripheral.setNotifyValue(true, for: c) }
                if c.uuid == FlipperLink.rxUUID { rx = c }
            }
            if rx != nil {
                state = .connected(peripheral.name ?? "Flipper")
                ready?.resume()
                ready = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { writeDone?.resume(throwing: error) } else { writeDone?.resume() }
            writeDone = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        MainActor.assumeIsolated { received(value) }
    }
}
