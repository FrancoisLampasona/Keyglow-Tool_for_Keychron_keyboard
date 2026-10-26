import SwiftUI

struct KeymapWorkspaceView:View {
    @ObservedObject var model:StudioModel
    var body:some View {
        HStack(alignment:.top,spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:28) {
                    WorkspaceKeyboardHeader(model:model,assignments:true)
                    VStack(alignment:.leading,spacing:16) {
                    HStack(alignment:.firstTextBaseline) {
                        Text("Assegna un’azione").font(.system(size:20,weight:.semibold))
                        Spacer()
                        Text("\(model.visibleKeycodes.count) azioni").font(.system(size:12)).monospacedDigit().foregroundColor(Studio.muted)
                    }
                    HStack(spacing:12) {
                        HStack(spacing:8) {
                            Image(systemName:"magnifyingglass").foregroundColor(Studio.muted)
                            TextField("Cerca tasto, azione o codice",text:$model.keySearch).textFieldStyle(.plain).accessibilityLabel("Cerca un’azione")
                        }.padding(.horizontal,12).frame(height:40).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:8))
                        Picker("Categoria",selection:$model.keyCategory) { Text("Tutte le categorie").tag("Tutti"); ForEach(Array(Set(KeycodeCatalog.entries.map(\.category))).sorted(),id:\.self) { Text($0).tag($0) } }.labelsHidden().controlSize(.large).frame(width:175)
                    }
                    StudioGrid(minimumCellWidth:110,cellHeight:58,spacing:8) {
                        ForEach(model.visibleKeycodes) { item in
                            Button {
                                let code=item.code<=255 ? item.code | UInt16(model.mappingModifiers<<8):item.code
                                model.assignKeycode(code)
                            } label:{
                                VStack(spacing:5) {
                                    Text(item.shortName).font(.system(size:13,weight:.semibold)).lineLimit(1)
                                    Text(item.name).font(.system(size:12)).lineLimit(1).foregroundColor(Studio.muted)
                                }.padding(.horizontal,8).frame(maxWidth:.infinity).frame(height:58).background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8))
                            }.buttonStyle(.plain).disabled(model.selectedKeys.isEmpty || model.busy).help(item.name).accessibilityLabel(item.name)
                        }
                    }
                    if model.visibleKeycodes.isEmpty { CapabilityNote(text:"Nessuna azione trovata. Prova un altro nome o inserisci un codice QMK nell’inspector.") }
                    }
                }.padding(28)
            }
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    PanelTitle(title:model.selectedKey?.isEncoder == true ? "Manopola":"Assegnazione",subtitle:model.selectedKeys.isEmpty ? nil : "\(model.selectedKeys.count) selezionati · \(model.definition.layerNames[model.selectedLayer])")
                    if let key=model.selectedKey {
                        VStack(alignment:.leading,spacing:8) {
                            Text("Azione attuale").font(.system(size:12)).foregroundColor(Studio.muted)
                            Text(KeycodeCatalog.display(model.workspace.layers[model.selectedLayer][key.matrixIndex])).font(.system(size:20,weight:.semibold)).foregroundColor(Studio.accent)
                        }
                        Button(model.captureMapping ? "In attesa del tasto…":"Cattura un tasto") { model.startMappingCapture() }.buttonStyle(StudioButton()).disabled(model.captureMapping)
                        if model.captureMapping { Text("Premi un tasto. Esc annulla.").font(.system(size:12)).foregroundColor(Studio.accent) }
                    Divider()
                    VStack(alignment:.leading,spacing:14) {
                    Text("Modificatori").font(.system(size:13,weight:.semibold))
                    ForEach(Array([(1,"Control"),(2,"Shift"),(4,"Option / Alt"),(8,"Command / Win")].enumerated()),id:\.offset) { _, pair in
                        Toggle(pair.1,isOn:Binding(get:{model.mappingModifiers & pair.0 != 0},set:{if $0 {model.mappingModifiers |= pair.0}else{model.mappingModifiers &= ~pair.0}})).toggleStyle(.checkbox)
                    }
                    Text("Aggiungili all’azione che scegli dal catalogo.").font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3)
                    }
                    if model.selectedKey?.isEncoder == true { encoderControls }
                    Divider()
                    DisclosureGroup("Codice QMK") {
                        HStack(spacing:8) {
                            Text("0x").foregroundColor(Studio.muted)
                            TextField("0004",text:$model.rawKeycode).textFieldStyle(.roundedBorder).font(.system(size:13,design:.monospaced)).onSubmit{model.assignRawKeycode()}
                            Button("Assegna"){model.assignRawKeycode()}.buttonStyle(StudioButton()).disabled(model.selectedKeys.isEmpty)
                        }.padding(.top,10)
                    }.font(.system(size:13,weight:.medium))
                    Menu("Altre azioni") {
                        Button("Ripristina selezione") {model.resetSelectedKeys()}.disabled(model.selectedKeys.isEmpty)
                        Button("Scambia i due tasti") {
                            let keys=model.selectedKeys.compactMap{model.definition.key(id:$0)}
                            if keys.count==2 {model.workspace.layers[model.selectedLayer].swapAt(keys[0].matrixIndex,keys[1].matrixIndex)}
                        }.disabled(model.selectedKeys.count != 2)
                    }.controlSize(.large)
                    } else {
                        VStack(alignment:.leading,spacing:12) {
                            Image(systemName:"cursorarrow.click.2").font(.system(size:25,weight:.light)).foregroundColor(Studio.accent)
                            Text("Scegli un tasto").font(.system(size:15,weight:.semibold))
                            Text("Selezionalo sulla tastiera per modificarne l’azione. Tieni premuto ⌘ o ⇧ per selezionarne più di uno.")
                                .font(.system(size:13)).foregroundColor(Studio.muted).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                        }.padding(.vertical,8)
                    }
                    Divider()
                    DisclosureGroup("Come funzionano i livelli") {
                        Text("Mac e Windows seguono il selettore fisico della tastiera. Fn attiva il livello associato finché lo tieni premuto.").padding(.top,8).lineSpacing(3)
                    }.font(.system(size:12)).foregroundColor(Studio.muted)
                }.padding(24).disabled(model.busy)
            }.frame(width:282).background(Studio.panel.opacity(0.6))
        }
    }
    private var encoderControls:some View {
        VStack(alignment:.leading,spacing:12) {
            Divider();Text("Rotazione").fontWeight(.semibold)
            ForEach(0..<2,id:\.self) { direction in
                Picker(direction==0 ? "Antiorario":"Orario",selection:$model.workspace.encoders[model.selectedLayer][direction]) {
                    ForEach(KeycodeCatalog.entries) {Text($0.shortName).tag($0.code)}
                }
            }
            Text("Assegna la pressione dal catalogo, come un normale tasto.").font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3)
        }
    }
}

