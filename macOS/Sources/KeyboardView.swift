import SwiftUI
import AppKit

struct PhysicalKeyboardView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var language = AppLanguageStore.shared
    var showsAssignments = false
    var testMode = false
    var body: some View {
        GeometryReader { geometry in
            let u = geometry.size.width / 23.4
            ZStack(alignment:.topLeading) {
                RoundedRectangle(cornerRadius:u*0.18).fill(Color(hex:0x0A0E0F))
                    .overlay(RoundedRectangle(cornerRadius:u*0.18).stroke(Color(hex:0x3E4546),lineWidth:1))
                ForEach(model.definition.keys) { key in
                    let offset = min(0,key.secondary?.x ?? 0)
                    let width = max(key.width,(key.secondary?.width ?? key.width)+offset)-offset
                    let selected=model.selectedKeys.contains(key.id)
                    let held=model.pressedKeys.contains(key.id)
                    let tested=model.testedKeys.contains(key.id)
                    let fill=held ? Color(hex:0x57D9C1) : testMode && tested ? Color(hex:0x8BAF9D) : keyColor(key)
                    Button { model.selectKey(key) } label: {
                        ZStack {
                            KeycapShape(iso:key.secondary != nil,knob:key.isEncoder).fill(fill)
                            KeycapShape(iso:key.secondary != nil,knob:key.isEncoder)
                                .strokeBorderCompatible(selected ? Studio.accent : rgbEdge(key),width:selected ? 2 : 0.8)
                            if key.isEncoder {
                                Circle().fill(LinearGradient(colors:[Color(hex:0x333B3C),Color(hex:0x111617)],startPoint:.topLeading,endPoint:.bottomTrailing)).padding(3)
                                Capsule().fill(Color(hex:0x778585)).frame(width:2,height:u*0.17).offset(y:-u*0.27)
                                if selected { Circle().stroke(Studio.accent,lineWidth:2) }
                            } else {
                                VStack(spacing:max(1,u*0.05)) {
                                    if showsAssignments {
                                        LText(KeycodeCatalog.display(model.workspace.layers[model.selectedLayer][key.matrixIndex]))
                                            .font(.system(size:max(6.5,u*0.21),weight:.medium)).lineLimit(1).minimumScaleFactor(0.65).multilineTextAlignment(.center)
                                    } else {
                                        if let symbol=key.symbolName { Image(systemName:symbol).font(.system(size:max(7,u*0.22))) }
                                        if !key.secondaryLegend.isEmpty { Text(verbatim: key.secondaryLegend).font(.system(size:max(6,u*0.18))) }
                                        if !key.legend.isEmpty { Text(verbatim: key.legend).font(.system(size:max(6.5,u*0.23),weight:.medium)).lineLimit(1).minimumScaleFactor(0.65) }
                                    }
                                }.padding(3).offset(x:key.secondary == nil ? 0 : u*0.05)
                                    .foregroundColor(key.appearance == .light || held || (testMode && tested) ? Color(hex:0x242D2F) : Color(hex:0xE3E9E7))
                            }
                        }.contentShape(KeycapShape(iso:key.secondary != nil,knob:key.isEncoder))
                    }.buttonStyle(KeycapButtonStyle())
                        .frame(width:(width-0.08)*u,height:(key.height-0.08)*u)
                        .position(x:(key.x+offset+0.45+(width-0.08)/2)*u,y:(key.y+0.45+(key.height-0.08)/2)*u)
                        .localizedHelp(keyHelp(key))
                        .localizedAccessibilityLabel(keyHelp(key))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .disabled(model.busy || testMode)
                }
            }
        }.aspectRatio(23.4/7.15,contentMode:.fit)
            .shadow(color:.black.opacity(0.25),radius:12,x:0,y:10)
    }
    private func keyColor(_ key:PhysicalKey)->Color {
        switch key.appearance { case .light: Color(hex:0xD9DFDC); case .dark: Color(hex:0x2C3336); case .accent: Color(hex:0x238C9C); case .knob: Color(hex:0x434B4B) }
    }
    private func rgbEdge(_ key:PhysicalKey)->Color {
        if model.workspace.lighting.effect == 0 || key.ledIndex == nil { return Color.black.opacity(0.5) }
        if model.lightingTab == 1, let hex=model.workspace.lighting.perKey[key.id], let value=UInt32(hex,radix:16) { return Color(hex:value).opacity(0.85) }
        if model.lightingTab == 2, let group=model.workspace.lighting.mix.first(where: { $0.keys.contains(key.id) }), let hex=group.sequence.first?.hex, let value=UInt32(hex,radix:16) { return Color(hex:value) }
        return model.color.opacity(0.25+model.brightness/100*0.65)
    }
    private func keyHelp(_ key:PhysicalKey)->String {
        let name=key.isEncoder ? L10n.string("Manopola · pressione") : key.legend.isEmpty ? L10n.format("Tasto {0}", [key.id]) : key.legend
        return L10n.catalog.format("{0} · {1} · riga {2}, colonna {3}", arguments: [name, L10n.string(KeycodeCatalog.display(model.workspace.layers[model.selectedLayer][key.matrixIndex])), String(key.row), String(key.col)], language: language.language)
    }
}
private struct KeycapButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View { configuration.label.opacity(configuration.isPressed ? 0.8:1) }
}
private struct KeycapShape: Shape {
    let iso:Bool
    let knob:Bool
    func path(in rect:CGRect)->Path {
        if knob { return Path(ellipseIn:rect.insetBy(dx:1,dy:1)) }
        if !iso { return Path(roundedRect:rect,cornerRadius:3) }
        let step=rect.width/6, middle=rect.height/2
        var p=Path();p.move(to:CGPoint(x:rect.minX,y:rect.minY));p.addLine(to:CGPoint(x:rect.maxX,y:rect.minY));p.addLine(to:CGPoint(x:rect.maxX,y:rect.maxY));p.addLine(to:CGPoint(x:rect.minX+step,y:rect.maxY));p.addLine(to:CGPoint(x:rect.minX+step,y:rect.minY+middle));p.addLine(to:CGPoint(x:rect.minX,y:rect.minY+middle));p.closeSubpath();return p
    }
}
private extension Shape {
    func strokeBorderCompatible(_ color:Color,width:CGFloat)->some View { stroke(color,style:StrokeStyle(lineWidth:width,lineJoin:.round)) }
}
