import AppKit
import SwiftUI

@MainActor final class StudioModel: ObservableObject {
    @Published var section = 0
    @Published var workspace = KeyboardWorkspace() { didSet { if !loadingWorkspace { saveWorkspaceLocally() } } }
    @Published var savedProfiles: [KeyboardWorkspace] = []
    @Published var selectedKeys: Set<String> = []
    @Published var selectedLayer = 0
    @Published var keySearch = ""
    @Published var keyCategory = "Tutti"
    @Published var rawKeycode = ""
    @Published var selectedMacro = 0
    @Published var selectedMixLayer = 0
    @Published var recording = false
    @Published var captureMapping = false
    @Published var mappingModifiers = 0
    @Published var testing = false
    @Published var pressedKeys: Set<String> = []
    @Published var testedKeys: Set<String> = []
    @Published var lastTestKey = "Premi un tasto nella finestra di Keyglow."
    @Published var usbDevices: [VIADevice] = []
    @Published var selectedUSBID: UInt64?
    @Published var usbSnapshot: VIASnapshot?
    @Published var baselineWorkspace: KeyboardWorkspace?
    @Published var usbMessage = "Leggi la configurazione della Q6 Max per abilitare l’applicazione delle modifiche."
    @Published var projectMessage = ""
    @Published var firmwareFileDescription = ""
    @Published var cableModeConfirmed = false
    @Published var lastBluetoothSend: Date?
    @Published var lastBluetoothEffect = ""
    @Published var radioVersion: RadioVersionResult?
    @Published var radioMessage = "La versione radio è distinta dal firmware della tastiera. La lettura richiede USB."
    @Published var lightingTab = 0
    @Published var previewAnimation = false
    var loadingWorkspace = false
    var localEventMonitor: Any?
    var lastRecordedAt: TimeInterval?
    var recordingPressed: Set<UInt8> = []
    @Published var hue = 0.455
    @Published var saturation = 0.60
    @Published var value = 0.85
    @Published var brightness = 80.0 { didSet { UserDefaults.standard.set(brightness, forKey: "studio.brightness") } }
    @Published var hexInput = "57D9C1"
    @Published var hexError = false
    @Published var available = false
    @Published var deviceDescription = "Ricerca della Q6 Max…"
    @Published var accessVerified = false
    @Published var accessAttempted = false
    @Published var firmwareArmed = false
    // This is a remembered setup choice, not a Bluetooth firmware readback.
    @Published var directBluetooth = UserDefaults.standard.bool(forKey: "bluetooth.directV3") {
        didSet { UserDefaults.standard.set(directBluetooth, forKey: "bluetooth.directV3"); firmwareArmed = false }
    }
    @Published var saveBluetoothOnKeyboard = UserDefaults.standard.object(forKey: "bluetooth.saveOnKeyboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saveBluetoothOnKeyboard, forKey: "bluetooth.saveOnKeyboard") }
    }
    @Published var busy = false
    @Published var transmitting = false
    @Published var progress = 0.0
    @Published var message = "Scegli un colore. L’anteprima cambia solo nell’app."
    @Published var accessMessage = "Verifica che macOS consenta all’app di accedere alla tastiera."
    @Published var selectedPreset = "Menta"
    private let transport = HIDTransport()
    private var deviceID: UInt64?

