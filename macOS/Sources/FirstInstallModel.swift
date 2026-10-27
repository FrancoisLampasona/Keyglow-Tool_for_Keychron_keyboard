// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AppKit
import Combine

@MainActor final class FirstInstallModel: ObservableObject {
    @Published private(set) var journal: FirstInstallJournal?
    @Published private(set) var directory: URL?
    @Published private(set) var message="Collega la Q6 Max ISO via USB e seleziona Cable. Il primo passaggio legge e salva le impostazioni reali."
    @Published private(set) var isBusy=false
    @Published private(set) var progress:Double=0
    @Published private(set) var failed=false
    @Published private(set) var isPreparingKey=false
    @Published var acceptsKey=false
    @Published var acceptsInstall=false
    var onBusyChanged:(Bool)->Void={_ in}
    var onRestored:(VIASnapshot)->Void={_ in}
    private var sessionReadFailed=false
    private var activity:NSObjectProtocol?
    nonisolated private static var root:URL { FirmwareUpdateFiles.root.appendingPathComponent("FirstInstall",isDirectory:true) }
    init(resumeFromDisk:Bool = true) {
        guard resumeFromDisk else{return}
        do {
            let root=Self.root
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("active.json").path) {
                let index=try FirstInstallStore(directory:root)
                let id=try JSONDecoder().decode(UUID.self,from:index.read("active.json"))
                let directory=root.appendingPathComponent(id.uuidString)
                self.directory=directory; journal=try FirstInstallStore(directory:directory).load()
                message="Sessione salvata recuperata. Riprendi dal passaggio indicato; il backup originale è conservato."
            }
        } catch { sessionReadFailed=true;failed=true;message="La sessione salvata non è leggibile. Apri la cartella di recupero e conserva i file. La procedura resta bloccata finché la sessione non viene recuperata. \(error.localizedDescription)" }
    }
    var readyResources:Bool {
        Bundle.main.url(forResource:"bootstrap-catalog",withExtension:"json") != nil &&
        Bundle.main.url(forResource:"bootstrap-loader",withExtension:"bin") != nil &&
        Bundle.main.url(forResource:"firmware-update",withExtension:"kgfw") != nil &&
        Bundle.main.executableURL.map{FileManager.default.isExecutableFile(atPath:$0.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/dfu-util").path)} == true
    }
    private func begin(_ text:String) {
        isBusy=true;failed=false;message=text;progress=0;onBusyChanged(true)
        activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"Installazione guidata del firmware Keyglow")
    }
    private func end(_ result:Result<FirstInstallJournal,Error>,directory:URL? = nil) {
        isBusy=false;isPreparingKey=false;onBusyChanged(false)
        if let activity {ProcessInfo.processInfo.endActivity(activity)};activity=nil
        switch result {
        case .success(let j):journal=j;if let directory{self.directory=directory};progress=1;failed=false
        case .failure(let error):failed=true;message=error.localizedDescription
            if let directory=self.directory {journal=try? FirstInstallStore(directory:directory).load()}
        }
    }
    func backupProfile() {
        guard !isBusy,readyResources,journal == nil,!failed else{return}
        begin("Leggo due volte la configurazione via USB…")
        Task.detached(priority:.userInitiated) { [self] in
            var folder:URL?
            let result=Result {
                let (identity,hid)=try FirstInstallUSB.normal()
                let snapshot=try VIAUSBTransport.withSession(deviceID:hid.id) { exchange in
                    let client=VIAClient(exchange:exchange,productID:0x0861)
                    let a=try client.readSnapshot(),b=try client.readSnapshot()
                    guard a == b else {throw FirstInstallError("La configurazione è cambiata durante il backup. Lascia la tastiera ferma e riprova.")};return a
                }
                let (again,_)=try FirstInstallUSB.normal(location:identity.location)
                guard again == identity else{throw FirstInstallError("La tastiera è cambiata durante la lettura.")}
                let catalog=try Self.resources().0
                guard snapshot.firmwareVersion != catalog.usbVersion else {throw FirstInstallError("Questa versione di Keyglow è già presente. Usa Aggiornamenti Bluetooth: non serve reinstallare il loader.")}
                let j=FirstInstallJournal(location:identity.location,snapshot:snapshot)
                let directory=Self.root.appendingPathComponent(j.id.uuidString);folder=directory
                let store=try FirstInstallStore(directory:directory)
                try store.write(JSONEncoder().encode(snapshot),name:"profile-original.json");try store.save(j)
                try FirstInstallStore(directory:Self.root).write(JSONEncoder().encode(j.id),name:"active.json")
                return j
            }
            await self.profileFinished(result,folder:folder)
        }
    }
    private func profileFinished(_ result:Result<FirstInstallJournal,Error>,folder:URL?) {
        end(result,directory:folder)
        if case .success=result {message="Impostazioni lette due volte e salvate. Autorizza la chiave mentre la tastiera può ancora scrivere."}
    }
    nonisolated private static func resources() throws -> (BootstrapCatalog,Data,Data) {
        guard let catalog=Bundle.main.url(forResource:"bootstrap-catalog",withExtension:"json"),
              let loader=Bundle.main.url(forResource:"bootstrap-loader",withExtension:"bin"),
              let package=Bundle.main.url(forResource:"firmware-update",withExtension:"kgfw") else {throw FirstInstallError("Pacchetto di prima installazione assente da questa copia di Keyglow.")}
        return (try JSONDecoder().decode(BootstrapCatalog.self,from:FirmwareUpdateFiles.boundedRead(catalog,maximum:32768)),
                try FirmwareUpdateFiles.boundedRead(loader,maximum:0x3f00),try FirmwareUpdateFiles.boundedRead(package,maximum:98364))
    }
    var ownerKeyReady:Bool {journal?.hashes["owner-keyslot.bin"] != nil}
    var recoveryDirectory:URL? {directory ?? (sessionReadFailed ? Self.root:nil)}
    func prepareOwnerKey() {
        guard !isBusy,acceptsKey,journal?.phase == .profileSaved,!ownerKeyReady,let directory else{return}
        begin("Autorizza la chiave nella finestra macOS. Puoi usare la tastiera per la password.")
        isPreparingKey=true
        Task.detached(priority:.userInitiated) { [self] in
            let result=Result {
                try FirstInstallStore(directory:Self.root).exclusively {
                    Result {
                        let store=try FirstInstallStore(directory:directory);var saved=try store.load()
                        guard saved.phase == .profileSaved else {throw FirstInstallError("La sessione è cambiata. Riapri la procedura salvata.")}
                        _ = try FirstInstallUSB.normal(location:saved.location)
                        let provision=try FirmwareUpdateFiles.provisionOwnerKey()
                        let slot=try FirmwareUpdateFiles.boundedRead(provision.slotURL,maximum:64)
                        _ = try FirmwareAuthorization.parseKeySlot(slot)
                        try store.preserve(slot,name:"owner-keyslot.bin")
                        saved.hashes["owner-keyslot.bin"]=bootstrapHash(slot);try store.save(saved)
                        return saved
                    }
                }.get()
            }
            await self.ownerKeyFinished(result)
        }
    }
    private func ownerKeyFinished(_ result:Result<FirstInstallJournal,Error>) {
        end(result)
        if case .success=result {message="Chiave pronta e salvata nella cartella privata. Ora puoi entrare in DFU: non servirà digitare una password durante l’installazione."}
    }
    func prepareDFU() {
        guard !isBusy,ownerKeyReady,journal?.phase == .profileSaved,let directory else{return}
        acceptsInstall=false;begin("Rilevo DFU sulla stessa porta USB…")
        Task.detached(priority:.userInitiated) { [self] in
            let result=Result {
                let (catalog,loader,package)=try Self.resources()
                _ = try catalog.validate(loader:loader,package:package)
                let store=try FirstInstallStore(directory:directory),dfu=try BundledDFU()
                let j=try store.load()
                guard let hash=j.hashes["owner-keyslot.bin"] else {throw FirstInstallError("Prepara la chiave in modalità Cable prima di entrare in DFU.")}
                let slot=try store.read("owner-keyslot.bin",expected:hash)
                let key=try FirmwareAuthorization.parseKeySlot(slot)
                return try FirstInstallCoordinator(store:store,dfu:dfu,progress:{text,value in
                    Task{@MainActor in guard self.isBusy else{return};self.message=text;self.progress=value}
                }).prepare(catalog:catalog,loader:loader,package:package,key:key)
            }
            await self.prepared(result)
        }
    }
    private func prepared(_ result:Result<FirstInstallJournal,Error>) {
        end(result);if case .success=result {message="Backup completo verificato con due letture. Controlla il riepilogo e conferma l’installazione."}
    }
    func install() {
        guard !isBusy,acceptsInstall,let directory,let j=journal,
              [.prepared,.staging,.loader].contains(j.phase),let stage=j.hashes["staging.bin"],let loader=j.hashes["loader-private.bin"] else{return}
        acceptsInstall=false;begin("Verifico il backup e i file approvati…")
        Task.detached(priority:.userInitiated) { [self] in
            let result=Result {
                try FirstInstallCoordinator(store:FirstInstallStore(directory:directory),dfu:BundledDFU(),progress:{text,value in
                    Task{@MainActor in guard self.isBusy else{return};self.message=text;self.progress=value}
                }).install(approvedStaging:stage,approvedLoader:loader)
            }
            await self.installed(result)
        }
    }
    private func installed(_ result:Result<FirstInstallJournal,Error>) {
        end(result);if case .success=result {message="Firmware e loader riletti e verificati. Scollega e ricollega USB senza tenere premuto alcun tasto, lasciando Cable."}
    }
    func restore() {
        guard !isBusy,let directory,let j=journal,[.awaitingRestart,.restoring].contains(j.phase) else{return}
        begin("Attendo la Q6 Max in Cable e verifico la versione installata…")
        Task.detached(priority:.userInitiated) { [self] in
            var restored:VIASnapshot?
            let result=Result {
                try FirstInstallStore(directory:Self.root).exclusively { Result {
                let store=try FirstInstallStore(directory:directory);var saved=try store.load()
                let (_,hid)=try FirstInstallUSB.normal(location:saved.location)
                let original=try JSONDecoder().decode(VIASnapshot.self,from:store.read("profile-original.json"))
                guard original == saved.snapshot else {throw FirstInstallError("Il profilo originale non coincide con la sessione salvata.")}
                let verified=try VIAUSBTransport.withSession(deviceID:hid.id) { exchange in
                    let client=VIAClient(exchange:exchange,productID:0x0861),current=try client.readSnapshot()
                    guard current.firmwareVersion == saved.usbVersion else {throw FirstInstallError("Il firmware atteso non è ancora avviato. Mantieni Cable, ricollega USB senza Esc e riprova. Il backup resta conservato.")}
                    let desired=try FirstInstallCoordinator.restoredSettings(saved:original,current:current)
                    saved.phase = .restoring;try store.save(saved)
                    return try client.applyChanges(baseline:current,desired:desired,allowOpaqueMacroRestore:true)
                }
                restored=verified;try store.write(JSONEncoder().encode(verified),name:"profile-restored.json")
                saved.phase = .complete;try store.save(saved);return saved
                }}.get()
            }
            await self.restored(result,snapshot:restored)
        }
    }
    private func restored(_ result:Result<FirstInstallJournal,Error>,snapshot:VIASnapshot?) {
        end(result)
        if case .success=result,let snapshot {message="Installazione completata: versione firmware e impostazioni ripristinate verificate via USB. Ora puoi scollegare il cavo e selezionare BT.";onRestored(snapshot)}
    }
    var canRetryBackup:Bool {failed && journal == nil && !sessionReadFailed}
    func retryProfileBackup() {guard canRetryBackup else{return};clearReadError();backupProfile()}
    private func clearReadError() {guard journal == nil,!isBusy,!sessionReadFailed else{return};failed=false;message="Riprova con una sola Q6 Max ISO collegata in Cable."}
    func revealBackup() {if let recoveryDirectory{NSWorkspace.shared.activateFileViewerSelecting([recoveryDirectory])}}
}

#if KEYGLOW_UI_PREVIEW
extension FirstInstallModel {
    convenience init(previewJournal:FirstInstallJournal?,busy:Bool=false,error:Bool=false,unreadable:Bool=false) {
        self.init(resumeFromDisk:false)
        journal=previewJournal;isBusy=busy;failed=error || unreadable;progress=0.65;sessionReadFailed=unreadable
        message=unreadable ? "La sessione salvata non è leggibile. Apri la cartella di recupero e conserva i file. La procedura resta bloccata finché la sessione non viene recuperata." : previewJournal?.phase == .loader && error ? "Verifica dell’immagine non riuscita. Il loader potrebbe essere incompleto: non riavviare e non scollegare la tastiera. Mantieni DFU e conserva la sessione per il recupero." : busy ? "Installo il loader · non scollegare il cavo" : error ? "Verifica dell’immagine non riuscita. Il loader non è stato scritto. Resta in DFU e riprendi dal riepilogo." : "Anteprima di test · nessun dispositivo o Portachiavi viene utilizzato."
    }
}
#endif
