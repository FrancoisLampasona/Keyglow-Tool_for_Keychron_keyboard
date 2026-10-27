// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import CoreBluetooth
import OSLog

/// App-owned, read-only monitoring. Visibility and keyboard focus never gate it.
/// No HID writes, scanning, owner-key access or automatic consent prompts.
@MainActor final class KeyboardStatusMonitor: ObservableObject {
    @Published private(set) var reading: BatteryReading?
    @Published private(set) var now = Date()
    @Published private(set) var failed = false
    @Published private(set) var isReading = false
    @Published private(set) var message = ""
    @Published private(set) var authorization: CBManagerAuthorization = .notDetermined
    private(set) var context = BatteryRefreshContext(connected:false, paused:false)
    private var lastAttempt: Date?
    private var readDeviceID: UInt64?
    private var awaitingExplicitConsent = false
    private var sleeping = false
    private var started = false
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var snapshot: (() -> BatteryRefreshContext)?
    private var refreshConnection: (() -> Void)?
    private let reader: any BatteryStatusReading
    private let clock: () -> Date
    private let permission: () -> CBManagerAuthorization
    private let log = Logger(subsystem:"local.tastiera.bluetooth-prototype", category:"KeyboardStatus")

    init(reader: any BatteryStatusReading = BluetoothFirmwareInspector(),
         clock: @escaping () -> Date = Date.init,
         permission: @escaping () -> CBManagerAuthorization = { CBCentralManager.authorization }) {
        self.reader=reader; self.clock=clock; self.permission=permission
        reader.onFinish = { [weak self] result, message, cancelled in
            self?.finished(result, message:message, cancelled:cancelled)
        }
    }

    func configure(snapshot: @escaping () -> BatteryRefreshContext, refreshConnection: @escaping () -> Void) {
        self.snapshot=snapshot; self.refreshConnection=refreshConnection
    }

    func start() {
        guard !started else { return }
        started=true
        let timer=Timer(timeInterval:5, repeats:true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance=1
        RunLoop.main.add(timer, forMode:.common)
        self.timer=timer
        tick()
    }

    func stop() {
        started=false; timer?.invalidate(); timer=nil
        reader.cancel(); isReading=false
        endActivity()
    }

    func setSleeping(_ value: Bool) {
        sleeping=value
        if !value { lastAttempt=nil }
        if value { reconcile() } else { tick() }
    }

    /// Called synchronously before device operations start, and after they finish.
    func reconcile() {
        guard started, var next=snapshot?() else { return }
        next.sleeping=sleeping
        let previous=context
        context=next; now=clock(); authorization=permission()
        let changedDevice = previous.connected != next.connected || previous.deviceID != next.deviceID
        if changedDevice {
            reading=nil; failed=false; lastAttempt=nil
            reader.cancel()
        }
        if changedDevice || previous.usbConnected != next.usbConnected {
            log.debug("Connection changed: bluetooth=\(next.connected) usb=\(next.usbConnected) foreground=\(NSApp?.isActive ?? false)")
        }
        let pendingConsent = awaitingExplicitConsent && authorization == .notDetermined
        if !next.canRead || (authorization != .allowedAlways && !pendingConsent) { reader.cancel() }
        if next.shouldRefreshConnection {
            // Keeps monitoring responsive when minimized without preventing Mac sleep.
            // Balanced on pause, sleep and termination; no global App Nap setting.
            if activity == nil {
                activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,
                    reason:"Keep keyboard connection and battery status current")
            }
        } else { endActivity() }
    }

    func tick() {
        guard started else { return }
        reconcile()
        if context.shouldRefreshConnection { refreshConnection?(); reconcile() }
        if context.shouldRefresh(authorized:authorization == .allowedAlways, running:reader.isRunning,
                                 lastAttempt:lastAttempt, now:now) { refresh(allowPermissionPrompt:false) }
    }

    func refresh(allowPermissionPrompt: Bool = true) {
        reconcile()
        guard started, context.canRead, !reader.isRunning,
              authorization == .allowedAlways || (allowPermissionPrompt && authorization == .notDetermined) else { return }
        lastAttempt=clock(); readDeviceID=context.deviceID; failed=false; isReading=true
        awaitingExplicitConsent = allowPermissionPrompt && authorization == .notDetermined
        reader.start(batteryOnly:true)
    }

    private func finished(_ result: BluetoothFirmwareInspection?, message: String, cancelled: Bool) {
        isReading=false; awaitingExplicitConsent=false; now=clock(); self.message=message
        if cancelled { failed=false; lastAttempt=nil; return }
        // Never publish a result from a detached/replaced device or paused session.
        guard started, context.canRead, readDeviceID == context.deviceID else { return }
        if let result, let percent=result.batteryPercent, (0...100).contains(percent) {
            reading=BatteryReading(percent:percent,date:result.inspectedAt); failed=false
            log.debug("Battery read: percent=\(percent) foreground=\(NSApp?.isActive ?? false)")
        } else { failed=true }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity=nil }
    }
}
