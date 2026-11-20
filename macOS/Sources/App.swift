import AppKit
import SwiftUI
import Combine

@MainActor final class StudioModel: ObservableObject {
    @Published var section: StudioSection = .lighting { didSet { flushWorkspaceSave(); refreshLiveRGBContext(); batteryMonitor.reconcile() } }
    let batteryMonitor = KeyboardStatusMonitor()
    let settings = AppSettingsModel()
    /// Owns the installed-firmware reading shared by the guide and the pages.
    let firmwareUpdater = FirmwareUpdateModel()
    private var firmwareReading: AnyCancellable?
    @Published var workspace = KeyboardWorkspace() { didSet {
        if !loadingWorkspace {
            if !restoringHistory { draftHistory.record(previous: oldValue, current: workspace, now: ProcessInfo.processInfo.systemUptime) }
            scheduleWorkspaceSave()
            if oldValue.lighting != workspace.lighting { queueLiveRGBChange() }
        }
    } }
    @Published var savedProfiles: [KeyboardWorkspace] = []
    /// The saved profile this draft was loaded from or last saved as.
    @Published var sourceProfileID: UUID? { didSet {
        guard !loadingWorkspace else { return }
        if let sourceProfileID { UserDefaults.standard.set(sourceProfileID.uuidString, forKey: "workspace.sourceProfile") }
        else { UserDefaults.standard.removeObject(forKey: "workspace.sourceProfile") }
    } }
    var profileStorageError = ""
    /// Set when the profile list had to be loaded from a fallback copy.
    @Published var profileLoadNotice = ""
    /// Saved profiles live in Application Support; the old preference stays as a fallback.
    var profileStore = ProfileStore.standard()
    /// Undo/redo of draft edits only. Loading, reading or applying clears it.
    var draftHistory = DraftHistory<KeyboardWorkspace>()
    var restoringHistory = false
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
    @Published var selectedUSBID: UInt64? { didSet { if oldValue != selectedUSBID { firmwareUpdater.forgetInstalledReading() }; refreshLiveRGBContext() } }
    @Published var usbSnapshot: VIASnapshot?
    @Published var baselineWorkspace: KeyboardWorkspace?
    @Published var usbMessage = "Leggi la configurazione della Q6 Max per abilitare l’applicazione delle modifiche."
    @Published var projectMessage = ""
    @Published var firmwareFileDescription = ""
    @Published var showFirmwareSetup = false
    @Published var cableModeConfirmed = false
    @Published var lastBluetoothSend: Date?
    @Published var lastBluetoothEffect = ""
    @Published var radioVersion: RadioVersionResult?
    @Published var radioMessage = "La versione radio è distinta dal firmware della tastiera. La lettura richiede USB."
    @Published var lightingTab = 0 { didSet { refreshLiveRGBContext() } }
    @Published var previewAnimation = false
    var loadingWorkspace = false
    /// Pending deferred draft save; nil when the stored draft is current.
    var workspaceSave: Task<Void, Never>?
    static let workspaceSaveDelay: UInt64 = 500_000_000
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
    @Published var busy = false { didSet { batteryMonitor.reconcile(); refreshLiveRGBContext(); if !busy { resumeDeferredAccessRefresh() } } }
    @Published var transmitting = false
    @Published var progress = 0.0
    @Published var message = "Scegli un colore. L’anteprima cambia solo nell’app."
    @Published var accessMessage = "Verifica che macOS consenta all’app di accedere alla tastiera."
    @Published var selectedPreset = "Menta"
    // Remember the user's opt-in, not a queued color or a permission grant.
    // Restoring this choice never sends until a new edit is made.
    @Published private(set) var liveRGBEnabled = UserDefaults.standard.bool(forKey: "bluetooth.livePreview")
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
    /// Last Input Monitoring state read from macOS for this process; never stored.
    @Published private(set) var systemPermission: OnboardingPermissionState = .unknown
    /// Quit and reopen through the app delegate's busy check.
    var onRelaunchRequested: (() -> Void)?

