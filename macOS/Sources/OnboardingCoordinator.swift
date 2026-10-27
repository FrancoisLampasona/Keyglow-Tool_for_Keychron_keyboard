import AppKit
import SwiftUI

@MainActor final class OnboardingCoordinator: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    let setup = KeyboardSetupModel()
    var onCompletion: ((SetupFirmwareChoice, Int) -> Void)?
    private var setupWindow: NSWindow?

    init(model: OnboardingModel? = nil) {
        self.model = model ?? OnboardingModel()
        super.init()
    }

    func showIfNeeded(parent: NSWindow) {
        model.refresh()
        guard model.needsAutomaticPresentation || setup.needsPresentation else { return }
        show(parent: parent)
    }

    func show(parent: NSWindow) {
        model.refresh()
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            return
        }
        setup.scan(); setup.step=0
        let available = availableSheetSize(parent: parent)
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: available),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sheet.contentMinSize = NSSize(width: min(480, available.width), height: min(480, available.height))
        sheet.title = "Configura \(model.appName)"
        sheet.isReleasedWhenClosed = false
        sheet.delegate = self
        sheet.contentView = NSHostingView(rootView: OnboardingView(model: model, setup:setup, onContinue: { [weak self] in
            guard let self else { return }
            self.model.refresh()
            if self.setup.step < 3 {
                self.setup.advance(permissionGranted:self.model.canContinue)
                if self.setup.step == 1 { self.model.beginAutomaticSetup() }
                return
            }
            guard self.model.completeSetup(), self.setup.complete(permissionGranted:self.model.canContinue) else { return }
            let choice=self.setup.firmwareChoice, destination=self.setup.destination
            self.dismiss()
            self.onCompletion?(choice,destination)
        }, onLater: { [weak self] in
            self?.model.deferSetup()
            self?.dismiss()
        }).preferredColorScheme(.dark))
        setupWindow = sheet
        parent.beginSheet(sheet)

    }

    private func availableSheetSize(parent: NSWindow) -> NSSize {
        let visible = parent.screen?.visibleFrame.size ?? NSSize(width: 1400, height: 900)
        return NSSize(width: min(620, max(360, min(parent.contentLayoutRect.width - 32, visible.width - 48))),
                      height: min(650, max(320, min(parent.contentLayoutRect.height - 32, visible.height - 80))))
    }
    func fitToParent(_ parent: NSWindow) {
        guard let sheet = setupWindow else { return }
        let available = availableSheetSize(parent: parent)
        let current = sheet.contentRect(forFrameRect: sheet.frame).size
        sheet.setContentSize(NSSize(width: min(current.width, available.width), height: min(current.height, available.height)))
    }

    /// Returning from Settings checks once; it never reopens Settings or a sheet.
    func refreshAfterActivation() {
        model.refresh()
        if setupWindow != nil { setup.scan() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.deferSetup()
        dismiss()
        return false
    }

    private func dismiss() {
        guard let sheet = setupWindow else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        setupWindow = nil
    }
}
