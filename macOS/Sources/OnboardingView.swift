import AppKit
import SwiftUI

/// First-run guide: keyboard, macOS access, firmware, summary. One visual
/// language for all four steps; the models decide what may happen next.
struct OnboardingView: View {
    @ObservedObject private var language = AppLanguageStore.shared
    @ObservedObject var model: OnboardingModel
    @ObservedObject var setup: KeyboardSetupModel
    let onContinue: () -> Void
    let onRelaunch: () -> Void
    let onLater: () -> Void
    static let steps=["Tastiera","Accessi","Firmware","Riepilogo"]
    static let warning=Color(hex:0xF1BD79)

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            header
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    VStack(alignment:.leading,spacing:8) {
                        LText(title).font(.system(size:22,weight:.semibold)).tracking(-0.3).fixedSize(horizontal:false,vertical:true)
                            .accessibilityAddTraits(.isHeader)
                        LText(subtitle).font(.system(size:13)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                    }
                    switch setup.step {
                    case 0: keyboardStep
                    case 1: permissionStep
                    case 2: firmwareStep
                    default: summaryStep
                    }
                }.frame(maxWidth:576,alignment:.leading).padding(.horizontal,32).padding(.vertical,24)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            Divider()
            footer
        }.background(Studio.background).foregroundColor(Studio.text).font(.system(size:13)).tint(Studio.accent).environment(\.locale, language.language.locale)
    }

    // MARK: Frame

    private var header: some View {
        VStack(spacing:16) {
            HStack {
                LText("Passo \(setup.step+1) di \(Self.steps.count)").font(.system(size:12,weight:.medium)).monospacedDigit().foregroundColor(Studio.muted)
                    .accessibilityHidden(true)
                Spacer(minLength:12)
                LanguageMenu()
            }
            OnboardingStepper(current:setup.step)
        }.padding(.horizontal,32).padding(.top,16).padding(.bottom,20)
    }
    private var footer: some View {
        HStack(spacing:12) {
            if setup.step > 0 {
                LButton("Indietro") {setup.step -= 1}.buttonStyle(StudioButton())
            } else {
                // Closes the guide without recording it as completed.
                LButton("Configura più tardi",action:onLater).buttonStyle(.plain).font(.system(size:12,weight:.medium))
                    .foregroundColor(Studio.muted).frame(minHeight:40).contentShape(Rectangle())
                    .localizedHelp("Chiude la guida: puoi riaprirla dal menu Keyglow")
            }
            Spacer(minLength:0)
            if setup.step == 1 && model.permission != .granted {
                // USB configuration does not need Input Monitoring; nothing is recorded as granted.
                LButton("Continua senza accesso") {setup.advanceWithoutAccess(); setup.recognizeFirmware()}.buttonStyle(StudioButton())
            }
            LButton(setup.step == 3 ? finishTitle : "Continua",action:onContinue)
                .buttonStyle(StudioButton(primary:true)).keyboardShortcut(.defaultAction)
                .disabled(setup.step == 0 ? !setup.supportsSelection : setup.step == 1 ? !model.canContinue : false)
        }.padding(.horizontal,32).padding(.vertical,20)
    }
    private var title:String { ["Benvenuto in Keyglow","Consenti l’accesso in macOS","Prepara la tastiera","Il tuo prossimo passo"][setup.step] }
    private var subtitle:String {
        ["Collega la tua Keychron: controlliamo prima il modello compatibile.",
         "Questo accesso serve per comunicare con la tastiera. Il consenso resta nelle tue mani.",
         "Per colori ed effetti via Bluetooth serve il firmware Keyglow sulla tastiera.",
         "Modello, accessi e firmware hanno ruoli diversi. Ecco cosa puoi fare adesso."][setup.step]
    }
    private var finishTitle:String {
        switch setup.firmwareChoice {
        case .install: "Prepara il firmware"
        case .installed: "Apri Illuminazione"
        case .usb: "Apri Connessione USB"
        }
    }

    // MARK: Keyboard

    private var keyboardStep:some View {
        VStack(alignment:.leading,spacing:16) {
            if setup.keyboards.isEmpty {
                VStack(alignment:.leading,spacing:16) {
                    HStack(alignment:.top,spacing:16) {
                        OnboardingIconTile(symbol:"keyboard",color:Studio.muted)
                        VStack(alignment:.leading,spacing:6) {
                            LText("Nessuna Keychron rilevata").font(.system(size:16,weight:.semibold))
                            LText("Collega USB e seleziona Cable, oppure associa la tastiera al Mac e seleziona BT. Il ricevitore 2,4 GHz non è supportato.")
                                .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                        }
                    }
                    Button {setup.scan()} label:{ LLabel("Rileva di nuovo",systemImage:"arrow.clockwise") }.buttonStyle(StudioButton())
                }.onboardingCard()
            } else {
                HStack(alignment:.firstTextBaseline) {
                    LText(setup.keyboards.count == 1 ? "Tastiera rilevata" : "Scegli la tastiera da configurare")
                        .font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    Spacer(minLength:12)
                    Button {setup.scan()} label:{ LLabel("Rileva di nuovo",systemImage:"arrow.clockwise").font(.system(size:12,weight:.medium)) }
                        .buttonStyle(.plain).foregroundColor(Studio.accent).frame(minHeight:28).contentShape(Rectangle())
                }
                VStack(spacing:10) {
                    ForEach(setup.keyboards) { keyboard in keyboardCard(keyboard) }
                }
                if let selected=setup.selected, !selected.supported {
                    LLabel("Non installare il firmware Q6 Max ISO su questa tastiera. Puoi esplorare una bozza locale senza inviare comandi.",systemImage:"exclamationmark.triangle")
                        .foregroundColor(Self.warning).fixedSize(horizontal:false,vertical:true)
                }
            }
            LDisclosureGroup("Modelli supportati e riconoscimento") {
                VStack(alignment:.leading,spacing:10) {
                    LText("Questa versione supporta la Q6 Max ISO con manopola. Il layout rappresentato è italiano. Altri modelli Keychron e la variante ANSI non sono ancora supportati.")
                    LText("Il modello viene identificato dai dati USB/Bluetooth. Il firmware installato viene valutato separatamente.")
                }.fixedSize(horizontal:false,vertical:true).padding(.top,10)
            }.font(.system(size:12)).foregroundColor(Studio.muted)
        }
    }
    private func keyboardCard(_ keyboard:SetupKeyboard) -> some View {
        let selected=setup.selectedID == keyboard.id, choosing=setup.keyboards.count > 1
        return Button {setup.selectedID=keyboard.id} label:{
            VStack(alignment:.leading,spacing:18) {
            // The supported model is shown as the keyboard itself: ISO Enter, teal Esc, knob.
            if keyboard.supported && !choosing { OnboardingKeyboardPicture().padding(.horizontal,4).padding(.top,4) }
            HStack(spacing:16) {
                if !keyboard.supported || choosing { OnboardingIconTile(symbol:"keyboard",color:keyboard.supported ? Studio.accent : Studio.muted) }
                VStack(alignment:.leading,spacing:8) {
                    LText(keyboard.modelTitle).font(.system(size:16,weight:.semibold)).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:8) {
                        OnboardingChip(text:Self.connection(keyboard.transport),symbol:Self.connectionSymbol(keyboard.transport),color:Studio.muted)
                        OnboardingChip(text:keyboard.supported ? "Supportata" : "Non supportata",
                                       symbol:keyboard.supported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                       color:keyboard.supported ? Studio.success : Self.warning)
                    }
                }
                Spacer(minLength:0)
                if choosing {
                    Image(systemName:selected ? "largecircle.fill.circle":"circle").font(.system(size:18)).foregroundColor(selected ? Studio.accent : Studio.muted).accessibilityHidden(true)
                }
            }
            }.onboardingCard(selected:selected && choosing).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(keyboard.modelTitle), \(keyboard.transport), \(L10n.string(keyboard.supported ? "modello supportato":"modello non supportato"))"))
            .accessibilityAddTraits(selected ? .isSelected:[])
    }
    /// Short connection label; the raw HID transport stays in the accessibility label.
    static func connection(_ transport:String) -> String {
        let value=transport.lowercased()
        return value.contains("bluetooth") ? "Bluetooth" : value == "usb" ? "USB" : transport
    }
    static func connectionSymbol(_ transport:String) -> String {
        transport.lowercased().contains("bluetooth") ? "dot.radiowaves.left.and.right" : "cable.connector"
    }

    // MARK: Access

    private var permissionStep:some View {
        let granted=model.permission == .granted
        return VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:12) {
                    Image(systemName:"hand.raised").font(.system(size:17)).foregroundColor(granted ? Studio.success : Self.warning).frame(width:24).accessibilityHidden(true)
                    LText("Monitoraggio input").font(.system(size:15,weight:.semibold))
                    OnboardingChip(text:granted ? "Consentito":"Da abilitare",symbol:granted ? "checkmark.circle.fill":"circle.dotted",color:granted ? Studio.success : Self.warning)
                    Spacer(minLength:0)
                    if !granted {
                        Button {model.refresh()} label:{ LLabel("Ricontrolla",systemImage:"arrow.clockwise").font(.system(size:12,weight:.medium)) }
                            .buttonStyle(.plain).foregroundColor(Studio.accent).frame(minHeight:28).contentShape(Rectangle())
                    }
                }.padding(.horizontal,20).frame(minHeight:56)
                if granted {
                    Divider()
                    LLabel("Non serve autorizzare di nuovo questo accesso.",systemImage:"checkmark.circle").foregroundColor(Studio.success)
                        .padding(.horizontal,20).frame(minHeight:52)
                } else {
                    Divider()
                    instruction(1,"Apri Impostazioni di Sistema → Privacy e sicurezza → Monitoraggio input.") {
                        LButton("Apri Impostazioni") {model.openPrivacySettings()}.buttonStyle(StudioButton(primary:!model.needsRelaunch))
                    }
                    Divider()
                    instruction(2,"Abilita Keyglow nell’elenco.") { EmptyView() }
                    Divider()
                    instruction(3,"Esci e riapri Keyglow: macOS applica il permesso solo alle app avviate dopo averlo concesso. La guida riprende da qui.") {
                        LButton("Esci e riapri Keyglow",action:onRelaunch).buttonStyle(StudioButton(primary:model.needsRelaunch))
                    }
                }
            }.onboardingCard(padding:0)
            if !granted {
                if !model.message.isEmpty {
                    LText(model.message).font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                }
                LLabel("Usi solo il cavo? Mappa, macro e RGB via USB non richiedono questo permesso. Gli RGB via Bluetooth restano non disponibili finché non lo abiliti.",systemImage:"cable.connector")
                    .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            }
            VStack(alignment:.leading,spacing:12) {
                if !granted {
                    LDisclosureGroup("Se Keyglow non compare nell’elenco") {
                        VStack(alignment:.leading,spacing:10) {
                            LText("Usa + e aggiungi questa copia dell’app:")
                            Text(verbatim: model.appURL.path).font(.system(size:11,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                            LButton("Mostra nel Finder") {model.revealApplication()}.buttonStyle(StudioButton())
                            LText("Se la voce Keyglow è già attiva ma l’app non vede il permesso, rimuovila con − e aggiungila di nuovo, poi esci e riapri Keyglow.")
                                .fixedSize(horizontal:false,vertical:true)
                        }.padding(.top,10)
                    }
                }
                LDisclosureGroup("Cosa fa Keyglow con questo accesso") {
                    VStack(alignment:.leading,spacing:10) {
                        LText("Keyglow usa l’accesso HID per comunicare con la Q6 Max. Non registra la digitazione in background. Registrazione macro e test dei tasti sono azioni esplicite in primo piano.")
                        LText("Bluetooth di sistema e Portachiavi chiedono un consenso separato solo quando usi la relativa verifica o la chiave per un aggiornamento firmware.")
                    }.fixedSize(horizontal:false,vertical:true).padding(.top,10)
                }
            }.font(.system(size:12)).foregroundColor(Studio.muted)
        }
    }
    private func instruction<Action:View>(_ number:Int,_ text:String,@ViewBuilder action:()->Action) -> some View {
        HStack(alignment:.center,spacing:14) {
            Text(verbatim:"\(number)").font(.system(size:12,weight:.semibold)).monospacedDigit().foregroundColor(Studio.text)
                .frame(width:24,height:24).background(Circle().fill(Studio.line)).accessibilityHidden(true)
            LText(text).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
            action().fixedSize()
        }.padding(.horizontal,20).padding(.vertical,10).frame(minHeight:52)
    }

    // MARK: Firmware

    private var firmwareStep:some View {
        VStack(alignment:.leading,spacing:16) {
            firmwareRecognitionNote
            VStack(spacing:10) {
                ForEach(SetupFirmwareChoice.allCases,id:\.self) { choice in firmwareCard(choice) }
            }
            LText(setup.firmwareChoice == .installed
                 ? (firmwareRecognized
                    ? "Riconosciuto dalla lettura USB. Gli aggiornamenti firmware via Bluetooth richiedono la chiave proprietario creata sul Mac usato per la prima installazione; la pagina Firmware esegue la verifica autenticata."
                    : "È una tua dichiarazione, non una lettura del firmware. Gli aggiornamenti firmware via Bluetooth richiedono il loader Keyglow e la chiave proprietario creata sul Mac usato per la prima installazione; la pagina Firmware esegue la verifica autenticata.")
                 : setup.firmwareChoice == .usb ? "Puoi usare l’editor USB e preparare profili. RGB e aggiornamenti via Bluetooth restano da configurare."
                 : "La prima installazione richiede USB e DFU. L’app ti accompagna nel backup, prepara la chiave privata, chiede conferma dei file e installa il firmware; poi ripristina il profilo. Gli aggiornamenti successivi possono passare via Bluetooth.")
                .font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            LDisclosureGroup("Firmware originale e firmware Keyglow") {
                LText("Con il firmware originale, il collegamento Bluetooth serve a digitare. I controlli RGB di Keyglow richiedono il firmware personalizzato. Mappa, macro e RGB via USB restano disponibili con firmware compatibile VIA.")
                    .fixedSize(horizontal:false,vertical:true).padding(.top,10)
            }.font(.system(size:12)).foregroundColor(Studio.muted)
        }
    }
    private func firmwareCard(_ choice:SetupFirmwareChoice) -> some View {
        let selected=setup.firmwareChoice == choice
        return Button {setup.firmwareChoice=choice} label:{
            HStack(alignment:.top,spacing:14) {
                Image(systemName:selected ? "largecircle.fill.circle":"circle").font(.system(size:18)).foregroundColor(selected ? Studio.accent : Studio.muted)
                    .frame(width:24,height:24).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    LText(choice.title).font(.system(size:14,weight:.semibold)).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                    LText(choice.summary).font(.system(size:12)).foregroundColor(Studio.muted).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
            }.onboardingCard(selected:selected,padding:16).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim:L10n.catalog.text(choice.title,language:language.language) + ". " + L10n.catalog.text(choice.summary,language:language.language)))
            .accessibilityAddTraits(selected ? .isSelected:[])
    }
    private var firmwareRecognized:Bool { if case .recognized = setup.firmwareRecognition { return true }; return false }
    @ViewBuilder private var firmwareRecognitionNote:some View {
        switch setup.firmwareRecognition {
        case .idle: EmptyView()
        case .reading:
            LLabel("Lettura della versione firmware via USB…",systemImage:"cable.connector").foregroundColor(Studio.muted)
        case .recognized(let version):
            VStack(alignment:.leading,spacing:4) {
                LLabel("Firmware Keyglow riconosciuto via USB",systemImage:"checkmark.seal.fill").foregroundColor(Studio.success)
                Text(verbatim:version).font(.system(size:12,design:.monospaced)).foregroundColor(Studio.muted).textSelection(.enabled)
            }
        case .unrecognized(let version):
            LLabel("Versione firmware letta via USB: \(version). Non corrisponde al firmware Keyglow incluso in questa app.",systemImage:"info.circle")
                .fixedSize(horizontal:false,vertical:true)
        case .failed(let reason):
            VStack(alignment:.leading,spacing:4) {
                LLabel("Lettura del firmware via USB non riuscita. Puoi verificarlo dalla pagina Firmware.",systemImage:"exclamationmark.triangle")
                    .foregroundColor(Self.warning).fixedSize(horizontal:false,vertical:true)
                LText(reason).font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            }
        case .bluetooth:
            LLabel("In Bluetooth non è possibile riconoscere con certezza il firmware senza la chiave proprietario. Per verificarlo collega la tastiera via USB oppure usa la pagina Firmware.",systemImage:"info.circle")
                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
        }
    }

    // MARK: Summary

    private var summaryStep:some View {
        VStack(alignment:.leading,spacing:20) {
            VStack(alignment:.leading,spacing:0) {
                summaryRow(setup.selected?.modelTitle ?? "Tastiera da rilevare",state:setup.supportsSelection ? .ready : .pending)
                Divider()
                summaryRow(model.permission == .granted ? "Monitoraggio input consentito" : setup.skippedAccess ? "Senza Monitoraggio input: gli RGB via Bluetooth restano non disponibili" : "Permesso da verificare",
                           state:model.permission == .granted ? .ready : setup.skippedAccess ? .limited : .pending)
                Divider()
                summaryRow(firmwareSummary.text,state:firmwareSummary.state)
            }.onboardingCard(padding:0)
            VStack(alignment:.leading,spacing:10) {
                switch setup.firmwareChoice {
                case .install:
                    LText("Prima installazione del firmware").font(.system(size:16,weight:.semibold))
                    LText("1. In Firmware → Prima installazione, collega USB e seleziona Cable. Keyglow salva le impostazioni.\n2. Autorizza la chiave privata mentre la tastiera può ancora scrivere.\n3. Segui le istruzioni DFU nell’app e attendi il backup completo.\n4. Controlla e conferma i file, attendi l’installazione, poi ricollega in Cable e ripristina il profilo.")
                        .lineSpacing(6).fixedSize(horizontal:false,vertical:true)
                    LText("Aprire la pagina Firmware non avvia alcuna installazione. I controlli RGB Bluetooth non sono ancora abilitati.")
                        .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                case .installed:
                    LText("Colori ed effetti dall’app").font(.system(size:16,weight:.semibold))
                    LText("Seleziona BT e scollega USB. In Illuminazione scegli colore ed effetto; abilita l’anteprima automatica oppure invia manualmente. Salva nella tastiera mantiene gli RGB dopo lo spegnimento.")
                        .fixedSize(horizontal:false,vertical:true)
                    LText("La disponibilità effettiva richiede anche la verifica in sola lettura del collegamento. Mappa, macro, Mix e timer continuano a usare USB.")
                        .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                case .usb:
                    LText("Configurazione via USB").font(.system(size:16,weight:.semibold))
                    LText("Collega USB e seleziona Cable, poi scegli Leggi configurazione. Le modifiche restano nella bozza fino ad Applica via USB. Potrai preparare il firmware Bluetooth in seguito.")
                        .fixedSize(horizontal:false,vertical:true)
                }
            }
            LLabel(destinationNote,systemImage:"arrow.right.circle").font(.system(size:12,weight:.medium)).foregroundColor(Studio.accent).fixedSize(horizontal:false,vertical:true)
            LText("Puoi riaprire questa procedura dal menu Keyglow → Configura tastiera e accessi.")
                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
    private enum SummaryState { case ready, limited, pending }
    private var firmwareSummary:(text:String,state:SummaryState) {
        switch setup.firmwareChoice {
        case .install: ("Firmware Keyglow da installare via USB",.pending)
        case .usb: ("Configurazione via USB, senza firmware Keyglow",.ready)
        // A recognized firmware is a reading; otherwise it stays the user's statement.
        case .installed: firmwareRecognized ? ("Firmware Keyglow riconosciuto via USB",.ready) : ("Firmware Keyglow dichiarato, da verificare nella pagina Firmware",.pending)
        }
    }
    private var destinationNote:String {
        switch setup.firmwareChoice {
        case .install: "Il pulsante apre la pagina Firmware."
        case .installed: "Il pulsante apre la pagina Illuminazione."
        case .usb: "Il pulsante apre la pagina Connessione."
        }
    }
    private func summaryRow(_ text:String,state:SummaryState) -> some View {
        let symbol=state == .ready ? "checkmark.circle.fill" : state == .limited ? "exclamationmark.triangle.fill" : "circle.dotted"
        let color=state == .ready ? Studio.success : state == .limited ? Self.warning : Studio.muted
        return HStack(alignment:.center,spacing:14) {
            Image(systemName:symbol).font(.system(size:16)).foregroundColor(color).frame(width:24).accessibilityHidden(true)
            LText(text).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
        }.padding(.horizontal,20).padding(.vertical,14).frame(minHeight:48)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(Text(verbatim:L10n.catalog.text(text,language:language.language) + ", " + L10n.catalog.text(state == .ready ? "pronto" : state == .limited ? "con limiti" : "da completare",language:language.language)))
    }
}

extension SetupFirmwareChoice {
    /// One line under the choice title; the consequences are spelled out below the list.
    var summary:String {
        switch self {
        case .install: "Prima installazione guidata, con cavo USB."
        case .installed: "Colori ed effetti via Bluetooth, senza cavo."
        case .usb: "Mappa, macro e RGB con il cavo. Il Bluetooth resta per digitare."
        }
    }
}

/// Numbered progress with connecting lines: done, current and upcoming are
/// told apart by shape and text as well as by color.
private struct OnboardingStepper: View {
    @ObservedObject private var language = AppLanguageStore.shared
    let current: Int
    var body: some View {
        ViewThatFits(in:.horizontal) {
            row(labels:.all)
            row(labels:.currentOnly)
        }.accessibilityElement(children:.ignore)
            .accessibilityLabel(Text(verbatim:L10n.catalog.format("Passo {0} di {1}: {2}",arguments:[String(current+1),String(OnboardingView.steps.count),L10n.catalog.text(OnboardingView.steps[current],language:language.language)],language:language.language)))
    }
    private enum Labels { case all, currentOnly }
    private func row(labels:Labels) -> some View {
        HStack(spacing:10) {
            ForEach(OnboardingView.steps.indices,id:\.self) { index in
                HStack(spacing:8) {
                    node(index)
                    if labels == .all || index == current {
                        LText(OnboardingView.steps[index]).font(.system(size:12,weight:index == current ? .semibold : .regular))
                            .foregroundColor(index == current ? Studio.text : index < current ? Studio.accent : Studio.muted)
                            .lineLimit(1).fixedSize()
                    }
                }
                if index != OnboardingView.steps.count-1 {
                    Rectangle().fill(index < current ? Studio.accent.opacity(0.6) : Studio.line).frame(height:1).frame(minWidth:12,maxWidth:.infinity)
                }
            }
        }
    }
    @ViewBuilder private func node(_ index:Int) -> some View {
        if index < current {
            Image(systemName:"checkmark").font(.system(size:11,weight:.bold)).foregroundColor(Studio.rail)
                .frame(width:24,height:24).background(Circle().fill(Studio.accent))
        } else if index == current {
            Text(verbatim:"\(index+1)").font(.system(size:12,weight:.bold)).monospacedDigit().foregroundColor(Studio.rail)
                .frame(width:24,height:24).background(Circle().fill(Studio.accent))
                .overlay(Circle().stroke(Studio.accent.opacity(0.35),lineWidth:3).padding(-3))
        } else {
            Text(verbatim:"\(index+1)").font(.system(size:12,weight:.medium)).monospacedDigit().foregroundColor(Studio.muted)
                .frame(width:24,height:24).overlay(Circle().strokeBorder(Studio.line,lineWidth:1.5))
        }
    }
}

private struct OnboardingIconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName:symbol).font(.system(size:22,weight:.regular)).foregroundColor(color)
            .frame(width:52,height:52).background(RoundedRectangle(cornerRadius:12).fill(Studio.rail)).accessibilityHidden(true)
    }
}

