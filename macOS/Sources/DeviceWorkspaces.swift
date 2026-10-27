import SwiftUI

struct ProfilesWorkspaceView: View {
    @ObservedObject var model: StudioModel
    @State private var search = ""
    private var visibleProfiles: [KeyboardWorkspace] {
        model.savedProfiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                StudioSurface {
                    StudioAdaptiveStack(breakpoint: 900, spacing: 18) {
                        PanelTitle(title: "La tua configurazione", subtitle: "Tasti, manopola, macro, colori ed energia.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Menu("Importa / esporta") {
                            Button("Importa profilo Keyglow") { model.importProfile() }
                            Button("Esporta profilo Keyglow") { model.exportProfile() }
                            Divider()
                            Button("Importa mappa Launcher") { model.importLauncher() }
                            Button("Esporta mappa Launcher") { model.exportLauncher() }
                        }.controlSize(.large).frame(width: 170)
                    }
                    StudioAdaptiveStack(breakpoint: 780, spacing: 12) {
                        TextField("Nome del profilo", text: $model.workspace.name).textFieldStyle(.plain).padding(12).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius: 7)).frame(maxWidth: .infinity).accessibilityLabel("Nome del profilo")
                        Button("Salva una copia") { model.archiveCurrentProfile() }.buttonStyle(StudioButton(primary: true))
                    }
                }
                StudioAdaptiveStack(breakpoint: 840, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Profili salvati").font(.system(size: 19, weight: .semibold))
                        Text("\(model.savedProfiles.count)").font(.system(size: 12)).monospacedDigit().foregroundColor(Studio.muted)
                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(Studio.muted)
                        TextField("Cerca un profilo", text: $search).textFieldStyle(.plain).accessibilityLabel("Cerca un profilo")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width:24,height:24) }
                                .buttonStyle(.plain).foregroundColor(Studio.muted).accessibilityLabel("Cancella ricerca")
                        }
                    }.padding(.horizontal,12).frame(height:40).frame(maxWidth:320).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:7))
                }
                if visibleProfiles.isEmpty {
                    Text(model.savedProfiles.isEmpty ? "Salva una copia per conservare la tua prima configurazione." : "Nessun profilo corrisponde alla ricerca.").foregroundColor(Studio.muted).padding(.vertical, 20)
                }
                LazyVStack(spacing: 0) {
                    ForEach(visibleProfiles) { profile in
                        HStack(spacing: 16) {
                            Image(systemName: "keyboard").font(.system(size: 21, weight: .regular)).foregroundColor(Studio.muted).frame(width:32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(profile.name).font(.system(size: 14, weight: .medium)).lineLimit(2).help(profile.name)
                                Text(profile.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).monospacedDigit().foregroundColor(Studio.muted)
                            }
                            Spacer()
                            Button("Carica") { model.loadProfile(profile) }.buttonStyle(StudioButton()).help("Carica nella bozza: non modifica la tastiera")
                            Button { model.deleteProfile(profile.id) } label: { Image(systemName: "trash").frame(width:40,height:40).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundColor(Studio.muted).accessibilityLabel("Rimuovi profilo \(profile.name)")
                        }.padding(.vertical, 13)
                        Divider()
                    }
                }
                DisclosureGroup("Recupero e compatibilità") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Caricare un profilo aggiorna solo la bozza. Prima di sostituirla, Keyglow conserva una copia di recupero. I file Launcher comprendono mappa e manopola; il formato Keyglow conserva anche RGB, macro e impostazioni.").font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3)
                        Button("Carica valori di fabbrica nella bozza") { model.resetDraft() }.buttonStyle(StudioButton())
                    }.padding(.top, 14)
                }
                if !model.projectMessage.isEmpty { Text(model.projectMessage).font(.system(size: 12)).foregroundColor(Studio.accent) }
            }.studioPage()
        }.disabled(model.busy)
    }
}
struct AdvancedWorkspaceView: View {
    @ObservedObject var model: StudioModel
    private var reactive: Bool { model.workspace.advanced.sleepMinutes == EnergyPolicy.reactiveMinutes }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pronta quando torni.").font(.system(size: 29, weight: .semibold)).tracking(-0.6)
                        Text("Scegli quanto tenere attiva la tastiera. Le luci hanno un timer separato: possono spegnersi mentre la connessione resta disponibile.")
                            .font(.system(size: 14)).foregroundColor(Studio.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 7) {
                        Text(model.usbSnapshot?.wireless.map { EnergyPolicy.duration(minutes: Int($0.sleepTimeoutSeconds) / 60) } ?? "—")
                            .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("Timeout letto via USB").font(.system(size: 11)).foregroundColor(Studio.muted)
                    }.frame(minWidth: 160)
                }
                StudioAdaptiveStack(breakpoint: 900, spacing: 14) {
                    energyPreset(title: "Reattiva", detail: "18 h 12 min", description: "Per lavorare a lungo. Il firmware Tastiera aggiornato mantiene attivo anche il controller quando il Bluetooth è connesso.", minutes: EnergyPolicy.reactiveMinutes, symbol: "bolt.horizontal")
                    energyPreset(title: "Bilanciata", detail: "2 ore", description: "Più spazio al risparmio energetico. Dopo un periodo di inattività, il primo tasto può richiedere la riconnessione.", minutes: EnergyPolicy.balancedMinutes, symbol: "leaf")
                }
                if reactive {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "battery.50percent").font(.system(size: 20)).foregroundColor(Studio.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.reactiveFirmwareRecognized ? "Firmware reattivo riconosciuto" : "Modalità reattiva: serve il firmware Tastiera aggiornato").fontWeight(.semibold)
                            Text("Il controller resta attivo solo con Bluetooth connesso e una lettura valida della batteria a livello non basso. Il consumo può aumentare. Il timer radio resta finito; l’avvio e il risveglio del Mac richiedono comunque una connessione.")
                                .font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(18).background(Studio.accent.opacity(0.065)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                StudioSurface {
                    PanelTitle(title: "Personalizza i tempi", subtitle: "Le modifiche restano nella bozza finché non le applichi via USB.")
                    HStack {
                        Label("Sospensione radio", systemImage: "moon.zzz").frame(width: 240, alignment: .leading)
                        TextField("Minuti di sospensione", value: $model.workspace.advanced.sleepMinutes, format: .number).textFieldStyle(.plain).padding(9).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 90)
                        Text("minuti · da 1 a 1092").font(.system(size: 12)).foregroundColor(Studio.muted)
                        Spacer()
                    }
                    HStack {
                        Label("Spegnimento delle luci", systemImage: "sun.max").frame(width: 240, alignment: .leading)
                        TextField("Secondi retroilluminazione", value: $model.workspace.advanced.backlightSeconds, format: .number).textFieldStyle(.plain).padding(9).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 90)
                        Text("secondi · da 5 a 65535").font(.system(size: 12)).foregroundColor(Studio.muted)
                        Spacer()
                    }
                    if model.usbSnapshot?.wireless == nil {
                        Text("Collega USB e scegli Leggi tastiera prima di applicare questi valori.").font(.system(size: 12)).foregroundColor(Studio.accent)
                    }
                    if model.energyChangesPending {
                        Divider()
                        Toggle("Il selettore della tastiera è su Cable", isOn: $model.cableModeConfirmed).toggleStyle(.checkbox)
                        Text("Usa Cable durante il salvataggio dei timer. Poi potrai tornare a Bluetooth: i valori restano memorizzati.").font(.system(size: 12)).foregroundColor(Studio.muted)
                    }
                }
                StudioSurface {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Tasti simultanei").font(.system(size: 17, weight: .semibold))
                            Text("NKRO, quando disponibile nel firmware letto.").font(.system(size: 12)).foregroundColor(Studio.muted)
                        }
                        Spacer()
                        Toggle("Abilita NKRO", isOn: $model.workspace.advanced.nkro).toggleStyle(.switch).disabled(model.usbSnapshot?.nkroCanSet != true)
                    }
                }
                DisclosureGroup("Capacità e limiti della Q6 Max") {
                    VStack(spacing: 12) {
                        capability("RGB per tasto e Mix", model.usbSnapshot?.customRGB != nil)
                        capability("Timer luce e radio", model.usbSnapshot?.wireless != nil)
                        capability("Modifica NKRO", model.usbSnapshot?.nkroCanSet == true)
                        Text("Debounce e polling non sono configurabili da questa versione. Le funzioni dei modelli HE non si applicano alla Q6 Max.").font(.system(size: 12)).foregroundColor(Studio.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 14)
                }.foregroundColor(Studio.muted)
            }.studioPage()
        }.disabled(model.busy)
    }
    private func energyPreset(title: String, detail: String, description: String, minutes: Int, symbol: String) -> some View {
        let selected = model.workspace.advanced.sleepMinutes == minutes
        return Button { model.workspace.advanced.sleepMinutes = minutes; model.projectMessage = "Profilo energia aggiornato nella bozza." } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).font(.system(size: 22)); Spacer(); Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 17)) }.foregroundColor(selected ? Studio.accent : Studio.muted)
                HStack(alignment: .firstTextBaseline) { Text(title).font(.system(size: 21, weight: .semibold)); Spacer(); Text(detail).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundColor(Studio.muted) }
                Text(description).font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(20).frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
                .background(selected ? Studio.accent.opacity(0.09) : Studio.panel)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? Studio.accent.opacity(0.65) : Studio.line.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(detail)").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func capability(_ name: String, _ supported: Bool) -> some View {
        HStack { Text(name); Spacer(); Label(supported ? "Rilevato" : "Non letto", systemImage: supported ? "checkmark.circle" : "minus.circle").foregroundColor(supported ? Studio.success : Studio.muted) }
    }
}