    init() {
        loadingWorkspace = true
        if let hex = UserDefaults.standard.string(forKey: "studio.hex") { applyHex(hex) }
        else { applyHex("57D9C1"); selectedPreset = "Menta" }
        if UserDefaults.standard.object(forKey: "studio.brightness") != nil {
            brightness = min(100, max(0, UserDefaults.standard.double(forKey: "studio.brightness")))
        }
        restoreWorkspaceLocally()
        batteryMonitor.configure(snapshot: { [weak self] in
            guard let self else { return BatteryRefreshContext(connected:false,paused:true) }
            return BatteryRefreshContext(connected:self.available && self.selectedUSBID == nil,
                paused:self.busy || self.section == .firmware, deviceID:self.deviceID, usbConnected:self.selectedUSBID != nil)
        }, refreshConnection: { [weak self] in self?.refreshConnectionMetadata() })
        settings.attach(to: batteryMonitor)
        firmwareUpdater.onBusyChanged = { [weak self] in self?.busy = $0 }
        // The remembered firmware choice follows a reading, never the reverse.
        firmwareReading = firmwareUpdater.$installed.sink { [weak self] reading in
            Task { @MainActor in
                guard let self else { return }
                if reading.foundKeyglow && !self.directBluetooth { self.directBluetooth = true }
                if reading.foundOther && self.directBluetooth { self.directBluetooth = false }
            }
        }
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
    var liveRGBEligible: Bool { available && accessVerified && directBluetooth && selectedUSBID == nil && lightingTab == 0 && bluetoothEffectSupported && !recording && !testing }
    var canEnableLiveRGB: Bool { liveRGBEligible && !busy && section == .lighting }
    var liveRGBUnavailableReason: String {
        if selectedUSBID != nil { return "L’anteprima automatica usa Bluetooth. Scollega USB e seleziona BT sulla tastiera." }
        if !available { return "Collega la Q6 Max via Bluetooth per attivare l’anteprima." }
        if !directBluetooth { return "In Connessione seleziona il firmware compatibile con RGB diretti." }
        if !accessVerified { return "Verifica l’accesso Bluetooth nella pagina Connessione." }
        if lightingTab != 0 || !bluetoothEffectSupported { return "L’anteprima Bluetooth supporta gli effetti generali. RGB per tasto e Mix richiedono USB." }
        return "Attendi il termine dell’operazione in corso."
    }
    func setLiveRGBEnabled(_ enabled: Bool) {
        guard !enabled || canEnableLiveRGB else { return }
        liveRGBEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "bluetooth.livePreview")
        refreshLiveRGBContext()
        if enabled { queueLiveRGBChange() }
    }
    private func refreshLiveRGBContext() {
        liveRGB.configure(enabled: liveRGBEnabled, allowed: liveRGBEligible && section == .lighting && (!busy || transmitting),
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
            liveRGBStatus = active.save ? "Salvataggio del colore finale in corso…" : "Invio dell’anteprima…"
            if liveRGBQueued { liveRGBStatus += " Seguirà l’ultima modifica scelta." }
            else if !liveRGBEnabled { liveRGBStatus += " L’invio già avviato terminerà; i successivi sono annullati." }
        } else if liveRGBQueued { liveRGBStatus = "Ultima modifica in attesa di invio…" }
        else if liveRGB.waitingToSave { liveRGBStatus = "Anteprima inviata · attendo prima di salvare l’ultimo stato." }
        else if liveRGBEnabled && liveRGB.allowed { liveRGBStatus = "Anteprima attiva · pronta alla prossima modifica." }
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
        guard ready, liveRGBEligible, section == .lighting else { refreshLiveRGBContext(); return }
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
        refreshBluetoothAccess(forceRead: true)
    }
    /// Metadata-only hot-plug refresh. Safe while typing; deferred during I/O.
    func refreshConnectionMetadata() {
        guard !busy else { return }
        scanUSB()
        identifyBluetoothDevice()
        batteryMonitor.reconcile()
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
        systemPermission = permission
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
        refreshConnectionMetadata()
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
                systemPermission = currentPermission
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
        case .denied: return "Monitoraggio input non consentito. Abilita Keyglow in Impostazioni di Sistema → Privacy e sicurezza → Monitoraggio input. macOS applica il permesso solo alle app avviate dopo averlo concesso: poi esci e riapri Keyglow."
        case .unknown: return "Conferma la richiesta Monitoraggio input di macOS. Se dopo la conferma l’accesso resta da verificare, esci e riapri Keyglow."
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private let model = StudioModel()
    private let onboarding = OnboardingCoordinator()
    private var wakeSubscription: AnyCancellable?
    private var sleepSubscription: AnyCancellable?
    private var languageSubscription: AnyCancellable?
    private var setupReady = false
    private var checkingUpdates = false
    private var menuBar: MenuBarController?
    private var secondLaunch: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quit requests from the Dock, logout or another app arrive as an Apple
        // event; route them through the same sheet-aware quit as the menu.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        buildMenu()
        languageSubscription = NotificationCenter.default.publisher(for: AppLanguageStore.didChange).sink { [weak self] _ in
            Task { @MainActor in self?.buildMenu() }
        }
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
        onboarding.firmwareUpdater = model.firmwareUpdater
        onboarding.onFirmwareCheck = { [weak self] in self?.model.checkInstalledFirmware() }
        onboarding.onRelaunchRequested = { [weak self] in self?.relaunchForPermission(resumeGuide: true) }
        model.onRelaunchRequested = { [weak self] in self?.relaunchForPermission(resumeGuide: false) }
        onboarding.onCompletion = { [weak self] choice,destination in
            guard let self else { return }
            self.model.directBluetooth = choice == .installed
            self.model.showFirmwareSetup = choice == .install
            self.model.section = StudioSection(rawValue: destination) ?? .lighting
            self.model.refreshBluetoothAccess()
        }
        menuBar = MenuBarController(model: model, openWindow: { [weak self] in self?.showMainWindow() }, quit: { [weak self] in self?.quitKeyglow(nil) })
        // A second launch asks the running copy to show its window instead of starting.
        secondLaunch = DistributedNotificationCenter.default().publisher(for: AppRelaunch.showWindowNotification).sink { [weak self] _ in
            Task { @MainActor in self?.showMainWindow() }
        }
        model.settings.onMenuBarChanged = { [weak self] visible in self?.menuBar?.setVisible(visible) }
        menuBar?.setVisible(model.settings.showsMenuBarItem)
        model.scan()
        model.batteryMonitor.start()
        _ = QuickLaunchService.shared
        setupReady = true
        wakeSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshBluetoothAccess(forceRead: true)
                self?.model.batteryMonitor.setSleeping(false)
            }
        }
        sleepSubscription = NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.model.batteryMonitor.setSleeping(true) }
        }
        onboarding.showIfNeeded(parent: window)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard setupReady else { return }
        onboarding.refreshAfterActivation()
        model.refreshBluetoothAccess()
    }
    func applicationDidResignActive(_ notification: Notification) { model.stopCapture(); onboarding.noteResignedActive() }
    func applicationWillTerminate(_ notification: Notification) { model.flushWorkspaceSave(); model.batteryMonitor.stop() }
    func windowWillClose(_ notification: Notification) { model.stopCapture(); model.flushWorkspaceSave() }
    func windowDidResize(_ notification: Notification) { if let window { onboarding.fitToParent(window) } }
    /// With the menu bar item on, Keyglow keeps running without its window so the
    /// battery monitor and Quick Launch stay active. Otherwise closing still quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !model.settings.showsMenuBarItem }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }
    private func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { mayClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { mayClose() ? .terminateNow : .terminateCancel }
    private func mayClose() -> Bool {
        guard model.busy else { return true }
        let alert = NSAlert(); alert.messageText = L10n.string("Operazione in corso")
        alert.informativeText = L10n.string("Attendi il completamento e il ripristino degli indicatori prima di chiudere l’app.")
        alert.runModal(); return false
    }
    /// Input Monitoring reaches only a process started after the grant. Start a
    /// new instance of this bundle, then quit this one; from the guide, it resumes
    /// at the access step. The busy check is the same as for Quit.
    private func relaunchForPermission(resumeGuide: Bool) {
        guard mayClose() else { return }
        if resumeGuide { onboarding.setup.saveResumePoint() }
        model.flushWorkspaceSave()
        UserDefaults.standard.synchronize()
        // The new copy must start only after this process is gone: a helper waits
        // for that, and opens nothing if this process does not exit.
        let helper: Process
        do { helper = try AppRelaunch.startHelper(waitingFor: getpid(), bundlePath: Bundle.main.bundlePath) }
        catch {
            let alert = NSAlert(); alert.messageText = L10n.string("Riapertura non riuscita")
            alert.informativeText = L10n.string("Esci da Keyglow e riaprilo manualmente.") + "\n" + error.localizedDescription
            alert.runModal(); return
        }
        quitKeyglow(nil)
        // Quitting did not happen within a moment (refused by the system): finish
        // the same shutdown steps and leave, so the helper can reopen one copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard self.mayClose() else { helper.terminate(); return }
            self.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            UserDefaults.standard.synchronize()
            exit(0)
        }
    }
    /// Quit from the menus. AppKit does not terminate while a sheet is attached,
    /// so the setup guide is closed first; the busy check still applies.
    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { quitKeyglow(nil) }
    @objc func quitKeyglow(_ sender: Any?) {
        guard mayClose() else { return }
        onboarding.dismissForTermination()
        // Any other sheet would block termination in the same way.
        for candidate in NSApp.windows { if let sheet = candidate.attachedSheet { candidate.endSheet(sheet) } }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    private func buildMenu() {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let app = NSMenu(); item.submenu = app
        app.addItem(withTitle: L10n.string("Informazioni su Keyglow"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = app.addItem(withTitle: L10n.string("Controlla aggiornamenti…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        let setup = app.addItem(withTitle: L10n.string("Configura tastiera e accessi…"), action: #selector(showSetup(_:)), keyEquivalent: ",")
        setup.target = self
        app.addItem(.separator())
        let quit = app.addItem(withTitle: L10n.string("Esci da Keyglow"), action: #selector(quitKeyglow(_:)), keyEquivalent: "q"); quit.target = self
        let editItem = NSMenuItem(); let edit = NSMenu(title: L10n.string("Modifica")); editItem.submenu = edit; menu.addItem(editItem)
        let undo = edit.addItem(withTitle: L10n.string("Annulla modifica"), action: #selector(undoEdit(_:)), keyEquivalent: "z"); undo.target = self
        let redo = edit.addItem(withTitle: L10n.string("Ripeti modifica"), action: #selector(redoEdit(_:)), keyEquivalent: "Z"); redo.target = self
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.string("Taglia"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.string("Copia"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.string("Incolla"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.string("Seleziona tutto"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem=NSMenuItem(); let windowMenu=NSMenu(title:L10n.string("Finestra")); windowItem.submenu=windowMenu; menu.addItem(windowItem)
        windowMenu.addItem(withTitle:L10n.string("Contrai"),action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowMenu.addItem(.separator())
        let compact=windowMenu.addItem(withTitle:L10n.string("Dimensione compatta"),action:#selector(compactWindow(_:)),keyEquivalent:""); compact.target=self
        let comfortable=windowMenu.addItem(withTitle:L10n.string("Dimensione comoda"),action:#selector(comfortableWindow(_:)),keyEquivalent:""); comfortable.target=self
        NSApp.windowsMenu=windowMenu
        NSApp.mainMenu = menu
    }
    /// A text field being edited keeps its native undo; otherwise the draft history applies.
    private var editingText: NSTextView? { (NSApp.keyWindow ?? window)?.firstResponder as? NSTextView }
    @objc private func undoEdit(_ sender: Any?) {
        if let text = editingText { text.undoManager?.undo() } else if window.attachedSheet == nil { model.undoDraft() }
    }
    @objc private func redoEdit(_ sender: Any?) {
        if let text = editingText { text.undoManager?.redo() } else if window.attachedSheet == nil { model.redoDraft() }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoEdit(_:)): return editingText.map { $0.undoManager?.canUndo == true } ?? (window.attachedSheet == nil && model.canUndoDraft)
        case #selector(redoEdit(_:)): return editingText.map { $0.undoManager?.canRedo == true } ?? (window.attachedSheet == nil && model.canRedoDraft)
        case #selector(checkForUpdates(_:)): return !checkingUpdates
        default: return true
        }
    }
    /// Runs only from this menu command: one request to the public release list.
    /// It never downloads or installs anything; the user opens the page if they wish.
    @objc private func checkForUpdates(_ sender: Any?) {
        guard !checkingUpdates else { return }
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            showUpdateResult(.failure(.currentVersion), current: ""); return
        }
        checkingUpdates = true
        Task { @MainActor [weak self] in
            let result = await UpdateCheck.check(current: current)
            guard let self else { return }
            self.checkingUpdates = false
            self.showUpdateResult(result, current: current)
        }
    }
    private func showUpdateResult(_ result: Result<UpdateCheck.Outcome, UpdateCheck.Failure>, current: String) {
        let alert = NSAlert()
        var page: URL?
        switch result {
        case .success(.available(let release)):
            alert.messageText = L10n.format("È disponibile Keyglow {0}", [release.tag])
            alert.informativeText = L10n.format(release.prerelease
                ? "Stai usando la versione {0}. La release è contrassegnata come anteprima. Keyglow non scarica né installa nulla: apri la pagina per leggere le note e scegliere."
                : "Stai usando la versione {0}. Keyglow non scarica né installa nulla: apri la pagina per leggere le note e scegliere.", [current])
            page = release.page
        case .success(.upToDate):
            alert.messageText = L10n.string("Keyglow è aggiornato")
            alert.informativeText = L10n.format("La versione {0} è la più recente fra le release pubblicate.", [current])
        case .success(.noRelease):
            alert.messageText = L10n.string("Nessuna release pubblicata")
            alert.informativeText = L10n.string("Puoi controllare la pagina delle release del progetto.")
            page = UpdateCheck.releasesPage
        case .failure(let failure):
            alert.messageText = L10n.string("Controllo aggiornamenti non riuscito")
            switch failure {
            case .network(let reason): alert.informativeText = L10n.string("Verifica la connessione a Internet e riprova.") + "\n" + reason
            case .status(let code): alert.informativeText = L10n.format("GitHub ha risposto con il codice {0}. Riprova più tardi.", [String(code)])
            case .malformed: alert.informativeText = L10n.string("La risposta di GitHub non è nel formato previsto.")
            case .currentVersion: alert.informativeText = L10n.string("La versione di questa copia di Keyglow non è leggibile.")
            }
            page = UpdateCheck.releasesPage
        }
        if page != nil {
            alert.addButton(withTitle: L10n.string("Apri la pagina delle release"))
            alert.addButton(withTitle: L10n.string("Non ora"))
        } else { alert.addButton(withTitle: L10n.string("OK")) }
        if alert.runModal() == .alertFirstButtonReturn, let page { NSWorkspace.shared.open(page) }
    }
    @objc private func compactWindow(_ sender:Any?) { resizeWindow(to:NSSize(width:900,height:640)) }
    @objc private func comfortableWindow(_ sender:Any?) { resizeWindow(to:NSSize(width:1400,height:900)) }
    private func resizeWindow(to size:NSSize) {
        guard !window.styleMask.contains(.fullScreen), let screen=window.screen?.visibleFrame else { return }
        var frame=window.frame
        frame.size=NSSize(width:min(size.width,screen.width),height:min(size.height,screen.height))
        frame.origin.x=max(screen.minX,min(frame.minX,screen.maxX-frame.width))
        frame.origin.y=max(screen.minY,min(window.frame.maxY-frame.height,screen.maxY-frame.height))
        window.setFrame(frame,display:true,animate:!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    @objc private func showSetup(_ sender: Any?) { onboarding.show(parent: window) }
}
