import AppKit
import SwiftUI
import IOKit

@MainActor final class ProbeAppModel: ObservableObject {
    @Published var confirmed = false
    @Published var pauseMilliseconds = 80
    @Published private(set) var granted = false
    @Published private(set) var busy = false
    @Published private(set) var readingCounters = false
    @Published private(set) var message = "Prepara il firmware diagnostico e il collegamento Bluetooth."
    @Published private(set) var result: ProbeResult?
    private var requestedAtLaunch = false
    private var cancellation: ProbeCancellation?

    func refreshAccess() { granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    func launchPermissionSetup() {
        refreshAccess()
        guard !granted, !requestedAtLaunch else { return }
        requestedAtLaunch = true
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refreshAccess()
        let state = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if state != kIOHIDAccessTypeGranted && state != kIOHIDAccessTypeUnknown { openPrivacy() }
    }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
    }
    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func cancel() { cancellation?.cancel(); message = "Interruzione in corso, ripristino degli indicatori…" }

    func readCounters() {
        guard !busy,
              let path = Bundle.main.object(forInfoDictionaryKey: "KeyglowProbeResultPath") as? String, path.hasPrefix("/"),
              let expected = Bundle.main.object(forInfoDictionaryKey: "KeyglowProbeExpectedFirmware") as? String else { return }
        let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("usb-counters.json")
        busy = true; readingCounters = true
        message = "Lettura dei contatori diagnostici via USB…"
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let counters = try ProbeUSBCounters.read(expectedFirmware: expected)
                try ProbeResultStore.save(counters, to: output)
                await MainActor.run {
                    self.message = "USB: \(counters.attempts) attivazioni, \(counters.challenges) richieste valide, \(counters.reportsSubmitted) report inviati alla radio, \(counters.completions) sequenze complete, \(counters.aborts) interruzioni. Stato \(counters.state), motivo \(counters.abortReason). Questi contatori non confermano la ricezione sul Mac."
                    self.busy = false; self.readingCounters = false
                }
            } catch {
                let detail = error.localizedDescription
                await MainActor.run { self.message = detail; self.busy = false; self.readingCounters = false }
            }
        }
    }

    func start() {
        refreshAccess()
        guard granted, confirmed, !busy else { return }
        guard let path = Bundle.main.object(forInfoDictionaryKey: "KeyglowProbeResultPath") as? String, path.hasPrefix("/") else {
            message = "Percorso del risultato diagnostico mancante nella configurazione dell’app."; return
        }
        let outputURL = URL(fileURLWithPath: path)
        let token = ProbeCancellation(); cancellation = token
        let interval = Double(pauseMilliseconds) / 1000
        let nonce = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        busy = true; confirmed = false; result = nil
        message = "Prova in corso. Non digitare e non usare la manopola; gli indicatori saranno ripristinati."
        Task.detached(priority: .userInitiated) { [self] in
            let outcome = ProbeRunner().run(channel: ProbeHIDChannel(), nonce: nonce, cancellation: token, interval: interval)
            var saved = true
            do { try ProbeResultStore.save(outcome, to: outputURL) } catch { saved = false }
            await MainActor.run {
                self.busy = false; self.cancellation = nil; self.result = outcome
                self.message = outcome.status == "passed"
                    ? "Canale di ritorno verificato: nonce e CRC corretti. Questa prova non aggiorna il firmware."
                    : (ProbeFailure(rawValue: outcome.status)?.message ?? "Prova non riuscita.")
                if !saved { self.message += " Il risultato non è stato salvato su disco." }
            }
        }
    }
}

private struct ProbeAppView: View {
    @ObservedObject var model: ProbeAppModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "wave.3.right.circle").font(.system(size: 38)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keyglow HID Probe").font(.system(size: 27, weight: .semibold))
                    Text("Q6 Max ISO · verifica del canale Bluetooth di ritorno").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.granted ? "Monitoraggio input consentito" : "Autorizzazione macOS necessaria",
                          systemImage: model.granted ? "checkmark.circle.fill" : "hand.raised")
                        .font(.headline).foregroundStyle(model.granted ? .mint : .primary)
                    Text("Abilita Keyglow HID Probe in Privacy e sicurezza → Monitoraggio input. Il risultato contiene soltanto contatori e verifica della risposta; la digitazione non viene salvata.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Apri Impostazioni") { model.openPrivacy() }
                        Button("Ricontrolla") { model.refreshAccess() }
                        Button("Mostra questa app") { model.revealApp() }
                    }.disabled(model.busy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Prima della prova").font(.title3.weight(.semibold))
                Text("1. Installa il firmware diagnostico keyglow_probe con il supporto KPRB, poi usa BT senza USB.")
                Text("2. Tieni Fn, aggiungi ○ sopra Num per almeno 2 secondi, quindi rilascia entrambi.")
                Text("3. Conferma qui sotto e avvia entro 30 secondi. Per circa 7 secondi non premere tasti o manopola.")
                Picker("Pausa dopo ogni scrittura", selection: $model.pauseMilliseconds) {
                    Text("80 ms · standard").tag(80)
                    Text("40 ms · sperimentale").tag(40)
                    Text("20 ms · sperimentale").tag(20)
                }.pickerStyle(.menu).disabled(model.busy)
                Text("Una prova alla volta. La cadenza effettiva comprende anche il tempo impiegato da macOS per ogni scrittura.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Firmware diagnostico installato; ho appena rilasciato Fn + ○", isOn: $model.confirmed)
                    .toggleStyle(.checkbox).font(.system(size: 13, weight: .medium)).padding(.top, 4)
                    .disabled(model.busy)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    if !model.readingCounters { Button("Interrompi") { model.cancel() } }
                }
                Button("Leggi contatori USB") { model.readCounters() }.disabled(model.busy)
                Spacer()
                Button("Avvia prova Bluetooth") { model.start() }.buttonStyle(.borderedProminent)
                    .disabled(!model.granted || !model.confirmed || model.busy)
            }
            Text(model.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if let result = model.result {
                Text("Simboli risposta: \(result.responseSymbols)/26 · Nonce: \(result.nonceMatched ? "corretto" : "non confermato") · CRC: \(result.crcMatched ? "corretto" : "non confermato") · Ripristino LED: \(result.restorationAccepted ? "accettato" : "non confermato")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let mean = result.meanWriteDurationMilliseconds, let maximum = result.maxWriteDurationMilliseconds {
                    Text("Pausa: \(result.requestedPauseMilliseconds) ms · Scrittura media/massima: \(mean, specifier: "%.1f") / \(maximum, specifier: "%.1f") ms · Andata e ritorno: \(result.roundTripMilliseconds.map { "\($0) ms" } ?? "non completo")")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }.padding(30).frame(maxWidth: .infinity).tint(.mint)
        }.frame(width: 700, height: 680)
    }
}

@MainActor private final class ProbeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = ProbeAppModel()
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Esci da Keyglow HID Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Keyglow HID Probe"; window.delegate = self
        window.contentView = NSHostingView(rootView: ProbeAppView(model: model).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.launchPermissionSetup()
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshAccess() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.busy { model.cancel(); return .terminateCancel }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { model.cancel(); return false }
        return true
    }
}

@main struct KeyglowProbeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProbeAppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