    init() {
        loadingWorkspace = true
        if let hex = UserDefaults.standard.string(forKey: "studio.hex") { applyHex(hex) }
        else { applyHex("57D9C1"); selectedPreset = "Menta" }
        if UserDefaults.standard.object(forKey: "studio.brightness") != nil {
            brightness = min(100, max(0, UserDefaults.standard.double(forKey: "studio.brightness")))
        }
        restoreWorkspaceLocally()
    }
    var nsColor: NSColor {
        let sector = (hue * 6).truncatingRemainder(dividingBy: 6)
        let chroma = value * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - chroma
        let rgb: (Double, Double, Double)
        switch sector {
        case 0..<1: rgb = (chroma, x, 0)
        case 1..<2: rgb = (x, chroma, 0)
        case 2..<3: rgb = (0, chroma, x)
        case 3..<4: rgb = (0, x, chroma)
        case 4..<5: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        return NSColor(srgbRed: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: 1)
    }
    var color: Color { Color(nsColor: nsColor) }
    var ready: Bool { available && accessVerified && (directBluetooth || firmwareArmed) && !busy }
    var bluetoothApplyTitle: String { directBluetooth && saveBluetoothOnKeyboard ? "Applica e salva RGB" : "Applica RGB" }
    var bluetoothEffectSupported: Bool { (0...22).contains(workspace.lighting.effect) }
    var hex: String {
        let c = nsColor
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    func colorChanged() {
        hexInput = hex; hexError = false; selectedPreset = "Personalizzato"
        UserDefaults.standard.set(hex, forKey: "studio.hex")
        syncLightDraft()
    }
    func setColor(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
        hue = c.hueComponent; saturation = c.saturationComponent; value = c.brightnessComponent
        colorChanged()
    }
    func applyHex(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, clean.allSatisfy({ $0.isHexDigit }), let n = UInt32(clean, radix: 16) else { hexError = true; return }
        let c = NSColor(srgbRed: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255, alpha: 1)
        hue = c.hueComponent; saturation = c.saturationComponent; value = c.brightnessComponent
        colorChanged()
    }
    func preset(_ name: String, _ hex: String) { applyHex(hex); selectedPreset = name }
    func scan() {
        guard !busy else { return }
        accessVerified = false; accessAttempted = false; firmwareArmed = false; cableModeConfirmed = false; radioVersion = nil
        accessMessage = "Verifica che macOS consenta all’app di accedere alla tastiera."
        do {
            let devices = try HIDTransport.enumerate()
            available = devices.count == 1 && devices[0].supportsExpectedLEDReport
            deviceID = available ? devices[0].registryID : nil
            if available { deviceDescription = "Q6 Max rilevata via Bluetooth." }
            else if devices.isEmpty { deviceDescription = "Nessuna Q6 Max Bluetooth rilevata. Collega la tastiera nelle impostazioni di macOS e riprova." }
            else if devices.count > 1 { deviceDescription = "Più Q6 Max rilevate. Lascia collegata solo quella da configurare." }
            else { deviceDescription = "Tastiera rilevata, ma formato Bluetooth non compatibile con questo prototipo." }
        } catch { available = false; deviceID = nil; deviceDescription = error.localizedDescription }
        scanUSB()
    }
    func checkAccess() {
        guard available && !busy else { return }
        busy = true; accessAttempted = false
        accessMessage = "Verifica dell’accesso in corso…"
        let id = deviceID
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try HIDTransport.readLEDState(deviceID: id) }
            DispatchQueue.main.async { [self] in
                busy = false; accessAttempted = true
                switch result {
                case .success:
                    accessVerified = true
                    accessMessage = "Accesso Bluetooth verificato. La modalità scelta sotto deve corrispondere al firmware installato."
                case .failure(let error):
                    accessVerified = false
                    accessMessage = error.localizedDescription
                }
            }
        }
    }
    func send(off: Bool) {
        guard ready else { return }
        let packet: [UInt8]
        func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, value.isFinite ? value.rounded() : 0))) }
        do {
            if directBluetooth {
                packet = try RGBProtocol.directStatePacket(effect: off ? 0 : workspace.lighting.effect,
                    hue: byte(hue * 255), saturation: byte(saturation * 255),
                    value: byte(value * brightness / 100 * 255), speed: byte(Double(workspace.lighting.speed)), save: saveBluetoothOnKeyboard)
            } else {
                packet = try RGBProtocol.statePacket(effect: off ? 0 : workspace.lighting.effect,
                    hue: byte(hue * 255), saturation: byte(saturation * 255),
                    value: byte(value * brightness / 100 * 255), speed: byte(Double(workspace.lighting.speed)))
            }
        } catch { message = error.localizedDescription; return }
        busy = true; transmitting = true; progress = 0; projectMessage = ""
        let submittedEffect = off ? "Spento" : currentEffect.name
        let requestedSave = directBluetooth && saveBluetoothOnKeyboard
        message = "Invio RGB via Bluetooth. Non premere Caps Lock o Num Lock per circa 5 secondi."
        transport.send(masks: RGBProtocol.masks(for: packet), interval: RGBProtocol.interval, deviceID: deviceID,
            progress: { [self] completed, total in
                DispatchQueue.main.async { [self] in progress = Double(completed) / Double(max(1, total)) }
            }, completion: { [self] result in
                DispatchQueue.main.async { [self] in
                    busy = false; transmitting = false; firmwareArmed = false
                    switch result {
                    case .success:
                        lastBluetoothSend = Date(); lastBluetoothEffect = submittedEffect
                        message = requestedSave
                            ? "Comando di salvataggio inviato; indicatori ripristinati. Attendi 2 secondi prima di spegnere la tastiera. Il canale non conferma la ricezione: verifica colore e persistenza sulla Q6 Max."
                            : "Invio completato e indicatori ripristinati. RGB temporanei fino al riavvio; il canale non conferma la ricezione dalla tastiera."
                    case .failure(let error): message = error.localizedDescription; progress = 0; accessVerified = false
                    }
                }
            })
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let model = StudioModel()
    private let onboarding = OnboardingCoordinator()
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Keyglow · Q6 Max ISO"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.086, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1180, height: 820)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: StudioView(model: model).preferredColorScheme(.dark))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.scan()
        _ = QuickLaunchService.shared
        onboarding.onCompletion = { [weak self] in self?.model.checkAccess() }
        onboarding.showIfNeeded(parent: window)
    }
    func applicationDidResignActive(_ notification: Notification) { model.stopCapture() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { mayClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { mayClose() ? .terminateNow : .terminateCancel }
    private func mayClose() -> Bool {
        guard model.busy else { return true }
        let alert = NSAlert(); alert.messageText = "Operazione in corso"
        alert.informativeText = "Attendi il completamento e il ripristino degli indicatori prima di chiudere l’app."
        alert.runModal(); return false
    }
    private func buildMenu() {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(); item.submenu = app
        app.addItem(withTitle: "Informazioni su Keyglow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let setup = app.addItem(withTitle: "Configura accessi…", action: #selector(showSetup(_:)), keyEquivalent: ",")
        setup.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Esci da Keyglow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Modifica"); editItem.submenu = edit; menu.addItem(editItem)
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    @objc private func showSetup(_ sender: Any?) { onboarding.show(parent: window) }
}