struct MacroWorkspaceView:View {
    @ObservedObject var model:StudioModel
    var body:some View {
        HStack(alignment:.top,spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:5) {
                    Text("Le tue macro").font(.system(size:13,weight:.semibold)).foregroundColor(Studio.muted).padding(.horizontal,12).padding(.bottom,12)
                    ForEach(model.workspace.macros.indices,id:\.self) { index in
                        Button {model.stopCapture();model.selectedMacro=index} label:{
                            HStack(spacing:12) {
                                Text("M\(index)").font(.system(size:12,weight:.medium,design:.monospaced)).foregroundColor(model.selectedMacro==index ? Studio.accent:Studio.muted).frame(width:28,alignment:.leading)
                                VStack(alignment:.leading,spacing:5){
                                    Text(model.workspace.macros[index].name).font(.system(size:13,weight:model.selectedMacro==index ? .semibold:.regular)).lineLimit(1)
                                    Text("\(model.workspace.macros[index].actions.count) eventi").font(.system(size:12)).foregroundColor(Studio.muted)
                                }
                                Spacer(minLength:0)
                            }.padding(12).background(model.selectedMacro==index ? Studio.accent.opacity(0.08):.clear).clipShape(RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.selectedMacro==index ? .isSelected:[])
                    }
                }.padding(18)
            }.frame(width:210)
            Divider()
            ScrollView {
                if model.workspace.macros.indices.contains(model.selectedMacro) {
                    VStack(alignment:.leading,spacing:24) {
                        HStack {
                            TextField("Nome macro",text:$model.workspace.macros[model.selectedMacro].name).textFieldStyle(.plain).font(.system(size:20,weight:.semibold))
                            Spacer()
                            Text("\(model.macroBytesUsed) / \(model.usbSnapshot.map{String($0.macroCapacity)} ?? "—") byte").font(.system(size:12)).monospacedDigit().foregroundColor(Studio.muted).help("Memoria usata da tutte le macro")
                        }
                        if model.workspace.macros[model.selectedMacro].rawBytes != nil {
                            CapabilityNote(text:"Questa macro contiene comandi non riconosciuti. Viene conservata nel profilo, ma non può essere modificata qui.")
                        } else {
                            HStack(spacing:9) {
                                Button {if model.recording{model.stopCapture()}else{model.startRecording()}} label:{
                                    Label(model.recording ? "Ferma":"Registra",systemImage:model.recording ? "stop.circle":"record.circle")
                                }.buttonStyle(StudioButton(primary:true))
                                Menu("Aggiungi evento") {ForEach(MacroActionKind.allCases,id:\.self){kind in Button(kind.title){model.addMacroAction(kind)}}}.controlSize(.large).frame(width:155).disabled(model.recording)
                                Spacer()
                                Menu("File macro") {
                                    Button("Importa macro Keyglow"){model.importMacro()}
                                    Button("Importa slot Launcher"){model.importLauncherMacros()}
                                    Button("Importa Launcher legacy · senza checksum"){model.importLauncherMacros(legacy:true)}
                                    Divider()
                                    Button("Esporta questa macro"){model.exportMacro()}
                                    Button("Esporta tutti gli slot Launcher"){model.exportLauncherMacros()}
                                }.controlSize(.large).frame(width:125).disabled(model.recording)
                            }
                            Text(model.recording ? "Registrazione in questa finestra · Esc per fermare" : "Quando è pronta, assegna M\(model.selectedMacro) a un tasto nella mappa.").font(.system(size:13)).foregroundColor(model.recording ? Studio.accent:Studio.muted).lineSpacing(3)
                            Divider()
                            if model.workspace.macros[model.selectedMacro].actions.isEmpty {
                                HStack(alignment:.top,spacing:18) {
                                    Image(systemName:"command").font(.system(size:30,weight:.light)).foregroundColor(Studio.accent)
                                    VStack(alignment:.leading,spacing:8){
                                        Text("Crea la prima sequenza").font(.system(size:20,weight:.semibold))
                                        Text("Premi Registra oppure aggiungi testo, tasti e attese. Gli eventi seguiranno l’ordine che scegli.")
                                            .font(.system(size:13)).foregroundColor(Studio.muted).lineSpacing(4).frame(maxWidth:480,alignment:.leading)
                                    }
                                }.padding(.vertical,32)
                            }
                            VStack(spacing:8) {
                                ForEach(model.workspace.macros[model.selectedMacro].actions.indices,id:\.self) { index in macroRow(index) }
                            }
                            DisclosureGroup("Testo e compatibilità") {
                                Text("Il testo usa ASCII e la mappatura del firmware. Per accenti e simboli italiani usa sequenze di tasti. Le macro vengono eseguite dalla tastiera dopo Applica.")
                                    .padding(.top,8).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                            }.font(.system(size:12)).foregroundColor(Studio.muted)
                        }
                    }.padding(28)
                }
            }
        }.disabled(model.busy)
    }
    private func macroRow(_ index:Int)->some View {
        let action=model.workspace.macros[model.selectedMacro].actions[index]
        return HStack(spacing:10) {
            Text(String(format:"%02d",index+1)).font(.system(size:12,design:.monospaced)).foregroundColor(Studio.muted).frame(width:25)
            Picker("Evento",selection:$model.workspace.macros[model.selectedMacro].actions[index].kind) {ForEach(MacroActionKind.allCases,id:\.self){Text($0.title).tag($0)}}.labelsHidden().frame(width:145)
            if action.kind == .text {TextField("Testo da scrivere",text:$model.workspace.macros[model.selectedMacro].actions[index].text).textFieldStyle(.roundedBorder)}
            else if action.kind == .delay {TextField("Attesa",value:$model.workspace.macros[model.selectedMacro].actions[index].milliseconds,format:.number).textFieldStyle(.roundedBorder).frame(width:90);Text("ms").foregroundColor(Studio.muted);Spacer()}
            else {Picker("Tasto",selection:$model.workspace.macros[model.selectedMacro].actions[index].keycode){ForEach(KeycodeCatalog.entries.filter{$0.code>0 && $0.code<=255}){Text($0.name).tag($0.code)}}.labelsHidden()}
            Button {model.moveMacroAction(index,by:-1)} label:{Image(systemName:"arrow.up").frame(width:32,height:40)}.buttonStyle(.plain).disabled(index==0).help("Sposta prima").accessibilityLabel("Sposta evento \(index+1) prima")
            Button {model.moveMacroAction(index,by:1)} label:{Image(systemName:"arrow.down").frame(width:32,height:40)}.buttonStyle(.plain).disabled(index==model.workspace.macros[model.selectedMacro].actions.count-1).help("Sposta dopo").accessibilityLabel("Sposta evento \(index+1) dopo")
            Button {model.workspace.macros[model.selectedMacro].actions.remove(at:index)} label:{Image(systemName:"trash").frame(width:32,height:40)}.buttonStyle(.plain).help("Rimuovi evento").accessibilityLabel("Rimuovi evento \(index+1)")
        }.controlSize(.large).padding(.horizontal,12).padding(.vertical,6).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:8)).disabled(model.recording)
    }
}

