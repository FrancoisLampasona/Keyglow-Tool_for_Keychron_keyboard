// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct FirstInstallView: View {
    @ObservedObject var model:FirstInstallModel
    let onBluetooth:()->Void
    private var step:Int {
        switch model.journal?.phase {
        case nil:return 0
        case .profileSaved:return 1
        case .prepared:return 2
        case .staging,.loader:return 3
        case .awaitingRestart,.restoring,.complete:return 4
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            PanelTitle(title:"Configura il firmware Keyglow",subtitle:"Una sola volta via USB. Poi colori e aggiornamenti passano dal Bluetooth.")
            HStack(alignment:.top,spacing:6) {
                ForEach(Array(["Backup","DFU","Riepilogo","Installa","Ripristina"].enumerated()),id:\.offset) { index,title in
                    VStack(alignment:.leading,spacing:7) {
                        Group { if model.journal?.phase == .complete || index < step {Image(systemName:"checkmark")} else {Text("\(index+1)")} }
                            .font(.system(size:12,weight:.semibold)).frame(width:26,height:26)
                            .background(index <= step ? Studio.accent.opacity(0.15):Studio.rail).clipShape(Circle())
                        Text(title).font(.system(size:11,weight:index == step ? .semibold:.regular))
                    }.foregroundColor(index == step ? Studio.accent:Studio.muted).frame(maxWidth:.infinity,alignment:.leading)
                        .accessibilityElement(children:.ignore).accessibilityLabel("Passaggio \(index+1), \(title)\(index == step ? ", attuale":"")")
                }
            }
            Divider()
            if model.failed {statusMessage}
            if model.isBusy {
                Label(step >= 2 ? "Lascia il cavo collegato":"Preparazione in corso",systemImage:"cable.connector")
                    .font(.system(size:18,weight:.semibold))
                ProgressView(value:model.progress,total:1).tint(Studio.accent).accessibilityLabel("Avanzamento del passaggio")
                Text(model.isPreparingKey ? "Puoi digitare la password solo nella finestra di macOS. Attendi la conferma prima di entrare in DFU." : "Usa solo il mouse. Non chiudere Keyglow e non spegnere il Mac durante la scrittura.")
                    .foregroundColor(Studio.muted)
            } else {
                switch model.journal?.phase {
                case nil: introduction
                case .profileSaved: dfuInstructions
                case .prepared,.staging,.loader: review
                case .awaitingRestart,.restoring: restart
                case .complete: completed
                }
            }
            if !model.failed {statusMessage}
            if model.recoveryDirectory != nil {
                Button("Mostra backup sul Mac",action:model.revealBackup).buttonStyle(StudioButton()).disabled(model.isBusy)
                Text("Backup, profilo e file di recupero restano privati sul Mac, anche se sposti l’app. Il loader personale contiene una chiave: non condividerlo.")
                    .font(.system(size:11)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            }
            if !model.isBusy && model.journal?.phase != .complete {
                Divider()
                Button("Torna agli aggiornamenti Bluetooth",action:onBluetooth).buttonStyle(StudioButton())
            }
        }.font(.system(size:13)).controlSize(.large)
    }
    private var statusMessage:some View {
        Label(model.message,systemImage:model.failed ? "exclamationmark.circle":model.journal?.phase == .complete ? "checkmark.circle.fill":"info.circle")
            .font(.system(size:13)).foregroundColor(model.failed ? Studio.text:Studio.muted)
            .fixedSize(horizontal:false,vertical:true).accessibilityElement(children:.combine)
    }
    private var introduction:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Prima, mettiamo al sicuro le tue impostazioni.").font(.system(size:18,weight:.semibold))
            instruction("cable.connector","Collega una sola Q6 Max ISO via USB e seleziona Cable. Non premere Esc per ora.")
            instruction("externaldrive","Keyglow legge tasti, manopola, macro, RGB ed energia. In DFU leggerà il controller due volte e salverà un backup verificato.")
            instruction("cursorarrow","Tieni un mouse a disposizione: in DFU la tastiera non scrive e gli RGB sono spenti.")
            Text("Supporto iniziale: Q6 Max ISO con una versione originale riconosciuta. Altri modelli e firmware sconosciuti vengono fermati prima della scrittura.")
                .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            if !model.readyResources {Text("Questa copia dell’app non include il pacchetto USB completo. La tastiera non verrà portata in DFU.").foregroundColor(Studio.muted)}
            if model.canRetryBackup {Button("Riprova il backup",action:model.retryProfileBackup).buttonStyle(StudioButton())}
            Button("Leggi e salva il backup",action:model.backupProfile).buttonStyle(StudioButton(primary:true))
                .disabled(!model.readyResources || model.failed)
        }
    }
    private var dfuInstructions:some View {
        VStack(alignment:.leading,spacing:14) {
            if !model.ownerKeyReady {
                Text("Autorizza i tuoi aggiornamenti").font(.system(size:18,weight:.semibold))
                Text("Il profilo è salvo. Lascia la tastiera in Cable, avviata normalmente: macOS potrebbe chiederti una password prima di continuare.").foregroundColor(Studio.muted)
                Toggle("Prepara la chiave privata che autorizzerà i miei aggiornamenti",isOn:$model.acceptsKey).toggleStyle(.checkbox)
                Text("La chiave esistente viene riutilizzata. Se manca, viene creata e conservata nel Portachiavi e nella cartella privata di recupero. Inserisci l’eventuale password solo nella finestra macOS.")
                    .font(.system(size:12)).foregroundColor(Studio.muted)
                Button("Autorizza e prepara la chiave",action:model.prepareOwnerKey).buttonStyle(StudioButton(primary:true)).disabled(!model.acceptsKey)
            } else {
                Text("Entra in modalità installazione (DFU)").font(.system(size:18,weight:.semibold))
                Text("Profilo e chiave sono già salvi. Esegui questi passaggi mantenendo la stessa porta USB:").foregroundColor(Studio.muted)
                instruction("1.circle","Lascia il selettore su Cable e scollega il cavo dalla tastiera.")
                instruction("2.circle","Tieni premuto Esc, ricollega il cavo e rilascia Esc dopo qualche secondo.")
                instruction("3.circle","Luci spente e nessuna digitazione: premi Rileva DFU con il mouse. Sarà l’app a verificare il dispositivo.")
                Text("La procedura con Esc può azzerare le impostazioni; le ripristineremo dal profilo salvato. Se DFU non compare, ripeti la sequenza e controlla di usare un cavo dati.")
                    .font(.system(size:12)).foregroundColor(Studio.muted)
                Button("Rileva DFU e verifica il backup",action:model.prepareDFU).buttonStyle(StudioButton(primary:true))
            }
        }.fixedSize(horizontal:false,vertical:true)
    }
    private var review:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(model.journal?.phase == .prepared ? "Tutto pronto per installare":"Riprendi la stessa installazione").font(.system(size:18,weight:.semibold))
            if model.failed {
                Text(model.journal?.phase == .loader
                     ? "Il loader potrebbe essere incompleto. Non scollegare, non spegnere e non riavviare la tastiera. Mantieni DFU sulla stessa porta USB; dopo aver confermato, Riprendi e verifica controllerà di nuovo dispositivo e file. Se DFU non è più disponibile, conserva i backup per il recupero assistito."
                     : "Nessun tentativo sul loader è iniziato. Se DFU non è rilevato, ripeti la sequenza Cable → scollega → tieni Esc → ricollega sulla stessa porta → rilascia Esc. Poi conferma e premi il pulsante di installazione qui sotto: rileverà di nuovo il dispositivo.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            }
            Label("Backup completo verificato con due letture",systemImage:"checkmark.shield").foregroundColor(Studio.success)
            Text("Q6 Max ISO · firmware Keyglow build \(model.journal?.targetBuild ?? 0)")
            Text("Prima verrà scritta e riletta l’immagine preparata, poi il loader. Il settore delle impostazioni viene preservato; dopo il riavvio verrà ripristinato il profilo USB.")
                .foregroundColor(Studio.muted)
            DisclosureGroup("File esatti e impronte di verifica") {
                VStack(alignment:.leading,spacing:10) {
                    Text("Origine: \(model.journal?.sourceName ?? "—")")
                    hash("Firmware preparato",key:"staging.bin");hash("Loader personale",key:"loader-private.bin")
                }.padding(.top,8)
            }.font(.system(size:12))
            Text("La prima scrittura del loader non resiste a un’interruzione di alimentazione. Se si interrompe proprio quel passaggio, il recupero può richiedere interventi hardware non verificati su questa tastiera. Lascia il cavo inserito e il Mac alimentato.")
                .font(.system(size:12)).foregroundColor(Studio.muted)
            Toggle("Confermo questi file e mantengo collegata l’alimentazione",isOn:$model.acceptsInstall).toggleStyle(.checkbox)
            Button(model.journal?.phase == .prepared ? "Installa e verifica":"Riprendi e verifica",action:model.install)
                .buttonStyle(StudioButton(primary:true)).disabled(!model.acceptsInstall)
        }.fixedSize(horizontal:false,vertical:true)
    }
    private var restart:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Riavvia, poi ripristiniamo il profilo").font(.system(size:18,weight:.semibold))
            instruction("checkmark.circle","Scrittura e rilettura USB completate. Ora puoi scollegare e ricollegare il cavo, senza premere Esc o altri tasti.")
            instruction("cable.connector","Mantieni Cable e la stessa porta USB. Attendi qualche secondo che la tastiera si avvii.")
            Text("Keyglow controllerà la versione del firmware, ripristinerà le impostazioni e le rileggerà. Se il ripristino si interrompe, il backup rimane disponibile per riprovare.").foregroundColor(Studio.muted)
            Button("Verifica avvio e ripristina",action:model.restore).buttonStyle(StudioButton(primary:true))
        }.fixedSize(horizontal:false,vertical:true)
    }
    private var completed:some View {
        VStack(alignment:.leading,spacing:14) {
            Label("La tastiera è pronta",systemImage:"checkmark.circle.fill").font(.system(size:20,weight:.semibold)).foregroundColor(Studio.success)
            Text("Ora puoi scollegare USB, selezionare BT e usare l’illuminazione dall’app. Gli aggiornamenti successivi passano dalla pagina Firmware via Bluetooth.")
                .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            Button("Apri aggiornamenti Bluetooth",action:onBluetooth).buttonStyle(StudioButton(primary:true))
        }
    }
    private func instruction(_ icon:String,_ text:String)->some View {Label(text,systemImage:icon).labelStyle(.titleAndIcon).fixedSize(horizontal:false,vertical:true)}
    private func hash(_ title:String,key:String)->some View {
        VStack(alignment:.leading,spacing:4) {Text(title);Text(model.journal?.hashes[key] ?? "—").font(.system(size:11,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
    }
}
