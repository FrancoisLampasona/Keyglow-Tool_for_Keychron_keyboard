// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

struct FirstInstallError: LocalizedError, Sendable {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

struct BootstrapCatalog: Codable, Sendable {
    struct Source: Codable, Sendable {
        let name: String
        let length: Int
        let vectorsSHA256: String
        let codeSHA256: String
        func matches(_ flash: Data) -> Bool {
            (32776...131072).contains(length) && flash.count == 262144 &&
            bootstrapHash(Data(flash.prefix(480))) == vectorsSHA256 &&
            bootstrapHash(Data(flash[32768..<length])) == codeSHA256
        }
    }
    let schema: Int
    let target: UInt32
    let loaderSHA256: String
    let packageSHA256: String
    let usbVersion: String
    let sources: [Source]
    func validate(loader: Data, package: Data) throws -> FirmwareUpdateArtifact {
        guard schema == 1, target == FirmwareAuthorization.targetID, !sources.isEmpty,
              !usbVersion.isEmpty, bootstrapHash(loader) == loaderSHA256,
              bootstrapHash(package) == packageSHA256 else { throw FirstInstallError("I file inclusi per la prima installazione non superano la verifica. Reinstalla una copia completa di Keyglow.") }
        return try .parse(package, fileName: "firmware-update.kgfw", isPackage: true)
    }
}

func bootstrapHash(_ data: Data) -> String { firmwareHex(FirmwareDeltaPlan.sha256(data)) }

/// Pure assembly matching firmware/ota/integration/assemble.py. No key creation,
/// Keychain use, device access or public file output occurs here.
enum BootstrapAssembler {
    struct Images: Sendable { let staging: Data; let loader: Data }
    static func make(target: FirmwareUpdateArtifact, loader: Data, source: Data, key: FirmwareOwnerKey,
                     nonce: Data) throws -> Images {
        func word(_ d: Data, _ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(d[p+$1]) << (8*$1) } }
        guard (64...0x3f00).contains(loader.count), (8...98304).contains(source.count) else { throw FirstInstallError("Dimensioni del loader o del firmware originale non valide.") }
        let stack = word(loader, 0), reset = word(loader, 4)
        guard stack >= 0x20000008, stack <= 0x20010000, stack & 7 == 0, reset & 1 == 1,
              reset & ~1 >= 0x08000000, reset & ~1 < 0x08000000 + UInt32(loader.count) else { throw FirstInstallError("Vettori del loader non validi.") }
        let old = try FirmwareAuthorization.InstalledImage(length: UInt32(source.count), sha256: FirmwareDeltaPlan.sha256(source))
        let auth = try FirmwareAuthorization.makePayload(manifest: target.manifest, source: old, reportedCurrentImage: old,
                                                         nonce: nonce, replace: false, ownerKey: key)
        var header = Data(repeating: 0xff, count: 256)
        func put(_ value: UInt32, _ p: Int) { for i in 0..<4 { header[p+i] = UInt8(truncatingIfNeeded: value >> (8*i)) } }
        header.replaceSubrange(0..<8, with: Data("KGOTA002".utf8))
        for (i,v) in [UInt32(2),target.manifest.target,target.manifest.address,target.manifest.length,target.manifest.build,256].enumerated() { put(v,8+i*4) }
        header.replaceSubrange(32..<64, with: auth[16..<48])
        header.replaceSubrange(88..<124, with: auth[48..<84])
        header.replaceSubrange(176..<208, with: auth[84..<116])
        header.replaceSubrange(208..<240, with: auth[117..<149]); header[240] = auth[116]
        put(BluetoothOTAWire.crc32(Array(header[0..<64] + header[88..<124] + header[176..<241])),64)
        put(0xa71a0a7a,68); put(0xfffffffe,72); put(0xfffffffe,76); put(0xffffffff,80)
        for i in 0..<((target.image.count+255)/256) { header[128+i/8] &= ~(UInt8(1) << (i%8)) }
        var stage = header + target.image
        stage.append(Data(repeating: 0xff, count: (4-stage.count%4)%4))
        var personalized = loader + Data(repeating: 0xff, count: 0x3f00-loader.count)
        personalized.append(FirmwareAuthorization.bootstrapKeySlot(ownerKey: key))
        return .init(staging: stage, loader: personalized)
    }
}

