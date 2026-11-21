import SwiftUI
import AppKit

struct ProfilesWorkspaceView: View {
    @ObservedObject var model: StudioModel
    @State private var search = ""
    @State private var collection = 0
    private func belongs(_ profile:KeyboardWorkspace) -> Bool {
        if collection == 2 { return profile.deletedAt != nil }
        return profile.deletedAt == nil && profile.isRecoveryCopy == (collection == 1)
    }
    private var visibleProfiles: [KeyboardWorkspace] {
        model.savedProfiles.filter { belongs($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                StudioSurface {
                    StudioAdaptiveStack(breakpoint: 650, spacing: 18) {
                        PanelTitle(title: "La tua configurazione", subtitle: "Tasti, manopola, macro, colori ed energia.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LMenu("Importa / esporta") {
                            LButton("Importa profilo Keyglow") { model.importProfile() }
                            LButton("Esporta profilo Keyglow") { model.exportProfile() }
                            Divider()
                            LButton("Importa mappa Launcher") { model.importLauncher() }
                            LButton("Esporta mappa Launcher") { model.exportLauncher() }
                        }.controlSize(.large).frame(width: 170)
                    }
                    StudioAdaptiveStack(breakpoint: 600, spacing: 12) {
                        LTextField("Nome del profilo", text: $model.workspace.name).textFieldStyle(.plain).padding(12).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius: 7)).frame(maxWidth: .infinity).localizedAccessibilityLabel("Nome del profilo")
                        LButton("Aggiorna profilo") { model.updateSourceProfile() }.buttonStyle(StudioButton()).disabled(model.updatableProfile == nil)
                            .localizedHelp(model.updatableProfile.map { "Sovrascrive “\($0.name)” con la bozza attuale" } ?? "Disponibile dopo aver caricato o salvato un profilo")
                        LButton("Salva una copia") { model.archiveCurrentProfile() }.buttonStyle(StudioButton(primary: true))
                    }
                }
                if !model.profileLoadNotice.isEmpty {
                    LLabel(model.profileLoadNotice, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundColor(Studio.accent).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                }
                StudioAdaptiveStack(breakpoint: 650, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        LText(collection == 0 ? "I tuoi profili" : collection == 1 ? "Copie di recupero" : "Cestino").font(.system(size: 19, weight: .semibold))
                        LText("\(visibleProfiles.count)").font(.system(size: 12)).monospacedDigit().foregroundColor(Studio.muted)
                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(Studio.muted)
                        LTextField("Cerca un profilo", text: $search).textFieldStyle(.plain).localizedAccessibilityLabel("Cerca un profilo")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width:24,height:24) }
                                .buttonStyle(.plain).foregroundColor(Studio.muted).localizedAccessibilityLabel("Cancella ricerca")
                        }
                    }.padding(.horizontal,12).frame(height:40).frame(maxWidth:320).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:7))
                }
                LPicker("Raccolta profili", selection:$collection) {
                    LText("Personali").tag(0)
                    LText("Recupero (\(model.savedProfiles.filter { $0.deletedAt == nil && $0.isRecoveryCopy }.count))").tag(1)
                    LText("Cestino").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth:460)
                LText(collection == 0 ? "Carica un profilo nella bozza, poi applica le modifiche alla tastiera." : collection == 1 ? "Copie create prima di una lettura o sostituzione della bozza, solo se contiene modifiche non salvate. Restano le 20 più recenti; non occupano l’elenco dei tuoi profili." : "I profili rimossi restano qui e possono essere ripristinati.")
                    .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                if collection == 2 && model.trashCount > 0 {
                    LButton("Svuota cestino") { model.emptyTrash() }.buttonStyle(StudioButton())
                }
                if visibleProfiles.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        LText(search.isEmpty ? (collection == 0 ? "La tua prima configurazione, pronta da salvare." : collection == 1 ? "Nessuna copia di recupero." : "Il cestino è vuoto.") : "Nessun risultato per “\(search)”.")
                            .font(.system(size:17,weight:.medium))
                        LText(search.isEmpty ? (collection == 0 ? "Dai un nome alla bozza e scegli Salva una copia." : "Le configurazioni disponibili compariranno qui.") : "Prova un altro nome o cambia raccolta.")
                            .foregroundColor(Studio.muted)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,28)
                }
                LazyVStack(spacing: 0) {
                    ForEach(visibleProfiles) { profile in
                        HStack(spacing: 16) {
                            Image(systemName: "keyboard").font(.system(size: 21, weight: .regular)).foregroundColor(Studio.muted).frame(width:32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: profile.name).font(.system(size: 14, weight: .medium)).lineLimit(2).help(Text(verbatim: profile.name))
                                LText(L10n.date(profile.updatedAt, includeDay: true)).font(.system(size: 12)).monospacedDigit().foregroundColor(Studio.muted)
                            }
                            Spacer()
                            if collection == 2 {
                                LButton("Ripristina") { model.restoreProfile(profile.id) }.buttonStyle(StudioButton())
                            } else {
                            LButton("Carica") { model.loadProfile(profile) }.buttonStyle(StudioButton()).localizedHelp("Carica nella bozza: non modifica la tastiera")
                            Button { model.deleteProfile(profile.id) } label: { Image(systemName: "trash").frame(width:40,height:40).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundColor(Studio.muted).localizedAccessibilityLabel("Sposta nel cestino \(profile.name)")
                            }
                        }.padding(.vertical, 13)
                        Divider()
                    }
                }
                LDisclosureGroup("Recupero e compatibilità") {
                    VStack(alignment: .leading, spacing: 14) {
                        LText("Caricare un profilo aggiorna solo la bozza. Prima di sostituirla, Keyglow conserva una copia di recupero se contiene modifiche non salvate in un profilo. I file Launcher comprendono mappa e manopola; il formato Keyglow conserva anche RGB, macro e impostazioni.").font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3)
                        LButton("Carica valori di fabbrica nella bozza") { model.resetDraft() }.buttonStyle(StudioButton())
                    }.padding(.top, 14)
                }
                if !model.projectMessage.isEmpty { LText(model.projectMessage).font(.system(size: 12)).foregroundColor(Studio.accent) }
            }.studioPage(maxWidth:920)
        }.disabled(model.busy)
    }
}
struct AdvancedWorkspaceView: View {
    @ObservedObject var model: StudioModel
    private var reactive: Bool { model.workspace.advanced.sleepMinutes == EnergyPolicy.reactiveMinutes }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StudioAdaptiveStack(breakpoint:850, spacing:20) {
                    VStack(alignment: .leading, spacing: 12) {
                        LText("Pronta quando torni.").font(.system(size: 29, weight: .semibold)).tracking(-0.6)
                        LText("Scegli quanto tenere attiva la tastiera. Le luci hanno un timer separato: possono spegnersi mentre la connessione resta disponibile.")
                            .font(.system(size: 14)).foregroundColor(Studio.muted).lineSpacing(4).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 7) {
                        LText(model.usbSnapshot?.wireless.map { EnergyPolicy.duration(minutes: Int($0.sleepTimeoutSeconds) / 60) } ?? "—")
                            .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                        LText("Timeout letto via USB").font(.system(size: 11)).foregroundColor(Studio.muted)
                    }.frame(minWidth: 160)
                }
                StudioAdaptiveStack(breakpoint: 900, spacing: 14) {
                    energyPreset(title: "Reattiva", detail: "18 h 12 min", description: "Per lavorare a lungo. Il firmware Keyglow aggiornato mantiene attivo anche il controller quando il Bluetooth è connesso.", minutes: EnergyPolicy.reactiveMinutes, symbol: "bolt.horizontal")
                    energyPreset(title: "Bilanciata", detail: "2 ore", description: "Più spazio al risparmio energetico. Dopo un periodo di inattività, il primo tasto può richiedere la riconnessione.", minutes: EnergyPolicy.balancedMinutes, symbol: "leaf")
                }
                if reactive {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "battery.50percent").font(.system(size: 20)).foregroundColor(Studio.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            LText(model.reactiveFirmwareRecognized ? "Firmware reattivo riconosciuto" : "Modalità reattiva: serve il firmware Keyglow aggiornato").fontWeight(.semibold)
                            LText("Il controller resta attivo solo con Bluetooth connesso e una lettura valida della batteria a livello non basso. Il consumo può aumentare. Il timer radio resta finito; l’avvio e il risveglio del Mac richiedono comunque una connessione.")
                                .font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                        }
                    }.padding(18).background(Studio.accent.opacity(0.065)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                StudioSurface {
                    PanelTitle(title: "Personalizza i tempi", subtitle: "Le modifiche restano nella bozza finché non le applichi via USB.")
                    StudioAdaptiveStack(breakpoint:600,spacing:10) {
                        LLabel("Sospensione radio", systemImage: "moon.zzz").frame(maxWidth:.infinity, alignment: .leading)
                        BoundedIntField(title: "Minuti di sospensione", value: $model.workspace.advanced.sleepMinutes, range: 1...1092).textFieldStyle(.plain).padding(9).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 90)
                        LText("minuti · da 1 a 1092").font(.system(size: 12)).foregroundColor(Studio.muted)
                        Spacer()
                    }
                    StudioAdaptiveStack(breakpoint:600,spacing:10) {
                        LLabel("Spegnimento delle luci", systemImage: "sun.max").frame(maxWidth:.infinity, alignment: .leading)
                        BoundedIntField(title: "Secondi retroilluminazione", value: $model.workspace.advanced.backlightSeconds, range: 5...65535).textFieldStyle(.plain).padding(9).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 90)
                        LText("secondi · da 5 a 65535").font(.system(size: 12)).foregroundColor(Studio.muted)
                        Spacer()
                    }
                    if model.usbSnapshot?.wireless == nil {
                        LText("Collega USB e scegli Leggi tastiera prima di applicare questi valori.").font(.system(size: 12)).foregroundColor(Studio.accent)
                    }
                    if model.energyChangesPending {
                        Divider()
                        LToggle("Il selettore della tastiera è su Cable", isOn: $model.cableModeConfirmed).toggleStyle(.checkbox)
                        LText("Usa Cable durante il salvataggio dei timer. Poi potrai tornare a Bluetooth: i valori restano memorizzati.").font(.system(size: 12)).foregroundColor(Studio.muted)
                    }
                }
                StudioSurface {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            LText("Tasti simultanei").font(.system(size: 17, weight: .semibold))
                            LText("NKRO, quando disponibile nel firmware letto.").font(.system(size: 12)).foregroundColor(Studio.muted)
                        }
                        Spacer()
                        LToggle("Abilita NKRO", isOn: $model.workspace.advanced.nkro).toggleStyle(.switch).disabled(model.usbSnapshot?.nkroCanSet != true)
                    }
                }
                LDisclosureGroup("Capacità e limiti della Q6 Max") {
                    VStack(spacing: 12) {
                        capability("RGB per tasto e Mix", model.usbSnapshot?.customRGB != nil)
                        capability("Timer luce e radio", model.usbSnapshot?.wireless != nil)
                        capability("Modifica NKRO", model.usbSnapshot?.nkroCanSet == true)
                        LText("Debounce e polling non sono configurabili da questa versione. Le funzioni dei modelli HE non si applicano alla Q6 Max.").font(.system(size: 12)).foregroundColor(Studio.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 14)
                }.foregroundColor(Studio.muted)
            }.studioPage(maxWidth:920)
        }.disabled(model.busy)
    }
    private func energyPreset(title: String, detail: String, description: String, minutes: Int, symbol: String) -> some View {
        let selected = model.workspace.advanced.sleepMinutes == minutes
        return Button { model.workspace.advanced.sleepMinutes = minutes; model.projectMessage = "Profilo energia aggiornato nella bozza." } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).font(.system(size: 22)); Spacer(); Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 17)) }.foregroundColor(selected ? Studio.accent : Studio.muted)
                HStack(alignment: .firstTextBaseline) { LText(title).font(.system(size: 21, weight: .semibold)); Spacer(); LText(detail).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundColor(Studio.muted) }
                LText(description).font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                Spacer(minLength: 0)
            }.padding(20).frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
                .background(selected ? Studio.accent.opacity(0.09) : Studio.panel)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? Studio.accent.opacity(0.65) : Studio.line.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain).localizedAccessibilityLabel("\(title), \(detail)").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func capability(_ name: String, _ supported: Bool) -> some View {
        HStack { LText(name); Spacer(); LLabel(supported ? "Rilevato" : "Non letto", systemImage: supported ? "checkmark.circle" : "minus.circle").foregroundColor(supported ? Studio.success : Studio.muted) }
    }
}

