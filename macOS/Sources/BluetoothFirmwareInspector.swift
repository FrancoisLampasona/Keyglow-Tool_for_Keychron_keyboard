// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Combine
@preconcurrency import CoreBluetooth

struct BluetoothQ6Identity: Equatable, Sendable {
    let vendor: UInt16
    let product: UInt16
    let version: UInt16

    static func parse(_ data: Data) -> Self? {
        let bytes = Array(data)
        guard bytes.count == 7, bytes[0] == 2 else { return nil }
        return Self(vendor: UInt16(bytes[1]) | UInt16(bytes[2]) << 8,
                    product: UInt16(bytes[3]) | UInt16(bytes[4]) << 8,
                    version: UInt16(bytes[5]) | UInt16(bytes[6]) << 8)
    }

    static func text(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 64, let decoded = String(data: data, encoding: .utf8) else { return nil }
        let value = decoded.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return nil }
        return value
    }

    static func matchingName(_ name: String?) -> Bool {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "keychron q6 max"
    }

    func matches(name: String?, model: String?) -> Bool {
        vendor == 0x3434 && product == 0x0861 && Self.matchingName(name) && Self.matchingName(model)
    }

    static func battery(_ data: Data) -> Int? {
        guard data.count == 1, let value = data.first, value <= 100 else { return nil }
        return Int(value)
    }
}

struct BluetoothCharacteristicInfo: Identifiable, Sendable {
    let id: String
    let service: String
    let uuid: String
    let properties: String
}

struct BluetoothFirmwareInspection: Sendable {
    let model: String
    let radioFirmware: String?
    let batteryPercent: Int?
    let inspectedAt: Date
    let serviceIDs: [String]
    let characteristics: [BluetoothCharacteristicInfo]
    let vendorServicePresent: Bool
}