struct InstallUSBIdentity: Codable, Equatable, Sendable {
    let location: UInt32
    let serial: String
}

struct FirstInstallJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case profileSaved, prepared, staging, loader, awaitingRestart, restoring, complete }
    var schema = 1
    var id = UUID()
    var date = Date()
    var phase: Phase = .profileSaved
    let location: UInt32
    var dfuSerial: String?
    let snapshot: VIASnapshot
    var sourceName: String?
    var sourceLength: Int?
    var hashes: [String:String] = [:]
    var targetBuild: UInt32?
    var usbVersion: String?
}

/// Durable private journal: write intent is persisted before any destructive
/// phase. Backups are never overwritten during resume. No repository paths.
final class FirstInstallStore {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw FirstInstallError("La cartella privata di recupero non è valida.") }
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: directory.path)
    }
    func write(_ data: Data, name: String) throws {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw FirstInstallError("Nome del file di recupero non valido.") }
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FirstInstallError("Impossibile salvare il backup privato.") }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        let success = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                if n < 0 && errno == EINTR { continue }; if n <= 0 { return false }; offset += n
            }
            return fsync(fd) == 0
        }
        guard success, rename(temporary.path, directory.appendingPathComponent(name).path) == 0 else { throw FirstInstallError("Salvataggio del recupero non completato. Nessuna nuova scrittura autorizzata.") }
        let dir = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard dir >= 0 else { throw FirstInstallError("Cartella di recupero non accessibile.") }
        defer { Darwin.close(dir) }
        guard fsync(dir) == 0 else { throw FirstInstallError("Impossibile confermare il salvataggio del recupero.") }
    }
    func exclusively<T>(_ operation:()->T) throws -> T {
        let fd=Darwin.open(directory.appendingPathComponent("operation.lock").path,O_RDWR | O_CREAT | O_NOFOLLOW,0o600)
        guard fd >= 0 else {throw FirstInstallError("Impossibile riservare la sessione di installazione.")}
        defer {Darwin.close(fd)}
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else {throw FirstInstallError("Un’altra istanza di Keyglow sta usando la sessione. Attendi prima di riprovare.")}
        defer {_ = flock(fd,LOCK_UN)}
        return operation()
    }
    func preserve(_ data:Data,name:String) throws {
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path) {
            guard try read(name) == data else {throw FirstInstallError("Il backup originale esiste già ed è diverso. Non viene sovrascritto: conserva la sessione per il recupero.")}
        } else {try write(data,name:name)}
    }
    func read(_ name: String, expected: String? = nil) throws -> Data {
        guard !name.contains("/"), !name.hasPrefix(".") else { throw FirstInstallError("File di recupero non valido.") }
        let url = directory.appendingPathComponent(name)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw FirstInstallError("Il backup non è un file privato valido.") }
        let data = try FirmwareUpdateFiles.boundedRead(url, maximum: 524288)
        if let expected, bootstrapHash(data) != expected { throw FirstInstallError("Un file di recupero è cambiato. Installazione bloccata; conserva il backup originale.") }
        return data
    }
    func save(_ journal: FirstInstallJournal) throws { try write(JSONEncoder().encode(journal), name:"session.json") }
    func load() throws -> FirstInstallJournal {
        let value = try JSONDecoder().decode(FirstInstallJournal.self, from: read("session.json"))
        guard value.schema == 1, value.location != 0, value.snapshot.productID == 0x0861 else { throw FirstInstallError("Sessione di recupero incompatibile.") }
        return value
    }
}

