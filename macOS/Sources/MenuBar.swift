// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine

/// Optional menu bar item, shown only while the user's setting is on.
/// It reads what the app already knows. A color or "lights off" is sent only
/// when the user chooses that item, through the same `send` path and `ready`
/// check as the Lighting page; a profile is only loaded into the draft.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    static let presetColors = ["57D9C1", "FFB65B", "719CFF", "FA81AA", "D5EAF0"]
    static let profileLimit = 12
    private let model: StudioModel
    private let openWindow: () -> Void
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?

    init(model: StudioModel, openWindow: @escaping () -> Void) {
        self.model = model; self.openWindow = openWindow
        super.init()
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            created.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyglow")
            created.button?.imagePosition = .imageLeading
            let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
            created.menu = menu
            item = created
            // Only the title follows the monitor; nothing is read or sent from here.
            subscription = model.batteryMonitor.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.updateTitle() }
            }
            updateTitle()
        } else if !visible, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil; subscription = nil
        }
    }

    /// A percentage is shown only for a current reading of the connected keyboard.
    private var currentReading: BatteryReading? {
        let monitor = model.batteryMonitor
        guard let reading = monitor.reading, reading.isFresh(at: monitor.now), !monitor.failed, monitor.context.connected else { return nil }
        return reading
    }
    private func updateTitle() {
        guard let button = item?.button else { return }
        let title = currentReading.map { " \($0.percent)%" } ?? ""
        if button.title != title { button.title = title }
        button.toolTip = L10n.string(currentReading == nil ? "Keyglow" : "Keyglow · batteria della Q6 Max")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) { let entry = menu.addItem(withTitle: title, action: nil, keyEquivalent: ""); entry.isEnabled = false }
        func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
            let entry = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); entry.target = self; entry.isEnabled = enabled
            return entry
        }
        let monitor = model.batteryMonitor
        info(L10n.string(model.selectedUSBID != nil ? "Q6 Max collegata via USB" : model.available ? "Q6 Max rilevata via Bluetooth" : "Tastiera non rilevata"))
        if let reading = monitor.reading {
            info(L10n.format(currentReading != nil ? "Batteria {0}% · letta alle {1}" : "Batteria {0}% · ultima lettura alle {1}", [String(reading.percent), L10n.date(reading.date)]))
        } else { info(L10n.string("Batteria: nessuna lettura")) }
        _ = action(L10n.string(monitor.isReading ? "Lettura in corso…" : "Aggiorna batteria"), #selector(refreshBattery(_:)),
                   enabled: monitor.context.connected && !monitor.context.paused && !monitor.isReading)
        menu.addItem(.separator())

        // Same gate as the Lighting page: verified access, compatible firmware, no operation running.
        let canSend = model.ready
        info(L10n.string(canSend ? "Invia un colore via Bluetooth" : "Colori non disponibili: apri Keyglow per verificare il collegamento"))
        for hex in Self.presetColors {
            let entry = action("#\(hex)", #selector(sendColor(_:)), enabled: canSend)
            entry.representedObject = hex; entry.image = Self.swatch(hex)
        }
        _ = action(L10n.string("Spegni luci"), #selector(lightsOff(_:)), enabled: canSend)
        menu.addItem(.separator())

        let profiles = model.savedProfiles.filter { $0.deletedAt == nil && !$0.isRecoveryCopy }
        info(L10n.string(profiles.isEmpty ? "Nessun profilo salvato" : "Carica un profilo nella bozza"))
        let canLoad = !model.busy && !model.recording && !model.testing
        for profile in profiles.prefix(Self.profileLimit) {
            // User-given names are shown verbatim.
            let entry = action(profile.name, #selector(loadProfile(_:)), enabled: canLoad)
            entry.representedObject = profile.id
        }
        if profiles.count > Self.profileLimit { info(L10n.format("Altri {0} nella pagina Profili", [String(profiles.count - Self.profileLimit)])) }
        menu.addItem(.separator())
        _ = action(L10n.string("Apri Keyglow"), #selector(open(_:)))
        let quit = menu.addItem(withTitle: L10n.string("Esci da Keyglow"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
    }

    private static func swatch(_ hex: String) -> NSImage? {
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
    }

    @objc private func refreshBattery(_ sender: Any?) { model.batteryMonitor.refresh() }
    @objc private func sendColor(_ sender: NSMenuItem) {
        guard model.ready, let hex = sender.representedObject as? String else { return }
        model.applyHex(hex)
        // A chosen color needs an effect that shows it and that Bluetooth can carry.
        if !model.currentEffect.usesColor || !model.bluetoothEffectSupported { model.workspace.lighting.effect = 1 }
        model.send(off: false)
    }
    @objc private func lightsOff(_ sender: Any?) {
        guard model.ready else { return }
        model.send(off: true)
    }
    @objc private func loadProfile(_ sender: NSMenuItem) {
        guard !model.busy, let id = sender.representedObject as? UUID,
              let profile = model.savedProfiles.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        model.loadProfile(profile)
    }
    @objc private func open(_ sender: Any?) { openWindow() }
}
