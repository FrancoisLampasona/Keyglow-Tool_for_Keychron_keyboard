// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit

struct FirmwareUpdateView: View {
    @ObservedObject var model: FirmwareUpdateModel
    @Binding var showsProvisioning:Bool
    let onOpenUSB:()->Void
    let onOpenProfiles:()->Void
    var body: some View {
        StudioSurface {
            if showsProvisioning { firstInstallation } else {
            VStack(alignment: .leading, spacing: 18) {
                StudioAdaptiveStack(breakpoint: 1120, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Aggiornamento del controller", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 21, weight: .semibold))
                        Text("Via Bluetooth, dopo la prima configurazione USB del loader Keyglow.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                    if model.hasBundledFirmware {
                        Button("Usa firmware incluso") { model.useBundledFirmware() }
                            .buttonStyle(StudioButton(primary:model.artifact == nil)).disabled(model.isBusy)
                    }
                    Button("Scegli firmware…") { model.chooseFile() }
                        .buttonStyle(StudioButton()).disabled(model.isBusy)
                    }
                }

                HStack(spacing:8) {
                    workflowStep("1", "Scegli file", done:model.artifact != nil)
                    Image(systemName:"chevron.right").foregroundColor(Studio.muted)
                    workflowStep("2", "Verifica", done:model.review != nil)
                    Image(systemName:"chevron.right").foregroundColor(Studio.muted)
                    workflowStep("3", "Installa", done:model.phase == .complete)
                }.padding(.vertical,4)

                if let rawName = model.pendingRawName {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(rawName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        HStack {
                            TextField("Numero build della compilazione", text: $model.rawBuild)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                            Button("Valida immagine") { model.validateRaw() }.buttonStyle(StudioButton())
                        }.disabled(model.isBusy)
                        Text("Usa la build dichiarata da chi ha compilato il file. I pacchetti .kgfw la includono già.")
                            .font(.system(size: 11)).foregroundColor(Studio.muted)
                    }
                }

                if let artifact = model.artifact {
                    VStack(alignment: .leading, spacing: 10) {
                        detail("File", artifact.fileName)
                        detail("Destinazione", "Q6 Max ISO · build \(artifact.manifest.build)")
                        detail("Dimensione", ByteCountFormatter.string(fromByteCount: Int64(artifact.image.count), countStyle: .file))
                        DisclosureGroup("SHA-256 dell’immagine") {
                            Text(firmwareHex(artifact.manifest.sha256)).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                        }.font(.system(size: 12)).foregroundColor(Studio.muted)
                    }
                } else if model.pendingRawName == nil {
                    Text("Scegli un pacchetto .kgfw per Q6 Max ISO. Il file verrà controllato prima di aprire il collegamento.")
                        .font(.system(size: 13)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }

                if model.artifact != nil {
                    Picker("Velocità di invio", selection: $model.transferPause) {
                        Text("Prudente · 80 ms").tag(0.08)
                        Text("Rapida · 40 ms").tag(0.04)
                        Text("Sperimentale · 20 ms").tag(0.02)
                    }.frame(maxWidth: 380).disabled(model.isBusy)
                    Text("Si applica anche alla verifica. Dopo un’interruzione puoi rallentare e rileggere la sessione prima di riprendere.")
                        .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }

                if let review = model.review {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Tastiera e chiave proprietario verificate", systemImage: "checkmark.shield")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(Studio.success)
                        detail("Build attuale", "\(review.controller.build)")
                        if let staging = review.staging {
                            detail("Sessione sulla tastiera", staging.summary)
                            detail("Build della sessione", "\(staging.manifest.build)")
                            detail("Blocchi salvati", "\(staging.savedChunks) di \(staging.chunkCount)")
                            DisclosureGroup("Dettagli della sessione") {
                                VStack(alignment: .leading, spacing: 8) {
                                    detail("Preparata", "Sì")
                                    detail("Immagine verificata", staging.ready ? "Sì" : "No")
                                    detail("Installazione confermata", staging.committed ? "Sì" : "No")
                                    detail("Installata", staging.installed ? "Sì" : "No")
                                    Text(firmwareHex(staging.manifest.sha256))
                                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.padding(.top, 8)
                            }.font(.system(size: 12)).foregroundColor(Studio.muted)
                        } else {
                            detail("Sessione sulla tastiera", "Nessun trasferimento preparato")
                        }
                        Text("La verifica legge soltanto identità e sessione: non prepara né installa un aggiornamento.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if !review.isAlreadyInstalled {
                            detail("Da trasferire", review.hasReadyTarget && !model.replaceUncommitted ? "Nessun blocco: immagine già completa" : ByteCountFormatter.string(fromByteCount: Int64(review.plan.literalBytes), countStyle: .file))
                            if review.hasReadyTarget && !model.replaceUncommitted {
                                Text("La ripresa verifica di nuovo identità, autorizzazione salvata e immagine, poi completa l’installazione senza preparare nuovamente il trasferimento.")
                                    .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            detail("Riutilizzati sulla tastiera", ByteCountFormatter.string(fromByteCount: Int64(review.plan.copiedBytes), countStyle: .file))
                            if review.plan.baselineUse != .verified {
                                Text("La base locale non è verificata: verrà trasferita l’intera immagine.")
                                    .font(.system(size: 12)).foregroundColor(Studio.muted)
                            }
                            if review.hasReadyTarget && !model.replaceUncommitted {
                                detail("Operazione", "Verifica finale, installazione e lettura dopo il riavvio")
                            } else if let estimate = model.estimate { detail("Durata stimata", estimate) }
                            Text("Stima indicativa: interruzioni e riconnessione possono allungarla. A 20 ms sono state verificate letture e finalizzazione; un trasferimento completo senza interruzioni resta sperimentale.")
                                .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        if !review.isAlreadyInstalled {
                            Toggle("Ricomincia un trasferimento precedente non ancora installato", isOn: $model.replaceUncommitted)
                                .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isBusy)
                            Text("Lascia disattivato per riprendere i blocchi già salvati. Ricominciare elimina soltanto la sessione di aggiornamento non confermata.")
                                .font(.system(size: 11)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.review != nil || model.artifact != nil { Divider() }

                if model.isBusy, let progress = model.progress, progress.stage == .transferring {
                    ProgressView(value: Double(progress.completedBytes), total: Double(max(1, progress.totalBytes)))
                        .tint(Studio.accent).accessibilityLabel("Dati salvati sulla tastiera")
                    Text("\(progress.completedBytes) di \(progress.totalBytes) byte salvati")
                        .font(.system(size: 11)).monospacedDigit().foregroundColor(Studio.muted)
                } else if model.isBusy { ProgressView().controlSize(.small).accessibilityLabel(model.message) }

                HStack(alignment: .top, spacing: 9) {
                    if model.phase == .complete { Image(systemName: "checkmark.circle.fill").foregroundColor(Studio.success) }
                    else if model.phase == .failed || model.phase == .paused { Image(systemName: "exclamationmark.circle").foregroundColor(Studio.accent) }
                    Text(model.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    if model.isBusy {
                        if model.canCancel { Button("Interrompi") { model.cancel() }.buttonStyle(StudioButton()) }
                    } else {
                        if model.artifact != nil {
                        Button(model.review == nil ? "Verifica tastiera" : "Verifica di nuovo") { model.verifyKeyboard() }
                            .buttonStyle(StudioButton(primary:model.review == nil)).disabled(model.artifact == nil || (model.cooldownUntil.map { context.date < $0 } ?? false))
                        }
                        if let review=model.review, !review.isAlreadyInstalled {
                        Button(model.review?.hasReadyTarget == true && !model.replaceUncommitted ? "Completa installazione" : "Avvia aggiornamento") { model.start() }
                            .buttonStyle(StudioButton(primary: true)).disabled(!model.canStart)
                        }
                    }
                }
                if let until = model.cooldownUntil, context.date < until, !model.isBusy {
                    Text("Nuova lettura disponibile tra \(max(1, Int(ceil(until.timeIntervalSince(context.date))))) s, dopo la scadenza della risposta precedente.")
                        .font(.system(size: 11)).foregroundColor(Studio.muted)
                }
                }
                }
                if model.canStart || model.isBusy {
                    Text("Durante gli scambi non digitare e non cambiare collegamento. Il completamento sarà confermato solo dopo il riavvio e la lettura del nuovo firmware.")
                        .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                Button("Prima installazione di Keyglow…") {showsProvisioning=true}
                    .buttonStyle(StudioButton()).disabled(model.isBusy)
            }.controlSize(.large)
            }
        }
    }

    private var firstInstallation:some View {
        VStack(alignment:.leading,spacing:22) {
            PanelTitle(title:"Prima installazione via USB",subtitle:"Prepara la tua Q6 Max ISO per usare colori e aggiornamenti via Bluetooth.")
            Text("Il firmware originale non riceve gli RGB Bluetooth di Keyglow. La prima installazione richiede USB/DFU e un loader personalizzato; questa pagina prepara il percorso, non esegue automaticamente il flash.")
                .font(.system(size:13)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            Divider()
            VStack(alignment:.leading,spacing:12) {
                Text("1. Leggi e salva la configurazione").font(.system(size:16,weight:.semibold))
                Text("Collega USB e seleziona Cable, senza entrare in DFU. Apri Connessione → Leggi configurazione, poi Profili → Salva una copia. Salvare una bozza non letta non conserva le impostazioni reali della tastiera.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                HStack(spacing:12) {
                    Button("Apri Connessione",action:onOpenUSB).buttonStyle(StudioButton(primary:true))
                    Button("Apri Profili",action:onOpenProfiles).buttonStyle(StudioButton())
                }
            }
            VStack(alignment:.leading,spacing:12) {
                Text("2. Prepara la chiave proprietario").font(.system(size:16,weight:.semibold))
                Text("La chiave autorizza gli aggiornamenti di questa tastiera. Se esiste già viene riutilizzata; il Portachiavi può chiederti conferma. Prepararla non installa firmware.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                Button("Prepara chiave proprietario") {model.prepareOwnerKey()}.buttonStyle(StudioButton()).disabled(model.isBusy)
                if let setup=model.provisioning {
                    detail("Impronta della chiave",firmwareHex(setup.keyID))
                    Button("Mostra file privato nel Finder") {NSWorkspace.shared.activateFileViewerSelecting([setup.slotURL])}.buttonStyle(StudioButton())
                    Text("Il file è privato e serve alla prima installazione USB. Non allegarlo a segnalazioni o repository.")
                        .font(.system(size:12)).foregroundColor(Studio.muted)
                }
                if model.isBusy {ProgressView().controlSize(.small)}
                if model.provisioning != nil || model.isBusy || model.phase == .failed {
                    Text(model.message).font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                }
            }
            VStack(alignment:.leading,spacing:12) {
                Text("3. Installa seguendo la guida").font(.system(size:16,weight:.semibold))
                Text("Usa solo loader e firmware preparati per Q6 Max ISO. La guida descrive backup completo, prima installazione USB/DFU e ripristino. Dopo l’installazione torna in BT e riapri Configura tastiera e accessi dal menu Keyglow.")
                    .foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                Button("Apri guida alla prima installazione") {
                    NSWorkspace.shared.open(URL(string:"https://github.com/FrancoisLampasona/keyglow-macos/blob/main/docs/firmware.md")!)
                }.buttonStyle(StudioButton())
            }
            Divider()
            Button("Keyglow è già installato · apri aggiornamenti Bluetooth") {showsProvisioning=false}
                .buttonStyle(StudioButton()).disabled(model.isBusy)
        }.font(.system(size:13)).controlSize(.large)
    }

    private func workflowStep(_ number:String,_ title:String,done:Bool) -> some View {
        HStack(spacing:7) {
            Group {if done {Image(systemName:"checkmark")} else {Text(number)}}
                .font(.system(size:11,weight:.semibold)).frame(width:24,height:24)
                .background(done ? Studio.accent.opacity(0.15) : Studio.rail).clipShape(Circle())
            Text(title).font(.system(size:12,weight:.medium))
        }.foregroundColor(done ? Studio.accent : Studio.muted).frame(maxWidth:.infinity,alignment:.leading)
    }
    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(name).foregroundColor(Studio.muted).frame(maxWidth: 180, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}
