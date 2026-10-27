// SPDX-License-Identifier: GPL-2.0-or-later
// Read-only GATT inventory, restricted to the connected Keychron Q6 Max by name.
// No characteristic writes, notification subscriptions, firmware or pairing changes.
import AppKit
import CoreBluetooth

final class GATTDiscovery: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var window: NSWindow!
    private var text: NSTextView!
    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var pending = Set<String>()
    private var pendingReads = Set<String>()
    private var pendingDescriptors = Set<String>()
    private var pendingDescriptorReads = Set<String>()
    private var readRecords: [[String: Any]] = []
    private var descriptorRecords: [[String: Any]] = []
    private var finished = false
    private var began = false
    private var records: [[String: Any]] = []
    private var messages: [String] = []
    private var deadline: Timer?
    private let targetName = "Keychron Q6 Max"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu(); let item = NSMenuItem(); appMenu.addItem(item)
        let submenu = NSMenu(); item.submenu = submenu
        submenu.addItem(withTitle: "Esci dalla diagnosi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:780,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Keyglow · Diagnosi Bluetooth in sola lettura"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width,.height]; scroll.hasVerticalScroller = true
        text = NSTextView(frame:scroll.bounds);text.isEditable=false;text.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        text.autoresizingMask = [.width];scroll.documentView=text;window.contentView=scroll
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        log("Ricerca servizi della Q6 Max. Nessuna scrittura o aggiornamento firmware.")
        log("Se macOS chiede accesso Bluetooth, conferma per eseguire questa lettura.")
        central = CBCentralManager(delegate:self,queue:nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { stop() }
    private func log(_ line:String) {
        messages.append(line);text.string=messages.joined(separator:"\n")+"\n"
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard !finished else{return}
        log("CoreBluetooth stato: \(central.state.rawValue); autorizzazione: \(CBManager.authorization.rawValue)")
        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .unsupported { finish("access_unavailable") }
            return
        }
        guard !began else{return};began=true
        let connected=central.retrieveConnectedPeripherals(withServices:[CBUUID(string:"1812"),CBUUID(string:"180F"),CBUUID(string:"180A")])
        let matches=connected.filter{$0.name == targetName}
        log("Q6 Max già connesse riconosciute: \(matches.count)")
        guard matches.count <= 1 else{finish("ambiguous_target");return}
        if let one=matches.first { connect(one) }
        else {
            log("Ricerca limitata agli annunci del servizio HID per 15 secondi…")
            central.scanForPeripherals(withServices:[CBUUID(string:"1812")],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
            deadline=Timer.scheduledTimer(withTimeInterval:15,repeats:false){[weak self] _ in self?.finish("target_not_exposed")}
        }
    }
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard !finished,target == nil else{return}
        let name=peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard name == targetName else{return}
        central.stopScan();connect(peripheral)
    }
    private func connect(_ peripheral:CBPeripheral) {
        deadline?.invalidate();target=peripheral;peripheral.delegate=self
        log("Collegamento locale per leggere la struttura GATT della Q6 Max…")
        deadline=Timer.scheduledTimer(withTimeInterval:30,repeats:false){[weak self] _ in self?.finish("discovery_timeout")}
        central.connect(peripheral,options:nil)
    }
    func centralManager(_ central:CBCentralManager,didConnect peripheral:CBPeripheral) {
        guard !finished,peripheral === target else{return}
        log("Connessione stabilita. Lettura elenco servizi…");peripheral.discoverServices(nil)
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect peripheral:CBPeripheral,error:Error?) {
        log("Connessione fallita: \(error?.localizedDescription ?? "errore non specificato")");finish("connect_failed")
    }
    func peripheral(_ peripheral:CBPeripheral,didDiscoverServices error:Error?) {
        guard !finished,peripheral === target else{return}
        if let error {log(error.localizedDescription);finish("services_failed");return}
        let services=peripheral.services ?? []
        log("Servizi esposti: \(services.map{$0.uuid.uuidString}.joined(separator:", "))")
        pending=Set(services.map{$0.uuid.uuidString})
        if services.isEmpty {finish("no_services");return}
        for service in services {peripheral.discoverCharacteristics(nil,for:service)}
    }
    func peripheral(_ peripheral:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard !finished,peripheral === target else{return}
        let chars=(service.characteristics ?? []).map { c -> [String:Any] in
            log("  \(service.uuid.uuidString) / \(c.uuid.uuidString) proprietà 0x\(String(c.properties.rawValue,radix:16))")
            return ["uuid":c.uuid.uuidString,"properties":c.properties.rawValue]
        }
        records.append(["service":service.uuid.uuidString,"primary":service.isPrimary,"characteristics":chars,"error":error?.localizedDescription ?? ""])
        // Limit value reads to model/firmware/vendor capability fields. Never read
        // the serial-number characteristic or subscribe to any input report.
        let allowed = Set(["2A50", "2A24", "2A26", "2A29", "2A19",
            "00010203-0405-0607-0809-0A0B0C0D2B12",
            "00010203-0405-0607-0809-0A0B0C0D2B14",
            "00010203-0405-0607-0809-0A0B0C0D2B15"])
        for characteristic in service.characteristics ?? [] where
            allowed.contains(characteristic.uuid.uuidString) && characteristic.properties.contains(.read) {
            pendingReads.insert(characteristic.uuid.uuidString)
            peripheral.readValue(for: characteristic)
            if characteristic.uuid.uuidString.hasPrefix("00010203-") {
                pendingDescriptors.insert(characteristic.uuid.uuidString)
                peripheral.discoverDescriptors(for: characteristic)
            }
        }
        pending.remove(service.uuid.uuidString)
        finishIfComplete()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !finished, peripheral === target, pendingReads.remove(characteristic.uuid.uuidString) != nil else { return }
        let data = characteristic.value ?? Data()
        let hex = data.prefix(256).map { String(format: "%02x", $0) }.joined()
        log("  Lettura \(characteristic.uuid.uuidString): \(error?.localizedDescription ?? hex)")
        readRecords.append(["uuid": characteristic.uuid.uuidString, "hex": hex,
            "length": data.count, "error": error?.localizedDescription ?? ""])
        finishIfComplete()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard !finished, peripheral === target, pendingDescriptors.remove(characteristic.uuid.uuidString) != nil else { return }
        for descriptor in characteristic.descriptors ?? [] {
            descriptorRecords.append(["characteristic": characteristic.uuid.uuidString, "uuid": descriptor.uuid.uuidString])
            if ["2901", "2902", "2904"].contains(descriptor.uuid.uuidString) {
                pendingDescriptorReads.insert(characteristic.uuid.uuidString + "/" + descriptor.uuid.uuidString)
                peripheral.readValue(for: descriptor)
            }
        }
        if let error { log("Descrittori: \(error.localizedDescription)") }
        finishIfComplete()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard let characteristic = descriptor.characteristic else { return }
        let key = characteristic.uuid.uuidString + "/" + descriptor.uuid.uuidString
        guard !finished, peripheral === target, pendingDescriptorReads.remove(key) != nil else { return }
        let value: String
        if let data = descriptor.value as? Data { value = data.prefix(256).map { String(format: "%02x", $0) }.joined() }
        else { value = String(String(describing: descriptor.value ?? "").prefix(256)) }
        log("  Descrittore \(key): \(error?.localizedDescription ?? value)")
        descriptorRecords.append(["characteristic": characteristic.uuid.uuidString, "uuid": descriptor.uuid.uuidString,
            "value": value, "error": error?.localizedDescription ?? ""])
        finishIfComplete()
    }
    private func finishIfComplete() {
        if pending.isEmpty && pendingReads.isEmpty && pendingDescriptors.isEmpty && pendingDescriptorReads.isEmpty {
            finish("inventory_complete")
        }
    }
    private func stop() {
        deadline?.invalidate();central?.stopScan()
        if let target {central?.cancelPeripheralConnection(target)}
    }
    private func finish(_ status:String) {
        guard !finished else{return};finished=true;stop();log("Esito: \(status)")
        let output:[String:Any]=["diagnostic":"q6-max-gatt-inventory","status":status,"characteristicWrites":0,"inputCapture":false,"services":records,"reads":readRecords,"descriptors":descriptorRecords,"messages":messages]
        if let path=Bundle.main.object(forInfoDictionaryKey:"KeyglowDiagnosticOutput") as? String {
            do { let data=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:path),options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path);log("Risultato salvato. Puoi chiudere la diagnosi.") }
            catch {log("Salvataggio fallito: \(error.localizedDescription)")}
        }
    }
}
let app=NSApplication.shared
let delegate=GATTDiscovery();app.delegate=delegate
app.setActivationPolicy(.regular);app.run()