/// The manager is created by an explicit read, or an already-authorized battery refresh.
/// Delegate conformances defer isolation checking because CoreBluetooth's ObjC
/// protocols are not actor annotated; all callbacks are requested on `.main`.
@MainActor
final class BluetoothFirmwareInspector: NSObject, ObservableObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Leggi modello, firmware radio e batteria direttamente via Bluetooth."
    @Published private(set) var inspection: BluetoothFirmwareInspection?
    @Published private(set) var permissionDenied = false

    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var candidates: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]
    private var pendingServices = Set<ObjectIdentifier>()
    private var characteristics: [(service: String, value: CBCharacteristic)] = []
    private var inventory: [BluetoothCharacteristicInfo] = []
    private var reads: [ObjectIdentifier: Reading] = [:]
    private var modelName: String?
    private var pnp: BluetoothQ6Identity?
    private var radioFirmware: String?
    private var batteryPercent: Int?
    private var discoveryBegan = false
    private var readingDetails = false
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var batteryOnly = false
    private let vendorService = "00010203-0405-0607-0809-0A0B0C0D1912"
    private enum Reading { case model, pnp, firmware, battery }

    func start(batteryOnly: Bool = false) {
        guard !isRunning else { return }
        cleanUp()
        self.batteryOnly = batteryOnly
        inspection = nil
        permissionDenied = false
        candidates.removeAll(); names.removeAll(); pendingServices.removeAll()
        characteristics.removeAll(); inventory.removeAll(); reads.removeAll()
        modelName = nil; pnp = nil; radioFirmware = nil; batteryPercent = nil
        discoveryBegan = false; readingDetails = false; generation = UUID()
        isRunning = true
        message = "Preparazione della lettura Bluetooth…"
        setDeadline(seconds: 30) { inspector in
            inspector.finish("Bluetooth non pronto. Controlla il collegamento e riprova.")
        }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func cancel() {
        guard isRunning else { return }
        finish("Verifica interrotta.")
    }

    private func setDeadline(seconds: UInt64, action: @escaping @MainActor (BluetoothFirmwareInspector) -> Void) {
        deadline?.cancel()
        let run = generation
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard let self, self.isRunning, self.generation == run else { return }
            action(self)
        }
    }

    private func cleanUp() {
        deadline?.cancel(); deadline = nil
        central?.stopScan()
        target?.delegate = nil
        if let target { central?.cancelPeripheralConnection(target) }
        central?.delegate = nil
        target = nil; central = nil
        reads.removeAll(); pendingServices.removeAll()
    }

    private func finish(_ text: String) {
        guard isRunning else { return }
        isRunning = false; message = text
        cleanUp()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isRunning, central === self.central else { return }
        switch central.state {
        case .unauthorized:
            permissionDenied = true
            finish("Consenti Bluetooth a Keyglow in Privacy e sicurezza, poi riprova.")
        case .poweredOff: finish("Attiva Bluetooth sul Mac e riprova.")
        case .unsupported: finish("Bluetooth Low Energy non disponibile su questo Mac.")
        case .poweredOn:
            guard !discoveryBegan else { return }
            discoveryBegan = true
            let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812"), CBUUID(string: "180A"), CBUUID(string: "180F")])
            for peripheral in connected where BluetoothQ6Identity.matchingName(peripheral.name) {
                candidates[peripheral.identifier] = peripheral
                names[peripheral.identifier] = peripheral.name
            }
            guard candidates.count <= 1 else { finish("Più Q6 Max collegate: lascia connessa solo quella da verificare."); return }
            if let peripheral = candidates.values.first { connect(peripheral) }
            else if batteryOnly {
                finish("Q6 Max non collegata via Bluetooth. Seleziona BT e attendi la connessione al Mac.")
            } else {
                message = "Cerco la Q6 Max per 8 secondi. La tastiera deve essere in modalità BT."
                central.scanForPeripherals(withServices: [CBUUID(string: "1812")], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                // Collect the entire window; never choose the first of two devices.
                setDeadline(seconds: 8) { inspector in
                    inspector.central?.stopScan()
                    guard inspector.candidates.count == 1, let peripheral = inspector.candidates.values.first else {
                        inspector.finish(inspector.candidates.isEmpty ? "Q6 Max non esposta via Bluetooth. Collegala al Mac e riprova." : "Più Q6 Max rilevate: lascia disponibile solo quella da verificare.")
                        return
                    }
                    inspector.connect(peripheral)
                }
            }
        case .unknown, .resetting: break
        @unknown default: finish("Stato Bluetooth non riconosciuto. Riprova.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isRunning, central === self.central, target == nil else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard BluetoothQ6Identity.matchingName(name) else { return }
        candidates[peripheral.identifier] = peripheral
        names[peripheral.identifier] = name
        if candidates.count > 1 { finish("Più Q6 Max rilevate: lascia disponibile solo quella da verificare.") }
    }

    private func connect(_ peripheral: CBPeripheral) {
        central?.stopScan(); target = peripheral; peripheral.delegate = self
        message = "Verifica dell’identità Q6 Max ISO…"
        setDeadline(seconds: 30) { $0.finish("La lettura è scaduta. Avvicina la tastiera e riprova.") }
        central?.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isRunning, central === self.central, peripheral === target else { return }
        peripheral.discoverServices(batteryOnly ? [CBUUID(string: "180A"), CBUUID(string: "180F")] : nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isRunning, central === self.central, peripheral === target else { return }
        finish("Impossibile aprire la sessione di lettura. Ricollega la Q6 Max e riprova.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isRunning, central === self.central, peripheral === target else { return }
        finish("La tastiera si è scollegata durante la verifica.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isRunning, peripheral === target else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { finish("Nessun servizio Bluetooth leggibile."); return }
        pendingServices = Set(services.map(ObjectIdentifier.init))
        for service in services {
            let ids = service.uuid.uuidString == "180F" ? ["2A19"] : ["2A24", "2A50"]
            peripheral.discoverCharacteristics(batteryOnly ? ids.map { CBUUID(string: $0) } : nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isRunning, peripheral === target, pendingServices.remove(ObjectIdentifier(service)) != nil else { return }
        if error == nil {
            for characteristic in service.characteristics ?? [] {
                characteristics.append((service.uuid.uuidString, characteristic))
                inventory.append(BluetoothCharacteristicInfo(id: "\(inventory.count)", service: service.uuid.uuidString,
                    uuid: characteristic.uuid.uuidString, properties: Self.describe(characteristic.properties)))
            }
        }
        if pendingServices.isEmpty { readIdentity(peripheral) }
    }

    private func uniqueCharacteristic(service: String, uuid: String) -> CBCharacteristic? {
        let matches = characteristics.filter { $0.service == service && $0.value.uuid.uuidString == uuid }
        guard matches.count == 1, let characteristic = matches.first?.value, characteristic.properties.contains(.read) else { return nil }
        return characteristic
    }

    private func readIdentity(_ peripheral: CBPeripheral) {
        guard let model = uniqueCharacteristic(service: "180A", uuid: "2A24"),
              let pnp = uniqueCharacteristic(service: "180A", uuid: "2A50") else {
            finish("Identità incompleta o ambigua: non posso confermare che sia la Q6 Max ISO."); return
        }
        reads[ObjectIdentifier(model)] = .model; reads[ObjectIdentifier(pnp)] = .pnp
        peripheral.readValue(for: model); peripheral.readValue(for: pnp)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning, peripheral === target, let kind = reads.removeValue(forKey: ObjectIdentifier(characteristic)) else { return }
        let value = error == nil ? characteristic.value : nil
        switch kind {
        case .model: modelName = value.flatMap(BluetoothQ6Identity.text)
        case .pnp: pnp = value.flatMap(BluetoothQ6Identity.parse)
        case .firmware: radioFirmware = value.flatMap(BluetoothQ6Identity.text)
        case .battery: batteryPercent = value.flatMap(BluetoothQ6Identity.battery)
        }
        guard reads.isEmpty else { return }
        if !readingDetails {
            guard let pnp, pnp.matches(name: peripheral.name ?? names[peripheral.identifier], model: modelName) else {
                finish("Identità non confermata: modello e PnP devono corrispondere alla Q6 Max ISO."); return
            }
            readingDetails = true
            message = "Q6 Max ISO riconosciuta. Leggo firmware radio e batteria…"
            if !batteryOnly, let firmware = uniqueCharacteristic(service: "180A", uuid: "2A26") { reads[ObjectIdentifier(firmware)] = .firmware }
            if let battery = uniqueCharacteristic(service: "180F", uuid: "2A19") { reads[ObjectIdentifier(battery)] = .battery }
            for (_, item) in characteristics where reads[ObjectIdentifier(item)] != nil { peripheral.readValue(for: item) }
            if !reads.isEmpty { return }
        }
        complete(peripheral)
    }

    private func complete(_ peripheral: CBPeripheral) {
        let services = (peripheral.services ?? []).map { $0.uuid.uuidString }.sorted()
        inspection = BluetoothFirmwareInspection(model: modelName ?? "Keychron Q6 Max", radioFirmware: radioFirmware,
            batteryPercent: batteryPercent, inspectedAt: Date(), serviceIDs: services,
            characteristics: inventory.sorted { ($0.service, $0.uuid) < ($1.service, $1.uuid) },
            vendorServicePresent: services.contains(vendorService))
        finish(batteryOnly ? (batteryPercent == nil ? "La tastiera non ha restituito una percentuale valida." : "Batteria aggiornata.") : "Lettura completata. Il canale di aggiornamento del controller resta da verificare.")
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.read) { names.append("Lettura") }
        if properties.contains(.write) { names.append("Scrittura") }
        if properties.contains(.writeWithoutResponse) { names.append("Scrittura senza risposta") }
        if properties.contains(.notify) { names.append("Notifiche") }
        if properties.contains(.indicate) { names.append("Indicazioni") }
        let description = names.isEmpty ? "Nessuna proprietà nota" : names.joined(separator: " · ")
        return "\(description) · 0x\(String(properties.rawValue, radix: 16))"
    }
}