struct ConnectionWorkspaceView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 20) {
                    Image(systemName: "keyboard").font(.system(size: 44, weight: .ultraLight)).foregroundColor(Studio.accent).frame(width: 78, height: 76).background(Studio.accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Keychron Q6 Max").font(.system(size: 28, weight: .semibold)).tracking(-0.5)
                        Text("ISO italiano · Scocca nera · Esc turchese").font(.system(size: 12)).foregroundColor(Studio.muted)
                        Label(model.available ? "Bluetooth rilevato" : model.selectedUSBID != nil ? "USB rilevata" : "In attesa della tastiera", systemImage: model.available || model.selectedUSBID != nil ? "circle.fill" : "circle.dotted")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(model.available || model.selectedUSBID != nil ? Studio.success : Studio.muted)
                    }
                    Spacer()
                    Button { model.scan() } label: { Label("Rileva", systemImage: "arrow.clockwise") }.buttonStyle(StudioButton()).disabled(model.busy)
                }
                StudioSurface {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RGB via Bluetooth").font(.system(size: 21, weight: .semibold))
                            Text("Colore, luminosità e 22 effetti. USB scollegata durante l’uso.").font(.system(size: 12)).foregroundColor(Studio.muted)
                        }
                        Spacer()
                        Text(model.directBluetooth ? "Controllo diretto selezionato" : "Modalità precedente").font(.system(size: 10, weight: .medium)).foregroundColor(Studio.muted)
                    }
                    StudioAdaptiveStack(breakpoint: 1050, spacing: 26) {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack(alignment: .top, spacing: 12) {
                                stepMarker("1", done: model.accessVerified)
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(model.accessVerified ? "Accesso pronto" : "Accesso alla tastiera").font(.system(size: 16, weight: .semibold))
                                    Text(model.accessMessage).font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                    Button(model.accessVerified ? "Verifica di nuovo" : "Verifica accesso Bluetooth") { model.checkAccess() }.buttonStyle(StudioButton()).disabled(!model.available || model.busy)
                                    if !model.accessVerified {
                                        Button("Apri impostazioni privacy") { model.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Studio.accent)
                                    }
                                }
                            }
                            Divider()
                            HStack(alignment: .top, spacing: 12) {
                                stepMarker("2", done: model.directBluetooth || model.firmwareArmed)
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Controllo dall’app").font(.system(size: 16, weight: .semibold))
                                    Toggle("Firmware Keyglow con RGB diretti installato", isOn: $model.directBluetooth).toggleStyle(.checkbox).disabled(model.busy)
                                    if model.directBluetooth {
                                        Label("Nessuna combinazione di tasti", systemImage: "cursorarrow.click").font(.system(size: 13, weight: .medium)).foregroundColor(Studio.accent)
                                        Text("Scegli gli RGB e premi Applica, anche dalla pagina Illuminazione. Questa scelta viene ricordata; non equivale alla verifica firmware della pagina Firmware.").font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Text("La versione 0.6 abilita invio diretto e salvataggio. Va prima installata sulla tastiera. Con il firmware precedente usa la combinazione qui sotto.").font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 7) { KeycapLabel(text: "fn"); Text("+").foregroundColor(Studio.muted); KeycapLabel(text: "○"); Text("2 secondi").font(.system(size: 12)).foregroundColor(Studio.muted) }
                                        Toggle("Ricezione attivata · invia entro 30 s", isOn: $model.firmwareArmed).toggleStyle(.checkbox).disabled(model.busy)
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 9).fill(model.workspace.lighting.effect == 0 ? Studio.rail : model.color).frame(width: 44, height: 44).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.15)))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.currentEffect.name).font(.system(size: 17, weight: .semibold))
                                    Text("#\(model.hex)").font(.system(size: 12, design: .monospaced)).foregroundColor(Studio.muted)
                                }
                            }
                            HStack {
                                Text("Luminosità"); Spacer(); Text("\(Int(model.brightness))%").monospacedDigit()
                            }.font(.system(size: 12)).foregroundColor(Studio.muted)
                            HStack {
                                Text("Velocità"); Spacer(); Text("\(Int(model.workspace.lighting.speed))").monospacedDigit()
                            }.font(.system(size: 12)).foregroundColor(Studio.muted)
                            Button("Modifica colore ed effetto") { model.section = 0 }.buttonStyle(StudioButton())
                            Divider()
                            if model.directBluetooth {
                                BluetoothSaveChoice(model: model)
                            }
                            Button { model.send(off: false) } label: { HStack { Text(model.bluetoothApplyTitle); Spacer(); Image(systemName: "arrow.up.right") }.frame(maxWidth: .infinity) }.buttonStyle(StudioButton(primary: true)).disabled(!model.ready || !model.bluetoothEffectSupported)
                            Button(model.directBluetooth && model.saveBluetoothOnKeyboard ? "Spegni e salva RGB" : "Spegni RGB") { model.send(off: true) }.buttonStyle(StudioButton()).disabled(!model.ready)
                            if model.transmitting { ProgressView(value: model.progress).tint(Studio.accent) }
                            if !model.bluetoothEffectSupported { Text("Per-tasto e Mix richiedono USB.").font(.system(size: 12)).foregroundColor(Studio.accent) }
                            Text(model.message).font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Studio.rail.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                Text(model.directBluetooth ? "Invio in circa 5 secondi. Evita Caps Lock e Num Lock durante l’invio. Con Salva nella tastiera, l’ultimo RGB applicato viene conservato anche dopo lo spegnimento; attendi 2 secondi al termine." : "Invio in circa 5 secondi. Evita Caps Lock e Num Lock durante l’invio. Con il firmware precedente gli RGB Bluetooth sono temporanei.").font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3)
                DisclosureGroup("Configurazione completa via USB") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Mappa dei tasti, macro, profili completi, RGB per tasto e timer si leggono e si salvano con USB.").font(.system(size: 12)).foregroundColor(Studio.muted)
                        if model.usbDevices.isEmpty {
                            Text("Collega il cavo, seleziona Cable e premi Rileva.").foregroundColor(Studio.muted)
                        } else {
                            Picker("Q6 Max USB", selection: $model.selectedUSBID) { Text("Seleziona").tag(Optional<UInt64>.none); ForEach(model.usbDevices) { Text("\($0.name) · USB").tag(Optional($0.id)) } }.frame(maxWidth: 530)
                            Button("Leggi configurazione dalla tastiera") { model.readUSB() }.buttonStyle(StudioButton(primary: true)).disabled(model.selectedUSBID == nil || model.busy)
                            Text(model.usbMessage).font(.system(size: 12)).foregroundColor(Studio.muted)
                        }
                        Text("Il ricevitore 2,4 GHz non è ancora gestito da Keyglow.").font(.system(size: 11)).foregroundColor(Studio.muted)
                    }.padding(.top, 15)
                }
            }.studioPage()
        }.onChange(of: model.selectedUSBID) { _ in model.usbSnapshot = nil; model.baselineWorkspace = nil; model.cableModeConfirmed = false }
    }
    private func stepMarker(_ number: String, done: Bool) -> some View {
        Group { if done { Image(systemName: "checkmark") } else { Text(number) } }
            .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(done ? Studio.rail : Studio.muted)
            .frame(width: 27, height: 27).background(done ? Studio.accent : Studio.line.opacity(0.5)).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct BluetoothSaveChoice: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Salva nella tastiera", isOn: $model.saveBluetoothOnKeyboard).toggleStyle(.checkbox)
            Text(model.saveBluetoothOnKeyboard ? "Mantieni gli RGB anche dopo lo spegnimento." : "Prova temporanea, fino al riavvio della tastiera.")
                .font(.system(size: 11)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
        }.disabled(model.lightingControlsDisabled)
    }
}

