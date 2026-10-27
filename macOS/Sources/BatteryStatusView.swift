// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import CoreBluetooth

/// One small, read-only session per minute while the app is in use. No scanning,
/// HID reports, Keychain access or automatic permission requests are involved.
struct BatteryStatusView: View {
    @ObservedObject var model: StudioModel
    @StateObject private var reader = BluetoothFirmwareInspector()
    @State private var reading: BatteryReading?
    @State private var lastAttempt: Date?
    @State private var failed = false
    @State private var showingDetails = false
    @State private var active = NSApp.isActive
    @State private var now = Date()
    @State private var authorization = CBCentralManager.authorization

    private var context: BatteryRefreshContext {
        BatteryRefreshContext(connected:model.available && model.selectedUSBID == nil, active:active,
                              paused:model.busy || model.section == 7)
    }
    private var current: Bool { reading?.isFresh(at:now) == true && !failed && context.connected }
    private var title: String {
        if let reading { return "\(reading.percent)%\(current ? "" : " · precedente")" }
        return reader.isRunning ? "Lettura…" : "Batteria —"
    }
    private var detail: String {
        if !context.connected { return "La percentuale si legge quando la Q6 Max è collegata in Bluetooth. In modalità Cable non è disponibile." }
        if model.busy { return "Lettura in pausa durante l’operazione. Riprende automaticamente al termine." }
        if model.section == 7 { return "Lettura in pausa nella pagina Firmware. Riprende quando torni alle altre pagine." }
        if authorization == .denied || authorization == .restricted { return "Consenti Bluetooth a Keyglow nelle impostazioni macOS per leggere la batteria." }
        if authorization == .notDetermined { return "Leggi la batteria per autorizzare l’accesso Bluetooth. È distinto da Monitoraggio input." }
        if reader.isRunning { return "Lettura della batteria dalla Q6 Max…" }
        if failed { return reader.message }
        if let reading, current { return reading.isLow ? "Batteria in esaurimento. Collega il cavo per ricaricarla." : "Livello comunicato dalla tastiera via Bluetooth." }
        if reading != nil { return "Questa è l’ultima lettura disponibile. Aggiorna per conoscere il livello attuale." }
        return "La percentuale viene letta automaticamente mentre usi Keyglow in Bluetooth."
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
                    if authorization == .denied || authorization == .restricted {
                        LButton("Apri impostazioni Bluetooth") {
                            model.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
                        }.buttonStyle(StudioButton())
                    } else {
                        LButton(reader.isRunning ? "Lettura in corso…" : reading == nil ? "Leggi batteria" : "Aggiorna batteria") { refresh() }
                            .buttonStyle(StudioButton()).disabled(!context.connected || context.paused || reader.isRunning)
                    }
                    LText("Aggiornamento ogni minuto quando l’app è attiva. Lo stato di ricarica non è esposto dalla tastiera.")
                        .font(.system(size:11)).foregroundColor(Studio.muted).fixedSize(horizontal:false,vertical:true)
                }.padding(20).frame(width:310).foregroundColor(Studio.text).background(Studio.panel)
            }
            .task(id:context) {
                if !context.canRead { reader.cancel() }
                if !context.connected { reading=nil; failed=false; lastAttempt=nil }
                while !Task.isCancelled {
                    now=Date(); active=NSApp.isActive; authorization=CBCentralManager.authorization
                    if context.shouldRefreshConnection {
                        // Public device metadata only; never opens HID or changes settings.
                        model.refreshConnectionMetadata()
                    }
                    if context.shouldRefresh(authorized:authorization == .allowedAlways,
                                             running:reader.isRunning,lastAttempt:lastAttempt,now:now) { refresh() }
                    do { try await Task.sleep(nanoseconds:5_000_000_000) } catch { return }
                }
            }
            .onReceive(reader.$inspection) { result in
                guard let result else { return }
                if let percent=result.batteryPercent { reading=BatteryReading(percent:percent,date:result.inspectedAt); failed=false }
            }
            .onChange(of:reader.isRunning) { running in
                if !running {
                    // A normal pause is not a failed read. Keep a fresh value and
                    // retry as soon as the app is eligible again, without a minute's delay.
                    if reader.wasCancelled { failed=false; lastAttempt=nil }
                    else { failed=reader.inspection?.batteryPercent == nil }
                    now=Date()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in active=true; now=Date(); authorization=CBCentralManager.authorization }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didResignActiveNotification)) { _ in active=false }
            .onDisappear { reader.cancel() }
    }
    private func refresh() {
        guard context.connected, !context.paused, !reader.isRunning else { return }
        lastAttempt=Date(); failed=false
        reader.start(batteryOnly:true)
    }
}
