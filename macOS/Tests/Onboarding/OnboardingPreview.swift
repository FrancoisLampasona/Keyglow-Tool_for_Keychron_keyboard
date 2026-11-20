// SPDX-License-Identifier: GPL-2.0-or-later
// Offscreen pictures of the setup guide in synthetic states. No keyboard, no
// system permission, no window on screen: the view is drawn into a bitmap.
import AppKit
import SwiftUI

@MainActor private final class StaticPermissions: OnboardingPermissionServicing {
    let state: OnboardingPermissionState
    init(_ state: OnboardingPermissionState) { self.state = state }
    func checkAccess() -> OnboardingPermissionState { state }
    func requestAccess() -> Bool { false }
    func openSettings() -> Bool { true }
}

@main @MainActor struct OnboardingPreview {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { fputs("usage: onboarding-preview <output-folder> [width height]\n", stderr); exit(2) }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let size = NSSize(width: arguments.count >= 4 ? Double(arguments[2]) ?? 640 : 640, height: arguments.count >= 4 ? Double(arguments[3]) ?? 620 : 620)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let suite = "keyglow.onboarding-preview.volatile"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let iso = SetupKeyboard(id: 1, name: "Keychron Q6 Max", vendor: 0x3434, product: 0x0861, transport: "Bluetooth Low Energy")
        let usb = SetupKeyboard(id: 2, name: "Keychron Q6 Max", vendor: 0x3434, product: 0x0861, transport: "USB")
        let ansi = SetupKeyboard(id: 3, name: "Keychron Q6 Max", vendor: 0x3434, product: 0x0860, transport: "USB")
        let build = FirmwareBuildInfo(buildTimestamp: "2026-01-02 03:04", capabilities: ["rgb-ble-v3-direct", "rgb-ble-persistent"])
        func flow(_ keyboards: [SetupKeyboard], step: Int, select: UInt64? = nil) -> KeyboardSetupModel {
            let model = KeyboardSetupModel(defaults: defaults, inventory: { keyboards }, firmwareVersion: { _ in "" }, firmwareBuild: { build })
            if let select { model.selectedID = select }
            model.step = step
            return model
        }
        func access(_ state: OnboardingPermissionState, visitedSettings: Bool = false) -> OnboardingModel {
            let model = OnboardingModel(permissions: StaticPermissions(state), defaults: defaults,
                                        appURL: URL(fileURLWithPath: "/Applications/Keyglow.app"), appName: "Keyglow")
            if visitedSettings { model.openPrivacySettings() }
            return model
        }
        var scenes = [(String, OnboardingModel, KeyboardSetupModel)]()
        scenes.append(("1-tastiera", access(.denied), flow([iso], step: 0)))
        scenes.append(("1-tastiera-nessuna", access(.denied), flow([], step: 0)))
        scenes.append(("1-tastiera-scelta", access(.denied), flow([iso, usb], step: 0, select: 2)))
        scenes.append(("1-tastiera-non-supportata", access(.denied), flow([ansi], step: 0)))
        scenes.append(("2-accessi", access(.denied), flow([iso], step: 1)))
        scenes.append(("2-accessi-riavvio", access(.denied, visitedSettings: true), flow([iso], step: 1)))
        scenes.append(("2-accessi-consentito", access(.granted), flow([iso], step: 1)))
        scenes.append(("3-firmware-bluetooth", access(.granted), { let m = flow([iso], step: 2); _ = m.beginFirmwareRecognition(); return m }()))
        scenes.append(("3-firmware-riconosciuto", access(.granted), {
            let m = flow([usb], step: 2)
            if let ticket = m.beginFirmwareRecognition() { m.finishFirmwareRecognition(ticket, result: .success("v1.1.1 2026-01-02 03:04")) }
            return m }()))
        scenes.append(("3-firmware-originale", access(.granted), {
            let m = flow([usb], step: 2)
            if let ticket = m.beginFirmwareRecognition() { m.finishFirmwareRecognition(ticket, result: .success("v1.1.1 2025-05-05 10:00")) }
            return m }()))
        scenes.append(("4-riepilogo-installa", access(.granted), { let m = flow([iso], step: 3); m.firmwareChoice = .install; return m }()))
        scenes.append(("4-riepilogo-solo-usb", access(.denied), {
            let m = flow([usb], step: 1); m.advanceWithoutAccess(); m.step = 3; return m }()))

        let languages: [AppLanguage] = arguments.contains("--all-languages") ? AppLanguage.allCases : [.italian]
        for language in languages {
            AppLanguageStore.shared.language = language
            for (name, model, setup) in scenes {
                let view = OnboardingView(model: model, setup: setup, onContinue: {}, onRelaunch: {}, onLater: {}).preferredColorScheme(.dark)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let file = output.appendingPathComponent("\(name)-\(language.rawValue).png")
                try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
                print(file.path)
            }
        }
        AppLanguageStore.shared.language = .italian
        defaults.removePersistentDomain(forName: suite)
        exit(0)
    }
}
