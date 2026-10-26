import AppKit
import SwiftUI

enum Studio {
    static let background=Color(hex:0x141A1C), rail=Color(hex:0x101517), panel=Color(hex:0x1B2427), line=Color(hex:0x354246)
    static let text=Color(hex:0xECF1EF), muted=Color(hex:0xA4B3B8), accent=Color(hex:0x80DCC7), success=Color(hex:0x80DCC7)
}
extension Color {
    init(hex:UInt32) { self.init(.sRGB,red:Double((hex>>16)&255)/255,green:Double((hex>>8)&255)/255,blue:Double(hex&255)/255,opacity:1) }
}
struct StudioButton:ButtonStyle {
    var primary=false
    @Environment(\.isEnabled) var enabled
    @State private var hover=false
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:12,weight:.semibold)).padding(.horizontal,15).frame(height:40)
            .foregroundColor(primary && enabled ? Studio.rail : enabled ? Studio.text : Studio.muted.opacity(0.65))
            .background(primary && enabled ? Studio.accent : .white.opacity(enabled ? (configuration.isPressed || hover ? 0.13:0.07):0.035))
            .clipShape(RoundedRectangle(cornerRadius:7)).contentShape(RoundedRectangle(cornerRadius:7))
            .opacity(configuration.isPressed ? 0.8:1).onHover { hover=$0 }
    }
}
struct StudioView:View {
    @ObservedObject var model:StudioModel
    private let names=["Illuminazione","Mappa dei tasti","Macro","Test tastiera","Profili","Energia","Connessione","Firmware","Avvio rapido"]
    private let symbols=["sun.max","keyboard","command","checkmark.circle","square.stack","battery.75percent","antenna.radiowaves.left.and.right","cpu","bolt"]
    var body:some View {
        HStack(spacing:0) {
            sidebar.frame(width:202)
            VStack(spacing:0) {
                header
                Divider()
                Group {
                    switch model.section {
                    case 0: LightingWorkspaceView(model:model)
                    case 1: KeymapWorkspaceView(model:model)
                    case 2: MacroWorkspaceView(model:model)
                    case 3: TestWorkspaceView(model:model)
                    case 4: ProfilesWorkspaceView(model:model)
                    case 5: AdvancedWorkspaceView(model:model)
                    case 6: ConnectionWorkspaceView(model:model)
                    case 7: FirmwareWorkspaceView(model:model)
                    default: QuickLaunchView()
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).disabled(model.busy)
                footer
            }
        }.background(Studio.background).foregroundColor(Studio.text).font(.system(size:13)).tint(Studio.accent).ignoresSafeArea()
            .onChange(of:model.section) { _ in model.stopCapture() }
            .onChange(of:model.brightness) { _ in model.syncLightDraft() }
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                if let url=Bundle.main.url(forResource:"TastieraIcon",withExtension:"png"),let icon=NSImage(contentsOf:url) { Image(nsImage:icon).resizable().frame(width:34,height:34).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true) }
                Text("Keyglow").font(.system(size:21,weight:.semibold))
            }.padding(.bottom,30)
            ForEach(names.indices,id:\.self) { index in
                Button { model.section=index } label: {
                    HStack(spacing:10) { Image(systemName:symbols[index]).frame(width:17); Text(names[index]).fontWeight(model.section==index ? .semibold:.regular); Spacer(minLength:0) }
                        .padding(.horizontal,10).frame(height:40).foregroundColor(model.section==index ? Studio.text:Studio.muted)
                        .background(model.section==index ? Color.white.opacity(0.07):.clear).clipShape(RoundedRectangle(cornerRadius:7))
                }.buttonStyle(.plain).padding(.bottom,3).accessibilityElement(children:.ignore).accessibilityLabel(names[index]).accessibilityAddTraits(.isButton).accessibilityAddTraits(model.section==index ? .isSelected:[])
            }
            Spacer(minLength:24)
            VStack(alignment:.leading,spacing:8) {
                Image(systemName:"keyboard").font(.system(size:23,weight:.light)).foregroundColor(Studio.muted)
                Text("Q6 Max · ISO IT").fontWeight(.semibold)
                Label(model.usbSnapshot != nil ? "USB · letta" : model.available ? "Bluetooth rilevata":"Non collegata",systemImage:model.usbSnapshot != nil ? "checkmark.circle":"circle.dotted").font(.system(size:11)).foregroundColor(model.usbSnapshot != nil ? Studio.success:Studio.muted)
            }
            Divider().padding(.vertical,18)
            HStack { Text("Studio tastiera"); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.7.0") }.font(.system(size:10)).foregroundColor(Studio.muted)
        }.padding(.horizontal,16).padding(.top,54).padding(.bottom,22).background(Studio.rail)
    }
    private var header:some View {
        HStack {
            VStack(alignment:.leading,spacing:6) {
                Text(names[model.section]).font(.system(size:30,weight:.semibold)).tracking(-0.4)
                Text(model.section==0 ? "La tua Q6 Max, nella sua luce." : model.section==1 ? "Ogni tasto, ogni livello. La disposizione della tua ISO italiana." : model.section==2 ? "Sequenze precise, pronte da assegnare a un tasto." : model.section==3 ? "Verifica i tasti ricevuti in questa finestra." : model.section==4 ? "Le tue configurazioni, conservate sul Mac." : model.section==5 ? "Prontezza, autonomia e spegnimento delle luci." : model.section==6 ? "Dispositivo, accesso e canali di configurazione." : model.section==7 ? "Identità e strumenti per preparare un aggiornamento." : "Apri app e siti con una scorciatoia dedicata.")
                    .font(.system(size:12)).foregroundColor(Studio.muted)
            }
            Spacer(minLength:12)
            VStack(alignment:.trailing,spacing:6) {
                Label(model.usbSnapshot != nil ? (model.hasLocalChanges ? "Bozza modificata" : "Configurazione letta") : model.available ? "Bluetooth rilevato" : "Progetto locale",
                      systemImage:model.usbSnapshot != nil && !model.hasLocalChanges ? "checkmark.circle" : model.available ? "antenna.radiowaves.left.and.right" : "pencil")
                    .foregroundColor(model.usbSnapshot != nil && !model.hasLocalChanges ? Studio.success : Studio.muted).font(.system(size:12,weight:.medium))
                if let sent=model.lastBluetoothSend {
                    Text("Ultimo invio RGB · \(sent.formatted(date:.omitted,time:.shortened))").font(.system(size:11)).foregroundColor(Studio.muted)
                } else {
                    Text(model.hasLocalChanges ? "Le modifiche restano nella bozza" : "Rilettura USB disponibile").font(.system(size:11)).foregroundColor(Studio.muted)
                }
            }
        }.padding(.horizontal,28).padding(.top,45).padding(.bottom,21)
    }
    private var footer:some View {
        VStack(spacing:0) {
            Divider()
            if model.busy { ProgressView().progressViewStyle(.linear).frame(height:3) }
            HStack(spacing:14) {
                VStack(alignment:.leading,spacing:5) {
                    Text(model.busy ? "Operazione in corso…" : model.usbReady ? (model.hasLocalChanges ? "Bozza pronta da applicare via USB" : "Configurazione USB aggiornata") : (model.available && [0,6].contains(model.section)) ? "RGB disponibile via Bluetooth" : model.section == 8 ? "Scorciatoie sul Mac" : "Il progetto è salvato sul Mac")
                        .font(.system(size:12,weight:.medium))
                    Text(footerDetail).font(.system(size:11)).foregroundColor(Studio.muted).lineLimit(2)
                }
                Spacer(minLength:4)
                Button { model.archiveCurrentProfile() } label: { Label("Salva profilo",systemImage:"square.and.arrow.down") }.buttonStyle(StudioButton()).disabled(model.busy || model.recording)
                if model.selectedUSBID != nil {
                    Button("Leggi tastiera") { model.readUSB() }.buttonStyle(StudioButton()).disabled(model.busy)
                    Button { model.applyUSB() } label: { Label("Applica via USB",systemImage:"arrow.up.right") }.buttonStyle(StudioButton(primary:true)).disabled(!model.usbReady || !model.hasLocalChanges)
                } else if model.available && model.section == 0 && model.ready {
                    Button { model.send(off: false) } label: { Label(model.bluetoothApplyTitle, systemImage: "arrow.up.right") }.buttonStyle(StudioButton(primary:true)).disabled(!model.bluetoothEffectSupported)
                } else if model.section != 6 && model.section != 8 {
                    Button(model.available && model.section == 0 ? "Controlli Bluetooth" : "Collega via USB") { model.section=6 }.buttonStyle(StudioButton(primary:true)).disabled(model.busy)
                }
            }.padding(.horizontal,28).padding(.vertical,17)
        }.background(Studio.rail.opacity(0.6))
    }
    private var footerDetail:String {
        if model.transmitting { return "Invio in corso: lascia terminare il ripristino degli indicatori." }
        if model.available && [0,6].contains(model.section), model.lastBluetoothSend != nil { return model.message }
        if !model.projectMessage.isEmpty { return model.projectMessage }
        if model.usbSnapshot != nil { return model.usbMessage }
        if model.section == 8 { return "Le scorciatoie funzionano mentre Keyglow resta aperta." }
        if model.available && [0,6].contains(model.section) { return "Colore ed effetti senza cavo. Mappa, macro e timer si salvano via USB." }
        if model.available { return "Le modifiche a questa configurazione si applicano via USB." }
        return "Puoi preparare colori e profili anche senza collegare la Q6 Max."
    }
}