struct ConnectionWorkspaceView: View {
    @ObservedObject var model: StudioModel
    @State private var showSetup=false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                StudioAdaptiveStack(breakpoint:650,spacing:18) {
                    HStack(spacing:18) {
                        Image(systemName:"keyboard").font(.system(size:38,weight:.light)).foregroundColor(Studio.accent)
                        VStack(alignment:.leading,spacing:6) {
                            LText("Keychron Q6 Max").font(.system(size:24,weight:.semibold))
                            LText("ISO italiano · Scocca nera · Esc turchese").font(.system(size:12)).foregroundColor(Studio.muted)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Button {model.scan()} label:{LLabel("Rileva dispositivi",systemImage:"arrow.clockwise")}.buttonStyle(StudioButton()).disabled(model.busy)
                }
                StudioSurface {
                    PanelTitle(title:"Bluetooth",subtitle:"Colori, effetti e aggiornamenti senza cavo.")
                    connectionRow("Collegamento", value:model.available ? "Q6 Max rilevata" : "In attesa della Q6 Max", ready:model.available)
                    connectionRow("Accesso macOS", value:model.accessVerified ? "Accesso pronto" : "Da verificare", ready:model.accessVerified)
                    if model.available && model.accessVerified && model.directBluetooth {
                        LButton("Vai all’illuminazione") {model.section = .lighting}.buttonStyle(StudioButton(primary:true))
                    } else if !model.available {
                        LText("Seleziona BT sulla tastiera e collegala nelle impostazioni Bluetooth del Mac, poi scegli Rileva dispositivi.")
                            .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                    } else if !model.accessVerified {
                        LText(model.accessMessage).font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                        HStack(spacing:10) {
                            if model.systemPermission == .granted {
                                LButton("Verifica accesso") {model.checkAccess()}.buttonStyle(StudioButton(primary:true)).disabled(model.busy)
                                LButton("Apri Impostazioni") {model.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")}.buttonStyle(StudioButton())
                            } else {
                                // A recheck in this process cannot see a grant made after launch.
                                LButton("Esci e riapri Keyglow") {model.onRelaunchRequested?()}.buttonStyle(StudioButton(primary:true)).disabled(model.busy)
                                LButton("Apri Impostazioni") {model.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")}.buttonStyle(StudioButton())
                                LButton("Verifica accesso") {model.checkAccess()}.buttonStyle(StudioButton()).disabled(model.busy)
                            }
                        }
                    }
                    LDisclosureGroup("Firmware e compatibilità",isExpanded:$showSetup) {
                        VStack(alignment:.leading,spacing:14) {
                            LToggle("Firmware Keyglow con RGB diretti installato",isOn:$model.directBluetooth).toggleStyle(.checkbox).disabled(model.busy)
                            InstalledFirmwareLine(updater:model.firmwareUpdater)
                            LText("Questa scelta ricorda la configurazione. La verifica della versione installata si trova nella pagina Firmware.")
                                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                            if !model.directBluetooth {
                                LText("Il firmware originale non riceve colori via Bluetooth. Con le prime versioni sperimentali di Keyglow, attiva la ricezione prima di inviare.")
                                    .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                                HStack(spacing:8) {KeycapLabel(text:"fn");LText("+");KeycapLabel(text:"○");LText("Tieni premuto per 2 secondi").font(.system(size:12))}
                                LToggle("Ricezione attivata · invia entro 30 s",isOn:$model.firmwareArmed).toggleStyle(.checkbox).disabled(model.busy)
                                LButton("Apri controlli RGB") {model.section = .lighting}.buttonStyle(StudioButton())
                            }
                            if model.accessVerified {
                                LText(model.accessMessage).font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                                LButton("Ricontrolla accesso") {model.checkAccess()}.buttonStyle(StudioButton()).disabled(model.busy)
                            }
                            LButton("Apri aggiornamento firmware") {model.section = .firmware}.buttonStyle(StudioButton())
                        }.padding(.top,14)
                    }.font(.system(size:13))
                }
                VStack(alignment:.leading,spacing:18) {
                    PanelTitle(title:"Configurazione completa via USB",subtitle:"Mappa dei tasti, macro, RGB per tasto, Mix e timer si salvano con il cavo.")
                    if model.usbDevices.isEmpty {
                        LLabel("Collega USB, seleziona Cable e premi Rileva dispositivi.",systemImage:"cable.connector")
                            .font(.system(size:13)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                    } else {
                        LPicker("Q6 Max USB",selection:$model.selectedUSBID) {
                            LText("Seleziona").tag(Optional<UInt64>.none)
                            ForEach(model.usbDevices) {LText("\($0.name) · USB").tag(Optional($0.id))}
                        }.frame(maxWidth:530)
                        LButton("Leggi configurazione") {model.readUSB()}.buttonStyle(StudioButton(primary:true)).disabled(model.selectedUSBID == nil || model.busy)
                        LText(model.usbMessage).font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                    }
                    LText("Il ricevitore 2,4 GHz non è ancora gestito da Keyglow.").font(.system(size:12)).foregroundColor(Studio.muted)
                }
                AppSettingsPanel(settings:model.settings)
            }.studioPage(maxWidth:920)
        }.onAppear {showSetup = !model.directBluetooth}
            .onChange(of:model.selectedUSBID) {_ in model.usbSnapshot=nil;model.baselineWorkspace=nil;model.cableModeConfirmed=false}
    }
    private func connectionRow(_ title:String,value:String,ready:Bool) -> some View {
        HStack(spacing:16) {
            LText(title).foregroundColor(Studio.muted)
            Spacer(minLength:0)
            LLabel(value,systemImage:ready ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundColor(ready ? Studio.success : Studio.muted)
        }.font(.system(size:13))
    }
}

struct BluetoothSaveChoice: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LToggle("Salva nella tastiera", isOn: $model.saveBluetoothOnKeyboard).toggleStyle(.checkbox)
            LText(model.saveBluetoothOnKeyboard ? "Mantieni gli RGB anche dopo lo spegnimento." : "Prova temporanea, fino al riavvio della tastiera.")
                .font(.system(size: 11)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
        }.disabled(model.lightingControlsDisabled)
    }
}

struct FirmwareWorkspaceView: View {
    @ObservedObject var model: StudioModel
    @StateObject private var bluetooth = BluetoothFirmwareInspector()
    @ObservedObject var updater: FirmwareUpdateModel
    @ObservedObject var installer:FirstInstallModel
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Color.clear.frame(height:0).id("firmware-top")
                InstalledFirmwareCard(updater:updater,usbConnected:model.selectedUSBID != nil,busy:model.busy) { model.checkInstalledFirmware() }
                FirmwareUpdateView(model: updater, showsProvisioning:$model.showFirmwareSetup,installer:installer).disabled(model.busy && !updater.isBusy && !installer.isBusy)
                LDisclosureGroup("Diagnostica e recupero") {
                VStack(alignment:.leading,spacing:24) {
                PanelTitle(title: "Due firmware, una tastiera", subtitle: "Il controller gestisce tasti e luci. Il modulo radio gestisce Bluetooth e riconnessione.")
                StudioSurface {
                    LLabel("Controller Q6 Max ISO", systemImage: "memorychip").font(.system(size: 18, weight: .semibold))
                    info("Versione letta", model.usbSnapshot?.firmwareVersion ?? "Collega USB e leggi la tastiera")
                    info("Protocollo VIA", model.usbSnapshot.map { String($0.protocolVersion) } ?? "—")
                    info("Firmware reattivo", model.reactiveFirmwareRecognized ? "Riconosciuta via USB" : "Non verificata sul dispositivo")
                }
                StudioSurface {
                    HStack {
                        LLabel("Modulo Bluetooth", systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 18, weight: .semibold))
                        Spacer()
                        LButton("Leggi versione radio") { model.readRadioVersion() }.buttonStyle(StudioButton()).disabled(model.selectedUSBID == nil || model.busy)
                    }
                    if let radio = model.radioVersion {
                        info("Modello radio", radio.moduleModel)
                        info("Versione firmware", radio.firmwareVersion)
                        info("Versione hardware", radio.hardwareVersion)
                    }
                    LText(model.radioMessage).font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                    LText("La lettura recupera informazioni: non avvia l’aggiornamento.").font(.system(size: 11)).foregroundColor(Studio.muted)
                }
                StudioSurface {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            LLabel("Verifica senza cavo", systemImage: "wave.3.right").font(.system(size: 18, weight: .semibold))
                            LText("Identità della radio e batteria").font(.system(size: 12)).foregroundColor(Studio.muted)
                        }
                        Spacer()
                        if bluetooth.isRunning {
                            ProgressView().controlSize(.small)
                            LButton("Interrompi") { bluetooth.cancel() }.buttonStyle(StudioButton())
                        } else {
                            LButton("Verifica Bluetooth") { bluetooth.start() }.buttonStyle(StudioButton())
                        }
                    }
                    LText(bluetooth.message).font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                    if bluetooth.permissionDenied {
                        LButton("Apri permessi Bluetooth") { model.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") }.buttonStyle(StudioButton())
                    }
                    if let result = bluetooth.inspection {
                        LLabel("Q6 Max ISO identificata · 3434:0861", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundColor(Studio.success)
                        info("Firmware radio via Bluetooth", result.radioFirmware ?? "Non esposto")
                        info("Batteria letta", result.batteryPercent.map { "\($0)%" } ?? "Non esposta")
                        info("Ultima lettura", L10n.date(result.inspectedAt, includeDay: true))
                        LText(result.vendorServicePresent ? "È presente un servizio proprietario della radio. La sua presenza non conferma un canale di aggiornamento del controller." : "Nessun servizio proprietario riconosciuto in questa lettura.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                        LDisclosureGroup("Servizi e caratteristiche rilevati") {
                            VStack(alignment: .leading, spacing: 12) {
                                LText("Servizi: \(result.serviceIDs.joined(separator: ", "))").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                ForEach(result.characteristics) { characteristic in
                                    VStack(alignment: .leading, spacing: 3) {
                                        LText("\(characteristic.service) / \(characteristic.uuid)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                        LText(characteristic.properties).font(.system(size: 11)).foregroundColor(Studio.muted)
                                    }
                                }
                            }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    LText("La verifica legge solo identità, firmware e batteria. Le caratteristiche proprietarie vengono elencate senza leggerne i valori. Nessuna scrittura o aggiornamento viene avviato.")
                        .font(.system(size: 11)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                }
                StudioSurface {
                    PanelTitle(title: "Backup e recupero", subtitle: "Conserva un profilo prima di modificare il firmware.")
                    HStack {
                        LButton("Esporta profilo") { model.exportProfile() }.buttonStyle(StudioButton())
                        LButton("Identifica file firmware") { model.inspectFirmwareFile() }.buttonStyle(StudioButton())
                    }
                    if !model.firmwareFileDescription.isEmpty { LText(model.firmwareFileDescription).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading) }
                    LText("Il firmware 0.6 richiede USB/DFU. Il nuovo percorso Bluetooth richiede la prima installazione del loader e la chiave proprietario: usa la sezione di aggiornamento qui sopra.").font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                }
                StudioAdaptiveStack(breakpoint:950,spacing:10) {
                    LButton("Launcher Keychron") { model.openURL("https://launcher.keychron.com/") }.buttonStyle(StudioButton())
                    LButton("Note firmware radio") { model.openURL("https://www.keychron.com/pages/keychron-v-max-q-max-k-max-series-bluetooth-firmware") }.buttonStyle(StudioButton())
                    LButton("Design hardware Q6 Max") { model.openURL("https://github.com/Keychron/Keychron-Keyboards-Hardware-Design/tree/main/Q-Max-Series/Q6%20Max") }.buttonStyle(StudioButton())
                }
                LText("I file CAD ufficiali documentano scocca, plate e assemblaggio. Il layout dell’app usa la matrice ISO ufficiale e le legende italiane della tua tastiera.").font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3)
                }.padding(.top,18)
                }.disabled(model.busy || updater.isBusy)
            }.studioPage(maxWidth:920)
        }.onAppear {
            updater.onBusyChanged = { model.busy = $0 }
            // With a cable the read is quiet and conclusive, so it runs by itself.
            // Over Bluetooth it uses the indicator channel and waits for the button.
            if model.selectedUSBID != nil && updater.installed == .unknown { model.checkInstalledFirmware() }
            installer.onBusyChanged = { model.busy = $0; if $0 {model.stopCapture()} }
            installer.onRestored = { snapshot in
                if model.hasLocalChanges {model.archiveRecoveryCopy(suffix:" · prima del ripristino")}
                let restored=model.document(from:snapshot)
                model.replaceLocalDraft(restored);model.sourceProfileID=nil;model.usbSnapshot=snapshot;model.baselineWorkspace=restored
                model.directBluetooth=true
                model.projectMessage="Profilo ripristinato e verificato via USB."
            }
        }
            .onDisappear { bluetooth.cancel(); updater.cancel() }
            .onChange(of:updater.isBusy) { busy in if busy {proxy.scrollTo("firmware-top",anchor:.top)} }
            .onChange(of:installer.isBusy) { busy in if busy {proxy.scrollTo("firmware-top",anchor:.top)} }
            .onChange(of:model.showFirmwareSetup) { _ in proxy.scrollTo("firmware-top",anchor:.top) }
        }
    }
    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { LText(label).foregroundColor(Studio.muted); Spacer(); LText(value).font(.system(size: 12, weight: .medium, design: .monospaced)).multilineTextAlignment(.trailing).fixedSize(horizontal:false,vertical:true).textSelection(.enabled) }
    }
}