protocol FirstInstallDFU: AnyObject {
    func identify(location: UInt32, serial: String?) throws -> InstallUSBIdentity
    func read(address: UInt32, length: Int) throws -> Data
    func write(address: UInt32, bytes: Data) throws
}

/// The coordinator cannot erase application or EEPROM sectors. It never changes
/// protection/option bytes and never retries a failed mutation automatically.
final class FirstInstallCoordinator {
    let store: FirstInstallStore
    let dfu: any FirstInstallDFU
    let progress: (String, Double) -> Void
    init(store: FirstInstallStore, dfu: any FirstInstallDFU, progress: @escaping (String,Double)->Void = {_,_ in}) {
        self.store=store; self.dfu=dfu; self.progress=progress
    }
    func prepare(catalog: BootstrapCatalog, loader: Data, package: Data, key: FirmwareOwnerKey) throws -> FirstInstallJournal {
        try FirstInstallStore(directory:store.directory.deletingLastPathComponent()).exclusively {
            Result {try prepareUnlocked(catalog:catalog,loader:loader,package:package,key:key)}
        }.get()
    }
    private func prepareUnlocked(catalog:BootstrapCatalog,loader:Data,package:Data,key:FirmwareOwnerKey)throws->FirstInstallJournal {
        var journal = try store.load()
        guard journal.phase == .profileSaved else { throw FirstInstallError("Questa sessione ha già un backup completo. Riprendi il percorso salvato.") }
        let target = try catalog.validate(loader:loader,package:package)
        let identity = try dfu.identify(location:journal.location,serial:nil)
        progress("Backup completo · prima lettura",0.1)
        let first = try dfu.read(address:0x08000000,length:262144)
        progress("Backup completo · seconda lettura",0.3)
        _ = try dfu.identify(location:journal.location,serial:identity.serial)
        let second = try dfu.read(address:0x08000000,length:262144)
        guard first.count == 262144, first == second else { throw FirstInstallError("Le due letture del controller non coincidono. Nessun firmware scritto: controlla il cavo e ripeti il backup.") }
        // Persist even an unsupported source's original bytes for recovery.
        try store.preserve(first,name:"controller-original.bin")
        guard let source = catalog.sources.first(where:{$0.matches(first)}) else { throw FirstInstallError("Il firmware presente non è tra le versioni originali verificate per questa installazione. Backup conservato; nessuna scrittura. Se Keyglow è già installato, usa Aggiornamenti Bluetooth.") }
        let images = try BootstrapAssembler.make(target:target,loader:loader,source:Data(first[32768..<source.length]),key:key,nonce:FirmwareAuthorization.generateTransactionNonce())
        for (name,data) in [("controller-original.bin",first),("staging.bin",images.staging),("loader-private.bin",images.loader),("target.kgfw",package)] {
            try store.write(data,name:name); journal.hashes[name] = bootstrapHash(data)
        }
        journal.dfuSerial=identity.serial; journal.sourceName=source.name; journal.sourceLength=source.length
        journal.targetBuild=target.manifest.build; journal.usbVersion=catalog.usbVersion; journal.phase = .prepared
        try store.save(journal); progress("Backup verificato · file di installazione pronti",1)
        return journal
    }
    func install(approvedStaging: String, approvedLoader: String) throws -> FirstInstallJournal {
        try FirstInstallStore(directory:store.directory.deletingLastPathComponent()).exclusively {
            Result {try installUnlocked(approvedStaging:approvedStaging,approvedLoader:approvedLoader)}
        }.get()
    }
    private func installUnlocked(approvedStaging:String,approvedLoader:String)throws->FirstInstallJournal {
        var j = try store.load()
        guard [.prepared,.staging,.loader].contains(j.phase), let serial=j.dfuSerial,
              let originalHash=j.hashes["controller-original.bin"],
              j.hashes["staging.bin"] == approvedStaging, j.hashes["loader-private.bin"] == approvedLoader else { throw FirstInstallError("Il riepilogo di installazione è cambiato. Riaprilo prima di confermare.") }
        let original=try store.read("controller-original.bin",expected:originalHash)
        let stage=try store.read("staging.bin",expected:approvedStaging)
        let loader=try store.read("loader-private.bin",expected:approvedLoader)
        guard original.count == 262144, (264...98560).contains(stage.count),loader.count == 0x3f40 else { throw FirstInstallError("File di installazione incompleti.") }
        _ = try dfu.identify(location:j.location,serial:serial)
        progress("Controllo dispositivo e backup prima della scrittura",0.02)
        let current=try dfu.read(address:0x08000000,length:262144)
        guard current.count == original.count, current[0x4000..<0x20000] == original[0x4000..<0x20000],
              j.phase == .loader || current[0..<0x4000] == original[0..<0x4000] else { throw FirstInstallError("Il controller è cambiato dopo il backup. Nessuna nuova scrittura: conserva il cavo collegato e il backup.") }
        if j.phase != .loader {
            j.phase = .staging; try store.save(j)
            progress("Scrivo il firmware nell’area di preparazione",0.15)
            try dfu.write(address:0x08020000,bytes:stage)
        }
        progress("Rileggo e verifico il firmware preparato",0.45)
        guard try dfu.read(address:0x08020000,length:stage.count) == stage else { throw FirstInstallError(j.phase == .loader ? "Verifica dell’immagine non riuscita. Il loader potrebbe essere incompleto: non riavviare e non scollegare la tastiera. Mantieni DFU e conserva la sessione per il recupero." : "Verifica dell’immagine non riuscita. Il loader non è stato scritto. Resta in DFU e riprendi dal riepilogo.") }
        j.phase = .loader; try store.save(j)
        _ = try dfu.identify(location:j.location,serial:serial)
        progress("Installo il loader · non scollegare il cavo",0.65)
        try dfu.write(address:0x08000000,bytes:loader)
        progress("Verifico loader e conservazione delle impostazioni",0.85)
        let after=try dfu.read(address:0x08000000,length:262144)
        guard after.count == 262144, Data(after.prefix(loader.count)) == loader,
              after[loader.count..<0x4000].allSatisfy({$0 == 0xff}),
              after[0x4000..<0x20000] == original[0x4000..<0x20000],
              Data(after[0x20000..<(0x20000+stage.count)]) == stage else { throw FirstInstallError("Verifica finale USB non riuscita. Non riavviare: mantieni DFU e riprendi la stessa installazione.") }
        j.phase = .awaitingRestart; try store.save(j)
        progress("Scrittura verificata · puoi riavviare in Cable",1)
        return j
    }
    static func restoredSettings(saved: VIASnapshot, current: VIASnapshot) throws -> VIASnapshot {
        guard saved.productID == 0x0861, current.productID == saved.productID,
              current.protocolVersion == saved.protocolVersion, current.rows == saved.rows, current.cols == saved.cols,
              current.macroCapacity == saved.macroCapacity, current.macroCount == saved.macroCount,
              saved.customRGB == nil || (current.customRGB?.ledIndices == saved.customRGB?.ledIndices && current.customRGB?.effects.map(\.count) == saved.customRGB?.effects.map(\.count)),
              saved.wireless == nil || current.wireless != nil,
              saved.nkro == nil || current.nkro == saved.nkro || current.nkroCanSet else { throw FirstInstallError("Il nuovo firmware non può ripristinare tutte le impostazioni salvate. Il backup è conservato; nessun ripristino parziale avviato.") }
        var desired=current
        desired.layers=saved.layers;desired.encoders=saved.encoders;desired.macroBuffer=saved.macroBuffer;desired.lighting=saved.lighting
        if let custom=saved.customRGB { desired.customRGB=custom }
        if let wireless=saved.wireless { desired.wireless=wireless }
        if let nkro=saved.nkro { desired.nkro=nkro }
        return desired
    }
}
