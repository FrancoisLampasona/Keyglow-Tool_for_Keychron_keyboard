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
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scorciatoie sul Mac").font(.system(size: 20, weight: .semibold))
                        Text("Apri app e siti con un tasto dedicato. Keyglow deve restare aperta.")
                            .foregroundColor(Studio.muted).lineSpacing(4).frame(maxWidth:500,alignment:.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Avvio rapido attivo", isOn: Binding(get: { service.enabled }, set: { service.setEnabled($0) })).toggleStyle(.switch).fixedSize()
                }
                Label(service.message,systemImage:service.enabled ? "bolt.circle":"pause.circle").font(.system(size: 13)).foregroundColor(Studio.muted).lineSpacing(3).textSelection(.enabled)
                Divider()
                if service.rules.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 28, weight: .light)).foregroundColor(Studio.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ancora nessuna azione").font(.system(size: 15, weight: .semibold))
                            Text("Scegli un’app o un sito nel modulo qui sotto.").foregroundColor(Studio.muted).lineSpacing(4)
                        }
                    }.padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(service.rules) { rule in ruleRow(rule) }
                    }
                }
                editor
                DisclosureGroup("Collega un tasto alla tua azione") {
                    Text("In Mappa dei tasti assegna la stessa funzione F13–F20 scelta qui. Funziona anche via Bluetooth. Le scorciatoie partono solo quando abiliti Avvio rapido; F21–F24 non sono supportati su macOS.")
                        .padding(.top,8).lineSpacing(4).frame(maxWidth:680,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                }.font(.system(size:12)).foregroundColor(Studio.muted)
            }.padding(30).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Studio.background).font(.system(size: 13)).tint(Studio.accent)
    }

    private func ruleRow(_ rule: QuickLaunchRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 15) {
                Toggle("Abilita \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { service.setRuleEnabled(rule.id, $0) })).labelsHidden().toggleStyle(.checkbox)
                Image(systemName: rule.target == .application ? "app" : "globe").frame(width: 22).foregroundColor(Studio.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name).fontWeight(.medium)
                    Text(rule.destination).font(.system(size: 12)).foregroundColor(Studio.muted).lineLimit(1).truncationMode(.middle).help(rule.destination)
                }
                Spacer(minLength: 12)
                Text(rule.shortcut).font(.system(size: 13, weight: .medium, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
                Text(service.registeredIDs.contains(rule.id) ? "Attiva" : service.errors[rule.id] != nil ? "Da correggere" : "Inattiva").font(.system(size: 12)).foregroundColor(service.registeredIDs.contains(rule.id) || service.errors[rule.id] != nil ? Studio.accent : Studio.muted).frame(width: 82, alignment: .trailing)
                Button { draft = rule; editing = true; editorError = nil } label: { Image(systemName: "pencil").frame(width: 40, height: 40) }.buttonStyle(.borderless).help("Modifica \(rule.name)").accessibilityLabel("Modifica \(rule.name)")
                Button { service.remove(rule.id); if draft.id == rule.id { resetDraft() } } label: { Image(systemName: "trash").frame(width: 40, height: 40) }.buttonStyle(.borderless).help("Rimuovi \(rule.name)").accessibilityLabel("Rimuovi \(rule.name)")
            }
            if let error = service.errors[rule.id] { Text(error).font(.system(size: 12)).foregroundColor(Studio.accent).lineSpacing(3).padding(.leading, 36).fixedSize(horizontal: false, vertical: true) }
            Divider().padding(.top, 8)
        }.padding(.vertical, 9)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(editing ? "Modifica azione" : "Nuova azione").font(.system(size: 20, weight: .semibold))
                Spacer()
                if editing { Button("Nuova azione") { resetDraft() }.buttonStyle(.borderless) }
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nome").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    TextField("Per esempio: Browser", text: $draft.name).textFieldStyle(.roundedBorder)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tasto").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    Picker("Tasto", selection: $draft.functionKey) { ForEach(QuickLaunchService.supportedFunctionKeys, id: \.self) { Text("F\($0)").tag($0) } }.labelsHidden().frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Modificatori facoltativi").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    HStack(spacing: 10) {
                        modifier("⌘", "Command", .command)
                        modifier("⌥", "Option", .option)
                        modifier("⌃", "Control", .control)
                        modifier("⇧", "Shift", .shift)
                    }
                }
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apri").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    Picker("Tipo destinazione", selection: Binding(get: { draft.target }, set: { draft.target = $0; draft.destination = ""; editorError = nil })) { ForEach(QuickLaunchTarget.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(draft.target == .website ? "Indirizzo" : "Applicazione sul Mac").font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
                    if draft.target == .website {
                        TextField("https://example.com", text: $draft.destination).textFieldStyle(.roundedBorder).accessibilityLabel("Indirizzo del sito")
                    } else {
                        HStack {
                            Text(draft.destination.isEmpty ? "Nessuna app selezionata" : URL(fileURLWithPath: draft.destination).deletingPathExtension().lastPathComponent).foregroundColor(draft.destination.isEmpty ? Studio.muted : Studio.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Scegli app…") { chooseApplication() }.buttonStyle(StudioButton())
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let editorError { Label(editorError,systemImage:"exclamationmark.circle").foregroundColor(Studio.accent).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Toggle("Azione abilitata", isOn: $draft.enabled).toggleStyle(.checkbox)
                Spacer()
                Button(editing ? "Salva modifiche" : "Aggiungi azione") {
                    do { try service.save(draft); resetDraft() }
                    catch { editorError = error.localizedDescription }
                }.buttonStyle(StudioButton(primary:true))
            }
        }.controlSize(.large).padding(24).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:12))
    }

    private func modifier(_ symbol: String, _ name: String, _ modifier: QuickLaunchModifiers) -> some View {
        Toggle(symbol, isOn: Binding(get: { draft.modifiers.contains(modifier) }, set: { if $0 { draft.modifiers.insert(modifier) } else { draft.modifiers.remove(modifier) } })).toggleStyle(.checkbox).accessibilityLabel(name)
    }
    private func resetDraft() { draft = QuickLaunchRule(); editing = false; editorError = nil }
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Scegli l’app da aprire"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.destination = url.path
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = url.deletingPathExtension().lastPathComponent }
            editorError = nil
        }
    }
}
