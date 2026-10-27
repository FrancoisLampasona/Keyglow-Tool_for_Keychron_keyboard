import SwiftUI

struct KeymapWorkspaceView:View {
    @ObservedObject var model:StudioModel
    @Environment(\.studioContentWidth) private var contentWidth
    private var hasSideInspector:Bool { contentWidth >= 1060 }
    var body:some View {
        Group {
            if hasSideInspector {
                HStack(alignment:.top,spacing:0) {
                    ScrollView { workspace.studioPage() }
                    Divider()
                    ScrollView { inspector.padding(24) }.frame(width:282).background(Studio.panel.opacity(0.6))
                }
            } else {
                ScrollView { workspace.studioPage() }
            }
        }
    }
    private var workspace:some View {
        VStack(alignment:.leading,spacing:28) {
            WorkspaceKeyboardHeader(model:model,assignments:true)
            if !hasSideInspector {
                inspector.padding(20).background(Studio.panel.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius:12))
            }
            catalog
        }
    }
    private var catalog:some View {
                    VStack(alignment:.leading,spacing:16) {
                    HStack(alignment:.firstTextBaseline) {
                        LText("Assegna un’azione").font(.system(size:20,weight:.semibold))
                        Spacer()
                        LText("\(model.visibleKeycodes.count) azioni").font(.system(size:12)).monospacedDigit().foregroundColor(Studio.muted)
                    }
                    HStack(spacing:12) {
                        HStack(spacing:8) {
                            Image(systemName:"magnifyingglass").foregroundColor(Studio.muted)
                            LTextField("Cerca tasto, azione o codice",text:$model.keySearch).textFieldStyle(.plain).localizedAccessibilityLabel("Cerca un’azione")
                        }.padding(.horizontal,12).frame(height:40).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:8))
                        LPicker("Categoria",selection:$model.keyCategory) { LText("Tutte le categorie").tag("Tutti"); ForEach(Array(Set(KeycodeCatalog.entries.map(\.category))).sorted(),id:\.self) { LText($0).tag($0) } }.labelsHidden().controlSize(.large).frame(width:175)
                    }
                    StudioGrid(minimumCellWidth:110,cellHeight:58,spacing:8) {
                        ForEach(model.visibleKeycodes) { item in
                            Button {
                                let code=item.code<=255 ? item.code | UInt16(model.mappingModifiers<<8):item.code
                                model.assignKeycode(code)
                            } label:{
                                VStack(spacing:5) {
                                    LText(item.shortName).font(.system(size:13,weight:.semibold)).lineLimit(1)
                                    LText(item.name).font(.system(size:12)).lineLimit(1).foregroundColor(Studio.muted)
                                }.padding(.horizontal,8).frame(maxWidth:.infinity).frame(height:58).background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).disabled(model.selectedKeys.isEmpty || model.busy).localizedHelp(item.name).localizedAccessibilityLabel(item.name)
                        }
                    }
                    if model.visibleKeycodes.isEmpty { CapabilityNote(text:"Nessuna azione trovata. Prova un altro nome o inserisci un codice QMK nell’inspector.") }
                    }
    }
    private var inspector:some View {
        VStack(alignment:.leading,spacing:20) {
            PanelTitle(title:model.selectedKey?.isEncoder == true ? "Manopola":"Assegnazione",subtitle:model.selectedKeys.isEmpty ? nil : "\(model.selectedKeys.count) selezionati · \(model.definition.layerNames[model.selectedLayer])")
            if let key=model.selectedKey {
                let layout=hasSideInspector ? AnyLayout(VStackLayout(alignment:.leading,spacing:24)):AnyLayout(HStackLayout(alignment:.top,spacing:28))
                layout {
                    VStack(alignment:.leading,spacing:14) {
                        VStack(alignment:.leading,spacing:8) {
                            LText("Azione attuale").font(.system(size:12)).foregroundColor(Studio.muted)
                            LText(KeycodeCatalog.display(model.workspace.layers[model.selectedLayer][key.matrixIndex]))
                                .font(.system(size:20,weight:.semibold)).foregroundColor(Studio.accent).fixedSize(horizontal:false,vertical:true)
                        }
                        LButton(model.captureMapping ? "In attesa del tasto…":"Cattura un tasto") { model.startMappingCapture() }
                            .buttonStyle(StudioButton()).disabled(model.captureMapping)
                        if model.captureMapping { LText("Premi un tasto. Esc annulla.").font(.system(size:12)).foregroundColor(Studio.accent) }
                        if model.selectedKey?.isEncoder == true { encoderControls }
                        LDisclosureGroup("Codice QMK") {
                            HStack(spacing:8) {
                                LText("0x").foregroundColor(Studio.muted)
                                LTextField("0004",text:$model.rawKeycode).textFieldStyle(.roundedBorder).font(.system(size:13,design:.monospaced)).onSubmit{model.assignRawKeycode()}
                                LButton("Assegna"){model.assignRawKeycode()}.buttonStyle(StudioButton()).disabled(model.selectedKeys.isEmpty)
                            }.padding(.top,10)
                        }.font(.system(size:13,weight:.medium))
                        LMenu("Altre azioni") {
                            LButton("Ripristina selezione") {model.resetSelectedKeys()}.disabled(model.selectedKeys.isEmpty)
                            LButton("Scambia i due tasti") {
                                let keys=model.selectedKeys.compactMap{model.definition.key(id:$0)}
                                if keys.count==2 {model.workspace.layers[model.selectedLayer].swapAt(keys[0].matrixIndex,keys[1].matrixIndex)}
                            }.disabled(model.selectedKeys.count != 2)
                        }.controlSize(.large)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    VStack(alignment:.leading,spacing:14) {
                        LText("Modificatori").font(.system(size:13,weight:.semibold))
                        ForEach(Array([(1,"Control"),(2,"Shift"),(4,"Option / Alt"),(8,"Command / Win")].enumerated()),id:\.offset) { _, pair in
                            LToggle(pair.1,isOn:Binding(get:{model.mappingModifiers & pair.0 != 0},set:{if $0 {model.mappingModifiers |= pair.0}else{model.mappingModifiers &= ~pair.0}})).toggleStyle(.checkbox)
                        }
                        LText("Aggiungili all’azione che scegli dal catalogo.").font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            } else {
                HStack(alignment:.top,spacing:14) {
                    Image(systemName:"cursorarrow.click.2").font(.system(size:25,weight:.light)).foregroundColor(Studio.accent)
                    VStack(alignment:.leading,spacing:8) {
                        LText("Scegli un tasto").font(.system(size:15,weight:.semibold))
                        LText("Selezionalo sulla tastiera per modificarne l’azione. Tieni premuto ⌘ o ⇧ per selezionarne più di uno.")
                            .font(.system(size:13)).foregroundColor(Studio.muted).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                    }
                }.padding(.vertical,4)
            }
            Divider()
            LDisclosureGroup("Come funzionano i livelli") {
                LText("Mac e Windows seguono il selettore fisico della tastiera. Fn attiva il livello associato finché lo tieni premuto.")
                    .padding(.top,8).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            }.font(.system(size:12)).foregroundColor(Studio.muted)
        }.disabled(model.busy)
    }
    private var encoderControls:some View {
        VStack(alignment:.leading,spacing:12) {
            Divider();LText("Rotazione").fontWeight(.semibold)
            ForEach(0..<2,id:\.self) { direction in
                LPicker(direction==0 ? "Antiorario":"Orario",selection:$model.workspace.encoders[model.selectedLayer][direction]) {
                    ForEach(KeycodeCatalog.entries) {LText($0.shortName).tag($0.code)}
                }
            }
            LText("Assegna la pressione dal catalogo, come un normale tasto.").font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3)
        }
    }
}

struct MacroWorkspaceView:View {
    @ObservedObject var model:StudioModel
    @Environment(\.studioContentWidth) private var contentWidth
    private var hasMacroSidebar:Bool { contentWidth >= 1060 }
    var body:some View {
        Group {
            if hasMacroSidebar {
                HStack(alignment:.top,spacing:0) {
                    ScrollView { macroList }.frame(width:210)
                    Divider()
                    ScrollView { macroEditor.studioPage(maxWidth:1000) }
                }
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:24) {
                        LPicker("Le tue macro",selection:Binding(get:{model.selectedMacro},set:{model.stopCapture();model.selectedMacro=$0})) {
                            ForEach(model.workspace.macros.indices,id:\.self) { index in
                                Text(verbatim: "M\(index) · \(model.workspace.macros[index].name)").tag(index)
                            }
                        }.controlSize(.large).frame(maxWidth:420,alignment:.leading)
                        macroEditor
                    }.studioPage(maxWidth:1000)
                }
            }
        }.disabled(model.busy)
    }
    private var macroList:some View {
                VStack(alignment:.leading,spacing:5) {
                    LText("Le tue macro").font(.system(size:13,weight:.semibold)).foregroundColor(Studio.muted).padding(.horizontal,12).padding(.bottom,12)
                    ForEach(model.workspace.macros.indices,id:\.self) { index in
                        Button {model.stopCapture();model.selectedMacro=index} label:{
                            HStack(spacing:12) {
                                LText("M\(index)").font(.system(size:12,weight:.medium,design:.monospaced)).foregroundColor(model.selectedMacro==index ? Studio.accent:Studio.muted).frame(width:28,alignment:.leading)
                                VStack(alignment:.leading,spacing:5){
                                    Text(verbatim: model.workspace.macros[index].name).font(.system(size:13,weight:model.selectedMacro==index ? .semibold:.regular)).lineLimit(1)
                                    LText("\(model.workspace.macros[index].actions.count) eventi").font(.system(size:12)).foregroundColor(Studio.muted)
                                }
                                Spacer(minLength:0)
                            }.padding(12).background(model.selectedMacro==index ? Studio.accent.opacity(0.08):.clear).clipShape(RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.selectedMacro==index ? .isSelected:[])
                    }
                }.padding(18)
    }
    @ViewBuilder private var macroEditor:some View {
                if model.workspace.macros.indices.contains(model.selectedMacro) {
                    VStack(alignment:.leading,spacing:24) {
                        HStack {
                            LTextField("Nome macro",text:$model.workspace.macros[model.selectedMacro].name).textFieldStyle(.plain).font(.system(size:20,weight:.semibold))
                            Spacer()
                            LText("\(model.macroBytesUsed) / \(model.usbSnapshot.map{String($0.macroCapacity)} ?? "—") byte").font(.system(size:12)).monospacedDigit().foregroundColor(Studio.muted).localizedHelp("Memoria usata da tutte le macro")
                        }
                        if model.workspace.macros[model.selectedMacro].rawBytes != nil {
                            CapabilityNote(text:"Questa macro contiene comandi non riconosciuti. Viene conservata nel profilo, ma non può essere modificata qui.")
                        } else {
                            HStack(spacing:9) {
                                Button {if model.recording{model.stopCapture()}else{model.startRecording()}} label:{
                                    LLabel(model.recording ? "Ferma":"Registra",systemImage:model.recording ? "stop.circle":"record.circle")
                                }.buttonStyle(StudioButton(primary:true))
                                LMenu("Aggiungi evento") {ForEach(MacroActionKind.allCases,id:\.self){kind in LButton(kind.title){model.addMacroAction(kind)}}}.controlSize(.large).frame(width:155).disabled(model.recording)
                                Spacer()
                                LMenu("File macro") {
                                    LButton("Importa macro Keyglow"){model.importMacro()}
                                    LButton("Importa slot Launcher"){model.importLauncherMacros()}
                                    LButton("Importa Launcher legacy · senza checksum"){model.importLauncherMacros(legacy:true)}
                                    Divider()
                                    LButton("Esporta questa macro"){model.exportMacro()}
                                    LButton("Esporta tutti gli slot Launcher"){model.exportLauncherMacros()}
                                }.controlSize(.large).frame(width:125).disabled(model.recording)
                            }
                            LText(model.recording ? "Registrazione in questa finestra · Esc per fermare" : "Quando è pronta, assegna M\(model.selectedMacro) a un tasto nella mappa.").font(.system(size:13)).foregroundColor(model.recording ? Studio.accent:Studio.muted).lineSpacing(3)
                            Divider()
                            if model.workspace.macros[model.selectedMacro].actions.isEmpty {
                                HStack(alignment:.top,spacing:18) {
                                    Image(systemName:"command").font(.system(size:30,weight:.light)).foregroundColor(Studio.accent)
                                    VStack(alignment:.leading,spacing:8){
                                        LText("Crea la prima sequenza").font(.system(size:20,weight:.semibold))
                                        LText("Premi Registra oppure aggiungi testo, tasti e attese. Gli eventi seguiranno l’ordine che scegli.")
                                            .font(.system(size:13)).foregroundColor(Studio.muted).lineSpacing(4).frame(maxWidth:480,alignment:.leading)
                                    }
                                }.padding(.vertical,32)
                            }
                            VStack(spacing:8) {
                                ForEach(model.workspace.macros[model.selectedMacro].actions.indices,id:\.self) { index in macroRow(index) }
                            }
                            LDisclosureGroup("Testo e compatibilità") {
                                LText("Il testo usa ASCII e la mappatura del firmware. Per accenti e simboli italiani usa sequenze di tasti. Le macro vengono eseguite dalla tastiera dopo Applica.")
                                    .padding(.top,8).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                            }.font(.system(size:12)).foregroundColor(Studio.muted)
                        }
                    }
                }
    }
    private func macroRow(_ index:Int)->some View {
        let action=model.workspace.macros[model.selectedMacro].actions[index]
        return VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                LText(String(format:"%02d",index+1)).font(.system(size:12,design:.monospaced)).foregroundColor(Studio.muted).frame(width:25)
                LPicker("Evento",selection:$model.workspace.macros[model.selectedMacro].actions[index].kind) {
                    ForEach(MacroActionKind.allCases,id:\.self){LText($0.title).tag($0)}
                }.labelsHidden().frame(maxWidth:180)
                Spacer(minLength:12)
                HStack(spacing:2) {
                    Button {model.moveMacroAction(index,by:-1)} label:{Image(systemName:"arrow.up").frame(width:36,height:36)}.buttonStyle(.plain).disabled(index==0).localizedHelp("Sposta prima").localizedAccessibilityLabel("Sposta evento \(index+1) prima")
                    Button {model.moveMacroAction(index,by:1)} label:{Image(systemName:"arrow.down").frame(width:36,height:36)}.buttonStyle(.plain).disabled(index==model.workspace.macros[model.selectedMacro].actions.count-1).localizedHelp("Sposta dopo").localizedAccessibilityLabel("Sposta evento \(index+1) dopo")
                    Button {model.workspace.macros[model.selectedMacro].actions.remove(at:index)} label:{Image(systemName:"trash").frame(width:36,height:36)}.buttonStyle(.plain).localizedHelp("Rimuovi evento").localizedAccessibilityLabel("Rimuovi evento \(index+1)")
                }.foregroundColor(Studio.muted)
            }
            if action.kind == .text {
                LTextField("Testo da scrivere",text:$model.workspace.macros[model.selectedMacro].actions[index].text).textFieldStyle(.roundedBorder)
                    .localizedAccessibilityLabel("Testo dell’evento \(index+1)")
            } else if action.kind == .delay {
                HStack(spacing:10) {
                    LTextField("Attesa",value:$model.workspace.macros[model.selectedMacro].actions[index].milliseconds,format:.number)
                        .textFieldStyle(.roundedBorder).frame(maxWidth:120).localizedAccessibilityLabel("Attesa in millisecondi")
                    LText("millisecondi").font(.system(size:12)).foregroundColor(Studio.muted)
                }
            } else {
                LPicker("Tasto",selection:$model.workspace.macros[model.selectedMacro].actions[index].keycode) {
                    ForEach(KeycodeCatalog.entries.filter{$0.code>0 && $0.code<=255}){LText($0.name).tag($0.code)}
                }
            }
        }.controlSize(.large).padding(14).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:10)).disabled(model.recording)
    }

}