/// A finite, adaptive grid keeps every control in the native accessibility tree.
struct StudioGrid:Layout {
    var minimumCellWidth:CGFloat
    var cellHeight:CGFloat
    var spacing:CGFloat
    private func resolvedWidth(_ width:CGFloat?)->CGFloat {
        guard let width, width.isFinite else { return minimumCellWidth*4+spacing*3 }
        return max(0,width)
    }
    private func columns(_ width:CGFloat)->Int { max(1,Int(min(1000,(resolvedWidth(width)+spacing)/(minimumCellWidth+spacing)))) }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize {
        let width=resolvedWidth(proposal.width)
        let rows=(subviews.count+columns(width)-1)/columns(width)
        return CGSize(width:width,height:CGFloat(rows)*cellHeight+CGFloat(max(0,rows-1))*spacing)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let count=columns(bounds.width), width=max(0,(resolvedWidth(bounds.width)-CGFloat(count-1)*spacing)/CGFloat(count))
        for (index,view) in subviews.enumerated() {
            view.place(at:CGPoint(x:bounds.minX+CGFloat(index%count)*(width+spacing),y:bounds.minY+CGFloat(index/count)*(cellHeight+spacing)),anchor:.topLeading,proposal:ProposedViewSize(width:width,height:cellHeight))
        }
    }
}

