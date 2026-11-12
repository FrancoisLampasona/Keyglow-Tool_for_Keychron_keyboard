import Foundation

@MainActor private final class FakePermissions: OnboardingPermissionServicing {
    var state: OnboardingPermissionState = .unknown
    var requestResult = false
    var stateAfterRequest: OnboardingPermissionState?
    var settingsResult = true
    var checks = 0
    var requests = 0
    var settingsOpens = 0
    func checkAccess() -> OnboardingPermissionState { checks += 1; return state }
    func requestAccess() -> Bool {
        requests += 1
        if let stateAfterRequest { state = stateAfterRequest }
        return requestResult
    }
    func openSettings() -> Bool { settingsOpens += 1; return settingsResult }
}

@main @MainActor struct OnboardingTests {
    private static var checks = 0
    @MainActor static func main() {
        let suite = "Keyglow.OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var inventory:[SetupKeyboard]=[]
        let flow=KeyboardSetupModel(defaults:defaults,inventory:{inventory})
        expect(flow.needsPresentation && !flow.supportsSelection, "first-run requires model setup even when macOS already granted access")
        flow.advance(permissionGranted:true)
        expect(flow.step == 0, "missing hardware cannot pass model validation")
        inventory=[SetupKeyboard(id:1,name:"Keychron Q6 Max",vendor:0x3434,product:0x0860,transport:"Bluetooth")]
        flow.scan(); expect(!flow.supportsSelection, "ANSI is never treated as supported ISO")
        inventory=[SetupKeyboard(id:2,name:"Keychron Q6 Max",vendor:0x3434,product:0x0861,transport:"Bluetooth")]
        flow.scan(); expect(flow.supportsSelection, "exact ISO identity can proceed")
        flow.advance(permissionGranted:false); expect(flow.step == 1, "hardware precedes permission step")
        flow.advance(permissionGranted:false); expect(flow.step == 1, "permissions gate firmware planning")
        flow.advance(permissionGranted:true); expect(flow.step == 2, "granted permissions reach firmware explanation, not the workspace")
        flow.advance(permissionGranted:true); expect(flow.step == 3, "firmware plan has an explicit summary")
        inventory=[]
        expect(!flow.complete(permissionGranted:true) && flow.step == 0, "completion rechecks disconnected hardware")
        let supported=SetupKeyboard(id:3,name:"Keychron Q6 Max",vendor:0x3434,product:0x0861,transport:"USB")
        inventory=[supported,SetupKeyboard(id:4,name:"Keychron Q6 Max",vendor:0x3434,product:0x0861,transport:"USB")]
        flow.scan(); expect(flow.selectedID == nil, "multiple keyboards require a user selection")
        flow.selectedID=3; flow.step=3
        expect(!flow.complete(permissionGranted:false) && flow.step == 1, "revoked access cannot complete the wizard")
        flow.step=3; flow.firmwareChoice = .install
        expect(flow.destination == 7, "stock firmware routes to preparation instead of live RGB")
        flow.firmwareChoice = .usb; expect(flow.destination == 6, "USB choice routes to connection")
        flow.firmwareChoice = .installed; expect(flow.destination == 0, "explicit installed choice routes to lighting")
        expect(flow.complete(permissionGranted:true) && !flow.needsPresentation, "completed setup is remembered")
        expect(!SetupKeyboard(id:5,name:"Another keyboard",vendor:0x3434,product:0x0861,transport:"Bluetooth").supported, "PID alone is insufficient")
        expect(!SetupKeyboard(id:5,name:"Keychron Q6 Max",vendor:0x3434,product:0x0861,transport:"Receiver").supported, "unsupported transport is blocked")

        let service = FakePermissions()
        let model = OnboardingModel(permissions: service, defaults: defaults,
                                    appURL: URL(fileURLWithPath: "/Applications/Keyglow.app"), appName: "Keyglow")
        expect(model.needsAutomaticPresentation, "fresh install presents setup")
        expect(service.checks == 1 && service.requests == 0 && service.settingsOpens == 0,
               "model initialization only checks access until setup is presented")
        model.refresh()
        expect(service.requests == 0 && service.settingsOpens == 0, "focus refresh has no permission side effects")

        service.requestResult = true
        service.stateAfterRequest = .denied
        model.requestInputMonitoring()
        expect(service.requests == 1, "explicit request calls the service once")
        expect(!model.canContinue && !model.completeSetup(), "request return value never overrides a denied system check")
        expect(defaults.integer(forKey: OnboardingModel.completedKey) == 0, "denied access cannot mark setup complete")

        model.deferSetup()
        expect(model.needsAutomaticPresentation, "missing access presents setup again next launch despite deferral")
        expect(defaults.integer(forKey: OnboardingModel.completedKey) == 0, "deferral does not record a completed setup")

        service.requestResult = false
        service.stateAfterRequest = .granted
        model.requestInputMonitoring()
        expect(model.canContinue, "current system status is authoritative even if request returned false")
        let requestCount = service.requests
        model.requestInputMonitoring()
        expect(service.requests == requestCount, "granted access is not requested again")
        service.state = .denied
        expect(!model.completeSetup(), "completion rechecks a permission revoked while the sheet was open")

        service.state = .granted
        expect(model.completeSetup(), "granted access completes setup")
        expect(defaults.integer(forKey: OnboardingModel.completedKey) == OnboardingModel.setupVersion, "completion persists its version")
        service.state = .denied
        let relocated = OnboardingModel(permissions: service, defaults: defaults,
                                        appURL: URL(fileURLWithPath: "/tmp/Moved Apps/Keyglow.app"), appName: "Keyglow")
        expect(relocated.needsAutomaticPresentation, "revoked access presents setup despite remembered completion")
        expect(!relocated.canContinue, "remembered completion never grants current access")
        expect(relocated.appURL.path == "/tmp/Moved Apps/Keyglow.app", "application location comes from the running bundle")

        service.settingsResult = false
        relocated.openPrivacySettings()
        expect(!relocated.message.isEmpty && service.settingsOpens == 1, "failed settings link offers manual navigation")
        expect(!relocated.canContinue, "opening Settings never implies approval")
        service.state = .unavailable
        relocated.refresh()
        expect(!relocated.canContinue, "unknown API results fail closed")

        let pendingService = FakePermissions()
        let pending = OnboardingModel(permissions: pendingService, defaults: defaults)
        pending.beginAutomaticSetup()
        expect(pendingService.requests == 1, "presenting setup automatically requests missing access")
        expect(pendingService.settingsOpens == 0, "a pending or unknown native prompt is not covered by Settings")
        pending.refresh()
        pending.beginAutomaticSetup()
        expect(pendingService.requests == 1 && pendingService.settingsOpens == 0,
               "focus and repeated presentation do not loop requests or Settings")

        let deniedService = FakePermissions()
        deniedService.state = .denied
        let denied = OnboardingModel(permissions: deniedService, defaults: defaults)
        denied.beginAutomaticSetup()
        expect(deniedService.requests == 1 && deniedService.settingsOpens == 1,
               "denied access requests once and opens the privacy page automatically")
        denied.refresh()
        denied.beginAutomaticSetup()
        expect(deniedService.requests == 1 && deniedService.settingsOpens == 1,
               "returning from Settings does not reopen Settings")
        denied.deferSetup()
        let nextLaunch = OnboardingModel(permissions: deniedService, defaults: defaults)
        expect(nextLaunch.needsAutomaticPresentation, "deferral never suppresses setup on a later denied launch")
        nextLaunch.beginAutomaticSetup()
        expect(deniedService.requests == 2 && deniedService.settingsOpens == 2,
               "a new launch gets one new automatic setup attempt")

        let unavailableService = FakePermissions()
        unavailableService.state = .unavailable
        let unavailable = OnboardingModel(permissions: unavailableService, defaults: defaults)
        unavailable.beginAutomaticSetup()
        expect(unavailableService.requests == 1 && unavailableService.settingsOpens == 1,
               "unavailable access opens the privacy page after requesting")

        let grantedService = FakePermissions()
        grantedService.state = .granted
        let granted = OnboardingModel(permissions: grantedService, defaults: defaults,
                                      appURL: URL(fileURLWithPath: "/tmp/Moved Apps/Keyglow.app"))
        expect(!granted.needsAutomaticPresentation, "completed setup and permission survive app relocation")
        granted.beginAutomaticSetup()
        expect(grantedService.requests == 0 && grantedService.settingsOpens == 0,
               "already granted access skips all automatic permission actions")

        let approvedService = FakePermissions()
        approvedService.stateAfterRequest = .granted
        let approved = OnboardingModel(permissions: approvedService, defaults: defaults)
        approved.beginAutomaticSetup()
        expect(approved.canContinue && approvedService.requests == 1 && approvedService.settingsOpens == 0,
               "native approval completes the request without opening Settings")
        let freshDefaults = UserDefaults(suiteName: suite + ".fresh")!
        defer { freshDefaults.removePersistentDomain(forName: suite + ".fresh") }
        let alreadyGranted = OnboardingModel(permissions: grantedService, defaults: freshDefaults)
        expect(!alreadyGranted.needsAutomaticPresentation, "a fresh install with current consent does not show a redundant modal")
        alreadyGranted.updateDeviceState(.notConnected)
        expect(alreadyGranted.canContinue, "disconnected keyboard does not negate macOS consent or block entry")
        alreadyGranted.updateDeviceState(.unavailable("Lettura non riuscita"))
        expect(alreadyGranted.permission == .granted && alreadyGranted.canContinue, "read failure remains separate from system permission")

        // Input Monitoring reaches only a relaunched process: the guide must resume.
        let relaunchSuite = suite + ".relaunch"
        let relaunchDefaults = UserDefaults(suiteName: relaunchSuite)!
        defer { relaunchDefaults.removePersistentDomain(forName: relaunchSuite) }
        let iso = SetupKeyboard(id:20,name:"Keychron Q6 Max",vendor:0x3434,product:0x0861,transport:"USB")
        var relaunchInventory = [iso]
        let before = KeyboardSetupModel(defaults:relaunchDefaults,inventory:{relaunchInventory})
        expect(!before.hasResumePoint && !before.restoreResumePoint() && before.step == 0, "a normal launch starts the guide at the keyboard step")
        before.advance(permissionGranted:false); before.firmwareChoice = .usb
        before.saveResumePoint()
        let after = KeyboardSetupModel(defaults:relaunchDefaults,inventory:{relaunchInventory})
        expect(after.hasResumePoint && after.step == 0, "the saved point is only applied when the guide is presented")
        expect(after.restoreResumePoint() && after.step == 1 && after.firmwareChoice == .usb, "relaunch resumes at the access step with the firmware choice")
        expect(!after.hasResumePoint && !after.restoreResumePoint(), "the resume point is consumed once")
        after.advance(permissionGranted:false); expect(after.step == 1, "a resumed guide still needs the current system permission")
        after.advance(permissionGranted:true); expect(after.step == 2 && !after.skippedAccess, "granted access after relaunch continues normally")
        before.step = 1; before.saveResumePoint(); relaunchInventory = []
        let unplugged = KeyboardSetupModel(defaults:relaunchDefaults,inventory:{relaunchInventory})
        expect(!unplugged.restoreResumePoint() && unplugged.step == 0 && !unplugged.hasResumePoint, "resume never skips model validation when the keyboard is gone")
        relaunchInventory = [iso, SetupKeyboard(id:21,name:"Keychron Q6 Max",vendor:0x3434,product:0x0861,transport:"USB")]
        before.scan(); before.selectedID = 21; before.step = 1; before.saveResumePoint()
        let chosen = KeyboardSetupModel(defaults:relaunchDefaults,inventory:{relaunchInventory})
        expect(chosen.restoreResumePoint() && chosen.selectedID == 21, "the selected keyboard survives the relaunch when still connected")

        let relaunchService = FakePermissions()
        relaunchService.state = .denied
        let waiting = OnboardingModel(permissions: relaunchService, defaults: relaunchDefaults)
        expect(!waiting.needsRelaunch, "relaunch is not suggested before the user has visited Settings")
        waiting.refresh(); expect(!waiting.needsRelaunch, "a plain recheck does not suggest relaunch")
        waiting.openPrivacySettings(); expect(waiting.needsRelaunch, "after opening Settings the main action is quit and reopen")
        relaunchService.state = .granted; waiting.refresh()
        expect(!waiting.needsRelaunch && waiting.canContinue, "a visible grant clears the relaunch suggestion")
        relaunchService.state = .denied
        let returned = OnboardingModel(permissions: relaunchService, defaults: relaunchDefaults)
        returned.noteReturnedToApp(); expect(returned.needsRelaunch && !returned.canContinue, "returning to the app without a visible grant suggests relaunch")
        let prompted = OnboardingModel(permissions: relaunchService, defaults: relaunchDefaults)
        prompted.requestInputMonitoring(); expect(prompted.needsRelaunch, "an unanswered or denied request also leads to relaunch")

        // USB-only: continue without Input Monitoring, never recorded as granted.
        let usbSuite = suite + ".usbonly"
        let usbDefaults = UserDefaults(suiteName: usbSuite)!
        defer { usbDefaults.removePersistentDomain(forName: usbSuite) }
        let usbFlow = KeyboardSetupModel(defaults:usbDefaults,inventory:{[iso]})
        usbFlow.advanceWithoutAccess(); expect(usbFlow.step == 0 && !usbFlow.skippedAccess, "skipping access is only offered at the access step")
        usbFlow.advance(permissionGranted:false); usbFlow.advanceWithoutAccess()
        expect(usbFlow.step == 2 && usbFlow.skippedAccess && usbFlow.firmwareChoice == .usb, "continue without access reaches firmware with the USB choice")
        usbFlow.advance(permissionGranted:false); expect(usbFlow.step == 3, "the summary is reachable without access")
        let usbService = FakePermissions(); usbService.state = .denied
        let usbModel = OnboardingModel(permissions: usbService, defaults: usbDefaults)
        expect(!usbModel.completeSetup(), "missing access still blocks a normal completion")
        expect(usbModel.completeSetup(withoutAccess:true) && usbFlow.complete(permissionGranted:usbModel.canContinue), "USB-only setup completes without the permission")
        expect(usbModel.permission == .denied && !usbModel.canContinue, "completing without access never marks the permission as granted")
        expect(usbDefaults.integer(forKey: OnboardingModel.completedKey) == 0, "permission setup is not recorded as completed")
        expect(!usbFlow.needsPresentation && usbFlow.destination == 6, "USB-only setup is remembered and routes to Connection")
        let usbNextLaunch = OnboardingModel(permissions: usbService, defaults: usbDefaults)
        expect(!usbNextLaunch.needsAutomaticPresentation && !usbNextLaunch.canContinue, "the USB-only choice stops the automatic guide without granting access")
        usbService.state = .granted
        expect(usbNextLaunch.completeSetup() && !usbNextLaunch.continuesWithoutAccess, "a later real grant replaces the USB-only choice")
        usbService.state = .denied
        expect(OnboardingModel(permissions: usbService, defaults: usbDefaults).needsAutomaticPresentation, "revocation after a real grant presents the guide again")
        let strict = KeyboardSetupModel(defaults:usbDefaults,inventory:{[iso]})
        strict.step = 3
        expect(!strict.complete(permissionGranted:false) && strict.step == 1, "without the explicit choice, missing access still returns to the access step")
        strict.advanceWithoutAccess(); strict.step = 1; strict.advance(permissionGranted:true)
        expect(!strict.skippedAccess, "a real grant clears the skipped-access state")

        var verification = OnboardingAccessVerification()
        expect(verification.begin(permission: .granted, deviceID: nil, busy: false) == nil, "consent without a unique device cannot start a read")
        expect(!verification.isVerified, "consent alone never establishes device access")
        for state in [OnboardingPermissionState.unknown, .denied, .unavailable] {
            expect(verification.begin(permission: state, deviceID: 10, busy: false) == nil, "missing consent forbids hardware preflight")
        }
        let first = verification.begin(permission: .granted, deviceID: 10, busy: false)!
        expect(!verification.isVerified && verification.active == first, "a read must finish before access becomes ready")
        expect(verification.begin(permission: .granted, deviceID: 10, busy: true) == nil && !verification.refreshPending,
               "repeated activation during the same read neither overlaps nor duplicates it")
        expect(verification.complete(first, succeeded: true, permission: .granted, deviceID: 10), "fresh same-device successful read establishes access")
        expect(verification.isVerified, "read evidence stays bound to this device")
        expect(verification.canReuseCurrentRead(permission: .granted, deviceID: 10) && verification.active == nil,
               "color-panel activation with fresh consent and identical device preserves current read without a new busy operation")
        expect(verification.canReuseCurrentRead(permission: .granted, deviceID: 10) && !verification.refreshPending,
               "repeated activation does not queue redundant preflight reads")
        var forced = verification
        expect(forced.begin(permission: .granted, deviceID: 10, busy: false) != nil && !forced.isVerified,
               "explicit verify or wake can force a fresh read despite matching evidence")
        var changedIdentity = verification
        expect(!changedIdentity.canReuseCurrentRead(permission: .granted, deviceID: 12) && !changedIdentity.isVerified,
               "a new registry identity cannot reuse the previous device's evidence")
        expect(!verification.canReuseCurrentRead(permission: .denied, deviceID: 10) && !verification.isVerified,
               "fresh permission revocation is never masked by the activation fast path")
        expect(!verification.canReuseCurrentRead(permission: .granted, deviceID: 10),
               "regrant after revocation cannot recover cached proof")
        verification.observe(permission: .denied, deviceID: 10)
        expect(!verification.isVerified, "permission revocation immediately invalidates device access")
        verification.observe(permission: .granted, deviceID: 10)
        expect(!verification.isVerified, "regrant requires a new read rather than cached success")
        let revoked = verification.begin(permission: .granted, deviceID: 10, busy: false)!
        expect(!verification.complete(revoked, succeeded: true, permission: .denied, deviceID: 10), "revocation during a successful read rejects stale success")
        let changed = verification.begin(permission: .granted, deviceID: 10, busy: false)!
        expect(!verification.complete(changed, succeeded: true, permission: .granted, deviceID: 11), "device replacement during a read rejects its result")
        expect(verification.refreshPending && verification.takeDeferredRefresh() && !verification.takeDeferredRefresh(), "replacement requests exactly one deferred verification")
        let replacement = verification.begin(permission: .granted, deviceID: 11, busy: false)!
        expect(!verification.complete(changed, succeeded: true, permission: .granted, deviceID: 11) && verification.active == replacement,
               "late callbacks cannot finish another device's read")
        expect(!verification.complete(replacement, succeeded: false, permission: .granted, deviceID: 11), "granted permission cannot override a read failure")
        expect(!verification.isVerified, "failed read never enables writes")
        expect(verification.begin(permission: .granted, deviceID: 11, busy: true) == nil && verification.refreshPending && verification.active == nil,
               "RGB or OTA occupancy postpones verification without opening HID")
        expect(verification.takeDeferredRefresh(), "verification resumes once the existing operation ends")
        let resumed = verification.begin(permission: .granted, deviceID: 11, busy: false)!
        expect(verification.complete(resumed, succeeded: true, permission: .granted, deviceID: 11), "deferred read can establish fresh access")
        verification.invalidateEvidence()
        expect(!verification.isVerified, "a later transport failure discards previous successful evidence")
        let transient = verification.begin(permission: .granted, deviceID: 11, busy: false)!
        verification.observe(permission: .denied, deviceID: 11)
        verification.observe(permission: .granted, deviceID: 11)
        expect(!verification.complete(transient, succeeded: true, permission: .granted, deviceID: 11), "revoke/regrant during a read invalidates its generation")
        let lost = verification.begin(permission: .granted, deviceID: 11, busy: false)!
        expect(!verification.complete(lost, succeeded: true, permission: .granted, deviceID: nil) && !verification.isVerified,
               "disconnect during read cannot leave access enabled")
        verification.deferRefresh()
        expect(verification.takeDeferredRefresh(), "wake while another operation is busy can defer discovery even with no prior device")
        print("Onboarding: \(checks) checks passed (fake permission service; no system prompts or hardware access).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
