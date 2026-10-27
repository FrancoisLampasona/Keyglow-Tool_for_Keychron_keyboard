import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

extension StudioModel {
    var definition: KeyboardDefinition { .q6ISO }
    var currentEffect: RGBEffect { RGBEffect.all.first { $0.id == workspace.lighting.effect } ?? RGBEffect.all[1] }
    var usbReady: Bool { usbSnapshot != nil && selectedUSBID != nil && !busy && !recording && !testing }
    var hasLocalChanges: Bool {
        guard let base = baselineWorkspace else { return true }
        return base.layers != workspace.layers || base.encoders != workspace.encoders || base.macros != workspace.macros || base.lighting != workspace.lighting || base.advanced != workspace.advanced
    }
    var changedKeys: Int {
        let base = baselineWorkspace?.layers ?? definition.defaultLayers
        return zip(base.flatMap { $0 }, workspace.layers.flatMap { $0 }).filter { $0 != $1 }.count
    }
    var selectedKey: PhysicalKey? { selectedKeys.sorted().first.flatMap { definition.key(id:$0) } }
    var visibleKeycodes: [KeycodeInfo] {
        KeycodeCatalog.entries.filter { item in
            let term = keySearch.trimmingCharacters(in: .whitespacesAndNewlines)
            return (term.isEmpty || [item.name, item.shortName, item.category, L10n.string(item.name), L10n.string(item.shortName), L10n.string(item.category), String(format: "0x%04X", item.code)].contains { $0.localizedCaseInsensitiveContains(term) }) && (keyCategory == "Tutti" || item.category == keyCategory)
        }
    }
    var macroBytesUsed: Int {
        (try? VIAMacroCodec.encode(macroActions(), count:max(1, workspace.macros.count), capacity:65535).prefix(while: { _ in true }).count).map { _ in
            workspace.macros.reduce(0) { $0 + 1 + $1.actions.reduce(0) { $0 + ($1.kind == .text ? $1.text.utf8.count : $1.kind == .delay ? String($1.milliseconds).count + 3 : 3) } }
        } ?? 0
    }
    func saveWorkspaceLocally() {
        workspaceTimestamplessSave()
    }
    private func workspaceTimestamplessSave() {
        if let data = try? JSONEncoder().encode(workspace) { UserDefaults.standard.set(data, forKey:"workspace.v3") }
    }
    func restoreWorkspaceLocally() {
        loadingWorkspace = true
        defer { loadingWorkspace = false }
        if let data = UserDefaults.standard.data(forKey:"workspace.v3"), let saved = try? JSONDecoder().decode(KeyboardWorkspace.self,from:data), (try? saved.validate()) != nil { workspace = saved }
        else { workspace.lighting.hue = hue; workspace.lighting.saturation = saturation; workspace.lighting.value = value; workspace.lighting.brightness = brightness }
        if let data = UserDefaults.standard.data(forKey:"profiles.v3"), let saved = try? JSONDecoder().decode([KeyboardWorkspace].self,from:data) { savedProfiles = saved.filter { (try? $0.validate()) != nil } }
        loadLightDraft()
    }
    func syncLightDraft() {
        guard !loadingWorkspace else { return }
        workspace.lighting.hue = hue; workspace.lighting.saturation = saturation; workspace.lighting.value = value; workspace.lighting.brightness = brightness
    }
    func loadLightDraft() {
        let wasLoading = loadingWorkspace; loadingWorkspace = true
        hue = workspace.lighting.hue; saturation = workspace.lighting.saturation; value = workspace.lighting.value; brightness = workspace.lighting.brightness
        lightingTab = workspace.lighting.effect == 23 ? 1 : workspace.lighting.effect == 24 ? 2 : 0
        hexInput = hex; hexError = false; selectedPreset = "Personalizzato"
        loadingWorkspace = wasLoading
    }
    func selectKey(_ key: PhysicalKey) {
        if section == 3 { return }
        if NSEvent.modifierFlags.intersection([.shift,.command]).isEmpty { selectedKeys = [key.id] }
        else if selectedKeys.contains(key.id) { selectedKeys.remove(key.id) } else { selectedKeys.insert(key.id) }
    }
    func assignKeycode(_ code: UInt16) {
        guard !busy, !selectedKeys.isEmpty else { return }
        for id in selectedKeys { if let key = definition.key(id:id) { workspace.layers[selectedLayer][key.matrixIndex] = code } }
        projectMessage = "Assegnazione aggiornata nella bozza."
    }
    func assignRawKeycode() {
        let raw = rawKeycode.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"0x",with:"")
        guard let code = UInt16(raw,radix:16) else { projectMessage = "Inserisci un keycode esadecimale da 0000 a FFFF."; return }
        assignKeycode(code)
    }
    func resetSelectedKeys() {
        for id in selectedKeys { if let key=definition.key(id:id) { workspace.layers[selectedLayer][key.matrixIndex] = definition.defaultLayers[selectedLayer][key.matrixIndex] } }
    }
    func paintSelectedKeys() {
        for id in selectedKeys where definition.key(id:id)?.ledIndex != nil { workspace.lighting.perKey[id] = hex }
    }
    func assignSelectedToMix() {
        guard workspace.lighting.mix.indices.contains(selectedMixLayer) else { return }
        for index in workspace.lighting.mix.indices { workspace.lighting.mix[index].keys.removeAll { selectedKeys.contains($0) } }
        workspace.lighting.mix[selectedMixLayer].keys = selectedKeys.sorted().filter { definition.key(id:$0)?.ledIndex != nil }
    }
    func addMixRegion() {
        guard workspace.lighting.mix.count < (usbSnapshot?.customRGB?.effects.count ?? 16) else { return }
        var region=MixLayerDraft(); region.name="Zona \(workspace.lighting.mix.count + 1)"; region.hex=hex
        region.sequence=[MixEffectDraft(effect:1,hex:hex,speed:128,durationMilliseconds:1000)]
        workspace.lighting.mix.append(region); selectedMixLayer=workspace.lighting.mix.count-1
    }
    func addMacroAction(_ kind: MacroActionKind) {
        guard workspace.macros.indices.contains(selectedMacro), !recording else { return }
        workspace.macros[selectedMacro].actions.append(MacroActionDraft(kind:kind))
    }
    func moveMacroAction(_ index: Int, by delta: Int) {
        let other = index+delta
        guard workspace.macros.indices.contains(selectedMacro), workspace.macros[selectedMacro].actions.indices.contains(other) else { return }
        workspace.macros[selectedMacro].actions.swapAt(index,other)
    }
    func macroActions() throws -> [[VIAMacroAction]] {
        try workspace.macros.map { macro in
            try macro.actions.map { action in
                switch action.kind {
                case .text: return .text(action.text)
                case .delay:
                    guard (0...65535).contains(action.milliseconds) else { throw VIAError.invalid("Attesa macro fuori intervallo.") }
                    return .delay(UInt16(action.milliseconds))
                case .tap,.down,.up:
                    guard action.keycode > 0 && action.keycode <= 255 else { throw VIAError.invalid("Le azioni macro accettano keycode HID da 01 a FF.") }
                    let code=UInt8(action.keycode)
                    return action.kind == .tap ? .tap(code) : action.kind == .down ? .down(code) : .up(code)
                }
            }
        }
    }
    func scanUSB() {
        do {
            usbDevices = try VIAUSBTransport.enumerate().filter { $0.productID == 0x0861 }
            if !usbDevices.contains(where: { $0.id == selectedUSBID }) { selectedUSBID = usbDevices.count == 1 ? usbDevices[0].id : nil; usbSnapshot=nil; baselineWorkspace=nil }
        } catch { usbMessage=error.localizedDescription }
    }
    func readUSB() {
        guard !busy, let id=selectedUSBID else { return }
        stopCapture(); busy=true; usbMessage="Leggo configurazione, macro e capacità del firmware…"
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            let result = Result { try VIAUSBTransport.withSession(deviceID:id) { exchange in try VIAClient(exchange:exchange,productID:0x0861).readSnapshot() } }
            DispatchQueue.main.async { [self] in
                busy=false
                guard selectedUSBID == id else { usbSnapshot=nil;baselineWorkspace=nil;usbMessage="Dispositivo cambiato durante la lettura. Rileggi la tastiera selezionata.";return }
                switch result {
                case .success(let snapshot):
                    // Preserve the local draft before replacing it with actual device data.
                    if hasLocalChanges { archiveCurrentProfile(suffix:" · prima della lettura") }
                    usbSnapshot=snapshot; workspace=document(from:snapshot); baselineWorkspace=workspace; selectedMacro=0;selectedMixLayer=0;selectedKeys=[];loadLightDraft()
                    directBluetooth = FirmwareBuildInfo.bundled?.supportsDirectRGB(snapshot.firmwareVersion) == true
                    usbMessage="Configurazione letta dalla Q6 Max. Le modifiche successive restano locali fino ad Applica."
                    projectMessage=""
                    message="Lettura USB completata."
                case .failure(let error): usbSnapshot=nil; baselineWorkspace=nil; usbMessage=error.localizedDescription; message="Lettura non riuscita. La bozza locale è conservata."
                }
            }
        }
    }
    func document(from snapshot: VIASnapshot, metadata:KeyboardWorkspace?=nil) -> KeyboardWorkspace {
        let source=metadata ?? workspace
        var doc=KeyboardWorkspace(); doc.id=source.id;doc.name=source.name; doc.origin="Letto dalla Q6 Max · firmware \(snapshot.firmwareVersion)"
        doc.layers=snapshot.layers; doc.encoders=snapshot.encoders
        doc.lighting.effect=Int(snapshot.lighting.effect); doc.lighting.hue=Double(snapshot.lighting.hue)/255; doc.lighting.saturation=Double(snapshot.lighting.saturation)/255
        doc.lighting.value=1; doc.lighting.brightness=Double(snapshot.lighting.brightness)/255*100; doc.lighting.speed=Double(snapshot.lighting.speed)
        if let decoded=try? VIAMacroCodec.decode(snapshot.macroBuffer,count:snapshot.macroCount) {
            doc.macros=decoded.enumerated().map { index, actions in MacroDraft(id:index,name:source.macros.indices.contains(index) ? source.macros[index].name : "Macro \(index+1)",actions:actions.map { action in
                switch action {
                case .text(let s): return MacroActionDraft(kind:.text,text:s)
                case .delay(let d): return MacroActionDraft(kind:.delay,milliseconds:Int(d))
                case .tap(let k): return MacroActionDraft(kind:.tap,keycode:UInt16(k))
                case .down(let k): return MacroActionDraft(kind:.down,keycode:UInt16(k))
                case .up(let k): return MacroActionDraft(kind:.up,keycode:UInt16(k))
                }
            }) }
        } else { doc.macros = [MacroDraft(id:0,name:source.macros.first(where: { $0.rawBytes != nil })?.name ?? "Buffer originale non decodificabile",rawBytes:snapshot.macroBuffer)] }
        if let rgb=snapshot.customRGB {
            doc.lighting.perKeyMode=Int(rgb.type); doc.lighting.indicatorsDisabled=Int(rgb.indicatorsDisabledMask); doc.lighting.indicatorHex=hexString(rgb.indicatorColor)
            for key in definition.keys {
                let index=Int(rgb.ledIndices[key.row][key.col])
                if rgb.colors.indices.contains(index) { doc.lighting.perKey[key.id]=hexString(rgb.colors[index]) }
            }
            doc.lighting.mix=rgb.effects.enumerated().map { region, effects in
                var item=MixLayerDraft(); item.name="Zona \(region+1)"
                if source.lighting.mix.indices.contains(region) { item.name=source.lighting.mix[region].name;item.id=source.lighting.mix[region].id }
                item.keys=definition.keys.filter { key in let index=Int(rgb.ledIndices[key.row][key.col]); return rgb.regions.indices.contains(index) && rgb.regions[index] == UInt8(region) }.map(\.id)
                item.sequence=effects.map { MixEffectDraft(effect:Int($0.effect),hex:hexString(VIAHSV(hue:$0.hue,saturation:$0.saturation,value:255)),speed:Int($0.speed),durationMilliseconds:Int($0.durationMilliseconds)) }
                return item
            }
        }
        if let wireless=snapshot.wireless { doc.advanced.backlightSeconds=Int(wireless.backlightTimeoutSeconds); doc.advanced.sleepMinutes=Int(wireless.sleepTimeoutSeconds)/60; doc.advanced.sleepEnabled=true }
        doc.advanced.nkro=snapshot.nkro ?? false
        return doc
    }
    func desiredSnapshot(from baseline: VIASnapshot) throws -> VIASnapshot {
        try workspace.validate()
        if let base=baselineWorkspace {
            if baseline.customRGB == nil && (workspace.lighting.perKey != base.lighting.perKey || workspace.lighting.mix != base.lighting.mix || workspace.lighting.perKeyMode != base.lighting.perKeyMode || workspace.lighting.indicatorsDisabled != base.lighting.indicatorsDisabled || workspace.lighting.indicatorHex != base.lighting.indicatorHex) { throw VIAError.invalid("Il progetto modifica RGB personalizzati non disponibili nel firmware letto. Le modifiche restano locali.") }
            if baseline.wireless == nil && (workspace.advanced.sleepMinutes != base.advanced.sleepMinutes || workspace.advanced.backlightSeconds != base.advanced.backlightSeconds) { throw VIAError.invalid("Il firmware letto non espone i timeout richiesti dal profilo.") }
            if !baseline.nkroCanSet && workspace.advanced.nkro != base.advanced.nkro { throw VIAError.invalid("La modifica NKRO non è disponibile nel firmware letto.") }
            if workspace.advanced.debounce != base.advanced.debounce || workspace.advanced.sleepEnabled != base.advanced.sleepEnabled { throw VIAError.invalid("Il profilo modifica un’impostazione avanzata non gestita da questo backend.") }
        }
        var desired=baseline; desired.layers=workspace.layers; desired.encoders=workspace.encoders
        desired.lighting=VIALighting(brightness:UInt8((brightness/100*value*255).rounded()),effect:UInt8(workspace.lighting.effect),speed:UInt8(workspace.lighting.speed.rounded()),hue:UInt8((hue*255).rounded()),saturation:UInt8((saturation*255).rounded()))
        if workspace.macros.map(\.actions) != baselineWorkspace?.macros.map(\.actions) || workspace.macros.map(\.rawBytes) != baselineWorkspace?.macros.map(\.rawBytes) {
            guard !workspace.macros.contains(where: { $0.rawBytes != nil }) else { throw VIAError.invalid("Il buffer macro originale contiene comandi non decodificabili: puoi esportarlo, ma non modificarlo con questo editor.") }
            desired.macroBuffer = try VIAMacroCodec.encode(macroActions(),count:baseline.macroCount,capacity:baseline.macroCapacity)
        }
        if var custom=desired.customRGB {
            custom.type=UInt8(workspace.lighting.perKeyMode)
            custom.indicatorsDisabledMask=UInt8(workspace.lighting.indicatorsDisabled)
            if workspace.lighting.indicatorHex != baselineWorkspace?.lighting.indicatorHex {
                let color=try hsv(workspace.lighting.indicatorHex)
                guard color.value >= 128 else { throw VIAError.invalid("Il colore degli indicatori deve avere intensità almeno 50%.") }
                custom.indicatorColor=color
            }
            for (id,color) in workspace.lighting.perKey {
                if color != baselineWorkspace?.lighting.perKey[id], let key=definition.key(id:id) { let index=Int(custom.ledIndices[key.row][key.col]); if custom.colors.indices.contains(index) { custom.colors[index]=try hsv(color) } }
            }
            if workspace.lighting.mix != baselineWorkspace?.lighting.mix {
                guard workspace.lighting.mix.count <= custom.effects.count else { throw VIAError.invalid("Il firmware dispone di \(custom.effects.count) zone Mix RGB.") }
                custom.regions=Array(repeating:0,count:custom.regions.count)
                for region in workspace.lighting.mix.count..<custom.effects.count { for slot in custom.effects[region].indices { custom.effects[region][slot].effect=0 } }
                for (region,item) in workspace.lighting.mix.enumerated() {
                    guard item.sequence.count <= custom.effects[region].count else { throw VIAError.invalid("La zona \(region+1) supporta \(custom.effects[region].count) effetti.") }
                    for (slot,step) in item.sequence.enumerated() {
                        guard (0...22).contains(step.effect), (0...255).contains(step.speed), (0...3600000).contains(step.durationMilliseconds) else { throw VIAError.invalid("Effetto Mix RGB non valido.") }
                        if let original=baselineWorkspace?.lighting.mix, original.indices.contains(region), original[region].sequence.indices.contains(slot), step == original[region].sequence[slot] { continue }
                        let color=try hsv(step.hex)
                        custom.effects[region][slot]=VIAMixedEffect(effect:UInt8(step.effect),hue:color.hue,saturation:color.saturation,speed:UInt8(step.speed),durationMilliseconds:UInt32(step.durationMilliseconds))
                    }
                    for slot in item.sequence.count..<custom.effects[region].count { custom.effects[region][slot].effect=0 }
                    for id in item.keys { if let key=definition.key(id:id) { let index=Int(custom.ledIndices[key.row][key.col]); if custom.regions.indices.contains(index) { custom.regions[index]=UInt8(region) } } }
                }
            }
            desired.customRGB=custom
        } else if workspace.lighting.effect >= 23 { throw VIAError.invalid("Il firmware letto non espone RGB per tasto o Mix RGB. Il progetto resta salvato localmente.") }
        if desired.wireless != nil {
            guard (5...65535).contains(workspace.advanced.backlightSeconds), (1...1092).contains(workspace.advanced.sleepMinutes) else { throw VIAError.invalid("Timeout luce:5–65535 secondi. Sospensione:1–1092 minuti.") }
            if workspace.advanced.backlightSeconds != baselineWorkspace?.advanced.backlightSeconds { desired.wireless?.backlightTimeoutSeconds=UInt16(workspace.advanced.backlightSeconds) }
            if workspace.advanced.sleepMinutes != baselineWorkspace?.advanced.sleepMinutes { desired.wireless?.sleepTimeoutSeconds=UInt16(workspace.advanced.sleepMinutes*60) }
        }
        if desired.nkroCanSet { desired.nkro=workspace.advanced.nkro }
        return desired
    }
    func applyUSB() {
        guard usbReady, let id=selectedUSBID, let baseline=usbSnapshot else { return }
        do {
            syncLightDraft(); let desired=try desiredSnapshot(from:baseline); let submittedWorkspace=workspace
            if desired.wireless != baseline.wireless && !cableModeConfirmed {
                throw VIAError.invalid("Per applicare i timeout, sposta il selettore su Cable e confermalo in Energia. Poi riprova Applica.")
            }
            try saveDeviceBackup(baseline)
            busy=true; usbMessage="Applico le sole differenze e verifico la rilettura…"
            DispatchQueue.global(qos:.userInitiated).async { [self] in
                let result=Result { try VIAUSBTransport.withSession(deviceID:id) { exchange in try VIAClient(exchange:exchange,productID:0x0861).applyChanges(baseline:baseline,desired:desired) } }
                DispatchQueue.main.async { [self] in
                    busy=false
                    guard selectedUSBID == id else { usbSnapshot=nil;baselineWorkspace=nil;usbMessage="Dispositivo cambiato durante l’operazione. Rileggi la tastiera prima di continuare.";return }
                    switch result {
                    case .success(let verified):
                        usbSnapshot=verified
                        var confirmed=document(from:verified,metadata:submittedWorkspace);confirmed.origin="Applicato e riletto dalla Q6 Max"
                        baselineWorkspace=confirmed
                        if workspace == submittedWorkspace { workspace=confirmed;loadLightDraft() }
                        usbMessage="Modifiche applicate e confermate dalla rilettura USB."; message=usbMessage; projectMessage=""; cableModeConfirmed=false
                    case .failure(let error): usbSnapshot=nil; usbMessage=error.localizedDescription; message="Rileggi la tastiera prima di riprovare."
                    }
                }
            }
        } catch { usbMessage=error.localizedDescription; message=usbMessage }
    }
    private func saveDeviceBackup(_ snapshot: VIASnapshot) throws {
        let root=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("Tastiera/Backups",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let stamp=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        try JSONEncoder().encode(snapshot).write(to:root.appendingPathComponent("q6-max-\(stamp).json"),options:.atomic)
    }
    func hsv(_ hex:String) throws -> VIAHSV {
        guard KeyboardWorkspace.validHex(hex), let n=UInt32(hex,radix:16) else { throw VIAError.invalid("Colore HEX non valido.") }
        let c=NSColor(srgbRed:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,alpha:1)
        return VIAHSV(hue:UInt8((c.hueComponent*255).rounded()),saturation:UInt8((c.saturationComponent*255).rounded()),value:UInt8((c.brightnessComponent*255).rounded()))
    }
    func hexString(_ hsv:VIAHSV) -> String {
        let h=Double(hsv.hue)/255, s=Double(hsv.saturation)/255, v=Double(hsv.value)/255
        let i=Int(h*6)%6, f=h*6-floor(h*6), p=v*(1-s), q=v*(1-f*s), t=v*(1-(1-f)*s)
        let rgb:[Double]=[[v,t,p],[q,v,p],[p,v,t],[p,q,v],[t,p,v],[v,p,q]][i]
        return rgb.map { String(format:"%02X",Int(($0*255).rounded())) }.joined()
    }
    func archiveCurrentProfile(suffix:String="") {
        var copy=workspace; copy.id=UUID(); copy.recoveryReason=suffix; copy.deletedAt=nil; copy.updatedAt=Date(); savedProfiles.insert(copy,at:0)
        saveProfiles(); projectMessage="Profilo salvato sul Mac."
    }
    func loadProfile(_ profile:KeyboardWorkspace) {
        guard profile.deletedAt == nil else { return }
        stopCapture(); archiveCurrentProfile(suffix:" · recupero")
        replaceLocalDraft(profile)
        selectedKeys=[]; selectedMacro=0; selectedMixLayer=0
        projectMessage="Profilo caricato nella bozza. La tastiera non è stata modificata."
    }
    func deleteProfile(_ id:UUID) {
        guard let index=savedProfiles.firstIndex(where: { $0.id == id }) else { return }
        savedProfiles[index].deletedAt=Date(); saveProfiles()
        projectMessage="Profilo spostato nel cestino. Puoi ripristinarlo dalla scheda Cestino."
    }
    func restoreProfile(_ id:UUID) {
        guard let index=savedProfiles.firstIndex(where: { $0.id == id }) else { return }
        savedProfiles[index].deletedAt=nil; saveProfiles(); projectMessage="Profilo ripristinato."
    }
    // Loading a saved draft is navigation/preparation, never a live RGB edit.
    func replaceLocalDraft(_ draft: KeyboardWorkspace) {
        let previous=loadingWorkspace; loadingWorkspace=true
        workspace=draft; workspace.recoveryReason=""; workspace.deletedAt=nil
        loadLightDraft(); loadingWorkspace=previous
        saveWorkspaceLocally()
    }
    private func saveProfiles() { if let data=try? JSONEncoder().encode(savedProfiles) { UserDefaults.standard.set(data,forKey:"profiles.v3") } }
    func exportProfile() {
        syncLightDraft(); let panel=NSSavePanel(); panel.allowedContentTypes=[.json]; panel.nameFieldStringValue="\(workspace.name).json"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; try encoder.encode(workspace).write(to:url,options:.atomic); projectMessage="Profilo esportato: \(url.lastPathComponent)" } catch { projectMessage=error.localizedDescription }
    }
    func importProfile() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.json]; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0; guard size<=2_000_000 else { throw WorkspaceError.tooLarge }
            let profile=try JSONDecoder().decode(KeyboardWorkspace.self,from:Data(contentsOf:url)); try profile.validate(); loadProfile(profile)
        } catch { projectMessage=error.localizedDescription }
    }
    func resetDraft() { guard !busy else{return};stopCapture();archiveCurrentProfile(suffix:" · prima del ripristino"); replaceLocalDraft(KeyboardWorkspace());selectedMacro=0;selectedMixLayer=0;selectedKeys=[]; projectMessage="Valori di fabbrica caricati nella bozza. Nessuna modifica alla tastiera." }
    func inspectFirmwareFile() {
        let panel=NSOpenPanel(); panel.allowsMultipleSelection=false; panel.message=L10n.string("Seleziona un firmware da identificare. Non verrà eseguito alcun flash.")
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=16_000_000 else { throw WorkspaceError.tooLarge }
            let data=try Data(contentsOf:url); let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            firmwareFileDescription="\(url.lastPathComponent) · \(data.count) byte\nSHA-256: \(digest)\nIl nome e l’hash non provano la compatibilità con questa tastiera."
        } catch { firmwareFileDescription=error.localizedDescription }
    }
    func openURL(_ string:String) { if let url=URL(string:string) { NSWorkspace.shared.open(url) } }
}