/// Small status label: icon and words carry the meaning, color supports it.
private struct OnboardingChip: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing:5) {
            Image(systemName:symbol).font(.system(size:10,weight:.semibold))
            LText(text).font(.system(size:11,weight:.semibold)).lineLimit(1)
        }.foregroundColor(color).padding(.horizontal,9).padding(.vertical,5)
            .background(Capsule().fill(color.opacity(0.14))).fixedSize()
    }
}

private extension View {
    /// The guide's surface: panel tone, 14 pt radius, a mint outline only for a selected choice.
    func onboardingCard(selected:Bool=false,padding:CGFloat=20) -> some View {
        self.padding(padding).frame(maxWidth:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:14).fill(selected ? Studio.accent.opacity(0.08) : Studio.panel))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(selected ? Studio.accent.opacity(0.7) : Color.clear,lineWidth:1.5))
    }
}

/// The supported Q6 Max ISO drawn from the same key geometry as the editor:
/// light keys, dark modifiers, teal Esc, knob. Decorative; the card text names the model.
private struct OnboardingKeyboardPicture: View {
    private let definition = KeyboardDefinition.q6ISO
    var body: some View {
        Canvas { context, size in
            let inset = 0.35, unit = size.width / (definition.width + inset * 2)
            let board = Path(roundedRect:CGRect(origin:.zero,size:size),cornerRadius:unit*0.3)
            context.fill(board,with:.color(Color(hex:0x0A0E0F)))
            context.stroke(board,with:.color(Color(hex:0x3E4546)),lineWidth:1)
            for key in definition.keys {
                let color:Color = key.appearance == .light ? Color(hex:0xD9DFDC) : key.appearance == .dark ? Color(hex:0x2C3336) : key.appearance == .accent ? Color(hex:0x238C9C) : Color(hex:0x434B4B)
                func rect(_ x:Double,_ y:Double,_ w:Double,_ h:Double) -> CGRect {
                    CGRect(x:(x+inset)*unit+0.6,y:(y+inset)*unit+0.6,width:w*unit-1.2,height:h*unit-1.2)
                }
                let main = rect(key.x,key.y,key.width,key.height)
                if key.isEncoder { context.fill(Path(ellipseIn:main),with:.color(color)); continue }
                var shape = Path(roundedRect:main,cornerRadius:unit*0.12)
                if let extra = key.secondary { shape.addPath(Path(roundedRect:rect(key.x+extra.x,key.y+extra.y,extra.width,extra.height),cornerRadius:unit*0.12)) }
                context.fill(shape,with:.color(color))
            }
        }.aspectRatio((definition.width+0.7)/(definition.height+0.7),contentMode:.fit)
            .shadow(color:.black.opacity(0.25),radius:12,x:0,y:10)
            .accessibilityHidden(true)
    }
}
