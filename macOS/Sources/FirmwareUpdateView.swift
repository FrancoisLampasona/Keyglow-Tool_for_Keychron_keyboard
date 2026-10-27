// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit

struct FirmwareUpdateView: View {
    @ObservedObject var model: FirmwareUpdateModel
    @Binding var showsProvisioning:Bool
    @ObservedObject var installer:FirstInstallModel
    @State private var mouseOnlyConfirmed=false
    var body: some View {
        StudioSurface {
            if showsProvisioning { FirstInstallView(model:installer,onBluetooth:{showsProvisioning=false}) } else {
            VStack(alignment: .leading, spacing: 18) {
                if model.isBusy { transferNotice }
                Group {
                StudioAdaptiveStack(breakpoint: 1120, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        LLabel("Aggiornamento del controller", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 21, weight: .semibold))
                        LText("Via Bluetooth, dopo la prima configurazione USB del loader Keyglow.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                    if model.hasBundledFirmware {
                        LButton("Usa firmware incluso") { model.useBundledFirmware() }
                            .buttonStyle(StudioButton(primary:model.artifact == nil)).disabled(model.isBusy)
                    }
                    LButton("Scegli firmware…") { model.chooseFile() }
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
                        LText(rawName).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        HStack {
                            LTextField("Numero build della compilazione", text: $model.rawBuild)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                            LButton("Valida immagine") { model.validateRaw() }.buttonStyle(StudioButton())
                        }.disabled(model.isBusy)
                        LText("Usa la build dichiarata da chi ha compilato il file. I pacchetti .kgfw la includono già.")
                            .font(.system(size: 11)).foregroundColor(Studio.muted)
                    }
                }

                if let artifact = model.artifact {
                    VStack(alignment: .leading, spacing: 10) {
                        detail("File", artifact.fileName)
                        detail("Destinazione", "Q6 Max ISO · build \(artifact.manifest.build)")
                        detail("Dimensione", ByteCountFormatter.string(fromByteCount: Int64(artifact.image.count), countStyle: .file))
                        LDisclosureGroup("SHA-256 dell’immagine") {
                            LText(firmwareHex(artifact.manifest.sha256)).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                        }.font(.system(size: 12)).foregroundColor(Studio.muted)
                    }
                } else if model.pendingRawName == nil {
                    LText("Scegli un pacchetto .kgfw per Q6 Max ISO. Il file verrà controllato prima di aprire il collegamento.")
                        .font(.system(size: 13)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }

                if model.artifact != nil {
                    LPicker("Velocità di invio", selection: $model.transferPause) {
                        LText("Prudente · 80 ms").tag(0.08)
                        LText("Rapida · 40 ms").tag(0.04)
                        LText("Sperimentale · 20 ms").tag(0.02)
                    }.frame(maxWidth: 380).disabled(model.isBusy)
                    LText("Si applica anche alla verifica. Dopo un’interruzione puoi rallentare e rileggere la sessione prima di riprendere.")
                        .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }

                if let review = model.review {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        LLabel("Tastiera e chiave proprietario verificate", systemImage: "checkmark.shield")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(Studio.success)
                        detail("Build attuale", "\(review.controller.build)")
                        if let staging = review.staging {
                            detail("Sessione sulla tastiera", staging.summary)
                            detail("Build della sessione", "\(staging.manifest.build)")
                            detail("Blocchi salvati", "\(staging.savedChunks) di \(staging.chunkCount)")
                            LDisclosureGroup("Dettagli della sessione") {
                                VStack(alignment: .leading, spacing: 8) {
                                    detail("Preparata", "Sì")
                                    detail("Immagine verificata", staging.ready ? "Sì" : "No")
                                    detail("Installazione confermata", staging.committed ? "Sì" : "No")
                                    detail("Installata", staging.installed ? "Sì" : "No")
                                    LText(firmwareHex(staging.manifest.sha256))
                                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.padding(.top, 8)
                            }.font(.system(size: 12)).foregroundColor(Studio.muted)
                        } else {
                            detail("Sessione sulla tastiera", "Nessun trasferimento preparato")
                        }
                        LText("La verifica legge soltanto identità e sessione: non prepara né installa un aggiornamento.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if !review.isAlreadyInstalled {
                            detail("Da trasferire", review.hasReadyTarget && !model.replaceUncommitted ? "Nessun blocco: immagine già completa" : ByteCountFormatter.string(fromByteCount: Int64(review.plan.literalBytes), countStyle: .file))
                            if review.hasReadyTarget && !model.replaceUncommitted {
                                LText("La ripresa verifica di nuovo identità, autorizzazione salvata e immagine, poi completa l’installazione senza preparare nuovamente il trasferimento.")
                                    .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            detail("Riutilizzati sulla tastiera", ByteCountFormatter.string(fromByteCount: Int64(review.plan.copiedBytes), countStyle: .file))
                            if review.plan.baselineUse != .verified {
                                LText("La base locale non è verificata: verrà trasferita l’intera immagine.")
                                    .font(.system(size: 12)).foregroundColor(Studio.muted)
                            }
                            if review.hasReadyTarget && !model.replaceUncommitted {
                                detail("Operazione", "Verifica finale, installazione e lettura dopo il riavvio")
                            } else if let estimate = model.estimate { detail("Durata stimata", estimate) }
                            LText("Stima indicativa: interruzioni e riconnessione possono allungarla. A 20 ms sono state verificate letture e finalizzazione; un trasferimento completo senza interruzioni resta sperimentale.")
                                .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        if !review.isAlreadyInstalled {
                            LToggle("Ricomincia un trasferimento precedente non ancora installato", isOn: $model.replaceUncommitted)
                                .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isBusy)
                            LText("Lascia disattivato per riprendere i blocchi già salvati. Ricominciare elimina soltanto la sessione di aggiornamento non confermata.")
                                .font(.system(size: 11)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.review != nil || model.artifact != nil { Divider() }

                }.disabled(model.isBusy)
                if !model.isBusy, let progress = model.progress, progress.stage == .transferring {
                    ProgressView(value: Double(progress.completedBytes), total: Double(max(1, progress.totalBytes)))
                        .tint(Studio.accent).localizedAccessibilityLabel("Dati salvati sulla tastiera")
                    LText("\(progress.completedBytes) di \(progress.totalBytes) byte salvati")
                        .font(.system(size: 11)).monospacedDigit().foregroundColor(Studio.muted)
                }

                HStack(alignment: .top, spacing: 9) {
                    if model.phase == .complete { Image(systemName: "checkmark.circle.fill").foregroundColor(Studio.success) }
                    else if model.phase == .failed || model.phase == .paused { Image(systemName: "exclamationmark.circle").foregroundColor(Studio.accent) }
                    LText(model.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)

                if model.canStart {
                    LToggle("Sono pronto: userò solo il mouse fino alla fine",isOn:$mouseOnlyConfirmed).toggleStyle(.checkbox)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    if model.isBusy {
                        if model.canCancel { LButton("Interrompi") { model.cancel() }.buttonStyle(StudioButton()) }
                    } else {
                        if model.artifact != nil {
                        LButton(model.review == nil ? "Verifica tastiera" : "Verifica di nuovo") { model.verifyKeyboard() }
                            .buttonStyle(StudioButton(primary:model.review == nil)).disabled(model.artifact == nil || (model.cooldownUntil.map { context.date < $0 } ?? false))
                        }
                        if let review=model.review, !review.isAlreadyInstalled {
                        LButton(model.review?.hasReadyTarget == true && !model.replaceUncommitted ? "Completa installazione" : "Avvia aggiornamento") { model.start() }
                            .buttonStyle(StudioButton(primary: true)).disabled(!model.canStart || !mouseOnlyConfirmed)
                        }
                    }
                }
                if let until = model.cooldownUntil, context.date < until, !model.isBusy {
                    LText("Nuova lettura disponibile tra \(max(1, Int(ceil(until.timeIntervalSince(context.date))))) s, dopo la scadenza della risposta precedente.")
                        .font(.system(size: 11)).foregroundColor(Studio.muted)
                }
                }
                }
                if model.canStart || model.isBusy {
                    LText("Usa solo il mouse durante verifica e aggiornamento. Tasti e manopola interrompono il trasferimento; puoi poi verificare di nuovo e riprendere i blocchi già salvati. La fine sarà confermata dopo il riavvio.")
                        .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                LButton("Prima installazione di Keyglow…") {showsProvisioning=true}
                    .buttonStyle(StudioButton()).disabled(model.isBusy)
            }.controlSize(.large).onChange(of:model.phase) { _ in mouseOnlyConfirmed=false }
            }
        }
    }

    private var transferNotice:some View {
        VStack(alignment:.leading,spacing:12) {
            LLabel(model.progress?.stage == .keyAccess ? "Conferma nel Portachiavi" : "Aggiornamento in corso · usa solo il mouse",systemImage:model.progress?.stage == .keyAccess ? "lock.shield":"computermouse")
                .font(.system(size:18,weight:.semibold))
            if let progress=model.progress,progress.stage == .transferring {
                ProgressView(value:Double(progress.completedBytes),total:Double(max(1,progress.totalBytes))).tint(Studio.accent)
                LText("\(Int(Double(progress.completedBytes)/Double(max(1,progress.totalBytes))*100))% · \(ByteCountFormatter.string(fromByteCount:Int64(progress.completedBytes),countStyle:.file)) di \(ByteCountFormatter.string(fromByteCount:Int64(progress.totalBytes),countStyle:.file)) salvati sulla tastiera")
                    .font(.system(size:12)).monospacedDigit().foregroundColor(Studio.muted)
            } else {ProgressView().controlSize(.small)}
            LText(model.progress?.stage == .keyAccess ? "Puoi usare la tastiera per la password solo nella finestra di macOS. Dopo la conferma torna a usare solo il mouse." : "Non toccare tasti o manopola e non cambiare collegamento. Puoi interrompere: i blocchi già verificati restano salvati per la ripresa.")
                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            if model.canCancel {LButton("Interrompi trasferimento") {model.cancel()}.buttonStyle(StudioButton())}
        }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius:12))
    }

    private func workflowStep(_ number:String,_ title:String,done:Bool) -> some View {
        HStack(spacing:7) {
            Group {if done {Image(systemName:"checkmark")} else {LText(number)}}
                .font(.system(size:11,weight:.semibold)).frame(width:24,height:24)
                .background(done ? Studio.accent.opacity(0.15) : Studio.rail).clipShape(Circle())
            LText(title).font(.system(size:12,weight:.medium))
        }.foregroundColor(done ? Studio.accent : Studio.muted).frame(maxWidth:.infinity,alignment:.leading)
    }
    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            LText(name).foregroundColor(Studio.muted).frame(maxWidth: 180, alignment: .leading)
            LText(value).frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}
