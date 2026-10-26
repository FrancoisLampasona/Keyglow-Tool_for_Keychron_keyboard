import AppKit
import SwiftUI

@MainActor final class OnboardingCoordinator: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    var onCompletion: (() -> Void)?
    private var setupWindow: NSWindow?

    init(model: OnboardingModel? = nil) {
        self.model = model ?? OnboardingModel()
        super.init()
    }

    func showIfNeeded(parent: NSWindow) {
        model.refresh()
        guard model.needsAutomaticPresentation else { return }
        show(parent: parent)
    }

    func show(parent: NSWindow) {
        model.refresh()
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            return
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