struct TestWorkspaceView:View {
    @ObservedObject var model:StudioModel
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                StudioAdaptiveStack(breakpoint:820,spacing:16) {
                    PanelTitle(title:model.testing ? "Test in corso":"Controlla i tuoi tasti",subtitle:model.testing ? "Premi i tasti. Esc termina il test." : "Avvia il test e premi i tasti sulla tastiera.")
                        .frame(maxWidth:.infinity,alignment:.leading)
                    HStack(spacing:10) {
                    LButton(model.testing ? "Ferma test":"Avvia test") {if model.testing{model.stopCapture()}else{model.startTest()}}.buttonStyle(StudioButton(primary:true))
                    LButton("Azzera"){model.testedKeys=[]}.buttonStyle(StudioButton())
                    }
                }
                PhysicalKeyboardView(model:model,testMode:true)
                HStack(spacing:20) {
                    LLabel(model.lastTestKey,systemImage:"keyboard").font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    LText("\(model.testedKeys.count) tasti rilevati").font(.system(size:13)).monospacedDigit().foregroundColor(Studio.muted)
                }.padding(18).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:10))
                LDisclosureGroup("Cosa rileva questo test") {
                    LText("Riceve solo i tasti diretti a questa finestra, senza registrazione globale. Non distingue fra più tastiere collegate. Alcune scorciatoie vengono intercettate da macOS e possono non comparire.")
                        .padding(.top,8).lineSpacing(4).frame(maxWidth:680,alignment:.leading)
                }.font(.system(size:12)).foregroundColor(Studio.muted)
                Divider()
                LDisclosureGroup("Diagnostica della matrice USB") {
                    VStack(alignment:.leading,spacing:14) {
                        LText("Legge la matrice se il firmware lo supporta. Una risposta tutta a zero non conferma che i tasti siano rilasciati.")
                            .font(.system(size:13)).foregroundColor(Studio.muted).lineSpacing(4).frame(maxWidth:680,alignment:.leading)
                        LButton("Leggi matrice Q6 Max"){model.readHardwareMatrix()}.buttonStyle(StudioButton()).disabled(!model.usbReady)
                    }.padding(.top,14)
                }.font(.system(size:15,weight:.semibold))
            }.studioPage()
        }
    }
}
