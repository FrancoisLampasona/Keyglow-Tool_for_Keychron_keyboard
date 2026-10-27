import AppKit
import SwiftUI

@MainActor final class OnboardingCoordinator: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    var onCompletion: (() -> Void)?
    private var setupWindow: NSWindow?
    private var automaticPresentation = false

    init(model: OnboardingModel? = nil) {
        self.model = model ?? OnboardingModel()
        super.init()
    }

    func showIfNeeded(parent: NSWindow) {
        model.refresh()
        guard model.needsAutomaticPresentation else { return }
        show(parent: parent, automatically: true)
    }

    func show(parent: NSWindow, automatically: Bool = false) {
        model.refresh()
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            return
        }
        automaticPresentation = automatically
        let available = availableSheetSize(parent: parent)
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: available),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sheet.contentMinSize = NSSize(width: min(480, available.width), height: min(480, available.height))
        sheet.title = "Configura \(model.appName)"
        sheet.isReleasedWhenClosed = false
        sheet.delegate = self
        sheet.contentView = NSHostingView(rootView: OnboardingView(model: model, onContinue: { [weak self] in
            guard let self, self.model.completeSetup() else { return }
            self.dismiss()
            self.onCompletion?()
        }, onLater: { [weak self] in
            self?.model.deferSetup()
            self?.dismiss()
        }).preferredColorScheme(.dark))
        setupWindow = sheet
        parent.beginSheet(sheet)
        model.beginAutomaticSetup()
        finishAutomaticSetupIfGranted()
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
        finishAutomaticSetupIfGranted()
    }
    private func finishAutomaticSetupIfGranted() {
        guard automaticPresentation, setupWindow != nil, model.canContinue, model.completeSetup() else { return }
        dismiss(); onCompletion?()
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
        automaticPresentation = false
    }
}
