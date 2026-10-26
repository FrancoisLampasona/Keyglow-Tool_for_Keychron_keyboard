import Foundation

@MainActor extension StudioModel {
    var reactiveFirmwareRecognized: Bool {
        // Preserve recognition of the physically verified 0.5 build.
        if usbSnapshot?.firmwareVersion == "v1.1.1 2026-10-26-21:48:49" { return true }
        guard let build = FirmwareBuildInfo.bundled, let snapshot = usbSnapshot,
              build.capabilities?.contains("reactive-idle-65520") == true else { return false }
        return build.matches(snapshot.firmwareVersion)
    }
    var energyChangesPending: Bool {
        guard let wireless = usbSnapshot?.wireless else { return false }
        return workspace.advanced.sleepMinutes != Int(wireless.sleepTimeoutSeconds) / 60 ||
               workspace.advanced.backlightSeconds != Int(wireless.backlightTimeoutSeconds)
    }
    func readRadioVersion() {
        guard !busy, let selected = selectedUSBID else { return }
        busy = true; radioVersion = nil; radioMessage = "Lettura della versione radio…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try RadioVersionReader.readUSB() }
            DispatchQueue.main.async { [self] in
                busy = false
                guard selectedUSBID == selected else { radioMessage = "Dispositivo cambiato. Ripeti la lettura sulla Q6 Max selezionata."; return }
                switch result {
                case .success(let version):
                    radioVersion = version
                    radioMessage = "Versione letta dal modulo radio. Consulta le note Keychron prima di valutare un aggiornamento."
                case .failure(let error): radioMessage = error.localizedDescription
                }
            }
        }
    }
}
