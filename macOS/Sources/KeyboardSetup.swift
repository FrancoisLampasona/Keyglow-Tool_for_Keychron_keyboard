import Combine
import Foundation
import IOKit
import IOKit.hid

struct SetupKeyboard: Equatable, Identifiable, Sendable {
    let id: UInt64
    let name: String
    let vendor: Int
    let product: Int
    let transport: String
    var supported: Bool {
        vendor == 0x3434 && product == 0x0861 && name == "Keychron Q6 Max" &&
        ["usb", "bluetooth", "bluetooth low energy"].contains(transport.lowercased())
    }
    var modelTitle: String {
        if vendor == 0x3434 && name == "Keychron Q6 Max" {
            if product == 0x0861 { return "Keychron Q6 Max · ISO" }
            if product == 0x0860 { return "Keychron Q6 Max · ANSI" }
        }
        return name.isEmpty ? "Tastiera Keychron" : name
    }
}

/// Discovery reads public HID identity only: no device open, report callbacks,
/// consent request, serial number or write. Multiple keyboards require a choice.
enum SystemSetupKeyboards {
    static func scan() -> [SetupKeyboard] {
        let manager=IOHIDManagerCreate(kCFAllocatorDefault,IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x3434,
            kIOHIDPrimaryUsagePageKey:1,kIOHIDPrimaryUsageKey:6] as CFDictionary)
        let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.compactMap { device in
            func number(_ key:String)->Int { (IOHIDDeviceGetProperty(device,key as CFString) as? NSNumber)?.intValue ?? -1 }
            func string(_ key:String)->String { IOHIDDeviceGetProperty(device,key as CFString) as? String ?? "" }
            var id:UInt64=0
            let service=IOHIDDeviceGetService(device)
            guard service != 0, IORegistryEntryGetRegistryEntryID(service,&id) == KERN_SUCCESS else { return nil }
            return SetupKeyboard(id:id,name:string(kIOHIDProductKey),vendor:number(kIOHIDVendorIDKey),
                                 product:number(kIOHIDProductIDKey),transport:string(kIOHIDTransportKey))
        }.sorted { $0.id < $1.id }
    }
}

enum SetupFirmwareChoice: String, CaseIterable {
    case install, installed, usb
    var title:String {
        switch self {
        case .install: "Voglio usare Bluetooth · devo installare Keyglow"
        case .installed: "Ho già installato il firmware Keyglow"
        case .usb: "Per ora uso la configurazione via USB"
        }
    }
}

@MainActor final class KeyboardSetupModel: ObservableObject {
    static let completionKey="onboarding.keyboardFlowVersion"
    static let version=1
    static let resumeStepKey="onboarding.resumeStep"
    static let resumeChoiceKey="onboarding.resumeFirmwareChoice"
    static let resumeKeyboardKey="onboarding.resumeKeyboard"
    @Published var step=0
    /// Session-only: the user chose to go on with USB without Input Monitoring.
    @Published private(set) var skippedAccess=false
    @Published private(set) var keyboards:[SetupKeyboard]=[]
    @Published var selectedID:UInt64?
    @Published var firmwareChoice:SetupFirmwareChoice = .install
    private let defaults:UserDefaults
    private let inventory:()->[SetupKeyboard]
    init(defaults:UserDefaults = .standard, inventory:@escaping ()->[SetupKeyboard] = SystemSetupKeyboards.scan) {
        self.defaults=defaults; self.inventory=inventory
        // A remembered choice is shown as a declaration, never a firmware readback.
        if defaults.bool(forKey:"bluetooth.directV3") { firmwareChoice = .installed }
        scan()
    }
    var selected:SetupKeyboard? { keyboards.first { $0.id == selectedID } }
    var supportsSelection:Bool { selected?.supported == true }
    var needsPresentation:Bool { defaults.integer(forKey:Self.completionKey) < Self.version }
    var destination:Int { firmwareChoice == .installed ? 0 : firmwareChoice == .usb ? 6 : 7 }
    func scan() {
        keyboards=inventory()
        if !keyboards.contains(where:{$0.id == selectedID}) { selectedID=nil }
        // Do not silently select one of several connected keyboards.
        if selectedID == nil && keyboards.count == 1 { selectedID=keyboards[0].id }
    }
    func advance(permissionGranted:Bool) {
        guard (step == 0 && supportsSelection) || (step == 1 && permissionGranted) || step == 2 else { return }
        if step == 1 { skippedAccess=false }
        step += 1
    }
    /// USB configuration does not use Input Monitoring. Nothing is recorded as granted.
    func advanceWithoutAccess() {
        guard step == 1, supportsSelection else { return }
        skippedAccess=true; firmwareChoice = .usb; step=2
    }
    /// Input Monitoring applies only to a process started after the grant, so the
    /// guide must survive a relaunch at the access step.
    func saveResumePoint() {
        defaults.set(step,forKey:Self.resumeStepKey)
        defaults.set(firmwareChoice.rawValue,forKey:Self.resumeChoiceKey)
        if let selectedID { defaults.set(String(selectedID),forKey:Self.resumeKeyboardKey) }
        else { defaults.removeObject(forKey:Self.resumeKeyboardKey) }
    }
    var hasResumePoint:Bool { defaults.object(forKey:Self.resumeStepKey) != nil }
    /// Consumes the saved point once. Hardware is rescanned; the permission is
    /// never restored from preferences. Returns false when the guide starts over.
    @discardableResult func restoreResumePoint() -> Bool {
        guard hasResumePoint else { return false }
        let saved=defaults.integer(forKey:Self.resumeStepKey)
        let choice=defaults.string(forKey:Self.resumeChoiceKey).flatMap(SetupFirmwareChoice.init(rawValue:))
        let keyboard=defaults.string(forKey:Self.resumeKeyboardKey).flatMap { UInt64($0) }
        for key in [Self.resumeStepKey,Self.resumeChoiceKey,Self.resumeKeyboardKey] { defaults.removeObject(forKey:key) }
        scan()
        if selectedID == nil, let keyboard, keyboards.contains(where:{$0.id == keyboard}) { selectedID=keyboard }
        if let choice { firmwareChoice=choice }
        guard saved >= 1, supportsSelection else { step=0; return false }
        step=1; return true
    }
    @discardableResult func complete(permissionGranted:Bool) -> Bool {
        scan()
        guard supportsSelection else { step=0; return false }
        guard permissionGranted || skippedAccess else { step=1; return false }
        guard step == 3 else { return false }
        defaults.set(Self.version,forKey:Self.completionKey)
        return true
    }
}
