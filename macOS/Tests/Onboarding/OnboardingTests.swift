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
