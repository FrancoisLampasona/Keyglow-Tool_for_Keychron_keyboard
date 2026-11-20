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
                let view = OnboardingView(model: model, setup: setup, firmware: FirmwareUpdateModel(), onContinue: {}, onRelaunch: {}, onLater: {}).preferredColorScheme(.dark)
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
        // Firmware card and sidebar keyboard status, with injected readings only.
        func render<V: View>(_ view: V, width: CGFloat, name: String) {
            let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true).padding(16)
                .background(Studio.background).foregroundColor(Studio.text).font(.system(size: 13)).tint(Studio.accent).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 32, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
            host.layoutSubtreeIfNeeded()
            let fitted = host.fittingSize
            host.frame = NSRect(origin: .zero, size: NSSize(width: width + 32, height: max(40, fitted.height)))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let file = output.appendingPathComponent(name)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
            print(file.path)
        }
        func wait(_ model: FirmwareUpdateModel) { while model.isBusy { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        let stamp = Date(timeIntervalSince1970: 1_795_000_000)
        let record = FirmwareVersionRecord(isKeyglow: true, version: "v1.1.1 2026-01-02 03:04", via: "USB", date: stamp)
        var readings = [(String, FirmwareUpdateModel, Bool)]()
        readings.append(("mai-letto", FirmwareUpdateModel(previewRecord: nil), false))
        readings.append(("ultima-lettura", FirmwareUpdateModel(previewRecord: record), false))
        let keyglow = FirmwareUpdateModel(previewRecord: nil); keyglow.recordUSBReading(version: "v1.1.1 2026-01-02 03:04", isKeyglow: true, at: stamp)
        readings.append(("usb-keyglow", keyglow, true))
        let other = FirmwareUpdateModel(previewRecord: nil); other.recordUSBReading(version: "v1.1.1 2025-05-05 10:00", isKeyglow: false, at: stamp)
        readings.append(("usb-altro", other, true))
        let responding = FirmwareUpdateModel(previewRecord: record); responding.checkInstalledFirmware(usb: nil, isKeyglow: { _ in true }); wait(responding)
        readings.append(("bluetooth-rilevato", responding, false))
        let silent = FirmwareUpdateModel(bluetoothIdentify: { _, _ in throw OTAChannelFailure.deadline }); silent.checkInstalledFirmware(usb: nil, isKeyglow: { _ in true }); wait(silent)
        readings.append(("bluetooth-silenzio", silent, false))
        let checking = FirmwareUpdateModel(bluetoothIdentify: { _, token in while !token.isCancelled { Thread.sleep(forTimeInterval: 0.05) }; return .responding })
        checking.checkTimeout = 600; checking.checkInstalledFirmware(usb: nil, isKeyglow: { _ in true })
        readings.append(("controllo-in-corso", checking, false))
        for language in languages {
            AppLanguageStore.shared.language = language
            for (name, model, usb) in readings {
                for width in [CGFloat(672), 872] {
                    render(InstalledFirmwareCard(updater: model, usbConnected: usb, busy: model.isBusy, onCheck: {}), width: width, name: "firmware-\(name)-\(Int(width))-\(language.rawValue).png")
                }
            }
            let links: [(String, SidebarDeviceStatus.Link, FirmwareUpdateModel)] = [("non-collegata", .none, readings[0].1), ("bluetooth-accesso", .bluetoothNeedsAccess, readings[0].1),
                ("bluetooth-pronta", .bluetoothReady, readings[1].1), ("usb-letta", .usbRead, keyglow), ("usb-da-leggere", .usbDetected, other)]
            for (name, link, model) in links {
                for width in [CGFloat(156), 184] {
                    render(SidebarDeviceStatus(updater: model, link: link, onOpen: {}), width: width, name: "barra-\(name)-\(Int(width))-\(language.rawValue).png")
                }
            }
        }
        AppLanguageStore.shared.language = .italian
        defaults.removePersistentDomain(forName: suite)
        exit(0)
    }
}
