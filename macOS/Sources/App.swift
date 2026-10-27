import AppKit
import SwiftUI
import Combine

@MainActor final class StudioModel: ObservableObject {
    @Published var section = 0 { didSet { refreshLiveRGBContext() } }
    @Published var workspace = KeyboardWorkspace() { didSet {
        if !loadingWorkspace {
            saveWorkspaceLocally()
            if oldValue.lighting != workspace.lighting { queueLiveRGBChange() }
        }
    } }
    @Published var savedProfiles: [KeyboardWorkspace] = []
    @Published var selectedKeys: Set<String> = []
    @Published var selectedLayer = 0
    @Published var keySearch = ""
    @Published var keyCategory = "Tutti"
    @Published var rawKeycode = ""
    @Published var selectedMacro = 0
    @Published var selectedMixLayer = 0
    @Published var recording = false { didSet { refreshLiveRGBContext() } }
    @Published var captureMapping = false
    @Published var mappingModifiers = 0
    @Published var testing = false { didSet { refreshLiveRGBContext() } }
    @Published var pressedKeys: Set<String> = []
    @Published var testedKeys: Set<String> = []
    @Published var lastTestKey = "Premi un tasto nella finestra di Keyglow."
    @Published var usbDevices: [VIADevice] = []
    @Published var selectedUSBID: UInt64? { didSet { refreshLiveRGBContext() } }
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
    @Published var brightness = 80.0 { didSet { UserDefaults.standard.set(brightness, forKey: "studio.brightness"); syncLightDraft() } }
    @Published var hexInput = "57D9C1"
    @Published var hexError = false
    @Published var available = false { didSet { refreshLiveRGBContext() } }
    @Published var deviceDescription = "Ricerca della Q6 Max…"
    @Published var accessVerified = false { didSet { if !accessVerified { accessVerification.invalidateEvidence() }; refreshLiveRGBContext() } }
    @Published var accessAttempted = false
    @Published var firmwareArmed = false
    // This is a remembered setup choice, not a Bluetooth firmware readback.
    @Published var directBluetooth = UserDefaults.standard.bool(forKey: "bluetooth.directV3") {
        didSet { UserDefaults.standard.set(directBluetooth, forKey: "bluetooth.directV3"); firmwareArmed = false; refreshLiveRGBContext() }
    }
    @Published var saveBluetoothOnKeyboard = UserDefaults.standard.object(forKey: "bluetooth.saveOnKeyboard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saveBluetoothOnKeyboard, forKey: "bluetooth.saveOnKeyboard"); refreshLiveRGBContext() }
    }
    @Published var busy = false { didSet { refreshLiveRGBContext(); if !busy { resumeDeferredAccessRefresh() } } }
    @Published var transmitting = false
    @Published var progress = 0.0
    @Published var message = "Scegli un colore. L’anteprima cambia solo nell’app."
    @Published var accessMessage = "Verifica che macOS consenta all’app di accedere alla tastiera."
    @Published var selectedPreset = "Menta"
    @Published private(set) var liveRGBEnabled = false
    @Published private(set) var liveRGBQueued = false
    @Published private(set) var liveRGBStatus = "L’anteprima sulla tastiera è disattivata."
    private var liveRGB = LiveRGBCoordinator()
    private var liveRGBWake: Task<Void, Never>?
    private let transport = HIDTransport()
    private var deviceID: UInt64?
    private var accessVerification = OnboardingAccessVerification()
    private var accessRefreshScheduled = false
    private var deferredAccessForceRead = false
    var onBluetoothAccessStateChanged: ((OnboardingDeviceState) -> Void)?

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
    var lightingControlsDisabled: Bool { busy && !transmitting }
    var liveRGBEligible: Bool { available && accessVerified && directBluetooth && selectedUSBID == nil && bluetoothEffectSupported && !recording && !testing }
    var canEnableLiveRGB: Bool { liveRGBEligible && !busy && section == 0 }
    var liveRGBUnavailableReason: String {
        if selectedUSBID != nil { return "L’anteprima automatica usa Bluetooth. Scollega USB e seleziona BT sulla tastiera." }
        if !available { return "Collega la Q6 Max via Bluetooth per attivare l’anteprima." }
        if !directBluetooth { return "In Connessione seleziona il firmware compatibile con RGB diretti." }
        if !accessVerified { return "Verifica l’accesso Bluetooth nella pagina Connessione." }
        if !bluetoothEffectSupported { return "L’anteprima Bluetooth supporta gli effetti generali. RGB per tasto e Mix richiedono USB." }
        return "Attendi il termine dell’operazione in corso."
    }
    func setLiveRGBEnabled(_ enabled: Bool) {
        guard !enabled || canEnableLiveRGB else { return }
        liveRGBEnabled = enabled
        refreshLiveRGBContext()
        if enabled { queueLiveRGBChange() }
    }
    private func refreshLiveRGBContext() {
        liveRGB.configure(enabled: liveRGBEnabled, allowed: liveRGBEligible && section == 0 && (!busy || transmitting),
                          save: saveBluetoothOnKeyboard, now: ProcessInfo.processInfo.systemUptime)
        scheduleLiveRGB()
    }
    private func queueLiveRGBChange() {
        guard !loadingWorkspace else { return }
        refreshLiveRGBContext()
        let light = workspace.lighting
        liveRGB.edit(LiveRGBColor(effect: light.effect, hue: light.hue, saturation: light.saturation, value: light.value,
                                 brightness: light.brightness, speed: light.speed), now: ProcessInfo.processInfo.systemUptime)
        scheduleLiveRGB()
    }
    private func scheduleLiveRGB() {
        liveRGBWake?.cancel(); liveRGBWake = nil
        liveRGBQueued = liveRGB.hasQueuedChange
        if let active = liveRGB.active {
            liveRGBStatus = active.save ? "Salvataggio finale in corso · invio rapido sperimentale." : "Anteprima in invio · modalità rapida sperimentale."
            if liveRGBQueued { liveRGBStatus += " Seguirà l’ultima modifica scelta." }
            else if !liveRGBEnabled { liveRGBStatus += " L’invio già avviato terminerà; i successivi sono annullati." }
        } else if liveRGBQueued { liveRGBStatus = "Ultima modifica in attesa di invio…" }
        else if liveRGB.waitingToSave { liveRGBStatus = "Anteprima inviata · attendo prima di salvare l’ultimo stato." }
        else if liveRGBEnabled && liveRGB.allowed { liveRGBStatus = "Anteprima rapida sperimentale attiva · attendi il cambiamento sulla tastiera; il canale non conferma la ricezione." }
        else if liveRGBEnabled { liveRGBStatus = liveRGBUnavailableReason }
        else { liveRGBStatus = "L’anteprima sulla tastiera è disattivata." }
        guard !busy, let due = liveRGB.nextDeadline else { return }
        let delay = max(0, due - ProcessInfo.processInfo.systemUptime)
        liveRGBWake = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.flushLiveRGB()
        }
    }
    private func flushLiveRGB() {
        guard ready, liveRGBEligible, section == 0 else { refreshLiveRGBContext(); return }
        guard let job = liveRGB.takeReady(now: ProcessInfo.processInfo.systemUptime) else { scheduleLiveRGB(); return }
        do {
            try performRGBSend(packet: job.color.packet(save: job.save), requestedSave: job.save,
                               submittedEffect: RGBEffect.all.first { $0.id == job.color.effect }?.name ?? "RGB", liveJob: job, interval: RGBProtocol.liveInterval)
        } catch {
            liveRGB.complete(job, succeeded: false, now: ProcessInfo.processInfo.systemUptime)
            message = error.localizedDescription; scheduleLiveRGB()
        }
    }
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
        guard !busy else { refreshBluetoothAccess(forceRead: true); return }
        firmwareArmed = false; cableModeConfirmed = false; radioVersion = nil
        scanUSB()
        refreshBluetoothAccess(forceRead: true)
    }
    private func identifyBluetoothDevice() {
        do {
            let devices = try HIDTransport.enumerate()
            available = devices.count == 1 && devices[0].supportsExpectedLEDReport
            deviceID = available ? devices[0].registryID : nil
            if available { deviceDescription = "Q6 Max rilevata via Bluetooth." }
            else if devices.isEmpty { deviceDescription = "Nessuna Q6 Max Bluetooth rilevata. Collega la tastiera nelle impostazioni di macOS e riprova." }
            else if devices.count > 1 { deviceDescription = "Più Q6 Max rilevate. Lascia collegata solo quella da configurare." }
            else { deviceDescription = "Tastiera rilevata, ma formato Bluetooth non compatibile con questo prototipo." }
        } catch { available = false; deviceID = nil; deviceDescription = error.localizedDescription }
    }
    func checkAccess() { refreshBluetoothAccess(forceRead: true) }

    /// Explicit scans, launch, activation and wake share this read-only path.
    /// No IOHID input callback, LED output write or consent request is registered.
    func refreshBluetoothAccess(forceRead: Bool = false) {
        let permission = SystemOnboardingPermissions().checkAccess()
        if busy {
            accessVerification.observe(permission: permission, deviceID: deviceID)
            if forceRead { accessVerification.invalidateEvidence(); deferredAccessForceRead = true }
            accessVerified = accessVerification.isVerified
            if accessVerification.active == nil || forceRead {
                accessVerification.deferRefresh()
                onBluetoothAccessStateChanged?(.waiting)
            }
            if permission != .granted { accessMessage = permissionMessage(permission) }
            return
        }
        identifyBluetoothDevice()
        // Activation after the native color panel must not cancel queued RGB.
        // Reuse only this process's successful read after fresh OS consent and
        // registry identity checks; explicit Verify/Scan and wake force a read.
        if !forceRead && accessVerification.canReuseCurrentRead(permission: permission, deviceID: deviceID) {
            accessVerified = true; accessAttempted = true
            accessMessage = "Permesso macOS e dispositivo ricontrollati. La verifica in sola lettura è ancora valida per questa Q6 Max."
            onBluetoothAccessStateChanged?(.verified)
            return
        }
        guard let attempt = accessVerification.begin(permission: permission, deviceID: deviceID, busy: false) else {
            accessVerified = false; accessAttempted = false
            if permission != .granted {
                accessMessage = permissionMessage(permission)
                onBluetoothAccessStateChanged?(available ? .detected : .notConnected)
            } else {
                accessMessage = available ? "Permesso concesso da macOS. Verifica della tastiera in attesa." : "Permesso concesso da macOS. Collega la Q6 Max via Bluetooth: l’accesso sarà verificato al ritorno nell’app."
                onBluetoothAccessStateChanged?(available ? .detected : .notConnected)
            }
            return
        }
        accessVerified = false; accessAttempted = false
        accessMessage = "Permesso macOS concesso · verifica della Q6 Max in sola lettura…"
        onBluetoothAccessStateChanged?(.checking)
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try HIDTransport.readLEDState(deviceID: attempt.deviceID) }
            DispatchQueue.main.async { [self] in
                // The read has closed its HID handle. Recheck fresh identity and
                // consent before accepting its result; never trust cached grants.
                identifyBluetoothDevice()
                let currentPermission = SystemOnboardingPermissions().checkAccess()
                let succeeded: Bool
                if case .success = result { succeeded = true } else { succeeded = false }
                accessVerified = accessVerification.complete(attempt, succeeded: succeeded, permission: currentPermission, deviceID: deviceID)
                accessAttempted = true
                if accessVerified {
                    accessMessage = "Accesso verificato automaticamente in sola lettura. Nessun colore o impostazione modificato."
                    onBluetoothAccessStateChanged?(.verified)
                } else if currentPermission != .granted {
                    accessMessage = permissionMessage(currentPermission)
                    onBluetoothAccessStateChanged?(available ? .detected : .notConnected)
                } else if !available {
                    accessMessage = "Permesso macOS concesso; la Q6 Max Bluetooth non è disponibile. Ricollegala e torna nell’app."
                    onBluetoothAccessStateChanged?(.notConnected)
                } else {
                    if case .failure(let error) = result { accessMessage = "Permesso macOS concesso, ma la lettura non è riuscita: \(error.localizedDescription)" }
                    else { accessMessage = "Dispositivo cambiato durante la verifica. Ricontrollo la Q6 Max rilevata." }
                    onBluetoothAccessStateChanged?(.unavailable(accessMessage))
                }
                busy = false
            }
        }
    }
    private func permissionMessage(_ permission: OnboardingPermissionState) -> String {
        switch permission {
        case .granted: return "Permesso concesso da macOS."
        case .denied: return "Monitoraggio input non consentito. Abilita Keyglow in Impostazioni di Sistema → Privacy e sicurezza; al ritorno l’accesso verrà ricontrollato."
        case .unknown: return "Conferma la richiesta Monitoraggio input di macOS. Keyglow ricontrolla il permesso al ritorno nell’app."
        case .unavailable: return "macOS non rende disponibile lo stato del permesso. Apri Configura accessi dal menu Keyglow."
        }
    }
    private func resumeDeferredAccessRefresh() {
        guard accessVerification.refreshPending, accessVerification.active == nil, !accessRefreshScheduled else { return }
        accessRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.accessRefreshScheduled = false
            guard !self.busy, self.accessVerification.takeDeferredRefresh() else { return }
            let forceRead = self.deferredAccessForceRead
            self.deferredAccessForceRead = false
            self.refreshBluetoothAccess(forceRead: forceRead)
        }
    }
    func send(off: Bool) {
        guard ready else { return }
        liveRGB.cancelUnsent(); scheduleLiveRGB()
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
        let submittedEffect = off ? "Spento" : currentEffect.name
        let requestedSave = directBluetooth && saveBluetoothOnKeyboard
        performRGBSend(packet: packet, requestedSave: requestedSave, submittedEffect: submittedEffect)
    }
    private func performRGBSend(packet: [UInt8], requestedSave: Bool, submittedEffect: String, liveJob: LiveRGBCoordinator.Job? = nil, interval: TimeInterval = RGBProtocol.interval) {
        transmitting = true; busy = true; progress = 0; projectMessage = ""
        message = liveJob == nil ? "Invio RGB via Bluetooth. Non premere Caps Lock o Num Lock per circa 5 secondi." : "Invio RGB rapido sperimentale. Evita Caps Lock e Num Lock fino al completamento; verifica il colore sulla tastiera."
        transport.send(masks: RGBProtocol.masks(for: packet), interval: interval, deviceID: deviceID,
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
                    if let liveJob {
                        let succeeded: Bool
                        if case .success = result { succeeded = true } else { succeeded = false }
                        liveRGB.complete(liveJob, succeeded: succeeded, now: ProcessInfo.processInfo.systemUptime)
                    }
                    scheduleLiveRGB()
                }
            })
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let model = StudioModel()
    private let onboarding = OnboardingCoordinator()
    private var wakeSubscription: AnyCancellable?
    private var setupReady = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1400, visible.width), height: min(900, visible.height)), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Keyglow · Q6 Max ISO"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.086, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: StudioView(model: model).preferredColorScheme(.dark))
        let restored = window.setFrameUsingName("Keyglow.MainWindow")
        window.setFrameAutosaveName("Keyglow.MainWindow")
        if !restored { window.center() }
        // Fit the full window frame, including its title bar, inside a current
        // display's visible area so restored positions never sit below the Dock.
        let screen = NSScreen.screens.max { left, right in
            let a = left.visibleFrame.intersection(window.frame), b = right.visibleFrame.intersection(window.frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }?.visibleFrame ?? visible
        var fitted = window.frame
        fitted.size.width = min(fitted.width, screen.width); fitted.size.height = min(fitted.height, screen.height)
        fitted.origin.x = min(max(fitted.minX, screen.minX), screen.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, screen.minY), screen.maxY - fitted.height)
        window.setFrame(fitted, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.onBluetoothAccessStateChanged = { [weak self] state in self?.onboarding.model.updateDeviceState(state) }
        onboarding.onCompletion = { [weak self] in self?.model.refreshBluetoothAccess() }
        model.scan()
        _ = QuickLaunchService.shared
        setupReady = true
        wakeSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.model.refreshBluetoothAccess(forceRead: true) }
        }
        onboarding.showIfNeeded(parent: window)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard setupReady else { return }
        onboarding.refreshAfterActivation()
        model.refreshBluetoothAccess()
    }
    func applicationDidResignActive(_ notification: Notification) { model.stopCapture() }
    func windowDidResize(_ notification: Notification) { if let window { onboarding.fitToParent(window) } }
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
