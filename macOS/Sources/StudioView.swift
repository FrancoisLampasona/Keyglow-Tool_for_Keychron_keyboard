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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:12,weight:.semibold)).padding(.horizontal,15).frame(height:40)
            .foregroundColor(primary && enabled ? Studio.rail : enabled ? Studio.text : Studio.muted.opacity(0.65))
            .background(primary && enabled ? Studio.accent : .white.opacity(enabled ? (configuration.isPressed || hover ? 0.13:0.07):0.035))
            .clipShape(RoundedRectangle(cornerRadius:7)).contentShape(RoundedRectangle(cornerRadius:7))
            .opacity(configuration.isPressed ? 0.8:1).onHover { hover=$0 }
            .animation(reduceMotion ? nil : .easeOut(duration:0.14),value:hover)
    }
}
struct StudioView:View {
    @ObservedObject var model:StudioModel
    @StateObject private var firmwareUpdater = FirmwareUpdateModel()
    @StateObject private var firstInstaller = FirstInstallModel()
    private let names=["Illuminazione","Mappa dei tasti","Macro","Test tastiera","Profili","Energia","Connessione","Firmware","Avvio rapido"]
    private let symbols=["sun.max","keyboard","command","checkmark.circle","square.stack","battery.75percent","antenna.radiowaves.left.and.right","cpu","bolt"]
    var body:some View {
        GeometryReader { geometry in
        let railWidth: CGFloat = geometry.size.width < 1100 ? 180 : 208
        HStack(spacing:0) {
            sidebar(compact:geometry.size.height < 760).frame(width:railWidth).disabled(model.busy && !model.transmitting)
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
                    case 7: FirmwareWorkspaceView(model:model, updater:firmwareUpdater,installer:firstInstaller)
                    default: QuickLaunchView()
                    }
                // Firmware keeps Interrompi available; lighting may queue the
                // latest preview while an earlier RGB command finishes.
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                    .disabled(model.busy && model.section != 7 && !(model.section == 0 && model.transmitting))
                if [0,1,2,5].contains(model.section) { footer }
            }
        }.environment(\.studioContentWidth, max(0, geometry.size.width - railWidth))
        }.background(Studio.background).foregroundColor(Studio.text).font(.system(size:13)).tint(Studio.accent).ignoresSafeArea()
            .onChange(of:model.section) { _ in model.stopCapture(); model.projectMessage="" }
    }
    private func sidebar(compact:Bool)->some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                if let url=Bundle.main.url(forResource:"TastieraIcon",withExtension:"png"),let icon=NSImage(contentsOf:url) { Image(nsImage:icon).resizable().frame(width:34,height:34).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true) }
                Text("Keyglow").font(.system(size:21,weight:.semibold))
            }.padding(.bottom,compact ? 16:24)
            ScrollView(.vertical) {
                VStack(spacing:4) {
                    ForEach(names.indices,id:\.self) { index in
                        if index == 3 || index == 6 { Divider().padding(.vertical,8) }
                        Button { model.section=index } label: {
                            Label(names[index], systemImage:symbols[index])
                                .labelStyle(StudioNavigationLabel())
                                .frame(maxWidth:.infinity, minHeight:40, alignment:.leading)
                                .padding(.horizontal,10).contentShape(Rectangle())
                        }.buttonStyle(StudioNavigationButton(selected:model.section == index))
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers:.command)
                            .help("\(names[index]) · ⌘\(index + 1)")
                            .accessibilityLabel(names[index])
                            .accessibilityAddTraits(model.section == index ? .isSelected:[])
                    }
                }
            }.scrollIndicators(.hidden)
            Spacer(minLength:compact ? 8:16)
            VStack(alignment:.leading,spacing:8) {
                if !compact { Image(systemName:"keyboard").font(.system(size:23,weight:.light)).foregroundColor(Studio.muted) }
                Text("Q6 Max · ISO IT").fontWeight(.semibold)
                Label(model.selectedUSBID != nil ? (model.usbSnapshot != nil ? "USB · letta" : "USB rilevata") : model.available ? "Bluetooth rilevata":"Non collegata",systemImage:model.selectedUSBID != nil ? "cable.connector":"circle.dotted").font(.system(size:11)).foregroundColor(model.usbSnapshot != nil ? Studio.success:Studio.muted)
                BatteryStatusView(model:model)
            }
            Divider().padding(.vertical,compact ? 10:18)
            HStack { Text("Studio tastiera"); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") }.font(.system(size:10)).foregroundColor(Studio.muted)
        }.padding(.horizontal,12).padding(.top,compact ? 36:44).padding(.bottom,compact ? 12:18).background(Studio.rail)
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                pageHeading
                Spacer(minLength: 12)
                pageStatus
            }
            VStack(alignment: .leading, spacing: 12) { pageHeading; pageStatus }
        }.frame(maxWidth: model.section >= 4 ? 1120 : .infinity, alignment: .leading)
            .padding(.horizontal,28).padding(.top,36).padding(.bottom,18)
            .frame(maxWidth:.infinity,alignment:.center)
    }
    private var pageHeading: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(names[model.section]).font(.system(size:28,weight:.semibold)).tracking(-0.4)
            Text(model.section==0 ? "La tua Q6 Max, nella sua luce." : model.section==1 ? "Ogni tasto, ogni livello. Il layout della tua ISO italiana." : model.section==2 ? "Sequenze precise, pronte da assegnare a un tasto." : model.section==3 ? "Verifica i tasti ricevuti in questa finestra." : model.section==4 ? "Le tue configurazioni, conservate sul Mac." : model.section==5 ? "Prontezza, autonomia e spegnimento delle luci." : model.section==6 ? "Dispositivo, accesso e collegamenti." : model.section==7 ? "Firmware, verifiche e aggiornamenti." : "Apri app e siti con una scorciatoia dedicata.")
                .font(.system(size:13)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
        }
    }
    private var pageStatus: some View {
        VStack(alignment:.trailing,spacing:5) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.system(size:12,weight:.medium)).foregroundColor(Studio.muted)
            if model.section == 0, let sent=model.lastBluetoothSend {
                Text("Ultimo invio · \(sent.formatted(date:.omitted,time:.shortened))")
                    .font(.system(size:11)).foregroundColor(Studio.muted)
            }
        }.fixedSize(horizontal:true,vertical:false)
    }
    private var statusTitle: String {
        if [3,4,8].contains(model.section) { return "Sul tuo Mac" }
        if model.selectedUSBID != nil { return model.usbSnapshot == nil ? "USB rilevata" : "USB · configurazione letta" }
        if [1,2,5].contains(model.section) { return "Bozza · applicazione via USB" }
        return model.available ? (model.accessVerified ? "Bluetooth · accesso pronto" : "Bluetooth · verifica accesso") : "Nessuna tastiera collegata"
    }
    private var statusSymbol: String {
        if [3,4,8].contains(model.section) { return "desktopcomputer" }
        if model.selectedUSBID != nil { return "cable.connector" }
        return [1,2,5].contains(model.section) ? "pencil" : "antenna.radiowaves.left.and.right"
    }
    private var footer: some View {
        VStack(spacing:0) {
            Divider()
            if model.transmitting { ProgressView(value:model.progress).progressViewStyle(.linear).frame(height:3) }
            else if model.busy { ProgressView().progressViewStyle(.linear).frame(height:3) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing:20) { footerStatus.frame(minWidth:220, maxWidth:.infinity, alignment:.leading); footerActions }
                VStack(alignment:.leading,spacing:12) { footerStatus; HStack { Spacer(minLength:0); footerActions } }
            }.padding(.horizontal,24).padding(.vertical,14)
        }.background(Studio.rail.opacity(0.8))
    }
    private var footerStatus: some View {
        VStack(alignment:.leading,spacing:5) {
            Text(model.busy ? "Operazione in corso…" : model.usbReady ? (model.hasLocalChanges ? "Bozza pronta da applicare via USB" : "Configurazione USB aggiornata") : (model.available && model.section == 0 && model.lightingTab == 0) ? "RGB via Bluetooth" : model.section == 8 ? "Scorciatoie sul Mac" : "Il progetto è salvato sul Mac")
                .font(.system(size:12,weight:.medium))
            Text(footerDetail).font(.system(size:11)).foregroundColor(Studio.muted).lineLimit(2).help(footerDetail)
        }
    }
    private var footerActions: some View {
        HStack(spacing:10) {
            Button { model.section=4 } label: { Label("Salva profilo…",systemImage:"square.and.arrow.down") }.buttonStyle(StudioButton()).disabled(model.busy || model.recording)
            if model.selectedUSBID != nil {
                Button("Leggi tastiera") { model.readUSB() }.buttonStyle(StudioButton()).disabled(model.busy)
                Button { model.applyUSB() } label: { Label("Applica via USB",systemImage:"arrow.up.right") }.buttonStyle(StudioButton(primary:true)).disabled(!model.usbReady || !model.hasLocalChanges)
            } else if model.available && model.section == 0 && model.lightingTab == 0 && model.ready {
                Button { model.send(off:false) } label: { Label(model.liveRGBEnabled ? "Invia ora" : model.bluetoothApplyTitle,systemImage:"arrow.up.right") }.buttonStyle(StudioButton(primary:true)).disabled(!model.bluetoothEffectSupported)
            } else if model.section != 6 && model.section != 8 {
                Button(model.available && model.section == 0 && model.lightingTab == 0 ? "Controlli Bluetooth" : "Collega via USB") { model.section=6 }.buttonStyle(StudioButton(primary:true)).disabled(model.busy)
            }
        }.fixedSize(horizontal:true,vertical:false)
    }
    private var footerDetail:String {
        if model.transmitting { return "Invio in corso: lascia terminare il ripristino degli indicatori." }
        if model.section == 0 && model.lightingTab != 0 { return "Queste modifiche si preparano nella bozza e si applicano via USB." }
        if model.section == 0 && model.liveRGBEnabled { return model.liveRGBStatus }
        if model.available && model.section == 0, model.lastBluetoothSend != nil { return model.message }
        if !model.projectMessage.isEmpty { return model.projectMessage }
        if model.usbSnapshot != nil { return model.usbMessage }
        if model.section == 8 { return "Le scorciatoie funzionano mentre Keyglow resta aperta." }
        if model.available && [0,6].contains(model.section) { return "Scegli gli RGB e inviali, oppure attiva l’anteprima automatica." }
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
    var selectionEnabled=true
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
            if selectionEnabled { HStack {
                Text(model.selectedKeys.isEmpty ? "Seleziona un tasto · ⌘ o ⇧ per selezionarne più di uno" : model.selectedKeys.count==1 ? "1 tasto selezionato" : "\(model.selectedKeys.count) tasti selezionati").font(.system(size:11)).foregroundColor(Studio.muted)
                Spacer()
                if !model.selectedKeys.isEmpty { Button("Deseleziona") { model.selectedKeys=[] }.buttonStyle(.plain).font(.system(size:11)).foregroundColor(Studio.accent) }
            } }
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

private struct StudioContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1000
}
extension EnvironmentValues {
    var studioContentWidth: CGFloat {
        get { self[StudioContentWidthKey.self] }
        set { self[StudioContentWidthKey.self] = newValue }
    }
}
private struct StudioPageModifier: ViewModifier {
    @Environment(\.studioContentWidth) private var width
    let maximum: CGFloat
    func body(content: Content) -> some View {
        content.frame(maxWidth:maximum,alignment:.leading)
            .padding(.horizontal,width < 800 ? 20:32).padding(.vertical,28)
            .frame(maxWidth:.infinity,alignment:.center)
    }
}
extension View {
    func studioPage(maxWidth: CGFloat = 1120) -> some View { modifier(StudioPageModifier(maximum:maxWidth)) }
}
struct StudioAdaptiveStack<Content: View>: View {
    @Environment(\.studioContentWidth) private var width
    var breakpoint: CGFloat = 820
    var spacing: CGFloat = 20
    @ViewBuilder let content: Content
    var body: some View {
        let layout = width >= breakpoint ? AnyLayout(HStackLayout(alignment:.top,spacing:spacing)) : AnyLayout(VStackLayout(alignment:.leading,spacing:spacing))
        layout { content }
    }
}
private struct StudioNavigationLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing:10) { configuration.icon.frame(width:18); configuration.title; Spacer(minLength:0) }
    }
}
private struct StudioNavigationButton: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:selected ? .semibold:.regular))
            .foregroundColor(selected ? Studio.text:Studio.muted)
            .background(selected ? Studio.accent.opacity(0.10) : Color.white.opacity(hovered || configuration.isPressed ? 0.055:0))
            .clipShape(RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())
            .opacity(enabled ? 1:0.45).onHover { hovered=$0 }
    }
}
