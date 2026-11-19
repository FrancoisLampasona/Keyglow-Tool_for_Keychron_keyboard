// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// Optional app behaviours, all off until the user turns them on. System
/// consent (notifications, login items) is requested only by that action and
/// its state is always read back from macOS, never assumed from preferences.
@MainActor final class AppSettingsModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let batteryAlertsKey = "settings.batteryAlerts"
    static let menuBarKey = "settings.menuBarItem"

    @Published private(set) var batteryAlerts: Bool
    @Published private(set) var batteryAlertMessage = ""
    @Published private(set) var opensAtLogin = false
    @Published private(set) var loginMessage = ""
    @Published private(set) var showsMenuBarItem: Bool
    var onMenuBarChanged: ((Bool) -> Void)?

    private let defaults: UserDefaults
    private var policy = BatteryAlertPolicy()
    private var readings: AnyCancellable?
    /// UserNotifications needs a real application bundle.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        batteryAlerts = defaults.bool(forKey: Self.batteryAlertsKey)
        showsMenuBarItem = defaults.bool(forKey: Self.menuBarKey)
        super.init()
    }

    /// Read-only observation of the readings the app already takes.
    func attach(to monitor: KeyboardStatusMonitor) {
        readings = monitor.$reading.sink { [weak self] reading in
            Task { @MainActor in self?.observe(reading) }
        }
        if batteryAlerts && canNotify { UNUserNotificationCenter.current().delegate = self }
    }
    func refreshSystemState() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "Approva Keyglow in Impostazioni di Sistema → Generali → Elementi login."
        }
        guard batteryAlerts, canNotify else { return }
        Task { @MainActor in
            if await Self.notificationStatus() == .denied {
                batteryAlertMessage = "Le notifiche di Keyglow sono disattivate in Impostazioni di Sistema → Notifiche."
            } else { batteryAlertMessage = "" }
        }
    }

    // MARK: Battery notice
    func setBatteryAlerts(_ enabled: Bool) {
        guard enabled else {
            batteryAlerts = false; defaults.set(false, forKey: Self.batteryAlertsKey)
            policy.reset(); batteryAlertMessage = ""; return
        }
        guard canNotify else { batteryAlertMessage = "Le notifiche richiedono l’app Keyglow installata come applicazione."; return }
        Task { @MainActor in
            // The system prompt appears here, only because the user asked for notices.
            let granted = await Self.requestNotifications()
            batteryAlerts = granted; defaults.set(granted, forKey: Self.batteryAlertsKey)
            policy.reset()
            if granted { UNUserNotificationCenter.current().delegate = self; batteryAlertMessage = "" }
            else { batteryAlertMessage = "Consenti le notifiche a Keyglow in Impostazioni di Sistema → Notifiche, poi riattiva l’avviso." }
        }
    }
    private func observe(_ reading: BatteryReading?) {
        // The monitor clears the reading when the keyboard changes.
        guard let reading else { policy.reset(); return }
        guard batteryAlerts, canNotify, let threshold = policy.evaluate(percent: reading.percent, readAt: reading.date, now: Date()) else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.format("Batteria della Q6 Max al {0}%", [String(reading.percent)])
        content.body = L10n.string(threshold <= 10 ? "Sotto il 10%: collega il cavo per ricaricarla." : "Sotto il 20%: collega il cavo quando puoi.")
        let request = UNNotificationRequest(identifier: "battery-\(threshold)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
    private nonisolated static func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
    }
    private nonisolated static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    /// Show the notice also while Keyglow is the front app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: Open at login
    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = ""
        } catch {
            // Stored in Italian with the system reason verbatim; the view translates the template.
            loginMessage = enabled
                ? "macOS non ha registrato Keyglow per l’avvio al login (\(error.localizedDescription)). Sposta Keyglow nella cartella Applicazioni, verifica che la firma sia valida e riprova."
                : "macOS non ha rimosso Keyglow dall’avvio al login (\(error.localizedDescription)). Puoi farlo da Impostazioni di Sistema → Generali → Elementi login."
        }
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        if status == .requiresApproval { loginMessage = "Approva Keyglow in Impostazioni di Sistema → Generali → Elementi login." }
    }

    // MARK: Menu bar
    func setShowsMenuBarItem(_ enabled: Bool) {
        showsMenuBarItem = enabled; defaults.set(enabled, forKey: Self.menuBarKey)
        onMenuBarChanged?(enabled)
    }
}

/// Small settings panel shown in the Connection page.
struct AppSettingsPanel: View {
    @ObservedObject var settings: AppSettingsModel
    var body: some View {
        StudioSurface {
            PanelTitle(title: "Impostazioni dell’app", subtitle: "Avvisi e avvio. Ogni opzione resta spenta finché non la attivi.")
            option("Avvisa quando la batteria è scarica", isOn: Binding(get: { settings.batteryAlerts }, set: { settings.setBatteryAlerts($0) }),
                   detail: "Una notifica sotto il 20% e una sotto il 10%, solo con una lettura Bluetooth recente e con Keyglow aperta. macOS chiede il consenso alle notifiche quando attivi l’opzione.",
                   message: settings.batteryAlertMessage)
            option("Apri Keyglow al login", isOn: Binding(get: { settings.opensAtLogin }, set: { settings.setOpensAtLogin($0) }),
                   detail: "Lo stato è quello registrato in macOS. Puoi cambiarlo anche da Impostazioni di Sistema → Generali → Elementi login.",
                   message: settings.loginMessage)
        }.onAppear { settings.refreshSystemState() }
    }
    private func option(_ title: String, isOn: Binding<Bool>, detail: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LToggle(title, isOn: isOn).toggleStyle(.checkbox)
            LText(detail).font(.system(size: 12)).foregroundColor(Studio.muted).fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty { LText(message).font(.system(size: 12)).foregroundColor(Studio.accent).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