struct WorkspaceKeyboardHeader:View {
    @ObservedObject var model:StudioModel
    var assignments=false
    var body:some View {
        VStack(alignment:.leading,spacing:17) {
            HStack {
                Text("Keychron Q6 Max").font(.system(size:17,weight:.semibold))
                Text("ISO italiano").font(.system(size:11)).foregroundColor(Studio.muted)
                Spacer()
                if assignments {
                    Picker("Livello",selection:$model.selectedLayer) { ForEach(0..<4,id:\.self) { Text(model.definition.layerNames[$0]).tag($0) } }.labelsHidden().frame(width:160)
                } else { Label("Anteprima locale",systemImage:"eye").font(.system(size:11)).foregroundColor(Studio.muted) }
            }
            PhysicalKeyboardView(model:model,showsAssignments:assignments)
            HStack {
                Text(model.selectedKeys.isEmpty ? "Seleziona un tasto · ⌘ o ⇧ per selezionarne più di uno" : model.selectedKeys.count==1 ? "1 tasto selezionato" : "\(model.selectedKeys.count) tasti selezionati").font(.system(size:11)).foregroundColor(Studio.muted)
                Spacer()
                if !model.selectedKeys.isEmpty { Button("Deseleziona") { model.selectedKeys=[] }.buttonStyle(.plain).font(.system(size:11)).foregroundColor(Studio.accent) }
            }
        }
    }
}
struct PanelTitle:View {
    let title:String
    var subtitle:String?=nil
    var body:some View { VStack(alignment:.leading,spacing:6) { Text(title).font(.system(size:20,weight:.semibold)).tracking(-0.25); if let subtitle { Text(subtitle).foregroundColor(Studio.muted).font(.system(size:13)).lineSpacing(3).fixedSize(horizontal:false,vertical:true) } } }
}
struct CapabilityNote:View {
    var text:String
    var body:some View { Label { Text(text).fixedSize(horizontal:false,vertical:true) } icon:{ Image(systemName:"info.circle") }.font(.system(size:12)).foregroundColor(Studio.muted).padding(.vertical,12) }
}

struct StudioSurface<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 20) { content }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.panel).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
struct KeycapLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).frame(minWidth: 30, minHeight: 29)
            .background(Studio.line.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.09)))
    }
}