struct FirmwareWorkspaceView: View {
    @ObservedObject var model: StudioModel
    @StateObject private var bluetooth = BluetoothFirmwareInspector()
    @StateObject private var updater = FirmwareUpdateModel()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                FirmwareUpdateView(model: updater).disabled(model.busy && !updater.isBusy)
                Group {
                PanelTitle(title: "Due firmware, una tastiera", subtitle: "Il controller gestisce tasti e luci. Il modulo radio gestisce Bluetooth e riconnessione.")
                StudioSurface {
                    Label("Controller Q6 Max ISO", systemImage: "cpu").font(.system(size: 18, weight: .semibold))
                    info("Versione letta", model.usbSnapshot?.firmwareVersion ?? "Collega USB e leggi la tastiera")
                    info("Protocollo VIA", model.usbSnapshot.map { String($0.protocolVersion) } ?? "—")
                    info("Firmware reattivo", model.reactiveFirmwareRecognized ? "Riconosciuta via USB" : "Non verificata sul dispositivo")
                }
                StudioSurface {
                    HStack {
                        Label("Modulo Bluetooth", systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Button("Leggi versione radio") { model.readRadioVersion() }.buttonStyle(StudioButton()).disabled(model.selectedUSBID == nil || model.busy)
                    }
                    if let radio = model.radioVersion {
                        info("Modello radio", radio.moduleModel)
                        info("Versione firmware", radio.firmwareVersion)
                        info("Versione hardware", radio.hardwareVersion)
                    }
                    Text(model.radioMessage).font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                    Text("La lettura recupera informazioni: non avvia l’aggiornamento.").font(.system(size: 11)).foregroundColor(Studio.muted)
                }
                StudioSurface {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Verifica senza cavo", systemImage: "wave.3.right").font(.system(size: 18, weight: .semibold))
                            Text("Identità della radio e batteria").font(.system(size: 12)).foregroundColor(Studio.muted)
                        }
                        Spacer()
                        if bluetooth.isRunning {
                            ProgressView().controlSize(.small)
                            Button("Interrompi") { bluetooth.cancel() }.buttonStyle(StudioButton())
                        } else {
                            Button("Verifica Bluetooth") { bluetooth.start() }.buttonStyle(StudioButton())
                        }
                    }
                    Text(bluetooth.message).font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                    if bluetooth.permissionDenied {
                        Button("Apri permessi Bluetooth") { model.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") }.buttonStyle(StudioButton())
                    }
                    if let result = bluetooth.inspection {
                        Label("Q6 Max ISO identificata · 3434:0861", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundColor(Studio.success)
                        info("Firmware radio via Bluetooth", result.radioFirmware ?? "Non esposto")
                        info("Batteria letta", result.batteryPercent.map { "\($0)%" } ?? "Non esposta")
                        info("Ultima lettura", result.inspectedAt.formatted(date: .abbreviated, time: .shortened))
                        Text(result.vendorServicePresent ? "È presente un servizio proprietario della radio. La sua presenza non conferma un canale di aggiornamento del controller." : "Nessun servizio proprietario riconosciuto in questa lettura.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("Servizi e caratteristiche rilevati") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Servizi: \(result.serviceIDs.joined(separator: ", "))").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                ForEach(result.characteristics) { characteristic in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(characteristic.service) / \(characteristic.uuid)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                        Text(characteristic.properties).font(.system(size: 11)).foregroundColor(Studio.muted)
                                    }
                                }
                            }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("La verifica legge solo identità, firmware e batteria. Le caratteristiche proprietarie vengono elencate senza leggerne i valori. Nessuna scrittura o aggiornamento viene avviato.")
                        .font(.system(size: 11)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }
                StudioSurface {
                    PanelTitle(title: "Backup e recupero", subtitle: "Conserva un profilo prima di modificare il firmware.")
                    HStack {
                        Button("Esporta profilo") { model.exportProfile() }.buttonStyle(StudioButton())
                        Button("Identifica file firmware") { model.inspectFirmwareFile() }.buttonStyle(StudioButton())
                    }
                    if !model.firmwareFileDescription.isEmpty { Text(model.firmwareFileDescription).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    Text("Il firmware 0.6 richiede USB/DFU. Il nuovo percorso Bluetooth richiede la prima installazione del loader e la chiave proprietario: usa la sezione di aggiornamento qui sopra.").font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Launcher Keychron") { model.openURL("https://launcher.keychron.com/") }.buttonStyle(StudioButton())
                    Button("Note firmware radio") { model.openURL("https://www.keychron.com/pages/keychron-v-max-q-max-k-max-series-bluetooth-firmware") }.buttonStyle(StudioButton())
                    Button("Design hardware Q6 Max") { model.openURL("https://github.com/Keychron/Keychron-Keyboards-Hardware-Design/tree/main/Q-Max-Series/Q6%20Max") }.buttonStyle(StudioButton())
                }
                Text("I file CAD ufficiali documentano scocca, plate e assemblaggio. Il layout dell’app usa la matrice ISO ufficiale e le legende italiane della tua tastiera.").font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3)
                }.disabled(model.busy || updater.isBusy)
            }.studioPage()
        }.onAppear { updater.onBusyChanged = { model.busy = $0 } }
            .onDisappear { bluetooth.cancel(); updater.cancel() }
    }
    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundColor(Studio.muted); Spacer(); Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).multilineTextAlignment(.trailing).fixedSize(horizontal:false,vertical:true).textSelection(.enabled) }
    }
}