/// What firmware is on the keyboard: the current reading, the version last
/// read (always shown, with its date) and the check button. One activity
/// indicator, inside the button; one message per state.
struct InstalledFirmwareCard: View {
    @ObservedObject var updater: FirmwareUpdateModel
    let usbConnected: Bool
    let busy: Bool
    let onCheck: () -> Void
    private var state: InstalledFirmwareCheck { updater.installed }
    var body: some View {
        StudioSurface {
            HStack(alignment:.top,spacing:16) {
                OnboardingIconTile(symbol:"cpu",color:Studio.accent)
                VStack(alignment:.leading,spacing:4) {
                    LText("Firmware installato").font(.system(size:21,weight:.semibold))
                    LLabel(InstalledFirmwareText.title(state),systemImage:InstalledFirmwareText.symbol(state))
                        .font(.system(size:13,weight:.medium)).foregroundColor(color).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                }.frame(maxWidth:.infinity,alignment:.leading)
                // After an unanswered Bluetooth request the button counts down instead of failing.
                TimelineView(.periodic(from:.now,by:1)) { context in
                    let wait=usbConnected ? 0 : updater.bluetoothWait(at:context.date)
                    Button(action:onCheck) {
                        HStack(spacing:8) {
                            if state == .checking { ProgressView().controlSize(.small) } else { Image(systemName:wait > 0 ? "timer" : "checkmark.shield") }
                            if wait > 0 { LText("Riprova tra \(wait) s").monospacedDigit() } else { LText("Controlla firmware") }
                        }
                    }.buttonStyle(StudioButton(primary:!state.foundKeyglow && wait == 0)).disabled(busy || wait > 0)
                        .localizedHelp(wait > 0 ? "Dopo una richiesta Bluetooth senza risposta serve un minuto di attesa. Con il cavo USB puoi controllare subito."
                                       : usbConnected ? "Legge la versione via USB: non modifica nulla" : "Chiede al firmware di rispondere via Bluetooth: dura meno di un minuto, non digitare")
                }
            }
            VStack(alignment:.leading,spacing:12) {
                HStack(alignment:.firstTextBaseline,spacing:18) {
                    LText("Versione").foregroundColor(Studio.muted).frame(width:92,alignment:.leading)
                    VStack(alignment:.leading,spacing:3) {
                        if let record=updater.lastVersion {
                            Text(verbatim:(record.isKeyglow ? "Keyglow · " : "") + record.version).font(.system(size:13,weight:.medium,design:.monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                            LText("Ultima lettura via \(record.via): \(L10n.date(record.date,includeDay:true))").font(.system(size:11)).foregroundColor(Studio.muted)
                        } else {
                            LText("Non ancora letta").font(.system(size:13,weight:.medium))
                        }
                    }
                }.font(.system(size:13))
                if state == .checking, let started=updater.checkStartedAt, updater.checkExpectedSeconds > 3 {
                    // An honest estimate: the exchange has a known length.
                    TimelineView(.periodic(from:.now,by:0.5)) { context in
                        let elapsed=max(0,context.date.timeIntervalSince(started)), expected=updater.checkExpectedSeconds
                        VStack(alignment:.leading,spacing:6) {
                            ProgressView(value:min(elapsed,expected),total:expected).tint(Studio.accent).frame(maxWidth:360)
                            LText(elapsed < expected ? "Circa \(Int((expected-elapsed).rounded(.up))) s" : "Quasi finito…").font(.system(size:11)).monospacedDigit().foregroundColor(Studio.muted)
                        }
                    }
                }
                if let detail=InstalledFirmwareText.detail(state,usbConnected:usbConnected) {
                    LText(detail).font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3)
                        .fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                }
                if !updater.lastCheckDetails.isEmpty && state != .checking {
                    LDisclosureGroup("Dettagli dell’ultimo controllo") {
                        VStack(alignment:.leading,spacing:8) {
                            Text(verbatim:updater.lastCheckDetails).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                            LButton("Copia dettagli") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(updater.lastCheckDetails,forType:.string)
                            }.buttonStyle(StudioButton())
                        }.padding(.top,8)
                    }.font(.system(size:12)).foregroundColor(Studio.muted)
                }
            }.padding(.leading,60)
        }
    }
    private var color: Color {
        switch state {
        case .usbKeyglow, .bluetoothVerified, .bluetoothResponding: Studio.success
        case .usbOther, .bluetoothSilent, .unreadable: Color(hex:0xF1BD79)
        case .unknown, .checking: Studio.muted
        }
    }
}

