import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var setup: KeyboardSetupModel
    let onContinue: () -> Void
    let onLater: () -> Void
    private let steps=["Tastiera","Accessi","Firmware","Riepilogo"]
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                ForEach(steps.indices,id:\.self) { index in
                    HStack(spacing:6) {
                        Image(systemName:index < setup.step ? "checkmark.circle.fill" : "circle")
                        Text(steps[index]).font(.system(size:12,weight:index == setup.step ? .semibold:.regular))
                    }.foregroundColor(index <= setup.step ? Studio.accent : Studio.muted)
                    if index != 3 { Spacer(minLength:0) }
                }
            }.padding(.horizontal,28).padding(.vertical,20)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    PanelTitle(title:title,subtitle:subtitle)
                    if setup.step == 0 { keyboardStep }
                    else if setup.step == 1 { permissionStep }
                    else if setup.step == 2 { firmwareStep }
                    else { summaryStep }
                }.padding(28).frame(maxWidth:.infinity,alignment:.leading)
            }
            Divider()
            HStack(spacing:12) {
                if setup.step > 0 {
                    Button("Indietro") {setup.step -= 1}.buttonStyle(StudioButton())
                } else {
                    Button("Esplora la bozza",action:onLater).buttonStyle(StudioButton())
                }
                Spacer(minLength:0)
                Button(setup.step == 3 ? finishTitle : "Continua",action:onContinue)
                    .buttonStyle(StudioButton(primary:true)).keyboardShortcut(.defaultAction)
                    .disabled(setup.step == 0 ? !setup.supportsSelection : setup.step == 1 ? !model.canContinue : false)
            }.padding(24)
        }.background(Studio.background).foregroundColor(Studio.text).font(.system(size:13)).tint(Studio.accent)
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
    private var keyboardStep:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Questa versione supporta la Q6 Max ISO con manopola. Il layout rappresentato è italiano. Altri modelli Keychron e la variante ANSI non sono ancora supportati.")
                .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            if setup.keyboards.isEmpty {
                Label("Nessuna Keychron rilevata",systemImage:"keyboard").font(.system(size:15,weight:.medium))
                Text("Collega USB e seleziona Cable, oppure associa la tastiera al Mac e seleziona BT. Il ricevitore 2,4 GHz non è supportato.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            } else {
                ForEach(setup.keyboards) { keyboard in
                    Button {setup.selectedID=keyboard.id} label:{
                        HStack(spacing:12) {
                            Image(systemName:setup.selectedID == keyboard.id ? "checkmark.circle.fill":"circle").foregroundColor(Studio.accent).accessibilityHidden(true)
                            VStack(alignment:.leading,spacing:5) {
                                Text(keyboard.modelTitle).font(.system(size:15,weight:.semibold))
                                Text("\(keyboard.transport) · \(keyboard.supported ? "Modello supportato" : "Modello non supportato")")
                                    .font(.system(size:12)).foregroundColor(Studio.muted)
                            }
                            Spacer(minLength:0)
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:10)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(keyboard.modelTitle), \(keyboard.transport), \(keyboard.supported ? "modello supportato":"modello non supportato")")
                        .accessibilityAddTraits(setup.selectedID == keyboard.id ? .isSelected:[])
                }
                if let selected=setup.selected, !selected.supported {
                    Text("Non installare il firmware Q6 Max ISO su questa tastiera. Puoi esplorare una bozza locale senza inviare comandi.")
                        .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                }
            }
            Button("Rileva di nuovo") {setup.scan()}.buttonStyle(StudioButton())
            Text("Il modello viene identificato dai dati USB/Bluetooth. Il firmware installato viene valutato separatamente.")
                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
    private var permissionStep:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Label("Monitoraggio input",systemImage:"hand.raised").font(.system(size:17,weight:.semibold))
                Spacer()
                Text(model.permission == .granted ? "Consentito":"Da abilitare").foregroundColor(model.permission == .granted ? Studio.success:Studio.muted)
            }
            Text("Keyglow usa l’accesso HID per comunicare con la Q6 Max. Non registra la digitazione in background. Registrazione macro e test dei tasti sono azioni esplicite in primo piano.")
                .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            if model.permission != .granted {
                Text("In Impostazioni di Sistema → Privacy e sicurezza → Monitoraggio input, abilita Keyglow. Al ritorno verifichiamo automaticamente il permesso.").fixedSize(horizontal:false,vertical:true)
                HStack(spacing:10) {
                    Button("Apri Impostazioni") {model.openPrivacySettings()}.buttonStyle(StudioButton(primary:true))
                    Button("Ricontrolla") {model.refresh()}.buttonStyle(StudioButton())
                }
            } else {
                Label("Non serve autorizzare di nuovo questo accesso.",systemImage:"checkmark.circle").foregroundColor(Studio.success)
            }
            if !model.message.isEmpty {Text(model.message).font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)}
            DisclosureGroup("Se Keyglow non compare nell’elenco") {
                VStack(alignment:.leading,spacing:12) {
                    Text("Usa + e aggiungi questa copia dell’app:")
                    Text(model.appURL.path).font(.system(size:11,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    Button("Mostra nel Finder") {model.revealApplication()}.buttonStyle(StudioButton())
                }.padding(.top,12)
            }.foregroundColor(Studio.muted)
            Text("Bluetooth di sistema e Portachiavi chiedono un consenso separato solo quando usi la relativa verifica o la chiave per un aggiornamento firmware.")
                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
    private var firmwareStep:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Con il firmware originale, il collegamento Bluetooth serve a digitare. I controlli RGB di Keyglow richiedono il firmware personalizzato. Mappa, macro e RGB via USB restano disponibili con firmware compatibile VIA.")
                .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            ForEach(SetupFirmwareChoice.allCases,id:\.self) { choice in
                Button {setup.firmwareChoice=choice} label:{
                    HStack(alignment:.top,spacing:12) {
                        Image(systemName:setup.firmwareChoice == choice ? "largecircle.fill.circle":"circle").foregroundColor(Studio.accent).accessibilityHidden(true)
                        Text(choice.title).font(.system(size:13,weight:.medium)).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                        Spacer(minLength:0)
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                        .background(setup.firmwareChoice == choice ? Studio.accent.opacity(0.08) : Studio.panel)
                        .clipShape(RoundedRectangle(cornerRadius:10)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(choice.title)
                    .accessibilityAddTraits(setup.firmwareChoice == choice ? .isSelected:[])
            }
            Text(setup.firmwareChoice == .installed
                 ? "È una tua dichiarazione, non una lettura del firmware. Per gli aggiornamenti Bluetooth serve anche il loader Keyglow con la chiave proprietario; la pagina Firmware esegue la verifica autenticata."
                 : setup.firmwareChoice == .usb ? "Puoi usare l’editor USB e preparare profili. RGB e aggiornamenti via Bluetooth restano da configurare."
                 : "La prima installazione richiede USB e DFU: prima salva il profilo, poi segui la guida della Q6 Max ISO. L’app prepara la chiave proprietario; il flash iniziale del loader non è automatico. Gli aggiornamenti successivi possono passare via Bluetooth.")
                .font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
        }
    }
    private var summaryStep:some View {
        VStack(alignment:.leading,spacing:20) {
            Label(setup.selected?.modelTitle ?? "Tastiera da rilevare",systemImage:"keyboard").font(.system(size:17,weight:.semibold))
            Label(model.permission == .granted ? "Monitoraggio input consentito":"Permesso da verificare",systemImage:"hand.raised")
            Divider()
            if setup.firmwareChoice == .install {
                Text("Prima installazione del firmware").font(.system(size:17,weight:.semibold))
                Text("1. Collega USB e seleziona Cable. In Connessione scegli Leggi configurazione; poi Profili → Salva una copia.\n2. Prepara la chiave proprietario nell’app.\n3. Segui la guida per il loader e il firmware esatti della Q6 Max ISO.\n4. Ripristina il profilo e torna in BT.")
                    .lineSpacing(8).fixedSize(horizontal:false,vertical:true)
                Text("Aprire la pagina Firmware non avvia alcuna installazione. I controlli RGB Bluetooth non sono ancora abilitati.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            } else if setup.firmwareChoice == .installed {
                Text("Colori ed effetti dall’app").font(.system(size:17,weight:.semibold))
                Text("Seleziona BT e scollega USB. In Illuminazione scegli colore ed effetto; abilita l’anteprima automatica oppure invia manualmente. Salva nella tastiera mantiene gli RGB dopo lo spegnimento.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                Text("La disponibilità effettiva richiede anche la verifica in sola lettura del collegamento. Mappa, macro, Mix e timer continuano a usare USB.")
                    .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            } else {
                Text("Configurazione via USB").font(.system(size:17,weight:.semibold))
                Text("Collega USB e seleziona Cable, poi scegli Leggi configurazione. Le modifiche restano nella bozza fino ad Applica via USB. Potrai preparare il firmware Bluetooth in seguito.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            }
            Text("Puoi riaprire questa procedura dal menu Keyglow → Configura tastiera e accessi.")
                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
}
