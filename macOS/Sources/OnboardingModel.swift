import AppKit
import Combine
import Foundation
import IOKit

enum OnboardingPermissionState: Equatable {
    case unknown, denied, granted, unavailable
}

@MainActor protocol OnboardingPermissionServicing {
    func checkAccess() -> OnboardingPermissionState
    func requestAccess() -> Bool
    func openSettings() -> Bool
}

@MainActor struct SystemOnboardingPermissions: OnboardingPermissionServicing {
    func checkAccess() -> OnboardingPermissionState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        case kIOHIDAccessTypeUnknown: return .unknown
        default: return .unavailable
        }
    }

    func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func openSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Setup preferences record presentation, never the user's current system permission.
@MainActor final class OnboardingModel: ObservableObject {
    static let setupVersion = 1
    static let presentedKey = "onboarding.presentedVersion"
    static let completedKey = "onboarding.completedVersion"

    @Published private(set) var permission: OnboardingPermissionState = .unknown
    @Published private(set) var isRequesting = false
    @Published private(set) var message = ""
    let appURL: URL
    let appName: String
    private let permissions: any OnboardingPermissionServicing
    private let defaults: UserDefaults
    private var attemptedAutomaticSetup = false

    init(permissions: (any OnboardingPermissionServicing)? = nil,
         defaults: UserDefaults = .standard,
         appURL: URL = Bundle.main.bundleURL,
         appName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Keyglow") {
        self.permissions = permissions ?? SystemOnboardingPermissions()
        self.defaults = defaults
        self.appURL = appURL
        self.appName = appName
        refresh()
    }

    var needsAutomaticPresentation: Bool {
        permission != .granted || defaults.integer(forKey: Self.presentedKey) < Self.setupVersion
    }
    var canContinue: Bool { permission == .granted && !isRequesting }

    func refresh() {
        permission = permissions.checkAccess()
        if permission == .granted { message = "" }
    }

    /// Run once when setup opens. Focus changes only refresh; they never restart this flow.
    func beginAutomaticSetup() {
        refresh()
        guard permission != .granted, !attemptedAutomaticSetup else { return }
        attemptedAutomaticSetup = true
        requestInputMonitoring()
        // Unknown may mean the system prompt is still pending. Do not cover it with Settings.
        if permission == .denied || permission == .unavailable { openPrivacySettings() }
    }

    /// Also available as an explicit retry when the native prompt has not completed.
    func requestInputMonitoring() {
        guard !isRequesting else { return }
        refresh()
        guard permission != .granted else { return }
        isRequesting = true
        _ = permissions.requestAccess()
        isRequesting = false
        refresh()
        if permission == .unknown {
            message = "Conferma la richiesta di macOS. Se il messaggio non compare, apri Impostazioni."
        } else if permission != .granted {
            message = "Conferma l’accesso in Impostazioni di Sistema. Se macOS lo richiede, chiudi e riapri \(appName)."
        }
    }

    func openPrivacySettings() {
        message = permissions.openSettings() ? "" : "Apri Impostazioni di Sistema → Privacy e sicurezza → Monitoraggio input."
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    func deferSetup() {
        defaults.set(Self.setupVersion, forKey: Self.presentedKey)
    }

    @discardableResult func completeSetup() -> Bool {
        // Recheck at the point of use: permission can be revoked while this window is open.
        refresh()
        guard canContinue else { return false }
        defaults.set(Self.setupVersion, forKey: Self.presentedKey)
        defaults.set(Self.setupVersion, forKey: Self.completedKey)
        return true
    }
}