/// The keyboard at the bottom of the sidebar: a lit status dot, what is
/// connected and how, and the firmware last read. Opens the Connection page.
struct SidebarDeviceStatus: View {
    enum Link: Equatable { case none, bluetoothNeedsAccess, bluetoothReady, usbDetected, usbRead }
    @ObservedObject var updater: FirmwareUpdateModel
    let link: Link
    let onOpen: () -> Void
    static let warning = Color(hex:0xF1BD79)
    private var dot: Color { link == .none ? Studio.muted.opacity(0.55) : link == .bluetoothNeedsAccess || link == .usbDetected ? Self.warning : Studio.success }
    private var status: String {
        switch link {
        case .none: "Non collegata"
        case .bluetoothNeedsAccess: "Bluetooth · accesso da abilitare"
        case .bluetoothReady: "Collegata via Bluetooth"
        case .usbDetected: "USB · configurazione da leggere"
        case .usbRead: "Collegata via USB"
        }
    }
    private var firmware: String {
        if updater.installed == .checking { return "Controllo firmware…" }
        guard let record=updater.lastVersion else { return "Firmware non verificato" }
        return (record.isKeyglow ? "Keyglow · " : "Firmware · ") + record.version
    }
    var body: some View {
        Button(action:onOpen) {
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:8) {
                    Circle().fill(dot).frame(width:9,height:9)
                        .overlay(Circle().stroke(dot.opacity(link == .none ? 0 : 0.3),lineWidth:3).padding(-2.5)).accessibilityHidden(true)
                    LText("Q6 Max · ISO IT").font(.system(size:13,weight:.semibold)).lineLimit(1)
                }
                LText(status).font(.system(size:11,weight:.medium)).foregroundColor(link == .none ? Studio.muted : Studio.text.opacity(0.9))
                    .fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                if record != nil || updater.installed == .checking {
                    Text(verbatim:L10n.string(firmware)).font(.system(size:10)).foregroundColor(Studio.muted).lineLimit(2).fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
                } else {
                    LText(firmware).font(.system(size:10)).foregroundColor(Studio.muted)
                }
            }.padding(.horizontal,10).padding(.vertical,9).frame(maxWidth:.infinity,alignment:.leading)
                .background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .localizedHelp("Apri Connessione")
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(Text(verbatim:"Q6 Max ISO IT, " + L10n.string(status) + ", " + L10n.string(firmware)))
    }
    private var record: FirmwareVersionRecord? { updater.lastVersion }
}

