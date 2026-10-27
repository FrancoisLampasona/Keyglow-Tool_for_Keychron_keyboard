import SwiftUI

struct LightingWorkspaceView:View {
    @ObservedObject var model:StudioModel
    @Environment(\.studioContentWidth) private var contentWidth
    @State private var previewExpanded = false
    private var hasSideInspector: Bool { contentWidth >= 1060 }
    var body:some View {
        Group {
            if hasSideInspector {
                HStack(alignment:.top,spacing:0) {
                    ScrollView { workspace.studioPage() }
                    Divider()
                    ColorInspectorView(model:model).frame(width:282)
                }
            } else {
                ScrollView { workspace.studioPage() }
            }
        }
    }
    private var workspace: some View {
        VStack(alignment:.leading,spacing:hasSideInspector ? 28:20) {
            if hasSideInspector || model.lightingTab == 1 || model.lightingTab == 2 {
                WorkspaceKeyboardHeader(model:model,selectionEnabled:model.lightingTab == 1 || model.lightingTab == 2)
            } else {
                LDisclosureGroup("Anteprima Q6 Max · ISO italiano",isExpanded:$previewExpanded) {
                    WorkspaceKeyboardHeader(model:model,selectionEnabled:false).padding(.top,14)
                }.font(.system(size:13,weight:.medium)).foregroundColor(Studio.muted)
            }
            LPicker("Tipo di illuminazione",selection:$model.lightingTab) {
                LText("Effetti").tag(0); LText("RGB per tasto").tag(1); LText("Mix RGB").tag(2); LText("Indicatori").tag(3)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
            if model.lightingTab==0 {
                effectPicker
                if hasSideInspector { livePreview }
            } else {
                LLabel("Questa sezione si applica via USB. Puoi prepararla nella bozza.", systemImage:"cable.connector")
                    .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            }
            if !hasSideInspector { ColorInspectorView(model:model,inline:true) }
            if model.lightingTab==0 {
                if !hasSideInspector { livePreview }
                effects
            }
            else if model.lightingTab==1 { perKey }
            else if model.lightingTab==2 { mix }
            else { indicators }
        }
    }
    private var effects:some View {
        VStack(alignment:.leading,spacing:18) {
            // The custom layout adapts columns without hiding native buttons from VoiceOver.
            StudioGrid(minimumCellWidth:160,cellHeight:56,spacing:8) {
                ForEach(RGBEffect.all.filter { $0.id < 23 }) { effect in
                    Button { model.workspace.lighting.effect=effect.id } label: {
                        HStack(spacing:10) {
                            Image(systemName:effect.symbol).font(.system(size:14)).frame(width:18)
                            LText(effect.name).font(.system(size:13,weight:model.workspace.lighting.effect==effect.id ? .medium:.regular))
                                .multilineTextAlignment(.leading).lineSpacing(2).fixedSize(horizontal:false,vertical:true)
                            Spacer(minLength:0)
                        }.padding(.horizontal,12).frame(maxWidth:.infinity).frame(height:56)
                            .foregroundColor(model.workspace.lighting.effect==effect.id ? Studio.accent:Studio.text)
                            .background(model.workspace.lighting.effect==effect.id ? Studio.accent.opacity(0.12):Color.white.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius:8))
                            .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(model.workspace.lighting.effect==effect.id ? Studio.accent.opacity(0.45):Color.clear,lineWidth:1))
                    }.buttonStyle(.plain).disabled(model.lightingControlsDisabled)
                        .accessibilityRepresentation { LButton(effect.name) { model.workspace.lighting.effect=effect.id }.buttonStyle(.plain).accessibilityAddTraits(model.workspace.lighting.effect==effect.id ? .isSelected:[]) }
                }
            }
        }
    }
    private var effectPicker: some View {
        HStack(spacing:16) {
            LText("Effetto").font(.system(size:18,weight:.semibold))
            Spacer()
            LPicker("Effetto RGB",selection:$model.workspace.lighting.effect) {
                if model.workspace.lighting.effect >= 23 { LText("Scegli un effetto").tag(model.workspace.lighting.effect) }
                ForEach(RGBEffect.all.filter { $0.id<23 }) { LText($0.name).tag($0.id) }
            }.labelsHidden().controlSize(.large).frame(width:230).disabled(model.lightingControlsDisabled)
        }
    }
    private var livePreview: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:12) {
                Image(systemName:"antenna.radiowaves.left.and.right").foregroundColor(Studio.accent)
                VStack(alignment:.leading,spacing:4) {
                    LText("Anteprima sulla tastiera").font(.system(size:13,weight:.semibold))
                    LText(model.liveRGBEnabled ? "Le modifiche vengono inviate automaticamente via Bluetooth." : "Attivala per inviare colori ed effetti mentre li scegli.")
                        .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
                LToggle("Anteprima sulla tastiera",isOn:Binding(get:{model.liveRGBEnabled},set:{model.setLiveRGBEnabled($0)}))
                    .labelsHidden().toggleStyle(.switch).disabled(!model.liveRGBEnabled && !model.canEnableLiveRGB)
            }
            if !model.canEnableLiveRGB && !model.liveRGBEnabled {
                LText(model.liveRGBUnavailableReason).font(.system(size:12)).foregroundColor(Studio.muted)
                    .fixedSize(horizontal:false,vertical:true)
            }
            LDisclosureGroup("Invio e salvataggio") {
                VStack(alignment:.leading,spacing:12) {
                    LText("L’anteprima rapida è sperimentale. Gli invii vengono raggruppati: continua a regolare, verrà inviato l’ultimo stato. Evita Caps Lock e Num Lock durante l’invio. Il canale non conferma la ricezione: controlla il risultato sulla Q6 Max.")
                    LText("Con il salvataggio attivo, il colore finale viene conservato dopo una pausa. L’apertura dell’app e la navigazione non inviano colori.")
                }.font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3).padding(.top,10)
                    .fixedSize(horizontal:false,vertical:true)
            }.font(.system(size:12)).foregroundColor(Studio.muted)
        }.padding(16).background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:12))
    }
    private var perKey:some View {
        VStack(alignment:.leading,spacing:20) {
            modeActivation(effect:23, title:"Usa RGB per tasto")
            HStack {
                PanelTitle(title:"Colore per tasto",subtitle:"Seleziona i tasti, scegli un colore e applicalo alla selezione.")
                Spacer()
                LMenu("Azioni RGB") {
                    LButton("Colora selezione") { model.paintSelectedKeys() }.disabled(model.selectedKeys.isEmpty)
                    LButton("Seleziona tutti") { model.selectedKeys=Set(model.definition.keys.filter { $0.ledIndex != nil }.map(\.id)) }
                    LButton("Spegni tutti") { model.workspace.lighting.perKey=Dictionary(uniqueKeysWithValues:model.definition.keys.filter { $0.ledIndex != nil }.map { ($0.id,"000000") }) }
                }.controlSize(.large).frame(width:120)
            }
            HStack {
                LButton("Colora selezione") { model.paintSelectedKeys() }.buttonStyle(StudioButton(primary:true)).disabled(model.selectedKeys.isEmpty).accessibilityRepresentation { LButton("Colora selezione") { model.paintSelectedKeys() }.disabled(model.selectedKeys.isEmpty) }
                LButton("Seleziona tutti") { model.selectedKeys=Set(model.definition.keys.filter { $0.ledIndex != nil }.map(\.id)) }.buttonStyle(StudioButton()).accessibilityRepresentation { LButton("Seleziona tutti") { model.selectedKeys=Set(model.definition.keys.filter { $0.ledIndex != nil }.map(\.id)) } }
                LButton("Spegni tutti") { model.workspace.lighting.perKey=Dictionary(uniqueKeysWithValues:model.definition.keys.filter { $0.ledIndex != nil }.map { ($0.id,"000000") }) }.buttonStyle(StudioButton()).accessibilityRepresentation { LButton("Spegni tutti") { model.workspace.lighting.perKey=Dictionary(uniqueKeysWithValues:model.definition.keys.filter { $0.ledIndex != nil }.map { ($0.id,"000000") }) } }
            }
            LPicker("Comportamento",selection:$model.workspace.lighting.perKeyMode) {
                LText("Statico").tag(0);LText("Respiro").tag(1);LText("Reattivo semplice").tag(2);LText("Reattivo ampio").tag(3);LText("Splash").tag(4)
            }.controlSize(.large).frame(maxWidth:360)
            LText(model.usbSnapshot?.customRGB != nil ? "\(model.workspace.lighting.perKey.count) colori nella bozza · RGB per tasto disponibile" : "Modifica locale. Leggi la tastiera per verificare il supporto RGB per tasto.")
                .font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3)
        }
    }
    private var mix:some View {
        VStack(alignment:.leading,spacing:20) {
            modeActivation(effect:24, title:"Usa Mix RGB")
            HStack { PanelTitle(title:"Zone e sequenze",subtitle:"Raggruppa i tasti e combina effetti e colori."); Spacer(); LButton("Aggiungi zona") { model.addMixRegion() }.buttonStyle(StudioButton()).disabled(model.workspace.lighting.mix.count >= (model.usbSnapshot?.customRGB?.effects.count ?? 16)) }
            if model.workspace.lighting.mix.isEmpty { CapabilityNote(text:"Crea la prima zona, poi seleziona i tasti da includere.") }
            else {
                LPicker("Zona",selection:$model.selectedMixLayer) { ForEach(model.workspace.lighting.mix.indices,id:\.self) { Text(verbatim: model.workspace.lighting.mix[$0].name).tag($0) } }.controlSize(.large).frame(maxWidth:300)
                if model.workspace.lighting.mix.indices.contains(model.selectedMixLayer) {
                    VStack(alignment:.leading,spacing:12) {
                        HStack(spacing:12) {
                            LTextField("Nome zona",text:$model.workspace.lighting.mix[model.selectedMixLayer].name).textFieldStyle(.roundedBorder).controlSize(.large)
                            Button { model.workspace.lighting.mix.remove(at:model.selectedMixLayer); model.selectedMixLayer=max(0,model.selectedMixLayer-1) } label: { Image(systemName:"trash").frame(width:40,height:40) }.buttonStyle(.plain).foregroundColor(Studio.muted).localizedHelp("Rimuovi zona").localizedAccessibilityLabel("Rimuovi zona")
                        }
                        HStack {
                            LText("\(model.workspace.lighting.mix[model.selectedMixLayer].keys.count) tasti nella zona").font(.system(size:12)).monospacedDigit().foregroundColor(Studio.muted)
                            Spacer()
                            LButton("Assegna selezione") { model.assignSelectedToMix() }.buttonStyle(StudioButton()).disabled(model.selectedKeys.isEmpty)
                        }
                    }
                    VStack(spacing:8) {
                        ForEach(model.workspace.lighting.mix[model.selectedMixLayer].sequence.indices,id:\.self) { index in mixStep(index) }
                    }
                    LButton("Aggiungi passaggio") { model.workspace.lighting.mix[model.selectedMixLayer].sequence.append(MixEffectDraft(hex:model.hex)) }.buttonStyle(StudioButton()).disabled(model.workspace.lighting.mix[model.selectedMixLayer].sequence.count >= mixStepLimit)
                }
            }
            LDisclosureGroup("Come vengono applicate le zone") {
                LText(model.usbSnapshot?.customRGB == nil ? "Mix RGB richiede un firmware compatibile. Puoi preparare la bozza senza collegamento. I tasti non assegnati usano la prima zona." : "Zone e passaggi rispettano le capacità lette dalla tastiera. I tasti non assegnati usano la prima zona.")
                    .padding(.top,6).fixedSize(horizontal:false,vertical:true).lineSpacing(3)
            }.font(.system(size:12)).foregroundColor(Studio.muted)
        }
    }
    private func modeActivation(effect:Int, title:String) -> some View {
        HStack(spacing:16) {
            LText(model.workspace.lighting.effect == effect ? "Modalità selezionata nella bozza" : "Aprire questa sezione non cambia l’effetto attuale.")
                .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
            LButton(title) { model.workspace.lighting.effect=effect }.buttonStyle(StudioButton())
                .disabled(model.workspace.lighting.effect == effect || model.busy)
        }
    }
    private var mixStepLimit:Int {
        guard let effects=model.usbSnapshot?.customRGB?.effects, effects.indices.contains(model.selectedMixLayer) else { return 32 }
        return effects[model.selectedMixLayer].count
    }
    private func mixStep(_ index:Int)->some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                LText("Passaggio \(index+1)").font(.system(size:12,weight:.medium)).monospacedDigit().foregroundColor(Studio.muted)
                Spacer()
                Button { model.workspace.lighting.mix[model.selectedMixLayer].sequence.remove(at:index) } label: {
                    Image(systemName:"minus.circle").frame(width:32,height:32)
                }.buttonStyle(.plain).foregroundColor(Studio.muted).localizedHelp("Rimuovi passaggio").localizedAccessibilityLabel("Rimuovi passaggio \(index+1)")
            }
            HStack(alignment:.top,spacing:14) {
                VStack(alignment:.leading,spacing:6) {
                    LText("Effetto").font(.system(size:11)).foregroundColor(Studio.muted)
                    LPicker("Effetto",selection:$model.workspace.lighting.mix[model.selectedMixLayer].sequence[index].effect) {
                        ForEach(RGBEffect.all.filter { $0.id<23 }) { LText($0.name).tag($0.id) }
                    }.labelsHidden()
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:6) {
                    LText("Colore HEX").font(.system(size:11)).foregroundColor(Studio.muted)
                    LTextField("HEX",text:$model.workspace.lighting.mix[model.selectedMixLayer].sequence[index].hex)
                        .textFieldStyle(.roundedBorder).font(.system(size:12,design:.monospaced)).localizedAccessibilityLabel("Colore HEX del passaggio")
                }.frame(width:90)
                VStack(alignment:.leading,spacing:6) {
                    LText("Velocità").font(.system(size:11)).foregroundColor(Studio.muted)
                    LTextField("Velocità",value:$model.workspace.lighting.mix[model.selectedMixLayer].sequence[index].speed,format:.number)
                        .textFieldStyle(.roundedBorder).localizedAccessibilityLabel("Velocità del passaggio, da 0 a 255").localizedHelp("Velocità: 0–255")
                }.frame(width:72)
                VStack(alignment:.leading,spacing:6) {
                    LText("Durata · ms").font(.system(size:11)).foregroundColor(Studio.muted)
                    LTextField("Durata",value:$model.workspace.lighting.mix[model.selectedMixLayer].sequence[index].durationMilliseconds,format:.number)
                        .textFieldStyle(.roundedBorder).localizedAccessibilityLabel("Durata in millisecondi")
                }.frame(width:94)
            }.controlSize(.large)
        }.padding(14).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:10))
    }
    private var indicators:some View {
        VStack(alignment:.leading,spacing:20) {
            PanelTitle(title:"Indicatori di blocco",subtitle:"Scegli i blocchi da segnalare e il loro colore.")
            VStack(alignment:.leading,spacing:0) {
            ForEach(Array([(0,"Num Lock"),(1,"Caps Lock"),(2,"Scroll Lock"),(3,"Compose"),(4,"Kana")].enumerated()),id:\.offset) { _, item in
                LToggle(item.1,isOn:Binding(get:{ model.workspace.lighting.indicatorsDisabled & (1<<item.0)==0 },set:{ enabled in
                    if enabled { model.workspace.lighting.indicatorsDisabled &= ~(1<<item.0) } else { model.workspace.lighting.indicatorsDisabled |= 1<<item.0 }
                })).toggleStyle(.checkbox).frame(minHeight:38).disabled(model.usbSnapshot?.customRGB.map { $0.supportedIndicatorsMask & UInt8(1<<item.0)==0 } ?? true)
            }
            }
            Divider()
            HStack { LText("Colore HEX");LTextField("57D9C1",text:$model.workspace.lighting.indicatorHex).textFieldStyle(.roundedBorder).controlSize(.large).font(.system(size:13,design:.monospaced)).frame(width:120); LButton("Usa colore attuale") { model.workspace.lighting.indicatorHex=model.hex }.buttonStyle(StudioButton()) }
            LText("Sono disponibili solo gli indicatori supportati dal firmware letto.").font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3)
        }
    }
}