struct TestWorkspaceView:View {
    @ObservedObject var model:StudioModel
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                HStack {
                    PanelTitle(title:model.testing ? "Test in corso":"Controlla i tuoi tasti",subtitle:model.testing ? "Premi i tasti. Esc termina il test." : "Avvia il test e premi i tasti sulla tastiera.")
                    Spacer()
                    Button(model.testing ? "Ferma test":"Avvia test") {if model.testing{model.stopCapture()}else{model.startTest()}}.buttonStyle(StudioButton(primary:true))
                    Button("Azzera"){model.testedKeys=[]}.buttonStyle(StudioButton())
                }
                PhysicalKeyboardView(model:model,testMode:true)
                HStack(spacing:20) {
                    Label(model.lastTestKey,systemImage:"keyboard").font(.system(size:13,weight:.medium))
                    Spacer()
                    Text("\(model.testedKeys.count) tasti rilevati").font(.system(size:13)).monospacedDigit().foregroundColor(Studio.muted)
                }.padding(18).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:10))
                DisclosureGroup("Cosa rileva questo test") {
                    Text("Riceve solo i tasti diretti a questa finestra, senza registrazione globale. Non distingue fra più tastiere collegate. Alcune scorciatoie vengono intercettate da macOS e possono non comparire.")
                        .padding(.top,8).lineSpacing(4).frame(maxWidth:680,alignment:.leading)
                }.font(.system(size:12)).foregroundColor(Studio.muted)
                Divider()
                DisclosureGroup("Diagnostica della matrice USB") {
                    VStack(alignment:.leading,spacing:14) {
                        Text("Legge la matrice se il firmware lo supporta. Una risposta tutta a zero non conferma che i tasti siano rilasciati.")
                            .font(.system(size:13)).foregroundColor(Studio.muted).lineSpacing(4).frame(maxWidth:680,alignment:.leading)
                        Button("Leggi matrice Q6 Max"){model.readHardwareMatrix()}.buttonStyle(StudioButton()).disabled(!model.usbReady)
                    }.padding(.top,14)
                }.font(.system(size:15,weight:.semibold))
            }.padding(30)
        }
    }
}
