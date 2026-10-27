// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit

struct FirmwareUpdateView: View {
    @ObservedObject var model: FirmwareUpdateModel
    var body: some View {
        StudioSurface {
            VStack(alignment: .leading, spacing: 18) {
                StudioAdaptiveStack(breakpoint: 1120, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Aggiornamento del controller", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Via Bluetooth, dopo la prima configurazione USB del loader Keyglow.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                    if model.hasBundledFirmware {
                        Button("Usa firmware incluso") { model.useBundledFirmware() }
                            .buttonStyle(StudioButton()).disabled(model.isBusy)
                    }
                    Button("Scegli firmware…") { model.chooseFile() }
                        .buttonStyle(StudioButton()).disabled(model.isBusy)
                    }
                }

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
                        Text("Stima basata sulle prove brevi: può variare. Include verifiche, riconnessione e un margine; digitazione e interruzioni possono allungarla. 20 ms è stato provato su scambi brevi, non su un aggiornamento completo.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
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
                        Button("Verifica tastiera") { model.verifyKeyboard() }
                            .buttonStyle(StudioButton()).disabled(model.artifact == nil || (model.cooldownUntil.map { context.date < $0 } ?? false))
                        Button(model.review?.hasReadyTarget == true && !model.replaceUncommitted ? "Completa installazione" : "Avvia aggiornamento") { model.start() }
                            .buttonStyle(StudioButton(primary: true)).disabled(!model.canStart)
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
                DisclosureGroup("Prima configurazione USB") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("La prima installazione del loader collega questa tastiera a una chiave privata del Mac. Preparare la chiave non installa firmware e non modifica la tastiera.")
                            .font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Prepara chiave proprietario") { model.prepareOwnerKey() }
                            .buttonStyle(StudioButton()).disabled(model.isBusy)
                        if let setup = model.provisioning {
                            detail("Impronta della chiave", firmwareHex(setup.keyID))
                            Text(setup.slotURL.path).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Button("Mostra file privato nel Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([setup.slotURL])
                            }.buttonStyle(StudioButton())
                            Text("Il file è privato e serve alla prima installazione USB. Non allegarlo a segnalazioni o repository.")
                                .font(.system(size: 11)).foregroundColor(Studio.muted)
                        }
                    }.padding(.top, 10)
                }.font(.system(size: 12))
            }.controlSize(.large)
        }
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(name).foregroundColor(Studio.muted).frame(maxWidth: 180, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}
