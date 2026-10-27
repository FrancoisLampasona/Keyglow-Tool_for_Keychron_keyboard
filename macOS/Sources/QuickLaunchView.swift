import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickLaunchView: View {
    @ObservedObject private var service = QuickLaunchService.shared
    @State private var draft = QuickLaunchRule()
    @State private var editing = false
    @State private var editorError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StudioAdaptiveStack(breakpoint: 900, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        LText("Scorciatoie sul Mac").font(.system(size: 20, weight: .semibold))
                        LText("Apri app e siti con un tasto dedicato. Keyglow deve restare aperta.")
                            .foregroundColor(Studio.muted).lineSpacing(4).frame(maxWidth:500,alignment:.leading).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    LToggle("Avvio rapido attivo", isOn: Binding(get: { service.enabled }, set: { service.setEnabled($0) })).toggleStyle(.switch).fixedSize()
                }
                LLabel(service.message,systemImage:service.enabled ? "bolt.circle":"pause.circle").font(.system(size: 13)).foregroundColor(Studio.muted).lineSpacing(3).textSelection(.enabled)
                Divider()
                if service.rules.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 28, weight: .light)).foregroundColor(Studio.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            LText("Ancora nessuna azione").font(.system(size: 15, weight: .semibold))
                            LText("Scegli un’app o un sito nel modulo qui sotto.").foregroundColor(Studio.muted).lineSpacing(4)
                        }
                    }.padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(service.rules) { rule in ruleRow(rule) }
                    }
                }
                editor
                LDisclosureGroup("Collega un tasto alla tua azione") {
                    LText("In Mappa dei tasti assegna la stessa funzione F13–F20 scelta qui. Funziona anche via Bluetooth. Le scorciatoie partono solo quando abiliti Avvio rapido; F21–F24 non sono supportati su macOS.")
                        .padding(.top,8).lineSpacing(4).frame(maxWidth:680,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                }.font(.system(size:12)).foregroundColor(Studio.muted)
            }.studioPage(maxWidth: 1000)
        }.background(Studio.background).font(.system(size: 13)).tint(Studio.accent)
    }

    private func ruleRow(_ rule: QuickLaunchRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioAdaptiveStack(breakpoint: 940, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    LToggle("Abilita \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { service.setRuleEnabled(rule.id, $0) }))
                        .labelsHidden().toggleStyle(.checkbox).padding(.top, 3)
                    Image(systemName: rule.target == .application ? "app" : "globe").frame(width: 22).foregroundColor(Studio.muted).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: rule.name).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: rule.destination).font(.system(size: 12)).foregroundColor(Studio.muted)
                            .lineLimit(1).truncationMode(.middle).help(Text(verbatim: rule.destination))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    LText(rule.shortcut).font(.system(size: 13, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
                    LText(service.registeredIDs.contains(rule.id) ? "Attiva" : service.errors[rule.id] != nil ? "Da correggere" : "Inattiva")
                        .font(.system(size: 12)).foregroundColor(service.registeredIDs.contains(rule.id) || service.errors[rule.id] != nil ? Studio.accent : Studio.muted)
                    HStack(spacing: 2) {
                        Button { draft = rule; editing = true; editorError = nil } label: {
                            Image(systemName: "pencil").frame(width: 40, height: 40)
                        }.buttonStyle(.borderless).localizedHelp("Modifica \(rule.name)").localizedAccessibilityLabel("Modifica \(rule.name)")
                        Button { service.remove(rule.id); if draft.id == rule.id { resetDraft() } } label: {
                            Image(systemName: "trash").frame(width: 40, height: 40)
                        }.buttonStyle(.borderless).localizedHelp("Rimuovi \(rule.name)").localizedAccessibilityLabel("Rimuovi \(rule.name)")
                    }
                }.fixedSize(horizontal: true, vertical: false)
            }
            if let error = service.errors[rule.id] {
                LText(error).font(.system(size: 12)).foregroundColor(Studio.accent).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 8)
        }.padding(.vertical, 12)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                LText(editing ? "Modifica azione" : "Nuova azione").font(.system(size: 20, weight: .semibold))
                Spacer()
                if editing { LButton("Nuova azione") { resetDraft() }.buttonStyle(.borderless) }
            }
            StudioAdaptiveStack(breakpoint: 940, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    LText("Nome").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    LTextField("Per esempio: Browser", text: $draft.name).textFieldStyle(.roundedBorder)
                }.frame(maxWidth: .infinity)
                HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    LText("Tasto").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    LPicker("Tasto", selection: $draft.functionKey) { ForEach(QuickLaunchService.supportedFunctionKeys, id: \.self) { LText("F\($0)").tag($0) } }.labelsHidden().frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 8) {
                    LText("Modificatori facoltativi").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    HStack(spacing: 10) {
                        modifier("⌘", "Command", .command)
                        modifier("⌥", "Option", .option)
                        modifier("⌃", "Control", .control)
                        modifier("⇧", "Shift", .shift)
                    }
                }
                }
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    LText("Apri").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    LPicker("Tipo destinazione", selection: Binding(get: { draft.target }, set: { draft.target = $0; draft.destination = ""; editorError = nil })) { ForEach(QuickLaunchTarget.allCases, id: \.self) { LText($0.title).tag($0) } }.labelsHidden().frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    LText(draft.target == .website ? "Indirizzo" : "Applicazione sul Mac").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    if draft.target == .website {
                        LTextField("https://example.com", text: $draft.destination).textFieldStyle(.roundedBorder).localizedAccessibilityLabel("Indirizzo del sito")
                    } else {
                        HStack {
                            Text(verbatim: draft.destination.isEmpty ? L10n.string("Nessuna app selezionata") : URL(fileURLWithPath: draft.destination).deletingPathExtension().lastPathComponent).foregroundColor(draft.destination.isEmpty ? Studio.muted : Studio.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            LButton("Scegli app…") { chooseApplication() }.buttonStyle(StudioButton())
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let editorError { LLabel(editorError,systemImage:"exclamationmark.circle").foregroundColor(Studio.accent).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
            HStack {
                LToggle("Azione abilitata", isOn: $draft.enabled).toggleStyle(.checkbox)
                Spacer()
                LButton(editing ? "Salva modifiche" : "Aggiungi azione") {
                    do { try service.save(draft); resetDraft() }
                    catch { editorError = error.localizedDescription }
                }.buttonStyle(StudioButton(primary:true))
            }
        }.controlSize(.large).padding(24).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:12))
    }

    private func modifier(_ symbol: String, _ name: String, _ modifier: QuickLaunchModifiers) -> some View {
        LToggle(symbol, isOn: Binding(get: { draft.modifiers.contains(modifier) }, set: { if $0 { draft.modifiers.insert(modifier) } else { draft.modifiers.remove(modifier) } })).toggleStyle(.checkbox).localizedAccessibilityLabel(name)
    }
    private func resetDraft() { draft = QuickLaunchRule(); editing = false; editorError = nil }
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Scegli l’app da aprire")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.destination = url.path
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = url.deletingPathExtension().lastPathComponent }
            editorError = nil
        }
    }
}
