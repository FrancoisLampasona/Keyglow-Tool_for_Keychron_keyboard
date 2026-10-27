// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import IOKit

/// Metadata only. Bind the normal HID and ROM DFU device to the same physical
/// USB port; never select a generic STM32 merely because it is the only one.
enum FirstInstallUSB {
    struct Device: Sendable { let vendor:Int; let product:Int; let name:String; let identity:InstallUSBIdentity }
    static func devices() -> [Device] {
        var iterator: io_iterator_t=0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result=[Device]()
        while true {
            let entry=IOIteratorNext(iterator); if entry == 0 { break }; defer { IOObjectRelease(entry) }
            func property(_ name:String)->Any? { IORegistryEntryCreateCFProperty(entry,name as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() }
            guard let vendor=property("idVendor") as? NSNumber, let product=property("idProduct") as? NSNumber,
                  let location=property("locationID") as? NSNumber,location.uint32Value != 0 else { continue }
            result.append(.init(vendor:vendor.intValue,product:product.intValue,name:property("USB Product Name") as? String ?? "",
                                identity:.init(location:location.uint32Value,serial:property("USB Serial Number") as? String ?? "")))
        }
        return result
    }
    static func normal(location:UInt32? = nil) throws -> (InstallUSBIdentity,VIADevice) {
        let all=devices().filter{$0.vendor == 0x3434 && $0.product == 0x0861 && $0.name == "Keychron Q6 Max"}
        // Exactly one normal keyboard, including during restoration, prevents
        // an ambiguous Raw HID session on two identical boards.
        let hid=try VIAUSBTransport.enumerate().filter{$0.productID == 0x0861}
        guard all.count == 1,hid.count == 1,location == nil || all[0].identity.location == location else {
            throw FirstInstallError("Collega una sola Q6 Max ISO via USB, seleziona Cable e mantieni la stessa porta per tutta la procedura. Chiudi Launcher e altri configuratori, poi riprova.")
        }
        return (all[0].identity,hid[0])
    }
}

/// Uses the bundled, signed dfu-util with explicit VID/PID, ROM serial and alt0.
/// No shell, Homebrew, global PATH, mass erase, protection changes or leave flags.
final class BundledDFU: FirstInstallDFU {
    let helper: URL
    let temporary: FirstInstallStore
    private var identity: InstallUSBIdentity?
    init(bundle:Bundle = .main) throws {
        guard let helper=bundle.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/dfu-util"),
              FileManager.default.isExecutableFile(atPath:helper.path) else { throw FirstInstallError("Questa copia di Keyglow non include il componente USB. Installa la versione completa prima di entrare in DFU.") }
        self.helper=helper
        temporary=try FirstInstallStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent("Keyglow-DFU-"+UUID().uuidString))
    }
    deinit { try? FileManager.default.removeItem(at:temporary.directory) }
    private func run(_ args:[String]) throws -> String {
        let process=Process();process.executableURL=helper;process.arguments=args
        // Do not inherit DYLD or libusb debug settings from a development shell.
        process.environment=["PATH":"/usr/bin:/bin", "LC_ALL":"C"]
        let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
        try process.run()
        let timeout=DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+180,execute:timeout)
        defer { timeout.cancel() }
        let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FirstInstallError("Operazione DFU non completata (codice \(process.terminationStatus)). Mantieni il cavo collegato; verifica che DFU sia ancora attivo e riprendi la stessa sessione. Nessun tentativo automatico di scrittura.") }
        return String(decoding:data.prefix(65536),as:UTF8.self)
    }
    func identify(location:UInt32,serial:String?) throws -> InstallUSBIdentity {
        let all=FirstInstallUSB.devices().filter{$0.vendor == 0x0483 && $0.product == 0xdf11}
        guard all.count == 1,let device=all.first,device.identity.location == location,
              !device.identity.serial.isEmpty,device.identity.serial.count <= 64,
              device.identity.serial.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")}),
              serial == nil || serial == device.identity.serial else {
            throw FirstInstallError("DFU della tastiera non rilevato sulla porta salvata. Mantieni la stessa porta USB e scollega altri dispositivi STM32 in DFU; poi riprova con il pulsante del passaggio corrente.")
        }
        let output=try run(["-l","-d",",0483:df11","-S",device.identity.serial,"-a","0"])
        let lines=output.split(separator:"\n").filter{$0.contains("Found DFU:") && $0.contains("alt=0,")}
        guard lines.count == 1,
              lines[0].contains("@Internal Flash  /0x08000000/04*016Kg,01*064Kg,01*128Kg") ||
              (lines.count == 1 && lines[0].contains("@Internal Flash /0x08000000/04*016Kg,01*064Kg,01*128Kg")) else {
            throw FirstInstallError("La geometria DFU non corrisponde al controller STM32F401 da 256 KB verificato. Nessuna scrittura consentita.")
        }
        identity=device.identity;return device.identity
    }
    private func args() throws -> [String] {
        guard let identity else { throw FirstInstallError("Rileva nuovamente DFU prima di continuare.") }
        _ = try identify(location:identity.location,serial:identity.serial)
        return ["-d",",0483:df11","-S",identity.serial,"-a","0"]
    }
    func read(address:UInt32,length:Int) throws -> Data {
        guard address >= 0x08000000,length > 0,length <= 262144,UInt64(address)+UInt64(length) <= 0x08040000 else { throw FirstInstallError("Lettura DFU fuori dai limiti consentiti.") }
        let name=UUID().uuidString+".bin",url=temporary.directory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at:url) }
        _ = try run(try args()+["-s",String(format:"0x%08x:%d",address,length),"-U",url.path])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let data=try temporary.read(name)
        guard data.count == length else { throw FirstInstallError("Backup DFU incompleto. Nessuna nuova scrittura consentita.") }
        return data
    }
    func write(address:UInt32,bytes:Data) throws {
        guard (address == 0x08000000 && bytes.count == 0x3f40) ||
              (address == 0x08020000 && (264...98560).contains(bytes.count)) else { throw FirstInstallError("Scrittura DFU fuori dalle due aree autorizzate.") }
        let name=UUID().uuidString+".bin",url=temporary.directory.appendingPathComponent(name)
        try temporary.write(bytes,name:name);defer { try? FileManager.default.removeItem(at:url) }
        _ = try run(try args()+["-s",String(format:"0x%08x",address),"-D",url.path])
    }
}
