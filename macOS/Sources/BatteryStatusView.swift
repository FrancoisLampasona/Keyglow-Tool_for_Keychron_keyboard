// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import CoreBluetooth

/// Presentation only. The app owns monitoring even while this view is not visible.
struct BatteryStatusView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var monitor: KeyboardStatusMonitor
    @State private var showingDetails = false

    init(model: StudioModel) {
        self.model=model; self.monitor=model.batteryMonitor
    }
    private var reading: BatteryReading? { monitor.reading }
    private var current: Bool {
        reading?.isFresh(at:monitor.now) == true && !monitor.failed && monitor.context.connected
            && monitor.authorization == .allowedAlways
    }
    private var title: String {
        if let reading { return "\(reading.percent)%\(current ? "" : " · precedente")" }
        return monitor.isReading ? "Lettura…" : "Batteria —"
    }
    private var detail: String {
        if !monitor.context.connected { return "La percentuale si legge quando la Q6 Max è collegata in Bluetooth. In modalità Cable non è disponibile." }
        if model.busy { return "Lettura in pausa durante l’operazione. Riprende automaticamente al termine." }
        if model.section == 7 { return "Lettura in pausa nella pagina Firmware. Riprende quando torni alle altre pagine." }
        if monitor.authorization == .denied || monitor.authorization == .restricted { return "Consenti Bluetooth a Keyglow nelle impostazioni macOS per leggere la batteria." }
        if monitor.authorization == .notDetermined { return "Leggi la batteria per autorizzare l’accesso Bluetooth. È distinto da Monitoraggio input." }
        if monitor.isReading { return "Lettura della batteria dalla Q6 Max…" }
        if monitor.failed { return monitor.message }
        if let reading, current { return reading.isLow ? "Batteria in esaurimento. Collega il cavo per ricaricarla." : "Livello comunicato dalla tastiera via Bluetooth." }
        if reading != nil { return "Questa è l’ultima lettura disponibile. Aggiorna per conoscere il livello attuale." }
        return "La percentuale si aggiorna anche mentre usi altre app. Lascia Keyglow aperta e la tastiera in Bluetooth."
    }
    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing:8) {
                Image(systemName:reading?.symbol ?? "battery.0percent").font(.system(size:16))
                LText(title).font(.system(size:12,weight:.medium)).monospacedDigit()
                Spacer(minLength:0)
                Image(systemName:"chevron.right").font(.system(size:9,weight:.semibold)).accessibilityHidden(true)
            }.foregroundColor(current && reading?.isLow == true ? Color(hex:0xF1BD79) : Studio.muted)
                .padding(.horizontal,8).frame(minHeight:36)
                .background(Studio.panel).clipShape(RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())
        }.buttonStyle(.plain).localizedAccessibilityLabel("Batteria tastiera, \(title)")
            .localizedHelp(detail)
            .popover(isPresented:$showingDetails,arrowEdge:.trailing) {
                VStack(alignment:.leading,spacing:14) {
                    LText("Batteria della Q6 Max").font(.system(size:17,weight:.semibold))
                    if let reading {
                        LLabel("\(reading.percent)%\(current ? "" : " · ultima lettura")",systemImage:reading.symbol)
                            .font(.system(size:20,weight:.medium)).monospacedDigit()
                        LText("Letta alle \(L10n.date(reading.date))")
                            .font(.system(size:11)).foregroundColor(Studio.muted)
                    }
                    LText(detail).font(.system(size:13)).fixedSize(horizontal:false,vertical:true)
                    if monitor.authorization == .denied || monitor.authorization == .restricted {
                        LButton("Apri impostazioni Bluetooth") {
                            model.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
                        }.buttonStyle(StudioButton())
                    } else {
                        LButton(monitor.isReading ? "Lettura in corso…" : reading == nil ? "Leggi batteria" : "Aggiorna batteria") { monitor.refresh() }
                            .buttonStyle(StudioButton()).disabled(!monitor.context.connected || monitor.context.paused || monitor.isReading)
                    }
                    LText("Aggiornamento ogni minuto, anche con Keyglow in background o ridotta. Si ferma durante le operazioni e la sospensione del Mac. Lo stato di ricarica non è disponibile.")
                        .font(.system(size:11)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                }.padding(20).frame(width:310).foregroundColor(Studio.text).background(Studio.panel)
            }
    }
}