/// One wording of the installed-firmware reading for every place that shows it.
enum InstalledFirmwareText {
    static func title(_ state: InstalledFirmwareCheck) -> String {
        switch state {
        case .unknown: "Non ancora verificato"
        case .checking: "Controllo in corso…"
        case .usbKeyglow(let version): "Firmware Keyglow rilevato via USB · \(version)"
        case .usbOther(let version): "Firmware Keyglow non trovato: via USB risponde \(version)"
        case .bluetoothVerified(let build): "Firmware Keyglow verificato via Bluetooth · build \(build)"
        case .bluetoothResponding: "Firmware Keyglow rilevato via Bluetooth, non autenticato"
        case .bluetoothSilent: "Keyglow non ha risposto via Bluetooth"
        case .unreadable: "Non riesco a leggere la tastiera"
        }
    }
    static func symbol(_ state: InstalledFirmwareCheck) -> String {
        switch state {
        case .usbKeyglow, .bluetoothVerified: "checkmark.seal.fill"
        case .bluetoothResponding: "checkmark.seal"
        case .usbOther, .bluetoothSilent, .unreadable: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        case .checking: "hourglass"
        }
    }
    static func detail(_ state: InstalledFirmwareCheck, usbConnected: Bool = false) -> String? {
        switch state {
        case .unknown: usbConnected ? "Con il cavo collegato il controllo legge la versione via USB e non modifica nulla."
            : "Senza cavo il controllo chiede al firmware di rispondere via Bluetooth e dura meno di un minuto: non digitare finché non termina. La lettura certa è via USB."
        case .checking: usbConnected ? "Lettura della versione via USB." : "Dura meno di un minuto: non digitare e non toccare la manopola finché non termina. Il controllo usa gli indicatori della tastiera."
        case .usbKeyglow: "È la build inclusa in questa app. Colori ed effetti via Bluetooth sono disponibili."
        case .usbOther: "Sulla tastiera c’è un altro firmware, per esempio quello originale. Per gli RGB via Bluetooth usa Prima installazione di Keyglow."
        case .bluetoothVerified: "La risposta è autenticata con la chiave proprietario conservata su questo Mac."
        case .bluetoothResponding: "La tastiera risponde come il loader Keyglow, ma su questo Mac manca la chiave proprietario per autenticarla. Gli RGB funzionano; gli aggiornamenti firmware via Bluetooth richiedono quella chiave."
        case .bluetoothSilent: "Non è una prova che il firmware manchi: in Bluetooth la tastiera può non rispondere anche con Keyglow installato, oppure può avere il firmware originale. Collega il cavo, seleziona Cable e ripeti il controllo: via USB la lettura è certa."
        case .unreadable(let reason): reason
        }
    }
}

/// The same reading, as one line, where the firmware choice is remembered.
struct InstalledFirmwareLine: View {
    @ObservedObject var updater: FirmwareUpdateModel
    var body: some View {
        LLabel(InstalledFirmwareText.title(updater.installed),systemImage:InstalledFirmwareText.symbol(updater.installed))
            .font(.system(size:12,weight:.medium)).foregroundColor(updater.installed.foundKeyglow ? Studio.success : Studio.muted)
            .fixedSize(horizontal:false,vertical:true).frame(maxWidth:640,alignment:.leading)
    }
}