struct ColorInspectorView:View {
    @ObservedObject var model:StudioModel
    var inline=false
    var body:some View {
        Group {
            if inline {
                HStack(alignment:.top,spacing:28) {
                    colorControls.frame(maxWidth:.infinity)
                    adjustmentControls.frame(maxWidth:.infinity)
                }.padding(20)
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:24) {
                        colorControls
                        Divider()
                        adjustmentControls
                    }.padding(24)
                }
            }
        }.disabled(model.lightingControlsDisabled)
            .background(Studio.panel.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius:inline ? 12:0))
    }
    private var colorControls:some View {
                VStack(alignment:.leading,spacing:14) {
                HStack { LText("Colore").font(.system(size:20,weight:.semibold));Spacer();ColorPicker(selection:Binding(get:{model.color},set:{model.setColor($0)}),supportsOpacity:false) { LText("Selettore colore") }.labelsHidden() }
                colorField.frame(height:inline ? 100:160)
                ZStack {
                    LinearGradient(colors:(0...6).map { Color(hue:Double($0)/6,saturation:0.85,brightness:1) },startPoint:.leading,endPoint:.trailing).frame(height:8).clipShape(Capsule())
                    Slider(value:Binding(get:{model.hue},set:{model.hue=$0;model.colorChanged()}),in:0...1).tint(.clear).localizedAccessibilityLabel("Tonalità")
                }
                HStack(spacing:8) {
                    LText("HEX").font(.system(size:12)).foregroundColor(Studio.muted)
                    LTextField("57D9C1",text:$model.hexInput).textFieldStyle(.plain).font(.system(size:13,design:.monospaced)).onSubmit{model.applyHex(model.hexInput)}.localizedAccessibilityLabel("Colore esadecimale")
                    Button {model.applyHex(model.hexInput)} label:{Image(systemName:"checkmark").frame(width:32,height:40)}.buttonStyle(.plain).localizedAccessibilityLabel("Applica codice HEX")
                }.padding(.leading,12).padding(.trailing,4).background(Studio.rail).clipShape(RoundedRectangle(cornerRadius:8))
                if model.hexError { LText("Usa 6 caratteri: 0–9 e A–F.").font(.system(size:12)).foregroundColor(Studio.accent) }
                HStack(spacing:7) {
                    ForEach(["57D9C1","FFB65B","719CFF","FA81AA","D5EAF0"],id:\.self) { hex in
                        Button {model.applyHex(hex)} label:{
                            Circle().fill(Color(hex:UInt32(hex,radix:16)!)).frame(width:27,height:27)
                                .overlay(Circle().strokeBorder(Studio.text.opacity(model.hex.uppercased()==hex ? 1:0),lineWidth:2).frame(width:34,height:34))
                                .frame(width:36,height:40)
                        }.buttonStyle(.plain).localizedHelp("#\(hex)").localizedAccessibilityLabel("Colore #\(hex)").accessibilityAddTraits(model.hex.uppercased()==hex ? .isSelected:[])
                    }
                }
                }
    }
    private var adjustmentControls:some View {
        VStack(alignment:.leading,spacing:24) {
                VStack(alignment:.leading,spacing:8) {
                    HStack {LText("Luminosità").fontWeight(.medium);Spacer();LText("\(Int(model.brightness))%").monospacedDigit().foregroundColor(Studio.muted)}
                    Slider(value:$model.brightness,in:0...100,step:1).localizedAccessibilityLabel("Luminosità")
                }
                VStack(alignment:.leading,spacing:8) {
                    HStack {LText("Velocità").fontWeight(.medium);Spacer();LText("\(Int(model.workspace.lighting.speed))").monospacedDigit().foregroundColor(Studio.muted)}
                    Slider(value:$model.workspace.lighting.speed,in:0...255,step:1).disabled(!model.currentEffect.usesSpeed).localizedAccessibilityLabel("Velocità effetto")
                    if !model.currentEffect.usesSpeed {
                        LText("Disponibile per gli effetti animati.").font(.system(size:12)).foregroundColor(Studio.muted).lineSpacing(3)
                    }
                }
                if model.lightingTab == 0 && !model.currentEffect.usesColor {
                    LText(model.workspace.lighting.effect == 0 ? "Luci spente. Scegli un effetto per riaccenderle." : "Questo effetto usa colori propri. Il colore scelto resta disponibile per gli altri effetti.")
                        .font(.system(size:12)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                }
                if model.lightingTab == 0 && model.directBluetooth { BluetoothSaveChoice(model:model) }
                if !model.accessVerified && model.selectedUSBID == nil {
                    LButton("Configura collegamento") {model.section=6}.buttonStyle(StudioButton())
                }
        }
    }
    private var colorField:some View {
        GeometryReader { g in
            ZStack {
                Color(hue:model.hue,saturation:1,brightness:1)
                LinearGradient(colors:[.white,.white.opacity(0)],startPoint:.leading,endPoint:.trailing)
                LinearGradient(colors:[.clear,.black],startPoint:.top,endPoint:.bottom)
                Circle().strokeBorder(.white,lineWidth:2).background(Circle().fill(model.color)).frame(width:14,height:14).shadow(color:.black.opacity(0.4),radius:2,y:1)
                    .position(x:max(7,min(g.size.width-7,model.saturation*g.size.width)),y:max(7,min(g.size.height-7,(1-model.value)*g.size.height)))
            }.clipShape(RoundedRectangle(cornerRadius:10)).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { event in
                model.saturation=max(0,min(1,event.location.x/g.size.width));model.value=max(0,min(1,1-event.location.y/g.size.height));model.colorChanged()
            })
        }.accessibilityHidden(true)
    }
}