extension StudioModel {
    func exportLauncher() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Q6-Max-ISO-Launcher.json"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{try LauncherBackup.encode(layers:workspace.layers,encoders:workspace.encoders).write(to:url,options:.atomic);projectMessage="Mappa esportata nel formato Keychron Launcher."}catch{projectMessage=error.localizedDescription}
    }
    func importLauncher() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<2_000_000 else{throw WorkspaceError.tooLarge};let decoded=try LauncherBackup.decode(Data(contentsOf:url));archiveCurrentProfile(suffix:" · prima di importare");workspace.layers=decoded.layers;if let encoders=decoded.encoders{workspace.encoders=encoders};projectMessage="Mappa Launcher importata nella bozza. Nessuna modifica inviata."}catch{projectMessage=error.localizedDescription}
    }
    func exportMacro() {
        guard workspace.macros.indices.contains(selectedMacro) else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Macro-\(selectedMacro+1).json"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(workspace.macros[selectedMacro]).write(to:url,options:.atomic);projectMessage="Macro Keyglow esportata."}catch{projectMessage=error.localizedDescription}
    }
    func exportLauncherMacros() {
        do {
            let data=try LauncherMacroBackup.encode(macros:workspace.macros)
            let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Q6-Max-macro-Launcher.json"
            guard panel.runModal() == .OK,let url=panel.url else{return}
            try data.write(to:url,options:.atomic);projectMessage="Tutti gli slot macro esportati nel formato Launcher."
        } catch { projectMessage=error.localizedDescription }
    }
    func importLauncherMacros(legacy:Bool=false) {
        guard !busy else{return};stopCapture()
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        panel.message=legacy ? "Importa il vecchio array macro Launcher, privo di checksum. Gli slot presenti sostituiranno quelli della bozza." : "Importa gli slot macro Launcher. Gli slot presenti sostituiranno quelli della bozza; viene conservato un profilo di recupero."
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<2_000_000 else{throw WorkspaceError.tooLarge}
            let data=try Data(contentsOf:url), macros=try legacy ? LauncherMacroBackup.decodeLegacy(data):LauncherMacroBackup.decode(data)
            guard macros.count <= workspace.macros.count else{throw VIAError.invalid("Il file contiene \(macros.count) slot; la bozza dispone di \(workspace.macros.count).")}
            var proposed=workspace
            for macro in macros { proposed.macros[macro.id]=macro }
            try proposed.validate();archiveCurrentProfile(suffix:" · prima delle macro Launcher");workspace=proposed;selectedMacro=0
            projectMessage="\(macros.count) slot Launcher importati nella bozza. Nessuna modifica inviata."
        } catch { projectMessage=error.localizedDescription }
    }
    func importMacro() {
        guard !busy else{return};stopCapture()
        guard workspace.macros.indices.contains(selectedMacro) else{return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false;panel.message=L10n.string("Importa una macro nel formato Keyglow (compatibile con Tastiera).")
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<2_000_000 else{throw WorkspaceError.tooLarge};var macro=try JSONDecoder().decode(MacroDraft.self,from:Data(contentsOf:url));macro.id=selectedMacro;var proposed=workspace;proposed.macros[selectedMacro]=macro;try proposed.validate();workspace=proposed;projectMessage="Macro importata nella bozza."}catch{projectMessage=error.localizedDescription}
    }
    func readHardwareMatrix() {
        guard usbReady,let id=selectedUSBID else{return}
        busy=true;lastTestKey="Lettura matrice hardware…"
        DispatchQueue.global(qos:.userInitiated).async{[self] in
            let result=Result{try VIAUSBTransport.withSession(deviceID:id){exchange in let client=VIAClient(exchange:exchange,productID:0x0861);_ = try client.readSnapshot();return try client.readMatrix()}}
            DispatchQueue.main.async{[self] in
                busy=false
                switch result{case .success(let matrix):pressedKeys=Set(definition.keys.filter{matrix[$0.row][$0.col]}.map(\.id));testedKeys.formUnion(pressedKeys);lastTestKey=pressedKeys.isEmpty ? "Matrice a zero: rilascio o lettura disabilitata dal firmware.":"\(pressedKeys.count) tasti premuti nella matrice hardware"
                case .failure(let error):lastTestKey=error.localizedDescription}
            }
        }
    }
}
