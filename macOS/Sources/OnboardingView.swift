import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onContinue: () -> Void
    let onLater: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    introduction
                    permissionCard
                    applicationDetails
                }.padding(32)
            }
            Divider()
            HStack {
                Button("Più tardi", action: onLater)
                    .buttonStyle(StudioButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continua", action: onContinue)
                    .buttonStyle(StudioButton(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }.padding(.horizontal, 32).padding(.vertical, 20)
        }
        .frame(width: 620, height: 650)
        .background(Studio.background).foregroundColor(Studio.text)
        .font(.system(size: 13)).tint(Studio.accent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 30, weight: .light)).foregroundColor(Studio.accent)
                .padding(.bottom, 4).accessibilityHidden(true)
            Text("Benvenuto in \(model.appName)")
                .font(.system(size: 29, weight: .semibold)).tracking(-0.5)
            Text("Prepariamo l’accesso alla tastiera. La conferma resta nelle tue mani.")
                .font(.system(size: 14)).foregroundColor(Studio.muted)
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised").font(.system(size: 21)).foregroundColor(Studio.accent)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Monitoraggio input").font(.system(size: 17, weight: .semibold))
                    Label(statusTitle, systemImage: model.permission == .granted ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(model.permission == .granted ? Studio.success : Studio.muted)
                }
                Spacer(minLength: 0)
            }
            Text("macOS richiede questo accesso per comunicare con la tastiera tramite HID. \(model.appName) non registra la digitazione in background.")
                .foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)

            if model.permission == .granted {
                Text("Accesso consentito da macOS. Puoi continuare nell’app.")
                    .foregroundColor(Studio.success).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("L’app avvia la richiesta di accesso automaticamente. In Privacy e sicurezza → Monitoraggio input, abilita \(model.appName). Se non compare, aggiungi l’app con il pulsante +.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if model.permission == .unknown {
                    Button("Richiedi accesso") { model.requestInputMonitoring() }
                        .buttonStyle(StudioButton(primary: true)).disabled(model.isRequesting)
                } else if model.permission != .granted {
                    Button("Apri Impostazioni") { model.openPrivacySettings() }
                        .buttonStyle(StudioButton(primary: true))
                }
                Button("Ricontrolla") { model.refresh() }.buttonStyle(StudioButton())
                if model.permission == .unknown {
                    Button("Impostazioni") { model.openPrivacySettings() }.buttonStyle(StudioButton())
                }
            }
            if !model.message.isEmpty {
                Text(model.message).font(.system(size: 12)).foregroundColor(Studio.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel(model.message)
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line.opacity(0.7), lineWidth: 1))
    }

    private var applicationDetails: some View {
        DisclosureGroup("Posizione dell’app e aggiornamenti", isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.appURL.path).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Mostra l’app nel Finder") { model.revealApplication() }
                    .buttonStyle(StudioButton())
                Text("Una build di sviluppo ricompilata può richiedere di autorizzare nuovamente l’app. Se l’accesso resta negato, rimuovi la vecchia voce da Monitoraggio input e aggiungi questa copia.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        }.foregroundColor(Studio.muted)
    }

    private var statusTitle: String {
        switch model.permission {
        case .granted: return "Consentito"
        case .denied: return "Da abilitare"
        case .unknown: return "Da autorizzare"
        case .unavailable: return "Stato non disponibile"
        }
    }
}
