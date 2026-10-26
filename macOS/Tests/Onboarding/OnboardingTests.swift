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

@main struct OnboardingTests {
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
        print("Onboarding: 30 checks passed (fake permission service; no system prompts or hardware access).")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
